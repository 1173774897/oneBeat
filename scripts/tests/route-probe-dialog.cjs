// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const source = fs.readFileSync('entry/src/main/ets/pages/LeaderLobbyPage.ets', 'utf8');
const builderStart = source.indexOf('  @Builder');
assert.ok(builderStart > 0, 'Lobby probe methods must precede the first ArkUI builder');

function actualMethodsBetween(start, end) {
  const startIndex = source.indexOf(start);
  const endIndex = source.indexOf(end, startIndex);
  assert.ok(startIndex >= 0 && endIndex > startIndex, `Expected actual lifecycle method ${start}`);
  return source.slice(startIndex, endIndex);
}

// ArkUI builders cannot run without a device. Keep the actual fields, probe
// methods and page-exit methods; only imports and ArkUI decorators are removed.
const businessSource = (source.slice(0, builderStart) +
  actualMethodsBetween('  aboutToDisappear(): void {', '  onBackPress(): boolean {') +
  actualMethodsBetween('  onPageHide(): void {', '  private startRosterStatusAnimation(): void {') +
  actualMethodsBetween('  private async leaveLobby(): Promise<void> {', '  refresh(): void {') + '\n}\n')
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct LeaderLobbyPage', 'export class LeaderLobbyPage');
const compiled = ts.transpileModule(businessSource, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0,
  'Actual probe and lifecycle methods must transpile');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function harness() {
  const requests = [];
  const toasts = [];
  const routes = [];
  const trace = [];
  const session = {
    playBluetoothRouteProbe() {
      const request = deferred();
      requests.push(request);
      return request.promise;
    },
    async stopLatencyCalibration() { trace.push('stop-probe'); }
  };
  const context = {
    exports: {},
    Map,
    Scroller: class {},
    AppSession: { get: () => session, async reset() { trace.push('reset-session'); } },
    promptAction: { showToast: args => toasts.push(args.message) },
    logUserFailure() {},
    userErrorMessage: (_error, fallback) => fallback,
    showUserNotice: message => toasts.push(message),
    navigateToHome: async () => routes.push('home'),
    router: { pushUrl: args => routes.push(args.url), back: () => routes.push('back') },
    access: { off: () => trace.push('remove-bluetooth-listener') }
  };
  vm.runInNewContext(compiled.outputText, context);
  const page = new context.exports.LeaderLobbyPage();
  page.btAudioActive = true;
  page.stopRosterStatusAnimation = () => trace.push('stop-roster-animation');
  page.stopDrumAccessRefresh = () => {};
  return { page, requests, toasts, routes, trace };
}

const mainSource = fs.readFileSync('entry/src/main/ets/pages/MainPage.ets', 'utf8');
const mainExitStart = mainSource.indexOf('  private async requestExit(): Promise<void> {');
const mainExitEnd = mainSource.indexOf('  private toggleChrome(): void {', mainExitStart);
const mainBusiness = (mainSource.slice(0, mainSource.indexOf('  @Builder')) +
  mainSource.slice(mainExitStart, mainExitEnd) + '\n}')
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
  .replace('struct MainPage', 'export class MainPage');
