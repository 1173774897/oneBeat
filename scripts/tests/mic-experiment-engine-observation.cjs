const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync('entry/src/main/ets/audio/MetronomeEngine.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function harness() {
  const clock = { now: 100000 }, trace = [], renderers = [], recoveries = [];
  const states = { STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_PAUSED: 5 };
  const hints = { INTERRUPT_HINT_RESUME: 1, INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3 };
  const makeRenderer = () => {
    const renderer = {
      state: states.STATE_RUNNING, handlers: {}, failClock: false, failDetails: false,
      frame: 750000, timestampNs: (clock.now - 50000 - 12) * 1000000,
      on(type, callback) { this.handlers[type] = callback; },
      getAudioStreamIdSync() { trace.push('stream-id'); return 19 + renderers.length; },
      getAudioTimestampInfoSync() {
        trace.push('timestamp'); if (this.failClock) { throw new Error('clock unavailable'); }
        return { framePos: this.frame, timestamp: this.timestampNs };
      },
      getUnderflowCountSync() { trace.push('underflows'); return 3; },
      getLatency(type) {
        trace.push(`latency:${type}`); clock.now += 2;
        if (this.failDetails) { throw new Error('latency unavailable'); }
        return { all: 245, software: 5, hardware: 240 }[type];
      },
      getCurrentOutputDevicesSync() {
        trace.push('output-devices'); if (this.failDetails) { throw new Error('route unavailable'); }
        return [{ deviceType: 8, id: 2 }];
      },
      start() { trace.push('mutate:start'); throw new Error('read-only observation must not start renderer'); },
      stop() { trace.push('mutate:stop'); throw new Error('read-only observation must not stop renderer'); },
      flush() { trace.push('mutate:flush'); throw new Error('read-only observation must not flush renderer'); },
      release() { trace.push('mutate:release'); throw new Error('read-only observation must not release renderer'); },
      setVolume() { trace.push('mutate:volume'); throw new Error('read-only observation must not change renderer volume'); }
    };
    renderers.push(renderer); return renderer;
  };
  const mocks = {
    '@kit.AudioKit': { audio: {
      AudioState: states, InterruptHint: hints, AudioDataCallbackResult: { VALID: 0, INVALID: -1 },
      AudioSamplingRate: { SAMPLE_RATE_44100: 44100 }, AudioChannel: { CHANNEL_1: 1 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
      StreamUsage: { STREAM_USAGE_GAME: 14 },
      AudioLatencyType: { LATENCY_TYPE_ALL: 'all', LATENCY_TYPE_HARDWARE: 'hardware', LATENCY_TYPE_SOFTWARE: 'software' },
      createAudioRenderer: async () => makeRenderer(),
      getAudioManager: () => ({
        getAudioSceneSync() { trace.push('scene'); return 0; },
        setAudioScene() { trace.push('mutate:scene'); throw new Error('observation must not change audio scene'); }
      })
    } },
    '@kit.BasicServicesKit': { systemDateTime: {
      TimeType: { STARTUP: 0, ACTIVE: 1 },
      getUptime: type => (clock.now - (type === 1 ? 50000 : 0)) * 1000000
    } },
    './ClickSound': { ACCENT_DURATION_MS: 20, WEAK_DURATION_MS: 10,
      ClickSound: { buildAccentBuffer: () => new ArrayBuffer(2), buildWeakBuffer: () => new ArrayBuffer(2) } },
    './AudioOutputMonitor': { AudioOutputMonitor: { isBluetoothA2dpActive: () => true } },
    '../store/AudioLatencyPersistence': {
      getEffectiveCalibrationMs: () => { trace.push('effective-calibration'); throw new Error('observation must not reload compensation'); },
      getCalibrationMs: () => { trace.push('saved-calibration'); throw new Error('observation must not reload calibration'); },
      getInputLatencyMs: () => { trace.push('input-calibration'); throw new Error('observation must not reload input calibration'); }
    },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => clock.now } },
    './RhythmTimeline': { BuiltInRhythmFactory: { create: () => ({ beatsPerBar: 4 }) } },
    './DrumMachineCatalog': {}, './DrumSampleBank': {},
    '../common/MeterModel': { defaultBeatPointStates: () => [] }, BuildProfile: { DEBUG: false }
  };
  const context = {
    exports: {}, require(name) { assert.ok(name in mocks, `Missing mock ${name}`); return mocks[name]; },
    console: { info() {}, warn() {} }, ArrayBuffer, Map, Int16Array, DataView, Math,
    setTimeout() { throw new Error('observation must not schedule work'); }, clearTimeout() {}
  };
  vm.runInNewContext(compiled.outputText, context);
  const engine = new context.exports.MetronomeEngine();
  return { engine, clock, trace, renderers, states, hints, recoveries };
}

