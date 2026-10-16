// Run with Node and a typescript/lib/typescript.js path, matching existing test scripts.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const root = path.resolve(__dirname, '../..');
const ets = name => fs.readFileSync(path.join(root, 'entry/src/main/ets', name), 'utf8');

function load(source, mocks = {}) {
  const context = { exports: {}, require: name => {
    assert.ok(name in mocks, `Unexpected import: ${name}`);
    return mocks[name];
  }};
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  vm.runInNewContext(result.outputText, context);
  return context.exports;
}

const catalog = load(ets('assets/CharacterCatalog.ets'), {
  '../store/EntitlementStore': { isCharacterAccessible: () => false }
});
const assets = load(ets('assets/AssetCatalog.ets'), { './CharacterCatalog': catalog });
const scene = ets('scene/WalkScene.ets');
const engine = ets('audio/MetronomeEngine.ets');
const updateMethods = scene.slice(scene.indexOf('  private updateWalkFrame('), scene.indexOf('  private startLoop('));
const snapshotMethod = engine.slice(engine.indexOf('  getVisualSnapshot():'), engine.indexOf('  async ensureRenderer():'));
const pauseMethod = engine.slice(engine.indexOf('  schedulePauseFromLeader('), engine.indexOf('  /** Leaving the walk/session'));
const { StandingPlayback } = load(`
const { memberAvatar, walkerAnimFrameIndex, WALK_FRAMES_PER_BEAT } = require('assets');
export class StandingPlayback {
  walkersWalking: boolean = false;
  animBeatIndex: number = 0;
  animBeatInBar: number = 1;
  animStepInBeat: number = 0;
${updateMethods}
}
`, { assets });
let now = 9000;
const timers = [];
const { VisualTransport } = load(`
const MonotonicClock = require('clock');
const { setTimeout, clearTimeout } = require('timers');
export class VisualTransport {
  running: boolean = false;
  transportRevision: number = 1;
  transportStartLocalMs: number = 10000;
  transportBpm: number = 120;
  transportStartBeatIndex: number = 0;
  transportCountInBeats: number = 4;
  transportCountInDurationMs: number = 2000;
  transportBeatsPerBar: number = 4;
  nextBeatAtMs: number = 10000;
  beatIndex: number = 0;
  runToken: number = 1;
  offsetMs: number = 0;
  outputLatencyMs: number = 0;
  pauseTimerId: number = -1;
  timerId: number = -1;
  scheduledPauseAtLocalMs: number | undefined = undefined;
  refreshOutputLatency(): void {}
  estimateTargetStreamFrame(at: number): number { return 0; }
  scheduleRunningTransition(transition: Object): void {}
${snapshotMethod}
${pauseMethod}
}
`, {
  clock: { nowMs: () => now },
  timers: {
    setTimeout(callback, delay) {
      timers.push({ at: now + delay, callback });
      return timers.length - 1;
    },
    clearTimeout(id) { timers[id] = undefined; }
  }
});
const transport = new VisualTransport();
const playback = new StandingPlayback();
const rawfiles = path.join(root, 'entry/src/main/resources/rawfile');
const fixed = ['cloud', 'mismatch', 'lilroll', 'teapot', 'wave', 'scooter', 'lamp'];
const random = Array.from(catalog.RANDOM_CHARACTER_KEYS);
const variants = fixed.map(avatarKey => ({ avatarKey, colorSlot: 0 }));
for (const resolvedAvatarKey of random) {
  for (const colorSlot of [0, 1]) variants.push({ avatarKey: 'random', resolvedAvatarKey, colorSlot });
}
const paths = new Set();
for (const [index, member] of variants.entries()) {
  const avatar = assets.memberAvatar(member.avatarKey, index, member.resolvedAvatarKey ?? '');
  const expected = random.includes(avatar)
    ? `stand/${avatar}/palette_${member.colorSlot + 1}/frame_01.png`
    : `stand/${avatar}/frame_01.png`;
  const filename = assets.standFramePath(avatar, member.colorSlot);
  assert.equal(filename, expected);
  paths.add(filename);
  assert.equal(assets.standFramePath(avatar, -1), assets.standFramePath(avatar, 0));
}
assert.equal(paths.size, 15, 'All fixed characters and random palettes need distinct standing assets');

