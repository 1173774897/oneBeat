// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const RATE = 44100;
const compiled = {};
for (const name of ['MetronomeEngine', 'MicLoopbackCalibrator']) {
  const source = fs.readFileSync(`entry/src/main/ets/audio/${name}.ets`, 'utf8');
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  compiled[name] = result.outputText;
}

function near(actual, expected, message, tolerance = 0.2) {
  assert.ok(Math.abs(actual - expected) <= tolerance,
    `${message}: expected ${expected}, received ${actual}`);
}

function load(name, mocks, timer = callback => { queueMicrotask(callback); return 1; }) {
  const context = {
    exports: {}, require(key) {
      assert.ok(Object.hasOwn(mocks, key), `Unexpected dependency ${key}`);
      return mocks[key];
    },
    console: { info() {}, warn() {} },
    ArrayBuffer, Int16Array, Float64Array, DataView, Map,
    setTimeout: timer, clearTimeout() {}
  };
  vm.runInNewContext(compiled[name], context);
  return context.exports;
}

function engineHarness(mappingOffsetMs, timestampAgeMs = 0) {
  const clock = { now: 100000, timestampAgeMs };
  const physicalOriginMs = 92000;
  const audioState = { STATE_RUNNING: 2 };
  const renderer = {
    state: audioState.STATE_RUNNING,
    getAudioTimestampInfoSync() {
      const sampleAt = clock.now - clock.timestampAgeMs;
      return {
        framePos: Math.round((sampleAt - physicalOriginMs) * RATE / 1000),
        timestamp: (sampleAt - 50000) * 1000000
      };
    }
  };
  const mocks = {
    '@kit.AudioKit': { audio: { AudioState: audioState } },
    '@kit.BasicServicesKit': { systemDateTime: {
      TimeType: { STARTUP: 0, ACTIVE: 1 },
      getUptime: type => (clock.now - (type === 1 ? 50000 : 0)) * 1000000
    } },
    './ClickSound': {
      ACCENT_DURATION_MS: 20, WEAK_DURATION_MS: 10,
      ClickSound: { buildAccentBuffer: () => new ArrayBuffer(2), buildWeakBuffer: () => new ArrayBuffer(2) }
    },
    './AudioOutputMonitor': { AudioOutputMonitor: { isBluetoothA2dpActive: () => true } },
    '../store/AudioLatencyPersistence': {},
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => clock.now } },
    './RhythmTimeline': { BuiltInRhythmFactory: { create: () => ({ beatsPerBar: 4 }) } },
    './DrumMachineCatalog': {}, './DrumSampleBank': {},
    '../common/MeterModel': { defaultBeatPointStates: () => [] }, BuildProfile: { DEBUG: false }
  };
  const engine = new (load('MetronomeEngine', mocks).MetronomeEngine)();
  engine.renderer = renderer;
  engine.rendererStarted = true;
  engine.rendererStartedAtLocalMs = physicalOriginMs;
  engine.calibrationFrameOriginExact = true;
  engine.audioTimestampBaseReady = true;
  engine.audioTimestampClockOffsetMs = -50000;
  engine.audioTimestampBaseFrame = -mappingOffsetMs * RATE / 1000;
  engine.audioSubmittedFrames = Math.round((clock.now - physicalOriginMs + 1000) * RATE / 1000);
  engine.rendererEpoch = 7;
  engine.rendererStreamId = 123;
  return { engine, clock, renderer, physicalOriginMs };
}

function primitiveState(engine) {
  return Object.fromEntries(Object.entries(engine)
    .filter(([, value]) => value === null || ['boolean', 'number', 'string', 'undefined'].includes(typeof value)));
}

function syntheticCapture(chirp, durationMs, signals) {
  const samples = Array.from({ length: Math.ceil(durationMs * RATE / 1000) }, () => 0);
  for (const { onsetMs, amplitude = 0.5 } of signals) {
    const start = Math.round(onsetMs * RATE / 1000);
    for (let i = 0; i < chirp.length; i++) {
      samples[start + i] += chirp[i] / 32768 * amplitude;
    }
  }
  return samples;
}

