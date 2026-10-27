// Execute the lobby's real Bluetooth invitation state and action lifecycle.
const assert = require('node:assert/strict');
const { load, ets } = require('./drum-editor-preview.cjs');
const { lobbyBusinessSource, bodyEnd } = require('./solo-roster-reorder.cjs');

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() {
  for (let turn = 0; turn < 12; turn++) await Promise.resolve();
}

function harness() {
  const calls = [];
  const notices = [];
  const errors = [];
  const permission = deferred();
  const settings = deferred();
  const handlers = new Map();
  let bluetoothState = 0;
  let stateError;
  let permissionWork = permission.promise;
  let settingsWork = settings.promise;
  let supported = true;
  let refreshWork = Promise.resolve();
  let activeSession;
  const controller = {
    isLeader: true, soloTeam: false, bpm: 120, beatsPerBar: 4, beatUnit: 4,
    rhythm: 0, drumProgram: '', sceneKey: 'sunset_coast', lobbyDeparted: false,
    joinCode: '123456', bleInviteAvailable: false,
    getMembers: () => [{ id: 'leader', displayName: '队长', avatarKey: 'cloud' }],
    getLocalMemberId: () => 'leader',
    buildJoinQrPayload: () => 'ready-room-qr',
    isLocalLobbyReady: () => true, canLeaderStartWalk: () => true
  };
  const session = {
    controller,
    async refreshLeaderP2pGroup() { calls.push(['refresh-room', this]); await refreshWork; }
  };
  activeSession = session;
  const { LeaderLobbyPage } = load(lobbyBusinessSource(), {}, {
    Scroller: class {}, COMIC_CONTROL_INK_OFFSET: 2, COMIC_CARD_INK_OFFSET: 4,
    AppSession: { get: () => activeSession },
    canIUse: () => supported,
    access: {
      BluetoothState: { STATE_OFF: 0, STATE_TURNING_ON: 1, STATE_ON: 2, STATE_TURNING_OFF: 3 },
      getState() { if (stateError) throw stateError; return bluetoothState; },
      on: (event, callback) => handlers.set(event, callback),
      off(event, callback) { if (handlers.get(event) === callback) handlers.delete(event); }
    },
    getContext: () => ({}),
    ensureBluetoothDiscoveryPermission() { calls.push(['permission']); return permissionWork; },
    openWirelessSettings() { calls.push(['settings']); return settingsWork; },
    showUserNotice: (text, scope) => notices.push([text, scope]),
    logUserFailure: (scope, error) => errors.push([scope, error]),
    userErrorMessage: (error, fallback) => error?.message || fallback,
    getCalibrationMs: () => -1,
    isRandomAvatar: () => false,
    setTimeout: () => assert.fail('Bluetooth invitation feedback must not own polling timers'),
    clearInterval() {},
    isSceneAccessible: () => true,
    resolveDrumAccess: () => ({ allowed: false, source: 'locked', expiresAt: 0 })
  });
  const page = new LeaderLobbyPage();
  page.loading = false;
  page.invite = true;
  page.stopDrumAccessRefresh = () => {};
  page.startDrumAccessRefresh = () => {};
  page.stopRosterStatusAnimation = () => {};
  page.startRosterStatusAnimation = () => {};
  return {
    page, controller, session, calls, notices, errors, permission, settings,
    setState: state => { bluetoothState = state; },
    failState: error => { stateError = error; },
    replace: value => { activeSession = value; },
    setSupported: value => { supported = value; },
    refreshResult: value => { refreshWork = value; },
    permissionResult: value => { permissionWork = Promise.resolve(value); },
    permissionWork: value => { permissionWork = value; },
    permissionFailure: error => { permissionWork = Promise.reject(error); },
    settingsResult: value => { settingsWork = Promise.resolve(value); },
    settingsFailure: error => { settingsWork = Promise.reject(error); },
    emitState(state) { bluetoothState = state; page.bluetoothStateListener(state); }
  };
}

