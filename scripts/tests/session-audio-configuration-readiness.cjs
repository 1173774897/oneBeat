// The real AppSession and MetronomeEngine prepare actual PCM. Only native
// services, controller transport and sample-resource completion are controlled.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const { fixture } = require('./metronome-start-timing.cjs');
const { program, bank, catalog, flush } = require('./drum-preview-session-ownership.cjs');
const BUDGET_MS = 4000;
const compiled = ts.transpileModule(fs.readFileSync(path.resolve(__dirname,
  '../../entry/src/main/ets/app/AppSession.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function harness() {
  const loads = [], starts = [], failures = [];
  const cached = new Map(), storage = new Map(), timers = new Map();
  let nextTimer = 1;
  const h = fixture({ queueMs: 0, moduleMocks: {
    './DrumMachineCatalog': catalog,
    './DrumSampleBank': { DrumSampleBank: { loadStyle(style) {
      if (cached.has(style)) return Promise.resolve(cached.get(style));
      return new Promise((resolve, reject) => loads.push({ style, reject,
        resolve(value = bank()) { cached.set(style, value); resolve(value); } }));
    } } }
  } });
  const e = h.engine;
  const schedule = e.scheduleFromLeaderStart.bind(e);
  e.scheduleFromLeaderStart = (...args) => { starts.push(args); return schedule(...args); };
  class Controller {
    state = 'paused'; bpm = 120; beatsPerBar = 4; beatUnit = 4;
    rhythm = 0; soundId = 0; drumProgram = ''; lobbyDeparted = true;
    beatPointStates = Array(4).fill('normal');
    constructor(_id, isLeader) { this.isLeader = isLeader; }
    setUiListener(listener) { this.listener = listener; }
    setTransportPreparationHandler(handler) { this.prepareAudio = handler; }
    getRemoteSessionEndReason() { return undefined; }
    getOffsetMs() { return 0; }
    getClockSkewPpm() { return 0; }
    getClockMappingValidUntilMs() { return Infinity; }
    setBeatIndex() {}
    completeCountIn() {}
  }
  const mocks = {
    '../session/SessionController': { SessionController: Controller },
    '../audio/MetronomeEngine': { MetronomeEngine: class { constructor() { return e; } } },
    '../audio/AudioOutputMonitor': { AudioOutputMonitor: { start() {}, stop() {} } },
    '../network/p2p/WifiP2pManager': { WifiP2pManager: class {} },
    '../network/p2p/BleRoomDiscovery': { BleRoomDiscovery: class { setJoinRequestListener() {} setMemberDisplayName() {} } },
    '../network/p2p/P2pInvitation': {},
    '../common/Constants': { PROTOCOL_VERSION: 6, TRANSPORT_START_PREPARE_TIMEOUT_MS: BUDGET_MS },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => h.now } },
    '../common/MeterModel': { defaultBeatPointStates: count => Array(count).fill('normal') },
    '../common/UserFeedback': { showUserNotice() {}, logUserFailure: (...args) => failures.push(args) },
    '../store/EntitlementStore': { isProDrumMachineAccessible: () => true },
    '../session/SessionBackgroundKeeper': { SessionBackgroundKeeper: {
      async ensurePlaybackReady() {},
      async updateMediaTitle() {},
      setControlHandler() {}, async updatePlaybackState() {}
    } },
    '@kit.ArkUI': { router: {} }
  };
  const context = {
    exports: {}, console: { info() {}, warn() {} },
    require(name) { assert.ok(Object.hasOwn(mocks, name), `Unexpected session dependency ${name}`); return mocks[name]; },
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    setTimeout(callback, delay) {
      const id = nextTimer++;
      timers.set(id, { callback, at: h.now + delay });
      return id;
    },
    clearTimeout: id => timers.delete(id)
  };
  vm.runInNewContext(compiled.outputText, context);
  const Session = context.exports.AppSession;
  const session = Session.createLeader('Audio readiness');
  return { ...h, engine: e, session, Session, loads, starts, failures, storage, timers,
    drum(style = 'rock') { session.controller.rhythm = 3; session.controller.drumProgram = program(style); },
    async advance(ms) {
      h.advanceClock(ms);
      for (const [id, timer] of [...timers]) {
        if (timer.at <= h.now) { timers.delete(id); timer.callback(); }
      }
      await flush();
    }
  };
}

