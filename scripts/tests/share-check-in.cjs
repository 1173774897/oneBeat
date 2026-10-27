const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
function load(file, mocks = {}, globals = {}) {
  const compiled = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.deepEqual((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error), []);
  const context = { exports: {}, require(name) {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
    return mocks[name];
  }, ...globals };
  vm.runInNewContext(compiled.outputText, context);
  return context.exports;
}
const rules = load('store/ShareCheckInRules.ets');
const day = rules.SHARE_CHECK_IN_DAY_MS;
const noon = Date.parse('2026-10-16T12:00:00+08:00');
function reduce(state, id, at, monthly = false) { return rules.reduceShareCheckIn(state, id, at, monthly); }

function testRules() {
  let state = rules.emptyShareCheckInSnapshot();
  for (let index = 0; index < 6; index++) {
    const change = reduce(state, `day-${index}`, noon + index * day);
    assert.equal(change.result.streakDays, index + 1);
    assert.equal(change.result.rewardGranted, index >= 2);
    state = change.snapshot;
  }
  assert.equal(state.trialExpiresAt, noon + 6 * day, 'Each consecutive day grants from confirmation, without stacking');
  const repeat = reduce(state, 'new-share-same-day', noon + 5 * day + 3600000);
  assert.equal(repeat.result.rewardGranted, false);
  assert.equal(repeat.snapshot.trialExpiresAt, state.trialExpiresAt);
  assert.equal(repeat.result.streakDays, 6);
  const replay = reduce(repeat.snapshot, 'day-2', noon + 7 * day);
  assert.equal(replay.result.alreadyProcessed, true);
  assert.equal(replay.result.rewardGranted, false, 'Replay reports no newly granted trial');
  assert.equal(replay.result.dayKey, '2026-10-18');
  assert.equal(replay.snapshot.days.length, 6, 'A consumed share cannot acquire a new calendar day after process recovery');
  assert.equal(reduce(state, 'gap', noon + 7 * day).result.streakDays, 1);
  assert.equal(rules.visibleShareStreak(state, noon + 7 * day), 0);

  let member = rules.emptyShareCheckInSnapshot();
  member = reduce(member, 'member-1', noon, true).snapshot;
  member = reduce(member, 'member-2', noon + day, true).snapshot;
  const skipped = reduce(member, 'member-3', noon + 2 * day, true);
  assert.equal(skipped.result.monthlySkipped, true);
  assert.equal(skipped.result.rewardGranted, false);
  assert.equal(skipped.snapshot.days[2].rewardGranted, false);
  const expired = reduce(skipped.snapshot, 'after-membership-ended', noon + 2 * day + 60000, false);
  assert.equal(expired.result.rewardGranted, true, 'Membership skip does not consume the same day reward');
  assert.equal(expired.result.trialExpiresAt, noon + 3 * day + 60000);

  const beforeMidnight = Date.parse('2026-10-18T23:59:00+08:00');
  const afterMidnight = Date.parse('2026-10-19T00:01:00+08:00');
  assert.equal(rules.beijingDayKey(beforeMidnight), '2026-10-18');
  assert.equal(rules.beijingDayIndex(afterMidnight) - rules.beijingDayIndex(beforeMidnight), 1);
  assert.equal(reduce(reduce(rules.emptyShareCheckInSnapshot(), 'late', beforeMidnight).snapshot,
    'early', afterMidnight).result.streakDays, 2);
}

function storeHarness(shared = { durable: '', fileDurable: '' }) {
  let now = noon;
  let mono = 1000;
  let monthly = false;
  let monthlyKnown = true;
  let pending = '';
  let failFlush = false;
  let flushGate;
  const app = new Map();
  const pref = {
    async get() { return shared.durable; },
    async put(_key, value) { pending = value; },
    async flush() {
      if (flushGate) await flushGate;
      if (failFlush) throw new Error('simulated disk failure');
      shared.durable = pending;
    }
  };
  class ClockDate extends Date { static now() { return now; } }
  const store = load('store/ShareCheckInStore.ets', {
    '@kit.ArkData': { preferences: { getPreferences: async () => pref } },
    '../common/AtomicTextFile': {
      async readOptional(path) { return path.endsWith('/clock-watermark-v1.json') ? shared.clockDurable ?? '' : shared.fileDurable ?? ''; },
      async writeAtomic(path, value) {
        if (flushGate) await flushGate;
        if (failFlush) throw new Error('simulated disk failure');
        if (path.endsWith('/clock-watermark-v1.json')) shared.clockDurable = value;
        else shared.fileDurable = value;
      }
    },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => mono } },
    './EntitlementStore': { isMonthlyPassActive: () => monthly,
      isMonthlyPassRewardStateKnown: () => monthlyKnown, waitForMonthlyPassCache: async () => {} },
    './ShareCheckInRules': rules
  }, {
    Date: ClockDate, AppStorage: { get: key => app.get(key), setOrCreate: (key, value) => app.set(key, value) },
    setInterval() { return 1; }, console
  });
  return { store, shared, app, setNow(value) { mono += Math.max(0, value - now); now = value; },
    advanceMonotonic(ms) { mono += ms; }, setMonthly(value) { monthly = value; },
    setMonthlyKnown(value) { monthlyKnown = value; },
    fail(value) { failFlush = value; }, gate(value) { flushGate = value; } };
}

