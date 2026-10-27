// Execute the lobby's initialization with deferred external work. Local roster
// publication may precede readiness, but permissions and room ownership may not.
const assert = require('node:assert/strict');
const { load, ets, plain } = require('./drum-editor-preview.cjs');
const { lobbyBusinessSource, bodyEnd } = require('./solo-roster-reorder.cjs');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() {
  for (let turn = 0; turn < 6; turn++) await Promise.resolve();
}

function controllerFor(name = '队长', soloTeam = false) {
  const members = [{ id: 'leader', displayName: name, avatarKey: 'cloud' }];
  return {
    members, soloTeam, isLeader: true, bpm: 120, beatsPerBar: 4, beatUnit: 4,
    rhythm: 0, drumProgram: '', sceneKey: 'sunset_coast', lobbyDeparted: false,
    getMembers: () => members.slice(), getLocalMemberId: () => 'leader',
    buildJoinQrPayload() { return this.soloTeam ? '' : this.qr ?? ''; },
    isLocalLobbyReady: () => true, canLeaderStartWalk: () => true,
    async updateSceneKey(key) { this.sceneKey = key; }
  };
}

function harness(params = { solo: '1', displayName: '新队长' }, { usableCache = false } = {}) {
  const store = deferred();
  const reset = deferred();
  const permissions = deferred();
  const access = deferred();
  const bluetooth = deferred();
  const bootstrap = deferred();
  const events = [];
  const errors = [];
  let activeSession;
  let createdSession;
  let paidSceneAccessible = true;
  const AppSession = {
    get: () => activeSession,
    reset() {
      events.push('reset');
      activeSession = undefined;
      return reset.promise;
    },
    createLeader(name) {
      events.push('create');
      const controller = controllerFor(name);
      createdSession = {
        controller,
        leaderBootstrapSolo(displayName) {
          events.push('solo-bootstrap');
          controller.soloTeam = true;
          controller.members.push({ id: 'solo-bot', displayName: '搭档', avatarKey: 'braids' });
          return bootstrap.promise;
        },
        leaderBootstrap(displayName) {
          events.push('team-bootstrap');
          return bootstrap.promise.then(() => { controller.qr = 'real-ready-invitation'; });
        }
      };
      activeSession = createdSession;
      return createdSession;
    }
  };
  const { LeaderLobbyPage } = load(lobbyBusinessSource(), {}, {
    AppSession, Scroller: class {}, COMIC_CONTROL_INK_OFFSET: 2, COMIC_CARD_INK_OFFSET: 4,
    router: { getParams: () => params }, getContext: () => ({}),
    refreshStoreEntitlementsNow() { events.push('store'); return store.promise; },
    ensureTeamNetworkPermissions() { events.push('permissions'); return permissions.promise; },
    verifyTeamNetworkAccess() { events.push('access'); return access.promise; },
    ensureBluetoothDiscoveryPermission() { events.push('bluetooth'); return bluetooth.promise; },
    teamNetworkPermissionDeniedHint: () => '请授予组队网络权限',
    teamNetworkAccessUnavailableHint: () => '请开启组队网络',
    logUserFailure: (scope, error) => errors.push([scope, error]),
    userErrorMessage: (error, fallback) => error?.message || fallback,
    hasUsableEntitlementCache: () => usableCache,
    isSceneAccessible: key => key === 'sunset_coast' || paidSceneAccessible,
    resolveDrumAccess: () => ({ allowed: paidSceneAccessible,
      source: paidSceneAccessible ? 'monthly' : 'locked', expiresAt: 0 }),
    isRandomAvatar: key => key === 'random', isRandomPoolCharacter: () => false,
    clearInterval: () => assert.fail('Initialization must not start or own page timers')
  });
  const page = new LeaderLobbyPage();
  const publications = [];
  const refresh = page.refresh.bind(page);
  page.refresh = () => {
    refresh();
    publications.push({ session: activeSession, members: plain(page.members) });
  };
  return {
    page, store, reset, permissions, access, bluetooth, bootstrap, events, errors, publications,
    get createdSession() { return createdSession; },
    replace(session) { activeSession = session; },
    revokePaidScene() { paidSceneAccessible = false; },
    async enterFresh() {
      const operation = page.initialize();
      reset.resolve();
      await flush();
      return { operation };
    }
  };
}

