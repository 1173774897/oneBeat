// Execute the real page lifecycle with a virtual clock and native frame/animation
// boundary. Animation callbacks set target state immediately, as ArkUI does;
// these tests inspect native delay/cancellation rather than simulate rendering.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const source = read('pages/MainPage.ets');
const stripImports = text => text.replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '');
function compile(text) {
  const result = ts.transpileModule(text, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
  });
  assert.equal(result.diagnostics.filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);
  return result.outputText;
}
const pageCode = compile(stripImports(source.slice(0, source.indexOf('  @Builder')) + '\n}')
  .replace(/@(?:Entry|Component)\b\s*/g, '').replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '').replace('struct MainPage', 'export class MainPage'));
const frameContext = { exports: {}, FrameCallback: class {} };
vm.runInNewContext(compile(stripImports(read('components/WalkReloadFrame.ets'))), frameContext);
const { WalkReloadFrame } = frameContext.exports;
const meterContext = { exports: {} };
vm.runInNewContext(compile(read('common/MeterModel.ets')), meterContext);
const meter = meterContext.exports;
const flush = async () => { for (let i = 0; i < 20; i++) { await Promise.resolve(); } };
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function harness() {
  let now = 0, timerId = 0, currentSession;
  const timers = new Map(), frames = [], animations = [], trace = [], notices = [], logs = [];
  const clock = {
    get now() { return now; },
    setTimeout(callback, delay) { timers.set(++timerId, { callback, at: now + delay }); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    advance(ms) {
      const target = now + ms;
      for (;;) {
        const next = [...timers].filter(([, timer]) => timer.at <= target)
          .sort((a, b) => a[1].at - b[1].at || a[0] - b[0])[0];
        if (!next) { break; }
        now = next[1].at; timers.delete(next[0]); next[1].callback();
      }
      now = target;
    }
  };
  function newSession() {
    const controller = {
      isLeader: true, state: 'paused', bpm: 120, beatsPerBar: 4, beatUnit: 4, soundId: 0,
      rhythm: 0, drumProgram: '', soloTeam: true, beatPointStates: meter.defaultBeatPointStates(4),
      getMembers: () => [],
      async updateBpm(value) { trace.push('bpm:' + value); this.bpm = value; },
      async updateSoundId(value) { trace.push('sound:' + value); this.soundId = value % 3; },
      async updateMeter(beats, unit) { trace.push(`meter:${beats}/${unit}`); this.beatsPerBar = beats; this.beatUnit = unit; },
      async cycleBeatPointState(index) { trace.push('point:' + index); },
      async updateDrumArrangement(raw, id) { trace.push(`program:${raw}:${id}`); return true; }
    };
    return { controller, metronome: { getVisualSnapshot: () => ({ running: false }) },
      async waitForCurrentAudioConfiguration() { trace.push('audio'); return true; },
      async leaderPause() { trace.push('pause'); controller.state = 'paused'; },
      async leaderResume() { trace.push('resume'); controller.state = 'playing'; },
      async leaderStart() { trace.push('start'); controller.state = 'playing'; } };
  }
  currentSession = newSession();
  class PageDate extends Date { static now() { return now; } }
  const context = { exports: {}, Map, Date: PageDate, ...meter, WalkReloadFrame,
    Curve: { Linear: 'linear', EaseInOut: 'ease' }, AppSession: { get: () => currentSession },
    AppStorage: { get: () => 0 }, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout,
    setInterval: () => 9000, clearInterval() {}, isProDrumMachineAccessible: () => true,
    rememberRecentDrumProgram: (...args) => trace.push('recent:' + args.join(':')),
    RecordingCoordinator: { getSnapshot: () => ({ state: 'idle', elapsedMs: 0, error: '', saveFailureDetail: '' }) },
    showUserNotice: text => notices.push(text), logUserFailure: (...args) => logs.push(args),
    userErrorMessage: (_error, fallback) => fallback };
  vm.runInNewContext(pageCode, context);
  const page = new context.exports.MainPage();
  page.getUIContext = () => ({
    animateTo(options, update) {
      update();
      animations.push({ at: now, ...options, top: page.topReloadOpacity, bottom: page.bottomReloadOpacity });
    },
    postFrameCallback(frame) { frames.push(frame); trace.push('post-frame'); }
  });
  page.refresh();
  return { page, clock, timers, frames, animations, trace, notices, logs,
    get session() { return currentSession; },
    replaceSession() { currentSession = newSession(); page.refresh(); return currentSession; },
    async frame(frame = frames[0]) {
      const index = frames.indexOf(frame);
      if (index >= 0) { frames.splice(index, 1); }
      trace.push('frame-idle'); frame.onIdle(0); await flush();
    } };
}

function assertClear(h) {
  assert.equal(h.page.topReloadPending, false);
  assert.equal(h.page.bottomReloadPending, false);
  assert.equal(h.page.topReloadOpacity + h.page.bottomReloadOpacity, 0);
  assert.equal(h.page.switchingProgramKey, '');
  assert.equal(h.page.switchingVisualOwner, 0);
  assert.equal(h.page.reloadRequests.size, 0);
  assert.equal(h.timers.size, 0);
}

async function timingAndAggregation() {
  {
    const h = harness(), p = h.page;
    const id = p.beginReloadFeedback('top', h.session);
    assert.equal(p.topReloadPending, true);
    assert.equal(p.topReloadOpacity, 1, 'State is the native animation target, not an already painted opacity');
    assert.equal(h.animations[0].delay, 300);
    assert.equal(h.animations[0].duration, 120);
    h.clock.advance(299); p.finishReloadFeedback(id);
    assertClear(h);
    assert.equal(h.animations.at(-1).delay, 0);
    assert.equal(h.animations.at(-1).duration, 0, 'Fast completion cancels the native delayed animation immediately');
    h.clock.advance(4000); assertClear(h);
  }
  {
    const h = harness(), p = h.page;
    const id = p.beginReloadFeedback('bottom', h.session, '正在切换编排…');
    h.clock.advance(2999);
    assert.equal(p.bottomReloadText, '正在切换编排…');
    h.clock.advance(1);
    assert.equal(p.bottomReloadText, '仍在处理，请稍候');
    p.finishReloadFeedback(id); assertClear(h);
    assert.equal(p.busy, false, 'Feedback does not acquire a business lock');
  }
  for (const regions of [['top', 'bottom'], ['top', 'top']]) {
    const h = harness(), p = h.page;
    const first = p.beginReloadFeedback(regions[0], h.session);
    const second = p.beginReloadFeedback(regions[1], h.session);
    p.finishReloadFeedback(first);
    assert.equal(p.reloadRequests.size, 1);
    assert.equal(regions[1] === 'top' ? p.topReloadPending : p.bottomReloadPending, true,
      'Finishing one request cannot clear another request in either region');
    p.finishReloadFeedback(second); assertClear(h);
  }
}

async function wrappersAndVisualHold() {
  const cases = [
    { name: 'top BPM', region: 'top', method: 'updateBpm', args: [132], invoke: p => p.applyBpm(132) },
    { name: 'top meter', region: 'top', method: 'updateMeter', args: [3, 8], invoke: p => p.applyMeter(3, 8) },
    { name: 'top point', region: 'top', method: 'cycleBeatPointState', args: [1], busy: true,
      invoke: p => p.cycleBeatPoint(1) },
    { name: 'bottom BPM', region: 'bottom', method: 'updateBpm', args: [119], invoke: p => p.changeBpm(-1) },
    { name: 'bottom sound', region: 'bottom', method: 'updateSoundId', args: [1], invoke: p => p.changeSound() },
    { name: 'bottom playback', region: 'bottom', method: 'leaderResume', args: [], busy: true,
      invoke: p => p.toggle() },
    { name: 'bottom arrangement', region: 'bottom', method: 'updateDrumArrangement', args: ['candidate-raw', 'candidate'],
      busy: true, program: true, invoke: p => p.switchDrumArrangement('candidate', 'candidate-raw') }
  ];
  for (const test of cases) {
    const h = harness(), p = h.page, operation = deferred(), audio = deferred(), calls = [];
    const host = test.method === 'leaderResume' ? h.session : h.session.controller;
    host[test.method] = async (...args) => { calls.push(args); h.trace.push('operation'); return operation.promise; };
    h.session.waitForCurrentAudioConfiguration = () => { h.trace.push('audio'); return audio.promise; };
    p.savedDrumPrograms = [{ id: 'candidate', program: 'candidate-raw' }];
    const pending = test.invoke(p);
    assert.equal(p.topReloadPending, test.region === 'top', test.name);
    assert.equal(p.bottomReloadPending, test.region === 'bottom', test.name);
    assert.equal(p.busy, Boolean(test.busy), test.name + ' preserves the original business-lock policy');
    assert.equal(calls.length, 0, 'PCM-capable work waits for the native frame to be submitted');
    assert.equal(h.frames.length, 1);
    if (test.program) { assert.equal(p.switchingProgramKey, 'candidate'); assert.equal(p.programSwitchInFlight, true); }
    await h.frame();
    assert.deepEqual(calls, [test.args], test.name);
    assert.ok(h.trace.indexOf('frame-idle') < h.trace.indexOf('operation'));
    operation.resolve(test.program ? true : undefined); await flush();
    assert.equal(h.trace.filter(item => item === 'audio').length, 1);
    assert.equal(p.reloadRequests.size, 1, 'Native configuration completion is still awaited');
    h.clock.advance(450); audio.resolve(true); await pending;
    assert.equal(p.busy, false, 'Business work finishes independently of the visual hold');
    if (test.program) {
      assert.equal(p.programSwitchInFlight, false);
      assert.equal(p.switchingProgramKey, 'candidate', 'Card feedback shares the bottom-bar minimum visual hold');
    }
    assert.equal(p.reloadRequests.size, 1);
    assert.equal([...p.reloadRequests.values()][0].settled, true);
    h.clock.advance(149); assert.equal(p.reloadRequests.size, 1);
    if (test.program) { assert.equal(p.switchingProgramKey, 'candidate'); }
    h.clock.advance(1); assertClear(h);
  }
}

async function staleWorkAndLifecycle() {
  {
    const h = harness(), p = h.page, oldAudio = deferred(), freshAudio = deferred();
    let waits = 0;
    h.session.waitForCurrentAudioConfiguration = () => ++waits === 1 ? oldAudio.promise : freshAudio.promise;
    const previous = p.applyBpm(132); await h.frame();
    const fresh = p.changeBpm(1); await h.frame();
    assert.equal(h.session.controller.bpm, 133);
    oldAudio.resolve(false); await previous;
    assert.deepEqual(h.notices, [], 'Superseded audio preparation is not a configuration failure');
    assert.equal(p.topReloadPending, false);
    assert.equal(p.bottomReloadPending, true, 'The new configuration still owns its feedback');
    freshAudio.resolve(true); await fresh; assertClear(h);
  }
  {
    const h = harness(), p = h.page;
    const pending = p.cycleBeatPoint(1);
    assert.equal(h.frames.length, 1); assert.equal(p.busy, true);
    h.session.controller.rhythm = 3;
    assert.equal(p.rhythm, 0, 'Exercise the room changing before the page receives its new mode');
    await h.frame(); await pending;
    assert.equal(h.trace.some(item => item.startsWith('point:')), false,
      'A pre-work frame cannot bypass the live drum-mode editing boundary');
    assert.equal(h.trace.includes('audio'), false);
    assert.equal(p.busy, false); assertClear(h);
  }
  for (const guard of ['exiting', 'returningToLobby']) {
    const h = harness(), p = h.page;
    const pending = p.applyBpm(132);
    p[guard] = true;
    await h.frame(); await pending;
    assert.equal(h.trace.some(item => item.startsWith('bpm:')), false,
      guard + ': a deferred frame cannot initiate work after navigation begins');
    assertClear(h);
  }
  for (const exit of ['onPageHide', 'aboutToDisappear', 'replaceSession']) {
    const h = harness(), p = h.page, oldCalls = [];
    h.session.controller.updateBpm = async value => oldCalls.push(value);
    const previous = p.applyBpm(132), oldFrame = h.frames[0];
    if (exit === 'replaceSession') { h.replaceSession(); }
    else { p[exit](); p.onPageShow(); }
    const fresh = p.changeSound(), newFrame = h.frames.at(-1);
    await flush(); await previous;
    assert.equal(p.bottomReloadPending, true, exit + ': old finally cannot clear the new source');
    assert.equal(p.topReloadPending, false);
    await h.frame(oldFrame);
    assert.deepEqual(oldCalls, [], exit + ': an old frame cannot start work after cleanup');
    assert.equal(p.bottomReloadPending, true);
    await h.frame(newFrame); await fresh; assertClear(h);
    h.clock.advance(5000); assertClear(h);
  }
  for (const exit of ['onPageHide', 'aboutToDisappear']) {
    const h = harness(), p = h.page, oldOperation = deferred(), freshOperation = deferred();
    let submissions = 0;
    h.session.leaderResume = () => ++submissions === 1 ? oldOperation.promise : freshOperation.promise;
    const previous = p.toggle(); await h.frame();
    assert.equal(submissions, 1, 'Exercise a real native operation after the frame boundary');
    p[exit](); p.onPageShow(); assertClear(h);
    assert.equal(p.busy, true, exit + ': clearing visuals must retain the submitted same-room lock');
    await p.toggle();
    assert.equal(submissions, 1, 'Showing again cannot submit a duplicate native operation');
    assert.equal(h.frames.length, 0, 'A blocked duplicate cannot create fresh feedback');
    oldOperation.reject(new Error('old native response')); await previous;
    assert.equal(p.busy, false, 'The original finally releases its own same-room lock');
    assert.deepEqual(h.notices, [], 'Hidden failures cannot publish feedback after showing');
    const fresh = p.toggle(); await h.frame();
    assert.equal(submissions, 2, 'Retry becomes available after the original operation settles');
    freshOperation.resolve(); await fresh; assertClear(h);
  }
  {
    const h = harness(), p = h.page;
    const previous = p.toggle(), oldFrame = h.frames[0];
    assert.equal(p.busy, true);
    p.onPageHide(); p.onPageShow();
    await previous;
    assert.equal(p.busy, false, 'Hiding before native submission releases the frame wait and finishes the lock');
    await h.frame(oldFrame);
    assert.equal(h.trace.includes('resume'), false, 'A stale frame cannot submit the cancelled operation');
    const fresh = p.toggle(); await h.frame(); await fresh;
    assert.equal(h.trace.filter(item => item === 'resume').length, 1);
    assertClear(h);
  }
  {
    const h = harness(), p = h.page, oldOperation = deferred(), freshOperation = deferred();
    h.session.controller.updateDrumArrangement = () => oldOperation.promise;
    const previous = p.switchDrumArrangement('old-card', 'old-raw'); await h.frame();
    p.onPageHide(); assert.equal(p.busy, true);
    const freshSession = h.replaceSession();
    assert.equal(p.busy, false, 'Replacing the owning room discards its business lock even after visuals were cleared');
    p.onPageShow();
    freshSession.controller.updateDrumArrangement = () => freshOperation.promise;
    const fresh = p.switchDrumArrangement('fresh-card', 'fresh-raw'); await h.frame();
    oldOperation.reject(new Error('old room native response')); await previous;
    assert.equal(p.busy, true, 'An old room finally cannot release the new request business lock');
    assert.equal(p.bottomReloadPending, true);
    assert.equal(p.programSwitchInFlight, true);
    assert.equal(p.switchingProgramKey, 'fresh-card', 'The new card retains ownership of its loading ring');
    assert.deepEqual(h.notices, [], 'An old room failure cannot publish feedback');
    freshOperation.resolve(true); await fresh; assertClear(h);
    assert.equal(p.busy, false); assert.equal(p.programSwitchInFlight, false);
  }
  {
    const h = harness(), p = h.page, oldAudio = deferred(), freshOperation = deferred();
    let waits = 0;
    h.session.waitForCurrentAudioConfiguration = () => ++waits === 1 ? oldAudio.promise : Promise.resolve(true);
    const previous = p.switchDrumArrangement('old-card', 'old-raw'); await h.frame();
    h.clock.advance(450); oldAudio.resolve(true); await previous;
    assert.equal(p.busy, false);
    assert.equal(p.switchingProgramKey, 'old-card');
    h.session.controller.updateDrumArrangement = () => freshOperation.promise;
    const fresh = p.switchDrumArrangement('fresh-card', 'fresh-raw'); await h.frame();
    h.clock.advance(150);
    assert.equal(p.reloadRequests.size, 1, 'The older minimum-hold request has been removed');
    assert.equal(p.switchingProgramKey, 'fresh-card', 'An old hide timer cannot clear the newer card loading ring');
    assert.equal(p.bottomReloadPending, true);
    assert.equal(p.busy, true);
    freshOperation.resolve(true); await fresh; assertClear(h);
    assert.equal(p.busy, false);
  }
  for (const exit of ['onPageHide', 'aboutToDisappear', 'replaceSession']) {
    const h = harness(), p = h.page;
    const id = p.beginReloadFeedback('top', h.session);
    h.clock.advance(450); p.finishReloadFeedback(id);
    assert.equal(h.timers.size, 1, 'Exercise cleanup while the minimum visual hold is pending');
    if (exit === 'replaceSession') { h.replaceSession(); }
    else { p[exit](); }
    assertClear(h); h.clock.advance(5000); assertClear(h);
  }
}

async function failureAndPause() {
  for (const failure of ['operation', 'audio', 'program-false']) {
    const h = harness(), p = h.page;
    if (failure === 'operation') { h.session.controller.updateBpm = async () => { throw new Error('PCM rejected'); }; }
    if (failure === 'audio') { h.session.waitForCurrentAudioConfiguration = async () => false; }
    if (failure === 'program-false') { h.session.controller.updateDrumArrangement = async () => false; }
    const pending = failure === 'program-false' ? p.switchDrumArrangement('candidate', 'raw') : p.applyBpm(132);
    await h.frame(); await pending; assertClear(h);
    assert.equal(p.busy, false); assert.equal(p.programSwitchInFlight, false); assert.equal(p.switchingProgramKey, '');
    assert.equal(h.notices.length, 1, failure + ': one existing failure notice remains actionable');
    assert.equal(h.logs.length, 1);
  }
  {
    const h = harness(), p = h.page, pause = deferred();
    p.state = 'playing'; h.session.controller.state = 'playing';
    h.session.leaderPause = async () => { await pause.promise; h.session.controller.state = 'paused'; };
    const pending = p.toggle(); await h.frame();
    h.clock.advance(450); pause.resolve(); await pending;
    assert.equal(p.state, 'paused'); assert.equal(p.busy, false);
    assert.equal(h.trace.includes('audio'), false, 'Pause does not wait for a fresh playback configuration');
    h.clock.advance(150); assertClear(h);
  }
}

function sourceContract() {
  const top = source.slice(source.indexOf('  private topPanel()'), source.indexOf('  private programCard('));
  const bottom = source.slice(source.indexOf('  private bottomPanel()'), source.indexOf('\n  build()'));
  const card = source.slice(source.indexOf('  private programCard('), source.indexOf('  private programDrawer()'));
  for (const [region, builder] of [['top', top], ['bottom', bottom]]) {
    assert.match(builder, new RegExp('LoadingProgress\\(\\)[\\s\\S]*?\\.enableLoading\\(this\\.' + region + 'ReloadPending\\)'));
    assert.ok(builder.includes('.opacity(this.' + region + 'ReloadOpacity)'));
    assert.ok(builder.includes('.height(WALK_RELOAD_ROW_HEIGHT)'));
    assert.doesNotMatch(builder, new RegExp('if \\(this\\.' + region + 'ReloadPending'),
      'Resident loading nodes can submit native delayed animations before synchronous PCM work');
  }
  assert.match(card, /LoadingProgress\(\)[\s\S]*?\.enableLoading\(this\.switchingProgramKey === key && this\.bottomReloadPending\)/);
  assert.match(card, /\.opacity\(this\.switchingProgramKey === key \? this\.bottomReloadOpacity : 0\)/,
    'The arrangement card and bottom bar share the same native fade timing');
}

(async () => {
  await timingAndAggregation(); await wrappersAndVisualHold(); await staleWorkAndLifecycle(); await failureAndPause();
  sourceContract();
  console.log('PASS walk loading feedback: native delayed fade and pre-work frame, request aggregation, source placement, slow notice, independent visual hold, audio readiness, lifecycle/room cleanup, stale work, failure and pause');
})().catch(error => { console.error(error); process.exitCode = 1; });
