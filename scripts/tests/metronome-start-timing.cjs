// Run with DevEco's bundled Node and its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const RATE = 44100;
const ENGINE = path.resolve('entry/src/main/ets/audio/MetronomeEngine.ets');
const AUDIO_STATE = { STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_PAUSED: 5 };

function fixture({ compensationMs = 300, queueMs = 280, timestampAvailable = true,
  frameBiasFrames = 0, physicalLatencyMs = compensationMs, moduleMocks = {} } = {}) {
  let savedCompensationMs = compensationMs;
  let queueFrames = Math.round(queueMs * RATE / 1000);
  let now = 100000;
  const nativeStartedAt = now - 4000;
  let nextTimer = 1;
  const timers = new Map();
  const cache = new Map();
  const logs = [];
  const audioCalls = [];
  const renderer = {
    state: AUDIO_STATE.STATE_RUNNING,
    getLatency(type) { audioCalls.push(`latency:${type}`); return 285; },
    getAudioTimestampInfoSync() {
      audioCalls.push('timestamp');
      if (!timestampAvailable) throw new Error('Timestamp unavailable in this fixture');
      return { framePos: Math.round((now - nativeStartedAt) * RATE / 1000), timestamp: now * 1000000 };
    },
    getAudioStreamIdSync() { audioCalls.push('stream-id'); return 42; },
    getUnderflowCountSync() { audioCalls.push('underflow'); return 0; },
    getCurrentOutputDevicesSync() { audioCalls.push('devices'); return [{ deviceType: 8, id: 1 }]; },
    async start() { throw new Error('A warm transition must not physically restart its renderer'); },
    async stop() { throw new Error('A warm transition must not stop its renderer'); }
  };
  const mocks = {
    '@kit.AudioKit': { audio: {
      AudioState: AUDIO_STATE,
      AudioLatencyType: { LATENCY_TYPE_ALL: 'all', LATENCY_TYPE_HARDWARE: 'hardware', LATENCY_TYPE_SOFTWARE: 'software' },
      AudioDataCallbackResult: { VALID: 0 },
      getAudioManager: () => ({ getAudioSceneSync() { audioCalls.push('scene'); return 0; } })
    } },
    '@kit.BasicServicesKit': { systemDateTime: {
      TimeType: { STARTUP: 0, ACTIVE: 1 }, getUptime: () => now * 1000000
    } },
    BuildProfile: { DEBUG: false },
    ...moduleMocks
  };
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {};
    cache.set(file, exports);
    const context = {
      exports, console: { info: line => logs.push(line), warn: line => logs.push(line) },
      ArrayBuffer, Int16Array, DataView, Map, Promise,
      // Removing only dither makes the real synthesized click onset measurable.
      Math: Object.assign(Object.create(Math), { random: () => 0.5 }),
      setTimeout(callback, ms) {
        const id = nextTimer++;
        timers.set(id, { callback, dueAt: now + Math.max(0, ms) });
        return id;
      },
      clearTimeout: id => timers.delete(id),
      require(name) {
        if (mocks[name]) return mocks[name];
        if (name.endsWith('/MonotonicClock')) return { MonotonicClock: { nowMs: () => now } };
        if (name.endsWith('/AudioOutputMonitor')) return { AudioOutputMonitor: {
          isBluetoothA2dpActive: () => true, estimateBluetoothLinkLatencyMs: () => 240
        } };
        if (name.endsWith('/AudioLatencyPersistence')) return {
          getCalibrationMs: () => savedCompensationMs, getEffectiveCalibrationMs: () => savedCompensationMs,
          getInputLatencyMs: () => 52
        };
        if (name.endsWith('/DrumMachineCatalog') || name.endsWith('/DrumSampleBank')) return {};
        return load(path.resolve(path.dirname(file), `${name}.ets`));
      }
    };
    const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
    }, reportDiagnostics: true });
    assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
    vm.runInNewContext(compiled.outputText, context, { filename: file });
    return exports;
  }
  const engine = new (load(ENGINE).MetronomeEngine)();
  engine.configure(0, 0);
  engine.renderer = renderer;
  engine.rendererStarted = true;
  engine.rendererStartedAtLocalMs = nativeStartedAt;
  engine.rendererPhysicalStartCount = 1;
  engine.rendererEpoch = 9;
  engine.rendererStreamId = 42;
  engine.audioTimestampBaseReady = true;
  engine.audioTimestampBaseFrame = -frameBiasFrames;
  engine.audioTimestampClockOffsetMs = 0;
  engine.outputLatencyMs = compensationMs;
  engine.offsetMs = 0;
  const playedAt = () => Math.round((now - nativeStartedAt) * RATE / 1000);
  engine.audioSubmittedFrames = playedAt() + queueFrames;
  engine.lastRenderedStreamFrame = playedAt();
  engine.lastAudioRawFrame = playedAt();
  engine.queueDepthFrames = queueFrames;
  engine.lastWriteProgressMs = now;

  async function flushMicrotasks() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
  async function fireDueTimers() {
    const due = [...timers].filter(([, timer]) => timer.dueAt <= now);
    due.forEach(([id]) => timers.delete(id));
    due.forEach(([, timer]) => timer.callback());
    await flushMicrotasks();
  }
  function advanceKeepAlive(ms) {
    now += ms;
    const wantedSubmitted = playedAt() + queueFrames;
    assert.ok(wantedSubmitted >= engine.audioSubmittedFrames);
    engine.handleWriteData(new ArrayBuffer((wantedSubmitted - engine.audioSubmittedFrames) * 2));
    engine.lastWriteProgressMs = now;
  }
  return {
    engine, renderer, logs, audioCalls, fireDueTimers, flushMicrotasks, advanceKeepAlive,
    get now() { return now; },
    get physicalFrame() { return playedAt(); },
    // Model CPU work on the shared JS thread without synthesizing an extra
    // write callback; realtime-boundary tests inject render cost here.
    advanceClock(ms) { now += ms; },
    audibleAtFrame: frame => nativeStartedAt + frame * 1000 / RATE + physicalLatencyMs,
    setQueueFrames(frames) { queueFrames = frames; },
    setCompensationMs(ms) { savedCompensationMs = ms; },
    get compensationMs() { return savedCompensationMs; },
    queueMs
  };
}