function verifyCodeReadiness() {
  const h = harness();
  h.controller.bleInviteAvailable = true;
  h.page.refresh();
  assert.equal(h.page.inviteBluetoothState, 'off');
  assert.equal(h.page.canShowJoinCode(), false,
    'A stale successful BLE advertisement cannot expose a code after the radio turns off');
  assert.equal(h.page.qr, 'ready-room-qr', 'Bluetooth is not a readiness gate for QR invitations');

  h.setState(2);
  h.controller.bleInviteAvailable = false;
  h.page.refresh();
  assert.equal(h.page.inviteBluetoothState, 'on');
  assert.equal(h.page.canShowJoinCode(), false,
    'Radio ON alone does not mean that a six-digit code is discoverable');
  h.controller.bleInviteAvailable = true;
  h.page.refresh();
  assert.equal(h.page.canShowJoinCode(), true);
  assert.equal(h.page.inviteJoinCode, '123456');
  for (const malformed of ['', '------', '12345', '1234567', '12x456']) {
    h.controller.joinCode = malformed;
    h.page.refresh();
    assert.equal(h.page.canShowJoinCode(), false, 'Only a ready six-digit invitation is displayed');
  }
  h.controller.joinCode = '123456';

  for (const [state, label] of [[1, 'turningOn'], [3, 'turningOff'], [0, 'off']]) {
    h.setState(state);
    h.page.refresh();
    assert.equal(h.page.inviteBluetoothState, label);
    assert.equal(h.page.canShowJoinCode(), false, `A transitional radio state (${label}) cannot expose a code`);
    assert.equal(h.page.qr, 'ready-room-qr');
  }

  h.failState(new Error('bluetooth state permission unavailable'));
  h.page.refresh();
  assert.equal(h.page.inviteBluetoothState, 'unavailable');
  assert.equal(h.page.canShowJoinCode(), false,
    'An unreadable state must not inherit an old ready invitation');
  assert.equal(h.page.qr, 'ready-room-qr');
  const unsupported = harness();
  unsupported.setSupported(false);
  unsupported.setState(2);
  unsupported.controller.bleInviteAvailable = true;
  unsupported.page.refresh();
  assert.equal(unsupported.page.inviteBluetoothSupported, false);
  assert.equal(unsupported.page.canShowJoinCode(), false);
}

async function verifySettingsAction() {
  const h = harness();
  h.page.refresh();
  const opening = h.page.activateJoinCode();
  assert.equal(h.page.inviteActionBusy, true);
  await h.page.activateJoinCode();
  assert.deepEqual(h.calls.map(([kind]) => kind), ['settings'],
    'Repeated taps cannot stack settings launches or request discovery permission while the radio is OFF');
  assert.equal(h.page.canShowJoinCode(), false);
  assert.equal(h.page.qr, 'ready-room-qr');
  h.settings.resolve();
  await opening;
  assert.equal(h.page.inviteActionBusy, false);
  assert.equal(h.page.canShowJoinCode(), false, 'Returning from settings without enabling Bluetooth cannot invent a code');

  const failed = harness();
  failed.page.refresh();
  failed.settingsFailure(new Error('设置暂时打不开'));
  await failed.page.activateJoinCode();
  assert.equal(failed.page.inviteActionBusy, false);
  assert.ok(failed.page.inviteActionError.length > 0, 'A settings failure remains actionable in the code slot');
  assert.equal(failed.page.qr, 'ready-room-qr');
}

async function verifyPermissionAndDiscovery() {
  const denied = harness();
  denied.setState(2);
  denied.page.refresh();
  const denying = denied.page.activateJoinCode();
  await denied.page.activateJoinCode();
  assert.deepEqual(denied.calls.map(([kind]) => kind), ['permission'], 'Permission prompts are deduplicated');
  denied.permission.resolve(false);
  await denying;
  assert.equal(denied.page.inviteActionBusy, false);
  assert.ok(denied.page.inviteActionError.length > 0);
  assert.equal(denied.calls.some(([kind]) => kind === 'refresh-room'), false,
    'Denied Bluetooth permission cannot attempt discovery setup');
  assert.equal(denied.page.canShowJoinCode(), false);
  assert.equal(denied.page.qr, 'ready-room-qr');

  const granted = harness();
  granted.setState(2);
  granted.page.refresh();
  const refreshing = deferred();
  granted.refreshResult(refreshing.promise);
  const enabling = granted.page.activateJoinCode();
  granted.permission.resolve(true);
  await flush();
  assert.equal(granted.calls.filter(([kind]) => kind === 'refresh-room').length, 1);
  assert.equal(granted.page.inviteActionBusy, true);
  assert.equal(granted.page.canShowJoinCode(), false, 'The code stays hidden while native advertising is pending');
  refreshing.resolve();
  await enabling;
  assert.equal(granted.page.inviteActionBusy, false);
  assert.equal(granted.page.canShowJoinCode(), false,
    'Successful permission and group refresh do not stand in for bleInviteAvailable');
  granted.controller.bleInviteAvailable = true;
  granted.page.refresh();
  assert.equal(granted.page.canShowJoinCode(), true);
  assert.equal(granted.page.inviteActionError, '', 'A later successful advertisement replaces old feedback');

  const unavailable = harness();
  unavailable.failState(new Error('permission missing'));
  unavailable.page.refresh();
  const retrying = unavailable.page.activateJoinCode();
  assert.deepEqual(unavailable.calls.map(([kind]) => kind), ['permission'],
    'An unreadable Bluetooth state recovers through permission, without assuming the radio is OFF');
  unavailable.permission.resolve(false);
  await retrying;
  assert.equal(unavailable.page.inviteActionBusy, false);
  assert.equal(unavailable.page.canShowJoinCode(), false);

  const failed = harness();
  failed.setState(2);
  failed.page.refresh();
  failed.permissionFailure(new Error('权限接口失败'));
  await failed.page.activateJoinCode();
  assert.equal(failed.page.inviteActionBusy, false);
  assert.ok(failed.page.inviteActionError.length > 0);
  assert.equal(failed.page.canShowJoinCode(), false);
}

