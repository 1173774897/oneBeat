import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { iap } from '@kit.IAPKit';

const STORE_IAP_LOG_TAG: string = '[StoreIap]';

/** Product id / type mismatch or AGC catalog not effective for this bundle. */
const IAP_ERROR_INVALID_PRODUCT: number = 1001860003;
/** IAP environment check when Huawei ID sign-in UI cannot be shown (still treat as unsigned). */
const IAP_ERROR_ACCOUNT_LOGIN_UNAVAILABLE: number = 1001860050;

const NONCONSUMABLE_PRODUCT_IDS: string[] = [
  'onebeat.character.cloud',
  'onebeat.character.teapot',
  'onebeat.character.wave',
  'onebeat.character.mismatch',
  'onebeat.character.scooter',
  'onebeat.character.lilroll',
  'onebeat.character.lamp',
  'onebeat.scene.neon_street'
];

const SUBSCRIPTION_PRODUCT_IDS: string[] = ['onebeat.pass.monthly'];

export interface StoreProductPrice {
  productId: string;
  displayPrice: string;
}

export type StorePriceUnavailableReason = 'none' | 'huawei_account' | 'product_catalog' | 'unknown';

export interface StoreProductPriceQueryResult {
  prices: StoreProductPrice[];
  unavailableReason: StorePriceUnavailableReason;
}

export function storeProductPriceQueryResult(
  prices: StoreProductPrice[],
  unavailableReason: StorePriceUnavailableReason
): StoreProductPriceQueryResult {
  const result: StoreProductPriceQueryResult = {
    prices: prices,
    unavailableReason: unavailableReason
  };
  return result;
}

export function emptyStoreProductPriceQueryResult(
  unavailableReason: StorePriceUnavailableReason
): StoreProductPriceQueryResult {
  return storeProductPriceQueryResult([], unavailableReason);
}

export function storePriceUnavailableMessage(reason: StorePriceUnavailableReason): string {
  if (reason === 'huawei_account') {
    return '请先在系统「设置」登录华为账号，返回小铺后将自动刷新价格';
  }
  if (reason === 'product_catalog') {
    return '华为商店商品信息暂未就绪，请更新应用或稍后再试';
  }
  if (reason === 'unknown') {
    return '商品价格暂时不可用，请检查网络后重试';
  }
  return '';
}

export function formatStoreIapError(err: Object): string {
  const business = err as BusinessError;
  const code = business.code ?? 0;
  let message = '';
  if (err instanceof Error) {
    message = err.message.trim();
  } else if (business.message !== undefined) {
    message = `${business.message}`.trim();
  } else {
    message = `${err}`.trim();
  }
  if (message.length === 0) {
    message = 'unknown error';
  }
  return code !== 0 ? `${message} (code=${code})` : message;
}

function iapErrorCode(err: Object): number {
  return (err as BusinessError).code ?? 0;
}

function isHuaweiAccountRequiredError(code: number): boolean {
  if (code === IAP_ERROR_ACCOUNT_LOGIN_UNAVAILABLE) {
    return true;
  }
  return code === iap.IAPErrorCode.ACCOUNT_NOT_LOGGED_IN;
}

function classifyPriceUnavailableReason(failureCodes: number[]): StorePriceUnavailableReason {
  for (let i = 0; i < failureCodes.length; i++) {
    if (isHuaweiAccountRequiredError(failureCodes[i])) {
      return 'huawei_account';
    }
  }
  for (let i = 0; i < failureCodes.length; i++) {
    if (failureCodes[i] === IAP_ERROR_INVALID_PRODUCT) {
      return 'product_catalog';
    }
  }
  return failureCodes.length > 0 ? 'unknown' : 'product_catalog';
}

function displayPriceForProduct(product: iap.Product): string {
  const localPrice = product.localPrice ?? '';
  return localPrice.length > 0 ? localPrice : '';
}

function addPrices(target: StoreProductPrice[], products: iap.Product[]): number {
  let added = 0;
  for (let i = 0; i < products.length; i++) {
    const product = products[i];
    const displayPrice = displayPriceForProduct(product);
    if (displayPrice.length > 0) {
      target.push({ productId: product.id, displayPrice: displayPrice });
      added++;
    }
  }
  return added;
}

function productWasReturned(products: iap.Product[], productId: string): boolean {
  for (let i = 0; i < products.length; i++) {
    if (products[i].id === productId) {
      return true;
    }
  }
  return false;
}

