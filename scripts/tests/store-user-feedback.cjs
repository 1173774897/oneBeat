// Run with Node and the bundled typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/StorePage.ets'), 'utf8');
const feedbackSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/common/UserFeedback.ets'), 'utf8');
const accountSource = fs.readFileSync(path.join(root, 'entry/src/main/ets/store/HuaweiAccountService.ets'), 'utf8');
const productCopySource = fs.readFileSync(path.join(root, 'entry/src/main/ets/store/StoreProductCopy.ets'), 'utf8');

function compile(text) {
  const result = ts.transpileModule(text, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  return result.outputText;
}
// Keep every real business method and field initializer. Only ArkUI builders and
// component decorators are removed because they require the device UI runtime.
const businessSource = source.slice(0, source.indexOf('  @Builder\n  private redemptionCard()'))
  .replace('@Entry\n@Component\nstruct StorePage {', 'export class StorePage {')
  .replace(/@StorageLink\([^)]*\)\s*/g, '').replace(/@State\s+/g, '') + '\n}';
const compiledPage = compile(businessSource);
const compiledFeedback = compile(feedbackSource);
const compiledAccount = compile(accountSource);
const productCopy = { exports: {} };
vm.runInNewContext(compile(productCopySource), productCopy);

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function flush() {
  for (let i = 0; i < 30; i++) await Promise.resolve();
}
function bootstrap(pass = {}) {
  return {
    serverTime: '2026-10-16T00:00:00Z', configVersion: 'test',
    pass: { active: false, source: '', status: '', autoRenewing: false, iapPurchaseAllowed: true, ...pass },
    items: [], redemption: { available: true }
  };
}
const receipt = { productId: 'onebeat.character.cloud', purchaseData: 'synthetic-receipt', idempotencyKey: 'synthetic-order' };
const cloud = { key: 'cloud', name: '云行者', productId: receipt.productId };
const scene = { key: 'neon_street', name: '霓虹街口', productId: 'onebeat.scene.neon_street' };

function harness(options = {}) {
  const notices = [], logs = [], trace = [], redemptions = [], storage = new Map();
  const scrolls = [];
  let uuid = 0;
  let latest = options.bootstrap ?? bootstrap();
  const appStorage = { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) };
  function apply(value) {
    latest = value;
    const pass = value.pass;
    for (const [key, item] of Object.entries({
      storePassActive: pass.active, storePassStatus: pass.status ?? '',
      storePassExpiresAt: pass.expiresAt ?? '', storePassSource: pass.source ?? '',
      storePassAutoRenewing: pass.autoRenewing, storePassIapPurchaseAllowed: pass.iapPurchaseAllowed,
      storeRedemptionAvailable: true
    })) storage.set(key, item);
  }
  const logger = { info() {}, warn: text => logs.push(text), error: text => logs.push(text) };
  const feedback = { exports: {}, console: logger, require(name) {
    if (name === '@kit.ArkUI') return { promptAction: { showToast: value => notices.push(value.message) } };
    if (name === './MonotonicClock') return { MonotonicClock: { nowMs: () => 1000 } };
    throw new Error('Unexpected feedback dependency ' + name);
  }};
  vm.runInNewContext(compiledFeedback, feedback);
  const api = {
    // Paid purchases never reach this API (on-device since 2026-11-03).
    async deleteStoreAccount() { trace.push('delete-account'); return options.deleteAccount ? options.deleteAccount() : '2026-11-03T00:00:00Z'; },
    async fetchStoreBootstrap() { trace.push('bootstrap'); return options.fetch ? options.fetch() : latest; },
    async redeemStoreCode(_token, request) {
      trace.push('redeem'); redemptions.push({ ...request });
      if (options.redeem) return options.redeem(request);
      latest = bootstrap({ active: true, source: 'PASS_REDEMPTION', expiresAt: '2026-11-16T00:00:00Z' });
      return { pass: latest.pass, grantEndsAt: '2026-11-16T00:00:00Z' };
    }
  };
  const mocks = {
    '../components/ComicInkSurface': { COMIC_CARD_INK_OFFSET: 4, COMIC_CONTROL_INK_OFFSET: 2 },
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'synthetic-uuid-' + ++uuid } },
    '@kit.ArkUI': { router: {} },
    '../common/UserFeedback': feedback.exports,
    '../store/StoreProductCopy': productCopy.exports,
    '../store/StoreApi': api,
    '../store/StoreApiConfig': { isStoreApiConfigured: () => true },
    '../store/EntitlementStore': {
      initializeEntitlementCache() {}, applyStoreBootstrap: apply,
      limitedFreeCharacterKeys: () => [], ownedCharacterKeys: () => options.ownedCharacters ?? [],
      ownedSceneKeys: () => options.ownedScenes ?? ['sunset_coast', 'neon_street'],
      storeItemAccessReason: key => options.accessReason ? options.accessReason(key) : '',
      isHuaweiPassActive: () => options.huaweiPass === true
    },
    '../store/IapEntitlements': {
      async refreshLocalIapEntitlements() {
        trace.push('iap-query');
        return options.query ? options.query() :
          { ownedItemCount: 0, passActive: false, finishedCount: 0, rejectedCount: 0 };
      }
    },
    '../store/IapCatalogService': {
      queryStoreProductPrices: async () => ({ prices: [], unavailableReason: 'none' }),
      emptyStoreProductPriceQueryResult: unavailableReason => ({ prices: [], unavailableReason }),
      storePriceUnavailableMessage: () => '商品价格暂时不可用，请检查网络后重试'
    },
    // The consent gate itself is covered by store-cross-border-consent.cjs.
    '../store/CrossBorderConsent': { setCrossBorderConsentPrompter() {}, hasCrossBorderConsent: () => options.consented !== false,
      async revokeCrossBorderConsent() { trace.push('revoke-consent'); } },
    '../store/HuaweiAccountService': {
      clearStoreSession() { trace.push('clear-session'); }, currentStoreSessionToken: () => 'synthetic-session',
      async ensureStoreSession() {
        trace.push('login');
        if (options.login) return options.login();
        return 'synthetic-session';
      }
    },
    '../store/IapPurchaseService': {
      productTypeForStoreItem: pass => pass ? 'subscription' : 'nonconsumable',
      async purchaseStoreProduct(_context, productId, productType) {
        trace.push('checkout:' + productId);
        const result = options.purchase ? await options.purchase(productId, productType) : receipt;
        trace.push('delivered:' + productId);
        return result;
      }
    }
  };
  const context = { exports: {}, Error, console: logger, AppStorage: appStorage,
    Scroller: class { scrollEdge(edge) { scrolls.push(edge); } }, Edge: { Top: 0 },
    TextInputController: class { stopEditing() { trace.push('keyboard-closed'); } }, require(name) {
    assert.ok(Object.hasOwn(mocks, name), 'Unexpected page dependency ' + name);
    return mocks[name];
  }};
  vm.runInNewContext(compiledPage, context);
  apply(latest);
  const page = new context.exports.StorePage();
  page.getUIContext = () => ({ getHostContext: () => ({}) });
  page.aboutToAppear();
  return { page, notices, logs, trace, redemptions, scrolls, apply };
}