function calibratorHarness(probes = [], options = {}) {
  const clock = { now: 10000 };
  let calibrator;
  let calls = 0;
  let boundaries = 0;
  let releases = 0;
  const mocks = {
    '@kit.AudioKit': { audio: {
      AudioSamplingRate: { SAMPLE_RATE_44100: RATE }, AudioChannel: { CHANNEL_1: 1 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 }
    } },
    '@kit.BasicServicesKit': {},
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => clock.now } }
  };
  const timer = (callback, delay) => {
    clock.now += delay;
    if (calibrator && calibrator.captureStartMonoMs < 0) {
      calibrator.captureStartMonoMs = clock.now - 100;
    }
    queueMicrotask(callback);
    return 1;
  };
  calibrator = new (load('MicLoopbackCalibrator', mocks, timer).MicLoopbackCalibrator)();
  calibrator.createStartedCapturer = async () => ({
    async stop() {},
    async release() {
      releases++;
      if (options.cancelOnRelease) calibrator.cancel();
      if (options.releaseFails) throw new Error('synthetic release failure');
    }
  });
  calibrator.waitWhileActive = async (_generation, duration) => {
    clock.now += Math.max(0, duration);
    return true;
  };
  const playSignal = async (_signal, presentationMonoMs) => {
    const probe = probes[calls++];
    assert.ok(probe, `Unexpected probe ${calls}`);
    const onsetMs = presentationMonoMs - calibrator.captureStartMonoMs + probe.rawRoundTripMs;
    calibrator.captured = syntheticCapture(calibrator.chirp,
      onsetMs + 650, probe.noSignal ? [] : [{ onsetMs }]);
    return {
      presentationMonoMs,
      hardwareLatencyMs: probe.hardwareLatencyMs ?? 40,
      playbackReference: probe.noReference ? undefined : {
        rendererEpoch: 100 + calls, streamId: 200 + calls,
        frameMappingOffsetMs: probe.mappingOffsetMs ?? 0,
        sampledAtMonoMs: clock.now
      }
    };
  };
  return {
    calibrator, playSignal,
    boundary: async () => { boundaries++; },
    calls: () => calls, boundaries: () => boundaries, releases: () => releases
  };
}

function probe(rawRoundTripMs, mappingOffsetMs = 0, extra = {}) {
  return { rawRoundTripMs, mappingOffsetMs, ...extra };
}

