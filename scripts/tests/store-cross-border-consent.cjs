// Separate PIPL consent before Store data reaches the Hong Kong server
// (2026-11-03). Real CrossBorderConsent, HuaweiAccountService gating and
// UserFeedback cancellation mapping; only platform kits are stubbed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');

function compile(relative, mocks, globals = {}) {
  const exports = {};
  const output = ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets', relative), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInNewContext(output, { exports, Error, console: { info() {}, warn() {} }, require(name) {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
    return mocks[name];
  }, ...globals });
  return exports;
}
const flush = async () => { for (let i = 0; i < 10; i++) await Promise.resolve(); };
const feedback = compile('common/UserFeedback.ets', {
  '@kit.ArkUI': { promptAction: {} }, './MonotonicClock': { MonotonicClock: { nowMs: () => 0 } }
});

function consentModule(stored = {}, { readFails = false } = {}) {
  const writes = [];
  const pref = {
    async get(key, fallback) { if (readFails) throw new Error('io'); return key in stored ? stored[key] : fallback; },
    async put(key, value) { writes.push([key, value]); stored[key] = value; },
    async flush() {}
  };
  const module = compile('store/CrossBorderConsent.ets', {
    '@kit.AbilityKit': {}, '@kit.ArkData': { preferences: { getPreferences: async () => pref } },
    '../common/UserFeedback': feedback
  });
  module.bindCrossBorderConsentContext({});
  return { module, writes, stored };
}

(async () => {
  {
    const { module, writes } = consentModule();
    await flush();
    assert.equal(module.hasCrossBorderConsent(), false);
    const silent = await module.ensureCrossBorderConsent(false).catch(e => e);
    assert.equal(feedback.isUserCancelled(silent), true, 'Silent renewal without consent is a cancellation, not a failure');
    const noDialog = await module.ensureCrossBorderConsent(true).catch(e => e);
    assert.equal(feedback.isUserCancelled(noDialog), true, 'Without a visible Store dialog nothing is sent');

    let asks = 0, answer;
    module.setCrossBorderConsentPrompter(() => { asks++; return new Promise(resolve => { answer = resolve; }); });
    const first = module.ensureCrossBorderConsent(true).catch(e => e);
    const second = module.ensureCrossBorderConsent(true).catch(e => e);
    await flush();
    assert.equal(asks, 1, 'Concurrent Store actions share one dialog');
    answer(false);
    assert.equal(feedback.isUserCancelled(await first), true);
    assert.equal(feedback.isUserCancelled(await second), true);
    assert.equal(module.hasCrossBorderConsent(), false, 'Declining keeps consent absent');
    assert.deepEqual(writes, []);

    module.setCrossBorderConsentPrompter(async () => true);
    await module.ensureCrossBorderConsent(true);
    assert.equal(module.hasCrossBorderConsent(), true);
    assert.deepEqual(writes, [['storeCrossBorderHkVersion', 1]], 'Consent is recorded with its version');
  }
  {
    const { module } = consentModule({ storeCrossBorderHkVersion: 1 });
    let asked = false;
    module.setCrossBorderConsentPrompter(async () => { asked = true; return true; });
    await module.ensureCrossBorderConsent(false);
    assert.equal(asked, false, 'Recorded consent is not asked again');
    assert.equal(module.hasCrossBorderConsent(), true);
  }
  {
    const { module } = consentModule({ storeCrossBorderHkVersion: 1 }, { readFails: true });
    await flush();
    assert.equal(module.hasCrossBorderConsent(), false, 'An unreadable record fails closed');
  }
  {
    // HuaweiAccountService: no token leaves and no login starts without consent.
    let consented = false;
    const logins = [];
    const storage = new Map([['storeAccessToken', 'old-token'],
      ['storeAccessTokenExpiresAt', new Date(Date.now() + 3600000).toISOString()]]);
    class Provider { createLoginWithHuaweiIDRequest() { return {}; } }
    class Controller { async executeRequest() { logins.push('login'); throw new Error('unreachable in this test'); } }
    const account = compile('store/HuaweiAccountService.ets', {
      '@kit.AbilityKit': {}, '@kit.ArkTS': { util: { generateRandomUUID: () => 'state' } },
      '@kit.AccountKit': { authentication: { HuaweiIDProvider: Provider, AuthenticationController: Controller } },
      './StoreApi': { authenticateHuawei: async () => ({}) },
      './StoreBootstrapRefresh': { invalidateStoreBootstrapRefresh() {} },
      './StoreSessionPersistence': { erasePersistedStoreSessionFromDisk: async () => {},
        getStoreSessionPersistenceContext: () => ({}), persistStoreSessionToDisk: async () => {} },
      './StoreModels': {},
      './CrossBorderConsent': {
        hasCrossBorderConsent: () => consented,
        async ensureCrossBorderConsent() { if (!consented) throw Object.assign(new Error('declined'), { code: feedback.PRIVACY_CONSENT_DECLINED_CODE }); }
      }
    }, { AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) } });
    assert.equal(account.currentStoreSessionToken(), '', 'A token from before consent is not used');
    assert.equal(await account.trySilentStoreSessionRenewal(), '', 'Silent renewal stays anonymous');
    const blocked = await account.ensureStoreSession({}, true).catch(e => e);
    assert.equal(feedback.isUserCancelled(blocked), true);
    assert.deepEqual(logins, [], 'No Huawei login starts before consent');
    consented = true;
    assert.equal(account.currentStoreSessionToken(), 'old-token', 'After consent the existing session is used');
  }
  console.log('PASS store cross-border consent: fail-closed load, silent paths never prompt, one shared dialog, ' +
    'decline is a cancellation, versioned record, no login or token before consent');
})().catch(error => { console.error(error); process.exitCode = 1; });
