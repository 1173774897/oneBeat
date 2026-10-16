import { SessionController } from '../session/SessionController';
import {
  CalibrationPlaybackReference,
  CalibrationSignalTiming,
  MetronomeEngine,
  MicPlaybackClockPendingError
} from '../audio/MetronomeEngine';
import { AudioOutputMonitor } from '../audio/AudioOutputMonitor';
import { WifiP2pManager } from '../network/p2p/WifiP2pManager';
import { BleMemberJoinFeedbackAttempt, BleRoomDiscovery } from '../network/p2p/BleRoomDiscovery';
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

const MIC_PLAYBACK_REFERENCE_MAX_SPREAD_MS: number = 30;
const MIC_PLAYBACK_REFERENCE_RECOVERY_TIMEOUT_MS: number = 4000;
const MIC_PLAYBACK_REFERENCE_SAMPLE_INTERVAL_MS: number = 250;
// The retained mic renderer is fixed at 44.1kHz. A 500ms window outruns its
// 20ms frame quantum without making the calibration depend on UI rendering.
const MIC_PLAYBACK_REFERENCE_RATE_HZ: number = 44100;

/** Informational join stages; session readiness still requires authentication and clock sync. */
export type MemberJoinStage = 'connecting' | 'joining' | 'preparing';

export class AppSession {
  private static instance: AppSession | undefined = undefined;
  private static retiringSession: AppSession | undefined = undefined;
  private static resetOperation: Promise<void> | undefined = undefined;
  readonly controller: SessionController;
  readonly metronome: MetronomeEngine = new MetronomeEngine();
  readonly p2p: WifiP2pManager = new WifiP2pManager();
  readonly bleDiscovery: BleRoomDiscovery = new BleRoomDiscovery();
  private lastTransportKey: string = '';
  private drumPreviewToken: number = 0;
  // Local audition owns both preparation and playback. Roster/settings UI
  // notifications must not replace its kit with the team's normal click sound.
  private drumPreviewActive: boolean = false;
  private drumPreviewReady: boolean = false;
  private drumPreviewUpdateRevision: number = 0;
  private countInStartBeatIndex: number = -1;
  private countInEndBeatIndex: number = -1;
  private latencyCalibrationActive: boolean = false;
  // Tap tests and previews share the transport guard, but only active mic
  // probes may rebuild the renderer when the physical output route changes.
  private micCalibrationActive: boolean = false;
  private latencyRouteProbeToken: number = 0;
  private latencyRouteProbeOwner: number = -1;
  private teamJoinedForWarmup: boolean = false;
  private memberJoinFeedbackAttempt: BleMemberJoinFeedbackAttempt | undefined = undefined;
  private shutdownOperation: Promise<void> | undefined = undefined;
  // Once calibration is saved or walking starts, the physical stream belongs
  // to the team session. Lobby/walk transitions must keep it running so the
  // Bluetooth buffer and renderer frame clock survive until session shutdown.
  private keepRendererAliveForSession: boolean = false;
  private bluetoothRouteStateInitialized: boolean = false;
  private previousBluetoothAudioActive: boolean = false;
  private previousAudioOutputRouteSignature: string = '';
  private handlingRemoteDisband: boolean = false;
  private micPostCaptureDiagGeneration: number = 0;

