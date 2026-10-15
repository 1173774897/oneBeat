// Run with DevEco's bundled Node; pass typescript/lib/typescript.js as argv[2].
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require(process.argv[2]);
const SOURCE = path.resolve('entry/src/main/ets/audio/MetronomeEngine.ets');
const ENGINE_SOURCE_OVERRIDE = process.env.ROUTE_PROBE_ENGINE_SOURCE;
const SAMPLE_RATE = 44100;
const AudioState = { STATE_PREPARED: 1, STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_PAUSED: 4 };

function harness(options = {}) {
  let now = 0;
  let nextTimer = 1;
  const timers = new Map();
  const logs = [];
  const pcm = [];
  const cache = new Map();
  let writesEnabled = true;
  let nextWriteAt = Number.POSITIVE_INFINITY;
  let startRequests = 0;
  let stopRequests = 0;
  let flushRequests = 0;
  let rendererCreates = 0;
  const callbacks = new Map();
  const renderer = {
    state: options.initialState ?? AudioState.STATE_PREPARED,
    on: (event, callback) => callbacks.set(event, callback),
    off: event => callbacks.delete(event),
    getAudioStreamIdSync: () => 42,
    getLatency: () => options.platformLatency ?? 285,
    getUnderflowCountSync: () => 0,
    getCurrentOutputDevices: async () => [{ deviceType: 8, id: 1 }],
    getAudioTimestampInfoSync: () => ({ framePos: 0, timestamp: Math.max(1, now * 1000000) }),
    start: () => {
      startRequests++;
      return new Promise((resolve, reject) => schedule(() => {
        if (options.startError) {
          reject(new Error(options.startError));
          return;
        }
        renderer.state = AudioState.STATE_RUNNING;
        callbacks.get('stateChange')?.(renderer.state);
        nextWriteAt = now + (options.firstWriteDelay ?? 0);
        resolve();
      }, options.coldStartDelay ?? 0));
    },
    stop: async () => {
      stopRequests++;
      if (options.stopError) throw new Error(options.stopError);
      renderer.state = AudioState.STATE_STOPPED;
      callbacks.get('stateChange')?.(renderer.state);
    },
    flush: async () => {
      flushRequests++;
      if (options.flushError) throw new Error(options.flushError);
    }, release: async () => {}
  };
  function schedule(callback, ms) {
    const id = nextTimer++;
    timers.set(id, { at: now + Math.max(0, ms), callback });
    return id;
  }
  const mocks = {
    '@kit.AudioKit': { audio: {
      AudioState,
      AudioSamplingRate: { SAMPLE_RATE_44100: SAMPLE_RATE }, AudioChannel: { CHANNEL_1: 1 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 1 },
      StreamUsage: { STREAM_USAGE_GAME: 1 },
      AudioDataCallbackResult: { VALID: 1, INVALID: 0 },
      AudioLatencyType: { LATENCY_TYPE_ALL: 1 },
      createAudioRenderer: () => {
        rendererCreates++;
        return new Promise(resolve => schedule(() => resolve(renderer), options.rendererCreateDelay ?? 0));
      }
    } },
    '@kit.BasicServicesKit': {},
    'BuildProfile': { DEBUG: false }
  };
  const context = vm.createContext({
    exports: {}, console: { info: x => logs.push(x), warn: x => logs.push(x) },
    ArrayBuffer, Int16Array, DataView, Map, Promise, Math: Object.assign(Object.create(Math), { random: () => 0.5 }),
    setTimeout: schedule, clearTimeout: id => timers.delete(id)
  });
  function load(file) {
    if (cache.has(file)) return cache.get(file);
    const exports = {};
    cache.set(file, exports);
    const moduleContext = Object.create(context);
    moduleContext.exports = exports;
    moduleContext.require = name => {
      if (mocks[name]) return mocks[name];
      if (name.endsWith('/MonotonicClock')) return { MonotonicClock: { nowMs: () => now } };
      if (name.endsWith('/AudioOutputMonitor')) return { AudioOutputMonitor: {
        isBluetoothA2dpActive: () => true, estimateBluetoothLinkLatencyMs: () => 0
      } };
      if (name.endsWith('/AudioLatencyPersistence')) return {
        getCalibrationMs: () => -1, getEffectiveCalibrationMs: () => -1, getInputLatencyMs: () => 0
      };
      if (name.endsWith('/DrumMachineCatalog')) return {};
      if (name.endsWith('/DrumSampleBank')) return {};
      return load(path.resolve(path.dirname(file), `${name}.ets`));
    };
    const source = fs.readFileSync(file === SOURCE && ENGINE_SOURCE_OVERRIDE ? ENGINE_SOURCE_OVERRIDE : file, 'utf8');
    const js = ts.transpileModule(source, { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
    } }).outputText;
    vm.runInNewContext(js, moduleContext, { filename: file });
    return exports;
  }
  const engine = new (load(SOURCE).MetronomeEngine)();
  // Ordinary playback coordinates can be rebased by the OS; route confirmation
  // only needs a conservative drain estimate after its PCM has fully submitted.
  engine.readRenderedStreamFrames = () => options.noTimestamp ? undefined :
    Math.max(0, engine.audioSubmittedFrames - (options.queueFrames ?? 35280));
  async function flushMicrotasks() {
    for (let i = 0; i < 14; i++) await Promise.resolve();
  }
  async function tick(ms = 20) {
    now += ms;
    for (let loop = 0; loop < 20; loop++) {
      const due = [...timers].filter(([, timer]) => timer.at <= now);
      if (!due.length) break;
      for (const [id, timer] of due) {
        timers.delete(id);
        timer.callback();
      }
      await flushMicrotasks();
    }
    if (writesEnabled && renderer.state === AudioState.STATE_RUNNING && now >= nextWriteAt) {
      const frames = Math.max(882, options.callbackFrames ?? 882);
      const data = new ArrayBuffer(frames * 2);
      callbacks.get('writeData')?.(data);
      pcm.push(...new Int16Array(data));
      nextWriteAt = now + 20;
    }
    await flushMicrotasks();
  }
  async function settle(task, limitMs = 14000) {
    let settled = false;
    let result;
    let error;
    task.then(value => { settled = true; result = value; }, e => { settled = true; error = e; });
    for (let elapsed = 0; !settled && elapsed <= limitMs; elapsed += 20) await tick();
    assert.ok(settled, 'The route probe must have bounded completion');
    if (error) throw error;
    return result;
  }
  function soundEvents() {
    const events = [];
    let previousLoudFrame = -SAMPLE_RATE;
    for (let frame = 0; frame < pcm.length; frame++) {
      if (Math.abs(pcm[frame]) < 64) continue;
      if (frame - previousLoudFrame > SAMPLE_RATE / 4) events.push(frame);
      previousLoudFrame = frame;
    }
    return events;
  }
  return {
    engine, renderer, logs, pcm, tick, settle, soundEvents, schedule,
    setWrites: value => { writesEnabled = value; },
    jumpClock: ms => { now += ms; },
    get now() { return now; }, get startRequests() { return startRequests; },
    get stopRequests() { return stopRequests; }, get flushRequests() { return flushRequests; },
    get rendererCreates() { return rendererCreates; }
  };
}