async function verifyActionOwnership() {
  const hidden = harness();
  hidden.setState(2);
  hidden.page.refresh();
  const pending = hidden.page.activateJoinCode();
  hidden.page.onPageHide();
  assert.equal(hidden.page.inviteActionBusy, false, 'A hidden page releases its local pending affordance');
  hidden.permission.resolve(true);
  await pending;
  assert.equal(hidden.calls.some(([kind]) => kind === 'refresh-room'), false,
    'Late authorization cannot reconfigure a room after leaving its lobby');
  assert.equal(hidden.page.inviteActionError, '');

  const replaced = harness();
  replaced.setState(2);
  replaced.page.refresh();
  const old = replaced.page.activateJoinCode();
  const replacementCalls = [];
  replaced.replace({ controller: replaced.controller,
    async refreshLeaderP2pGroup() { replacementCalls.push('new-room-refresh'); } });
  replaced.permission.resolve(true);
  await old;
  assert.deepEqual(replacementCalls, [], 'An old room permission result cannot refresh a replacement room');
  assert.equal(replaced.page.inviteActionError, '');

  const reopened = harness();
  reopened.setState(2);
  reopened.page.refresh();
  const earlier = reopened.page.activateJoinCode();
  reopened.page.onPageHide();
  reopened.page.randomPreviewPageVisible = true;
  const currentPermission = deferred();
  reopened.permissionWork(currentPermission.promise);
  const current = reopened.page.activateJoinCode();
  assert.equal(reopened.page.inviteActionBusy, true);
  reopened.permission.resolve(false);
  await earlier;
  assert.equal(reopened.page.inviteActionBusy, true,
    'An older finally block must not clear a new request after the lobby reopens');
  assert.equal(reopened.page.inviteActionError, '', 'An old denial cannot overwrite the current request');
  currentPermission.resolve(false);
  await current;
  assert.equal(reopened.page.inviteActionBusy, false);
}

async function verifyActionGuards() {
  for (const state of [
    { leader: false }, { soloTeam: true }, { loading: true }, { failed: true },
    { leavingLobby: true }, { randomPreviewPageVisible: false }, { qr: '' }
  ]) {
    const h = harness();
    h.page.refresh();
    Object.assign(h.page, state);
    await h.page.activateJoinCode();
    assert.equal(h.calls.length, 0, `The recovery action is unavailable for ${JSON.stringify(state)}`);
    assert.equal(h.page.inviteActionBusy, false);
  }
  for (const guard of ['unsupported', 'turning-on', 'no-session', 'ready']) {
    const h = harness();
    if (guard === 'unsupported') h.setSupported(false);
    if (guard === 'turning-on') h.setState(1);
    if (guard === 'no-session') h.replace(undefined);
    if (guard === 'ready') { h.setState(2); h.controller.bleInviteAvailable = true; }
    h.page.refresh();
    await h.page.activateJoinCode();
    assert.equal(h.calls.length, 0, `${guard} does not launch settings or permission work`);
  }
}

