// Device logs (2026-10-28): ~60s after the leader backgrounded, the system
// audit reported "use unclaimed mode 5" (bluetoothInteraction) for the live BLE
// advertising/GATT server and cancelled the whole audioPlayback task, muting the
// leader. Exercise the production lifecycle methods so background never keeps
// BLE alive and foreground restores manual-code discovery.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/app/AppSession.ets'), 'utf8');

function slice(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `Missing production code ${start}`);
  return source.slice(from, to);
}

const fields = ['  private leaderInviteRevision: number = 0;',
  '  private leaderAdvertisingLifecycle: Promise<void> = Promise.resolve();',
  '  private leaderAdvertisingPausedForBackground: boolean = false;'];
for (const field of fields) assert.ok(source.includes(field), `Missing field ${field.trim()}`);
assert.match(slice('  static handleAppBackground(): void {', '  /**'), /pauseLeaderAdvertisingForBackground\(\)/);
assert.match(slice('  static handleAppForeground(): void {', '  static handleAppBackground'), /resumeLeaderAdvertisingAfterForeground\(\)/);

const compiled = ts.transpileModule(`export class AppSession {
  private static instance: AppSession | undefined = undefined;
  private shutdownOperation: Promise<void> | undefined = undefined;
  ${fields.join('\n')}
  ${slice('  private pauseLeaderAdvertisingForBackground(): void {', '  private async restoreAppPlayback')}
  ${slice('  async leaderBootstrap(displayName:', '  /** 从编辑页返回大厅')}
  ${slice('  async refreshLeaderP2pGroup():', '  /** 队长单人队伍')}
}`, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true });
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve;
  const promise = new Promise(yes => { resolve = yes; });
  return { promise, resolve };
}

async function flush() {
  for (let turn = 0; turn < 20; turn++) await Promise.resolve();
}

function harness({ holdAdvertise = false } = {}) {
  const calls = [];
  const pending = [];
  let advertising = false;
  const controller = {
    isLeader: true, soloTeam: false, bleInviteAvailable: true,
    invitation: { code: '123456', roomId: 'room' },
    getP2pInvitation() { return this.invitation; },
    configureP2pRoom(value) { this.invitation = value; },
    async startLeader() {},
    hasConnectedFollowers: () => true
  };
  const context = {
    exports: {}, console: { warn() {} },
    createP2pRoomInvitation: () => ({ code: '654321', roomId: 'new', groupName: 'g', passphrase: 'password' }),
    invitationWithGroupCredentials: (draft) => draft,
    SessionBackgroundKeeper: { async start() {} }
  };
  vm.runInNewContext(compiled.outputText, context);
  const Session = context.exports.AppSession;
  const session = new Session();
  Session.instance = session;
  session.controller = controller;
  session.p2p = {
    async isLeaderGroupReady() { return true; },
    async createLeaderGroup() { return { groupName: 'g', passphrase: 'password', ownerInfo: { deviceName: 'l' }, goIpAddress: '1.1.1.1' }; }
  };
  session.bleDiscovery = {
    isBluetoothEnabled: () => true,
    async startLeaderAdvertising(invitation) {
      calls.push('start');
      if (holdAdvertise) { const gate = deferred(); pending.push(gate); await gate.promise; }
      advertising = true;
    },
    async stopLeaderAdvertising() { calls.push('stop'); advertising = false; }
  };
  session.syncEngineFromSession = () => {};
  session.maybeWarmUpRendererForPlayback = async () => {};
  return { session, controller, calls, pending, advertising: () => advertising };
}

(async () => {
  // Background stops BLE and hides the manual code; foreground restores both.
  {
    const h = harness();
    h.session.pauseLeaderAdvertisingForBackground();
    assert.equal(h.controller.bleInviteAvailable, false);
    await flush();
    assert.deepEqual(h.calls, ['stop']);
    assert.equal(h.advertising(), false);
    h.session.resumeLeaderAdvertisingAfterForeground();
    await flush();
    assert.deepEqual(h.calls, ['stop', 'start']);
    assert.equal(h.advertising(), true);
    assert.equal(h.controller.bleInviteAvailable, true);
    // A second foreground without an intervening pause must not re-advertise.
    h.session.resumeLeaderAdvertisingAfterForeground();
    await flush();
    assert.deepEqual(h.calls, ['stop', 'start']);
  }

  // A bootstrap whose native start finishes after backgrounding must not leave BLE running.
  {
    const h = harness({ holdAdvertise: true });
    const bootstrap = h.session.leaderBootstrap('leader');
    await flush();
    assert.equal(h.pending.length, 1);
    h.session.pauseLeaderAdvertisingForBackground();
    h.pending[0].resolve();
    await bootstrap;
    await flush();
    assert.equal(h.advertising(), false, 'late bootstrap advertising must be stopped');
    assert.equal(h.controller.bleInviteAvailable, false);
  }

  // Radio refreshes delivered in background must not restart advertising.
  {
    const h = harness();
    h.session.pauseLeaderAdvertisingForBackground();
    await flush();
    await h.session.refreshLeaderP2pGroup();
    await flush();
    assert.deepEqual(h.calls, ['stop']);
    assert.equal(h.advertising(), false);
  }

  // Quick foreground then background: the serialized final operation is a stop.
  {
    const h = harness({ holdAdvertise: true });
    h.session.pauseLeaderAdvertisingForBackground();
    await flush();
    h.session.resumeLeaderAdvertisingAfterForeground();
    await flush();
    h.session.pauseLeaderAdvertisingForBackground();
    h.pending[0].resolve();
    await flush();
    assert.deepEqual(h.calls, ['stop', 'start', 'stop']);
    assert.equal(h.advertising(), false);
    assert.equal(h.controller.bleInviteAvailable, false);
  }

  // Members never own leader advertising.
  {
    const h = harness();
    h.controller.isLeader = false;
    h.session.pauseLeaderAdvertisingForBackground();
    h.session.resumeLeaderAdvertisingAfterForeground();
    await flush();
    assert.deepEqual(h.calls, []);
  }
  console.log('PASS leader background BLE: pause on background, foreground resume, late bootstrap start, background radio refresh, quick toggle ordering, member no-op');
})().catch(error => { console.error(error); process.exit(1); });
