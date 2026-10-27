// Execute actual page methods with native layout/resource boundaries supplied by the shared harness.
const assert = require('node:assert/strict');
const { harness, catalog, plain } = require('./drum-editor-preview.cjs');
const clean = (id, styleKey, extra = {}) => ({ id, styleKey, patternIndex: 1,
  repeats: 4, fillIndex: 1, fillEvery: 4, ...extra });
function setup() {
  const h = harness();
  h.page.sections = [clean('A', 'rock'), clean('B', 'jazz'), clean('C', 'funk')];
  h.page.expandedSections = [true, true, true];
  h.page.resetSectionPlaybackKeys();
  return h;
}

function testIndependentStylesAndDraftOwnership() {
  const { page: p } = setup();
  const original = plain(p.sections);
  p.chooseSectionStyle(1, 'trap');
  assert.equal(p.sections[0].styleKey, 'rock');
  assert.equal(p.sections[1].styleKey, 'trap');
  assert.equal(p.sections[1].patternIndex, 0);
  assert.equal(p.sections[1].fillIndex, 0);
  assert.deepEqual(plain(p.sections[0]), original[0]);
  assert.deepEqual(plain(p.sections[2]), original[2]);
  assert.deepEqual(plain(catalog.drumProgramStyleKeys(p.currentProgram())), ['rock', 'trap', 'funk']);
  const snapshot = p.currentProgram();
  snapshot.sections[0].styleKey = 'jazz';
  assert.equal(p.sections[0].styleKey, 'rock', 'Program snapshots cannot alias editable sections');

  const exact = { subdivision: 6, events: [
    { tick: 17.5, sampleKey: 'snare', velocity: 0.37 },
    { tick: 560, sampleKey: 'ride', velocity: 0.81 }
  ] };
  p.sections[1] = clean('B', 'jazz', { customPattern: plain(exact), customFill: plain(exact) });
  const before = plain(p.sections[1]);
  p.chooseSectionStyle(1, 'latin');
  assert.equal(p.pendingStyleKey, 'latin');
  assert.deepEqual(plain(p.sections[1]), before, 'A custom phrase cannot disappear while its style decision is pending');
  p.applySectionStyle(1, 'latin', true);
  assert.deepEqual(plain(p.sections[1].customPattern), exact);
  assert.deepEqual(plain(p.sections[1].customFill), exact);
  assert.equal(p.sections[1].styleKey, 'latin');
  const copy = p.currentProgram();
  copy.sections[1].customPattern.events[0].tick = 999;
  assert.equal(p.sections[1].customPattern.events[0].tick, 17.5);
  p.applySectionStyle(1, 'disco', false);
  assert.equal(p.sections[1].customPattern, undefined);
  assert.equal(p.sections[1].customFill, undefined);
  assert.deepEqual(plain(p.sections[0]), original[0]);
  assert.deepEqual(plain(p.sections[2]), original[2]);
}

async function testPreviewUsesTargetStyle() {
  for (const fill of [false, true]) {
    const h = setup();
    await h.page.previewSection(1, fill);
    assert.equal(catalog.drumSectionStyleKey(h.calls[0].program, h.calls[0].program.sections[0]), 'jazz');
    assert.equal(h.calls[0].program.sections[0].patternIndex, 1);
    assert.equal(h.calls[0].program.sections[0].fillEvery, fill ? 4 : 0);
  }
  for (const mode of [0, 1]) {
    const h = setup(), p = h.page;
    p.openEditor(1, mode);
    const draft = p.buildEditorPreviewProgram();
    assert.equal(catalog.drumSectionStyleKey(draft, draft.sections[0]), 'jazz');
    assert.match(p.editorPatternLabel(), /^爵士 · /);
    const expected = mode === 0 ? catalog.buildSectionPattern(p.currentProgram(), p.sections[1], false).events :
      p.buildFillEditorEvents(p.sections[1]);
    assert.deepEqual(plain(draft.sections[0].customPattern.events), plain(expected));
  }
  const h = setup();
  await h.page.togglePreview();
  assert.deepEqual(plain(catalog.drumProgramStyleKeys(h.calls[0].program)), ['rock', 'jazz', 'funk']);
}

