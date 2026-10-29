// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const RATE = 44100;

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

class MicPlaybackClockPendingError extends Error {
  constructor(reason) {
    super(`Synthetic pending playback clock: ${reason}`);
    this.reason = reason;
  }
}

const source = fs.readFileSync('entry/src/main/ets/app/AppSession.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function harness(initialWireless = true, leader = true) {
  const storage = new Map();
  const messages = [];
  const toasts = [];
  const timers = new Map();
  let timerId = 0;
  let wireless = initialWireless;
  let signature = wireless ? '8:1' : '2:1';
  let routeListener;
  let now = 1000;
  class MockMetronome {
    boundaries = 0;
    warmups = 0;
    starts = [];
    pauses = 0;
    running = false;
    routeRephases = 0;
    routeProbeCalls = [];
    routeProbeGate;
    playbackReferences = [];
    referenceReadTimes = [];
    playbackReference = { rendererEpoch: 1, streamId: 7, frameMappingOffsetMs: 213 };
    currentPlaybackReference() {
      return { ...this.playbackReference, sampledAtMonoMs: now,
        framePos: Math.round(now * RATE / 1000), timestampMonoMs: now,
        submittedFrames: Math.round((now + 1000) * RATE / 1000) };
    }
    readMicCalibrationPlaybackReference(expected) {
      this.referenceReadTimes.push(now);
      if (expected && (this.playbackReference.rendererEpoch !== expected.rendererEpoch ||
        this.playbackReference.streamId !== expected.streamId)) {
        throw new Error('测量后的正式播放基准发生变化，请重新测量');
      }
      const next = this.playbackReferences.shift();
      if (next instanceof Error) throw next;
      return { ...this.currentPlaybackReference(), ...next };
    }
    async flushCalibrationStreamBetweenProbes() { this.boundaries++; }
    async scheduleCalibrationSignal(_signal, targetAt) {
      return { presentationMonoMs: targetAt, hardwareLatencyMs: 40,
        playbackReference: this.currentPlaybackReference() };
    }
    async scheduleFromLeaderStart(...args) { this.starts.push(args); }
    async ensureRenderer() {}
    async warmUpRendererForPlayback() { this.warmups++; }
    async suspendRenderer() {}
    async stopEngine() {}
    pause() { this.pauses++; }
    isRunning() { return this.running; }
    async rescheduleForOutputRouteChange() { this.routeRephases++; return true; }
    setBeatCallback() {}
    refreshOutputCalibration() {}
    setOffsetMs() {}
    setBpm() {}
    setBeatPointStates() {}
    configure() {}
    configureRouteProbeClickPair() {}
    async playRouteProbeClickPair(isCancelled) {
      this.routeProbeCalls.push({ isCancelled });
      if (this.routeProbeGate) await this.routeProbeGate.promise;
      return !isCancelled();
    }
    logMicCalibrationAudioState() {}
  }
  class MockController {
    state = 'idle';
    bpm = 120;
    beatsPerBar = 4;
    beatPointStates = [];
    rhythm = 0;
    soundId = 0;
    beatIndex = 0;
    transportCommands = [];
    constructor(_id, isLeader) { this.isLeader = isLeader; }
    setUiListener() {}
    setTransportPreparationHandler(handler) { this.prepareAudio = handler; }
    getOffsetMs() { return 12; }
    getClockSkewPpm() { return 0; }
    getClockMappingValidUntilMs() { return Infinity; }
    async disconnect() {}
    async startTransport() { this.transportCommands.push('start'); }
    async pauseTransport() { this.transportCommands.push('pause'); }
    async resumeTransport() { this.transportCommands.push('resume'); }
  }
  const mocks = {
    '../session/SessionController': { SessionController: MockController },
    '../audio/MetronomeEngine': { MetronomeEngine: MockMetronome, MicPlaybackClockPendingError },
    '../audio/AudioOutputMonitor': { AudioOutputMonitor: {
      start(listener) { routeListener = listener; listener(wireless, signature); },
      stop() {},
      isBluetoothA2dpActive: () => wireless,
      isBuiltInSpeakerActive: () => !wireless
    } },
    '../network/p2p/WifiP2pManager': { WifiP2pManager: class { async teardown() {} } },
    '../network/p2p/BleRoomDiscovery': { BleRoomDiscovery: class { async stopLeaderAdvertising() {} setJoinRequestListener() {} setMemberDisplayName() {} } },
    '../network/p2p/P2pInvitation': {},
    '../common/UserFeedback': { showUserNotice: message => toasts.push(message), logUserFailure() {} },
    '../store/EntitlementStore': { isProDrumMachineAccessible: () => true },
    '../common/Constants': { PROTOCOL_VERSION: 6 },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => now } },
    '../common/MeterModel': { defaultBeatPointStates: () => [] },
    '../session/SessionBackgroundKeeper': { SessionBackgroundKeeper: {
      async ensurePlaybackReady() {},
      setControlHandler() {}, async stop() {}
    } },
    '@kit.ArkUI': { promptAction: { showToast: ({ message }) => toasts.push(message) }, router: {} }
  };
  const context = {
    exports: {},
    require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
      return mocks[name];
    },
    console: { info: message => messages.push(message), warn: message => messages.push(message) },
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value), get: key => storage.get(key) },
    setTimeout(callback, delay) {
      const id = ++timerId;
      timers.set(id, { callback, dueAt: now + delay });
      return id;
    },
    clearTimeout: id => timers.delete(id)
  };
  vm.runInNewContext(compiled.outputText, context);
  const session = leader ? context.exports.AppSession.createLeader('Routing test') :
    context.exports.AppSession.createMember('Routing test');
  // Route handling is exercised after the fixture has joined its team lobby.
  session.teamJoinedForWarmup = true;
  return {
    session, toasts,
    emit(nextSignature, nextWireless = wireless) {
      signature = nextSignature;
      wireless = nextWireless;
      routeListener(wireless, signature);
    },
    lastRouteLog: () => messages.filter(message => message.startsWith('[AudioRouteDiag]')).at(-1),
    now: () => now,
    timerCount: () => timers.size,
    runNextTimer() {
      const dueAt = Math.min(...Array.from(timers.values(), timer => timer.dueAt));
      assert.ok(Number.isFinite(dueAt), 'Fixture must have a timer to run');
      now = dueAt;
      const due = Array.from(timers.entries()).filter(([, timer]) => timer.dueAt === dueAt);
      due.forEach(([id]) => timers.delete(id));
      due.forEach(([, timer]) => timer.callback());
    },
    runTimers() {
      const pending = Array.from(timers.values()).sort((a, b) => a.dueAt - b.dueAt);
      timers.clear();
      pending.forEach(timer => { now = timer.dueAt; timer.callback(); });
    }
  };
}

