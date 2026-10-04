import { SessionController } from '../session/SessionController';
import { MetronomeEngine } from '../audio/MetronomeEngine';
import { WifiP2pManager } from '../network/p2p/WifiP2pManager';
import { BleRoomDiscovery } from '../network/p2p/BleRoomDiscovery';
import {
  createP2pRoomInvitation,
  invitationWithGroupCredentials,
  P2pRoomInvitation
} from '../network/p2p/P2pInvitation';
import { PROTOCOL_VERSION } from '../common/Constants';
import { MonotonicClock } from '../common/MonotonicClock';
import { SessionBackgroundKeeper } from '../session/SessionBackgroundKeeper';
import {
  TransportPausePayload,
  TransportPayload,
  TransportResumePayload,
  WireMessage
} from '../protocol/messages';
export class AppSession {
  private static instance: AppSession | undefined = undefined;
  readonly controller: SessionController;
  readonly metronome: MetronomeEngine = new MetronomeEngine();
  readonly p2p: WifiP2pManager = new WifiP2pManager();
  readonly bleDiscovery: BleRoomDiscovery = new BleRoomDiscovery();
  private lastTransportKey: string = '';
  private drumPreviewToken: number = 0;
  private countInStartBeatIndex: number = -1;
  private countInEndBeatIndex: number = -1;

  private constructor(controller: SessionController) {
    AppStorage.setOrCreate('lastTransportMessage', '');
    this.controller = controller;
    this.controller.setUiListener(() => {
      this.syncEngineFromSession();
      this.handleTransportFromStorage();
      if (!this.controller.lobbyDeparted && this.controller.state === 'idle') {
        this.clearCountIn();
        this.metronome.pause();
      }
    });
    this.metronome.setBeatCallback((beatIndex, beatInBar, scheduledAtMonoMs) => {
      let visibleBeatInBar = beatInBar;
      if (this.countInEndBeatIndex >= 0 && beatIndex < this.countInEndBeatIndex) {
        visibleBeatInBar = beatIndex - this.countInStartBeatIndex + 1;
      } else if (this.countInEndBeatIndex >= 0) {
        this.clearCountIn();
        this.controller.completeCountIn(beatIndex);
      }
      // Beat pulses have their own lightweight storage signal. Avoid running the
      // full session listener (and rebuilding audio configuration) every beat.
      this.controller.setBeatIndex(beatIndex, false);
      AppStorage.setOrCreate('currentBeatIndex', beatIndex);
      AppStorage.setOrCreate('currentBeatInBar', visibleBeatInBar);
      AppStorage.setOrCreate('beatStartedAtMs', scheduledAtMonoMs);
      AppStorage.setOrCreate('beatEpoch', (AppStorage.get<number>('beatEpoch') ?? 0) + 1);
    });
  }

  static get(): AppSession | undefined {
    return AppSession.instance;
  }

  static createLeader(displayName: string): AppSession {
    const id = `sess-${Date.now()}`;
    const session = new AppSession(new SessionController(id, true, displayName));
    AppSession.instance = session;
    return session;
  }

  static createMember(displayName: string): AppSession {
    const id = `sess-member-${Date.now()}`;
    const session = new AppSession(new SessionController(id, false, displayName));
    AppSession.instance = session;
    return session;
  }

  static clear(): void {
    void AppSession.instance?.shutdown();
    AppSession.instance = undefined;
  }

  static async reset(): Promise<void> {
    const previous = AppSession.instance;
    AppSession.instance = undefined;
    if (previous !== undefined) { await previous.shutdown(); }
    AppStorage.setOrCreate('lastTransportMessage', '');
  }

  async shutdown(): Promise<void> {
    try {
      this.metronome.pause();
      await this.metronome.stopEngine();
      await this.bleDiscovery.stopLeaderAdvertising();
      await this.controller.disconnect();
      await this.p2p.teardown();
    } finally {
      await SessionBackgroundKeeper.stop();
    }
  }

