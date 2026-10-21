const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const filename = path.join(__dirname, '../../entry/src/main/ets/pages/MicCaptureExperimentPage.ets');
const source = fs.readFileSync(filename, 'utf8');
const builderStart = source.indexOf('  @Builder');
assert.ok(builderStart > 0, 'Exercise the real page lifecycle and audio ownership methods before ArkUI builders');
const business = (source.slice(0, builderStart) + '\n}')
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct MicCaptureExperimentPage', 'export class MicCaptureExperimentPage');
const result = ts.transpileModule(business, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal(result.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
const guardSource = fs.readFileSync(path.join(__dirname,
  '../../entry/src/main/ets/audio/MicExperimentPlaybackGuard.ets'), 'utf8');
const guardContext = { exports: {} };
vm.runInNewContext(ts.transpileModule(guardSource, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, guardContext);

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() { for (let index = 0; index < 160; index++) await Promise.resolve(); }

function fakeResult(source) {
  return { source, wavPath: `/private/lab/mic-capture-experiment/${source}.wav`,
    reportPath: `/private/lab/mic-capture-experiment/${source}.json`, sampleRate: 48000,
    channels: 1, durationMs: 10000, totalFrames: 480000, peak: 0.5, clippedSamples: 0,
    aecSupported: true, devices: [{ type: 15, role: 1 }], anchors: [], timestampReadFailures: 0,
    overflowCount: 0, snapshots: [], chunks: [], chunkCount: 1000, chunkObservationsDropped: 0,
    clockMetrics: { quality: 'insufficient', reason: '硬件锚点不足', clockRateErrorPpm: 0,
      timestampFitResidualP95Ms: 0 } };
}

function harness(options = {}) {
  const trace = [], notices = [], engines = [], captures = [], reports = [], auditions = [];
  const applicationCallbacks = new Set(), routeCallbacks = new Set();
  let appSession, retiringSession = false, resetPending = false, recordingState = 'idle', now = 10000;
  let permissionCount = 0, permission = options.permission ?? Promise.resolve(true);
  let cleanupGate, playerStopGate = options.playerStopGate;
  const capability = { apiVersion: 20, liveAvailable: true, liveAecSupported: true,
    micAecSupported: false, reason: '' };
  const route = {
    on(_event, info, callback) {
      assert.equal(info.usage, 7);
      trace.push('route:on'); routeCallbacks.add(callback);
    },
    off(_event, callback) { trace.push('route:off'); routeCallbacks.delete(callback); }
  };
  const application = {
    on(event, callback) { assert.equal(event, 'applicationStateChange'); applicationCallbacks.add(callback); },
    off(event, callback) { assert.equal(event, 'applicationStateChange'); applicationCallbacks.delete(callback); }
  };
  class Engine {
    constructor() {
      this.id = engines.length + 1; this.running = false;
      this.snapshotChange = {}; this.ensureCount = 0; this.scheduleCount = 0;
      this.physicalStartCount = 0; this.stopped = false;
      engines.push(this); trace.push(`engine:${this.id}:create`);
    }
    configure(a, b) { assert.equal(a, 0); assert.equal(b, 0); trace.push(`engine:${this.id}:configure`); }
    setBpm(bpm, meter) { assert.equal(bpm, 120); assert.equal(meter, 4); }
    setOffsetMs(offset) { assert.equal(offset, 0, 'The independent engine must not borrow earphone compensation'); }
    async ensureRenderer() {
      this.ensureCount++; trace.push(`engine:${this.id}:prepare`);
      if (options.ensureGate) await options.ensureGate.promise;
    }
    async scheduleFromLeaderStart() {
      this.scheduleCount++; this.physicalStartCount++; this.running = true;
      trace.push(`engine:${this.id}:schedule`);
    }
    readMicExperimentPlaybackSnapshot() {
      return { sampledAtMonoMs: now, rendererEpoch: 11, streamId: 22,
        physicalStartCount: this.physicalStartCount, running: this.running, started: this.running,
        state: 2, interruptCount: 0, underflowCount: 0, lastWriteProgressMs: now,
        outputDevices: '8:1', audioScene: 0, writeCallbackCount: 10, ...this.snapshotChange };
    }
    pause() { this.running = false; trace.push(`engine:${this.id}:pause`); }
    async stopEngine() {
      trace.push(`engine:${this.id}:stop-begin`);
      if (cleanupGate) await cleanupGate.promise;
      this.stopped = true; trace.push(`engine:${this.id}:stop-end`);
    }
  }
  class Capture {
    static capability() { return { ...capability }; }
    async clear() { trace.push('capture:clear'); }
    run(_directory, captureSource, observer, duration) {
      assert.equal(duration, 10000);
      assert.equal(captures.some(request => request.active), false, 'A and B capturers must never overlap');
      const request = { ...deferred(), source: captureSource, observer, active: true };
      const resolve = request.resolve, reject = request.reject;
      request.resolve = (value = fakeResult(captureSource)) => {
        request.active = false; trace.push(`capture:${captureSource}:released`); resolve(value);
      };
      request.reject = error => {
        request.active = false; trace.push(`capture:${captureSource}:released`); reject(error);
      };
      captures.push(request); trace.push(`capture:${captureSource}:start`);
      observer.snapshot();
      return request.promise;
    }
    cancel() {
      trace.push('capture:cancel');
      const current = captures.find(request => request.active);
      current?.reject(new Error('实验已取消'));
    }
  }
  class Player {
    async stop() {
      trace.push('player:stop');
      if (playerStopGate) await playerStopGate.promise;
    }
    cancel() { trace.push('player:cancel'); }
    async play(file, onEnded) {
      assert.equal(captures.some(request => request.active), false, 'Audition must follow capturer release');
      assert.ok(engines.every(engine => engine.stopped), 'Audition must follow independent engine release');
      trace.push(`player:play:${file}`); this.onEnded = onEnded;
      if (options.deferredAuditions) {
        const request = { ...deferred(), file, onEnded };
        auditions.push(request);
        await request.promise;
      }
    }
  }
  const context = {
    exports: {}, MetronomeEngine: Engine, MicCaptureExperiment: Capture, MicExperimentPlayer: Player,
    micExperimentPlaybackProblem: guardContext.exports.micExperimentPlaybackProblem,
    AppSession: { get: () => appSession,
      hasLiveOrRetiringSession: () => appSession !== undefined || retiringSession || resetPending },
    RecordingCoordinator: { getSnapshot: () => ({ state: recordingState }) },
    audio: { getAudioManager: () => ({ getRoutingManager: () => route }), StreamUsage: { STREAM_USAGE_GAME: 7 } },
    MonotonicClock: { nowMs: () => now }, fs: { access: async () => false, unlink: async () => {} },
    ensureMicrophonePermission: () => { permissionCount++; return permission; },
    microphonePermissionDeniedHint: () => '需要麦克风权限',
    writeAtomic: async (filename, payload) => { reports.push({ filename, payload: JSON.parse(payload) }); },
    showUserNotice: message => notices.push(message), router: { back: () => trace.push('router:back') },
    setTimeout(callback, delay) { queueMicrotask(() => { now += delay; callback(); }); return 1; },
    clearTimeout() {}
  };
  vm.runInNewContext(result.outputText, context);
  const page = new context.exports.MicCaptureExperimentPage();
  page.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/private/lab', getApplicationContext: () => application }) });
  page.aboutToAppear(); page.onPageShow();
  return { page, trace, engines, captures, reports, notices, auditions, routeCallbacks, applicationCallbacks,
    setSession: value => { appSession = value; },
    setRetiringSession: value => { retiringSession = value; },
    setResetPending: value => { resetPending = value; },
    setRecordingState: value => { recordingState = value; },
    setCleanupGate: value => { cleanupGate = value; },
    setPlayerStopGate: value => { playerStopGate = value; },
    permissionCount: () => permissionCount,
    background: () => { for (const callback of applicationCallbacks) callback.onApplicationBackground(); },
    foreground: () => { for (const callback of applicationCallbacks) callback.onApplicationForeground(); },
    routeChange: devices => { for (const callback of routeCallbacks) callback(devices); }
  };
}

(async () => {
  for (const isolation of ['session', 'retiring', 'reset', 'recording', 'saving']) {
    const h = harness();
    if (isolation === 'session') h.setSession({ productionEngine: true });
    else if (isolation === 'retiring') h.setRetiringSession(true);
    else if (isolation === 'reset') h.setResetPending(true);
    else h.setRecordingState(isolation);
    await h.page.startExperiment(true);
    assert.equal(h.engines.length, 0); assert.equal(h.captures.length, 0);
    assert.equal(h.permissionCount(), 0, 'Production isolation is checked before requesting permission');
    assert.match(h.page.outcome, /退出练习|结束正式录制/);
  }

  {
    const permission = deferred(); const h = harness({ permission: permission.promise });
    const task = h.page.startExperiment(true); await flush();
    h.setRetiringSession(true); permission.resolve(true); await task;
    assert.equal(h.engines.length, 0, 'A retiring production renderer blocks late permission startup');
    assert.equal(h.captures.length, 0); assert.match(h.page.outcome, /退出练习/);
    await h.page.preview(fakeResult('mic'));
    assert.equal(h.trace.some(item => item.startsWith('player:play:')), false,
      'Audition also waits for retiring production audio resources');
    assert.match(h.notices.at(-1), /退出练习/);
  }

  for (const cancellation of ['hidden', 'background']) {
    const permission = deferred();
    const h = harness({ permission: permission.promise });
    const task = h.page.startExperiment(true); await flush();
    assert.equal(h.permissionCount(), 1); assert.equal(h.page.busy, true);
    if (cancellation === 'hidden') h.page.aboutToDisappear(); else h.background();
    permission.resolve(true); await task;
    assert.equal(h.engines.length, 0, 'A late permission result cannot create a renderer');
    assert.equal(h.captures.length, 0, 'A late permission result cannot create a capturer');
    assert.equal(h.page.busy, false);
    if (cancellation === 'hidden') assert.equal(h.applicationCallbacks.size, 0);
  }

  {
    const playerStopGate = deferred();
    const h = harness({ playerStopGate });
    const task = h.page.startExperiment(false); await flush();
    h.background(); playerStopGate.resolve(); await task;
    assert.equal(h.permissionCount(), 0, 'Cancellation during old preview cleanup must not open a hidden permission prompt');
    assert.equal(h.engines.length, 0);
  }

  {
    const ensureGate = deferred(); const h = harness({ ensureGate });
    const task = h.page.startExperiment(false); await flush();
    assert.equal(h.engines.length, 1); assert.equal(h.engines[0].scheduleCount, 0);
    h.page.cancelExperiment('停止准备'); ensureGate.resolve(); await task;
    assert.equal(h.engines[0].scheduleCount, 0, 'Canceled renderer preparation must never schedule the rhythm');
    assert.equal(h.engines[0].stopped, true); assert.equal(h.captures.length, 0);
  }

  {
    const h = harness(); const task = h.page.startExperiment(true); await flush();
    assert.equal(h.captures.length, 1); assert.equal(h.captures[0].source, 'mic');
    await h.page.startExperiment(true);
    await h.page.preview(fakeResult('mic'));
    assert.equal(h.engines.length, 1); assert.equal(h.captures.length, 1);
    assert.equal(h.trace.some(item => item.startsWith('player:play:')), false, 'No audition while the experiment owns audio');
    h.captures[0].resolve(); await flush();
    assert.equal(h.captures.length, 2); assert.equal(h.captures[1].source, 'live');
    assert.equal(h.engines.length, 1, 'A/B must keep the same independent renderer');
    assert.equal(h.engines[0].ensureCount, 1); assert.equal(h.engines[0].scheduleCount, 1);
    h.captures[1].resolve(); await task;
    assert.equal(h.engines[0].stopped, true); assert.equal(h.routeCallbacks.size, 0);
    assert.equal(h.page.busy, false); assert.equal(h.page.baseline, undefined);
    assert.equal(h.reports.length, 1); assert.equal(h.reports[0].payload.mode, 'mic-vs-live');
    assert.ok(h.reports[0].payload.boundaries.some(boundary => boundary.phase === 'live-restored'));
    await h.page.preview(h.page.micResult);
    assert.equal(h.page.previewSource, 'mic');
    assert.ok(h.trace.some(item => item.endsWith('/mic.wav')));
    h.background(); assert.equal(h.page.previewSource, '');
    const plays = h.trace.filter(item => item.startsWith('player:play:')).length;
    h.foreground(); assert.equal(h.trace.filter(item => item.startsWith('player:play:')).length, plays,
      'Returning to foreground never resumes an old audition');
  }

  {
    const h = harness(); const task = h.page.startExperiment(true); await flush();
    const oldObserver = h.captures[0].observer;
    h.routeChange([{ deviceType: 7, id: 99 }]); await task;
    assert.equal(h.captures.length, 1, 'Route interruption cannot continue into LIVE');
    assert.equal(h.engines[0].stopped, true); assert.equal(h.routeCallbacks.size, 0);
    assert.match(h.page.outcome, /输出设备发生变化/);
    oldObserver.onProgress(9000, 0.9, 1);
    assert.equal(h.page.level, 0, 'Late callbacks cannot restore a canceled run waveform');
    assert.throws(() => oldObserver.snapshot(), /变化|取消|停止/);
  }

  {
    const h = harness(); const task = h.page.startExperiment(true); await flush();
    h.engines[0].snapshotChange = { physicalStartCount: 2 };
    let problem;
    try { h.captures[0].observer.snapshot(); } catch (error) { problem = error; }
    assert.ok(problem); h.captures[0].reject(problem); await task;
    assert.match(h.page.outcome, /播放实例|物理起点/);
    assert.equal(h.captures.length, 1);
  }

  {
    const h = harness(); const task = h.page.startExperiment(false); await flush();
    h.setSession({ productionEngine: true });
    let problem;
    try { h.captures[0].observer.snapshot(); } catch (error) { problem = error; }
    assert.ok(problem); h.captures[0].reject(problem); await task;
    assert.match(h.page.outcome, /退出练习/);
    const plays = h.trace.filter(item => item.startsWith('player:play:')).length;
    await h.page.preview(fakeResult('mic'));
    assert.equal(h.trace.filter(item => item.startsWith('player:play:')).length, plays);
    assert.match(h.notices.at(-1), /退出练习/);
  }

  {
    const h = harness(); const task = h.page.startExperiment(false); await flush();
    const cleanup = deferred(); h.setCleanupGate(cleanup);
    const leave = h.page.leavePage(); const repeatedLeave = h.page.leavePage(); await flush();
    assert.equal(h.trace.includes('router:back'), false, 'Navigation waits for owned audio release');
    assert.equal(h.captures[0].active, false);
    cleanup.resolve(); await leave; await repeatedLeave; await task;
    assert.equal(h.engines[0].stopped, true);
    assert.equal(h.trace.at(-1), 'router:back');
    assert.equal(h.trace.filter(item => item === 'router:back').length, 1);
  }

  {
    const h = harness({ deferredAuditions: true });
    const old = h.page.preview(fakeResult('mic')); await flush();
    const current = h.page.preview(fakeResult('live')); await flush();
    assert.equal(h.auditions.length, 2);
    h.auditions[0].reject(new Error('旧试听已取消')); await old;
    assert.equal(h.page.previewSource, 'live', 'Late cancellation of A cannot clear the active B preview');
    assert.equal(h.notices.length, 0, 'A superseded preview must not publish a stale failure notice');
    h.auditions[0].onEnded();
    assert.equal(h.page.previewSource, 'live', 'Late A completion cannot clear the active B preview');
    h.auditions[1].resolve(); await current;
    h.auditions[1].onEnded(); assert.equal(h.page.previewSource, '');
  }

  {
    const h = harness(); const playerStopGate = deferred(); h.setPlayerStopGate(playerStopGate);
    const clear = h.page.clearFiles(); await flush();
    assert.equal(h.page.busy, true, 'File cleanup owns the page until the old player releases its fd');
    await h.page.startExperiment(false);
    assert.equal(h.engines.length, 0, 'Capture cannot overlap a pending clearFiles operation');
    playerStopGate.resolve(); await clear;
    assert.equal(h.page.busy, false); assert.match(h.page.outcome, /已清除/);
  }

  console.log('PASS MIC experiment page: production isolation, late permissions, preparation cancellation, one-renderer A/B, route/focus boundaries, background audition and release-before-navigation');
})().catch(error => { console.error(error); process.exitCode = 1; });
