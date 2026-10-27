// Solo lobby roster order follows Map insertion order and drives walk layout.
const assert = require('node:assert/strict');
const { load, ets, meter, catalog, plain } = require('./drum-editor-preview.cjs');

const lobbySource = ets('pages/LeaderLobbyPage.ets');

// Builders are interspersed with the lobby's methods. Strip only ArkUI bodies so
// the tests execute the real state initializers and drag lifecycle below them.
function bodyEnd(source, open) {
  let depth = 0;
  for (let index = open; index < source.length; index++) {
    const char = source[index];
    const next = source[index + 1];
    if (char === '"' || char === "'" || char === '`') {
      const quote = char;
      for (index++; index < source.length; index++) {
        if (source[index] === '\\') { index++; continue; }
        if (source[index] === quote) break;
      }
    } else if (char === '/' && next === '/') {
      index = source.indexOf('\n', index + 2);
      if (index < 0) return source.length;
    } else if (char === '/' && next === '*') {
      index = source.indexOf('*/', index + 2);
      assert.ok(index >= 0, 'Unclosed source comment');
      index++;
    } else if (char === '{') {
      depth++;
    } else if (char === '}' && --depth === 0) {
      return index + 1;
    }
  }
  assert.fail('Unclosed lobby method body');
}

function lobbyBusinessSource() {
  let source = lobbySource;
  const remove = [];
  const builders = /^  @Builder\s+|^  build\(\)\s*\{/gm;
  for (const match of source.matchAll(builders)) {
    const open = source.indexOf('{', match.index);
    remove.push([match.index, bodyEnd(source, open)]);
  }
  for (const [start, end] of remove.reverse()) source = source.slice(0, start) + source.slice(end);
  return source
    .replace(/^import[\s\S]*?from\s+['"][^'"]+['"];\s*/gm, '')
    .replace(/@(?:Entry|Component)\b\s*/g, '')
    .replace(/@State\s+/g, '')
    .replace(/@(?:StorageLink|Watch)\([^)]*\)\s*/g, '')
    .replace('struct LeaderLobbyPage', 'export class LeaderLobbyPage');
}

function lobbyHarness() {
  let now = 1000;
  const calls = [];
  const selected = [];
  const failures = [];
  const members = ['leader', 'bot-1', 'bot-2', 'bot-3'].map(id => ({ id, displayName: id, avatarKey: 'cloud' }));
  const controller = {
    isLeader: true,
    soloTeam: true,
    getMembers: () => members.slice(),
    async reorderSoloMembers(from, to) {
      calls.push([from, to]);
      members.splice(to, 0, members.splice(from, 1)[0]);
    }
  };
  const session = { controller };
  let activeSession = session;
  const { LeaderLobbyPage } = load(lobbyBusinessSource(), {}, {
    Date: class extends Date { static now() { return now; } },
    Scroller: class {},
    COMIC_CONTROL_INK_OFFSET: 2,
    COMIC_CARD_INK_OFFSET: 4,
    AppSession: { get: () => activeSession },
    Map,
    logUserFailure: (scope, error) => failures.push([scope, error]),
    userErrorMessage: (_error, fallback) => fallback,
    showUserNotice: () => {},
    setTimeout: () => assert.fail('Drag click suppression must expire by timestamp, without unowned timers')
  });
  const page = new LeaderLobbyPage();
  page.members = members.slice();
  page.soloTeam = true;
  page.loading = false;
  let refreshes = 0;
  page.refresh = () => { refreshes++; page.members = activeSession.controller.getMembers(); };
  page.selectEditingMember = id => selected.push(id);
  return {
    page, calls, selected, failures, members, controller, session,
    get refreshes() { return refreshes; },
    advance: elapsed => { now += elapsed; },
    switchSession: value => { activeSession = value; }
  };
}

