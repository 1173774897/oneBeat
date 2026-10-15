// Run with DevEco's bundled Node and its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const ts = require(process.argv[2]);

const RATE = 44100;
const ENGINE_PATH = 'entry/src/main/ets/audio/MetronomeEngine.ets';
// This commit was verified on devices before the uncommitted mic investigation.
const BASELINE = '56c9e55';
const sources = {
  baseline: execFileSync('git', ['show', `${BASELINE}:${ENGINE_PATH}`], { encoding: 'utf8' }),
  current: fs.readFileSync(ENGINE_PATH, 'utf8')
};
const compiled = {};
for (const [name, source] of Object.entries(sources)) {
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0,
    `${name} must transpile`);
  compiled[name] = result.outputText;
}

function fixture(version, route, micExact) {
  const clock = { now: 100000 };
  const trace = [];
  const logs = [];
  const rendererStartedAt = clock.now - 4000;
  const timestampOrigin = 700000;
  const audioState = { STATE_RUNNING: 2, STATE_PAUSED: 5 };
  const renderer = {
    state: audioState.STATE_RUNNING,
    getLatency(type) {
      trace.push(`latency:${type}`);
      // Diagnostic calls take time too; matching only the resulting saved value
      // would miss extra hot-path queries that shift the scheduling timestamp.
      clock.now += 2;
      return { all: route.all, hardware: route.hardware, software: route.all - route.hardware }[type];
    },
    getAudioTimestampInfoSync() {
      trace.push('timestamp');
      const result = {
        framePos: timestampOrigin + Math.round((clock.now - rendererStartedAt - route.queueMs) * RATE / 1000),
        timestamp: (clock.now - 50000 - 12) * 1000000
      };
      clock.now += 0.1;
      return result;
    },
    getCurrentOutputDevicesSync() { trace.push('output-devices'); return []; }
  };
  const mocks = {
    '@kit.AudioKit': { audio: {
      AudioState: audioState,
      AudioLatencyType: { LATENCY_TYPE_ALL: 'all', LATENCY_TYPE_HARDWARE: 'hardware', LATENCY_TYPE_SOFTWARE: 'software' },
      getAudioManager: () => ({ getAudioSceneSync: () => { trace.push('scene'); return 0; } })
    } },
    '@kit.BasicServicesKit': { systemDateTime: {
      TimeType: { STARTUP: 0, ACTIVE: 1 },
      getUptime: type => (clock.now - (type === 1 ? 50000 : 0)) * 1000000
    } },
    './ClickSound': {
      ACCENT_DURATION_MS: 20, WEAK_DURATION_MS: 10,
      ClickSound: { buildAccentBuffer: () => new ArrayBuffer(2), buildWeakBuffer: () => new ArrayBuffer(2) }
    },
    './AudioOutputMonitor': { AudioOutputMonitor: {
      isBluetoothA2dpActive: () => route.bluetooth,
      estimateBluetoothLinkLatencyMs: () => 240
    } },
    '../store/AudioLatencyPersistence': {
      getEffectiveCalibrationMs: () => route.saved,
      getCalibrationMs: () => route.saved,
      getInputLatencyMs: () => 62
    },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => clock.now } },
    './RhythmTimeline': { BuiltInRhythmFactory: { create: () => ({ beatsPerBar: 4 }) } },
    './DrumMachineCatalog': {},
    './DrumSampleBank': {},
    '../common/MeterModel': { defaultBeatPointStates: () => [] },
    BuildProfile: { DEBUG: false }
  };
  const deterministicMath = Object.create(Math);
  deterministicMath.random = () => 0.5;
  const context = {
    exports: {}, require: name => {
      assert.ok(name in mocks, `Missing mock for ${name}`);
      return mocks[name];
    },
    console: { info: text => logs.push(text), warn: text => logs.push(text) },
    ArrayBuffer, Map, Int16Array, Math: deterministicMath,
    setTimeout(callback, delay) { clock.now += delay; callback(); return 1; },
    clearTimeout() {}
  };
  vm.runInNewContext(compiled[version], context);
  const { MetronomeEngine } = context.exports;
  const engine = new MetronomeEngine();
  engine.renderer = renderer;
  engine.rendererStarted = true;
  engine.rendererStartedAtLocalMs = rendererStartedAt;
  engine.running = true;
  engine.runToken = 3;
  engine.lastWriteProgressMs = clock.now;
  engine.audioSubmittedFrames = 200000;
  engine.outputLatencyMs = Math.max(0, route.saved);
  engine.offsetMs = -12345;
  engine.transportStartLocalMs = clock.now + 1300;
  engine.calibrationFrameOriginExact = micExact;
  const samples = new Int16Array(RATE * 2);
  samples[0] = 15000;
  samples[RATE / 2] = 10000;
  const bar = { samples, frameCount: samples.length, samplesPerBeat: RATE / 2, beatsPerBar: 4 };
  engine.pendingSequence = [bar];
  engine.activeSequence = [bar];
  engine.activeRevision = 0;
  engine.pendingRevision = 0;
  return { engine, Engine: MetronomeEngine, renderer, clock, trace, logs };
}

