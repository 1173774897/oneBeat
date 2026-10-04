import { common } from '@kit.AbilityKit';
import { iap } from '@kit.IAPKit';
import { util } from '@kit.ArkTS';
import { StorePurchaseSubmission } from './StoreModels';

interface PurchaseOrderProbe {
  productId?: string;
}

interface RenewalInfoProbe {
  productId?: string;
}

interface SubscriptionStatusProbe {
  renewalInfo?: RenewalInfoProbe;
  lastPurchaseOrder?: PurchaseOrderProbe;
}

interface PurchasePayloadProbe extends PurchaseOrderProbe {
  lastSubscriptionStatus?: SubscriptionStatusProbe;
}

interface PurchaseDataEnvelope {
  jwsPurchaseOrder?: string;
  jwsSubscriptionStatus?: string;
}

export function productTypeForStoreItem(isPass: boolean): iap.ProductType {
  return isPass ? iap.ProductType.AUTORENEWABLE : iap.ProductType.NONCONSUMABLE;
}

export async function createStorePurchase(
  context: common.UIAbilityContext,
  productId: string,
  productType: iap.ProductType,
  developerPayload: string
): Promise<StorePurchaseSubmission> {
  const parameter: iap.PurchaseParameter = {
    productId: productId,
    productType: productType,
    developerPayload: developerPayload
  };
  const result: iap.CreatePurchaseResult = await iap.createPurchase(context, parameter);
  if (result.purchaseData.length === 0) {
    throw new Error('华为支付未返回订单数据');
  }
  const clientPurchaseData = normalizePurchaseDataString(result.purchaseData);
  const serverPurchaseData = compactPurchaseDataForServer(clientPurchaseData);
  if (serverPurchaseData.length === 0) {
    throw new Error('华为支付未返回可验单的 JWS 数据');
  }
  return {
    idempotencyKey: util.generateRandomUUID(false),
    productId: productId,
    purchaseData: serverPurchaseData
  };
}

export async function queryRestorablePurchases(context: common.UIAbilityContext): Promise<StorePurchaseSubmission[]> {
  const purchases: StorePurchaseSubmission[] = [];
  const seenPurchaseData = new Set<string>();
  const productTypes: iap.ProductType[] = [iap.ProductType.NONCONSUMABLE, iap.ProductType.AUTORENEWABLE];
  const queryTypes: iap.PurchaseQueryType[] = [
    iap.PurchaseQueryType.CURRENT_ENTITLEMENT,
    iap.PurchaseQueryType.UNFINISHED
  ];
  for (let typeIndex = 0; typeIndex < productTypes.length; typeIndex++) {
    for (let queryIndex = 0; queryIndex < queryTypes.length; queryIndex++) {
      await appendPurchases(context, productTypes[typeIndex], queryTypes[queryIndex], purchases, seenPurchaseData);
    }
  }
  return purchases;
}

async function appendPurchases(
  context: common.UIAbilityContext,
  productType: iap.ProductType,
  queryType: iap.PurchaseQueryType,
  target: StorePurchaseSubmission[],
  seenPurchaseData: Set<string>
): Promise<void> {
  let continuationToken: string | undefined = undefined;
  do {
    const parameter: iap.QueryPurchasesParameter = {
      productType: productType,
      queryType: queryType,
      continuationToken: continuationToken
    };
    const result: iap.QueryPurchaseResult = await iap.queryPurchases(context, parameter);
    const purchaseDataList: string[] = result.purchaseDataList ?? [];
    for (let index = 0; index < purchaseDataList.length; index++) {
      const clientPurchaseData: string = normalizePurchaseDataString(purchaseDataList[index]);
      const serverPurchaseData: string = compactPurchaseDataForServer(clientPurchaseData);
      if (serverPurchaseData.length === 0 || seenPurchaseData.has(serverPurchaseData)) {
        continue;
      }
      seenPurchaseData.add(serverPurchaseData);
      const productId: string = productIdFromPurchaseData(clientPurchaseData);
      target.push({
        idempotencyKey: util.generateRandomUUID(false),
        productId: productId,
        purchaseData: serverPurchaseData
      });
    }
    continuationToken = result.continuationToken;
  } while (continuationToken !== undefined && continuationToken.length > 0 && target.length < 100);
}

function normalizePurchaseDataString(raw: string | Object): string {
  if (typeof raw === 'string') {
    return raw;
  }
  try {
    return JSON.stringify(raw);
  } catch (_e) {
    return '';
  }
}

// Backend expects compact JWS (see store-system-design §8.4). queryPurchases wraps it in JSON.
function compactPurchaseDataForServer(raw: string): string {
  const trimmed = raw.trim();
  if (isCompactJws(trimmed)) {
    return trimmed;
  }
  try {
    const envelope = JSON.parse(trimmed) as PurchaseDataEnvelope;
    const purchaseOrderJws = envelope.jwsPurchaseOrder ?? '';
    if (purchaseOrderJws.length > 0) {
      return purchaseOrderJws;
    }
    const subscriptionJws = envelope.jwsSubscriptionStatus ?? '';
    if (subscriptionJws.length > 0) {
      return subscriptionJws;
    }
  } catch (_e) {
    // Not JSON; fall through.
  }
  return '';
}

function isCompactJws(value: string): boolean {
  const parts = value.split('.');
  return parts.length === 3 && parts[0].startsWith('eyJ');
}

function productIdFromPurchaseData(raw: string): string {
  try {
    const envelope = JSON.parse(raw) as PurchaseDataEnvelope;
    const purchaseOrderJws = envelope.jwsPurchaseOrder ?? '';
    if (purchaseOrderJws.length > 0) {
      const fromOrder = productIdFromJwsPayload(purchaseOrderJws);
      if (fromOrder.length > 0) {
        return fromOrder;
      }
    }
    const subscriptionJws = envelope.jwsSubscriptionStatus ?? '';
    if (subscriptionJws.length > 0) {
      const fromSubscription = productIdFromJwsPayload(subscriptionJws);
      if (fromSubscription.length > 0) {
        return fromSubscription;
      }
    }
  } catch (_e) {
    // Fall through: purchaseData may already be a compact JWS string.
  }
  return productIdFromJwsPayload(raw);
}

function productIdFromJwsPayload(jws: string): string {
  const payloadJson = decodeJwsPayload(jws);
  if (payloadJson.length === 0) {
    return '';
  }
  try {
    const payload = JSON.parse(payloadJson) as PurchasePayloadProbe;
    if (payload.productId !== undefined && payload.productId.length > 0) {
      return payload.productId;
    }
    const status = payload.lastSubscriptionStatus;
    if (status?.renewalInfo?.productId !== undefined && status.renewalInfo.productId.length > 0) {
      return status.renewalInfo.productId;
    }
    const orderProductId = status?.lastPurchaseOrder?.productId;
    return orderProductId !== undefined ? orderProductId : '';
  } catch (_e) {
    return '';
  }
}

function decodeJwsPayload(jws: string): string {
  const parts = jws.split('.');
  if (parts.length !== 3) {
    return '';
  }
  return base64UrlDecode(parts[1]);
}

function base64UrlDecode(input: string): string {
  try {
    let base64 = input.replace(/-/g, '+').replace(/_/g, '/');
    const padding = base64.length % 4;
    if (padding > 0) {
      base64 += '='.repeat(4 - padding);
    }
    const decoded = new util.Base64Helper().decodeSync(base64);
    return util.TextDecoder.create('utf-8').decodeToString(decoded);
  } catch (_e) {
    return '';
  }
}