// Comparing both references and nested data catches rebasing an existing clock object as well as replacing it.
function protectState(engine, excluded = []) {
  const exclude = new Set(['renderer', ...excluded]);
  const references = new Map(Object.entries(engine).filter(([key]) => !excluded.includes(key)));
  const data = JSON.stringify(Object.fromEntries(Object.entries(engine).filter(([key]) => !exclude.has(key))),
    (_key, value) => value instanceof Map ? [...value.entries()] : value);
  const keys = Object.keys(engine);
  return () => {
    assert.deepEqual(Object.keys(engine), keys, 'observation adds or deletes no engine field');
    for (const [key, value] of references) { assert.ok(Object.is(engine[key], value), `observation replaced ${key}`); }
    assert.equal(JSON.stringify(Object.fromEntries(Object.entries(engine).filter(([key]) => !exclude.has(key))),
      (_key, value) => value instanceof Map ? [...value.entries()] : value), data,
    'observation must not mutate nested production state');
  };
}

async function ready(h, exact) {
  await h.engine.ensureRenderer();
  const e = h.engine;
  Object.assign(e, {
    running: true, rendererStarted: true, rendererPhysicalStartCount: 2, runToken: 7,
    writeCallbackCount: 100, audioSubmittedFrames: 761000, lastWriteProgressMs: 99995,
    calibrationFrameOriginExact: exact, calibrationRouteResetPending: false,
    audioTimestampBaseReady: true, audioTimestampBaseFrame: 651932, audioTimestampClockOffsetMs: -50032,
    lastAudioRawFrame: 748236, lastRenderedStreamFrame: 98068, queueDepthFrames: 11000,
    audioTimelineToken: 7, audioTimelineLeadFrames: 89000, audioTimelineOutputLatencyMs: 49.8,
    transportRevision: 6, transportStartLocalMs: 97000, transportStartBeatIndex: 8,
    transportCountInBeats: 4, transportBpm: 120, transportBeatsPerBar: 4,
    transportOutputCompensationOverrideMs: 0, phaseCorrectionFrames: 12,
    productionClockSample: { queryMonoMs: 99992, renderedFrame: 98068, rendererEpoch: e.rendererEpoch },
    pendingAudioTransition: { kind: 'play', token: 7, targetFrame: 790000, beatIndex: 8, countInBeats: 0, outputLatencyMs: 49.8 }
  });
  h.trace.length = 0;
}

