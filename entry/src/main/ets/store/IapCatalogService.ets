import { common } from '@kit.AbilityKit';
import { iap } from '@kit.IAPKit';

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

function displayPriceForProduct(product: iap.Product): string {
  const localPrice = product.localPrice ?? '';
  return localPrice.length > 0 ? localPrice : '';
}

function addPrices(target: StoreProductPrice[], products: iap.Product[]): void {
  for (let i = 0; i < products.length; i++) {
    const product = products[i];
    const displayPrice = displayPriceForProduct(product);
    if (displayPrice.length > 0) {
      target.push({ productId: product.id, displayPrice: displayPrice });
    }
  }
}

export async function queryStoreProductPrices(context: common.UIAbilityContext): Promise<StoreProductPrice[]> {
  const prices: StoreProductPrice[] = [];
  const products = await iap.queryProducts(context, {
    productType: iap.ProductType.NONCONSUMABLE,
    productIds: NONCONSUMABLE_PRODUCT_IDS
  });
  addPrices(prices, products);

  const subscriptions = await iap.queryProducts(context, {
    productType: iap.ProductType.AUTORENEWABLE,
    productIds: SUBSCRIPTION_PRODUCT_IDS
  });
  addPrices(prices, subscriptions);
  return prices;
}