(async () => {
  const paidProducts = ['cloud', 'teapot', 'wave', 'mismatch', 'scooter', 'lilroll', 'lamp']
    .map(key => 'onebeat.character.' + key).concat(['onebeat.scene.neon_street', 'onebeat.pass.monthly']);
  for (const productId of paidProducts) {
    const introduction = productCopy.exports.storeProductIntroduction(productId);
    assert.ok(introduction.trim().length > 0, productId + ' must provide its paid-product introduction');
    assert.ok(Array.from(introduction).length <= 100, productId + ' introduction must stay within 100 characters');
  }
  for (const productId of ['', 'onebeat.character.unknown', 'onebeat.scene.unknown', 'onebeat.pass.unknown']) {
    assert.equal(productCopy.exports.storeProductIntroduction(productId), '',
      'Unknown products must not display the story of another product');
  }

  const measuredIntroduction = harness();
  measuredIntroduction.page.openCharacterPurchase(cloud);
  let fullTextHeight = 88;
  const nativeMeasurement = { measureTextSize(options) {
    return { width: 300, height: options.maxLines === undefined ? fullTextHeight : 44 };
  } };
  measuredIntroduction.page.getUIContext = () => ({ getMeasureUtils: () => nativeMeasurement });
  measuredIntroduction.page.updatePurchaseIntroOverflow(300);
  assert.equal(measuredIntroduction.page.purchaseIntroOverflow, true,
    'A story taller than its folded native text layout must expose its detail action');
  fullTextHeight = 44;
  measuredIntroduction.page.updatePurchaseIntroOverflow(300);
  assert.equal(measuredIntroduction.page.purchaseIntroOverflow, false,
    'A story that fits the folded native text layout must not show an unnecessary detail action');
  fullTextHeight = 0;
  measuredIntroduction.page.updatePurchaseIntroOverflow(300);
  assert.equal(measuredIntroduction.page.purchaseIntroOverflow, true,
    'An empty native measurement for non-empty copy must not hide the full story');
  measuredIntroduction.page.getUIContext = () => ({ getMeasureUtils() { throw new Error('native measurement unavailable'); } });
  measuredIntroduction.page.updatePurchaseIntroOverflow(300);
  assert.equal(measuredIntroduction.page.purchaseIntroOverflow, true,
    'A native measurement failure must leave the full story accessible');
  measuredIntroduction.page.updatePurchaseIntroOverflow(0);
  assert.equal(measuredIntroduction.page.purchaseIntroOverflow, false, 'An unmeasured width must not retain another layout result');

  const details = harness();
  details.page.purchaseIntroOverflow = true;
  details.page.expandPurchaseIntroduction();
  assert.equal(details.page.purchaseIntroExpanded, false, 'A hidden purchase plan cannot expand its introduction');
  assert.equal(details.page.purchaseIntroAnchorPinned, false, 'An unavailable expansion must not pin the dialog layout');
  details.page.openCharacterPurchase(cloud);
  assert.equal(details.page.purchaseIntroOverflow, false, 'Opening a product discards the previous text measurement');
  assert.equal(details.page.pendingIntroduction(), productCopy.exports.storeProductIntroduction(cloud.productId));
  details.page.expandPurchaseIntroduction();
  assert.equal(details.page.purchaseIntroExpanded, false, 'A fitting introduction needs no expansion');
  details.page.purchaseIntroOverflow = true;
  details.scrolls.length = 0;
  details.page.expandPurchaseIntroduction();
  assert.equal(details.page.purchaseIntroExpanded, true);
  assert.equal(details.page.purchaseIntroAnchorPinned, true, 'The first expansion pins the existing header anchor');
  assert.deepEqual(details.scrolls, [], 'Expanding the introduction must preserve the current scroll position');
  const selectedProduct = [details.page.pendingProductId, details.page.pendingPrice];
  details.page.onBackPress();
  assert.equal(details.page.purchaseIntroExpanded, false, 'Back first collapses the inline introduction');
  assert.equal(details.page.purchaseIntroAnchorPinned, true, 'Collapsing must retain the pinned header rather than recenter');
  assert.equal(details.page.purchaseVisible, true, 'Collapsing the story must preserve the purchase plan');
  assert.deepEqual([details.page.pendingProductId, details.page.pendingPrice], selectedProduct);
  assert.deepEqual(details.scrolls, [], 'Collapsing the introduction must not jump to the top');
  assert.equal(details.trace.length, 0, 'Reading an introduction must not request login, checkout or store APIs');

  const anchoredIntroduction = harness();
  anchoredIntroduction.page.openCharacterPurchase(cloud);
  anchoredIntroduction.page.topSafeInset = 24;
  assert.equal(anchoredIntroduction.page.purchaseDialogTopPadding(), 44,
    'A collapsed introduction keeps the normal safe-area top clearance');
  anchoredIntroduction.page.updatePurchaseDialogAnchor(128);
  anchoredIntroduction.page.purchaseIntroOverflow = true;
  anchoredIntroduction.page.expandPurchaseIntroduction();
  assert.equal(anchoredIntroduction.page.purchaseDialogTopPadding(), 128,
    'Expanded text must grow below the original dialog top rather than recenter the header');
  anchoredIntroduction.page.updatePurchaseDialogAnchor(82);
  assert.equal(anchoredIntroduction.page.purchaseIntroAnchorTop, 128,
    'An expanded layout must not replace its original header anchor with a shifted measurement');
  anchoredIntroduction.page.topSafeInset = 140;
  assert.equal(anchoredIntroduction.page.purchaseDialogTopPadding(), 160,
    'A changed system safe area must take precedence over an earlier header anchor');
  anchoredIntroduction.page.topSafeInset = 24;
  anchoredIntroduction.page.collapsePurchaseIntroduction();
  assert.equal(anchoredIntroduction.page.purchaseIntroAnchorPinned, true,
    'The dialog remains pinned after its introduction collapses');
  assert.equal(anchoredIntroduction.page.purchaseDialogTopPadding(), 128,
    'Collapsing text keeps the same header top instead of restoring centered layout');
  anchoredIntroduction.page.updatePurchaseDialogAnchor(82);
  assert.equal(anchoredIntroduction.page.purchaseIntroAnchorTop, 128,
    'A collapsed measurement cannot replace the anchor once the dialog has been pinned');
  anchoredIntroduction.page.expandPurchaseIntroduction();
  anchoredIntroduction.page.collapsePurchaseIntroduction();
  assert.equal(anchoredIntroduction.page.purchaseDialogTopPadding(), 128,
    'Repeated expand/collapse cycles keep the original header position');
  assert.deepEqual(anchoredIntroduction.scrolls, [],
    'Repeated expand/collapse cycles must not request a scroll reset');
  anchoredIntroduction.page.openScenePurchase(scene);
  assert.equal(anchoredIntroduction.page.purchaseIntroAnchorPinned, false,
    'Selecting a new product releases the previous header anchor');
  anchoredIntroduction.page.updatePurchaseDialogAnchor(176);
  assert.equal(anchoredIntroduction.page.purchaseIntroAnchorTop, 176,
    'The new product can establish its own expansion anchor');
  anchoredIntroduction.page.purchaseIntroOverflow = true;
  anchoredIntroduction.page.expandPurchaseIntroduction();
  assert.equal(anchoredIntroduction.page.purchaseDialogTopPadding(), 176,
    'The next product pins its own measured top rather than the earlier product position');

  for (const openProduct of [page => page.openScenePurchase(scene), page => page.openPassPurchase(),
    page => page.openCharacterPurchase(cloud)]) {
    details.page.purchaseIntroExpanded = true;
    details.page.purchaseIntroAnchorPinned = true;
    details.page.purchaseIntroOverflow = true;
    openProduct(details.page);
    assert.equal(details.page.purchaseIntroExpanded, false, 'A newly opened product starts at purchase confirmation');
    assert.equal(details.page.purchaseIntroAnchorPinned, false, 'A newly opened product starts with a fresh centered layout');
    assert.equal(details.page.purchaseIntroOverflow, false, 'A new product must measure its own introduction');
    assert.equal(details.page.pendingIntroduction(), productCopy.exports.storeProductIntroduction(details.page.pendingProductId));
  }

  const emptyDetails = harness();
  emptyDetails.page.openCharacterPurchase({ key: 'unknown', name: 'Unknown', productId: 'onebeat.character.unknown' });
  emptyDetails.page.purchaseIntroOverflow = true;
  emptyDetails.page.expandPurchaseIntroduction();
  assert.equal(emptyDetails.page.purchaseIntroExpanded, false, 'An empty introduction must not expose an empty expanded state');
  assert.equal(emptyDetails.page.purchaseIntroAnchorPinned, false, 'Empty copy must not pin the dialog');

  const busyDetails = harness();
  busyDetails.page.openCharacterPurchase(cloud);
  busyDetails.page.purchaseIntroOverflow = true;
  busyDetails.page.purchaseBusy = true;
  busyDetails.page.expandPurchaseIntroduction();
  assert.equal(busyDetails.page.purchaseIntroExpanded, false, 'Checkout must not expand the introduction');
  assert.equal(busyDetails.page.purchaseIntroAnchorPinned, false, 'Checkout must not change the header positioning mode');
  busyDetails.page.purchaseBusy = false;
  busyDetails.page.expandPurchaseIntroduction();
  busyDetails.page.purchaseBusy = true;
  busyDetails.page.collapsePurchaseIntroduction();
  busyDetails.page.onBackPress();
  assert.equal(busyDetails.page.purchaseIntroExpanded, true, 'Checkout must preserve the current expansion state');
  assert.equal(busyDetails.page.purchaseVisible, true, 'Checkout must not close the purchase surface');
  busyDetails.page.purchaseBusy = false;
  busyDetails.scrolls.length = 0;
  busyDetails.page.collapsePurchaseIntroduction();
  assert.equal(busyDetails.page.purchaseIntroExpanded, false);
  assert.deepEqual(busyDetails.scrolls, [], 'The inline collapse control must not request a scroll reset');

  const nestedDetails = harness();
  nestedDetails.page.openPassPurchase();
  nestedDetails.page.purchaseIntroOverflow = true;
  nestedDetails.page.expandPurchaseIntroduction();
  nestedDetails.page.openDrumIntro();
  assert.equal(nestedDetails.page.drumIntroVisible, true);
  nestedDetails.page.onBackPress();
  assert.equal(nestedDetails.page.drumIntroVisible, false, 'Back closes the drum comic before collapsing the story');
  assert.equal(nestedDetails.page.purchaseIntroExpanded, true);
  nestedDetails.page.onBackPress();
  assert.equal(nestedDetails.page.purchaseIntroExpanded, false, 'The next Back collapses the inline introduction');
  assert.equal(nestedDetails.page.purchaseVisible, true);
  nestedDetails.page.onBackPress();
  assert.equal(nestedDetails.page.purchaseVisible, false, 'Only the final Back dismisses purchase confirmation');
  assert.deepEqual(nestedDetails.trace, [], 'Nested feature and story previews are read-only');

  const restoreQuery = deferred();
  const restoringDetails = harness({ query: () => restoreQuery.promise });
  restoringDetails.page.openCharacterPurchase(cloud);
  restoringDetails.page.purchaseIntroOverflow = true;
  restoringDetails.page.expandPurchaseIntroduction();
  const restoringFromDetails = restoringDetails.page.restorePurchases();
  assert.equal(restoringDetails.page.storeActionType, 'restore');
  assert.equal(restoringDetails.page.purchaseIntroExpanded, false, 'Restoring purchases clears the old introduction expansion');
  assert.equal(restoringDetails.page.purchaseIntroAnchorPinned, false, 'Restoring purchases releases the old product header anchor');
  assert.equal(restoringDetails.page.purchaseIntroOverflow, false);
  assert.equal(restoringDetails.page.pendingIntroduction(), '', 'Restore feedback must not show the previous product story');
  restoreQuery.resolve({ ownedItemCount: 0, passActive: false, finishedCount: 0, rejectedCount: 0 });
  await restoringFromDetails;
  restoringDetails.page.purchaseIntroOverflow = true;
  restoringDetails.page.expandPurchaseIntroduction();
  assert.equal(restoringDetails.page.purchaseIntroExpanded, false, 'Restore results cannot expand an old product introduction');

  const intro = harness();
  intro.page.openDrumIntro();
  assert.equal(intro.page.drumIntroVisible, false, 'Feature preview only opens from a visible pass plan');
  intro.page.openPassPurchase();
  const plan = [intro.page.pendingProductId, intro.page.pendingPrice];
  intro.page.openDrumIntro();
  assert.equal(intro.page.drumIntroVisible, true);
  assert.equal(intro.page.onBackPress(), true);
  assert.equal(intro.page.drumIntroVisible, false, 'First Back closes the comic, not its underlying purchase plan');
  assert.equal(intro.page.purchaseVisible, true);
  assert.deepEqual([intro.page.pendingProductId, intro.page.pendingPrice], plan, 'Preview preserves plan context');
  intro.page.openDrumIntro();
  intro.page.closeDrumIntro();
  assert.equal(intro.page.purchaseVisible, true, 'The close control returns to the same plan');
  intro.page.purchaseBusy = true;
  intro.page.openDrumIntro();
  assert.equal(intro.page.drumIntroVisible, false, 'Do not overlay an in-flight checkout');
  intro.page.purchaseBusy = false;
  assert.equal(intro.page.onBackPress(), true);
  assert.equal(intro.page.purchaseVisible, false, 'Second Back retains ordinary plan dismissal');
  assert.equal(intro.trace.length, 0, 'Viewing comic art never starts login, checkout or store API calls');

  const selection = harness();
  selection.page.selectScene(scene);
  assert.equal(selection.page.selectedSceneKey, scene.key);
  assert.equal(selection.notices.length, 0, 'Scene selection is already visible on its card');

  for (const code of [1001860000, 1001502012]) {
    const cancel = { code, message: 'synthetic native cancellation' };
    const h = harness({ purchase: async () => { throw cancel; } });
    h.page.openCharacterPurchase(cloud);
    await h.page.confirmPurchase();
    assert.equal(h.page.storeActionStatus, '');
    assert.equal(h.page.purchaseVisible, false);
    assert.equal(h.page.purchaseBusy, false);
    assert.equal(h.notices.length + h.logs.length, 0, 'Verified cancellation is silent');
  }
  const failure = harness({ purchase: async () => { throw { code: 1001860001, message: 'cancelled synthetic-private-payload' }; } });
  failure.page.openCharacterPurchase(cloud);
  await failure.page.confirmPurchase();
  assert.equal(failure.page.purchaseVisible, true, 'Failure remains visible at the purchase action');
  assert.equal(failure.page.storeActionRecovery, 'purchase');
  assert.match(failure.page.storeActionStatus, /购买未完成/);
  assert.equal(failure.notices.length, 0, 'Inline purchase failure has no duplicate toast');
  assert.equal(failure.logs.length, 1);
  assert.doesNotMatch(failure.logs.join('') + failure.page.storeActionStatus, /synthetic-private-payload|cancelled/);

  const success = harness();
  success.page.openCharacterPurchase(cloud);
  await success.page.confirmPurchase();
  assert.deepEqual(success.notices, ['购买成功，权益已到账']);
  assert.equal(success.page.storeActionStatus, '');
  assert.equal(success.page.purchaseVisible, false);
  assert.deepEqual(success.trace, ['checkout:onebeat.character.cloud', 'delivered:onebeat.character.cloud'],
    'Buying needs no Store login, consent or server request; delivery happens on the device');

  const owned = harness({ purchase: async () => { throw { code: 1001860051, message: 'synthetic already owned' }; },
    accessReason: key => key === 'character.cloud' ? 'IAP_PURCHASE' : 'LOCKED' });
  owned.page.openCharacterPurchase(cloud);
  await owned.page.confirmPurchase();
  assert.deepEqual(owned.notices, ['已同步华为账号中的购买记录']);
  assert.ok(owned.trace.includes('iap-query') && !owned.trace.includes('login'),
    'An already-owned item is re-read from Huawei, not from the server');
  const ownedElsewhere = harness({ purchase: async () => { throw { code: 1001860051 }; }, accessReason: () => 'LOCKED' });
  ownedElsewhere.page.openCharacterPurchase(cloud);
  await ownedElsewhere.page.confirmPurchase();
  assert.match(ownedElsewhere.page.storeActionStatus, /恢复购买/);

  const freshRestriction = harness({ bootstrap: bootstrap({ active: true, source: 'PASS_REDEMPTION',
    expiresAt: '2026-11-16T00:00:00Z', iapPurchaseAllowed: false }) });
  freshRestriction.page.openPassPurchase();
  await freshRestriction.page.confirmPurchase();
  assert.equal(freshRestriction.trace.some(item => item.startsWith('checkout:')), false,
    'A live gift pass blocks buying the Huawei pass');
  assert.equal(freshRestriction.page.purchaseVisible, true);
  assert.match(freshRestriction.page.passPurchaseRestriction(), /赠送月卡/);
  assert.match(freshRestriction.page.passDescription(), /2026-11-16/);
  assert.equal(freshRestriction.notices.length, 0);

  const native = deferred();
  const concurrent = harness({ purchase: () => native.promise });
  concurrent.page.openCharacterPurchase(cloud);
  const buying = concurrent.page.confirmPurchase();
  await flush();
  concurrent.page.openScenePurchase(scene);
  concurrent.page.openPassPurchase();
  concurrent.page.redemptionCode = 'synthetic-secret';
  await concurrent.page.submitRedemption();
  await concurrent.page.restorePurchases();
  await concurrent.page.confirmPurchase();
  assert.equal(concurrent.page.pendingProductId, cloud.productId, 'In-flight product selection cannot mutate');
  assert.equal(concurrent.trace.filter(item => item.startsWith('checkout:')).length, 1);
  assert.equal(concurrent.redemptions.length, 0);
  concurrent.page.onBackPress();
  assert.equal(concurrent.page.purchaseVisible, true, 'In-flight feedback cannot be closed accidentally');
  concurrent.page.aboutToDisappear();
  native.resolve(receipt);
  await buying;
  assert.ok(concurrent.trace.includes('delivered:' + cloud.productId),
    'A completed paid order is still delivered after the page leaves');
  assert.equal(concurrent.notices.length, 0, 'A destroyed page must not emit a late purchase toast');
  assert.equal(concurrent.page.storeActionStatus, '正在完成购买…', 'A destroyed page is not mutated by completion');

  // No redemption entrance while any pass is active; it reappears when it ends.
  assert.equal(harness().page.redemptionEntranceVisible(), true);
  const giftMember = harness({ bootstrap: bootstrap({ active: true, source: 'PASS_REDEMPTION',
    expiresAt: '2026-11-16T00:00:00Z' }) });
  assert.equal(giftMember.page.redemptionEntranceVisible(), false, 'A gift pass hides the redemption entrance');
  const paidMember = harness({ bootstrap: bootstrap({ active: true, source: 'PASS_IAP', status: 'ACTIVE' }) });
  assert.equal(paidMember.page.redemptionEntranceVisible(), false, 'A Huawei pass hides the redemption entrance');
  paidMember.apply(bootstrap());
  paidMember.page.loadPurchases();
  assert.equal(paidMember.page.redemptionEntranceVisible(), true, 'The entrance returns once the pass ends');

  // The consent dialog and Huawei sign-in run inside ensureStoreSession. The
  // centred redemption page must not change height meanwhile: a status line
  // added then and cleared on decline made it jump up, then drop.
  const pendingLogin = deferred();
  const consenting = harness({ login: () => pendingLogin.promise });
  consenting.page.redemptionCode = 'synthetic-secret';
  const consentRun = consenting.page.submitRedemption();
  await flush();
  assert.equal(consenting.page.redemptionBusy, true);
  assert.equal(consenting.page.redemptionStatus, '', 'No status line while consent or sign-in is open');
  pendingLogin.reject(Object.assign(new Error('declined'), { code: 2026110301 }));
  await consentRun;
  assert.equal(consenting.page.redemptionStatus, '', 'Declining leaves the page exactly as it was');

  // 「我的」 keeps only what stays: bought or free by default. Limited-free and
  // pass access are usable but stay out of it.
  const reasons = {
    'character.cloud': 'IAP_PURCHASE', 'character.lamp': 'LIMITED_FREE', 'character.wave': 'PASS_IAP',
    'character.teapot': 'PASS_REDEMPTION', 'scene.sunset_coast': 'DEFAULT_FREE', 'scene.neon_street': 'LIMITED_FREE'
  };
  const mine = harness({ ownedCharacters: ['cloud', 'lamp', 'wave', 'teapot'],
    ownedScenes: ['sunset_coast', 'neon_street'], accessReason: key => reasons[key] ?? 'LOCKED' });
  mine.page.loadPurchases();
  assert.deepEqual(Array.from(mine.page.keptCharacters), ['cloud'], 'Only the bought character is listed in 「我的」');
  assert.deepEqual(Array.from(mine.page.keptScenes), ['sunset_coast'], 'Limited-free scenes stay out of 「我的」');
  assert.equal(mine.page.hasCharacter('lamp'), true, 'A limited-free character is still usable');
  assert.equal(mine.page.ownedExclusiveCharacterCount(), 1);
  assert.equal(mine.page.ownedSceneCount(), 1);

  const huaweiMember = harness({ huaweiPass: true });
  huaweiMember.page.redemptionCode = 'synthetic-secret';
  await huaweiMember.page.submitRedemption();
  assert.equal(huaweiMember.page.redemptionStatus, '华为自动续费月卡仍在生效，暂时不能领取赠送月卡');
  assert.equal(huaweiMember.redemptions.length, 0, 'The client blocks a gift pass while a Huawei pass is live');
  assert.ok(huaweiMember.trace.indexOf('iap-query') > huaweiMember.trace.indexOf('login'),
    'Redemption still signs in, then re-checks Huawei before redeeming');
  assert.equal(huaweiMember.trace[0], 'keyboard-closed',
    'The keyboard closes before sign-in or consent, so leaving for the privacy statement cannot drop the page');

  const redeemed = harness();
  redeemed.page.redemptionCode = 'synthetic-secret';
  await redeemed.page.submitRedemption();
  assert.match(redeemed.page.redemptionStatus, /已兑换 · 有效至 2026-11-16/);
  assert.equal(redeemed.page.redemptionCode, '');
  assert.equal(redeemed.page.redemptionIdempotencyKey, '');
  assert.equal(redeemed.page.redemptionSucceeded, true);
  assert.equal(redeemed.notices.length + redeemed.logs.length, 0);
  const completedKey = redeemed.redemptions[0].idempotencyKey;
  redeemed.page.startAnotherRedemption();
  assert.equal(redeemed.page.redemptionSucceeded, false, 'A deliberate new-code action restores the form');
  assert.equal(redeemed.page.redemptionStatus, '');
  redeemed.page.updateRedemptionCode('synthetic-other-code');
  await redeemed.page.submitRedemption();
  assert.equal(redeemed.redemptions.length, 2, 'The same shop visit must still support another campaign');
  assert.notEqual(redeemed.redemptions[1].idempotencyKey, completedKey, 'A new redemption gets its own retry identity');

  const delayedSnapshot = deferred();
  const immediate = harness({ fetch: () => delayedSnapshot.promise });
  immediate.page.redemptionVisible = true;
  immediate.page.redemptionCode = 'synthetic-secret';
  const pendingRefresh = immediate.page.submitRedemption();
  await flush();
  assert.equal(immediate.page.redemptionSucceeded, true,
    'A committed redemption must become visible before the follow-up catalog request finishes');
  assert.match(immediate.page.redemptionStatus, /有效至 2026-11-16/);
  immediate.page.startAnotherRedemption();
  assert.equal(immediate.page.redemptionSucceeded, true, 'Pending refresh must retain the committed result');
  immediate.page.updateRedemptionCode('');
  assert.match(immediate.page.redemptionStatus, /已兑换/,
    'The callback from programmatically clearing/removing the input cannot erase success');
  assert.equal(immediate.page.onBackPress(), true);
  assert.equal(immediate.page.redemptionVisible, false,
    'A successful result can be closed while the item-rights refresh is still pending');
  delayedSnapshot.resolve(bootstrap({ active: true, source: 'PASS_REDEMPTION', expiresAt: '2026-11-16T00:00:00Z' }));
  await pendingRefresh;

  let refreshAttempts = 0;
  const refreshFailure = harness({ fetch: async () => {
    if (++refreshAttempts === 1) throw new Error('synthetic-secret');
    return bootstrap({ active: true, source: 'PASS_REDEMPTION', expiresAt: '2026-11-16T00:00:00Z' });
  }});
  refreshFailure.page.redemptionCode = 'synthetic-secret';
  await refreshFailure.page.submitRedemption();
  assert.equal(refreshFailure.page.redemptionSucceeded, true);
  assert.equal(refreshFailure.page.passActive, true, 'The committed pass response is visible even when item refresh fails');
  assert.equal(refreshFailure.page.redemptionSyncFailed, true);
  assert.match(refreshFailure.page.redemptionStatus, /已兑换 · 有效至/);
  assert.equal(refreshFailure.page.redemptionBusy, false);
  assert.equal(refreshFailure.page.redemptionIdempotencyKey, '');
  await refreshFailure.page.submitRedemption();
  assert.equal(refreshFailure.redemptions.length, 1, 'A known successful operation must not be redeemed twice');
  await refreshFailure.page.retryRedemptionEntitlements();
  assert.equal(refreshFailure.page.redemptionSyncFailed, false);
  assert.equal(refreshAttempts, 2);
  assert.equal(refreshFailure.redemptions.length, 1, 'Retrying item sync must never repeat the redemption POST');
  assert.doesNotMatch(refreshFailure.logs.join(''), /synthetic-secret/);
  assert.equal(refreshFailure.notices.length, 0, 'The persistent result card is the sole success feedback');

  const noSnapshot = harness({ fetch: async () => null });
  noSnapshot.page.redemptionCode = 'synthetic-secret';
  await noSnapshot.page.submitRedemption();
  assert.equal(noSnapshot.page.redemptionSucceeded, true);
  assert.equal(noSnapshot.page.redemptionSyncFailed, true);

  const stackedPass = harness({ redeem: async () => ({
    pass: bootstrap({ active: true, source: 'PASS_REDEMPTION', expiresAt: '2026-12-16T00:00:00Z' }).pass,
    grantEndsAt: '2026-11-16T00:00:00Z'
  }), fetch: async () => { throw new Error('offline'); } });
  stackedPass.page.redemptionCode = 'synthetic-secret';
  await stackedPass.page.submitRedemption();
  assert.match(stackedPass.page.redemptionStatus, /有效至 2026-12-16/,
    'A stacked monthly pass must show the total expiry, not just the latest grant end');

  let redeemAttempt = 0;
  const redemptionFailure = harness({ redeem: async () => {
    if (redeemAttempt++ === 0) throw { code: 0, message: 'synthetic-secret' };
    throw new Error('口令不正确或活动已结束');
  }});
  redemptionFailure.page.redemptionCode = 'synthetic-secret';
  await redemptionFailure.page.submitRedemption();
  const retryKey = redemptionFailure.page.redemptionIdempotencyKey;
  assert.ok(retryKey.length > 0);
  redemptionFailure.page.updateRedemptionCode('synthetic-secret');
  assert.equal(redemptionFailure.page.redemptionIdempotencyKey, retryKey,
    'A same-value native callback cannot discard the retry identity after an uncertain POST');
  assert.match(redemptionFailure.page.redemptionStatus, /兑换未完成/);
  await redemptionFailure.page.submitRedemption();
  assert.equal(redemptionFailure.redemptions[1].idempotencyKey, retryKey, 'Transport retry reuses the redemption operation');
  assert.equal(redemptionFailure.page.redemptionStatus, '口令不正确或活动已结束');
  assert.equal(redemptionFailure.notices.length, 0);
  assert.doesNotMatch(redemptionFailure.logs.join('') + redemptionFailure.page.redemptionStatus, /synthetic-secret/);
  redemptionFailure.page.updateRedemptionCode('synthetic-new-secret');
  assert.equal(redemptionFailure.page.redemptionIdempotencyKey, '', 'A deliberate code edit begins a new operation');
  assert.equal(redemptionFailure.page.redemptionStatus, '');

  const restored = harness({ query: async () => ({ ownedItemCount: 1, passActive: false, finishedCount: 0, rejectedCount: 0 }) });
  await restored.page.restorePurchases();
  assert.equal(restored.page.storeActionStatus, '已购权益已恢复');
  assert.equal(restored.page.storeActionRecovery, '');
  assert.equal(restored.notices.length, 0);
  assert.deepEqual(restored.trace, ['iap-query'], 'Restore is a Huawei query only: no login, no server');
  const noReceipts = harness();
  await noReceipts.page.restorePurchases();
  assert.equal(noReceipts.page.storeActionStatus, '当前华为账号没有可恢复的购买');
  const partialRestore = harness({ query: async () => ({ ownedItemCount: 1, passActive: false, finishedCount: 0, rejectedCount: 1 }) });
  await partialRestore.page.restorePurchases();
  assert.match(partialRestore.page.storeActionStatus, /部分购买记录未能核验/);
  assert.equal(partialRestore.page.storeActionRecovery, 'restore', 'Partial recovery retains a retry action');
  assert.equal(partialRestore.notices.length, 0);
  const restoreFailure = harness({ query: async () => { throw { code: 1001860001, message: 'synthetic-private-payload' }; } });
  await restoreFailure.page.restorePurchases();
  assert.match(restoreFailure.page.storeActionStatus, /恢复失败/);
  assert.equal(restoreFailure.page.storeActionRecovery, 'restore');
  assert.equal(restoreFailure.notices.length, 0);
  assert.doesNotMatch(restoreFailure.logs.join('') + restoreFailure.page.storeActionStatus, /synthetic-private-payload/);

  const nativeCancel = { code: 1001502012, message: 'synthetic native account cancellation' };
  const account = { exports: {}, AppStorage: { get: () => '' }, require(name) {
    if (name === '@kit.AccountKit') return { authentication: {
      HuaweiIDProvider: class { createLoginWithHuaweiIDRequest() { return {}; } },
      AuthenticationController: class { async executeRequest() { throw nativeCancel; } }
    }};
    if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'synthetic-login-state' } };
    if (name === './StoreApi') return {};
    if (name === './StoreBootstrapRefresh') return {};
    if (name === './StoreSessionPersistence') return {};
    // Consent already given: this case checks the native cancellation path.
    if (name === './CrossBorderConsent') return { ensureCrossBorderConsent: async () => {}, hasCrossBorderConsent: () => true };
    throw new Error('Unexpected account dependency ' + name);
  }};
  vm.runInNewContext(compiledAccount, account);
  await assert.rejects(account.exports.ensureStoreSession({}, true), error => error === nativeCancel,
    'The login adapter must preserve the native cancellation object and code');

  console.log('PASS: product stories preserve inline expansion anchors, scroll position, restore resets, busy guards and nested Back priority; actual store methods keep purchase/restore on the device without login, block gifts during a Huawei pass, immediate committed redemption results, isolated follow-up refresh/retry, input callback safety, silent SDK cancellation, retry identity and lifetime guards');
  // Online account deletion: an in-page dialog with two explicit steps, then
  // login, server deletion, session/consent reset and anonymous rights.
  const dialogSource = source.slice(source.indexOf('  accountDeletionDialog() {'),
    source.indexOf('  @Builder\n  crossBorderConsentDialog() {'));
  assert.match(dialogSource, /注销只影响通过活动口令兑换获得的权益，这部分在注销后再也无法找回/);
  assert.match(dialogSource, /已购买的角色、场景和华为自动续费月卡：不受影响/);
  assert.match(dialogSource, /注销不会停止续费/);
  assert.match(dialogSource, /再也无法找回，且注销无法撤销。已购商品/);
  assert.match(dialogSource, /if \(this\.accountDeletionWithoutLocalAccount\) \{\s*Text\('这台设备上没有需要清理的小铺数据。[^']*登录前会请你同意数据跨境传输。'\)/,
    'Without consent on record, the first step explains the consent step before it appears');
  assert.match(dialogSource, /if \(this\.accountDeletionWithoutLocalAccount\) \{\s*Text\('确认后会先请你同意数据跨境传输，再登录华为账号核实身份。'\)/);
  const crossDialog = source.slice(source.indexOf('  crossBorderConsentDialog() {'), source.indexOf('  build() {'));
  for (const style of ["fill: '#FFF1D7'", 'cornerRadius: 8', 'paperLineWidth: 2.5', '.fontSize(17).fontWeight(900)',
    ".width('88%').constraintSize({ maxWidth: 360 })", ".backgroundColor('#77000000').zIndex(110)"]) {
    assert.ok(dialogSource.includes(style) && crossDialog.includes(style), 'Deletion dialog keeps the shared dialog style: ' + style);
  }

  const openDialog = (consented, options = {}) => {
    const h = harness({ ...options, consented });
    h.page.openAccountDeletionDialog();
    assert.equal(h.page.accountDeletionDialogStep, 1);
    return h;
  };
  const consented = openDialog(true);
  assert.equal(consented.page.accountDeletionWithoutLocalAccount, false);
  assert.equal(consented.page.accountDeletionDialogTitle(), '注销后兑换权益将永久失去');
  assert.equal(consented.page.accountDeletionConfirmLabel(), '继续');
  const fresh = openDialog(false);
  assert.equal(fresh.page.accountDeletionWithoutLocalAccount, true, 'No consent on record: this install never logged in');
  assert.equal(fresh.page.accountDeletionDialogTitle(), '本机还没有登录过小铺账号');
  assert.equal(fresh.page.accountDeletionConfirmLabel(), '仍要注销');
  fresh.page.dismissAccountDeletionDialog();
  assert.equal(fresh.page.accountDeletionDialogStep, 0);
  assert.equal(fresh.trace.includes('login') || fresh.trace.includes('delete-account'), false,
    'Cancelling the first step neither logs in nor deletes');
  const backOut = openDialog(false);
  backOut.page.advanceAccountDeletion();
  assert.equal(backOut.page.accountDeletionDialogTitle(), '确认注销小铺账号？');
  assert.equal(backOut.page.accountDeletionConfirmLabel(), '确认注销');
  backOut.page.dismissAccountDeletionDialog();
  assert.equal(backOut.trace.includes('delete-account'), false, 'The final step can still back out');

  const deleted = openDialog(false);
  deleted.page.advanceAccountDeletion();
  deleted.page.confirmAccountDeletion();
  assert.equal(deleted.page.accountDeletionDialogStep, 0);
  for (let turn = 0; turn < 20; turn++) await Promise.resolve();
  const order = ['login', 'delete-account', 'clear-session', 'revoke-consent', 'bootstrap'];
  assert.deepEqual(deleted.trace.filter(step => order.includes(step)).slice(-5), order,
    'Login (which asks for consent first), delete, then clear the session and consent and fall back to anonymous rights');
  assert.ok(deleted.notices.some(notice => notice.includes('小铺账号已注销')));
  assert.equal(deleted.page.accountDeletionBusy, false);
  const blocked = harness({ deleteAccount: async () => { throw new Error('注销未完成，请检查网络后重试'); } });
  await blocked.page.performAccountDeletion();
  assert.equal(blocked.page.accountDeletionStatus, '注销未完成，请检查网络后重试');
  assert.equal(blocked.trace.includes('clear-session'), false, 'A refused deletion keeps the session');

  console.log('PASS store account deletion: in-page dialog in the shared style, two steps (only redemption gifts are lost, purchases stay with Huawei), no-consent variant explains the consent step first, login/delete/reset order, refusal keeps the session');
})().catch(error => { console.error(error); process.exitCode = 1; });
