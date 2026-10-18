import { Context, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { runningLock } from '@kit.BasicServicesKit';

const BUNDLE_NAME: string = 'com.onebeat.app';
const ABILITY_NAME: string = 'EntryAbility';
const SESSION_TAG: string = 'onebeat-audio';
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
  private static operation: Promise<void> = Promise.resolve();
  private static session: avSession.AVSession | undefined = undefined;
  private static controlHandler: TransportControlHandler | undefined = undefined;
  private static sessionRunningLock: runningLock.RunningLock | undefined = undefined;
  private static runningLockRenewTimer: number = -1;

  static initialize(context: Context): void {
    SessionBackgroundKeeper.context = context;
  }

  static setControlHandler(handler: TransportControlHandler): void {
    SessionBackgroundKeeper.controlHandler = handler;
  }

  /**
   * 申请后台长时任务并接入 AVSession。
   * 长时任务是后台保活的主要依赖，所有角色（队长/单机/队员）都需要。
   * AVSession 用于后台播控：仅队长/单机需要激活以显示媒体卡片，队员虽创建但不激活，
   * 从而在保持后台出声的同时不显示播控卡片。
   */
  static start(showMediaCard: boolean): Promise<void> {
    SessionBackgroundKeeper.operation = SessionBackgroundKeeper.operation.then(async () => {
      if (SessionBackgroundKeeper.context === undefined) {
        return;
      }
      if (SessionBackgroundKeeper.active) {
        if (SessionBackgroundKeeper.session === undefined) {
          try { await SessionBackgroundKeeper.ensureAvSession(showMediaCard); }
          catch (err) { console.warn(`SessionBackgroundKeeper media card: ${(err as Error).message}`); }
        }
        return;
      }
      try {
        await SessionBackgroundKeeper.applyBackgroundModes(true, SessionBackgroundKeeper.recordingActive);
        // The background owner exists even if its optional media card fails.
        SessionBackgroundKeeper.active = true;
        await SessionBackgroundKeeper.ensureAvSession(showMediaCard);
        await SessionBackgroundKeeper.ensureRunningLock();
      } catch (err) {
        console.warn(`SessionBackgroundKeeper start: ${(err as Error).message}`);
      }
    });
    return SessionBackgroundKeeper.operation;
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
      }
    });
    return SessionBackgroundKeeper.operation;
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
      modes.push('audioPlayback', 'multiDeviceConnection');
    }
    if (recording) {
      modes.push('audioRecording');
    }
    if (modes.length === 0) {
      if (SessionBackgroundKeeper.backgroundTaskStarted) {
        await backgroundTaskManager.stopBackgroundRunning(context);
        SessionBackgroundKeeper.backgroundTaskStarted = false;
      }
      return;
    }
    if (SessionBackgroundKeeper.backgroundTaskStarted) {
      await backgroundTaskManager.updateBackgroundRunning(context, modes);
      return;
    }
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: BUNDLE_NAME, abilityName: ABILITY_NAME }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 9527,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
    await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
    SessionBackgroundKeeper.backgroundTaskStarted = true;
  }

  /**
   * 同步 AVSession 播放状态。暂停时仅更新状态为 PAUSE，不销毁会话，
   * 从而队员/队长暂停后仍保有后台出声能力，恢复播放时无需重新申请。
   */
  static async updatePlaybackState(playing: boolean): Promise<void> {
    const session = SessionBackgroundKeeper.session;
    if (session === undefined) {
      return;
    }
    try {
      await session.setAVPlaybackState({
        state: playing
          ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
      });
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
    await session.setAVMetadata({
      assetId: 'onebeat-metronome',
      title: 'oneBeat',
      artist: 'oneBeat'
    });
    if (showMediaCard) {
      await session.activate();
      await session.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY
      });
    } else {
      // 队员：去激活以隐藏卡片，但保留会话对象，后台保活不受影响。
      try {
        await session.deactivate();
      } catch (err) {
        console.warn(`SessionBackgroundKeeper deactivate: ${(err as Error).message}`);
      }
    }
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