async function testTempoDraftControls() {
  const h = setup(), p = h.page;
  h.session.controller.isLeader = false;
  let published = 0;
  h.session.controller.updateBpm = async () => { published++; };
  await p.setBpm(150);
  await p.changeBpm(-1);
  assert.equal(p.bpm, 149, 'A member can edit the local draft and use tempo steppers');
  assert.equal(published, 0, 'Local editing must not publish tempo as a member');
  p.chooseMeter(3, 4);
  assert.equal(p.beatsPerBar, 3);
  assert.equal(h.session.controller.beatsPerBar, 4, 'Draft meter edits cannot replace the team meter');
  await p.setBpm(999);
  assert.equal(p.bpm, 240);
  await p.changeBpm(1);
  assert.equal(p.bpm, 240);
  await p.setBpm(1);
  assert.equal(p.bpm, 40);
  h.setSessionAvailable(false);
  await p.setBpm(90);
  assert.equal(p.bpm, 90, 'A draft remains editable if its team session has ended');

  const leader = setup();
  const releases = [];
  const sent = [];
  leader.session.controller.updateBpm = async value => {
    sent.push(value);
    leader.session.controller.bpm = value;
    await new Promise(resolve => releases.push(resolve));
  };
  const first = leader.page.changeBpm(1);
  const second = leader.page.changeBpm(1);
  assert.deepEqual(sent, [121, 122], 'Rapid presses increment the visible draft rather than an older transport value');
  releases[1](); await second;
  releases[0](); await first;
  assert.equal(leader.page.bpm, 122, 'An older tempo completion cannot rewind the latest value');
}

async function testRetiringSectionControls() {
  const h = setup(), p = h.page;
  const oldKey = p.sectionRenderKey(2);
  p.deleteSection(1);
  assert.notEqual(p.sectionRenderKey(1), oldKey, 'A moved card must drop closures bound to its previous index');
  assert.equal(p.sectionDisplayId(2), '');
  assert.equal(p.sectionRepeats(2), 1);
  assert.equal(p.hasCustomPattern(undefined), false);
  assert.equal(p.hasCustomFill(undefined), false);
  const before = plain(p.sections);
  p.updateRepeats(2, 1);
  p.updatePattern(2, 1);
  p.updateFill(2, 1);
  p.selectFillEvery(2, 1);
  p.deleteSection(2);
  p.openEditor(2, 0);
  await p.previewSection(2, false);
  assert.deepEqual(plain(p.sections), before, 'Late controls from a removed card are harmless');
  assert.equal(h.calls.length, 0);
  p.updateRepeats(1, 1);
  assert.equal(p.sectionRepeats(1), 5);
  p.updateRepeats(1, -1);
  assert.equal(p.sectionRepeats(1), 4, 'Repeat display reads the same reactive section used by its buttons');
}

function testLoadedProgramSaveIdentity() {
  const h = setup(), p = h.page;
  const raw = catalog.serializeDrumProgram(p.currentProgram());
  p.savedPrograms = [{ id: 'other', name: '起步摇滚', program: raw }, { id: 'loaded', name: '夜行律动', program: raw }];
  p.loadSavedProgram(p.savedPrograms[1]);
  assert.equal(p.loadedProgramName(), '夜行律动');
  p.updateRepeats(0, 1);
  p.openSaveDialog();
  assert.equal(p.saveDialogVisible, false, 'Save directly updates the explicitly loaded arrangement');
  assert.equal(p.overwriteDialogVisible, false);
  assert.equal(p.savedPrograms.length, 2);
  assert.equal(p.savedPrograms[1].id, 'loaded');
  assert.equal(p.savedPrograms[1].name, '夜行律动');
  assert.equal(p.savedPrograms[0].program, raw, 'Saving one loaded record cannot overwrite a different arrangement');
  assert.equal(catalog.parseDrumProgram(p.savedPrograms[1].program).sections[0].repeats, 5);
  assert.deepEqual(h.toasts, ['已更新我的编排']);
  p.deleteSavedProgram('loaded');
  assert.equal(p.loadedProgramName(), '');
  p.openSaveDialog();
  assert.equal(p.saveDialogVisible, true, 'Deleting the loaded library record returns its retained draft to the naming flow');
}