async function verifyLobbyDragLifecycle() {
  const right = lobbyHarness();
  assert.equal(right.page.rosterDragMemberId, '');
  assert.equal(right.page.rosterDragOffsetX, 0);
  assert.equal(right.page.rosterDragFromIndex, -1);
  right.page.beginRosterDrag('leader');
  assert.equal(right.page.rosterDragMemberId, 'leader');
  assert.equal(right.page.rosterDragSession, right.session, 'A drag belongs to the room in which it started');
  right.page.updateRosterDrag(68 * 2);
  assert.equal(right.page.rosterDragOffsetX, 136);
  await right.page.finishRosterDrag();
  assert.deepEqual(right.calls, [[0, 2]]);
  assert.deepEqual(right.members.map(member => member.id), ['bot-1', 'bot-2', 'leader', 'bot-3']);
  assert.equal(right.refreshes, 1, 'Successful order changes refresh the visible roster');
  assert.equal(right.page.rosterDragMemberId, '');
  assert.equal(right.page.rosterDragOffsetX, 0);
  assert.equal(right.page.rosterDragFromIndex, -1);
  assert.equal(right.page.rosterDragSession, undefined);
  right.page.selectRosterMember('bot-1');
  assert.deepEqual(right.selected, [], 'Finishing a drag must not also switch the edited avatar');
  right.advance(151);
  right.page.selectRosterMember('bot-1');
  assert.deepEqual(right.selected, ['bot-1'], 'Normal avatar taps resume after the release guard');

  const left = lobbyHarness();
  left.page.beginRosterDrag('bot-3');
  left.page.updateRosterDrag(-68 * 2);
  await left.page.finishRosterDrag();
  assert.deepEqual(left.calls, [[3, 1]], 'Dragging left uses the same slot spacing as dragging right');

  for (const [member, offset, expected] of [['leader', 100000, [0, 3]], ['bot-3', -100000, [3, 0]]]) {
    const bounded = lobbyHarness();
    bounded.page.beginRosterDrag(member);
    bounded.page.updateRosterDrag(offset);
    await bounded.page.finishRosterDrag();
    assert.deepEqual(bounded.calls, [expected], 'Dragging beyond the row clamps the destination to a real member');
  }

  const canceled = lobbyHarness();
  canceled.page.beginRosterDrag('bot-1');
  canceled.page.cancelRosterDrag();
  canceled.advance(149);
  canceled.page.cancelRosterDrag();
  canceled.page.selectRosterMember('bot-1');
  assert.deepEqual(canceled.selected, [], 'A sequence canceled before Pan begins still suppresses the release click');
  canceled.advance(2);
  canceled.page.selectRosterMember('bot-1');
  assert.deepEqual(canceled.selected, ['bot-1'], 'Redundant cancel callbacks must not extend the click guard');
  assert.equal(canceled.page.rosterDragSession, undefined);
  await canceled.page.finishRosterDrag();
  assert.deepEqual(canceled.calls, []);

  const held = lobbyHarness();
  held.page.beginRosterDrag('bot-1');
  held.page.selectRosterMember('leader');
  assert.deepEqual(held.selected, [], 'An active long press never selects an unrelated avatar');
  await held.page.finishRosterDrag();
  assert.deepEqual(held.calls, [], 'Holding without movement does not rewrite roster order');

  const tooShort = lobbyHarness();
  tooShort.page.beginRosterDrag('bot-1');
  tooShort.page.updateRosterDrag(20);
  await tooShort.page.finishRosterDrag();
  assert.deepEqual(tooShort.calls, [], 'A drag shorter than half a slot leaves order intact');

  for (const state of [
    { soloTeam: false }, { leader: false }, { loading: true },
    { randomPreviewPageVisible: false }, { leavingLobby: true }, { enteringStage: true }
  ]) {
    const guarded = lobbyHarness();
    Object.assign(guarded.page, state);
    guarded.page.beginRosterDrag('leader');
    guarded.page.updateRosterDrag(136);
    await guarded.page.finishRosterDrag();
    assert.equal(guarded.page.rosterDragMemberId, '');
    assert.deepEqual(guarded.calls, [], `Reordering is disabled for ${JSON.stringify(state)}`);
  }

  const unknown = lobbyHarness();
  unknown.page.beginRosterDrag('not-a-member');
  unknown.page.updateRosterDrag(136);
  await unknown.page.finishRosterDrag();
  assert.deepEqual(unknown.calls, []);

  const idle = lobbyHarness();
  idle.page.updateRosterDrag(136);
  assert.equal(idle.page.rosterDragOffsetX, 0, 'Pan callbacks without an accepted long press have no effect');
  idle.page.cancelRosterDrag();
  idle.page.selectRosterMember('leader');
  assert.deepEqual(idle.selected, ['leader'], 'Canceling a never-started drag does not block a normal tap');

  const stale = lobbyHarness();
  stale.page.beginRosterDrag('leader');
  stale.page.updateRosterDrag(68);
  const replacementCalls = [];
  stale.switchSession({ controller: { getMembers: () => stale.members.slice(),
    async reorderSoloMembers(from, to) { replacementCalls.push([from, to]); } } });
  stale.page.updateRosterDrag(136);
  await stale.page.finishRosterDrag();
  assert.deepEqual(stale.calls, [], 'A drag cannot reorder the room it has already left');
  assert.deepEqual(replacementCalls, [], 'A late release must not reorder a replacement session');

  const pending = lobbyHarness();
  let release;
  pending.controller.reorderSoloMembers = async (from, to) => {
    pending.calls.push([from, to]);
    await new Promise(resolve => { release = resolve; });
  };
  pending.page.beginRosterDrag('leader');
  pending.page.updateRosterDrag(68);
  const completing = pending.page.finishRosterDrag();
  assert.deepEqual(pending.calls, [[0, 1]], 'A drop starts its mutation on the captured controller');
  pending.switchSession({ controller: { getMembers: () => [] } });
  release();
  await completing;
  assert.equal(pending.refreshes, 0, 'A late reorder completion must not refresh a replacement room');

  const changedOrder = lobbyHarness();
  changedOrder.page.beginRosterDrag('leader');
  changedOrder.page.updateRosterDrag(136);
  changedOrder.members.splice(1, 0, changedOrder.members.shift());
  changedOrder.page.members = changedOrder.members.slice();
  await changedOrder.page.finishRosterDrag();
  assert.deepEqual(changedOrder.calls, [], 'A changed source index cancels the drag instead of moving another avatar');

  const removed = lobbyHarness();
  removed.page.beginRosterDrag('bot-1');
  removed.page.updateRosterDrag(136);
  removed.members.splice(1, 1);
  removed.page.members = removed.members.slice();
  await removed.page.finishRosterDrag();
  assert.deepEqual(removed.calls, [], 'A removed source member cannot reorder its old neighbour');
}

