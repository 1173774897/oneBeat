// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
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

const PEER_ADDRESS = '02:00:00:00:00:01';
const CONNECT = { DISCONNECTED: 0, CONNECTED: 1 };
const DEVICE = { CONNECTED: 0, INVITED: 1, FAILED: 2, AVAILABLE: 3, UNAVAILABLE: 4 };
const REJECTED = '队长已拒绝本次加入请求，请和队长确认后再试一次';
const CONFIRM_TIMEOUT = '系统未完成本次 P2P 确认；请确认队长已收到连接弹窗后再试一次';
const invitation = { groupName: 'DIRECT-OB-test', passphrase: 'test-passphrase', leaderDeviceName: 'Leader' };

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function observe(promise) {
  const result = { state: 'pending', value: undefined, error: undefined };
  result.done = promise.then(value => {
    result.state = 'resolved';
    result.value = value;
  }, error => {
    result.state = 'rejected';
    result.error = error;
  });
  return result;
}

async function flushMicrotasks() {
  for (let i = 0; i < 30; i++) await Promise.resolve();
}

function harness() {
  let now = 0;
  let timerId = 0;
  const timers = new Map();
  const listeners = new Map();
  const calls = { linked: 0, peers: 0, group: 0, connect: 0, cancel: 0, remove: 0, start: 0, stop: 0 };
  const peer = { deviceAddress: PEER_ADDRESS, deviceName: 'Leader', deviceStatus: DEVICE.AVAILABLE,
    groupCapabilities: 1, deviceAddressType: 1 };
  const connected = { connectState: CONNECT.CONNECTED, isGroupOwner: false, groupOwnerAddr: '192.168.49.1' };
  const disconnected = { connectState: CONNECT.DISCONNECTED, isGroupOwner: false, groupOwnerAddr: '' };
  const state = { linked: disconnected, peers: [peer], group: {
    groupName: invitation.groupName, goIpAddress: connected.groupOwnerAddr, isP2pGo: false
  }, linkedRead: undefined, peerRead: undefined, groupRead: undefined, onConnect: undefined };
  const emit = (type, value) => {
    for (const callback of [...(listeners.get(type) ?? [])]) callback(value);
  };
  const wifiManager = {
    P2pConnectState: CONNECT,
    P2pDeviceStatus: DEVICE,
    DeviceAddressType: { RANDOM_DEVICE_ADDRESS: 1 },
    GroupOwnerBand: { GO_BAND_AUTO: 0 },
    isWifiActive: () => true,
    on(type, callback) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(callback);
    },
    off(type, callback) { listeners.get(type)?.delete(callback); },
    async getP2pLinkedInfo() {
      calls.linked++;
      return state.linkedRead ? await state.linkedRead() : state.linked;
    },
    async getP2pPeerDevices() {
      calls.peers++;
      return state.peerRead ? await state.peerRead() : state.peers;
    },
    async getCurrentGroup() {
      calls.group++;
      return state.groupRead ? await state.groupRead() : state.group;
    },
    p2pConnect(config) {
      calls.connect++;
      if (state.onConnect) state.onConnect(config);
    },
    p2pCancelConnect() { calls.cancel++; },
    removeGroup() {
      calls.remove++;
      state.linked = disconnected;
    },
    startDiscoverDevices() { calls.start++; },
    stopDiscoverDevices() { calls.stop++; }
  };
  const mocks = {
    '@kit.ConnectivityKit': { wifiManager },
    '@kit.BasicServicesKit': {},
    './P2pInvitation': { validateP2pRoomInvitation(value) { assert.ok(value.groupName.length > 0); } }
  };
  const context = {
    exports: {},
    require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
      return mocks[name];
    },
    console: { info() {}, warn() {} },
    canIUse: () => true,
    Date: class extends Date { static now() { return now; } },
    setTimeout(callback, delay) {
      const id = ++timerId;
      timers.set(id, { callback, dueAt: now + delay });
      return id;
    },
    clearTimeout(id) { timers.delete(id); }
  };
  vm.runInNewContext(compiled.outputText, context);
  const manager = new context.exports.WifiP2pManager();
  return {
    manager, state, calls, peer, connected, disconnected, emit,
    start(rejectionSignal) {
      return observe(manager.waitForConnection(PEER_ADDRESS, DEVICE.AVAILABLE, 25000,
        () => wifiManager.p2pConnect({ deviceAddress: PEER_ADDRESS }), rejectionSignal));
    },
    listenerCount() { return [...listeners.values()].reduce((sum, handlers) => sum + handlers.size, 0); },
    timerCount() { return timers.size; },
    now: () => now,
    async advanceTo(target) {
      assert.ok(target >= now);
      await flushMicrotasks();
      while (true) {
        const next = [...timers.entries()].filter(([, timer]) => timer.dueAt <= target)
          .sort((a, b) => a[1].dueAt - b[1].dueAt || a[0] - b[0])[0];
        if (!next) break;
        now = next[1].dueAt;
        timers.delete(next[0]);
        next[1].callback();
        await flushMicrotasks();
      }
      now = target;
      await flushMicrotasks();
    }
  };
}