async function verifySoloEarlyPaint() {
  const h = harness();
  const operation = h.page.initialize();
  assert.deepEqual(h.events, ['store', 'reset'], 'Store refresh starts in parallel with retiring the old room');
  assert.equal(h.createdSession, undefined, 'A replacement room must wait for the old renderer/network teardown');
  h.reset.resolve();
  await flush();
  assert.deepEqual(h.events, ['store', 'reset', 'create', 'solo-bootstrap']);
  assert.deepEqual(plain(h.page.members.map(member => member.id)), ['leader', 'solo-bot'],
    'The synchronous solo setup, including its partner, paints before native bootstrap and store finish');
  assert.equal(h.page.members[0].displayName, '新队长');
  assert.equal(h.page.soloTeam, true, 'Solo controls must use the real session mode on the first populated frame');
  assert.equal(h.page.loading, true);
  assert.equal(h.page.primaryLobbyActive(), false, 'Early roster paint cannot enable an unprepared departure');
  assert.equal(h.page.randomPreviewReady(), false, 'A newly visible mystery avatar still waits for room readiness');
  h.bootstrap.resolve();
  await flush();
  assert.equal(h.page.loading, true, 'The existing fresh-entitlement readiness barrier remains intact');
  assert.equal(h.page.primaryLobbyActive(), false);
  h.store.resolve();
  await operation;
  assert.equal(h.page.loading, false);
  assert.equal(h.page.failed, false);
  assert.equal(h.page.primaryLobbyActive(), true);
  assert.equal(h.page.status, '');

  const failed = harness();
  const { operation: failing } = await failed.enterFresh();
  failed.store.resolve();
  failed.bootstrap.reject(new Error('本机队伍启动失败'));
  await failing;
  assert.equal(failed.page.members.length, 2);
  assert.equal(failed.page.failed, true, 'Bootstrap failure still reports failure after its roster was painted');
  assert.equal(failed.page.loading, false);
  assert.equal(failed.page.status, '本机队伍启动失败');
  assert.equal(failed.page.primaryLobbyLabel(), '重试创建');
}

async function verifyTeamEarlyPaintAndPermissions() {
  const h = harness({ displayName: '多人队长' });
  const { operation } = await h.enterFresh();
  assert.deepEqual(plain(h.page.members.map(member => member.displayName)), ['多人队长'],
    'The local team leader is visible while the system permission prompt is pending');
  assert.equal(h.page.soloTeam, false);
  assert.deepEqual(h.events, ['store', 'reset', 'create', 'permissions']);
  assert.equal(h.page.primaryLobbyActive(), false);
  assert.equal(h.page.qr, '', 'Early local paint cannot invent a ready room invitation');
  h.permissions.resolve(true);
  await flush();
  assert.deepEqual(h.events.slice(-1), ['access']);
  assert.equal(h.page.loading, true);
  h.access.resolve(true);
  await flush();
  assert.deepEqual(h.events.slice(-1), ['bluetooth']);
  h.bluetooth.resolve(true);
  await flush();
  assert.deepEqual(h.events.slice(-1), ['team-bootstrap']);
  assert.equal(h.page.invite, false, 'The invite sheet must wait for real bootstrap output');
  assert.equal(h.page.primaryLobbyActive(), false);
  h.store.resolve();
  await flush();
  assert.equal(h.page.loading, true, 'A fast store response cannot bypass pending room bootstrap');
  h.bootstrap.resolve();
  await operation;
  assert.equal(h.page.loading, false);
  assert.equal(h.page.failed, false);
  assert.equal(h.page.invite, true);
  assert.equal(h.page.qr, 'real-ready-invitation');
  assert.equal(h.page.primaryLobbyActive(), true);

  for (const failure of ['permission', 'access']) {
    const denied = harness({ displayName: '待授权队长' });
    const { operation: failing } = await denied.enterFresh();
    denied.store.resolve();
    denied.permissions.resolve(failure !== 'permission');
    await flush();
    if (failure === 'access') denied.access.resolve(false);
    await failing;
    assert.equal(denied.page.members.length, 1, 'A failed permission keeps the already-painted real leader visible');
    assert.equal(denied.page.failed, true, 'Permission failures remain actionable, rather than hidden by early paint');
    assert.equal(denied.page.loading, false);
    assert.equal(denied.page.primaryLobbyLabel(), '重试创建');
    assert.equal(denied.page.primaryLobbyActive(), true);
    assert.equal(denied.page.invite, false);
    assert.equal(denied.events.includes('team-bootstrap'), false);
    assert.match(denied.page.status, /请(?:授予|开启)组队网络/);
  }
}