async function testDurability() {
  const h = storeHarness();
  await h.store.initializeShareCheckInStore({});
  for (let i = 0; i < 2; i++) {
    h.setNow(noon + i * day);
    await h.store.acceptShareCheckIn(`confirmed-${i}`);
  }
  h.setNow(noon + 2 * day);
  let release;
  h.gate(new Promise(resolve => { release = resolve; }));
  const committing = h.store.acceptShareCheckIn('confirmed-2');
  for (let i = 0; i < 8; i++) await Promise.resolve();
  assert.equal(h.store.getShareCheckInSummary().todayCompleted, false, 'UI must not see a day before durable flush');
  assert.equal(h.app.get('shareTrialExpiresAt'), 0);
  release(); h.gate(undefined);
  const [first, duplicate, secondShare] = await Promise.all([
    committing, h.store.acceptShareCheckIn('confirmed-2'), h.store.acceptShareCheckIn('another-share')
  ]);
  assert.equal(first.rewardGranted, true);
  assert.equal(duplicate.alreadyProcessed, true);
  assert.equal(secondShare.rewardGranted, false);
  assert.equal(h.store.getShareCheckInSummary().history[0].shareCount, 2);

  h.setNow(noon + 3 * day);
  h.fail(true);
  await assert.rejects(h.store.acceptShareCheckIn('retry-after-disk-failure'), /disk failure/);
  assert.equal(h.store.getShareCheckInSummary().todayCompleted, false);
  h.fail(false);
  assert.equal((await h.store.acceptShareCheckIn('retry-after-disk-failure')).rewardGranted, true);
  const restored = storeHarness(h.shared);
  restored.setNow(noon + 4 * day);
  await restored.store.initializeShareCheckInStore({});
  const replay = await restored.store.acceptShareCheckIn('confirmed-2');
  assert.equal(replay.alreadyProcessed, true);
  assert.equal(restored.store.getShareCheckInSummary().todayCompleted, false, 'Crash replay cannot check in a later day');

  h.advanceMonotonic(3600000);
  h.setNow(noon + 2 * day);
  assert.equal(h.store.getShareCheckInSummary().clockBlocked, true);
  await assert.rejects(h.store.acceptShareCheckIn('rolled-back'), /设备时间发生回拨/);
  assert.equal((await h.store.acceptShareCheckIn('confirmed-2')).alreadyProcessed, true);
  await h.store.refreshShareCheckInClock();
  const rollbackRestart = storeHarness(h.shared);
  await rollbackRestart.store.initializeShareCheckInStore({});
  assert.equal(rollbackRestart.store.getShareCheckInSummary().clockBlocked, true);
  await assert.rejects(rollbackRestart.store.acceptShareCheckIn('rollback-after-restart'), /设备时间发生回拨/);

  const membership = storeHarness();
  await membership.store.initializeShareCheckInStore({});
  membership.app.set('storePurchasePending', true);
  await assert.rejects(membership.store.acceptShareCheckIn('purchase-pending'), /购买结果待确认/);
  assert.equal(membership.store.getShareCheckInSummary().todayCompleted, false);
  membership.app.set('storePurchasePending', false);
  membership.setMonthlyKnown(false);
  await assert.rejects(membership.store.acceptShareCheckIn('purchase-pending'), /月卡状态暂时无法核对/);
  assert.equal(membership.store.getShareCheckInSummary().todayCompleted, false);
  membership.setMonthlyKnown(true);
  await membership.store.acceptShareCheckIn('purchase-pending');
  membership.setMonthly(true);
  membership.setNow(noon + day); await membership.store.acceptShareCheckIn('paid-2');
  membership.setNow(noon + 2 * day); await membership.store.acceptShareCheckIn('paid-3');
  membership.setMonthly(false);
  assert.equal((await membership.store.acceptShareCheckIn('paid-ended')).rewardGranted, true);
}

