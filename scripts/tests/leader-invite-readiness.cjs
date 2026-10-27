// Exercise the production bootstrap/refresh methods with controlled native
// completion so stale BLE work cannot publish an available six-digit join code.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2] || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.resolve(__dirname, '../../entry/src/main/ets/app/AppSession.ets'), 'utf8');

function method(start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `Missing production method ${start}`);
  return source.slice(from, to);
}

const revision = source.match(/  private leaderInviteRevision: number = \d+;/);
assert.ok(revision, 'The availability owner must be retained across bootstrap and foreground refresh');
const compiled = ts.transpileModule(`export class AppSession {
  private static instance: AppSession | undefined = undefined;
  private shutdownOperation: Promise<void> | undefined = undefined;
  ${revision[0]}
  ${method('  async leaderBootstrap(displayName:', '  /** 从编辑页返回大厅')}
  ${method('  async refreshLeaderP2pGroup():', '  /** 队长单人队伍')}
}`, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true });
assert.equal((compiled.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error).length, 0);

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() {
  for (let turn = 0; turn < 8; turn++) await Promise.resolve();
}

function harness() {
  const calls = [], warnings = [], advertisements = [];
  let radioOn = true;
  let readyWork = async () => true;
  let createWork = async () => ({ groupName: 'team', passphrase: 'password',
    ownerInfo: { deviceName: 'leader' }, goIpAddress: '192.168.49.1' });
  let stopWork = async () => {};
  let nextRoom = 0;
  const controller = {
    isLeader: true, soloTeam: false, bleInviteAvailable: true, followers: false,
    invitation: { code: '123456', roomId: 'existing' },
    getP2pInvitation() { return this.invitation; },
    configureP2pRoom(value) { this.invitation = value; },
    async startLeader(address) { calls.push(['start-leader', address]); },
    hasConnectedFollowers() { return this.followers; }
  };
  const context = {
    exports: {},
    console: { warn: message => warnings.push(message) },
    createP2pRoomInvitation: () => ({ code: '123456', roomId: `new-${++nextRoom}`, groupName: 'team', passphrase: 'password' }),
    invitationWithGroupCredentials: (draft, groupName, passphrase, name) => ({ ...draft, groupName, passphrase, name }),
    SessionBackgroundKeeper: { async start() { calls.push(['background']); } }
  };
  vm.runInNewContext(compiled.outputText, context);
  const Session = context.exports.AppSession;
  const session = new Session();
  Session.instance = session;
  session.controller = controller;
  session.p2p = {
    async isLeaderGroupReady(invitation) { calls.push(['ready', invitation]); return await readyWork(invitation); },
    async createLeaderGroup(invitation) { calls.push(['create', invitation]); return await createWork(invitation); }
  };
  session.bleDiscovery = {
    isBluetoothEnabled: () => radioOn,
    startLeaderAdvertising(invitation) {
      calls.push(['advertise', invitation]);
      const request = deferred();
      advertisements.push({ ...request, invitation });
      return request.promise;
    },
    async stopLeaderAdvertising() { calls.push(['stop']); await stopWork(); }
  };
  session.syncEngineFromSession = () => calls.push(['sync-audio']);
  session.maybeWarmUpRendererForPlayback = async () => calls.push(['warmup']);
  return { session, Session, controller, calls, warnings, advertisements,
    setRadio(value) { radioOn = value; },
    setReady(work) { readyWork = work; },
    setCreate(work) { createWork = work; },
    setStop(work) { stopWork = work; } };
}

async function bootstrapReadiness() {
  const h = harness();
  const work = h.session.leaderBootstrap('Leader');
  assert.equal(h.controller.bleInviteAvailable, false, 'A new room clears prior availability before P2P setup');
  await flush();
  assert.equal(h.advertisements.length, 1);
  assert.equal(h.controller.bleInviteAvailable, false, 'Advertising has to finish before displaying an available code');
  h.advertisements[0].resolve();
  assert.equal(await work, '192.168.49.1');
  assert.equal(h.controller.bleInviteAvailable, true);
  assert.ok(h.calls.some(item => item[0] === 'background'));

  const failure = harness();
  const failed = failure.session.leaderBootstrap('Leader');
  await flush();
  failure.advertisements[0].reject(new Error('native advertising failed'));
  assert.equal(await failed, '192.168.49.1', 'BLE failure must retain the working P2P/QR room');
  assert.equal(failure.controller.bleInviteAvailable, false);
  assert.equal(failure.warnings.length, 1);
}

