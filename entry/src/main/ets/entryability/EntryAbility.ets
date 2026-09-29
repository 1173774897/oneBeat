import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { DOMAIN, TAG } from '../common/Constants';
import { DrumSampleBank } from '../audio/DrumSampleBank';
import { AppSession } from '../app/AppSession';
import { SessionBackgroundKeeper } from '../session/SessionBackgroundKeeper';

export default class EntryAbility extends UIAbility {
  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    SessionBackgroundKeeper.initialize(this.context);
    DrumSampleBank.initialize(this.context.resourceManager);
    AppStorage.setOrCreate('sessionEpoch', 0);
    AppStorage.setOrCreate('lastTransportMessage', '');
    AppStorage.setOrCreate('beatEpoch', 0);
    AppStorage.setOrCreate('currentBeatIndex', 0);
    AppStorage.setOrCreate('currentBeatInBar', 1);
    AppStorage.setOrCreate('beatStartedAtMs', 0);
    AppStorage.setOrCreate('safeAreaTop', 0);
    AppStorage.setOrCreate('safeAreaBottom', 0);
    AppStorage.setOrCreate('selectedSceneKey', 'neon_street');
    AppStorage.setOrCreate('playerDisplayName', '');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
    AppSession.clear();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    void this.configureWindow(windowStage);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `Failed to load Index: ${JSON.stringify(err)}`);
      }
    });
  }

  private async configureWindow(windowStage: window.WindowStage): Promise<void> {
    try {
      const mainWindow = await windowStage.getMainWindow();
      await mainWindow.setWindowKeepScreenOn(true);
      await mainWindow.setWindowLayoutFullScreen(true);
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#171B1F',
        navigationBarContentColor: '#171B1F'
      });
      const avoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      AppStorage.setOrCreate('safeAreaTop', px2vp(avoidArea.topRect.height));
      AppStorage.setOrCreate('safeAreaBottom', px2vp(avoidArea.bottomRect.height));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, `Failed to configure immersive window: ${JSON.stringify(error)}`);
    }
  }
}
