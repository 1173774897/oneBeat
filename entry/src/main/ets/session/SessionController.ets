import {
  COUNT_IN_BARS,
  MEMBER_HEARTBEAT_SWEEP_MS,
  MEMBER_HEARTBEAT_TIMEOUT_MS,
  PING_SAMPLES,
  RESYNC_INTERVAL_MS,
  SESSION_MAX_MEMBER_COUNT,
  SESSION_TCP_PORT,
  TRANSPORT_PREPARE_TIMEOUT_MS,
  TRANSPORT_PAUSE_PREROLL_MS,
  TRANSPORT_PREROLL_MS,
  TRANSPORT_RESTART_PREROLL_MS
} from '../common/Constants';
import { DEBUG } from 'BuildProfile';
import { MonotonicClock } from '../common/MonotonicClock';
import { createMessage } from '../protocol/messages';
import {
  BluetoothCalibrationStatePayload,
  ClientHelloPayload,
  ClientLeavePayload,
  LobbyReadyPayload,
  PingPayload,
  PingResponse,
  PongPayload,
  RandomPreviewCompletePayload,
  SessionDisbandedAckPayload,
  SessionDisbandedPayload,
  SessionMember,
  SessionSnapshotPayload,
  TransportPausePayload,
  TransportPayload,
  TransportPreparePayload,
  TransportResumePayload,
  TransportState,
  WireMessage
} from '../protocol/messages';
import { SessionServer } from '../network/socket/SessionServer';
import { SessionClient } from '../network/socket/SessionClient';
import { SessionPeerConnection } from '../network/transport/SessionPeerConnection';
import { ClockSyncEstimator, SyncSample } from '../sync/ClockSync';
import {
  P2pRoomInvitation,
  randomAuthNonce,
  validateP2pRoomInvitation
} from '../network/p2p/P2pInvitation';
import { isAllowedAvatarKey } from '../assets/AssetCatalog';
import {
  BeatPointState,
  beatPointStatesForRhythm,
  defaultBeatPointStates,
  isValidMeter,
  nextBeatPointState,
  normalizeBeatPointStates
} from '../common/MeterModel';
import { parseDrumProgram, serializeDrumProgram } from '../audio/DrumMachineCatalog';
import {
  defaultSessionAvatar,
  getExclusiveAvatarsLockedByReadyMembers,
  isAvatarAllowedForSession,
  isDuplicatableAvatar,
  isExclusiveTakenByOther,
  isRandomAvatar,
  isRandomPoolCharacter,
  isRosterAvatarKey,
  normalizeAvatarKey,
  pickFallbackAvatar,
  pickRandomCharacterKey,
  pickRandomColorSlot,
  rosterKeysForLobby
} from '../assets/CharacterCatalog';

export type SessionUiListener = () => void;

export interface ProDrumEditorSettings {
  beatsPerBar: number;
  beatUnit: number;
  bpm: number;
}

interface TransportPrepareWaiter {
  id: string;
  pendingConnectionIds: Set<string>;
  timerId: number;
  resolve: () => void;
}

const SOLO_BOT_ID_PREFIX: string = 'solo-bot-';
const SOLO_BOT_DISPLAY_NAME: string = '人机';
export const SOLO_MAX_BOT_COUNT: number = SESSION_MAX_MEMBER_COUNT - 1;
// Publish a future deadline so peers use clock sync, not packet arrival order,
// to switch their roster avatars. Late packets reveal immediately on receipt.
const RANDOM_AVATAR_REVEAL_LEAD_MS: number = 250;
const SESSION_DISBAND_ACK_TIMEOUT_MS: number = 800;
const MEMBER_RESYNC_FAILURE_LIMIT: number = 3;

type RemoteSessionEndReason = 'leader_exit' | 'connection_lost';

export class SessionController {
  readonly sessionId: string;
  readonly isLeader: boolean;
  private readonly server: SessionServer = new SessionServer();
  private readonly client: SessionClient = new SessionClient();
  private readonly clockSync: ClockSyncEstimator = new ClockSyncEstimator();
  private readonly connectionMembers: Map<string, SessionMember> = new Map();
  private readonly authenticatedConnections: Set<string> = new Set();
  private readonly usedAuthNonces: Set<string> = new Set();
  private readonly pendingPings: Map<string, (payload: PongPayload) => void> = new Map();
  private readonly connectionLastSeenMs: Map<string, number> = new Map();
  private p2pInvitation: P2pRoomInvitation | undefined = undefined;
  private uiListener: SessionUiListener = () => {
  };
  private resyncTimer: number = -1;
  private heartbeatSweepTimer: number = -1;
  private nextRandomDrawId: number = 0;
  private nextSoloBotNumber: number = 0;
  private randomAvatarRevealTimer: number = -1;
  private randomAvatarRevealsActive: boolean = true;
  private readonly revealedRandomAvatars: Map<string, number> = new Map();
  private proDrumEditorSettings: ProDrumEditorSettings | undefined = undefined;
  private nextTransportPrepareId: number = 0;
  private transportPrepareWaiter: TransportPrepareWaiter | undefined = undefined;
  private clockSyncWork: Promise<SyncSample> | undefined = undefined;
  private transportPauseTimer: number = -1;
  private remoteSessionEndReason: RemoteSessionEndReason | undefined = undefined;
  private readonly pendingDisbandAcks: Set<string> = new Set();
  private disbandAckResolver: (() => void) | undefined = undefined;
  private disbandAckTimer: number = -1;
  private consecutiveResyncFailures: number = 0;
  private appInBackground: boolean = false;

  bpm: number = 120;
  beatsPerBar: number = 4;
  beatUnit: number = 4;
  beatPointStates: BeatPointState[] = defaultBeatPointStates(4);
  rhythm: number = 0;
  drumProgram: string = '';
  avatarKey: string = defaultSessionAvatar();
  lobbyDeparted: boolean = false;
  localMemberId: string = '';
  soundId: number = 0;
  sceneKey: string = 'sunset_coast';
  state: TransportState = 'idle';
  beatIndex: number = 0;
  leaderHost: string = '';
  tcpPort: number = SESSION_TCP_PORT;
  /** 6 位数字只用于 BLE 附近房间匹配。 */
  joinCode: string = '';
  bleInviteAvailable: boolean = false;
  displayName: string = 'Player';
  bluetoothAcknowledged: boolean = false;
  /** 仅队长一人在场，不依赖 P2P / 队员加入 */
  soloTeam: boolean = false;

  constructor(sessionId: string, isLeader: boolean, displayName: string) {
    this.sessionId = sessionId;
    this.isLeader = isLeader;
    this.displayName = displayName;
    this.sceneKey = this.normalizeSceneKey(AppStorage.get<string>('selectedSceneKey') ?? 'sunset_coast');
    if (isLeader) {
      const leaderMember: SessionMember = {
        id: 'leader',
        displayName: displayName,
        avatarKey: this.avatarKey,
        colorSlot: -1,
        lobbyReady: false,
        bluetoothCalibrating: false,
        rttMs: 0,
        offsetMs: 0
      };
      this.assignAvatarIdentity(leaderMember, this.avatarKey);
      this.connectionMembers.set('leader', leaderMember);
    }
  }

  getProDrumEditorSettings(): ProDrumEditorSettings | undefined {
    if (this.proDrumEditorSettings === undefined) {
      return undefined;
    }
    return {
      beatsPerBar: this.proDrumEditorSettings.beatsPerBar,
      beatUnit: this.proDrumEditorSettings.beatUnit,
      bpm: this.proDrumEditorSettings.bpm
    };
  }

