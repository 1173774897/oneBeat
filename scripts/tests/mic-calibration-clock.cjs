// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const RATE = 44100;
const QUANTUM = 882;
const START = 100000;
const BASE_FRAME = RATE * 8;
const result = ts.transpileModule(
  fs.readFileSync('entry/src/main/ets/audio/MetronomeEngine.ets', 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
assert.equal((result.diagnostics ?? [])
  .filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function quantizedFrame(elapsedMs, rate = RATE) {
  return BASE_FRAME + Math.floor(elapsedMs * rate / 1000 / QUANTUM) * QUANTUM;
}

function healthy(elapsedMs) {
  const framePos = quantizedFrame(elapsedMs);
  return { framePos, timestampMonoMs: START + elapsedMs, submittedFrames: framePos + RATE };
}

function primitiveState(engine) {
  return Object.fromEntries(Object.entries(engine)
    .filter(([key, value]) => !['audioSubmittedFrames', 'queueDepthFrames'].includes(key) &&
      (value === null || ['boolean', 'number', 'string', 'undefined'].includes(typeof value))));
}

function harness(sample = healthy) {
  const clock = { now: START };
  const logs = [];
  const timers = new Map();
  let timerId = 0;
  let engine;
  const audioState = { STATE_RUNNING: 2, STATE_PAUSED: 3 };
  const renderer = {
    state: audioState.STATE_RUNNING,
    getAudioTimestampInfoSync() {
      const current = sample(clock.now - START, h);
      if (current.submittedFrames !== undefined) engine.audioSubmittedFrames = current.submittedFrames;
      if (current.unavailable) throw new Error('hardware timestamp temporarily unavailable');
      return {
        framePos: current.framePos,
        timestamp: (current.timestampMonoMs - 50000) * 1000000
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
    './AudioOutputMonitor': { AudioOutputMonitor: { isBluetoothA2dpActive: () => false } },
    '../store/AudioLatencyPersistence': {},
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => clock.now } },
    './RhythmTimeline': { BuiltInRhythmFactory: { create: () => ({ beatsPerBar: 4 }) } },
    './DrumMachineCatalog': {}, './DrumSampleBank': {},
    '../common/MeterModel': { defaultBeatPointStates: () => [] }, BuildProfile: { DEBUG: false }
  };
  const context = {
    exports: {}, require(key) {
      assert.ok(Object.hasOwn(mocks, key), `Unexpected dependency ${key}`);
      return mocks[key];
    },
    console: { info: message => logs.push(message), warn: message => logs.push(message) },
    ArrayBuffer, Int16Array, Float64Array, DataView, Map,
    setTimeout(callback, delay) {
      const id = ++timerId;
      timers.set(id, { callback, dueAt: clock.now + Math.max(0, delay) });
      return id;
    },
    clearTimeout(id) { timers.delete(id); }
  };
  vm.runInNewContext(result.outputText, context);
  engine = new context.exports.MetronomeEngine();
  engine.renderer = renderer;
  engine.rendererStarted = true;
  engine.rendererStartedAtLocalMs = START - 8000;
  engine.calibrationFrameOriginExact = true;
  engine.audioTimestampBaseReady = true;
  engine.audioTimestampClockOffsetMs = -50000;
  engine.audioTimestampBaseFrame = -4410;
  engine.audioSubmittedFrames = BASE_FRAME + RATE;
  engine.rendererEpoch = 7;
  engine.rendererStreamId = 123;
  const h = { engine, renderer, clock, logs, timers, onAdvance: undefined };
  h.drive = async promise => {
    let done = false;
    let value;
    let failure;
    promise.then(result => { value = result; done = true; }, error => { failure = error; done = true; });
    for (let step = 0; !done && step < 1000; step++) {
      // Flush the VM's await chain before advancing the next due timer. This
      // models several immediate awaits without giving each one extra time.
      await new Promise(resolve => setImmediate(resolve));
      if (done) break;
      assert.ok(timers.size > 0, 'VM promise stalled without a scheduled timer');
      const [id, timer] = [...timers.entries()].sort((a, b) => a[1].dueAt - b[1].dueAt)[0];
      timers.delete(id);
      clock.now = Math.max(clock.now, timer.dueAt);
      h.onAdvance?.(clock.now - START);
      timer.callback();
    }
    assert.equal(done, true, 'Clock operation exceeded the virtual timer budget');
    if (failure) throw failure;
    return value;
  };
  return h;
}

async function read(h, name) {
  const before = primitiveState(h.engine);
  const value = await h.drive(h.engine.readStableCalibrationClock(h.renderer));
  assert.deepEqual(primitiveState(h.engine), before,
    `${name}: clock sampling must not rebuild or rebase normal playback`);
  assert.ok(h.logs.every(line => line.startsWith('[CalibClock] stage=pre-chirp ')),
    `${name}: diagnostics identify the failing calibration stage`);
  return value;
}

async function rejected(h, reason, name, elapsedMs) {
  assert.equal(await read(h, name), undefined, name);
  assert.ok(h.logs.some(line => line.includes(`state=rejected reason=${reason}`)),
    `${name}: logs must explain permanent rejection`);
  if (elapsedMs !== undefined) assert.equal(h.clock.now - START, elapsedMs, name);
}

async function timedOut(h, name, reason) {
  assert.equal(await read(h, name), undefined, name);
  assert.equal(h.clock.now - START, 4000, `${name}: recovery has one bounded deadline`);
  assert.ok(h.logs.some(line => line.includes('state=timeout')), `${name}: timeout diagnostics`);
  if (reason) assert.ok(h.logs.some(line => line.includes(`reason=${reason}`)), `${name}: reason`);
}

function schedulingHarness(sample = healthy) {
  const h = harness(sample);
  h.engine.ensureRenderer = async () => {};
  h.engine.ensureSilentRendererRunning = async requireExact => { assert.equal(requireExact, true); };
  h.engine.warmUpRenderQueueForCalibration = async () => {};
  h.engine.logMicCalibrationAudioStateForRenderer = () => ({ hardwareMs: 200 });
  let signal;
  h.assignments = [];
  Object.defineProperty(h.engine, 'calibrationSignal', {
    get: () => signal,
    set: value => {
      signal = value;
      if (value !== undefined) {
        h.assignments.push({ at: h.clock.now, value });
        value.submitMonoMs = h.clock.now;
        value.fullySubmitted = true;
      }
    }
  });
  h.crossings = [];
  h.engine.waitForCalibrationFrameCrossing = async (renderer, targetFrame, anchor, pendingSignal) => {
    assert.equal(renderer, h.renderer);
    assert.equal(pendingSignal, signal);
    assert.ok(h.logs.some(line => line.includes('stage=pre-chirp state=stable')),
      'Chirp frame crossing must only run after a stable hardware window');
    h.crossings.push({ targetFrame, anchor });
    return anchor.timestampMonoMs + (targetFrame - anchor.framePos) * 1000 / RATE;
  };
  return h;
}

(async () => {
  for (const phaseMs of [0, 3, 19]) {
    const h = harness(elapsed => {
      const framePos = quantizedFrame(elapsed + phaseMs);
      return { framePos, timestampMonoMs: START + elapsed, submittedFrames: framePos + RATE };
    });
    const value = await read(h, `Healthy 20 ms quantization phase ${phaseMs}`);
    assert.ok(value);
    assert.equal(h.clock.now - START, 400, 'Healthy clock waits for the full 400 ms window');
    assert.ok(h.logs.some(line => line.includes('state=stable') && line.includes('rateHz=44100.0')));
  }

  for (const durationMs of [500, 2000]) {
    const h = harness(elapsed => {
      const runningMs = Math.max(0, elapsed - durationMs);
      const framePos = quantizedFrame(runningMs);
      return {
        framePos, timestampMonoMs: elapsed < durationMs ? START : START + elapsed,
        submittedFrames: framePos + RATE
      };
    });
    assert.ok(await read(h, `Frozen timestamp and playhead for ${durationMs} ms`));
    assert.equal(h.clock.now - START, durationMs + 400,
      'A recovered clock must provide an entirely new 400 ms window');
    assert.ok(h.logs.some(line => line.includes('reason=timestamp-stale')));
  }

  const freshFrozen = harness(elapsed => {
    const framePos = quantizedFrame(Math.max(0, elapsed - 2000));
    return { framePos, timestampMonoMs: START + elapsed, submittedFrames: framePos + RATE };
  });
  assert.ok(await read(freshFrozen, 'Fresh timestamps with a two-second frozen playhead'));
  assert.equal(freshFrozen.clock.now - START, 2400);
  assert.ok(freshFrozen.logs.some(line => line.includes('reason=write-not-advancing')));

  for (const rate of [0, RATE * 0.5, RATE * 2]) {
    const h = harness(elapsed => {
      const framePos = quantizedFrame(elapsed, rate);
      return {
        framePos, timestampMonoMs: START + elapsed,
        submittedFrames: framePos + RATE + (rate === 0 ? Math.min(elapsed, 800) * RATE / 1000 : 0)
      };
    });
    await timedOut(h, `Permanent ${rate / RATE}x hardware rate`);
  }

  const frozenWrites = harness(elapsed => ({
    framePos: quantizedFrame(Math.min(elapsed, 200)),
    timestampMonoMs: START + elapsed,
    submittedFrames: BASE_FRAME + RATE * 2
  }));
  await timedOut(frozenWrites, 'Frozen writes with a bounded queue', 'write-not-advancing');
  const drainingFrozenWrites = harness(elapsed => ({
    framePos: quantizedFrame(elapsed), timestampMonoMs: START + elapsed,
    submittedFrames: BASE_FRAME + RATE * 2
  }));
  await rejected(drainingFrozenWrites, 'queue-out-of-range',
    'Continuously advancing hardware must reject a draining frozen write queue', 2060);

  for (const pendingKind of ['unavailable', 'stale']) {
    const h = harness(elapsed => {
      const current = healthy(elapsed);
      if (pendingKind === 'unavailable' && elapsed === 200) current.unavailable = true;
      if (pendingKind === 'stale' && elapsed >= 200 && elapsed <= 440) {
        current.timestampMonoMs = START + 180;
        current.framePos = quantizedFrame(180);
      }
      return current;
    });
    assert.ok(await read(h, `A ${pendingKind} sample resets the rate window`));
    assert.equal(h.clock.now - START, pendingKind === 'unavailable' ? 620 : 860,
      'Pre-pending rate progress must not be included in the recovered anchor');
  }

  const firstSlowWindow = harness(elapsed => {
    const runningMs = elapsed <= 400 ? elapsed * 0.5 : 200 + elapsed - 400;
    const framePos = quantizedFrame(runningMs);
    return { framePos, timestampMonoMs: START + elapsed, submittedFrames: framePos + RATE };
  });
  assert.ok(await read(firstSlowWindow, 'An initial implausible rate can recover'));
  assert.equal(firstSlowWindow.clock.now - START, 800);
  assert.ok(firstSlowWindow.logs.some(line => line.includes('reason=rate-not-stable')));

  for (const [name, change] of [
    ['changed renderer epoch', h => { h.engine.rendererEpoch++; }],
    ['changed stream id', h => { h.engine.rendererStreamId++; }],
    ['replaced renderer', h => { h.engine.renderer = { ...h.renderer }; }],
    ['route reset', h => { h.engine.calibrationRouteResetPending = true; }],
    ['mic rebuild', h => { h.engine.micCalibrationRendererRebuildPending = true; }],
    ['inexact clock epoch', h => { h.engine.calibrationFrameOriginExact = false; }],
    ['renderer stopped', h => { h.engine.rendererStarted = false; }],
    ['renderer state changed', h => { h.renderer.state = 3; }]
  ]) {
    const h = harness();
    h.onAdvance = elapsed => { if (elapsed === 100) change(h); };
    // These state changes are external route/lifecycle events, so the pure-read
    // state assertion applies to the clock method separately from that event.
    assert.equal(await h.drive(h.engine.readStableCalibrationClock(h.renderer)), undefined, name);
    assert.equal(h.clock.now - START, 100, `${name}: permanent changes fail immediately`);
    assert.ok(h.logs.some(line => line.includes('state=rejected reason=stream-invalidated')), name);
  }

  const oneQuantum = harness(elapsed => {
    const current = healthy(elapsed);
    if (elapsed === 200) current.framePos -= QUANTUM * 2;
    return current;
  });
  assert.ok(await read(oneQuantum, 'One hardware quantum of backward reading is discarded'));
  assert.equal(oneQuantum.clock.now - START, 620);
  assert.ok(oneQuantum.logs.some(line => line.includes('reason=frame-quantum-regression')));
  const grossRegression = harness(elapsed => {
    const current = healthy(elapsed);
    if (elapsed === 200) current.framePos -= QUANTUM * 3;
    return current;
  });
  await rejected(grossRegression, 'clock-invalid', 'A regression larger than one quantum', 200);
  const cumulativeRegression = harness(elapsed => {
    const current = healthy(elapsed);
    if (elapsed === 200) current.framePos = quantizedFrame(160);
    if (elapsed === 220) current.framePos = quantizedFrame(140);
    return current;
  });
  await rejected(cumulativeRegression, 'clock-invalid',
    'Repeated quantum regressions cannot drift behind the high-water frame', 220);
  const timestampRegression = harness(elapsed => {
    const current = healthy(elapsed);
    if (elapsed === 200) current.timestampMonoMs = START + 178;
    return current;
  });
  await rejected(timestampRegression, 'clock-invalid', 'A timestamp regressing by more than 1 ms', 200);
  await rejected(harness(elapsed => ({ ...healthy(elapsed), timestampMonoMs: START + elapsed + 51 })),
    'clock-invalid', 'A timestamp in the wrong future clock domain', 0);
  for (const framePos of [NaN, Infinity]) {
    await rejected(harness(elapsed => ({ ...healthy(elapsed), framePos })),
      'clock-invalid', 'Nonfinite hardware frames must never become an anchor', 0);
  }
  for (const queueMs of [-51, 2501]) {
    await rejected(harness(elapsed => {
      const current = healthy(elapsed);
      current.submittedFrames = current.framePos + queueMs * RATE / 1000;
      return current;
    }), 'queue-out-of-range', `Impossible queue ${queueMs} ms`, 0);
  }

  const canceled = harness();
  canceled.onAdvance = elapsed => { if (elapsed === 100) canceled.engine.pause(); };
  assert.equal(await canceled.drive(canceled.engine.readStableCalibrationClock(canceled.renderer)), undefined);
  assert.equal(canceled.clock.now - START, 100);
  assert.ok(canceled.logs.some(line => line.includes('state=rejected') && line.includes('cancelled=true')));

  const warmupCanceled = schedulingHarness();
  warmupCanceled.engine.warmUpRenderQueueForCalibration = async () => {
    await new Promise(resolve => {
      warmupCanceled.timers.set(9999, {
        dueAt: warmupCanceled.clock.now + 100,
        callback: () => { warmupCanceled.engine.pause(); resolve(); }
      });
    });
  };
  await assert.rejects(warmupCanceled.drive(warmupCanceled.engine.scheduleCalibrationSignalExclusive(
    new Int16Array(32), START + 1000)), /未取得稳定的音频硬件时间戳/);
  assert.equal(warmupCanceled.assignments.length, 0,
    'Cancellation during warmup must not later install a chirp');

  const neverReady = schedulingHarness(elapsed => ({ ...healthy(elapsed), unavailable: true }));
  await assert.rejects(neverReady.drive(neverReady.engine.scheduleCalibrationSignalExclusive(
    new Int16Array(32), START + 1000)), /未取得稳定的音频硬件时间戳/);
  assert.equal(neverReady.clock.now - START, 4000);
  assert.equal(neverReady.assignments.length, 0, 'A timed-out clock must not enqueue a chirp');
  const scheduled = schedulingHarness();
  const timing = await scheduled.drive(scheduled.engine.scheduleCalibrationSignalExclusive(
    new Int16Array(32), START + 2000));
  assert.equal(scheduled.assignments.length, 1);
  assert.equal(scheduled.assignments[0].at - START, 400,
    'The scheduling transaction must wait for the real stable clock method');
  assert.equal(scheduled.crossings.length, 1);
  assert.equal(timing.presentationMonoMs, START + 2000);
  assert.equal(timing.hardwareLatencyMs, 200);

  console.log('PASS: actual Engine bounds pre-chirp clock recovery, rejects invalid streams, and prevents scheduling after cancellation');
})().catch(error => { console.error(error); process.exitCode = 1; });