  syncEngineFromSession(): void {
    this.metronome.setBpm(this.controller.bpm, this.controller.beatsPerBar);
    this.metronome.setOffsetMs(this.controller.getOffsetMs());
    if (this.controller.rhythm === 3 && this.controller.drumProgram.length > 0) {
      void this.metronome.configureProgram(this.controller.drumProgram);
    } else {
      this.metronome.configure(this.controller.rhythm, this.controller.soundId);
    }
  }

  async previewDrumProgram(
    program: string,
    looping: boolean = true,
    previewBpm?: number,
    previewBeatsPerBar?: number
  ): Promise<void> {
    const token = ++this.drumPreviewToken;
    this.metronome.pause();
    const bpm = previewBpm ?? this.controller.bpm;
    const beatsPerBar = previewBeatsPerBar ?? this.controller.beatsPerBar;
    this.metronome.setBpm(bpm, beatsPerBar);
    await this.metronome.configureProgram(program, looping);
    if (token !== this.drumPreviewToken) {
      return;
    }
    await this.metronome.scheduleFromLeaderStart(MonotonicClock.nowMs() + 350, 0);
  }

  stopDrumPreview(): void {
    this.drumPreviewToken++;
    if (this.controller.state === 'idle' || this.controller.state === 'paused') {
      this.metronome.pause();
    }
  }

  async leaderBootstrap(displayName: string): Promise<string> {
    this.controller.soloTeam = false;
    this.controller.displayName = displayName;
    const draft = createP2pRoomInvitation();
    const group = await this.p2p.createLeaderGroup(draft);
    const invitation = invitationWithGroupCredentials(
      draft,
      group.groupName.length > 0 ? group.groupName : draft.groupName,
      group.passphrase.length >= 8 ? group.passphrase : draft.passphrase,
      group.ownerInfo.deviceName
    );
    this.controller.configureP2pRoom(invitation);
    await this.controller.startLeader(group.goIpAddress);
    try {
      await this.bleDiscovery.startLeaderAdvertising(invitation);
      this.controller.bleInviteAvailable = true;
    } catch (err) {
      this.controller.bleInviteAvailable = false;
      console.warn(`BLE room advertising unavailable: ${(err as Error).message}`);
    }
    this.syncEngineFromSession();
    await SessionBackgroundKeeper.start();
    return group.goIpAddress;
  }

  /** 从编辑页返回大厅或系统重建网络后，确认临时 P2P 组仍然可用。 */
  async refreshLeaderP2pGroup(): Promise<void> {
    if (!this.controller.isLeader || this.controller.soloTeam) {
      return;
    }
    const invitation = this.controller.getP2pInvitation();
    if (invitation === undefined) {
      return;
    }
    if (!(await this.p2p.isLeaderGroupReady(invitation))) {
      const group = await this.p2p.createLeaderGroup(invitation);
      this.controller.leaderHost = group.goIpAddress;
    }
    if (this.bleDiscovery.isBluetoothEnabled()) {
      await this.bleDiscovery.startLeaderAdvertising(invitation);
      this.controller.bleInviteAvailable = true;
    } else {
      await this.bleDiscovery.stopLeaderAdvertising();
      this.controller.bleInviteAvailable = false;
    }
    this.syncEngineFromSession();
  }

  /** 队长单人队伍：本机节拍 + 走路场景，可选稍后再开 P2P 供队员加入 */
  async leaderBootstrapSolo(displayName: string): Promise<void> {
    this.controller.soloTeam = true;
    this.controller.displayName = displayName;
    this.controller.ensureSoloWalkPair(displayName);
    try {
      await this.controller.startLeader('127.0.0.1');
      this.controller.leaderHost = '127.0.0.1';
    } catch (err) {
      console.warn(`Solo TCP listen skipped: ${(err as Error).message}`);
      this.controller.leaderHost = '';
    }
    this.syncEngineFromSession();
    await SessionBackgroundKeeper.start();
  }