  rememberProDrumEditorSettings(beatsPerBar: number, beatUnit: number, bpm: number): void {
    if (!this.isLeader || !isValidMeter(beatsPerBar, beatUnit)) {
      return;
    }
    // This draft is intentionally session-local: first entry follows the lobby,
    // but later entries in the same team lifecycle preserve explicit PRO edits.
    this.proDrumEditorSettings = {
      beatsPerBar: beatsPerBar,
      beatUnit: beatUnit,
      bpm: Math.max(40, Math.min(240, bpm))
    };
  }

  getLocalMemberId(): string {
    if (this.isLeader) {
      return 'leader';
    }
    if (this.localMemberId.length > 0) {
      return this.localMemberId;
    }
    const members = this.getMembers();
    for (let i = 0; i < members.length; i++) {
      if (members[i].id !== 'leader' && members[i].displayName === this.displayName) {
        this.localMemberId = members[i].id;
        return this.localMemberId;
      }
    }
    return '';
  }

  isLocalLobbyReady(): boolean {
    const id = this.getLocalMemberId();
    if (id.length === 0) {
      return false;
    }
    const member = this.connectionMembers.get(id);
    return member !== undefined && member.lobbyReady === true;
  }

  allTeamMembersLobbyReady(): boolean {
    const members = this.getMembers();
    for (let i = 0; i < members.length; i++) {
      if (members[i].id === 'leader') {
        continue;
      }
      if (members[i].lobbyReady !== true) {
        return false;
      }
    }
    // A multiplayer room with no followers has nobody left to wait for, so the
    // leader may depart alone. Once a follower joins, every follower must still
    // be ready before this invariant becomes true.
    return true;
  }

  canLeaderStartWalk(): boolean {
    return !this.soloTeam && this.isLeader && this.allTeamMembersLobbyReady();
  }

  private assignAvatarIdentity(member: SessionMember, key: string): void {
    const normalized = normalizeAvatarKey(key);
    member.avatarKey = normalized;
    if (!isRandomAvatar(normalized)) {
      member.resolvedAvatarKey = undefined;
      member.colorSlot = -1;
      member.randomDrawId = undefined;
      member.randomAvatarRevealAtLeaderMs = undefined;
      return;
    }
    // The leader owns the result: the film can reveal its shared silhouette,
    // while the actual character colors remain hidden until leaving the lobby.
    const resolved = pickRandomCharacterKey();
    member.resolvedAvatarKey = resolved;
    member.colorSlot = pickRandomColorSlot(this.getMembers(), resolved, member.id);
    member.randomDrawId = ++this.nextRandomDrawId;
    member.randomAvatarRevealAtLeaderMs = undefined;
  }

  /** Complete only this device's draw (or its solo bot); the leader owns publication. */
  async completeRandomAvatarPreview(memberId: string, drawId: number): Promise<void> {
    if (!this.randomAvatarRevealsActive || this.lobbyDeparted ||
      (memberId !== this.getLocalMemberId() &&
        !(this.isLeader && this.soloTeam && SessionController.isSoloBotMemberId(memberId)))) {
      return;
    }
    const member = this.connectionMembers.get(memberId);
    if (member === undefined || !isRandomAvatar(member.avatarKey) || member.randomDrawId !== drawId ||
      !Number.isSafeInteger(drawId) || drawId <= 0) {
      return;
    }
    if (this.isLeader) {
      await this.publishRandomAvatarReveal(memberId, drawId);
    } else {
      await this.sendToLeader(createMessage('RANDOM_PREVIEW_COMPLETE', { drawId } as RandomPreviewCompletePayload));
    }
  }

  private async publishRandomAvatarReveal(memberId: string, drawId: number): Promise<void> {
    const member = this.connectionMembers.get(memberId);
    if (!this.isLeader || !this.randomAvatarRevealsActive || this.lobbyDeparted ||
      typeof drawId !== 'number' || !Number.isSafeInteger(drawId) || drawId <= 0 ||
      member === undefined || !isRandomAvatar(member.avatarKey) || member.randomDrawId !== drawId ||
      !isRandomPoolCharacter(member.resolvedAvatarKey ?? '') ||
      member.randomAvatarRevealAtLeaderMs !== undefined) {
      return;
    }
    // A stale/cancelled completion cannot publish a newer draw, even when both
    // happened to resolve to the same character. Duplicate acknowledgements are idempotent.
    member.randomAvatarRevealAtLeaderMs = MonotonicClock.nowMs() +
      (this.soloTeam ? 0 : RANDOM_AVATAR_REVEAL_LEAD_MS);
    await this.broadcastSnapshot();
  }

  /** Shared roster visibility, latched per draw so small clock corrections cannot hide it again. */
  isMemberRandomAvatarRevealed(memberId: string): boolean {
    const member = this.connectionMembers.get(memberId);
    return member !== undefined && isRandomAvatar(member.avatarKey) &&
      isRandomPoolCharacter(member.resolvedAvatarKey ?? '') &&
      this.revealedRandomAvatars.get(memberId) === member.randomDrawId &&
      member.randomDrawId !== undefined;
  }

  private stopRandomAvatarRevealTimer(): void {
    if (this.randomAvatarRevealTimer >= 0) {
      clearTimeout(this.randomAvatarRevealTimer);
      this.randomAvatarRevealTimer = -1;
    }
  }

  private scheduleRandomAvatarReveals(): void {
    this.stopRandomAvatarRevealTimer();
    if (!this.randomAvatarRevealsActive) {
      this.revealedRandomAvatars.clear();
      return;
    }
    const leaderNow = MonotonicClock.nowMs() + (this.isLeader ? 0 : this.getOffsetMs());
    let nextDelay: number = Number.POSITIVE_INFINITY;
    this.revealedRandomAvatars.forEach((drawId: number, id: string) => {
      const member = this.connectionMembers.get(id);
      if (member === undefined || member.randomDrawId !== drawId || !isRandomAvatar(member.avatarKey)) {
        this.revealedRandomAvatars.delete(id);
      }
    });
    this.connectionMembers.forEach((member: SessionMember) => {
      const drawId = member.randomDrawId ?? 0;
      const revealAt = member.randomAvatarRevealAtLeaderMs;
      if (!isRandomAvatar(member.avatarKey) || !isRandomPoolCharacter(member.resolvedAvatarKey ?? '') ||
        !Number.isSafeInteger(drawId) || drawId <= 0 || revealAt === undefined ||
        !Number.isFinite(revealAt) || revealAt < 0) {
        this.revealedRandomAvatars.delete(member.id);
        return;
      }
      if (this.revealedRandomAvatars.get(member.id) === drawId) {
        return;
      }
      if (revealAt <= leaderNow) {
        this.revealedRandomAvatars.set(member.id, drawId);
      } else {
        nextDelay = Math.min(nextDelay, revealAt - leaderNow);
      }
    });
    if (Number.isFinite(nextDelay)) {
      this.randomAvatarRevealTimer = setTimeout(() => {
        this.randomAvatarRevealTimer = -1;
        this.scheduleRandomAvatarReveals();
        this.notifyUi();
      }, Math.max(1, Math.ceil(nextDelay)));
    }
  }