async function verifyLiveReorderPreview() {
  const preview = lobbyHarness();
  const page = preview.page;
  const ids = preview.members.map(member => member.id);
  const originalMembers = plain(preview.members);
  const offsets = () => ids.map(id => page.rosterMemberDragOffsetX(id));
  const assertUncommitted = () => {
    assert.deepEqual(preview.members, originalMembers, 'Making room is visual; the controller order stays unchanged until drop');
    assert.deepEqual(plain(page.members), originalMembers, 'Preview must not rearrange the source row or replace active gesture nodes');
    assert.deepEqual(preview.calls, [], 'Moving the finger never broadcasts intermediate roster changes');
    assert.equal(page.rosterMemberDragOffsetX('add-slot'), 0, 'The add slot and unknown IDs never make room');
  };

  assert.equal(page.rosterDragTargetIndex(), -1, 'An idle roster has no insertion target');
  assert.deepEqual(offsets(), [0, 0, 0, 0]);
  page.beginRosterDrag('bot-1');
  assert.equal(page.rosterDragTargetIndex(), 1);
  assert.deepEqual(offsets(), [0, 0, 0, 0], 'Long press alone does not displace neighbours');
  page.updateRosterDrag(20);
  assert.equal(page.rosterDragTargetIndex(), 1);
  assert.deepEqual(offsets(), [0, 20, 0, 0], 'The active avatar tracks the exact finger offset before crossing a slot');
  assertUncommitted();

  page.updateRosterDrag(35);
  assert.equal(page.rosterDragTargetIndex(), 2);
  assert.deepEqual(offsets(), [0, 35, -68, 0], 'Passing a slot midpoint moves that neighbour one slot left');
  assertUncommitted();
  page.updateRosterDrag(140);
  assert.equal(page.rosterDragTargetIndex(), 3);
  assert.deepEqual(offsets(), [0, 140, -68, -68], 'Crossing multiple slots opens one gap at the destination');
  assertUncommitted();

  page.updateRosterDrag(40);
  assert.equal(page.rosterDragTargetIndex(), 2);
  assert.deepEqual(offsets(), [0, 40, -68, 0], 'Backtracking releases neighbours beyond the new destination');
  page.updateRosterDrag(0);
  assert.equal(page.rosterDragTargetIndex(), 1);
  assert.deepEqual(offsets(), [0, 0, 0, 0], 'Returning to the source closes the temporary gap');
  page.updateRosterDrag(-70);
  assert.equal(page.rosterDragTargetIndex(), 0);
  assert.deepEqual(offsets(), [68, -70, 0, 0], 'Reversing across the source opens the gap on the opposite side');
  assertUncommitted();
  page.cancelRosterDrag();
  assert.equal(page.rosterDragTargetIndex(), -1);
  assert.deepEqual(offsets(), [0, 0, 0, 0], 'Cancel restores every avatar to its original slot');
  assertUncommitted();

  const backward = lobbyHarness();
  backward.page.beginRosterDrag('bot-3');
  backward.page.updateRosterDrag(-140);
  assert.equal(backward.page.rosterDragTargetIndex(), 1);
  assert.deepEqual(ids.map(id => backward.page.rosterMemberDragOffsetX(id)), [0, 68, 68, -140],
    'Dragging left shifts only the crossed interval right');
  assert.deepEqual(backward.calls, []);
  await backward.page.finishRosterDrag();
  assert.deepEqual(backward.calls, [[3, 1]], 'Drop commits the same insertion target shown by the gap');
  assert.deepEqual(backward.members.map(member => member.id), ['leader', 'bot-3', 'bot-1', 'bot-2']);
  assert.deepEqual(ids.map(id => backward.page.rosterMemberDragOffsetX(id)), [0, 0, 0, 0],
    'After drop, the reordered row owns placement and all temporary offsets are cleared');

  for (const [source, offset, target, expected] of [
    ['bot-1', 100000, 3, [0, 100000, -68, -68]],
    ['bot-2', -100000, 0, [68, 68, -100000, 0]],
    ['leader', -100000, 0, [-100000, 0, 0, 0]],
    ['bot-3', 100000, 3, [0, 0, 0, 100000]]
  ]) {
    const bounded = lobbyHarness();
    bounded.page.beginRosterDrag(source);
    bounded.page.updateRosterDrag(offset);
    assert.equal(bounded.page.rosterDragTargetIndex(), target, 'Insertion targets clamp to roster bounds');
    assert.deepEqual(ids.map(id => bounded.page.rosterMemberDragOffsetX(id)), expected,
      'Out-of-bounds finger movement never shifts neighbours beyond real member slots');
    assert.deepEqual(bounded.calls, []);
    bounded.page.cancelRosterDrag();
    assert.deepEqual(ids.map(id => bounded.page.rosterMemberDragOffsetX(id)), [0, 0, 0, 0]);
  }

  for (const invalidIndex of [-1, 99]) {
    const invalid = lobbyHarness();
    invalid.page.beginRosterDrag('bot-1');
    invalid.page.updateRosterDrag(140);
    invalid.page.rosterDragFromIndex = invalidIndex;
    assert.equal(invalid.page.rosterDragTargetIndex(), -1, 'Invalid source indices cannot produce a preview target');
    assert.deepEqual(ids.map(id => invalid.page.rosterMemberDragOffsetX(id)), [0, 0, 0, 0],
      'Invalid source indices cannot leave avatars displaced');
    assert.deepEqual(invalid.calls, []);
  }
}

