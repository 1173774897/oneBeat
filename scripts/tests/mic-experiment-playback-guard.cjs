const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync('entry/src/main/ets/audio/MicExperimentPlaybackGuard.ets', 'utf8');
const context = { exports: {} };
vm.runInNewContext(ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, context);
const problem = context.exports.micExperimentPlaybackProblem;
const before = { sampledAtMonoMs: 1000, rendererEpoch: 1, streamId: 42, physicalStartCount: 1,
  running: true, started: true, state: 2, interruptCount: 0, underflowCount: 0,
  lastWriteProgressMs: 999, outputDevices: '8:1', audioScene: 0 };
assert.equal(problem(before, { ...before, sampledAtMonoMs: 1500, lastWriteProgressMs: 1499,
  outputDevices: '', audioScene: -1 }), '', 'Fast snapshots omit slow boundary queries');
for (const change of [{ running: false }, { started: false }, { state: 3 }, { rendererEpoch: 2 },
  { streamId: 43 }, { physicalStartCount: 2 }, { interruptCount: 1 }, { underflowCount: 1 },
  { sampledAtMonoMs: 1900 }, { outputDevices: '7:2' }, { audioScene: 3 }]) {
  assert.notEqual(problem(before, { ...before, ...change }), '', JSON.stringify(change));
}
assert.equal(problem({ ...before, underflowCount: -1, audioScene: -1 },
  { ...before, underflowCount: -1, audioScene: -1 }), '', 'Unavailable counters never invent a successful measurement');
const anchored = { ...before, rawFrame: 44100, timestampMonoMs: 1000 };
assert.equal(problem(anchored, { ...anchored, rawFrame: 44100 * 3, timestampMonoMs: 3000 }), '');
assert.equal(problem(anchored, { ...anchored, rawFrame: 44100 * 3 - 882, timestampMonoMs: 3000 }), '', '20ms frame quantum tolerated');
for (const change of [{ rawFrame: 0 }, { timestampMonoMs: 900 },
  { rawFrame: 44100 * 3 - 4410, timestampMonoMs: 3000 }]) {
  assert.match(problem(anchored, { ...anchored, ...change }), /时间戳/, JSON.stringify(change));
}
console.log('PASS MIC playback guard: route, scene, focus, renderer restart, underrun, hardware clock and progress boundaries');