async function run(version, route, micExact, entry, compensation) {
  const f = fixture(version, route, micExact);
  const e = f.engine;
  const audible = e.transportStartLocalMs;
  if (entry === 'continuous') {
    await e.startAudioStream(audible, 4, 0, e.runToken, compensation);
  } else if (entry === 'clock-lock') {
    e.pendingAudioTransition = {
      kind: 'play', token: e.runToken, targetFrame: e.audioSubmittedFrames + 50000,
      beatIndex: 4, countInBeats: 0, outputLatencyMs: e.outputLatencyMs
    };
    await e.lockAudioStartToPresentationClock(f.renderer, audible, f.clock.now,
      e.runToken, compensation);
  } else {
    await e.settleOutputLatency(f.renderer, audible, 4, 0, e.runToken, compensation);
  }
  const transition = e.pendingAudioTransition;
  assert.ok(transition, `${entry} must schedule a play transition`);
  const scheduled = JSON.parse(JSON.stringify(transition));
  // Render across the actual transition: checking only a computed target would
  // miss a changed origin or content cursor when that target enters writeData.
  const pcm = new ArrayBuffer((transition.targetFrame - e.audioSubmittedFrames + 32) * 2);
  e.fillAudioData(pcm);
  return {
    scheduled,
    lead: e.audioTimelineLeadFrames,
    submitted: e.audioSubmittedFrames,
    cursor: e.audioFrameCursor,
    token: e.audioTimelineToken,
    queue: e.queueDepthFrames,
    baseFrame: e.audioTimestampBaseFrame,
    clockOffset: e.audioTimestampClockOffsetMs,
    renderedFrame: e.lastRenderedStreamFrame,
    firstClick: Array.from(new Int16Array(pcm)).findIndex(sample => sample !== 0),
    now: f.clock.now,
    trace: f.trace,
    // The added clock snapshot is read-only observability. Retain every prior
    // log and the full audio API trace so diagnostics cannot hide a hot-path change.
    logs: f.logs.filter(text => !text.startsWith('[ProductionClockDiag]')),
    mapExact: e.lastAudioFrameMapExact ?? false
  };
}

(async () => {
  const routes = [
    { name: 'AirPods', bluetooth: true, all: 205, hardware: 200, queueMs: 240, saved: 49.8 },
    { name: 'FreeBuds', bluetooth: true, all: 285, hardware: 280, queueMs: 280, saved: 363 },
    { name: 'speaker', bluetooth: false, all: 45, hardware: 40, queueMs: 200, saved: 363 }
  ];
  let comparisons = 0;
  for (const route of routes) {
    for (const micExact of [false, true]) {
      for (const entry of ['continuous', 'clock-lock', 'settle']) {
        for (const compensation of [0, route.saved, undefined]) {
          const baseline = await run('baseline', route, micExact, entry, compensation);
          const current = await run('current', route, micExact, entry, compensation);
          assert.deepEqual(current, baseline,
            `${route.name}/${entry}/micExact=${micExact}/compensation=${compensation}`);
          assert.equal(current.mapExact, false, 'Mic history must not enable experimental playback mapping');
          comparisons++;
        }
      }
    }
    const zero = await run('current', route, true, 'continuous', 0);
    const compensated = await run('current', route, true, 'continuous', 200);
    assert.ok(Math.abs(zero.scheduled.targetFrame - compensated.scheduled.targetFrame - 8820) <= 1,
      'A 200ms override must move the scheduled content by 200ms in the same renderer coordinate');
    assert.ok(Math.abs(zero.lead - compensated.lead) <= 1,
      'The compensated audio playhead origin must retain the same audible target');
  }

  // The saved Bluetooth zero and uncalibrated platform fallback are separate
  // contracts; restoring the old hot path must preserve both.
  for (const bluetooth of [false, true]) {
    for (const saved of [-1, 0, 49.8, 363]) {
      const route = { bluetooth, saved, all: 205, hardware: 200, queueMs: 240 };
      const head = fixture('baseline', route, false);
      const current = fixture('current', route, true);
      const headValue = head.Engine.readOutputLatencyOffsetMs(head.renderer);
      const currentValue = current.Engine.readOutputLatencyOffsetMs(current.renderer);
      assert.equal(currentValue, headValue);
      assert.deepEqual(current.trace, head.trace);
      assert.equal(current.clock.now, head.clock.now);
      assert.deepEqual(current.logs, head.logs);
    }
  }

  const mic = fixture('current', routes[0], true);
  const rawClock = mic.engine.readCalibrationClockSample(mic.renderer);
  assert.ok(rawClock, 'The disabled playback experiment must not disable mic hardware timestamps');
  assert.ok(rawClock.framePos > 700000, 'Mic calibration retains the absolute raw renderer frame');
  assert.equal(rawClock.timestampMonoMs, 99988,
    'Mic keeps its ACTIVE-to-STARTUP timestamp conversion instead of the playback query-time anchor');
  console.log(`PASS: ${comparisons} playback paths match ${BASELINE} targets, PCM origins and API traces; compensation and route fallback preserved`);
})().catch(error => { console.error(error); process.exitCode = 1; });