async function startAndRender(h, arrivalDelayMs = 0, { timerDelayMs = 0, operationDelayMs = 0 } = {}) {
  const e = h.engine;
  const requestedAudibleAt = h.now + 650;
  // A late request can reach an already healthy, continuously written renderer.
  // This isolates insufficient scheduling headroom from native cold-start behavior.
  h.advanceKeepAlive(arrivalDelayMs);
  const logStart = h.logs.length;
  const callsStart = h.audioCalls.length;
  let releaseOperation;
  if (operationDelayMs > 0) {
    // An earlier serialized renderer operation can delay start while native
    // write callbacks continue; it is distinct from a late transport timer.
    const gate = new Promise(resolve => { releaseOperation = resolve; });
    void e.queueRendererOperation(async () => { await gate; });
  }
  await e.scheduleFromLeaderStart(requestedAudibleAt, 4, 0);
  h.advanceKeepAlive(timerDelayMs);
  await h.fireDueTimers();
  if (operationDelayMs > 0) {
    h.advanceKeepAlive(operationDelayMs);
    releaseOperation();
    await h.flushMicrotasks();
  }
  const requestAt = h.now;
  const submittedBefore = e.audioSubmittedFrames;
  const transition = e.pendingAudioTransition;
  assert.ok(transition, 'The public shared-clock API must install a real play transition');
  assert.equal(transition.outputLatencyMs, h.compensationMs);
  const requestedFrame = Math.round((requestedAudibleAt - h.compensationMs -
    e.rendererStartedAtLocalMs) * RATE / 1000);
  const sourceOnset = e.pendingSequence[0].samples.findIndex(sample => sample !== 0);
  assert.ok(sourceOnset >= 0, 'Use the actual synthesized click samples');
  const buffer = new ArrayBuffer((transition.targetFrame - submittedBefore + sourceOnset + 512) * 2);
  e.handleWriteData(buffer);
  const clickOffset = new Int16Array(buffer).findIndex(sample => sample !== 0);
  assert.equal(clickOffset, transition.targetFrame - submittedBefore + sourceOnset,
    'The real writeData buffer must contain the click at the selected frame');
  assert.equal(e.audioTimelineToken, e.runToken);
  return {
    token: e.runToken, revision: e.transportRevision, requestAt, requestedAudibleAt, requestedFrame,
    selectedFrame: transition.targetFrame, submittedBefore,
    clampMs: (transition.targetFrame - requestedFrame) * 1000 / RATE,
    audibleErrorMs: h.audibleAtFrame(submittedBefore + clickOffset - sourceOnset) - requestedAudibleAt,
    timerDelayMs, operationDelayMs,
    logs: h.logs.slice(logStart), calls: h.audioCalls.slice(callsStart)
  };
}

function diagnostic(result, stage) {
  const line = result.logs.find(item => item.startsWith('[StartTimingDiag]') &&
    item.includes(`stage=${stage} `));
  assert.ok(line, `A ${stage} diagnostic must describe the actual transition`);
  return Object.fromEntries([...line.matchAll(/(\w+)=([^\s]+)/g)].map(match => [match[1], match[2]]));
}

function near(actual, expected, label, tolerance = 0.11) {
  assert.ok(Number.isFinite(Number(actual)), `${label} must be a finite numeric diagnostic`);
  assert.ok(Math.abs(Number(actual) - expected) <= tolerance,
    `${label}: expected ${expected}, received ${actual}`);
}

