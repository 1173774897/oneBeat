const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

const source = fs.readFileSync('entry/src/main/ets/audio/MicCaptureExperiment.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function harness(config = {}) {
  const files = new Map(), handles = new Map(), intervals = new Map(), timeouts = new Map(), capturers = [];
  const trace = [];
  let now = 0, nextHandle = 0, nextTimer = 0, createCount = 0, insideRead = false;
  const deviceInfo = { sdkApiVersion: config.api ?? 20 };
  const fileIo = {
    OpenMode: { CREATE: 1, TRUNC: 2, WRITE_ONLY: 4 },
    async access(path) { assert.equal(insideRead, false, 'capture callback must never touch disk'); return files.has(path); },
    async mkdir(path) { files.set(path, null); },
    async open(path) {
      assert.equal(insideRead, false); trace.push(`write:${path}`);
      files.set(path, Buffer.alloc(0)); handles.set(++nextHandle, path); return { fd: nextHandle };
    },
    async write(fd, buffer) {
      assert.equal(insideRead, false);
      if (config.failWrite) { throw new Error('disk full'); }
      const input = Buffer.from(new Uint8Array(buffer));
      const count = Math.min(input.length, config.partialWrite ?? input.length);
      const path = handles.get(fd); files.set(path, Buffer.concat([files.get(path), input.subarray(0, count)]));
      now += path.endsWith('wav.tmp') ? config.wavWriteMs ?? 0 : config.reportWriteMs ?? 0;
      return count;
    },
    async fsync() { now += config.fsyncMs ?? 0; }, async close(file) { handles.delete(file.fd); },
    async rename(from, to) {
      assert.ok(files.has(from)); files.set(to, files.get(from)); files.delete(from); now += config.renameMs ?? 0;
    },
    async unlink(path) { files.delete(path); }
  };
  const audio = {
    SourceType: { SOURCE_TYPE_MIC: 0, SOURCE_TYPE_LIVE: 17 },
    AudioChannel: { CHANNEL_1: 1, CHANNEL_2: 2 },
    AudioSamplingRate: { SAMPLE_RATE_48000: 48000 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
    AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, InterruptType: { INTERRUPT_TYPE_BEGIN: 1 },
    getAudioManager: () => ({ getStreamManager: () => ({ isAcousticEchoCancelerSupported(source) {
      if (config.failCapability) { throw new Error('unsupported query'); }
      return source === 17 ? config.aec !== false : false;
    } }) }),
    async createAudioCapturer(options) {
      createCount++;
      if (config.failMono && options.streamInfo.channels === 1) { throw new Error('mono unsupported'); }
      if (config.pendingCreate) { await config.pendingCreate; }
      const events = new Map();
      const capturer = {
        options, events, frames: 0, started: 0, stopped: 0, stopCompleted: false, released: 0,
        async getStreamInfo() { return { ...options.streamInfo, ...(config.actualFormat ?? {}) }; },
        async getCapturerInfo() { return { source: config.actualSource ?? options.capturerInfo.source }; },
        on(type, callback) { events.set(type, callback); },
        off(type) {
          trace.push(`off:${type}`);
          if (type === 'readData' && !this.stopCompleted) { now += config.runningOffMs ?? 0; }
          events.delete(type);
          if (config.failOff) { throw new Error('native off failed'); }
        },
        async start() { this.started++; if (config.failStart) { throw new Error('focus denied'); } },
        async stop() {
          trace.push('native-stop'); this.stopped++; now += config.stopMs ?? 0;
          if (config.failStop) { throw new Error('native stop failed'); }
          if (config.pendingStop) { await config.pendingStop; }
          this.stopCompleted = true;
        },
        async release() {
          trace.push('native-release');
          this.released++;
          now += config.releaseMs ?? 0;
          if (config.alwaysFailRelease || config.failRelease && this.released === 1) { throw new Error('retry release'); }
        },
        getCurrentInputDevices: () => [{ deviceType: 15, deviceRole: 1, displayName: 'do not serialize', address: 'private' }],
        getAudioTimestampInfoSync() {
          if (config.failClock) { throw new Error('no timestamp'); }
          return { framePos: this.frames, timestamp: 1000000000 + this.frames * 1000000000 / 48000 };
        },
        getOverflowCountSync: () => 0,
        emit(buffer) {
          this.frames += buffer.byteLength / (options.streamInfo.channels * 2);
          now += buffer.byteLength / (options.streamInfo.channels * 2) / 48;
          insideRead = true;
          try { events.get('readData')?.(buffer); } finally { insideRead = false; }
        }
      };
      capturers.push(capturer); return capturer;
    }
  };
  const context = {
    exports: {}, require(name) {
      if (name === '@kit.AudioKit') { return { audio }; }
      if (name === '@kit.BasicServicesKit') { return { deviceInfo }; }
      if (name === '@kit.CoreFileKit') { return { fileIo }; }
      if (name === '@kit.ArkTS') { return { util: { TextEncoder: class {
        encodeInto(value) { trace.push('encode'); now += config.encodeMs ?? 0; return new TextEncoder().encode(value); }
      } } }; }
      if (name.endsWith('MonotonicClock')) { return { MonotonicClock: { nowMs: () => now } }; }
      if (name.endsWith('MicCaptureExperimentAnalysis')) {
        return { analyzeMicCaptureClock: (anchors, sampleRate) => {
          trace.push('analysis'); now += config.analysisMs ?? 0;
          return { sampleRate, anchorCount: anchors.length, quality: 'stable' };
        } };
      }
      throw new Error(name);
    },
    setTimeout(callback, delay) { timeouts.set(++nextTimer, { callback, delay }); return nextTimer; },
    clearTimeout(id) { timeouts.delete(id); },
    setInterval(callback, delay) { intervals.set(++nextTimer, { callback, delay }); return nextTimer; },
    clearInterval(id) { intervals.delete(id); }
  };
  vm.runInNewContext(compiled.outputText, context);
  return {
    Experiment: context.exports.MicCaptureExperiment, files, handles, capturers, trace, intervals, timeouts,
    get createCount() { return createCount; },
    tick() { for (const item of [...intervals.values()]) { item.callback(); } },
    timeout() { for (const item of [...timeouts.values()]) { item.callback(); } }
  };
}

async function flush() { for (let index = 0; index < 35; index++) { await Promise.resolve(); } }
function pcm(frames = 960, channels = 1, value = 1200) {
  const bytes = new ArrayBuffer(frames * channels * 2), view = new DataView(bytes);
  for (let offset = 0; offset < bytes.byteLength; offset += 2) { view.setInt16(offset, value, true); }
  return bytes;
}
async function finish(h, task, value = 1200) {
  await flush();
  const capturer = h.capturers.at(-1);
  assert.ok(capturer?.events.has('readData'), 'capturer actually starts and subscribes to PCM');
  for (let index = 0; index < 25; index++) {
    capturer.emit(pcm(960, capturer.options.streamInfo.channels, value));
    h.tick();
  }
  return await task;
}

(async () => {
  for (const config of [{ api: 19 }, { aec: false }, { failCapability: true }]) {
    const h = harness(config), capture = new h.Experiment();
    assert.equal(h.Experiment.capability().liveAvailable, false);
    await assert.rejects(capture.run('/private/app', 'live', undefined, 500));
    assert.equal(h.createCount, 0, 'unsupported LIVE never silently falls back to raw MIC');
  }
  {
    const h = harness({ partialWrite: 2048 }), capture = new h.Experiment();
    const seen = [];
    const result = await finish(h, capture.run('/private/app', 'live', {
      snapshot: () => '{"rendererId":9,"deviceType":15}',
      onProgress: (elapsed, level, frames) => seen.push({ elapsed, level, frames })
    }, 500), 32767);
    assert.equal(result.source, 'live'); assert.equal(result.aecSupported, true);
    assert.equal(result.sampleRate, 48000); assert.equal(result.channels, 1);
    assert.equal(result.totalFrames, 24000); assert.equal(result.durationMs, 500);
    assert.equal(result.clippedSamples, 24000); assert.equal(result.peak, 32767 / 32768);
    assert.equal(result.chunkCount, 25); assert.equal(result.chunks[1].firstFrame, 960);
    assert.equal(result.chunks[1].frameCount, 960); assert.equal(result.chunks[1].callbackGapMs, 20);
    assert.equal(result.anchors.at(-1).framePosition, 24000);
    assert.equal(result.anchors.at(-1).receivedFrames, 24000);
    assert.equal(result.anchors.at(-1).timestampNs, 1500000000);
    assert.ok(seen.some(item => item.level > 0 && item.frames > 0));
    const wav = h.files.get(result.wavPath);
    assert.equal(wav.toString('ascii', 0, 4), 'RIFF'); assert.equal(wav.toString('ascii', 8, 12), 'WAVE');
    assert.equal(wav.readUInt16LE(22), 1); assert.equal(wav.readUInt32LE(24), 48000);
    assert.equal(wav.readUInt32LE(40), 48000); assert.equal(wav.length, 48044);
    assert.deepEqual(wav.subarray(44), Buffer.from(pcm(24000, 1, 32767)), 'WAV preserves raw PCM bytes exactly');
    const report = h.files.get(result.reportPath).toString();
    assert.equal(report.includes('do not serialize'), false); assert.equal(report.includes('private\"'), false);
    assert.equal(h.capturers[0].stopped, 1); assert.equal(h.capturers[0].released, 1);
    assert.equal(h.intervals.size, 0); assert.equal(h.timeouts.size, 0); assert.equal(h.handles.size, 0);
    await assert.rejects(capture.removeResult({ ...result, wavPath: '/another/mic-capture-experiment/live.wav', reportPath: '/another/mic-capture-experiment/live.json' }));
    await capture.removeResult(result); assert.equal(h.files.has(result.wavPath), false);
  }
  {
    const h = harness({ failMono: true }), capture = new h.Experiment();
    const result = await finish(h, capture.run('/private/app', 'mic', undefined, 500));
    assert.equal(h.createCount, 2); assert.equal(result.channels, 2);
    assert.equal(h.files.get(result.wavPath).readUInt16LE(22), 2);
  }
  {
    const h = harness(), capture = new h.Experiment();
    const task = capture.run('/private/app', 'mic', undefined, 500); await flush();
    const lateCallback = h.capturers[0].events.get('readData');
    await assert.rejects(new h.Experiment().run('/private/app', 'mic', undefined, 500), /已有/);
    capture.cancel(); await assert.rejects(task, /取消/);
    assert.equal(h.capturers[0].released, 1); lateCallback(pcm());
    const result = await finish(h, capture.run('/private/app', 'mic', undefined, 500));
    assert.equal(result.totalFrames, 24000, 'late callbacks never enter a later run');
    await capture.clear('/private/app');
    assert.equal([...h.files.keys()].some(path => /\.(wav|json)$/.test(path)), false);
  }
  {
    let resolveCreate;
    const h = harness({ pendingCreate: new Promise(resolve => { resolveCreate = resolve; }) });
    const capture = new h.Experiment(), task = capture.run('/private/app', 'mic', undefined, 500);
    await flush(); capture.cancel(); resolveCreate();
    await assert.rejects(task, /取消/);
    assert.equal(h.capturers[0].started, 0); assert.equal(h.capturers[0].released, 1);
  }
  for (const config of [{ failStart: true }, { actualSource: 99 }, { actualFormat: { samplingRate: 44100 } }]) {
    const h = harness(config), capture = new h.Experiment();
    await assert.rejects(capture.run('/private/app', 'mic', undefined, 500));
    assert.equal(h.capturers[0].released, 1, 'failure after creation always releases the real capturer');
    assert.equal(h.intervals.size, 0); assert.equal(h.timeouts.size, 0);
  }
  for (const event of ['inputDeviceChange', 'audioInterrupt']) {
    const h = harness(), capture = new h.Experiment();
    const task = capture.run('/private/app', 'mic', undefined, 500); await flush();
    h.capturers[0].events.get(event)({ eventType: 1 });
    await assert.rejects(task, /变化|中断/); assert.equal(h.capturers[0].released, 1);
  }
  {
    const h = harness(), capture = new h.Experiment();
    const task = capture.run('/private/app', 'mic', undefined, 500); await flush(); h.timeout();
    await assert.rejects(task, /足够音频/); assert.equal(h.capturers[0].released, 1);
  }
  {
    const h = harness({ failClock: true, failRelease: true }), capture = new h.Experiment();
    const result = await finish(h, capture.run('/private/app', 'mic', undefined, 500));
    assert.equal(result.anchors.length, 0); assert.ok(result.timestampReadFailures > 0);
    assert.equal(h.capturers[0].released, 2, 'a transient release failure is retried before allowing another run');
  }
  for (const buffer of [new ArrayBuffer(1), new ArrayBuffer(200000)]) {
    const h = harness(), capture = new h.Experiment();
    const task = capture.run('/private/app', 'mic', undefined, 500); await flush();
    h.capturers[0].emit(buffer);
    await assert.rejects(task, /分块格式或大小异常/);
    assert.equal(h.capturers[0].released, 1, 'malformed or unbounded callback data cannot expand the fixed PCM buffer');
  }
  {
    const h = harness({ alwaysFailRelease: true }), capture = new h.Experiment();
    await assert.rejects(finish(h, capture.run('/private/app', 'mic', undefined, 500)), /资源未能释放/);
    assert.equal(h.capturers[0].released, 2);
    await assert.rejects(capture.run('/private/app', 'mic', undefined, 500), /重启应用/);
    assert.equal(h.capturers.length, 1, 'unconfirmed resource release blocks another capturer until restart');
  }
  {
    const h = harness({ failWrite: true }), capture = new h.Experiment();
    await assert.rejects(finish(h, capture.run('/private/app', 'mic', undefined, 500)), /disk full/);
    assert.equal(h.capturers[0].released, 1); assert.equal(h.handles.size, 0);
    assert.equal([...h.files.keys()].some(path => /\.(wav|json|tmp)$/.test(path)), false);
  }
  {
    const h = harness(), capture = new h.Experiment();
    let calls = 0;
    const task = capture.run('/private/app', 'mic', { snapshot: () => {
      if (++calls >= 2) { throw new Error('renderer changed'); } return 'renderer=9';
    } }, 500);
    await assert.rejects(task, /renderer changed/);
    assert.equal(h.capturers[0].released, 1, 'observer guard aborts without touching playback settings');
  }
  {
    const h = harness({ stopMs: 17, releaseMs: 23, analysisMs: 31, wavWriteMs: 41,
      reportWriteMs: 43, fsyncMs: 47, encodeMs: 53, renameMs: 59 });
    const capture = new h.Experiment(), stages = [];
    const result = await finish(h, capture.run('/private/app', 'mic', {
      snapshot: () => '{"underflowCount":0}', onStage: timing => stages.push({ ...timing })
    }, 500));
    const names = ['capturer-stop', 'capturer-unsubscribe', 'capturer-release', 'clock-analysis', 'wav-pack', 'wav-write',
      'report-encode', 'report-write', 'rename-wav', 'rename-report'];
    assert.deepEqual(stages.map(stage => stage.stage), names);
    assert.deepEqual(Array.from(result.stageTimings, timing => timing.stage), names);
    const durations = { 'capturer-unsubscribe': 0, 'capturer-stop': 17, 'capturer-release': 23, 'clock-analysis': 31, 'wav-pack': 0,
      'wav-write': 88, 'report-encode': 53, 'report-write': 90, 'rename-wav': 59, 'rename-report': 59 };
    for (const stage of stages) {
      assert.equal(stage.source, 'mic'); assert.equal(stage.error, '');
      assert.equal(stage.durationMs, durations[stage.stage]);
      assert.ok(stage.beforeSnapshotIndex >= 0 && stage.afterSnapshotIndex > stage.beforeSnapshotIndex);
      assert.equal(result.snapshots[stage.beforeSnapshotIndex].stage, `${stage.stage}-before`);
      assert.equal(result.snapshots[stage.afterSnapshotIndex].stage, `${stage.stage}-after`);
    }
    const diskReport = JSON.parse(h.files.get(result.reportPath).toString());
    assert.equal(diskReport.stageTimings.at(-1).stage, 'wav-write',
      'the encoded report does not pretend to include completion of its own write/rename; onStage supplies that tail');
  }
  for (const failurePoint of ['capturer-stop', 'clock-analysis', 'wav-write', 'report-encode', 'rename-report']) {
    const h = harness(), capture = new h.Experiment(), stages = [];
    let observedFailure = false, snapshotsAfterFailure = 0;
    const task = capture.run('/private/app', 'mic', {
      snapshot: () => {
        if (observedFailure) { snapshotsAfterFailure++; }
        const fail = failurePoint === 'capturer-stop' ? h.capturers[0]?.stopped > 0 :
          failurePoint === 'clock-analysis' ? h.trace.includes('analysis') :
          failurePoint === 'wav-write' ? h.files.has('/private/app/mic-capture-experiment/mic.wav.tmp') :
          failurePoint === 'report-encode' ? h.trace.includes('encode') :
          h.files.has('/private/app/mic-capture-experiment/mic.json');
        if (fail) { observedFailure = true; throw new Error(`guard rejected ${failurePoint}`); }
        return '{"underflowCount":0}';
      },
      onStage: timing => { stages.push({ ...timing }); if (timing.error) { throw new Error('secondary diagnostic error'); } }
    }, 500);
    await assert.rejects(finish(h, task), new RegExp(`guard rejected ${failurePoint}`));
    assert.equal(snapshotsAfterFailure, 0, 'failed guards are never invoked again during cleanup');
    const failedStage = stages.find(stage => stage.stage === failurePoint);
    assert.ok(failedStage, 'stage timing survives a throwing observer and a rejected result');
    assert.equal(failedStage.afterSnapshotIndex, -1); assert.match(failedStage.error, /guard rejected/);
    assert.equal(h.capturers[0].stopped, 1); assert.equal(h.capturers[0].released, 1);
    assert.equal([...h.files.keys()].some(path => /\.(wav|json|tmp)$/.test(path)), false,
      'a guard rejection in any completion stage leaves no finished recording');
  }
  {
    let resolveStop;
    const h = harness({ pendingStop: new Promise(resolve => { resolveStop = resolve; }) });
    const capture = new h.Experiment(), stages = [];
    let snapshots = 0;
    const task = capture.run('/private/app', 'mic', {
      snapshot: () => { snapshots++; return 'renderer=9'; }, onStage: timing => stages.push(timing)
    }, 500);
    await flush();
    for (let index = 0; index < 25; index++) { h.capturers[0].emit(pcm()); }
    await flush(); assert.equal(h.capturers[0].stopped, 1);
    capture.cancel(); const before = snapshots; resolveStop();
    await assert.rejects(task, /取消/);
    assert.equal(snapshots, before, 'no stage snapshot calls a hidden/cancelled page while release awaits');
    assert.equal(h.capturers[0].released, 1);
    assert.ok(stages.some(stage => stage.stage === 'capturer-stop' && /取消/.test(stage.error)));
  }
  {
    let resolveStop;
    const h = harness({ runningOffMs: 1000, pendingStop: new Promise(resolve => { resolveStop = resolve; }) });
    const capture = new h.Experiment();
    const task = capture.run('/private/app', 'mic', undefined, 500);
    await flush();
    for (let index = 0; index < 25; index++) { h.capturers[0].emit(pcm()); }
    await flush();
    assert.equal(h.capturers[0].stopped, 1);
    assert.equal(h.capturers[0].events.has('readData'), true, 'readData stays registered until native stop finishes');
    assert.equal(h.trace.some(item => item.startsWith('off:')), false, 'off never blocks the still-running capture');
    h.capturers[0].emit(pcm(960, 1, 32767));
    resolveStop(); const result = await task;
    assert.equal(result.totalFrames, 24000, 'accepting=false ignores late PCM while native stop is pending');
    assert.equal(result.clippedSamples, 0, 'late PCM cannot change captured quality statistics');
    assert.equal(result.stageTimings.find(stage => stage.stage === 'capturer-unsubscribe').durationMs, 0,
      'stopping before off avoids the simulated one-second running-callback join');
    assert.deepEqual(h.trace.filter(item => /^(native-stop|off:|native-release)/.test(item)),
      ['native-stop', 'off:readData', 'off:inputDeviceChange', 'off:audioInterrupt', 'native-release']);
  }
  {
    const h = harness({ failStop: true, failOff: true }), capture = new h.Experiment();
    await assert.rejects(finish(h, capture.run('/private/app', 'mic', undefined, 500)), /native stop failed/);
    assert.deepEqual(h.trace.filter(item => item.startsWith('off:')),
      ['off:readData', 'off:inputDeviceChange', 'off:audioInterrupt'], 'each unsubscribe is attempted after stop fails');
    assert.equal(h.capturers[0].released, 1, 'release still runs after stop and unsubscribe errors');
  }
  console.log('PASS mic-capture-experiment: real PCM, capability gates, clock observations, cancellation and cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