  private canAssignAvatarToMember(memberId: string, key: string, checkLocalOwnership: boolean): boolean {
    if (!isRosterAvatarKey(key, this.soloTeam)) {
      return false;
    }
    // Purchases belong to the device choosing the character. A leader must not
    // evaluate a remote member with the leader's own local entitlement cache.
    if (checkLocalOwnership && !isAvatarAllowedForSession(key, this.soloTeam)) {
      return false;
    }
    const members = this.getMembers();
    const target = this.connectionMembers.get(memberId);
    if (target !== undefined && target.lobbyReady === true) {
      return false;
    }
    const readyLocked = getExclusiveAvatarsLockedByReadyMembers(members, memberId);
    if (readyLocked.has(key)) {
      return false;
    }
    if (isExclusiveTakenByOther(members, key, memberId)) {
      return false;
    }
    return true;
  }

  private resolveExclusiveConflictsAfterLock(lockedMemberId: string): void {
    const locker = this.connectionMembers.get(lockedMemberId);
    if (locker === undefined || locker.lobbyReady !== true) {
      return;
    }
    const lockedKey = locker.avatarKey;
    if (isDuplicatableAvatar(lockedKey)) {
      return;
    }
    this.connectionMembers.forEach((member: SessionMember, id: string) => {
      if (id === lockedMemberId || member.lobbyReady === true) {
        return;
      }
      if (member.avatarKey === lockedKey) {
        this.assignAvatarIdentity(member, pickFallbackAvatar(this.getMembers(), id, this.soloTeam));
      }
    });
  }

  async updateMemberAvatar(memberId: string, key: string): Promise<void> {
    const normalized = normalizeAvatarKey(key);
    if (!this.canAssignAvatarToMember(memberId, normalized, true)) {
      return;
    }
    if (this.soloTeam && this.isLeader) {
      const member = this.connectionMembers.get(memberId);
      if (member !== undefined) {
        this.assignAvatarIdentity(member, normalized);
        if (memberId === 'leader') {
          this.avatarKey = normalized;
        }
        await this.broadcastSnapshot();
      }
      return;
    }
    if (memberId !== this.getLocalMemberId()) {
      return;
    }
    if (this.isLocalLobbyReady()) {
      return;
    }
    await this.updateAvatar(normalized);
  }

  async setLobbyReady(ready: boolean): Promise<void> {
    if (this.soloTeam || this.isLeader) {
      return;
    }
    const memberId = this.getLocalMemberId();
    if (memberId.length === 0) {
      return;
    }
    await this.sendToLeader(createMessage('LOBBY_READY', { ready: ready } as LobbyReadyPayload));
  }

  /** Publish only the active measurement window; previews and saved results are settled states. */
  async setBluetoothCalibrationActive(active: boolean): Promise<void> {
    if (active && (this.lobbyDeparted || this.state !== 'idle')) {
      return;
    }
    const memberId = this.getLocalMemberId();
    if (memberId.length === 0) {
      return;
    }
    const member = this.connectionMembers.get(memberId);
    if (member === undefined || member.bluetoothCalibrating === active) {
      return;
    }
    member.bluetoothCalibrating = active;
    if (this.isLeader) {
      await this.broadcastSnapshot();
      return;
    }
    this.notifyUi();
    await this.sendToLeader(createMessage('BLUETOOTH_CALIBRATION_STATE', {
      active: active
    } as BluetoothCalibrationStatePayload));
  }

  async departLobbyToWalk(): Promise<void> {
    if (!this.isLeader || this.soloTeam || !this.canLeaderStartWalk()) {
      return;
    }
    this.lobbyDeparted = true;
    this.connectionMembers.forEach((member: SessionMember) => {
      member.bluetoothCalibrating = false;
    });
    await this.broadcastSnapshot();
  }

  async returnToLobby(): Promise<void> {
    if (!this.isLeader || (!this.soloTeam && !this.lobbyDeparted)) {
      return;
    }
    this.cancelScheduledPauseState();
    if (!this.soloTeam) {
      const pausePayload: TransportPausePayload = {
        pauseAtLeaderMonoMs: MonotonicClock.nowMs(),
        beatIndex: this.beatIndex
      };
      await this.sendToAll(createMessage('TRANSPORT_PAUSE', pausePayload));
    }
    this.state = 'idle';
    this.beatIndex = 0;
    this.lobbyDeparted = false;
    this.connectionMembers.forEach((member: SessionMember) => {
      member.lobbyReady = false;
      member.bluetoothCalibrating = false;
    });
    AppStorage.setOrCreate('lastTransportMessage', '');
    await this.broadcastSnapshot();
  }

  setUiListener(listener: SessionUiListener): void {
    this.uiListener = listener;
  }

  getOffsetMs(): number {
    return this.clockSync.getOffsetMs();
  }

  getRttMs(): number {
    return this.clockSync.getRttMs();
  }

  getSyncQuality(): string {
    if (this.isLeader && this.soloTeam) {
      return 'local';
    }
    return this.clockSync.getQualityLabel();
  }

  getMembers(): SessionMember[] {
    return Array.from(this.connectionMembers.values());
  }

  updateLeaderDisplayName(name: string): void {
    const leader = this.connectionMembers.get('leader');
    if (leader !== undefined) {
      leader.displayName = name;
    }
  }

  static isSoloBotMemberId(id: string): boolean {
    return id.startsWith(SOLO_BOT_ID_PREFIX);
  }

  getSoloBotCount(): number {
    return this.listSoloBotIdsSorted().length;
  }

  canAddSoloBot(): boolean {
    return this.getMembers().length < SESSION_MAX_MEMBER_COUNT &&
      this.getSoloBotCount() < SOLO_MAX_BOT_COUNT && this.getAvailableAvatarsForNewSoloBot().length > 0;
  }

  getAvailableAvatarsForNewSoloBot(): string[] {
    const members = this.getMembers();
    const roster = rosterKeysForLobby(true);
    const available: string[] = [];
    for (let i = 0; i < roster.length; i++) {
      const key = roster[i];
      if (!isAvatarAllowedForSession(key, true)) {
        continue;
      }
      if (isDuplicatableAvatar(key)) {
        available.push(key);
        continue;
      }
      if (!isExclusiveTakenByOther(members, key, '')) {
        available.push(key);
      }
    }
    return available;
  }

  private listSoloBotIdsSorted(): string[] {
    const ids: string[] = [];
    this.connectionMembers.forEach((_member: SessionMember, id: string) => {
      if (SessionController.isSoloBotMemberId(id)) {
        ids.push(id);
      }
    });
    ids.sort((a: string, b: string) => {
      const ai = parseInt(a.substring(SOLO_BOT_ID_PREFIX.length), 10);
      const bi = parseInt(b.substring(SOLO_BOT_ID_PREFIX.length), 10);
      return ai - bi;
    });
    return ids;
  }

  private purgeSoloBots(): void {
    const removeIds: string[] = [];
    this.connectionMembers.forEach((_member: SessionMember, id: string) => {
      if (SessionController.isSoloBotMemberId(id)) {
        removeIds.push(id);
      }
    });
    for (let i = 0; i < removeIds.length; i++) {
      this.connectionMembers.delete(removeIds[i]);
    }
  }

  /** 单人模式默认仅创建玩家；人机必须由玩家在大厅或行进页主动添加。 */
  ensureSoloWalkPair(leaderName: string): void {
    this.purgeSoloBots();
    const leaderMember: SessionMember = {
      id: 'leader',
      displayName: leaderName,
      avatarKey: this.avatarKey,
      colorSlot: -1,
      lobbyReady: false,
      bluetoothCalibrating: false,
      rttMs: 0,
      offsetMs: 0
    };
    this.assignAvatarIdentity(leaderMember, this.avatarKey);
    this.connectionMembers.set('leader', leaderMember);
    this.notifyUi();
  }