async function refreshReadiness() {
  const h = harness();
  const query = deferred();
  h.setReady(() => query.promise);
  const work = h.session.refreshLeaderP2pGroup();
  assert.equal(h.controller.bleInviteAvailable, false, 'P2P revalidation must immediately withdraw stale availability');
  query.resolve(true);
  await flush();
  assert.equal(h.controller.bleInviteAvailable, false);
  h.advertisements[0].resolve();
  await work;
  assert.equal(h.controller.bleInviteAvailable, true);

  for (const stage of ['p2p', 'advertising', 'stop']) {
    const failure = harness();
    const error = new Error(`${stage} failed`);
    if (stage === 'p2p') failure.setReady(async () => { throw error; });
    if (stage === 'stop') {
      failure.setRadio(false);
      failure.setStop(async () => { throw error; });
    }
    const failed = failure.session.refreshLeaderP2pGroup();
    const rejection = assert.rejects(failed, error);
    assert.equal(failure.controller.bleInviteAvailable, false);
    await flush();
    if (stage === 'advertising') failure.advertisements[0].reject(error);
    await rejection;
    assert.equal(failure.controller.bleInviteAvailable, false, `${stage} failure cannot retain an earlier true`);
  }

  const stopped = harness();
  const stop = deferred();
  stopped.setRadio(false);
  stopped.setStop(() => stop.promise);
  const stopping = stopped.session.refreshLeaderP2pGroup();
  await flush();
  assert.equal(stopped.controller.bleInviteAvailable, false, 'A pending native stop cannot leave a usable code on screen');
  stop.resolve();
  await stopping;
  assert.equal(stopped.advertisements.length, 0);
}

async function ownershipAfterAdvertising() {
  for (const entry of ['leaderBootstrap', 'refreshLeaderP2pGroup']) {
    for (const boundary of ['radio-off', 'replaced-session', 'replaced-invitation', 'shutdown']) {
      const h = harness();
      const work = h.session[entry]('Leader');
      await flush();
      assert.equal(h.advertisements.length, 1);
      if (boundary === 'radio-off') h.setRadio(false);
      if (boundary === 'replaced-session') h.Session.instance = {};
      if (boundary === 'replaced-invitation') h.controller.invitation = { ...h.controller.invitation };
      if (boundary === 'shutdown') h.session.shutdownOperation = Promise.resolve();
      h.advertisements[0].resolve();
      await work;
      assert.equal(h.controller.bleInviteAvailable, false, `${entry} must recheck ${boundary} after native completion`);
    }
  }
}

async function bootstrapBeforeInvitation() {
  const h = harness();
  const create = deferred();
  h.controller.invitation = undefined;
  h.setCreate(() => create.promise);
  const bootstrap = h.session.leaderBootstrap('Leader');
  const revision = h.session.leaderInviteRevision;
  await h.session.refreshLeaderP2pGroup();
  assert.equal(h.session.leaderInviteRevision, revision,
    'A radio event before an invitation exists cannot supersede its pending bootstrap');
  assert.equal(h.calls.filter(item => item[0] === 'ready').length, 0);
  create.resolve({ groupName: 'team', passphrase: 'password',
    ownerInfo: { deviceName: 'leader' }, goIpAddress: '192.168.49.1' });
  await flush();
  assert.equal(h.advertisements.length, 1);
  h.advertisements[0].resolve();
  assert.equal(await bootstrap, '192.168.49.1');
  assert.equal(h.controller.bleInviteAvailable, true,
    'The original room must publish successful BLE readiness after an early radio event');
}

