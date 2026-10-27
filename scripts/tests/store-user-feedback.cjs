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
    serverTime: '2026-10-16T00:00:00Z', configVersion: 'test', developerPayload: 'synthetic-binding',
    pass: { active: false, source: '', status: '', autoRenewing: false, iapPurchaseAllowed: true, ...pass },
    items: [], redemption: { available: true }
  };
}
const receipt = { productId: 'onebeat.character.cloud', purchaseData: 'synthetic-receipt', idempotencyKey: 'synthetic-order' };
const cloud = { key: 'cloud', name: '云行者', productId: receipt.productId };
const scene = { key: 'neon_street', name: '霓虹街口', productId: 'onebeat.scene.neon_street' };

function harness(options = {}) {
  const notices = [], logs = [], trace = [], redemptions = [], storage = new Map();
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
    async fetchStoreBootstrap() { trace.push('bootstrap'); return options.fetch ? options.fetch() : latest; },
    async verifyStorePurchase(_token, order) {
      trace.push('verify');
      return options.verify ? options.verify(order) : bootstrap();
    },
    async restoreStorePurchases(_token, orders) {
      trace.push('restore:' + orders.length);
      return options.restore ? options.restore(orders) : latest;
    },
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
    '../store/StoreApi': api,
    '../store/StoreApiConfig': { isStoreApiConfigured: () => true },
    '../store/EntitlementStore': {
      initializeEntitlementCache() {}, applyStoreBootstrap: apply,
      limitedFreeCharacterKeys: () => [], ownedCharacterKeys: () => [],
      ownedSceneKeys: () => ['sunset_coast', 'neon_street'], storeItemAccessReason: () => ''
    },
    '../store/IapCatalogService': {
      queryStoreProductPrices: async () => ({ prices: [], unavailableReason: 'none' }),
      emptyStoreProductPriceQueryResult: unavailableReason => ({ prices: [], unavailableReason }),
      storePriceUnavailableMessage: () => '商品价格暂时不可用，请检查网络后重试'
    },
    '../store/HuaweiAccountService': {
      clearStoreSession() {}, currentStoreSessionToken: () => 'synthetic-session',
      async ensureStoreSession() {
        trace.push('login');
        if (options.login) return options.login();
        return 'synthetic-session';
      }
    },
    '../store/IapPurchaseService': {
      productTypeForStoreItem: pass => pass ? 'subscription' : 'nonconsumable',
      async createStorePurchase(_context, productId, productType, binding) {
        trace.push('checkout:' + productId);
        assert.equal(binding, 'synthetic-binding');
        return options.purchase ? options.purchase(productId, productType) : receipt;
      },
      async queryRestorablePurchases() {
        trace.push('query');
        return options.query ? options.query() : [];
      }
    }
  };
  const context = { exports: {}, Error, console: logger, AppStorage: appStorage, require(name) {
    assert.ok(Object.hasOwn(mocks, name), 'Unexpected page dependency ' + name);
    return mocks[name];
  }};
  vm.runInNewContext(compiledPage, context);
  apply(latest);
  const page = new context.exports.StorePage();
  page.getUIContext = () => ({ getHostContext: () => ({}) });
  page.aboutToAppear();
  return { page, notices, logs, trace, redemptions, apply };
}

(async () => {
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
    const h = harness(code === 1001502012 ? { login: async () => { throw cancel; } } :
      { purchase: async () => { throw cancel; } });
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
  assert.equal(success.trace.filter(item => item === 'verify').length, 1);

  const freshRestriction = harness({ fetch: async () => bootstrap({ active: true, source: 'PASS_REDEMPTION',
    expiresAt: '2026-11-16T00:00:00Z', iapPurchaseAllowed: false }) });
  freshRestriction.page.openPassPurchase();
  await freshRestriction.page.confirmPurchase();
  assert.equal(freshRestriction.trace.some(item => item.startsWith('checkout:')), false,
    'Fresh server rights must block checkout even when the cached entry allowed purchase');
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
  assert.equal(concurrent.trace.filter(item => item === 'verify').length, 1,
    'A completed paid order still reaches server verification after the page leaves');
  assert.equal(concurrent.notices.length, 0, 'A destroyed page must not emit a late purchase toast');
  assert.equal(concurrent.page.storeActionStatus, '正在完成购买…', 'A destroyed page is not mutated by completion');

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

  const restored = harness({ query: async () => [receipt] });
  await restored.page.restorePurchases();
  assert.equal(restored.page.storeActionStatus, '权益已同步');
  assert.equal(restored.page.storeActionRecovery, '');
  assert.equal(restored.notices.length, 0);
  const noReceipts = harness();
  await noReceipts.page.restorePurchases();
  assert.equal(noReceipts.page.storeActionStatus, '权益已同步', 'An empty native receipt list still reconciles account rights');
  assert.ok(noReceipts.trace.includes('restore:0'));
  const otherReceipt = { ...receipt, productId: scene.productId };
  const partialRestore = harness({ query: async () => [receipt, otherReceipt],
    restore: async orders => {
      if (orders.length > 1 || orders[0]?.productId === scene.productId) throw { code: 42231 };
      return bootstrap();
    }, verify: async order => {
      if (order.productId === scene.productId) throw { code: 42231 };
      return bootstrap();
    }
  });
  await partialRestore.page.restorePurchases();
  assert.match(partialRestore.page.storeActionStatus, /部分权益已同步/);
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
    throw new Error('Unexpected account dependency ' + name);
  }};
  vm.runInNewContext(compiledAccount, account);
  await assert.rejects(account.exports.ensureStoreSession({}, true), error => error === nativeCancel,
    'The login adapter must preserve the native cancellation object and code');

  console.log('PASS: nested drum-comic preview preserves the pass plan and Back priority; actual store methods preserve checkout/verification, immediate committed redemption results, isolated follow-up refresh/retry, input callback safety, silent SDK cancellation, retry identity and lifetime guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