  async addSoloBotWithNextAvatar(): Promise<string | undefined> {
    if (!this.isLeader || !this.soloTeam || this.getMembers().length >= SESSION_MAX_MEMBER_COUNT) {
      return undefined;
    }
    const available = this.getAvailableAvatarsForNewSoloBot();
    if (available.length === 0) {
      return undefined;
    }
    const ids = this.listSoloBotIdsSorted();
    const lastId = ids.length > 0 ? ids[ids.length - 1] : '';
    const lastNumber = lastId.length > 0 ? parseInt(lastId.substring(SOLO_BOT_ID_PREFIX.length), 10) : 0;
    // Member IDs identify a lifetime, not a reusable roster slot. Reusing an
    // ID after removal would reuse preview caches and admit stale callbacks.
    this.nextSoloBotNumber = Math.max(this.nextSoloBotNumber, lastNumber) + 1;
    const newBotId = `${SOLO_BOT_ID_PREFIX}${this.nextSoloBotNumber}`;
    const member: SessionMember = {
      id: newBotId,
      displayName: SOLO_BOT_DISPLAY_NAME,
      avatarKey: available[0],
      colorSlot: -1,
      lobbyReady: false,
      bluetoothCalibrating: false,
      rttMs: 0,
      offsetMs: 0
    };
    this.assignAvatarIdentity(member, available[0]);
    this.connectionMembers.set(newBotId, member);
    await this.broadcastSnapshot();
    return newBotId;
  }

  async removeSoloBotById(id: string): Promise<void> {
    if (!this.isLeader || !this.soloTeam || !SessionController.isSoloBotMemberId(id)) {
      return;
    }
    this.connectionMembers.delete(id);
    await this.broadcastSnapshot();
  }

  async addSoloBot(): Promise<void> {
    await this.addSoloBotWithNextAvatar();
  }

  async removeSoloBot(): Promise<void> {
    const ids = this.listSoloBotIdsSorted();
    if (ids.length === 0) {
      return;
    }
    await this.removeSoloBotById(ids[ids.length - 1]);
  }

  removeSoloBots(): void {
    this.purgeSoloBots();
    this.notifyUi();
  }

  configureP2pRoom(invitation: P2pRoomInvitation): void {
    validateP2pRoomInvitation(invitation);
    this.p2pInvitation = invitation;
    this.joinCode = invitation.code;
    this.usedAuthNonces.clear();
  }

  getP2pInvitation(): P2pRoomInvitation | undefined {
    return this.p2pInvitation;
  }

  async startLeader(host: string): Promise<void> {
    this.randomAvatarRevealsActive = true;
    if (!this.soloTeam && this.p2pInvitation === undefined) {
      throw new Error('P2P 房间尚未初始化');
    }
    this.leaderHost = host;
    this.server.setHandlers(
      (connection, message) => this.onLeaderMessage(connection, message),
      (connection) => {
        this.connectionLastSeenMs.set(connection.id, MonotonicClock.nowMs());
        this.notifyUi();
      },
      (connectionId) => {
        this.connectionMembers.delete(connectionId);
        this.authenticatedConnections.delete(connectionId);
        this.connectionLastSeenMs.delete(connectionId);
        this.releaseTransportPreparationConnection(connectionId);
        void this.broadcastSnapshot();
      }
    );
    this.tcpPort = await this.server.start(SESSION_TCP_PORT);
    this.startHeartbeatSweep();
    this.notifyUi();
  }

  async connectMember(
    host: string,
    port: number,
    invitation: P2pRoomInvitation
  ): Promise<void> {
    this.randomAvatarRevealsActive = true;
    validateP2pRoomInvitation(invitation);
    this.leaderHost = host;
    this.tcpPort = port;
    this.client.setHandler((message) => this.onMemberMessage(message));
    this.client.setCloseHandler(() => this.onMemberConnectionClosed());
    await this.client.connect(host, port);
    await this.client.send(createMessage('CLIENT_HELLO', {
      displayName: this.displayName,
      avatarKey: this.avatarKey,
      joinCode: invitation.code,
      roomId: invitation.roomId,
      authToken: invitation.authToken,
      protocolVersion: invitation.protocolVersion,
      nonce: randomAuthNonce()
    } as ClientHelloPayload));
    const sync = await this.measureClockSync(PING_SAMPLES);
    this.clockSync.applySample(sync);
    this.scheduleRandomAvatarReveals();
    this.startResyncLoop();
    this.notifyUi();
  }

  async disconnect(): Promise<void> {
    this.randomAvatarRevealsActive = false;
    this.stopRandomAvatarRevealTimer();
    this.revealedRandomAvatars.clear();
    this.finishTransportPreparation();
    this.cancelScheduledPauseState();
    this.stopResyncLoop();
    if (this.isLeader) {
      this.stopHeartbeatSweep();
      // A deliberate leader exit is a room-level event. Send it before closing
      // sockets so members can distinguish disbanding from a transient link loss.
      await this.broadcastSessionDisbanded();
      await this.server.stop();
      this.authenticatedConnections.clear();
      this.connectionLastSeenMs.clear();
      this.usedAuthNonces.clear();
    } else {
      await this.announceLeave();
      await this.client.disconnect();
    }
    this.notifyUi();
  }

  getRemoteSessionEndReason(): RemoteSessionEndReason | undefined {
    return this.remoteSessionEndReason;
  }

  hasConnectedFollowers(): boolean {
    return this.authenticatedConnections.size > 0;
  }

  handleAppForeground(): void {
    this.appInBackground = false;
    this.consecutiveResyncFailures = 0;
    if (this.remoteSessionEndReason !== undefined) {
      return;
    }
    if (this.isLeader) {
      const now = MonotonicClock.nowMs();
      // Ability timers may be frozen in the background. Give sockets that are
      // still open a fresh heartbeat window before the resumed sweep runs.
      this.authenticatedConnections.forEach((connectionId: string) => {
        this.connectionLastSeenMs.set(connectionId, now);
      });
      return;
    }
    // Do not wait up to RESYNC_INTERVAL_MS after foregrounding to prove that a
    // half-open P2P/TCP path is still usable.
    if (this.clockSyncWork === undefined) {
      void this.runLightResync();
    }
  }

  handleAppBackground(): void {
    this.appInBackground = true;
  }

  async updateBpm(next: number): Promise<void> {
    if (!this.isLeader) { return; }
    const restartRunningTransport = this.state === 'playing' || this.state === 'countdown';
    this.bpm = Math.max(40, Math.min(240, next));
    if (!restartRunningTransport) {
      await this.broadcastSnapshot();
      return;
    }
    await this.restartRunningTransportAfterConfiguration();
  }

  async updateSoundId(next: number): Promise<void> {
    if (!this.isLeader) { return; }
    const restartRunningTransport = this.state === 'playing' || this.state === 'countdown';
    this.soundId = next % 3;
    if (!restartRunningTransport) {
      await this.broadcastSnapshot();
      return;
    }
    await this.restartRunningTransportAfterConfiguration();
  }

