// A character this device chose but lost (refund, ended pass, expired limited
// free) falls back to random in the real lobby business code; a ready member
// un-readies first. Badges let taps through to the avatar button.
const assert = require('node:assert/strict');
const { load, ets } = require('./drum-editor-preview.cjs');
const { lobbyBusinessSource, bodyEnd } = require('./solo-roster-reorder.cjs');

async function flush() {
  for (let turn = 0; turn < 12; turn++) await Promise.resolve();
}

function harness({ soloTeam = false, isLeader = false, members, owned = new Set(['random']) }) {
  const calls = [];
  const notices = [];
  const controller = {
    isLeader, soloTeam, bpm: 120, beatsPerBar: 4, beatUnit: 4, rhythm: 0, drumProgram: '',
    sceneKey: 'sunset_coast', lobbyDeparted: false, joinCode: '123456', bleInviteAvailable: false,
    members,
    // Live objects, like SessionController: an update rewrites what callers hold.
    getMembers() { return this.members; },
    getLocalMemberId: () => 'me',
    buildJoinQrPayload: () => 'qr',
    isLocalLobbyReady() { return this.members.some(m => m.id === 'me' && m.lobbyReady === true); },
    canLeaderStartWalk: () => true,
    async updateMemberAvatar(id, key) {
      calls.push(['avatar', id, key]);
      const member = this.members.find(m => m.id === id);
      if (member !== undefined && member.lobbyReady !== true) member.avatarKey = key;
    },
    async setLobbyReady(ready) { calls.push(['ready', ready]); }
  };
  const session = { controller };
  const { LeaderLobbyPage } = load(lobbyBusinessSource(), {}, {
    Scroller: class {}, COMIC_CONTROL_INK_OFFSET: 2, COMIC_CARD_INK_OFFSET: 4,
    AppSession: { get: () => session },
    RANDOM_AVATAR_KEY: 'random',
    isRandomAvatar: key => key === 'random',
    isCharacterOwned: key => owned.has(key),
    avatarDisplayName: key => `name:${key}`,
    showUserNotice: (text, scope) => notices.push([text, scope]),
    logUserFailure() {},
    canIUse: () => false,
    access: { BluetoothState: { STATE_OFF: 0, STATE_TURNING_ON: 1, STATE_ON: 2, STATE_TURNING_OFF: 3 },
      getState: () => 0, on() {}, off() {} },
    getCalibrationMs: () => -1,
    setTimeout: () => 0, clearInterval() {},
    isSceneAccessible: () => true,
    resolveDrumAccess: () => ({ allowed: false, source: 'locked', expiresAt: 0 })
  });
  const page = new LeaderLobbyPage();
  // Counts passes so a self-scheduling loop (which froze the device) fails fast.
  const reconcile = page.reconcileLobbyCharacterAccess.bind(page);
  let passes = 0;
  page.reconcileLobbyCharacterAccess = () => {
    if (++passes > 40) throw new Error('reconcile loops without a new snapshot');
    reconcile();
  };
  page.loading = false;
  page.randomPreviewPageVisible = true;
  page.stopDrumAccessRefresh = () => {};
  page.startDrumAccessRefresh = () => {};
  page.reconcileLobbySceneAccess = async () => {};
  return { page, controller, calls, notices, owned, passes: () => passes };
}

async function verifyDirectFallback() {
  const h = harness({ members: [{ id: 'me', avatarKey: 'teapot' }, { id: 'other', avatarKey: 'cloud' }],
    owned: new Set(['random', 'teapot']) });
  h.page.refresh();
  assert.deepEqual(h.calls, [], 'Owned characters and remote members are left alone');
  h.owned.delete('teapot');
  h.page.onStoreEntitlementsChanged();
  await flush();
  assert.deepEqual(h.calls, [['avatar', 'me', 'random']],
    'Only the member this device chose for falls back; the remote member uses its own entitlements');
  assert.deepEqual(h.notices, [['「name:teapot」已无法使用，已换成随机角色', 'lobby-character-revoke']]);
  h.page.refresh();
  await flush();
  assert.equal(h.calls.length, 1, 'Once random, later snapshots do not resend');
  assert.equal(h.page.characterRevertPending, false);
}