  async upgradeSoloToP2p(displayName: string): Promise<string> {
    if (!this.controller.isLeader || !this.controller.soloTeam) {
      return this.controller.leaderHost;
    }
    this.controller.soloTeam = false;
    this.controller.removeSoloBots();
    return await this.leaderBootstrap(displayName);
  }

  async memberJoinWithInvitation(invitation: P2pRoomInvitation): Promise<void> {
    const joinFeedback = await this.bleDiscovery.startMemberJoinFeedback(invitation);
    try {
      const goIp = await this.p2p.connectToLeader(invitation, joinFeedback?.rejection);
      await this.controller.connectMember(goIp, invitation.port, invitation);
      this.syncEngineFromSession();
      this.handleTransportFromStorage();
      await SessionBackgroundKeeper.start();
    } catch (err) {
      const joinError = err as Error;
      await this.p2p.abortMemberJoin();
      throw joinError;
    } finally {
      if (joinFeedback !== undefined) {
        await joinFeedback.close();
      }
    }
  }

  async memberJoinByCode(code: string, onRoomFound?: () => void): Promise<void> {
    const trimmed = code.trim();
    const invitation = await this.bleDiscovery.resolveInvitationByCode(trimmed, PROTOCOL_VERSION);
    if (onRoomFound) {
      onRoomFound();
    }
    await this.memberJoinWithInvitation(invitation);
  }

  async leaderStart(): Promise<void> {
    await this.controller.startTransport();
  }

  async leaderPause(): Promise<void> {
    this.clearCountIn();
    await this.controller.pauseTransport();
    this.metronome.pause();
  }

  async leaderReturnToLobby(): Promise<void> {
    this.clearCountIn();
    this.metronome.pause();
    await this.controller.returnToLobby();
  }

  async leaderResume(): Promise<void> {
    await this.controller.resumeTransport();
  }

  private handleTransportFromStorage(): void {
    const raw = AppStorage.get<string>('lastTransportMessage') ?? '';
    if (raw.length === 0 || raw === this.lastTransportKey) {
      return;
    }
    this.lastTransportKey = raw;
    try {
      const message = JSON.parse(raw) as WireMessage;
      this.applyTransportMessage(message);
    } catch (_e) {
      // ignore
    }
  }

  private applyTransportMessage(message: WireMessage): void {
    this.syncEngineFromSession();
    if (message.type === 'TRANSPORT') {
      const payload = message.payload as TransportPayload;
      const countInBeats = payload.countInBeats ?? this.controller.beatsPerBar;
      this.beginCountIn(payload.beatIndex, countInBeats);
      void this.metronome.scheduleFromLeaderStart(payload.startAtLeaderMonoMs, payload.beatIndex, countInBeats);
      return;
    }
    if (message.type === 'TRANSPORT_PAUSE') {
      this.clearCountIn();
      this.metronome.pause();
      return;
    }
    if (message.type === 'TRANSPORT_RESUME') {
      const payload = message.payload as TransportResumePayload;
      const countInBeats = payload.countInBeats ?? this.controller.beatsPerBar;
      this.beginCountIn(payload.beatIndex, countInBeats);
      void this.metronome.scheduleFromLeaderStart(payload.resumeAtLeaderMonoMs, payload.beatIndex, countInBeats);
    }
  }

  private beginCountIn(startBeatIndex: number, countInBeats: number): void {
    this.countInStartBeatIndex = startBeatIndex;
    this.countInEndBeatIndex = startBeatIndex + Math.max(0, countInBeats);
    AppStorage.setOrCreate('currentBeatInBar', 0);
  }

  private clearCountIn(): void {
    this.countInStartBeatIndex = -1;
    this.countInEndBeatIndex = -1;
  }

  private syncEngineFromStorage(): void {
    this.handleTransportFromStorage();
  }
}
