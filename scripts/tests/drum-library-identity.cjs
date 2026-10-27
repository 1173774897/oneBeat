// Exercise editor lifecycle, persistence and named/unnamed ownership with the actual production library.
const assert = require('node:assert/strict');
const { harness, catalog, plain } = require('./drum-editor-preview.cjs');

function fixture() {
  const h = harness();
  const program = catalog.defaultDrumProgram();
  program.beatsPerBar = 3;
  program.sections[0].styleKey = 'jazz';
  program.styleKey = 'jazz';
  const saved = { id: 'named-a', name: '夜行律动', program: catalog.serializeDrumProgram(program) };
  h.library.writeSavedDrumPrograms([saved]);
  h.library.rememberRecentDrumProgram(saved.program, saved.id);
  h.setPersistenceTime(10000);
  return { ...h, saved };
}

function testRecentRestoresCompleteNamedDraft() {
  const h = fixture(), p = h.page;
  p.aboutToAppear();
  assert.equal(p.loadedProgramId, h.saved.id);
  assert.equal(p.arrangementTitleName(), h.saved.name);
  assert.equal(p.hasUnsavedProgramChanges(), false);
  assert.equal(p.beatsPerBar, 3, 'A recent arrangement retains its own meter until explicitly applied');
  const revision = p.savedProgramsRevision;
  p.updateRepeats(0, 1);
  p.openSaveDialog();
  assert.equal(p.saveDialogVisible, false, 'An owned draft updates its original record without renaming');
  assert.equal(p.savedPrograms.length, 1);
  assert.equal(p.savedPrograms[0].id, h.saved.id);
  assert.ok(p.savedProgramsRevision > revision, 'A same-ID update must invalidate cached card presentation');
  assert.equal(catalog.parseDrumProgram(p.savedPrograms[0].program).sections[0].repeats, 5);
  p.aboutToDisappear(); p.aboutToAppear();
  assert.equal(p.arrangementTitleName(), h.saved.name);
  assert.equal(p.sections[0].repeats, 5);
  assert.equal(p.hasUnsavedProgramChanges(), false);
}

async function testApplyReopenAndRetainedOwnership() {
  const h = fixture(), p = h.page, c = h.session.controller;
  p.aboutToAppear();
  await p.applyToTeam();
  assert.equal(c.drumProgramLibraryId, h.saved.id);
  p.aboutToDisappear(); p.aboutToAppear();
  assert.equal(p.arrangementTitleName(), h.saved.name, 'Lobby round trips retain the named origin');
  p.updateRepeats(0, 1);
  await p.applyToTeam();
  p.aboutToDisappear(); p.aboutToAppear();
  assert.equal(p.arrangementTitleName(), h.saved.name);
  assert.equal(p.hasUnsavedProgramChanges(), true,
    'Applying an edited named draft is independent of saving its library record');
  assert.equal(catalog.parseDrumProgram(h.library.loadSavedDrumPrograms()[0].program).sections[0].repeats, 4);
  p.openSaveDialog();
  assert.equal(p.savedPrograms.length, 1);
  assert.equal(p.savedPrograms[0].id, h.saved.id);
  assert.equal(catalog.parseDrumProgram(p.savedPrograms[0].program).sections[0].repeats, 5);
  assert.equal(p.hasUnsavedProgramChanges(), false);
}

async function testUnnamedNeverOverwritesAnEqualNamedRecord() {
  const h = fixture(), p = h.page, c = h.session.controller;
  h.library.rememberRecentDrumProgram(h.saved.program, '');
  p.aboutToAppear();
  assert.equal(p.arrangementTitleName(), '未命名');
  assert.equal(p.loadedProgramId, '');
  await p.applyToTeam();
  assert.equal(c.drumProgramLibraryId, '');
  p.aboutToDisappear(); p.aboutToAppear();
  assert.equal(p.arrangementTitleName(), '未命名');
  p.openSaveDialog();
  assert.equal(p.saveDialogVisible, true);
  p.saveName = h.saved.name; p.confirmNamedSave();
  assert.equal(p.overwriteDialogVisible, true, 'Equal content never bypasses same-name overwrite confirmation');
  p.persistNamedSave(true);
  assert.equal(c.drumProgramLibraryId, h.saved.id, 'Saving an identical applied unnamed draft may name it without applying again');
  assert.equal(h.teamProgramCalls.length, 1, 'Saving identity cannot submit an extra audio configuration');
  p.aboutToDisappear(); p.aboutToAppear();
  assert.equal(p.arrangementTitleName(), h.saved.name);
}

