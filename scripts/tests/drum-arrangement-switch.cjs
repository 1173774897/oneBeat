// Executes actual session transactions and walking-page selection/ownership logic.
const assert = require('node:assert/strict');
const { load, ets, meter, catalog, plain, memoryDrumLibrary } = require('./drum-editor-preview.cjs');
async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const controllerStorage = new Map();
const { SessionController } = load(ets('session/SessionController.ets'), {
  '../common/Constants': { TRANSPORT_RESTART_PREROLL_MS: 650 },
  BuildProfile: { DEBUG: false },
  '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 1000 } },
  '../protocol/messages': { createMessage: (type, payload) => ({ type, payload }) },
  '../network/socket/SessionServer': { SessionServer: class {} },
  '../network/socket/SessionClient': { SessionClient: class {} },
  '../sync/ClockSync': { ClockSyncEstimator: class {} },
  '../network/p2p/P2pInvitation': {}, '../assets/AssetCatalog': {},
  '../assets/CharacterCatalog': { defaultSessionAvatar: () => 'test' },
  '../common/MeterModel': meter, '../audio/DrumMachineCatalog': catalog
}, { AppStorage: { get: key => controllerStorage.get(key), setOrCreate: (key, value) => controllerStorage.set(key, value) },
  console: { info() {}, warn() {} }, clearTimeout() {}, setTimeout: () => 1 });