  async updateAvatar(key: string): Promise<void> {
    const normalized = normalizeAvatarKey(key);
    if (!isAllowedAvatarKey(normalized, this.soloTeam)) { return; }
    const memberId = this.getLocalMemberId();
    if (!this.soloTeam && memberId.length > 0 && !this.canAssignAvatarToMember(memberId, normalized, true)) {
      return;
    }
    if (this.isLocalLobbyReady()) {
      return;
    }
    this.avatarKey = normalized;
    if (this.isLeader) {
      const member = this.connectionMembers.get('leader');
      if (member !== undefined) {
        this.assignAvatarIdentity(member, normalized);
      }
      await this.broadcastSnapshot();
    } else {
      await this.sendToLeader(createMessage('MEMBER_UPDATE', {
        displayName: this.displayName, avatarKey: normalized
      } as ClientHelloPayload));
    }
  }

  async updateMeter(beats: number, unit: number): Promise<void> {
    if (!this.isLeader || !isValidMeter(beats, unit)) { return; }
    const restartRunningTransport = this.state === 'playing' || this.state === 'countdown';
    const previousBeatCount = this.beatPointStates.length;
    this.beatsPerBar = beats;
    this.beatUnit = unit;
    this.beatPointStates = normalizeBeatPointStates(this.beatPointStates, beats);
    if (this.rhythm === 2) {
      for (let i = previousBeatCount; i < this.beatPointStates.length; i++) {
        this.beatPointStates[i] = 'silent';
      }
    }
    if (this.rhythm === 3 && this.drumProgram.length > 0) {
      const program = parseDrumProgram(this.drumProgram);
      program.beatsPerBar = beats;
      program.beatUnit = unit;
      this.drumProgram = serializeDrumProgram(program);
    }
    if (!restartRunningTransport) {
      await this.broadcastSnapshot();
      return;
    }

    await this.restartRunningTransportAfterConfiguration();
  }

  async cycleBeatPointState(index: number): Promise<void> {
    if (!this.isLeader || index < 0 || index >= this.beatsPerBar) {
      return;
    }
    const restartRunningTransport = this.state === 'playing' || this.state === 'countdown';
    const next = normalizeBeatPointStates(this.beatPointStates, this.beatsPerBar);
    next[index] = nextBeatPointState(next[index]);
    this.beatPointStates = next;
    if (!restartRunningTransport) {
      await this.broadcastSnapshot();
      return;
    }
    await this.restartRunningTransportAfterConfiguration();
  }

