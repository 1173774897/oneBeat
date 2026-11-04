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
  WHITE,
} from '../components/ComicKit';
import { deleteStoreAccount, fetchStoreBootstrap, redeemStoreCode } from '../store/StoreApi';
import { isStoreApiConfigured } from '../store/StoreApiConfig';
import {
  applyStoreBootstrap,
  initializeEntitlementCache,
  isHuaweiPassActive,
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
import { productTypeForStoreItem, purchaseStoreProduct } from '../store/IapPurchaseService';
import { refreshLocalIapEntitlements } from '../store/IapEntitlements';
import { StoreBootstrap, StoreRedemptionResult } from '../store/StoreModels';
import {
  hasCrossBorderConsent,
  revokeCrossBorderConsent,
  setCrossBorderConsentPrompter
} from '../store/CrossBorderConsent';
import { storeProductIntroduction } from '../store/StoreProductCopy';

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
  { key: 'cloud', name: '云行者', caption: '轻盈天空拍', asset: 'cloud', photoAsset: 'comic/store/cloud.png', color: '#DCE9FA', productId: 'onebeat.character.cloud' },
  { key: 'teapot', name: '茶壶太太', caption: '慢火稳拍', asset: 'teapot', photoAsset: 'comic/store/teapot.png', color: '#FFD06A', productId: 'onebeat.character.teapot' },
  { key: 'wave', name: 'Wave', caption: '浪线步态', asset: 'wave', photoAsset: 'comic/store/wave.png', color: '#7EC8FF', productId: 'onebeat.character.wave' },
  { key: 'mismatch', name: '条纹步客', caption: '酷脸推进', asset: 'mismatch', photoAsset: 'comic/store/mismatch.png', color: '#E8DFF6', productId: 'onebeat.character.mismatch' },
  { key: 'scooter', name: '青柠滑手', caption: '双拍十六帧', asset: 'scooter', color: '#FF9E7A', productId: 'onebeat.character.scooter' },
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
// Header slot of the「兑」redemption entrance; kept as an empty placeholder while
// a pass is active so the title row does not shift.
const REDEMPTION_ENTRANCE_WIDTH: number = 46;
const REDEMPTION_ENTRANCE_HEIGHT: number = 42;
// Gap between「恢复购买」and the low-key「注销小铺账号」link in the 我的 tab.
const ACCOUNT_DELETION_LINK_TOP: number = 4;

const PASS_BANNER_MAX_WIDTH: number = 472;
const PASS_BANNER_DEFAULT_WIDTH: number = 372;
// The PNG canvas keeps transparent room around a 2.52:1 ticket. Cover-cropping
// it into this ratio preserves the complete ink edge while removing that room.
const PASS_BANNER_DISPLAY_RATIO: number = 2.42;
const PASS_BANNER_STATUS_X: string = '6.2%';
const PASS_BANNER_STATUS_Y: string = '85.2%';
const PASS_BANNER_STATUS_WIDTH: string = '21%';
const PASS_BANNER_STATUS_HEIGHT: string = '10%';
const PASS_BANNER_STATUS_FONT_SIZE: number = 7.2;
const PASS_BANNER_STATUS_LINE_HEIGHT: number = 10;
// Center live content on the illustrated capsule face, not its offset ink shadow.
const PASS_BANNER_ACTION_X: string = '78.5%';
const PASS_BANNER_ACTION_Y: string = '58.5%';
const PASS_BANNER_ACTION_WIDTH: string = '17.4%';
const PASS_BANNER_ACTION_HEIGHT: string = '20.5%';
const PASS_BANNER_ACTION_FONT_SIZE: number = 10.5;
const PASS_BANNER_ACTION_LINE_HEIGHT: number = 14;
const PASS_BANNER_ACTION_CONTENT_GAP: number = 3;
const PASS_BANNER_ACTION_ARROW_WIDTH: number = 5;
const PASS_BANNER_ACTION_ARROW_HEIGHT: number = 8;
const PASS_BANNER_ACTION_ARROW_STROKE: number = 1.6;
const DRUM_INTRO_ASSET: string = 'comic/store/pro-drum-intro.png';
const DRUM_INTRO_IMAGE_RATIO: number = 2 / 3;
const DRUM_INTRO_SIDE_INSET: number = 12;
const DRUM_INTRO_CLOSE_TOP: number = 8;
const DRUM_INTRO_CLOSE_SIZE: number = 44;
const DRUM_INTRO_CONTENT_GAP: number = 10;
const PURCHASE_DIALOG_MAX_WIDTH: number = 388;
const PURCHASE_DIALOG_PADDING: number = 28;
const PURCHASE_DIALOG_EDGE_GAP: number = 20;
const PURCHASE_HEADER_GAP: number = 14;
// All viewports share these tuning values; a breakpoint must not override them.
const PURCHASE_AVATAR_SIZE: number = 102;
const PURCHASE_PRODUCT_MEDIA_WIDTH: number = 104;
const PURCHASE_MEDIA_TOP: number = 0;
const PURCHASE_INTRO_FONT_SIZE: number = 13;
const PURCHASE_INTRO_LINE_HEIGHT: number = 22;
const PURCHASE_INTRO_LINES: number = 2;
// Product stories are capped at 100 characters; keep one Text node in both states.
const PURCHASE_INTRO_EXPANDED_LINES: number = 100;
// A small preview avoids mounting the full parallax scene in a checkout dialog.
const PURCHASE_SCENE_PREVIEW_ASSET: string = 'comic/store/neon-preview.jpg';

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

/** Access that lapses by itself; such items are usable but not kept in 「我的」. */
function isTemporaryAccessReason(reason: string): boolean {
  return reason === 'LIMITED_FREE' || reason === 'PASS_IAP' || reason === 'PASS_REDEMPTION';
}

@Entry
@Component
struct StorePage {
  @StorageLink('safeAreaTop') topSafeInset: number = 0;
  @StorageLink('safeAreaBottom') bottomSafeInset: number = 0;
  @StorageLink('selectedSceneKey') selectedSceneKey: string = 'sunset_coast';
  @State selectedTab: number = 0;
  @State ownedCharacters: string[] = [];
  @State ownedScenes: string[] = [];
  // 「我的」 lists only items kept for good (bought, or free by default). Access
  // that ends on its own (limited free, monthly pass) stays out of it.
  @State keptCharacters: string[] = [];
  @State keptScenes: string[] = [];
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
  private readonly redemptionInputController: TextInputController = new TextInputController();
  @State purchaseVisible: boolean = false;
  @State drumIntroVisible: boolean = false;
  @State purchaseIntroExpanded: boolean = false;
  @State purchaseIntroAnchorTop: number = 0;
  @State purchaseIntroAnchorPinned: boolean = false;
  @State purchaseIntroOverflow: boolean = false;
  @State storeViewportHeight: number = 720;
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
  @State accountDeletionBusy: boolean = false;
  @State accountDeletionStatus: string = '';
  @State accountDeletionDialogStep: number = 0;
  @State accountDeletionWithoutLocalAccount: boolean = false;
  @State storeActionType: string = '';
  @State purchaseBusy: boolean = false;
  private storeLifetimeEpoch: number = 0;
  private storePageActive: boolean = true;
  private readonly purchaseScroller: Scroller = new Scroller();
  @State crossBorderConsentVisible: boolean = false;
  private crossBorderConsentResolver: ((agreed: boolean) => void) | undefined = undefined;

  aboutToAppear(): void {
    this.storePageActive = true;
    this.storeLifetimeEpoch++;
    setCrossBorderConsentPrompter(() => this.askCrossBorderConsent());
    initializeEntitlementCache();
    this.loadPurchases();
  }

  aboutToDisappear(): void {
    this.storePageActive = false;
    this.storeLifetimeEpoch++;
    setCrossBorderConsentPrompter(undefined);
  }

  /**
   * Separate PIPL consent before any Store data goes to the Hong Kong server.
   * Since 2026-11-03 only redemption (and its sign-in) needs it: purchase data
   * stays between the device and Huawei.
   * Opening the privacy statement counts as not yet agreeing: the action is
   * cancelled silently and the user can tap it again after reading.
   */
  private askCrossBorderConsent(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      this.crossBorderConsentResolver = resolve;
      this.crossBorderConsentVisible = true;
    });
  }

  private resolveCrossBorderConsent(agreed: boolean): void {
    const resolve = this.crossBorderConsentResolver;
    this.crossBorderConsentResolver = undefined;
    this.crossBorderConsentVisible = false;
    if (resolve !== undefined) {
      resolve(agreed);
    }
  }

  private viewPrivacyFromConsent(): void {
    this.resolveCrossBorderConsent(false);
    router.pushUrl({ url: 'pages/PrivacyPage' });
  }

  private isCurrentStorePage(epoch: number): boolean {
    return this.storePageActive && this.storeLifetimeEpoch === epoch;
  }

  onPageShow(): void {
    // Runs on first open and when returning from system Settings after Huawei ID sign-in.
    void this.refreshStoreData();
  }

  onBackPress(): boolean {
    if (this.crossBorderConsentVisible) {
      this.resolveCrossBorderConsent(false);
      return true;
    }
    if (this.purchaseVisible && this.drumIntroVisible) {
      this.closeDrumIntro();
      return true;
    }
    if (this.purchaseVisible) {
      if (!this.purchaseBusy) {
        if (this.purchaseIntroExpanded && this.storeActionType !== 'restore') {
          this.collapsePurchaseIntroduction();
        } else {
          this.purchaseVisible = false;
        }
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
    // Paid items: re-ask Huawei on every Store visit so refunds, renewals and
    // purchases made on another device show up. Failures keep the saved summary.
    void refreshLocalIapEntitlements(this.hostContext()).then(() => {
      if (this.isCurrentStorePage(lifetime)) {
        this.loadPurchases();
      }
    }).catch((error: Object) => logUserFailure('store.iap-refresh', error));
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
    this.keptCharacters = this.ownedCharacters.filter((key: string) =>
      !isTemporaryAccessReason(storeItemAccessReason(`character.${key}`)));
    this.keptScenes = this.ownedScenes.filter((key: string) =>
      !isTemporaryAccessReason(storeItemAccessReason(`scene.${key}`)));
    this.redemptionAvailable = AppStorage.get<boolean>('storeRedemptionAvailable') ?? false;
  }

  private hasCharacter(key: string): boolean {
    return this.ownedCharacters.indexOf(key) >= 0;
  }

  private hasScene(key: string): boolean {
    return this.ownedScenes.indexOf(key) >= 0;
  }

  private keepsCharacter(key: string): boolean {
    return this.keptCharacters.indexOf(key) >= 0;
  }

  private keepsScene(key: string): boolean {
    return this.keptScenes.indexOf(key) >= 0;
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
      if (this.keepsScene(STORE_SCENES[i].key)) {
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
      if (this.keepsCharacter(items[i].key)) {
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
    // Purchases are completed between this device and Huawei only: no Store
    // login, no cross-border consent and no request to the store server.
    try {
      try {
        await purchaseStoreProduct(this.hostContext(), productId, productTypeForStoreItem(isPass));
        // A paid order is delivered even if the page leaves during native
        // checkout; only this page's state and completion notice are discarded.
        if (!this.isCurrentStorePage(lifetime)) {
          return;
        }
        this.loadPurchases();
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
          // untrusted native prose out of the page's error contract.
          throw new StorePurchaseError(userErrorMessage(purchaseError, '购买未完成，请重试；已支付可恢复购买'),
            iapError.code ?? 0);
        }
        this.storeActionStatus = '正在同步已购权益…';
        await refreshLocalIapEntitlements(this.hostContext());
        if (!this.isCurrentStorePage(lifetime)) {
          return;
        }
        this.loadPurchases();
        if (storeItemAccessReason(this.pendingItemKey()) === 'LOCKED') {
          throw new Error('华为账号已拥有该商品，请稍后点击「恢复购买」同步权益');
        }
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

  private pendingItemKey(): string {
    if (this.pendingType === 'pass') {
      return 'pass.all';
    }
    return this.pendingType === 'scene' ? `scene.${this.pendingKey}` : `character.${this.pendingKey}`;
  }

  /**
   * No new redemption is offered while any pass (Huawei or gift) is active.
   * An already open redemption page stays open so a background refresh cannot
   * pull it away mid-entry; its result page hides "another code" the same way.
   */
  private redemptionEntranceVisible(): boolean {
    return !this.passActive;
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
    // Close the keyboard before any consent dialog or sign-in UI appears. If it
    // stays open, the page stays lifted above it and drops when the keyboard
    // finally closes on navigation (e.g. opening the privacy statement).
    this.redemptionInputController.stopEditing();
    this.redemptionBusy = true;
    const lifetime = this.storeLifetimeEpoch;
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      // Shown only after sign-in and consent. The redemption Scroll centres its
      // shorter-than-screen content, so a status line inserted before the
      // consent dialog lifted the page, and clearing it on decline (e.g. via
      // 「详见隐私声明」) dropped it again. The button already reads 「兑换中…」.
      this.redemptionStatus = '正在核对账号权益…';
      // The server no longer knows about Huawei subscriptions, so the rule
      // "no gift pass while a Huawei pass is live" is checked here against a
      // fresh Huawei query. A failed query falls back to the saved summary.
      try {
        await refreshLocalIapEntitlements(this.hostContext());
      } catch (queryError) {
        logUserFailure('store.redemption.iap-query', queryError);
      }
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      this.loadPurchases();
      if (isHuaweiPassActive()) {
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
    this.purchaseIntroExpanded = false;
    this.purchaseIntroAnchorPinned = false;
    this.purchaseIntroOverflow = false;
    this.drumIntroVisible = false;
    if (this.purchaseVisible) {
      this.purchaseScroller.scrollEdge(Edge.Top);
    }
    const lifetime = this.storeLifetimeEpoch;
    this.storeActionType = 'restore';
    this.storeActionStatus = '正在恢复购买…';
    this.storeActionRecovery = '';
    try {
      // Restoring is a fresh query of the Huawei account; purchases are kept
      // by Huawei, so no Store login is involved.
      const result = await refreshLocalIapEntitlements(this.hostContext());
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      this.loadPurchases();
      const restored = result.ownedItemCount > 0 || result.passActive;
      this.storeActionStatus = result.rejectedCount > 0 ? '部分购买记录未能核验，请稍后重试' :
        restored ? '已购权益已恢复' : '当前华为账号没有可恢复的购买';
      this.storeActionRecovery = result.rejectedCount > 0 ? 'restore' : '';
    } catch (e) {
      if (!this.isCurrentStorePage(lifetime)) {
        return;
      }
      if (isUserCancelled(e)) {
        this.storeActionStatus = '';
        return;
      }
      logUserFailure('store.restore', e);
      this.storeActionStatus = userErrorMessage(e, '恢复失败，请确认已登录华为账号并检查网络后重试');
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
    return '查看方案';
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
    this.purchaseIntroExpanded = false;
    this.purchaseIntroAnchorPinned = false;
    this.purchaseIntroOverflow = false;
    if (this.purchaseVisible) {
      this.purchaseScroller.scrollEdge(Edge.Top);
    }
    this.storeActionType = 'purchase';
    this.storeActionStatus = '';
    this.storeActionRecovery = '';
  }

  private pendingIntroduction(): string {
    return this.storeActionType === 'restore' ? '' : storeProductIntroduction(this.pendingProductId);
  }

  private pendingPurchaseCaption(): string {
    if (this.pendingType === 'pass') {
      return '角色、场景与 PRO 定制鼓机';
    }
    if (this.pendingType === 'scene') {
      return STORE_SCENES.find((item: StoreScene) => item.key === this.pendingKey)?.caption ?? '';
    }
    const caption = STORE_CHARACTERS.find((item: StoreCharacter) => item.key === this.pendingKey)?.caption ?? '';
    return caption.length > 0 ? `独占角色 · ${caption}` : '独占角色';
  }

  private purchaseMediaWidth(): number {
    return this.pendingType === 'character' ? PURCHASE_AVATAR_SIZE : PURCHASE_PRODUCT_MEDIA_WIDTH;
  }

  private updatePurchaseIntroOverflow(width: number): void {
    const introduction = this.pendingIntroduction();
    if (!Number.isFinite(width) || width <= 0 || introduction.length === 0) {
      this.purchaseIntroOverflow = false;
      return;
    }
    try {
      // Compare the same native font layout with and without a line limit.
      // Character counts would hide the link incorrectly after font/window changes.
      const measure = this.getUIContext().getMeasureUtils();
      const full = measure.measureTextSize({
        textContent: introduction, fontSize: `${PURCHASE_INTRO_FONT_SIZE}fp`, fontWeight: 400,
        lineHeight: `${PURCHASE_INTRO_LINE_HEIGHT}vp`, constraintWidth: `${width}vp`
      });
      const folded = measure.measureTextSize({
        textContent: introduction, fontSize: `${PURCHASE_INTRO_FONT_SIZE}fp`, fontWeight: 400,
        lineHeight: `${PURCHASE_INTRO_LINE_HEIGHT}vp`, constraintWidth: `${width}vp`, maxLines: PURCHASE_INTRO_LINES
      });
      const fullHeight = Number(full.height);
      const foldedHeight = Number(folded.height);
      this.purchaseIntroOverflow = !Number.isFinite(fullHeight) || !Number.isFinite(foldedHeight) ||
        fullHeight <= 0 || foldedHeight <= 0 ||
        fullHeight > foldedHeight + 1;
    } catch (_error) {
      // A measurement failure must not make truncated product copy inaccessible.
      this.purchaseIntroOverflow = true;
    }
  }

  private expandPurchaseIntroduction(): void {
    if (!this.purchaseVisible || this.purchaseBusy || this.storeActionType === 'restore' ||
      !this.purchaseIntroOverflow || this.pendingIntroduction().length === 0) {
      return;
    }
    this.purchaseIntroAnchorPinned = true;
    this.purchaseIntroExpanded = true;
  }

  private collapsePurchaseIntroduction(): void {
    if (this.purchaseBusy) {
      return;
    }
    this.purchaseIntroExpanded = false;
  }

  private updatePurchaseDialogAnchor(top: number): void {
    if (!this.purchaseIntroAnchorPinned && Number.isFinite(top) && top >= 0 &&
      Math.abs(top - this.purchaseIntroAnchorTop) >= 0.5) {
      this.purchaseIntroAnchorTop = top;
    }
  }

  private purchaseDialogTopPadding(): number {
    const safeTop = this.topSafeInset + PURCHASE_DIALOG_EDGE_GAP;
    // Once opened, keep this top edge through every expand/collapse cycle.
    // Switching back to centering while Text shrinks produces a second layout jump.
    return this.purchaseIntroAnchorPinned ? Math.max(safeTop, this.purchaseIntroAnchorTop) : safeTop;
  }

  private openAccountDeletionDialog(): void {
    if (this.accountDeletionBusy || this.purchaseBusy) {
      return;
    }
    // Login requires cross-border consent first, and consent is cleared only by
    // a completed deletion, so no consent on record means this install never
    // sent anything to the server. The server may still hold data from another
    // device or an earlier install, which only a login can find, so deletion
    // stays available; the dialog just explains the consent step up front
    // instead of surprising the user with it after「确认注销」.
    this.accountDeletionWithoutLocalAccount = !hasCrossBorderConsent();
    this.accountDeletionDialogStep = 1;
  }

  private accountDeletionDialogTitle(): string {
    if (this.accountDeletionDialogStep !== 1) {
      return '确认注销小铺账号？';
    }
    return this.accountDeletionWithoutLocalAccount ? '本机还没有登录过小铺账号' : '注销后兑换权益将永久失去';
  }

  private accountDeletionConfirmLabel(): string {
    if (this.accountDeletionDialogStep !== 1) {
      return '确认注销';
    }
    return this.accountDeletionWithoutLocalAccount ? '仍要注销' : '继续';
  }

  private dismissAccountDeletionDialog(): void {
    this.accountDeletionDialogStep = 0;
  }

  private advanceAccountDeletion(): void {
    this.accountDeletionDialogStep = 2;
  }

  private confirmAccountDeletion(): void {
    this.accountDeletionDialogStep = 0;
    void this.performAccountDeletion();
  }

  /**
   * Two explicit confirmations that every entitlement is lost for good, then
   * the server deletion. Login comes after confirming: it may first ask for
   * the cross-border consent, and deletion itself needs the account identity.
   */
  private async performAccountDeletion(): Promise<void> {
    const lifetime = this.storeLifetimeEpoch;
    this.accountDeletionBusy = true;
    this.accountDeletionStatus = '';
    try {
      const accessToken = await ensureStoreSession(this.hostContext(), true);
      await deleteStoreAccount(accessToken);
      clearStoreSession();
      await revokeCrossBorderConsent();
      // Reset the server-granted part through the ordinary anonymous bootstrap
      // path. Paid items come from Huawei (IapEntitlements) and stay.
      try {
        const anonymous = await fetchStoreBootstrap('');
        if (anonymous !== null) {
          applyStoreBootstrap(anonymous);
        }
      } catch (_e) {
        // The deletion succeeded; entitlements refresh on the next Store visit.
      }
      if (this.isCurrentStorePage(lifetime)) {
        this.loadPurchases();
        this.storeActionStatus = '';
        this.storeActionRecovery = '';
      }
      showUserNotice('小铺账号已注销', 'store.account-deletion');
    } catch (e) {
      if (!this.isCurrentStorePage(lifetime) || isUserCancelled(e)) {
        return;
      }
      logUserFailure('store.account-deletion', e);
      this.accountDeletionStatus = userErrorMessage(e, '注销未完成，请检查网络后重试');
    } finally {
      if (this.isCurrentStorePage(lifetime)) {
        this.accountDeletionBusy = false;
      }
    }
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
          TextInput({ placeholder: '输入活动口令', text: this.redemptionCode, controller: this.redemptionInputController })
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
      if (this.redemptionAvailable && this.redemptionEntranceVisible()) {
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
    .width(REDEMPTION_ENTRANCE_WIDTH).height(REDEMPTION_ENTRANCE_HEIGHT)
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

  private passBannerChevronPath(): string {
    const scale = this.passBannerScale();
    const width = PASS_BANNER_ACTION_ARROW_WIDTH * scale;
    const height = PASS_BANNER_ACTION_ARROW_HEIGHT * scale;
    const inset = PASS_BANNER_ACTION_ARROW_STROKE * scale / 2;
    // Geometry keeps the arrow centered independently of CJK/Latin font baselines.
    return `M ${vp2px(inset)} ${vp2px(inset)} L ${vp2px(width - inset)} ${vp2px(height / 2)} ` +
      `L ${vp2px(inset)} ${vp2px(height - inset)}`;
  }

  @Builder
  private passBanner() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The approved illustration is one composition. Only the short status and
      // action label stay live because entitlement state changes after purchase.
      Image($rawfile('comic/decor/monthly_pass_ticket_v2.png'))
        .width('100%').height('100%').objectFit(ImageFit.Cover).zIndex(0)
        .hitTestBehavior(HitTestMode.None).accessibilityLevel('no')

      Row() {
        Text(this.passTicketStatusLabel())
          .fontSize(PASS_BANNER_STATUS_FONT_SIZE * this.passBannerScale()).fontWeight(900).fontColor(INK)
          .lineHeight(PASS_BANNER_STATUS_LINE_HEIGHT * this.passBannerScale()).halfLeading(true)
          .maxLines(1).textAlign(TextAlign.Center).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }.width(PASS_BANNER_STATUS_WIDTH).height(PASS_BANNER_STATUS_HEIGHT)
        .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .position({ x: PASS_BANNER_STATUS_X, y: PASS_BANNER_STATUS_Y })
        .hitTestBehavior(HitTestMode.None)

      Button({ type: ButtonType.Normal }) {
        Row({ space: PASS_BANNER_ACTION_CONTENT_GAP * this.passBannerScale() }) {
          Text(this.passButtonLabel())
            .fontSize(PASS_BANNER_ACTION_FONT_SIZE * this.passBannerScale()).fontWeight(900).fontColor(PAPER)
            .lineHeight(PASS_BANNER_ACTION_LINE_HEIGHT * this.passBannerScale()).halfLeading(true)
            .maxLines(1).textAlign(TextAlign.Center).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
          if (!this.passActive) {
            Path().commands(this.passBannerChevronPath())
              .width(PASS_BANNER_ACTION_ARROW_WIDTH * this.passBannerScale())
              .height(PASS_BANNER_ACTION_ARROW_HEIGHT * this.passBannerScale())
              .fill('#00000000').stroke(PAPER)
              .strokeWidth(PASS_BANNER_ACTION_ARROW_STROKE * this.passBannerScale())
              .strokeLineCap(LineCapStyle.Round).strokeLineJoin(LineJoinStyle.Round)
              .accessibilityLevel('no')
          }
        }.width('100%').height('100%')
          .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
      }.width(PASS_BANNER_ACTION_WIDTH).height(PASS_BANNER_ACTION_HEIGHT)
        .padding(0)
        .backgroundColor('#00000000').borderRadius(18)
        .position({ x: PASS_BANNER_ACTION_X, y: PASS_BANNER_ACTION_Y })
        .accessibilityText(this.passButtonLabel())
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

  /** Deliberately low-key: a destructive, rarely used action below「恢复购买」. */
  @Builder
  private accountDeletionEntry() {
    Column({ space: 4 }) {
      Text(this.accountDeletionBusy ? '正在注销…' : '注销小铺账号 ›')
        .fontSize(12)
        .fontColor('#66615A')
        .width('100%')
        .textAlign(TextAlign.End)
        .opacity(this.accountDeletionBusy || this.purchaseBusy ? 0.5 : 1)
        .accessibilityText('注销小铺账号')
        .onClick(() => { this.openAccountDeletionDialog(); })
      if (this.accountDeletionStatus.length > 0) {
        Text(this.accountDeletionStatus).fontSize(12).fontWeight(FontWeight.Bold).width('100%')
      }
    }.width('100%').margin({ top: ACCOUNT_DELETION_LINK_TOP })
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
          Button({ type: ButtonType.Normal }) {
            Row() {
              Text(label).fontSize(15).fontWeight(900).fontColor(INK)
                .lineHeight(20).halfLeading(true).maxLines(1).textAlign(TextAlign.Center)
            }.width('100%').height('100%')
              .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
              .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
          }.layoutWeight(1).height(42).padding(0)
            .backgroundColor(this.selectedTab === index ? CORAL : PAPER)
            .border({ width: { right: index < 2 ? 1 : 0 }, color: '#C9C0B4' })
            .accessibilityText(label)
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
        Text(title).fontSize(11).fontWeight(900).fontColor('#655F57').lineHeight(15).halfLeading(true)
        Divider().color(INK).strokeWidth(1).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center)
      Text(hint).fontSize(10).fontWeight(FontWeight.Medium).fontColor('#6B655D')
        .lineHeight(15).width('100%').textAlign(TextAlign.Start)
    }.width('100%').margin({ top: 4, bottom: 10 })
  }

  @Builder
  private characterGridForList(items: StoreCharacter[], onlyAccessible: boolean) {
    Grid() {
      ForEach(items, (item: StoreCharacter) => {
        if (!onlyAccessible || this.keepsCharacter(item.key)) {
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
        // “我的”只展示永久拥有（已购买或默认免费）的独占角色；限免和月卡不算，无需分区标题或随机池卡片。
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
  private purchaseProductImage() {
    if (this.pendingType === 'character') {
      ComicCharacter({ avatar: this.pendingKey, portrait: true, allowNativeDrag: false })
        .width(this.purchaseMediaWidth()).height(this.purchaseMediaWidth())
        .accessibilityText(`${this.pendingName}头像`)
    } else if (this.pendingType === 'scene') {
      Image($rawfile(PURCHASE_SCENE_PREVIEW_ASSET)).width(this.purchaseMediaWidth())
        .aspectRatio(13 / 8).objectFit(ImageFit.Cover).draggable(false)
        .border({ width: 1.5, color: INK }).borderRadius(5).clip(true)
        .accessibilityText(`${this.pendingName}场景缩略图`)
    }
  }

  @Builder
  private purchaseProductHeader() {
    Row({ space: PURCHASE_HEADER_GAP }) {
      Column({ space: 9 }) {
        Text(this.storeActionType === 'restore' ? 'RESTORE' : this.pendingType === 'pass' ? 'MORE BEATS!' :
          this.pendingType === 'scene' ? 'NEW WORLD!' : 'NEW FRIEND!')
          .fontSize(11).fontWeight(900).fontColor(PAPER).backgroundColor(INK)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 }).rotate({ angle: -3 })
          .background(comicInkSurface(INK, 0, COMIC_CONTROL_INK_OFFSET)).clip(false)
        Text(this.storeActionType === 'restore' ? '恢复购买' : this.pendingName)
          .fontSize(27).fontWeight(900).fontStyle(FontStyle.Italic).width('100%').maxLines(2)
        if (this.storeActionType !== 'restore') {
          Text(this.pendingPurchaseCaption()).fontSize(12).lineHeight(18).fontColor('#665E54').width('100%')
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.storeActionType !== 'restore' && (this.pendingType === 'character' || this.pendingType === 'scene')) {
        Column() {
          this.purchaseProductImage()
        }.width(this.purchaseMediaWidth()).margin({ top: PURCHASE_MEDIA_TOP })
      }
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  private purchaseIntroduction() {
    if (this.pendingIntroduction().length > 0) {
      Column({ space: 1 }) {
        Text(this.pendingIntroduction()).fontSize(PURCHASE_INTRO_FONT_SIZE).fontWeight(400)
          .lineHeight(`${PURCHASE_INTRO_LINE_HEIGHT}vp`).fontColor('#665E54').width('100%')
          .maxLines(this.purchaseIntroExpanded ? PURCHASE_INTRO_EXPANDED_LINES : PURCHASE_INTRO_LINES)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onAreaChange((_old: Area, area: Area) => {
            this.updatePurchaseIntroOverflow(Number(area.width));
          })
        if (this.purchaseIntroExpanded || this.purchaseIntroOverflow) {
          ActionButton({
            label: this.purchaseIntroExpanded ? '收起 ⌃' : '查看更多 ⌄',
            active: !this.purchaseBusy, controlWidth: 'auto', controlHeight: 40,
            labelSize: 12, labelWeight: 800, labelColor: '#167B76', fill: Color.Transparent,
            action: () => {
              if (this.purchaseIntroExpanded) {
                this.collapsePurchaseIntroduction();
              } else {
                this.expandPurchaseIntroduction();
              }
            }
          }).id('purchase-introduction-toggle')
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  private purchaseRightsAndPrice() {
    Column({ space: 11 }) {
      Column({ space: 4 }) {
        Text(this.pendingType === 'pass' ? '开通后' : '购买后')
          .fontSize(11).fontWeight(800).fontColor('#665E54').width('100%')
        if (this.pendingType === 'pass') {
          Text('有效期内畅用全部角色、场景').fontSize(12).fontWeight(800).lineHeight(20).width('100%')
            .id('pass-benefits-description')
          Text() {
            Span('包含后续上架内容与 ')
            Span('PRO 定制鼓机').fontColor('#B63926').decoration({ type: TextDecorationType.Underline })
              .onClick(() => this.openDrumIntro())
          }.fontSize(12).fontWeight(800).lineHeight(20).width('100%').id('pass-rights-description')
        } else {
          Text('永久解锁并加入“我的”').fontSize(12).fontWeight(800).lineHeight(20).width('100%')
          Text(this.pendingType === 'scene' ? '单人练习可选；多人场景由队长设置' : '单人、多人练习均可选用')
            .fontSize(12).fontWeight(800).lineHeight(20).width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Text(this.pendingType !== 'pass' ? '一次购买' :
          this.passActive && this.passSource === 'PASS_REDEMPTION' ? '赠送月卡 · 不自动续费' : '每月自动续费')
          .fontSize(11).fontColor('#665E54').margin({ right: 12 })
        Row({ space: 3 }) {
          Text(this.pendingPrice).fontSize(26).fontWeight(900).fontColor(CORAL).flexShrink(1)
          if (this.pendingType === 'pass' && this.pendingPrice !== '价格加载中') {
            Text('/月').fontSize(12).fontWeight(700).fontColor('#665E54').flexShrink(0)
          }
        }.constraintSize({ maxWidth: '100%' }).alignItems(VerticalAlign.Center)
      }.width('100%')
      if (this.pendingType === 'pass') {
        if (this.passActive || this.passExpiresAt.length > 0) {
          Text(this.passDescription()).fontSize(12).fontWeight(800).width('100%')
        }
        Text(this.passActive && this.passSource === 'PASS_REDEMPTION' ? '赠送月卡到期后结束，不自动续费。' :
          '按月自动续费，可在华为账号的订阅管理中取消；取消后本期仍可使用。')
          .fontSize(11).fontColor('#6B655D').lineHeight(18).width('100%')
        if (this.passPurchaseRestriction().length > 0) {
          Text(this.passPurchaseRestriction()).fontSize(12).fontWeight(800).width('100%')
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 11 })
      .border({ width: { top: 1 }, color: '#D5C6AD' })
  }

  @Builder
  private purchaseDialogActions() {
    Column({ space: 12 }) {
      if (this.storeActionStatus.length > 0) {
        Text(this.storeActionStatus).fontSize(12).fontWeight(FontWeight.Bold).width('100%')
      }
      Row({ space: 9 }) {
        ActionButton({
          label: this.storeActionType === 'restore' ? '关闭' : '再想想', active: !this.purchaseBusy,
          controlHeight: 44, labelSize: 13, labelWeight: 900, fill: PAPER,
          contentPadding: { left: 16, right: 16 }, lineWidth: 1.5, cornerRadius: 5,
          hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
          action: () => { this.purchaseVisible = false; }
        }).layoutWeight(1)
        if (this.storeActionType === 'restore') {
          if (this.storeActionRecovery === 'restore') {
            ActionButton({
              label: '重试恢复', active: !this.purchaseBusy, controlHeight: 44, labelSize: 13,
              labelWeight: 900, fill: CORAL, contentPadding: { left: 16, right: 16 },
              lineWidth: 1.5, cornerRadius: 5,
              hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
              action: () => { void this.restorePurchases(); }
            }).layoutWeight(1.3)
          }
        } else {
          ActionButton({
            label: this.pendingType === 'pass' && this.passPurchaseRestriction().length > 0 ? '暂不可购买' :
              (this.storeActionRecovery === 'purchase' ? '重新购买' : '确认购买'),
            active: !this.purchaseBusy && (this.pendingType !== 'pass' || this.passPurchaseRestriction().length === 0),
            controlHeight: 44, labelSize: 13, labelWeight: 900, fill: CORAL,
            contentPadding: { left: 16, right: 16 }, lineWidth: 1.5, cornerRadius: 5,
            hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
            action: () => { void this.confirmPurchase(); }
          }).layoutWeight(1.3)
        }
      }.width('100%')
      if (this.storeActionRecovery === 'purchase') {
        ActionButton({
          label: '恢复购买', active: !this.purchaseBusy, controlHeight: 44, labelSize: 12,
          labelWeight: 900, fill: PAPER, contentPadding: { left: 16, right: 16 }, lineWidth: 1, cornerRadius: 5,
          hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
          action: () => { void this.restorePurchases(); }
        })
      }
      Text('支付后权益未到账，可在“我的”中恢复购买。').fontSize(11).lineHeight(17).fontColor('#6B655D').width('100%')
    }.width('100%')
  }

  @Builder
  private purchaseDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll(this.purchaseScroller) {
        Column() {
          // A native background follows this host in the same layout pass.
          // A measured backing can retain its expanded height for one frame.
          Column() {
            Column({ space: 13 }) {
              this.purchaseProductHeader()
              if (this.storeActionType !== 'restore') {
                this.purchaseIntroduction()
                this.purchaseRightsAndPrice()
              }
              this.purchaseDialogActions()
            }.width('100%').padding(PURCHASE_DIALOG_PADDING)
              .backgroundColor('#FFF1D7').border({ width: 2.5, color: INK }).borderRadius(8).clip(true)
          }.width('88%').constraintSize({ maxWidth: PURCHASE_DIALOG_MAX_WIDTH })
            .background(comicInkSurface('#FFF1D7', 8, COMIC_CARD_INK_OFFSET)).clip(false)
            .onAreaChange((_old: Area, area: Area) => {
              this.updatePurchaseDialogAnchor(Number(area.position.y));
            })
        }.width('100%').constraintSize({ minHeight: this.storeViewportHeight })
          .justifyContent(this.purchaseIntroAnchorPinned ? FlexAlign.Start : FlexAlign.Center)
          .padding({ top: this.purchaseDialogTopPadding(),
            bottom: this.bottomSafeInset + PURCHASE_DIALOG_EDGE_GAP + COMIC_CARD_INK_OFFSET })
      }.width('100%').height('100%').scrollBar(BarState.Auto)
        .onAppear(() => { this.purchaseScroller.scrollEdge(Edge.Top); })
    }.width('100%').height('100%').backgroundColor('#77000000').zIndex(100)
  }

  @Builder
  consentTransferBullet(label: string, detail: string) {
    Row({ space: 6 }) {
      Text(label)
        .fontSize(11.5).fontWeight(900).fontColor(INK)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(LILAC).borderRadius(4)
      Text(detail)
        .fontSize(11.5).fontColor(INK).lineHeight(17)
        .layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  accountDeletionDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .onClick(() => this.dismissAccountDeletionDialog())
      Column() {
        DrumPaper({
          fill: '#FFF1D7',
          paperWidth: '100%',
          cornerRadius: 8,
          paperLineWidth: 2.5,
          paperLineColor: INK,
          offsetX: COMIC_CARD_INK_OFFSET,
          offsetY: COMIC_CARD_INK_OFFSET,
          clipContent: true
        }) {
          Column({ space: 12 }) {
            Text(this.accountDeletionDialogTitle())
              .fontSize(17).fontWeight(900).fontColor(INK).width('100%')
            if (this.accountDeletionDialogStep === 1) {
              Scroll() {
                Column({ space: 8 }) {
                  if (this.accountDeletionWithoutLocalAccount) {
                    Text('这台设备上没有需要清理的小铺数据。如果你曾在其他设备或重装应用前用这个华为账号兑换过口令，注销前需要登录华为账号确认身份，登录前会请你同意数据跨境传输。')
                      .fontSize(12.5).fontColor(INK).lineHeight(19).width('100%')
                  }
                  Text('注销只影响通过活动口令兑换获得的权益，这部分在注销后再也无法找回。')
                    .fontSize(12.5).fontColor('#5D574F').lineHeight(19).width('100%')
                  Text('· 兑换获得的畅游月卡：立即失效，不退还、不折算。')
                    .fontSize(12.5).fontColor('#5D574F').lineHeight(19).width('100%')
                  Text('· 已购买的角色、场景和华为自动续费月卡：不受影响。它们随华为账号保留，重装应用后点「恢复购买」即可找回。')
                    .fontSize(12.5).fontColor('#5D574F').lineHeight(19).width('100%')
                  Text('· 自动续费的扣费由华为账号管理，注销不会停止续费；如需停止，请在华为账号的订阅管理中取消。')
                    .fontSize(12.5).fontColor('#5D574F').lineHeight(19).width('100%')
                  Text('· 服务器会删除账号与华为账号的对应关系，兑换记录仅以去标识化形式保留。')
                    .fontSize(12.5).fontColor('#5D574F').lineHeight(19).width('100%')
                }.width('100%')
              }.width('100%').constraintSize({ maxHeight: 260 }).scrollBar(BarState.Off)
            } else {
              Text('兑换获得的权益注销后再也无法找回，且注销无法撤销。已购商品、节拍练习、组队和录制不受影响。')
                .fontSize(12.5).fontColor('#5D574F').lineHeight(19).width('100%')
              if (this.accountDeletionWithoutLocalAccount) {
                Text('确认后会先请你同意数据跨境传输，再登录华为账号核实身份。')
                  .fontSize(12.5).fontColor(INK).lineHeight(19).width('100%')
              }
            }
            Row({ space: 10 }) {
              ActionButton({
                label: this.accountDeletionDialogStep === 1 ? '取消' : '再想想',
                active: true, controlHeight: 44, labelSize: 13, labelWeight: 900,
                fill: PAPER, labelColor: INK, contentPadding: { left: 16, right: 16 }, lineWidth: 1.5, cornerRadius: 5,
                hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                action: () => this.dismissAccountDeletionDialog()
              }).layoutWeight(1)
              ActionButton({
                label: this.accountDeletionConfirmLabel(),
                active: true, controlHeight: 44, labelSize: 13, labelWeight: 900,
                fill: CORAL, labelColor: WHITE, contentPadding: { left: 16, right: 16 }, lineWidth: 1.5, cornerRadius: 5,
                hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
                action: () => {
                  if (this.accountDeletionDialogStep === 1) {
                    this.advanceAccountDeletion();
                  } else {
                    this.confirmAccountDeletion();
                  }
                }
              }).layoutWeight(1)
            }.width('100%')
          }
          .width('100%')
          .padding(22)
        }
      }
      .width('88%').constraintSize({ maxWidth: 360 })
    }
    .width('100%').height('100%').backgroundColor('#77000000').zIndex(110)
  }

  @Builder
  crossBorderConsentDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .onClick(() => this.resolveCrossBorderConsent(false))
      Column() {
        DrumPaper({
          fill: '#FFF1D7',
          paperWidth: '100%',
          cornerRadius: 8,
          paperLineWidth: 2.5,
          paperLineColor: INK,
          offsetX: COMIC_CARD_INK_OFFSET,
          offsetY: COMIC_CARD_INK_OFFSET,
          clipContent: true
        }) {
          Column({ space: 12 }) {
            Text('数据跨境传输说明')
            .fontSize(17).fontWeight(900).fontColor(INK).width('100%')
          Scroll() {
            Column({ space: 8 }) {
              Text('使用活动口令兑换需要登录华为账号，并同意将以下信息跨境传输：')
                .fontSize(12.5).fontColor(INK).lineHeight(18).width('100%')
              this.consentTransferBullet('传输内容', '华为账号标识（经不可逆脱敏）、兑换信息及兑换权益记录')
              this.consentTransferBullet('接收方', '开发者服务器（位于中国香港特别行政区）')
              this.consentTransferBullet('用途', '核实账号、发放和恢复兑换权益')
              Text('购买与恢复购买由手机直接与华为应用内支付完成，不经过该服务器，无需此项同意。')
                .fontSize(11.5).fontColor('#5D574F').lineHeight(17).width('100%')
              Text('如不同意：仅无法使用口令兑换，不影响购买、节拍练习、组队和录制。')
                .fontSize(11.5).fontColor('#5D574F').lineHeight(17).width('100%')
              Text('详见《隐私声明》第四部分 ›')
                .fontSize(12).fontWeight(700).fontColor(CORAL)
                .onClick(() => this.viewPrivacyFromConsent())
            }.width('100%')
          }.width('100%').constraintSize({ maxHeight: 280 }).scrollBar(BarState.Off)
          Row({ space: 10 }) {
            ActionButton({
              label: '不同意', active: true, controlHeight: 44, labelSize: 13, labelWeight: 900,
              fill: PAPER, labelColor: INK, contentPadding: { left: 16, right: 16 }, lineWidth: 1.5, cornerRadius: 5,
              hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
              action: () => this.resolveCrossBorderConsent(false)
            }).layoutWeight(1)
            ActionButton({
              label: '同意', active: true, controlHeight: 44, labelSize: 13, labelWeight: 900,
              fill: CORAL, labelColor: WHITE, contentPadding: { left: 16, right: 16 }, lineWidth: 1.5, cornerRadius: 5,
              hardShadow: { offsetX: COMIC_CONTROL_INK_OFFSET, offsetY: COMIC_CONTROL_INK_OFFSET, color: INK },
              action: () => this.resolveCrossBorderConsent(true)
            }).layoutWeight(1)
          }.width('100%')
        }
        .width('100%')
        .padding(22)
        }
      }
      .width('88%').constraintSize({ maxWidth: 360 })
    }
    .width('100%').height('100%').backgroundColor('#77000000').zIndex(110)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 14 }) {
          Row() {
            Text('‹').fontSize(32).width(32).onClick(() => router.back())
            Text('奇遇小铺').fontSize(32).fontWeight(900).fontStyle(FontStyle.Italic)
            Blank()
            if (this.redemptionEntranceVisible()) {
              this.redemptionEntrance()
            } else {
              Row().width(REDEMPTION_ENTRANCE_WIDTH).height(REDEMPTION_ENTRANCE_HEIGHT)
            }
          }.width('100%').alignItems(VerticalAlign.Center)
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
                if (this.keepsScene(item.key)) {
                  this.sceneCard(item)
                }
              }, (item: StoreScene) => this.storeOfferRenderKey('owned-scene', item.key, item.productId))
            }
            this.restorePurchasesAction()
            if (this.storeActionType === 'restore' && !this.purchaseVisible && this.storeActionStatus.length > 0) {
              Text(this.storeActionStatus).fontSize(12).fontWeight(FontWeight.Bold).width('100%')
            }
            this.accountDeletionEntry()
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
      if (this.crossBorderConsentVisible) {
        this.crossBorderConsentDialog()
      }
      if (this.accountDeletionDialogStep > 0) {
        this.accountDeletionDialog()
      }
    }.width('100%').height('100%').backgroundColor(PAPER)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((_old: Area, area: Area) => {
      const height = Number(area.height);
      if (Number.isFinite(height) && height > 0 && height !== this.storeViewportHeight) {
        this.storeViewportHeight = height;
      }
    })
  }
}