async function testClockExperimentOwnership() {
  const ready = harness();
  assert.equal(ready.engine.phaseCorrectionEnabled, true);
  assert.equal(ready.session.configureSharedClockExperiment(false), true);
  assert.equal(ready.session.configureSharedClockExperiment(true), true);
  assert.equal(ready.engine.phaseCorrectionEnabled, true);
  assert.equal(ready.session.configureSharedClockExperiment(false), true);
  assert.equal(ready.engine.phaseCorrectionEnabled, false);
  for (const boundary of ['playing', 'counting', 'preview', 'calibration', 'shutdown', 'streaming']) {
    const h = harness();
    assert.equal(h.session.configureSharedClockExperiment(false), true);
    if (boundary === 'playing' || boundary === 'counting') h.session.controller.state = boundary;
    if (boundary === 'preview') h.session.drumPreviewActive = true;
    if (boundary === 'calibration') h.session.latencyCalibrationActive = true;
    if (boundary === 'shutdown') h.session.shutdownOperation = Promise.resolve();
    if (boundary === 'streaming') h.engine.audioStreaming = true;
    assert.equal(h.session.configureSharedClockExperiment(true), false, `${boundary} owns audio configuration`);
    assert.equal(h.engine.phaseCorrectionEnabled, false);
  }
}

async function testColdAndCachedPcm() {
  const h = harness();
  h.drum();
  const token = h.engine.runToken;
  let settled = false;
  const ready = h.session.waitForCurrentAudioConfiguration().then(value => { settled = true; return value; });
  assert.equal(h.loads.length, 1, 'The explicit wait must join the bank load already started by session sync');
  await flush();
  assert.equal(settled, false, 'Cold resource loading is not ready before PCM rendering finishes');
  h.loads[0].resolve();
  assert.equal(await ready, true);
  assert.equal(h.engine.customProgramRaw, h.session.controller.drumProgram);
  assert.ok(h.engine.pendingSequence[0].samples.some(value => value !== 0), 'True requires actual rendered drum samples');
  assert.equal(h.engine.runToken, token);
  assert.equal(h.engine.running, false);
  assert.equal(h.session.controller.state, 'paused');
  assert.equal(h.starts.length, 0, 'Waiting cannot start or reschedule playback');
  assert.equal(h.storage.get('lastTransportMessage'), '', 'Local PCM readiness cannot publish a transport deadline');
  assert.equal(h.timers.size, 0);
  assert.equal(await h.session.waitForCurrentAudioConfiguration(), true);
  assert.equal(h.loads.length, 1, 'An already rendered configuration needs no second resource load');
  assert.equal(h.timers.size, 0);
}

async function testOrdinaryAndStrictPreparation() {
  const normal = harness();
  const token = normal.engine.runToken;
  assert.equal(await normal.session.waitForCurrentAudioConfiguration(), true);
  assert.equal(normal.loads.length, 0);
  assert.equal(normal.engine.runToken, token);
  assert.equal(normal.starts.length, 0);
  assert.equal(normal.timers.size, 0);
  const strict = harness();
  strict.drum();
  const ready = strict.session.controller.prepareAudio();
  await flush();
  assert.equal(strict.loads.length, 1);
  assert.equal(strict.timers.size, 0, 'Transport preparation retains its controller-owned budget without a second timeout');
  strict.loads[0].resolve();
  assert.equal(await ready, true);
  assert.equal(strict.starts.length, 0);
}

async function testConfigurationReplacement() {
  const changes = {
    rhythm: c => { c.rhythm = 0; },
    program: c => { c.drumProgram = program('jazz'); },
    bpm: c => { c.bpm = 132; },
    beats: c => { c.beatsPerBar = 3; },
    unit: c => { c.beatUnit = 8; },
    sound: c => { c.soundId = 1; },
    points: c => { c.beatPointStates[1] = 'silent'; }
  };
  for (const [name, change] of Object.entries(changes)) {
    const h = harness();
    h.drum();
    const ready = h.session.waitForCurrentAudioConfiguration();
    change(h.session.controller);
    h.loads[0].resolve();
    assert.equal(await ready, false, `A prepared but superseded ${name} cannot claim the current configuration is ready`);
    assert.equal(h.timers.size, 0);
  }
}

