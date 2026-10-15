// Run with DevEco's bundled Node; pass typescript/lib/typescript.js and optionally an older source path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const source = fs.readFileSync(process.argv[3] ?? 'entry/src/main/ets/network/p2p/WifiP2pManager.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

const CONNECT = { DISCONNECTED: 0, CONNECTED: 1 };
const DEVICE = { CONNECTED: 0, INVITED: 1, FAILED: 2, AVAILABLE: 3, UNAVAILABLE: 4 };
const FOREIGN_MESSAGE = '设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试';
const invitation = { groupName: 'DIRECT-OB-rejoin', passphrase: 'synthetic-passphrase', leaderDeviceName: 'Leader' };

function observe(promise) {
  const result = { state: 'pending' };
  result.done = promise.then(value => { result.state = 'resolved'; result.value = value; },
    error => { result.state = 'rejected'; result.error = error; });
  return result;
}

async function flush() {
  for (let i = 0; i < 30; i++) await Promise.resolve();
}

function harness(options = {}) {
  let now = 0, nextTimer = 0;
  const timers = new Map(), listeners = new Map();
  const calls = { connect: 0, remove: 0, cancel: 0, stop: 0 };
  const disconnected = { connectState: CONNECT.DISCONNECTED, isGroupOwner: false, groupOwnerAddr: '' };
  const connected = { connectState: CONNECT.CONNECTED, isGroupOwner: false, groupOwnerAddr: '192.168.49.1' };
  const peer = { deviceAddress: '02:00:00:00:00:02', deviceName: 'Leader', deviceStatus: DEVICE.AVAILABLE,
    groupCapabilities: 1, deviceAddressType: 1 };
  const state = { linked: disconnected, removeDelay: options.removeDelay, removeError: options.removeError,
    group: { groupName: invitation.groupName, goIpAddress: '192.168.49.1', isP2pGo: false } };
  const setTimer = (callback, delay) => {
    const id = ++nextTimer;
    timers.set(id, { callback, due: now + delay });
    return id;
  };
  const emit = (type, value) => {
    for (const callback of [...(listeners.get(type) ?? [])]) callback(value);
  };
  const wifiManager = {
    P2pConnectState: CONNECT, P2pDeviceStatus: DEVICE,
    DeviceAddressType: { RANDOM_DEVICE_ADDRESS: 1 }, GroupOwnerBand: { GO_BAND_AUTO: 0 },
    isWifiActive: () => true,
    on(type, callback) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(callback);
    },
    off(type, callback) { listeners.get(type)?.delete(callback); },
    async getP2pLinkedInfo() { return state.linked; },
    async getCurrentGroup() { return state.group; },
    async getP2pPeerDevices() { return [peer]; },
    p2pConnect() {
      calls.connect++;
      state.linked = connected;
      emit('p2pConnectionChange', connected);
    },
    removeGroup() {
      calls.remove++;
      if (state.removeError) throw state.removeError;
      if (state.removeDelay === undefined) return;
      // The SDK accepts removal before the global system link actually falls back.
      // Deliberately omit the event to verify real state polling, not event timing.
      setTimer(() => { state.linked = disconnected; }, state.removeDelay);
    },
    p2pCancelConnect() { calls.cancel++; },
    stopDiscoverDevices() { calls.stop++; }
  };
  const dependencies = {
    '@kit.ConnectivityKit': { wifiManager }, '@kit.BasicServicesKit': {},
    './P2pInvitation': { validateP2pRoomInvitation(value) { assert.equal(value.groupName, invitation.groupName); } }
  };
  const context = {
    exports: {}, require(name) { assert.ok(Object.hasOwn(dependencies, name), `Unexpected dependency ${name}`);
      return dependencies[name]; },
    console: { info() {}, warn() {} }, canIUse: () => true,
    Date: class extends Date { static now() { return now; } },
    setTimeout: setTimer, clearTimeout(id) { timers.delete(id); }
  };
  vm.runInNewContext(compiled.outputText, context);
  const newManager = () => new context.exports.WifiP2pManager();
  return {
    manager: newManager(), newManager, state, calls, connected, disconnected, peer,
    disconnectAfter(delay) { setTimer(() => { state.linked = disconnected; }, delay); },
    async connectMember() {
      const work = observe(this.manager.connectCandidate(peer, invitation));
      await flush();
      assert.equal(work.state, 'resolved', 'The setup must execute a successful actual member connection');
      assert.equal(work.value, '192.168.49.1');
      assert.equal(this.manager.ownsGroup, true);
      assert.equal(this.manager.lastMemberAttemptGroupName, '', 'Successful joins cannot rely on failed-attempt cleanup');
    },
    async advanceTo(target) {
      assert.ok(target >= now);
      await flush();
      while (true) {
        const next = [...timers.entries()].filter(([, timer]) => timer.due <= target)
          .sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
        if (!next) break;
        now = next[1].due;
        timers.delete(next[0]);
        next[1].callback();
        await flush();
      }
      now = target;
      await flush();
    },
    assertClean() {
      assert.equal(timers.size, 0, 'Settled lifecycle work must not leave retry timers');
      assert.equal([...listeners.values()].reduce((sum, handlers) => sum + handlers.size, 0), 0,
        'Settled lifecycle work must not leave P2P listeners');
    }
  };
}

