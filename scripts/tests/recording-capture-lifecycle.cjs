// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const nativeSource = fs.readFileSync('entry/src/main/cpp/recording_native.cpp', 'utf8');
const trackWriterSource = nativeSource.match(/struct TrackWriter \{[\s\S]*?\n\};/)?.[0] ?? '';
const mixFileSource = nativeSource.slice(
  nativeSource.indexOf('ProcessedMicInfo MixFile('), nativeSource.indexOf('std::mutex globalMutex'));
assert.match(trackWriterSource,
  /WriteAll\(fd,\s*chunk\.bytes\.data\(\),\s*chunk\.bytes\.size\(\)\)/,
  'Every accepted screen-capture PCM payload must be appended byte-for-byte');
assert.doesNotMatch(trackWriterSource, /\b(?:targetFrame|missing|skip)\s*=/,
  'Per-callback timestamps must not edit otherwise contiguous PCM');
assert.match(nativeSource,
  /const int size = capacity;[\s\S]*chunk\.bytes\.assign\(address,\s*address \+ size\)/,
  'Screen-capture audio uses its exact callback capacity, not optional codec attrs');
assert.match(nativeSource,
  /EchoFirReferenceFirstFrame\(\s*absoluteFrame,\s*model\.delayFrames\)/,
  'Speaker reference delay must use the absolute output frame across AAC input blocks');
assert.doesNotMatch(nativeSource, /frame\s*>=\s*speakerBleedDelayFrames/,
  'Speaker cancellation must not reset its delay at each encoder block');
assert.match(nativeSource,
  /ProcessedMicInfo EnsureProcessedMic[\s\S]*existing\.st_size == expectedBytes[\s\S]*std::vector<float> residual/,
  'Echo-cleaned MIC must be cached once as an unclipped floating-point residual');
assert.match(nativeSource,
  /constexpr int64_t VIDEO_BITRATE = 8000000;[\s\S]*OH_MD_KEY_BITRATE, VIDEO_BITRATE/,
  '1080-wide screen capture must raise its H.264 bitrate with the pixel count');
