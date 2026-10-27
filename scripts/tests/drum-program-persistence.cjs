// Run production snapshot code against real files and fresh VM/AppStorage instances for each launch.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { load, ets, meter, catalog, plain } = require('./drum-editor-preview.cjs');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'onebeat-drum-library-'));
const snapshotPath = path.join(root, 'drum-programs-v1.json');
let fail = '', syncs = 0;
const atomic = load(ets('common/AtomicTextFile.ets'), {
  '@kit.CoreFileKit': { fileIo: {
    OpenMode: { CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC, WRITE_ONLY: fs.constants.O_WRONLY },
    accessSync: name => fs.existsSync(name),
    readTextSync: name => {
      if (fail === 'read') throw new Error('simulated read failure');
      return fs.readFileSync(name, 'utf8');
    },
    openSync: (name, flags) => ({ fd: fs.openSync(name, flags) }),
    writeSync: (fd, bytes) => {
      if (fail === 'write') return 0;
      const buffer = Buffer.from(bytes);
      return fs.writeSync(fd, buffer, 0, Math.min(buffer.length, 1021));
    },
    fsyncSync: fd => {
      if (fail === 'sync') throw new Error('simulated sync failure');
      syncs++; fs.fsyncSync(fd);
    },
    closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd),
    renameSync: (from, to) => {
      if (fail === 'rename') throw new Error('simulated rename failure');
      fs.renameSync(from, to);
    },
    unlinkSync: name => fs.unlinkSync(name)
  } },
  '@kit.ArkTS': { util: {
    generateRandomUUID: () => randomUUID(),
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } }
  } }
});

function launch(directory = root, initialize = true) {
  const storage = new Map();
  const library = load(ets('audio/DrumProgramLibrary.ets'), {
    './DrumMachineCatalog': catalog, '../common/MeterModel': meter, '../common/AtomicTextFile': atomic
  }, { AppStorage: {
    get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value)
  } });
  if (initialize) library.initializeDrumProgramLibrary({ filesDir: directory });
  return { library, storage };
}

try {
  const program = catalog.defaultDrumProgram();
  program.sections[0].styleKey = 'rock';
  program.sections[0].customPattern = { subdivision: 6, events: Array.from({ length: 100 }, (_, i) =>
    ({ tick: i * 16, sampleKey: 'snare', velocity: 0.53 })) };
  const raw = catalog.serializeDrumProgram(catalog.parseDrumProgram(catalog.serializeDrumProgram(program)));
  const records = Array.from({ length: 12 }, (_, i) => ({ id: `arrangement-${i}`, name: `我的编排 ${i}`, program: raw }));
  const notReady = launch(root, false);
  assert.throws(() => notReady.library.writeSavedDrumPrograms(records), /尚未准备好/);
  assert.equal(notReady.storage.get('savedDrumPrograms'), undefined, 'Uninitialized saves cannot pretend to succeed');

  const first = launch();
  first.library.writeSavedDrumPrograms(records);
  first.library.rememberRecentDrumProgram(raw, records[3].id);
  assert.ok(fs.statSync(snapshotPath).size > 8192, 'Libraries larger than a Preferences value must be fully retained');
  assert.equal(syncs, 2, 'Both library saves and recent-arrangement updates flush before returning');
  const rebooted = launch();
  assert.deepEqual(plain(rebooted.library.loadSavedDrumPrograms()), records);
  assert.deepEqual(plain(rebooted.library.loadRecentDrumProgram()), { program: raw, libraryId: records[3].id });

  const updated = catalog.parseDrumProgram(raw);
  updated.sections[0].repeats = 7;
  const updatedRaw = catalog.serializeDrumProgram(updated);
  const next = records.map((record, i) => i === 3 ? { ...record, program: updatedRaw } : record);
  rebooted.library.writeSavedDrumPrograms(next);
  rebooted.library.rememberRecentDrumProgram(updatedRaw, records[3].id);
  const afterUpdate = launch();
  assert.deepEqual(plain(afterUpdate.library.loadSavedDrumPrograms()), next, 'Same-ID overwrites survive a new process');
  assert.equal(afterUpdate.library.resolveSavedDrumProgram(updatedRaw,
    afterUpdate.library.loadRecentDrumProgram().libraryId, afterUpdate.library.loadSavedDrumPrograms()).name, records[3].name);

  const before = fs.readFileSync(snapshotPath, 'utf8');
  for (const failure of ['write', 'sync', 'rename']) {
    fail = failure;
    assert.throws(() => afterUpdate.library.writeSavedDrumPrograms([]));
    assert.deepEqual(plain(afterUpdate.library.loadSavedDrumPrograms()), next,
      'A failed disk write must not clear the visible library');
    assert.throws(() => afterUpdate.library.rememberRecentDrumProgram(raw, ''));
    assert.equal(afterUpdate.library.loadRecentDrumProgram().libraryId, records[3].id);
    fail = '';
    assert.equal(fs.readFileSync(snapshotPath, 'utf8'), before, 'Interrupted writes preserve the last complete snapshot');
    assert.deepEqual(fs.readdirSync(root), ['drum-programs-v1.json'], 'Failed temporary writes are cleaned up');
  }
  assert.deepEqual(plain(launch().library.loadSavedDrumPrograms()), next);

  const afterDelete = next.filter(record => record.id !== records[3].id);
  afterUpdate.library.writeSavedDrumPrograms(afterDelete);
  assert.deepEqual(plain(launch().library.loadSavedDrumPrograms()), afterDelete, 'Explicit deletions also survive restart');
  afterUpdate.library.writeSavedDrumPrograms([]);
  afterUpdate.library.rememberRecentDrumProgram(raw, '');
  const emptied = launch();
  assert.deepEqual(plain(emptied.library.loadSavedDrumPrograms()), []);
  assert.equal(emptied.library.loadRecentDrumProgram().libraryId, '', 'Unnamed identity survives restart without inventing ownership');

  fail = 'read';
  const unreadable = launch(root, false);
  assert.throws(() => unreadable.library.initializeDrumProgramLibrary({ filesDir: root }), /read failure/);
  assert.throws(() => unreadable.library.writeSavedDrumPrograms(records), /尚未准备好/);
  fail = '';
  fs.writeFileSync(snapshotPath, '{interrupted');
  const corrupted = launch(root, false);
  assert.throws(() => corrupted.library.initializeDrumProgramLibrary({ filesDir: root }));
  assert.throws(() => corrupted.library.writeSavedDrumPrograms(records), /尚未准备好/);
  assert.equal(fs.readFileSync(snapshotPath, 'utf8'), '{interrupted', 'Unreadable records must not be silently replaced');

  const freshInstall = fs.mkdtempSync(path.join(root, 'fresh-install-'));
  assert.deepEqual(plain(launch(freshInstall).library.loadSavedDrumPrograms()), [],
    'A new installation with a new private directory starts with an empty library');
  const ability = ets('entryability/EntryAbility.ets');
  assert.ok(ability.slice(ability.indexOf('  onCreate('), ability.indexOf('  private async prepareLocalEntitlements'))
    .includes('initializeDrumProgramLibrary(this.context)'), 'Startup must restore before any page is displayed');
  console.log('PASS drum persistence: real atomic files, fresh-process restore, >8KB custom events/UTF-8, named/recent ownership, overwrite/delete, durable flush, partial writes, failure isolation and empty new installation');
} finally {
  fail = '';
  fs.rmSync(root, { recursive: true, force: true });
}
