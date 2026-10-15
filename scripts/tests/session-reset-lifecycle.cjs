// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const source = fs.readFileSync('entry/src/main/ets/app/AppSession.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function observe(promise) {
  const result = { state: 'pending' };
  result.done = promise.then(value => {
    result.state = 'resolved'; result.value = value;
  }, error => {
    result.state = 'rejected'; result.error = error;
  });
  return result;
}
async function flush() {
  for (let i = 0; i < 50; i++) await Promise.resolve();
}

function harness() {
  const trace = [], warnings = [], storage = new Map(), errors = new Map(), holds = new Map();
  let controllerCreated = 0;
  let monitorActive = false;
  const cleanup = async stage => {
    trace.push(stage);
    if (holds.has(stage)) await holds.get(stage).promise;
    if (errors.has(stage)) throw errors.get(stage);
  };
  class MockController {
    constructor(_id, isLeader, displayName) {
      controllerCreated++;
      trace.push(`create:${displayName}`);
      this.isLeader = isLeader;
      this.state = 'idle';
      this.lobbyDeparted = false;
    }
    setUiListener(listener) { this.uiListener = listener; }
    async disconnect() { await cleanup('new:controller'); }
  }
  class MockMetronome {
    setBeatCallback(listener) { this.beatListener = listener; }
    async stopEngine() { await cleanup('new:audio'); }
  }
  class MockP2p {
    async teardown() { await cleanup('new:p2p'); }
  }
  class MockBle {
    async stopLeaderAdvertising() { await cleanup('new:ble'); }
  }
  const mocks = {
    '../session/SessionController': { SessionController: MockController },
    '../audio/MetronomeEngine': { MetronomeEngine: MockMetronome },
    '../audio/AudioOutputMonitor': { AudioOutputMonitor: {
      start() { trace.push('monitor-start'); monitorActive = true; },
      stop() {
        trace.push('monitor-stop'); monitorActive = false;
        if (errors.has('monitor-stop')) throw errors.get('monitor-stop');
      }
    } },
    '../network/p2p/WifiP2pManager': { WifiP2pManager: MockP2p },
    '../network/p2p/BleRoomDiscovery': { BleRoomDiscovery: MockBle },
    '../network/p2p/P2pInvitation': {},
    '../common/Constants': {},
    '../common/MonotonicClock': {},
    '../common/MeterModel': {},
    '../session/SessionBackgroundKeeper': { SessionBackgroundKeeper: {
      setControlHandler() {},
      async stop() { await cleanup('background-stop'); }
    } },
    '@kit.ArkUI': {
      router: {
        clear() { trace.push('router-clear'); },
        async replaceUrl(options) { trace.push(`navigate:${options.url}`); }
      },
      promptAction: { showToast(options) { trace.push(`toast:${options.message}`); } }
    }
  };
  const context = {
    exports: {},
    require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
      return mocks[name];
    },
    console: { info() {}, warn(message) { warnings.push(message); } },
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) }
  };
  vm.runInNewContext(compiled.outputText, context);
  const AppSession = context.exports.AppSession;
  // Exercise actual lifecycle methods. Only platform cleanup boundaries are
  // substituted so promise ownership and static barriers remain production code.
  const old = Object.create(AppSession.prototype);
  Object.assign(old, {
    latencyRouteProbeToken: 0,
    latencyRouteProbeOwner: -1,
    controller: {
      async disconnect() { await cleanup('old:controller'); },
      getRemoteSessionEndReason() { return 'leader_exit'; }
    },
    metronome: { async stopEngine() { await cleanup('old:audio'); } },
    bleDiscovery: { async stopLeaderAdvertising() { await cleanup('old:ble'); } },
    p2p: { async teardown() { await cleanup('old:p2p'); } }
  });
  AppSession.instance = old;
  return { AppSession, old, trace, warnings, errors, holds, storage,
    created: () => controllerCreated, monitorActive: () => monitorActive };
}

const OLD_CLEANUP = ['old:controller', 'old:audio', 'old:ble', 'old:p2p', 'monitor-stop', 'background-stop'];
const count = (trace, stage) => trace.filter(value => value === stage).length;

