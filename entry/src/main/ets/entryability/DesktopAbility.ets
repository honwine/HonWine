import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import testNapi from 'libentry.so';
import { WineWindowManager } from '../service/WineWindowManager';

const DOMAIN = 0x0000;
const TAG = 'DWA';

export default class DesktopAbility extends UIAbility {
  private toplevelId: number = 0;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      const params = want.parameters ?? {};
      this.toplevelId = Number(params.toplevelId) || 0;
      hilog.info(DOMAIN, TAG, '[DWA]  onCreate: tl=%{public}d', this.toplevelId);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '[DWA] ERR onCreate: %{public}s', JSON.stringify(e));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '[DWA] onWindowStageCreate tl=%{public}d', this.toplevelId);
    windowStage.loadContent('pages/DesktopPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '[DWA] loadContent FAILED: %{public}s', JSON.stringify(err));
      } else {
        hilog.info(DOMAIN, TAG, '[DWA] loadContent OK tl=%{public}d', this.toplevelId);
      }
    });
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '[DWA] onForeground tl=%{public}d', this.toplevelId);
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '[DWA] onBackground tl=%{public}d', this.toplevelId);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '[DWA] onDestroy tl=%{public}d', this.toplevelId);
    try {
      testNapi.destroyToplevel(this.toplevelId);
      WineWindowManager.getInstance().unregisterAbility(this.toplevelId);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '[DWA] ERR onDestroy: %{public}s', JSON.stringify(e));
    }
  }
}