(async () => {
  for (const delay of [300, 1500]) {
    const h = harness({ removeDelay: delay });
    await h.connectMember();
    const leaving = observe(h.manager.teardown());
    await flush();
    assert.equal(leaving.state, 'pending', `Leaving must wait for delayed ${delay}ms system disconnection`);
    assert.equal(h.manager.ownsGroup, true, 'Accepted removeGroup cannot discard ownership before system disconnection');
    assert.equal(h.calls.remove, 1);
    const joining = observe(h.newManager().assertReadyForOneBeat());
    await flush();
    assert.equal(joining.state, 'pending', 'A new session must wait for OneBeat cleanup instead of reporting foreign P2P');
    await h.advanceTo(delay - 1);
    assert.equal(leaving.state, 'pending');
    assert.equal(joining.state, 'pending');
    await h.advanceTo(delay + 150);
    assert.equal(leaving.state, 'resolved');
    assert.equal(joining.state, 'resolved');
    assert.equal(h.manager.ownsGroup, false);
    assert.equal(h.calls.remove, 1, 'Rejoin preflight must not remove a second group');
    assert.equal(h.calls.cancel, 0);
    h.assertClean();
  }

  const concurrent = harness({ removeDelay: 300 });
  await concurrent.connectMember();
  const concurrentFirst = observe(concurrent.manager.teardown());
  const concurrentSecond = observe(concurrent.manager.teardown());
  await flush();
  assert.equal(concurrentFirst.state, 'pending');
  assert.equal(concurrentSecond.state, 'pending');
  assert.equal(concurrent.calls.remove, 1, 'Concurrent exit requests must share the same native group removal');
  const concurrentJoin = observe(concurrent.newManager().assertReadyForOneBeat());
  await concurrent.advanceTo(450);
  assert.equal(concurrentFirst.state, 'resolved');
  assert.equal(concurrentSecond.state, 'resolved');
  assert.equal(concurrentJoin.state, 'resolved');
  assert.equal(concurrent.calls.remove, 1);
  assert.equal(concurrent.manager.ownsGroup, false);
  concurrent.assertClean();

  const immediate = harness({ removeDelay: 300 });
  await immediate.connectMember();
  const immediateLeave = observe(immediate.manager.teardown());
  const immediateJoin = observe(immediate.newManager().assertReadyForOneBeat());
  await flush();
  assert.equal(immediateLeave.state, 'pending');
  assert.equal(immediateJoin.state, 'pending', 'Same-turn rejoin must not bypass release registration after discovery cleanup');
  await immediate.advanceTo(450);
  assert.equal(immediateLeave.state, 'resolved');
  assert.equal(immediateJoin.state, 'resolved');
  assert.equal(immediate.calls.remove, 1);
  immediate.assertClean();

  const unknown = harness();
  await unknown.connectMember();
  unknown.state.linked = { ...unknown.connected, connectState: 2 };
  const unknownLeave = observe(unknown.manager.teardown());
  await flush();
  assert.equal(unknownLeave.state, 'pending', 'An unknown transitional state is not confirmed disconnection');
  assert.equal(unknown.manager.ownsGroup, true);
  assert.equal(unknown.calls.remove, 0, 'An unknown system state must not authorize another native removal');
  unknown.disconnectAfter(300);
  const unknownJoin = observe(unknown.newManager().assertReadyForOneBeat());
  await unknown.advanceTo(299);
  assert.equal(unknownLeave.state, 'pending');
  assert.equal(unknownJoin.state, 'pending');
  await unknown.advanceTo(450);
  assert.equal(unknownLeave.state, 'resolved');
  assert.equal(unknownJoin.state, 'resolved');
  assert.equal(unknown.manager.ownsGroup, false);
  unknown.assertClean();

  const emptyGroup = harness({ removeDelay: 150 });
  await emptyGroup.connectMember();
  emptyGroup.state.group = { ...emptyGroup.state.group, groupName: '' };
  const emptyLeave = observe(emptyGroup.manager.teardown());
  await flush();
  assert.equal(emptyLeave.state, 'rejected', 'Missing SDK group identity cannot prove the app connection was replaced');
  assert.match(emptyLeave.error.message, /P2P 组信息/);
  assert.equal(emptyGroup.manager.ownsGroup, true);
  assert.equal(emptyGroup.calls.remove, 0);
  assert.equal(emptyGroup.calls.cancel, 0);
  emptyGroup.assertClean();
  emptyGroup.state.group = { ...emptyGroup.state.group, groupName: invitation.groupName };
  const emptyRetry = observe(emptyGroup.manager.teardown());
  await emptyGroup.advanceTo(300);
  assert.equal(emptyRetry.state, 'resolved', 'Retry must use the retained owner once the SDK returns group identity');
  assert.equal(emptyGroup.calls.remove, 1);
  assert.equal(emptyGroup.manager.ownsGroup, false);
  emptyGroup.assertClean();

  const timeout = harness();
  await timeout.connectMember();
  const timeoutLeave = observe(timeout.manager.teardown());
  await flush();
  const timeoutJoin = observe(timeout.newManager().assertReadyForOneBeat());
  await timeout.advanceTo(3100);
  assert.equal(timeoutLeave.state, 'rejected', 'An accepted SDK request cannot silently succeed when the link stays connected');
  assert.match(timeoutLeave.error.message, /释放超时/);
  assert.equal(timeout.manager.ownsGroup, true, 'A timed-out removal must retain the right to retry owned cleanup');
  assert.equal(timeoutJoin.state, 'rejected');
  assert.notEqual(timeoutJoin.error.message, FOREIGN_MESSAGE, 'Pending owned cleanup failure is not proof of a foreign group');
  assert.equal(timeout.calls.remove, 1);
  assert.equal(timeout.calls.cancel, 0);
  timeout.assertClean();
  timeout.state.removeDelay = 150;
  const retry = observe(timeout.manager.teardown());
  await timeout.advanceTo(3400);
  assert.equal(retry.state, 'resolved', 'The retained owner must be able to retry after a release timeout');
  assert.equal(timeout.calls.remove, 2);
  assert.equal(timeout.manager.ownsGroup, false);
  timeout.assertClean();

  const sdkError = harness({ removeError: new Error('synthetic removeGroup failure') });
  await sdkError.connectMember();
  const failedLeave = observe(sdkError.manager.teardown());
  await flush();
  assert.equal(failedLeave.state, 'rejected', 'Native removeGroup failure must reach the exit lifecycle');
  assert.match(failedLeave.error.message, /synthetic removeGroup failure/);
  assert.equal(sdkError.manager.ownsGroup, true, 'SDK failure must not abandon ownership');
  sdkError.assertClean();
  sdkError.state.removeError = undefined;
  sdkError.state.removeDelay = 150;
  const retriedSdk = observe(sdkError.manager.teardown());
  await sdkError.advanceTo(300);
  assert.equal(retriedSdk.state, 'resolved');
  assert.equal(sdkError.calls.remove, 2);
  assert.equal(sdkError.manager.ownsGroup, false);
  sdkError.assertClean();

  const foreign = harness();
  foreign.state.linked = foreign.connected;
  foreign.state.group = { ...foreign.state.group, groupName: 'DIRECT-other-app' };
  const foreignPreflight = observe(foreign.manager.assertReadyForOneBeat());
  await flush();
  assert.equal(foreignPreflight.state, 'rejected');
  assert.equal(foreignPreflight.error.message, FOREIGN_MESSAGE);
  await foreign.manager.teardown();
  assert.equal(foreign.calls.remove, 0, 'A fresh manager must preserve a real foreign group');
  assert.equal(foreign.calls.cancel, 0, 'A fresh manager must not cancel another application connection');
  foreign.assertClean();

  const replaced = harness({ removeDelay: 150 });
  await replaced.connectMember();
  replaced.state.group = { ...replaced.state.group, groupName: 'DIRECT-new-foreign-group' };
  await replaced.manager.teardown();
  assert.equal(replaced.manager.ownsGroup, false, 'A stale owned claim must be relinquished after system group replacement');
  assert.equal(replaced.calls.remove, 0, 'The former owner must not remove a different current group');
  assert.equal(replaced.calls.cancel, 0, 'Successful old membership must not become a pending foreign connect cancellation');
  const replacedPreflight = observe(replaced.newManager().assertReadyForOneBeat());
  await flush();
  assert.equal(replacedPreflight.state, 'rejected');
  assert.equal(replacedPreflight.error.message, FOREIGN_MESSAGE);
  replaced.assertClean();
  console.log('PASS: actual P2P leave/rejoin waits for system release, deduplicates concurrent exit, retains ownership on timeout/SDK or missing identity, and preserves foreign groups');
})().catch(error => { console.error(error); process.exitCode = 1; });
