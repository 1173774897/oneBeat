// Run with Node and a typescript/lib/typescript.js path, matching the sync regressions.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');
const ets = name => fs.readFileSync(path.join(root, 'entry/src/main/ets', name), 'utf8');

function load(source, mocks = {}, globals = {}) {
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.deepEqual((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error), [],
    'The actual business methods must transpile');
  const context = {
    exports: {},
    require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency: ${name}`);
      return mocks[name];
    },
    ...globals
  };
  vm.runInNewContext(compiled.outputText, context);
  return context.exports;
}

const meter = load(ets('common/MeterModel.ets'));
const timeline = load(ets('audio/RhythmTimeline.ets'), { '../common/MeterModel': meter });
const jazz = load(ets('audio/JazzDrumPatterns.ets'), { './RhythmTimeline': timeline });
const styles = load(ets('audio/StyleDrumPatterns.ets'), { './RhythmTimeline': timeline });
const catalog = load(ets('audio/DrumMachineCatalog.ets'), {
  './StyleDrumPatterns': styles,
  './JazzDrumPatterns': jazz,
  './RhythmTimeline': timeline,
  '../common/MeterModel': meter
});
const source = ets('pages/DrumMachinePage.ets');
function numericConstant(name) {
  const match = source.match(new RegExp(`const ${name}: number = ([\\d.]+);`));
  assert.ok(match, `Expected layout constant ${name}`);
  return Number(match[1]);
}
const CELL_WIDTH = numericConstant('DRUM_EDITOR_CELL_WIDTH');
const PLAYHEAD_WIDTH = numericConstant('DRUM_EDITOR_PLAYHEAD_WIDTH');
const builderStart = source.indexOf('  @Builder');
assert.ok(builderStart > 0, 'Page business methods must precede ArkUI builders');
// Execute the production audition, draft and scroll logic rather than a model of it.
const businessSource = source.slice(0, builderStart)
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct DrumMachinePage', 'export class DrumMachinePage') + '\n}\n';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function plain(value) { return JSON.parse(JSON.stringify(value)); }

function harness() {
  const calls = [];
  const audioActions = [];
  const toasts = [];
  const failures = [];
  const storageWrites = [];
  const teamMeterCalls = [];
  const teamProgramCalls = [];
  const teamMeterResponses = [];
  const teamProgramResponses = [];
  const timers = new Map();
  const archivedTimers = new Map();
  const responses = [];
  const updateCalls = [];
  const updateResponses = [];
  let nextTimer = 1;
  let stopCount = 0;
  let sessionAvailable = true;
  let previewActive = false;
  let previewReady = false;
  let previewRequest = 0;
  let updateRevision = 0;
  let invalidations = 0;
  let appliedPlan;
  let positionOverride;
  let usePositionOverride = false;
  let snapshotProvider;
  let virtualTime = 0;
  let persistenceTime;
  let backCount = 0;
  let sessionOverride;
  const readSnapshot = () => snapshotProvider === undefined ? snapshot : snapshotProvider(virtualTime);
  let snapshot = { running: true, countIn: false, mainPlayheadMs: -350 };
  const session = {
    controller: {
      isLeader: true,
      bpm: 120,
      beatsPerBar: 4,
      beatUnit: 4,
      drumProgram: '',
      getProDrumEditorSettings() { return undefined; },
      rememberProDrumEditorSettings() {},
      async updateMeter(beats, unit) {
        teamMeterCalls.push([beats, unit]);
        const response = teamMeterResponses.shift();
        if (response !== undefined) await response.promise;
      },
      async updateDrumProgram(raw) {
        teamProgramCalls.push(raw);
        const response = teamProgramResponses.shift();
        if (response !== undefined) await response.promise;
      }
    },
    async previewDrumProgram(raw, looping, bpm, beats, positionBeats = 0, sectionKeys) {
      const request = ++previewRequest;
      previewActive = true;
      previewReady = false;
      const call = { program: JSON.parse(raw), looping, bpm, beats, positionBeats,
        sectionKeys: sectionKeys === undefined ? undefined : [...sectionKeys] };
      calls.push(call);
      audioActions.push('play');
      snapshot = { running: true, countIn: false, mainPlayheadMs: -350 };
      const response = responses.shift();
      if (response !== undefined) await response.promise;
      if (request === previewRequest && previewActive) {
        previewReady = true;
        appliedPlan = call;
      }
    },
    stopDrumPreview() {
      previewActive = false;
      previewReady = false;
      previewRequest++;
      updateRevision++;
      stopCount++;
      audioActions.push('stop');
      snapshot = { running: false, countIn: false, mainPlayheadMs: -1 };
    },
    metronome: { getVisualSnapshot: readSnapshot, getDrumPreviewPosition: () => session.getDrumPreviewPosition() },
    isDrumPreviewActive: () => previewActive,
    isDrumPreviewReady: () => previewActive && previewReady,
    getDrumPreviewRequestRevision: () => previewRequest,
    invalidateDrumPreviewUpdate() { invalidations++; updateRevision++; },
    async updateDrumPreviewProgram(raw, sectionKeys) {
      const revision = ++updateRevision;
      updateCalls.push({ program: JSON.parse(raw), sectionKeys: [...sectionKeys], revision });
      const response = updateResponses.shift();
      const prepared = response === undefined ? true : await response.promise;
      return prepared !== false && previewActive && previewReady && revision === updateRevision;
    },
    getDrumPreviewPosition() {
      const snapshot = readSnapshot();
      if (!previewActive || !previewReady) return undefined;
      if (usePositionOverride) return typeof positionOverride === 'function' ? positionOverride(virtualTime) : positionOverride;
      if (appliedPlan?.sectionKeys === undefined || !snapshot.running || snapshot.countIn ||
        !Number.isFinite(snapshot.mainPlayheadMs) || snapshot.mainPlayheadMs < 0) return undefined;
      const barMs = appliedPlan.beats * 60000 / appliedPlan.bpm;
      const total = appliedPlan.program.sections.reduce((sum, section) => sum + section.repeats, 0);
      let bar = Math.floor(snapshot.mainPlayheadMs / barMs) % total;
      for (let i = 0; i < appliedPlan.program.sections.length; i++) {
        if (bar < appliedPlan.program.sections[i].repeats) {
          const section = appliedPlan.program.sections[i];
          const barPositionMs = snapshot.mainPlayheadMs % barMs;
          const useFill = section.fillEvery > 0 && (bar + 1) % section.fillEvery === 0;
          const fillStartMs = useFill ? catalog.sectionFillStartBeat(appliedPlan.program, section) *
            60000 / appliedPlan.bpm : barMs;
          const isFill = useFill && barPositionMs >= fillStartMs;
          return { sectionKey: appliedPlan.sectionKeys[i], repeatIndex: bar,
            isFill, nextBoundaryDelayMs: (useFill && !isFill ? fillStartMs : barMs) - barPositionMs };
        }
        bar -= appliedPlan.program.sections[i].repeats;
      }
      return undefined;
    }
  };
  function addTimer(callback, delay, interval) {
    const id = nextTimer++;
    const timer = { callback, delay, interval, dueAt: virtualTime + delay };
    timers.set(id, timer);
    archivedTimers.set(id, timer);
    return id;
  }
  const { DrumMachinePage } = load(businessSource, {
    '@kit.ArkUI': {
      promptAction: { showToast: ({ message }) => toasts.push(message) },
      router: { back() { backCount++; } }
    },
    '../app/AppSession': { AppSession: { get: () => sessionAvailable ? sessionOverride ?? session : undefined } },
    '../components/ComicKit': {},
    '../store/EntitlementStore': { isProDrumMachineAccessible: () => true },
    '../common/MeterModel': meter,
    '../common/UserFeedback': {
      showUserNotice: message => toasts.push(message),
      logUserFailure: scope => failures.push(scope),
      userErrorMessage: (_error, fallback) => fallback
    },
    '../audio/DrumMachineCatalog': catalog,
    '../audio/RhythmTimeline': timeline
  }, {
    Date: { now() {
      if (persistenceTime === undefined) throw new Error('Audition progress must use the transport snapshot, never Date.now()');
      return persistenceTime;
    } },
    AppStorage: { setOrCreate: (...args) => storageWrites.push(plain(args)), get() { return ''; } },
    Scroller: class {
      offset = 0;
      calls = [];
      currentOffset() { return { xOffset: this.offset, yOffset: 0 }; }
      scrollTo(options) {
        this.calls.push(plain(options));
        this.offset = options.xOffset;
      }
    },
    setInterval: (callback, delay) => addTimer(callback, delay, true),
    clearInterval: id => timers.delete(id),
    setTimeout: (callback, delay) => addTimer(callback, delay, false),
    clearTimeout: id => timers.delete(id)
  });
  const page = new DrumMachinePage();
  page.sections = [{
    id: 'B', patternIndex: 2, repeats: 8, fillIndex: 2, fillEvery: 4,
    customRows: Array.from({ length: catalog.DRUM_TRACKS.length }, (_, i) => i === 0 ? '1000000010000000' : '0000000000000000'),
    customFillRows: Array.from({ length: catalog.DRUM_TRACKS.length }, (_, i) => i === 1 ? '0000000000001111' : '0000000000000000')
  }];
  return {
    page, session, calls, audioActions, responses, updateCalls, updateResponses, toasts, failures, timers, archivedTimers, storageWrites,
    teamMeterCalls, teamProgramCalls, teamMeterResponses, teamProgramResponses,
    backCount: () => backCount,
    replaceSession: () => { sessionOverride = { ...session, controller: { ...session.controller } }; },
    setPersistenceTime: value => { persistenceTime = value; },
    stopCount: () => stopCount,
    getSnapshot: () => plain(readSnapshot()),
    setSessionAvailable: value => { sessionAvailable = value; },
    setPreviewActive: value => {
      previewActive = value;
      if (!value) { previewRequest++; updateRevision++; previewReady = false; }
    },
    setPreviewReady: value => { previewReady = value; },
    setPreviewPosition: value => { usePositionOverride = true; positionOverride = value; },
    setSnapshotProvider: provider => { snapshotProvider = provider; },
    advanceTime(ms) {
      const target = virtualTime + ms;
      let remaining = 10000;
      while (remaining-- > 0) {
        const next = [...timers].filter(([, timer]) => timer.dueAt <= target)
          .sort((a, b) => a[1].dueAt - b[1].dueAt)[0];
        if (next === undefined) break;
        const [id, timer] = next;
        virtualTime = timer.dueAt;
        if (timer.interval) timer.dueAt += timer.delay;
        else timers.delete(id);
        timer.callback();
      }
      assert.ok(remaining > 0, 'Virtual timer scheduling must settle without a zero-delay loop');
      virtualTime = target;
    },
    applyPreviewUpdate(index = updateCalls.length - 1) {
      const call = updateCalls[index];
      appliedPlan = { ...appliedPlan, ...call };
    },
    invalidations: () => invalidations,
    runTimeouts(delay) {
      for (const [id, timer] of [...timers]) {
        if (!timer.interval && (delay === undefined || timer.delay === delay)) {
          timers.delete(id);
          timer.callback();
        }
      }
    },
    setSnapshot: nextSnapshot => {
      snapshot = { running: true, countIn: false, mainPlayheadMs: 0, ...nextSnapshot };
    },
    tick(nextSnapshot) {
      snapshot = { running: true, countIn: false, mainPlayheadMs: 0, ...nextSnapshot };
      for (const [id, timer] of [...timers]) {
        if (timers.has(id)) {
          if (!timer.interval) timers.delete(id);
          timer.callback();
        }
      }
    }
  };
}

async function settle() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

function sectionFixture(index) {
  return { id: String.fromCharCode(65 + index), patternIndex: index % 3,
    repeats: index + 1, fillIndex: (index + 1) % 3, fillEvery: 4 };
}

function expansion(page) {
  return Array.from(page.sections, (_section, index) => page.isSectionExpanded(index));
}

async function testIndependentSectionExpansion() {
  for (const mode of [0, 1]) {
    const h = harness();
    const p = h.page;
    p.sections = Array.from({ length: 3 }, (_value, index) => sectionFixture(index));
    assert.deepEqual(expansion(p), [true, false, false], 'Only the first card starts expanded');
    p.toggleSectionExpanded(1);
    assert.deepEqual(expansion(p), [true, true, false], 'Expanding B cannot collapse A');
    const originalA = plain(p.sections[0]);
    p.openEditor(1, mode);
    assert.equal(p.selectedSection, 1);
    assert.deepEqual(expansion(p), [true, true, false], 'Selecting B for either editor cannot fold A');
    p.toggleStep(3, 5);
    p.chooseEditorSubdivision(6);
    p.seekEditorStep(7);
    p.closeEditor();
    assert.deepEqual(expansion(p), [true, true, false], 'Discarding B edits cannot change any card expansion');
    p.openEditor(1, mode);
    p.toggleStep(8, 3);
    const savedDraft = plain(p.editorEvents);
    p.saveEditor();
    assert.deepEqual(expansion(p), [true, true, false], 'Applying B edits must leave A and B expanded');
    assert.deepEqual(plain(p.sections[1][mode === 0 ? 'customPattern' : 'customFill'].events), savedDraft);
    assert.deepEqual(plain(p.sections[0]), originalA, 'Editing B must preserve A content as well as its visible card');
    p.updateRepeats(1, 1);
    p.updatePattern(1, 2);
    p.updateFill(1, 0);
    p.selectFillEvery(1, 1);
    assert.deepEqual(expansion(p), [true, true, false], 'Changing B controls cannot collapse another card');
    p.openEditor(0, mode);
    p.closeEditor();
    assert.deepEqual(expansion(p), [true, true, false], 'The modal selection must remain independent of card expansion');
    p.toggleSectionExpanded(0);
    assert.deepEqual(expansion(p), [false, true, false], 'The manual A arrow must collapse only A');
    p.openEditor(1, mode);
    assert.equal(p.onBackPress(), true);
    assert.deepEqual(expansion(p), [false, true, false], 'Editing B must also preserve a manually collapsed A');
    p.toggleSectionExpanded(0);
    p.toggleSectionExpanded(1);
    assert.deepEqual(expansion(p), [true, false, false], 'Both arrows must toggle independently in either direction');
    const beforeInvalid = expansion(p);
    p.toggleSectionExpanded(-1);
    p.toggleSectionExpanded(p.sections.length);
    assert.deepEqual(expansion(p), beforeInvalid, 'Out-of-range card actions cannot modify expansion');
  }
}

async function testSectionExpansionStructure() {
  const h = harness();
  const p = h.page;
  p.sections = Array.from({ length: 4 }, (_value, index) => sectionFixture(index));
  p.expandedSections = [false, true, false, true];
  p.selectedSection = 3;
  p.deleteSection(1);
  assert.deepEqual(plain(p.sections).map(section => section.repeats), [1, 3, 4]);
  assert.deepEqual(plain(p.sections).map(section => section.id), ['A', 'B', 'C']);
  assert.deepEqual(expansion(p), [false, false, true],
    'Deleting B must keep each surviving card state even when C/D are renamed B/C');
  p.deleteSection(0);
  assert.deepEqual(expansion(p), [false, true], 'Deleting the first card cannot automatically expand the renamed first survivor');
  p.addSection();
  assert.deepEqual(expansion(p), [false, true, true], 'A newly added card opens without closing existing cards');
  p.addSection();
  assert.deepEqual(expansion(p), [false, true, true, true], 'Adding again must retain all previous expansion choices');
  while (p.sections.length < 8) p.addSection();
  const atLimit = expansion(p);
  p.addSection();
  assert.deepEqual(expansion(p), atLimit, 'The maximum-section guard cannot append an orphan expansion flag');
  assert.equal(p.expandedSections.length, p.sections.length);
  while (p.sections.length > 1) p.deleteSection(0);
  const last = expansion(p);
  p.deleteSection(0);
  assert.deepEqual(expansion(p), last, 'The final-section guard must retain its expansion state');
  assert.equal(p.expandedSections.length, 1);

  h.setSessionAvailable(false);
  const imported = Array.from({ length: 4 }, (_value, index) => sectionFixture(index));
  p.loadSavedProgram({ id: 'saved', name: 'Expansion test', program: catalog.serializeDrumProgram({
    styleKey: 'rock', beatsPerBar: 4, beatUnit: 4, sections: imported
  }) });
  assert.deepEqual(expansion(p), [true, false, false, false], 'Loading a different arrangement must initialize its own card states');
  p.expandedSections = [false, true, true, true];
  p.aboutToAppear();
  assert.deepEqual(expansion(p), Array.from(p.sections, (_section, index) => index === 0),
    'Initial page loading must initialize expansion for the loaded arrangement');
}

async function testSectionCollapsePreservesPlayback() {
  for (const target of ['song', 'pattern', 'fill']) {
    const h = harness();
    const p = h.page;
    p.sections = [sectionFixture(0), sectionFixture(1)];
    p.expandedSections = [true, true];
    if (target === 'song') await p.togglePreview();
    else await p.previewSection(0, target === 'fill');
    const previewTarget = p.previewTarget;
    const revision = p.sectionPreviewRevision;
    const timerIds = [...h.timers.keys()];
    const snapshot = h.getSnapshot();
    p.openDropdownFromAnchor('menu-pattern-0', 'dm-pattern-0', 126);
    p.toggleSectionExpanded(1);
    assert.equal(p.dropdownTarget, 'menu-pattern-0', 'Collapsing B cannot close A’s anchored menu');
    assert.deepEqual(expansion(p), [true, false]);
    p.toggleSectionExpanded(0);
    assert.equal(p.dropdownTarget, '', 'Collapsing A must dismiss the menu whose anchor it hides');
    assert.equal(p.dropdownKind, '');
    assert.deepEqual(expansion(p), [false, false]);
    p.toggleSectionExpanded(0);
    await settle();
    assert.deepEqual(expansion(p), [true, false]);
    assert.equal(p.dropdownTarget, '', 'Expanding a card cannot resurrect an old menu');
    assert.equal(p.previewTarget, previewTarget, 'Manual folding cannot change the current playback target');
    assert.equal(h.calls.length, 1, 'Manual folding must not restart playback');
    assert.equal(h.stopCount(), 0, 'Manual folding must not stop playback');
    assert.equal(p.sectionPreviewRevision, revision, 'Manual folding cannot invalidate in-flight playback ownership');
    assert.deepEqual([...h.timers.keys()], timerIds, 'Manual folding must preserve standalone audition stop timers');
    assert.deepEqual(h.getSnapshot(), snapshot);
    p.aboutToDisappear();
  }
}

function songProgressFixture(h) {
  const p = h.page;
  p.sections = [1, 3, 2].map((repeats, index) => ({ ...sectionFixture(index), repeats }));
  p.expandedSections = [true, true, false];
  p.bpm = 120;
  p.beatsPerBar = 4;
  p.beatUnit = 4;
  return p;
}

async function testSongSectionProgress() {
  const h = harness();
  const p = songProgressFixture(h);
  await p.togglePreview();
  assert.equal(p.playingSongSection, -1, 'Preroll must not identify a section as already audible');
  assert.equal(h.timers.size, 1);
  assert.equal(p.editorPreviewTimerId, -1);
  assert.ok(h.timers.has(p.songPreviewProgressTimerId));
  const frames = [[0, 0], [1999.99, 0], [2000, 1], [7999.99, 1],
    [8000, 2], [11999.99, 2], [12000, 0], [14000, 1], [24000, 0]];
  for (const [mainPlayheadMs, expected] of frames) {
    h.tick({ mainPlayheadMs });
    assert.equal(p.playingSongSection, expected, `Unequal section repeats must select the audible card at ${mainPlayheadMs} ms`);
  }
  for (const snapshot of [
    { mainPlayheadMs: -350 }, { mainPlayheadMs: NaN }, { mainPlayheadMs: Infinity },
    { mainPlayheadMs: -Infinity }, { mainPlayheadMs: 5000, running: false },
    { mainPlayheadMs: 5000, countIn: true }
  ]) {
    h.tick(snapshot);
    assert.equal(p.playingSongSection, -1, 'Invalid, inaudible or count-in transport snapshots cannot highlight a card');
  }
  h.tick({ mainPlayheadMs: 2000 });
  assert.equal(p.playingSongSection, 1);
  const flags = expansion(p);
  const timer = p.songPreviewProgressTimerId;
  const observerRevision = p.songPreviewProgressRevision;
  p.openEditor(0, 1);
  h.tick({ mainPlayheadMs: 8000 });
  assert.equal(p.playingSongSection, 2, 'Background song progress must continue while a different section editor is open');
  assert.equal(p.selectedSection, 0);
  assert.deepEqual(expansion(p), flags, 'Following the audible section must not expand or fold any card');
  p.closeEditor();
  p.toggleSectionExpanded(0);
  h.tick({ mainPlayheadMs: 14000 });
  assert.equal(p.playingSongSection, 1);
  assert.deepEqual(expansion(p), [false, true, false]);
  assert.equal(p.songPreviewProgressRevision, observerRevision,
    'Editor navigation and manual folding must retain the same visual observer lifetime');
  assert.ok(h.timers.has(p.songPreviewProgressTimerId));
  assert.equal(h.calls.length, 1, 'Section progress must never schedule or restart audio');
  assert.equal(h.stopCount(), 0);

  p.sections[0].repeats = 16;
  p.bpm = 60;
  p.beatsPerBar = 7;
  h.tick({ mainPlayheadMs: 2000 });
  assert.equal(p.playingSongSection, 1, 'Highlight boundaries must use the submitted program snapshot, not mutable editor controls');
  await p.togglePreview();
  assert.equal(p.playingSongSection, -1);
  assert.equal(h.timers.size, 0);
  h.setSnapshot({ mainPlayheadMs: 8000 });
  h.archivedTimers.get(timer).callback();
  p.updateSongPreviewProgress();
  assert.equal(p.playingSongSection, -1, 'Queued or direct updates cannot restore a stopped song highlight');

  const compound = harness();
  const q = songProgressFixture(compound);
  q.beatsPerBar = 3;
  q.beatUnit = 8;
  await q.togglePreview();
  compound.tick({ mainPlayheadMs: 1499.99 });
  assert.equal(q.playingSongSection, 0);
  compound.tick({ mainPlayheadMs: 1500 });
  assert.equal(q.playingSongSection, 1, 'An eighth-note denominator must retain the actual transport beat duration');
  q.aboutToDisappear();
  assert.equal(q.playingSongSection, -1);
  assert.equal(compound.timers.size, 0);
}

async function testSongPhraseProgress() {
  const h = harness();
  const p = songProgressFixture(h);
  p.sections = [
    { id: 'A', patternIndex: 0, repeats: 2, fillIndex: 0, fillEvery: 2 },
    { id: 'B', patternIndex: 0, repeats: 1, fillIndex: 0, fillEvery: 1,
      customFill: { subdivision: 3, events: [{ tick: 0, sampleKey: 'snare', velocity: 0.7 }] } }
  ];
  await p.togglePreview();
  assert.equal(p.isSongPhrasePlaying(0, false), false, 'Preroll has no active dropdown');
  for (const [time, section, fill] of [[0, 0, false], [1999.99, 0, false], [2000, 0, false],
    [3499.99, 0, false], [3500, 0, true], [3999.99, 0, true],
    [4000, 1, true], [5999.99, 1, true], [6000, 0, false]]) {
    h.tick({ mainPlayheadMs: time });
    assert.equal(p.playingSongSection, section);
    for (let index = 0; index < p.sections.length; index++) {
      assert.equal(p.isSongPhrasePlaying(index, false), index === section && !fill,
        `${time} ms: only the audible main phrase may highlight its dropdown`);
      assert.equal(p.isSongPhrasePlaying(index, true), index === section && fill,
        `${time} ms: preset fill starts on the final beat, custom fill owns the whole bar`);
    }
  }
  p.sections[0].fillEvery = 0;
  p.sections[0].fillIndex = 2;
  h.tick({ mainPlayheadMs: 3499 });
  assert.equal(p.isSongPhrasePlaying(0, false), true);
  h.tick({ mainPlayheadMs: 3500 });
  assert.equal(p.isSongPhrasePlaying(0, true), true,
    'Unapplied frequency/fill edits cannot change the highlight for already queued audio');
  p.openEditor(1, 0);
  h.tick({ mainPlayheadMs: 3800 });
  assert.equal(p.isSongPhrasePlaying(0, true), true, 'Background song highlighting survives draft navigation');
  p.closeEditor();
  assert.equal(h.calls.length, 1, 'Dropdown highlighting cannot schedule or restart sound');
  for (const invalid of [{ running: false }, { countIn: true }, { mainPlayheadMs: -350 }]) {
    h.tick({ mainPlayheadMs: 3500, ...invalid });
    assert.equal(p.isSongPhrasePlaying(0, false), false);
    assert.equal(p.isSongPhrasePlaying(0, true), false);
  }
  h.tick({ mainPlayheadMs: 3500 });
  const queuedPaint = h.archivedTimers.get(p.songPreviewProgressTimerId);
  await p.togglePreview();
  queuedPaint.callback();
  assert.equal(p.playingSongIsFill, false);
  assert.equal(p.isSongPhrasePlaying(0, false), false);
  assert.equal(p.isSongPhrasePlaying(0, true), false, 'Stop clears both dropdown highlights permanently');
  p.previewTarget = 'fill-0';
  p.playingSongSection = 0;
  p.playingSongIsFill = true;
  assert.equal(p.isSongPhrasePlaying(0, true), false, 'Standalone audition must not borrow whole-song highlight state');
}

async function testSongSectionProgressRaces() {
  for (const staleFails of [false, true]) {
    const h = harness();
    const p = songProgressFixture(h);
    await p.togglePreview();
    h.tick({ mainPlayheadMs: 8000 });
    assert.equal(p.playingSongSection, 2);
    const oldPaint = h.archivedTimers.get(p.songPreviewProgressTimerId);
    const old = deferred();
    const fresh = deferred();
    h.responses.push(old, fresh);
    p.sections = p.sections.map((section, index) => ({ ...section, repeats: index === 0 ? 2 : section.repeats }));
    const first = p.restartSongPreview();
    assert.equal(p.playingSongSection, -1, 'Restart preparation must clear the old audible-section highlight');
    assert.equal(h.timers.size, 0);
    const second = p.restartSongPreview();
    p.sections[0].repeats = 16;
    p.bpm = 60;
    p.beatsPerBar = 7;
    fresh.resolve();
    await second;
    assert.ok(h.timers.has(p.songPreviewProgressTimerId));
    assert.equal(h.timers.size, 1);
    h.tick({ mainPlayheadMs: 4000 });
    const timer = p.songPreviewProgressTimerId;
    assert.equal(p.playingSongSection, 1, 'A prepared restart must follow the timing actually requested before its async load');
    oldPaint.callback();
    assert.equal(p.playingSongSection, 1, 'An old visual callback cannot restore a superseded program boundary');
    if (staleFails) old.reject(new Error('Superseded song preparation'));
    else old.resolve();
    await first;
    assert.equal(p.previewTarget, 'song');
    assert.equal(p.songPreviewProgressTimerId, timer);
    assert.equal(p.playingSongSection, 1);
    assert.equal(h.timers.size, 1, 'A stale song completion cannot install another highlight observer');
    assert.deepEqual(h.toasts, []);
    p.aboutToDisappear();
    oldPaint.callback();
    h.archivedTimers.get(timer).callback();
    assert.equal(p.playingSongSection, -1, 'Page exit must clear the highlight and reject every queued paint');
    assert.equal(h.timers.size, 0);
  }

  for (const fail of [false, true]) {
    const h = harness();
    const p = songProgressFixture(h);
    const pending = deferred();
    h.responses.push(pending);
    const start = p.togglePreview();
    await p.togglePreview();
    if (fail) pending.reject(new Error('Canceled song load'));
    else pending.resolve();
    await start;
    assert.equal(p.playingSongSection, -1);
    assert.equal(p.songPreviewProgressTimerId, -1);
    assert.equal(h.timers.size, 0);
    assert.deepEqual(h.toasts, []);
  }

  const failed = harness();
  const p = songProgressFixture(failed);
  await p.togglePreview();
  failed.tick({ mainPlayheadMs: 2000 });
  const paint = failed.archivedTimers.get(p.songPreviewProgressTimerId);
  const load = deferred();
  failed.responses.push(load);
  const restart = p.restartSongPreview();
  load.reject(new Error('Current restart unavailable'));
  await restart;
  paint.callback();
  assert.equal(p.previewTarget, '');
  assert.equal(p.playingSongSection, -1, 'A failed current restart must not retain an obsolete playing card');
  assert.equal(failed.timers.size, 0);
  assert.deepEqual(failed.toasts, ['切换试听失败']);
}

async function testSongSectionPlaybackOwnership() {
  for (const foreignRevision of [false, true]) {
    const h = harness();
    const p = songProgressFixture(h);
    const ready = deferred();
    h.responses.push(ready);
    const start = p.togglePreview();
    h.setSnapshot({ revision: 99, mainPlayheadMs: 0 });
    ready.resolve();
    await start;
    assert.equal(p.songPreviewTransportRevision, 99);
    h.tick({ revision: 99, mainPlayheadMs: 2000 });
    assert.equal(p.playingSongSection, 1);
    const paint = h.archivedTimers.get(p.songPreviewProgressTimerId);
    if (!foreignRevision) h.setPreviewActive(false);
    h.tick({ revision: foreignRevision ? 100 : 99, mainPlayheadMs: 8000 });
    assert.equal(p.playingSongSection, -1,
      'A foreign transport revision or lost preview ownership must immediately clear the song-card highlight');
    assert.equal(p.songPreviewProgressTimerId, -1);
    assert.equal(p.songPreviewTransportRevision, undefined);
    assert.equal(h.timers.size, 0, 'A foreign playback timeline must stop the obsolete song observer');
    h.setPreviewActive(true);
    h.setSnapshot({ revision: 99, mainPlayheadMs: 8000 });
    paint.callback();
    p.updateSongPreviewProgress();
    assert.equal(p.playingSongSection, -1, 'Reusing an old revision or preview lease cannot resurrect a canceled song observer');
    assert.equal(h.timers.size, 0);
    assert.equal(h.calls.length, 1, 'Foreign playback detection must not submit new audio');
    assert.equal(h.stopCount(), 0, 'A local visual observer cannot stop playback owned by another feature');
  }

  for (const restarting of [false, true]) {
    const h = harness();
    const p = songProgressFixture(h);
    if (restarting) {
      await p.togglePreview();
      h.tick({ mainPlayheadMs: 2000 });
      assert.equal(p.playingSongSection, 1);
    }
    const ready = deferred();
    h.responses.push(ready);
    const start = restarting ? p.restartSongPreview() : p.togglePreview();
    h.setPreviewActive(false);
    h.setSnapshot({ revision: 100, mainPlayheadMs: 8000 });
    ready.resolve();
    await start;
    assert.equal(p.playingSongSection, -1, 'A song completing after its preview lease was reclaimed cannot highlight another playback timeline');
    assert.equal(p.songPreviewProgressTimerId, -1);
    assert.equal(p.songPreviewTransportRevision, undefined);
    assert.equal(h.timers.size, 0);
    for (const timer of h.archivedTimers.values()) timer.callback();
    assert.equal(p.playingSongSection, -1);
    assert.equal(h.calls.length, restarting ? 2 : 1);
    assert.equal(h.stopCount(), 0);
  }
}

async function testWholeSongLiveUpdateQueue() {
  const h = harness();
  const p = songProgressFixture(h);
  await p.togglePreview();
  h.tick({ mainPlayheadMs: 2500 });
  const keys = [...h.calls[0].sectionKeys];
  const progressTimer = p.songPreviewProgressTimerId;
  const flags = expansion(p);
  h.setPreviewPosition({ sectionKey: keys[1], repeatIndex: 0 });
  p.updatePattern(1, 2);
  p.updateRepeats(1, 1);
  p.updateFill(1, 1);
  p.selectFillEvery(1, 1);
  p.openEditor(1, 0);
  p.toggleStep(8, 3);
  const saved = plain(p.editorEvents);
  p.saveEditor();
  assert.equal(h.calls.length, 1, 'Editing a sounding whole song must not issue another start request');
  assert.equal(h.stopCount(), 0);
  assert.equal(h.updateCalls.length, 0, 'Rapid changes must wait for the 150 ms coalescing window');
  assert.equal([...h.timers.values()].filter(timer => !timer.interval && timer.delay === 150).length, 1);
  assert.equal(p.songPreviewProgressTimerId, progressTimer);
  assert.deepEqual(expansion(p), flags);
  h.runTimeouts(150);
  await settle();
  assert.equal(h.updateCalls.length, 1, 'A burst must prepare only its latest arrangement');
  assert.deepEqual(h.updateCalls[0].sectionKeys, keys);
  assert.deepEqual(h.updateCalls[0].program.sections[1].customPattern.events, saved);
  assert.equal(h.updateCalls[0].program.sections[1].repeats, 4);
  assert.ok(h.invalidations() >= 5, 'Each newer edit must withdraw any obsolete staged or pending update immediately');
  p.updateRepeats(0, 3);
  h.runTimeouts(150);
  await settle();
  h.setSnapshot({ mainPlayheadMs: 2500 });
  p.updateSongPreviewProgress();
  assert.equal(p.playingSongSection, 1,
    'Highlight must keep the actually audible B key while the edited earlier A length is still staged');
  h.setPreviewPosition({ sectionKey: keys[2], repeatIndex: 0 });
  p.updateSongPreviewProgress();
  assert.equal(p.playingSongSection, 2, 'Highlight must follow the engine only after its applied plan reaches C');
  p.deleteSection(0);
  assert.deepEqual(plain(p.playbackSectionKeys()), keys.slice(1), 'Deleting A must preserve the playback identities of renamed B/C');
  assert.equal(p.playingSongSection, 1, 'A renamed card must remain highlighted by stable key');
  p.addSection();
  const added = plain(p.playbackSectionKeys());
  assert.deepEqual(added.slice(0, 2), keys.slice(1));
  assert.equal(keys.includes(added[2]), false, 'A new card needs a fresh key rather than a reused display letter');
  assert.equal(new Set(added).size, 3);
  h.runTimeouts(150);
  await settle();
  assert.equal(h.calls.length, 1);
  assert.equal(h.stopCount(), 0);
  assert.deepEqual(h.updateCalls.at(-1).sectionKeys, added);
  assert.equal(JSON.stringify(h.updateCalls.at(-1).program).includes('sectionKey'), false,
    'Local playback identities cannot leak into the persisted/shared drum program');
  p.aboutToDisappear();
  assert.equal(h.timers.size, 0);
}

async function testLiveUpdateFailureAndCancellation() {
  const h = harness();
  const p = songProgressFixture(h);
  await p.togglePreview();
  h.tick({ mainPlayheadMs: 2500 });
  const old = deferred();
  h.updateResponses.push(old);
  p.updatePattern(1, 1);
  h.runTimeouts(150);
  assert.equal(h.updateCalls.length, 1);
  p.updatePattern(1, 2);
  h.runTimeouts(150);
  await settle();
  old.reject(new Error('Superseded live update'));
  await settle();
  assert.deepEqual(h.toasts, [], 'A superseded update failure must not report an error for the latest draft');
  const current = deferred();
  h.updateResponses.push(current);
  p.updateFill(1, 2);
  h.runTimeouts(150);
  current.reject(new Error('Current live update unavailable'));
  await settle();
  assert.deepEqual(h.toasts, [], 'Live-update failure belongs beside the audition controls, without a toast');
  assert.equal(p.songPreviewMessage, '修改未进入试听，正在播放上一版');
  assert.deepEqual(h.failures, ['drum.preview.update'], 'Only the current failed edit produces diagnostics');
  assert.equal(p.previewTarget, 'song');
  assert.equal(p.playingSongSection, 1);
  assert.equal(h.calls.length, 1, 'A failed update must leave the original playback running');
  assert.equal(h.stopCount(), 0);
  const retry = deferred();
  h.updateResponses.push(retry);
  p.updateFill(1, 1);
  h.runTimeouts(150);
  assert.equal(p.songPreviewMessage, '修改未进入试听，正在播放上一版',
    'A pending edit cannot claim that the newer visible arrangement is already audible');
  retry.resolve(false);
  await settle();
  assert.equal(p.songPreviewMessage, '修改未进入试听，正在播放上一版',
    'An unaccepted update must retain the previous-audio explanation');
  p.updateFill(1, 2);
  h.runTimeouts(150);
  await settle();
  assert.equal(p.songPreviewMessage, '', 'A successful current update clears the previous-audio explanation');
  p.songPreviewMessage = '修改未进入试听，正在播放上一版';
  await p.togglePreview();
  assert.equal(p.songPreviewMessage, '', 'Stopping audition clears its local feedback');
  p.aboutToDisappear();

  for (const exit of [q => q.togglePreview(), q => q.aboutToDisappear(), async q => {
    q.openEditor(1, 0);
    await q.toggleEditorPreview();
  }]) {
    const next = harness();
    const q = songProgressFixture(next);
    await q.togglePreview();
    next.tick({ mainPlayheadMs: 0 });
    q.updatePattern(1, 1);
    const queued = [...next.timers.values()].find(timer => !timer.interval && timer.delay === 150);
    assert.ok(queued);
    await exit(q);
    queued.callback();
    await settle();
    assert.equal(next.updateCalls.length, 0, 'Stop, editor handoff and page exit must cancel queued whole-song updates');
    assert.equal(q.songPreviewUpdateTimerId, -1);
  }
}

async function testLiveUpdateNoticeOwnership() {
  for (const staleFails of [false, true]) {
    const h = harness();
    const p = songProgressFixture(h);
    await p.togglePreview();
    h.tick({ mainPlayheadMs: 2500 });
    const old = deferred();
    const current = deferred();
    h.updateResponses.push(old, current);
    p.updatePattern(1, 1);
    h.runTimeouts(150);
    p.updatePattern(1, 2);
    h.runTimeouts(150);
    current.reject(new Error('Current edit failed'));
    await settle();
    assert.equal(p.songPreviewMessage, '修改未进入试听，正在播放上一版');
    if (staleFails) old.reject(new Error('Older edit failed later'));
    else old.resolve();
    await settle();
    assert.equal(p.songPreviewMessage, '修改未进入试听，正在播放上一版',
      'An older failure or success cannot replace the latest edit feedback');
    assert.deepEqual(h.failures, ['drum.preview.update']);
    assert.deepEqual(h.toasts, []);
    p.aboutToDisappear();
    assert.equal(p.songPreviewMessage, '', 'Leaving the page clears old-audio feedback');
  }

  for (const failed of [false, true]) {
    const h = harness();
    const p = songProgressFixture(h);
    await p.togglePreview();
    h.tick({ mainPlayheadMs: 2500 });
    const update = deferred();
    h.updateResponses.push(update);
    p.updatePattern(1, 1);
    h.runTimeouts(150);
    h.setPreviewActive(false);
    h.setPreviewActive(true);
    h.setPreviewReady(true);
    if (failed) update.reject(new Error('Former audition owner failed'));
    else update.resolve();
    await settle();
    assert.equal(p.songPreviewMessage, '', 'A different audition owner cannot inherit an old request failure');
    assert.deepEqual(h.failures, []);
    assert.deepEqual(h.toasts, []);
    p.aboutToDisappear();
  }
}

async function testLocalSaveAndEditingFeedback() {
  const h = harness();
  const p = h.page;
  h.setPersistenceTime(1000);
  p.openSaveDialog();
  p.saveName = '   ';
  p.confirmNamedSave();
  assert.equal(p.saveNameError, '请输入名称');
  assert.equal(p.saveDialogVisible, true);
  assert.equal(p.overwriteDialogVisible, false);
  assert.deepEqual(h.storageWrites, [], 'An empty name cannot persist or dismiss the save field');
  assert.deepEqual(h.toasts, [], 'Name validation must remain beside its field');
  p.saveName = ' 夜跑 ';
  p.confirmNamedSave();
  assert.equal(p.saveNameError, '');
  assert.equal(p.savedPrograms[0].name, '夜跑');
  assert.equal(p.saveDialogVisible, false);
  assert.deepEqual(h.toasts, ['已保存到我的节奏'], 'Persistence has one lightweight result notice');
  const original = p.savedPrograms[0].program;
  const writesBeforeOverwrite = h.storageWrites.length;
  p.updateRepeats(0, 1);
  p.openSaveDialog();
  p.saveName = '夜跑';
  p.confirmNamedSave();
  assert.equal(p.overwriteDialogVisible, true, 'A duplicate name still requires explicit overwrite confirmation');
  assert.equal(p.saveDialogVisible, false);
  assert.equal(h.storageWrites.length, writesBeforeOverwrite);
  assert.equal(p.savedPrograms[0].program, original, 'Showing confirmation must preserve the existing arrangement');
  p.returnToRename();
  assert.equal(p.saveDialogVisible, true);
  assert.equal(p.overwriteDialogVisible, false);
  p.confirmNamedSave();
  p.persistNamedSave(true);
  assert.equal(p.savedPrograms.length, 1);
  assert.notEqual(p.savedPrograms[0].program, original);
  assert.deepEqual(h.toasts, ['已保存到我的节奏', '已更新我的节奏']);

  h.toasts.length = 0;
  const saved = p.savedPrograms[0];
  p.sections[0].repeats = 1;
  p.loadSavedProgram(saved);
  assert.notEqual(p.sections[0].repeats, 1, 'Loading still changes the visible arrangement');
  p.deleteSavedProgram(saved.id);
  assert.equal(p.savedPrograms.length, 0, 'Deleting still updates the saved list');
  p.openEditor(0, 0);
  p.toggleStep(0, 1);
  const draft = plain(p.editorEvents);
  p.saveEditor();
  assert.equal(p.editorVisible, false);
  assert.deepEqual(plain(p.sections[0].customPattern.events), draft);
  assert.deepEqual(h.toasts, [], 'Visible load/delete/editor-apply changes must not add success notices');

  while (p.sections.length < 8) p.addSection();
  const upper = plain(p.sections);
  p.addSection();
  assert.deepEqual(plain(p.sections), upper, 'The upper bound must leave eight sections intact');
  while (p.sections.length > 1) p.deleteSection(0);
  const lower = plain(p.sections);
  p.deleteSection(0);
  assert.deepEqual(plain(p.sections), lower, 'The lower bound must preserve the final section');
  assert.deepEqual(h.toasts, [], 'Boundary controls communicate their disabled state without notices');
}

async function testTeamApplyFeedbackOwnership() {
  for (const stage of ['meter', 'program']) {
    for (const transition of ['leave', 'replace']) {
      for (const failed of [false, true]) {
        const h = harness();
        const p = h.page;
        const result = deferred();
        (stage === 'meter' ? h.teamMeterResponses : h.teamProgramResponses).push(result);
        const applying = p.applyToTeam();
        await settle();
        assert.equal(p.saving, true);
        await p.applyToTeam();
        assert.equal(h.teamMeterCalls.length, 1, 'Repeated applies while busy must share one operation');
        if (transition === 'leave') p.aboutToDisappear();
        else h.replaceSession();
        if (failed) result.reject(new Error('Former page or session failed'));
        else result.resolve();
        await applying;
        assert.deepEqual(h.toasts, [], 'An obsolete team apply must not publish success or error feedback');
        assert.deepEqual(h.failures, [], 'An obsolete team apply must not log a current-operation failure');
        assert.equal(h.backCount(), 0, 'A late apply cannot navigate away from a different page or session');
        assert.equal(h.teamProgramCalls.length, stage === 'meter' ? 0 : 1,
          'A page/session change after meter preparation must not submit the remaining program update');
      }
    }
  }

  for (const failed of [false, true]) {
    const h = harness();
    const p = h.page;
    const result = deferred();
    h.teamProgramResponses.push(result);
    const applying = p.applyToTeam();
    await settle();
    if (failed) result.reject(new Error('Current apply failed'));
    else result.resolve();
    await applying;
    assert.equal(p.saving, false);
    assert.deepEqual(h.toasts, [failed ? '应用失败，请重试' : '鼓机编排已应用到队伍'],
      'The current team apply must retain one clear result');
    assert.equal(h.backCount(), failed ? 0 : 1);
    assert.deepEqual(h.failures, failed ? ['drum.apply'] : []);
  }

  const h = harness();
  const p = h.page;
  const old = deferred();
  const current = deferred();
  h.teamMeterResponses.push(old, current);
  const former = p.applyToTeam();
  p.aboutToDisappear();
  p.aboutToAppear();
  assert.equal(p.saving, false, 'A new page appearance must not inherit an old apply spinner');
  const latest = p.applyToTeam();
  old.resolve();
  await former;
  assert.equal(p.saving, true, 'An older completion cannot clear the new page apply state');
  assert.deepEqual(h.toasts, []);
  current.resolve();
  await latest;
  assert.equal(p.saving, false);
  assert.equal(h.teamProgramCalls.length, 1);
  assert.deepEqual(h.toasts, ['鼓机编排已应用到队伍']);
  assert.equal(h.backCount(), 1);
}

async function testDeferredInitialSongUpdate() {
  for (const preroll of [false, true]) {
    const h = harness();
    const p = songProgressFixture(h);
    const cold = deferred();
    if (!preroll) h.responses.push(cold);
    const initialStart = p.togglePreview();
    if (preroll) await initialStart;
    p.updateRepeats(0, 1);
    p.updatePattern(1, 2);
    assert.equal(h.calls.length, 1, 'A cold/preroll edit must coalesce before submitting a replacement');
    assert.equal(p.playingSongSection, -1);
    assert.equal(h.updateCalls.length, 0, 'A nonaudible initial request must be replaced rather than hot-updated');
    h.runTimeouts(150);
    await settle();
    assert.equal(h.calls.length, 2);
    assert.equal(h.calls[1].program.sections[0].repeats, 2);
    assert.equal(h.calls[1].program.sections[1].patternIndex, 2);
    assert.deepEqual(h.calls[1].sectionKeys, h.calls[0].sectionKeys);
    if (!preroll) { cold.resolve(); await initialStart; }
    assert.equal(p.previewTarget, 'song');
    assert.equal(h.timers.size, 1);
    h.tick({ mainPlayheadMs: 0 });
    assert.equal(p.playingSongSection, 0);
    p.aboutToDisappear();
  }

  const h = harness();
  const p = songProgressFixture(h);
  const cold = deferred();
  h.responses.push(cold);
  const initialStart = p.togglePreview();
  p.updateRepeats(0, 1);
  h.setPreviewActive(false);
  h.runTimeouts(150);
  cold.resolve();
  await initialStart;
  await settle();
  assert.equal(h.calls.length, 1,
    'A production/calibration/Stop takeover during the canceled-start debounce must prevent a deferred song restart');
  assert.equal(p.previewTarget, '');
  assert.equal(p.playingSongSection, -1);
  assert.equal(h.timers.size, 0);

  const meter = harness();
  const q = songProgressFixture(meter);
  await q.togglePreview();
  meter.tick({ mainPlayheadMs: 0 });
  q.bpm = 135;
  q.beatsPerBar = 3;
  q.beatUnit = 8;
  await q.refreshActivePreview();
  assert.equal(meter.calls.length, 2, 'Tempo/meter changes must retain their explicit restart behavior');
  assert.equal(meter.calls[1].bpm, 135);
  assert.equal(meter.calls[1].beats, 3);
  assert.equal(meter.updateCalls.length, 0);
  q.aboutToDisappear();
}

async function testSongHighlightPresentationDeadlines() {
  for (const audibleStart of [350, 180, 830]) {
    const h = harness();
    const p = songProgressFixture(h);
    p.sections = [3, 1, 2].map((repeats, index) => ({ ...sectionFixture(index), repeats }));
    const keys = plain(p.playbackSectionKeys());
    h.setSnapshotProvider(time => ({ revision: 99, running: true, countIn: false,
      mainPlayheadMs: time - 350 }));
    h.setPreviewPosition(time => {
      if (time < audibleStart) return undefined;
      const elapsed = (time - audibleStart) % 12000;
      const section = elapsed < 6000 ? 0 : elapsed < 8000 ? 1 : 2;
      return { sectionKey: keys[section], repeatIndex: Math.floor(elapsed / 2000),
        nextBoundaryDelayMs: 2000 - elapsed % 2000 };
    });
    await p.togglePreview();
    let elapsed = 0;
    const advanceTo = time => { h.advanceTime(time - elapsed); elapsed = time; };
    advanceTo(audibleStart - 1);
    assert.equal(p.playingSongSection, -1, 'The first highlight cannot precede the actual PCM presentation');
    advanceTo(audibleStart + 16);
    assert.equal(p.playingSongSection, 0, 'Preroll must become visible within one display-sized polling interval');
    advanceTo(audibleStart + 5999);
    assert.equal(p.playingSongSection, 0);
    advanceTo(audibleStart + 6000);
    assert.equal(p.playingSongSection, 1,
      'The adaptive paint must land on the real B boundary instead of waiting for the next fixed polling tick');
    advanceTo(audibleStart + 8000);
    assert.equal(p.playingSongSection, 2);
    advanceTo(audibleStart + 12000);
    assert.equal(p.playingSongSection, 0, 'The same deadline scheduling must cover the whole-song loop boundary');
    assert.equal(h.calls.length, 1);
    assert.equal(h.stopCount(), 0);
    assert.deepEqual(expansion(p), [true, true, false]);
    p.aboutToDisappear();
    assert.equal(h.timers.size, 0);
  }
}

async function testSongEditDuringPresentationRecoveryGap() {
  const h = harness();
  const p = songProgressFixture(h);
  await p.togglePreview();
  h.tick({ mainPlayheadMs: 2500 });
  assert.equal(p.playingSongSection, 1);
  const key = h.calls[0].sectionKeys[1];
  h.setPreviewPosition(undefined);
  h.tick({ mainPlayheadMs: 2600 });
  assert.equal(p.playingSongSection, -1, 'An unanchored native recovery gap must temporarily clear the unknown audible card');
  p.updatePattern(1, 2);
  assert.equal(h.calls.length, 1);
  assert.equal(h.stopCount(), 0,
    'A song already heard must not be treated as an initial cold load when a native recovery anchor is temporarily missing');
  h.runTimeouts(150);
  await settle();
  assert.equal(h.updateCalls.length, 1, 'Edits during a known-running song recovery gap must remain live updates');
  assert.equal(h.calls.length, 1);
  assert.equal(p.previewTarget, 'song');
  h.setPreviewPosition({ sectionKey: key, repeatIndex: 0, nextBoundaryDelayMs: 1000 });
  h.tick({ mainPlayheadMs: 2700 });
  assert.equal(p.playingSongSection, 1);
  p.aboutToDisappear();
}

async function testSongBehindEditor() {
  for (const mode of [0, 1]) {
    for (const hardwareBack of [false, true]) {
      const h = harness();
      const p = h.page;
      const saved = plain(p.sections);
      await p.togglePreview();
      h.setSnapshot({ mainPlayheadMs: 4875 });
      p.updateSongPreviewProgress();
      const songSnapshot = h.getSnapshot();
      const songRequest = plain(h.calls[0]);
      const songRevision = p.sectionPreviewRevision;
      const songTimer = p.songPreviewProgressTimerId;
      const assertSongUntouched = () => {
        assert.equal(p.previewTarget, 'song');
        assert.equal(h.calls.length, 1, 'Inspecting or editing a draft cannot restart or seek the song');
        assert.equal(h.stopCount(), 0, 'The song must remain audible until editor audition is requested');
        assert.deepEqual(h.audioActions, ['play']);
        assert.equal(p.sectionPreviewRevision, songRevision,
          'Opening and dismissing drafts must retain ownership of the pending/current song request');
        assert.deepEqual(h.getSnapshot(), songSnapshot, 'Draft navigation must preserve the running transport snapshot');
        assert.deepEqual(h.calls[0], songRequest, 'Unsaved edits must not alter the song already requested');
        assert.deepEqual(plain(p.sections), saved, 'Draft actions cannot apply changes to the arrangement');
        assert.equal(h.timers.size, 1, 'A background song must retain only its own section highlight timer');
        assert.equal(p.songPreviewProgressTimerId, songTimer);
        assert.equal(p.editorPreviewTimerId, -1, 'A background song cannot acquire an editor playhead timer');
        assert.equal(p.playingSongSection, 0, 'Opening and dismissing the editor cannot clear the playing card highlight');
      };

      p.openEditor(0, mode);
      assert.equal(p.editorVisible, true);
      assert.equal(p.editorPlayheadStep, -1, 'A fresh draft cannot borrow the whole-song playhead');
      assertSongUntouched();
      p.toggleStep(3, 5);
      p.chooseEditorSubdivision(3);
      const single = p.editorOffGridEvents(3).find(event => event.tick === 600);
      assert.ok(single, 'The draft fixture must contain a note to snap individually');
      p.snapEditorEventToGrid(3, single.tick);
      p.toggleStep(8, 1);
      p.chooseEditorSubdivision(4);
      assert.ok(p.editorOffGridCount() > 0);
      p.snapAllEditorOffGridEvents();
      p.chooseEditorSubdivision(6);
      p.seekEditorStep(15);
      assert.equal(p.editorPlayheadBeats, 2.5, 'Timeline taps select the future draft audition origin');
      assertSongUntouched();

      if (hardwareBack) assert.equal(p.onBackPress(), true);
      else p.closeEditor();
      assert.equal(p.editorVisible, false);
      assert.equal(p.editorPlayheadStep, -1);
      assertSongUntouched();

      p.openEditor(0, 1 - mode);
      assert.deepEqual(plain(p.editorEvents), plain(catalog.buildSectionPattern(
        p.currentProgram(), p.sections[0], mode === 0).events),
      'Reopening the opposite editor must load that source phrase while the song continues');
      p.seekEditorStep(4);
      p.openEditor(0, mode);
      assert.equal(p.editorPlayheadStep, -1, 'Switching drafts must reset the selected editor origin');
      assert.deepEqual(plain(p.editorEvents), plain(catalog.buildSectionPattern(
        p.currentProgram(), p.sections[0], mode === 1).events),
      'Reopening a discarded draft cannot restore unsaved changes');
      assertSongUntouched();
      p.closeEditor();
      assertSongUntouched();
      p.aboutToDisappear();
      assert.equal(h.stopCount(), 1, 'Leaving the page must still stop the background song');
      assert.equal(p.previewTarget, '');
      assert.equal(p.playingSongSection, -1);
      assert.equal(h.timers.size, 0);
      assert.deepEqual(h.audioActions, ['play', 'stop']);
    }
  }
}

async function testSongToEditorHandoff() {
  const exits = [p => p.closeEditor(), p => assert.equal(p.onBackPress(), true), p => p.aboutToDisappear()];
  for (const mode of [0, 1]) {
    for (const exit of exits) {
      const h = harness();
      const p = h.page;
      await p.togglePreview();
      h.tick({ mainPlayheadMs: 500 });
      const songPaint = h.archivedTimers.get(p.songPreviewProgressTimerId);
      assert.equal(p.playingSongSection, 0);
      const songRevision = p.sectionPreviewRevision;
      p.openEditor(0, mode);
      p.seekEditorStep(12);
      p.toggleStep(3, 5);
      p.chooseEditorSubdivision(3);
      const draft = plain(p.editorEvents);
      const saved = plain(p.sections);
      await p.toggleEditorPreview();
      assert.deepEqual(h.audioActions, ['play', 'stop', 'play'],
        'The editor audition button must stop the song before starting its draft');
      assert.equal(h.calls.length, 2);
      assert.equal(h.stopCount(), 1);
      assert.ok(p.sectionPreviewRevision > songRevision, 'Only explicit editor audition supersedes the song request');
      assert.equal(p.previewTarget, 'editor');
      assert.equal(p.playingSongSection, -1, 'Switching to draft audition must clear the whole-song card highlight');
      assert.equal(p.songPreviewProgressTimerId, -1);
      songPaint.callback();
      assert.equal(p.playingSongSection, -1, 'A queued song paint cannot highlight a card during editor audition');
      assert.deepEqual(h.calls[1].program, {
        styleKey: p.styleKey, beatsPerBar: 4, beatUnit: 4,
        sections: [{ id: 'B', patternIndex: 0, repeats: 1, fillIndex: 0, fillEvery: 0,
          customPattern: { subdivision: 3, events: draft } }]
      }, 'The handoff must play the current unsaved main/fill draft, not the previously playing song');
      assert.equal(h.calls[1].positionBeats, 3, 'The handoff must use the editor cursor, not song progress');
      assert.equal(h.calls[1].looping, true);
      assert.equal(h.timers.size, 1);
      h.tick({ mainPlayheadMs: 1650 });
      exit(p);
      assert.equal(h.stopCount(), 2, 'Exiting after editor audition must stop the draft');
      assert.equal(h.calls.length, 2, 'Closing a draft cannot automatically resume the old song');
      assert.equal(p.previewTarget, '');
      assert.equal(p.playingSongSection, -1);
      assert.equal(p.editorPlayheadStep, -1);
      assert.equal(h.timers.size, 0);
      assert.deepEqual(plain(p.sections), saved);
      for (const timer of h.archivedTimers.values()) timer.callback();
      assert.equal(h.calls.length, 2);
      assert.equal(p.previewTarget, '', 'Queued editor callbacks cannot revive either playback owner');
    }
  }
}

async function testPendingSongSurvivesDraftNavigation() {
  for (const mode of [0, 1]) {
    for (const restarting of [false, true]) {
      for (const fail of [false, true]) {
        const h = harness();
        const p = h.page;
        const pending = deferred();
        h.responses.push(pending);
        if (restarting) p.previewTarget = 'song';
        const start = restarting ? p.restartSongPreview() : p.previewProgram(p.currentProgram(), 'song');
        const songRevision = p.sectionPreviewRevision;
        p.openEditor(0, mode);
        p.toggleStep(2, 7);
        p.seekEditorStep(9);
        p.chooseEditorSubdivision(6);
        assert.equal(p.onBackPress(), true);
        p.openEditor(0, 1 - mode);
        p.closeEditor();
        p.openEditor(0, mode);
        assert.equal(p.sectionPreviewRevision, songRevision,
          'Draft open/close/reopen cannot invalidate a song still preparing samples');
        assert.equal(h.stopCount(), 0);
        assert.equal(h.calls.length, 1);
        assert.equal(p.previewTarget, 'song');
        assert.equal(h.timers.size, 0, 'Pending songs cannot highlight a section before playback is prepared');
        if (fail) pending.reject(new Error('Current song sample preparation failed'));
        else pending.resolve();
        const result = await start;
        if (!restarting) assert.equal(result, !fail, 'The song request must retain its own completion result');
        assert.equal(p.previewTarget, fail ? '' : 'song');
        assert.deepEqual(h.toasts, fail ? [restarting ? '切换试听失败' : '试听启动失败'] : [],
          'A current song failure remains current even after its editor was opened and closed');
        assert.equal(p.editorVisible, true, 'Song preparation completion cannot dismiss the editor');
        assert.equal(p.editorPlayheadStep, -1, 'Song preparation cannot create a draft cursor');
        assert.equal(p.sectionPreviewRevision, songRevision);
        assert.equal(h.stopCount(), 0);
        assert.equal(h.calls.length, 1);
        assert.equal(h.timers.size, fail ? 0 : 1, 'Only successfully prepared songs create a section highlight timer');
        assert.equal(p.editorPreviewTimerId, -1, 'Song completion cannot create an editor playhead timer');
        p.aboutToDisappear();
        assert.equal(h.stopCount(), 1);
      }
    }
  }

  for (const mode of [0, 1]) {
    for (const withFill of [false, true]) {
      const h = harness();
      await h.page.previewSection(0, withFill);
      const previousRevision = h.page.sectionPreviewRevision;
      const oldTimers = [...h.archivedTimers.values()];
      assert.equal(h.timers.size, 1);
      h.page.openEditor(0, mode);
      assert.equal(h.stopCount(), 1, 'Opening a draft must still stop a standalone pattern/fill audition');
      assert.equal(h.page.previewTarget, '');
      assert.ok(h.page.sectionPreviewRevision > previousRevision);
      assert.equal(h.timers.size, 0, 'Opening a draft must cancel a standalone audition stop timer');
      for (const timer of oldTimers) timer.callback();
      assert.equal(h.stopCount(), 1, 'A canceled section timer cannot stop a later playback owner');
      assert.equal(h.calls.length, 1);
      h.page.closeEditor();
      assert.equal(h.calls.length, 1, 'Dismissal cannot restart a stopped standalone audition');
    }
  }
}

async function testDraftsAndLifecycle() {
  for (const mode of [0, 1]) {
    const h = harness();
    const p = h.page;
    p.previewTarget = 'song';
    const original = plain(p.sections);
    p.openEditor(0, mode);
    assert.equal(h.stopCount(), 0, 'Opening the editor must preserve a whole-song audition');
    assert.deepEqual(plain(p.editorEvents), plain(catalog.buildSectionPattern(p.currentProgram(), p.sections[0], mode === 1).events),
      'An editor draft must preserve the source notes and dynamics');
    p.toggleStep(3, 5);
    assert.deepEqual(plain(p.sections), original, 'Draft edits must remain unsaved while auditioning');
    await p.toggleEditorPreview();
    assert.equal(p.previewTarget, 'editor');
    assert.equal(h.calls.length, 1);
    const audition = h.calls[0];
    assert.deepEqual(audition.program, {
      styleKey: p.styleKey, beatsPerBar: 4, beatUnit: 4,
      sections: [{ id: 'B', patternIndex: 0, repeats: 1, fillIndex: 0, fillEvery: 0, customPattern: { subdivision: p.editorSubdivision, events: plain(p.editorEvents) } }]
    }, 'Both grid modes must play exactly the visible draft as one looping bar, without scheduled fills');
    assert.equal(audition.looping, true);
    assert.equal(audition.bpm, 120);
    assert.equal(audition.beats, 4);
    assert.equal(audition.positionBeats, 0, 'A fresh draft without a cursor must audition from the beginning');
    assert.equal(p.editorPlayheadStep, -1, 'The scheduled preparation interval has no active grid step');
    assert.equal(h.timers.size, 1);
    const initialTimer = p.editorPreviewTimerId;
    assert.equal(h.timers.get(initialTimer).delay, 32);

    h.tick({ mainPlayheadMs: 625 });
    assert.equal(p.editorPlayheadStep, 5, 'The cursor must reflect the engine timeline');
    const playingEvents = plain(p.editorEvents);
    h.setSnapshot({ mainPlayheadMs: 687.5 });
    p.toggleStep(2, 7);
    await settle();
    assert.equal(h.calls.length, 2, 'Toggling a cell while auditioning must restart with the updated draft');
    assert.equal(h.calls[1].positionBeats, 1.375,
      'Live draft edits must continue from the latest fractional transport position');
    assert.equal(p.editorPlayheadStep, 5.5, 'Live edits must keep the cursor while the revised draft is preparing');
    assert.notDeepEqual(h.calls[1].program.sections[0].customPattern.events, playingEvents);
    assert.deepEqual(h.calls[1].program.sections[0].customPattern.events, plain(p.editorEvents));
    assert.deepEqual(audition.program.sections[0].customPattern.events, playingEvents,
      'A later edit must not mutate the prior playback request');
    assert.equal(h.timers.size, 1, 'A draft restart must replace its old paint timer');
    assert.equal(h.timers.has(initialTimer), false);

    h.tick({ mainPlayheadMs: 875 });
    await p.toggleEditorPreview();
    assert.equal(p.previewTarget, '');
    assert.equal(p.editorVisible, true, 'Stopping audition must keep the draft editor open');
    assert.equal(p.editorPlayheadStep, 7, 'Explicit Stop must keep the last played position visible');
    assert.equal(h.timers.size, 0);
    p.closeEditor();
    assert.equal(p.editorVisible, false);
    assert.equal(p.editorPlayheadStep, -1, 'Closing must clear a cursor retained by Stop');
    assert.deepEqual(plain(p.sections), original, 'Close must discard the draft without saving it');

    p.openEditor(0, mode);
    p.toggleStep(4, 3);
    await p.toggleEditorPreview();
    const savedDraft = plain(p.editorEvents);
    p.saveEditor();
    assert.equal(p.editorVisible, false);
    assert.equal(p.previewTarget, '');
    assert.equal(h.timers.size, 0);
    const savedPattern = mode === 0 ? p.sections[0].customPattern : p.sections[0].customFill;
    assert.equal(savedPattern.subdivision, p.editorSubdivision);
    assert.deepEqual(plain(savedPattern.events), savedDraft);
    assert.notEqual(savedPattern.events, p.editorEvents, 'Applying must store a distinct copy of the draft');
  }

  for (const close of [p => p.closeEditor(), p => assert.equal(p.onBackPress(), true), p => p.aboutToDisappear()]) {
    const h = harness();
    h.page.openEditor(0, 1);
    await h.page.toggleEditorPreview();
    h.tick({ mainPlayheadMs: 1100 });
    const stops = h.stopCount();
    close(h.page);
    assert.equal(h.stopCount(), stops + 1, 'Every editor exit must stop the audio audition');
    assert.equal(h.page.previewTarget, '');
    assert.equal(h.page.editorPlayheadStep, -1);
    assert.equal(h.timers.size, 0);
    for (const timer of h.archivedTimers.values()) timer.callback();
    assert.equal(h.page.editorPlayheadStep, -1, 'A queued paint callback must not revive a closed audition');
  }

  const absent = harness();
  absent.page.openEditor(0, 1);
  absent.setSessionAvailable(false);
  await absent.page.toggleEditorPreview();
  assert.equal(absent.calls.length, 0);
  assert.equal(absent.timers.size, 0);
  assert.equal(absent.page.previewTarget, '');
}

async function testStartRaces() {
  for (const fail of [false, true]) {
    const h = harness();
    h.page.openEditor(0, 1);
    const old = deferred();
    h.responses.push(old);
    const start = h.page.toggleEditorPreview();
    assert.equal(h.page.previewTarget, 'editor');
    h.page.closeEditor();
    if (fail) old.reject(new Error('Canceled sample preparation'));
    else old.resolve();
    await start;
    assert.equal(h.page.previewTarget, '');
    assert.equal(h.timers.size, 0, 'Late preparation must not create a timer after cancellation');
    assert.equal(h.toasts.length, 0, 'A canceled stale request must not display a startup failure');
  }

  for (const staleFails of [false, true]) {
    const h = harness();
    h.page.openEditor(0, 0);
    const old = deferred();
    const fresh = deferred();
    h.responses.push(old, fresh);
    const firstStart = h.page.toggleEditorPreview();
    h.page.toggleStep(1, 1);
    fresh.resolve();
    await settle();
    assert.equal(h.timers.size, 1);
    const freshTimer = h.page.editorPreviewTimerId;
    if (staleFails) old.reject(new Error('Old configuration failed'));
    else old.resolve();
    await firstStart;
    assert.equal(h.page.previewTarget, 'editor', 'Old completion must not clear a newer audition');
    assert.equal(h.page.editorPreviewTimerId, freshTimer);
    assert.equal(h.timers.size, 1, 'Old completion must not add a second timer');
    assert.equal(h.toasts.length, 0);
    h.page.aboutToDisappear();
  }

  const failed = harness();
  failed.page.openEditor(0, 0);
  const preparation = deferred();
  failed.responses.push(preparation);
  const started = failed.page.toggleEditorPreview();
  const stops = failed.stopCount();
  preparation.reject(new Error('Renderer unavailable'));
  await started;
  assert.equal(failed.page.previewTarget, '');
  assert.equal(failed.page.editorVisible, true);
  assert.equal(failed.timers.size, 0);
  assert.equal(failed.stopCount(), stops + 1, 'A current startup failure must stop partially prepared audio');
  assert.deepEqual(failed.toasts, ['试听启动失败']);
}

async function testStoppedCursor() {
  const h = harness();
  const p = h.page;
  p.openEditor(0, 1);
  p.updateEditorViewport(6 * CELL_WIDTH + PLAYHEAD_WIDTH);
  await p.toggleEditorPreview();
  h.tick({ mainPlayheadMs: 1050 });
  assert.equal(p.editorPlayheadStep, 8.4);
  const offset = p.editorScroller.offset;
  const scrollCalls = p.editorScroller.calls.length;
  const paint = h.archivedTimers.get(p.editorPreviewTimerId);
  // Time advances between paint callbacks. Stop must sample before its audio
  // cleanup destroys the engine snapshot, rather than freezing the prior paint.
  h.setSnapshot({ mainPlayheadMs: 1162.5 });
  await p.toggleEditorPreview();
  assert.ok(Math.abs(p.editorPlayheadStep - 9.3) < 1e-9,
    'Stop must retain the precise current transport position without waiting for a paint tick');
  assert.equal(p.previewTarget, '');
  assert.equal(h.timers.size, 0);
  assert.equal(p.editorScroller.offset, offset, 'Stopping must retain the current scroll offset');
  assert.equal(p.editorScroller.calls.length, scrollCalls, 'Capturing a stopped position must not turn the page');
  const frozenStep = p.editorPlayheadStep;
  paint.callback();
  p.updateEditorPreviewProgress();
  h.tick({ mainPlayheadMs: 1500 });
  assert.equal(p.editorPlayheadStep, frozenStep, 'Queued paints and new engine snapshots cannot alter the stopped cursor');
  p.editorScroller.offset = CELL_WIDTH;
  p.updateEditorViewport(4 * CELL_WIDTH);
  p.toggleStep(0, 3);
  paint.callback();
  assert.equal(p.editorPlayheadStep, frozenStep, 'Draft edits while stopped must keep the retained cursor');
  assert.equal(p.editorScroller.offset, CELL_WIDTH,
    'Stopped editors must allow manual scrolling and viewport changes without following the old cursor');
  assert.equal(h.calls.length, 1, 'Stopped draft edits must not restart the audio');

  await p.toggleEditorPreview();
  assert.equal(p.editorPlayheadStep, frozenStep, 'A resumed audition must keep its start cursor through preparation');
  assert.ok(Math.abs(h.calls.at(-1).positionBeats - frozenStep / 4) < 1e-9,
    'Audition must forward the retained fractional cursor as its playback origin');
  assert.equal(h.timers.size, 1);
  h.tick({ mainPlayheadMs: -350 });
  h.tick({ countIn: true, mainPlayheadMs: 500 });
  assert.equal(p.editorPlayheadStep, frozenStep, 'Preroll and count-in must not move or hide the retained start cursor');
  h.setSnapshot({ mainPlayheadMs: 1250 });
  paint.callback();
  assert.equal(p.editorPlayheadStep, frozenStep, 'A queued paint from a superseded audition cannot paint the new transport');
  h.tick({ mainPlayheadMs: 1250 });
  assert.equal(p.editorPlayheadStep, 10, 'The resumed cursor must advance from the engine sought position');
  h.setSnapshot({ mainPlayheadMs: 2012.5 });
  const beforeLoopStop = p.editorScroller.calls.length;
  await p.toggleEditorPreview();
  assert.ok(Math.abs(p.editorPlayheadStep - 0.1) < 1e-9, 'Stop must capture a loop boundary from the live transport');
  assert.equal(p.editorScroller.offset, 0, 'A loop boundary captured on Stop must reveal the exact final cursor once');
  assert.equal(p.editorScroller.calls.length, beforeLoopStop + 1);

  const boundary = harness();
  boundary.page.openEditor(0, 1);
  boundary.page.updateEditorViewport(6 * CELL_WIDTH + PLAYHEAD_WIDTH);
  await boundary.page.toggleEditorPreview();
  boundary.tick({ mainPlayheadMs: 737.5 });
  assert.equal(boundary.page.editorPlayheadStep, 5.9);
  assert.equal(boundary.page.editorScroller.offset, 0);
  const beforeBoundaryStop = boundary.page.editorScroller.calls.length;
  boundary.setSnapshot({ mainPlayheadMs: 762.5 });
  await boundary.page.toggleEditorPreview();
  assert.equal(boundary.page.editorPlayheadStep, 6.1, 'Stop must preserve exact progress crossing a screen between paints');
  assert.equal(boundary.page.editorScroller.offset, 6 * CELL_WIDTH,
    'Stop must reveal a newly crossed screen once so the retained cursor is visible');
  assert.equal(boundary.page.editorScroller.calls.length, beforeBoundaryStop + 1);
  boundary.page.editorScroller.offset = 0;
  boundary.tick({ mainPlayheadMs: 1000 });
  assert.equal(boundary.page.editorScroller.offset, 0, 'After the final reveal stopped manual scrolling stays under user control');
  boundary.page.closeEditor();

  const resetActions = [
    q => q.closeEditor(),
    q => assert.equal(q.onBackPress(), true),
    q => q.saveEditor(),
    q => q.aboutToDisappear(),
    q => q.openEditor(0, 0)
  ];
  for (const reset of resetActions) {
    const next = harness();
    next.page.openEditor(0, 1);
    await next.page.toggleEditorPreview();
    next.tick({ mainPlayheadMs: 750 });
    await next.page.toggleEditorPreview();
    assert.equal(next.page.editorPlayheadStep, 6);
    reset(next.page);
    assert.equal(next.page.editorPlayheadStep, -1, 'Leaving, applying or opening a new draft must clear the stopped cursor');
    assert.equal(next.page.previewTarget, '');
    assert.equal(next.timers.size, 0);
    for (const timer of next.archivedTimers.values()) timer.callback();
    assert.equal(next.page.editorPlayheadStep, -1);
  }

  for (const fail of [false, true]) {
    const pending = harness();
    pending.page.openEditor(0, 0);
    const preparation = deferred();
    pending.responses.push(preparation);
    const start = pending.page.toggleEditorPreview();
    pending.setSnapshot({ mainPlayheadMs: 1000 });
    await pending.page.toggleEditorPreview();
    assert.equal(pending.page.editorPlayheadStep, -1,
      'Stopping pending preparation cannot invent a cursor from an unrelated engine snapshot');
    assert.equal(pending.timers.size, 0);
    if (fail) preparation.reject(new Error('Stopped before preparation finished'));
    else preparation.resolve();
    await start;
    assert.equal(pending.page.previewTarget, '');
    assert.equal(pending.page.editorPlayheadStep, -1);
    assert.equal(pending.timers.size, 0);
    assert.deepEqual(pending.toasts, []);
    await pending.page.toggleEditorPreview();
    await pending.page.toggleEditorPreview();
    assert.equal(pending.page.editorPlayheadStep, -1, 'Stopping the scheduled warm-up cannot invent a played step');
    assert.equal(pending.timers.size, 0);
  }

  for (const staleFails of [false, true]) {
    const resumed = harness();
    resumed.page.openEditor(0, 1);
    await resumed.page.toggleEditorPreview();
    resumed.tick({ mainPlayheadMs: 750 });
    await resumed.page.toggleEditorPreview();
    const stalePreparation = deferred();
    resumed.responses.push(stalePreparation);
    const staleStart = resumed.page.toggleEditorPreview();
    assert.equal(resumed.page.editorPlayheadStep, 6);
    resumed.setSnapshot({ mainPlayheadMs: 1500 });
    await resumed.page.toggleEditorPreview();
    assert.equal(resumed.page.editorPlayheadStep, 6,
      'Stopping a pending resume cannot advance its retained start cursor');
    await resumed.page.toggleEditorPreview();
    assert.equal(resumed.calls.at(-1).positionBeats, 1.5);
    resumed.tick({ mainPlayheadMs: 1000 });
    const currentTimer = resumed.page.editorPreviewTimerId;
    if (staleFails) stalePreparation.reject(new Error('Superseded resumed preparation'));
    else stalePreparation.resolve();
    await staleStart;
    assert.equal(resumed.page.previewTarget, 'editor');
    assert.equal(resumed.page.editorPlayheadStep, 8, 'A superseded resume cannot move the current cursor');
    assert.equal(resumed.page.editorPreviewTimerId, currentTimer);
    assert.equal(resumed.timers.size, 1);
    assert.deepEqual(resumed.toasts, []);
    resumed.page.closeEditor();
  }

  const failedRetry = harness();
  failedRetry.page.openEditor(0, 0);
  await failedRetry.page.toggleEditorPreview();
  failedRetry.tick({ mainPlayheadMs: 750 });
  await failedRetry.page.toggleEditorPreview();
  const failedPreparation = deferred();
  failedRetry.responses.push(failedPreparation);
  const retry = failedRetry.page.toggleEditorPreview();
  failedPreparation.reject(new Error('Retry unavailable'));
  await retry;
  assert.equal(failedRetry.page.editorPlayheadStep, 6, 'A failed retry must keep the chosen start cursor available for another attempt');
  assert.equal(failedRetry.calls.at(-1).positionBeats, 1.5);
  assert.equal(failedRetry.page.previewTarget, '');
  assert.equal(failedRetry.timers.size, 0);
  assert.deepEqual(failedRetry.toasts, ['试听启动失败']);
  await failedRetry.page.toggleEditorPreview();
  assert.equal(failedRetry.calls.at(-1).positionBeats, 1.5, 'A retry after failure must use the same retained start position');
  failedRetry.page.closeEditor();
}

async function testCursorSeeking() {
  for (const mode of [0, 1]) {
    const h = harness();
    const p = h.page;
    p.openEditor(0, mode);
    p.updateEditorViewport(6 * CELL_WIDTH + PLAYHEAD_WIDTH);
    const saved = plain(p.sections);
    const draft = plain(p.editorEvents);
    const stoppedAudioCalls = h.stopCount();
    p.seekEditorStep(12);
    assert.equal(p.editorPlayheadStep, 12);
    assert.equal(p.editorScroller.offset, p.editorGridWidth() - (6 * CELL_WIDTH + PLAYHEAD_WIDTH),
      'A stopped seek must reveal the chosen cursor once');
    assert.equal(h.calls.length, 0, 'Choosing a cursor while stopped must not start playback');
    assert.equal(h.stopCount(), stoppedAudioCalls, 'Choosing a cursor while stopped must not touch audio');
    p.editorScroller.offset = 0;
    p.updateEditorViewport(6 * CELL_WIDTH + PLAYHEAD_WIDTH);
    h.tick({ mainPlayheadMs: 1000 });
    assert.equal(p.editorPlayheadStep, 12);
    assert.equal(p.editorScroller.offset, 0, 'After a stopped seek, manual scrolling must remain available');
    const invalid = [-1, p.editorStepCount(), 1.25, NaN, Infinity, -Infinity];
    for (const step of invalid) p.seekEditorStep(step);
    assert.equal(p.editorPlayheadStep, 12, 'Out-of-range or noninteger seek values must be ignored');
    assert.equal(h.calls.length, 0);
    assert.equal(h.timers.size, 0);
    p.seekEditorStep(2);
    await p.toggleEditorPreview();
    assert.equal(h.calls.at(-1).positionBeats, 0.5, 'The next audition must use the stopped seek position');
    assert.equal(p.editorPlayheadStep, 2);
    h.tick({ mainPlayheadMs: 312.5 });
    assert.equal(p.editorPlayheadStep, 2.5);
    h.setSnapshot({ mainPlayheadMs: 875 });
    p.seekEditorStep(10);
    assert.equal(p.editorPlayheadStep, 10,
      'An explicit playing seek must replace the old clock position rather than sampling it over the chosen target');
    assert.equal(h.calls.at(-1).positionBeats, 2.5, 'A playing seek must immediately request audio from the new cursor');
    await settle();
    assert.equal(h.timers.size, 1);
    const callCount = h.calls.length;
    const activeTimer = p.editorPreviewTimerId;
    for (const step of invalid) p.seekEditorStep(step);
    assert.equal(h.calls.length, callCount, 'Invalid seeks must not restart an active audition');
    assert.equal(p.editorPreviewTimerId, activeTimer);
    h.tick({ mainPlayheadMs: 1300 });
    assert.equal(p.editorPlayheadStep, 10.4, 'The sought audition must advance from the new engine clock');
    await p.toggleEditorPreview();
    p.seekEditorStep(15);
    assert.equal(h.calls.length, callCount, 'Moving the stopped cursor remains silent after a prior audition');
    await p.toggleEditorPreview();
    assert.equal(h.calls.at(-1).positionBeats, 3.75);
    assert.deepEqual(plain(p.sections), saved, 'Seeking must not apply or alter a saved section');
    assert.deepEqual(plain(p.editorEvents), draft, 'Seeking must not toggle any draft drum cells');
    p.closeEditor();
    const closedCalls = h.calls.length;
    p.seekEditorStep(3);
    assert.equal(p.editorPlayheadStep, -1, 'A hidden editor cannot retain a seek for the next draft');
    assert.equal(h.calls.length, closedCalls);
  }

  const compound = harness();
  compound.page.beatsPerBar = 7;
  compound.page.beatUnit = 8;
  compound.page.openEditor(0, 1);
  compound.page.seekEditorStep(9);
  await compound.page.toggleEditorPreview();
  assert.equal(compound.calls.at(-1).positionBeats, 2.25, 'A numbered seek must honor the current per-beat grid in any meter');
  compound.page.closeEditor();

  const failedSeek = harness();
  failedSeek.page.openEditor(0, 1);
  await failedSeek.page.toggleEditorPreview();
  failedSeek.tick({ mainPlayheadMs: 250 });
  const failedPreparation = deferred();
  failedSeek.responses.push(failedPreparation);
  failedSeek.page.seekEditorStep(7);
  failedPreparation.reject(new Error('Seek renderer unavailable'));
  await settle();
  assert.equal(failedSeek.page.previewTarget, '');
  assert.equal(failedSeek.page.editorPlayheadStep, 7, 'A failed seek must retain its chosen cursor for retry');
  assert.equal(failedSeek.timers.size, 0);
  assert.deepEqual(failedSeek.toasts, ['试听启动失败']);
  await failedSeek.page.toggleEditorPreview();
  assert.equal(failedSeek.calls.at(-1).positionBeats, 1.75, 'Retry after a failed seek must start at the chosen cursor');
  failedSeek.page.closeEditor();

  for (const staleFails of [false, true]) {
    const h = harness();
    const p = h.page;
    p.openEditor(0, 1);
    await p.toggleEditorPreview();
    h.tick({ mainPlayheadMs: 250 });
    const oldPaint = h.archivedTimers.get(p.editorPreviewTimerId);
    const old = deferred();
    const fresh = deferred();
    h.responses.push(old, fresh);
    p.seekEditorStep(4);
    p.seekEditorStep(12);
    assert.equal(p.editorPlayheadStep, 12, 'A seek during pending preparation must immediately replace its target');
    assert.deepEqual(h.calls.slice(-2).map(call => call.positionBeats), [1, 3]);
    fresh.resolve();
    await settle();
    const currentTimer = p.editorPreviewTimerId;
    if (staleFails) old.reject(new Error('Superseded numbered seek'));
    else old.resolve();
    await settle();
    h.setSnapshot({ mainPlayheadMs: 500 });
    oldPaint.callback();
    assert.equal(p.editorPlayheadStep, 12, 'A stale seek or paint cannot restore an earlier cursor');
    assert.equal(p.previewTarget, 'editor');
    assert.equal(p.editorPreviewTimerId, currentTimer);
    assert.equal(h.timers.size, 1, 'Several rapid seeks must leave only the current paint timer');
    assert.deepEqual(h.toasts, [], 'A superseded seek failure must remain silent');
    p.closeEditor();
  }
}

async function testSupersededArrangementPreview() {
  const previousAuditions = [
    { name: 'song start', start: p => p.previewProgram(p.currentProgram(), 'song') },
    { name: 'pattern start', start: p => p.previewSection(0, false) },
    { name: 'fill start', start: p => p.previewSection(0, true) },
    { name: 'song restart', start: p => { p.previewTarget = 'song'; return p.restartSongPreview(); } },
    { name: 'pattern restart', start: p => {
      p.previewTarget = 'pattern-0';
      return p.restartSectionPreview(0, false, p.sections[0]);
    } },
    { name: 'fill restart', start: p => {
      p.previewTarget = 'fill-0';
      return p.restartSectionPreview(0, true, p.sections[0]);
    } }
  ];
  for (const previous of previousAuditions) {
    for (const fail of [false, true]) {
      const h = harness();
      const old = deferred();
      h.responses.push(old);
      const oldStart = previous.start(h.page);
      assert.notEqual(h.page.previewTarget, '');
      assert.equal(h.calls[0].positionBeats, 0, `${previous.name} must retain its normal start-from-zero behavior`);
      h.page.openEditor(0, 1);
      await h.page.toggleEditorPreview();
      const currentTimer = h.page.editorPreviewTimerId;
      assert.equal(h.calls.length, 2);
      assert.equal(h.timers.size, 1);
      if (fail) old.reject(new Error(`${previous.name} superseded`));
      else old.resolve();
      await oldStart;
      assert.equal(h.page.previewTarget, 'editor', `${previous.name} must not clear the new grid audition`);
      assert.equal(h.page.editorPreviewTimerId, currentTimer);
      assert.equal(h.timers.size, 1, `${previous.name} must not add a stale section stop timer`);
      assert.deepEqual(h.toasts, [], `${previous.name} must not show a stale failure toast`);
      h.tick({ mainPlayheadMs: 625 });
      assert.equal(h.page.editorPlayheadStep, 5, `${previous.name} must leave the new cursor active`);
      h.page.aboutToDisappear();
    }
  }
}

async function testTransportAndScrolling() {
  const h = harness();
  const p = h.page;
  p.openEditor(0, 1);
  const firstViewport = 10 * CELL_WIDTH + PLAYHEAD_WIDTH;
  const lastPageOffset = p.editorGridWidth() - firstViewport;
  p.updateEditorViewport(firstViewport);
  await p.toggleEditorPreview();
  for (const unavailable of [
    { running: false, mainPlayheadMs: 500 },
    { countIn: true, mainPlayheadMs: 500 },
    { mainPlayheadMs: -1 }
  ]) {
    h.tick(unavailable);
    assert.equal(p.editorPlayheadStep, -1, 'Stopped, count-in and predeadline snapshots have no active step');
  }
  h.tick({ mainPlayheadMs: 0 });
  assert.equal(p.editorPlayheadStep, 0);
  assert.equal(p.editorScroller.offset, 0);
  h.tick({ mainPlayheadMs: 1187.5 });
  assert.equal(p.editorPlayheadStep, 9.5);
  assert.equal(p.editorPlayheadX(), 9.5 * CELL_WIDTH, 'The cursor should advance smoothly inside the active step');
  assert.equal(p.editorScroller.offset, 0, 'A wholly visible final cell must not turn the page early');
  h.tick({ mainPlayheadMs: 1250 });
  assert.equal(p.editorPlayheadStep, 10);
  assert.equal(p.editorScroller.offset, lastPageOffset, 'Reaching the next screen must scroll, clamped to the grid end');
  assert.equal(p.editorScroller.calls.at(-1).animation, false, 'A page turn must keep pace with audio');
  h.tick({ mainPlayheadMs: 1999.5 });
  assert.equal(p.editorScroller.offset, lastPageOffset);
  assert.ok(p.editorPlayheadX() <= p.editorGridWidth() - PLAYHEAD_WIDTH, 'The final progress line must fit inside the grid');
  const lastStepScrollCount = p.editorScroller.calls.length;
  h.tick({ mainPlayheadMs: 1999.9 });
  assert.equal(p.editorScroller.calls.length, lastStepScrollCount,
    'The grid edge must not cause repeated scroll requests during the final step');
  h.tick({ mainPlayheadMs: 2000 });
  assert.equal(p.editorPlayheadStep, 0);
  assert.equal(p.editorScroller.offset, 0, 'The next loop must return to the first screen');

  p.updateEditorViewport(10 * CELL_WIDTH);
  h.tick({ mainPlayheadMs: 1187.5 });
  assert.equal(p.editorScroller.offset, 6 * CELL_WIDTH, 'The cursor stroke needs room beyond the last full cell of a screen');

  h.tick({ mainPlayheadMs: 875 });
  assert.equal(p.editorPlayheadStep, 7);
  p.editorScroller.offset = 0;
  p.updateEditorViewport(6 * CELL_WIDTH);
  const stepVisible = () => {
    const left = Math.floor(p.editorPlayheadStep) * CELL_WIDTH;
    assert.ok(left >= p.editorScroller.offset && left + CELL_WIDTH + PLAYHEAD_WIDTH <= p.editorScroller.offset + 6 * CELL_WIDTH,
      'The full active cell and cursor stroke must fit inside the viewport');
  };
  assert.notEqual(p.editorScroller.offset, 0, 'Shrinking the viewport must reveal the full current step immediately');
  stepVisible();
  p.editorScroller.offset = 10 * CELL_WIDTH;
  h.tick({ mainPlayheadMs: 900 });
  stepVisible();
  p.editorScroller.offset = 7 * CELL_WIDTH;
  const scrollCount = p.editorScroller.calls.length;
  h.tick({ mainPlayheadMs: 905 });
  assert.equal(p.editorScroller.calls.length, scrollCount, 'A manually positioned visible step should remain stable');
  p.updateEditorViewport(1000);
  assert.equal(p.editorScroller.offset, 0, 'A viewport wider than the pattern must clamp to its first screen');

  p.beatsPerBar = 7;
  p.beatUnit = 8;
  p.bpm = 90;
  assert.equal(p.editorStepCount(), 28);
  h.tick({ mainPlayheadMs: 1000 });
  assert.equal(p.editorPlayheadStep, 6, 'A meter change must keep the chosen four-way per-beat grid');
  h.tick({ mainPlayheadMs: 7 * 60000 / 90 + 500 });
  assert.ok(Math.abs(p.editorPlayheadStep - 3) < 1e-9, 'The cursor must wrap after the selected meter, not a fixed four beats');
  await p.toggleEditorPreview();
  await p.toggleEditorPreview();
  assert.ok(Math.abs(h.calls.at(-1).positionBeats - 0.75) < 1e-9,
    'Resuming compound meter must convert grid steps using the selected beat unit');
  p.aboutToDisappear();
}

async function testSubdivisionDraftsAndSnapping() {
  const event = (tick, sampleKey = 'snare', velocity = 0.37) => ({ tick, sampleKey, velocity });
  const seed = { subdivision: 4, events: [event(0, 'kick', 0.81), event(120, 'snare', 0.32),
    event(240, 'hat_closed', 0.64), event(360, 'snare', 0.51), event(400, 'perc', 0.68), event(1900, 'tom_low', 0.75)] };
  const h = harness();
  const p = h.page;
  p.sections[0].customPattern = plain(seed);
  const saved = plain(p.sections);
  const contexts = plain(p.contextStates);
  p.openEditor(0, 0);
  p.seekEditorStep(5);
  for (const division of [3, 6, 4]) {
    p.chooseEditorSubdivision(division);
    assert.equal(p.editorSubdivision, division);
    assert.equal(p.editorStepCount(), 4 * division);
    assert.equal(p.editorPlayheadBeats, 1.25, 'Switching grids must keep the same chosen musical time');
    assert.equal(p.editorPlayheadStep, 1.25 * division);
    assert.deepEqual(plain(p.editorEvents), seed.events, 'Switching grids must not quantize notes or rewrite their velocities');
    assert.deepEqual(plain(p.sections), saved, 'A grid switch is an unsaved draft action');
    assert.deepEqual(plain(p.contextStates), contexts, 'A grid switch cannot commit the context cache');
    assert.deepEqual(h.storageWrites, [], 'A grid switch cannot persist the arrangement');
  }
  for (const invalid of [2, 5, 8, 0, -1, NaN, Infinity]) p.chooseEditorSubdivision(invalid);
  assert.equal(p.editorSubdivision, 4);
  assert.equal(h.calls.length, 0);
  await p.toggleEditorPreview();
  const beforeSwitch = h.calls.length;
  const stopCount = h.stopCount();
  const timer = p.editorPreviewTimerId;
  h.setSnapshot({ mainPlayheadMs: 812.5 });
  p.chooseEditorSubdivision(3);
  assert.equal(p.editorPlayheadBeats, 1.625, 'A playing grid switch must capture the latest transport position');
  assert.equal(p.editorPlayheadStep, 4.875);
  assert.equal(h.calls.length, beforeSwitch, 'A display-only grid switch cannot restart sounding events');
  assert.equal(h.stopCount(), stopCount);
  assert.equal(p.editorPreviewTimerId, timer, 'A grid switch must keep the current paint lifecycle');
  h.tick({ mainPlayheadMs: 1000 });
  assert.equal(p.editorPlayheadStep, 6);
  await p.toggleEditorPreview();
  p.chooseEditorSubdivision(6);
  assert.equal(p.editorPlayheadBeats, 2);
  assert.equal(p.editorPlayheadStep, 12, 'A stopped cursor must stay visible at the same beat on the new grid');
  await p.toggleEditorPreview();
  assert.equal(h.calls.at(-1).positionBeats, 2, 'Audition resumes from the canonical beat instead of reinterpreting an old step number');
  p.closeEditor();
  assert.deepEqual(plain(p.sections), saved, 'Closing after grid changes discards every draft change');
  p.openEditor(0, 0);
  assert.equal(p.editorSubdivision, 4, 'Reopening a discarded draft restores the saved grid');
  assert.notEqual(p.editorEvents[0], p.sections[0].customPattern.events[0]);
  p.chooseEditorSubdivision(3);
  p.saveEditor();
  assert.equal(p.sections[0].customPattern.subdivision, 3, 'Only Apply stores the draft subdivision');
  assert.deepEqual(plain(p.sections[0].customPattern.events), seed.events);
  assert.equal(p.sections[0].customRows, undefined, 'Applying event data retires the corresponding legacy rows');
  assert.equal(h.storageWrites.some(([key]) => key === 'myDrumProgram'), false,
    'Applying the editor updates the arrangement draft; the main Save/Apply action still owns global persistence');
  p.openEditor(0, 0);
  assert.equal(p.editorSubdivision, 3);
  p.closeEditor();

  const snapping = harness();
  const q = snapping.page;
  q.sections[0].customPattern = { subdivision: 3, events: [
    event(80, 'snare', 0.35), event(0, 'snare', 0.6), event(100, 'snare', 0.9),
    event(240, 'snare', 0.4), event(1900, 'snare', 0.7), event(240, 'kick', 0.88),
    event(321, 'perc', 0.5), event(320, 'hat_closed', 0.41)
  ] };
  const savedBeforeSnap = plain(q.sections);
  q.openEditor(0, 0);
  assert.equal(q.editorOffGridCount(), 6);
  const untouched = plain(q.editorEvents.filter(e => e.tick !== 80 && !(e.sampleKey === 'snare' && e.tick === 0)));
  q.snapEditorEventToGrid(1, 80);
  assert.equal(q.editorOffGridCount(), 5, 'Clicking one diamond must snap that note instead of deleting it');
  const first = q.editorEvents.filter(e => e.sampleKey === 'snare' && e.tick === 0);
  assert.equal(first.length, 1, 'Snapping onto an existing note must produce one audible trigger');
  assert.equal(first[0].velocity, 0.6, 'A snap collision keeps the louder velocity');
  assert.deepEqual(plain(q.editorEvents.filter(e => !(e.sampleKey === 'snare' && e.tick === 0))), untouched,
    'Clicking one diamond must not quantize or reorder any other note');
  assert.equal(q.editorCellEnabled(1, 0), true, 'The nearest destination cell must light immediately');
  q.snapAllEditorOffGridEvents();
  assert.equal(q.editorOffGridCount(), 0, 'The bulk nearest action must remove every diamond by placing the notes on cells');
  const sorted = plain(q.editorEvents).sort((a, b) => a.tick - b.tick || a.sampleKey.localeCompare(b.sampleKey));
  assert.deepEqual(sorted, [event(0, 'snare', 0.6), event(160, 'kick', 0.88), event(160, 'snare', 0.9),
    event(320, 'hat_closed', 0.41), event(320, 'perc', 0.5), event(1760, 'snare', 0.7)],
    'Nearest snapping must choose earlier midpoint ties, clamp at the last cell and merge only same-instrument collisions');
  for (const [track, step] of [[1, 0], [1, 1], [1, 11], [0, 1], [8, 2], [2, 2]]) {
    assert.equal(q.editorCellEnabled(track, step), true);
  }
  assert.equal(snapping.calls.length, 0, 'Snapping a stopped draft stays silent');
  assert.deepEqual(plain(q.sections), savedBeforeSnap, 'Nearest actions are draft edits until Apply');
  q.closeEditor();
  assert.deepEqual(plain(q.sections), savedBeforeSnap);

  const playing = harness();
  playing.page.sections[0].customPattern = { subdivision: 3, events: [event(120, 'snare', 0.31), event(360, 'perc', 0.47)] };
  playing.page.openEditor(0, 0);
  await playing.page.toggleEditorPreview();
  playing.setSnapshot({ mainPlayheadMs: 675 });
  playing.page.snapEditorEventToGrid(1, 120);
  await settle();
  assert.equal(playing.calls.length, 2);
  assert.equal(playing.calls.at(-1).positionBeats, 1.35, 'A playing diamond snap must audition the revised draft from the latest cursor');
  playing.setSnapshot({ mainPlayheadMs: 800 });
  playing.page.snapAllEditorOffGridEvents();
  await settle();
  assert.equal(playing.calls.length, 3);
  assert.equal(playing.calls.at(-1).positionBeats, 1.6);
  const noOpCalls = playing.calls.length;
  playing.page.snapAllEditorOffGridEvents();
  playing.page.snapEditorEventToGrid(1, 160);
  assert.equal(playing.calls.length, noOpCalls, 'No-op snapping must not restart audition');
  playing.page.closeEditor();

  for (const mode of [0, 1]) {
    const migration = harness();
    const page = migration.page;
    page.beatsPerBar = 6;
    page.beatUnit = 8;
    const rows = Array.from({ length: 8 }, (_, track) => track === 0 ? '010000000001' : '000000000000');
    page.sections[0].customRows = rows.slice();
    page.sections[0].customFillRows = rows.slice();
    page.openEditor(0, mode);
    assert.deepEqual(plain(page.editorEvents), [event(240, 'kick', 0.78), event(2640, 'kick', 0.78)],
      'Legacy 6/8 rows must retain half-beat timing when opened on the new four-way view');
    assert.equal(page.editorStepCount(), 24);
    page.chooseEditorSubdivision(6);
    page.saveEditor();
    const applied = mode === 0 ? page.sections[0].customPattern : page.sections[0].customFill;
    assert.equal(applied.subdivision, 6);
    assert.deepEqual(plain(applied.events), [event(240, 'kick', 0.78), event(2640, 'kick', 0.78)]);
    assert.deepEqual(plain(mode === 0 ? page.sections[0].customFillRows : page.sections[0].customRows), rows,
      'Applying one mode must preserve the other mode including unmigrated legacy data');
  }

  const nearGrid = harness();
  nearGrid.page.sections[0].customPattern = { subdivision: 4, events: [event(120.0000001, 'snare', 0.51)] };
  nearGrid.page.openEditor(0, 0);
  assert.equal(nearGrid.page.editorCellEnabled(1, 1), true);
  nearGrid.page.toggleStep(1, 1);
  assert.deepEqual(plain(nearGrid.page.editorEvents), [],
    'An event projected into a lit cell must toggle off even when its stored tick has insignificant floating-point error');
  nearGrid.page.editorEvents = [event(120, 'snare', 0)];
  nearGrid.page.refreshEditorGridProjection();
  assert.equal(nearGrid.page.editorCellEnabled(1, 1), false);
  nearGrid.page.toggleStep(1, 1);
  assert.deepEqual(plain(nearGrid.page.editorEvents), [event(120, 'snare', 0.78)],
    'Clicking an empty zero-velocity cell must add an audible note without leaving a duplicate silent event');
  nearGrid.page.editorEvents = [event(120.0000001, 'snare', 0.81), event(100, 'snare', 0.6),
    event(480, 'kick', 0.4), event(480, 'kick', 0.5)];
  nearGrid.page.refreshEditorGridProjection();
  nearGrid.page.snapEditorEventToGrid(1, 100);
  assert.deepEqual(plain(nearGrid.page.editorEvents), [event(120, 'snare', 0.81), event(480, 'kick', 0.4), event(480, 'kick', 0.5)],
    'A snapped destination merges near-grid notes by the same visible cell, while unrelated note records stay intact');
  nearGrid.page.closeEditor();

  const expandedKit = harness();
  expandedKit.page.sections[0].customPattern = { subdivision: 4, events: [] };
  expandedKit.page.openEditor(0, 0);
  for (let track = 0; track < catalog.DRUM_TRACKS.length; track++) {
    expandedKit.page.toggleStep(track, 1);
    assert.deepEqual(plain(expandedKit.page.editorEvents), [event(120, catalog.DRUM_TRACKS[track].key, 0.78)],
      'Every visible track, including inserted ride and appended shaker, must edit its own instrument key');
    assert.equal(expandedKit.page.editorCellEnabled(track, 1), true);
    expandedKit.page.toggleStep(track, 1);
    assert.deepEqual(plain(expandedKit.page.editorEvents), []);
  }
  expandedKit.page.toggleStep(4, 2);
  expandedKit.page.toggleStep(9, 3);
  expandedKit.page.saveEditor();
  assert.deepEqual(plain(expandedKit.page.sections[0].customPattern.events),
    [event(240, 'ride', 0.78), event(360, 'shaker', 0.78)],
    'Applying the editor must save both new voice keys in the event schema');
  expandedKit.page.openEditor(0, 0);
  assert.equal(expandedKit.page.editorCellEnabled(4, 2), true);
  assert.equal(expandedKit.page.editorCellEnabled(9, 3), true);
  expandedKit.page.closeEditor();

  for (const division of [3, 6]) {
    const triplet = harness();
    const page = triplet.page;
    page.openEditor(0, 0);
    page.chooseEditorSubdivision(division);
    page.seekEditorStep(division + 1);
    await page.toggleEditorPreview();
    assert.equal(triplet.calls.at(-1).positionBeats, (division + 1) / division);
    triplet.tick({ mainPlayheadMs: 625 });
    assert.equal(page.editorPlayheadStep, 1.25 * division);
    triplet.setSnapshot({ mainPlayheadMs: 687.5 });
    await page.toggleEditorPreview();
    assert.equal(page.editorPlayheadBeats, 1.375);
    await page.toggleEditorPreview();
    assert.equal(triplet.calls.at(-1).positionBeats, 1.375, 'Three- and six-way views retain exact fractional seek/resume');
    page.closeEditor();
  }
}

async function testBuiltInGridSelection() {
  const event = (tick, sampleKey = 'snare', velocity = 0.37) => ({ tick, sampleKey, velocity });
  const freshSection = (variant = 1, fill = 1) =>
    ({ id: 'A', patternIndex: variant, repeats: 4, fillIndex: fill, fillEvery: 4 });
  for (const [beats, unit] of [[4, 4], [3, 4], [6, 8], [12, 8]]) {
    const h = harness();
    const p = h.page;
    p.styleKey = 'trap';
    p.beatsPerBar = beats;
    p.beatUnit = unit;
    p.sections = [freshSection()];
    const sections = plain(p.sections);
    const contexts = plain(p.contextStates);
    const notes = plain(catalog.buildSectionPattern(p.currentProgram(), p.sections[0], false).events);
    p.openEditor(0, 0);
    assert.equal(p.editorSubdivision, 6, 'Trap triplet rolls open in six subdivisions, even when compound phrasing also fits four');
    assert.equal(p.editorOffGridCount(), 0, 'Every triplet-roll drum voice must appear as a lit cell rather than a diamond');
    assert.deepEqual(plain(p.editorEvents), notes, 'Choosing the opening grid cannot quantize or alter note dynamics');
    for (const note of notes) {
      const track = catalog.DRUM_TRACKS.findIndex(t => t.key === note.sampleKey);
      assert.equal(p.editorCellEnabled(track, Math.round(note.tick * 6 / 480)), true);
    }
    assert.deepEqual(plain(p.sections), sections);
    assert.deepEqual(plain(p.contextStates), contexts);
    assert.deepEqual(h.storageWrites, [], 'Automatically choosing a built-in view cannot save a section or context');
    assert.equal(h.calls.length, 0, 'Opening the correct grid cannot start audition');
    p.chooseEditorSubdivision(4);
    if (unit === 4) assert.ok(p.editorOffGridCount() > 0, 'A straight view must honestly expose triplet positions');
    p.chooseEditorSubdivision(6);
    assert.equal(p.editorOffGridCount(), 0);
    assert.deepEqual(plain(p.editorEvents), notes);
    p.closeEditor();
    p.openEditor(0, 0);
    assert.equal(p.editorSubdivision, 6);
    assert.deepEqual(plain(p.sections), sections, 'Opening, switching and closing a built-in remains an unsaved draft action');
    p.closeEditor();
  }

  for (const mode of [0, 1]) for (const subdivision of [4, 3, 6]) for (const notes of [[],
    [event(80, 'hat_closed', 0.32), event(120, 'kick', 0.77), event(320, 'snare', 0.63)]]) {
    const h = harness();
    const p = h.page;
    p.styleKey = 'trap';
    const section = freshSection();
    section[mode === 0 ? 'customPattern' : 'customFill'] = { subdivision, events: plain(notes) };
    section[mode === 0 ? 'customRows' : 'customFillRows'] = Array(8).fill('1111111111111111');
    p.sections = [section];
    const saved = plain(p.sections);
    p.openEditor(0, mode);
    assert.equal(p.editorSubdivision, subdivision, 'An explicitly saved grid always wins, including mixed or silent custom patterns');
    assert.deepEqual(plain(p.editorEvents), notes, 'Automatic view selection cannot reinterpret saved custom events or fall back to legacy rows');
    assert.deepEqual(plain(p.sections), saved);
    assert.deepEqual(h.storageWrites, []);
    p.closeEditor();
  }

  for (const style of ['trap', 'jazz']) for (const mode of [0, 1]) {
    const h = harness();
    const p = h.page;
    p.styleKey = style;
    p.beatsPerBar = 6;
    p.beatUnit = 8;
    const section = freshSection();
    section[mode === 0 ? 'customRows' : 'customFillRows'] =
      Array.from({ length: 8 }, (_, track) => track === 0 ? '010000000001' : '000000000000');
    p.sections = [section];
    const saved = plain(p.sections);
    p.openEditor(0, mode);
    assert.equal(p.editorSubdivision, 4, 'Legacy rows retain their four-way opening view despite a triplet preset name');
    assert.deepEqual(plain(p.editorEvents), [event(240, 'kick', 0.78), event(2640, 'kick', 0.78)],
      'The four-way projection must preserve the original denominator-dependent half-beat legacy timing');
    assert.deepEqual(plain(p.sections), saved);
    assert.deepEqual(h.storageWrites, []);
    p.closeEditor();
  }

  for (const mode of [0, 1]) {
    const h = harness();
    const p = h.page;
    p.styleKey = 'trap';
    p.sections = [{ ...freshSection(), customRows: [], customFillRows: [] }];
    const saved = plain(p.sections);
    p.openEditor(0, mode);
    assert.equal(p.editorSubdivision, 6, 'Empty legacy row arrays fall back to built-ins and cannot force a straight view');
    assert.equal(p.editorOffGridCount(), 0);
    assert.deepEqual(plain(p.sections), saved);
    assert.deepEqual(h.storageWrites, []);
    p.closeEditor();
  }

  for (const [style, variant, fill, mode, expected, expectedOffGrid = 0] of [
    ['rock', 0, 1, 0, 4], ['rock', 0, 1, 1, 4],
    ['jazz', 0, 0, 0, 3], ['jazz', 0, 0, 1, 3], ['jazz', 0, 1, 1, 6],
    ['trap', 0, 1, 0, 4], ['trap', 0, 1, 1, 6],
    ['trap', 1, 0, 1, 6], ['trap', 1, 2, 1, 6, 1]
  ]) {
    const h = harness();
    const p = h.page;
    p.styleKey = style;
    p.sections = [freshSection(variant, fill)];
    const notes = plain(catalog.buildSectionPattern(p.currentProgram(), p.sections[0], mode === 1).events);
    p.openEditor(0, mode);
    assert.equal(p.editorSubdivision, expected, 'The opening view must fit the actual opened main/fill phrase rather than just the style name');
    assert.equal(p.editorOffGridCount(), expectedOffGrid, 'A genuinely mixed phrase retains its unmatched notes rather than quantizing them on open');
    assert.deepEqual(plain(p.editorEvents), notes);
    assert.deepEqual(h.storageWrites, []);
    p.closeEditor();
  }

  const playing = harness();
  const p = playing.page;
  p.styleKey = 'trap';
  p.sections = [freshSection()];
  const saved = plain(p.sections);
  p.openEditor(0, 0);
  const notes = plain(p.editorEvents);
  p.seekEditorStep(7);
  await p.toggleEditorPreview();
  assert.equal(playing.calls.at(-1).positionBeats, 7 / 6);
  assert.deepEqual(playing.calls.at(-1).program.sections[0].customPattern.events, notes,
    'Triplet audition must use the original event positions and velocities');
  const callCount = playing.calls.length;
  playing.setSnapshot({ mainPlayheadMs: 812.5 });
  p.chooseEditorSubdivision(4);
  assert.equal(playing.calls.length, callCount, 'Switching the automatically selected grid still cannot restart audition');
  assert.equal(p.editorPlayheadBeats, 1.625);
  assert.deepEqual(plain(p.editorEvents), notes);
  assert.deepEqual(plain(p.sections), saved);
  assert.deepEqual(playing.storageWrites, []);
  p.closeEditor();
}

async function main() {
  await testSongSectionProgress();
  await testSongPhraseProgress();
  await testSongSectionProgressRaces();
  await testSongSectionPlaybackOwnership();
  await testWholeSongLiveUpdateQueue();
  await testLiveUpdateFailureAndCancellation();
  await testLiveUpdateNoticeOwnership();
  await testLocalSaveAndEditingFeedback();
  await testTeamApplyFeedbackOwnership();
  await testDeferredInitialSongUpdate();
  await testSongHighlightPresentationDeadlines();
  await testSongEditDuringPresentationRecoveryGap();
  await testIndependentSectionExpansion();
  await testSectionExpansionStructure();
  await testSectionCollapsePreservesPlayback();
  await testSongBehindEditor();
  await testSongToEditorHandoff();
  await testPendingSongSurvivesDraftNavigation();
  await testBuiltInGridSelection();
  await testSubdivisionDraftsAndSnapping();
  await testDraftsAndLifecycle();
  await testStartRaces();
  await testStoppedCursor();
  await testCursorSeeking();
  await testSupersededArrangementPreview();
  await testTransportAndScrolling();
  const sectionBuilder = source.slice(source.indexOf('  private sectionCard(index: number)'),
    source.indexOf('  private savedProgramCard('));
  assert.ok(sectionBuilder.includes('.onClick(() => this.toggleSectionExpanded(index))'),
    'Each manual card arrow must use the tested independent expansion action');
  assert.ok(sectionBuilder.includes('if (this.isSectionExpanded(index))'),
    'Card contents must follow their own expansion state');
  assert.ok(sectionBuilder.includes('.enabled(this.sections.length > 1)'),
    'The final remaining section must have a disabled delete control');
  assert.ok(source.includes('.enabled(this.sections.length < 8)'),
    'The eighth section must disable adding another section');
  assert.equal(sectionBuilder.includes('this.selectedSection === index'), false,
    'The editor-selected section must never control card visibility');
  assert.equal(sectionBuilder.includes('.onClick(() => this.selectedSection = index)'), false,
    'The card title must not select or fold the card');
  assert.match(source, /const DRUM_SECTION_PLAYING_COLOR: string = '#EDE4FA';/,
    'The playing card must use the requested light-purple palette');
  assert.ok(sectionBuilder.includes('this.playingSongSection === index') && sectionBuilder.includes('DRUM_SECTION_PLAYING_COLOR'),
    'Card background must react to the audible whole-song section independently of editor selection');
  for (const fill of [false, true]) {
    assert.ok(sectionBuilder.includes(`this.isSongPhrasePlaying(index, ${fill}) ? DRUM_PHRASE_PLAYING_COLOR : PAPER`),
      'Both phrase dropdowns must use the tested exclusive playback highlight');
  }
  const editorBuilder = source.slice(source.indexOf('  private editorOverlay()'), source.indexOf('\n  build()'));
  assert.equal((editorBuilder.match(/\.onClick\(\(\) => this\.closeEditor\(\)\)/g) ?? []).length, 1,
    'The top-right close button must use the tested audio cleanup path');
  assert.ok(editorBuilder.includes('this.toggleEditorPreview()'), 'The editor must expose its audition action');
  assert.ok(editorBuilder.includes('this.seekEditorStep(step)'), 'The numbered timeline must expose its tested cursor seek action');
  for (const action of ['this.chooseEditorSubdivision(subdivision)', 'this.snapAllEditorOffGridEvents()', 'this.snapEditorEventToGrid(trackIndex, event.tick)']) {
    assert.ok(editorBuilder.includes(action), `The editor must expose its tested grid action: ${action}`);
  }
  assert.match(editorBuilder, /Rect\(\)[\s\S]*?\.height\(this\.editorTracksHeight\(\)\)[\s\S]*?\.position\(\{ x: this\.editorPlayheadX\(\), y: DRUM_EDITOR_HEADER_HEIGHT \}\)[\s\S]*?\.hitTestBehavior\(HitTestMode\.None\)/,
    'The grid cursor must span the track viewport and let cell taps pass through it');
  assert.ok(editorBuilder.includes('Scroll(this.editorScroller)') && editorBuilder.includes('this.updateEditorViewport(Number(area.width))'),
    'The tested scroll controller and resize handler must be attached to the grid');
  console.log('PASS drum editor audition: exclusive main/fill dropdown highlight follows audible fill windows, transport-driven song card highlight, unequal-repeat boundaries and loops, frozen timing and stale visual races, independent manual card expansion, add/delete/load card state, fold preserves playback, continuous background song across draft navigation, explicit song-to-draft handoff, pending song ownership, unsaved events, subdivision switches and nearest snapping, startup races, numbered cursor seek, cursor resume, stop cursor capture, exit cleanup, transport cursor and viewport following');
}

module.exports = { harness, load, ets, meter, catalog, plain };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