function verifyGestureWiring() {
  const slotStart = lobbySource.indexOf('  private rosterMemberSlot(member: SessionMember)');
  const slotEnd = bodyEnd(lobbySource, lobbySource.indexOf('{', slotStart));
  const slot = lobbySource.slice(slotStart, slotEnd);
  assert.match(slot, /\.translate\(\{\s*x:\s*this\.rosterMemberDragOffsetX\(member\.id\)\s*\}\)/,
    'Every roster avatar uses the insertion-preview offset, not only the active avatar');
  assert.match(slot, /\.priorityGesture\(\s*GestureGroup\(GestureMode\.Sequence/,
    'Solo drag must win avatar child/native recognizer arbitration');
  assert.match(slot, /PanGesture\(\{[^}]*distance:\s*1\b/,
    'After holding, a one-vp movement should begin sorting before Scroll takes the gesture');
  assert.match(slot, /\.onCancel\(\(\)\s*=>\s*\{\s*this\.cancelRosterDrag\(\)/,
    'The whole sequence cleans up if released before Pan recognition');
  assert.match(slot, /LongPressGesture\([\s\S]*\.onAction\([\s\S]*this\.beginRosterDrag\(member\.id\)/);
  assert.match(slot, /\.onActionStart\([\s\S]*this\.updateRosterDrag\(event\.offsetX\)/);
  assert.match(slot, /\.onActionUpdate\([\s\S]*this\.updateRosterDrag\(event\.offsetX\)/);
  assert.match(slot, /\.onActionEnd\([\s\S]*this\.updateRosterDrag\(event\.offsetX\)[\s\S]*this\.finishRosterDrag\(\)/,
    'Drop uses the release position even if no final update was delivered');
  assert.ok((lobbySource.match(/\.enableScrollInteraction\(this\.rosterDragMemberId\.length\s*===\s*0\)/g) ?? []).length >= 2,
    'Both the page and horizontal roster scroll stay still while sorting');
  const portraitStart = lobbySource.indexOf('  private rosterMemberPortrait(member: SessionMember)');
  const portraitEnd = bodyEnd(lobbySource, lobbySource.indexOf('{', portraitStart));
  const portrait = lobbySource.slice(portraitStart, portraitEnd);
  assert.match(portrait, /allowNativeDrag:\s*false/,
    'Lobby avatars opt out of native image dragging without blocking the sorting ancestor');
  assert.doesNotMatch(portrait, /\.hitTestBehavior\(HitTestMode\.Block\)/,
    'The avatar must not block the outer sorting gesture from hit testing');
  const comicSource = ets('components/ComicKit.ets');
  const character = comicSource.slice(comicSource.indexOf('export struct ComicCharacter'),
    comicSource.indexOf('export struct ComicButton'));
  assert.match(character, /@Prop allowNativeDrag:\s*boolean\s*=\s*true/,
    'Native drag is opt-out so other character uses retain their existing behavior');
  assert.equal((character.match(/\.draggable\(this\.allowNativeDrag\)/g) ?? []).length, 2,
    'Both ordinary and revealed mystery portrait images honor native-drag opt-out');
}

const controllerStorage = new Map();
const { SessionController } = load(ets('session/SessionController.ets'), {
  '../common/Constants': { TRANSPORT_RESTART_PREROLL_MS: 650, SESSION_MAX_MEMBER_COUNT: 8 },
  BuildProfile: { DEBUG: false },
  '../common/MonotonicClock': { MonotonicClock: { nowMs: () => 1000 } },
  '../protocol/messages': { createMessage: (type, payload) => ({ type, payload }) },
  '../network/socket/SessionServer': { SessionServer: class {} },
  '../network/socket/SessionClient': { SessionClient: class {} },
  '../sync/ClockSync': { ClockSyncEstimator: class {} },
  '../network/p2p/P2pInvitation': {}, '../assets/AssetCatalog': {},
  '../assets/CharacterCatalog': {
    defaultSessionAvatar: () => 'braids',
    rosterKeysForLobby: () => ['braids', 'cloud'],
    isAvatarAllowedForSession: () => true,
    normalizeAvatarKey: key => key,
    isRandomAvatar: key => key === 'random',
    isDuplicatableAvatar: () => true,
    isExclusiveTakenByOther: () => false
  },
  '../common/MeterModel': meter,
  '../audio/DrumMachineCatalog': catalog
}, {
  AppStorage: {
    get: key => controllerStorage.get(key),
    setOrCreate: (key, value) => controllerStorage.set(key, value)
  },
  console: { info() {}, warn() {} },
  clearTimeout() {},
  setTimeout: () => 1
});

async function main() {
  const c = new SessionController('solo-reorder', true, '队长');
  c.soloTeam = true;
  c.isLeader = true;
  c.scheduleRandomAvatarReveals = () => {};
  const snapshots = [];
  c.sendToAll = async wire => { snapshots.push(plain(wire)); };
  await c.addSoloBotWithNextAvatar();
  await c.addSoloBotWithNextAvatar();
  const before = plain(c.getMembers().map(member => member.id));
  assert.equal(before.length, 3);
  assert.equal(before[0], 'leader');

  await c.reorderSoloMembers(2, 0);
  assert.deepEqual(plain(c.getMembers().map(member => member.id)), [before[2], before[0], before[1]]);
  assert.equal(snapshots.at(-1).type, 'SESSION_SNAPSHOT');

  await c.reorderSoloMembers(0, 2);
  assert.deepEqual(plain(c.getMembers().map(member => member.id)), before);

  await c.reorderSoloMembers(0, 0);
  assert.deepEqual(plain(c.getMembers().map(member => member.id)), before);

  c.soloTeam = false;
  await c.reorderSoloMembers(0, 1);
  assert.deepEqual(plain(c.getMembers().map(member => member.id)), before, 'Multiplayer sessions ignore reorder');

  await verifyLobbyDragLifecycle();
  await verifyLiveReorderPreview();
  verifyGestureWiring();
  console.log('PASS solo roster reorder: map/snapshot order, real lobby drag lifecycle, live insertion preview, release/cancel/session guards, gesture wiring');
}

module.exports = { lobbyBusinessSource, bodyEnd };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
