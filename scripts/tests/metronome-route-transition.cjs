// Run with DevEco's bundled Node and typescript/lib/typescript.js as argv[2].
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const RATE = 44100;
const AUDIO_STATE = { STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_PAUSED: 5 };
const SOURCE = path.resolve('entry/src/main/ets/audio/MetronomeEngine.ets');
const ENGINE_SOURCE_OVERRIDE = process.env.METRONOME_ROUTE_ENGINE_SOURCE;

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function harness(bluetooth = true) {
  let now = 10000;
  let nativeStartedAt = 6000;
  let nextTimer = 1;
  const timers = new Map();
  const trace = [];
  const logs = [];
  const cache = new Map();
  let stopGate;
  let startGate;
  let writesEnabled = true;
  const renderer = {
    state: AUDIO_STATE.STATE_RUNNING,
    getAudioStreamIdSync: () => 42,
    getLatency: () => bluetooth ? 205 : 45,
    getUnderflowCountSync: () => 0,
    getCurrentOutputDevices: async () => [{ deviceType: bluetooth ? 8 : 2, id: 1 }],
    getAudioTimestampInfoSync: () => ({
      framePos: 123456 + Math.round((now - nativeStartedAt) * RATE / 1000),
      timestamp: now * 1000000
    }),
    stop: async () => {
      trace.push('stop');
      if (stopGate) await stopGate.promise;
      renderer.state = AUDIO_STATE.STATE_STOPPED;
    },
    flush: async () => { trace.push('flush'); },
    start: async () => {
      trace.push('start');
      if (startGate) await startGate.promise;
      nativeStartedAt = now;
      renderer.state = AUDIO_STATE.STATE_RUNNING;
    }
  };
  const mocks = {
    '@kit.AudioKit': { audio: {
      AudioState: AUDIO_STATE,
      AudioLatencyType: { LATENCY_TYPE_ALL: 1, LATENCY_TYPE_HARDWARE: 2, LATENCY_TYPE_SOFTWARE: 3 },
      AudioDataCallbackResult: { VALID: 0 },
      getAudioManager: () => ({ getAudioSceneSync: () => 0 })
    } },
    '@kit.BasicServicesKit': { systemDateTime: {
      TimeType: { STARTUP: 0, ACTIVE: 1 }, getUptime: () => now * 1000000
    } },
    BuildProfile: { DEBUG: false }
  };
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {};
    cache.set(file, exports);
    const context = {
      exports, console: { info: message => logs.push(message), warn: message => logs.push(message) },
      ArrayBuffer, Int16Array, DataView, Map, Promise,
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
          isBluetoothA2dpActive: () => bluetooth, estimateBluetoothLinkLatencyMs: () => 240
        } };
        if (name.endsWith('/AudioLatencyPersistence')) return {
          getCalibrationMs: () => 300, getEffectiveCalibrationMs: () => 300, getInputLatencyMs: () => 52
        };
        if (name.endsWith('/DrumMachineCatalog') || name.endsWith('/DrumSampleBank')) return {};
        return load(path.resolve(path.dirname(file), `${name}.ets`));
      }
    };
    const sourcePath = file === SOURCE && ENGINE_SOURCE_OVERRIDE ? ENGINE_SOURCE_OVERRIDE : file;
    const compiled = ts.transpileModule(fs.readFileSync(sourcePath, 'utf8'), { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
    }, reportDiagnostics: true });
    assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
    vm.runInNewContext(compiled.outputText, context, { filename: file });
    return exports;
  }
  const engine = new (load(SOURCE).MetronomeEngine)();
  engine.configure(0, 0);
  engine.renderer = renderer;
  engine.rendererStarted = true;
  engine.rendererStartedAtLocalMs = nativeStartedAt;
  engine.rendererPhysicalStartCount = 1;
  engine.rendererStreamId = 42;
  engine.running = true;
  engine.runToken = 7;
  engine.transportRevision = 9;
  engine.transportBpm = 120;
  engine.transportBeatsPerBar = 4;
  engine.transportStartLocalMs = 1200;
  engine.transportStartBeatIndex = 0;
  engine.transportCountInBeats = 4;
  engine.transportCountInDurationMs = 2000;
  engine.beatIndex = 18;
  engine.nextBeatAtMs = 10200;
  engine.audioSubmittedFrames = 200000;
  engine.audioTimestampBaseReady = true;
  engine.audioTimestampBaseFrame = 123456;
  engine.audioTimestampClockOffsetMs = 0;
  engine.outputLatencyMs = bluetooth ? 300 : 45;
  engine.audioTimelineOutputLatencyMs = engine.outputLatencyMs;
  engine.lastWriteProgressMs = now;
  engine.prepareAudioCursor(17, 0);
  engine.mainStartBeatIndex = 4;
  engine.audioFrameCursor += 12000;
  engine.audioStreaming = true;
  engine.audioTimelineToken = engine.runToken;
  engine.audioSequenceTransportRevision = engine.transportRevision;

  async function flushMicrotasks() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
  async function advance(ms) {
    now += ms;
    const due = [...timers].filter(([, item]) => item.dueAt <= now);
    due.forEach(([id]) => timers.delete(id));
    due.forEach(([, item]) => item.callback());
    await flushMicrotasks();
    if (writesEnabled && renderer.state === AUDIO_STATE.STATE_RUNNING) {
      engine.handleWriteData(new ArrayBuffer(Math.round(ms * RATE / 1000) * 2));
    }
    await flushMicrotasks();
  }
  async function settle(task, limitMs = 5000) {
    let done = false;
    let value;
    let error;
    Promise.resolve(task).then(result => { value = result; done = true; }, err => { error = err; done = true; });
    await flushMicrotasks();
    for (let elapsed = 0; !done && elapsed <= limitMs; elapsed += 20) await advance(20);
    assert.ok(done, 'Route operation must complete within its bound');
    if (error) throw error;
    return value;
  }
  function snapshot() {
    return {
      token: engine.runToken, revision: engine.transportRevision, anchor: engine.transportStartLocalMs,
      startBeat: engine.transportStartBeatIndex, countIn: engine.transportCountInBeats,
      beat: engine.beatIndex, nextBeat: engine.nextBeatAtMs
    };
  }
  return {
    engine, renderer, trace, logs, timers, snapshot, settle, advance, flushMicrotasks,
    setRoute: value => { bluetooth = value; },
    setStopGate: gate => { stopGate = gate; }, setStartGate: gate => { startGate = gate; },
    setWrites: value => { writesEnabled = value; },
    jumpClock: ms => { now += ms; },
    writeBuffer(frames) {
      const data = new ArrayBuffer(frames * 2);
      engine.handleWriteData(data);
      return new Int16Array(data);
    },
    get now() { return now; }
  };
}