function assertClean(h) {
  assert.equal(h.listenerCount(), 0, 'A settled attempt must remove both P2P event listeners');
  assert.equal(h.timerCount(), 0, 'A settled attempt must clear its timeout and next poll');
}

async function assertRejected(h, work, message) {
  await flushMicrotasks();
  assert.equal(work.state, 'rejected');
  await work.done;
  assert.equal(work.error.message, message);
  assertClean(h);
}

(async () => {
  // CONNECTED precedes DHCP/group-owner address readiness on a real first join.
  // Exercise the public chain: retry preflight must not label our just-created
  // connection as another app's P2P session while its group IP is still pending.
  const firstJoin = harness();
  firstJoin.state.group = { ...firstJoin.state.group, goIpAddress: '' };
  firstJoin.state.onConnect = () => {
    firstJoin.state.linked = firstJoin.connected;
    firstJoin.emit('p2pConnectionChange', firstJoin.connected);
  };
  const firstJoinWork = observe(firstJoin.manager.connectToLeader(invitation));
  await flushMicrotasks();
  assert.equal(firstJoin.calls.connect, 1, 'A fresh join must submit one native connection request');
  assert.equal(firstJoinWork.state, 'pending',
    `The approved link must wait for its delayed group-owner IP instead of failing as foreign P2P: ${firstJoinWork.error?.message ?? firstJoinWork.state}`);
  assert.equal(firstJoin.calls.cancel, 0, 'A successful system confirmation must not be cancelled while DHCP settles');
  assert.equal(firstJoin.calls.remove, 0);
  await firstJoin.advanceTo(499);
  assert.equal(firstJoinWork.state, 'pending');
  firstJoin.state.group = { ...firstJoin.state.group, goIpAddress: '192.168.49.1' };
  await firstJoin.advanceTo(750);
  assert.equal(firstJoinWork.state, 'resolved');
  await firstJoinWork.done;
  assert.equal(firstJoinWork.value, '192.168.49.1');
  assert.equal(firstJoin.manager.ownsGroup, true);
  assert.equal(firstJoin.manager.lastMemberAttemptGroupName, '');
  assert.equal(firstJoin.calls.connect, 1, 'IP readiness must not ask the leader to approve again');
  assert.equal(firstJoin.calls.remove, 0);
  assertClean(firstJoin);

  // A genuinely pre-existing system connection is never ours, even when its
  // group name happens to equal the newly scanned room invitation.
  for (const groupName of ['DIRECT-foreign', invitation.groupName]) {
    const existingGroup = harness();
    existingGroup.state.linked = existingGroup.connected;
    existingGroup.state.group = { ...existingGroup.state.group, groupName };
    const existingWork = observe(existingGroup.manager.connectToLeader(invitation));
    await assertRejected(existingGroup, existingWork,
      '设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试');
    assert.equal(existingGroup.calls.connect, 0, 'Foreign preflight must not submit a connection');
    assert.equal(existingGroup.calls.cancel, 0);
    assert.equal(existingGroup.calls.remove, 0, 'A matching invitation alone cannot authorize foreign group deletion');
    assert.equal(existingGroup.manager.ownsGroup, false);
  }

  // System state can become connected without delivering the corresponding event.
  const missedEvent = harness();
  const missedWork = missedEvent.start();
  await flushMicrotasks();
  assert.equal(missedWork.state, 'pending');
  assert.equal(missedEvent.calls.linked, 1);
  await missedEvent.advanceTo(349);
  missedEvent.state.linked = missedEvent.connected;
  assert.equal(missedWork.state, 'pending');
  await missedEvent.advanceTo(350);
  assert.equal(missedWork.state, 'resolved');
  await missedWork.done;
  assert.equal(missedWork.value, missedEvent.connected);
  assert.equal(missedEvent.calls.linked, 2);
  assert.equal(missedEvent.now(), 350);
  assertClean(missedEvent);

  // A disconnected query is normal while the leader confirmation is still pending.
  const pending = harness();
  const pendingWork = pending.start();
  await pending.advanceTo(1050);
  assert.equal(pendingWork.state, 'pending');
  assert.equal(pending.calls.linked, 4);
  assert.equal(pending.listenerCount(), 2);
  pending.emit('p2pConnectionChange', pending.connected);
  await flushMicrotasks();
  assert.equal(pendingWork.state, 'resolved');
  await pendingWork.done;
  assertClean(pending);

  const readFailure = harness();
  readFailure.state.linkedRead = async () => { throw new Error('Transient system query failure'); };
  const readFailureWork = readFailure.start();
  await flushMicrotasks();
  assert.equal(readFailureWork.state, 'pending');
  readFailure.emit('p2pConnectionChange', readFailure.connected);
  await flushMicrotasks();
  assert.equal(readFailureWork.state, 'resolved');
  await readFailureWork.done;
  assertClean(readFailure);

  // Registration must precede p2pConnect because a cached group can notify synchronously.
  const synchronous = harness();
  synchronous.state.onConnect = () => {
    assert.equal(synchronous.listenerCount(), 2);
    synchronous.emit('p2pConnectionChange', synchronous.connected);
  };
  const synchronousWork = synchronous.start();
  await flushMicrotasks();
  assert.equal(synchronousWork.state, 'resolved');
  await synchronousWork.done;
  assertClean(synchronous);

  const failedPeer = harness();
  const failedPeerWork = failedPeer.start();
  failedPeer.emit('p2pPeerDeviceChange', [{ ...failedPeer.peer, deviceStatus: DEVICE.FAILED }]);
  await assertRejected(failedPeer, failedPeerWork, REJECTED);

  const returnedAvailable = harness();
  const returnedWork = returnedAvailable.start();
  returnedAvailable.emit('p2pPeerDeviceChange', [{ ...returnedAvailable.peer, deviceStatus: DEVICE.INVITED }]);
  returnedAvailable.emit('p2pPeerDeviceChange', [{ ...returnedAvailable.peer, deviceStatus: DEVICE.AVAILABLE }]);
  await assertRejected(returnedAvailable, returnedWork, REJECTED);

  const disconnectedEvent = harness();
  const disconnectedWork = disconnectedEvent.start();
  disconnectedEvent.emit('p2pConnectionChange', disconnectedEvent.disconnected);
  await assertRejected(disconnectedEvent, disconnectedWork, REJECTED);

  const bleRejected = harness();
  const rejection = deferred();
  const bleWork = bleRejected.start(rejection.promise);
  await flushMicrotasks();
  rejection.resolve(new Error(REJECTED));
  await assertRejected(bleRejected, bleWork, REJECTED);

  const timeout = harness();
  const timeoutWork = timeout.start();
  await timeout.advanceTo(24999);
  assert.equal(timeoutWork.state, 'pending');
  await timeout.advanceTo(25000);
  await assertRejected(timeout, timeoutWork, CONFIRM_TIMEOUT);

  // In-flight SDK queries cannot recreate a poll after an event has settled the attempt.
  for (const query of ['linkedRead', 'peerRead']) {
    const late = harness();
    const read = deferred();
    late.state[query] = () => read.promise;
    const lateWork = late.start();
    await flushMicrotasks();
    late.emit('p2pConnectionChange', late.connected);
    await flushMicrotasks();
    assert.equal(lateWork.state, 'resolved');
    await lateWork.done;
    assertClean(late);
    read.resolve(query === 'linkedRead' ? late.disconnected : [late.peer]);
    await flushMicrotasks();
    await late.advanceTo(1000);
    assert.equal(lateWork.state, 'resolved');
    assertClean(late);
  }

  const successfulCandidate = harness();
  successfulCandidate.state.linked = successfulCandidate.connected;
  const candidate = observe(successfulCandidate.manager.connectCandidate(successfulCandidate.peer, invitation));
  await flushMicrotasks();
  assert.equal(candidate.state, 'resolved');
  await candidate.done;
  assert.equal(candidate.value, '192.168.49.1');
  assert.equal(successfulCandidate.calls.connect, 1);
  assert.equal(successfulCandidate.manager.ownsGroup, true);
  assert.equal(successfulCandidate.manager.lastMemberAttemptGroupName, '');
  assertClean(successfulCandidate);

  const foreignGroup = harness();
  foreignGroup.state.linked = foreignGroup.connected;
  foreignGroup.state.group = { ...foreignGroup.state.group, groupName: 'DIRECT-foreign' };
  const foreignWork = observe(foreignGroup.manager.connectCandidate(foreignGroup.peer, invitation));
  await assertRejected(foreignGroup, foreignWork,
    '设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试');
  assert.equal(foreignGroup.manager.ownsGroup, false);
  assert.equal(foreignGroup.calls.remove, 0, 'A nonmatching group must never be adopted just to remove it');
  assert.equal(foreignGroup.calls.cancel, 1);

  const foreignAfterApproval = harness();
  foreignAfterApproval.state.group = { ...foreignAfterApproval.state.group, groupName: 'DIRECT-other-app' };
  foreignAfterApproval.state.onConnect = () => {
    foreignAfterApproval.state.linked = foreignAfterApproval.connected;
    foreignAfterApproval.emit('p2pConnectionChange', foreignAfterApproval.connected);
  };
  const foreignApprovedWork = observe(foreignAfterApproval.manager.connectToLeader(invitation));
  await assertRejected(foreignAfterApproval, foreignApprovedWork,
    '设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试');
  assert.equal(foreignAfterApproval.calls.connect, 1);
  assert.equal(foreignAfterApproval.calls.remove, 0);
  assert.equal(foreignAfterApproval.manager.ownsGroup, false);
  await foreignAfterApproval.manager.abortMemberJoin();
  assert.equal(foreignAfterApproval.calls.remove, 0, 'Join cleanup must also preserve the unowned group');
  assertClean(foreignAfterApproval);

  const noAddress = harness();
  noAddress.state.group = { ...noAddress.state.group, goIpAddress: '' };
  noAddress.state.onConnect = () => {
    noAddress.state.linked = noAddress.connected;
    noAddress.emit('p2pConnectionChange', noAddress.connected);
  };
  const noAddressWork = observe(noAddress.manager.connectToLeader(invitation));
  await noAddress.advanceTo(3999);
  assert.equal(noAddressWork.state, 'pending', 'IP readiness has a bounded grace period after system approval');
  assert.equal(noAddress.manager.ownsGroup, true, 'Exact group identity owns cleanup even before the IP is ready');
  await noAddress.advanceTo(4000);
  await assertRejected(noAddress, noAddressWork, '已连接 P2P，但系统未返回队长地址');
  assert.equal(noAddress.calls.connect, 1, 'A matched but incomplete group must not fall through to foreign preflight');
  assert.equal(noAddress.calls.cancel, 1);
  await noAddress.manager.abortMemberJoin();
  assert.equal(noAddress.calls.remove, 1, 'Join failure cleanup can release only the group this attempt verified');
  assert.equal(noAddress.manager.ownsGroup, false);
  assertClean(noAddress);

  // The native group query can finish after our deadline. Its stale value
  // cannot acquire ownership or recreate a poll after this candidate has failed.
  const lateGroup = harness();
  const lateGroupRead = deferred();
  lateGroup.state.linked = lateGroup.connected;
  lateGroup.state.groupRead = () => lateGroupRead.promise;
  const lateGroupWork = observe(lateGroup.manager.connectCandidate(lateGroup.peer, invitation));
  await lateGroup.advanceTo(3999);
  assert.equal(lateGroupWork.state, 'pending');
  await lateGroup.advanceTo(4000);
  await assertRejected(lateGroup, lateGroupWork, '系统未返回当前 P2P 组信息');
  assert.equal(lateGroup.manager.ownsGroup, false);
  lateGroupRead.resolve(lateGroup.state.group);
  await flushMicrotasks();
  await lateGroup.advanceTo(5000);
  assert.equal(lateGroupWork.state, 'rejected');
  assert.equal(lateGroup.manager.ownsGroup, false, 'A late SDK result cannot resurrect ownership after the deadline');
  assert.equal(lateGroup.calls.remove, 0);
  assertClean(lateGroup);

  const abortedAddress = harness();
  abortedAddress.state.linked = abortedAddress.connected;
  abortedAddress.state.group = { ...abortedAddress.state.group, goIpAddress: '' };
  const abortedWork = observe(abortedAddress.manager.connectCandidate(abortedAddress.peer, invitation));
  await flushMicrotasks();
  assert.equal(abortedWork.state, 'pending');
  assert.equal(abortedAddress.manager.ownsGroup, true);
  await abortedAddress.manager.abortMemberJoin();
  await assertRejected(abortedAddress, abortedWork, '本次加入已取消');
  assert.equal(abortedAddress.calls.remove, 1, 'Leaving during IP readiness must release the verified group');
  abortedAddress.state.group = { ...abortedAddress.state.group, goIpAddress: '192.168.49.1' };
  await abortedAddress.advanceTo(5000);
  assert.equal(abortedAddress.manager.ownsGroup, false);
  assert.equal(abortedWork.state, 'rejected');
  assertClean(abortedAddress);

  // Cancellation can land after CONNECTED resolves but before the awaited
  // continuation installs group readiness, or while that SDK query is in flight.
  // Neither old continuation may accept the group or reclaim ownership later.
  for (const cancelAt of ['connected-event', 'group-query']) {
    const gap = harness();
    const groupRead = deferred();
    let abortWork;
    gap.state.groupRead = () => groupRead.promise;
    gap.state.onConnect = () => {
      gap.state.linked = gap.connected;
      gap.emit('p2pConnectionChange', gap.connected);
      if (cancelAt === 'connected-event') abortWork = observe(gap.manager.abortMemberJoin());
    };
    const gapWork = observe(gap.manager.connectToLeader(invitation));
    await flushMicrotasks();
    if (cancelAt === 'group-query') {
      assert.equal(gap.calls.group, 1);
      abortWork = observe(gap.manager.abortMemberJoin());
    }
    await flushMicrotasks();
    assert.equal(abortWork.state, 'resolved');
    await abortWork.done;
    groupRead.resolve(gap.state.group);
    await flushMicrotasks();
    await assertRejected(gap, gapWork, '本次加入已取消');
    assert.equal(gap.manager.ownsGroup, false,
      `An aborted attempt cannot reacquire group ownership after ${cancelAt}`);
    assert.equal(gap.calls.remove, 0, 'An unverified late group must not authorize removal');
    await gap.advanceTo(5000);
    assert.equal(gap.manager.ownsGroup, false);
    assert.equal(gap.calls.connect, 1, 'Cancelling public join cannot submit another candidate connection');
    assert.equal(gap.calls.start, 1, 'Cancellation must not restart discovery through the candidate retry branch');
    assertClean(gap);
  }

  // A later invitation is not evidence that an old failed request owns a group
  // which replaced it. Exact previous identity alone can authorize reset.
  const replacedAttempt = harness();
  replacedAttempt.manager.lastMemberAttemptGroupName = 'DIRECT-OB-old-attempt';
  replacedAttempt.state.linked = replacedAttempt.connected;
  const replacedWork = observe(replacedAttempt.manager.connectToLeader(invitation));
  await replacedAttempt.advanceTo(200);
  await assertRejected(replacedAttempt, replacedWork,
    '设备正在使用其他 P2P 连接，请先结束投屏、互传或附近共享后重试');
  assert.equal(replacedAttempt.calls.connect, 0);
  assert.equal(replacedAttempt.calls.remove, 0,
    'A newly supplied invitation cannot authorize deletion of an unrelated current group');
  assert.equal(replacedAttempt.manager.ownsGroup, false);

  // A find that began before the leader created its group never sees it (device
  // 2026-10-29: empty peer list for 30s). Discovery restarts while the leader is
  // missing, and the restarted find (a fresh full scan) reports it.
  const staleFind = harness();
  staleFind.state.peers = [];
  staleFind.state.peerRead = async () => (staleFind.calls.start >= 2 ? [staleFind.peer] : []);
  staleFind.state.onConnect = () => {
    staleFind.state.linked = staleFind.connected;
    staleFind.emit('p2pConnectionChange', staleFind.connected);
  };
  const staleFindWork = observe(staleFind.manager.connectToLeader(invitation));
  await staleFind.advanceTo(3000);
  assert.equal(staleFind.calls.connect, 0, 'No leader is visible before discovery restarts');
  // The first poll follows the up-to-3s wait for a discovery event; the restart
  // comes DISCOVERY_RESTART_MS later.
  await staleFind.advanceTo(8000);
  assert.ok(staleFind.calls.start >= 2, 'Discovery restarts while the leader is missing');
  assert.ok(staleFind.calls.stop >= 1, 'The stale find is stopped before restarting');
  assert.equal(staleFind.calls.connect, 1, 'The restarted find reports the leader and the join proceeds');
  await staleFind.advanceTo(15000);
  await staleFindWork.done;
  assert.equal(staleFindWork.state, 'resolved', `Join succeeds after rediscovery: ${staleFindWork.error?.message}`);

  console.log('PASS: first-join approval waits for bounded group/IP readiness; discovery restarts while the leader is missing; P2P event/rejection cleanup and exact group ownership preserve foreign connections');
})().catch(error => { console.error(error); process.exitCode = 1; });