  private constructor(controller: SessionController) {
    AppStorage.setOrCreate('lastTransportMessage', '');
    AppStorage.setOrCreate('btAudioActive', false);
    AppStorage.setOrCreate('btCalibrationTracksConnection', false);
    AppStorage.setOrCreate('btCalibrationNeedsRemeasure', false);
    AppStorage.setOrCreate('audioOutputRouteEpoch', 0);
    AudioOutputMonitor.start((active: boolean, routeSignature: string) => {
      const previousRouteSignature = this.previousAudioOutputRouteSignature;
      const routeChanged = this.bluetoothRouteStateInitialized &&
        previousRouteSignature !== routeSignature;
      const tracksConnection = AppStorage.get<boolean>('btCalibrationTracksConnection') ?? false;
      const routeProbeActive = this.latencyRouteProbeOwner >= 0;
      const productionRunning = !this.latencyCalibrationActive &&
        (controller.state === 'playing' || controller.state === 'countdown') && this.metronome.isRunning();
      if (routeProbeActive && (routeChanged || !active)) {
        // A different physical output invalidates this pair. Ordinary warmup
        // must not restart its stream and silently discard the second click.
        this.latencyRouteProbeToken++;
        this.metronome.pause();
      }
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
      const routeEpoch = AppStorage.get<number>('audioOutputRouteEpoch') ?? 0;
      const routeAction = routeProbeActive ? (routeChanged || !active ? 'probe-cancel' : 'probe-playing') :
        productionRunning ? (routeChanged ? 'playback-rephase' : 'playback-running') :
        routeChanged && this.micCalibrationActive
        ? 'calibration-boundary'
        : (active && !this.micCalibrationActive ? 'playback-warmup' : 'none');
      console.info(`[AudioRouteDiag] old=${previousRouteSignature || 'none'} new=${routeSignature} ` +
        `changed=${routeChanged} wireless=${active} calibrationActive=${this.latencyCalibrationActive} ` +
        `micCalibrationActive=${this.micCalibrationActive} ` +
        `routeEpoch=${routeEpoch} action=${routeAction}`);
      AppStorage.setOrCreate('btAudioActive', active);
      // The same renderer can survive a route switch, so immediately drop or
      // restore the Bluetooth-only manual compensation for the new route.
      this.metronome.refreshOutputCalibration(routeChanged);
      // Do not leave routeReset on a surviving renderer while mic calibration is
      // running; the next scheduleCalibrationSignal would flush-only and break
      // framePos alignment on Huawei builds.
      if (routeChanged && this.micCalibrationActive) {
        void this.flushMicCalibrationProbeBoundary();
      } else if (routeChanged && productionRunning) {
        // Route repair is local to this device. Do not publish a TRANSPORT or
        // change the leader's clock: all members keep the same beat timeline.
        void this.metronome.rescheduleForOutputRouteChange().catch((err: Error) => {
          console.warn(`[RouteRephaseDiag] stage=failed reason=${err.message}`);
          if (AppSession.instance === this &&
            AppStorage.get<number>('audioOutputRouteEpoch') === routeEpoch && this.metronome.isRunning()) {
            promptAction.showToast({ message: err.message });
          }
        });
      } else if (active && !this.micCalibrationActive && !routeProbeActive) {
        // Mic probes own renderer creation even for duplicate route callbacks.
        // Other playback keeps its normal warm-up behavior, including tap tests.
        if (!productionRunning) {
          void this.maybeWarmUpRendererForPlayback();
        }
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
      if (!this.latencyCalibrationActive && !this.drumPreviewActive && !this.keepRendererAliveForSession &&
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
    AppSession.assertPreviousSessionReleased();
    const id = `sess-${Date.now()}`;
    const session = new AppSession(new SessionController(id, true, displayName));
    AppSession.instance = session;
    return session;
  }

  static createMember(displayName: string): AppSession {
    AppSession.assertPreviousSessionReleased();
    const id = `sess-member-${Date.now()}`;
    const session = new AppSession(new SessionController(id, false, displayName));
    AppSession.instance = session;
    return session;
  }

  static clear(): void {
    void AppSession.reset().catch((err: Error) => {
      console.warn(`Session cleanup incomplete: ${err.message}`);
    });
  }

  static async reset(): Promise<void> {
    const pending = AppSession.resetOperation;
    if (pending !== undefined) {
      await pending;
      return;
    }
    const previous = AppSession.instance ?? AppSession.retiringSession;
    AppSession.instance = undefined;
    // Losing the old instance before removeGroup actually finishes also loses
    // the proof that this is our group. Retain it after failure for a safe retry.
    AppSession.retiringSession = previous;
    const operation = AppSession.releasePreviousSession(previous);
    AppSession.resetOperation = operation;
    try {
      await operation;
    } finally {
      if (AppSession.resetOperation === operation) {
        AppSession.resetOperation = undefined;
      }
    }
  }

  private static async releasePreviousSession(previous?: AppSession): Promise<void> {
    if (previous !== undefined) {
      await previous.shutdown();
    }
    if (AppSession.retiringSession === previous) {
      AppSession.retiringSession = undefined;
    }
    AppStorage.setOrCreate('lastTransportMessage', '');
  }

  /** Wait only for old-session cleanup, without delaying join on discovery prewarm. */
  static async prepareMember(displayName: string): Promise<AppSession> {
    while (AppSession.resetOperation !== undefined) {
      await AppSession.resetOperation;
    }
    if (AppSession.retiringSession !== undefined) {
      await AppSession.reset();
    }
    return AppSession.instance ?? AppSession.createMember(displayName);
  }

  private static assertPreviousSessionReleased(): void {
    if (AppSession.resetOperation !== undefined || AppSession.retiringSession !== undefined) {
      throw new Error('上次队伍连接尚未释放，请稍后重试');
    }
  }

  static handleAppForeground(): void {
    AppSession.instance?.controller.handleAppForeground();
  }

  static handleAppBackground(): void {
    AppSession.instance?.controller.handleAppBackground();
  }

  async shutdown(): Promise<void> {
    if (this.shutdownOperation !== undefined) {
      await this.shutdownOperation;
      return;
    }
    const operation = this.shutdownExclusive();
    this.shutdownOperation = operation;
    let completed = false;
    try {
      await operation;
      completed = true;
    } finally {
      // A retired session can still receive a late socket callback. Successful
      // shutdown remains idempotent so it cannot stop the new global monitors.
      if (!completed && this.shutdownOperation === operation) {
        this.shutdownOperation = undefined;
      }
    }
  }

  private async shutdownExclusive(): Promise<void> {
    this.releaseDrumPreviewOwnership();
    this.latencyRouteProbeToken++;
    this.latencyRouteProbeOwner = -1;
    this.memberJoinFeedbackAttempt?.cancel();
    this.memberJoinFeedbackAttempt = undefined;
    this.latencyCalibrationActive = false;
    this.micCalibrationActive = false;
    this.keepRendererAliveForSession = false;
    this.teamJoinedForWarmup = false;
    try {
      // Disband the room before fallible audio/BLE cleanup so a local teardown
      // error cannot leave followers displaying a leader that has already gone.
      await this.controller.disconnect();
    } finally {
      // A failed audio/BLE stop must not strand the app-owned P2P connection.
      // The shared reset barrier stays active through every cleanup attempt.
      try {
        await this.metronome.stopEngine();
      } finally {
        try {
          await this.bleDiscovery.stopLeaderAdvertising();
        } finally {
          try {
            await this.p2p.teardown();
          } finally {
            try {
              AudioOutputMonitor.stop();
            } finally {
              await SessionBackgroundKeeper.stop();
            }
          }
        }
      }
    }
  }

  private async handleRemoteDisband(): Promise<void> {
    if (this.handlingRemoteDisband || AppSession.instance !== this) {
      return;
    }
    this.handlingRemoteDisband = true;
    try {
      await AppSession.reset();
    } catch (err) {
      console.warn(`Remote disband cleanup incomplete: ${(err as Error).message}`);
    }
    // A different room may have been prepared while cleanup was completing.
    // The old room's callback must not clear its transport or replace its page.
    if (AppSession.instance !== undefined && AppSession.instance !== this) {
      return;
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
    if (this.latencyCalibrationActive || this.drumPreviewActive) {
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

  /** Lets local audition visuals reject a transport taken over by production or calibration. */
  isDrumPreviewActive(): boolean {
    return this.drumPreviewActive;
  }

  /** PCM and the start schedule are ready; audible time may still be in preroll. */
  isDrumPreviewReady(): boolean {
    return this.drumPreviewActive && this.drumPreviewReady;
  }

  /** Also changes when another transport cancels a debounced, not-yet-started audition. */
  getDrumPreviewRequestRevision(): number {
    return this.drumPreviewToken;
  }

  /** A newer edit withdraws older prepared changes without stopping the active audition. */
  invalidateDrumPreviewUpdate(): void {
    this.drumPreviewUpdateRevision++;
    if (this.drumPreviewActive) {
      this.metronome.invalidateDrumPreviewUpdate();
    }
  }

  async updateDrumPreviewProgram(program: string, sectionKeys: string[]): Promise<boolean> {
    if (!this.isDrumPreviewReady()) {
      return false;
    }
    const owner = this.drumPreviewToken;
    const revision = ++this.drumPreviewUpdateRevision;
    try {
      const prepared = await this.metronome.updateDrumPreviewProgram(program, sectionKeys);
      return prepared && this.drumPreviewActive && owner === this.drumPreviewToken &&
        revision === this.drumPreviewUpdateRevision;
    } catch (err) {
      if (!this.drumPreviewActive || owner !== this.drumPreviewToken ||
        revision !== this.drumPreviewUpdateRevision) {
        return false;
      }
      // The existing plan keeps playing when an edit cannot be prepared.
      throw new Error((err as Error).message ?? '试听更新失败');
    }
  }

  /**
   * Starts a new local audition at an optional fractional editor cursor.
   * Whole-song callers also attach transient section keys for later live updates.
   */
  async previewDrumProgram(
    program: string,
    looping: boolean = true,
    previewBpm?: number,
    previewBeatsPerBar?: number,
    previewStartPositionBeats: number = 0,
    previewSectionKeys?: string[]
  ): Promise<void> {
    const token = ++this.drumPreviewToken;
    this.drumPreviewActive = true;
    this.drumPreviewReady = false;
    this.drumPreviewUpdateRevision++;
    const bpm = previewBpm ?? this.controller.bpm;
    const beatsPerBar = previewBeatsPerBar ?? this.controller.beatsPerBar;
    try {
      this.metronome.pause();
      this.metronome.setBpm(bpm, beatsPerBar);
      const ready = await this.metronome.configureProgram(program, looping);
      if (token !== this.drumPreviewToken) {
        return;
      }
      if (!ready) {
        throw new Error('鼓机试听配置已失效，请重试');
      }
      if (previewSectionKeys !== undefined) {
        this.metronome.attachDrumPreviewPlan(previewSectionKeys);
      }
      await this.metronome.scheduleFromLeaderStart(MonotonicClock.nowMs() + 350, 0, 0,
        undefined, previewStartPositionBeats);
      if (token === this.drumPreviewToken && this.drumPreviewActive) {
        this.drumPreviewReady = true;
      }
    } catch (err) {
      // A late failure belongs to its original request, never the newer audition.
      if (token === this.drumPreviewToken) {
        this.releaseDrumPreviewOwnership();
        this.metronome.pause();
      }
      throw new Error((err as Error).message ?? '鼓机试听启动失败');
    }
  }

  private releaseDrumPreviewOwnership(): boolean {
    const owned = this.drumPreviewActive === true;
    this.drumPreviewToken++;
    this.drumPreviewActive = false;
    this.drumPreviewReady = false;
    this.drumPreviewUpdateRevision++;
    if (owned) {
      this.metronome.cancelProgramPreparation();
    }
    return owned;
  }

  private preemptDrumPreview(): boolean {
    if (!this.drumPreviewActive) {
      this.drumPreviewToken++;
      return false;
    }
    this.releaseDrumPreviewOwnership();
    this.metronome.pause();
    return true;
  }

  stopDrumPreview(): void {
    if (!this.releaseDrumPreviewOwnership()) {
      return;
    }
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
    this.micCalibrationActive = false;
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('当前声音没有通过蓝牙耳机输出');
    }
    this.preemptDrumPreview();
    this.latencyRouteProbeToken++;
    this.latencyRouteProbeOwner = -1;
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
   * The raw presentation target measures the acoustic leg; its playback
   * reference binds the result to the renderer coordinate reused after save.
   * Stream continuity alone cannot prove capture teardown leaves A2DP unchanged.
   */
  async scheduleMicLoopbackSignal(signal: Int16Array,
    targetAtLocalMonoMs: number): Promise<CalibrationSignalTiming> {
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('当前声音没有通过蓝牙耳机输出');
    }
    this.preemptDrumPreview();
    this.latencyRouteProbeToken++;
    this.latencyRouteProbeOwner = -1;
    this.latencyCalibrationActive = true;
    this.micCalibrationActive = true;
    const timing = await this.metronome.scheduleCalibrationSignal(signal, targetAtLocalMonoMs);
    const expectedReference = timing.playbackReference;
    if (expectedReference === undefined) {
      throw new Error('本次回环测量未取得正式播放基准，请重新测量');
    }
    timing.playbackReference = this.readMicCalibrationPlaybackReference(expectedReference);
    return timing;
  }

  /** Reject a candidate whose retained renderer or production frame mapping has changed. */
  readMicCalibrationPlaybackReference(expected?: CalibrationPlaybackReference): CalibrationPlaybackReference {
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('蓝牙耳机已断开，请重新测量');
    }
    const current = this.metronome.readMicCalibrationPlaybackReference(expected);
    if (expected !== undefined &&
      (current.rendererEpoch !== expected.rendererEpoch || current.streamId !== expected.streamId ||
        Math.abs(current.frameMappingOffsetMs - expected.frameMappingOffsetMs) >
          MIC_PLAYBACK_REFERENCE_MAX_SPREAD_MS)) {
      throw new Error('测量后的正式播放基准发生变化，请重新测量');
    }
    return current;
  }

  /** Wait for fresh, advancing samples after capture teardown, without rebasing or rebuilding playback. */
  async verifyMicCalibrationPlaybackReference(expected: CalibrationPlaybackReference):
    Promise<CalibrationPlaybackReference> {
    const deadline = MonotonicClock.nowMs() + MIC_PLAYBACK_REFERENCE_RECOVERY_TIMEOUT_MS;
    let stable: CalibrationPlaybackReference[] = [];
    while (MonotonicClock.nowMs() <= deadline) {
      let current: CalibrationPlaybackReference | undefined = undefined;
      try {
        current = this.readMicCalibrationPlaybackReference(expected);
      } catch (err) {
        if (!(err instanceof MicPlaybackClockPendingError)) {
          throw new Error((err as Error).message ?? '正式播放基准校验失败，请重新测量');
        }
        // Never average the frozen interval into a healthy recovered clock.
        stable = [];
        console.info(`[MicPlaybackBridge] stage=verify state=waiting reason=${err.reason}`);
      }
      if (current !== undefined) {
        const previous = stable.length > 0 ? stable[stable.length - 1] : undefined;
        if (previous !== undefined &&
          (current.framePos < previous.framePos - MIC_PLAYBACK_REFERENCE_RATE_HZ * 0.02 ||
            current.timestampMonoMs < previous.timestampMonoMs - 1)) {
          throw new Error('录音结束后的播放时钟发生回退，请重新测量');
        }
        stable.push(current);
        if (stable.length >= 3) {
          const first = stable[0];
          const last = stable[stable.length - 1];
          const frameDelta = last.framePos - first.framePos;
          const timestampDeltaMs = last.timestampMonoMs - first.timestampMonoMs;
          if (frameDelta < -MIC_PLAYBACK_REFERENCE_RATE_HZ * 0.02 || timestampDeltaMs < -1) {
            throw new Error('录音结束后的播放时钟发生回退，请重新测量');
          }
          const offsets = stable.map((sample: CalibrationPlaybackReference) => sample.frameMappingOffsetMs);
          offsets.sort((a: number, b: number) => a - b);
          if (offsets[offsets.length - 1] - offsets[0] > MIC_PLAYBACK_REFERENCE_MAX_SPREAD_MS) {
            throw new Error('录音结束后的播放基准不稳定，请重新测量');
          }
          if (last.sampledAtMonoMs - first.sampledAtMonoMs >= 500) {
            const rateHz = timestampDeltaMs > 0 ? frameDelta * 1000 / timestampDeltaMs : 0;
            const advancing = timestampDeltaMs >= 400 &&
              frameDelta >= MIC_PLAYBACK_REFERENCE_RATE_HZ * 0.3 &&
              Math.abs(rateHz - MIC_PLAYBACK_REFERENCE_RATE_HZ) / MIC_PLAYBACK_REFERENCE_RATE_HZ <= 0.08 &&
              last.submittedFrames > first.submittedFrames;
            if (advancing) {
              console.info(`[MicPlaybackBridge] stage=verify state=stable ` +
                `rendererEpoch=${last.rendererEpoch} streamId=${last.streamId} rateHz=${rateHz.toFixed(1)}`);
              return {
                rendererEpoch: last.rendererEpoch,
                streamId: last.streamId,
                frameMappingOffsetMs: offsets[Math.floor(offsets.length / 2)],
                sampledAtMonoMs: last.sampledAtMonoMs,
                framePos: last.framePos,
                timestampMonoMs: last.timestampMonoMs,
                submittedFrames: last.submittedFrames
              };
            }
            console.info(`[MicPlaybackBridge] stage=verify state=waiting reason=clock-not-advancing ` +
              `rateHz=${rateHz.toFixed(1)} frameDelta=${frameDelta} timestampDeltaMs=${timestampDeltaMs.toFixed(1)} ` +
              `submittedDelta=${last.submittedFrames - first.submittedFrames}`);
            stable = [last];
          }
        }
      }
      const remainingMs = deadline - MonotonicClock.nowMs();
      if (remainingMs <= 0) {
        break;
      }
      await new Promise<void>((resolve) =>
        setTimeout(() => resolve(), Math.min(MIC_PLAYBACK_REFERENCE_SAMPLE_INTERVAL_MS, remainingMs)));
    }
    throw new Error('录音结束后的播放时钟未在 4 秒内恢复，请保持耳机连接后重试');
  }

  /** Play the input-reference chirp through the phone speaker on the same frame clock. */
  async scheduleMicInputReferenceSignal(signal: Int16Array,
    targetAtLocalMonoMs: number): Promise<CalibrationSignalTiming> {
    if (!AudioOutputMonitor.isBuiltInSpeakerActive()) {
      throw new Error('输入侧校准需要把媒体输出切到手机扬声器');
    }
    this.preemptDrumPreview();
    this.latencyRouteProbeToken++;
    this.latencyRouteProbeOwner = -1;
    this.latencyCalibrationActive = true;
    this.micCalibrationActive = true;
    return await this.metronome.scheduleCalibrationSignal(signal, targetAtLocalMonoMs);
  }

  /** Enter mic measurement before its first chirp, then realign the probe frame epoch. */
  async flushMicCalibrationProbeBoundary(): Promise<void> {
    this.preemptDrumPreview();
    this.latencyRouteProbeToken++;
    this.latencyRouteProbeOwner = -1;
    this.latencyCalibrationActive = true;
    this.micCalibrationActive = true;
    await this.metronome.flushCalibrationStreamBetweenProbes();
  }

  /** Compare the same renderer immediately before production settles after capture teardown. */
  scheduleMicPostCaptureDiagnostics(stage: string): void {
    this.micCalibrationActive = false;
    const generation = ++this.micPostCaptureDiagGeneration;
    const logAfter = (delayMs: number): void => {
      setTimeout((): void => {
        if (generation !== this.micPostCaptureDiagGeneration) {
          return;
        }
        this.metronome.logMicCalibrationAudioState(
          `${stage}-capturer-released+${delayMs}ms`);
      }, delayMs);
    };
    this.metronome.logMicCalibrationAudioState(`${stage}-capturer-released+0ms`);
    logAfter(500);
    logAfter(2000);
  }

  /**
   * Run the same 120 BPM click against a visual reference for result-page A/B
   * listening. The explicit override lets the preview compare raw output with
   * the freshly measured app-to-ear compensation without saving it first.
   */
  async scheduleLatencyPreview(startAtLocalMonoMs: number, compensationMs: number): Promise<void> {
    this.micCalibrationActive = false;
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('当前声音没有通过蓝牙耳机输出');
    }
    this.preemptDrumPreview();
    this.latencyRouteProbeToken++;
    this.latencyRouteProbeOwner = -1;
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
    this.micCalibrationActive = false;
    if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
      throw new Error('未检测到蓝牙耳机输出');
    }
    this.preemptDrumPreview();
    const probeToken = ++this.latencyRouteProbeToken;
    this.latencyRouteProbeOwner = probeToken;
    this.latencyCalibrationActive = true;
    try {
      const played = await this.metronome.playRouteProbeClickPair(() =>
        probeToken !== this.latencyRouteProbeToken || !AudioOutputMonitor.isBluetoothA2dpActive());
      if (probeToken !== this.latencyRouteProbeToken) {
        return false;
      }
      this.pauseLatencyCalibration();
      if (!AudioOutputMonitor.isBluetoothA2dpActive()) {
        throw new Error('试音期间蓝牙耳机已断开');
      }
      return played;
    } catch (err) {
      if (probeToken === this.latencyRouteProbeToken) {
        this.pauseLatencyCalibration();
      }
      throw new Error((err as Error).message ?? '蓝牙试音失败，请重试');
    } finally {
      if (this.latencyRouteProbeOwner === probeToken) {
        this.latencyRouteProbeOwner = -1;
      }
    }
  }

  async stopLatencyCalibration(): Promise<void> {
    const stopToken = ++this.latencyRouteProbeToken;
    this.latencyRouteProbeOwner = -1;
    this.micCalibrationActive = false;
    if (!this.latencyCalibrationActive) {
      return;
    }
    this.latencyCalibrationActive = false;
    if (this.keepRendererAliveForSession) {
      this.metronome.pause();
    } else {
      await this.metronome.suspendRenderer();
    }
    // A delayed stop can finish after a new pair or measurement starts. Do not
    // replace that newer finite sequence with the team's looping configuration.
    if (stopToken === this.latencyRouteProbeToken && !this.latencyCalibrationActive) {
      this.syncEngineFromSession();
    }
  }

  /** Preserve the exact physical output stream that produced the saved result. */
  keepLatencyCalibrationRendererAlive(): void {
    this.micCalibrationActive = false;
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
    this.micCalibrationActive = false;
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

  async memberJoinWithInvitation(
    invitation: P2pRoomInvitation,
    onProgress?: (stage: MemberJoinStage) => void
  ): Promise<void> {
    const startedAt = MonotonicClock.nowMs();
    let previousStageAt = startedAt;
    const reportStage = (stage: string, progress?: MemberJoinStage): void => {
      const now = MonotonicClock.nowMs();
      console.info(`[JoinDiag] stage=${stage} elapsedMs=${(now - startedAt).toFixed(1)} ` +
        `stageMs=${(now - previousStageAt).toFixed(1)}`);
      previousStageAt = now;
      if (progress !== undefined) {
        onProgress?.(progress);
      }
    };
    // BLE 反馈通道只负责把队长的“拒绝”信号快速传回队员，属于尽力而为；
    // 若在 P2P 连接前串行等待，会明显拖慢队长确认弹窗的出现。
    // 这里并行发起 P2P 连接，同时后台建立 BLE 反馈通道。
    const feedbackAttempt = new BleMemberJoinFeedbackAttempt();
    this.memberJoinFeedbackAttempt?.cancel();
    this.memberJoinFeedbackAttempt = feedbackAttempt;
    const feedbackPromise = this.bleDiscovery.startMemberJoinFeedback(invitation, feedbackAttempt)
      .catch(() => undefined);
    const rejectionSignal: Promise<Error> = feedbackPromise.then((channel) => {
      if (channel !== undefined) {
        return channel.rejection;
      }
      // 未建立 BLE 拒绝通道时保持 pending，由系统 P2P 确认弹窗超时兜底
      return new Promise<Error>(() => {});
    });
    try {
      reportStage('p2p-start', 'connecting');
      const goIp = await this.p2p.connectToLeader(invitation, rejectionSignal);
      reportStage('p2p-ready', 'joining');
      await this.controller.connectMember(goIp, invitation.port, invitation);
      reportStage('clock-ready', 'preparing');
      this.syncEngineFromSession();
      try {
        // Members prepare their renderer while still in the lobby; otherwise a
        // slow first allocation can make only that device miss the shared start.
        await this.metronome.ensureRenderer();
      } catch (err) {
        console.warn(`MetronomeEngine member prewarm failed: ${(err as Error).message}`);
      }
      reportStage('renderer-ready');
      this.handleTransportFromStorage();
      await SessionBackgroundKeeper.start(false); // 队员：隐藏媒体卡片
      reportStage('background-ready');
      this.teamJoinedForWarmup = true;
      void this.maybeWarmUpRendererForPlayback();
      reportStage('lobby-ready');
    } catch (err) {
      const joinError = err as Error;
      reportStage('join-failed');
      await this.p2p.abortMemberJoin();
      throw joinError;
    } finally {
      // BLE only reports rejection; room authentication uses the TCP hello.
      // Cancel pending registration before allowing a retry, and release any
      // late channel without holding up a successfully joined lobby or its error.
      feedbackAttempt.cancel();
      if (this.memberJoinFeedbackAttempt === feedbackAttempt) {
        this.memberJoinFeedbackAttempt = undefined;
      }
      void feedbackPromise.then(async (channel) => {
        if (channel !== undefined) {
          await channel.close();
        }
      }).catch(() => { console.warn('[JoinDiag] feedback cleanup failed'); });
    }
  }

  async memberJoinByCode(
    code: string,
    onRoomFound?: () => void,
    onProgress?: (stage: MemberJoinStage) => void
  ): Promise<void> {
    const trimmed = code.trim();
    // 预热 P2P 设备发现，与 BLE 扫描并行，避免连接阶段冷启动等待
    const discoveryWarmup = this.p2p.prepareMemberDiscovery().catch(() => {});
    const invitation = await this.bleDiscovery.resolveInvitationByCode(trimmed, PROTOCOL_VERSION);
    if (onRoomFound) {
      onRoomFound();
    }
    await discoveryWarmup;
    await this.memberJoinWithInvitation(invitation, onProgress);
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
    if (this.preemptDrumPreview()) {
      this.syncEngineFromSession();
    }
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
    if (this.preemptDrumPreview()) {
      this.syncEngineFromSession();
    }
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
    // Shared transport has priority over local audition; late kit loads must
    // lose their start permission before session configuration is restored.
    if (message.type === 'TRANSPORT' || message.type === 'TRANSPORT_PAUSE' ||
      message.type === 'TRANSPORT_RESUME') {
      this.preemptDrumPreview();
    }
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
