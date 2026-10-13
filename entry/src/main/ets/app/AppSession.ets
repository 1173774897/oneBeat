import { SessionController } from '../session/SessionController';
import { CalibrationSignalTiming, MetronomeEngine } from '../audio/MetronomeEngine';
import { AudioOutputMonitor } from '../audio/AudioOutputMonitor';
import { WifiP2pManager } from '../network/p2p/WifiP2pManager';
import { BleRoomDiscovery } from '../network/p2p/BleRoomDiscovery';
import {
  createP2pRoomInvitation,
  invitationWithGroupCredentials,
  P2pRoomInvitation
} from '../network/p2p/P2pInvitation';
import { PROTOCOL_VERSION } from '../common/Constants';
import { MonotonicClock } from '../common/MonotonicClock';
import { defaultBeatPointStates } from '../common/MeterModel';
import { SessionBackgroundKeeper } from '../session/SessionBackgroundKeeper';
import { promptAction, router } from '@kit.ArkUI';
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
  private latencyCalibrationActive: boolean = false;
  private latencyRouteProbeToken: number = 0;
  private teamJoinedForWarmup: boolean = false;
  // Once calibration is saved or walking starts, the physical stream belongs
  // to the team session. Lobby/walk transitions must keep it running so the
  // Bluetooth buffer and renderer frame clock survive until session shutdown.
  private keepRendererAliveForSession: boolean = false;
  private bluetoothRouteStateInitialized: boolean = false;
  private previousBluetoothAudioActive: boolean = false;
  private previousAudioOutputRouteSignature: string = '';
  private handlingRemoteDisband: boolean = false;

  private constructor(controller: SessionController) {
    AppStorage.setOrCreate('lastTransportMessage', '');
    AppStorage.setOrCreate('btAudioActive', false);
    AppStorage.setOrCreate('btCalibrationTracksConnection', false);
    AppStorage.setOrCreate('btCalibrationNeedsRemeasure', false);
    AppStorage.setOrCreate('audioOutputRouteEpoch', 0);
    AudioOutputMonitor.start((active: boolean, routeSignature: string) => {
      const routeChanged = this.bluetoothRouteStateInitialized &&
        this.previousAudioOutputRouteSignature !== routeSignature;
      const tracksConnection = AppStorage.get<boolean>('btCalibrationTracksConnection') ?? false;
      if (this.bluetoothRouteStateInitialized && this.previousBluetoothAudioActive && !active &&
        tracksConnection) {
        // Reconnection creates a new wireless buffering state. Keep this sticky
        // until another measurement is saved, even if the headset reconnects.
        AppStorage.setOrCreate('btCalibrationNeedsRemeasure', true);
      }
      this.previousBluetoothAudioActive = active;
      this.previousAudioOutputRouteSignature = routeSignature;
      this.bluetoothRouteStateInitialized = true;
      if (routeChanged) {
        const routeEpoch = AppStorage.get<number>('audioOutputRouteEpoch') ?? 0;
        AppStorage.setOrCreate('audioOutputRouteEpoch', routeEpoch + 1);
      }
      AppStorage.setOrCreate('btAudioActive', active);
      // The same renderer can survive a route switch, so immediately drop or
      // restore the Bluetooth-only manual compensation for the new route.
      this.metronome.refreshOutputCalibration(routeChanged);
      if (active) {
        void this.maybeWarmUpRendererForPlayback();
      }
    });
    this.controller = controller;
    SessionBackgroundKeeper.setControlHandler({
      onPlay: () => {
        if (!this.controller.isLeader) {
          return;
        }
        if (this.controller.state === 'idle') {
          void this.leaderStart();
        } else if (this.controller.state === 'paused') {
          void this.leaderResume();
        }
      },
      onPause: () => {
        if (!this.controller.isLeader) {
          return;
        }
        void this.leaderPause();
      }
    });
    this.controller.setUiListener(() => {
      if (this.controller.getRemoteSessionEndReason() !== undefined) {
        void this.handleRemoteDisband();
        return;
      }
      if (!this.latencyCalibrationActive) {
        this.syncEngineFromSession();
        this.handleTransportFromStorage();
      }
      const playing = this.controller.state === 'playing' || this.controller.state === 'countdown';
      void SessionBackgroundKeeper.updatePlaybackState(playing);
      if (!this.latencyCalibrationActive && !this.keepRendererAliveForSession &&
        !this.controller.lobbyDeparted && this.controller.state === 'idle') {
        this.clearCountIn();
        void this.metronome.suspendRenderer();
      }
    });
    this.metronome.setBeatCallback((beatIndex, beatInBar, scheduledAtMonoMs) => {
      if (this.latencyCalibrationActive) {
        return;
      }
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

  static handleAppForeground(): void {
    AppSession.instance?.controller.handleAppForeground();
  }

  static handleAppBackground(): void {
    AppSession.instance?.controller.handleAppBackground();
  }

  async shutdown(): Promise<void> {
    this.latencyCalibrationActive = false;
    this.keepRendererAliveForSession = false;
    this.teamJoinedForWarmup = false;
    try {
      // Disband the room before fallible audio/BLE cleanup so a local teardown
      // error cannot leave followers displaying a leader that has already gone.
      await this.controller.disconnect();
      await this.metronome.stopEngine();
      await this.bleDiscovery.stopLeaderAdvertising();
      await this.p2p.teardown();
    } finally {
      AudioOutputMonitor.stop();
      await SessionBackgroundKeeper.stop();
    }
  }

  private async handleRemoteDisband(): Promise<void> {
    if (this.handlingRemoteDisband) {
      return;
    }
    this.handlingRemoteDisband = true;
    if (AppSession.instance === this) {
      AppSession.instance = undefined;
    }
    try {
      await this.shutdown();
    } catch (err) {
      console.warn(`Remote disband cleanup incomplete: ${(err as Error).message}`);
    }
    AppStorage.setOrCreate('lastTransportMessage', '');
    router.clear();
    try {
      await router.replaceUrl({ url: 'pages/TeamPage' });
    } catch (err) {
      console.warn(`Remote disband navigation failed: ${(err as Error).message}`);
    }
    const reason = this.controller.getRemoteSessionEndReason();
    promptAction.showToast({
      message: reason === 'leader_exit' ? '队长已退出，队伍已解散' :
        '与队长的连接已断开，已退出队伍'
    });
  }

  syncEngineFromSession(): void {
    if (this.latencyCalibrationActive) {
      return;
    }
    this.metronome.setBpm(this.controller.bpm, this.controller.beatsPerBar);
    this.metronome.setBeatPointStates(this.controller.beatPointStates);
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
    if (this.controller.state === 'idle') {
      if (this.keepRendererAliveForSession) {
        this.metronome.pause();
      } else {
        void this.metronome.suspendRenderer();
      }
    } else if (this.controller.state === 'paused') {
      this.metronome.pause();
    }
  }

  /**
   * Start the fixed 120 BPM tap test without platform output compensation. The
   * measured tap delta must include the complete route, including the unknown
   * Bluetooth buffer, rather than only the residual after getLatency().
   */
  async scheduleLatencyTapMeasurement(startAtLocalMonoMs: number, countInBeats: number): Promise<void> {
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('当前声音没有通过蓝牙耳机输出');
    }
    this.latencyRouteProbeToken++;
    this.latencyCalibrationActive = true;
    this.metronome.setOffsetMs(this.controller.getOffsetMs());
    this.metronome.setBpm(120, 4);
    this.metronome.setBeatPointStates(defaultBeatPointStates(4));
    this.metronome.configure(0, 0);
    const audioStartLeaderMonoMs = startAtLocalMonoMs + this.controller.getOffsetMs();
    // Keep the rehearsal bar on the renderer timeline so Bluetooth latency shifts
    // the count-in and measured bars together without changing their spacing.
    await this.metronome.scheduleFromLeaderStart(audioStartLeaderMonoMs, 0, countInBeats, 0);
  }

  /**
   * Play the microphone-loopback chirp through the persistent walking renderer.
   * The returned time is the signal frame's presentation target. Keeping this
   * renderer alive after save preserves the measured physical A2DP route.
   */
  async scheduleMicLoopbackSignal(signal: Int16Array,
    targetAtLocalMonoMs: number): Promise<CalibrationSignalTiming> {
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('当前声音没有通过蓝牙耳机输出');
    }
    this.latencyRouteProbeToken++;
    this.latencyCalibrationActive = true;
    return await this.metronome.scheduleCalibrationSignal(signal, targetAtLocalMonoMs);
  }

  /** Play the input-reference chirp through the phone speaker on the same frame clock. */
  async scheduleMicInputReferenceSignal(signal: Int16Array,
    targetAtLocalMonoMs: number): Promise<CalibrationSignalTiming> {
    if (!AudioOutputMonitor.isBuiltInSpeakerActive()) {
      throw new Error('输入侧校准需要把媒体输出切到手机扬声器');
    }
    this.latencyRouteProbeToken++;
    this.latencyCalibrationActive = true;
    return await this.metronome.scheduleCalibrationSignal(signal, targetAtLocalMonoMs);
  }

  /**
   * Run the same 120 BPM click against a visual reference for result-page A/B
   * listening. The explicit override lets the preview compare raw output with
   * the freshly measured app-to-ear compensation without saving it first.
   */
  async scheduleLatencyPreview(startAtLocalMonoMs: number, compensationMs: number): Promise<void> {
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('当前声音没有通过蓝牙耳机输出');
    }
    this.latencyCalibrationActive = true;
    this.metronome.setOffsetMs(this.controller.getOffsetMs());
    this.metronome.setBpm(120, 4);
    this.metronome.setBeatPointStates(defaultBeatPointStates(4));
    this.metronome.configure(0, 0);
    const audioStartLeaderMonoMs = startAtLocalMonoMs + this.controller.getOffsetMs();
    await this.metronome.scheduleFromLeaderStart(audioStartLeaderMonoMs, 0, 0,
      Math.max(0, compensationMs));
  }

  /** Play a finite “accent + weak” pair so the user can confirm the physical route. */
  async playBluetoothRouteProbe(): Promise<boolean> {
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('未检测到蓝牙耳机输出');
    }
    const probeToken = ++this.latencyRouteProbeToken;
    this.latencyCalibrationActive = true;
    // Establish the renderer before choosing the first-beat deadline. Otherwise
    // a cold renderer can make scheduleFromLeaderStart skip the initial accent.
    await this.metronome.ensureRenderer();
    if (probeToken !== this.latencyRouteProbeToken) {
      return false;
    }
    const audibleAtMs = MonotonicClock.nowMs() + 900;
    this.metronome.setOffsetMs(this.controller.getOffsetMs());
    this.metronome.configureRouteProbeClickPair();
    const audioStartLeaderMonoMs = audibleAtMs + this.controller.getOffsetMs();
    await this.metronome.scheduleFromLeaderStart(audioStartLeaderMonoMs, 0, 0, 0);
    // At 120 BPM the second click starts at +500 ms; keep the one-shot alive
    // through its full two-beat render before revealing the route choices.
    const stopDelayMs = Math.max(0, audibleAtMs + 1050 - MonotonicClock.nowMs());
    await new Promise<void>((resolve) => {
      setTimeout(() => resolve(), stopDelayMs);
    });
    if (probeToken !== this.latencyRouteProbeToken) {
      return false;
    }
    this.pauseLatencyCalibration();
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('试音期间蓝牙耳机已断开');
    }
    return true;
  }

  async stopLatencyCalibration(): Promise<void> {
    this.latencyRouteProbeToken++;
    if (!this.latencyCalibrationActive) {
      return;
    }
    this.latencyCalibrationActive = false;
    if (this.keepRendererAliveForSession) {
      this.metronome.pause();
    } else {
      await this.metronome.suspendRenderer();
    }
    this.syncEngineFromSession();
  }

  /** Preserve the exact physical output stream that produced the saved result. */
  keepLatencyCalibrationRendererAlive(): void {
    if (!this.latencyCalibrationActive) {
      return;
    }
    this.keepRendererAliveForSession = true;
    this.metronome.pause();
  }

  /** Bind the new result to the currently connected Bluetooth route. */
  markLatencyCalibrationRoute(isBluetooth: boolean): void {
    AppStorage.setOrCreate('btCalibrationTracksConnection', isBluetooth);
    AppStorage.setOrCreate('btCalibrationNeedsRemeasure', false);
    if (isBluetooth) {
      this.previousBluetoothAudioActive = true;
      this.bluetoothRouteStateInitialized = true;
    }
  }

  /** Stop click content after a run while retaining the warmed renderer for retry. */
  pauseLatencyCalibration(): void {
    if (this.latencyCalibrationActive) {
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
    await SessionBackgroundKeeper.start(true); // 队长：显示媒体卡片
    this.teamJoinedForWarmup = true;
    void this.maybeWarmUpRendererForPlayback();
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
      if (this.controller.hasConnectedFollowers()) {
        // System P2P queries can briefly report DISCONNECTED while an ability is
        // returning to foreground. Recreating the group here would evict every
        // follower without a reconnect protocol and split the two rosters.
        console.warn('Leader P2P readiness is transiently unavailable; preserving the active team');
      } else {
        const group = await this.p2p.createLeaderGroup(invitation);
        this.controller.leaderHost = group.goIpAddress;
      }
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
    await SessionBackgroundKeeper.start(true); // 单机：显示媒体卡片
    this.teamJoinedForWarmup = true;
    void this.maybeWarmUpRendererForPlayback();
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
    // BLE 反馈通道只负责把队长的“拒绝”信号快速传回队员，属于尽力而为；
    // 若在 P2P 连接前串行等待，会明显拖慢队长确认弹窗的出现。
    // 这里并行发起 P2P 连接，同时后台建立 BLE 反馈通道。
    const feedbackPromise = this.bleDiscovery.startMemberJoinFeedback(invitation)
      .catch(() => undefined);
    const rejectionSignal: Promise<Error> = feedbackPromise.then((channel) => {
      if (channel !== undefined) {
        return channel.rejection;
      }
      // 未建立 BLE 拒绝通道时保持 pending，由系统 P2P 确认弹窗超时兜底
      return new Promise<Error>(() => {});
    });
    try {
      const goIp = await this.p2p.connectToLeader(invitation, rejectionSignal);
      await this.controller.connectMember(goIp, invitation.port, invitation);
      this.syncEngineFromSession();
      try {
        // Members prepare their renderer while still in the lobby; otherwise a
        // slow first allocation can make only that device miss the shared start.
        await this.metronome.ensureRenderer();
      } catch (err) {
        console.warn(`MetronomeEngine member prewarm failed: ${(err as Error).message}`);
      }
      this.handleTransportFromStorage();
      await SessionBackgroundKeeper.start(false); // 队员：隐藏媒体卡片
      this.teamJoinedForWarmup = true;
      void this.maybeWarmUpRendererForPlayback();
    } catch (err) {
      const joinError = err as Error;
      await this.p2p.abortMemberJoin();
      throw joinError;
    } finally {
      const channel = await feedbackPromise;
      if (channel !== undefined) {
        await channel.close();
      }
    }
  }

  async memberJoinByCode(code: string, onRoomFound?: () => void): Promise<void> {
    const trimmed = code.trim();
    // 预热 P2P 设备发现，与 BLE 扫描并行，避免连接阶段冷启动等待
    const discoveryWarmup = this.p2p.prepareMemberDiscovery().catch(() => {});
    const invitation = await this.bleDiscovery.resolveInvitationByCode(trimmed, PROTOCOL_VERSION);
    if (onRoomFound) {
      onRoomFound();
    }
    await discoveryWarmup;
    await this.memberJoinWithInvitation(invitation);
  }

  /**
   * 进入队伍且蓝牙已连后，提前启动持久 renderer 并让 dither 填满队列到稳态，
   * 让第一拍和后续校准直接复用已暖好的 renderer，跳过冷启动。
   */
  private async maybeWarmUpRendererForPlayback(): Promise<void> {
    if (!this.teamJoinedForWarmup) {
      return;
    }
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      return;
    }
    try {
      await this.metronome.warmUpRendererForPlayback();
    } catch (err) {
      console.warn(`[WarmUp] renderer warm-up failed: ${(err as Error).message}`);
    }
  }

  async leaderStart(): Promise<void> {
    try {
      // Create the stream before the leader publishes a shared deadline so
      // renderer allocation time cannot consume the synchronization window.
      await this.metronome.ensureRenderer();
    } catch (err) {
      console.warn(`MetronomeEngine prewarm failed: ${(err as Error).message}`);
    }
    await this.controller.startTransport();
    // Once walking has started, the physical stream belongs to this team
    // session and remains alive across every later walk/lobby transition.
    this.keepRendererAliveForSession = true;
  }

  async leaderPause(): Promise<void> {
    this.clearCountIn();
    await this.controller.pauseTransport();
  }

  async leaderReturnToLobby(): Promise<void> {
    this.clearCountIn();
    this.keepRendererAliveForSession = true;
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
      this.keepRendererAliveForSession = true;
      const payload = message.payload as TransportPayload;
      const countInBeats = payload.countInBeats ?? this.controller.beatsPerBar;
      this.beginCountIn(payload.beatIndex, countInBeats);
      void this.metronome.scheduleFromLeaderStart(payload.startAtLeaderMonoMs, payload.beatIndex, countInBeats);
      return;
    }
    if (message.type === 'TRANSPORT_PAUSE') {
      const payload = message.payload as TransportPausePayload;
      this.clearCountIn();
      this.metronome.schedulePauseFromLeader(payload.pauseAtLeaderMonoMs);
      return;
    }
    if (message.type === 'TRANSPORT_RESUME') {
      this.keepRendererAliveForSession = true;
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