function testPersistenceAndMeterContextIdentity() {
  const h = setup(), p = h.page;
  h.setPersistenceTime(123456);
  p.saveName = '混合律动';
  p.persistNamedSave(false);
  assert.deepEqual(plain(catalog.drumProgramStyleKeys(catalog.parseDrumProgram(p.savedPrograms[0].program))),
    ['rock', 'jazz', 'funk']);
  assert.equal(p.savedProgramStyle(p.savedPrograms[0]), '摇滚 · 爵士 · …');
  p.chooseMeter(3, 4);
  p.deleteSection(0);
  p.chooseMeter(4, 4);
  assert.deepEqual(plain(p.sections.map(section => section.styleKey)), ['jazz', 'funk'],
    'Meter caches must follow surviving section identities after deleting and renumbering A');
}

function testLongFrequencyFillPreview() {
  const { page: p } = setup();
  p.sections[1].repeats = 4;
  p.sections[1].fillEvery = 16;
  const before = plain(p.sections[1]);
  const preview = p.buildSectionPreviewProgram(p.sections[1], true);
  const sequence = catalog.buildProgramSequence(preview);
  const fill = catalog.buildSectionPattern(preview, preview.sections[0], true);
  assert.ok(sequence.some(bar => JSON.stringify(bar.events) === JSON.stringify(fill.events)),
    'The fill play icon must actually audition a fill even when its frequency exceeds the section length');
  assert.deepEqual(plain(p.sections[1]), before, 'An extended audition cannot alter the saved section repeat count');
}

