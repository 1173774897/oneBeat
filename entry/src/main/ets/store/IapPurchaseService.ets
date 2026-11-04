import { common } from '@kit.AbilityKit';
import { iap } from '@kit.IAPKit';
import { deliverNewPurchase } from './IapEntitlements';
import { VerifiedIapRecord } from './IapJwsVerifier';

export function productTypeForStoreItem(isPass: boolean): iap.ProductType {
  return isPass ? iap.ProductType.AUTORENEWABLE : iap.ProductType.NONCONSUMABLE;
}

/**
 * Opens Huawei checkout and delivers the result on the device: verify the JWS,
 * save the entitlement locally, then finishPurchase. Nothing is sent to the
 * store server. No developerPayload is set because no server account binding
 * exists any more; the purchase belongs to the Huawei account.
 */
export async function purchaseStoreProduct(
  context: common.UIAbilityContext,
  productId: string,
  productType: iap.ProductType
): Promise<VerifiedIapRecord> {
  const parameter: iap.PurchaseParameter = { productId, productType };
  const result: iap.CreatePurchaseResult = await iap.createPurchase(context, parameter);
  const raw: string | Object = result.purchaseData;
  const purchaseData = typeof raw === 'string' ? raw : JSON.stringify(raw);
  if (purchaseData.length === 0) {
    throw new Error('华为支付未返回订单数据');
  }
  const record = await deliverNewPurchase(context, purchaseData, productType);
  const deliveredProductId = record.purchase?.productId ?? record.pass?.productId ?? '';
  if (deliveredProductId !== productId) {
    throw new Error('华为支付返回的商品与所选商品不一致');
  }
  return record;
}