(async () => {
  const concurrent = harness();
  const release = deferred();
  concurrent.holds.set('old:p2p', release);
  const first = observe(concurrent.AppSession.reset());
  const second = observe(concurrent.AppSession.reset());
  concurrent.AppSession.clear();
  const direct = observe(concurrent.old.shutdown());
  const memberA = observe(concurrent.AppSession.prepareMember('A'));
  const memberB = observe(concurrent.AppSession.prepareMember('B'));
  await flush();
  assert.equal(first.state, 'pending');
  assert.equal(second.state, 'pending');
  assert.equal(direct.state, 'pending');
  assert.equal(memberA.state, 'pending');
  assert.equal(memberB.state, 'pending');
  assert.equal(concurrent.created(), 0, 'New session allocation must await actual P2P release');
  assert.deepEqual(concurrent.trace, OLD_CLEANUP.slice(0, 4));
  assert.throws(() => concurrent.AppSession.createMember('early'), /上次队伍连接尚未释放/);
  release.resolve();
  await Promise.all([first.done, second.done, direct.done, memberA.done, memberB.done]);
  assert.equal(memberA.state, 'resolved');
  assert.equal(memberB.value, memberA.value, 'Concurrent preparation must reuse one new session');
  assert.equal(concurrent.created(), 1);
  for (const stage of OLD_CLEANUP) assert.equal(count(concurrent.trace, stage), 1, stage);
  assert.ok(concurrent.trace.indexOf('background-stop') < concurrent.trace.indexOf('create:A'));
  assert.equal(concurrent.monitorActive(), true, 'Old global cleanup must finish before the new monitor starts');
  assert.equal(concurrent.AppSession.retiringSession, undefined);

  const failed = harness();
  const releaseError = new Error('synthetic P2P release failure');
  failed.errors.set('old:p2p', releaseError);
  const failure = observe(failed.AppSession.reset());
  await failure.done;
  assert.equal(failure.error, releaseError);
  assert.equal(failed.AppSession.get(), undefined);
  assert.equal(failed.AppSession.retiringSession, failed.old, 'Failed release must retain the old ownership proof');
  assert.equal(failed.AppSession.resetOperation, undefined, 'Failed shared promise must not permanently poison retries');
  assert.throws(() => failed.AppSession.createLeader('blocked'), /上次队伍连接尚未释放/);
  const retryRelease = deferred();
  failed.errors.delete('old:p2p');
  failed.holds.set('old:p2p', retryRelease);
  const retryA = observe(failed.AppSession.prepareMember('retry'));
  const retryB = observe(failed.AppSession.prepareMember('same'));
  await flush();
  assert.equal(retryA.state, 'pending');
  assert.equal(retryB.state, 'pending');
  assert.equal(failed.created(), 0);
  assert.equal(count(failed.trace, 'old:p2p'), 2, 'Retry must clean the same retiring manager, once');
  retryRelease.resolve();
  await Promise.all([retryA.done, retryB.done]);
  assert.equal(retryA.state, 'resolved');
  assert.equal(retryA.value, retryB.value);
  assert.equal(failed.created(), 1);
  assert.equal(failed.AppSession.retiringSession, undefined);

  for (const stage of OLD_CLEANUP) {
    const cleanupFailure = harness();
    const error = new Error(`synthetic ${stage} failure`);
    cleanupFailure.errors.set(stage, error);
    const work = observe(cleanupFailure.AppSession.reset());
    await work.done;
    assert.equal(work.state, 'rejected', stage);
    assert.equal(work.error, error, stage);
    assert.deepEqual(cleanupFailure.trace, OLD_CLEANUP, `${stage} failure must not skip later cleanup`);
    assert.equal(cleanupFailure.AppSession.retiringSession, cleanupFailure.old);
    cleanupFailure.errors.delete(stage);
    const retried = await cleanupFailure.AppSession.prepareMember('recovered');
    assert.equal(retried, cleanupFailure.AppSession.get());
    assert.equal(cleanupFailure.created(), 1);
    for (const boundary of OLD_CLEANUP) assert.equal(count(cleanupFailure.trace, boundary), 2, boundary);
  }

  // Once a successful shutdown has crossed the barrier, old references can
  // still receive late events; repeating shutdown must not stop the new monitor.
  const postReleaseTrace = [...concurrent.trace];
  await concurrent.old.shutdown();
  assert.deepEqual(concurrent.trace, postReleaseTrace, 'Successful old shutdown must stay idempotent after a new session starts');
  assert.equal(concurrent.monitorActive(), true);
  concurrent.storage.set('lastTransportMessage', 'new-room-transport');
  await concurrent.old.handleRemoteDisband();
  assert.deepEqual(concurrent.trace, postReleaseTrace, 'Late remote callback from an old room must not navigate away from the new room');
  assert.equal(concurrent.storage.get('lastTransportMessage'), 'new-room-transport');

  const remoteRace = harness();
  const remoteRelease = deferred();
  remoteRace.holds.set('old:p2p', remoteRelease);
  const remoteWork = observe(remoteRace.old.handleRemoteDisband());
  const replacement = observe(remoteRace.AppSession.prepareMember('replacement'));
  await flush();
  assert.equal(remoteWork.state, 'pending');
  assert.equal(replacement.state, 'pending');
  remoteRelease.resolve();
  await Promise.all([remoteWork.done, replacement.done]);
  assert.equal(replacement.state, 'resolved');
  assert.equal(remoteRace.created(), 1);
  assert.equal(count(remoteRace.trace, 'router-clear'), 0, 'Replacement during remote cleanup must preserve its page');
  assert.ok(!remoteRace.trace.some(stage => stage.startsWith('navigate:') || stage.startsWith('toast:')));
  assert.equal(remoteRace.monitorActive(), true);

  const remoteExit = harness();
  await remoteExit.old.handleRemoteDisband();
  assert.equal(remoteExit.AppSession.get(), undefined);
  assert.equal(count(remoteExit.trace, 'router-clear'), 1);
  assert.equal(count(remoteExit.trace, 'navigate:pages/TeamPage'), 1);
  assert.equal(count(remoteExit.trace, 'toast:队长已退出，队伍已解散'), 1);

  console.log('PASS session reset lifecycle: confirmed-release barrier, concurrent cleanup, safe retries and late old shutdown');
})().catch(error => { console.error(error); process.exitCode = 1; });