async function verifyReuseAndStoreFailure() {
  const reused = harness({ reuse: '1' });
  const controller = controllerFor('保留的队员', true);
  const session = { controller };
  reused.replace(session);
  const operation = reused.page.initialize();
  assert.deepEqual(plain(reused.page.members.map(member => member.displayName)), ['保留的队员'],
    'Reused rooms paint synchronously, even with a pending store refresh');
  assert.deepEqual(reused.events, ['store'], 'Reentry must not recreate the room or rerun permissions');
  assert.equal(reused.page.loading, true);
  assert.equal(reused.page.primaryLobbyActive(), false);
  const storeError = new Error('store offline');
  reused.store.reject(storeError);
  await operation;
  assert.equal(reused.page.failed, false, 'Entitlement refresh failure does not fail an existing local room');
  assert.equal(reused.page.loading, false);
  assert.equal(reused.page.primaryLobbyActive(), true);
  assert.ok(reused.errors.some(([scope, error]) => scope === 'lobby-store-refresh' && error === storeError),
    'Background store failures remain logged and handled');
}

async function verifyValidCacheFastReady() {
  const h = harness({ solo: '1', displayName: '缓存队长' }, { usableCache: true });
  const { operation } = await h.enterFresh();
  assert.equal(h.page.members.length, 2);
  assert.equal(h.page.loading, true, 'A valid cache still cannot bypass native room preparation');
  assert.equal(h.page.primaryLobbyActive(), false);
  h.bootstrap.resolve();
  await flush();
  assert.equal(h.page.loading, false, 'A usable persisted cache removes store network latency from room readiness');
  assert.equal(h.page.primaryLobbyActive(), true);
  await operation;
  const storeError = new Error('background refresh offline');
  h.store.reject(storeError);
  await flush();
  assert.equal(h.page.failed, false, 'A failed background refresh cannot invalidate an already-ready cached room');
  assert.ok(h.errors.some(([scope, error]) => scope === 'lobby-store-refresh' && error === storeError));

  const reused = harness({ reuse: '1' }, { usableCache: true });
  const controller = controllerFor('缓存返回队长', true);
  reused.replace({ controller });
  const reentry = reused.page.initialize();
  assert.equal(reused.page.members.length, 1, 'Cached reentry paints synchronously');
  await flush();
  assert.equal(reused.page.loading, false, 'Cached reentry becomes ready while its refresh is still pending');
  assert.equal(reused.page.primaryLobbyActive(), true);
  assert.deepEqual(reused.events, ['store']);
  await reentry;
  reused.store.resolve();
  await flush();
}

async function verifyLateInitializationOwnership() {
  const resetCanceled = harness();
  const canceled = resetCanceled.page.initialize();
  resetCanceled.page.onPageHide();
  resetCanceled.reset.resolve();
  resetCanceled.store.resolve();
  await canceled;
  assert.equal(resetCanceled.createdSession, undefined, 'A page hidden during teardown cannot create a late room');
  assert.equal(resetCanceled.publications.length, 0);

  for (const waitAt of ['permissions', 'bootstrap', 'store']) {
    const h = harness(waitAt === 'permissions' ? {} : { solo: '1' });
    const { operation } = await h.enterFresh();
    const originalMembers = plain(h.page.members);
    const publishedBeforeReplacement = h.publications.length;
    if (waitAt === 'store') {
      h.bootstrap.resolve();
      await flush();
    }
    const replacement = { controller: controllerFor('另一个房间', true) };
    h.replace(replacement);
    h.permissions.resolve(true);
    h.access.resolve(true);
    h.bluetooth.resolve(true);
    h.bootstrap.resolve();
    h.store.resolve();
    await operation;
    assert.deepEqual(plain(h.page.members), originalMembers,
      `Late ${waitAt} completion cannot replace this page's roster with another room`);
    assert.equal(h.publications.length, publishedBeforeReplacement,
      `Late ${waitAt} completion cannot publish any state into the replacement room`);
    assert.equal(h.page.failed, false);
  }

  const hidden = harness();
  const { operation } = await hidden.enterFresh();
  const publications = hidden.publications.length;
  hidden.page.onPageHide();
  hidden.bootstrap.reject(new Error('late native failure'));
  hidden.store.resolve();
  await operation;
  assert.equal(hidden.publications.length, publications);
  assert.equal(hidden.page.failed, false, 'A hidden page must not surface an obsolete initialization error');
}

