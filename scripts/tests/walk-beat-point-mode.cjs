// Execute the production page action and controller transition; ArkUI-only
// boundaries are checked separately because they require a device to render.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const source = read('pages/MainPage.ets');

function load(source, globals = {}) {
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal(compiled.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  const context = { exports: {}, ...globals };
  vm.runInNewContext(compiled.outputText, context);
  return context.exports;
}

const meter = load(read('common/MeterModel.ets'));
const colors = Object.fromEntries([...read('components/ComicKit.ets')
  .matchAll(/export const (PAPER|INK|CORAL|LILAC|WHITE): string = '([^']+)';/g)]
  .map(match => [match[1], match[2]]));
const pageBusiness = (source.slice(0, source.indexOf('  @Builder')) + '\n}')
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '').replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct MainPage', 'export class MainPage');
const controllerSource = read('session/SessionController.ets');
const cycleStart = controllerSource.indexOf('  async cycleBeatPointState(index: number): Promise<void> {');
const cycleEnd = controllerSource.indexOf('  private async restartRunningTransportAfterConfiguration', cycleStart);
assert.ok(cycleStart >= 0 && cycleEnd > cycleStart, 'Use the actual controller transition, not a test-side state model');
const { ActualControllerCycle } = load('export class ActualControllerCycle {\n' +
  controllerSource.slice(cycleStart, cycleEnd) + '\n}', meter);
const plain = value => JSON.parse(JSON.stringify(value));

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function harness(rhythm = 0, state = 'paused', gate) {
  const notices = [], logs = [], calls = [], busyChanges = [];
  const timers = new Map();
  let nextTimer = 1;
  let broadcasts = 0, restarts = 0, refreshes = 0;
  const controller = Object.assign(new ActualControllerCycle(), {
    isLeader: true, rhythm, state, bpm: 120, beatsPerBar: 4, beatUnit: 4, soloTeam: true,
    drumProgram: '', beatPointStates: meter.defaultBeatPointStates(4), getMembers: () => [],
    broadcastSnapshot: async () => { broadcasts++; },
    restartRunningTransportAfterConfiguration: async () => { restarts++; }
  });
  const session = { controller, metronome: { getVisualSnapshot: () => ({ running: false }) },
    waitForCurrentAudioConfiguration: async () => true };
  const { MainPage } = load(pageBusiness, {
    ...meter, ...colors, Map, AppSession: { get: () => session }, AppStorage: { get: () => 0 },
    showUserNotice: notice => notices.push(notice), logUserFailure: (...args) => logs.push(args),
    userErrorMessage: (_error, fallback) => fallback, Curve: { Linear: 0 },
    setTimeout(callback, delay) { const id = nextTimer++; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id)
  });
  const page = new MainPage();
  const actualRefresh = page.refresh;
  page.refresh = () => { refreshes++; actualRefresh.call(page); };
  page.refresh();
  let busy = page.busy;
  Object.defineProperty(page, 'busy', {
    get: () => busy,
    set: value => { busyChanges.push(value); busy = value; }
  });
  const actualCycle = controller.cycleBeatPointState;
  controller.cycleBeatPointState = async index => {
    calls.push({ index, busy: page.busy });
    if (gate && calls.length === 1) { await gate.promise; }
    return actualCycle.call(controller, index);
  };
  return { page, controller, calls, notices, logs, busyChanges,
    get broadcasts() { return broadcasts; }, get restarts() { return restarts; },
    get refreshes() { return refreshes; } };
}

async function flush() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

function snapshot(h) {
  return { points: plain(h.controller.beatPointStates), displayed: plain(h.page.beatPointStates),
    busy: h.page.busy, sequence: h.page.actionSequence, refreshes: h.refreshes };
}

function assertBlocked(h, before, message) {
  assert.deepEqual(snapshot(h), before, message);
  assert.equal(h.calls.length, 0, message + ': controller must not run');
  assert.deepEqual(h.busyChanges, [], message + ': even a transient busy state is forbidden');
  assert.equal(h.broadcasts + h.restarts, 0);
  assert.deepEqual(h.notices, []);
}

