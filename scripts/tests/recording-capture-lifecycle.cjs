// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
function compile(path) {
  const compiled = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  return compiled.outputText;
}
const coordinatorJs = compile('entry/src/main/ets/recording/RecordingCoordinator.ets');
const mixerJs = compile('entry/src/main/ets/recording/RecordingMixer.ets');
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject }; }
async function flush() { for (let i = 0; i < 80; i++) await Promise.resolve(); }
function harness(options = {}) {
  let now = 1000, sequence = 0, timerId = 0, epoch = 1, startedAt = -1, stateCode = -1;
  let startGate, inputListener, nativeOptions;
  const files = options.files ?? new Set();
  const pendingCaptures = options.pendingCaptures ?? new Map();
  const timers = new Map();
  const calls = { starts: 0, stops: 0, cancels: 0, permissionRequests: 0, added: [], mixes: [], deleted: [], tasks: [], timingLogs: [] };
  function emit(code) {
    stateCode = code;
    if (code === 0) { startedAt = now; startGate?.resolve(); }
    else if (code === 1) startGate?.reject(new Error('已取消录制'));
  }
  const native = {
    start: async args => {
      nativeOptions = args; calls.starts++; startedAt = -1; stateCode = -1;
      files.add(args.videoPath); files.add(args.innerPath); files.add(args.micPath);
      startGate = deferred();
      if (options.rejectStart) throw new Error('capture service failure');
      if (!options.deferConsent) emit(0);
      await startGate.promise;
    },
    cancel: () => { calls.cancels++; if (startedAt < 0) startGate?.reject(new Error('已取消录制')); },
    stop: async () => {
      calls.stops++; stateCode = 2;
      return { durationMs: startedAt < 0 ? 0 : Math.max(1, now - startedAt),
        micOffsetUs: options.invalidSync ? 20000000 : 17000, innerOffsetUs: -11000,
        syncValid: !options.invalidSync && !options.invalidSmallOffset,
        timestampMappingVersion: 2, videoTimestampDivisor: options.videoTimestampDivisor ?? 1000,
        videoFirstPtsUs: 5000000, videoLastPtsUs: 5000000 + Math.max(1, now - startedAt) * 1000,
        micFirstPtsUs: 5017000, innerFirstPtsUs: 4989000 };
    },
    getStatus: () => ({ stateCode, amplitude: stateCode === 0 ? .42 : 0, error: '' }),
    mix: async args => {
      if (/\/\d+\.mp4$/.test(args.outputPath)) {
        assert.equal(pendingCaptures.size, 1, 'Capture identity and validated mapping must be durable before initial export');
      }
      assert.ok(args.sourcePath.endsWith('-source.mp4'));
      assert.ok(args.innerPath.endsWith('-inner.pcm'));
      assert.ok(args.micPath.endsWith('-mic.pcm'));
      assert.equal(args.innerOffsetUs, -11000);
      calls.mixes.push(args);
      if (options.mixFailures > 0) { options.mixFailures--; throw new Error('encode failed'); }
      files.add(args.outputPath);
    }
  };
  const input = { id: 3, deviceType: options.headsetMic ? 7 : 15 };
  const mocks = {
    'libonebeat_recording.so': native,
    '@kit.AbilityKit': { abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
      checkAccessToken: async () => options.permissionRequired || options.permissionDenied ? -1 : 0,
      requestPermissionsFromUser: async (_context, permissions) => {
        assert.deepEqual([...permissions], ['ohos.permission.MICROPHONE']); calls.permissionRequests++;
        return { authResults: [options.permissionDenied ? -1 : 0] };
      }
    }) } },
    '@kit.AudioKit': { audio: { SourceType: { SOURCE_TYPE_MIC: 0 }, DeviceType: { MIC: 15 },
      getAudioManager: () => ({ getRoutingManager: () => ({
        getPreferredInputDeviceForCapturerInfo: async () => [input],
        on: (_name, _info, callback) => { inputListener = callback; }, off: () => { inputListener = undefined; }
      }) }) } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 1200, height: 2600 }) } },
    '@kit.CoreFileKit': { fileIo: { access: async path => files.has(path),
      stat: async () => ({ isFile: () => true, size: options.zeroOutput ? 0 : 1000 }),
      unlink: async path => { calls.deleted.push(path); files.delete(path); } } },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => now } },
    '../session/SessionBackgroundKeeper': { SessionBackgroundKeeper: { setRecordingActive: async value => calls.tasks.push(value) } },
    './RecordingRepository': { RecordingRepository: {
      get: id => calls.added.find(clip => clip.id === id),
      initialize: async () => {}, createTarget: async () => ({ id: `clip-${++sequence}`, path: `/recordings/${sequence}.mp4`, createdAt: 90000 }),
      loadPendingCapture: async () => [...pendingCaptures.values()][0],
      retainPendingCapture: async clip => {
        if (options.retainFailures > 0) { options.retainFailures--; throw new Error('metadata write failed'); }
        pendingCaptures.set(clip.id, JSON.parse(JSON.stringify(clip)));
      },
      clearPendingCapture: async clip => pendingCaptures.delete(clip.id),
      add: async clip => {
        if (options.addFailures > 0) { options.addFailures--; throw new Error('index write failed'); }
        calls.added.push(clip);
      }
    } }
  };
  const mixerContext = { exports: {}, require: name => mocks[name], Number, Math, Error };
  vm.runInNewContext(mixerJs, mixerContext);
  mocks['./RecordingMixer'] = mixerContext.exports;
  const context = { exports: {}, require: name => {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency: ${name}`); return mocks[name];
  }, console: { warn() {}, info(value) { calls.timingLogs.push(value); } }, canIUse: () => true, AppStorage: { get: () => epoch }, Date,
  setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, at: now + delay }); return id; },
  clearTimeout: id => timers.delete(id) };
  vm.runInNewContext(coordinatorJs, context);
  const coordinator = context.exports.RecordingCoordinator;
  return { coordinator, mixer: mixerContext.exports.RecordingMixer, calls, files, pendingCaptures, timers, emit,
    initialize: () => coordinator.initialize({ filesDir: '/files', applicationInfo: { accessTokenId: 14 } }),
    switchOutput: () => { epoch++; coordinator.handleRouteChange(); },
    switchInput: () => inputListener?.([{ id: 7, deviceType: 7 }]),
    async advance(ms) {
      now += ms;
      for (const [id, timer] of [...timers].filter(([, item]) => item.at <= now)) { timers.delete(id); timer.callback(); }
      await flush();
    }
  };
}
(async () => {
  const normal = harness();
  await normal.initialize();
  await normal.coordinator.start('team');
  await normal.advance(720);
  assert.equal(normal.coordinator.getSnapshot().amplitude, .42);
  const [clip, duplicate] = await Promise.all([normal.coordinator.stop(), normal.coordinator.stop()]);
  assert.equal(clip, duplicate);
  assert.equal(clip.durationMs, 720);
  assert.equal(clip.scope, 'team');
  assert.equal(clip.width, 720);
  assert.equal(clip.height, 1560);
  assert.equal(clip.renderedGain, 1);
  assert.equal(clip.micOffsetUs, 17000);
  assert.equal(clip.innerOffsetUs, -11000);
  assert.equal(clip.captureSyncValid, true);
  assert.equal(clip.captureMappingVersion, 2);
  assert.equal(clip.videoTimestampDivisor, 1000);
  assert.equal(normal.pendingCaptures.size, 0, 'Successful indexing clears the capture recovery note');
  assert.match(normal.calls.timingLogs[0], /\[RecordingTime\] mapping=2 divisor=1000/);
  assert.doesNotMatch(normal.calls.timingLogs[0], /\/recordings/, 'Timing diagnostics must not contain paths or work identifiers');
  assert.equal(normal.calls.starts, 1);
  assert.equal(normal.calls.stops, 1);
  assert.equal(normal.calls.mixes.length, 1);
  assert.equal(normal.calls.mixes[0].gain, 1);
  assert.equal(normal.calls.added.length, 1);
  assert.deepEqual(normal.calls.tasks, [true, false]);
  assert.equal(normal.timers.size, 0);
  await normal.mixer.exportMixed(clip, 0, '/recordings/preview-zero.mp4');
  await normal.mixer.exportMixed(clip, 2, '/recordings/preview-two.mp4');
  assert.equal(normal.calls.mixes.at(-2).gain, 0);
  assert.equal(normal.calls.mixes.at(-1).gain, 2);
  await assert.rejects(normal.mixer.exportMixed(clip, 2.01, '/recordings/bad.mp4'), /200%/);
  const legacy = { ...clip, captureSyncValid: undefined, captureMappingVersion: undefined, videoTimestampDivisor: undefined };
  normal.mixer.validateCaptureTiming(legacy);
  assert.throws(() => normal.mixer.validateCaptureTiming({ ...clip, captureSyncValid: false }), /时间戳不兼容/);
  assert.throws(() => normal.mixer.validateCaptureTiming({ ...clip, videoTimestampDivisor: 0 }), /时间戳不兼容/);

  const delayed = harness({ deferConsent: true });
  await delayed.initialize();
  const waiting = delayed.coordinator.start(); await flush();
  delayed.coordinator.handleBackground();
  await delayed.advance(1200);
  assert.equal(delayed.coordinator.getSnapshot().state, 'preparing');
  assert.equal(delayed.coordinator.getSnapshot().elapsedMs, 0);
  delayed.coordinator.handleForeground(); delayed.emit(0); await waiting;
  await delayed.advance(700);
  assert.equal((await delayed.coordinator.stop()).durationMs, 700);

  const cancelled = harness({ deferConsent: true }); await cancelled.initialize();
  const cancellation = cancelled.coordinator.start(); await flush(); cancelled.emit(1);
  await assert.rejects(cancellation, /取消/); await flush();
  assert.equal(cancelled.calls.added.length, 0);
  assert.equal(cancelled.calls.stops, 1);
  assert.equal(cancelled.files.size, 0);

  const leaving = harness({ deferConsent: true }); await leaving.initialize();
  const leavingStart = leaving.coordinator.start(); await flush();
  const leavingStop = leaving.coordinator.stop('page-hidden');
  await assert.rejects(leavingStart, /取消/); await leavingStop;
  assert.equal(leaving.calls.stops, 1);
  assert.equal(leaving.files.size, 0);

  const failed = harness({ rejectStart: true }); await failed.initialize();
  await assert.rejects(failed.coordinator.start(), /capture service failure/);
  assert.equal(failed.calls.stops, 1);
  assert.equal(failed.files.size, 0);

  for (const problem of ['index', 'encode', 'metadata']) {
    const retained = harness(problem === 'index' ? { addFailures: 1 } : problem === 'encode' ? { mixFailures: 1 } : { retainFailures: 1 });
    await retained.initialize(); await retained.coordinator.start(); await retained.advance(900);
    assert.equal(await retained.coordinator.stop(), undefined);
    assert.equal(retained.coordinator.getSnapshot().state, 'failed');
    assert.equal(retained.coordinator.getSnapshot().lastClip, undefined);
    assert.equal(retained.coordinator.getSnapshot().pendingClip.durationMs, 900);
    await assert.rejects(retained.coordinator.start(), /重试保存/);
    const saved = await retained.coordinator.retrySave();
    assert.equal(saved.durationMs, 900);
    assert.equal(retained.calls.starts, 1);
    assert.equal(retained.calls.deleted.length, 0);
    assert.equal(retained.calls.added.length, 1);
    assert.equal(retained.coordinator.getSnapshot().pendingClip, undefined);
  }

  const invalid = harness({ invalidSync: true }); await invalid.initialize();
  await invalid.coordinator.start(); await invalid.advance(500);
  assert.equal(await invalid.coordinator.stop(), undefined);
  assert.equal(invalid.calls.mixes.length, 0);
  assert.equal(invalid.calls.added.length, 0);
  await assert.rejects(invalid.coordinator.retrySave(), /原始音轨已保留/);
  assert.equal(invalid.calls.mixes.length, 0);
  assert.equal(invalid.files.size, 3);
  await invalid.coordinator.discardPending();
  assert.equal(invalid.coordinator.getSnapshot().pendingClip, undefined);
  assert.equal(invalid.coordinator.getSnapshot().state, 'idle');
  assert.equal(invalid.files.size, 0);

  for (const invalidSmallOffset of [false, true]) {
    const beforeRestart = harness({ mixFailures: 1, invalidSmallOffset });
    await beforeRestart.initialize(); await beforeRestart.coordinator.start('team'); await beforeRestart.advance(900);
    assert.equal(await beforeRestart.coordinator.stop(), undefined);
    assert.equal(beforeRestart.pendingCaptures.size, 1);
    const restored = harness({ files: beforeRestart.files, pendingCaptures: beforeRestart.pendingCaptures });
    await restored.initialize();
    assert.equal(restored.coordinator.getSnapshot().pendingClip.scope, 'team');
    assert.equal(restored.coordinator.getSnapshot().pendingClip.captureSyncValid, !invalidSmallOffset);
    await assert.rejects(restored.coordinator.start(), /重试保存/);
    if (invalidSmallOffset) {
      await assert.rejects(restored.coordinator.retrySave(), /同步校验未通过/);
      assert.equal(restored.calls.mixes.length, 0, 'Explicit invalid mapping must block retry even when both offsets are small');
      await restored.coordinator.discardPending();
    } else {
      const recovered = await restored.coordinator.retrySave();
      assert.equal(recovered.captureMappingVersion, 2);
      assert.equal(restored.calls.mixes.length, 1);
    }
    assert.equal(restored.pendingCaptures.size, 0);
  }

  for (const reason of ['output', 'input', 'background', 'call']) {
    const interrupted = harness(); await interrupted.initialize(); await interrupted.coordinator.start();
    await interrupted.advance(600);
    if (reason === 'output') interrupted.switchOutput();
    else if (reason === 'input') interrupted.switchInput();
    else if (reason === 'background') interrupted.coordinator.handleBackground();
    else { interrupted.emit(4); await interrupted.advance(80); }
    await flush();
    assert.equal(interrupted.calls.added.length, 1, reason);
    assert.equal(interrupted.calls.added[0].interrupted, true, reason);
    assert.equal(interrupted.calls.stops, 1, reason);
    assert.equal(interrupted.timers.size, 0, reason);
  }

  const denied = harness({ permissionDenied: true }); await denied.initialize();
  await assert.rejects(denied.coordinator.start(), /麦克风权限/);
  await assert.rejects(denied.coordinator.start(), /麦克风权限/);
  assert.equal(denied.calls.permissionRequests, 1);
  assert.equal(denied.calls.starts, 0);
  const headset = harness({ headsetMic: true }); await headset.initialize();
  await assert.rejects(headset.coordinator.start(), /手机麦克风/);
  assert.equal(headset.calls.starts, 0);

  const clock = harness(); await clock.initialize(); const seconds = [];
  clock.coordinator.subscribe(snapshot => seconds.push(Math.floor(snapshot.elapsedMs / 1000)));
  await clock.coordinator.start(); await clock.advance(1100);
  assert.ok(seconds.includes(1), 'elapsed time must notify the page without requiring PCM-driven scene redraws');
  await clock.coordinator.stop();
  console.log('PASS Recording lifecycle: consent, separate sources, measured MIC, 0–2 gain, retry and timing guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