function assertDiagnostics(result, h, mode = 'timestamp') {
  const scheduled = diagnostic(result, 'schedule');
  const timer = diagnostic(result, 'timer');
  const target = diagnostic(result, 'target');
  const applied = diagnostic(result, 'applied');
  for (const item of [scheduled, timer, target, applied]) {
    assert.equal(item.token, String(result.token));
    assert.equal(item.seq, scheduled.seq, 'One schedule sequence must join all four stages');
  }
  assert.equal(target.path, 'continuous');
  assert.equal(target.mode, mode);
  near(target.queryMonoMs, result.requestAt, 'mapping query time');
  near(target.targetHardwareMs, result.requestedAudibleAt - h.compensationMs, 'hardware deadline');
  near(target.audibleMs, result.requestedAudibleAt, 'shared audible deadline');
  near(target.compensationMs, h.compensationMs, 'saved compensation');
  near(target.requestedFrame, result.requestedFrame, 'unclamped requested frame', 0);
  near(target.submittedAtEstimate, result.submittedBefore, 'submitted frame at estimate', 0);
  near(target.selectedFrame, result.selectedFrame, 'selected target frame', 0);
  near(target.committedFrame, result.selectedFrame, 'committed target frame', 0);
  near(target.headroomMs, (result.requestedFrame - result.submittedBefore) * 1000 / RATE,
    'signed writable headroom');
  near(target.clampMs, Math.max(0, result.clampMs), 'target clamp');
  near(target.queueEstimateMs, h.queueMs, 'submitted queue estimate');
  near(target.remainingAudibleMs, result.requestedAudibleAt - result.requestAt,
    'remaining audible lead');
  near(target.timerLateMs, result.timerDelayMs, 'timer lateness');
  near(target.operationWaitMs, result.operationDelayMs, 'renderer operation wait');
  near(target.physicalStartCount, 1, 'persistent renderer start count', 0);
  assert.equal(target.audioClockLocked, 'false');
  near(applied.targetFrame, result.selectedFrame, 'applied frame', 0);
  near(applied.submittedFrame, result.selectedFrame, 'submitted frame at application', 0);
  near(applied.appliedMonoMs, result.requestAt, 'application callback time');
  near(applied.audibleLeadMs, result.requestedAudibleAt - result.requestAt, 'write callback audible lead');
  near(applied.estimatedFrameDeadlineDeltaMs,
    result.requestAt - (result.requestedAudibleAt - h.compensationMs), 'write versus frame deadline');
  near(applied.clampMs, Math.max(0, result.clampMs), 'applied clamp');
  return scheduled.seq;
}

async function main() {
  const warm = fixture();
  const first = await startAndRender(warm, 120);
  assert.ok(Math.abs(first.audibleErrorMs - 50) < 1 / RATE * 1000,
    'A 120ms arrival delay consumes 70ms headroom, then shifts actual PCM by 50ms');
  assert.equal(first.selectedFrame, first.submittedBefore);
  assert.equal(first.selectedFrame - first.requestedFrame, 2205);
  const firstSequence = assertDiagnostics(first, warm);

  const renderer = warm.engine.renderer;
  warm.engine.pause();
  warm.advanceKeepAlive(4000);
  const resumed = await startAndRender(warm);
  assert.ok(Math.abs(resumed.audibleErrorMs) <= 1 / RATE * 1000,
    'The same warm renderer with fresh lead time can align the next start');
  assert.equal(warm.engine.renderer, renderer);
  assert.equal(warm.engine.rendererPhysicalStartCount, 1);
  assert.ok(resumed.token > first.token);
  assert.ok(resumed.revision > first.revision);
  const resumedSequence = assertDiagnostics(resumed, warm);
  assert.notEqual(firstSequence, resumedSequence, 'Separate starts must remain distinguishable in logs');

  const largeQueue = fixture({ queueMs: 400 });
  const queued = await startAndRender(largeQueue);
  assert.ok(Math.abs(queued.audibleErrorMs - 50) < 1 / RATE * 1000,
    'Queue plus compensation can exceed the nominal lead even without request delay');
  assertDiagnostics(queued, largeQueue);
  const sufficientHarness = fixture();
  const sufficient = await startAndRender(sufficientHarness, 40);
  assert.ok(Math.abs(sufficient.audibleErrorMs) <= 1 / RATE * 1000);
  assertDiagnostics(sufficient, sufficientHarness);

  const fallbackHarness = fixture({ timestampAvailable: false });
  const fallback = await startAndRender(fallbackHarness, 120);
  assert.ok(Math.abs(fallback.audibleErrorMs - 50) < 1 / RATE * 1000);
  assertDiagnostics(fallback, fallbackHarness, 'fallback');

  const delayedHarness = fixture();
  const delayed = await startAndRender(delayedHarness, 0, { timerDelayMs: 80, operationDelayMs: 40 });
  assert.ok(Math.abs(delayed.audibleErrorMs - 50) < 1 / RATE * 1000);
  assertDiagnostics(delayed, delayedHarness);

  console.log('PASS: actual warm-renderer PCM and correlated diagnostics reproduce first-start 50ms clamp and aligned resume with unchanged calibration; queue, sufficient lead, fallback, timer lateness and operation wait covered');
}

module.exports = { fixture, startAndRender, diagnostic, RATE };
if (require.main === module) {
  main().catch(error => { console.error(error); process.exitCode = 1; });
}