function logProductQueryResult(
  label: string,
  requestedIds: string[],
  products: iap.Product[],
  prices: StoreProductPrice[]
): void {
  const beforeCount = prices.length;
  const pricedCount = addPrices(prices, products);
  console.info(`${STORE_IAP_LOG_TAG} ${label} requested=${requestedIds.length} ` +
    `returned=${products.length} priced=${pricedCount}`);
  for (let i = 0; i < products.length; i++) {
    const product = products[i];
    if (displayPriceForProduct(product).length === 0) {
      console.warn(`${STORE_IAP_LOG_TAG} ${label} productId=${product.id} returned without localPrice`);
    }
  }
  for (let i = 0; i < requestedIds.length; i++) {
    const productId = requestedIds[i];
    if (!productWasReturned(products, productId)) {
      console.warn(`${STORE_IAP_LOG_TAG} ${label} productId=${productId} not returned by IAP ` +
        `(check AppGallery Connect id, type, and app bundle)`);
    }
  }
  if (pricedCount === 0 && products.length > 0) {
    console.warn(`${STORE_IAP_LOG_TAG} ${label} IAP returned ${products.length} product(s) but none had ` +
      `localPrice; prices added=${prices.length - beforeCount}`);
  }
}

async function queryProductPricesForType(
  context: common.UIAbilityContext,
  label: string,
  productType: iap.ProductType,
  productIds: string[],
  prices: StoreProductPrice[]
): Promise<number> {
  try {
    const products = await iap.queryProducts(context, {
      productType: productType,
      productIds: productIds
    });
    logProductQueryResult(label, productIds, products, prices);
    return 0;
  } catch (err) {
    const code = iapErrorCode(err);
    console.error(`${STORE_IAP_LOG_TAG} queryProducts ${label} failed: ${formatStoreIapError(err)}`);
    return code;
  }
}

async function ensureIapEnvironmentReady(
  context: common.UIAbilityContext,
  failureCodes: number[]
): Promise<boolean> {
  try {
    await iap.queryEnvironmentStatus(context);
    console.info(`${STORE_IAP_LOG_TAG} queryEnvironmentStatus ok`);
    return true;
  } catch (err) {
    const code = iapErrorCode(err);
    failureCodes.push(code);
    console.warn(`${STORE_IAP_LOG_TAG} queryEnvironmentStatus failed: ${formatStoreIapError(err)}`);
    return !isHuaweiAccountRequiredError(code);
  }
}

export async function queryStoreProductPrices(
  context: common.UIAbilityContext
): Promise<StoreProductPriceQueryResult> {
  console.info(`${STORE_IAP_LOG_TAG} queryStoreProductPrices start ` +
    `nonConsumable=${NONCONSUMABLE_PRODUCT_IDS.length} subscription=${SUBSCRIPTION_PRODUCT_IDS.length}`);
  const prices: StoreProductPrice[] = [];
  const failureCodes: number[] = [];

  const environmentReady = await ensureIapEnvironmentReady(context, failureCodes);
  if (!environmentReady) {
    console.warn(`${STORE_IAP_LOG_TAG} skipping product query: Huawei account required`);
    return emptyStoreProductPriceQueryResult('huawei_account');
  }

  const nonConsumableCode = await queryProductPricesForType(
    context,
    'NONCONSUMABLE',
    iap.ProductType.NONCONSUMABLE,
    NONCONSUMABLE_PRODUCT_IDS,
    prices
  );
  if (nonConsumableCode !== 0) {
    failureCodes.push(nonConsumableCode);
  }

  const subscriptionCode = await queryProductPricesForType(
    context,
    'AUTORENEWABLE',
    iap.ProductType.AUTORENEWABLE,
    SUBSCRIPTION_PRODUCT_IDS,
    prices
  );
  if (subscriptionCode !== 0) {
    failureCodes.push(subscriptionCode);
  }

  if (prices.length > 0) {
    console.info(`${STORE_IAP_LOG_TAG} queryStoreProductPrices finished priceCount=${prices.length}`);
    return storeProductPriceQueryResult(prices, 'none');
  }

  const unavailableReason = classifyPriceUnavailableReason(failureCodes);
  console.warn(`${STORE_IAP_LOG_TAG} queryStoreProductPrices finished with zero prices; ` +
    `reason=${unavailableReason} codes=${failureCodes.join(',')}`);
  return emptyStoreProductPriceQueryResult(unavailableReason);
}
