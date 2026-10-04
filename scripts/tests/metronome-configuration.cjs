// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const loads = [];
const mocks = {
  '@kit.AudioKit': {}, '@kit.BasicServicesKit': {},
  './ClickSound': { ClickSound: { buildAccentBuffer: () => new ArrayBuffer(2), buildWeakBuffer: () => new ArrayBuffer(2), buildTone: () => new ArrayBuffer(2) } },
  '../common/MonotonicClock': {},
  './RhythmTimeline': { BuiltInRhythmFactory: { create: () => ({ beatsPerBar: 4 }) } },
  './DrumMachineCatalog': { parseDrumProgram: raw => ({ styleKey: raw }), buildProgramSequence: () => [{}] },
  './DrumSampleBank': { DrumSampleBank: { loadStyle: () => new Promise(resolve => loads.push(resolve)) } }
};
const context = { exports: {}, require: name => mocks[name], console, ArrayBuffer, Map, Int16Array };
const source = fs.readFileSync('entry/src/main/ets/audio/MetronomeEngine.ets', 'utf8');
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, context);
function engine() {
  const e = new context.exports.MetronomeEngine();
  e.renderBar = () => ({ samples: new Int16Array([120, 0]), frameCount: 2, samplesPerBeat: 0.5, beatsPerBar: 4 });
  e.configure(0, 0);
  return e;
}
(async () => {
  const e = engine();
  const preview = e.configureProgram('preview', false);
  const walk = e.configureProgram('walk', true);
  loads[1](new Map()); await walk;
  loads[0](new Map()); await preview;
  assert.equal(e.customProgramRaw, 'walk');
  assert.equal(e.pendingSequenceLooping, true);
  e.prepareAudioCursor(0); e.audioStreaming = true;
  const pcm = new ArrayBuffer(80); e.fillAudioData(pcm);
  assert.equal(new Int16Array(pcm).filter(x => x !== 0).length, 20);

  const late = e.configureProgram('late-preview', false);
  await e.configureProgram('walk', true);
  loads[2](new Map()); await late;
  assert.equal(e.customProgramRaw, 'walk');

  const oneShot = e.configureProgram('one-shot', false);
  loads[3](new Map()); await oneShot;
  e.prepareAudioCursor(0); e.fillAudioData(pcm);
  assert.equal(new Int16Array(pcm).filter(x => x !== 0).length, 1);
  e.configure(0, 0);
  assert.equal(e.pendingSequenceLooping, true);
  e.prepareAudioCursor(0); e.fillAudioData(pcm);
  assert.equal(new Int16Array(pcm).filter(x => x !== 0).length, 20);

  const stale = e.configureProgram('stale', false);
  e.configure(0, 0);
  loads[4](new Map()); await stale;
  assert.equal(e.customProgram, undefined);
  assert.equal(e.pendingSequenceLooping, true);
  console.log('PASS: out-of-order loads, cached request invalidation, one-shot completion, built-in loop restoration');
})().catch(error => { console.error(error); process.exitCode = 1; });