// The cases below exercise route changes through the public route transition
// API and then render the actual source across its selected frame boundary.
async function changeRoute(h, bluetooth) {
  h.setRoute(bluetooth);
  h.engine.refreshOutputCalibration(true);
  return h.engine.rescheduleForOutputRouteChange();
}

function assertTransportRetained(h, before) {
  const after = h.snapshot();
  assert.deepEqual({ revision: after.revision, anchor: after.anchor, startBeat: after.startBeat, countIn: after.countIn },
    { revision: before.revision, anchor: before.anchor, startBeat: before.startBeat, countIn: before.countIn },
    'A physical output change must retain the logical team count-in and shared anchor');
  assert.ok(after.token > before.token, 'Only local asynchronous scheduling ownership is renewed');
  assert.ok(after.beat >= before.beat, 'The visual team beat must continue forwards');
  assert.equal(after.nextBeat - before.nextBeat, (after.beat - before.beat) * 500,
    'UI beat progression must retain the same team grid');
  assert.equal(h.engine.running, true);
}

function assertRephasedPcm(h, before, compensation, selectedSource) {
  const e = h.engine;
  const transition = e.pendingAudioTransition;
  assert.ok(transition, 'A route switch must produce a real audio transition');
  assert.equal(transition.kind, 'play');
  assert.equal(transition.token, e.runToken);
  assert.equal(transition.outputLatencyMs, compensation);
  assert.ok(transition.targetFrame >= e.audioSubmittedFrames);
  assert.ok(transition.beatIndex >= before.beat, 'Route recovery must select a future shared beat');

  const interval = 60000 / e.transportBpm;
  const selectedAt = before.nextBeat + (transition.beatIndex - before.beat) * interval;
  assert.ok(Math.abs(transition.hardwareAtLocalMs - (selectedAt - compensation)) <= 1,
    'The synchronous expiry deadline must describe the selected shared hardware beat');
  // Inspect the exact mapping used to commit the target. A simulated native
  // restart can clamp renderedFrames until the first callback submits its data;
  // a later read would then compare a different instantaneous queue boundary.
  const mapping = e.productionClockSample;
  const mappedAt = mapping?.queryMonoMs ?? h.now;
  const played = mapping?.renderedFrame ?? e.readRenderedStreamFrames(h.renderer, h.now);
  const targetAt = mappedAt + (transition.targetFrame - played) * 1000 / RATE + compensation;
  assert.ok(Math.abs(targetAt - selectedAt) <= 1,
    `New PCM target must map back to its existing shared beat (${targetAt} vs ${selectedAt})`);

  const start = e.audioSubmittedFrames;
  const offset = transition.targetFrame - start;
  const countIn = transition.beatIndex < before.startBeat + before.countIn;
  const expectedSamples = selectedSource ? selectedSource(transition.beatIndex).samples :
    countIn ? e.renderCountInBar(before.countIn).samples :
    e.pendingSequence[0].samples;
  const expectedCursor = selectedSource ? selectedSource(transition.beatIndex).cursor :
    countIn ? Math.round((transition.beatIndex - before.startBeat) * RATE / 2) :
    Math.round((transition.beatIndex % 4) * RATE / 2);
  const pcm = new ArrayBuffer((offset + 128) * 2);
  e.fillAudioData(pcm);
  const rendered = new Int16Array(pcm);
  assert.deepEqual(Array.from(rendered.subarray(offset, offset + 128)),
    Array.from(expectedSamples.subarray(expectedCursor, expectedCursor + 128)),
    'The callback must render the selected real beat, rather than continue the old PCM cursor');
  assert.ok(rendered.subarray(offset, offset + 128).some(sample => Math.abs(sample) > 100));
  assert.equal(e.audioTimelineToken, e.runToken);
  const elapsedFrames = Math.round((selectedAt - before.anchor) * RATE / 1000);
  assert.ok(Math.abs(e.audioTimelineLeadFrames -
    (transition.targetFrame + Math.round(compensation * RATE / 1000) - elapsedFrames)) <= 1,
  'Rephasing must retain the original audio playhead origin for subsequent phase locking');
  assert.equal(e.pendingAudioTransition, undefined);
}