function tick(at) {
  now = at;
  for (const [index, timer] of timers.entries()) {
    if (timer !== undefined && timer.at <= now) {
      timers[index] = undefined;
      timer.callback();
    }
  }
  playback.updateWalkFrame(transport.getVisualSnapshot());
}
function standing(at) {
  tick(at);
  assert.equal(playback.walkersWalking, false, `Expected standing at ${at}`);
  assert.equal(playback.animBeatIndex, 0);
  assert.equal(playback.animStepInBeat, 0);
}
standing(9000);
transport.running = true;
for (const at of [9000, 9999, 10000, 10500, 11500, 11999]) standing(at);

// Exercise actual transport snapshots at four subframes per beat, including
// both eight-frame and sixteen-frame cycles without changing the walk contract.
for (let beat = 0; beat < 6; beat++) {
  for (let step = 0; step < 4; step++) {
    tick(12000 + beat * 500 + step * 125);
    assert.equal(playback.walkersWalking, true);
    for (const [index, member] of variants.entries()) {
      const avatar = assets.memberAvatar(member.avatarKey, index, member.resolvedAvatarKey ?? '');
      assert.equal(playback.walkerFrameFor(member, index), assets.walkerAnimFrameIndex(avatar, beat, step));
    }
  }
}
transport.schedulePauseFromLeader(15000);
tick(14999);
assert.equal(playback.walkersWalking, true, 'A scheduled pause must keep walking until its shared deadline');
standing(15000);
playback.updateWalkFrame(undefined);
assert.equal(playback.walkersWalking, false, 'A disconnected session must retain the standing pose');

transport.running = true;
transport.transportRevision++;
transport.transportStartLocalMs = 20000;
transport.nextBeatAtMs = 20000;
transport.transportStartBeatIndex = 8;
transport.beatIndex = 8;
for (const at of [19000, 19999, 20000, 21500, 21999]) standing(at);
tick(22000);
assert.equal(playback.walkersWalking, true);
assert.equal(playback.animBeatIndex, 0, 'A resumed main timeline begins at the same first walk frame');

transport.transportStartLocalMs = 30000;
transport.nextBeatAtMs = 30000;
transport.transportStartBeatIndex = 20;
transport.beatIndex = 20;
transport.transportCountInBeats = 0;
transport.transportCountInDurationMs = 0;
standing(29999);
tick(30000);
assert.equal(playback.walkersWalking, true, 'A start without count-in switches at its shared deadline');
playback.updateWalkFrame({ ...transport.getVisualSnapshot(), countIn: true });
assert.equal(playback.walkersWalking, false, 'An explicit preparation beat must retain the standing pose');
playback.updateWalkFrame({ ...transport.getVisualSnapshot(), beatInBar: 0 });
assert.equal(playback.walkersWalking, false, 'A transport awaiting its first beat must retain the standing pose');

const tickBody = scene.slice(scene.indexOf('  private tickFrame():'), scene.indexOf('  private roadTileWidth():'));
assert.ok(tickBody.indexOf('this.updateWalkFrame(snapshot);') < tickBody.indexOf('if (snapshot !== undefined'),
  'Stopped and missing snapshots must also update the pose instead of retaining the previous walk frame');
assert.match(scene, /isWalking: this\.walkersWalking/);
const sprite = ets('scene/WalkerSprite.ets');
assert.match(sprite, /StandingWalkerSprite\([\s\S]*?\.visibility\(this\.isWalking \? Visibility\.Hidden : Visibility\.Visible\)/);
assert.match(sprite, /this\.walkLayers\(\);[\s\S]*?\.visibility\(this\.isWalking \? Visibility\.Visible : Visibility\.Hidden\)/);
assert.doesNotMatch(sprite, /if \(!?this\.isWalking\)/, 'Pose switches must preserve the already-mounted PNG layers');

for (const filename of paths) {
  const png = fs.readFileSync(path.join(rawfiles, filename));
  assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  assert.ok(png.readUInt32BE(16) > 0 && png.readUInt32BE(20) > 0);
  assert.ok([4, 6].includes(png[25]), `Standing image must preserve transparency: ${filename}`);
}

console.log('PASS: 15 standing assets, all palettes, idle/count-in/pause/resume deadlines, unchanged active walk cycles');
