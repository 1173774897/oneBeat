// Native-policy mute was observed without an audioInterrupt event. Exercise real
// ownership and foreground recovery code with controllable native boundaries.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const { fixture } = require('./metronome-start-timing.cjs');

function load(file, mocks, globals = {}) {
  const result = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  const context = { exports: {}, require: name => mocks[name] ?? {},
    console: { info() {}, warn() {} }, setInterval: () => 1, clearInterval() {}, ...globals };
  vm.runInNewContext(result.outputText, context);
  return context.exports;
}

function background() {
  let nativeTask, staleSession = false, updatesFail = 0, mediaFail = 0, creates = 0, locks = 0;
  const events = [], callbacks = {};
  const Keeper = load('entry/src/main/ets/session/SessionBackgroundKeeper.ets', {
    '@kit.AbilityKit': { wantAgent: { getWantAgent: async () => ({}),
      OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: {
      on: (name, callback) => { callbacks[name] = callback; },
      async startBackgroundRunning(_context, modes) {
        assert.equal(nativeTask, undefined, 'A live task must be updated rather than duplicated');
        nativeTask = { abilityName: 'EntryAbility', backgroundModes: [...modes], suspendState: false };
        events.push(['start', [...modes]]);
      },
      async updateBackgroundRunning(_context, modes) {
        assert.ok(nativeTask, 'The old local active flag cannot stand in for a native task');
        if (updatesFail-- > 0) throw new Error('task update rejected');
        nativeTask.backgroundModes = [...modes]; nativeTask.suspendState = false;
        events.push(['update', [...modes]]);
      },
      async getAllContinuousTasks() { return nativeTask ? [{ ...nativeTask }] : []; },
      async stopBackgroundRunning() { nativeTask = undefined; events.push(['stop']); }
    } },
    '@kit.AVSessionKit': { avSession: {
      PlaybackState: { PLAYBACK_STATE_PLAY: 2, PLAYBACK_STATE_PAUSE: 3 },
      async createAVSession() {
        creates++;
        if (mediaFail-- > 0) throw new Error('media session unavailable');
        staleSession = false;
        return { on() {}, async activate() {}, async deactivate() {}, async destroy() {},
          async setAVMetadata() { if (staleSession) throw new Error('stale media proxy'); },
          async setAVPlaybackState(state) { events.push(['playback', state.state]); } };
      }
    } },
    '@kit.BasicServicesKit': { runningLock: { RunningLockType: { BACKGROUND: 1 },
      isSupported: () => true, async create() { return { isHolding: () => false,
        hold() { locks++; }, unhold() {} }; } } }
  }).SessionBackgroundKeeper;
  Keeper.initialize({});
  return { Keeper, events, modes: () => nativeTask?.backgroundModes,
    creates: () => creates, locks: () => locks,
    cancel() { nativeTask = undefined; callbacks.continuousTaskCancel({ reason: 6, id: 1 }); },
    removeSilently() { nativeTask = undefined; },
    suspend() { nativeTask.suspendState = true; },
    stale() { staleSession = true; }, failUpdates() { updatesFail = 1; },
    failMedia(count) { mediaFail = count; } };
}

async function testBackgroundOwnership() {
  const h = background(), k = h.Keeper;
  await k.start(true);
  assert.deepEqual(h.modes(), ['multiDeviceConnection'], 'An idle lobby must not claim to be playing audio');
  assert.equal(h.events.at(-1)[1], 3, 'The media card reflects pause before actual transport');
  await k.ensurePlaybackReady();
  assert.deepEqual(h.modes(), ['audioPlayback'],
    'Wi-Fi P2P/TCP fails the multiDeviceConnection audit, which would cancel audio too');
  await k.updatePlaybackState(false);
  assert.ok(h.modes().includes('audioPlayback'), 'A duplicate paused UI refresh cannot cancel a prepared start');
  await k.updatePlaybackState(true);
  await k.setRecordingActive(true);
  assert.deepEqual(h.modes(), ['audioPlayback', 'audioRecording']);
  assert.equal(k.consumePlaybackContinuityLoss(), false);
  h.cancel();
  await k.ensurePlaybackReady();
  assert.equal(k.consumePlaybackContinuityLoss(), true, 'Task cancellation while playing forces foreground rephase');
  assert.equal(k.consumePlaybackContinuityLoss(), false, 'Loss evidence is consumed once');
  assert.deepEqual(h.modes(), ['audioPlayback', 'audioRecording']);
  h.removeSilently();
  await k.ensurePlaybackReady();
  assert.equal(k.consumePlaybackContinuityLoss(), true, 'A cancellation missed while frozen is still loss evidence');
  assert.ok(h.modes().includes('audioPlayback'), 'Enumeration repairs cancellation missed while JS was frozen');
  h.suspend();
  await k.ensurePlaybackReady();
  assert.ok(h.modes().includes('audioRecording'), 'Reactivation preserves the recording owner');
  h.stale();
  await k.ensurePlaybackReady();
  assert.equal(h.creates(), 2, 'A stale media proxy is recreated instead of treated as ready');
  h.failUpdates();
  await assert.rejects(k.ensurePlaybackReady(), /task update rejected/);
  await k.ensurePlaybackReady();
  await k.updatePlaybackState(false);
  assert.deepEqual(h.modes(), ['multiDeviceConnection', 'audioRecording']);
  await k.setRecordingActive(false);
  assert.deepEqual(h.modes(), ['multiDeviceConnection']);
  await k.stop();
  assert.equal(h.modes(), undefined);

  const failed = background(); failed.failMedia(1);
  await failed.Keeper.start(true);
  assert.ok(failed.locks() > 0, 'Media setup failure cannot skip the independent running lock');
  await failed.Keeper.ensurePlaybackReady();
  assert.ok(failed.modes().includes('audioPlayback'));
}

async function playing() {
  const h = fixture({ compensationMs: 100, queueMs: 200 });
  await h.engine.scheduleFromLeaderStart(h.now + 650, 0, 0);
  await h.fireDueTimers(); h.advanceKeepAlive(650);
  return h;
}

// restoreAfterForeground rechecks on timers: a busy transition waits for its
// bounded deadline and a phase residual needs two consecutive confirmations.
// Drive the fake clock while marking callbacks as still arriving, so only those
// rules (not the writeData stall watchdog) decide the outcome.
async function driveForegroundCheck(h) {
  let done = false, failure;
  h.engine.restoreAfterForeground().then(() => { done = true; }, error => { done = true; failure = error; });
  await h.flushMicrotasks();
  for (let waited = 0; !done && waited <= 4000; waited += 20) {
    h.advanceClock(20); h.engine.lastWriteProgressMs = h.now; await h.fireDueTimers();
  }
  assert.ok(done, 'Foreground check must finish within its bounded observation window');
  if (failure) throw failure;
}

async function testForegroundRecovery() {
  const h = await playing(), e = h.engine;
  const token = e.runToken, revision = e.transportRevision, origin = e.transportStartLocalMs;
  const starts = [];
  e.haltRenderer = async () => { h.advanceClock(2100); };
  e.startAudioStream = async (...args) => { starts.push(args); };
  h.advanceClock(4500);
  await e.restoreAfterForeground();
  assert.equal(starts.length, 1, 'A muted/frozen renderer can recover without an audioInterrupt event');
  const [audibleAt, beatIndex, countIn, recoveredToken] = starts[0];
  assert.ok(audibleAt - h.now >= 750, 'Cold-start and output latency lead is selected after slow stop completes');
  assert.ok(Math.abs(audibleAt - (origin + (beatIndex - e.transportStartBeatIndex) * 500)) < .01);
  assert.equal(countIn, 0); assert.equal(recoveredToken, token);
  assert.equal(e.runToken, token); assert.equal(e.transportRevision, revision);
  assert.equal(e.transportStartLocalMs, origin, 'Local recovery cannot move the team epoch');

  for (const guard of ['healthy', 'focus', 'preview', 'calibration', 'paused', 'transition']) {
    const f = await playing(); let recoveries = 0;
    f.engine.recoverAudio = async () => { recoveries++; };
    if (guard !== 'healthy') f.advanceClock(4500);
    if (guard === 'focus') f.engine.audioFocusInterrupted = true;
    if (guard === 'preview') f.engine.transportPreviewStartPositionBeats = 0;
    if (guard === 'calibration') f.engine.transportOutputCompensationOverrideMs = 0;
    if (guard === 'paused') f.engine.pause();
    if (guard === 'transition') f.engine.pendingAudioTransition = {};
    await driveForegroundCheck(f);
    assert.equal(recoveries, 0, `${guard} must retain its existing audio ownership`);
  }
  const gap = await playing(); let repaired = 0;
  gap.engine.recoverAudio = async () => { repaired++; };
  gap.advanceKeepAlive(4500);
  assert.equal(gap.engine.lastWriteProgressMs, gap.now, 'A resumed callback can hide the stale timestamp');
  await gap.engine.restoreAfterForeground();
  assert.equal(repaired, 1, 'The recorded callback gap still proves loss of continuity');
  const lag = await playing(); repaired = 0;
  lag.engine.recoverAudio = async () => { repaired++; };
  lag.engine.transportStartLocalMs += 4500;
  await driveForegroundCheck(lag);
  assert.equal(repaired, 1, 'Multi-second residual must rephase rather than slew for thousands of seconds');
}

async function testAppLifecycleWiring() {
  const trace = [];
  let release;
  let readiness = Promise.resolve();
  let lost = false;
  const App = load('entry/src/main/ets/app/AppSession.ets', {
    '../session/SessionBackgroundKeeper': { SessionBackgroundKeeper: {
      async ensurePlaybackReady() { trace.push('verify'); await readiness; },
      async updatePlaybackState(playing, force) { trace.push(['state', playing, force]); },
      consumePlaybackContinuityLoss() { return lost; }
    } },
    '../common/UserFeedback': { logUserFailure() {}, showUserNotice() {} }
  }).AppSession;
  const session = Object.create(App.prototype);
  session.controller = { state: 'playing',
    handleAppForeground() { trace.push('foreground'); },
    handleAppBackground() { trace.push('background'); } };
  session.metronome = { async restoreAfterForeground(continuityLost) {
    trace.push(continuityLost ? 'restore-lost' : 'restore'); } };
  session.syncEngineFromSession = () => trace.push('mapping');
  App.instance = session;
  const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };
  App.handleAppBackground(); await flush();
  assert.deepEqual(trace, ['background', 'verify'], 'Background transition refreshes ownership without restarting PCM');
  trace.length = 0;
  App.handleAppForeground(); await flush();
  assert.deepEqual(trace, ['foreground', 'verify', 'mapping', 'restore']);
  trace.length = 0; lost = true;
  App.handleAppForeground(); await flush();
  assert.deepEqual(trace, ['foreground', 'verify', 'mapping', 'restore-lost'],
    'Native task loss reaches the engine even when hardware phase reads 0ms');
  trace.length = 0; lost = false;
  readiness = new Promise(resolve => { release = resolve; });
  App.handleAppForeground();
  session.shutdownOperation = Promise.resolve();
  release(); await flush();
  assert.deepEqual(trace, ['foreground', 'verify'], 'An old foreground request cannot restore a retired session');
  session.shutdownOperation = undefined;
  session.controller.state = 'paused'; trace.length = 0;
  App.handleAppBackground(); await flush();
  assert.deepEqual(trace, ['background', ['state', false, true]], 'A paused team releases audio mode while retaining connection ownership');
}

(async () => {
  await testBackgroundOwnership();
  await testForegroundRecovery();
  await testAppLifecycleWiring();
  console.log('PASS background playback continuity: real task/AV ownership, idle versus playing modes, cancellation/retry, recording union, policy-mute recovery, slow stop lead and shared epoch/focus/preview guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