async function testGrowingLedgerAndMigration() {
  const h = storeHarness();
  await h.store.initializeShareCheckInStore({ filesDir: '/app/files' });
  for (let i = 0; i < 90; i++) {
    h.setNow(noon + i * day);
    await h.store.acceptShareCheckIn(`long-lived-attempt-${i.toString().padStart(3, '0')}`);
  }
  assert.ok(h.shared.fileDurable.length > 8192, 'A growing ledger must exceed the platform Preferences string limit safely');
  assert.equal(h.store.getShareCheckInSummary().history.length, 90);
  const ledgerBeforeCheckpoint = h.shared.fileDurable;
  h.advanceMonotonic(60000);
  await h.store.refreshShareCheckInClock();
  assert.equal(h.shared.fileDurable, ledgerBeforeCheckpoint, 'A playback-time clock checkpoint must not rewrite the unbounded ledger');
  assert.ok(h.shared.clockDurable.length < 128, 'Clock checkpoint work remains bounded as history grows');
  const restart = storeHarness(h.shared);
  restart.setNow(noon + 90 * day);
  await restart.store.initializeShareCheckInStore({ filesDir: '/app/files' });
  assert.equal(restart.store.getShareCheckInSummary().history.length, 90);
  assert.equal((await restart.store.acceptShareCheckIn('long-lived-attempt-002')).alreadyProcessed, true);
  const legacy = rules.reduceShareCheckIn(rules.emptyShareCheckInSnapshot(), 'legacy-attempt', noon, false).snapshot;
  const migrated = storeHarness({ durable: JSON.stringify(legacy), fileDurable: '' });
  await migrated.store.initializeShareCheckInStore({ filesDir: '/app/files' });
  assert.equal(migrated.store.getShareCheckInSummary().history.length, 1);
  assert.ok(migrated.shared.fileDurable.length > 0, 'A legacy Preferences ledger migrates to the private atomic file');
  assert.equal((await migrated.store.acceptShareCheckIn('legacy-attempt')).alreadyProcessed, true);
}

function monthlyCacheHarness(durable = new Map()) {
  const app = new Map([['storeEntitlementCacheSchema', 5]]);
  const ClockDate = class extends Date { static now() { return noon; } };
  let fail = false;
  let readGate;
  let writeGate;
  const prefName = 'onebeat_monthly_pass_summary';
  const mocks = {
    '@kit.ArkData': { preferences: { async getPreferences(_context, name) {
      let pending;
      return {
        async get(_key, fallback) {
          const result = durable.get(name) ?? fallback;
          if (name === prefName && readGate) await readGate;
          return result;
        },
        async put(_key, value) { pending = value; },
        async flush() {
          if (writeGate) await writeGate;
          if (fail) throw new Error('monthly summary disk failure');
          durable.set(name, pending);
        }
      };
    } } },
    './EntitlementSnapshotCache': load('store/EntitlementSnapshotCache.ets', {}, { Date: ClockDate }),
    '../common/AtomicTextFile': {
      readOptionalSync: file => durable.get(file) ?? '',
      writeAtomicSync: (file, value) => durable.set(file, value)
    },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 0 } }
  };
  const entitlement = load('store/EntitlementStore.ets', mocks, {
    AppStorage: { get: key => app.get(key), setOrCreate: (key, value) => app.set(key, value) },
    console: { warn() {} }, Date: ClockDate
  });
  entitlement.initializeStoredEntitlementCache({ filesDir: '/app/files' });
  return { entitlement, durable, app, fail(value) { fail = value; },
    readGate(value) { readGate = value; }, writeGate(value) { writeGate = value; } };
}

function monthlyBootstrap(active, at, extra = {}) {
  return { serverTime: new Date(at).toISOString(), items: [], redemption: { available: false },
    developerPayload: 'synthetic-sensitive-binding',
    pass: { active, expiresAt: active ? new Date(noon + 30 * day).toISOString() : '', autoRenewing: false }, ...extra };
}

