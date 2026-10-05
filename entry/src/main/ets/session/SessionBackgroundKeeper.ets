import { Context, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';

const BUNDLE_NAME: string = 'com.onebeat.app';
const ABILITY_NAME: string = 'EntryAbility';
const SESSION_TAG: string = 'onebeat-audio';

export interface TransportControlHandler {
  onPlay: () => void;
  onPause: () => void;
}

export class SessionBackgroundKeeper {
  private static context: Context | undefined = undefined;
  private static active: boolean = false;
  private static operation: Promise<void> = Promise.resolve();
  private static session: avSession.AVSession | undefined = undefined;
  private static controlHandler: TransportControlHandler | undefined = undefined;

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
      if (SessionBackgroundKeeper.active || SessionBackgroundKeeper.context === undefined) {
        return;
      }
      try {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: BUNDLE_NAME, abilityName: ABILITY_NAME }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 9527,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        await backgroundTaskManager.startBackgroundRunning(
          SessionBackgroundKeeper.context,
          ['audioPlayback', 'multiDeviceConnection'],
          agent
        );
        await SessionBackgroundKeeper.ensureAvSession(showMediaCard);
        SessionBackgroundKeeper.active = true;
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
        await backgroundTaskManager.stopBackgroundRunning(SessionBackgroundKeeper.context);
      } catch (err) {
        console.warn(`SessionBackgroundKeeper stop: ${(err as Error).message}`);
      } finally {
        SessionBackgroundKeeper.active = false;
      }
    });
    return SessionBackgroundKeeper.operation;
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
}
