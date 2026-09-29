import { Context, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

const BUNDLE_NAME: string = 'com.onebeat.app';
const ABILITY_NAME: string = 'EntryAbility';

export class SessionBackgroundKeeper {
  private static context: Context | undefined = undefined;
  private static active: boolean = false;
  private static operation: Promise<void> = Promise.resolve();

  static initialize(context: Context): void {
    SessionBackgroundKeeper.context = context;
  }

  static start(): Promise<void> {
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
        await backgroundTaskManager.stopBackgroundRunning(SessionBackgroundKeeper.context);
      } catch (err) {
        console.warn(`SessionBackgroundKeeper stop: ${(err as Error).message}`);
      } finally {
        SessionBackgroundKeeper.active = false;
      }
    });
    return SessionBackgroundKeeper.operation;
  }
}