async function verifyRefreshedSceneAccess() {
  const h = harness({ reuse: '1' });
  const controller = controllerFor('场景队长', true);
  controller.sceneKey = 'neon_street';
  h.replace({ controller });
  const operation = h.page.initialize();
  assert.equal(h.page.selectedSceneKey, 'neon_street', 'First paint can use the locally cached scene');
  assert.equal(h.page.members.length, 1);
  h.revokePaidScene();
  h.store.resolve();
  await operation;
  assert.equal(controller.sceneKey, 'sunset_coast', 'Fresh revocation updates the authoritative room, not only storage');
  assert.equal(h.page.selectedSceneKey, 'sunset_coast', 'Final refresh cannot restore the revoked cached scene');
  assert.equal(h.page.failed, false);
  assert.equal(h.page.loading, false);
  assert.equal(h.page.primaryLobbyActive(), true);

  const stale = harness({ reuse: '1' });
  const original = controllerFor('原场景队长', true);
  original.sceneKey = 'neon_street';
  const changingScene = deferred();
  const changes = [];
  original.updateSceneKey = async key => { changes.push(key); await changingScene.promise; original.sceneKey = key; };
  stale.replace({ controller: original });
  const late = stale.page.initialize();
  stale.revokePaidScene();
  stale.store.resolve();
  await flush();
  assert.deepEqual(changes, ['sunset_coast']);
  assert.equal(stale.page.loading, true, 'Readiness waits for authoritative scene reconciliation');
  const publications = stale.publications.length;
  const replacement = controllerFor('新场景队长', true);
  replacement.sceneKey = 'neon_street';
  stale.replace({ controller: replacement });
  changingScene.resolve();
  await late;
  assert.equal(stale.publications.length, publications, 'A late scene update cannot paint a replacement room');
  assert.equal(replacement.sceneKey, 'neon_street', 'Reconciliation only mutates the session that started it');
  assert.equal(stale.page.failed, false);
}