async function testMonthlyCache() {
  const fresh = monthlyCacheHarness();
  assert.equal(fresh.entitlement.isMonthlyPassRewardStateKnown(), false);
  await fresh.entitlement.initializeMonthlyPassCache({});
  assert.equal(fresh.entitlement.isMonthlyPassRewardStateKnown(), true, 'A fresh unsigned install has a determined non-member state');
  assert.deepEqual(Object.keys(JSON.parse(fresh.durable.get('onebeat_monthly_pass_summary'))).sort(),
    ['active', 'capturedAt', 'expiresAt'], 'Only membership facts may reach this cache');

  fresh.entitlement.applyStoreBootstrap(monthlyBootstrap(true, noon + 1000));
  assert.equal(fresh.entitlement.isMonthlyPassRewardStateKnown(), false, 'Fresh network state is not reward-safe until durable');
  await fresh.entitlement.waitForMonthlyPassCache();
  assert.equal(fresh.entitlement.isMonthlyPassRewardStateKnown(), true);
  assert.equal(fresh.entitlement.isMonthlyPassActive(noon), true);
  const restart = monthlyCacheHarness(fresh.durable);
  await restart.entitlement.initializeMonthlyPassCache({});
  assert.equal(restart.entitlement.isMonthlyPassActive(noon), true, 'Offline restart restores the paid cutoff');
  assert.equal(restart.entitlement.isMonthlyPassRewardStateKnown(), true);
  restart.entitlement.applyStoreBootstrap(monthlyBootstrap(false, noon));
  await restart.entitlement.waitForMonthlyPassCache();
  assert.equal(restart.entitlement.isMonthlyPassActive(noon), true, 'An older async catalog response cannot revoke a newer pass');

  restart.fail(true);
  restart.entitlement.applyStoreBootstrap(monthlyBootstrap(false, noon + 2000));
  await restart.entitlement.waitForMonthlyPassCache();
  assert.equal(restart.entitlement.isMonthlyPassRewardStateKnown(), false, 'A failed latest write pauses reward decisions');
  restart.fail(false);
  restart.entitlement.applyStoreBootstrap(monthlyBootstrap(false, noon + 3000));
  await restart.entitlement.waitForMonthlyPassCache();
  assert.equal(restart.entitlement.isMonthlyPassRewardStateKnown(), true);

  const unknown = monthlyCacheHarness(new Map([['onebeat_store_session', 'synthetic-token']]));
  await unknown.entitlement.initializeMonthlyPassCache({});
  assert.equal(unknown.entitlement.isMonthlyPassRewardStateKnown(), false, 'An existing account without a summary is not assumed free');
  unknown.entitlement.applyStoreBootstrap(monthlyBootstrap(false, noon));
  await unknown.entitlement.waitForMonthlyPassCache();
  assert.equal(unknown.entitlement.isMonthlyPassRewardStateKnown(), true);

  for (const timing of ['before-restore', 'during-restore']) {
    const older = JSON.stringify({ active: false, expiresAt: '', capturedAt: noon });
    const race = monthlyCacheHarness(new Map([['onebeat_monthly_pass_summary', older]]));
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    if (timing === 'before-restore') race.entitlement.applyStoreBootstrap(monthlyBootstrap(true, noon + 1000));
    race.readGate(gate);
    const initializing = race.entitlement.initializeMonthlyPassCache({});
    for (let i = 0; i < 10; i++) await Promise.resolve();
    if (timing === 'during-restore') race.entitlement.applyStoreBootstrap(monthlyBootstrap(true, noon + 1000));
    release(); race.readGate(undefined);
    await initializing; await race.entitlement.waitForMonthlyPassCache();
    assert.equal(race.entitlement.isMonthlyPassActive(noon), true, `${timing}: restore cannot overwrite a new bootstrap`);
    assert.equal(JSON.parse(race.durable.get('onebeat_monthly_pass_summary')).active, true);
  }

  const invalid = monthlyCacheHarness();
  await invalid.entitlement.initializeMonthlyPassCache({});
  invalid.entitlement.applyStoreBootstrap(monthlyBootstrap(true, noon, { pass: { active: true, expiresAt: null } }));
  await invalid.entitlement.waitForMonthlyPassCache();
  assert.equal(invalid.entitlement.isMonthlyPassRewardStateKnown(), false, 'An active membership with unknown cutoff cannot earn a trial');
}

