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
  promise.then(value => { result.state = 'resolved'; result.value = value; },
    error => { result.state = 'rejected'; result.error = error; });
  return result;
}
async function flush() {
  for (let i = 0; i < 30; i++) await Promise.resolve();
}

function harness(options = {}) {
  const trace = [], stages = [], messages = [], attempts = [];
  const storage = new Map();
  const feedback = options.feedback ?? deferred();
  class Attempt {
    constructor() { this.cancelled = false; attempts.push(this); }
    cancel() { if (!this.cancelled) { this.cancelled = true; trace.push('feedback-cancel'); } }
  }
  const background = {
    async start(showMediaCard) {
      trace.push('background'); assert.equal(showMediaCard, false);
      if (options.background) await options.background.promise;
    },
    async stop() { trace.push('background-stop'); }
  };
  const mocks = {
    '../session/SessionController': {},
    '../audio/MetronomeEngine': {},
    '../audio/AudioOutputMonitor': { AudioOutputMonitor: { stop() { trace.push('monitor-stop'); } } },
    '../network/p2p/WifiP2pManager': {},
    '../network/p2p/BleRoomDiscovery': { BleMemberJoinFeedbackAttempt: Attempt },
    '../network/p2p/P2pInvitation': {},
    '../common/Constants': { PROTOCOL_VERSION: 6 },
    '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 1000 + trace.length * 10 } },
    '../common/MeterModel': {},
    '../session/SessionBackgroundKeeper': { SessionBackgroundKeeper: background },
    '../common/UserFeedback': { showUserNotice() {}, logUserFailure() {} },
    '../store/EntitlementStore': { isProDrumMachineAccessible: () => true },
    '@kit.ArkUI': {}
  };
  const context = {
    exports: {}, require(name) {
      assert.ok(Object.hasOwn(mocks, name), `Unexpected dependency ${name}`);
      return mocks[name];
    }, console: { info: message => messages.push(message), warn: message => messages.push(message) },
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) }
  };
  vm.runInNewContext(compiled.outputText, context);
  // Execute actual join/shutdown methods; replace only the platform/service
  // boundaries, not the promises that decide when joining is complete.
  const session = Object.create(context.exports.AppSession.prototype);
  session.controller = {
    async connectMember(host, port, invitation) {
      trace.push('authenticated-clock-sync');
      assert.equal(host, '192.168.49.1'); assert.equal(port, 39001);
      assert.equal(invitation, options.invitation ?? testInvitation);
      if (options.session) await options.session.promise;
      if (options.sessionError) throw options.sessionError;
    },
    async disconnect() { trace.push('disconnect'); }
  };
  session.p2p = {
    async connectToLeader(_invitation, rejection) {
      trace.push('p2p'); assert.equal(typeof rejection.then, 'function');
      if (options.p2p) await options.p2p.promise;
      if (options.p2pError) throw options.p2pError;
      return '192.168.49.1';
    },
    async prepareMemberDiscovery() { trace.push('discovery'); if (options.discovery) await options.discovery.promise; },
    async abortMemberJoin() { trace.push('abort-p2p'); },
    async teardown() { trace.push('teardown'); }
  };
  session.metronome = {
    async ensureRenderer() {
      trace.push('renderer'); if (options.renderer) await options.renderer.promise;
      if (options.rendererError) throw options.rendererError;
    },
    async stopEngine() { trace.push('audio-stop'); }
  };
  session.bleDiscovery = {
    async startMemberJoinFeedback(invitation, attempt) {
      trace.push('feedback-open'); assert.equal(invitation, options.invitation ?? testInvitation);
      assert.equal(attempt, attempts.at(-1));
      return await feedback.promise;
    },
    async resolveInvitationByCode(code, version) {
      trace.push('room-found'); assert.equal(code, '123456'); assert.equal(version, mocks['../common/Constants'].PROTOCOL_VERSION);
      return options.invitation ?? testInvitation;
    },
    async stopLeaderAdvertising() { trace.push('ble-stop'); }
  };
  session.syncEngineFromSession = () => trace.push('engine-sync');
  session.handleTransportFromStorage = () => trace.push('transport');
  session.maybeWarmUpRendererForPlayback = async () => trace.push('warmup');
  session.teamJoinedForWarmup = false;
  return { session, trace, stages, messages, attempts, feedback,
    join: () => observe(session.memberJoinWithInvitation(options.invitation ?? testInvitation,
      stage => stages.push(stage))) };
}
const testInvitation = { roomId: 'synthetic-room', port: 39001 };