function testNativeCoordinatesAndScrollGestures() {
  const { page: p } = setup();
  const density = 3.5;
  const rectangles = {
    'dm-scroll-content': { windowOffset: { x: 0, y: -200 * density }, size: { width: 390 * density, height: 1400 * density } },
    'dm-page-scroll': { windowOffset: { x: 0, y: 0 }, size: { width: 390 * density, height: 760 * density } },
    'dm-style-0': { windowOffset: { x: 240 * density, y: 220 * density }, size: { width: 100 * density, height: 34 * density } },
    'dm-open-dropdown': { windowOffset: { x: 20 * density, y: 256 * density }, size: { width: 320 * density, height: 182 * density } },
    'dm-pattern-0': { windowOffset: { x: 74 * density, y: 260 * density }, size: { width: 212 * density, height: 30 * density } }
  };
  p.getUIContext = () => ({ px2vp: value => value / density,
    getComponentUtils: () => ({ getRectangleById: id => rectangles[id] }) });
  p.openDropdownFromAnchor('menu-style-0', 'dm-style-0');
  assert.equal(p.dropdownTarget, 'menu-style-0');
  assert.equal(p.dropdownAbove, false);
  assert.equal(p.dropdownAnchorY, 456, 'The anchor offset is relative to content in vp, independent of scroll and density');
  assert.equal(p.dropdownAnchorX + p.dropdownMenuWidth, 340, 'The palette grows left while preserving its trigger right edge');
  assert.equal(p.styleDropdownColumns(), 3);
  assert.ok(p.dropdownAnchorX >= 16 && p.dropdownAnchorX + p.dropdownMenuWidth <= 374);
  assert.equal(p.pointInsideComponent('dm-style-0', 250, 230), true,
    'TouchObject window coordinates are already vp; native rectangle coordinates need one conversion');
  const touch = (type, windowX, windowY) => p.observePageTouch({ type, changedTouches: [{ windowX, windowY }] });
  touch(0, 150, 300); touch(1, 150, 300);
  assert.equal(p.dropdownTarget, 'menu-style-0', 'Tapping inside the bubble is not an outside dismiss');
  touch(0, 10, 700); touch(2, 10, 660); touch(1, 10, 660);
  assert.equal(p.dropdownTarget, 'menu-style-0', 'A vertical swipe keeps the bubble open while the parent scrolls');
  touch(0, 10, 700); touch(1, 10, 700);
  assert.equal(p.dropdownTarget, '', 'A stationary outside tap dismisses the bubble');

  rectangles['dm-page-scroll'].windowOffset.y = 130 * density;
  rectangles['dm-page-scroll'].size.height = 300 * density;
  rectangles['dm-style-0'].windowOffset.y = 260 * density;
  p.openDropdownFromAnchor('menu-style-0', 'dm-style-0');
  assert.equal(p.dropdownAbove, false, 'A flipped bubble must fit below the pinned page navigation');
  p.closeDropdown();
  rectangles['dm-style-0'].windowOffset.y = 340 * density;
  p.openDropdownFromAnchor('menu-style-0', 'dm-style-0');
  assert.equal(p.dropdownAbove, true, 'An above-anchor bubble still opens when the scroll viewport has room');
  p.closeDropdown();
  p.bottomSafeInset = 30;
  rectangles['dm-page-scroll'].size.height = 870 * density;
  rectangles['dm-style-0'].windowOffset.y = 770 * density;
  p.openDropdownFromAnchor('menu-style-0', 'dm-style-0');
  assert.equal(p.dropdownAbove, false, 'The footer safe area must not be deducted twice from the measured scroll viewport');
  p.openDropdownFromAnchor('menu-pattern-0', 'dm-pattern-0');
  assert.equal(p.dropdownMenuWidth, 212, 'A phrase list must follow the actual field width rather than a fixed modal width');
  assert.equal(p.dropdownAnchorX, 74, 'The phrase list starts at its field left edge');
  p.closeDropdown();
  rectangles['dm-pattern-0'].size.width = 140 * density;
  p.openDropdownFromAnchor('menu-pattern-0', 'dm-pattern-0');
  assert.equal(p.dropdownMenuWidth, 180, 'Narrow fields retain enough space for readable list options');
  p.closeDropdown();
  rectangles['dm-scroll-content'].size.width = 300 * density;
  rectangles['dm-style-0'].windowOffset.x = 210 * density;
  rectangles['dm-style-0'].size.width = 66 * density;
  p.openDropdownFromAnchor('menu-style-0', 'dm-style-0');
  assert.equal(p.styleDropdownColumns(), 2, 'A narrow viewport falls back to two columns so long style labels still fit');
  assert.equal(p.styleDropdownRows().length * p.styleDropdownColumns(), catalog.DRUM_STYLES.length,
    'Responsive style columns cannot drop any available styles');
  assert.ok(p.dropdownAnchorX >= 16 && p.dropdownAnchorX + p.dropdownMenuWidth + 3 <= 284,
    'The popup and its hard backing stay within the page gutters');
}

async function main() {
  testIndependentStylesAndDraftOwnership();
  await testPreviewUsesTargetStyle();
  await testTempoDraftControls();
  await testRetiringSectionControls();
  testLoadedProgramSaveIdentity();
  testPersistenceAndMeterContextIdentity();
  testLongFrequencyFillPreview();
  testNativeCoordinatesAndScrollGestures();
  console.log('PASS multi-style page: section isolation/custom decisions/deep copies, section+grid+song previews, editable member drafts and leader tempo races, retired section controls, loaded-record save identity, library style summary, meter-cache identities, audible long-frequency fills, density-correct anchored popover and scrolling touch behavior');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