function testResolver() {
  let now = noon;
  const app = new Map();
  const ClockDate = class extends Date { static now() { return now; } };
  const entitlement = load('store/EntitlementStore.ets', {
    '@kit.ArkData': { preferences: {} },
    './EntitlementSnapshotCache': load('store/EntitlementSnapshotCache.ets', {}, { Date: ClockDate }),
    '../common/AtomicTextFile': { readOptionalSync: () => '', writeAtomicSync() {} },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 0 } }
  }, { AppStorage: { get: key => app.get(key), setOrCreate: (key, value) => app.set(key, value) }, Date: ClockDate });
  function apply(active, reason = 'PASS', cutoff = noon + day) {
    entitlement.applyStoreBootstrap(monthlyBootstrap(active, now, { pass: { active,
      expiresAt: active ? new Date(cutoff).toISOString() : '', autoRenewing: false, iapPurchaseAllowed: true },
      items: [{ itemKey: 'feature.pro_drum_machine', access: { allowed: true, reason } }] }));
  }
  apply(true);
  assert.equal(entitlement.resolveDrumAccess(noon).source, 'monthly');
  assert.equal(entitlement.resolveDrumAccess(noon + day).allowed, false, 'Cached pass cannot outlive its cutoff');
  app.set('shareTrialExpiresAt', noon + 2 * day);
  assert.equal(entitlement.resolveDrumAccess(noon + day).source, 'trial');
  assert.equal(entitlement.resolveDrumAccess(noon + 2 * day).allowed, false);
  apply(false, 'OWNED');
  assert.equal(entitlement.resolveDrumAccess(noon).source, 'owned');
  apply(true);
  assert.equal(entitlement.resolveDrumAccess(noon + 2 * day).allowed, false);
  assert.equal(entitlement.formatTrialExpiry(Date.parse('2026-10-18T23:59:00+08:00')), '10/18 23:59');
  now = Date.now();
  apply(true, 'PASS', now + day);
  app.set('shareTrialClockWallAnchor', now + 40 * day);
  assert.equal(entitlement.resolveDrumAccess().source, 'monthly',
    'The campaign rollback floor must not revoke a still-valid paid membership');
  entitlement.applyStoreBootstrap(monthlyBootstrap(false, now));
  app.set('shareTrialExpiresAt', now + day);
  assert.equal(entitlement.resolveDrumAccess().allowed, false, 'The same future floor still restricts campaign trials');
}

async function testTransportAccess() {
  const { harness, program, bank, flush } = require('./drum-preview-session-ownership.cjs');
  let allowed = false;
  const denied = harness({ drumAccess: () => allowed });
  const token = denied.engine.runToken;
  await assert.rejects(denied.session.previewDrumProgram(program()), /鼓机权益已到期/);
  assert.equal(denied.engine.runToken, token, 'Denied audition must not mutate production audio');
  denied.session.controller.rhythm = 3;
  denied.session.controller.drumProgram = program();
  let commands = 0;
  denied.session.controller.startTransport = async () => { commands++; };
  denied.session.controller.resumeTransport = async () => { commands++; };
  await assert.rejects(denied.session.leaderStart(), /鼓机权益已到期/);
  await assert.rejects(denied.session.leaderResume(), /鼓机权益已到期/);
  assert.equal(commands, 0);
  denied.session.controller.isLeader = false;
  await denied.session.leaderResume();
  assert.equal(commands, 1, 'Followers are not required to hold their own drum entitlement');
  allowed = true;
  const cold = harness({ drumAccess: () => allowed });
  const starting = cold.session.previewDrumProgram(program());
  await flush();
  allowed = false;
  cold.loads[0].resolve(bank());
  await assert.rejects(starting, /鼓机权益已到期/);
  assert.equal(cold.starts.length, 0, 'A trial expiring during sample preparation must not schedule new playback');
  allowed = true;
  const active = harness({ drumAccess: () => allowed });
  const playback = active.session.previewDrumProgram(program());
  await flush(); active.loads[0].resolve(bank()); await playback;
  const runToken = active.engine.runToken;
  allowed = false;
  active.session.controller.emit();
  assert.equal(active.engine.runToken, runToken, 'Expiry does not asynchronously cut an already playing audition');
}

(async () => {
  testRules(); await testDurability(); await testGrowingLedgerAndMigration(); testResolver(); await testMonthlyCache(); await testTransportAccess();
  console.log('PASS share check-in: Beijing streaks/rewards, membership expiry, durable publication, concurrent confirmation, crash replay, rollback, access cutoffs and transport boundaries');
})().catch(error => { console.error(error); process.exitCode = 1; });
