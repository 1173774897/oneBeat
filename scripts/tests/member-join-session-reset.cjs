// Run with DevEco's bundled Node; pass its typescript/lib/typescript.js path.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(process.argv[2]);

const pageSource = fs.readFileSync('entry/src/main/ets/pages/MemberJoinPage.ets', 'utf8');
const pageBuilderStart = pageSource.indexOf('  build() {');
const pageMethodsStart = pageSource.indexOf('  private async ensureP2pReady():');
assert.ok(pageBuilderStart > 0 && pageMethodsStart > pageBuilderStart,
  'Keep the real member-page lifecycle and join methods outside ArkUI builders');
const pageBusinessSource = (pageSource.slice(0, pageBuilderStart) + pageSource.slice(pageMethodsStart))
  .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
  .replace(/@(?:Entry|Component)\b\s*/g, '')
  .replace(/@State\s+/g, '')
  .replace(/@StorageLink\([^)]*\)\s*/g, '')
  .replace('struct MemberJoinPage', 'export class MemberJoinPage');

// Execute the actual session reset/prepare/create methods. Only the heavy
// native session constructor is replaced with controlled member connections.
const sessionSource = fs.readFileSync('entry/src/main/ets/app/AppSession.ets', 'utf8');
const sessionFieldsStart = sessionSource.indexOf('  private static instance:');
const sessionFieldsEnd = sessionSource.indexOf('  readonly controller:', sessionFieldsStart);
const sessionMethodsStart = sessionSource.indexOf('  static get():');
const sessionMethodsEnd = sessionSource.indexOf('  static handleAppForeground():', sessionMethodsStart);
assert.ok(sessionFieldsStart > 0 && sessionFieldsEnd > sessionFieldsStart &&
  sessionMethodsStart > sessionFieldsEnd && sessionMethodsEnd > sessionMethodsStart);
const sessionBusinessSource = 'export class AppSession {\n' +
  sessionSource.slice(sessionFieldsStart, sessionFieldsEnd) +
  '  constructor(controller) { this.controller = controller; Object.assign(this, makeMember(controller)); }\n' +
  sessionSource.slice(sessionMethodsStart, sessionMethodsEnd) + '\n}\n';

function compile(source) {
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
    reportDiagnostics: true
  });
  assert.equal((result.diagnostics ?? []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0,
    'Actual session and page methods must transpile');
  return result.outputText;
}
const compiledSession = compile(sessionBusinessSource);
const compiledPage = compile(pageBusinessSource);

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const flush = () => new Promise(resolve => setImmediate(resolve));

function harness(options = {}) {
  const cleanup = options.cleanup ?? deferred();
  const join = deferred();
  const trace = [];
  const members = [];
  const routes = [];
  let permissionCalls = 0;
  let accessCalls = 0;
  const context = {
    exports: {},
    Object,
    Date,
    console,
    AppStorage: { get: () => '', setOrCreate() {} },
    SessionController: class {
      constructor(id, leader, displayName) { Object.assign(this, { id, leader, displayName }); }
    },
    getContext: () => ({}),
    ensureTeamNetworkPermissions: () => {
      permissionCalls++;
      return permissionCalls === 1 && options.warmupPermission
        ? options.warmupPermission.promise : Promise.resolve(true);
    },
    verifyTeamNetworkAccess: () => {
      accessCalls++;
      return accessCalls === 1 && options.warmupAccess
        ? options.warmupAccess.promise : Promise.resolve(true);
    },
    ensureBluetoothDiscoveryPermission: async () => true,
    isBluetoothDiscoveryAvailable: () => true,
    teamNetworkAccessUnavailableHint: () => 'Wi-Fi unavailable',
    teamNetworkPermissionDeniedHint: () => 'Permission denied',
    router: { replaceUrl: args => routes.push(args.url) },
    makeMember(controller) {
      const member = {
        controller,
        p2p: {
          async prepareMemberDiscovery() {
            trace.push('discovery');
            if (options.discovery) await options.discovery.promise;
          }
        },
        async memberJoinWithInvitation(_invitation, stage) {
          trace.push('connect-invitation');
          stage('connecting');
          await join.promise;
        },
        async memberJoinByCode(_code, found, stage) {
          trace.push('connect-code');
          found();
          stage('connecting');
          await join.promise;
        }
      };
      members.push(member);
      return member;
    }
  };
  vm.runInNewContext(compiledSession, context);
  const AppSession = context.exports.AppSession;
  context.AppSession = AppSession;
  context.exports = {};
  const oldSession = {
    async shutdown() {
      trace.push('old-shutdown');
      if (options.failCleanupOnce && trace.filter(item => item === 'old-shutdown').length === 1) {
        throw new Error('旧 P2P 清理失败');
      }
      await cleanup.promise;
    }
  };
  AppSession.instance = oldSession;
  vm.runInNewContext(compiledPage, context);
  const page = new context.exports.MemberJoinPage();
  page.displayName = '测试队员';
  page.bluetoothAck = true;
  return { page, AppSession, oldSession, cleanup, join, members, routes, trace };
}