async function testOwnershipBoundaries() {
  for (const boundary of ['preview', 'calibration', 'shutdown', 'retired']) {
    const h = harness();
    h.drum();
    if (boundary === 'preview') h.session.drumPreviewActive = true;
    if (boundary === 'calibration') h.session.latencyCalibrationActive = true;
    if (boundary === 'shutdown') h.session.shutdownOperation = Promise.resolve();
    if (boundary === 'retired') h.Session.instance = undefined;
    const revision = h.engine.configurationToken;
    assert.equal(await h.session.waitForCurrentAudioConfiguration(), false, `${boundary} must reject a wait before mutating audio`);
    assert.equal(h.engine.configurationToken, revision);
    assert.equal(h.loads.length, 0);
    assert.equal(h.timers.size, 0);
  }
  for (const boundary of ['preview-roundtrip', 'calibration-roundtrip', 'shutdown', 'retired']) {
    const h = harness();
    h.drum();
    const ready = h.session.waitForCurrentAudioConfiguration();
    if (boundary === 'preview-roundtrip') h.session.drumPreviewToken++;
    if (boundary === 'calibration-roundtrip') h.session.latencyRouteProbeToken++;
    if (boundary === 'shutdown') h.session.shutdownOperation = Promise.resolve();
    if (boundary === 'retired') h.Session.instance = undefined;
    h.loads[0].resolve();
    assert.equal(await ready, false, `${boundary} invalidates the original wait even when the PCM request completes`);
    assert.equal(h.timers.size, 0);
  }
  const preview = harness();
  const previewWork = preview.session.previewDrumProgram(program('jazz'));
  const owner = preview.session.drumPreviewToken;
  const revision = preview.engine.configurationToken;
  assert.equal(await preview.session.waitForCurrentAudioConfiguration(), false);
  assert.equal(preview.session.drumPreviewToken, owner);
  assert.equal(preview.engine.configurationToken, revision);
  preview.loads[0].resolve();
  await previewWork;
  assert.equal(preview.session.isDrumPreviewReady(), true, 'A passive wait must preserve the real preview preparation and playback owner');
  assert.equal(preview.starts.length, 1);
}

async function testTimeoutAndFailure() {
  const timed = harness();
  timed.drum();
  const ready = timed.session.waitForCurrentAudioConfiguration();
  const revision = timed.engine.configurationToken;
  await timed.advance(BUDGET_MS);
  assert.equal(await ready, false);
  assert.equal(timed.timers.size, 0);
  assert.equal(timed.engine.configurationToken, revision, 'Timeout cannot cancel the engine preparation token');
  timed.loads[0].resolve();
  await flush();
  assert.equal(timed.engine.customProgramRaw, timed.session.controller.drumProgram,
    'The engine may finish the still-current background load after the UI waiting budget');
  assert.equal(timed.starts.length, 0);
  const blocked = harness();
  const render = blocked.engine.rebuildPendingSequence.bind(blocked.engine);
  blocked.engine.rebuildPendingSequence = (...args) => {
    render(...args);
    blocked.advanceClock(BUDGET_MS + 1);
  };
  blocked.session.controller.bpm = 121;
  assert.equal(await blocked.session.waitForCurrentAudioConfiguration(), false,
    'Synchronous rendering beyond the deadline cannot beat an overdue timer through microtask ordering');
  assert.equal(blocked.timers.size, 0);
  const failed = harness();
  failed.drum();
  const rejected = failed.session.waitForCurrentAudioConfiguration();
  failed.loads[0].reject(new Error('Missing sample'));
  assert.equal(await rejected, false);
  assert.ok(failed.failures.some(([scope]) => scope === 'drum-configuration'));
  assert.equal(failed.timers.size, 0);
}

async function main() {
  await testClockExperimentOwnership();
  await testColdAndCachedPcm();
  await testOrdinaryAndStrictPreparation();
  await testConfigurationReplacement();
  await testOwnershipBoundaries();
  await testTimeoutAndFailure();
  console.log('PASS session audio configuration readiness: actual cold/cached PCM, complete configuration identity, passive ownership, bounded waiting and no transport side effects');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
