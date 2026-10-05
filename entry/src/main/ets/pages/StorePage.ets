import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { promptAction, router } from '@kit.ArkUI';
import {
  ComicCharacter,
  CORAL,
  INK,
  LILAC,
  PAPER,
  CARD_SHADOW,
  CONTROL_SHADOW
} from '../components/ComicKit';
import { fetchStoreBootstrap, redeemStoreCode, restoreStorePurchases, verifyStorePurchase } from '../store/StoreApi';
import { isStoreApiConfigured } from '../store/StoreApiConfig';
import {
  applyStoreBootstrap,
  initializeEntitlementCache,
  limitedFreeCharacterKeys,
  ownedCharacterKeys,
  ownedSceneKeys,
  storeItemAccessReason
} from '../store/EntitlementStore';
import { queryStoreProductPrices, StoreProductPrice } from '../store/IapCatalogService';
import {
  clearStoreSession,
  currentStoreSessionToken,
  ensureStoreSession
} from '../store/HuaweiAccountService';
import {
  createStorePurchase,
  productTypeForStoreItem,
  queryRestorablePurchases
} from '../store/IapPurchaseService';
import { StoreBootstrap, StorePurchaseSubmission } from '../store/StoreModels';

interface StoreCharacter {
  key: string;
  name: string;
  caption: string;
  asset: string;
  color: string;
  productId: string;
  mystery?: boolean;
}

interface StoreScene {
  key: string;
  name: string;
  caption: string;
  productId: string;
}

const STORE_CHARACTERS: StoreCharacter[] = [
  { key: 'braids', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'braids', color: '#B9B2C7', productId: '', mystery: true },
  { key: 'boonie', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'boonie', color: '#B7C7BC', productId: '', mystery: true },
  { key: 'curly', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'curly', color: '#B6C7C8', productId: '', mystery: true },
  { key: 'buzz', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'buzz', color: '#C7BEBA', productId: '', mystery: true },
  { key: 'cloud', name: '云行者', caption: '轻盈天空拍', asset: 'cloud', color: '#DCE9FA', productId: 'onebeat.character.cloud' },
  { key: 'teapot', name: '茶壶太太', caption: '慢火稳拍', asset: 'teapot', color: '#FFD06A', productId: 'onebeat.character.teapot' },
  { key: 'wave', name: 'Wave', caption: '浪线步态', asset: 'wave', color: '#7EC8FF', productId: 'onebeat.character.wave' },
  { key: 'mismatch', name: '条纹步客', caption: '酷脸推进', asset: 'mismatch', color: '#E8DFF6', productId: 'onebeat.character.mismatch' },
  { key: 'scooter', name: '思古特', caption: '双拍十六帧', asset: 'scooter', color: '#FF9E7A', productId: 'onebeat.character.scooter' },
  { key: 'lilroll', name: '轮滑小子', caption: '贴地飞行', asset: 'lilroll', color: '#C7B8EC', productId: 'onebeat.character.lilroll' },
  { key: 'lamp', name: '台灯漫游者', caption: '独占角色', asset: 'lamp', color: '#FFB347', productId: 'onebeat.character.lamp' }
];

const STORE_SCENES: StoreScene[] = [
  { key: 'sunset_coast', name: '夕阳海边', caption: '海水、云层与土路循环行进', productId: '' },
  { key: 'neon_street', name: '霓虹街口', caption: '雨夜楼群与湿润街道多层视差', productId: 'onebeat.scene.neon_street' }
];

const PASS_PRODUCT_ID: string = 'onebeat.pass.monthly';
const IAP_ERROR_ALREADY_OWNED: number = 1001860051;