function joinPage(h, method) {
  return method === 'joinInvitation'
    ? h.page.joinInvitation({ code: '123456' }) : h.page.joinWithCode('123456');
}

(async () => {
  for (const method of ['joinInvitation', 'joinWithCode']) {
    const pending = harness();
    const initialization = pending.page.initialize();
    const joining = joinPage(pending, method);
    await flush();
    assert.equal(pending.members.length, 0, `${method} must not create a member before old cleanup finishes`);
    assert.equal(pending.trace.filter(item => item.startsWith('connect-')).length, 0,
      `${method} must not connect while the previous P2P group is still being released`);
    assert.equal(pending.AppSession.get(), undefined);
    assert.equal(pending.page.joining, true);
    pending.cleanup.resolve();
    await flush();
    assert.equal(pending.trace.filter(item => item === 'old-shutdown').length, 1,
      'Initialization and join must share a single in-flight cleanup');
    assert.equal(pending.members.length, 1, 'Initialization must not replace the member created by join');
    assert.equal(pending.AppSession.get().controller.displayName, '测试队员');
    assert.equal(pending.AppSession.get().controller.bluetoothAcknowledged, true);
    pending.join.resolve();
    await Promise.all([initialization, joining]);
    assert.deepEqual(pending.routes, ['pages/LeaderLobbyPage']);
    assert.equal(pending.page.joining, false);

    for (const pendingWarmup of ['warmupPermission', 'warmupAccess', 'discovery']) {
      const gate = deferred();
      const ready = harness({ [pendingWarmup]: gate });
      ready.cleanup.resolve();
      const warmup = ready.page.initialize();
      await flush();
      assert.equal(ready.members.length, 1);
      const member = ready.AppSession.get();
      const fastJoin = joinPage(ready, method);
      await flush();
      assert.equal(ready.trace.filter(item => item.startsWith('connect-')).length, 1,
        `${method} must not wait for ${pendingWarmup} in the page's background initialization`);
      assert.equal(ready.AppSession.get(), member, 'Join must reuse the prepared member');
      const joiningStatus = ready.page.status;
      gate.resolve(pendingWarmup === 'warmupAccess' ? false : true);
      await warmup;
      assert.equal(ready.page.status, joiningStatus, 'Late warmup must not overwrite joining progress');
      assert.equal(ready.page.wirelessSettingsAvailable, false,
        'Late background access failure must not change the active join affordance');
      if (pendingWarmup !== 'discovery') assert.equal(ready.trace.includes('discovery'), false,
        'Obsolete initialization must not start discovery after join has begun');
      ready.join.resolve();
      await fastJoin;
      assert.deepEqual(ready.routes, ['pages/LeaderLobbyPage']);
    }

    const failed = harness({ failCleanupOnce: true });
    failed.cleanup.resolve();
    await failed.page.initialize();
    assert.equal(failed.members.length, 0, 'Failed cleanup must retain the previous session for retry');
    assert.match(failed.page.status, /准备加入失败：旧 P2P 清理失败/);
    assert.equal(failed.AppSession.retiringSession, failed.oldSession);
    const retry = joinPage(failed, method);
    await flush();
    assert.equal(failed.trace.filter(item => item === 'old-shutdown').length, 2,
      `${method} must retry retained old-session cleanup after initialization failure`);
    assert.equal(failed.members.length, 1);
    failed.join.resolve();
    await retry;
    assert.deepEqual(failed.routes, ['pages/LeaderLobbyPage']);
    assert.equal(failed.AppSession.retiringSession, undefined);
  }

  console.log('PASS: actual member-page joins wait for old-session cleanup, reuse one prepared member, bypass pending discovery prewarm, reject stale status updates and retry failed cleanup');
})().catch(error => { console.error(error); process.exitCode = 1; });