async function ownershipBeforeAdvertising() {
  for (const boundary of ['newer-refresh', 'replaced-session', 'replaced-invitation', 'shutdown']) {
    const h = harness();
    const startLeader = deferred();
    h.controller.startLeader = () => startLeader.promise;
    const bootstrap = h.session.leaderBootstrap('Leader');
    await flush();
    assert.equal(h.advertisements.length, 0);
    if (boundary === 'newer-refresh') {
      const refresh = h.session.refreshLeaderP2pGroup();
      await flush();
      h.advertisements[0].resolve();
      await refresh;
      assert.equal(h.controller.bleInviteAvailable, true);
    }
    if (boundary === 'replaced-session') h.Session.instance = {};
    if (boundary === 'replaced-invitation') h.controller.invitation = { ...h.controller.invitation };
    if (boundary === 'shutdown') h.session.shutdownOperation = Promise.resolve();
    startLeader.resolve();
    await bootstrap;
    assert.equal(h.advertisements.length, boundary === 'newer-refresh' ? 1 : 0,
      `A bootstrap superseded by ${boundary} must not restart obsolete BLE advertising`);
    if (boundary === 'newer-refresh') assert.equal(h.controller.bleInviteAvailable, true);
  }

  for (const boundary of ['replaced-session', 'shutdown']) {
    const h = harness();
    if (boundary === 'replaced-session') h.Session.instance = {};
    if (boundary === 'shutdown') h.session.shutdownOperation = Promise.resolve();
    await h.session.refreshLeaderP2pGroup();
    assert.equal(h.calls.length, 0, `A ${boundary} cannot start another connectivity refresh`);
  }
}

async function overlappingRequests() {
  for (const firstEntry of ['leaderBootstrap', 'refreshLeaderP2pGroup']) {
    for (const oldOutcome of ['resolve', 'reject']) {
      const h = harness();
      const older = h.session[firstEntry]('Leader');
      const olderResult = older.catch(error => error);
      await flush();
      const newer = h.session.refreshLeaderP2pGroup();
      await flush();
      assert.equal(h.advertisements.length, 2);
      h.advertisements[1].resolve();
      await newer;
      assert.equal(h.controller.bleInviteAvailable, true);
      h.advertisements[0][oldOutcome](new Error('superseded advertising'));
      await olderResult;
      assert.equal(h.controller.bleInviteAvailable, true, `Older ${firstEntry} ${oldOutcome} cannot overwrite current success`);
    }
  }

  const h = harness();
  const query = deferred();
  h.setReady(() => query.promise);
  const older = h.session.refreshLeaderP2pGroup();
  h.setReady(async () => true);
  const newer = h.session.refreshLeaderP2pGroup();
  await flush();
  h.advertisements[0].resolve();
  await newer;
  query.resolve(false);
  await older;
  assert.equal(h.advertisements.length, 1, 'A superseded P2P query must not restart the current advertisement');
  assert.equal(h.calls.filter(item => item[0] === 'create').length, 0);
  assert.equal(h.controller.bleInviteAvailable, true);
}

async function p2pRecreationBoundaries() {
  const followers = harness();
  followers.controller.followers = true;
  followers.setReady(async () => false);
  const preserved = followers.session.refreshLeaderP2pGroup();
  await flush();
  assert.equal(followers.calls.filter(item => item[0] === 'create').length, 0,
    'A transient P2P query cannot evict connected followers');
  followers.advertisements[0].resolve();
  await preserved;
  assert.equal(followers.controller.bleInviteAvailable, true);

  const h = harness();
  const create = deferred();
  h.setReady(async () => false);
  h.setCreate(() => create.promise);
  const work = h.session.refreshLeaderP2pGroup();
  await flush();
  h.controller.invitation = { code: '654321', roomId: 'newer-room' };
  create.resolve({ goIpAddress: '192.168.49.2' });
  await work;
  assert.equal(h.advertisements.length, 0, 'An invitation replaced during P2P recreation cannot advertise an obsolete code');
  assert.equal(h.controller.bleInviteAvailable, false);
  assert.equal(h.controller.leaderHost, undefined);

  const noInvitation = harness();
  noInvitation.controller.invitation = undefined;
  await noInvitation.session.refreshLeaderP2pGroup();
  assert.equal(noInvitation.controller.bleInviteAvailable, false);
  assert.equal(noInvitation.calls.length, 0);
}

(async () => {
  await bootstrapReadiness();
  await refreshReadiness();
  await bootstrapBeforeInvitation();
  await ownershipBeforeAdvertising();
  await ownershipAfterAdvertising();
  await overlappingRequests();
  await p2pRecreationBoundaries();
  console.log('PASS leader-invite-readiness: native completion, radio/session/invitation ownership, failures and overlapping refreshes');
})().catch(error => { console.error(error); process.exitCode = 1; });