function observe(request) {
  const result = { settled: false, value: undefined, error: undefined };
  request.then(value => { result.settled = true; result.value = value; }, error => {
    result.settled = true; result.error = error;
  });
  return result;
}

async function awaitScheduled(h, request, limitMs = 5000) {
  const result = observe(request);
  await h.flushMicrotasks();
  for (let elapsed = 0; !h.engine.pendingAudioTransition?.routeRephase && elapsed <= limitMs; elapsed += 20) {
    if (result.settled) {
      if (result.error) throw result.error;
      assert.fail('Route request completed before installing its pending PCM target');
    }
    await h.advance(20);
  }
  assert.equal(h.engine.pendingAudioTransition?.routeRephase, true,
    'The route request must install its future PCM target within the preparation bound');
  await h.flushMicrotasks();
  assert.equal(result.settled, false, 'Success must wait for actual target application, not only scheduling');
  return result;
}

async function completeRoutePcm(h, request, before, compensation, selectedSource) {
  await awaitScheduled(h, request);
  assertTransportRetained(h, before);
  assertRephasedPcm(h, before, compensation, selectedSource);
  assert.equal(await h.settle(request), true, 'Route success must follow real PCM application');
}

async function assertFrozenPendingRoute(recoveryMode) {
  const h = harness(true);
  const e = h.engine;
  const before = h.snapshot();
  const request = changeRoute(h, false);
  const outcome = await awaitScheduled(h, request);
  const original = { ...e.pendingAudioTransition };
  const originalAudibleAt = before.anchor + original.timelineElapsedFrames * 1000 / RATE;
  const applications = [];
  const apply = e.applyAudioTransition.bind(e);
  e.applyAudioTransition = transition => {
    if (transition.routeRephase) applications.push({ ...transition, appliedAt: h.now });
    apply(transition);
  };

  h.setWrites(false);
  if (recoveryMode === 'watchdog-first') {
    for (let i = 0; i < 100; i++) await h.advance(20);
    assert.ok(e.beatIndex > before.beat, 'UI beats must keep advancing during the write freeze');
  } else {
    // A suspended JS event loop cannot run the watchdog before the native
    // callback returns. Reject expired PCM synchronously within fillAudioData.
    h.jumpClock(2000);
    const firstBuffer = h.writeBuffer(original.targetFrame - e.audioSubmittedFrames + 128);
    assert.ok(firstBuffer.every(sample => Math.abs(sample) <= 1),
      'The first callback after a suspended timer must contain dither, never the expired route beat');
    assert.notEqual(e.pendingAudioTransition?.targetFrame, original.targetFrame);
  }
  assert.ok(h.now > originalAudibleAt);
  assert.equal(outcome.settled, false,
    'A route request must remain unresolved until a fresh target actually reaches the PCM callback');
  assert.equal(e.audioStreaming, false);
  assert.equal(applications.length, 0, 'An expired pending beat must never be applied');

  h.setWrites(true);
  await h.flushMicrotasks();
  for (let elapsed = 0; elapsed <= 4000; elapsed += 20) {
    const transition = e.pendingAudioTransition;
    if (transition?.routeRephase && transition.targetFrame !== original.targetFrame &&
      transition.beatIndex > original.beatIndex) break;
    if (outcome.settled) {
      if (outcome.error) throw outcome.error;
      assert.fail('Freeze recovery resolved without installing a new future PCM target');
    }
    await h.advance(20);
  }
  const replacement = e.pendingAudioTransition;
  assert.ok(replacement?.routeRephase);
  assert.ok(replacement.beatIndex > original.beatIndex,
    'Resumed output must skip the expired shared beat and choose a future beat');
  const replacementAudibleAt = before.anchor + replacement.timelineElapsedFrames * 1000 / RATE;
  assert.ok(replacementAudibleAt > h.now + replacement.outputLatencyMs,
    'The replacement hardware deadline must still be in the future');
  assert.equal(e.runToken, original.token, 'The same route owner must finish its own stalled target');
  assertTransportRetained(h, before);
  assertRephasedPcm(h, before, 45);
  assert.equal(await h.settle(request), true);
  assert.equal(applications.length, 1);
  assert.equal(applications[0].beatIndex, replacement.beatIndex);
  assert.notEqual(applications[0].targetFrame, original.targetFrame);
}

