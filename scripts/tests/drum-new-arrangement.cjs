const assert = require('node:assert/strict');
const { harness, catalog, plain } = require('./drum-editor-preview.cjs');

function fixture() {
  const h = harness(), p = h.page;
  const program = { styleKey: 'jazz', beatsPerBar: 3, beatUnit: 4, sections: [
    { id: 'A', styleKey: 'jazz', patternIndex: 1, repeats: 4, fillIndex: 1, fillEvery: 4 },
    { id: 'B', styleKey: 'funk', patternIndex: 2, repeats: 8, fillIndex: 2, fillEvery: 2 }
  ] };
  const saved = { id: 'loaded', name: '夜行律动', program: catalog.serializeDrumProgram(program) };
  p.savedPrograms = [saved];
  h.storage.set('savedDrumPrograms', JSON.stringify([saved]));
  h.storage.set('myDrumProgram', saved.program);
  p.loadSavedProgram(saved);
  p.bpm = 148;
  h.session.controller.drumProgram = saved.program;
  h.setPersistenceTime(5000);
  return { ...h, original: plain(saved) };
}

function assertFresh(h) {
  const p = h.page;
  assert.equal(p.loadedProgramId, '');
  assert.equal(p.arrangementTitleName(), '未命名');
  assert.equal(p.sections.length, 1);
  assert.equal(p.sections[0].id, 'A');
  assert.equal(p.sections[0].repeats, 4);
  assert.equal(p.sections[0].customPattern, undefined);
  assert.deepEqual(plain(p.expandedSections), [true]);
  assert.equal(p.beatsPerBar, 3);
  assert.equal(p.beatUnit, 4);
  assert.equal(p.bpm, 148);
  assert.equal(p.newProgramDialogVisible, false);
  assert.equal(p.newProgramAfterSave, false);
  assert.equal(p.hasUnsavedProgramChanges(), false);
  assert.deepEqual(h.teamProgramCalls, []);
  assert.deepEqual(h.teamMeterCalls, []);
  assert.equal(h.session.controller.drumProgram, h.original.program,
    'New must not replace the applied team arrangement');
  assert.equal(h.session.controller.bpm, 120, 'New must not publish a tempo change');
  assert.equal(p.pageScroller.calls.at(-1).yOffset, 0);
}

function testCleanAndRevertedDrafts() {
  const h = fixture(), p = h.page;
  assert.equal(p.hasUnsavedProgramChanges(), false);
  p.updateRepeats(0, 1);
  assert.equal(p.hasUnsavedProgramChanges(), true);
  p.updateRepeats(0, -1);
  assert.equal(p.hasUnsavedProgramChanges(), false, 'Reverting an edit does not leave a sticky dirty flag');
  const before = plain(p.savedPrograms);
  p.requestNewProgram();
  assertFresh(h);
  assert.deepEqual(plain(p.savedPrograms), before);
  assert.deepEqual(h.storageWrites, [], 'An unchanged draft starts fresh without rewriting library/session storage');
  p.openSaveDialog();
  assert.equal(p.saveDialogVisible, true, 'The new draft must be named instead of overwriting the previously loaded record');
  assert.equal(p.saveName, '', 'The naming field starts empty and uses its placeholder');
}

async function testCancelPreservesContentAndPreview() {
  const h = fixture(), p = h.page;
  p.updateRepeats(0, 1);
  await p.togglePreview();
  const before = plain(p.sections), stops = h.stopCount();
  p.requestNewProgram();
  assert.equal(p.newProgramDialogVisible, true);
  assert.equal(p.previewTarget, 'song');
  assert.equal(p.onBackPress(), true);
  assert.equal(p.newProgramDialogVisible, false);
  assert.deepEqual(plain(p.sections), before);
  assert.equal(p.loadedProgramId, 'loaded');
  assert.equal(h.stopCount(), stops, 'Canceling a prompt must not interrupt the current audition');
  p.requestNewProgram();
  p.cancelNewProgram();
  assert.deepEqual(plain(p.sections), before);
  assert.equal(p.newProgramAfterSave, false);
  p.requestNewProgram();
  p.beginNewProgram();
  assertFresh(h);
  assert.equal(p.previewTarget, '');
  assert.ok(h.stopCount() > stops);
  assert.equal(p.savedPrograms[0].program, h.original.program, 'Discard only affects the local draft');
  assert.equal(h.storage.get('myDrumProgram'), h.original.program);
}

function testSaveLoadedThenNew() {
  const h = fixture(), p = h.page;
  p.updateRepeats(0, 1);
  p.requestNewProgram();
  p.saveBeforeNewProgram();
  assertFresh(h);
  assert.equal(p.saveDialogVisible, false);
  assert.equal(p.savedPrograms.length, 1);
  assert.equal(p.savedPrograms[0].id, h.original.id);
  assert.equal(p.savedPrograms[0].name, h.original.name);
  assert.equal(catalog.parseDrumProgram(p.savedPrograms[0].program).sections[0].repeats, 5);
  assert.deepEqual(h.toasts, ['已更新我的编排']);
}