const compiledMain = ts.transpileModule(mainBusiness, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiledMain.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function mainHarness() {
  const requests = [];
  const notices = [];
  let session = {
    controller: { isLeader: true },
    leaderStart() { const request = deferred(); requests.push(request); return request.promise; },
    leaderReturnToLobby() { const request = deferred(); requests.push(request); return request.promise; }
  };
  const context = {
    exports: {},
    Map,
    AppSession: { get: () => session },
    defaultBeatPointStates: () => [],
    logUserFailure() {},
    showUserNotice: message => notices.push(message),
    userErrorMessage: (_error, fallback) => fallback,
    router: { back() { assert.fail('A hidden page must not navigate after a late response'); } }
  };
  vm.runInNewContext(compiledMain.outputText, context);
  const page = new context.exports.MainPage();
  page.leader = true;
  page.refresh = () => {};
  page.startVisualLoop = () => {};
  page.startRecordingLoop = () => {};
  page.finishRecordingOnLeave = async () => {};
  return { page, requests, notices, replaceSession: () => { session = {}; } };
}

(async () => {
  const hidden = harness();
  await hidden.page.playBluetoothRouteProbe();
  assert.equal(hidden.requests.length, 0, 'A hidden dialog must not start a route probe');

  const repeated = harness();
  repeated.page.requestBluetoothCalibration();
  const pending = repeated.page.playBluetoothRouteProbe();
  await repeated.page.playBluetoothRouteProbe();
  assert.equal(repeated.requests.length, 1, 'Repeated taps must not restart the playing click pair');
  assert.equal(repeated.page.bluetoothRouteProbePlaying, true);
  assert.equal(repeated.page.bluetoothRouteProbePlayed, false);
  await repeated.page.confirmBluetoothCalibration();
  assert.equal(repeated.routes.length, 0, 'A pending probe cannot confirm the output route');
  repeated.page.bluetoothRouteProbePlayed = true;
  await repeated.page.confirmBluetoothCalibration();
  assert.equal(repeated.routes.length, 0, 'Playing must block confirmation even with a stale played flag');
  repeated.requests[0].resolve(true);
  await pending;
  await repeated.page.confirmBluetoothCalibration();
  assert.deepEqual(repeated.routes, ['pages/TimeCardCalibrationPage']);
  repeated.page.onPageHide();
  repeated.page.aboutToDisappear();
  assert.equal(repeated.trace.filter(item => item === 'stop-probe').length, 0,
    'Confirmed navigation must retain the renderer warmed for the time-card page');

  for (const staleOutcome of ['success', 'failure', 'canceled']) {
    const h = harness();
    h.page.requestBluetoothCalibration();
    const old = h.page.playBluetoothRouteProbe();
    h.page.dismissBluetoothRouteConfirmation();
    h.page.requestBluetoothCalibration();
    const current = h.page.playBluetoothRouteProbe();
    if (staleOutcome === 'failure') h.requests[0].reject(new Error('old failure'));
    else h.requests[0].resolve(staleOutcome === 'success');
    await old;
    assert.equal(h.page.bluetoothRouteProbePlaying, true,
      `Old ${staleOutcome} must not enable replay during the new pair`);
    assert.equal(h.page.bluetoothRouteProbePlayed, false,
      `Old ${staleOutcome} must not mark the new dialog completed`);
    assert.equal(h.toasts.length, 0, `Old ${staleOutcome} must not publish a stale toast`);
    await h.page.playBluetoothRouteProbe();
    assert.equal(h.requests.length, 2, 'A stale completion must not permit a third overlapping probe');
    h.requests[1].resolve(true);
    await current;
    assert.equal(h.page.bluetoothRouteProbePlaying, false);
    assert.equal(h.page.bluetoothRouteProbePlayed, true);
    assert.equal(h.trace.filter(item => item === 'stop-probe').length, 1);
  }

  for (const outcome of ['canceled', 'failure']) {
    const h = harness();
    h.page.requestBluetoothCalibration();
    const play = h.page.playBluetoothRouteProbe();
    if (outcome === 'failure') h.requests[0].reject(new Error('current failure'));
    else h.requests[0].resolve(false);
    await play;
    assert.equal(h.page.bluetoothRouteProbePlaying, false);
    assert.equal(h.page.bluetoothRouteProbePlayed, false);
    assert.equal(h.toasts.length, 0, 'Current probe failures should stay inside the dialog');
    assert.equal(h.page.bluetoothRouteConfirmVisible, true);
    assert.match(h.page.bluetoothRouteStatus, outcome === 'failure' ? /试音失败/ : /试音未完成/);
    await h.page.confirmBluetoothCalibration();
    assert.equal(h.routes.length, 0);
  }

  for (const outcome of ['success', 'failure']) {
    const disconnected = harness();
    disconnected.page.requestBluetoothCalibration();
    const play = disconnected.page.playBluetoothRouteProbe();
    disconnected.page.btAudioActive = false;
    disconnected.page.onBluetoothAudioRouteChanged();
    if (outcome === 'failure') disconnected.requests[0].reject(new Error('disconnected'));
    else disconnected.requests[0].resolve(true);
    await play;
    assert.equal(disconnected.page.bluetoothRouteConfirmVisible, true);
    assert.equal(disconnected.page.bluetoothRouteProbePlayed, false);
    assert.equal(disconnected.page.bluetoothRouteProbePlaying, false);
    assert.equal(disconnected.toasts.length, 0, 'Disconnection must suppress obsolete playback feedback');
    assert.match(disconnected.page.bluetoothRouteStatus, /耳机已断开/);
    await disconnected.page.confirmBluetoothCalibration();
    assert.equal(disconnected.routes.length, 0);
  }

  for (const exit of ['onPageHide', 'aboutToDisappear', 'leaveLobby']) {
    for (const outcome of ['success', 'failure']) {
      const h = harness();
      h.page.requestBluetoothCalibration();
      const play = h.page.playBluetoothRouteProbe();
      await h.page[exit]();
      if (outcome === 'failure') h.requests[0].reject(new Error('late exit failure'));
      else h.requests[0].resolve(true);
      await play;
      assert.equal(h.page.bluetoothRouteConfirmVisible, false, `${exit} must dismiss an active probe`);
      assert.equal(h.page.bluetoothRouteProbePlayed, false);
      assert.equal(h.page.bluetoothRouteProbePlaying, false);
      assert.equal(h.toasts.length, 0, `${exit} must suppress late ${outcome} feedback`);
      assert.equal(h.trace.filter(item => item === 'stop-probe').length, 1);
    }
  }

  const unavailable = harness();
  unavailable.page.requestBluetoothCalibration();
  unavailable.page.btAudioActive = false;
  await unavailable.page.playBluetoothRouteProbe();
  assert.equal(unavailable.requests.length, 0, 'An unavailable Bluetooth route must not start a pair');
  assert.equal(unavailable.toasts.length, 0);
  assert.match(unavailable.page.bluetoothRouteStatus, /未检测到耳机输出/);

  const wrongOutput = harness();
  wrongOutput.page.requestBluetoothCalibration();
  const firstProbe = wrongOutput.page.playBluetoothRouteProbe();
  wrongOutput.requests[0].resolve(true);
  await firstProbe;
  wrongOutput.page.rejectBluetoothRouteConfirmation();
  assert.equal(wrongOutput.page.bluetoothRouteConfirmVisible, true,
    'Choosing a different output must retain the current route-confirmation step');
  assert.equal(wrongOutput.page.bluetoothRouteProbePlayed, false);
  assert.match(wrongOutput.page.bluetoothRouteStatus, /请先把媒体输出切到耳机/);
  assert.equal(wrongOutput.toasts.length, 0);
  await wrongOutput.page.confirmBluetoothCalibration();
  assert.equal(wrongOutput.routes.length, 0, 'A wrong output requires another completed probe');
  const secondProbe = wrongOutput.page.playBluetoothRouteProbe();
  assert.equal(wrongOutput.page.bluetoothRouteStatus, '');
  wrongOutput.requests[1].resolve(true);
  await secondProbe;
  await wrongOutput.page.confirmBluetoothCalibration();
  assert.deepEqual(wrongOutput.routes, ['pages/TimeCardCalibrationPage']);

  assert.match(source, /const BLUETOOTH_ROUTE_CONFIRM_WIDTH: number = 318;/);
  assert.match(source, /const BLUETOOTH_ROUTE_PROBE_BUTTON_HEIGHT: number = 48;/);
  assert.match(source, /return '声音不同步时，可校准耳机';/);
  assert.match(source, /return '耳机设置 ›';/);
  assert.doesNotMatch(actualMethodsBetween('  private soloCalibrationEntryLabel(): string {', '  @Builder'),
    /latencyCalibrationMs|ms/, 'The solo entry should leave compensation details to calibration');

  const hiddenWalk = mainHarness();
  const toggle = hiddenWalk.page.toggle();
  assert.equal(hiddenWalk.page.busy, true);
  hiddenWalk.page.onPageHide();
  hiddenWalk.page.onPageShow();
  await hiddenWalk.page.toggle();
  assert.equal(hiddenWalk.requests.length, 1, 'A pending hidden action must still prevent overlap after showing');
  hiddenWalk.requests[0].reject(new Error('late native playback failure'));
  await toggle;
  assert.equal(hiddenWalk.page.busy, false, 'A hidden action must always release its busy flag');
  assert.equal(hiddenWalk.notices.length, 0, 'Hiding must invalidate the old action feedback');
  const replay = hiddenWalk.page.toggle();
  hiddenWalk.requests[1].reject(new Error('new playback failure'));
  await replay;
  assert.deepEqual(hiddenWalk.notices, ['播放操作失败，请重试']);

  const changedRoom = mainHarness();
  const previousRoomAction = changedRoom.page.toggle();
  changedRoom.replaceSession();
  changedRoom.requests[0].reject(new Error('old room failure'));
  await previousRoomAction;
  assert.equal(changedRoom.page.busy, false);
  assert.equal(changedRoom.notices.length, 0, 'A response from the previous room must not show feedback');

  const hiddenReturn = mainHarness();
  const returning = hiddenReturn.page.requestExit();
  assert.equal(hiddenReturn.page.returningToLobby, true);
  hiddenReturn.page.onPageHide();
  hiddenReturn.requests[0].reject(new Error('late return failure'));
  await returning;
  assert.equal(hiddenReturn.page.returningToLobby, false, 'Hidden return failures must release the navigation guard');
  assert.equal(hiddenReturn.notices.length, 0);

  console.log('PASS: lobby route confirmation keeps failures inline and rejects stale callbacks; walking actions release hidden busy state and suppress previous-room feedback');
})().catch(error => { console.error(error); process.exitCode = 1; });