function arrangement(style = 'rock', beats = 4, unit = 4) {
  const p = catalog.defaultDrumProgram();
  p.beatsPerBar = beats; p.beatUnit = unit;
  p.sections[0].styleKey = style;
  p.sections.push({ ...p.sections[0], id: 'B', styleKey: 'jazz', repeats: 2 });
  p.sections.push({ ...p.sections[0], id: 'C', styleKey: 'funk', repeats: 1 });
  return catalog.serializeDrumProgram(catalog.parseDrumProgram(catalog.serializeDrumProgram(p)));
}
function controllerHarness(state = 'playing') {
  const c = new SessionController('switch-test', false, 'test');
  c.isLeader = true; c.rhythm = 3; c.state = state; c.bpm = 137;
  c.drumProgram = arrangement(); c.beatsPerBar = 4; c.beatUnit = 4;
  c.beatPointStates = ['accent', 'silent', 'normal', 'normal'];
  c.rememberProDrumEditorSettings(4, 4, 137);
  c.scheduleRandomAvatarReveals = () => {};
  c.notifyUi = () => {};
  const trace = [];
  c.sendToAll = async wire => { trace.push(plain(wire)); };
  c.prepareConnectedMembersForTransport = async strict => {
    trace.push({ type: 'prepare', strict }); return 'ready';
  };
  return { c, trace };
}
async function sessionTransactions() {
  for (const state of ['idle', 'paused', 'playing', 'countdown']) {
    const { c, trace } = controllerHarness(state);
    c.drumProgramLibraryId = 'old-record';
    const target = arrangement('latin', 3, 8);
    assert.equal(await c.updateDrumArrangement(target, 'new-record'), true);
    assert.equal(c.drumProgramLibraryId, 'new-record');
    assert.ok(trace.every(wire => wire.payload?.drumProgramLibraryId === undefined),
      'Install-local identities cannot enter peer snapshots or transport messages');
    assert.deepEqual([c.bpm, c.beatsPerBar, c.beatUnit, c.drumProgram], [137, 3, 8, target]);
    assert.deepEqual(plain(c.getProDrumEditorSettings()), { beatsPerBar: 3, beatUnit: 8, bpm: 137 });
    const transports = trace.filter(x => x.type === 'TRANSPORT');
    const expectedStarts = ['playing', 'countdown'].includes(state) ? 1 : 0;
    assert.equal(transports.length, expectedStarts, 'Meter+program issue one shared restart, never two');
    if (expectedStarts) {
      const config = trace.findIndex(x => x.type === 'SESSION_SNAPSHOT');
      const preparation = trace.findIndex(x => x.type === 'prepare');
      assert.ok(config < preparation, 'Complete configuration reaches every device before clock preparation');
      assert.equal(trace[preparation].strict, true);
      assert.equal(transports[0].payload.startAtLeaderMonoMs, 1650);
      assert.equal(transports[0].payload.countInBeats, 0);
    } else assert.equal(c.state, state, 'Choosing in paused/idle does not begin playback');
    const beforeNoop = trace.length;
    assert.equal(await c.updateDrumArrangement(target), true);
    assert.equal(trace.length, beforeNoop, 'An already applied arrangement does not restart');
  }
  for (const result of ['failed', 'timeout', 'disconnected', 'cancelled']) {
    const { c, trace } = controllerHarness();
    c.drumProgramLibraryId = 'previous-record';
    const before = [c.drumProgram, c.rhythm, c.beatsPerBar, c.beatUnit, plain(c.beatPointStates), plain(c.getProDrumEditorSettings())];
    c.prepareConnectedMembersForTransport = async () => result;
    await assert.rejects(c.updateDrumArrangement(arrangement('latin', 3, 8), 'candidate-record'), /未切换/);
    assert.equal(c.drumProgramLibraryId, 'previous-record', 'Identity rolls back with the last playable content');
    assert.deepEqual([c.drumProgram, c.rhythm, c.beatsPerBar, c.beatUnit, plain(c.beatPointStates), plain(c.getProDrumEditorSettings())], before,
      'Failed preparation restores the previous playable program, meter, points and editor settings');
    assert.equal(c.bpm, 137);
    assert.equal(c.state, 'playing');
    assert.equal(trace.some(x => x.type === 'TRANSPORT'), false);
    assert.equal(trace.at(-1).payload.drumProgram, before[0], 'Rollback is broadcast to members');
  }
  {
    const { c, trace } = controllerHarness();
    const oldGate = deferred(), newGate = deferred();
    let requests = 0;
    c.prepareConnectedMembersForTransport = () => ++requests === 1 ? oldGate.promise : newGate.promise;
    const old = c.updateDrumArrangement(arrangement('latin', 3, 8)).catch(e => e);
    await flush();
    const target = arrangement('techno', 5, 4);
    const fresh = c.updateDrumArrangement(target);
    await flush();
    assert.equal(requests, 2);
    newGate.resolve('ready'); assert.equal(await fresh, true);
    oldGate.resolve('ready'); assert.match((await old).message, /取消/);
    assert.equal(c.drumProgram, target, 'A stale transaction cannot roll back the newest arrangement');
    assert.equal(trace.filter(x => x.type === 'TRANSPORT').length, 1);
  }
  {
    const { c, trace } = controllerHarness();
    const baseline = c.drumProgram;
    const oldGate = deferred(), newGate = deferred();
    let requests = 0;
    c.prepareConnectedMembersForTransport = () => ++requests === 1 ? oldGate.promise : newGate.promise;
    const firstTarget = arrangement('latin', 3, 8);
    const old = c.updateDrumArrangement(firstTarget).catch(e => e);
    await flush();
    assert.equal(await c.updateDrumArrangement(firstTarget), false,
      'The same pending target is not an already committed no-op success');
    assert.equal(requests, 1, 'Duplicate pending selection neither starts another preparation nor commits the candidate');
    const fresh = c.updateDrumArrangement(arrangement('techno', 5, 4)).catch(e => e);
    await flush();
    newGate.resolve('failed'); assert.match((await fresh).message, /未切换/);
    assert.equal(c.drumProgram, baseline, 'A then B failure restores the committed baseline, never uncommitted A');
    assert.equal(c.beatsPerBar, 4); assert.equal(c.state, 'playing');
    oldGate.resolve('ready'); assert.match((await old).message, /取消/);
    assert.equal(c.drumProgram, baseline);
    assert.equal(trace.filter(x => x.type === 'TRANSPORT').length, 0);
  }
  {
    const { c } = controllerHarness();
    const delivery = deferred();
    const committedA = arrangement('latin', 3, 8);
    c.sendToAll = async wire => { if (wire.type === 'TRANSPORT') await delivery.promise; };
    const first = c.updateDrumArrangement(committedA);
    await flush();
    assert.equal(c.drumArrangementBaseline, undefined, 'Publishing the shared future deadline commits the baseline immediately');
    c.prepareConnectedMembersForTransport = async () => 'failed';
    await assert.rejects(c.updateDrumArrangement(arrangement('techno', 5, 4)), /未切换/);
    assert.equal(c.drumProgram, committedA, 'A published while delivery was pending becomes the baseline of B');
    delivery.resolve(); assert.equal(await first, false, 'A superseded completion cannot report itself as the current request');
  }
  {
    const { c } = controllerHarness();
    let snapshots = 0;
    const before = c.drumProgram;
    c.sendToAll = async wire => {
      if (wire.type === 'SESSION_SNAPSHOT' && ++snapshots === 2) throw new Error('pre-publication send error');
    };
    await assert.rejects(c.updateDrumArrangement(arrangement('latin', 3, 8)), /pre-publication send error/);
    assert.equal(c.drumProgram, before);
    assert.equal(c.state, 'playing', 'A failed pre-publication snapshot restores the running UI state');
  }
  {
    const { c } = controllerHarness();
    const target = arrangement('latin', 3, 8);
    c.sendToAll = async wire => { if (wire.type === 'TRANSPORT') throw new Error('late send error'); };
    await assert.rejects(c.updateDrumArrangement(target, 'published-record'), /late send error/);
    assert.equal(c.drumProgram, target, 'Once a shared deadline is emitted, a send error cannot undo its configuration');
    assert.equal(c.drumProgramLibraryId, 'published-record', 'Published content keeps its corresponding identity');
  }
  {
    const { c, trace } = controllerHarness();
    c.isLeader = false;
    assert.equal(await c.updateDrumArrangement(arrangement('latin')), false);
    assert.equal(trace.length, 0);
    c.isLeader = true;
    await assert.rejects(c.updateDrumArrangement('{broken'));
    await assert.rejects(c.updateDrumArrangement(JSON.stringify({ sections: [], beatsPerBar: 4, beatUnit: 4 })), /无效/);
  }
}
function pageHarness() {
  const first = controllerHarness('paused');
  let session = { controller: first.c, waitForCurrentAudioConfiguration: async () => true };
  const entries = [{ id: 'saved-a', name: '夜行律动', program: arrangement('latin') },
    { id: 'saved-b', name: '三拍', program: arrangement('techno', 3, 4) }];
  const notices = [];
  const timers = new Map();
  let nextTimer = 1;
  const storage = new Map();
  const appStorage = { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) };
  const library = memoryDrumLibrary(appStorage);
  const source = ets('pages/MainPage.ets');
  const business = (source.slice(0, source.indexOf('  @Builder')) + '\n}')
    .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
    .replace(/@(?:Entry|Component)\b\s*/g, '').replace(/@State\s+/g, '')
    .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
    .replace('struct MainPage', 'export class MainPage');
  const Page = load(business, {}, { ...catalog, ...meter, ...library, Map,
    AppSession: { get: () => session }, loadSavedDrumPrograms: () => entries,
    isProDrumMachineAccessible: () => true, logUserFailure() {},
    showUserNotice: text => notices.push(text), userErrorMessage: e => e.message,
    AppStorage: appStorage, router: {}, setInterval: () => 1, clearInterval() {},
    Curve: { Linear: 0 },
    setTimeout(callback, delay) { const id = nextTimer++; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id) }).MainPage;
  const page = new Page();
  page.refreshVisualTransport = () => {};
  page.leader = true; page.rhythm = 3;
  // Exercise the real selection observer without unrelated network-roster rendering.
  page.refresh = () => page.refreshProgramSelection();
  page.refresh();
  return { page, entries, notices, session, storage, trace: first.trace, replaceSession(next) { session = next; } };
}