async function assertPair(options, mutate) {
  const h = harness(options);
  if (mutate) mutate(h);
  let completed;
  try {
    completed = await h.settle(h.engine.playRouteProbeClickPair());
  } catch (error) {
    console.error('Probe simulation:', options, h.logs);
    throw error;
  }
  assert.equal(completed, true);
  for (let i = 0; i < 60; i++) await h.tick();
  const events = h.soundEvents();
  assert.equal(events.length, 2, 'The actual PCM must contain exactly two audible transients');
  assert.equal(events[1] - events[0], 22050, 'The pair must be separated by 500 ms in PCM');
  assert.ok(Math.abs(h.pcm[events[0] + 4]) > Math.abs(h.pcm[events[1] + 4]),
    'The first PCM event must be the accent, followed by the weak click');
  assert.equal(h.rendererCreates, 1, 'Route confirmation must retain one ordinary renderer');
  assert.equal(h.startRequests, 1, 'No second renderer start may reset the probe origin');
  assert.equal(h.engine.calibrationFrameOriginExact, false, 'Probe warm-up must not enter strict mic timing');
  assert.equal(h.engine.timerId, -1, 'Route confirmation must not run a UI beat timer');
  return h;
}

(async () => {
  await assertPair({ coldStartDelay: 1600, firstWriteDelay: 700 });
  await assertPair({ queueFrames: 88200, callbackFrames: 4096 });
  await assertPair({ noTimestamp: true, firstWriteDelay: 400 });
  for (const initialState of [AudioState.STATE_PREPARED, AudioState.STATE_STOPPED, AudioState.STATE_PAUSED]) {
    const routeDirty = await assertPair({ initialState, flushError: 'system error' }, h => {
      h.engine.refreshOutputCalibration(true);
    });
    assert.equal(routeDirty.flushRequests, 0,
      'An ordinary route probe must not require the strict mic-clock flush');
    assert.equal(routeDirty.stopRequests, initialState === AudioState.STATE_PAUSED ? 1 : 0);
    assert.equal(routeDirty.engine.micCalibrationRendererRebuildPending, true,
      'An ordinary probe must leave strict mic-route invalidation for the next mic measurement');
  }

  const runningRouteDirty = harness({ flushError: 'system error', stopError: 'system error' });
  await runningRouteDirty.settle(runningRouteDirty.engine.warmUpRendererForPlayback());
  for (let i = 0; i < 20; i++) await runningRouteDirty.tick();
  const warmSubmitted = runningRouteDirty.engine.audioSubmittedFrames;
  const warmEpoch = runningRouteDirty.engine.rendererEpoch;
  runningRouteDirty.engine.refreshOutputCalibration(true);
  assert.equal(await runningRouteDirty.settle(runningRouteDirty.engine.playRouteProbeClickPair()), true);
  assert.equal(runningRouteDirty.stopRequests, 0, 'A healthy route notification must retain the ordinary playback stream');
  assert.equal(runningRouteDirty.flushRequests, 0);
  assert.equal(runningRouteDirty.startRequests, 1);
  assert.equal(runningRouteDirty.rendererCreates, 1);
  assert.equal(runningRouteDirty.engine.rendererEpoch, warmEpoch);
  assert.ok(runningRouteDirty.engine.audioSubmittedFrames > warmSubmitted,
    'Route confirmation must preserve the established frame origin');
  assert.equal(runningRouteDirty.soundEvents().length, 2);
  assert.equal(runningRouteDirty.soundEvents()[1] - runningRouteDirty.soundEvents()[0], 22050);
  assert.equal(runningRouteDirty.engine.calibrationFrameOriginExact, false,
    'Ordinary route handling does not prove an exact mic-calibration origin');

  const stalledRouteDirty = harness({ flushError: 'system error' });
  await stalledRouteDirty.settle(stalledRouteDirty.engine.warmUpRendererForPlayback());
  for (let i = 0; i < 20; i++) await stalledRouteDirty.tick();
  stalledRouteDirty.setWrites(false);
  stalledRouteDirty.jumpClock(2000);
  stalledRouteDirty.engine.refreshOutputCalibration(true);
  stalledRouteDirty.schedule(() => stalledRouteDirty.setWrites(true), 100);
  assert.equal(await stalledRouteDirty.settle(stalledRouteDirty.engine.playRouteProbeClickPair()), true);
  assert.equal(stalledRouteDirty.stopRequests, 1, 'A running stream with stalled writes must still recover');
  assert.equal(stalledRouteDirty.startRequests, 2);
  assert.equal(stalledRouteDirty.flushRequests, 0);
  assert.equal(stalledRouteDirty.soundEvents().length, 2);
  assert.equal(stalledRouteDirty.soundEvents()[1] - stalledRouteDirty.soundEvents()[0], 22050);
  assert.equal(stalledRouteDirty.engine.calibrationFrameOriginExact, false);

  const strictMic = harness({ flushError: 'system error' });
  await strictMic.settle(strictMic.engine.ensureRenderer());
  await assert.rejects(strictMic.settle(strictMic.engine.ensureSilentRendererRunning(true)),
    /重置麦克回环音频时钟失败：system error/);
  assert.equal(strictMic.flushRequests, 1, 'Strict mic timing must still require its physical flush');
  assert.equal(strictMic.startRequests, 0, 'A failed strict reset must not start an unproven mic clock');
  assert.equal(strictMic.engine.calibrationFrameOriginExact, false);
  assert.equal(strictMic.soundEvents().length, 0);
  assert.equal(await strictMic.settle(strictMic.engine.playRouteProbeClickPair()), true,
    'A rejected strict reset must release serialized preparation for an ordinary probe');
  assert.equal(strictMic.flushRequests, 1, 'The ordinary retry must not repeat the failed strict reset');
  assert.equal(strictMic.soundEvents().length, 2);

  const startFailure = harness({ startError: 'native start rejected', flushError: 'system error' });
  startFailure.engine.refreshOutputCalibration(true);
  await assert.rejects(startFailure.settle(startFailure.engine.playRouteProbeClickPair()), /native start rejected/);
  assert.equal(startFailure.startRequests, 1);
  assert.equal(startFailure.flushRequests, 0);
  assert.equal(startFailure.soundEvents().length, 0, 'A genuine native-start failure must never report a completed pair');
  assert.equal(startFailure.engine.rendererStarted, false);
  await assertPair({}, h => {
    const configure = h.engine.configureRouteProbeClickPair.bind(h.engine);
    h.engine.configureRouteProbeClickPair = () => {
      configure(); h.jumpClock(2500);
      // Advance the simulated callback clock too: this case tests late wall
      // deadlines while audio remains healthy, independently of a write stall.
      h.engine.lastWriteProgressMs = h.now;
    };
  });

  const lobbyWarmup = harness({ rendererCreateDelay: 700, coldStartDelay: 500 });
  const ordinaryWarmup = lobbyWarmup.engine.warmUpRendererForPlayback();
  const pairWhileWarming = lobbyWarmup.engine.playRouteProbeClickPair();
  assert.deepEqual(await lobbyWarmup.settle(Promise.all([ordinaryWarmup, pairWhileWarming])), [undefined, true]);
  assert.equal(lobbyWarmup.rendererCreates, 1, 'Lobby warm-up and route probe must share native creation');
  assert.equal(lobbyWarmup.startRequests, 1, 'The probe must retain the lobby warm-up stream');
  assert.equal(lobbyWarmup.soundEvents().length, 2);

  const cancelled = harness({ rendererCreateDelay: 700, coldStartDelay: 1000 });
  let cancel = false;
  cancelled.schedule(() => { cancel = true; }, 100);
  assert.equal(await cancelled.settle(cancelled.engine.playRouteProbeClickPair(() => cancel)), false);
  assert.equal(cancelled.soundEvents().length, 0, 'Cancellation during cold preparation must not configure a pair');
  assert.equal(await cancelled.settle(cancelled.engine.playRouteProbeClickPair()), true);
  assert.equal(cancelled.soundEvents().length, 2, 'A superseded cold preparation must not overwrite a new probe');
  assert.equal(cancelled.rendererCreates, 1);

  const newer = harness();
  newer.schedule(() => {
    newer.engine.beginTransport();
    newer.engine.audioStreaming = true;
  }, 900);
  assert.equal(await newer.settle(newer.engine.playRouteProbeClickPair()), false);
  assert.equal(newer.engine.running, true, 'An obsolete probe must not stop the newer transport');
  assert.equal(newer.engine.audioStreaming, true);

  const changed = harness();
  changed.schedule(() => { changed.engine.rendererPhysicalStartCount++; }, 900);
  assert.equal(await changed.settle(changed.engine.playRouteProbeClickPair()), false,
    'A changed physical origin must invalidate completion');

  const epoch = harness();
  epoch.schedule(() => { epoch.engine.rendererEpoch++; }, 1000);
  assert.equal(await epoch.settle(epoch.engine.playRouteProbeClickPair()), false);

  const realTransport = harness({ rendererCreateDelay: 700, coldStartDelay: 500 });
  let cancelForTransport = false;
  let transport;
  realTransport.schedule(() => {
    cancelForTransport = true;
    realTransport.engine.configure(0, 0);
    transport = realTransport.engine.scheduleFromLeaderStart(realTransport.now + 2000, 0, 4, 0);
  }, 100);
  assert.equal(await realTransport.settle(
    realTransport.engine.playRouteProbeClickPair(() => cancelForTransport)), false);
  await realTransport.settle(transport);
  for (let i = 0; i < 190; i++) await realTransport.tick();
  assert.equal(realTransport.rendererCreates, 1, 'Late native creation must be shared with ordinary transport');
  assert.equal(realTransport.startRequests, 1, 'Cancelled preparation must not start its silent stream after creation');
  assert.equal(realTransport.engine.running, true, 'The tap transport must retain logical ownership');
  assert.equal(realTransport.engine.activeSequenceLooping, true, 'Late preview preparation must not replace the tap sequence');
  assert.equal(realTransport.engine.audioStreaming, true, 'Late preparation must not clear the live tap transition');

  const neverWrites = harness({ firstWriteDelay: 100000 });
  await assert.rejects(neverWrites.settle(neverWrites.engine.playRouteProbeClickPair()), /写入回调/);
  assert.equal(neverWrites.soundEvents().length, 0);

  const stalled = harness();
  stalled.schedule(() => stalled.setWrites(false), 1000);
  await assert.rejects(stalled.settle(stalled.engine.playRouteProbeClickPair()), /未完整播放/);
  assert.equal(stalled.soundEvents().length, 1,
    'A partially submitted pair must fail rather than claim that both clicks played');

  const coldTimeout = harness({ coldStartDelay: 100000 });
  await assert.rejects(coldTimeout.settle(coldTimeout.engine.playRouteProbeClickPair()), /启动超时/);
  await assert.rejects(coldTimeout.settle(coldTimeout.engine.playRouteProbeClickPair()), /启动超时/,
    'A new request queued behind a hung native start must also fail within its bound');
  assert.equal(coldTimeout.rendererCreates, 1);
  assert.equal(coldTimeout.startRequests, 1);

  const drainStall = harness({ queueFrames: 88200 });
  drainStall.schedule(() => drainStall.setWrites(false), 1800);
  await assert.rejects(drainStall.settle(drainStall.engine.playRouteProbeClickPair()), /输出已停滞/);
  assert.equal(drainStall.soundEvents().length, 2,
    'A frozen drain must fail even though both PCM events were already submitted');

  const ordinary = harness();
  ordinary.engine.configure(0, 0);
  assert.equal(ordinary.engine.pendingSequenceLooping, true, 'Ordinary metronome configuration must keep looping');
  ordinary.engine.prepareAudioCursor(0);
  ordinary.engine.audioStreaming = true;
  const output = new ArrayBuffer(SAMPLE_RATE * 6 * 2);
  ordinary.engine.fillAudioData(output);
  for (const sample of new Int16Array(output)) ordinary.pcm.push(sample);
  assert.equal(ordinary.soundEvents().length, 12, 'Ordinary looping PCM must remain unchanged');
  console.log('PASS: route PCM preserves accent + weak at 500 ms across cold starts, dirty routes, queues and clock jumps; ordinary playback avoids strict mic resets, while strict-reset/native-start failure and cancellation remain bounded');
})().catch(error => { console.error(error); process.exitCode = 1; });
