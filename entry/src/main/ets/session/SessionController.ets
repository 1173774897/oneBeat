import {
  COUNT_IN_BARS,
  MEMBER_HEARTBEAT_SWEEP_MS,
  MEMBER_HEARTBEAT_TIMEOUT_MS,
  RESYNC_INTERVAL_MS,
  SESSION_TCP_PORT,
  TRANSPORT_PREROLL_MS
} from '../common/Constants';
import { MonotonicClock } from '../common/MonotonicClock';
import { createMessage } from '../protocol/messages';
import {
  ClientHelloPayload,
  ClientLeavePayload,
  LobbyReadyPayload,
  PingPayload,
  PingResponse,
  PongPayload,
  SessionMember,
  SessionSnapshotPayload,
  TransportPausePayload,
  TransportPayload,
  TransportResumePayload,
  TransportState,
  WireMessage
} from '../protocol/messages';
import { SessionServer } from '../network/socket/SessionServer';
import { SessionClient } from '../network/socket/SessionClient';
import { SessionPeerConnection } from '../network/transport/SessionPeerConnection';
import { ClockSyncEstimator } from '../sync/ClockSync';
import {
  P2pRoomInvitation,
  randomAuthNonce,
  validateP2pRoomInvitation
} from '../network/p2p/P2pInvitation';
import { isAllowedAvatarKey } from '../assets/AssetCatalog';
import {
  defaultSessionAvatar,
  getExclusiveAvatarsLockedByReadyMembers,
  isAvatarAllowedForSession,
  isDuplicatableAvatar,
  isExclusiveTakenByOther,
  pickFallbackAvatar,
  rosterKeysForLobby
} from '../assets/CharacterCatalog';

export type SessionUiListener = () => void;