(async () => {
  const late = harness();
  const lateResult = late.join(); await flush();
  assert.equal(lateResult.state, 'resolved', 'Successful authenticated join must not wait for pending BLE setup');
  assert.equal(late.attempts[0].cancelled, true);
  assert.deepEqual(late.stages, ['connecting', 'joining', 'preparing']);
  assert.equal(late.session.teamJoinedForWarmup, true);
  const closeWork = deferred(); let closed = 0;
  late.feedback.resolve({ close() { closed++; return closeWork.promise; } }); await flush();
  assert.equal(closed, 1, 'A late feedback channel must still be released');
  assert.equal(lateResult.state, 'resolved', 'An unresolved GATT close must not hold the lobby');
  closeWork.reject(new Error('synthetic BLE close failure')); await flush();
  assert.equal(lateResult.state, 'resolved', 'Cleanup errors must not undo successful joining');

  const failedError = new Error('synthetic network failure');
  const failed = harness({ p2pError: failedError });
  const failedResult = failed.join(); await flush();
  assert.equal(failedResult.state, 'rejected', 'Failed join must not wait for pending BLE setup');
  assert.equal(failedResult.error, failedError, 'Optional cleanup cannot replace the original failure');
  assert.deepEqual(failed.trace, ['feedback-open', 'p2p', 'abort-p2p', 'feedback-cancel']);
  let failedClosed = 0;
  failed.feedback.resolve({ async close() { failedClosed++; throw new Error('synthetic close failure'); } });
  await flush(); assert.equal(failedClosed, 1); assert.equal(failedResult.error, failedError);

  const authentication = deferred();
  const authenticated = harness({ session: authentication });
  const authenticatedResult = authenticated.join(); await flush();
  assert.equal(authenticatedResult.state, 'pending', 'P2P readiness cannot bypass room authentication or initial clock sync');
  assert.ok(!authenticated.trace.includes('renderer'));
  authentication.resolve(); await flush(); assert.equal(authenticatedResult.state, 'resolved');

  const authError = new Error('synthetic authentication failure');
  const rejected = harness({ sessionError: authError });
  const rejectedResult = rejected.join(); await flush();
  assert.equal(rejectedResult.error, authError);
  assert.ok(rejected.trace.includes('abort-p2p') && !rejected.trace.includes('renderer'));

  const renderer = deferred(), background = deferred();
  const prepared = harness({ renderer, background });
  const preparedResult = prepared.join(); await flush();
  assert.equal(preparedResult.state, 'pending', 'Entering the lobby must retain renderer readiness');
  renderer.resolve(); await flush(); assert.equal(preparedResult.state, 'pending');
  assert.ok(prepared.trace.includes('transport') && prepared.trace.includes('background'));
  background.resolve(); await flush(); assert.equal(preparedResult.state, 'resolved');

  const rendererFallback = harness({ rendererError: new Error('synthetic audio failure') });
  const fallbackResult = rendererFallback.join(); await flush();
  assert.equal(fallbackResult.state, 'resolved', 'Existing nonfatal audio allocation behavior remains');

  const networkPending = deferred();
  const shutdown = harness({ p2p: networkPending });
  shutdown.join(); await flush();
  assert.equal(shutdown.attempts[0].cancelled, false);
  await shutdown.session.shutdown();
  assert.equal(shutdown.attempts[0].cancelled, true, 'Session shutdown must cancel feedback while P2P is still pending');
  assert.equal(shutdown.session.memberJoinFeedbackAttempt, undefined);

  const discovery = deferred();
  const code = harness({ discovery });
  const codeResult = observe(code.session.memberJoinByCode(' 123456 ',
    () => code.trace.push('found-callback'), stage => code.stages.push(stage)));
  await flush(); assert.ok(code.trace.includes('found-callback'));
  assert.equal(codeResult.state, 'pending', 'Discovery warmup remains bounded by its existing readiness contract');
  discovery.resolve(); await flush(); assert.equal(codeResult.state, 'resolved');
  assert.deepEqual(code.stages, ['connecting', 'joining', 'preparing']);
  console.log('PASS: actual member join skips optional BLE waits, preserves readiness gates and cancels feedback on failure/shutdown');
})().catch(error => { console.error(error); process.exitCode = 1; });