@Entry
@Component
struct StorePage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') selectedSceneKey: string = 'sunset_coast';
  @State selectedTab: number = 0;
  @State ownedCharacters: string[] = [];
  @State ownedScenes: string[] = [];
  @State passActive: boolean = false;
  @State passStatus: string = '';
  @State passExpiresAt: string = '';
  @State passAutoRenewing: boolean = false;
  @State passSource: string = '';
  @State passIapPurchaseAllowed: boolean = true;
  @State limitedFreeCharacters: string[] = [];
  @State limitedFreeScenes: string[] = [];
  @State passCharacters: string[] = [];
  @State passScenes: string[] = [];
  @State redemptionAvailable: boolean = false;
  @State redemptionVisible: boolean = false;
  @State redemptionCode: string = '';
  @State redemptionIdempotencyKey: string = '';
  @State redemptionStatus: string = '';
  @State redemptionBusy: boolean = false;
  @State purchaseVisible: boolean = false;
  @State pendingType: string = '';
  @State pendingKey: string = '';
  @State pendingName: string = '';
  @State pendingPrice: string = '';
  @State pendingProductId: string = '';
  @State productPrices: StoreProductPrice[] = [];
  @State productPriceEpoch: number = 0;
  @State serviceStatus: string = '';
  @State purchaseBusy: boolean = false;

  aboutToAppear(): void {
    initializeEntitlementCache();
    this.loadPurchases();
    void this.refreshStoreData();
  }

  onBackPress(): boolean {
    if (this.purchaseVisible) {
      this.purchaseVisible = false;
      return true;
    }
    if (this.redemptionVisible) {
      this.redemptionVisible = false;
      return true;
    }
    return false;
  }

  private hostContext(): common.UIAbilityContext {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      throw new Error('无法获取应用上下文');
    }
    return host as common.UIAbilityContext;
  }

  private purchaseFailureMessage(error: Object): string {
    if (error instanceof Error && error.message.length > 0) {
      return error.message;
    }
    return '购买未完成，请稍后重试';
  }

  private async refreshStoreData(): Promise<void> {
    const priceTask: Promise<StoreProductPrice[]> = isStoreApiConfigured() ?
      queryStoreProductPrices(this.hostContext()).catch((_e: Object) => [] as StoreProductPrice[]) :
      Promise.resolve([] as StoreProductPrice[]);

    if (!isStoreApiConfigured()) {
      this.serviceStatus = '开发配置：请填写测试与生产 API 地址';
    } else {
      try {
        let accessToken = currentStoreSessionToken();
        if (accessToken.length === 0) {
          try {
            accessToken = await ensureStoreSession(this.hostContext(), false);
          } catch (_e) {
            accessToken = '';
          }
        }
        let bootstrap: StoreBootstrap | null = null;
        try {
          bootstrap = await fetchStoreBootstrap(accessToken);
        } catch (_e) {
          if (accessToken.length === 0) {
            throw new Error('匿名商店目录加载失败');
          }
          clearStoreSession();
          bootstrap = await fetchStoreBootstrap();
        }
        if (bootstrap !== null) {
          applyStoreBootstrap(bootstrap);
          this.loadPurchases();
          this.serviceStatus = '';
        }
      } catch (_e) {
        this.serviceStatus = '商店服务暂时不可用，已使用本机最近一次权益';
      }
    }

    try {
      const prices = await priceTask;
      this.productPrices = prices;
      this.productPriceEpoch++;
      if (prices.length === 0 && this.serviceStatus.length === 0 && isStoreApiConfigured()) {
        this.serviceStatus = '商品价格暂时不可用，请稍后重试';
      }
    } catch (_e) {
      if (this.serviceStatus.length === 0) {
        this.serviceStatus = '商品价格暂时不可用，请稍后重试';
      }
    }
  }

  private storeOfferRenderKey(scope: string, itemKey: string, productId: string): string {
    return `${scope}:${itemKey}:${this.productPriceEpoch}:${this.productPrice(productId)}`;
  }

  private loadPurchases(): void {
    this.ownedCharacters = ownedCharacterKeys();
    this.ownedScenes = ownedSceneKeys();
    this.passActive = AppStorage.get<boolean>('storePassActive') ?? false;
    this.passStatus = AppStorage.get<string>('storePassStatus') ?? '';
    this.passExpiresAt = AppStorage.get<string>('storePassExpiresAt') ?? '';
    this.passAutoRenewing = AppStorage.get<boolean>('storePassAutoRenewing') ?? false;
    this.passSource = AppStorage.get<string>('storePassSource') ?? '';
    this.passIapPurchaseAllowed = AppStorage.get<boolean>('storePassIapPurchaseAllowed') ?? true;
    this.limitedFreeCharacters = limitedFreeCharacterKeys();
    const limitedScenes: string[] = [];
    const passCharacters: string[] = [];
    const passScenes: string[] = [];
    for (let i = 0; i < STORE_CHARACTERS.length; i++) {
      const reason = storeItemAccessReason(`character.${STORE_CHARACTERS[i].key}`);
      if (reason === 'PASS_IAP' || reason === 'PASS_REDEMPTION') {
        passCharacters.push(STORE_CHARACTERS[i].key);
      }
    }
    for (let i = 0; i < STORE_SCENES.length; i++) {
      const reason = storeItemAccessReason(`scene.${STORE_SCENES[i].key}`);
      if (reason === 'LIMITED_FREE') {
        limitedScenes.push(STORE_SCENES[i].key);
      } else if (reason === 'PASS_IAP' || reason === 'PASS_REDEMPTION') {
        passScenes.push(STORE_SCENES[i].key);
      }
    }
    this.limitedFreeScenes = limitedScenes;
    this.passCharacters = passCharacters;
    this.passScenes = passScenes;
    this.redemptionAvailable = AppStorage.get<boolean>('storeRedemptionAvailable') ?? false;
  }

  private hasCharacter(key: string): boolean {
    return this.ownedCharacters.indexOf(key) >= 0;
  }

  private hasScene(key: string): boolean {
    return this.ownedScenes.indexOf(key) >= 0;
  }

  private selectScene(item: StoreScene): void {
    if (!this.hasScene(item.key)) {
      return;
    }
    this.selectedSceneKey = item.key;
    promptAction.showToast({ message: `已切换到 ${item.name}` });
  }

  private ownedCharacterCount(): number {
    let count = 0;
    for (let i = 0; i < STORE_CHARACTERS.length; i++) {
      if (this.ownedCharacters.indexOf(STORE_CHARACTERS[i].key) >= 0) {
        count++;
      }
    }
    return count;
  }

  private visibleCharacterCount(onlyAccessible: boolean): number {
    if (!onlyAccessible) {
      return STORE_CHARACTERS.length;
    }
    return this.ownedCharacterCount();
  }

  private openCharacterPurchase(item: StoreCharacter): void {
    if (this.hasCharacter(item.key)) {
      return;
    }
    this.pendingType = 'character';
    this.pendingKey = item.key;
    this.pendingName = item.name;
    this.pendingPrice = this.productPrice(item.productId);
    this.pendingProductId = item.productId;
    this.purchaseVisible = true;
  }

  private openScenePurchase(item: StoreScene): void {
    this.pendingType = 'scene';
    this.pendingKey = item.key;
    this.pendingName = item.name;
    this.pendingPrice = this.productPrice(item.productId);
    this.pendingProductId = item.productId;
    this.purchaseVisible = true;
  }

  private openPassPurchase(): void {
    if (this.passActive) {
      const message = this.passSource === 'PASS_REDEMPTION' ?
        '赠送月卡生效期间不能购买自动续费月卡' : '畅游月卡已生效';
      promptAction.showToast({ message: message });
      return;
    }
    if (!this.passIapPurchaseAllowed) {
      promptAction.showToast({ message: '当前暂不能购买自动续费月卡' });
      return;
    }
    this.pendingType = 'pass';
    this.pendingKey = 'pass.all';
    this.pendingName = '畅游月卡';
    this.pendingPrice = this.productPrice(PASS_PRODUCT_ID);
    this.pendingProductId = PASS_PRODUCT_ID;
    this.purchaseVisible = true;
  }

  private restorablePurchases(purchases: StorePurchaseSubmission[]): StorePurchaseSubmission[] {
    const restorable: StorePurchaseSubmission[] = [];
    for (let i = 0; i < purchases.length; i++) {
      if (purchases[i].productId.length > 0 && purchases[i].purchaseData.length > 0) {
        restorable.push(purchases[i]);
      }
    }
    return restorable;
  }

  private purchasesForProduct(
    purchases: StorePurchaseSubmission[],
    productId: string
  ): StorePurchaseSubmission[] {
    const matched: StorePurchaseSubmission[] = [];
    for (let i = 0; i < purchases.length; i++) {
      if (purchases[i].productId === productId) {
        matched.push(purchases[i]);
      }
    }
    return matched;
  }

  private async syncOwnedPurchase(accessToken: string, productId: string): Promise<boolean> {
    const purchases = this.restorablePurchases(await queryRestorablePurchases(this.hostContext()));
    const scoped = this.purchasesForProduct(purchases, productId);
    if (scoped.length === 0) {
      return false;
    }
    try {
      const verified = await verifyStorePurchase(accessToken, scoped[0]);
      applyStoreBootstrap(verified);
      this.loadPurchases();
      return true;
    } catch (_verifyError) {
      const bootstrap = await restoreStorePurchases(accessToken, [scoped[0]]);
      applyStoreBootstrap(bootstrap);
      this.loadPurchases();
      return true;
    }
  }

  private async confirmPurchase(): Promise<void> {
    if (this.purchaseBusy || this.pendingProductId.length === 0) {
      return;
    }
    this.purchaseVisible = false;
    this.purchaseBusy = true;
    this.serviceStatus = '正在连接华为支付并核验订单…';
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      // Recheck the server immediately before opening Huawei checkout. Cached UI
      // state may predate a code redemption on another device.
      const bootstrap = await fetchStoreBootstrap(accessToken);
      if (bootstrap === null || bootstrap.developerPayload === undefined || bootstrap.developerPayload.length === 0) {
        throw new Error('服务端未返回购买绑定信息');
      }
      applyStoreBootstrap(bootstrap);
      this.loadPurchases();
      if (this.pendingType === 'pass' && (!bootstrap.pass.iapPurchaseAllowed || bootstrap.pass.active)) {
        throw new Error(bootstrap.pass.source === 'PASS_REDEMPTION' ?
          '赠送月卡生效期间不能购买自动续费月卡' : '畅游月卡已生效');
      }
      try {
        const purchase = await createStorePurchase(
          this.hostContext(),
          this.pendingProductId,
          productTypeForStoreItem(this.pendingType === 'pass'),
          bootstrap.developerPayload
        );
        const verified = await verifyStorePurchase(accessToken, purchase);
        applyStoreBootstrap(verified);
        this.loadPurchases();
        this.serviceStatus = '';
        promptAction.showToast({ message: '购买成功，权益已到账' });
      } catch (purchaseError) {
        const iapError = purchaseError as BusinessError;
        if (iapError.code !== IAP_ERROR_ALREADY_OWNED) {
          if (purchaseError instanceof Error) {
            throw purchaseError;
          }
          throw new Error('购买未完成，请稍后重试');
        }
        this.serviceStatus = '华为账号已拥有该商品，正在同步权益…';
        const synced = await this.syncOwnedPurchase(accessToken, this.pendingProductId);
        if (!synced) {
          throw new Error('华为账号已拥有该商品，请稍后点击「恢复购买」同步权益');
        }
        this.serviceStatus = '';
        promptAction.showToast({ message: '已同步华为账号中的购买记录' });
      }
    } catch (e) {
      const detail = this.purchaseFailureMessage(e);
      this.serviceStatus = detail.length > 0 ?
        detail : '购买未完成或验单失败，可稍后点击“恢复购买”重试';
      promptAction.showToast({ message: this.purchaseFailureMessage(e) });
    } finally {
      this.purchaseBusy = false;
    }
  }

  private async synchronizePurchasesBeforeRedemption(accessToken: string): Promise<void> {
    // Huawei cannot query all subscriptions by OneBeat user ID. Restore the
    // purchases visible on this device before asking the server to grant a pass.
    const purchases = this.restorablePurchases(await queryRestorablePurchases(this.hostContext()));
    const bootstrap = await restoreStorePurchases(accessToken, purchases);
    applyStoreBootstrap(bootstrap);
    this.loadPurchases();
  }

  private async submitRedemption(): Promise<void> {
    if (this.redemptionBusy || this.redemptionCode.trim().length === 0) {
      return;
    }
    this.redemptionBusy = true;
    this.redemptionStatus = '正在核对账号权益…';
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      await this.synchronizePurchasesBeforeRedemption(accessToken);
      if (this.passActive && this.passSource === 'PASS_IAP') {
        throw new Error('华为自动续费月卡仍在生效，暂时不能领取赠送月卡');
      }
      if (this.redemptionIdempotencyKey.length === 0) {
        // Reuse this UUID after transport failures; editing the code clears it so
        // a changed phrase cannot accidentally replay the previous redemption.
        this.redemptionIdempotencyKey = util.generateRandomUUID(false);
      }
      const result = await redeemStoreCode(accessToken, {
        idempotencyKey: this.redemptionIdempotencyKey,
        code: this.redemptionCode
      });
      const bootstrap = await fetchStoreBootstrap(accessToken);
      if (bootstrap !== null) {
        applyStoreBootstrap(bootstrap);
        this.loadPurchases();
      }
      this.redemptionCode = '';
      this.redemptionIdempotencyKey = '';
      this.redemptionStatus = `领取成功，赠送月卡可用至 ${this.passDate(result.pass.expiresAt ?? '')}`;
      promptAction.showToast({ message: '口令兑换成功，畅游月卡已到账' });
    } catch (e) {
      const detail = this.purchaseFailureMessage(e);
      this.redemptionStatus = detail;
      promptAction.showToast({ message: detail });
    } finally {
      this.redemptionBusy = false;
    }
  }

  private async restorePurchases(): Promise<void> {
    if (this.purchaseBusy) {
      return;
    }
    this.purchaseBusy = true;
    this.serviceStatus = '正在从华为账号恢复购买记录…';
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      const purchases = this.restorablePurchases(await queryRestorablePurchases(this.hostContext()));
      let bootstrap: StoreBootstrap | null = null;
      let lastFailureMessage: string = '';
      if (purchases.length > 0) {
        try {
          bootstrap = await restoreStorePurchases(accessToken, purchases);
        } catch (_batchRestoreError) {
          let syncedCount: number = 0;
          for (let i = 0; i < purchases.length; i++) {
            try {
              await verifyStorePurchase(accessToken, purchases[i]);
              syncedCount++;
            } catch (verifyError) {
              lastFailureMessage = this.purchaseFailureMessage(verifyError);
              try {
                await restoreStorePurchases(accessToken, [purchases[i]]);
                syncedCount++;
              } catch (restoreError) {
                lastFailureMessage = this.purchaseFailureMessage(restoreError);
              }
            }
          }
          if (syncedCount === 0) {
            throw new Error(lastFailureMessage.length > 0 ?
              lastFailureMessage : '恢复购买失败，请稍后重试');
          }
          bootstrap = await fetchStoreBootstrap(accessToken);
        }
      } else {
        try {
          bootstrap = await restoreStorePurchases(accessToken, []);
        } catch (_reconcileError) {
          bootstrap = await fetchStoreBootstrap(accessToken);
        }
      }
      if (bootstrap !== null) {
        applyStoreBootstrap(bootstrap);
        this.loadPurchases();
      }
      this.serviceStatus = '';
      const toastMessage = purchases.length > 0 ?
        '购买记录已恢复' : '已与服务端同步账号权益';
      promptAction.showToast({ message: toastMessage });
    } catch (e) {
      const detail = this.purchaseFailureMessage(e);
      this.serviceStatus = detail.length > 0 ? detail : '恢复购买失败，请确认华为账号与网络状态后重试';
      promptAction.showToast({ message: detail.length > 0 ? detail : '恢复购买失败，请稍后重试' });
    } finally {
      this.purchaseBusy = false;
    }
  }

  private productPrice(productId: string): string {
    if (productId.length === 0) {
      return '免费';
    }
    for (let i = 0; i < this.productPrices.length; i++) {
      if (this.productPrices[i].productId === productId) {
        return this.productPrices[i].displayPrice;
      }
    }
    return '价格加载中';
  }

  private characterAccessState(item: StoreCharacter): string {
    if (item.mystery === true) {
      return 'mystery';
    }
    if (this.limitedFreeCharacters.indexOf(item.key) >= 0) {
      return 'limited';
    }
    if (this.passCharacters.indexOf(item.key) >= 0) {
      return 'pass';
    }
    return this.hasCharacter(item.key) ? 'owned' : 'locked';
  }

  private sceneAccessState(item: StoreScene): string {
    if (this.limitedFreeScenes.indexOf(item.key) >= 0) {
      return 'limited';
    }
    if (this.passScenes.indexOf(item.key) >= 0) {
      return 'pass';
    }
    return this.hasScene(item.key) ? 'owned' : 'locked';
  }

  private passDate(value: string): string {
    if (value.length === 0) {
      return '';
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return '';
    }
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day}`;
  }

  private passDescription(): string {
    const expires = this.passDate(this.passExpiresAt);
    if (this.passStatus === 'CANCELED_ACTIVE' && this.passActive) {
      return expires.length > 0 ? `已取消续费，可使用至 ${expires}` : '已取消续费，本期仍可使用';
    }
    if (this.passActive && this.passAutoRenewing) {
      return expires.length > 0 ? `自动续费中 · 可使用至 ${expires}` : '自动续费中';
    }
    if (this.passActive) {
      if (this.passSource === 'PASS_REDEMPTION') {
        return expires.length > 0 ? `口令赠送 · 可使用至 ${expires}` : '口令赠送月卡';
      }
      return expires.length > 0 ? `可使用至 ${expires}` : '全部角色与场景';
    }
    return '全部角色、场景与 PRO 鼓机';
  }

  private passButtonLabel(): string {
    if (this.passActive) {
      return this.passSource === 'PASS_REDEMPTION' ? '赠送生效中' : '已开通';
    }
    return '查看方案  ›';
  }

  @Builder
  private redemptionCard() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 2 }) {
          Text('活动口令').fontSize(24).fontWeight(900).fontStyle(FontStyle.Italic)
          Text('登录后兑换 · 赠送一个自然月 · 不自动续费')
            .fontSize(11).fontColor('#645E55').maxLines(2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.redemptionAvailable ? 'OPEN' : 'CLOSED').fontSize(9).fontWeight(900).fontColor(PAPER)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.redemptionAvailable ? CORAL : INK).rotate({ angle: 3 })
          .shadow(CONTROL_SHADOW)
      }.width('100%')
      if (this.redemptionAvailable) {
        Column({ space: 9 }) {
          TextInput({ placeholder: '输入活动口令', text: this.redemptionCode })
            .width('100%').height(46).fontSize(15).fontColor(INK)
            .placeholderColor('#8D857A').backgroundColor(PAPER)
            .border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .padding({ left: 12, right: 12 }).maxLength(64)
            .enabled(!this.redemptionBusy)
            .onChange((value: string) => {
              this.redemptionCode = value;
              this.redemptionIdempotencyKey = '';
            })
          Button(this.redemptionBusy ? '兑换中…' : '立即兑换', { type: ButtonType.Normal })
            .width('100%').height(46).padding(0).fontSize(15).fontWeight(900).fontColor(INK)
            .backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(5)
            .shadow({ radius: 0, offsetX: 3, offsetY: 4, color: INK })
            .enabled(!this.redemptionBusy && this.redemptionCode.trim().length > 0)
            .onClick(() => void this.submitRedemption())
        }.width('100%')
      } else {
        Text('当前没有开放中的口令活动')
          .width('100%').fontSize(14).fontWeight(900).textAlign(TextAlign.Center)
          .padding({ top: 20, bottom: 20 }).backgroundColor(PAPER)
          .border({ width: 1.2, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
      }
      if (this.redemptionStatus.length > 0) {
        Text(this.redemptionStatus).fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor('#645E55').lineHeight(17).width('100%')
      }
    }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 18 })
    .backgroundColor(LILAC).border({ width: 2, color: INK }).borderRadius(8)
    .shadow({ radius: 0, offsetX: 5, offsetY: 6, color: INK })
  }

  @Builder
  private redemptionEntrance() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(33).height(24).backgroundColor(LILAC)
        .border({ width: 2, color: INK }).borderRadius(4)
        .rotate({ angle: -7 })
        .shadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
      Text('兑').fontSize(14).fontWeight(900).fontStyle(FontStyle.Italic).rotate({ angle: -7 })
      if (this.redemptionAvailable) {
        Circle().width(9).height(9).fill(CORAL).stroke(PAPER).strokeWidth(1.5)
          .position({ x: 34, y: 3 })
      }
    }
    .width(46).height(42)
    .onClick(() => this.redemptionVisible = true)
  }

  @Builder
  private redemptionPage() {
    Scroll() {
      Column({ space: 24 }) {
        Row() {
          Text('‹').fontSize(32).width(34).onClick(() => this.redemptionVisible = false)
          Column({ space: 0 }) {
            Text('口令兑换').fontSize(30).fontWeight(900).fontStyle(FontStyle.Italic)
            Text('SECRET PASS').fontSize(9).fontWeight(900).letterSpacing(2)
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Stack({ alignContent: Alignment.Center }) {
            Row().width(42).height(29).backgroundColor(CORAL)
              .border({ width: 2, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW).rotate({ angle: 7 })
            Text('兑').fontSize(17).fontWeight(900).rotate({ angle: 7 })
          }.width(52).height(44)
        }.width('100%')
        Row({ space: 12 }) {
          Column({ space: 7 }) {
            Text('说出暗号，节拍开门！').fontSize(26).fontWeight(900).fontStyle(FontStyle.Italic)
              .minFontSize(20).maxFontSize(26).width('100%').maxLines(2)
            Text('有效口令会直接为当前账号送上一张畅游月卡。')
              .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).fontColor('#5D574F').width('100%')
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          ComicCharacter({ avatar: 'mismatch', pose: 'mismatch-ticket' }).width('38%').height(160)
        }.width('100%')
        this.redemptionCard()
        Text('口令区分具体字符，请按活动公布的原文输入。')
          .width('100%').fontSize(10).fontColor('#6B655D').textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({
        left: 18,
        right: 18,
        top: 10 + this.topSafeInset,
        bottom: 28 + this.bottomSafeInset
      })
    }
    .width('100%').height('100%').backgroundColor(PAPER).zIndex(90)
  }

  @Builder
  private limitedPrice(price: string) {
    Row({ space: 7 }) {
      Text(price).fontSize(11).fontWeight(900).fontColor('#6B655D')
        .decoration({ type: TextDecorationType.LineThrough, color: INK })
        .maxLines(1)
      Text('限免').fontSize(11).fontWeight(900).fontColor(PAPER)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(CORAL).border({ width: 1, color: INK }).borderRadius(3)
        .rotate({ angle: -3 })
    }
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private characterAction(item: StoreCharacter) {
    if (this.characterAccessState(item) === 'mystery') {
      Text('随机池成员').width('88%').height(32).fontSize(12).fontWeight(900).textAlign(TextAlign.Center)
        .fontColor(PAPER).backgroundColor(INK).border({ width: 1, color: INK }).borderRadius(16)
    } else if (this.characterAccessState(item) === 'limited') {
      Row() {
        this.limitedPrice(this.productPrice(item.productId))
      }.width('90%').height(34).justifyContent(FlexAlign.Center)
      .backgroundColor('#FFF1D7').border({ width: 1, color: INK }).borderRadius(17)
    } else if (this.characterAccessState(item) === 'pass') {
      Text('可使用').width('88%').height(32).fontSize(12).fontWeight(900).textAlign(TextAlign.Center)
        .backgroundColor(LILAC).border({ width: 1, color: INK }).borderRadius(16)
    } else if (this.characterAccessState(item) === 'owned') {
      Text('已拥有').width('88%').height(32).fontSize(12).fontWeight(900).textAlign(TextAlign.Center)
        .backgroundColor(PAPER).border({ width: 1, color: INK }).borderRadius(16)
    } else {
      Button(this.productPrice(item.productId), { type: ButtonType.Normal })
        .width('88%').height(32).padding(0).fontSize(12).fontWeight(900).fontColor(INK)
        .backgroundColor(CORAL).border({ width: 1, color: INK }).borderRadius(16)
        .onClick(() => this.openCharacterPurchase(item))
    }
  }

  @Builder
  private mysteryCharacterArt(item: StoreCharacter) {
    Stack({ alignContent: Alignment.Center }) {
      Image($rawfile(`comic/mystery/${item.asset}.png`)).width('100%').height('100%').objectFit(ImageFit.Contain)
      Text('?').fontSize(58).fontWeight(900).fontColor(PAPER)
        .textShadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
    }.width('96%').height('96%')
  }

  @Builder
  private passBanner() {
    Stack() {
      Image($rawfile('comic/decor/subscription_ticket.png')).width('100%').height('100%').objectFit(ImageFit.Fill)
      Row() {
        Column({ space: 4 }) {
          Text(this.passActive ? '月卡正在生效' : '畅游月卡')
            .fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic).width('100%').maxLines(1)
          Text(this.passDescription()).fontSize(13).fontWeight(900).width('100%').maxLines(2)
          Button(this.passButtonLabel(), { type: ButtonType.Normal })
            .height(34).padding({ left: 13, right: 13 }).fontSize(12).fontWeight(900)
            .fontColor(INK).backgroundColor(PAPER).border({ width: 1.2, color: INK }).borderRadius(17)
            .enabled(this.passIapPurchaseAllowed && !this.passActive).onClick(() => this.openPassPurchase())
        }.width('62%').padding({ left: 13 }).alignItems(HorizontalAlign.Start)
        Row({ space: -22 }) {
          ComicCharacter({ avatar: 'cloud' }).width(72).height(118)
          ComicCharacter({ avatar: 'mismatch' }).width(84).height(126)
        }.width('38%').justifyContent(FlexAlign.Center)
      }.width('100%').height('100%').padding({ left: 10, right: 4, top: 14, bottom: 12 })
    }.width('100%').height(184)
  }

  @Builder
  private tabBar() {
    Row() {
      ForEach(['角色', '场景', '我的'], (label: string, index: number) => {
        Button(label, { type: ButtonType.Normal }).layoutWeight(1).height(42).padding(0)
          .fontSize(15).fontWeight(900).fontColor(INK)
          .backgroundColor(this.selectedTab === index ? CORAL : PAPER)
          .border({ width: { right: index < 2 ? 1 : 0 }, color: '#C9C0B4' })
          .onClick(() => this.selectedTab = index)
      })
    }.width('100%').border({ width: 1.5, color: INK }).borderRadius(7).clip(true)
  }

  @Builder
  private characterCard(item: StoreCharacter) {
    Column({ space: 0 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Column().width('100%').height('100%').backgroundColor(item.color)
        Text('.....').fontSize(20).letterSpacing(5).fontColor('#332D2960')
          .position({ x: 10, y: 7 }).rotate({ angle: -8 })
        if (item.mystery === true) {
          this.mysteryCharacterArt(item)
        } else {
          ComicCharacter({ avatar: item.asset, pose: item.asset }).width('96%').height('96%')
        }
      }.width('100%').height(150).clip(true)
      Column({ space: 4 }) {
        Text(item.name).fontSize(15).fontWeight(900).maxLines(1)
        Text(item.caption).fontSize(9).fontColor('#645E55').maxLines(1)
        this.characterAction(item)
      }.width('100%').height(84).padding({ top: 5, bottom: 6 })
    }.width('100%').height(234).backgroundColor('#FFFDF7')
    .border({ width: 1.3, color: INK }).borderRadius(7).clip(true)
  }

  @Builder
  private characterGrid(onlyAccessible: boolean) {
    Grid() {
      ForEach(STORE_CHARACTERS, (item: StoreCharacter) => {
        if (!onlyAccessible || this.hasCharacter(item.key)) {
          GridItem() {
            this.characterCard(item)
          }
        }
      }, (item: StoreCharacter) => this.storeOfferRenderKey('character', item.key, item.productId))
    }.columnsTemplate('1fr 1fr').columnsGap(10).rowsGap(10).width('100%')
    .height(Math.ceil(this.visibleCharacterCount(onlyAccessible) / 2) * 244)
  }

  @Builder
  private sunsetPreview() {
    Stack() {
      Image($rawfile('background/sunset_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
      Image($rawfile('background/sunset_sun.png')).width(90).height(90).objectFit(ImageFit.Contain)
        .position({ x: '64%', y: 4 })
      Image($rawfile('background/sunset_clouds.png')).width('150%').height(92).objectFit(ImageFit.Fill)
        .position({ x: -30, y: 5 })
      Image($rawfile('background/ocean.png')).width('100%').height(72).objectFit(ImageFit.Fill)
        .position({ x: 0, y: 72 })
      Image($rawfile('background/midground_dirt.png')).width('100%').height(62).objectFit(ImageFit.Fill)
        .position({ x: 0, y: 116 })
      Text('夕阳海边').fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic)
        .fontColor(PAPER).textShadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
        .position({ x: 14, y: 116 })
    }.width('100%').height(178).clip(true)
  }

  @Builder
  private neonPreview() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image($rawfile('scenes/neon/neon_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
      Image($rawfile('scenes/neon/neon_far_skyline.png')).width('115%').height(104).objectFit(ImageFit.Fill)
        .position({ x: -12, y: 20 })
      Image($rawfile('scenes/neon/neon_street_blocks.png')).width('130%').height(112).objectFit(ImageFit.Fill)
        .position({ x: -36, y: 36 })
      Image($rawfile('scenes/neon/neon_road.png')).width('125%').height(72).objectFit(ImageFit.Fill)
        .position({ x: -20, y: 106 })
      Text('霓虹街口').fontSize(22).fontWeight(900).fontStyle(FontStyle.Italic)
        .fontColor(PAPER).textShadow({ radius: 0, offsetX: 2, offsetY: 2, color: INK })
        .position({ x: 14, y: 116 })
    }.width('100%').height(178).clip(true)
  }

  @Builder
  private scenePreview(item: StoreScene) {
    if (item.key === 'neon_street') {
      this.neonPreview()
    } else {
      this.sunsetPreview()
    }
  }

  @Builder
  private sceneAction(item: StoreScene) {
    if (this.selectedSceneKey === item.key) {
      Button('使用中', { type: ButtonType.Normal }).height(34).padding({ left: 13, right: 13 })
        .fontSize(12).fontWeight(900).fontColor(INK).backgroundColor(PAPER)
        .border({ width: 1, color: INK }).borderRadius(17).enabled(false)
    } else if (this.sceneAccessState(item) === 'limited') {
      Button({ type: ButtonType.Normal }) {
        this.limitedPrice(this.productPrice(item.productId))
      }
      .height(36).padding({ left: 9, right: 9 }).backgroundColor('#FFF1D7')
      .border({ width: 1, color: INK }).borderRadius(18)
      .onClick(() => this.selectScene(item))
    } else if (this.sceneAccessState(item) === 'pass') {
      Button('可使用', { type: ButtonType.Normal }).height(34).padding({ left: 13, right: 13 })
        .fontSize(12).fontWeight(900).fontColor(INK).backgroundColor(LILAC)
        .border({ width: 1, color: INK }).borderRadius(17)
        .onClick(() => this.selectScene(item))
    } else if (this.sceneAccessState(item) === 'owned') {
      Button('已拥有', { type: ButtonType.Normal }).height(34).padding({ left: 13, right: 13 })
        .fontSize(12).fontWeight(900).fontColor(INK).backgroundColor(PAPER)
        .border({ width: 1, color: INK }).borderRadius(17)
        .onClick(() => this.selectScene(item))
    } else {
      Button(this.productPrice(item.productId), { type: ButtonType.Normal })
        .height(34).padding({ left: 13, right: 13 }).fontSize(12).fontWeight(900).fontColor(INK)
        .backgroundColor(CORAL).border({ width: 1, color: INK }).borderRadius(17)
        .onClick(() => this.openScenePurchase(item))
    }
  }

  @Builder
  private sceneCard(item: StoreScene) {
    Column({ space: 0 }) {
      this.scenePreview(item)
      Row() {
        Column({ space: 2 }) {
          Text(item.name).fontSize(16).fontWeight(900)
          Text(item.caption).fontSize(9).fontColor('#645E55').maxLines(2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        this.sceneAction(item)
      }.width('100%').height(62).padding({ left: 12, right: 10 })
    }.width('100%').height(240).backgroundColor('#FFFDF7')
    .border({ width: 1.3, color: INK }).borderRadius(7).clip(true)
  }

  @Builder
  private purchaseDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 12 }) {
        Text(this.pendingType === 'pass' ? 'MORE BEATS!' : 'NEW FRIEND!')
          .fontSize(11).fontWeight(900).fontColor(PAPER).backgroundColor(INK)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 }).rotate({ angle: -3 })
          .shadow(CONTROL_SHADOW)
        Text(this.pendingName).fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic)
        Text(this.pendingType === 'pass' ? '开通后可使用当前及后续上架的所有角色和场景。' :
          '购买后会加入“我的”，可在角色选择页使用。')
          .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).width('100%')
        Text(this.pendingPrice).fontSize(22).fontWeight(900).fontColor(CORAL)
        Row({ space: 9 }) {
          Button('再想想', { type: ButtonType.Normal }).layoutWeight(1).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(PAPER).border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .onClick(() => this.purchaseVisible = false)
          Button('确认购买', { type: ButtonType.Normal }).layoutWeight(1.3).height(42).fontSize(13).fontWeight(900)
            .fontColor(INK).backgroundColor(CORAL).border({ width: 1.5, color: INK }).borderRadius(5).shadow(CONTROL_SHADOW)
            .enabled(!this.purchaseBusy).onClick(() => void this.confirmPurchase())
        }.width('100%')
        Text('最终权益以华为支付结果与 OneBeat 服务端验单结果为准。')
          .fontSize(9).fontColor('#6B655D').width('100%')
      }.width('88%').padding(17).backgroundColor('#FFF1D7')
      .border({ width: 2.5, color: INK }).borderRadius(8)
      .shadow({ radius: 0, offsetX: 7, offsetY: 8, color: INK })
    }.width('100%').height('100%').backgroundColor('#77000000').zIndex(100)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text('‹').fontSize(32).width(32).onClick(() => router.back())
            Text('收藏小铺').fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic)
            Blank()
            this.redemptionEntrance()
          }.width('100%')
          this.passBanner()
          if (this.serviceStatus.length > 0) {
            Text(this.serviceStatus).fontSize(10).fontColor('#6B655D').width('100%')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('#FFF1D7').border({ width: 1, color: '#C9C0B4' }).borderRadius(5)
          }
          this.tabBar()
          if (this.selectedTab === 0) {
            this.characterGrid(false)
          } else if (this.selectedTab === 1) {
            ForEach(STORE_SCENES, (item: StoreScene) => {
              this.sceneCard(item)
            }, (item: StoreScene) => this.storeOfferRenderKey('scene', item.key, item.productId))
            Column({ space: 4 }) {
              Text('MORE WORLDS INCOMING').fontSize(11).fontWeight(900).letterSpacing(1)
              Text('新场景将会在这里持续上架').fontSize(12).fontColor('#655F57')
            }.width('100%').padding(16).backgroundColor(LILAC)
            .border({ width: 1.2, color: INK }).borderRadius(7)
          } else {
            Row() {
              Text('我的角色').fontSize(17).fontWeight(900)
              Blank()
              Text(`${this.ownedCharacterCount()} 个`).fontSize(11).fontColor('#655F57')
            }.width('100%')
            this.characterGrid(true)
            Text('我的场景').fontSize(17).fontWeight(900).width('100%')
            ForEach(STORE_SCENES, (item: StoreScene) => {
              if (this.hasScene(item.key)) {
                this.sceneCard(item)
              }
            }, (item: StoreScene) => this.storeOfferRenderKey('owned-scene', item.key, item.productId))
            Button('恢复购买', { type: ButtonType.Normal }).width('100%').height(48)
              .fontSize(15).fontWeight(900).fontColor(INK).backgroundColor(PAPER)
              .border({ width: 1.5, color: INK }).borderRadius(7).enabled(!this.purchaseBusy)
              .onClick(() => void this.restorePurchases())
          }
          Row() {
            Text('COLLECT MORE WEIRDOS\nFOR A BRIGHTER RHYTHM.')
              .fontSize(9).fontWeight(900).lineHeight(11)
            Blank()
            Image($rawfile('comic/brand/onebeat_wordmark.png')).width(112).height(50).objectFit(ImageFit.Contain)
          }.width('100%')
          Text('隐私声明')
            .fontSize(12)
            .fontColor('#66615A')
            .decoration({ type: TextDecorationType.Underline })
            .width('100%')
            .textAlign(TextAlign.End)
            .onClick(() => {
              router.pushUrl({ url: 'pages/PrivacyPage' });
            })
        }.width('100%').padding({
          left: 16,
          right: 16,
          top: 10 + this.topSafeInset,
          bottom: 24 + this.bottomSafeInset
        })
      }.width('100%').height('100%').backgroundColor(PAPER)
      if (this.redemptionVisible) {
        this.redemptionPage()
      }
      if (this.purchaseVisible) {
        this.purchaseDialog()
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