function testUnnamedCancellationAndLaterOrdinarySave() {
  const h = fixture(), p = h.page;
  p.requestNewProgram();
  p.updateRepeats(0, 1);
  const draft = plain(p.sections);
  p.requestNewProgram();
  p.saveBeforeNewProgram();
  assert.equal(p.saveDialogVisible, true);
  assert.equal(p.newProgramAfterSave, true);
  p.saveName = '   ';
  p.confirmNamedSave();
  assert.equal(p.saveDialogVisible, true);
  assert.deepEqual(plain(p.sections), draft);
  assert.equal(p.onBackPress(), true);
  assert.equal(p.newProgramAfterSave, false);
  assert.deepEqual(plain(p.sections), draft);
  p.openSaveDialog();
  p.saveName = '新的律动';
  p.confirmNamedSave();
  assert.equal(p.arrangementTitleName(), '新的律动');
  assert.deepEqual(plain(p.sections), draft, 'Canceling naming must remove the deferred New from a later ordinary Save');
  assert.equal(p.hasUnsavedProgramChanges(), false);
  assert.equal(p.savedPrograms.length, 2);
}

function testUnnamedSaveAndDuplicateDecision() {
  const h = fixture(), p = h.page;
  p.requestNewProgram();
  p.updateRepeats(0, 1);
  p.requestNewProgram();
  p.saveBeforeNewProgram();
  p.saveName = h.original.name;
  p.confirmNamedSave();
  assert.equal(p.overwriteDialogVisible, true);
  assert.equal(p.newProgramAfterSave, true);
  assert.equal(p.savedPrograms[0].program, h.original.program);
  assert.equal(p.onBackPress(), true);
  assert.equal(p.saveDialogVisible, true);
  assert.equal(p.newProgramAfterSave, true, 'Returning to rename keeps the explicit save-and-new intent');
  p.saveName = '第二首';
  p.confirmNamedSave();
  assertFresh(h);
  assert.equal(p.savedPrograms.length, 2);
  assert.equal(p.savedPrograms[0].name, '第二首');
  assert.equal(catalog.parseDrumProgram(p.savedPrograms[0].program).sections[0].repeats, 5);
  assert.equal(p.savedPrograms[1].program, h.original.program);
}

function testPersistenceFailureKeepsDraft() {
  for (const unnamed of [false, true]) {
    const h = fixture(), p = h.page;
    if (unnamed) p.requestNewProgram();
    p.updateRepeats(0, 1);
    const draft = plain(p.sections), library = plain(p.savedPrograms);
    const set = h.storage.set.bind(h.storage);
    let fail = true;
    h.storage.set = (key, value) => {
      if (fail && key === 'savedDrumPrograms') throw new Error('Simulated storage failure');
      return set(key, value);
    };
    p.requestNewProgram();
    p.saveBeforeNewProgram();
    if (unnamed) { p.saveName = '待保存'; p.confirmNamedSave(); }
    assert.deepEqual(plain(p.sections), draft, 'A failed save may never reset the current arrangement');
    assert.deepEqual(plain(p.savedPrograms), library);
    assert.equal(p.hasUnsavedProgramChanges(), true);
    assert.deepEqual(h.failures, ['drum.save']);
    if (unnamed) {
      assert.equal(p.saveDialogVisible, true);
      assert.equal(p.newProgramAfterSave, true);
    } else {
      assert.equal(p.newProgramDialogVisible, true);
      assert.equal(p.loadedProgramId, 'loaded');
    }
    fail = false;
    if (unnamed) p.confirmNamedSave();
    else p.saveBeforeNewProgram();
    assertFresh(h);
  }
}

function testBusyAndDeletedRecord() {
  const h = fixture(), p = h.page;
  p.saving = true;
  p.requestNewProgram();
  assert.equal(p.loadedProgramId, 'loaded');
  assert.equal(p.newProgramDialogVisible, false);
  p.saving = false;
  p.deleteSavedProgram('loaded');
  p.requestNewProgram();
  assert.equal(p.newProgramDialogVisible, true, 'A deleted library record leaves an unsaved local draft');
}

async function main() {
  testCleanAndRevertedDrafts();
  await testCancelPreservesContentAndPreview();
  testSaveLoadedThenNew();
  testUnnamedCancellationAndLaterOrdinarySave();
  testUnnamedSaveAndDuplicateDecision();
  testPersistenceFailureKeepsDraft();
  testBusyAndDeletedRecord();
  console.log('PASS new arrangement: clean/reverted drafts, cancel and audition ownership, discard, loaded overwrite, unnamed naming/collision/cancellation, save failure/retry, preserved meter/tempo and unchanged applied team program');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
