// Run with Node and a typescript/lib/typescript.js path, matching the sync gate.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const { fixture } = require('./metronome-start-timing.cjs');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function loadCatalog() {
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {};
    cache.set(file, exports);
    const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    });
    vm.runInNewContext(result.outputText, { exports,
      require: name => load(path.resolve(path.dirname(file), `${name}.ets`)) });
    return exports;
  }
  return load(path.resolve(__dirname, '../../entry/src/main/ets/audio/DrumMachineCatalog.ets'));
}

const catalog = loadCatalog();
const program = (styleKey = 'rock') => catalog.serializeDrumProgram({
  styleKey, beatsPerBar: 4, beatUnit: 4, sections: [{
    id: 'A', patternIndex: 0, repeats: 1, fillIndex: 0, fillEvery: 0,
    customPattern: { subdivision: 4, events: [
      { tick: 0, sampleKey: 'kick', velocity: 0.5 },
      { tick: 480, sampleKey: 'kick', velocity: 1 }
    ] }
  }]
});
const bank = (marker = 12345) => new Map([
  ['kick', new Int16Array([marker, -6789, 4321, 0]).buffer]
]);

function harness({ sampleBankClass, engineOptions = {}, drumAccess = () => true } = {}) {
  const loads = [];
  const cached = new Map();
  const storage = new Map();
  const starts = [];
  const backgroundUpdates = [];
  let suspends = 0;
  const h = fixture({ queueMs: 0, ...engineOptions, moduleMocks: {
    './DrumMachineCatalog': catalog,
    './DrumSampleBank': { DrumSampleBank: sampleBankClass || { loadStyle(style) {
      if (cached.has(style)) return Promise.resolve(cached.get(style));
      const gate = deferred();
      loads.push({ style, reject: gate.reject, resolve(value = bank()) {
        cached.set(style, value);
        gate.resolve(value);
      } });
      return gate.promise;
    } } }
  } });
  const e = h.engine;
  const schedule = e.scheduleFromLeaderStart.bind(e);
  e.scheduleFromLeaderStart = (...args) => { starts.push(args); return schedule(...args); };
  const suspend = e.suspendRenderer.bind(e);
  e.suspendRenderer = async () => { suspends++; await suspend(); };
  h.renderer.stop = async () => { h.renderer.state = 3; };
  class Controller {
    state = 'idle';
    bpm = 120;
    beatsPerBar = 4;
    rhythm = 0;
    soundId = 0;
    drumProgram = '';
    lobbyDeparted = false;
    beatPointStates = Array(4).fill('normal');
    constructor(_id, leader) { this.isLeader = leader; }
    setUiListener(listener) { this.listener = listener; }
    setTransportPreparationHandler(handler) { this.prepareAudio = handler; }
    emit() { this.listener(); }
    getRemoteSessionEndReason() { return undefined; }
    getOffsetMs() { return 0; }
    getClockSkewPpm() { return 0; }
    getClockMappingValidUntilMs() { return Infinity; }
    setBeatIndex() {}
    completeCountIn() {}
    async disconnect() {}
  }
  const mocks = {
    '../session/SessionController': { SessionController: Controller },
    '../audio/MetronomeEngine': { MetronomeEngine: class { constructor() { return e; } } },
    '../audio/AudioOutputMonitor': { AudioOutputMonitor: {
      start() {}, stop() {}, isBluetoothA2dpActive: () => true, isBuiltInSpeakerActive: () => false
    } },
    '../network/p2p/WifiP2pManager': { WifiP2pManager: class { async teardown() {} } },
    '../network/p2p/BleRoomDiscovery': { BleRoomDiscovery: class { async stopLeaderAdvertising() {} setJoinRequestListener() {} setMemberDisplayName() {} } },
    '../network/p2p/P2pInvitation': {},
    '../common/UserFeedback': { showUserNotice() {}, logUserFailure() {} },
    '../store/EntitlementStore': { isProDrumMachineAccessible: drumAccess },
    '../common/Constants': { PROTOCOL_VERSION: 6 },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => h.now } },
    '../common/MeterModel': { defaultBeatPointStates: count => Array(count).fill('normal') },
    '../session/SessionBackgroundKeeper': { SessionBackgroundKeeper: {
      async ensurePlaybackReady() {},
      async updateMediaTitle() {},
      setControlHandler() {}, async updatePlaybackState(playing) { backgroundUpdates.push(playing); }, async stop() {}
    } },
    '@kit.ArkUI': { promptAction: { showToast() {} }, router: {} }
  };
  // A baseline source override keeps the regression reproducible without
  // changing either production file or substituting a model of its methods.
  const sourcePath = process.env.ONEBEAT_PREVIEW_SESSION_SOURCE ||
    path.resolve(__dirname, '../../entry/src/main/ets/app/AppSession.ets');
  const compiled = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const exports = {};
  vm.runInNewContext(compiled.outputText, {
    exports, console: { info() {}, warn() {} },
    require(name) { assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`); return mocks[name]; },
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value), get: key => storage.get(key) },
    setTimeout() { throw new Error('This session test must not start unrelated delayed work'); }, clearTimeout() {}
  });
  const session = exports.AppSession.createLeader('Drum preview ownership');
  e.beatPointStates = Array(4).fill('normal');
  return { ...h, get now() { return h.now; }, get physicalFrame() { return h.physicalFrame; },
    session, loads, starts, storage, backgroundUpdates, suspends: () => suspends };
}

async function flush() { for (let i = 0; i < 30; i++) await Promise.resolve(); }

async function renderCurrent(h, expectedMarker) {
  await h.fireDueTimers();
  const e = h.engine;
  const transition = e.pendingAudioTransition;
  assert.ok(transition && transition.kind === 'play', 'The real engine must install a playback transition');
  const before = transition.targetFrame - e.audioSubmittedFrames;
  assert.ok(before >= 0);
  const samples = new Int16Array(before + 8);
  for (let cursor = 0; cursor < samples.length; cursor += 4096) {
    const data = new ArrayBuffer(Math.min(4096, samples.length - cursor) * 2);
    e.handleWriteData(data);
    samples.set(new Int16Array(data), cursor);
  }
  assert.deepEqual(Array.from(samples.subarray(before, before + 4)), [expectedMarker, -6789, 4321, 0],
    'Actual writeData must start with the requested drum PCM at its editor cursor, never a fallback metronome click');
}

async function testUnrelatedNotifications() {
  const h = harness();
  const s = h.session;
  // Isolate the configuration race first; idle renderer cleanup is checked
  // separately with keep-alive disabled below.
  s.keepRendererAliveForSession = true;
  const raw = program();
  const preview = s.previewDrumProgram(raw, true, 120, 4, 1);
  assert.equal(h.loads.length, 1);
  for (let i = 0; i < 3; i++) s.controller.emit();
  s.syncEngineFromSession();
  h.loads[0].resolve();
  await preview;
  await renderCurrent(h, 12345);
  assert.equal(s.drumPreviewActive, true, 'Preview ownership must include both preparation and playback');
  assert.equal(h.engine.customProgramRaw, raw);
  const run = h.engine.runToken;
  const revision = h.engine.configurationToken;
  const active = h.engine.activeSequence;
  for (let i = 0; i < 3; i++) s.controller.emit();
  s.syncEngineFromSession();
  assert.equal(h.engine.configurationToken, revision, 'Ordinary UI notifications cannot reconfigure the active drum kit');
  assert.equal(h.engine.activeSequence, active);
  assert.equal(h.engine.runToken, run);
  assert.equal(h.starts.length, 1);
  assert.equal(h.suspends(), 0);

  const idle = harness();
  const pending = idle.session.previewDrumProgram(raw, true, 120, 4, 1);
  const token = idle.engine.configurationToken;
  assert.equal(idle.session.drumPreviewActive, true, 'Acquire ownership before awaiting the cold bank');
  idle.session.controller.emit();
  idle.session.syncEngineFromSession();
  await flush();
  assert.equal(idle.suspends(), 0, 'Idle UI cleanup must not suspend a preview preparing its samples');
  assert.equal(idle.engine.configurationToken, token);
  idle.loads[0].resolve();
  await pending;
  await renderCurrent(idle, 12345);
  idle.session.controller.emit();
  assert.equal(idle.suspends(), 0, 'Idle UI cleanup must also preserve a preview already playing');
  idle.session.stopDrumPreview();
  await flush();
  assert.equal(idle.session.drumPreviewActive, false);
  assert.equal(idle.suspends(), 1, 'Explicit Stop must release the idle renderer');
}

async function testConfigurationReadiness() {
  const h = harness();
  const e = h.engine;
  assert.equal(await e.configureProgram(''), false, 'Empty configuration is not an applied drum program');
  const discarded = e.configureProgram(program('jazz'));
  e.configure(0, 0);
  h.loads[0].resolve();
  assert.equal(await discarded, false, 'An ordinary configuration must discard an older asynchronous drum load');
  assert.equal(e.customProgramRaw, '');
  const raw = program();
  const applied = e.configureProgram(raw);
  h.loads[1].resolve();
  assert.equal(await applied, true);
  assert.equal(await e.configureProgram(raw), true, 'An already applied configuration is ready without a new bank load');
  const slow = e.configureProgram(program('latin'));
  assert.equal(await e.configureProgram(raw), true, 'Reasserting the applied program still invalidates older pending loads');
  h.loads[2].resolve(bank(21000));
  assert.equal(await slow, false);
  assert.equal(e.customProgramRaw, raw);
  assert.equal(h.loads.length, 3);
}

async function testStopSupersessionAndFailures() {
  for (const rejectOld of [false, true]) {
    const h = harness();
    const s = h.session;
    s.keepRendererAliveForSession = true;
    const old = s.previewDrumProgram(program(), true, 120, 4, 1).then(() => undefined, error => error);
    s.stopDrumPreview();
    assert.equal(s.drumPreviewActive, false);
    if (rejectOld) h.loads[0].reject(new Error('Stopped sample request'));
    else h.loads[0].resolve();
    await old;
    await h.fireDueTimers();
    assert.equal(h.starts.length, 0, 'A stopped cold preview cannot schedule later');
    assert.equal(h.engine.running, false);
  }

  for (const rejectOld of [false, true]) {
    const h = harness();
    const s = h.session;
    s.keepRendererAliveForSession = true;
    const old = s.previewDrumProgram(program(), true, 120, 4, 1).then(() => undefined, error => error);
    const fresh = s.previewDrumProgram(program('jazz'), true, 120, 4, 1);
    h.loads[1].resolve(bank(21000));
    await fresh;
    await renderCurrent(h, 21000);
    const revision = h.engine.configurationToken;
    if (rejectOld) h.loads[0].reject(new Error('Superseded style load'));
    else h.loads[0].resolve();
    await old;
    assert.equal(s.drumPreviewActive, true, 'A stale completion/failure cannot release the newer preview owner');
    assert.equal(h.starts.length, 1);
    assert.equal(h.engine.configurationToken, revision);
    assert.equal(h.engine.customProgramRaw, program('jazz'));
    s.controller.emit();
    assert.equal(h.engine.configurationToken, revision);
    s.stopDrumPreview();
  }

  const failed = harness();
  failed.session.keepRendererAliveForSession = true;
  const outcome = failed.session.previewDrumProgram(program()).then(() => undefined, error => error);
  failed.loads[0].reject(new Error('Current bank unavailable'));
  assert.match((await outcome)?.message ?? '', /Current bank unavailable/);
  assert.equal(failed.session.drumPreviewActive, false, 'A current load failure must release its preview lease');
  assert.equal(failed.starts.length, 0, 'A failed load cannot schedule a fallback click');
  assert.equal(failed.engine.running, false);
  const beforeSync = failed.engine.configurationToken;
  failed.session.syncEngineFromSession();
  assert.ok(failed.engine.configurationToken > beforeSync, 'Normal session configuration resumes after failure');

  const discarded = harness();
  discarded.session.keepRendererAliveForSession = true;
  const request = discarded.session.previewDrumProgram(program()).then(() => undefined, error => error);
  discarded.engine.configure(0, 0);
  discarded.loads[0].resolve();
  assert.match((await request)?.message ?? '', /配置已失效/,
    'A current discarded configuration must fail explicitly so its UI cannot advertise an audible audition');
  assert.equal(discarded.starts.length, 0, 'An explicitly discarded configuration must never schedule the previously configured click');
  assert.equal(discarded.session.drumPreviewActive, false);

  const cached = harness();
  cached.session.keepRendererAliveForSession = true;
  const first = cached.session.previewDrumProgram(program(), true, 120, 4, 1);
  cached.loads[0].resolve();
  await first;
  cached.session.stopDrumPreview();
  await cached.session.previewDrumProgram(program(), true, 120, 4, 1);
  assert.equal(cached.loads.length, 1, 'Cached preview restarts must not need a second style load');
  assert.equal(cached.starts.length, 2);
  await renderCurrent(cached, 12345);
}

async function testRealTakeovers() {
  for (const type of ['TRANSPORT', 'TRANSPORT_PAUSE', 'TRANSPORT_RESUME']) {
    const h = harness();
    const s = h.session;
    const old = s.previewDrumProgram(program(), true, 120, 4, 1).then(() => undefined, error => error);
    s.controller.state = type === 'TRANSPORT_PAUSE' ? 'paused' : 'playing';
    h.storage.set('lastTransportMessage', JSON.stringify({ type, payload: {
      startAtLeaderMonoMs: h.now + 650, pauseAtLeaderMonoMs: h.now + 650,
      resumeAtLeaderMonoMs: h.now + 650, beatIndex: 8, countInBeats: 0
    } }));
    s.controller.emit();
    await flush();
    assert.equal(s.drumPreviewActive, false, `${type} must reclaim local preview ownership`);
    const scheduled = h.starts.length;
    assert.equal(scheduled, type === 'TRANSPORT_PAUSE' ? 0 : 1);
    h.loads[0].resolve();
    await old;
    assert.equal(h.starts.length, scheduled, `Late preview preparation cannot override ${type}`);
    assert.equal(h.engine.customProgramRaw, '', 'The controller configuration must win a genuine transport handoff');
    assert.equal(h.engine.transportPreviewStartPositionBeats, undefined, 'A team transport cannot inherit a local editor cursor');
  }

  for (const calibrate of [s => s.scheduleLatencyTapMeasurement(101000, 4),
    s => s.scheduleLatencyPreview(101000, 0)]) {
    const h = harness();
    const s = h.session;
    const old = s.previewDrumProgram(program()).then(() => undefined, error => error);
    await calibrate(s);
    assert.equal(s.drumPreviewActive, false, 'A genuine calibration schedule must reclaim preview ownership');
    assert.equal(s.latencyCalibrationActive, true);
    h.loads[0].resolve();
    await old;
    assert.equal(h.starts.length, 1, 'A stale drum load cannot schedule over calibration');
    assert.equal(h.engine.customProgramRaw, '');
  }

  const shutdown = harness();
  const old = shutdown.session.previewDrumProgram(program()).then(() => undefined, error => error);
  await shutdown.session.shutdown();
  assert.equal(shutdown.session.drumPreviewActive, false);
  shutdown.loads[0].resolve();
  await old;
  assert.equal(shutdown.starts.length, 0, 'A retired session cannot restart from late drum preparation');
  assert.equal(shutdown.engine.renderer, undefined);
}

function actualSampleBank() {
  const exports = {};
  const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/audio/DrumSampleBank.ets'), 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  });
  vm.runInNewContext(compiled.outputText, { exports, ArrayBuffer, Uint8Array,
    require(name) {
      assert.equal(name, './DrumMachineCatalog');
      return catalog;
    }
  });
  return exports.DrumSampleBank;
}

async function testActualResourceBank() {
  const unavailable = harness({ sampleBankClass: actualSampleBank() });
  await assert.rejects(unavailable.session.previewDrumProgram(program()), /音色资源尚未初始化/,
    'A missing resource manager must fail before the engine can substitute generic clicks');
  assert.equal(unavailable.starts.length, 0);
  assert.equal(unavailable.session.drumPreviewActive, false);

  const SampleBank = actualSampleBank();
  const gate = deferred();
  const reads = [];
  const wav = Buffer.alloc(52);
  wav.write('RIFF', 0);
  wav.writeUInt32LE(44, 4);
  wav.write('WAVEfmt ', 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(44100, 24);
  wav.writeUInt32LE(88200, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write('data', 36);
  wav.writeUInt32LE(8, 40);
  [12345, -6789, 4321, 0].forEach((value, index) => wav.writeInt16LE(value, 44 + index * 2));
  SampleBank.initialize({ async getRawFileContent(file) {
    reads.push(file);
    await gate.promise;
    return new Uint8Array(wav);
  } });
  const h = harness({ sampleBankClass: SampleBank });
  h.session.keepRendererAliveForSession = true;
  const start = h.session.previewDrumProgram(program(), true, 120, 4, 1);
  assert.equal(reads.length, 1, 'Exercise the real sequential raw-resource loader while its first file is pending');
  h.session.controller.emit();
  h.session.syncEngineFromSession();
  gate.resolve();
  await start;
  assert.deepEqual(reads, Array.from(catalog.DRUM_TRACKS, track => `drums/rock/${track.key}.wav`));
  await renderCurrent(h, 12345);
  h.session.stopDrumPreview();
  const revised = JSON.parse(program());
  revised.sections[0].customPattern.events.push({ tick: 960, sampleKey: 'kick', velocity: 0.7 });
  await h.session.previewDrumProgram(catalog.serializeDrumProgram(revised), true, 120, 4, 1);
  assert.equal(reads.length, 10, 'The actual bank cache must serve a different arrangement in the same style');
  assert.equal(h.starts.length, 2);
  await renderCurrent(h, 12345);
}

async function main() {
  await testUnrelatedNotifications();
  await testConfigurationReadiness();
  await testStopSupersessionAndFailures();
  await testRealTakeovers();
  await testActualResourceBank();
  console.log('PASS drum preview session ownership: actual AppSession/engine/raw-bank PCM survives cold-load and playback UI updates, idle cleanup, readiness/cache, stop/supersession/failure, real transport/calibration and shutdown takeovers, missing resource rejection');
}

module.exports = { harness, program, bank, catalog, flush };
if (require.main === module) {
  main().catch(error => { console.error(error); process.exitCode = 1; });
}