async function main() {
  {
    const h = harness(3);
    h.controller.beatPointStates = ['accent', 'normal', 'silent', 'normal'];
    h.page.refresh();
    assert.deepEqual([0, 1, 2].map(index => h.page.beatPointFill(index)),
      [colors.LILAC, colors.CORAL, colors.WHITE], 'Drum indicators retain their normal state colors');
    const before = snapshot(h);
    for (const index of [0, 1, 2, 3]) { await h.page.cycleBeatPoint(index); }
    assertBlocked(h, before, 'Drum indicators cannot edit accents through an old callback');
  }
  {
    const h = harness(0);
    h.controller.rhythm = 3;
    assert.equal(h.page.rhythm, 0, 'Exercise a callback before the page receives the new mode');
    const before = snapshot(h);
    await h.page.cycleBeatPoint(1);
    assertBlocked(h, before, 'The live controller mode also protects stale metronome UI');
  }
  for (const rhythm of [0, 1, 2]) {
    for (const state of ['paused', 'playing']) {
      const h = harness(rhythm, state);
      for (const [expectedState, expectedColor] of [
        ['accent', colors.LILAC], ['silent', colors.WHITE], ['normal', colors.CORAL]
      ]) {
        await h.page.cycleBeatPoint(1);
        assert.equal(h.controller.beatPointStates[1], expectedState);
        assert.equal(h.page.beatPointStates[1], expectedState);
        assert.equal(h.page.beatPointFill(1), expectedColor);
        assert.equal(h.page.busy, false);
      }
      assert.deepEqual(h.calls, Array.from({ length: 3 }, () => ({ index: 1, busy: true })));
      assert.deepEqual(h.busyChanges, [true, false, true, false, true, false]);
      assert.equal(h.broadcasts, state === 'paused' ? 3 : 0);
      assert.equal(h.restarts, state === 'playing' ? 3 : 0);
      assert.deepEqual(h.notices, []);
    }
    for (const guard of [{ leader: false }, { busy: true }, { exiting: true }]) {
      const h = harness(rhythm);
      Object.assign(h.page, guard);
      h.busyChanges.length = 0;
      const before = snapshot(h);
      await h.page.cycleBeatPoint(1);
      assertBlocked(h, before, `Rhythm ${rhythm} preserves ${Object.keys(guard)[0]} protection`);
    }
  }
  {
    const gate = deferred(), h = harness(0, 'paused', gate);
    const pending = h.page.cycleBeatPoint(1);
    assert.equal(h.page.busy, true);
    assert.equal(h.calls.length, 0, 'The native loading frame precedes the controller mutation');
    await flush();
    assert.equal(h.calls.length, 1);
    await h.page.cycleBeatPoint(1);
    assert.equal(h.calls.length, 1, 'A pending update cannot overlap a second click');
    gate.resolve();
    await pending;
    assert.equal(h.page.busy, false);
    assert.equal(h.page.beatPointFill(1), colors.LILAC);
    assert.deepEqual(h.busyChanges, [true, false]);
  }
  {
    const gate = deferred(), h = harness(1, 'paused', gate);
    const before = plain(h.controller.beatPointStates);
    const pending = h.page.cycleBeatPoint(1);
    await flush();
    const failure = new Error('synthetic sync failure');
    gate.reject(failure);
    await pending;
    assert.equal(h.page.busy, false, 'Failure must release the native disabled state');
    assert.deepEqual(plain(h.controller.beatPointStates), before);
    assert.deepEqual(h.notices, ['拍点修改失败，请重试']);
    assert.deepEqual(h.logs, [['walk-beat-point', failure]]);
    await h.page.cycleBeatPoint(1);
    assert.equal(h.calls.length, 2, 'A failed update leaves editing available for retry');
    assert.equal(h.page.beatPointFill(1), colors.LILAC);
  }

  const builder = source.slice(source.indexOf('  private beatPoint(index: number) {'),
    source.indexOf('  private beatUnitIconPath(): string {'));
  const branch = builder.indexOf('    if (this.rhythm === 3) {');
  const split = builder.indexOf('    } else {', branch);
  assert.ok(branch >= 0 && split > branch, 'Drum display and metronome editing have explicit ownership branches');
  const display = builder.slice(branch, split), editable = builder.slice(split);
  assert.match(display, /Row\(\)\.width\(this\.beatPointSize\(\)\)\.height\(this\.beatPointHeight\(\)\)/);
  assert.doesNotMatch(display, /\b(?:ActionButton|Button)\s*\(|\.on(?:Click|Touch)\s*\(|\.gesture\s*\(/,
    'The drum branch has no actionable control or event handler');
  assert.match(display, /\.hitTestBehavior\(HitTestMode\.Block\)/,
    'Indicator touches cannot fall through to the scene chrome toggle');
  assert.match(display, /\.focusable\(false\)\.accessibilityLevel\('no'\)/);
  assert.match(editable, /ActionButton\(\{\s*active: this\.leader && !this\.busy/);
  assert.match(editable, /action: \(\) => \{ void this\.cycleBeatPoint\(index\); \}/);
  for (const face of [display, editable]) {
    assert.ok(face.includes('this.beatPointFill(index)'), 'Both modes use the same production state color');
    assert.ok(face.includes("{ radius: 8, color: '#CC35D6E4', offsetX: 0, offsetY: 0 }"),
      'Both modes retain the live beat glow');
  }
  console.log('PASS walk beat-point modes: static drum indicators, stale-mode guards, metronome three-state cycles, leader/busy/exit protection, async overlap, failure recovery and native UI boundary');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