  private async restartRunningTransportAfterConfiguration(): Promise<void> {
    // Configure every peer first, then restart on a shared future downbeat. Applying
    // on packet receipt would let network latency put devices in different bars.
    // 发送前先强制队员重采样时钟偏移，避免重启时刻 offset 陈旧导致即使有充足 preroll 仍偏。
    this.cancelScheduledPauseState();
    await this.prepareConnectedMembersForTransport();
    this.state = 'countdown';
    await this.broadcastSnapshot();
    const nextBarBeatIndex = (Math.floor(this.beatIndex / this.beatsPerBar) + 1) * this.beatsPerBar;
    this.beatIndex = nextBarBeatIndex;
    const restartAt = MonotonicClock.nowMs() + TRANSPORT_RESTART_PREROLL_MS;
    if (DEBUG) {
      console.info(`OneBeatSync restart[leader] restartAt=${restartAt.toFixed(2)}ms beat=${nextBarBeatIndex} beatsPerBar=${this.beatsPerBar} now=${MonotonicClock.nowMs().toFixed(2)}ms`);
    }
    const payload: TransportPayload = {
      startAtLeaderMonoMs: restartAt,
      countdownMs: 0,
      beatIndex: nextBarBeatIndex,
      countInBeats: 0
    };
    const wire = createMessage('TRANSPORT', payload);
    AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(wire));
    this.notifyUi();
    await this.sendToAll(wire);
  }

  async updateRhythm(rhythm: number): Promise<void> {
    if (!this.isLeader || rhythm < 0 || rhythm > 3) { return; }
    const restartRunningTransport = this.state === 'playing' || this.state === 'countdown';
    this.rhythm = rhythm;
    if (rhythm >= 0 && rhythm <= 2) {
      this.beatPointStates = beatPointStatesForRhythm(rhythm, this.beatsPerBar);
    }
    if (!restartRunningTransport) {
      await this.broadcastSnapshot();
      return;
    }
    await this.restartRunningTransportAfterConfiguration();
  }

  async updateDrumProgram(program: string): Promise<void> {
    if (!this.isLeader || program.length === 0) { return; }
    const restartRunningTransport = this.state === 'playing' || this.state === 'countdown';
    this.drumProgram = program;
    this.rhythm = 3;
    if (!restartRunningTransport) {
      await this.broadcastSnapshot();
      return;
    }
    await this.restartRunningTransportAfterConfiguration();
  }

  async updateSceneKey(key: string): Promise<void> {
    if (!this.isLeader) { return; }
    this.sceneKey = this.normalizeSceneKey(key);
    AppStorage.setOrCreate('selectedSceneKey', this.sceneKey);
    await this.broadcastSnapshot();
  }

  async startTransport(): Promise<number> {
    if (!this.isLeader) {
      return 0;
    }
    this.cancelScheduledPauseState();
    await this.prepareConnectedMembersForTransport();
    this.state = 'countdown';
    // 全新起拍从第一小节 downbeat（第 1 拍）开始，避免沿用上一次停在中途的拍号
    this.beatIndex = 0;
    const countInBeats = this.beatsPerBar * COUNT_IN_BARS;
    const countdownMs = Math.round(countInBeats * 60000 / this.bpm);
    const startAt = MonotonicClock.nowMs() + TRANSPORT_PREROLL_MS;
    const payload: TransportPayload = {
      startAtLeaderMonoMs: startAt,
      countdownMs: countdownMs,
      beatIndex: this.beatIndex,
      countInBeats: countInBeats
    };
    await this.sendToAll(createMessage('TRANSPORT', payload));
    AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(createMessage('TRANSPORT', payload)));
    await this.broadcastSnapshot();
    return startAt;
  }

  async pauseTransport(): Promise<void> {
    if (!this.isLeader) {
      return;
    }
    await this.prepareConnectedMembersForTransport();
    const pauseAt = MonotonicClock.nowMs() + TRANSPORT_PAUSE_PREROLL_MS;
    const payload: TransportPausePayload = {
      pauseAtLeaderMonoMs: pauseAt,
      beatIndex: this.beatIndex
    };
    const wire = createMessage('TRANSPORT_PAUSE', payload);
    AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(wire));
    this.schedulePauseState(payload);
    this.notifyUi();
    await this.sendToAll(wire);
  }

  async resumeTransport(): Promise<number> {
    if (!this.isLeader) {
      return 0;
    }
    this.cancelScheduledPauseState();
    await this.prepareConnectedMembersForTransport();
    this.state = 'countdown';
    // 恢复时把拍号对齐到下一小节 downbeat，保证 count-in 结束后主循环从第 1 拍（小节头）切入
    this.beatIndex = Math.ceil(this.beatIndex / this.beatsPerBar) * this.beatsPerBar;
    const countInBeats = this.beatsPerBar * COUNT_IN_BARS;
    const resumeAt = MonotonicClock.nowMs() + TRANSPORT_PREROLL_MS;
    const payload: TransportResumePayload = {
      resumeAtLeaderMonoMs: resumeAt,
      beatIndex: this.beatIndex,
      countInBeats: countInBeats
    };
    const wire = createMessage('TRANSPORT_RESUME', payload);
    await this.sendToAll(wire);
    AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(wire));
    await this.broadcastSnapshot();
    return resumeAt;
  }

  completeCountIn(index: number): void {
    if (this.state !== 'countdown') {
      return;
    }
    this.beatIndex = index;
    this.state = 'playing';
    if (this.isLeader) {
      void this.broadcastSnapshot();
    } else {
      this.notifyUi();
    }
  }

  setBeatIndex(index: number, notify: boolean = true): void {
    this.beatIndex = index;
    if (notify) {
      this.notifyUi();
    }
  }

  buildJoinQrPayload(): string {
    if (this.soloTeam || this.p2pInvitation === undefined) {
      return '';
    }
    return JSON.stringify(this.p2pInvitation);
  }

  private async broadcastSnapshot(): Promise<void> {
    if (!this.isLeader) {
      return;
    }
    this.scheduleRandomAvatarReveals();
    const payload: SessionSnapshotPayload = {
      sessionId: this.sessionId,
      bpm: this.bpm,
      beatsPerBar: this.beatsPerBar,
      beatUnit: this.beatUnit,
      beatPointStates: this.beatPointStates.slice(),
      rhythm: this.rhythm,
      drumProgram: this.drumProgram,
      sceneKey: this.sceneKey,
      soundId: this.soundId,
      state: this.state,
      leaderMonoMs: MonotonicClock.nowMs(),
      members: this.getMembers(),
      beatIndex: this.beatIndex,
      lobbyDeparted: this.lobbyDeparted ? true : undefined
    };
    this.notifyUi();
    await this.sendToAll(createMessage('SESSION_SNAPSHOT', payload));
  }

  private onLeaderMessage(connection: SessionPeerConnection, message: WireMessage): void {
    this.connectionLastSeenMs.set(connection.id, MonotonicClock.nowMs());
    if (!this.soloTeam && message.type !== 'CLIENT_HELLO' &&
      !this.authenticatedConnections.has(connection.id)) {
      console.warn(`Rejected message before room authentication: ${connection.id}`);
      void connection.close();
      return;
    }
    if (message.type === 'SESSION_DISBANDED_ACK') {
      if (this.pendingDisbandAcks.delete(connection.id) && this.pendingDisbandAcks.size === 0) {
        this.finishDisbandAckWait();
      }
      return;
    }
    if (message.type === 'CLIENT_LEAVE') {
      const removed = this.connectionMembers.delete(connection.id);
      this.authenticatedConnections.delete(connection.id);
      this.connectionLastSeenMs.delete(connection.id);
      this.releaseTransportPreparationConnection(connection.id);
      if (removed) {
        this.notifyUi();
      }
      // Remove it from the server's broadcast set before publishing the new
      // roster, so one closing socket cannot block updates to remaining peers.
      this.server.removeConnection(connection.id);
      void connection.close();
      return;
    }
    if (message.type === 'MEMBER_UPDATE') {
      const update = message.payload as ClientHelloPayload;
      const member = this.connectionMembers.get(connection.id);
      if (member === undefined || member.lobbyReady === true) {
        return;
      }
      const normalized = normalizeAvatarKey(update.avatarKey);
      if (this.canAssignAvatarToMember(connection.id, normalized, false)) {
        this.assignAvatarIdentity(member, normalized);
        void this.broadcastSnapshot();
      }
      return;
    }
    if (message.type === 'RANDOM_PREVIEW_COMPLETE') {
      const completed = message.payload as RandomPreviewCompletePayload;
      if (completed !== undefined && completed !== null) {
        // Never trust a payload member id or avatar: the authenticated socket
        // owns exactly one member, and the leader already assigned its result.
        void this.publishRandomAvatarReveal(connection.id, completed.drawId);
      }
      return;
    }
    if (message.type === 'LOBBY_READY') {
      const readyPayload = message.payload as LobbyReadyPayload;
      const member = this.connectionMembers.get(connection.id);
      if (member === undefined) {
        return;
      }
      if (readyPayload.ready && !this.canAssignAvatarToMember(connection.id, member.avatarKey, false)) {
        return;
      }
      member.lobbyReady = readyPayload.ready;
      if (readyPayload.ready) {
        this.resolveExclusiveConflictsAfterLock(connection.id);
      }
      void this.broadcastSnapshot();
      return;
    }
    if (message.type === 'BLUETOOTH_CALIBRATION_STATE') {
      const calibrationPayload = message.payload as BluetoothCalibrationStatePayload;
      const member = this.connectionMembers.get(connection.id);
      if (member === undefined || calibrationPayload === undefined || calibrationPayload === null ||
        typeof calibrationPayload.active !== 'boolean' ||
        (calibrationPayload.active && (this.lobbyDeparted || this.state !== 'idle'))) {
        return;
      }
      if (member.bluetoothCalibrating === calibrationPayload.active) {
        return;
      }
      member.bluetoothCalibrating = calibrationPayload.active;
      void this.broadcastSnapshot();
      return;
    }
    if (message.type === 'TRANSPORT_READY') {
      const ready = message.payload as TransportPreparePayload;
      const waiter = this.transportPrepareWaiter;
      if (waiter !== undefined && ready.id === waiter.id) {
        waiter.pendingConnectionIds.delete(connection.id);
        if (waiter.pendingConnectionIds.size === 0) {
          this.finishTransportPreparation(waiter.id);
        }
      }
      return;
    }
    if (message.type === 'CLIENT_HELLO') {
      const hello = message.payload as ClientHelloPayload;
      if (!this.soloTeam && !this.isValidRoomHello(hello)) {
        console.warn(`Rejected unauthenticated session client: ${connection.id}`);
        void connection.close();
        return;
      }
      // Capacity is enforced by the leader before authentication so parallel
      // join attempts cannot create a tenth member or enter later snapshots.
      if (!this.connectionMembers.has(connection.id) &&
        this.connectionMembers.size >= SESSION_MAX_MEMBER_COUNT) {
        console.warn(`Rejected session client because room is full: ${connection.id}`);
        void connection.close();
        return;
      }
      if (hello.nonce !== undefined) {
        this.usedAuthNonces.add(hello.nonce);
      }
      this.authenticatedConnections.add(connection.id);
      const requestedAvatar = normalizeAvatarKey(hello.avatarKey);
      const allowedAvatar = isRosterAvatarKey(requestedAvatar, this.soloTeam)
        ? requestedAvatar : defaultSessionAvatar();
      const member: SessionMember = {
        id: connection.id,
        displayName: hello.displayName,
        avatarKey: allowedAvatar,
        colorSlot: -1,
        lobbyReady: false,
        bluetoothCalibrating: false,
        rttMs: 0,
        offsetMs: 0
      };
      this.assignAvatarIdentity(member, allowedAvatar);
      this.connectionMembers.set(connection.id, member);
      void this.broadcastSnapshot();
      return;
    }
    if (message.type === 'PING') {
      const ping = message.payload as PingPayload;
      const recvMono = MonotonicClock.nowMs();
      const pong: PongPayload = {
        id: ping.id,
        clientMono: ping.clientMono,
        serverMono: recvMono,
        leaderMono: MonotonicClock.nowMs()
      };
      void connection.send(createMessage('PONG', pong));
    }
  }

  private isValidRoomHello(hello: ClientHelloPayload): boolean {
    const invitation = this.p2pInvitation;
    const nonce = hello.nonce ?? '';
    if (invitation === undefined || invitation.expiresAt <= Date.now()) {
      return false;
    }
    if (nonce.length < 16 || this.usedAuthNonces.has(nonce)) {
      return false;
    }
    return hello.joinCode === invitation.code &&
      hello.roomId === invitation.roomId &&
      hello.authToken === invitation.authToken &&
      hello.protocolVersion === invitation.protocolVersion;
  }

  private onMemberMessage(message: WireMessage): void {
    if (message.type === 'SESSION_DISBANDED') {
      const payload = message.payload as SessionDisbandedPayload;
      if (payload === undefined || payload === null ||
        payload.reason !== 'leader_exit' || this.remoteSessionEndReason !== undefined) {
        return;
      }
      // Mark the reason before awaiting ACK so the following socket close cannot
      // downgrade an explicit room disband into a generic connection-loss event.
      this.remoteSessionEndReason = 'leader_exit';
      void this.acknowledgeAndApplySessionDisband();
      return;
    }
    if (message.type === 'PONG') {
      const pong = message.payload as PongPayload;
      const resolver = this.pendingPings.get(pong.id);
      if (resolver !== undefined) {
        resolver(pong);
        this.pendingPings.delete(pong.id);
      }
      return;
    }
    if (message.type === 'SESSION_SNAPSHOT') {
      const snapshot = message.payload as SessionSnapshotPayload;
      this.applySnapshot(snapshot);
      return;
    }
    if (message.type === 'TRANSPORT_PREPARE') {
      void this.handleTransportPreparation(message.payload as TransportPreparePayload);
      return;
    }
    if (message.type === 'TRANSPORT') {
      this.cancelScheduledPauseState();
      this.state = 'countdown';
      AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(message));
      this.notifyUi();
      return;
    }
    if (message.type === 'TRANSPORT_PAUSE') {
      const payload = message.payload as TransportPausePayload;
      AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(message));
      this.schedulePauseState(payload);
      this.notifyUi();
      return;
    }
    if (message.type === 'TRANSPORT_RESUME') {
      this.cancelScheduledPauseState();
      this.state = 'countdown';
      AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(message));
      this.notifyUi();
    }
  }

  private async announceLeave(): Promise<void> {
    if (!this.client.isConnected()) {
      return;
    }
    try {
      await this.client.send(createMessage('CLIENT_LEAVE', {
        reason: 'user_exit'
      } as ClientLeavePayload));
    } catch (_e) {
      // Socket close detection remains the fallback for abrupt disconnects.
    }
  }

  private async broadcastSessionDisbanded(): Promise<void> {
    const message = createMessage('SESSION_DISBANDED', {
      reason: 'leader_exit'
    } as SessionDisbandedPayload);
    this.pendingDisbandAcks.clear();
    const connections = this.server.getConnections();
    for (let i = 0; i < connections.length; i++) {
      if (this.authenticatedConnections.has(connections[i].id)) {
        this.pendingDisbandAcks.add(connections[i].id);
      }
    }
    await this.server.broadcast(async (connection: SessionPeerConnection) => {
      if (!this.authenticatedConnections.has(connection.id)) {
        return;
      }
      try {
        await connection.send(message);
      } catch (err) {
        // One stale peer must not prevent the leader from notifying and closing
        // every other member connection during room teardown.
        console.warn(`Session disband notify failed for ${connection.id}: ${(err as Error).message}`);
      }
    });
    if (this.pendingDisbandAcks.size === 0) {
      return;
    }
    await new Promise<void>((resolve: () => void) => {
      this.disbandAckResolver = resolve;
      this.disbandAckTimer = setTimeout(() => this.finishDisbandAckWait(), SESSION_DISBAND_ACK_TIMEOUT_MS);
    });
    if (this.pendingDisbandAcks.size > 0) {
      console.warn(`Session disband ACK timeout: pending=${Array.from(this.pendingDisbandAcks).join(',')}`);
    }
    this.pendingDisbandAcks.clear();
  }

  private async acknowledgeAndApplySessionDisband(): Promise<void> {
    try {
      await this.client.send(createMessage('SESSION_DISBANDED_ACK', {
        received: true
      } as SessionDisbandedAckPayload));
    } catch (err) {
      console.warn(`Session disband ACK failed: ${(err as Error).message}`);
    }
    this.applyRemoteSessionEnd();
  }

  private onMemberConnectionClosed(): void {
    if (this.remoteSessionEndReason !== undefined) {
      return;
    }
    // There is no reconnect protocol for an established room. Leaving a stale
    // roster visible would imply a live team that can no longer receive control.
    this.remoteSessionEndReason = 'connection_lost';
    this.applyRemoteSessionEnd();
  }

  private applyRemoteSessionEnd(): void {
    this.cancelScheduledPauseState();
    this.stopResyncLoop();
    this.state = 'idle';
    AppStorage.setOrCreate('lastTransportMessage', '');
    this.notifyUi();
  }

  private finishDisbandAckWait(): void {
    if (this.disbandAckTimer >= 0) {
      clearTimeout(this.disbandAckTimer);
      this.disbandAckTimer = -1;
    }
    const resolve = this.disbandAckResolver;
    this.disbandAckResolver = undefined;
    resolve?.();
  }

  private applySnapshot(snapshot: SessionSnapshotPayload): void {
    this.bpm = snapshot.bpm;
    this.beatsPerBar = snapshot.beatsPerBar;
    this.beatUnit = snapshot.beatUnit ?? 4;
    this.rhythm = snapshot.rhythm ?? 0;
    this.beatPointStates = normalizeBeatPointStates(
      snapshot.beatPointStates ?? beatPointStatesForRhythm(this.rhythm, this.beatsPerBar),
      this.beatsPerBar);
    this.drumProgram = snapshot.drumProgram ?? '';
    this.sceneKey = this.normalizeSceneKey(snapshot.sceneKey ?? 'sunset_coast');
    AppStorage.setOrCreate('selectedSceneKey', this.sceneKey);
    this.soundId = snapshot.soundId;
    this.state = snapshot.state;
    this.beatIndex = snapshot.beatIndex;
    this.connectionMembers.clear();
    for (let i = 0; i < snapshot.members.length; i++) {
      this.connectionMembers.set(snapshot.members[i].id, snapshot.members[i]);
    }
    this.lobbyDeparted = snapshot.lobbyDeparted === true;
    const localId = this.getLocalMemberId();
    if (localId.length > 0) {
      const localMember = this.connectionMembers.get(localId);
      if (localMember !== undefined) {
        this.avatarKey = localMember.avatarKey;
      }
    }
    this.scheduleRandomAvatarReveals();
    this.notifyUi();
  }

  private normalizeSceneKey(key: string): string {
    return key === 'neon_street' ? 'neon_street' : 'sunset_coast';
  }

  private async prepareConnectedMembersForTransport(): Promise<void> {
    if (this.soloTeam || this.authenticatedConnections.size === 0) {
      return;
    }
    this.finishTransportPreparation();
    const pendingConnectionIds = new Set<string>();
    this.authenticatedConnections.forEach((connectionId: string) => {
      pendingConnectionIds.add(connectionId);
    });
    const id = `transport-prepare-${++this.nextTransportPrepareId}-${Math.round(MonotonicClock.nowMs())}`;
    let resolveReady: () => void = () => {};
    const ready = new Promise<void>((resolve) => {
      resolveReady = resolve;
    });
    const waiter: TransportPrepareWaiter = {
      id: id,
      pendingConnectionIds: pendingConnectionIds,
      timerId: -1,
      resolve: resolveReady
    };
    this.transportPrepareWaiter = waiter;
    waiter.timerId = setTimeout(() => {
      this.finishTransportPreparation(id);
    }, TRANSPORT_PREPARE_TIMEOUT_MS);

    const wire = createMessage('TRANSPORT_PREPARE', { id: id } as TransportPreparePayload);
    const connections = this.server.getConnections();
    for (let i = 0; i < connections.length; i++) {
      if (!pendingConnectionIds.has(connections[i].id)) {
        continue;
      }
      try {
        await connections[i].send(wire);
      } catch (_e) {
        this.releaseTransportPreparationConnection(connections[i].id);
      }
    }
    if (pendingConnectionIds.size === 0) {
      this.finishTransportPreparation(id);
    }
    await ready;
  }

  private finishTransportPreparation(expectedId?: string): void {
    const waiter = this.transportPrepareWaiter;
    if (waiter === undefined || (expectedId !== undefined && waiter.id !== expectedId)) {
      return;
    }
    this.transportPrepareWaiter = undefined;
    if (waiter.timerId >= 0) {
      clearTimeout(waiter.timerId);
    }
    waiter.resolve();
  }

  private releaseTransportPreparationConnection(connectionId: string): void {
    const waiter = this.transportPrepareWaiter;
    if (waiter === undefined) {
      return;
    }
    waiter.pendingConnectionIds.delete(connectionId);
    if (waiter.pendingConnectionIds.size === 0) {
      this.finishTransportPreparation(waiter.id);
    }
  }

  private async handleTransportPreparation(payload: TransportPreparePayload): Promise<void> {
    try {
      const sample = await this.measureClockSync(PING_SAMPLES);
      this.clockSync.applySample(sample);
      this.scheduleRandomAvatarReveals();
      this.notifyUi();
    } catch (_e) {
      // The leader has a bounded wait and will use the last valid offset if a
      // fresh exchange is interrupted by a transient network failure.
    }
    if (this.isMemberTransportConnected()) {
      try {
        await this.sendToLeader(createMessage('TRANSPORT_READY', { id: payload.id } as TransportPreparePayload));
      } catch (_e) {
        // A closed connection no longer participates in the leader's waiter.
      }
    }
  }

  private async measureClockSync(sampleCount: number): Promise<SyncSample> {
    const active = this.clockSyncWork;
    if (active !== undefined) {
      return await active;
    }
    const work = ClockSyncEstimator.measureWithSender(
      async (id, clientMono) => {
        return await this.sendPing(id, clientMono);
      },
      sampleCount,
      (offsetMs, rttMs) => this.clockSync.recordSample(offsetMs, rttMs)
    );
    this.clockSyncWork = work;
    try {
      return await work;
    } finally {
      if (this.clockSyncWork === work) {
        this.clockSyncWork = undefined;
      }
    }
  }

  private async sendPing(id: string, clientMono: number): Promise<PingResponse> {
    return await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingPings.delete(id);
        reject(new Error('ping timeout'));
      }, 2000);
      this.pendingPings.set(id, (pong) => {
        clearTimeout(timeout);
        resolve({ serverMono: pong.serverMono, leaderMono: pong.leaderMono });
      });
      void this.sendToLeader(createMessage('PING', { id: id, clientMono: clientMono } as PingPayload));
    });
  }

  private startResyncLoop(): void {
    this.stopResyncLoop();
    this.resyncTimer = setInterval(() => {
      void this.runLightResync();
    }, RESYNC_INTERVAL_MS);
  }

  private stopResyncLoop(): void {
    if (this.resyncTimer >= 0) {
      clearInterval(this.resyncTimer);
      this.resyncTimer = -1;
    }
  }

  private startHeartbeatSweep(): void {
    this.stopHeartbeatSweep();
    this.heartbeatSweepTimer = setInterval(() => {
      this.removeStaleMembers();
    }, MEMBER_HEARTBEAT_SWEEP_MS);
  }

  private stopHeartbeatSweep(): void {
    if (this.heartbeatSweepTimer >= 0) {
      clearInterval(this.heartbeatSweepTimer);
      this.heartbeatSweepTimer = -1;
    }
  }

  private removeStaleMembers(): void {
    if (!this.isLeader || this.appInBackground) {
      return;
    }
    const now = MonotonicClock.nowMs();
    const staleIds: string[] = [];
    this.authenticatedConnections.forEach((connectionId: string) => {
      const lastSeen = this.connectionLastSeenMs.get(connectionId) ?? now;
      if (now - lastSeen > MEMBER_HEARTBEAT_TIMEOUT_MS) {
        staleIds.push(connectionId);
      }
    });
    if (staleIds.length === 0) {
      return;
    }
    const connections = this.server.getConnections();
    for (let i = 0; i < staleIds.length; i++) {
      const connectionId = staleIds[i];
      this.connectionMembers.delete(connectionId);
      this.authenticatedConnections.delete(connectionId);
      this.connectionLastSeenMs.delete(connectionId);
      this.releaseTransportPreparationConnection(connectionId);
      for (let j = 0; j < connections.length; j++) {
        if (connections[j].id === connectionId) {
          this.server.removeConnection(connectionId);
          void connections[j].close();
          break;
        }
      }
    }
    void this.broadcastSnapshot();
  }

  private async runLightResync(): Promise<void> {
    if (this.isLeader || !this.isMemberTransportConnected()) {
      return;
    }
    try {
      const sample = await this.measureClockSync(5);
      const delta = Math.abs(sample.offsetMs - this.clockSync.getOffsetMs());
      if (delta > 3) {
        this.clockSync.smoothAdjust(sample.offsetMs);
      } else {
        this.clockSync.applySample(sample);
      }
      this.consecutiveResyncFailures = 0;
      this.scheduleRandomAvatarReveals();
      this.notifyUi();
    } catch (_e) {
      this.consecutiveResyncFailures += 1;
      if (this.consecutiveResyncFailures >= MEMBER_RESYNC_FAILURE_LIMIT &&
        this.remoteSessionEndReason === undefined) {
        // A TCP socket can remain locally "connected" after Wi-Fi P2P vanished.
        // Repeated unanswered application pings are the authoritative fallback.
        this.remoteSessionEndReason = 'connection_lost';
        this.applyRemoteSessionEnd();
      }
    }
  }

  private schedulePauseState(payload: TransportPausePayload): void {
    this.cancelScheduledPauseState();
    const offsetMs = this.isLeader ? 0 : this.clockSync.getOffsetMs();
    const localPauseAt = payload.pauseAtLeaderMonoMs - offsetMs;
    this.transportPauseTimer = setTimeout(() => {
      this.transportPauseTimer = -1;
      this.state = 'paused';
      this.notifyUi();
      if (this.isLeader) {
        void this.broadcastSnapshot();
      }
    }, Math.max(0, localPauseAt - MonotonicClock.nowMs()));
  }

  private cancelScheduledPauseState(): void {
    if (this.transportPauseTimer >= 0) {
      clearTimeout(this.transportPauseTimer);
      this.transportPauseTimer = -1;
    }
  }

  private notifyUi(): void {
    this.uiListener();
    AppStorage.setOrCreate('sessionEpoch', (AppStorage.get<number>('sessionEpoch') ?? 0) + 1);
  }

  private isMemberTransportConnected(): boolean {
    return this.client.isConnected();
  }

  private async sendToLeader(message: WireMessage): Promise<void> {
    await this.client.send(message);
  }

  private async sendToAll(message: WireMessage): Promise<void> {
    await this.server.sendToAll(message);
  }
}
