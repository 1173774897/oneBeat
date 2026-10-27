// Run with Node and a typescript/lib/typescript.js path, matching the drum regressions.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const sourceRoot = path.resolve(__dirname, '../../entry/src/main/ets');
const storage = new Map();
const writes = [];
const cache = new Map();
const files = new Map();
function load(relative) {
  const file = path.resolve(sourceRoot, relative);
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  vm.runInNewContext(compiled.outputText, {
    exports,
    AppStorage: {
      get: key => storage.get(key),
      setOrCreate: (key, value) => { storage.set(key, value); writes.push([key, value]); }
    },
    require(name) {
      if (name === '../common/AtomicTextFile') return {
        readOptionalSync: path => files.get(path) ?? '',
        writeAtomicSync: (path, contents) => files.set(path, contents)
      };
      return load(path.relative(sourceRoot, path.resolve(path.dirname(file), `${name}.ets`)));
    }
  }, { filename: file });
  return exports;
}
const catalog = load('audio/DrumMachineCatalog.ets');
const library = load('audio/DrumProgramLibrary.ets');
library.initializeDrumProgramLibrary({ filesDir: '/test-files' });
const key = 'savedDrumPrograms';
const plain = value => JSON.parse(JSON.stringify(value));
const section = (id, styleKey) => ({ id, styleKey, patternIndex: 1, repeats: 4, fillIndex: 2, fillEvery: 4 });
const mixed = {
  styleKey: 'rock', beatsPerBar: 4, beatUnit: 4,
  sections: [section('A', 'rock'), section('B', 'jazz'), section('C', 'funk'), section('D', 'rock')]
};
mixed.sections[1].customPattern = { subdivision: 3, events: [
  { tick: 160, sampleKey: 'snare', velocity: 0.37 },
  { tick: 480, sampleKey: 'ride', velocity: 0.61 }
] };
const first = { id: 'first', name: '混合律动', program: JSON.stringify(mixed) };
const second = { id: 'second', name: '同名也可使用 ID 区分', program: JSON.stringify({
  beatsPerBar: 3, beatUnit: 8, sections: [section('A', 'psychedelic')]
}) };

for (const raw of [undefined, '', 42, null, 'broken', 'null', '{}', 'true', '[]']) {
  storage.set(key, raw);
  assert.deepEqual(plain(library.loadSavedDrumPrograms()), [], 'Malformed storage must not synthesize a default item');
}
const obsolete = { id: 'old', name: '旧风格记录', program: JSON.stringify({
  ...mixed, sections: [{ id: 'A', patternIndex: 0, repeats: 4, fillIndex: 0, fillEvery: 4 }]
}) };
const invalidPrograms = ['broken', 'null', '{}', JSON.stringify({ ...mixed, beatUnit: 3 }),
  JSON.stringify({ ...mixed, sections: [] }), JSON.stringify({ ...mixed, sections: [null] }),
  JSON.stringify({ ...mixed, sections: [{}] }), JSON.stringify({ ...mixed, sections: [section('A', 'missing')] }),
  JSON.stringify({ ...mixed, sections: [{ ...section('A', 'jazz'), repeats: -1 }] })];
const invalidEntries = [null, 1, 'bad', [], {}, { ...first, id: '' }, { ...first, name: '   ' },
  { ...first, program: {} }, ...invalidPrograms.map((program, i) => ({ id: `bad-${i}`, name: 'bad', program }))];
storage.set(key, JSON.stringify([first, ...invalidEntries, obsolete, second, { ...first, name: 'duplicate ID' }]));
const untouchedStorage = storage.get(key);
const loaded = library.loadSavedDrumPrograms();
assert.deepEqual(plain(loaded.map(p => [p.id, p.name])), [[first.id, first.name], [second.id, second.name]],
  'Valid order/identity is stable; malformed, obsolete and duplicate records are ignored');
assert.equal(storage.get(key), untouchedStorage, 'Read validation must not mutate persisted data');
assert.equal(writes.length, 0);
const restored = catalog.parseDrumProgram(loaded[0].program);
assert.deepEqual(plain(restored.sections[1].customPattern), mixed.sections[1].customPattern,
  'Canonicalization preserves manually edited timing, velocities and samples');
assert.deepEqual(plain(catalog.drumProgramStyleKeys(restored)), ['rock', 'jazz', 'funk']);
assert.equal(catalog.parseDrumProgram(loaded[1].program).sections[0].styleKey, 'psychedelic',
  'Section-only style records remain valid');
assert.deepEqual(plain(library.loadSavedDrumPrograms()), plain(loaded));
loaded[0].name = 'local only';
assert.equal(library.loadSavedDrumPrograms()[0].name, first.name, 'Consumers must not share mutable records');

library.writeSavedDrumPrograms([second, first, ...invalidEntries, obsolete]);
assert.equal(writes.length, 1);
assert.equal(writes[0][0], key, 'Editor and stage must keep the same AppStorage key');
const expectedOrder = [second.id, first.id];
assert.deepEqual(plain(library.loadSavedDrumPrograms().map(p => p.id)), expectedOrder);
const canonicalStorage = storage.get(key);
library.writeSavedDrumPrograms(library.loadSavedDrumPrograms());
assert.equal(storage.get(key), canonicalStorage, 'Canonical writes are idempotent and do not invent entries');
library.writeSavedDrumPrograms([]);
assert.deepEqual(JSON.parse(storage.get(key)), [], 'Deleting all entries clears the shared library');
const records = [first, second].map(entry => ({ ...entry,
  program: catalog.serializeDrumProgram(catalog.parseDrumProgram(entry.program)) }));
assert.equal(library.resolveSavedDrumProgram(records[0].program, undefined, records).id, first.id);
assert.equal(library.resolveSavedDrumProgram(records[0].program, '', records), undefined,
  'Explicitly unnamed drafts never acquire an owner from equal content');
assert.equal(library.resolveSavedDrumProgram(records[0].program, 'deleted', records), undefined);
assert.equal(library.resolveSavedDrumProgram(records[1].program, first.id, records).id, first.id,
  'An edited draft remains owned by ID instead of becoming a different equal-content record');
assert.equal(library.resolveSavedDrumProgram(records[0].program, undefined,
  [records[0], { ...records[0], id: 'clone' }]), undefined, 'Ambiguous origin cannot silently pick a record to overwrite');
library.rememberRecentDrumProgram(records[1].program, second.id);
assert.deepEqual(plain(library.loadRecentDrumProgram()), { program: records[1].program, libraryId: second.id });
library.rememberRecentDrumProgram(records[0].program, '');
assert.equal(library.loadRecentDrumProgram().libraryId, '', 'The recent cache preserves deliberate unnamed identity');
storage.set('recentDrumProgram', '{broken');
assert.equal(library.loadRecentDrumProgram(), undefined, 'Broken caches cannot lend an identity to unrelated audio');
console.log('PASS drum program library: shared storage, multi-style/custom-event preservation, section-only input, safe rejection, stable identities/order, independent reads and idempotent writes');