(async () => {
  // Real Engine scheduling plus a known physical clock checks the bridge sign.
  // A formula-only test would pass even if production uses a different mapping.
  for (const mappingOffsetMs of [-200, -50, 0, 213, 333]) {
    const h = engineHarness(mappingOffsetMs);
    const targetAudibleMs = h.clock.now + 3000;
    const beforeTarget = h.engine.estimateTargetStreamFrame(targetAudibleMs);
    const beforeState = primitiveState(h.engine);
    const reference = h.engine.readMicCalibrationPlaybackReference();
    near(reference.frameMappingOffsetMs, mappingOffsetMs, 'Bridge coordinate difference');
    assert.equal(reference.rendererEpoch, 7);
    assert.equal(reference.streamId, 123);
    assert.deepEqual(primitiveState(h.engine), beforeState, 'Bridge reads must not mutate production state');
    assert.equal(h.engine.estimateTargetStreamFrame(targetAudibleMs), beforeTarget,
      'Bridge reads must not change the normal target frame');
    const inputMs = 62;
    const physicalOutputMs = 280;
    const rawRoundTripMs = physicalOutputMs + inputMs;
    const compensation = rawRoundTripMs - inputMs + reference.frameMappingOffsetMs;
    const targetFrame = h.engine.estimateTargetStreamFrame(targetAudibleMs - compensation);
    const actualAudibleMs = h.physicalOriginMs + targetFrame * 1000 / RATE + physicalOutputMs;
    near(actualAudibleMs, targetAudibleMs, 'Mapped compensation closes the physical playback loop');
    const unbridgedFrame = h.engine.estimateTargetStreamFrame(targetAudibleMs - physicalOutputMs);
    const unbridgedAudibleMs = h.physicalOriginMs + unbridgedFrame * 1000 / RATE + physicalOutputMs;
    near(unbridgedAudibleMs - targetAudibleMs, mappingOffsetMs, 'Unbridged result leaves the coordinate bias');
    const advancedFrame = h.engine.estimateTargetStreamFrame(targetAudibleMs - 200);
    near((beforeTarget - advancedFrame) * 1000 / RATE, 200, 'Normal compensation response remains intact');
  }

  for (const [name, invalidate] of [
    ['dirty route', h => { h.engine.calibrationRouteResetPending = true; }],
    ['pending rebuild', h => { h.engine.micCalibrationRendererRebuildPending = true; }],
    ['uninitialized legacy base', h => { h.engine.audioTimestampBaseReady = false; }],
    ['missing clock offset', h => { h.engine.audioTimestampClockOffsetMs = undefined; }],
    ['inexact raw epoch', h => { h.engine.calibrationFrameOriginExact = false; }],
    ['old timestamp', h => { h.clock.timestampAgeMs = 251; }],
    ['regressed raw frame', h => { h.engine.lastAudioRawFrame = 400000; }],
    ['stopped renderer', h => { h.engine.rendererStarted = false; }]
  ]) {
    const h = engineHarness(200);
    invalidate(h);
    const state = primitiveState(h.engine);
    assert.throws(() => h.engine.readMicCalibrationPlaybackReference(), undefined, name);
    assert.deepEqual(primitiveState(h.engine), state, `${name} must fail without rebasing production`);
  }

  const stale = engineHarness(200, 251);
  assert.throws(() => stale.engine.readMicCalibrationPlaybackReference(),
    error => error.name === 'MicPlaybackClockPendingError' && error.reason === 'timestamp-stale',
    'An aged sample must remain rejected, but explicitly allow bounded recovery');
  const future = engineHarness(200, -51);
  assert.throws(() => future.engine.readMicCalibrationPlaybackReference(),
    error => error.name !== 'MicPlaybackClockPendingError',
    'An invalid clock domain must not be retried as an ordinary transition');
  const identityFirst = engineHarness(200);
  const priorReference = identityFirst.engine.readMicCalibrationPlaybackReference();
  identityFirst.clock.timestampAgeMs = 600;
  identityFirst.engine.rendererEpoch++;
  assert.throws(() => identityFirst.engine.readMicCalibrationPlaybackReference(priorReference),
    /基准发生变化/, 'A stale timestamp must not hide an epoch change');

  const direct = calibratorHarness().calibrator;
  const withOldChirp = syntheticCapture(direct.chirp, 2200,
    [{ onsetMs: 500, amplitude: 1 }, { onsetMs: 1300, amplitude: 0.25 }]);
  const correlation = await direct.analyzeCaptured(withOldChirp, 0, 1000);
  assert.equal(correlation.detected, true);
  near(correlation.latencyMs, 300, 'A stronger previous chirp is excluded by the raw causal window');
  const negativeMappingCapture = syntheticCapture(direct.chirp, 1700, [{ onsetMs: 1110 }]);
  const physical = await direct.analyzeCaptured(negativeMappingCapture, 0, 1000);
  const wrongReference = await direct.analyzeCaptured(negativeMappingCapture, 0, 1300);
  assert.equal(physical.detected, true);
  near(physical.latencyMs, 110, 'Raw correlation remains valid for a negative production offset');
  assert.equal(wrongReference.detected, false, 'The production reference must not become the causal-window anchor');

  const outlier = calibratorHarness([
    probe(300), probe(300, 0), probe(310, 20), probe(305, 40), probe(900, 333)
  ]);
  const outlierResult = await outlier.calibrator.measureWithPersistentRenderer(
    outlier.playSignal, undefined, outlier.boundary);
  assert.equal(outlierResult.detected, true);
  assert.equal(outlierResult.validRuns, 3);
  near(outlierResult.latencyMs, 305, 'Raw acoustic outlier is excluded');
  assert.equal(outlierResult.playbackReference.rendererEpoch, 105,
    'The excluded last probe still owns the retained production renderer');
  assert.equal(outlierResult.playbackReference.frameMappingOffsetMs, 333,
    'Offsets from released earlier epochs must not be median-pooled');
  near(outlierResult.latencyMs - 62 + outlierResult.playbackReference.frameMappingOffsetMs,
    576, 'Saved compensation uses the final epoch after taking the raw median');
  assert.equal(outlier.calls(), outlier.boundaries());
  assert.equal(outlier.releases(), 1);

  const lowSnrTail = calibratorHarness([
    probe(300), probe(300), probe(305), probe(310),
    ...Array.from({ length: 5 }, (_, i) => probe(300, 100 + i * 10, { noSignal: true }))
  ]);
  const tailResult = await lowSnrTail.calibrator.measureWithPersistentRenderer(
    lowSnrTail.playSignal, undefined, lowSnrTail.boundary);
  assert.equal(tailResult.detected, true);
  assert.equal(tailResult.validRuns, 3);
  assert.equal(tailResult.playbackReference.rendererEpoch, 109,
    'A low-SNR last attempt still replaces the retained renderer');
  assert.equal(tailResult.playbackReference.frameMappingOffsetMs, 140);

  const boundaryCluster = calibratorHarness([
    probe(300), ...[300, 310, 320, 330].map(value => probe(value))
  ]);
  const boundaryResult = await boundaryCluster.calibrator.measureWithPersistentRenderer(boundaryCluster.playSignal);
  assert.equal(boundaryResult.detected, true, 'A cluster at the accepted 30ms spread boundary remains usable');
  near(boundaryResult.spreadMs, 30, 'Accepted cluster spread');

  for (const values of [[300, 350, 400, 450], [300, 350, 400], [300, 310, 320, 330.2]]) {
    const invalid = calibratorHarness([
      probe(300), ...values.map(value => probe(value)),
      ...Array.from({ length: 8 - values.length }, () => probe(300, 0, { noSignal: true }))
    ]);
    const result = await invalid.calibrator.measureWithPersistentRenderer(
      invalid.playSignal, undefined, invalid.boundary);
    assert.equal(result.detected, false, 'High-SNR but unstable round trips must not be saved');
    assert.ok(result.spreadMs > 30);
  }

  const missingLastReference = calibratorHarness([
    probe(300), probe(300, 10), probe(300, 20), probe(300, 30),
    probe(300, 0, { noReference: true })
  ]);
  const missingResult = await missingLastReference.calibrator.measureWithPersistentRenderer(missingLastReference.playSignal);
  assert.equal(missingResult.playbackReference, undefined,
    'A missing final-epoch reference must not reuse an earlier epoch');

  const input = calibratorHarness([
    probe(102, -900), probe(103, 333), probe(101, 200)
  ]);
  const inputResult = await input.calibrator.measureInputLatency(input.playSignal, undefined, input.boundary);
  assert.equal(inputResult.detected, true);
  near(inputResult.inputLatencyMs, 62, 'Input calibration subtracts only physical HARDWARE, without production mapping');
  near(inputResult.roundTripMs, 102, 'Input reports physical raw round trip');
  assert.equal(Object.hasOwn(inputResult, 'playbackReference'), false);

  // A new run must clear a prior headphone reference even before it gets a timing.
  input.calibrator.lastPlaybackReference = outlierResult.playbackReference;
  input.calibrator.createStartedCapturer = async () => { throw new Error('new input failed to start'); };
  await assert.rejects(input.calibrator.measureInputLatency(input.playSignal), /new input failed/);
  assert.equal(input.calibrator.lastPlaybackReference, undefined);
  const retry = calibratorHarness();
  retry.calibrator.lastPlaybackReference = outlierResult.playbackReference;
  retry.calibrator.createStartedCapturer = async () => { throw new Error('new headphone failed to start'); };
  await assert.rejects(retry.calibrator.measureWithPersistentRenderer(retry.playSignal), /new headphone failed/);
  assert.equal(retry.calibrator.lastPlaybackReference, undefined);

  for (const stage of ['input', 'headphone']) {
    const probes = stage === 'input'
      ? [probe(102), probe(102), probe(102)]
      : Array.from({ length: 5 }, () => probe(300));
    const h = calibratorHarness(probes, { releaseFails: true });
    const operation = stage === 'input'
      ? h.calibrator.measureInputLatency(h.playSignal)
      : h.calibrator.measureWithPersistentRenderer(h.playSignal);
    await assert.rejects(operation, /录音流未能关闭/, `${stage} must fail closed when capturer release fails`);
    assert.equal(h.calibrator.capturer, undefined);
  }
  const cancelledRelease = calibratorHarness([probe(102), probe(102), probe(102)],
    { releaseFails: true, cancelOnRelease: true });
  await cancelledRelease.calibrator.measureInputLatency(cancelledRelease.playSignal);

  console.log('PASS: actual mic correlation, stable raw clusters, final renderer identity, input isolation and read-only production bridge close the physical playback loop');
})().catch(error => { console.error(error); process.exitCode = 1; });