async function identicalContentIdentity() {
  const h = pageHarness(), p = h.page, c = h.session.controller;
  c.notifyUi = () => { throw new Error('Identity-only selection must bypass the audio/transport UI listener'); };
  const original = p.walkBaseProgram;
  c.state = 'playing';
  h.entries.push({ id: 'clone-a', name: '同内容甲', program: original },
    { id: 'clone-b', name: '同内容乙', program: original });
  p.toggleStyleDrawer();
  const before = [c.drumProgram, c.bpm, c.state, c.beatsPerBar, c.beatUnit];
  const epoch = controllerStorage.get('sessionEpoch') ?? 0;
  for (const key of ['clone-a', 'clone-b', 'base']) {
    await p.chooseDrumArrangement(key, original, key);
    assert.equal(p.selectedProgramKey, key, 'Content equality must not swallow selection of another identity');
    assert.equal(c.drumProgramLibraryId, key === 'base' ? '' : key);
    assert.deepEqual([c.drumProgram, c.bpm, c.state, c.beatsPerBar, c.beatUnit], before);
    assert.equal(h.trace.length, 0, 'Identity-only switching cannot prepare audio, broadcast configuration or restart the shared clock');
    assert.equal(JSON.parse(h.storage.get('recentDrumProgram')).libraryId, key === 'base' ? '' : key);
  }
  assert.equal(controllerStorage.get('sessionEpoch'), epoch + 3, 'Identity changes still invalidate observed page presentation');
  assert.equal(c.rememberDrumProgramLibraryId(original, ''), true);
  assert.equal(controllerStorage.get('sessionEpoch'), epoch + 3, 'An unchanged identity does not publish an extra refresh');
  assert.equal(p.walkBaseProgram, original);

  const changed = pageHarness(), q = changed.page;
  q.toggleStyleDrawer();
  await q.chooseDrumArrangement(changed.entries[0].id, changed.entries[0].program, changed.entries[0].name);
  const version = q.savedDrumProgramsRevision;
  const updated = catalog.parseDrumProgram(changed.entries[0].program);
  updated.sections[0].repeats = 8;
  changed.entries[0] = { ...changed.entries[0], program: catalog.serializeDrumProgram(updated) };
  q.reloadSavedDrumPrograms(); q.refresh();
  assert.ok(q.savedDrumProgramsRevision > version);
  assert.notEqual(q.selectedProgramKey, changed.entries[0].id,
    'Replacing a record cannot mark its newer content as already audible');
  await q.chooseDrumArrangement(changed.entries[0].id, changed.entries[0].program, changed.entries[0].name);
  assert.equal(changed.session.controller.drumProgram, changed.entries[0].program);
  assert.equal(changed.session.controller.drumProgramLibraryId, changed.entries[0].id);
}
async function pageSelection() {
  const h = pageHarness(), p = h.page;
  const original = p.walkBaseProgram;
  p.toggleStyleDrawer();
  assert.equal(p.showStyles, true);
  assert.equal(p.savedDrumPrograms.length, 2);
  assert.deepEqual(plain(p.programStyleKeys(original)), ['rock', 'jazz', 'funk']);
  const gate = deferred();
  h.session.controller.updateDrumArrangement = async raw => { await gate.promise; h.session.controller.drumProgram = raw; return true; };
  const pending = p.chooseDrumArrangement(h.entries[0].id, h.entries[0].program, h.entries[0].name);
  assert.equal(p.switchingProgramKey, 'saved-a');
  assert.equal(p.selectedProgramKey, 'base', 'Busy candidate never claims to be the audible program');
  assert.equal(p.busy, true);
  gate.resolve(); await pending;
  assert.equal(p.selectedProgramKey, 'saved-a');
  assert.equal(p.walkBaseProgram, original, 'Saved selections cannot overwrite the pinned original');
  assert.equal(p.showStyles, true, 'Selection leaves the drawer open');
  await p.chooseDrumArrangement('saved-b', h.entries[1].program, h.entries[1].name);
  assert.equal(p.showProgramMeterConfirm, true);
  assert.equal(p.selectedProgramKey, 'saved-a');
  assert.equal(p.onBackPress(), true);
  assert.equal(p.showProgramMeterConfirm, false, 'Back closes confirmation before drawer');
  assert.equal(p.showStyles, true);
  assert.equal(p.onBackPress(), true); assert.equal(p.showStyles, false);
  await p.chooseDrumArrangement('saved-b', h.entries[1].program, h.entries[1].name);
  const oldProgram = h.session.controller.drumProgram;
  h.replaceSession({ controller: controllerHarness('paused').c });
  await p.confirmDrumArrangement();
  assert.equal(h.session.controller.drumProgram, oldProgram, 'A confirmation cannot mutate its departed room');
  p.refresh(); assert.notEqual(p.walkBaseProgram, oldProgram, 'A fresh room captures its own initial arrangement');
  const fail = pageHarness();
  fail.session.controller.updateDrumArrangement = async () => { throw new Error('clock not ready'); };
  await fail.page.chooseDrumArrangement(fail.entries[0].id, fail.entries[0].program, fail.entries[0].name);
  assert.equal(fail.page.selectedProgramKey, 'base');
  assert.equal(fail.page.switchingProgramKey, ''); assert.equal(fail.page.busy, false);
  assert.deepEqual(fail.notices, ['clock not ready']);
}
async function audioReadinessBarrier() {
  const transportHarness = require('./transport-start-diagnostics.cjs').harness;
  {
    const h = transportHarness(true), gate = deferred();
    const peer = h.addPeer('ready-peer');
    h.controller.setTransportPreparationHandler(() => gate.promise);
    let finished = false;
    const prepare = h.controller.prepareConnectedMembersForTransport(true).then(result => { finished = true; return result; });
    const message = h.sent.find(x => x.type === 'TRANSPORT_PREPARE');
    assert.ok(message, 'Peer clock preparation starts without waiting for the leader kit loader');
    h.controller.onLeaderMessage(peer, { type: 'TRANSPORT_READY', payload: { id: message.payload.id, clockReady: true } });
    await flush(); assert.equal(finished, false, 'Ready peers cannot start while the leader PCM is still loading');
    gate.resolve(true); assert.equal(await prepare, 'ready');
  }
  {
    const h = transportHarness(true), gate = deferred();
    h.controller.soloTeam = true;
    h.controller.setTransportPreparationHandler(() => gate.promise);
    let finished = false;
    const prepare = h.controller.prepareConnectedMembersForTransport(true).then(result => { finished = true; return result; });
    await h.advance(3999); await flush(); assert.equal(finished, false);
    await h.advance(1); assert.equal(await prepare, 'failed', 'Cold local audio loading is bounded by the existing strict 4-second budget');
    gate.resolve(true); await flush();
    assert.equal(h.sent.length, 0, 'A late local loader completion does not publish transport');
  }
  for (const [clockSucceeds, audioSucceeds] of [[true, true], [true, false], [false, true]]) {
    const h = transportHarness(), audioGate = deferred();
    h.controller.setTransportPreparationHandler(() => audioGate.promise);
    const ready = h.controller.handleTransportPreparation({ id: 'combined-ready', requireClockReady: true });
    if (clockSucceeds) h.measurement.resolve({ offsetMs: 12, rttMs: 3 });
    else h.measurement.reject(new Error('no usable clock'));
    await flush(); assert.equal(h.sent.length, 0, 'A member clock sample alone is not audio readiness');
    audioGate.resolve(audioSucceeds); await ready;
    assert.equal(h.sent[0].payload.clockReady, clockSucceeds && audioSucceeds,
      'The strict ACK promises both clock and current complete audio configuration');
  }
}
async function main() {
  await sessionTransactions(); await pageSelection(); await identicalContentIdentity(); await audioReadinessBarrier();
  console.log('PASS arrangement switching: atomic meter/program, retained BPM/pause intent, one future shared restart, strict preparation rollback, no stale rollback or post-publication undo, leader-only selection, pinned snapshot, confirmation, room ownership and leader/member bounded audio readiness');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
