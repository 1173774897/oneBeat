// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
let now = 1000;
const state = { STATE_RUNNING: 2, STATE_STOPPED: 3, STATE_PAUSED: 5 };
const hint = { INTERRUPT_HINT_RESUME: 1, INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3 };
let nextRenderer;
const mocks = {
  '@kit.AudioKit': { audio: { AudioState: state, InterruptHint: hint,
    AudioDataCallbackResult: { VALID: 0 },
    AudioSamplingRate: { SAMPLE_RATE_44100: 44100 }, AudioChannel: { CHANNEL_1: 1 },
    AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
    StreamUsage: { STREAM_USAGE_MUSIC: 1 }, createAudioRenderer: async () => nextRenderer } },
  '@kit.BasicServicesKit': {},
  '../common/MonotonicClock': { MonotonicClock: { nowMs: () => now } },
  './AudioOutputMonitor': { AudioOutputMonitor: { isBluetoothA2dpActive: () => false } },
  '../store/AudioLatencyPersistence': { getCalibrationMs: () => -1,
    getEffectiveCalibrationMs: () => -1, getInputLatencyMs: () => 0 },
  './DrumMachineCatalog': {}, './DrumSampleBank': {}, BuildProfile: { DEBUG: false }
};
function load(name) {
  const context = { exports: {}, require: key => mocks[key], console, ArrayBuffer, Map, Int16Array, DataView, setTimeout, clearTimeout };
  const source = fs.readFileSync(`entry/src/main/ets/audio/${name}.ets`, 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, context);
  return context.exports;
}
mocks['./ClickSound'] = load('ClickSound');
const meterContext = { exports: {}, Math, Number };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('entry/src/main/ets/common/MeterModel.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, meterContext);
mocks['../common/MeterModel'] = meterContext.exports;
mocks['./RhythmTimeline'] = load('RhythmTimeline');
const { MetronomeEngine } = load('MetronomeEngine');
function engine() { const e = new MetronomeEngine(); e.configure(0, 0); return e; }
function renderer() {
  return { state: state.STATE_RUNNING, handlers: {}, on(type, cb) { this.handlers[type] = cb; },
    async stop() { this.state = state.STATE_STOPPED; }, async flush() {},
    async start() { this.state = state.STATE_RUNNING; },
    getAudioTimestampInfoSync: () => ({ framePos: 0, timestamp: now * 1000000 }),
    getUnderflowCountSync: () => 0 };
}
(async () => {
  // Exercise actual PCM rendering and bar transitions, with no drum configuration.
  for (const rhythm of [0, 1, 2]) {
    const e = engine(); e.configure(rhythm, 0); e.prepareAudioCursor(0, 4); e.audioStreaming = true;
    for (let bar = 0; bar < 100; bar++) {
      const pcm = new ArrayBuffer(88200 * 2); e.fillAudioData(pcm);
      assert.ok(new Int16Array(pcm).some(x => x !== 0));
      assert.equal(e.activeSequenceFinished, false);
    }
  }
  const e = engine(); e.renderer = renderer(); e.rendererStarted = true; e.running = true; e.runToken = 1;
  e.transportStartLocalMs = 1000;
  let completeStop;
  let starts = 0;
  e.renderer.stop = () => new Promise(resolve => { completeStop = () => { e.renderer.state = state.STATE_STOPPED; resolve(); }; });
  e.renderer.start = async () => { starts++; e.renderer.state = state.STATE_RUNNING; };
  const stop = e.haltRenderer();
  const start = e.startAudioStream(1500, 1, 0, 1);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(starts, 0);
  completeStop(); await Promise.all([stop, start]);
  assert.equal(starts, 1);
  assert.equal(e.audioTimelineLeadFrames, 0);
  assert.equal(e.transportStartLocalMs, 1000);

  // Native start cannot be recalled; a pause while it is pending must prevent
  // its late completion from restoring the logical transport or transition.
  let completeStart;
  e.renderer.stop = async () => { e.renderer.state = state.STATE_STOPPED; };
  e.renderer.start = () => new Promise(resolve => {
    starts++;
    completeStart = () => { e.renderer.state = state.STATE_RUNNING; resolve(); };
  });
  e.lastWriteProgressMs = -10000;
  const cancelledStart = e.startAudioStream(1500, 1, 0, 1);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(typeof completeStart, 'function');
  e.pause(); completeStart(); await cancelledStart; await e.rendererOperation;
  assert.equal(starts, 2);
  assert.equal(e.running, false);
  assert.equal(e.rendererStarted, false);
  assert.equal(e.pendingAudioTransition, undefined);

  const recovered = engine(); recovered.renderer = renderer(); recovered.running = true;
  recovered.runToken = 7; recovered.transportRevision = 3;
  recovered.transportStartLocalMs = 1000; recovered.transportStartBeatIndex = 0;
  recovered.transportCountInBeats = 4; recovered.nextBeatAtMs = 3000; recovered.beatIndex = 4;
  now = 2600;
  await recovered.recoverAudio('test stall');
  assert.equal(recovered.runToken, 7);
  assert.equal(recovered.transportRevision, 3);
  assert.equal(recovered.transportStartLocalMs, 1000);
  const recoveryTransition = recovered.pendingAudioTransition;
  assert.equal(recoveryTransition.beatIndex, 5, 'Recovery reserves cold-start lead on a future shared beat');
  assert.equal(recoveryTransition.countInBeats, 0, 'Recovery must not replay the rehearsal bar');
  assert.equal(recoveryTransition.token, 7);
  recovered.fillAudioData(new ArrayBuffer((recoveryTransition.targetFrame + 1) * 2));
  assert.equal(recovered.activeLoopStartIndex, 0);
  assert.equal(recovered.audioTimelineToken, 7, 'The recovered PCM must stay on the existing transport');
  assert.equal(recovered.pendingAudioTransition, undefined);

  const monitored = engine(); monitored.renderer = renderer(); monitored.audioStreaming = true;
  monitored.lastWriteProgressMs = 1000;
  const recoveries = [];
  monitored.recoverAudio = async reason => { recoveries.push(reason); };
  monitored.checkAudioProgress(2000); assert.equal(recoveries.length, 0);
  monitored.checkAudioProgress(2600); assert.equal(recoveries.length, 1);
  monitored.renderer.state = state.STATE_PAUSED;
  monitored.checkAudioProgress(5000); assert.equal(recoveries.length, 1);
  monitored.renderer.state = state.STATE_RUNNING; monitored.writeCallbackCount++;
  monitored.checkAudioProgress(5000); assert.equal(recoveries.length, 1);

  nextRenderer = renderer(); const focused = engine(); await focused.ensureRenderer();
  focused.recoverAudio = async reason => { recoveries.push(reason); };
  nextRenderer.handlers.audioInterrupt({ hintType: hint.INTERRUPT_HINT_RESUME, forceType: 1 });
  assert.equal(recoveries.length, 1);
  focused.running = true;
  nextRenderer.handlers.audioInterrupt({ hintType: hint.INTERRUPT_HINT_PAUSE, forceType: 0 });
  assert.equal(recoveries.length, 1);
  nextRenderer.handlers.audioInterrupt({ hintType: hint.INTERRUPT_HINT_RESUME, forceType: 1 });
  assert.equal(recoveries.length, 2);
  console.log('PASS: 300 metronome bars, serialized stop/start, pause during native start, stall detection, focus resume');
})().catch(error => { console.error(error); process.exitCode = 1; });