(async () => {
  for (const exact of [false, true]) {
    const h = harness(); await ready(h, exact);
    if (!exact) {
      assert.equal(h.engine.readCalibrationClockSample(h.engine.renderer, true), undefined,
        'Existing calibration callers still require an exact production origin');
    }
    const unchanged = protectState(h.engine);
    for (let index = 0; index < 100; index++) {
      const snapshot = h.engine.readMicExperimentPlaybackSnapshot();
      assert.equal(snapshot.rendererEpoch, h.engine.rendererEpoch);
      assert.equal(snapshot.productionFrame, 98068); assert.equal(snapshot.productionClockQueryMonoMs, 99992);
      assert.equal(snapshot.rawFrame, 750000, 'Raw hardware observations do not require a production frame origin');
      assert.equal(snapshot.timestampMonoMs, 99988);
      assert.equal(snapshot.outputDevices, ''); assert.equal(snapshot.audioScene, -1);
      assert.equal(snapshot.latencyAllMs, -1); assert.equal(snapshot.latencySoftwareMs, -1);
      assert.equal(snapshot.latencyHardwareMs, -1); assert.equal(snapshot.underflowCount, 3);
      h.clock.now += 100;
    }
    unchanged();
    assert.ok(h.trace.every(item => item === 'timestamp' || item === 'underflows'),
      'fast observer reads only existing hardware timestamp and underflow counter');
    assert.equal(h.trace.filter(item => item === 'timestamp').length, 100);
    assert.equal(h.trace.some(item => /latency|output-devices|scene/.test(item)), false,
      '100 ms polling never performs slow latency/device/scene queries');
    h.trace.length = 0;
    const boundaryUnchanged = protectState(h.engine);
    const boundary = h.engine.readMicExperimentPlaybackSnapshot(true);
    boundaryUnchanged();
    assert.deepEqual(h.trace, ['timestamp', 'underflows',
      'latency:all', 'latency:software', 'latency:hardware', 'output-devices', 'scene']);
    assert.equal(boundary.latencyAllMs, 245); assert.equal(boundary.latencySoftwareMs, 5);
    assert.equal(boundary.latencyHardwareMs, 240); assert.equal(boundary.outputDevices, '8:2');
    assert.equal(boundary.audioScene, 0);
  }
  {
    const h = harness(); await ready(h, true);
    h.renderers[0].failClock = true; h.renderers[0].failDetails = true;
    const unchanged = protectState(h.engine);
    const snapshot = h.engine.readMicExperimentPlaybackSnapshot(true); unchanged();
    assert.equal(snapshot.rawFrame, -1); assert.equal(snapshot.timestampMonoMs, -1);
    assert.equal(snapshot.latencyAllMs, -1); assert.equal(snapshot.outputDevices, 'unavailable');
    assert.equal(snapshot.productionFrame, 98068, 'unavailable raw clock never primes or overwrites production mapping');
  }
  {
    const h = harness();
    const unchanged = protectState(h.engine);
    const snapshot = h.engine.readMicExperimentPlaybackSnapshot(); unchanged();
    assert.equal(snapshot.rendererEpoch, 0); assert.equal(snapshot.streamId, -1); assert.equal(snapshot.rawFrame, -1);
    assert.deepEqual(h.trace, [], 'reading an uninitialized engine never creates or primes a renderer');
  }
  {
    const h = harness(); await ready(h, true);
    const current = h.renderers[0];
    h.engine.recoverAudio = async reason => { h.recoveries.push(reason); };
    const unchanged = protectState(h.engine, ['experimentInterruptCount', 'experimentLastInterruptHint', 'experimentLastInterruptForce']);
    const before = h.engine.readMicExperimentPlaybackSnapshot();
    current.state = h.states.STATE_PAUSED;
    current.handlers.stateChange(current.state);
    current.handlers.audioInterrupt({ hintType: h.hints.INTERRUPT_HINT_PAUSE, forceType: 1 });
    current.state = h.states.STATE_RUNNING;
    current.handlers.stateChange(current.state);
    current.handlers.audioInterrupt({ hintType: h.hints.INTERRUPT_HINT_RESUME, forceType: 1 });
    const after = h.engine.readMicExperimentPlaybackSnapshot();
    assert.equal(before.running, true); assert.equal(after.running, true);
    assert.equal(before.started, true); assert.equal(after.started, true);
    assert.equal(before.sampledAtMonoMs, after.sampledAtMonoMs, 'pause/resume can both occur between observer ticks');
    assert.equal(after.interruptCount - before.interruptCount, 2, 'real native event handlers retain short interruption evidence');
    assert.equal(after.lastInterruptHint, h.hints.INTERRUPT_HINT_RESUME); assert.equal(after.lastInterruptForce, 1);
    assert.deepEqual(h.recoveries, ['focus resumed'], 'existing resume recovery policy remains unchanged');
    unchanged();
    const oldInterrupt = current.handlers.audioInterrupt, oldState = current.handlers.stateChange;
    await h.engine.createRenderer();
    h.engine.rendererStarted = true;
    const replacementBefore = h.engine.readMicExperimentPlaybackSnapshot();
    oldInterrupt({ hintType: h.hints.INTERRUPT_HINT_PAUSE, forceType: 0 });
    oldInterrupt({ hintType: h.hints.INTERRUPT_HINT_RESUME, forceType: 0 });
    oldState(h.states.STATE_PAUSED);
    const replacementAfter = h.engine.readMicExperimentPlaybackSnapshot();
    assert.equal(replacementAfter.interruptCount, replacementBefore.interruptCount,
      'queued events from a retired renderer never count against its replacement');
    assert.equal(replacementAfter.lastInterruptForce, replacementBefore.lastInterruptForce);
    assert.equal(replacementAfter.started, true); assert.equal(h.recoveries.length, 1);
    h.renderers[1].handlers.audioInterrupt({ hintType: h.hints.INTERRUPT_HINT_PAUSE, forceType: 0 });
    assert.equal(h.engine.readMicExperimentPlaybackSnapshot().interruptCount, replacementBefore.interruptCount + 1);
    h.engine.running = false;
    h.renderers[1].handlers.audioInterrupt({ hintType: h.hints.INTERRUPT_HINT_RESUME, forceType: 1 });
    assert.equal(h.engine.readMicExperimentPlaybackSnapshot().interruptCount, replacementBefore.interruptCount + 2);
    assert.equal(h.recoveries.length, 1, 'observation does not turn a stopped transport into a resumed playback');
  }
  console.log('PASS mic-experiment-engine-observation: fast/boundary reads preserve clock, epoch and transport; native interruption evidence and retired renderer isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });
