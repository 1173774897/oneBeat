import { Context, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { runningLock } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';

const BUNDLE_NAME: string = 'com.onebeat.app';
const ABILITY_NAME: string = 'EntryAbility';
const SESSION_TAG: string = 'onebeat-audio';
const MEDIA_COVER_PATH: string = 'comic/brand/media_session_cover.png';
const RUNNING_LOCK_NAME: string = 'com.onebeat.app.team-session';
const RUNNING_LOCK_HOLD_MS: number = 10 * 60 * 1000;
const RUNNING_LOCK_RENEW_MS: number = 5 * 60 * 1000;

export interface TransportControlHandler {
  onPlay: () => void;
  onPause: () => void;
}

export class SessionBackgroundKeeper {
  private static context: Context | undefined = undefined;
  private static active: boolean = false;
  private static recordingActive: boolean = false;
  private static backgroundTaskStarted: boolean = false;
  private static backgroundTaskId: number = -1;
  private static operation: Promise<void> = Promise.resolve();
  private static session: avSession.AVSession | undefined = undefined;
  private static mediaCover: image.PixelMap | undefined = undefined;
  private static mediaTitle: string = '单人练习';
  private static controlHandler: TransportControlHandler | undefined = undefined;
  private static sessionRunningLock: runningLock.RunningLock | undefined = undefined;
  private static runningLockRenewTimer: number = -1;
  private static showMediaCard: boolean = false;
  private static playing: boolean = false;
  private static audioActive: boolean = false;
  private static cancellationObserved: boolean = false;
  // Set when the native task vanished while audio mode was owned. The system
  // mutes such a stream shortly afterwards while PCM callbacks and hardware
  // timestamps keep advancing, so phase feedback cannot detect the loss.
  private static playbackContinuityLost: boolean = false;

  static initialize(context: Context): void {
    SessionBackgroundKeeper.context = context;
    if (!SessionBackgroundKeeper.cancellationObserved) {
      try {
        backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
          if (SessionBackgroundKeeper.backgroundTaskId >= 0 && info.id !== SessionBackgroundKeeper.backgroundTaskId) {
            return;
          }
          // System cancellation invalidates our local cache even while the team
          // connection remains alive. Only a later playback/lifecycle request retries.
          SessionBackgroundKeeper.backgroundTaskStarted = false;
          SessionBackgroundKeeper.backgroundTaskId = -1;
          if (SessionBackgroundKeeper.audioActive) {
            SessionBackgroundKeeper.playbackContinuityLost = true;
          }
          console.warn(`[BackgroundPlaybackDiag] stage=cancelled reason=${info.reason}`);
        });
        SessionBackgroundKeeper.cancellationObserved = true;
      } catch (error) {
        console.warn(`SessionBackgroundKeeper cancellation observer: ${(error as Error).message}`);
      }
    }
  }

  static setControlHandler(handler: TransportControlHandler): void {
    SessionBackgroundKeeper.controlHandler = handler;
  }

  /** Cache presentation before AVSession creation; repeated UI updates must not resend artwork. */
  static async updateMediaTitle(title: string): Promise<void> {
    if (SessionBackgroundKeeper.mediaTitle === title) {
      return;
    }
    SessionBackgroundKeeper.mediaTitle = title;
    const task = SessionBackgroundKeeper.operation.then(async () => {
      const session = SessionBackgroundKeeper.session;
      const context = SessionBackgroundKeeper.context;
      if (session !== undefined && context !== undefined) {
        await SessionBackgroundKeeper.updateAvMetadata(session, context);
      }
    });
    SessionBackgroundKeeper.operation = task.catch(() => {});
    try {
      await task;
    } catch (err) {
      console.warn(`SessionBackgroundKeeper update media metadata: ${(err as Error).message}`);
    }
  }

  /**
   * 申请后台长时任务并接入 AVSession。
   * 长时任务是后台保活的主要依赖，所有角色（队长/单机/队员）都需要。
   * AVSession 用于后台播控：仅队长/单机需要激活以显示媒体卡片，队员虽创建但不激活，
   * 从而在保持后台出声的同时不显示播控卡片。
   */
  static start(showMediaCard: boolean): Promise<void> {
    SessionBackgroundKeeper.operation = SessionBackgroundKeeper.operation.then(async () => {
      SessionBackgroundKeeper.showMediaCard = showMediaCard;
      if (SessionBackgroundKeeper.context === undefined) {
        return;
      }
      if (SessionBackgroundKeeper.active) {
        try { await SessionBackgroundKeeper.ensureAvSession(showMediaCard); }
        catch (err) { console.warn(`SessionBackgroundKeeper media session: ${(err as Error).message}`); }
        await SessionBackgroundKeeper.ensureRunningLock();
        return;
      }
      try {
        await SessionBackgroundKeeper.applyBackgroundModes(true, SessionBackgroundKeeper.recordingActive);
        // Keep connection ownership if media setup fails. Playback admission
        // separately requires both AVSession and a live native background task.
        SessionBackgroundKeeper.active = true;
        await SessionBackgroundKeeper.ensureAvSession(showMediaCard);
      } catch (err) {
        console.warn(`SessionBackgroundKeeper start: ${(err as Error).message}`);
      } finally {
        if (SessionBackgroundKeeper.active) {
          await SessionBackgroundKeeper.ensureRunningLock();
        }
      }
    });
    return SessionBackgroundKeeper.operation;
  }

  /** Revalidate native ownership before shared playback and across ability transitions. */
  static ensurePlaybackReady(): Promise<void> {
    const task = SessionBackgroundKeeper.operation.then(async () => {
      if (!SessionBackgroundKeeper.active || SessionBackgroundKeeper.context === undefined) {
        throw new Error('后台播放任务尚未准备好');
      }
      try {
        await SessionBackgroundKeeper.ensureAvSession(SessionBackgroundKeeper.showMediaCard);
      } catch (_error) {
        // A cached proxy can outlive the native session. Rebuild it once before
        // declaring playback unavailable; retaining the object alone is no proof.
        await SessionBackgroundKeeper.destroyAvSession();
        await SessionBackgroundKeeper.ensureAvSession(SessionBackgroundKeeper.showMediaCard);
      }
      let canVerifyTask = false;
      try {
        const tasks = await backgroundTaskManager.getAllContinuousTasks(SessionBackgroundKeeper.context, true);
        canVerifyTask = true;
        const current = tasks.find((item: backgroundTaskManager.ContinuousTaskInfo) => item.abilityName === ABILITY_NAME);
        if (SessionBackgroundKeeper.audioActive && (current === undefined || current.suspendState)) {
          // Cancellation can be missed while JS is frozen; enumeration is the backstop.
          SessionBackgroundKeeper.playbackContinuityLost = true;
        }
        SessionBackgroundKeeper.backgroundTaskStarted = current !== undefined;
        SessionBackgroundKeeper.backgroundTaskId = current?.continuousTaskId ?? -1;
        console.info(`[BackgroundPlaybackDiag] stage=verify taskPresent=${current !== undefined} ` +
          `suspended=${current?.suspendState ?? false} modes=${current?.backgroundModes.join(',') ?? 'none'}`);
      } catch (error) {
        // Older runtimes may not expose enumeration. Updating the task below
        // still checks the native service, rather than trusting active alone.
        console.warn(`SessionBackgroundKeeper task query: ${(error as Error).message}`);
      }
      const wasAudioActive = SessionBackgroundKeeper.audioActive;
      SessionBackgroundKeeper.audioActive = true;
      try {
        await SessionBackgroundKeeper.applyBackgroundModes(true, SessionBackgroundKeeper.recordingActive);
      } catch (error) {
        SessionBackgroundKeeper.audioActive = wasAudioActive;
        throw error as Error;
      }
      if (canVerifyTask) {
        const tasks = await backgroundTaskManager.getAllContinuousTasks(SessionBackgroundKeeper.context, true);
        const current = tasks.find((item: backgroundTaskManager.ContinuousTaskInfo) => item.abilityName === ABILITY_NAME);
        if (current === undefined || current.suspendState || !current.backgroundModes.includes('audioPlayback')) {
          throw new Error('系统后台音频任务尚未生效');
        }
      }
      await SessionBackgroundKeeper.ensureRunningLock();
      console.info('[BackgroundPlaybackDiag] stage=ready');
    });
    SessionBackgroundKeeper.operation = task.catch(() => {});
    return task;
  }

  static stop(): Promise<void> {
    SessionBackgroundKeeper.operation = SessionBackgroundKeeper.operation.then(async () => {
      if (!SessionBackgroundKeeper.active || SessionBackgroundKeeper.context === undefined) {
        return;
      }
      try {
        await SessionBackgroundKeeper.destroyAvSession();
        await SessionBackgroundKeeper.applyBackgroundModes(false, SessionBackgroundKeeper.recordingActive);
      } catch (err) {
        console.warn(`SessionBackgroundKeeper stop: ${(err as Error).message}`);
      } finally {
        SessionBackgroundKeeper.releaseRunningLock();
        SessionBackgroundKeeper.active = false;
        SessionBackgroundKeeper.audioActive = false;
        SessionBackgroundKeeper.playing = false;
        SessionBackgroundKeeper.playbackContinuityLost = false;
        SessionBackgroundKeeper.mediaTitle = '单人练习';
      }
    });
    return SessionBackgroundKeeper.operation;
  }

  /**
   * Returns and clears whether the playing stream lost its native background
   * task since the last check. Callers that receive true must rebuild audio on
   * the shared epoch; a muted stream cannot prove its own continuity.
   */
  static consumePlaybackContinuityLoss(): boolean {
    const lost = SessionBackgroundKeeper.playbackContinuityLost;
    SessionBackgroundKeeper.playbackContinuityLost = false;
    return lost;
  }

  /** A UIAbility owns one task: capture must extend it without releasing team audio/connection. */
  static setRecordingActive(active: boolean): Promise<void> {
    const task = SessionBackgroundKeeper.operation.then(async () => {
      if (SessionBackgroundKeeper.recordingActive === active) {
        return;
      }
      await SessionBackgroundKeeper.applyBackgroundModes(SessionBackgroundKeeper.active, active);
      SessionBackgroundKeeper.recordingActive = active;
    });
    SessionBackgroundKeeper.operation = task.catch(() => {});
    return task;
  }

  private static async applyBackgroundModes(team: boolean, recording: boolean): Promise<void> {
    const context = SessionBackgroundKeeper.context;
    if (context === undefined) {
      throw new Error('后台任务尚未准备好，请稍后重试');
    }
    const modes: string[] = [];
    if (team) {
      // The team link is Wi-Fi P2P + TCP, not a distributed (DSoftBus) link, so
      // the system audit rejects multiDeviceConnection after ~60s and cancels the
      // WHOLE task, muting playback. While audio plays, audioPlayback alone is a
      // compliant reason to keep the process and its sockets alive.
      modes.push(SessionBackgroundKeeper.audioActive ? 'audioPlayback' : 'multiDeviceConnection');
    }
    if (recording) {
      modes.push('audioRecording');
    }
    if (modes.length === 0) {
      if (SessionBackgroundKeeper.backgroundTaskStarted) {
        await backgroundTaskManager.stopBackgroundRunning(context);
        SessionBackgroundKeeper.backgroundTaskStarted = false;
        SessionBackgroundKeeper.backgroundTaskId = -1;
      }
      return;
    }
    if (SessionBackgroundKeeper.backgroundTaskStarted) {
      const task = await backgroundTaskManager.updateBackgroundRunning(context, modes);
      SessionBackgroundKeeper.backgroundTaskId = task?.continuousTaskId ?? SessionBackgroundKeeper.backgroundTaskId;
      return;
    }
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: BUNDLE_NAME, abilityName: ABILITY_NAME }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 9527,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    const task = await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
    SessionBackgroundKeeper.backgroundTaskStarted = true;
    SessionBackgroundKeeper.backgroundTaskId = task?.continuousTaskId ?? -1;
  }

  /**
   * Audio mode follows real transport ownership; a paused team retains its
   * connection task and AVSession, then rearms audio at the next prepared start.
   */
  static async updatePlaybackState(playing: boolean, force: boolean = false): Promise<void> {
    const changed = SessionBackgroundKeeper.playing !== playing;
    SessionBackgroundKeeper.playing = playing;
    if (!changed && !force) { return; }
    const task = SessionBackgroundKeeper.operation.then(async () => {
      const wasAudioActive = SessionBackgroundKeeper.audioActive;
      SessionBackgroundKeeper.audioActive = playing;
      if (!playing) {
        // The next start builds a fresh stream, so earlier loss needs no repair.
        SessionBackgroundKeeper.playbackContinuityLost = false;
      }
      try {
        if (SessionBackgroundKeeper.active) {
          await SessionBackgroundKeeper.applyBackgroundModes(true, SessionBackgroundKeeper.recordingActive);
        }
      } catch (error) {
        SessionBackgroundKeeper.audioActive = wasAudioActive;
        throw error as Error;
      }
      const session = SessionBackgroundKeeper.session;
      if (session !== undefined) {
        await session.setAVPlaybackState({ state: playing ?
          avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE });
      }
    });
    SessionBackgroundKeeper.operation = task.catch(() => {});
    try {
      await task;
    } catch (err) {
      console.warn(`SessionBackgroundKeeper updatePlaybackState: ${(err as Error).message}`);
    }
  }

  private static async ensureAvSession(showMediaCard: boolean): Promise<void> {
    const context = SessionBackgroundKeeper.context;
    if (context === undefined) {
      return;
    }
    if (SessionBackgroundKeeper.session === undefined) {
      const session = await avSession.createAVSession(context, SESSION_TAG, 'audio');
      session.on('play', () => {
        SessionBackgroundKeeper.controlHandler?.onPlay();
      });
      session.on('pause', () => {
        SessionBackgroundKeeper.controlHandler?.onPause();
      });
      SessionBackgroundKeeper.session = session;
    }
    const session = SessionBackgroundKeeper.session;
    await SessionBackgroundKeeper.updateAvMetadata(session, context);
    if (showMediaCard) {
      await session.activate();
    } else {
      // 队员：去激活以隐藏卡片，但保留会话对象，后台保活不受影响。
      try {
        await session.deactivate();
      } catch (err) {
        console.warn(`SessionBackgroundKeeper deactivate: ${(err as Error).message}`);
      }
    }
    await session.setAVPlaybackState({ state: SessionBackgroundKeeper.playing ?
      avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE });
  }

  private static async destroyAvSession(): Promise<void> {
    const session = SessionBackgroundKeeper.session;
    if (session === undefined) {
      return;
    }
    try {
      await session.destroy();
    } catch (err) {
      console.warn(`SessionBackgroundKeeper destroyAvSession: ${(err as Error).message}`);
    }
    SessionBackgroundKeeper.session = undefined;
    const cover = SessionBackgroundKeeper.mediaCover;
    SessionBackgroundKeeper.mediaCover = undefined;
    try {
      await cover?.release();
    } catch (err) {
      console.warn(`SessionBackgroundKeeper release media cover: ${(err as Error).message}`);
    }
  }

  private static async updateAvMetadata(session: avSession.AVSession, context: Context): Promise<void> {
    await session.setAVMetadata({
      assetId: 'onebeat-metronome',
      title: SessionBackgroundKeeper.mediaTitle,
      artist: '同拍 · ONEBEAT',
      mediaImage: await SessionBackgroundKeeper.loadMediaCover(context)
    });
  }

  private static async loadMediaCover(context: Context): Promise<image.PixelMap | undefined> {
    if (SessionBackgroundKeeper.mediaCover !== undefined) {
      return SessionBackgroundKeeper.mediaCover;
    }
    let source: image.ImageSource | undefined = undefined;
    try {
      const content = await context.resourceManager.getRawFileContent(MEDIA_COVER_PATH);
      source = image.createImageSource(content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength));
      // Native media surfaces receive pixels instead of an app-private rawfile URI.
      // Keep one decoded cover for this AVSession; lifecycle refreshes reuse it.
      SessionBackgroundKeeper.mediaCover = await source.createPixelMap();
    } catch (err) {
      // Artwork failure must not prevent playback or the remaining metadata.
      console.warn(`SessionBackgroundKeeper load media cover: ${(err as Error).message}`);
    } finally {
      try {
        await source?.release();
      } catch (err) {
        console.warn(`SessionBackgroundKeeper release image source: ${(err as Error).message}`);
      }
    }
    return SessionBackgroundKeeper.mediaCover;
  }

  private static async ensureRunningLock(): Promise<void> {
    try {
      if (!runningLock.isSupported(runningLock.RunningLockType.BACKGROUND)) {
        console.warn('SessionBackgroundKeeper: BACKGROUND running lock is unsupported');
        return;
      }
      if (SessionBackgroundKeeper.sessionRunningLock === undefined) {
        SessionBackgroundKeeper.sessionRunningLock = await runningLock.create(
          RUNNING_LOCK_NAME,
          runningLock.RunningLockType.BACKGROUND
        );
      }
      SessionBackgroundKeeper.renewRunningLock();
      if (SessionBackgroundKeeper.runningLockRenewTimer < 0) {
        SessionBackgroundKeeper.runningLockRenewTimer = setInterval(() => {
          SessionBackgroundKeeper.renewRunningLock();
        }, RUNNING_LOCK_RENEW_MS);
      }
    } catch (err) {
      // Long-running task and AVSession remain useful fallbacks on devices that
      // reject the optional lock despite declaring RUNNING_LOCK permission.
      console.warn(`SessionBackgroundKeeper running lock start: ${(err as Error).message}`);
    }
  }

  private static renewRunningLock(): void {
    const lock = SessionBackgroundKeeper.sessionRunningLock;
    if (lock === undefined) {
      return;
    }
    try {
      if (lock.isHolding()) {
        lock.unhold();
      }
      // A finite hold limits leakage after an abnormal process teardown; the
      // timer renews it while the team session remains active.
      lock.hold(RUNNING_LOCK_HOLD_MS);
    } catch (err) {
      console.warn(`SessionBackgroundKeeper running lock renew: ${(err as Error).message}`);
    }
  }

  private static releaseRunningLock(): void {
    if (SessionBackgroundKeeper.runningLockRenewTimer >= 0) {
      clearInterval(SessionBackgroundKeeper.runningLockRenewTimer);
      SessionBackgroundKeeper.runningLockRenewTimer = -1;
    }
    const lock = SessionBackgroundKeeper.sessionRunningLock;
    SessionBackgroundKeeper.sessionRunningLock = undefined;
    if (lock === undefined) {
      return;
    }
    try {
      if (lock.isHolding()) {
        lock.unhold();
      }
    } catch (err) {
      console.warn(`SessionBackgroundKeeper running lock stop: ${(err as Error).message}`);
    }
  }
}