async function verifyCachedBackgroundRevocation() {
  const h = harness({ reuse: '1' }, { usableCache: true });
  const controller = controllerFor('后台刷新队长', true);
  controller.sceneKey = 'neon_street';
  h.replace({ controller });
  const initialization = h.page.initialize();
  await flush();
  assert.equal(h.page.loading, false);
  assert.equal(h.page.selectedSceneKey, 'neon_street');
  await initialization;
  h.revokePaidScene();
  h.store.resolve();
  h.page.onStoreEntitlementsChanged();
  await flush();
  assert.equal(h.page.drumAccessAllowed, false, 'Background refresh updates the displayed drum entitlement');
  assert.equal(controller.sceneKey, 'sunset_coast',
    'A refreshed revocation after cached readiness reconciles the authoritative leader scene');
  assert.equal(h.page.selectedSceneKey, 'sunset_coast');
  assert.equal(h.page.loading, false, 'Background refresh must not restart the ready lobby');
  assert.equal(h.page.failed, false);

  const stale = harness({ reuse: '1' }, { usableCache: true });
  const original = controllerFor('原房间队长', true);
  original.sceneKey = 'neon_street';
  const changingScene = deferred();
  const changes = [];
  original.updateSceneKey = async key => { changes.push(key); await changingScene.promise; original.sceneKey = key; };
  stale.replace({ controller: original });
  const ready = stale.page.initialize();
  await flush();
  assert.equal(stale.page.loading, false);
  await ready;
  stale.revokePaidScene();
  stale.store.resolve();
  stale.page.onStoreEntitlementsChanged();
  await flush();
  assert.deepEqual(changes, ['sunset_coast']);
  const publications = stale.publications.length;
  const replacement = controllerFor('替换的房间队长', true);
  replacement.sceneKey = 'neon_street';
  stale.replace({ controller: replacement });
  changingScene.resolve();
  await flush();
  assert.equal(stale.publications.length, publications,
    'A late background reconciliation cannot refresh a replacement room');
  assert.equal(replacement.sceneKey, 'neon_street');

  const follower = harness({ reuse: '1' }, { usableCache: true });
  const member = controllerFor('队员', false);
  member.isLeader = false;
  member.sceneKey = 'neon_street';
  const memberChanges = [];
  member.updateSceneKey = async key => { memberChanges.push(key); };
  follower.replace({ controller: member });
  await follower.page.initialize();
  follower.revokePaidScene();
  follower.store.resolve();
  follower.page.onStoreEntitlementsChanged();
  await flush();
  assert.deepEqual(memberChanges, [], 'A follower cannot overwrite the leader scene because its own access changed');
  assert.equal(follower.page.selectedSceneKey, 'neon_street');

  for (const blockedState of ['hidden', 'leaving']) {
    const blocked = harness({ reuse: '1' }, { usableCache: true });
    const leader = controllerFor('离开的队长', true);
    leader.sceneKey = 'neon_street';
    const session = { controller: leader };
    const blockedChanges = [];
    leader.updateSceneKey = async key => { blockedChanges.push(key); };
    blocked.replace(session);
    await blocked.page.initialize();
    if (blockedState === 'hidden') blocked.page.onPageHide();
    else blocked.page.leavingLobby = true;
    blocked.revokePaidScene();
    blocked.store.resolve();
    blocked.page.onStoreEntitlementsChanged();
    await flush();
    assert.deepEqual(blockedChanges, [], `A ${blockedState} lobby cannot change a room scene on a background entitlement event`);
  }

  const replaced = harness({ reuse: '1' }, { usableCache: true });
  const retired = controllerFor('旧队长', true);
  retired.sceneKey = 'neon_street';
  const retiredChanges = [];
  retired.updateSceneKey = async key => { retiredChanges.push(key); };
  const retiredSession = { controller: retired };
  replaced.replace(retiredSession);
  await replaced.page.initialize();
  replaced.revokePaidScene();
  replaced.store.resolve();
  replaced.replace({ controller: controllerFor('新队长', true) });
  await replaced.page.reconcileLobbySceneAccess(retiredSession);
  assert.deepEqual(retiredChanges, [], 'A captured reconciliation must not mutate a session that has already been replaced');
}

function verifyStableAvatarSubtrees() {
  const source = ets('pages/LeaderLobbyPage.ets');
  const start = source.indexOf('  private rosterMemberSlot(member: SessionMember)');
  assert.ok(start > 0);
  const slot = source.slice(start, bodyEnd(source, source.indexOf('{', start)));
  assert.match(slot, /if\s*\(this\.soloTeam\s*&&\s*this\.leader\)/,
    'Solo avatar subtree identity follows room mode, rather than transient loading state');
  assert.doesNotMatch(slot, /if\s*\(this\.soloRosterReorderEnabled\(\)\)/,
    'Readiness changes must not destroy and rebuild every avatar and image');
  const begin = source.slice(source.indexOf('  private beginRosterDrag('), source.indexOf('  private updateRosterDrag('));
  assert.match(begin, /!this\.soloRosterReorderEnabled\(\)/,
    'Preserving the gesture subtree must not enable sorting before preparation finishes');
}

async function main() {
  await verifySoloEarlyPaint();
  await verifyTeamEarlyPaintAndPermissions();
  await verifyReuseAndStoreFailure();
  await verifyValidCacheFastReady();
  await verifyLateInitializationOwnership();
  await verifyRefreshedSceneAccess();
  await verifyCachedBackgroundRevocation();
  verifyStableAvatarSubtrees();
  console.log('PASS lobby initial render: early fresh/reused roster, usable-cache fast readiness, no-cache store barrier, deferred permissions/bootstrap, background scene revocation, stable avatar subtrees, canceled/replaced room isolation');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