async function verifyReadyMemberUnreadiesFirst() {
  const h = harness({ members: [{ id: 'me', avatarKey: 'teapot', lobbyReady: true }] });
  h.page.onStoreEntitlementsChanged();
  await flush();
  assert.deepEqual(h.calls, [['ready', false]], 'A ready member must un-ready before the room accepts a change');
  const waiting = h.passes();
  await flush();
  await flush();
  assert.equal(h.passes(), waiting, 'While the unready snapshot is pending, no pass may schedule another');
  h.page.refresh();
  await flush();
  assert.deepEqual(h.calls, [['ready', false]], 'The unready request is sent once while its snapshot is pending');
  h.controller.members[0].lobbyReady = false;
  h.page.refresh();
  await flush();
  assert.deepEqual(h.calls, [['ready', false], ['avatar', 'me', 'random']],
    'The snapshot confirming un-ready completes the fallback');
  assert.equal(h.controller.members[0].avatarKey, 'random');
}

async function verifySoloLeaderChecksEveryRole() {
  const h = harness({ soloTeam: true, isLeader: true,
    members: [{ id: 'me', avatarKey: 'random' }, { id: 'solo-2', avatarKey: 'lamp' }] });
  h.page.onStoreEntitlementsChanged();
  await flush();
  assert.deepEqual(h.calls, [['avatar', 'solo-2', 'random']], 'Solo practice edits every role on this device');
}

async function verifyHiddenLobbyWaits() {
  const h = harness({ members: [{ id: 'me', avatarKey: 'teapot' }] });
  h.page.randomPreviewPageVisible = false;
  h.page.onStoreEntitlementsChanged();
  await flush();
  assert.deepEqual(h.calls, [], 'A hidden lobby does not change the room');
  h.page.randomPreviewPageVisible = true;
  h.page.refresh();
  await flush();
  assert.deepEqual(h.calls, [['avatar', 'me', 'random']], 'The pending fallback runs when the lobby shows again');
}

function verifyBadgesPassTaps() {
  const source = ets('pages/LeaderLobbyPage.ets');
  const start = source.indexOf('  private characterBadges(key: string)');
  const body = source.slice(start, bodyEnd(source, source.indexOf('{', start)));
  assert.match(body, /\.hitTestBehavior\(HitTestMode\.Transparent\)\s*$/m,
    'Badge taps must reach the avatar button beneath');
  assert.doesNotMatch(body, /HitTestMode\.None/, 'None lets the badge images swallow the tap');
}

// The lobby names a character with ComicKit.avatarDisplayName; the Store lists
// the official names. They must agree (lilroll once showed as 「Lilroll」).
function verifyDisplayNamesMatchStore() {
  const kit = ets('components/ComicKit.ets');
  const lobbyNames = new Map();
  for (const match of kit.matchAll(/if \(key === '(\w+)'(?: \|\| key === '\w+')?\) \{ return '([^']+)'; \}/g)) {
    lobbyNames.set(match[1], match[2]);
  }
  const store = ets('pages/StorePage.ets');
  let checked = 0;
  for (const match of store.matchAll(/\{ key: '(\w+)', name: '([^']+)',[^\n]*productId: 'onebeat\.character\./g)) {
    assert.equal(lobbyNames.get(match[1]), match[2], `${match[1]}: lobby name must match the Store name`);
    checked++;
  }
  assert.equal(checked, 7, 'Every paid character is compared');
}

async function main() {
  verifyDisplayNamesMatchStore();
  await verifyDirectFallback();
  await verifyReadyMemberUnreadiesFirst();
  await verifySoloLeaderChecksEveryRole();
  await verifyHiddenLobbyWaits();
  verifyBadgesPassTaps();
  console.log('PASS lobby character revocation: lost local choices fall back to random (ready members un-ready once first), remote members untouched, hidden lobby waits; badges pass taps to the avatar; lobby names match the Store');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
