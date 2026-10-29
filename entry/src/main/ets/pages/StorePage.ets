import { comicInkSurface, COMIC_CARD_INK_OFFSET, COMIC_CONTROL_INK_OFFSET } from '../components/ComicInkSurface';
import { DrumPaper } from '../components/DrumPaper';
import { ActionButton } from '../components/ActionButton';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { router } from '@kit.ArkUI';
import { isUserCancelled, logUserFailure, showUserNotice, userErrorMessage } from '../common/UserFeedback';
import {
  ComicCharacter,
  CORAL,
  INK,
  LILAC,
  PAPER,
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
import {
  emptyStoreProductPriceQueryResult,
  queryStoreProductPrices,
  storePriceUnavailableMessage,
  StoreProductPrice,
  StoreProductPriceQueryResult
} from '../store/IapCatalogService';
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
import { StoreBootstrap, StorePurchaseSubmission, StoreRedemptionResult } from '../store/StoreModels';

interface StoreCharacter {
  key: string;
  name: string;
  caption: string;
  asset: string;
  photoAsset?: string;
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

class StorePurchaseError extends Error {
  code: number;

  constructor(message: string, code: number) {
    super(message);
    this.code = code;
  }
}

const STORE_EXCLUSIVE_CHARACTERS: StoreCharacter[] = [
  { key: 'cloud', name: '云行者', caption: '轻盈天空拍', asset: 'cloud', color: '#DCE9FA', productId: 'onebeat.character.cloud' },
  { key: 'teapot', name: '茶壶太太', caption: '慢火稳拍', asset: 'teapot', color: '#FFD06A', productId: 'onebeat.character.teapot' },
  { key: 'wave', name: 'Wave', caption: '浪线步态', asset: 'wave', photoAsset: 'comic/store/wave.png', color: '#7EC8FF', productId: 'onebeat.character.wave' },
  { key: 'mismatch', name: '条纹步客', caption: '酷脸推进', asset: 'mismatch', photoAsset: 'comic/store/mismatch.png', color: '#E8DFF6', productId: 'onebeat.character.mismatch' },
  { key: 'scooter', name: '思古特', caption: '双拍十六帧', asset: 'scooter', color: '#FF9E7A', productId: 'onebeat.character.scooter' },
  { key: 'lilroll', name: '轮滑小子', caption: '贴地飞行', asset: 'lilroll', color: '#C7B8EC', productId: 'onebeat.character.lilroll' },
  { key: 'lamp', name: '台灯漫游者', caption: '暖光引路', asset: 'lamp', photoAsset: 'comic/store/lamp.png', color: '#FFB347', productId: 'onebeat.character.lamp' }
];

const STORE_MULTI_CHARACTERS: StoreCharacter[] = [
  { key: 'braids', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'braids', color: '#B9B2C7', productId: '', mystery: true },
  { key: 'boonie', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'boonie', color: '#B7C7BC', productId: '', mystery: true },
  { key: 'curly', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'curly', color: '#B6C7C8', productId: '', mystery: true },
  { key: 'buzz', name: '神秘角色', caption: '随机池成员 · 行进时揭晓', asset: 'buzz', color: '#C7BEBA', productId: '', mystery: true }
];

const EXCLUSIVE_CHARACTER_SECTION_TITLE: string = '独占角色';
const EXCLUSIVE_CHARACTER_SECTION_HINT: string =
  '每个独占角色在队伍里只有一席，先选先得。';
const MULTI_CHARACTER_SECTION_TITLE: string = '随机角色';
const MULTI_CHARACTER_SECTION_HINT: string =
  '随机池成员可在同一队伍中同时出现多份，互不占用。';

const STORE_CHARACTERS: StoreCharacter[] = STORE_EXCLUSIVE_CHARACTERS.concat(STORE_MULTI_CHARACTERS);

const STORE_SCENES: StoreScene[] = [
  { key: 'sunset_coast', name: '夕阳海边', caption: '海水、云层与土路循环行进', productId: '' },
  { key: 'neon_street', name: '霓虹街口', caption: '雨夜楼群与湿润街道多层视差', productId: 'onebeat.scene.neon_street' }
];

const PASS_PRODUCT_ID: string = 'onebeat.pass.monthly';
const IAP_ERROR_ALREADY_OWNED: number = 1001860051;

const PASS_BANNER_MAX_WIDTH: number = 472;
const PASS_BANNER_DEFAULT_WIDTH: number = 372;
// The PNG canvas keeps transparent room around a 2.52:1 ticket. Cover-cropping
// it into this ratio preserves the complete ink edge while removing that room.
const PASS_BANNER_DISPLAY_RATIO: number = 2.42;
const PASS_BANNER_STATUS_X: string = '6.2%';
const PASS_BANNER_STATUS_Y: string = '85.2%';
const PASS_BANNER_STATUS_WIDTH: string = '21%';
const PASS_BANNER_STATUS_HEIGHT: string = '10%';
const PASS_BANNER_ACTION_X: string = '78.4%';
const PASS_BANNER_ACTION_Y: string = '59.2%';
const PASS_BANNER_ACTION_WIDTH: string = '17.4%';
const PASS_BANNER_ACTION_HEIGHT: string = '20.5%';
const DRUM_INTRO_ASSET: string = 'comic/store/pro-drum-intro.png';
const DRUM_INTRO_IMAGE_RATIO: number = 2 / 3;
const DRUM_INTRO_SIDE_INSET: number = 12;
const DRUM_INTRO_CLOSE_TOP: number = 8;
const DRUM_INTRO_CLOSE_SIZE: number = 44;
const DRUM_INTRO_CONTENT_GAP: number = 10;

// The bubble hugs two five-character phrases instead of stretching with the viewport.
const REDEMPTION_SPEECH_WIDTH: number = 168;
const REDEMPTION_SPEECH_BODY_HEIGHT: number = 98;
const REDEMPTION_SPEECH_TAIL_HEIGHT: number = 12;
const REDEMPTION_SPEECH_PADDING_X: number = 19;
const REDEMPTION_HERO_HEIGHT: number = 266;
const REDEMPTION_CHARACTER_WIDTH: number = 160;
const REDEMPTION_CHARACTER_HEIGHT: number = 240;
const REDEMPTION_CHARACTER_TOP: number = 14;
const REDEMPTION_TEXT_WIDTH_RATIO: number = 0.46;
const REDEMPTION_CHARACTER_X_OFFSET: number = 0;

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
  @State passBannerWidth: number = PASS_BANNER_DEFAULT_WIDTH;
  @State redemptionHeroWidth: number = PASS_BANNER_DEFAULT_WIDTH;
  @State limitedFreeCharacters: string[] = [];
  @State limitedFreeScenes: string[] = [];
  @State passCharacters: string[] = [];
  @State passScenes: string[] = [];
  @State redemptionAvailable: boolean = false;
  @State redemptionVisible: boolean = false;
  @State redemptionCode: string = '';
  @State redemptionIdempotencyKey: string = '';
  @State redemptionStatus: string = '';
  @State redemptionSucceeded: boolean = false;
  @State redemptionSyncFailed: boolean = false;
  @State redemptionBusy: boolean = false;
  @State purchaseVisible: boolean = false;
  @State drumIntroVisible: boolean = false;
  @State pendingType: string = '';
  @State pendingKey: string = '';
  @State pendingName: string = '';
  @State pendingPrice: string = '';
  @State pendingProductId: string = '';
  @State productPrices: StoreProductPrice[] = [];
  @State productPriceEpoch: number = 0;
  @State serviceStatus: string = '';
  @State storeActionStatus: string = '';
  @State storeActionRecovery: string = '';
  @State storeActionType: string = '';
  @State purchaseBusy: boolean = false;
  private storeLifetimeEpoch: number = 0;
  private storePageActive: boolean = true;

  aboutToAppear(): void {
    this.storePageActive = true;
    this.storeLifetimeEpoch++;
    initializeEntitlementCache();
    this.loadPurchases();
  }

  aboutToDisappear(): void {
    this.storePageActive = false;
    this.storeLifetimeEpoch++;
  }

  private isCurrentStorePage(epoch: number): boolean {
    return this.storePageActive && this.storeLifetimeEpoch === epoch;
  }

  onPageShow(): void {
    // Runs on first open and when returning from system Settings after Huawei ID sign-in.
    void this.refreshStoreData();
  }

  onBackPress(): boolean {
    if (this.purchaseVisible && this.drumIntroVisible) {
      this.closeDrumIntro();
      return true;
    }
    if (this.purchaseVisible) {
      if (!this.purchaseBusy) {
        this.purchaseVisible = false;
      }
      return true;
    }
    if (this.redemptionVisible) {
      if (!this.redemptionBusy || this.redemptionSucceeded) {
        this.redemptionVisible = false;
      }
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

  private async refreshStoreData(): Promise<void> {
    const lifetime = this.storeLifetimeEpoch;
    const priceTask: Promise<StoreProductPriceQueryResult> = isStoreApiConfigured() ?
      queryStoreProductPrices(this.hostContext()).catch((err: Object) => {
        logUserFailure('store.price', err);
        return emptyStoreProductPriceQueryResult('unknown');
      }) :
      Promise.resolve(emptyStoreProductPriceQueryResult('none'));

    if (!isStoreApiConfigured()) {
      console.info('[StoreIap] StorePage skipped IAP query: store API base URL not configured');
    }

    if (!isStoreApiConfigured()) {
      this.serviceStatus = '商店暂时不可用，请稍后重试';
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
          if (!this.isCurrentStorePage(lifetime)) {
            return;
          }
          applyStoreBootstrap(bootstrap);
          this.loadPurchases();
          this.serviceStatus = '';
        }
      } catch (error) {
        if (!this.isCurrentStorePage(lifetime)) {
          return;
        }
        logUserFailure('store.refresh', error);
        this.serviceStatus = '暂时无法连接商店，已保留现有权益';
      }
    }

    try {
      const priceResult = await priceTask;
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      this.productPrices = priceResult.prices;
      this.productPriceEpoch++;
      if (priceResult.prices.length === 0 && this.serviceStatus.length === 0 && isStoreApiConfigured()) {
        if (priceResult.unavailableReason !== 'none') {
          this.serviceStatus = storePriceUnavailableMessage(priceResult.unavailableReason);
          console.warn(`[StoreIap] StorePage empty-price banner reason=${priceResult.unavailableReason}`);
        }
      } else if (priceResult.prices.length > 0) {
        console.info(`[StoreIap] StorePage loaded ${priceResult.prices.length} product price(s)`);
      }
    } catch (err) {
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      logUserFailure('store.price', err);
      if (this.serviceStatus.length === 0) {
        this.serviceStatus = storePriceUnavailableMessage('unknown');
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

  /** “我的” tab lists owned exclusive characters only, not random-pool members. */
  private ownedExclusiveCharacterCount(): number {
    return this.visibleCharacterCountInList(STORE_EXCLUSIVE_CHARACTERS, true);
  }

  private ownedSceneCount(): number {
    let count = 0;
    for (let i = 0; i < STORE_SCENES.length; i++) {
      if (this.hasScene(STORE_SCENES[i].key)) {
        count++;
      }
    }
    return count;
  }

  private visibleCharacterCountInList(items: StoreCharacter[], onlyAccessible: boolean): number {
    if (!onlyAccessible) {
      return items.length;
    }
    let count = 0;
    for (let i = 0; i < items.length; i++) {
      if (this.hasCharacter(items[i].key)) {
        count++;
      }
    }
    return count;
  }

  private characterGridHeight(itemCount: number): number {
    if (itemCount <= 0) {
      return 0;
    }
    return Math.ceil(itemCount / 2) * (234 + 10 + COMIC_CARD_INK_OFFSET);
  }

  private openCharacterPurchase(item: StoreCharacter): void {
    if (this.purchaseBusy || this.redemptionBusy || this.hasCharacter(item.key)) {
      return;
    }
    this.pendingType = 'character';
    this.pendingKey = item.key;
    this.pendingName = item.name;
    this.pendingPrice = this.productPrice(item.productId);
    this.pendingProductId = item.productId;
    this.resetPurchaseFeedback();
    this.purchaseVisible = true;
  }

  private openScenePurchase(item: StoreScene): void {
    if (this.purchaseBusy || this.redemptionBusy) {
      return;
    }
    this.pendingType = 'scene';
    this.pendingKey = item.key;
    this.pendingName = item.name;
    this.pendingPrice = this.productPrice(item.productId);
    this.pendingProductId = item.productId;
    this.resetPurchaseFeedback();
    this.purchaseVisible = true;
  }

  private openPassPurchase(): void {
    if (this.purchaseBusy || this.redemptionBusy) {
      return;
    }
    this.pendingType = 'pass';
    this.pendingKey = 'pass.all';
    this.pendingName = '畅游月卡';
    this.pendingPrice = this.productPrice(PASS_PRODUCT_ID);
    this.pendingProductId = PASS_PRODUCT_ID;
    this.resetPurchaseFeedback();
    this.purchaseVisible = true;
  }

  private openDrumIntro(): void {
    if (!this.purchaseVisible || this.pendingType !== 'pass' ||
      this.storeActionType === 'restore' || this.purchaseBusy) {
      return;
    }
    this.drumIntroVisible = true;
  }

  private closeDrumIntro(): void {
    this.drumIntroVisible = false;
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

  private async syncOwnedPurchase(accessToken: string, productId: string, lifetime: number): Promise<boolean> {
    const purchases = this.restorablePurchases(await queryRestorablePurchases(this.hostContext()));
    if (!this.isCurrentStorePage(lifetime)) {
      return false;
    }
    const scoped = this.purchasesForProduct(purchases, productId);
    if (scoped.length === 0) {
      return false;
    }
    try {
      const verified = await verifyStorePurchase(accessToken, scoped[0]);
      applyStoreBootstrap(verified);
      if (this.isCurrentStorePage(lifetime)) {
        this.loadPurchases();
      }
      return true;
    } catch (_verifyError) {
      const bootstrap = await restoreStorePurchases(accessToken, [scoped[0]]);
      applyStoreBootstrap(bootstrap);
      if (this.isCurrentStorePage(lifetime)) {
        this.loadPurchases();
      }
      return true;
    }
  }

  private async confirmPurchase(): Promise<void> {
    if (this.purchaseBusy || this.redemptionBusy || this.pendingProductId.length === 0 ||
      (this.pendingType === 'pass' && this.passPurchaseRestriction().length > 0)) {
      return;
    }
    this.purchaseBusy = true;
    AppStorage.setOrCreate('storePurchasePending', true);
    const lifetime = this.storeLifetimeEpoch;
    const productId = this.pendingProductId;
    const isPass = this.pendingType === 'pass';
    this.storeActionType = 'purchase';
    this.storeActionStatus = '正在完成购买…';
    this.storeActionRecovery = '';
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      // Recheck the server immediately before opening Huawei checkout. Cached UI
      // state may predate a code redemption on another device.
      const bootstrap = await fetchStoreBootstrap(accessToken);
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      if (bootstrap === null || bootstrap.developerPayload === undefined || bootstrap.developerPayload.length === 0) {
        throw new Error('服务端未返回购买绑定信息');
      }
      applyStoreBootstrap(bootstrap);
      this.loadPurchases();
      if (isPass && (!bootstrap.pass.iapPurchaseAllowed || bootstrap.pass.active)) {
        this.storeActionStatus = '';
        this.purchaseVisible = true;
        return;
      }
      try {
        const purchase = await createStorePurchase(
          this.hostContext(),
          productId,
          productTypeForStoreItem(isPass),
          bootstrap.developerPayload
        );
        const verified = await verifyStorePurchase(accessToken, purchase);
        applyStoreBootstrap(verified);
        // Paid orders still reach verification if the page leaves during native
        // checkout; only this page's state and completion notice are discarded.
        if (!this.isCurrentStorePage(lifetime)) {
          return;
        }
        this.loadPurchases();
        this.serviceStatus = '';
        this.storeActionStatus = '';
        this.purchaseVisible = false;
        showUserNotice('购买成功，权益已到账', 'store.purchase');
      } catch (purchaseError) {
        if (!this.isCurrentStorePage(lifetime)) {
          return;
        }
        const iapError = purchaseError as BusinessError;
        if (iapError.code !== IAP_ERROR_ALREADY_OWNED) {
          // ArkTS only throws Error classes; retain the SDK code while keeping
          // untrusted native/server prose out of the page's error contract.
          throw new StorePurchaseError(userErrorMessage(purchaseError, '购买未完成，请重试；已支付可恢复购买'),
            iapError.code ?? 0);
        }
        this.storeActionStatus = '正在同步已购权益…';
        const synced = await this.syncOwnedPurchase(accessToken, productId, lifetime);
        if (!this.isCurrentStorePage(lifetime)) {
          return;
        }
        if (!synced) {
          throw new Error('华为账号已拥有该商品，请稍后点击「恢复购买」同步权益');
        }
        this.serviceStatus = '';
        this.storeActionStatus = '';
        this.purchaseVisible = false;
        showUserNotice('已同步华为账号中的购买记录', 'store.purchase');
      }
    } catch (e) {
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      if (isUserCancelled(e)) {
        this.storeActionStatus = '';
        this.purchaseVisible = false;
        return;
      }
      logUserFailure('store.purchase', e);
      this.storeActionStatus = userErrorMessage(e, '购买未完成，请重试；已支付可恢复购买');
      this.storeActionRecovery = 'purchase';
    } finally {
      AppStorage.setOrCreate('storePurchasePending', false);
      if (this.isCurrentStorePage(lifetime)) {
        this.purchaseBusy = false;
      }
    }
  }

  private async synchronizePurchasesBeforeRedemption(accessToken: string, lifetime: number): Promise<void> {
    // Huawei cannot query all subscriptions by OneBeat user ID. Restore the
    // purchases visible on this device before asking the server to grant a pass.
    // queryPurchases may throw BusinessError (not instanceof Error); that must not
    // block redemption — treat as "no local receipts" and still refresh bootstrap.
    let purchases: StorePurchaseSubmission[] = [];
    try {
      purchases = this.restorablePurchases(await queryRestorablePurchases(this.hostContext()));
    } catch (_queryError) {
      purchases = [];
    }
    if (!this.isCurrentStorePage(lifetime)) {
      return;
    }
    try {
      const bootstrap = await restoreStorePurchases(accessToken, purchases);
      applyStoreBootstrap(bootstrap);
      if (this.isCurrentStorePage(lifetime)) {
        this.loadPurchases();
      }
    } catch (restoreError) {
      if (purchases.length === 0) {
        if (restoreError instanceof Error) {
          throw restoreError;
        }
        throw new Error(String(restoreError));
      }
      // Stale or unverifiable local JWS should not prevent a code redemption attempt.
      const bootstrap = await restoreStorePurchases(accessToken, []);
      applyStoreBootstrap(bootstrap);
      if (this.isCurrentStorePage(lifetime)) {
        this.loadPurchases();
      }
    }
  }

  private startAnotherRedemption(): void {
    if (this.redemptionBusy || this.purchaseBusy) {
      return;
    }
    this.redemptionSucceeded = false;
    this.redemptionSyncFailed = false;
    this.redemptionCode = '';
    this.redemptionIdempotencyKey = '';
    this.redemptionStatus = '';
  }

  private updateRedemptionCode(value: string): void {
    // Removing the input after success can deliver a final change callback.
    // Only an actual editable draft change may clear its operation and feedback.
    if (this.redemptionBusy || this.redemptionSucceeded || value === this.redemptionCode) {
      return;
    }
    this.redemptionCode = value;
    this.redemptionIdempotencyKey = '';
    this.redemptionStatus = '';
  }

  private showRedemptionSuccess(result: StoreRedemptionResult): void {
    this.redemptionSucceeded = true;
    this.redemptionSyncFailed = false;
    this.redemptionCode = '';
    this.redemptionIdempotencyKey = '';
    const expires = this.passDate(result.pass.expiresAt ?? result.grantEndsAt);
    this.redemptionStatus = expires.length > 0 ? `已兑换 · 有效至 ${expires}` : '已兑换，畅游月卡已到账';
    // The committed response owns the pass result. Item rights still require a
    // complete bootstrap; inventing one here would erase existing purchases.
    this.passActive = result.pass.active;
    this.passStatus = result.pass.status ?? '';
    this.passExpiresAt = result.pass.expiresAt ?? result.grantEndsAt;
    this.passSource = result.pass.source ?? '';
    this.passAutoRenewing = result.pass.autoRenewing;
    this.passIapPurchaseAllowed = result.pass.iapPurchaseAllowed;
  }

  private async refreshRedemptionEntitlements(accessToken: string, lifetime: number): Promise<void> {
    try {
      const bootstrap = await fetchStoreBootstrap(accessToken);
      if (bootstrap === null) {
        throw new Error('兑换后权益快照暂不可用');
      }
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      applyStoreBootstrap(bootstrap);
      this.loadPurchases();
      this.serviceStatus = '';
      this.redemptionSyncFailed = false;
    } catch (error) {
      if (this.isCurrentStorePage(lifetime)) {
        logUserFailure('store.redemption.refresh', error);
        // A failed follow-up GET cannot turn a committed grant into a failed
        // redemption or encourage another POST for the same benefit.
        this.redemptionSyncFailed = true;
      }
    }
  }

  private async retryRedemptionEntitlements(): Promise<void> {
    if (!this.redemptionSucceeded || this.redemptionBusy || this.purchaseBusy) {
      return;
    }
    this.redemptionBusy = true;
    const lifetime = this.storeLifetimeEpoch;
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      if (this.isCurrentStorePage(lifetime)) {
        await this.refreshRedemptionEntitlements(accessToken, lifetime);
      }
    } catch (error) {
      if (this.isCurrentStorePage(lifetime)) {
        this.redemptionSyncFailed = true;
        if (!isUserCancelled(error)) {
          logUserFailure('store.redemption.refresh', error);
        }
      }
    } finally {
      if (this.isCurrentStorePage(lifetime)) {
        this.redemptionBusy = false;
      }
    }
  }

  private async submitRedemption(): Promise<void> {
    if (this.redemptionSucceeded || this.redemptionBusy || this.purchaseBusy || this.redemptionCode.trim().length === 0) {
      return;
    }
    this.redemptionBusy = true;
    const lifetime = this.storeLifetimeEpoch;
    this.redemptionStatus = '正在核对账号权益…';
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      await this.synchronizePurchasesBeforeRedemption(accessToken, lifetime);
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
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
        code: this.redemptionCode.trim()
      });
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      this.showRedemptionSuccess(result);
      await this.refreshRedemptionEntitlements(accessToken, lifetime);
    } catch (e) {
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      if (isUserCancelled(e)) {
        this.redemptionStatus = '';
        return;
      }
      logUserFailure('store.redemption', e);
      this.redemptionStatus = userErrorMessage(e, '兑换未完成，请检查账号和网络后重试');
    } finally {
      if (this.isCurrentStorePage(lifetime)) {
        this.redemptionBusy = false;
      }
    }
  }

  private async restorePurchases(): Promise<void> {
    if (this.purchaseBusy || this.redemptionBusy) {
      return;
    }
    this.purchaseBusy = true;
    const lifetime = this.storeLifetimeEpoch;
    this.storeActionType = 'restore';
    this.storeActionStatus = '正在恢复购买…';
    this.storeActionRecovery = '';
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      const purchases = this.restorablePurchases(await queryRestorablePurchases(this.hostContext()));
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      let bootstrap: StoreBootstrap | null = null;
      let failedCount: number = 0;
      if (purchases.length > 0) {
        try {
          bootstrap = await restoreStorePurchases(accessToken, purchases);
        } catch (_batchRestoreError) {
          let syncedCount: number = 0;
          for (let i = 0; i < purchases.length; i++) {
            try {
              await verifyStorePurchase(accessToken, purchases[i]);
              syncedCount++;
            } catch (_verifyError) {
              try {
                await restoreStorePurchases(accessToken, [purchases[i]]);
                syncedCount++;
              } catch (restoreError) {
                failedCount++;
                logUserFailure('store.restore.item', restoreError);
              }
            }
          }
          if (syncedCount === 0) {
            throw new Error('恢复失败，请检查账号和网络后重试');
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
        if (!this.isCurrentStorePage(lifetime)) {
          return;
        }
        this.loadPurchases();
        this.serviceStatus = '';
      }
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      this.storeActionStatus = failedCount > 0 ? '部分权益已同步，其余购买记录请稍后重试' : '权益已同步';
      this.storeActionRecovery = failedCount > 0 ? 'restore' : '';
    } catch (e) {
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      if (isUserCancelled(e)) {
        this.storeActionStatus = '';
        return;
      }
      logUserFailure('store.restore', e);
      this.storeActionStatus = userErrorMessage(e, '恢复失败，请检查账号和网络后重试');
      this.storeActionRecovery = 'restore';
    } finally {
      if (this.isCurrentStorePage(lifetime)) {
        this.purchaseBusy = false;
      }
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
      return expires.length > 0 ? `可使用至 ${expires}` : '付费角色与场景';
    }
    if (expires.length > 0) {
      return `已于 ${expires} 到期`;
    }
    return '付费角色、场景与 PRO 定制鼓机';
  }

  private passButtonLabel(): string {
    if (this.passActive) {
      return this.passSource === 'PASS_REDEMPTION' ? '赠送生效中' : '已开通';
    }
    return '查看方案  ›';
  }

  private passPurchaseRestriction(): string {
    if (this.passActive) {
      return this.passSource === 'PASS_REDEMPTION' ?
        '赠送月卡生效期间不能购买自动续费月卡' : '畅游月卡已生效';
    }
    return this.passIapPurchaseAllowed ? '' : '当前暂不能购买自动续费月卡，请稍后重试';
  }

  private resetPurchaseFeedback(): void {
    this.drumIntroVisible = false;
    this.storeActionType = 'purchase';
    this.storeActionStatus = '';
    this.storeActionRecovery = '';
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
          .background(comicInkSurface(this.redemptionAvailable ? CORAL : INK, 0, COMIC_CONTROL_INK_OFFSET)).clip(false)
      }.width('100%')
      if (this.redemptionAvailable) {
        Column({ space: 9 }) {
          TextInput({ placeholder: '输入活动口令', text: this.redemptionCode })
            .width('100%').height(46).fontSize(15).fontColor(INK)
            .placeholderColor('#8D857A').backgroundColor(PAPER)
            .border({ width: 1.5, color: INK }).borderRadius(5)
            .background(comicInkSurface(PAPER, 5, COMIC_CONTROL_INK_OFFSET)).clip(false)
            .padding({ left: 12, right: 12 }).maxLength(64)
            .enabled(!this.redemptionBusy)
            .onChange((value: string) => this.updateRedemptionCode(value))
          if (this.redemptionStatus.length > 0) {
            Text(this.redemptionStatus).fontSize(11).fontWeight(FontWeight.Bold)
              .fontColor('#645E55').lineHeight(17).width('100%')
          }
          ActionButton({
            label: this.redemptionBusy ? '兑换中…' : '立即兑换',
            active: !this.redemptionBusy && this.redemptionCode.trim().length > 0,
            controlHeight: 46, labelSize: 15, labelWeight: 900, fill: CORAL,
            lineWidth: 1.5, cornerRadius: 5,
            hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
            action: () => { void this.submitRedemption(); }
          })
        }.width('100%')
      } else {
        Text('当前没有开放中的口令活动')
          .width('100%').fontSize(14).fontWeight(900).textAlign(TextAlign.Center)
          .padding({ top: 20, bottom: 20 }).backgroundColor(PAPER)
          .border({ width: 1.2, color: INK }).borderRadius(5)
          .background(comicInkSurface(PAPER, 5, COMIC_CONTROL_INK_OFFSET)).clip(false)
      }
      if (!this.redemptionAvailable && this.redemptionStatus.length > 0) {
        Text(this.redemptionStatus).fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor('#645E55').lineHeight(17).width('100%')
      }
    }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 18 })
  }

  @Builder
  private redemptionCardFrame() {
    DrumPaper({
      fill: LILAC,
      paperWidth: '100%',
      cornerRadius: 8,
      paperLineWidth: 2,
      clipContent: true,
      offsetX: COMIC_CARD_INK_OFFSET,
      offsetY: COMIC_CARD_INK_OFFSET
    }) {
      this.redemptionCard()
    }
  }

  @Builder
  private redemptionResultCard() {
    Column({ space: 12 }) {
      Text('✓').fontSize(36).fontWeight(900).fontColor('#08827B')
      Text('兑换成功').fontSize(28).fontWeight(900).fontStyle(FontStyle.Italic).fontColor(INK)
      Text('赠送畅游月卡已领取').fontSize(16).fontWeight(900).fontColor(INK)
      Text(this.redemptionStatus).fontSize(14).fontWeight(800).lineHeight(22)
        .fontColor('#08827B').textAlign(TextAlign.Center).width('100%')
      Text('到期后结束，不自动续费').fontSize(12).fontColor('#645E55')
      if (this.redemptionBusy) {
        Text('正在更新小铺权益…').fontSize(12).fontColor('#645E55')
      } else if (this.redemptionSyncFailed) {
        Text('月卡已领取，权益列表暂未更新，可重试更新。').fontSize(12).lineHeight(19)
          .fontColor('#645E55').textAlign(TextAlign.Center).width('100%')
        ActionButton({
          label: '重试更新权益', active: !this.purchaseBusy,
          controlHeight: 42, labelSize: 14, labelWeight: 900, fill: LILAC,
          contentPadding: { left: 16, right: 16 },
          lineWidth: 1.5, cornerRadius: 6,
          hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
          action: () => { void this.retryRedemptionEntitlements(); }
        })
      }
      Button('返回小铺', { type: ButtonType.Normal }).width('100%').height(46)
        .fontSize(16).fontWeight(900).fontColor(INK).backgroundColor(CORAL)
        .border({ width: 1.5, color: INK }).borderRadius(6)
        .background(comicInkSurface(CORAL, 6, COMIC_CONTROL_INK_OFFSET)).clip(false)
        .onClick(() => { this.redemptionVisible = false; })
      if (this.redemptionAvailable) {
        ActionButton({
          label: '兑换其他口令', active: !this.redemptionBusy && !this.purchaseBusy,
          controlHeight: 36, labelSize: 13, labelWeight: 800, fill: '#00000000',
          contentPadding: { left: 16, right: 16 },
          cornerRadius: 18,
          action: () => this.startAnotherRedemption()
        })
      }
    }.width('100%').padding(20)
  }

  @Builder
  private redemptionResultCardFrame() {
    DrumPaper({
      fill: '#FFF9EE',
      paperWidth: '100%',
      cornerRadius: 8,
      paperLineWidth: 2,
      clipContent: true,
      offsetX: COMIC_CARD_INK_OFFSET,
      offsetY: COMIC_CARD_INK_OFFSET
    }) {
      this.redemptionResultCard()
    }
  }

  @Builder
  private redemptionEntrance() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(33).height(24).backgroundColor(LILAC)
        .border({ width: 2, color: INK }).borderRadius(4)
        .rotate({ angle: -7 })
        .background(comicInkSurface(LILAC, 4, COMIC_CONTROL_INK_OFFSET)).clip(false)
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
  private redemptionSpeechBubble() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The SVG contains the face and tail as one silhouette, including its solid
      // ink backing. Text stays native; no separate tail shadow can get clipped.
      Image($rawfile('comic/decor/redemption_speech_bubble.svg'))
        .width(REDEMPTION_SPEECH_WIDTH + 8)
        .height(REDEMPTION_SPEECH_BODY_HEIGHT + REDEMPTION_SPEECH_TAIL_HEIGHT + 8)
        .objectFit(ImageFit.Fill).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      Column({ space: 0 }) {
        Text('说出暗号，').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic)
          .fontColor(INK).lineHeight(35).height(35).width('100%').maxLines(1)
        Text('节拍开门！').fontSize(25).fontWeight(900).fontStyle(FontStyle.Italic)
          .fontColor(INK).lineHeight(35).height(35).width('100%').maxLines(1)
      }.width(REDEMPTION_SPEECH_WIDTH).height(REDEMPTION_SPEECH_BODY_HEIGHT)
        .padding({ left: REDEMPTION_SPEECH_PADDING_X, right: REDEMPTION_SPEECH_PADDING_X })
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Start)
        .position({ x: 1, y: 1 })
    }.width(REDEMPTION_SPEECH_WIDTH + 8)
      .height(REDEMPTION_SPEECH_BODY_HEIGHT + REDEMPTION_SPEECH_TAIL_HEIGHT + 8)
      .rotate({ angle: -2 }).clip(false).position({ x: 0, y: 8 })
  }

  private redemptionArtworkX(): number {
    // Reserve the complete speech bubble as well as the proportional copy column.
    // Keep the character at its original size when a narrow viewport overhangs it.
    const textWidth = Math.max(REDEMPTION_SPEECH_WIDTH + 8,
      this.redemptionHeroWidth * REDEMPTION_TEXT_WIDTH_RATIO);
    return textWidth + (this.redemptionHeroWidth - textWidth - REDEMPTION_CHARACTER_WIDTH) / 2 +
      REDEMPTION_CHARACTER_X_OFFSET;
  }

  @Builder
  private redemptionHero() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Mirror the existing pose so its tickets continue facing the speech bubble.
      ComicCharacter({ avatar: 'mismatch', pose: 'mismatch-ticket' })
        .width(REDEMPTION_CHARACTER_WIDTH).height(REDEMPTION_CHARACTER_HEIGHT)
        .scale({ x: -1, y: 1 })
        .position({ x: this.redemptionArtworkX(), y: REDEMPTION_CHARACTER_TOP })
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
      this.redemptionSpeechBubble()
      Text('有效口令会直接为当前账号送上一张畅游月卡。')
        .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).fontColor('#5D574F')
        .width(`${REDEMPTION_TEXT_WIDTH_RATIO * 100}%`).maxLines(4).position({ x: 0, y: 184 })
    }.width('100%').height(REDEMPTION_HERO_HEIGHT).clip(false)
      .onAreaChange((_old: Area, area: Area) => {
        const width = Number(area.width);
        if (width > 0 && Math.abs(width - this.redemptionHeroWidth) > 0.1) {
          this.redemptionHeroWidth = width;
        }
      })
  }

  @Builder
  private redemptionPage() {
    Scroll() {
      Column({ space: 24 }) {
        Row() {
          Text('‹').fontSize(32).width(34).onClick(() => {
            if (!this.redemptionBusy || this.redemptionSucceeded) {
              this.redemptionVisible = false;
            }
          })
          Column({ space: 0 }) {
            Text('口令兑换').fontSize(30).fontWeight(900).fontStyle(FontStyle.Italic)
            Text('SECRET PASS').fontSize(9).fontWeight(900).letterSpacing(2)
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Stack({ alignContent: Alignment.Center }) {
            Row().width(42).height(29).backgroundColor(CORAL)
              .border({ width: 2, color: INK }).borderRadius(5)
              .background(comicInkSurface(CORAL, 5, COMIC_CONTROL_INK_OFFSET)).clip(false).rotate({ angle: 7 })
            Text('兑').fontSize(17).fontWeight(900).rotate({ angle: 7 })
          }.width(52).height(44)
        }.width('100%')
        if (this.redemptionSucceeded) {
          this.redemptionResultCardFrame()
        } else {
          this.redemptionHero()
          this.redemptionCardFrame()
          Text('口令区分具体字符，请按活动公布的原文输入。')
            .width('100%').fontSize(10).fontColor('#6B655D').textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .padding({
        left: 18,
        right: 18 + COMIC_CARD_INK_OFFSET,
        top: 10 + this.topSafeInset,
        bottom: 28 + this.bottomSafeInset + COMIC_CARD_INK_OFFSET
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
        .background(comicInkSurface(CORAL, 16, COMIC_CONTROL_INK_OFFSET)).clip(false)
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

  private passTicketStatusLabel(): string {
    const expires = this.passDate(this.passExpiresAt);
    const shortExpires = expires.length >= 10 ? expires.substring(5) : '';
    if (this.passStatus === 'CANCELED_ACTIVE' && this.passActive) {
      return shortExpires.length > 0 ? `有效至 ${shortExpires}` : '本期仍有效';
    }
    if (this.passActive && this.passAutoRenewing) {
      return shortExpires.length > 0 ? `续费至 ${shortExpires}` : '自动续费中';
    }
    if (this.passActive && this.passSource === 'PASS_REDEMPTION') {
      return shortExpires.length > 0 ? `赠送至 ${shortExpires}` : '赠送月卡';
    }
    if (this.passActive) {
      return shortExpires.length > 0 ? `有效至 ${shortExpires}` : '已开通';
    }
    return '全权益通行';
  }

  private passBannerScale(): number {
    return this.passBannerWidth / PASS_BANNER_DEFAULT_WIDTH;
  }

  @Builder
  private passBanner() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The approved illustration is one composition. Only the short status and
      // action label stay live because entitlement state changes after purchase.
      Image($rawfile('comic/decor/monthly_pass_ticket_v2.png'))
        .width('100%').height('100%').objectFit(ImageFit.Cover).zIndex(0)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')

      Text(this.passTicketStatusLabel())
        .width(PASS_BANNER_STATUS_WIDTH).height(PASS_BANNER_STATUS_HEIGHT)
        .fontSize(7.2 * this.passBannerScale()).fontWeight(900).fontColor(INK)
        .maxLines(1).textAlign(TextAlign.Center)
        .position({ x: PASS_BANNER_STATUS_X, y: PASS_BANNER_STATUS_Y })
        .hitTestBehavior(HitTestMode.None)

      Button(this.passButtonLabel(), { type: ButtonType.Normal })
        .width(PASS_BANNER_ACTION_WIDTH).height(PASS_BANNER_ACTION_HEIGHT)
        .padding(0).fontSize(10.5 * this.passBannerScale()).fontWeight(900).fontColor(PAPER)
        .backgroundColor('#00000000').borderRadius(18)
        .position({ x: PASS_BANNER_ACTION_X, y: PASS_BANNER_ACTION_Y })
        .onClick(() => this.openPassPurchase())
    }
    .width('102%')
    .constraintSize({ maxWidth: PASS_BANNER_MAX_WIDTH })
    .height(this.passBannerWidth / PASS_BANNER_DISPLAY_RATIO)
    .clip(true)
    .accessibilityGroup(true)
    .accessibilityText(`畅游月卡，${this.passDescription()}，${this.passButtonLabel()}`)
    .onAreaChange((_oldArea, area) => {
      const width = Number(area.width);
      if (Number.isFinite(width) && width > 0 && Math.abs(width - this.passBannerWidth) >= 0.5) {
        this.passBannerWidth = width;
      }
    })
  }

  @Builder
  private restorePurchasesAction() {
    ActionButton({
      label: '恢复购买', active: !this.purchaseBusy && !this.redemptionBusy,
      controlHeight: 48, labelSize: 15, labelWeight: 900, fill: PAPER,
      lineWidth: 1.5, cornerRadius: 7,
      hardShadow: { offsetX: COMIC_CARD_INK_OFFSET, offsetY: COMIC_CARD_INK_OFFSET, color: INK },
      action: () => { void this.restorePurchases(); }
    })
  }

  @Builder
  private tabBar() {
    DrumPaper({
      fill: PAPER,
      paperWidth: '100%',
      cornerRadius: 7,
      paperLineWidth: 1.5,
      clipContent: true,
      offsetX: COMIC_CARD_INK_OFFSET,
      offsetY: COMIC_CARD_INK_OFFSET
    }) {
      Row() {
        ForEach(['角色', '场景', '我的'], (label: string, index: number) => {
          Button(label, { type: ButtonType.Normal }).layoutWeight(1).height(42).padding(0)
            .fontSize(15).fontWeight(900).fontColor(INK)
            .backgroundColor(this.selectedTab === index ? CORAL : PAPER)
            .border({ width: { right: index < 2 ? 1 : 0 }, color: '#C9C0B4' })
            .onClick(() => this.selectedTab = index)
        })
      }.width('100%').clip(true)
    }
  }

  @Builder
  private characterCard(item: StoreCharacter) {
    DrumPaper({
      fill: '#FFFDF7',
      paperWidth: '100%',
      cornerRadius: 7,
      paperLineWidth: 1.3,
      clipContent: true,
      offsetX: COMIC_CARD_INK_OFFSET,
      offsetY: COMIC_CARD_INK_OFFSET
    }) {
      Column({ space: 0 }) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column().width('100%').height('100%').backgroundColor(item.color)
          Text('.....').fontSize(20).letterSpacing(5).fontColor('#332D2960')
            .position({ x: 10, y: 7 }).rotate({ angle: -8 })
          if (item.mystery === true) {
            this.mysteryCharacterArt(item)
          } else if (item.photoAsset !== undefined) {
            Image($rawfile(item.photoAsset)).width('96%').height('96%').objectFit(ImageFit.Contain)
          } else {
            ComicCharacter({ avatar: item.asset, pose: item.asset }).width('96%').height('96%')
          }
        }.width('100%').height(150).clip(true)
        Column({ space: 4 }) {
          Text(item.name).fontSize(15).fontWeight(900).maxLines(1)
          Text(item.caption).fontSize(9).fontColor('#645E55').maxLines(1)
          this.characterAction(item)
        }.width('100%').height(84).padding({ top: 5, bottom: 6 })
      }.width('100%').height(234)
    }
  }

  @Builder
  private characterRoleSectionHeader(title: string, hint: string) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Divider().color(INK).strokeWidth(1).layoutWeight(1)
        Text(title).fontSize(11).fontWeight(900).fontColor('#655F57')
        Divider().color(INK).strokeWidth(1).layoutWeight(1)
      }.width('100%')
      Text(hint).fontSize(10).fontWeight(FontWeight.Medium).fontColor('#6B655D')
        .lineHeight(15).width('100%').textAlign(TextAlign.Start)
    }.width('100%').margin({ top: 4, bottom: 10 })
  }

  @Builder
  private characterGridForList(items: StoreCharacter[], onlyAccessible: boolean) {
    Grid() {
      ForEach(items, (item: StoreCharacter) => {
        if (!onlyAccessible || this.hasCharacter(item.key)) {
          GridItem() {
            this.characterCard(item)
          }.clip(false)
        }
      }, (item: StoreCharacter) => this.storeOfferRenderKey('character', item.key, item.productId))
    }.columnsTemplate('1fr 1fr').columnsGap(10 + COMIC_CARD_INK_OFFSET).rowsGap(10 + COMIC_CARD_INK_OFFSET).width('100%')
    .height(this.characterGridHeight(this.visibleCharacterCountInList(items, onlyAccessible)))
    .clip(false)
  }

  @Builder
  private characterCatalog(onlyAccessible: boolean) {
    Column({ space: 0 }) {
      if (onlyAccessible) {
        // “我的”只展示已拥有的独占角色，无需分区标题或随机池卡片。
        this.characterGridForList(STORE_EXCLUSIVE_CHARACTERS, true)
      } else {
        if (this.visibleCharacterCountInList(STORE_EXCLUSIVE_CHARACTERS, false) > 0) {
          this.characterRoleSectionHeader(EXCLUSIVE_CHARACTER_SECTION_TITLE, EXCLUSIVE_CHARACTER_SECTION_HINT)
          this.characterGridForList(STORE_EXCLUSIVE_CHARACTERS, false)
        }
        if (this.visibleCharacterCountInList(STORE_MULTI_CHARACTERS, false) > 0) {
          this.characterRoleSectionHeader(MULTI_CHARACTER_SECTION_TITLE, MULTI_CHARACTER_SECTION_HINT)
          this.characterGridForList(STORE_MULTI_CHARACTERS, false)
        }
      }
    }.width('100%')
  }

  @Builder
  private sunsetPreview() {
    Stack() {
      Image($rawfile('scenes/sunset/sunset_sky.png')).width('100%').height('100%').objectFit(ImageFit.Cover)
      Image($rawfile('scenes/sunset/sunset_sun.png')).width(90).height(90).objectFit(ImageFit.Contain)
        .position({ x: '64%', y: 4 })
      Image($rawfile('scenes/sunset/sunset_clouds.png')).width('150%').height(92).objectFit(ImageFit.Fill)
        .position({ x: -30, y: 5 })
      Image($rawfile('scenes/sunset/sunset_ocean.png')).width('100%').height(72).objectFit(ImageFit.Fill)
        .position({ x: 0, y: 72 })
      Image($rawfile('scenes/sunset/sunset_midground_dirt.png')).width('100%').height(62).objectFit(ImageFit.Fill)
        .position({ x: 0, y: 86 })
      Image($rawfile('scenes/sunset/sunset_road.png')).width('125%').height(72).objectFit(ImageFit.Fill)
        .position({ x: -20, y: 116 })
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
      Image($rawfile('scenes/neon/neon_street_blocks.png')).width('92%').height(112).objectFit(ImageFit.Fill)
        .position({ x: 0, y: 36 })
      Image($rawfile('scenes/neon/neon_road.png')).width('125%').height(72).objectFit(ImageFit.Fill)
        .position({ x: -20, y: 106 })
      Image($rawfile('scenes/neon/neon_front_occluders3.png')).width('48%').height(178).objectFit(ImageFit.Fill)
        .position({ x: 208, y: 0 })
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
      ActionButton({
        label: '使用中', active: false, controlWidth: 'auto', controlHeight: 34,
        contentPadding: { left: 13, right: 13 }, labelSize: 12, labelWeight: 900,
        fill: PAPER, lineWidth: 1, cornerRadius: 17,
        hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
        action: () => {}
      })
    } else if (this.sceneAccessState(item) === 'limited') {
      Button({ type: ButtonType.Normal }) {
        this.limitedPrice(this.productPrice(item.productId))
      }
      .height(36).padding({ left: 9, right: 9 }).backgroundColor('#FFF1D7')
      .border({ width: 1, color: INK }).borderRadius(18)
      .background(comicInkSurface('#FFF1D7', 18, COMIC_CONTROL_INK_OFFSET)).clip(false)
      .onClick(() => this.selectScene(item))
    } else if (this.sceneAccessState(item) === 'pass') {
      Button('可使用', { type: ButtonType.Normal }).height(34).padding({ left: 13, right: 13 })
        .fontSize(12).fontWeight(900).fontColor(INK).backgroundColor(LILAC)
        .border({ width: 1, color: INK }).borderRadius(17)
        .background(comicInkSurface(LILAC, 17, COMIC_CONTROL_INK_OFFSET)).clip(false)
        .onClick(() => this.selectScene(item))
    } else if (this.sceneAccessState(item) === 'owned') {
      Button('已拥有', { type: ButtonType.Normal }).height(34).padding({ left: 13, right: 13 })
        .fontSize(12).fontWeight(900).fontColor(INK).backgroundColor(PAPER)
        .border({ width: 1, color: INK }).borderRadius(17)
        .background(comicInkSurface(PAPER, 17, COMIC_CONTROL_INK_OFFSET)).clip(false)
        .onClick(() => this.selectScene(item))
    } else {
      Button(this.productPrice(item.productId), { type: ButtonType.Normal })
        .height(34).padding({ left: 13, right: 13 }).fontSize(12).fontWeight(900).fontColor(INK)
        .backgroundColor(CORAL).border({ width: 1, color: INK }).borderRadius(17)
        .background(comicInkSurface(CORAL, 17, COMIC_CONTROL_INK_OFFSET)).clip(false)
        .onClick(() => this.openScenePurchase(item))
    }
  }

  @Builder
  private sceneCard(item: StoreScene) {
    DrumPaper({
      fill: '#FFFDF7',
      paperWidth: '100%',
      cornerRadius: 7,
      paperLineWidth: 1.3,
      clipContent: true,
      offsetX: COMIC_CARD_INK_OFFSET,
      offsetY: COMIC_CARD_INK_OFFSET
    }) {
      Column({ space: 0 }) {
        this.scenePreview(item)
        Row() {
          Column({ space: 2 }) {
            Text(item.name).fontSize(16).fontWeight(900)
            Text(item.caption).fontSize(9).fontColor('#645E55').maxLines(2)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          this.sceneAction(item)
        }.width('100%').height(62).padding({ left: 12, right: 10 })
      }.width('100%').height(240)
    }
  }

  @Builder
  private drumIntroOverlay() {
    // Block also suppresses child hit tests; the modal must keep its close and scroll controls interactive.
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Image($rawfile(DRUM_INTRO_ASSET)).width('100%').aspectRatio(DRUM_INTRO_IMAGE_RATIO)
          .objectFit(ImageFit.Contain).draggable(false)
          .accessibilityText('PRO 定制鼓机介绍：12 种风格、最多 8 个段落独立选风格、10 种鼓声，选择节奏型与加花、点格子编写鼓点，保存到我的编排、试听并应用到队伍，行进时可切换编排')
      }.width('100%').height('100%').align(Alignment.TopStart)
        .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)
        .padding({ left: DRUM_INTRO_SIDE_INSET, right: DRUM_INTRO_SIDE_INSET,
          top: this.topSafeInset + DRUM_INTRO_CLOSE_TOP + DRUM_INTRO_CLOSE_SIZE + DRUM_INTRO_CONTENT_GAP,
          bottom: this.bottomSafeInset + DRUM_INTRO_SIDE_INSET })
      Row() {
        Blank()
        Button('×', { type: ButtonType.Normal }).width(DRUM_INTRO_CLOSE_SIZE).height(DRUM_INTRO_CLOSE_SIZE)
          .padding(0).fontSize(29).fontWeight(FontWeight.Bold).fontColor(INK).backgroundColor(PAPER)
          .border({ width: 1.5, color: INK }).borderRadius(DRUM_INTRO_CLOSE_SIZE / 2)
          .background(comicInkSurface(PAPER, DRUM_INTRO_CLOSE_SIZE / 2, COMIC_CONTROL_INK_OFFSET)).clip(false)
          .id('drum-intro-close').accessibilityText('关闭鼓机介绍')
          .onClick(() => this.closeDrumIntro())
      }.width('100%').height(DRUM_INTRO_CLOSE_SIZE)
        .padding({ right: DRUM_INTRO_SIDE_INSET })
        .position({ x: 0, y: this.topSafeInset + DRUM_INTRO_CLOSE_TOP })
    }.width('100%').height('100%').backgroundColor('#F2171B1F')
      .hitTestBehavior(HitTestMode.Default).zIndex(110)
  }

  @Builder
  private purchaseDialog() {
    Stack({ alignContent: Alignment.Center }) {
      DrumPaper({
        fill: '#FFF1D7',
        paperWidth: '88%',
        cornerRadius: 8,
        paperLineWidth: 2.5,
        clipContent: true,
        offsetX: COMIC_CARD_INK_OFFSET,
        offsetY: COMIC_CARD_INK_OFFSET
      }) {
        Column({ space: 12 }) {
          Text(this.pendingType === 'pass' ? 'MORE BEATS!' : 'NEW FRIEND!')
            .fontSize(11).fontWeight(900).fontColor(PAPER).backgroundColor(INK)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 }).rotate({ angle: -3 })
            .background(comicInkSurface(INK, 0, COMIC_CONTROL_INK_OFFSET)).clip(false)
          Text(this.storeActionType === 'restore' ? '恢复购买' : this.pendingName)
            .fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic)
          if (this.storeActionType !== 'restore') {
            if (this.pendingType === 'pass') {
              Text() {
                Span('开通后可使用当前及后续上架的所有角色、场景和 ')
                Span('PRO 定制鼓机').fontColor('#B63926')
                  .decoration({ type: TextDecorationType.Underline })
                  .onClick(() => this.openDrumIntro())
                Span('。')
              }.fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).width('100%')
                .id('pass-benefits-description')
            } else {
              Text('购买后会加入“我的”，可在小铺和队伍中使用。')
                .fontSize(13).fontWeight(FontWeight.Bold).lineHeight(20).width('100%')
            }
            Text(this.pendingPrice).fontSize(22).fontWeight(900).fontColor(CORAL)
          }
          if (this.pendingType === 'pass' && this.storeActionType !== 'restore') {
            Text() {
              if (this.passDescription().includes('PRO 定制鼓机')) {
                Span(this.passDescription().split('PRO 定制鼓机')[0])
                Span('PRO 定制鼓机').fontColor('#B63926')
                  .decoration({ type: TextDecorationType.Underline })
                  .onClick(() => this.openDrumIntro())
                Span(this.passDescription().split('PRO 定制鼓机')[1])
              } else {
                Span(this.passDescription())
              }
            }.fontSize(12).fontWeight(FontWeight.Bold).width('100%').id('pass-rights-description')
            Text(this.passActive && this.passSource === 'PASS_REDEMPTION' ? '赠送月卡到期后结束，不自动续费。' :
              '本方案按月自动续费，可在华为账号的订阅管理中取消；取消后本期仍可使用。')
              .fontSize(11).fontColor('#6B655D').lineHeight(17).width('100%')
            if (this.passPurchaseRestriction().length > 0) {
              Text(this.passPurchaseRestriction()).fontSize(12).fontWeight(FontWeight.Bold).width('100%')
            }
          }
          if (this.storeActionStatus.length > 0) {
            Text(this.storeActionStatus).fontSize(12).fontWeight(FontWeight.Bold).width('100%')
          }
          Row({ space: 9 }) {
            ActionButton({
              label: this.storeActionType === 'restore' ? '关闭' : '再想想', active: !this.purchaseBusy,
              controlHeight: 42, labelSize: 13, labelWeight: 900, fill: PAPER,
              contentPadding: { left: 16, right: 16 },
              lineWidth: 1.5, cornerRadius: 5,
              hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
              action: () => { this.purchaseVisible = false; }
            }).layoutWeight(1)
            if (this.storeActionType === 'restore') {
              if (this.storeActionRecovery === 'restore') {
                ActionButton({
                  label: '重试恢复', active: !this.purchaseBusy,
                  controlHeight: 42, labelSize: 13, labelWeight: 900, fill: CORAL,
                  contentPadding: { left: 16, right: 16 },
                  lineWidth: 1.5, cornerRadius: 5,
                  hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                  action: () => { void this.restorePurchases(); }
                }).layoutWeight(1.3)
              }
            } else {
              ActionButton({
                label: this.pendingType === 'pass' && this.passPurchaseRestriction().length > 0 ? '暂不可购买' :
                  (this.storeActionRecovery === 'purchase' ? '重新购买' : '确认购买'),
                active: !this.purchaseBusy &&
                  (this.pendingType !== 'pass' || this.passPurchaseRestriction().length === 0),
                controlHeight: 42, labelSize: 13, labelWeight: 900, fill: CORAL,
                contentPadding: { left: 16, right: 16 },
                lineWidth: 1.5, cornerRadius: 5,
                hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                action: () => { void this.confirmPurchase(); }
              }).layoutWeight(1.3)
            }
          }.width('100%')
          if (this.storeActionRecovery === 'purchase') {
            ActionButton({
              label: '恢复购买', active: !this.purchaseBusy,
              controlHeight: 34, labelSize: 12, labelWeight: 900, fill: PAPER,
              contentPadding: { left: 16, right: 16 },
              lineWidth: 1, cornerRadius: 5,
              hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
              action: () => { void this.restorePurchases(); }
            })
          }
          Text('支付后权益未到账，可在“我的”中点击“恢复购买”。')
            .fontSize(9).fontColor('#6B655D').width('100%')
        }.width('100%').padding(17)
      }
    }.width('100%').height('100%').backgroundColor('#77000000').zIndex(100)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text('‹').fontSize(32).width(32).onClick(() => router.back())
            Text('奇遇小铺').fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic)
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
            this.characterCatalog(false)
          } else if (this.selectedTab === 1) {
            ForEach(STORE_SCENES, (item: StoreScene) => {
              this.sceneCard(item)
            }, (item: StoreScene) => this.storeOfferRenderKey('scene', item.key, item.productId))
            DrumPaper({
              fill: LILAC,
              paperWidth: '100%',
              cornerRadius: 7,
              paperLineWidth: 1.2,
              clipContent: true,
              offsetX: COMIC_CARD_INK_OFFSET,
              offsetY: COMIC_CARD_INK_OFFSET
            }) {
              Column({ space: 4 }) {
                Text('MORE WORLDS INCOMING').fontSize(11).fontWeight(900).letterSpacing(1)
                Text('新场景将会在这里持续上架').fontSize(12).fontColor('#655F57')
              }.width('100%').padding(16)
            }
          } else {
            if (this.ownedExclusiveCharacterCount() > 0) {
              Row() {
                Text('我的角色').fontSize(17).fontWeight(900)
                Blank()
                Text(`${this.ownedExclusiveCharacterCount()} 个`).fontSize(11).fontColor('#655F57')
              }.width('100%')
              this.characterCatalog(true)
            }
            if (this.ownedSceneCount() > 0) {
              Text('我的场景').fontSize(17).fontWeight(900).width('100%')
              ForEach(STORE_SCENES, (item: StoreScene) => {
                if (this.hasScene(item.key)) {
                  this.sceneCard(item)
                }
              }, (item: StoreScene) => this.storeOfferRenderKey('owned-scene', item.key, item.productId))
            }
            this.restorePurchasesAction()
            if (this.storeActionType === 'restore' && !this.purchaseVisible && this.storeActionStatus.length > 0) {
              Text(this.storeActionStatus).fontSize(12).fontWeight(FontWeight.Bold).width('100%')
            }
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
          right: 16 + COMIC_CARD_INK_OFFSET,
          top: 10 + this.topSafeInset,
          bottom: 24 + this.bottomSafeInset + COMIC_CARD_INK_OFFSET
        })
      }.width('100%').height('100%').backgroundColor(PAPER)
      if (this.redemptionVisible) {
        this.redemptionPage()
      }
      if (this.purchaseVisible) {
        this.purchaseDialog()
      }
      if (this.purchaseVisible && this.drumIntroVisible) {
        this.drumIntroOverlay()
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
