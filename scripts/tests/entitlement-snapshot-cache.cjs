const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const DAY = 24 * 60 * 60 * 1000;
const START = Date.parse('2026-10-22T12:00:00+08:00');
const FILE = '/app/files/entitlement-snapshot-v1.json';

function compile(file, mocks, globals) {
  const result = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.deepEqual(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const context = { exports: {}, require(name) {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`); return mocks[name];
  }, ...globals };
  vm.runInNewContext(result.outputText, context);
  return context.exports;
}

function harness(durable = new Map(), at = START) {
  let now = at, failWrite = false, failRead = false, reentrant = false;
  const app = new Map(), events = [], writes = [];
  const ClockDate = class extends Date { static now() { return now; } };
  const helpers = compile('store/EntitlementSnapshotCache.ets', {}, { Date: ClockDate });
  const atomic = {
    readOptionalSync(file) { if (failRead) throw new Error('synthetic read failure'); return durable.get(file) ?? ''; },
    writeAtomicSync(file, value) {
      if (failWrite) throw new Error('synthetic write failure');
      writes.push(value); durable.set(file, value);
    }
  };
  let store;
  store = compile('store/EntitlementStore.ets', {
    './EntitlementSnapshotCache': helpers,
    '../common/AtomicTextFile': atomic,
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => now - START } },
    '@kit.ArkData': { preferences: { async getPreferences(_context, name) {
      return { async get(_key, fallback) { return durable.get(name) ?? fallback; },
        async put(_key, value) { this.value = value; },
        async flush() { durable.set(name, this.value); } };
    } } }
  }, {
    Date: ClockDate, console: { warn() {} },
    AppStorage: { get: key => app.get(key), setOrCreate(key, value) {
      app.set(key, value);
      if (key === 'storeEntitlementEpoch') {
        events.push(new Map(app));
        if (reentrant) store.resolveDrumAccess();
      }
    } }
  });
  return { store, app, events, durable, writes, helpers,
    initialize: () => store.initializeStoredEntitlementCache({ filesDir: '/app/files' }),
    at: value => { now = value; }, now: () => now,
    failWrite: value => { failWrite = value; }, failRead: value => { failRead = value; },
    reentrant: value => { reentrant = value; } };
}

function item(key, reason = 'OWNED', until, extra = {}) {
  return { itemKey: key, displayName: key, kind: key.split('.')[0], defaultFree: false, includedInPass: false,
    access: { allowed: true, reason, validUntil: until }, ...extra };
}
function bootstrap(items = [], extra = {}) {
  return { serverTime: new Date(START).toISOString(), configVersion: 'catalog-v1',
    developerPayload: 'synthetic-sensitive-binding',
    pass: { active: false, expiresAt: '', autoRenewing: false, iapPurchaseAllowed: true },
    redemption: { available: true }, items, ...extra };
}
const iso = value => new Date(value).toISOString();
const plain = value => JSON.parse(JSON.stringify(value));

function testRestoreAndSanitization() {
  const first = harness(); first.initialize();
  assert.equal(first.store.hasUsableEntitlementCache(), false);
  assert.deepEqual(plain(first.store.ownedSceneKeys()), ['sunset_coast']);
  first.store.applyStoreBootstrap(bootstrap([
    item('character.cloud', 'OWNED', undefined, { purchaseBinding: 'synthetic-item-binding',
      access: { allowed: true, reason: 'OWNED', receipt: 'synthetic-receipt' } }),
    item('scene.neon_street'), item('feature.pro_drum_machine')
  ], { token: 'synthetic-token', pass: { active: false, expiresAt: '', autoRenewing: false,
    iapPurchaseAllowed: false, iapPurchaseBlockedReason: '已有月卡', payload: 'synthetic-pass-binding' } }));
  const disk = first.durable.get(FILE);
  for (const secret of ['synthetic-sensitive-binding', 'synthetic-token', 'synthetic-receipt',
    'synthetic-item-binding', 'synthetic-pass-binding', 'developerPayload', 'purchaseBinding']) {
    assert.ok(!disk.includes(secret), `Sensitive or unknown field persisted: ${secret}`);
  }
  assert.equal(JSON.parse(disk).updatedAt, START);
  const restart = harness(first.durable, START + 3 * DAY); restart.initialize();
  assert.equal(restart.store.hasUsableEntitlementCache(), true);
  assert.equal(restart.store.isCharacterAccessible('cloud'), true);
  assert.equal(restart.store.isSceneAccessible('neon_street'), true);
  assert.equal(restart.store.resolveDrumAccess().source, 'owned');
  assert.equal(restart.app.get('storePassIapPurchaseAllowed'), false);
  assert.equal(JSON.parse(restart.durable.get(FILE)).updatedAt, START, 'Restore does not renew freshness');
  restart.at(START + 30 * DAY - 1);
  assert.equal(restart.store.isCharacterAccessible('cloud'), true);
  restart.at(START + 30 * DAY);
  assert.equal(restart.store.hasUsableEntitlementCache(), false);
  assert.equal(restart.store.isCharacterAccessible('cloud'), false, 'Permanent cached purchases still have a thirty-day cap');
  assert.equal(restart.store.isSceneAccessible('neon_street'), false);
  assert.equal(restart.store.resolveDrumAccess().allowed, false);
  assert.deepEqual(plain(restart.store.ownedSceneKeys()), ['sunset_coast']);
  assert.equal(restart.app.get('storePassActive'), false);
  const expiredRestart = harness(first.durable, START + 31 * DAY); expiredRestart.initialize();
  assert.equal(expiredRestart.store.hasUsableEntitlementCache(), false);
  assert.equal(expiredRestart.store.isCharacterAccessible('cloud'), false);
  assert.equal(JSON.parse(expiredRestart.durable.get(FILE)).updatedAt, START);
}

function testMeaningfulPublication() {
  const h = harness(); h.initialize(); h.reentrant(true);
  const original = bootstrap([item('character.cloud'), item('feature.pro_drum_machine')]);
  h.store.applyStoreBootstrap(original);
  const count = h.events.length;
  const published = h.events.at(-1);
  assert.equal(published.get('storeRedemptionAvailable'), true, 'Revision observers see all fields atomically projected');
  assert.equal(published.get('storePassIapPurchaseAllowed'), true);
  assert.equal(published.get('storeProDrumMachine'), true);
  h.at(START + 20 * DAY);
  h.store.applyStoreBootstrap({ ...original, serverTime: iso(START + 20 * DAY),
    developerPayload: 'another-binding', configVersion: 'catalog-v2', items: [...original.items].reverse() });
  assert.equal(h.events.length, count, 'Time, private binding, config tag and array order do not repaint the UI');
  assert.equal(JSON.parse(h.durable.get(FILE)).updatedAt, START + 20 * DAY, 'Identical successful fetch renews TTL silently');
  h.at(START + 31 * DAY);
  assert.equal(h.store.isCharacterAccessible('cloud'), true, 'The successful refresh extends the old lease');
  assert.equal(h.events.length, count);
  const changed = bootstrap([item('character.cloud', 'LOCKED', undefined, { access: { allowed: false, reason: 'LOCKED' } })],
    { serverTime: iso(START + 31 * DAY), redemption: { available: false } });
  h.store.applyStoreBootstrap(changed);
  assert.equal(h.events.length, count + 1, 'A meaningful response publishes exactly once, including reentrant getters');
  assert.equal(h.events.at(-1).get('storeRedemptionAvailable'), false);
  assert.equal(h.events.at(-1).get('storeOwnedCharacters'), '[]');
}

function testItemDeadlinesAndIndependentTrial() {
  const h = harness(); h.initialize();
  const pass = { active: true, expiresAt: iso(START + 5 * DAY), autoRenewing: true, iapPurchaseAllowed: false, source: 'PASS_IAP' };
  h.store.applyStoreBootstrap(bootstrap([
    item('character.cloud', 'PASS', iso(START + 15 * DAY)),
    item('character.teapot', 'OWNED'),
    item('character.wave', 'LIMITED_FREE', iso(START + DAY), { freeWindow: { startsAt: iso(START), endsAt: iso(START + 2 * DAY) } }),
    item('scene.neon_street', 'SUBSCRIPTION', iso(START + 3 * DAY)),
    item('feature.pro_drum_machine', 'PASS', iso(START + 20 * DAY)),
    item('character.lamp', 'OWNED', 'not-a-date')
  ], { pass }));
  assert.equal(h.store.isMonthlyPassActive(), true);
  assert.equal(h.store.resolveDrumAccess().expiresAt, START + 5 * DAY);
  assert.equal(h.store.isCharacterAccessible('lamp'), false, 'Malformed explicit deadline cannot become permanent');
  h.at(START + DAY);
  assert.equal(h.store.isCharacterAccessible('wave'), false);
  assert.deepEqual(plain(h.store.limitedFreeCharacterKeys()), []);
  assert.equal(h.store.storeItemAccessReason('character.wave'), 'LOCKED');
  h.at(START + 3 * DAY);
  assert.equal(h.store.isSceneAccessible('neon_street'), false, 'Item cutoff precedes membership cutoff');
  assert.equal(h.store.isCharacterAccessible('cloud'), true);
  h.at(START + 5 * DAY);
  assert.equal(h.store.isCharacterAccessible('cloud'), false, 'Pass-derived character cannot outlive membership');
  assert.equal(h.store.isCharacterAccessible('teapot'), true, 'Independent purchase survives membership expiry');
  assert.equal(h.store.resolveDrumAccess().allowed, false);
  h.at(START + 31 * DAY);
  h.app.set('shareTrialExpiresAt', h.now() + DAY);
  assert.equal(h.store.resolveDrumAccess().source, 'trial', 'Expired server cache cannot erase a local check-in reward');
  assert.equal(h.app.get('shareTrialExpiresAt'), START + 32 * DAY);
  h.at(START + 32 * DAY);
  assert.equal(h.store.resolveDrumAccess().allowed, false);

  const longPass = harness(); longPass.initialize();
  longPass.store.applyStoreBootstrap(bootstrap([item('character.cloud', 'PASS')], {
    pass: { ...pass, expiresAt: iso(START + 365 * DAY) }
  }));
  assert.equal(longPass.store.resolveDrumAccess().expiresAt, START + 30 * DAY);
  longPass.at(START + 30 * DAY);
  assert.equal(longPass.store.isMonthlyPassActive(), false, 'Long memberships are capped at the successful refresh plus thirty days');
  assert.equal(longPass.store.isCharacterAccessible('cloud'), false);
}

function testFailureAndStaleOrdering() {
  const h = harness(); h.initialize();
  const granted = bootstrap([item('character.cloud')]); h.store.applyStoreBootstrap(granted);
  const originalDisk = h.durable.get(FILE), originalCount = h.events.length;
  h.at(START + 20 * DAY);
  h.store.ownedCharacterKeys(); h.store.hasUsableEntitlementCache();
  assert.equal(h.durable.get(FILE), originalDisk, 'Reads, offline use and failed refreshes never extend disk freshness');
  h.store.applyStoreBootstrap({ ...granted, serverTime: iso(START - DAY), items: [] });
  assert.equal(h.durable.get(FILE), originalDisk, 'Out-of-order responses do not renew TTL or revoke newer rights');
  assert.equal(h.events.length, originalCount);
  h.failWrite(true);
  h.store.applyStoreBootstrap({ ...granted, serverTime: iso(START + 20 * DAY), items: [item('character.teapot')] });
  assert.equal(h.store.isCharacterAccessible('teapot'), true, 'A disk failure does not discard a fresh network result in this process');
  assert.equal(h.durable.get(FILE), originalDisk, 'Failed writes preserve the last committed age');
  const restart = harness(h.durable, START + 31 * DAY); restart.initialize();
  assert.equal(restart.store.isCharacterAccessible('cloud'), false, 'A failed write cannot renew the next process cache');

  const race = harness(new Map([[FILE, originalDisk]]), START + DAY);
  race.store.applyStoreBootstrap(bootstrap([item('character.teapot')], { serverTime: iso(START + DAY) }));
  race.initialize();
  assert.equal(race.store.isCharacterAccessible('teapot'), true, 'Late local restore cannot overwrite a network snapshot');
  assert.equal(race.store.isCharacterAccessible('cloud'), false);
  assert.equal(JSON.parse(race.durable.get(FILE)).updatedAt, START + DAY);
  race.initialize();
  assert.equal(JSON.parse(race.durable.get(FILE)).updatedAt, START + DAY, 'Ability recreation cannot refresh the age');

  for (const raw of ['not-json', '{}', JSON.stringify({ version: 1, updatedAt: START,
    bootstrap: { pass: { active: true }, items: [], redemption: { available: false }, serverTime: 'invalid' } }),
    JSON.stringify({ version: 1, updatedAt: START + DAY, bootstrap: granted })]) {
    const corrupt = harness(new Map([[FILE, raw]])); corrupt.initialize();
    assert.equal(corrupt.store.hasUsableEntitlementCache(), false);
    assert.equal(corrupt.store.resolveDrumAccess().allowed, false);
    assert.deepEqual(plain(corrupt.store.ownedSceneKeys()), ['sunset_coast']);
  }
  const readFailure = harness(); readFailure.failRead(true); readFailure.initialize();
  assert.equal(readFailure.store.hasUsableEntitlementCache(), false);
}

async function testMonthlyRewardAuthority() {
  const onlySummary = harness(new Map([['onebeat_monthly_pass_summary', JSON.stringify({ active: true,
    expiresAt: iso(START + DAY), capturedAt: START })]]));
  onlySummary.initialize(); await onlySummary.store.initializeMonthlyPassCache({});
  assert.equal(onlySummary.store.isMonthlyPassActive(), false, 'An independent reward summary cannot unlock content without a full snapshot');
  assert.equal(onlySummary.store.isMonthlyPassRewardStateKnown(), false, 'A possibly active member cannot obtain a trial from missing full authority');
  const normal = harness(); normal.initialize(); await normal.store.initializeMonthlyPassCache({});
  assert.equal(normal.store.isMonthlyPassRewardStateKnown(), true);
  normal.store.applyStoreBootstrap(bootstrap([], { pass: { active: true, expiresAt: iso(START + 60 * DAY),
    autoRenewing: false, iapPurchaseAllowed: false } }));
  assert.equal(normal.store.isMonthlyPassRewardStateKnown(), false, 'Accepted membership waits for its own durable reward write');
  await normal.store.waitForMonthlyPassCache();
  assert.equal(normal.store.isMonthlyPassRewardStateKnown(), true);
  normal.at(START + 30 * DAY);
  assert.equal(normal.store.isMonthlyPassRewardStateKnown(), false, 'Stale active membership waits for refresh before issuing a campaign reward');

  const old = harness(); old.initialize();
  old.store.applyStoreBootstrap(bootstrap());
  const oldDisk = old.durable.get(FILE);
  const splitCommit = new Map([[FILE, oldDisk], ['onebeat_monthly_pass_summary', JSON.stringify({
    active: true, expiresAt: iso(START + 10 * DAY), capturedAt: START + DAY
  })]]);
  const inconsistent = harness(splitCommit, START + 2 * DAY); inconsistent.initialize();
  await inconsistent.store.initializeMonthlyPassCache({});
  assert.equal(inconsistent.store.hasUsableEntitlementCache(), true, 'A failed newer write did not renew the older full snapshot');
  assert.equal(inconsistent.store.isMonthlyPassActive(), false);
  assert.equal(inconsistent.store.isMonthlyPassRewardStateKnown(), false,
    'A newer active summary plus an older inactive full snapshot must not issue a trial');
  assert.equal(inconsistent.durable.get(FILE), oldDisk);
  inconsistent.store.applyStoreBootstrap(bootstrap([], { serverTime: iso(START + 2 * DAY), pass: {
    active: true, expiresAt: iso(START + 10 * DAY), autoRenewing: false, iapPurchaseAllowed: false
  } }));
  await inconsistent.store.waitForMonthlyPassCache();
  assert.equal(inconsistent.store.isMonthlyPassActive(), true);
  assert.equal(inconsistent.store.isMonthlyPassRewardStateKnown(), true, 'A consistent new response resumes reward decisions');
}

(async () => {
  testRestoreAndSanitization(); testMeaningfulPublication(); testItemDeadlinesAndIndependentTrial();
  testFailureAndStaleOrdering(); await testMonthlyRewardAuthority();
  console.log('PASS entitlement snapshot: private sanitized cache, thirty-day refresh lease, restart/expiry/failure, item/pass cutoffs, stable complete publication, stale races and independent trials');
})().catch(error => { console.error(error); process.exitCode = 1; });
