// Exercise the real session mutations and editor entry; only native networking/UI are mocked.
const assert = require('node:assert/strict');
const { harness, load, ets, meter, catalog, plain } = require('./drum-editor-preview.cjs');
const { SessionController } = load(ets('session/SessionController.ets'), {
  '../common/Constants': {},
  BuildProfile: { DEBUG: false },
  '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 1000 } },
  '../protocol/messages': { createMessage: (type, payload) => ({ type, payload }) },
  '../network/socket/SessionServer': { SessionServer: class {} },
  '../network/socket/SessionClient': { SessionClient: class {} },
  '../sync/ClockSync': { ClockSyncEstimator: class {} },
  '../network/p2p/P2pInvitation': {},
  '../assets/AssetCatalog': {},
  '../assets/CharacterCatalog': { defaultSessionAvatar: () => 'test' },
  '../common/MeterModel': meter,
  '../audio/DrumMachineCatalog': catalog
}, {
  AppStorage: { get: () => undefined },
  console: { info() {}, warn() {} }
});

function setup() {
  const h = harness();
  // Member construction skips unrelated avatar setup; exercise leader mutation guards afterward.
  const controller = new SessionController('settings-test', false, 'test');
  controller.isLeader = true;
  controller.notifyUi = () => {};
  controller.scheduleRandomAvatarReveals = () => {};
  const snapshots = [];
  controller.sendToAll = async message => { snapshots.push(plain(message)); };
  controller.rhythm = 3;
  const program = catalog.defaultDrumProgram();
  program.sections[0].repeats = 5;
  program.sections[0].customPattern = { subdivision: 3, events: [
    { tick: 0, sampleKey: 'kick', velocity: 0.73 },
    { tick: 320, sampleKey: 'ride', velocity: 0.42 }
  ] };
  program.sections[0].customFill = { subdivision: 6, events: [
    { tick: 960, sampleKey: 'tom_low', velocity: 0.67 },
    { tick: 1040, sampleKey: 'snare', velocity: 0.31 }
  ] };
  program.sections.push({ id: 'B', patternIndex: 1, repeats: 2, fillIndex: 2, fillEvery: 2 });
  controller.drumProgram = catalog.serializeDrumProgram(program);
  controller.rememberProDrumEditorSettings(4, 4, 120);
  h.session.controller = controller;
  return { ...h, controller, snapshots };
}

async function main() {
  const h = setup();
  const { controller: c, page: p } = h;
  p.aboutToAppear();
  const arrangement = plain(p.sections);
  assert.deepEqual([p.beatsPerBar, p.beatUnit, p.bpm], [4, 4, 120]);
  p.aboutToDisappear();
  await c.updateBpm(156);
  await c.updateMeter(3, 8);
  p.aboutToAppear();
  assert.deepEqual([p.beatsPerBar, p.beatUnit, p.bpm], [3, 8, 156],
    'Reopening after lobby summary edits must use the new meter and BPM, not the old editor cache');
  assert.deepEqual(plain(p.sections), arrangement, 'Settings synchronization must not replace section arrangements');
  assert.deepEqual([catalog.parseDrumProgram(c.drumProgram).beatsPerBar,
    catalog.parseDrumProgram(c.drumProgram).beatUnit], [3, 8]);
  assert.equal(h.snapshots.at(-1).payload.bpm, 156);
  assert.deepEqual([h.snapshots.at(-1).payload.beatsPerBar, h.snapshots.at(-1).payload.beatUnit], [3, 8]);

  p.chooseMeter(7, 8);
  assert.deepEqual([c.beatsPerBar, c.beatUnit], [3, 8], 'Changing a draft meter still waits for Apply');
  await c.updateBpm(180);
  assert.deepEqual(plain(c.getProDrumEditorSettings()), { beatsPerBar: 7, beatUnit: 8, bpm: 180 },
    'A live BPM change must preserve the independent, unapplied draft meter');
  c.rememberProDrumEditorSettings(7, 8, 147);
  await c.updateMeter(5, 4);
  assert.deepEqual(plain(c.getProDrumEditorSettings()), { beatsPerBar: 5, beatUnit: 4, bpm: 147 },
    'A live meter change must replace only the cached meter fields');

  for (const [bpm, expected] of [[999, 240], [1, 40]]) {
    await c.updateBpm(bpm);
    p.aboutToAppear();
    assert.equal(p.bpm, expected, 'The cache must receive the clamped session value');
  }
  const beforeInvalid = plain(c.getProDrumEditorSettings());
  await c.updateMeter(0, 3);
  assert.deepEqual(plain(c.getProDrumEditorSettings()), beforeInvalid, 'Invalid meters must leave the editor cache untouched');
  const copy = c.getProDrumEditorSettings();
  copy.bpm = 999;
  assert.deepEqual(plain(c.getProDrumEditorSettings()), beforeInvalid, 'Settings reads must not expose mutable cache ownership');

  // Basic-metronome settings and saved PRO drafts intentionally remain separate.
  c.rhythm = 0;
  await c.updateBpm(90);
  await c.updateMeter(6, 8);
  assert.deepEqual(plain(c.getProDrumEditorSettings()), beforeInvalid);
  const first = setup();
  first.controller.proDrumEditorSettings = undefined;
  await first.controller.updateBpm(132);
  await first.controller.updateMeter(6, 8);
  first.page.aboutToAppear();
  assert.deepEqual([first.page.beatsPerBar, first.page.beatUnit, first.page.bpm], [6, 8, 132],
    'First entry without a draft cache must still follow the live session');

  const running = setup();
  running.controller.state = 'playing';
  const configurations = [];
  running.controller.restartRunningTransportAfterConfiguration = async () => {
    configurations.push(plain(running.controller.getProDrumEditorSettings()));
  };
  await running.controller.updateBpm(164);
  await running.controller.updateMeter(7, 8);
  assert.deepEqual(configurations, [{ beatsPerBar: 4, beatUnit: 4, bpm: 164 },
    { beatsPerBar: 7, beatUnit: 8, bpm: 164 }], 'Cache changes must be visible before the existing transport restart');
  console.log('PASS drum lobby/editor settings: actual cached and live tempo/meter mutations, reopen, field isolation, bounds, arrangement retention and running configuration order');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
