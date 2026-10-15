// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const RATE = 44100;
const source = fs.readFileSync('entry/src/main/ets/audio/MetronomeEngine.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function near(actual, expected, label, tolerance = 0.2) {
  assert.ok(Math.abs(Number(actual) - expected) <= tolerance,
    `${label}: expected ${expected}, received ${actual}`);
}

function primitiveState(engine) {
  return Object.fromEntries(Object.entries(engine)
    .filter(([, value]) => value === null || ['boolean', 'number', 'string', 'undefined'].includes(typeof value)));
}

function fixture() {
  const clock = { now: 100000, rawAgeMs: 12, rawFrame: 352270.8, failTimestamp: false };
  const audioCalls = [];
  const logs = [];
  const listeners = new Map();
  const audioState = { STATE_PREPARED: 1, STATE_RUNNING: 2, STATE_PAUSED: 5, STATE_STOPPED: 3 };
  const renderer = {
    state: audioState.STATE_RUNNING,
    getAudioTimestampInfoSync() {
      audioCalls.push('timestamp');
      if (clock.failTimestamp) throw new Error('synthetic timestamp unavailable');
      return { framePos: clock.rawFrame, timestamp: (clock.now - 50000 - clock.rawAgeMs) * 1000000 };
    },
    getLatency(type) {
      audioCalls.push(`latency:${type}`);
      return { all: 205, hardware: 200, software: 5 }[type];
    },
    getAudioStreamIdSync() { audioCalls.push('stream-id'); return 123; },
    getCurrentOutputDevicesSync() { audioCalls.push('output-devices'); return []; },
    async getCurrentOutputDevices() { audioCalls.push('output-devices-async'); return []; },
    getUnderflowCountSync() { audioCalls.push('underflow'); return 0; },
    on(name, callback) { listeners.set(name, callback); },
    off(name) { listeners.delete(name); },
    async start() {
      audioCalls.push('start');
      renderer.state = audioState.STATE_RUNNING;
      listeners.get('stateChange')?.(renderer.state);
    },
    async stop() {
      audioCalls.push('stop');
      renderer.state = audioState.STATE_STOPPED;
      listeners.get('stateChange')?.(renderer.state);
    },
    async flush() { audioCalls.push('flush'); },
    async release() { audioCalls.push('release'); }
  };
  const mocks = {
    '@kit.AudioKit': { audio: {
      AudioState: audioState,
      AudioLatencyType: { LATENCY_TYPE_ALL: 'all', LATENCY_TYPE_HARDWARE: 'hardware', LATENCY_TYPE_SOFTWARE: 'software' },
      AudioSamplingRate: { SAMPLE_RATE_44100: RATE }, AudioChannel: { CHANNEL_1: 1 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
      StreamUsage: { STREAM_USAGE_GAME: 1 },
      createAudioRenderer: async () => { audioCalls.push('create'); return renderer; },
      getAudioManager: () => ({ getAudioSceneSync: () => { audioCalls.push('scene'); return 0; } })
    } },
    '@kit.BasicServicesKit': { systemDateTime: {
      TimeType: { STARTUP: 0, ACTIVE: 1 },
      getUptime: type => {
        if (clock.failUptime) throw new Error('synthetic clock domain unavailable');
        return (clock.now - (type === 1 ? 50000 : 0)) * 1000000;
      }
    } },
    './ClickSound': {
      ACCENT_DURATION_MS: 20, WEAK_DURATION_MS: 10,
      ClickSound: { buildAccentBuffer: () => new ArrayBuffer(2), buildWeakBuffer: () => new ArrayBuffer(2) }
    },
    './AudioOutputMonitor': { AudioOutputMonitor: {
      isBluetoothA2dpActive: () => true, estimateBluetoothLinkLatencyMs: () => 240
    } },
    '../store/AudioLatencyPersistence': {
      getEffectiveCalibrationMs: () => 298.2, getCalibrationMs: () => 298.2, getInputLatencyMs: () => 53
    },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => clock.now } },
    './RhythmTimeline': {
      DEFAULT_TICKS_PER_BEAT: 480,
      SequencerPattern: class {
        constructor(ticksPerBeat, beatsPerBar, events) {
          Object.assign(this, { ticksPerBeat, beatsPerBar, events });
        }
      },
      BuiltInRhythmFactory: { create: () => ({ ticksPerBeat: 480, beatsPerBar: 4, events: [] }) }
    },
    './DrumMachineCatalog': {}, './DrumSampleBank': {},
    '../common/MeterModel': { defaultBeatPointStates: () => [] }, BuildProfile: { DEBUG: false }
  };
  const context = {
    exports: {}, require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
      return mocks[name];
    },
    console: { info: value => logs.push(value), warn: value => logs.push(value) },
    ArrayBuffer, Int16Array, Float64Array, DataView, Map,
    setTimeout(callback, delay) { clock.now += delay; callback(); return 1; }, clearTimeout() {}
  };
  vm.runInNewContext(compiled.outputText, context);
  const engine = new context.exports.MetronomeEngine();
  engine.renderer = renderer;
  engine.rendererStarted = true;
  engine.rendererEpoch = 7;
  engine.rendererStreamId = 123;
  engine.rendererPhysicalStartCount = 1;
  engine.rendererStartedAtLocalMs = 92000;
  engine.audioSubmittedFrames = RATE * 9;
  engine.audioTimestampBaseReady = true;
  // Legacy anchors an old query-time offset. The three-ms difference from the
  // real ACTIVE→STARTUP conversion must remain visible in the diagnostic.
  engine.audioTimestampClockOffsetMs = -49997;
  engine.audioTimestampBaseFrame = -8820;
  engine.runToken = 3;
  engine.running = true;
  engine.lastWriteProgressMs = clock.now;
  engine.outputLatencyMs = 298.2;
  engine.transportStartLocalMs = clock.now + 1000;
  engine.pendingAudioTransition = {
    kind: 'play', token: 3, targetFrame: 380000, beatIndex: 0,
    countInBeats: 0, outputLatencyMs: 298.2
  };
  return { engine, renderer, clock, audioCalls, logs, context };
}