async function finishWithTimers(h, operation, maxTimers = 30) {
  let settled = false;
  const outcome = operation.then(value => {
    settled = true;
    return { value };
  }, error => {
    settled = true;
    return { error };
  });
  for (let i = 0; i < maxTimers && !settled; i++) {
    await new Promise(resolve => setImmediate(resolve));
    if (!settled && h.timerCount()) h.runNextTimer();
  }
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(settled, 'Bounded verification must settle rather than wait indefinitely');
  const result = await outcome;
  if (result.error) throw result.error;
  return result.value;
}

function assertNoMicBoundary(h, before, label) {
  assert.equal(h.session.metronome.boundaries, before, label);
  assert.match(h.lastRouteLog(), /micCalibrationActive=false/);
  assert.doesNotMatch(h.lastRouteLog(), /action=calibration-boundary/);
}

(async () => {
  for (const leader of [false, true]) {
    const playing = harness(true, leader);
    const c = playing.session.controller;
    c.state = 'playing';
    c.beatIndex = 42;
    playing.session.metronome.running = true;
    const original = { state: c.state, beatIndex: c.beatIndex, bpm: c.bpm, offset: c.getOffsetMs() };
    playing.emit('2:1', false);
    assert.equal(playing.session.metronome.routeRephases, 1);
    assert.match(playing.lastRouteLog(), /action=playback-rephase/);
    playing.emit('2:1', false);
    playing.emit('8:1', true);
    playing.emit('8:1', true);
    assert.equal(playing.session.metronome.routeRephases, 2, 'Only actual changes rephase both output directions');
    assert.equal(playing.session.metronome.warmups, 0, 'Duplicate BT events cannot restart a rephased production renderer');
    assert.match(playing.lastRouteLog(), /action=playback-running/);
    assert.deepEqual({ state: c.state, beatIndex: c.beatIndex, bpm: c.bpm, offset: c.getOffsetMs() }, original,
      'A leader or member output switch cannot change the shared logical clock or beat');
    assert.deepEqual(c.transportCommands, [], 'Local route repair must not send a team start/pause/resume');
    assert.deepEqual(playing.session.metronome.starts, [], 'Local route repair must not create a new shared transport');
  }

  const countdownRoute = harness();
  countdownRoute.session.controller.state = 'countdown';
  countdownRoute.session.metronome.running = true;
  countdownRoute.emit('2:1', false);
  assert.equal(countdownRoute.session.metronome.routeRephases, 1, 'Count-in keeps its original team grid during a route change');

  const measuringRoute = harness();
  measuringRoute.session.controller.state = 'playing';
  measuringRoute.session.metronome.running = true;
  await measuringRoute.session.scheduleLatencyTapMeasurement(2300, 4);
  measuringRoute.emit('2:1', false);
  assert.equal(measuringRoute.session.metronome.routeRephases, 0, 'Tap calibration owns its uncompensated schedule');

  const oldFailure = harness();
  oldFailure.session.controller.state = 'playing';
  oldFailure.session.metronome.running = true;
  const rephaseFailure = deferred();
  oldFailure.session.metronome.rescheduleForOutputRouteChange = () => rephaseFailure.promise;
  oldFailure.emit('2:1', false);
  oldFailure.session.metronome.rescheduleForOutputRouteChange = async () => true;
  oldFailure.emit('8:1', true);
  rephaseFailure.reject(new Error('stale route failure'));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(oldFailure.toasts, []);

  const currentFailure = harness();
  currentFailure.session.controller.state = 'playing';
  currentFailure.session.metronome.running = true;
  currentFailure.session.metronome.rescheduleForOutputRouteChange = async () => {
    throw new Error('current output failed');
  };
  currentFailure.emit('2:1', false);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(currentFailure.toasts, ['声音输出切换失败，请暂停后重试']);

  const replacedDuringReturn = harness();
  replacedDuringReturn.session.metronome.scheduleCalibrationSignal = async () => {
    const reference = { ...replacedDuringReturn.session.metronome.playbackReference };
    replacedDuringReturn.session.metronome.playbackReference.rendererEpoch++;
    return { presentationMonoMs: 2000, hardwareLatencyMs: 40, playbackReference: reference };
  };
  await assert.rejects(
    replacedDuringReturn.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000),
    /基准发生变化/, 'A chirp must not be rebound to a renderer replaced while its promise settles');

  const reference = harness();
  const timing = await reference.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000);
  const expected = timing.playbackReference;
  assert.equal(expected.frameMappingOffsetMs, 213, 'Headphone timing must carry its retained renderer reference');
  reference.session.metronome.playbackReferences = [209, 217, 213].map(frameMappingOffsetMs =>
    ({ frameMappingOffsetMs }));
  const checked = await finishWithTimers(reference,
    reference.session.verifyMicCalibrationPlaybackReference(expected));
  assert.equal(checked.frameMappingOffsetMs, 213, 'Release verification uses the current epoch median');
  assert.equal(reference.now(), 1500, 'Ordinary verification needs three samples over at least 500ms');
  assert.equal(reference.session.metronome.boundaries, 0, 'Reference verification must not rebuild playback');
  for (const change of [{ rendererEpoch: 2 }, { streamId: 8 }, { frameMappingOffsetMs: 244 }]) {
    reference.session.metronome.playbackReference = { ...expected, ...change };
    assert.throws(() => reference.session.readMicCalibrationPlaybackReference(expected), /基准发生变化/);
  }
  reference.session.metronome.playbackReferences = [-25, 0, 25].map(frameMappingOffsetMs =>
    ({ frameMappingOffsetMs }));
  reference.session.metronome.playbackReference = { ...expected, frameMappingOffsetMs: 0 };
  await assert.rejects(finishWithTimers(reference,
    reference.session.verifyMicCalibrationPlaybackReference({ ...expected, frameMappingOffsetMs: 0 })),
  /基准不稳定/);
  reference.emit('2:1', false);
  assert.throws(() => reference.session.readMicCalibrationPlaybackReference(expected), /蓝牙耳机已断开/);

  // Capturer release can freeze a surviving A2DP stream for about two seconds.
  // Recovery must be followed by a new full stability window, not a stale median.
  for (const pendingReads of [2, 8]) {
    const recovering = harness();
    const baseline = recovering.session.metronome.currentPlaybackReference();
    recovering.session.metronome.playbackReferences = Array.from({ length: pendingReads }, (_, index) =>
      new MicPlaybackClockPendingError(index % 2 ? 'timestamp-unavailable' : 'stale'));
    const result = await finishWithTimers(recovering,
      recovering.session.verifyMicCalibrationPlaybackReference(baseline));
    assert.equal(result.frameMappingOffsetMs, baseline.frameMappingOffsetMs);
    assert.equal(recovering.now(), 1000 + pendingReads * 250 + 500,
      'Transient clock failures must wait for recovery plus three fresh progressing samples');
    assert.equal(recovering.session.metronome.boundaries, 0);
    assert.equal(recovering.session.metronome.warmups, 0);
  }

  const interruptedWindow = harness();
  const interruptedBaseline = interruptedWindow.session.metronome.currentPlaybackReference();
  interruptedWindow.session.metronome.playbackReferences = [
    { frameMappingOffsetMs: 209 }, new MicPlaybackClockPendingError('stale'),
    { frameMappingOffsetMs: 213 }, { frameMappingOffsetMs: 217 }, { frameMappingOffsetMs: 219 }
  ];
  const recoveredWindow = await finishWithTimers(interruptedWindow,
    interruptedWindow.session.verifyMicCalibrationPlaybackReference(interruptedBaseline));
  assert.equal(recoveredWindow.frameMappingOffsetMs, 217,
    'A pending sample discards the earlier stability window and its median');
  assert.equal(interruptedWindow.now(), 2000);

  const framesRecovering = harness();
  const framesBaseline = framesRecovering.session.metronome.currentPlaybackReference();
  framesRecovering.session.metronome.playbackReferences = Array.from({ length: 8 }, () => ({
    framePos: framesBaseline.framePos
  }));
  const framesRecovered = await finishWithTimers(framesRecovering,
    framesRecovering.session.verifyMicCalibrationPlaybackReference(framesBaseline));
  assert.equal(framesRecovered.rendererEpoch, framesBaseline.rendererEpoch);
  assert.ok(framesRecovering.now() >= 3500 && framesRecovering.now() <= 5000,
    'A fresh timestamp with frozen frames must wait for a new full advancing stability window');

  const replacedWhilePending = harness();
  const pendingBaseline = replacedWhilePending.session.metronome.currentPlaybackReference();
  replacedWhilePending.session.metronome.playbackReferences = [
    new MicPlaybackClockPendingError('stale'), new MicPlaybackClockPendingError('stale')
  ];
  const replacedOperation = assert.rejects(
    replacedWhilePending.session.verifyMicCalibrationPlaybackReference(pendingBaseline), /基准发生变化/);
  await new Promise(resolve => setImmediate(resolve));
  replacedWhilePending.session.metronome.playbackReference.rendererEpoch++;
  replacedWhilePending.runNextTimer();
  await replacedOperation;
  assert.equal(replacedWhilePending.now(), 1250,
    'Renderer identity must be checked before another pending timestamp can prolong retries');
  assert.equal(replacedWhilePending.timerCount(), 0);

  for (const change of [{ rendererEpoch: 2 }, { streamId: 8 }, { frameMappingOffsetMs: 244 }]) {
    const permanent = harness();
    const baseline = permanent.session.metronome.currentPlaybackReference();
    permanent.session.metronome.playbackReference = { ...baseline, ...change };
    await assert.rejects(permanent.session.verifyMicCalibrationPlaybackReference(baseline), /基准发生变化/);
    assert.equal(permanent.now(), 1000, 'Changed coordinates must reject immediately without retry');
    assert.equal(permanent.timerCount(), 0);
  }
  const disconnected = harness();
  const disconnectedBaseline = disconnected.session.metronome.currentPlaybackReference();
  disconnected.emit('2:1', false);
  await assert.rejects(disconnected.session.verifyMicCalibrationPlaybackReference(disconnectedBaseline),
    /蓝牙耳机已断开/);
  assert.equal(disconnected.timerCount(), 0, 'Disconnected output must not be treated as a transient clock');

  // Fresh query time alone cannot establish recovery: renderer frames must also
  // advance at the audio sample rate across the accepted stability window.
  for (const frameRate of [0, RATE * 0.5, RATE * 2]) {
    const frozen = harness();
    const baseline = frozen.session.metronome.currentPlaybackReference();
    frozen.session.metronome.playbackReferences = Array.from({ length: 24 }, (_, index) => ({
      framePos: baseline.framePos + index * 250 * frameRate / 1000,
      timestampMonoMs: 1000 + index * 250,
      sampledAtMonoMs: 1000 + index * 250
    }));
    await assert.rejects(finishWithTimers(frozen,
      frozen.session.verifyMicCalibrationPlaybackReference(baseline)));
    assert.ok(frozen.now() >= 5000 && frozen.now() <= 5250,
      'A clock that never progresses at the audio rate must fail within the four-second bound');
    assert.equal(frozen.session.metronome.boundaries, 0, 'Recovery verification must never rebuild the renderer');
    assert.equal(frozen.session.metronome.starts.length, 0, 'Recovery verification must not start a tap or preview');
    assert.equal(frozen.session.metronome.pauses, 0, 'An expired verification must not activate the result');
  }
  const timedOut = harness();
  const timeoutBaseline = timedOut.session.metronome.currentPlaybackReference();
  timedOut.session.metronome.playbackReferences = Array.from({ length: 24 }, () =>
    new MicPlaybackClockPendingError('stale'));
  await assert.rejects(finishWithTimers(timedOut,
    timedOut.session.verifyMicCalibrationPlaybackReference(timeoutBaseline)));
  assert.ok(timedOut.now() >= 5000 && timedOut.now() <= 5250,
    'A permanently unavailable clock must fail within the four-second bound');
  assert.equal(timedOut.session.metronome.boundaries, 0);
  assert.equal(timedOut.session.metronome.warmups, 0);
  assert.equal(timedOut.session.metronome.pauses, 0);

  const writesFrozen = harness();
  const writesBaseline = writesFrozen.session.metronome.currentPlaybackReference();
  writesFrozen.session.metronome.playbackReferences = Array.from({ length: 24 }, () => ({
    submittedFrames: writesBaseline.submittedFrames
  }));
  await assert.rejects(finishWithTimers(writesFrozen,
    writesFrozen.session.verifyMicCalibrationPlaybackReference(writesBaseline)));
  assert.ok(writesFrozen.now() >= 5000 && writesFrozen.now() <= 5250,
    'A progressing timestamp cannot validate playback while submitted audio remains frozen');
  assert.equal(writesFrozen.session.metronome.boundaries, 0);

  const brokenClock = harness();
  const brokenBaseline = brokenClock.session.metronome.currentPlaybackReference();
  brokenClock.session.metronome.playbackReferences = [new Error('Synthetic permanent frame regression')];
  await assert.rejects(brokenClock.session.verifyMicCalibrationPlaybackReference(brokenBaseline),
    /permanent frame regression/);
  assert.equal(brokenClock.timerCount(), 0, 'Unclassified clock failures must reject without retry');

  const tap = harness();
  await tap.session.scheduleLatencyTapMeasurement(2300, 4);
  assert.deepEqual(tap.session.metronome.starts.at(-1), [2312, 0, 4, 0]);
  tap.emit('8:2');
  assertNoMicBoundary(tap, 0, 'A physical route change during tap measurement must not clear its PCM');
  assert.equal(tap.session.metronome.warmups, 1, 'Tap route callbacks retain ordinary playback warm-up');
  assert.match(tap.lastRouteLog(), /action=playback-warmup/);
  tap.emit('8:2');
  assertNoMicBoundary(tap, 0, 'Duplicate tap route callbacks must not enter mic calibration');
  assert.equal(tap.session.metronome.warmups, 2, 'Duplicate tap routes retain the working playback behavior');

  for (const inputSide of [false, true]) {
    const h = harness(!inputSide);
    if (inputSide) {
      await h.session.scheduleMicInputReferenceSignal(new Int16Array([1]), 2000);
    } else {
      await h.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000);
    }
    h.emit(inputSide ? '8:2' : '8:3', true);
    assert.equal(h.session.metronome.boundaries, 1, 'Active mic measurement must retain route realignment');
    assert.equal(h.session.metronome.warmups, 0, 'A mic boundary must not race ordinary playback warm-up');
    assert.match(h.lastRouteLog(), /micCalibrationActive=true/);
    assert.match(h.lastRouteLog(), /action=calibration-boundary/);
    h.emit(inputSide ? '8:2' : '8:3', true);
    assert.equal(h.session.metronome.boundaries, 1, 'Duplicate routes must not rebuild a mic stream');
    assert.equal(h.session.metronome.warmups, 0, 'Duplicate mic routes must not start ordinary warm-up');
  }

  // Both mic estimators call the boundary hook before their first chirp.
  const beforeChirp = harness();
  await beforeChirp.session.flushMicCalibrationProbeBoundary();
  beforeChirp.emit('8:2');
  assert.equal(beforeChirp.session.metronome.boundaries, 2);
  assert.match(beforeChirp.lastRouteLog(), /action=calibration-boundary/);

  const transitionedTap = harness();
  await transitionedTap.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000);
  await transitionedTap.session.scheduleLatencyTapMeasurement(2300, 4);
  transitionedTap.emit('8:2');
  assertNoMicBoundary(transitionedTap, 0, 'Tap entry must clear the previous mic mode');

  const preview = harness();
  await preview.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000);
  await preview.session.scheduleLatencyPreview(2300, 50);
  assert.deepEqual(preview.session.metronome.starts.at(-1), [2312, 0, 0, 50]);
  preview.emit('8:2');
  assertNoMicBoundary(preview, 0, 'Result preview must not inherit mic rebuild ownership');
  assert.equal(preview.session.metronome.warmups, 1, 'Preview route callbacks retain ordinary playback warm-up');
  preview.emit('8:2');
  assert.equal(preview.session.metronome.warmups, 2, 'Duplicate preview routes match normal playback behavior');

  const probe = harness();
  await probe.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000);
  probe.session.metronome.routeProbeGate = deferred();
  const probeResult = probe.session.playBluetoothRouteProbe();
  await new Promise(resolve => setImmediate(resolve));
  probe.emit('8:1');
  assertNoMicBoundary(probe, 0, 'Bluetooth route confirmation must not inherit mic ownership');
  assert.equal(probe.session.metronome.warmups, 0, 'Duplicate route notifications must not restart a finite pair');
  assert.match(probe.lastRouteLog(), /action=probe-playing/);
  probe.session.metronome.routeProbeGate.resolve();
  assert.equal(await probeResult, true);
  assert.equal(probe.session.metronome.pauses, 1, 'Only a completed pair may pause its own transport');
  probe.emit('8:1');
  assert.equal(probe.session.metronome.warmups, 1, 'Ordinary route warmup resumes after the pair relinquishes ownership');

  for (const disconnected of [false, true]) {
    const changed = harness();
    changed.session.metronome.routeProbeGate = deferred();
    const result = changed.session.playBluetoothRouteProbe();
    changed.emit(disconnected ? '2:1' : '8:2', !disconnected);
    assert.equal(changed.session.metronome.routeProbeCalls[0].isCancelled(), true);
    assert.equal(changed.session.metronome.pauses, 1, 'A changed physical output cancels the old pair immediately');
    assert.equal(changed.session.metronome.warmups, 0, 'A route change cannot silently rebuild the pair renderer');
    assert.match(changed.lastRouteLog(), /action=probe-cancel/);
    changed.session.metronome.routeProbeGate.resolve();
    assert.equal(await result, false, 'A pair interrupted by a changed output cannot enable confirmation');
    assert.equal(changed.session.latencyRouteProbeOwner, -1);
  }

  // Dismiss may await a native suspend while a newly opened dialog starts its
  // finite pair. The old stop must not restore a looping team configuration.
  const reopened = harness();
  await reopened.session.scheduleLatencyTapMeasurement(2300, 4);
  const suspend = deferred();
  reopened.session.metronome.suspendRenderer = () => suspend.promise;
  let restored = 0;
  reopened.session.syncEngineFromSession = () => { restored++; };
  const stopping = reopened.session.stopLatencyCalibration();
  reopened.session.metronome.routeProbeGate = deferred();
  const restarted = reopened.session.playBluetoothRouteProbe();
  suspend.resolve();
  await stopping;
  assert.equal(restored, 0, 'Late stop completion must not overwrite the newer pair');
  reopened.session.metronome.routeProbeGate.resolve();
  assert.equal(await restarted, true);

  for (const next of ['tap', 'preview', 'mic', 'mic-boundary']) {
    const superseded = harness();
    superseded.session.metronome.routeProbeGate = deferred();
    const result = superseded.session.playBluetoothRouteProbe();
    if (next === 'tap') await superseded.session.scheduleLatencyTapMeasurement(2300, 4);
    if (next === 'preview') await superseded.session.scheduleLatencyPreview(2300, 50);
    if (next === 'mic') await superseded.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000);
    if (next === 'mic-boundary') await superseded.session.flushMicCalibrationProbeBoundary();
    assert.equal(superseded.session.metronome.routeProbeCalls[0].isCancelled(), true);
    superseded.session.metronome.routeProbeGate.resolve();
    assert.equal(await result, false);
    assert.equal(superseded.session.metronome.pauses, 0, 'An old pair cannot pause the newer measurement');
    superseded.emit('8:1');
    assert.doesNotMatch(superseded.lastRouteLog(), /action=probe-/);
    assert.equal(superseded.session.metronome.warmups, next.startsWith('mic') ? 0 : 1);
  }

  for (const exit of ['pause', 'stop', 'save', 'capture-complete', 'shutdown']) {
    const h = harness();
    await h.session.scheduleMicLoopbackSignal(new Int16Array([1]), 2000);
    if (exit === 'pause') h.session.pauseLatencyCalibration();
    if (exit === 'stop') await h.session.stopLatencyCalibration();
    if (exit === 'save') h.session.keepLatencyCalibrationRendererAlive();
    if (exit === 'capture-complete') h.session.scheduleMicPostCaptureDiagnostics('headphone');
    if (exit === 'shutdown') await h.session.shutdown();
    h.emit('8:2');
    assertNoMicBoundary(h, 0, `${exit} must clear mic route ownership before the result or walking page`);
  }

  // Stopping an already inactive transport still ends a pre-chirp mic boundary.
  const inactiveStop = harness();
  await inactiveStop.session.flushMicCalibrationProbeBoundary();
  inactiveStop.session.latencyCalibrationActive = false;
  await inactiveStop.session.stopLatencyCalibration();
  inactiveStop.emit('8:2');
  assertNoMicBoundary(inactiveStop, 1, 'The stop early return must not leave mic mode set');

  console.log('PASS: AppSession bounds mic clock recovery and isolates route probe ownership, cancellation, and delayed stop from newer playback');
})().catch(error => { console.error(error); process.exitCode = 1; });