const SOLO_BOT_ID_PREFIX: string = 'solo-bot-';
const SOLO_BOT_DISPLAY_NAME: string = '人机';
const SOLO_DEFAULT_BOT_COUNT: number = 2;
export const SOLO_MAX_BOT_COUNT: number = 7;

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

  bpm: number = 120;
  beatsPerBar: number = 4;
  beatUnit: number = 4;
  rhythm: number = 0;
  drumProgram: string = '';
  avatarKey: string = defaultSessionAvatar();
  lobbyDeparted: boolean = false;
  localMemberId: string = '';
  soundId: number = 0;
  sceneKey: string = 'neon_street';
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
    this.sceneKey = this.normalizeSceneKey(AppStorage.get<string>('selectedSceneKey') ?? 'neon_street');
    if (isLeader) {
      this.connectionMembers.set('leader', {
        id: 'leader',
        displayName: displayName,
        avatarKey: this.avatarKey,
        colorSlot: -1,
        lobbyReady: false,
        rttMs: 0,
        offsetMs: 0
      });
    }
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
    let teamMemberCount: number = 0;
    for (let i = 0; i < members.length; i++) {
      if (members[i].id === 'leader') {
        continue;
      }
      teamMemberCount += 1;
      if (members[i].lobbyReady !== true) {
        return false;
      }
    }
    return teamMemberCount > 0;
  }

  canLeaderStartWalk(): boolean {
    return !this.soloTeam && this.isLeader && this.allTeamMembersLobbyReady();
  }

  private canAssignAvatarToMember(memberId: string, key: string): boolean {
    if (!isAvatarAllowedForSession(key, this.soloTeam)) {
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
        member.avatarKey = pickFallbackAvatar(this.getMembers(), id, this.soloTeam);
      }
    });
  }

  async updateMemberAvatar(memberId: string, key: string): Promise<void> {
    if (!this.canAssignAvatarToMember(memberId, key)) {
      return;
    }
    if (this.soloTeam && this.isLeader) {
      const member = this.connectionMembers.get(memberId);
      if (member !== undefined) {
        member.avatarKey = key;
        if (memberId === 'leader') {
          this.avatarKey = key;
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
    await this.updateAvatar(key);
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

  async departLobbyToWalk(): Promise<void> {
    if (!this.isLeader || this.soloTeam || !this.canLeaderStartWalk()) {
      return;
    }
    this.lobbyDeparted = true;
    await this.broadcastSnapshot();
  }

  async returnToLobby(): Promise<void> {
    if (!this.isLeader || (!this.soloTeam && !this.lobbyDeparted)) {
      return;
    }
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
      member.colorSlot = -1;
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
    return this.getAvailableAvatarsForNewSoloBot().length > 0;
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

  private listSoloBotAvatarKeysInOrder(): string[] {
    const keys: string[] = [];
    const ids = this.listSoloBotIdsSorted();
    for (let i = 0; i < ids.length; i++) {
      const member = this.connectionMembers.get(ids[i]);
      if (member !== undefined) {
        keys.push(member.avatarKey);
      }
    }
    return keys;
  }

  private applySoloBotsWithAvatars(avatarKeys: string[]): void {
    this.purgeSoloBotsAndLegacy();
    for (let i = 0; i < avatarKeys.length; i++) {
      const id = `${SOLO_BOT_ID_PREFIX}${i + 1}`;
      this.connectionMembers.set(id, {
        id: id,
        displayName: SOLO_BOT_DISPLAY_NAME,
        avatarKey: avatarKeys[i],
        colorSlot: -1,
        lobbyReady: false,
        rttMs: 0,
        offsetMs: 0
      });
    }
  }

  private defaultSoloBotAvatarsForLeader(): string[] {
    const picked: string[] = [];
    const synthetic: SessionMember[] = [{
      id: 'leader',
      displayName: '',
      avatarKey: this.avatarKey,
      colorSlot: -1,
      lobbyReady: false,
      rttMs: 0,
      offsetMs: 0
    }];
    const roster = rosterKeysForLobby(true);
    for (let i = 0; i < roster.length && picked.length < SOLO_DEFAULT_BOT_COUNT; i++) {
      const key = roster[i];
      if (!isAvatarAllowedForSession(key, true)) {
        continue;
      }
      if (isExclusiveTakenByOther(synthetic, key, '')) {
        continue;
      }
      picked.push(key);
      synthetic.push({
        id: `solo-bot-${picked.length}`,
        displayName: SOLO_BOT_DISPLAY_NAME,
        avatarKey: key,
        colorSlot: -1,
        lobbyReady: false,
        rttMs: 0,
        offsetMs: 0
      });
    }
    return picked;
  }

  private purgeSoloBotsAndLegacy(): void {
    const removeIds: string[] = [];
    this.connectionMembers.forEach((_member: SessionMember, id: string) => {
      if (SessionController.isSoloBotMemberId(id) || id === 'solo-partner' || id === 'solo-lilroll') {
        removeIds.push(id);
      }
    });
    for (let i = 0; i < removeIds.length; i++) {
      this.connectionMembers.delete(removeIds[i]);
    }
  }

  /** 单人模式：队长 + 可增减的人机队友 */
  ensureSoloWalkPair(leaderName: string): void {
    this.purgeSoloBotsAndLegacy();
    this.connectionMembers.set('leader', {
      id: 'leader',
      displayName: leaderName,
      avatarKey: this.avatarKey,
      colorSlot: -1,
      lobbyReady: false,
      rttMs: 0,
      offsetMs: 0
    });
    this.applySoloBotsWithAvatars(this.defaultSoloBotAvatarsForLeader());
    this.notifyUi();
  }

  async addSoloBotWithNextAvatar(): Promise<void> {
    if (!this.isLeader || !this.soloTeam) {
      return;
    }
    const available = this.getAvailableAvatarsForNewSoloBot();
    if (available.length === 0) {
      return;
    }
    const nextAvatars = this.listSoloBotAvatarKeysInOrder();
    nextAvatars.push(available[0]);
    this.applySoloBotsWithAvatars(nextAvatars);
    await this.broadcastSnapshot();
  }

  async removeSoloBotById(id: string): Promise<void> {
    if (!this.isLeader || !this.soloTeam || !SessionController.isSoloBotMemberId(id)) {
      return;
    }
    const nextAvatars: string[] = [];
    const ids = this.listSoloBotIdsSorted();
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] === id) {
        continue;
      }
      const member = this.connectionMembers.get(ids[i]);
      if (member !== undefined) {
        nextAvatars.push(member.avatarKey);
      }
    }
    this.applySoloBotsWithAvatars(nextAvatars);
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

  removeSoloPartner(): void {
    this.purgeSoloBotsAndLegacy();
    this.notifyUi();
  }

  /** 旧版 solo-partner / solo-lilroll 迁移为 solo-bot-* */
  reconcileSoloLegacyBots(): void {
    if (!this.soloTeam || !this.isLeader) {
      return;
    }
    if (!this.connectionMembers.has('solo-partner') && !this.connectionMembers.has('solo-lilroll')) {
      return;
    }
    const avatars: string[] = [];
    if (this.connectionMembers.has('solo-partner')) {
      const m = this.connectionMembers.get('solo-partner');
      if (m !== undefined) {
        avatars.push(m.avatarKey);
      }
    }
    if (this.connectionMembers.has('solo-lilroll')) {
      const m = this.connectionMembers.get('solo-lilroll');
      if (m !== undefined) {
        avatars.push(m.avatarKey);
      }
    }
    this.applySoloBotsWithAvatars(avatars.length > 0 ? avatars : this.defaultSoloBotAvatarsForLeader());
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
    validateP2pRoomInvitation(invitation);
    this.leaderHost = host;
    this.tcpPort = port;
    this.client.setHandler((message) => this.onMemberMessage(message));
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
    const sync = await ClockSyncEstimator.measureWithSender(async (id, clientMono) => {
      return await this.sendPing(id, clientMono);
    });
    this.clockSync.applySample(sync);
    this.startResyncLoop();
    this.notifyUi();
  }

  async disconnect(): Promise<void> {
    this.stopResyncLoop();
    if (this.isLeader) {
      this.stopHeartbeatSweep();
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

  async updateBpm(next: number): Promise<void> {
    if (!this.isLeader) { return; }
    this.bpm = Math.max(40, Math.min(240, next));
    await this.broadcastSnapshot();
  }

  async updateSoundId(next: number): Promise<void> {
    if (!this.isLeader) { return; }
    this.soundId = next % 3;
    await this.broadcastSnapshot();
  }

  async updateAvatar(key: string): Promise<void> {
    if (!isAllowedAvatarKey(key, this.soloTeam)) { return; }
    const memberId = this.getLocalMemberId();
    if (!this.soloTeam && memberId.length > 0 && !this.canAssignAvatarToMember(memberId, key)) {
      return;
    }
    if (this.isLocalLobbyReady()) {
      return;
    }
    this.avatarKey = key;
    if (this.isLeader) {
      const member = this.connectionMembers.get('leader');
      if (member !== undefined) {
        member.avatarKey = key;
        member.colorSlot = -1;
      }
      await this.broadcastSnapshot();
    } else {
      await this.sendToLeader(createMessage('MEMBER_UPDATE', {
        displayName: this.displayName, avatarKey: key
      } as ClientHelloPayload));
    }
  }

  async updateMeter(beats: number, unit: number): Promise<void> {
    if (!this.isLeader || !((beats === 4 && unit === 4) || (beats === 3 && unit === 4) || (beats === 6 && unit === 8))) { return; }
    this.beatsPerBar = beats;
    this.beatUnit = unit;
    await this.broadcastSnapshot();
  }

  async updateRhythm(rhythm: number): Promise<void> {
    if (!this.isLeader || rhythm < 0 || rhythm > 3) { return; }
    this.rhythm = rhythm;
    await this.broadcastSnapshot();
  }

  async updateDrumProgram(program: string): Promise<void> {
    if (!this.isLeader || program.length === 0) { return; }
    this.drumProgram = program;
    this.rhythm = 3;
    await this.broadcastSnapshot();
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
    this.state = 'countdown';
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
    this.state = 'paused';
    const payload: TransportPausePayload = {
      pauseAtLeaderMonoMs: MonotonicClock.nowMs(),
      beatIndex: this.beatIndex
    };
    await this.sendToAll(createMessage('TRANSPORT_PAUSE', payload));
    await this.broadcastSnapshot();
  }

  async resumeTransport(): Promise<number> {
    if (!this.isLeader) {
      return 0;
    }
    this.state = 'countdown';
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
    const payload: SessionSnapshotPayload = {
      sessionId: this.sessionId,
      bpm: this.bpm,
      beatsPerBar: this.beatsPerBar,
      beatUnit: this.beatUnit,
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
    if (message.type === 'CLIENT_LEAVE') {
      const removed = this.connectionMembers.delete(connection.id);
      this.authenticatedConnections.delete(connection.id);
      this.connectionLastSeenMs.delete(connection.id);
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
      if (this.canAssignAvatarToMember(connection.id, update.avatarKey)) {
        member.avatarKey = update.avatarKey;
        member.colorSlot = -1;
        void this.broadcastSnapshot();
      }
      return;
    }
    if (message.type === 'LOBBY_READY') {
      const readyPayload = message.payload as LobbyReadyPayload;
      const member = this.connectionMembers.get(connection.id);
      if (member === undefined) {
        return;
      }
      if (readyPayload.ready && !this.canAssignAvatarToMember(connection.id, member.avatarKey)) {
        return;
      }
      member.lobbyReady = readyPayload.ready;
      if (readyPayload.ready) {
        this.resolveExclusiveConflictsAfterLock(connection.id);
      }
      void this.broadcastSnapshot();
      return;
    }
    if (message.type === 'CLIENT_HELLO') {
      const hello = message.payload as ClientHelloPayload;
      if (!this.soloTeam && !this.isValidRoomHello(hello)) {
        console.warn(`Rejected unauthenticated session client: ${connection.id}`);
        void connection.close();
        return;
      }
      if (hello.nonce !== undefined) {
        this.usedAuthNonces.add(hello.nonce);
      }
      this.authenticatedConnections.add(connection.id);
      const member: SessionMember = {
        id: connection.id,
        displayName: hello.displayName,
        avatarKey: isAllowedAvatarKey(hello.avatarKey, this.soloTeam) ? hello.avatarKey : defaultSessionAvatar(),
        colorSlot: -1,
        lobbyReady: false,
        rttMs: 0,
        offsetMs: 0
      };
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
    if (message.type === 'TRANSPORT') {
      this.state = 'countdown';
      AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(message));
      this.notifyUi();
      return;
    }
    if (message.type === 'TRANSPORT_PAUSE') {
      this.state = 'paused';
      AppStorage.setOrCreate('lastTransportMessage', JSON.stringify(message));
      this.notifyUi();
      return;
    }
    if (message.type === 'TRANSPORT_RESUME') {
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

  private applySnapshot(snapshot: SessionSnapshotPayload): void {
    this.bpm = snapshot.bpm;
    this.beatsPerBar = snapshot.beatsPerBar;
    this.beatUnit = snapshot.beatUnit ?? 4;
    this.rhythm = snapshot.rhythm ?? 0;
    this.drumProgram = snapshot.drumProgram ?? '';
    this.sceneKey = this.normalizeSceneKey(snapshot.sceneKey ?? 'neon_street');
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
    this.notifyUi();
  }

  private normalizeSceneKey(key: string): string {
    return key === 'sunset_coast' ? 'sunset_coast' : 'neon_street';
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
    if (!this.isLeader) {
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
      const sample = await ClockSyncEstimator.measureWithSender(async (id, clientMono) => {
        return await this.sendPing(id, clientMono);
      }, 3);
      const delta = Math.abs(sample.offsetMs - this.clockSync.getOffsetMs());
      if (delta > 3) {
        this.clockSync.smoothAdjust(sample.offsetMs);
      } else {
        this.clockSync.applySample(sample);
      }
      this.notifyUi();
    } catch (_e) {
      // ignore transient resync errors
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