function readLog(h, stage = 'test', audible = h.engine.transportStartLocalMs) {
  const priorCount = h.logs.length;
  const before = primitiveState(h.engine);
  const transition = h.engine.pendingAudioTransition;
  const beforeTransition = JSON.stringify(transition);
  const cache = h.engine.productionClockSample;
  const beforeCache = JSON.stringify(cache);
  const renderer = h.engine.renderer;
  const calls = h.audioCalls.slice();
  h.engine.logProductionClockDiagnostic(stage, audible);
  assert.deepEqual(primitiveState(h.engine), before, 'Logging must not mutate primitive playback state');
  assert.equal(h.engine.pendingAudioTransition, transition);
  assert.equal(JSON.stringify(transition), beforeTransition);
  assert.equal(h.engine.productionClockSample, cache);
  assert.equal(JSON.stringify(cache), beforeCache);
  assert.equal(h.engine.renderer, renderer);
  assert.deepEqual(h.audioCalls, calls, 'Logging must not query or operate any audio API');
  const lines = h.logs.slice(priorCount).filter(line => line.startsWith('[ProductionClockDiag]'));
  assert.equal(lines.length, 1, 'One read-only snapshot must be logged per call');
  const fields = Object.fromEntries(Array.from(lines[0].matchAll(/(\w+)=([^ ]+)/g),
    match => [match[1], match[2]]));
  assert.equal(fields.stage, stage);
  return fields;
}