async function verifySystemStateRefresh() {
  const h = harness();
  h.setState(2);
  h.controller.bleInviteAvailable = true;
  h.page.refresh();
  assert.equal(h.page.canShowJoinCode(), true);
  const networkRefresh = deferred();
  h.refreshResult(networkRefresh.promise);
  h.emitState(0);
  assert.equal(h.page.inviteBluetoothState, 'off');
  assert.equal(h.page.canShowJoinCode(), false,
    'A radio-OFF event hides stale code synchronously, before a slow network refresh can complete');
  assert.equal(h.page.qr, 'ready-room-qr');
  networkRefresh.resolve();
  await flush();

  const resumed = harness();
  resumed.page.refresh();
  resumed.page.onPageHide();
  resumed.setState(2);
  resumed.controller.bleInviteAvailable = true;
  resumed.page.onPageShow();
  assert.equal(resumed.page.inviteBluetoothState, 'on');
  assert.equal(resumed.page.canShowJoinCode(), true,
    'Returning from system settings reads current state even if the background event was missed');
  await flush();
  assert.equal(resumed.calls.filter(([kind]) => kind === 'refresh-room').length, 1);

  const queued = harness();
  queued.page.refresh();
  const firstRefresh = deferred();
  queued.refreshResult(firstRefresh.promise);
  queued.emitState(1);
  queued.emitState(2);
  queued.emitState(0);
  assert.equal(queued.calls.filter(([kind]) => kind === 'refresh-room').length, 1,
    'A burst of radio events cannot run overlapping native refreshes for the same room');
  assert.equal(queued.page.inviteBluetoothState, 'off', 'Coalescing network work cannot coalesce away the visible OFF state');
  firstRefresh.resolve();
  await flush();
  assert.equal(queued.calls.filter(([kind]) => kind === 'refresh-room').length, 2,
    'The last system state gets one queued retry, rather than being dropped or polled indefinitely');
  assert.equal(queued.page.refreshingConnectivity, false);

  const hiddenRefresh = harness();
  hiddenRefresh.page.refresh();
  const nativeRefresh = deferred();
  hiddenRefresh.refreshResult(nativeRefresh.promise);
  hiddenRefresh.emitState(1);
  hiddenRefresh.page.onPageHide();
  hiddenRefresh.setState(2);
  hiddenRefresh.controller.bleInviteAvailable = true;
  hiddenRefresh.page.onPageShow();
  assert.equal(hiddenRefresh.calls.filter(([kind]) => kind === 'refresh-room').length, 1,
    'Returning to the same room cannot overlap its in-flight native refresh');
  assert.equal(hiddenRefresh.page.canShowJoinCode(), true);
  nativeRefresh.resolve();
  await flush();
  assert.equal(hiddenRefresh.calls.filter(([kind]) => kind === 'refresh-room').length, 2,
    'A hidden request completion yields a fresh foreground owner for the queued refresh');
  assert.equal(hiddenRefresh.page.refreshingConnectivity, false);
}

function verifyUiBoundary() {
  const source = ets('pages/LeaderLobbyPage.ets');
  const invitation = source.indexOf('if (this.invite && this.qr.length > 0)');
  assert.ok(invitation > 0);
  const block = source.slice(invitation, bodyEnd(source, source.indexOf('{', invitation)));
  const qr = block.indexOf('QRCode(this.qr)');
  const codeBranch = block.indexOf('if (this.leader && !this.canShowJoinCode())');
  assert.ok(qr >= 0 && codeBranch > qr,
    'The working QR remains outside and before the optional code branch');
  assert.match(block, /this\.inviteJoinCode/, 'The UI reads the readiness-gated snapshot of the code');
  assert.doesNotMatch(block, /controller\.joinCode/, 'ArkUI must not bypass readiness by reading a raw controller code');
  assert.match(block, /this\.inviteUnavailableCard\(\)/, 'The unavailable code is replaced in its own invitation slot');
  const cardStart = source.indexOf('  private inviteUnavailableCard()');
  const card = source.slice(cardStart, bodyEnd(source, source.indexOf('{', cardStart)));
  assert.match(card, /this\.activateJoinCode\(\)/, 'The replacement slot exposes the guarded recovery action');
  assert.match(card, /this\.inviteUnavailableTitle\(\)/);
  assert.match(card, /this\.inviteUnavailableDetail\(\)/);
  assert.match(card, /accessibilityLabel:[\s\S]*前往系统设置开启蓝牙/,
    'Assistive technology hears that the action opens settings rather than directly enabling Bluetooth');
}

async function main() {
  verifyCodeReadiness();
  await verifySettingsAction();
  await verifyPermissionAndDiscovery();
  await verifyActionOwnership();
  await verifyActionGuards();
  await verifySystemStateRefresh();
  verifyUiBoundary();
  console.log('PASS lobby Bluetooth invitation: radio and advertising readiness, persistent QR, settings and permission recovery, duplicate-tap protection, lifecycle ownership, immediate OFF and foreground refresh');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