(async () => {
  await assertFrozenPendingRoute('watchdog-first');
  await assertFrozenPendingRoute('callback-first');
  for (const toBluetooth of [false, true]) {
    const h = harness(!toBluetooth);
    const before = h.snapshot();
    await completeRoutePcm(h, changeRoute(h, toBluetooth), before, toBluetooth ? 300 : 45);
  }

  const roundTrip = harness(true);
  const roundTripBefore = roundTrip.snapshot();
  await completeRoutePcm(roundTrip, changeRoute(roundTrip, false), roundTripBefore, 45);
  const speakerBefore = roundTrip.snapshot();
  await completeRoutePcm(roundTrip, changeRoute(roundTrip, true), speakerBefore, 300);

  const focusResume = harness(true);
  const focusBefore = focusResume.snapshot();
  const routePreparing = changeRoute(focusResume, false);
  await focusResume.flushMicrotasks();
  assert.equal(focusResume.engine.outputRouteRephasePreparing, true,
    'This focus event must occur while native route preparation owns scheduling');
  const preparationToken = focusResume.engine.runToken;
  const preparationTrace = [...focusResume.trace];
  await focusResume.engine.recoverAudio('focus resumed');
  assert.equal(focusResume.engine.runToken, preparationToken,
    'Focus resume during preparation must not cancel the route owner');
  assert.deepEqual(focusResume.trace, preparationTrace,
    'Focus resume must not issue a second native stop/start during route preparation');
  await awaitScheduled(focusResume, routePreparing);
  assertTransportRetained(focusResume, focusBefore);
  const firstRouteTarget = focusResume.engine.pendingAudioTransition.targetFrame;
  assert.equal(focusResume.engine.pendingAudioTransition.routeRephase, true);
  const pendingFocusBefore = focusResume.snapshot();
  await focusResume.settle(focusResume.engine.recoverAudio('focus resumed'));
  assert.deepEqual(focusResume.snapshot(), pendingFocusBefore,
    'The owner must retain its installed pending target when focus resumes');
  assert.equal(focusResume.engine.pendingAudioTransition.routeRephase, true,
    'Focus recovery before submission must preserve the route-specific seek and shared playhead mapping');
  assert.equal(focusResume.engine.pendingAudioTransition.targetFrame, firstRouteTarget,
    'The pending owner monitors its own deadline; focus recovery must not replace it');
  assert.equal(focusResume.trace.filter(operation => operation === 'start').length, 0,
    'A healthy renderer must retain its physical stream across both focus events');
  assertRephasedPcm(focusResume, pendingFocusBefore, 45);
  assert.equal(await focusResume.settle(routePreparing), true);

  const countIn = harness(true);
  countIn.engine.transportStartLocalMs = 11000;
  countIn.engine.transportStartBeatIndex = 0;
  countIn.engine.transportCountInBeats = 4;
  countIn.engine.transportCountInDurationMs = 2000;
  countIn.engine.nextBeatAtMs = 11000;
  countIn.engine.beatIndex = 0;
  countIn.engine.audioStreaming = false;
  countIn.engine.audioTimelineToken = -1;
  countIn.engine.audioSequenceTransportRevision = -1;
  const countInBefore = countIn.snapshot();
  await completeRoutePcm(countIn, changeRoute(countIn, false), countInBefore, 45);

  const remainingCountIn = harness(true);
  remainingCountIn.engine.transportStartLocalMs = 9000;
  remainingCountIn.engine.nextBeatAtMs = 10500;
  remainingCountIn.engine.beatIndex = 3;
  remainingCountIn.engine.prepareAudioCursor(0, 4);
  remainingCountIn.engine.audioFrameCursor = 3 * RATE / 2;
  remainingCountIn.engine.audioSubmittedFrames = 180810;
  remainingCountIn.engine.audioTimelineOutputLatencyMs = 50;
  const remainingBefore = remainingCountIn.snapshot();
  const remainingRequest = changeRoute(remainingCountIn, false);
  await awaitScheduled(remainingCountIn, remainingRequest);
  assertTransportRetained(remainingCountIn, remainingBefore);
  assert.ok(remainingCountIn.engine.pendingAudioTransition.beatIndex < 4,
    'This fixture must resume within the original count-in rather than after it');
  assertRephasedPcm(remainingCountIn, remainingBefore, 45);
  assert.equal(await remainingCountIn.settle(remainingRequest), true);

  // Calibration owns its own compensation and must not be rephased by this
  // production-only API, even when its override is exactly zero.
  for (const compensation of [0, 50]) {
    const override = harness(true);
    override.engine.transportOutputCompensationOverrideMs = compensation;
    const overrideBefore = override.snapshot();
    assert.equal(await override.settle(changeRoute(override, false)), false);
    assert.deepEqual(override.snapshot(), overrideBefore);
    assert.equal(override.engine.pendingAudioTransition, undefined);
  }

  const multiBar = harness(true);
  function sourceBars(levels) {
    return levels.map(level => {
    const samples = new Int16Array(RATE * 2);
    for (let beat = 0; beat < 4; beat++) samples[beat * RATE / 2] = level + beat * 500;
    return { samples, frameCount: samples.length, samplesPerBeat: RATE / 2, beatsPerBar: 4 };
    });
  }
  const bars = sourceBars([5000, 10000, 15000]);
  multiBar.engine.pendingSequence = bars;
  multiBar.engine.activeSequence = bars;
  multiBar.engine.activeBar = bars[0];
  multiBar.engine.mainStartBeatIndex = 4;
  multiBar.engine.activeSequenceIndex = 0;
  multiBar.engine.activeLoopStartIndex = 0;
  multiBar.engine.activeSequenceLooping = true;
  const multiBefore = multiBar.snapshot();
  await completeRoutePcm(multiBar, changeRoute(multiBar, false), multiBefore, 45, beat => {
    const mainBeat = beat - 4;
    return { samples: bars[Math.floor(mainBeat / 4) % bars.length].samples, cursor: (mainBeat % 4) * RATE / 2 };
  });

  // A local route token may change twice before PCM resumes. That must not
  // make a still-owned old program look abandoned and apply a pending edit.
  const pendingEdit = harness(true);
  const oldBars = sourceBars([6000, 12000]);
  const editedBars = sourceBars([18000, 24000]);
  pendingEdit.engine.activeSequence = oldBars;
  pendingEdit.engine.activeBar = oldBars[0];
  pendingEdit.engine.activeSequenceIndex = 0;
  pendingEdit.engine.activeLoopStartIndex = 0;
  pendingEdit.engine.activeSequenceLooping = true;
  pendingEdit.engine.pendingSequence = editedBars;
  pendingEdit.engine.activeRevision = 1;
  pendingEdit.engine.pendingRevision = 2;
  pendingEdit.engine.deferPendingSequenceActivation = true;
  const editBefore = pendingEdit.snapshot();
  const oldEditRequest = changeRoute(pendingEdit, false);
  await awaitScheduled(pendingEdit, oldEditRequest);
  const newEditRequest = changeRoute(pendingEdit, true);
  await awaitScheduled(pendingEdit, newEditRequest);
  assertTransportRetained(pendingEdit, editBefore);
  assertRephasedPcm(pendingEdit, editBefore, 300, beat => {
    const mainBeat = beat - 4;
    return { samples: oldBars[Math.floor(mainBeat / 4) % oldBars.length].samples, cursor: (mainBeat % 4) * RATE / 2 };
  });
  assert.deepEqual(await pendingEdit.settle(Promise.all([oldEditRequest, newEditRequest])), [false, true]);
  assert.equal(pendingEdit.engine.activeSequence, oldBars);
  assert.equal(pendingEdit.engine.pendingSequence, editedBars);
  assert.equal(pendingEdit.engine.deferPendingSequenceActivation, true,
    'Two output switches must not activate an intentionally deferred drum edit');

  const pausedPending = harness(true);
  const pausedPendingRequest = changeRoute(pausedPending, false);
  await awaitScheduled(pausedPending, pausedPendingRequest);
  const sharedPauseAt = pausedPending.now + 1000;
  pausedPending.engine.schedulePauseFromLeader(sharedPauseAt);
  const sharedPauseTransition = pausedPending.engine.pendingAudioTransition;
  assert.equal(sharedPauseTransition.kind, 'pause');
  assert.equal(await pausedPending.settle(pausedPendingRequest), false,
    'A shared pause must cancel the unsubmitted route target');
  assert.equal(pausedPending.engine.pendingAudioTransition, sharedPauseTransition,
    'The cancelled route watcher must not clear the newer shared pause transition');
  const pauseFrames = sharedPauseTransition.targetFrame - pausedPending.engine.audioSubmittedFrames;
  const pausedPendingPcm = new ArrayBuffer((pauseFrames + 128) * 2);
  pausedPending.engine.fillAudioData(pausedPendingPcm);
  assert.equal(pausedPending.engine.audioStreaming, false);
  assert.ok(new Int16Array(pausedPendingPcm).subarray(pauseFrames).every(sample => Math.abs(sample) <= 1));
  await pausedPending.advance(sharedPauseAt - pausedPending.now);
  assert.equal(pausedPending.engine.running, false);

  for (const toBluetooth of [false, true]) {
    const pendingPause = harness(!toBluetooth);
    const pauseAt = pendingPause.now + 1800;
    pendingPause.engine.schedulePauseFromLeader(pauseAt);
    const pauseBefore = pendingPause.snapshot();
    await pendingPause.settle(changeRoute(pendingPause, toBluetooth));
    assertTransportRetained(pendingPause, pauseBefore);
    const transition = pendingPause.engine.pendingAudioTransition;
    assert.equal(transition.kind, 'pause', 'A scheduled team pause must take precedence over route resumption');
    assert.equal(transition.outputLatencyMs, toBluetooth ? 300 : 45);
    const played = pendingPause.engine.readRenderedStreamFrames(pendingPause.renderer, pendingPause.now);
    assert.ok(Math.abs(pendingPause.now + (transition.targetFrame - played) * 1000 / RATE +
      transition.outputLatencyMs - pauseAt) < 1, 'Pause retains its original shared audible deadline');
    const remaining = transition.targetFrame - pendingPause.engine.audioSubmittedFrames;
    const pcm = new ArrayBuffer((remaining + 128) * 2);
    pendingPause.engine.fillAudioData(pcm);
    assert.equal(pendingPause.engine.audioStreaming, false);
    assert.ok(new Int16Array(pcm).subarray(remaining).every(sample => Math.abs(sample) <= 1),
      'Actual PCM after the pause boundary must contain only dither');
    await pendingPause.advance(pauseAt - pendingPause.now);
    assert.equal(pendingPause.engine.running, false, 'Route warm-up must not cancel the shared pause timer');
  }

  const pauseWhileWarming = harness(true);
  const warming = changeRoute(pauseWhileWarming, false);
  await pauseWhileWarming.flushMicrotasks();
  const warmingPauseAt = pauseWhileWarming.now + 100;
  pauseWhileWarming.engine.schedulePauseFromLeader(warmingPauseAt);
  await pauseWhileWarming.settle(warming);
  await pauseWhileWarming.advance(warmingPauseAt - pauseWhileWarming.now);
  assert.equal(pauseWhileWarming.engine.running, false);
  assert.equal(pauseWhileWarming.engine.audioStreaming, false,
    'A pause reached during warm-up must prevent a late route play transition');
  assert.notEqual(pauseWhileWarming.engine.pendingAudioTransition?.kind, 'play');

  const paused = harness(true);
  paused.engine.pause();
  const pausedBefore = paused.snapshot();
  await paused.settle(changeRoute(paused, false));
  assert.deepEqual(paused.snapshot(), pausedBefore, 'Changing output while paused must not start a transport');
  assert.equal(paused.engine.running, false);
  assert.equal(paused.engine.pendingAudioTransition, undefined);

  const cancelled = harness(true);
  cancelled.renderer.state = AUDIO_STATE.STATE_PAUSED;
  const stop = deferred();
  cancelled.setStopGate(stop);
  const pending = changeRoute(cancelled, false);
  await cancelled.flushMicrotasks();
  cancelled.engine.pause();
  stop.resolve();
  await cancelled.settle(pending);
  assert.equal(cancelled.engine.running, false);
  assert.equal(cancelled.engine.audioStreaming, false);
  assert.equal(cancelled.engine.pendingAudioTransition, undefined,
    'Native completion after a user pause must not revive the obsolete route playback');

  const reversed = harness(true);
  reversed.renderer.state = AUDIO_STATE.STATE_PAUSED;
  const reversingStop = deferred();
  reversed.setStopGate(reversingStop);
  const reverseBefore = reversed.snapshot();
  const speakerPending = changeRoute(reversed, false);
  await reversed.flushMicrotasks();
  const bluetoothPending = changeRoute(reversed, true);
  reversingStop.resolve();
  const reversedRequests = Promise.all([speakerPending, bluetoothPending]);
  await awaitScheduled(reversed, reversedRequests);
  assertTransportRetained(reversed, reverseBefore);
  assertRephasedPcm(reversed, reverseBefore, 300);
  assert.deepEqual(await reversed.settle(reversedRequests), [false, true]);

  const cold = harness(true);
  cold.renderer.state = AUDIO_STATE.STATE_PAUSED;
  cold.engine.rendererStarted = false;
  const nativeStart = deferred();
  cold.setStartGate(nativeStart);
  const initialToken = cold.engine.runToken;
  const initialStart = cold.engine.startAudioStream(11200, 20, 0, initialToken);
  await cold.flushMicrotasks();
  assert.ok(cold.trace.includes('start'));
  const coldBefore = cold.snapshot();
  const reroutedCold = changeRoute(cold, false);
  nativeStart.resolve();
  const coldRequests = Promise.all([initialStart, reroutedCold]);
  await awaitScheduled(cold, coldRequests);
  assertTransportRetained(cold, coldBefore);
  assertRephasedPcm(cold, coldBefore, 45);
  assert.deepEqual(await cold.settle(coldRequests), [undefined, true]);

  const finished = harness(true);
  finished.engine.activeSequenceFinished = true;
  const finishedBefore = finished.snapshot();
  assert.equal(await finished.settle(changeRoute(finished, false)), false);
  assert.deepEqual(finished.snapshot(), finishedBefore);
  assert.equal(finished.engine.pendingAudioTransition, undefined,
    'An already finished finite sequence must not be revived by a route change');

  const stalled = harness(true);
  stalled.setWrites(false);
  await assert.rejects(stalled.settle(changeRoute(stalled, false)), /未收到音频写入/);
  assert.equal(stalled.engine.pendingAudioTransition, undefined);
  assert.equal(stalled.engine.audioStreaming, false,
    'No write callback within the route bound must fail silent instead of applying a stale phase');

  for (const timeoutBeforeRetry of [false, true]) {
    const nativeHang = harness(true);
    nativeHang.renderer.state = AUDIO_STATE.STATE_PAUSED;
    const neverStopped = deferred();
    nativeHang.setStopGate(neverStopped);
    const hangBefore = nativeHang.snapshot();
    const firstRequestAt = nativeHang.now;
    const firstRequest = changeRoute(nativeHang, false);
    await nativeHang.flushMicrotasks();
    assert.deepEqual(nativeHang.trace, ['stop'], 'This case must wait on an actual native stop');

    if (timeoutBeforeRetry) {
      await assert.rejects(nativeHang.settle(firstRequest), /切换准备超时/);
      assert.ok(nativeHang.now - firstRequestAt >= 4000 && nativeHang.now - firstRequestAt <= 4040,
        'A native stop that never resolves must reject within the four-second preparation bound');
      assertTransportRetained(nativeHang, hangBefore);
      assert.ok(nativeHang.engine.beatIndex > hangBefore.beat,
        'The shared UI beat must keep progressing while native preparation is stuck');
    }

    const retryAt = nativeHang.now;
    const retryRequest = changeRoute(nativeHang, true);
    if (!timeoutBeforeRetry) {
      assert.equal(await nativeHang.settle(firstRequest), false,
        'A newer physical route must cancel the obsolete logical request even while native stop is unresolved');
    }
    await assert.rejects(nativeHang.settle(retryRequest), /切换准备超时/);
    assert.ok(nativeHang.now - retryAt >= 4000 && nativeHang.now - retryAt <= 4060,
      'A fresh request queued behind native stop must have its own four-second preparation bound');
    assertTransportRetained(nativeHang, hangBefore);
    assert.equal(nativeHang.engine.audioStreaming, false);
    assert.equal(nativeHang.engine.pendingAudioTransition, undefined);
    assert.ok(nativeHang.engine.beatIndex > hangBefore.beat);

    // Releasing native work after both logical attempts ended cannot resurrect
    // either old route. It only lets the serial renderer queue finish safely.
    neverStopped.resolve();
    await nativeHang.settle(nativeHang.engine.rendererOperation);
    await nativeHang.advance(1000);
    assert.equal(nativeHang.engine.running, true);
    assert.equal(nativeHang.engine.audioStreaming, false);
    assert.equal(nativeHang.engine.pendingAudioTransition, undefined);
    assert.equal(nativeHang.trace.filter(operation => operation === 'start').length, 0,
      'Late native stop completion must not start either abandoned route');
    const silentPcm = new ArrayBuffer(882 * 2);
    nativeHang.engine.fillAudioData(silentPcm);
    assert.ok(new Int16Array(silentPcm).every(sample => Math.abs(sample) <= 1),
      'Abandoned native preparation must remain silent in actual PCM after late completion');
  }

  console.log('PASS: real BT/SPK route PCM rephasing retains shared beat; pending targets survive 2s freezes without stale audio; calibration, pause, rapid reversal and native hangs are bounded');
})().catch(error => { console.error(error); process.exitCode = 1; });