(async () => {
  // Assertions below exercise the real Engine cache and logger; no reimplemented
  // frame mapping is substituted for the source under test.
  const fresh = fixture();
  const rendered = fresh.engine.readRenderedStreamFrames(fresh.renderer, fresh.clock.now);
  near(rendered, 361752.3, 'Existing production frame read');
  const diagnostic = readLog(fresh);
  assert.equal(diagnostic.rendererEpoch, '7');
  assert.equal(diagnostic.streamId, '123');
  assert.equal(diagnostic.physicalStartCount, '1');
  assert.equal(diagnostic.originProven, 'true', 'The first start of a new renderer has a known raw zero');
  assert.equal(diagnostic.exactCalibrationOrigin, 'false',
    'A newly created renderer can have a known zero without prior mic calibration');
  assert.equal(diagnostic.sampleFresh, 'true');
  assert.equal(diagnostic.baseUpdate, 'retained');
  near(diagnostic.rawAgeMs, 12, 'Real ACTIVE-to-STARTUP timestamp age');
  near(diagnostic.legacyAgeMs, 15, 'Existing query-anchored production timestamp age');
  near(diagnostic.coordinateDeltaMs, 203, 'Same-sample raw/production coordinate delta');
  near(parseFloat(diagnostic.m), 203, 'Proven mapping offset');
  const rawTargetMonoMs = 99988 + (380000 - 352270.8) * 1000 / RATE;
  near(diagnostic.rawTargetMonoMs, rawTargetMonoMs, 'Target estimate on the raw frame clock');
  near(diagnostic.rawTargetMinusAudibleMs, rawTargetMonoMs - 101000,
    'Raw target error relative to the requested audible time');
  assert.equal(diagnostic.targetPending, 'true');
  assert.equal(diagnostic.targetEstimate, 'true', 'A raw-clock target estimate is not a measured crossing');

  for (const [name, change] of [
    ['restarted stream', h => { h.engine.rendererPhysicalStartCount = 2; }],
    ['unknown start count', h => { h.engine.rendererPhysicalStartCount = 0; }],
    ['dirty route', h => { h.engine.calibrationRouteResetPending = true; }],
    ['pending mic rebuild', h => { h.engine.micCalibrationRendererRebuildPending = true; }]
  ]) {
    const h = fixture();
    change(h);
    h.engine.readRenderedStreamFrames(h.renderer, h.clock.now);
    const d = readLog(h, name.replaceAll(' ', '-'));
    assert.equal(d.originProven, 'false', name);
    assert.equal(d.m, 'unprovenms', `${name} must not claim an acoustic offset`);
    assert.equal(d.rawTargetMonoMs, 'unproven', name);
    assert.equal(d.rawTargetMinusAudibleMs, 'unproven', name);
    near(d.coordinateDeltaMs, 203, `${name} may retain a plainly labelled coordinate delta`);
  }

  for (const [name, change] of [
    ['old cached query', h => { h.clock.now += 251; }],
    ['stale raw timestamp', h => { h.clock.rawAgeMs = 251; }],
    ['future raw timestamp', h => { h.clock.rawAgeMs = -51; }],
    ['invalid frame position', h => { h.clock.rawFrame = Number.NaN; }],
    ['negative frame position', h => { h.clock.rawFrame = -1; }],
    ['clamped legacy age', h => { h.engine.audioTimestampClockOffsetMs = -49700; }]
  ]) {
    const h = fixture();
    if (name === 'old cached query') {
      h.engine.readRenderedStreamFrames(h.renderer, h.clock.now);
      change(h);
    } else {
      change(h);
      h.engine.readRenderedStreamFrames(h.renderer, h.clock.now);
    }
    const d = readLog(h, name.replaceAll(' ', '-'));
    assert.equal(d.sampleFresh, 'false', name);
    assert.equal(d.m, 'unprovenms', name);
    assert.equal(d.rawTargetMonoMs, 'unproven', name);
  }

  for (const [name, change] of [
    ['missing sample', () => {}],
    ['timestamp unavailable', h => { h.clock.failTimestamp = true; }],
    ['legacy timestamp rejected', h => { h.clock.rawAgeMs = 2001; }],
    ['changed epoch', h => { h.engine.rendererEpoch++; }],
    ['changed stream ID', h => { h.engine.rendererStreamId++; }],
    ['changed physical start count', h => { h.engine.rendererPhysicalStartCount++; }],
    ['changed renderer availability', h => { h.engine.renderer = undefined; }],
    ['changed started state', h => { h.engine.rendererStarted = false; }],
    ['changed native state', h => { h.renderer.state = 3; }]
  ]) {
    const h = fixture();
    if (name.startsWith('changed')) h.engine.readRenderedStreamFrames(h.renderer, h.clock.now);
    change(h);
    if (name.includes('timestamp')) h.engine.readRenderedStreamFrames(h.renderer, h.clock.now);
    const d = readLog(h, name.replaceAll(' ', '-'));
    assert.equal(d.state, 'sample-unavailable', name);
    assert.equal(d.m, undefined, name);
    assert.equal(d.rawTargetMonoMs, undefined, name);
  }

  const noPending = fixture();
  noPending.engine.readRenderedStreamFrames(noPending.renderer, noPending.clock.now);
  noPending.engine.pendingAudioTransition = undefined;
  const noTarget = readLog(noPending, 'no-pending-transition');
  assert.equal(noTarget.targetPending, 'false');
  assert.equal(noTarget.rawTargetMonoMs, 'unproven');
  const wrongToken = fixture();
  wrongToken.engine.readRenderedStreamFrames(wrongToken.renderer, wrongToken.clock.now);
  wrongToken.engine.pendingAudioTransition.token++;
  const cancelledTarget = readLog(wrongToken, 'cancelled-transition');
  assert.equal(cancelledTarget.targetPending, 'false');
  assert.equal(cancelledTarget.rawTargetMonoMs, 'unproven');
  const invalidTarget = fixture();
  invalidTarget.engine.readRenderedStreamFrames(invalidTarget.renderer, invalidTarget.clock.now);
  invalidTarget.engine.pendingAudioTransition.targetFrame = Number.NaN;
  assert.equal(readLog(invalidTarget, 'invalid-target').rawTargetMonoMs, 'unproven');
  const invalidAudible = fixture();
  invalidAudible.engine.readRenderedStreamFrames(invalidAudible.renderer, invalidAudible.clock.now);
  assert.equal(readLog(invalidAudible, 'invalid-audible', Number.NaN).rawTargetMonoMs, 'unproven');
  const unavailableClock = fixture();
  unavailableClock.engine.readRenderedStreamFrames(unavailableClock.renderer, unavailableClock.clock.now);
  unavailableClock.clock.failUptime = true;
  assert.equal(readLog(unavailableClock, 'unavailable-clock').state, 'clock-domain-unavailable');

  const regressed = fixture();
  regressed.engine.lastAudioRawFrame = regressed.clock.rawFrame + 882;
  regressed.engine.lastRenderedStreamFrame = 362000;
  regressed.engine.readRenderedStreamFrames(regressed.renderer, regressed.clock.now);
  const regression = readLog(regressed, 'quantum-regression');
  assert.equal(regression.baseUpdate, 'raw-frame-regression',
    'Diagnostics must expose the existing production rebase even for one hardware quantum');
  near(regression.previousRawFrame, regressed.clock.rawFrame + 882, 'Previous raw frame preserved in the cache');
  near(regression.baseFrame, regressed.clock.rawFrame - 362000, 'Existing rebase value is recorded exactly');
  assert.ok(regressed.logs.some(line =>
    line.startsWith('[ProductionClockDiag] stage=frame-map state=base-update ') &&
    line.includes('reason=raw-frame-regression')),
  'A later read must not erase the evidence that production rebased on a hardware quantum');
  const resetCounter = fixture();
  resetCounter.engine.lastAudioRawFrame = resetCounter.clock.rawFrame + 883;
  resetCounter.engine.lastRenderedStreamFrame = 362000;
  resetCounter.engine.readRenderedStreamFrames(resetCounter.renderer, resetCounter.clock.now);
  assert.equal(readLog(resetCounter, 'counter-reset').originProven, 'false');
  assert.equal(resetCounter.engine.diagnosticRawOriginLost, true);
  resetCounter.clock.rawFrame += 882;
  resetCounter.engine.readRenderedStreamFrames(resetCounter.renderer, resetCounter.clock.now);
  assert.equal(readLog(resetCounter, 'after-counter-reset').m, 'unprovenms',
    'A later forward read does not prove the zero lost by a hardware counter reset');
  const initialized = fixture();
  initialized.engine.audioTimestampBaseReady = false;
  initialized.engine.readRenderedStreamFrames(initialized.renderer, initialized.clock.now);
  assert.equal(readLog(initialized, 'base-initialization').baseUpdate, 'elapsed-time-initialization');

  const cold = fixture();
  cold.engine.renderer = undefined;
  cold.engine.rendererStarted = false;
  cold.renderer.state = 1;
  cold.clock.rawFrame = 0;
  cold.clock.rawAgeMs = 0;
  await cold.engine.ensureRenderer();
  assert.equal(cold.engine.rendererPhysicalStartCount, 0, 'Creation resets diagnostic start metadata');
  await cold.engine.startAudioStreamNow(cold.clock.now + 1000, 0, 0, cold.engine.runToken);
  assert.equal(cold.engine.rendererPhysicalStartCount, 1);
  assert.ok(cold.logs.some(line => line.startsWith('[ProductionClockDiag] stage=cold-lock ')));
  assert.ok(cold.logs.some(line => line.startsWith('[ProductionClockDiag] stage=cold-settle ')));
  cold.engine.pause();
  cold.engine.running = true;
  cold.clock.now += 100;
  cold.engine.lastWriteProgressMs = cold.clock.now;
  const callsBeforeResume = cold.audioCalls.filter(call => call === 'start').length;
  await cold.engine.startAudioStream(cold.clock.now + 1000, 8, 0, cold.engine.runToken);
  assert.equal(cold.engine.rendererPhysicalStartCount, 1, 'Logical pause/resume retains the physical start count');
  assert.equal(cold.audioCalls.filter(call => call === 'start').length, callsBeforeResume);
  assert.ok(cold.logs.some(line => line.startsWith('[ProductionClockDiag] stage=continuous-play ')));

  const warm = fixture();
  warm.engine.renderer = undefined;
  warm.engine.rendererStarted = false;
  warm.renderer.state = 1;
  warm.clock.rawFrame = 0;
  warm.clock.rawAgeMs = 0;
  await warm.engine.warmUpRendererForPlayback();
  assert.equal(warm.engine.rendererPhysicalStartCount, 1, 'Silent warm-up counts an actual physical start');
  await warm.engine.startAudioStream(warm.clock.now + 1000, 0, 0, warm.engine.runToken);
  assert.ok(warm.logs.some(line => line.startsWith('[ProductionClockDiag] stage=continuous-play ')));
  await warm.engine.haltRendererNow();
  warm.engine.running = true;
  await warm.engine.startAudioStreamNow(warm.clock.now + 1000, 0, 0, warm.engine.runToken);
  assert.equal(warm.engine.rendererPhysicalStartCount, 2, 'Restarting an existing renderer loses proof of the raw frame zero');
  assert.ok(warm.logs.filter(line => line.startsWith('[ProductionClockDiag]')).at(-1).includes('m=unprovenms'));
  const oldEpoch = warm.engine.rendererEpoch;
  await warm.engine.flushCalibrationStreamBetweenProbes();
  assert.ok(warm.engine.rendererEpoch > oldEpoch);
  assert.equal(warm.engine.rendererPhysicalStartCount, 1,
    'A mic boundary creates a new renderer and counts only its first physical start');
  assert.equal(warm.engine.diagnosticRawOriginLost, false);
  assert.equal(warm.engine.productionClockSample, undefined,
    'A renderer boundary must discard the previous production diagnostic sample');
  console.log('PASS: production diagnostics reuse cached samples, preserve playback state and audio APIs, and distinguish proven starts from restarts');
})().catch(error => { console.error(error); process.exitCode = 1; });
