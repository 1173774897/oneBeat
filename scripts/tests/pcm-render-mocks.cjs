// Shared stubs for suites that whitelist every MetronomeEngine dependency.
// PcmRender is the real pure renderer, resolved against the suite's own mocks;
// no TaskPool runner is registered, so configuration PCM renders synchronously.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const AUDIO_DIR = path.resolve(__dirname, '../../entry/src/main/ets/audio');

function pcmRenderMocks(ts, mocks, math = Math) {
  const loaded = new Map();
  // A suite mock wins; otherwise load the real module (some suites add theirs later).
  const resolve = (dir, name) => {
    if (mocks[name] !== undefined) return mocks[name];
    const file = path.resolve(dir, `${name}.ets`);
    if (!loaded.has(file)) loaded.set(file, load(file));
    return loaded.get(file);
  };
  function load(file) {
    const exports = {};
    const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText;
    vm.runInNewContext(output, { exports, require: name => resolve(path.dirname(file), name), console,
      ArrayBuffer, Map, Int16Array, Float32Array, DataView, Date, Math: math });
    return exports;
  }
  return {
    './PcmRender': load(path.join(AUDIO_DIR, 'PcmRender.ets')),
    './PcmRenderOffload': { PcmRenderOffload: { get: () => undefined, register() {} } }
  };
}

module.exports = { pcmRenderMocks };