function testAppliedSourceWinsAndDeletedOwnerBecomesUnnamed() {
  const h = fixture(), p = h.page, c = h.session.controller;
  const other = catalog.defaultDrumProgram(); other.sections[0].repeats = 7;
  c.drumProgram = catalog.serializeDrumProgram(other);
  c.drumProgramLibraryId = '';
  p.aboutToAppear();
  assert.equal(p.sections[0].repeats, 7, 'The active team snapshot wins over a different recent cache');
  assert.equal(p.loadedProgramId, '');
  c.drumProgram = h.saved.program; c.drumProgramLibraryId = h.saved.id;
  p.aboutToAppear(); p.deleteSavedProgram(h.saved.id);
  const draft = plain(p.sections);
  assert.equal(p.arrangementTitleName(), '未命名');
  assert.deepEqual(plain(p.sections), draft, 'Deleting a library record preserves its editable content');
  p.aboutToDisappear(); p.aboutToAppear();
  assert.equal(p.loadedProgramId, '', 'A stale applied ID cannot recreate or overwrite a deleted record');
  p.openSaveDialog(); assert.equal(p.saveDialogVisible, true);
}

function testOwnedCacheFailureDoesNotUndoSave() {
  const h = fixture(), p = h.page;
  p.aboutToAppear(); p.updateRepeats(0, 1);
  const set = h.storage.set.bind(h.storage);
  h.storage.set = (key, value) => { if (key === 'recentDrumProgram') throw new Error('cache failed'); return set(key, value); };
  p.openSaveDialog();
  assert.equal(p.hasUnsavedProgramChanges(), false);
  assert.equal(catalog.parseDrumProgram(h.library.loadSavedDrumPrograms()[0].program).sections[0].repeats, 5);
  assert.equal(h.toasts.at(-1), '已更新我的编排');
}

function testCustomPatternSnapshotRemainsStable() {
  const h = fixture(), p = h.page, c = h.session.controller;
  const program = catalog.parseDrumProgram(h.saved.program);
  program.sections[0].customPattern = { subdivision: 4, events: [{ tick: 0, sampleKey: 'kick', velocity: 0.8 }] };
  program.sections[0].customFill = { subdivision: 3, events: [{ tick: 48, sampleKey: 'snare', velocity: 0.7 }] };
  program.sections[0].customRows = ['1000'];
  program.sections[0].customFillRows = ['0100'];
  const raw = catalog.serializeDrumProgram(catalog.parseDrumProgram(catalog.serializeDrumProgram(program)));
  h.library.writeSavedDrumPrograms([{ ...h.saved, program: raw }]);
  c.drumProgram = raw; c.rhythm = 3; c.beatsPerBar = 3; c.beatUnit = 4;
  p.aboutToAppear();
  assert.equal(catalog.serializeDrumProgram(p.currentProgram()), raw,
    'Custom events and row snapshots must serialize consistently across editor and controller');
  assert.equal(p.hasUnsavedProgramChanges(), false, 'Opening a custom named arrangement must not invent an edit');
  p.openSaveDialog();
  assert.equal(c.drumProgramLibraryId, h.saved.id, 'Saving identical custom content can update identity without applying audio');
  assert.equal(h.teamProgramCalls.length, 0);
  p.aboutToDisappear(); p.aboutToAppear();
  assert.equal(p.arrangementTitleName(), h.saved.name);
  assert.equal(p.hasUnsavedProgramChanges(), false);
}

async function main() {
  testRecentRestoresCompleteNamedDraft();
  await testApplyReopenAndRetainedOwnership();
  await testUnnamedNeverOverwritesAnEqualNamedRecord();
  testAppliedSourceWinsAndDeletedOwnerBecomesUnnamed();
  testOwnedCacheFailureDoesNotUndoSave();
  testCustomPatternSnapshotRemainsStable();
  console.log('PASS drum identity: recent restore, owned overwrite/card refresh, apply/lobby reopening, explicit unnamed duplicates, deleted origin, independent save/apply and cache failure isolation');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