assert.doesNotMatch(mixFileSource, /EstimateEchoAt\(/,
  'A gain or manual alignment remux must not repeat the expensive FIR fit');
assert.match(mixFileSource,
  /effectiveMicShiftUs = options\.micShiftUs \+ processedInfo\.autoMicShiftUs[\s\S]*ReadAlignedProcessedMic\([^;]*effectiveMicShiftUs[\s\S]*MixProcessedMicSample/,
  'Automatic baseline and manual edit must shift only the cached MIC residual before the final mix');
function compile(path) {
  const compiled = ts.transpileModule(fs.readFileSync(path, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  return compiled.outputText;
}
const coordinatorJs = compile('entry/src/main/ets/recording/RecordingCoordinator.ets');
const mixerJs = compile('entry/src/main/ets/recording/RecordingMixer.ets');
const playbackObserverJs = compile('entry/src/main/ets/audio/RecordingPlaybackObserver.ets');
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject }; }
async function flush() { for (let i = 0; i < 80; i++) await Promise.resolve(); }
function harness(options = {}) {
  let now = 1000, sequence = 0, timerId = 0, epoch = 1, startedAt = -1, stateCode = -1;
  let startGate, inputListener, nativeOptions;
  const files = options.files ?? new Set();
  const pendingCaptures = options.pendingCaptures ?? new Map();
  const timers = new Map();
  const playback = { rendererEpoch: 4, streamId: 17, physicalStartCount: 1, running: true, started: true,
    state: 2, writeCallbackCount: 100, submittedFrames: 48000, interruptCount: 0, underflowCount: 0,
    outputDevices: '2:8', audioScene: 0, latencyHardwareMs: 34, latencySoftwareMs: 12, latencyAllMs: 46,
    rawFrame: 48000, timestampMonoMs: 1000, productionClockQueryMonoMs: 1000, productionFrame: 48000 };
  const forbiddenPlaybackCall = () => {
    calls.playbackMutations.push('mutation');
    throw new Error('Recording may not mutate the team playback engine');
  };
  let session = options.observePlayback ? { controller: { state: 'playing' }, metronome: {
    readMicExperimentPlaybackSnapshot(details) {
      return { ...playback, sampledAtMonoMs: now, lastWriteProgressMs: now,
        ...(details ? {} : { outputDevices: '', audioScene: -1, latencyHardwareMs: -1, latencySoftwareMs: -1, latencyAllMs: -1 }) };
    }, pause: forbiddenPlaybackCall, stopEngine: forbiddenPlaybackCall, configure: forbiddenPlaybackCall,
    setOffsetMs: forbiddenPlaybackCall, setBpm: forbiddenPlaybackCall, scheduleFromLeaderStart: forbiddenPlaybackCall
  } } : undefined;
  const calls = { starts: 0, stops: 0, cancels: 0, permissionRequests: 0, added: [], mixes: [], deleted: [], tasks: [], timingLogs: [],
    nativeOptions: [], inputQueries: [], inputSubscriptions: [], aecQueries: [], playbackMutations: [] };
  function emit(code) {
    stateCode = code;
    if (code === 0) { startedAt = now; startGate?.resolve(); }
    else if (code === 1) startGate?.reject(new Error('已取消录制'));
  }
  const native = {
    start: async args => {
      nativeOptions = args; calls.nativeOptions.push(args); calls.starts++; startedAt = -1; stateCode = -1;
      files.add(args.videoPath); files.add(args.innerPath); files.add(args.micPath);
      startGate = deferred();
      if (options.rejectStart) throw new Error('capture service failure');
      if (!options.deferConsent) emit(0);
      await startGate.promise;
    },
    cancel: () => { calls.cancels++; if (startedAt < 0) startGate?.reject(new Error('已取消录制')); },
    stop: async () => {
      calls.stops++; stateCode = 2;
      if (options.stopGate) await options.stopGate.promise;
      return { durationMs: startedAt < 0 ? 0 : Math.max(1, now - startedAt),
        micOffsetUs: options.invalidSync ? 20000000 : 17000, innerOffsetUs: -11000,
        syncValid: !options.invalidSync && !options.invalidSmallOffset,
        timestampMappingVersion: options.timestampMappingVersion ?? (nativeOptions?.systemAecMic ? 3 : 2),
        videoTimestampDivisor: options.videoTimestampDivisor ?? 1000,
        videoFirstPtsUs: 5000000, videoLastPtsUs: 5000000 + Math.max(1, now - startedAt) * 1000,
        micFirstPtsUs: 5017000, innerFirstPtsUs: 4989000,
        micCaptureMode: options.actualMicCaptureMode ?? (nativeOptions?.systemAecMic ? 'system-aec' : 'screen-mic'),
        micAecApplied: options.actualMicAecApplied ?? nativeOptions?.systemAecMic === true,
        micHardwareTimestampKnown: options.micHardwareTimestampKnown ?? true,
        micInputChannels: 1 };
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
      assert.ok(Number.isFinite(args.micShiftUs));
      const systemAecCache = nativeOptions?.systemAecMic ??
        [...pendingCaptures.values()][0]?.micCaptureMode === 'system-aec';
      assert.equal(args.processedMicPath, systemAecCache ?
        `${args.micPath}.system-aec-v2.f32` : `${args.micPath}.clean-v3.f32`);
      assert.ok(args.autoMicShiftKnown === 0 || args.autoMicShiftKnown === 1);
      calls.mixes.push(args);
      if (options.mixFailures > 0) { options.mixFailures--; throw new Error('encode failed'); }
      files.add(args.outputPath);
      return args.autoMicShiftKnown === 1 ? {
        autoMicShiftUs: args.autoMicShiftUs,
        autoMicShiftConfidence: args.autoMicShiftConfidence,
        autoMicShiftReliable: args.autoMicShiftReliable === 1
      } : args.speakerBleedCancel > 0 ? {
        autoMicShiftUs: -1000, autoMicShiftConfidence: .8, autoMicShiftReliable: true
      } : {
        autoMicShiftUs: 0, autoMicShiftConfidence: 0, autoMicShiftReliable: false
      };
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
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: options.sdkApiVersion ?? 19 } },
    '@kit.AudioKit': { audio: { SourceType: { SOURCE_TYPE_MIC: 0, SOURCE_TYPE_LIVE: 17 }, DeviceType: { MIC: 15 },
      getAudioManager: () => ({
        getStreamManager: () => ({ isAcousticEchoCancelerSupported(source) {
          calls.aecQueries.push(source);
          if (options.capabilityFailure) throw new Error('AEC capability query unavailable');
          return options.liveAecSupported === true;
        } }),
        getRoutingManager: () => ({
          getPreferredInputDeviceForCapturerInfo: async info => { calls.inputQueries.push(info.source); return [input]; },
          on: (_name, info, callback) => { calls.inputSubscriptions.push(info.source); inputListener = callback; },
          off: () => { inputListener = undefined; }
        })
      }) } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 1200, height: 2600 }) } },
    '@kit.CoreFileKit': { fileIo: { access: async path => files.has(path),
      stat: async () => ({ isFile: () => true, size: options.zeroOutput ? 0 : 1000 }),
      unlink: async path => { calls.deleted.push(path); files.delete(path); } } },
    '../audio/AudioOutputMonitor': { AudioOutputMonitor: {
      isBuiltInSpeakerActive: () => options.builtInSpeaker === true
    } },
    '../app/AppSession': { AppSession: { get: () => session } },
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
  const timerGlobals = {
    setTimeout(callback, delay) { const id = ++timerId; timers.set(id, { callback, at: now + delay }); return id; },
    clearTimeout: id => timers.delete(id),
    setInterval(callback, delay) { const id = ++timerId; timers.set(id, { callback, at: now + delay, delay }); return id; },
    clearInterval: id => timers.delete(id)
  };
  const observerContext = { exports: {}, console: {
    info(value) { calls.timingLogs.push(value); }, warn(value) { calls.timingLogs.push(value); }
  }, ...timerGlobals };
  vm.runInNewContext(playbackObserverJs, observerContext);
  mocks['../audio/RecordingPlaybackObserver'] = observerContext.exports;
  const context = { exports: {}, require: name => {
    assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency: ${name}`); return mocks[name];
  }, console: { warn() {}, info(value) { calls.timingLogs.push(value); } }, canIUse: () => true, AppStorage: { get: () => epoch }, Date,
  ...timerGlobals };
  vm.runInNewContext(coordinatorJs, context);
  const coordinator = context.exports.RecordingCoordinator;
  return { coordinator, mixer: mixerContext.exports.RecordingMixer, calls, files, pendingCaptures, timers, emit,
    initialize: () => coordinator.initialize({ filesDir: '/files', applicationInfo: { accessTokenId: 14 } }),
    switchOutput: () => { epoch++; coordinator.handleRouteChange(); },
    switchInput: () => inputListener?.([{ id: 7, deviceType: 7 }]),
    changePlayback: change => Object.assign(playback, change),
    endSession: () => { session = undefined; },
    async advance(ms) {
      now += ms;
      for (const [id, timer] of [...timers].filter(([, item]) => item.at <= now)) {
        if (!timers.has(id)) continue;
        if (timer.delay !== undefined) timer.at = now + timer.delay;
        else timers.delete(id);
        timer.callback();
      }
      await flush();
    }
  };
}
(async () => {
  const stopGate = deferred();
  const tail = harness({ stopGate });
  await tail.initialize();
  await tail.coordinator.start('solo');
  await tail.advance(250);
  const boundaries = [];
  tail.coordinator.subscribe(snapshot => boundaries.push({ ...snapshot }));
  const pendingStop = tail.coordinator.stop();
  await flush();
  assert.equal(tail.coordinator.getSnapshot().state, 'stopping');
  assert.equal(tail.coordinator.getSnapshot().captureActive, true,
    'Requesting Stop cannot certify that screen frames have stopped');
  assert.equal(tail.calls.mixes.length, 0, 'Export must wait for native stop/release');
  stopGate.resolve();
  await pendingStop;
  assert.ok(boundaries.some(snapshot => snapshot.state === 'stopping' &&
    snapshot.captureActive === false && snapshot.savePhase === 'finishing'),
    'Publish the capture-release boundary before mixing, even while state remains stopping');
  assert.equal(tail.coordinator.getSnapshot().captureActive, false);

  const normal = harness();
  await normal.initialize();
  await normal.coordinator.start('team');
  await normal.advance(720);
  assert.equal(normal.coordinator.getSnapshot().amplitude, .42);
  const [clip, duplicate] = await Promise.all([normal.coordinator.stop(), normal.coordinator.stop()]);
  assert.equal(clip, duplicate);
  assert.equal(clip.durationMs, 720);
  assert.equal(clip.scope, 'team');
  assert.equal(clip.width, 1080);
  assert.equal(clip.height, 2340);
  assert.equal(clip.renderedGain, 1);
  assert.equal(clip.renderedMixVersion, 6);
  assert.equal(clip.renderedMicShiftUs, 0);
  assert.equal(clip.autoMicShiftUs, 0);
  assert.equal(clip.autoMicShiftReliable, false);
  assert.equal(clip.micOffsetUs, 17000);
  assert.equal(clip.innerOffsetUs, -11000);
  assert.equal(clip.captureSyncValid, true);
  assert.equal(clip.captureMappingVersion, 2);
  assert.equal(clip.videoTimestampDivisor, 1000);
  assert.equal(normal.pendingCaptures.size, 0, 'Successful indexing clears the capture recovery note');
  const timingLog = normal.calls.timingLogs.find(value => value.includes('[RecordingTime]'));
  assert.match(timingLog, /\[RecordingTime\] mapping=2 divisor=1000/);
  assert.doesNotMatch(timingLog, /\/recordings/, 'Timing diagnostics must not contain paths or work identifiers');
  assert.equal(normal.calls.starts, 1);
  assert.equal(normal.calls.stops, 1);
  assert.equal(normal.calls.mixes.length, 1);
  assert.equal(normal.calls.mixes[0].gain, 1);
  assert.equal(normal.calls.mixes[0].micShiftUs, 0);
  assert.equal(normal.calls.added.length, 1);
  assert.deepEqual(normal.calls.tasks, [true, false]);
  assert.equal(normal.timers.size, 0);
  await normal.mixer.exportMixed(clip, 0, '/recordings/preview-zero.mp4');
  await normal.mixer.exportMixed(clip, 2, '/recordings/preview-two.mp4', -60000);
  assert.equal(normal.calls.mixes.at(-2).gain, 0);
  assert.equal(normal.calls.mixes.at(-1).gain, 2);
  assert.equal(normal.calls.mixes.at(-1).micShiftUs, -60000);
  assert.equal(normal.calls.mixes.at(-1).speakerBleedCancel, 0);
  const automaticMix = await normal.mixer.exportMixed({
    ...clip, autoMicShiftUs: undefined, autoMicShiftConfidence: undefined,
    autoMicShiftReliable: undefined, builtInSpeakerCapture: true
  }, 1,
    '/recordings/preview-speaker.mp4');
  assert.equal(automaticMix.autoMicShiftUs, -1000);
  assert.equal(automaticMix.autoMicShiftReliable, true);
  assert.equal(normal.calls.mixes.at(-1).speakerBleedCancel, 4,
    'Built-in speaker mix passes only a ceiling; native code estimates the actual bleed level');
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

  const systemAec = { sdkApiVersion: 20, liveAecSupported: true, builtInSpeaker: true };
  const aec = harness({ ...systemAec, observePlayback: true }); await aec.initialize(); await aec.coordinator.start('team');
  await aec.advance(820);
  const aecClip = await aec.coordinator.stop();
  assert.equal(aecClip.scope, 'team', 'Team recording uses the same production AEC chain');
  assert.equal(aec.calls.nativeOptions[0].systemAecMic, true);
  assert.deepEqual(aec.calls.aecQueries, [17]);
  assert.deepEqual(aec.calls.inputQueries, [17, 17],
    'Preflight and active-route validation both query the actual LIVE capture source');
  assert.deepEqual(aec.calls.inputSubscriptions, [17]);
  assert.equal(aecClip.micCaptureMode, 'system-aec');
  assert.equal(aecClip.captureMappingVersion, 3);
  assert.equal(aecClip.captureSyncValid, true);
  assert.equal(aecClip.renderedGain, 1);
  assert.equal(aecClip.autoMicShiftUs, 0);
  assert.equal(aecClip.autoMicShiftConfidence, 0);
  assert.equal(aecClip.autoMicShiftReliable, false);
  assert.equal(aec.calls.mixes[0].speakerBleedCancel, 0);
  assert.equal(aec.calls.mixes[0].autoMicShiftKnown, 1);
  assert.equal(aec.calls.mixes[0].processedMicPath, `${aecClip.micPath}.system-aec-v2.f32`);
  assert.deepEqual(aec.calls.tasks, [true, false]);
  assert.equal(aec.timers.size, 0);
  assert.deepEqual(aec.calls.playbackMutations, [], 'Starting and ending AEC never touches the existing team transport or calibration');
  for (const phase of ['before-native-start', 'native-started', 'before-native-stop', 'after-native-stop']) {
    assert.ok(aec.calls.timingLogs.some(value => value.includes(`phase=${phase}`) && value.includes('transport=playing')),
      `${phase}: an existing team output is observed at each capture lifecycle boundary`);
  }

  for (const unavailable of [
    { sdkApiVersion: 19, liveAecSupported: true },
    { sdkApiVersion: 20, liveAecSupported: false },
    { sdkApiVersion: 20, liveAecSupported: true, capabilityFailure: true }
  ]) {
    const fallback = harness(unavailable); await fallback.initialize();
    await fallback.coordinator.start('team'); await fallback.advance(500);
    const fallbackClip = await fallback.coordinator.stop();
    assert.equal(fallback.calls.nativeOptions[0].systemAecMic, false);
    assert.deepEqual(fallback.calls.inputQueries, [0, 0]);
    assert.deepEqual(fallback.calls.inputSubscriptions, [0]);
    assert.equal(fallbackClip.micCaptureMode, 'screen-mic');
    assert.equal(fallbackClip.captureMappingVersion, 2);
    assert.equal(fallbackClip.captureSyncValid, true);
    if (unavailable.sdkApiVersion < 20) assert.deepEqual(fallback.calls.aecQueries, [],
      'Old SDKs must not call an unavailable API merely to decide the fallback');
  }

  for (const unsafeResult of [
    { actualMicCaptureMode: 'screen-mic' },
    { actualMicAecApplied: false },
    { timestampMappingVersion: 2 },
    { micHardwareTimestampKnown: false }
  ]) {
    const unsafe = harness({ ...systemAec, ...unsafeResult }); await unsafe.initialize();
    await unsafe.coordinator.start('team'); await unsafe.advance(500);
    assert.equal(await unsafe.coordinator.stop(), undefined);
    assert.equal(unsafe.coordinator.getSnapshot().state, 'failed');
    assert.equal(unsafe.coordinator.getSnapshot().pendingClip.micCaptureMode, 'system-aec');
    assert.equal(unsafe.coordinator.getSnapshot().pendingClip.captureSyncValid, false);
    assert.equal(unsafe.calls.mixes.length, 0, 'A requested AEC capture may never silently export a mismatched native fallback');
    assert.equal(unsafe.files.size, 3, 'Unverified captures retain their immutable source tracks for explicit disposal');
    await unsafe.coordinator.discardPending();
    assert.equal(unsafe.files.size, 0);
  }

  const aecCancel = harness({ ...systemAec, deferConsent: true }); await aecCancel.initialize();
  const aecWaiting = aecCancel.coordinator.start('team'); await flush();
  const aecStopping = aecCancel.coordinator.stop('page-hidden');
  await assert.rejects(aecWaiting, /取消/); await aecStopping;
  assert.equal(aecCancel.calls.nativeOptions[0].systemAecMic, true);
  assert.equal(aecCancel.calls.stops, 1);
  assert.equal(aecCancel.files.size, 0);
  assert.equal(aecCancel.timers.size, 0);
  assert.deepEqual(aecCancel.calls.tasks, [true, false]);
  const aecStartFailure = harness({ ...systemAec, rejectStart: true }); await aecStartFailure.initialize();
  await assert.rejects(aecStartFailure.coordinator.start('team'), /capture service failure/);
  assert.equal(aecStartFailure.calls.starts, 1, 'A failed LIVE start must not retry through a hidden second MIC chain');
  assert.equal(aecStartFailure.calls.stops, 1);
  assert.equal(aecStartFailure.files.size, 0);

  const aecPending = harness({ ...systemAec, mixFailures: 1 }); await aecPending.initialize();
  await aecPending.coordinator.start('team'); await aecPending.advance(910);
  assert.equal(await aecPending.coordinator.stop(), undefined);
  assert.equal([...aecPending.pendingCaptures.values()][0].micCaptureMode, 'system-aec');
  const aecRestart = harness({ ...systemAec, files: aecPending.files, pendingCaptures: aecPending.pendingCaptures });
  await aecRestart.initialize();
  assert.equal(aecRestart.coordinator.getSnapshot().pendingClip.micCaptureMode, 'system-aec');
  const aecRecovered = await aecRestart.coordinator.retrySave();
  assert.equal(aecRecovered.captureMappingVersion, 3);
  assert.equal(aecRecovered.micCaptureMode, 'system-aec');
  assert.equal(aecRecovered.autoMicShiftUs, 0);
  assert.equal(aecRestart.calls.starts, 0, 'Save recovery exports retained AEC stems without opening any new capture');

  const aecRoute = harness(systemAec); await aecRoute.initialize(); await aecRoute.coordinator.start('team');
  await aecRoute.advance(600); aecRoute.switchInput(); await flush();
  assert.equal(aecRoute.calls.added.length, 1);
  assert.equal(aecRoute.calls.added[0].interrupted, true);
  assert.equal(aecRoute.calls.added[0].micCaptureMode, 'system-aec');
  assert.equal(aecRoute.calls.stops, 1);
  for (const change of [{ interruptCount: 1 }, { streamId: 18 }, { underflowCount: 1 }]) {
    const protectedTeam = harness({ ...systemAec, observePlayback: true }); await protectedTeam.initialize();
    await protectedTeam.coordinator.start('team'); await protectedTeam.advance(500);
    protectedTeam.changePlayback(change); await protectedTeam.advance(300); await flush();
    assert.equal(protectedTeam.calls.added.length, 1);
    assert.equal(protectedTeam.calls.added[0].interrupted, true);
    assert.equal(protectedTeam.calls.added[0].stopReason, 'playback-output-change');
    assert.equal(protectedTeam.calls.stops, 1, 'Observable team playback changes stop capture only once');
    assert.equal(protectedTeam.calls.starts, 1);
    assert.deepEqual(protectedTeam.calls.playbackMutations, [],
      'The AEC safety observer must not pause, restart, reschedule or recalibrate the accompaniment');
    assert.equal(protectedTeam.timers.size, 0);
  }
  console.log('PASS Recording lifecycle: consent, separate sources, measured MIC, 0–2 gain, retry and timing guards');
})().catch(error => { console.error(error); process.exitCode = 1; });
