import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { WineWindowManager } from '../service/WineWindowManager';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private applyBenchmarkParams(want: Want, source: string): void {
    const params = want.parameters ?? {};
    const mode = String(params['winehua.benchmark'] ?? params['benchmark'] ?? params['bench'] ?? '');
    const seconds = Number(params['winehua.benchmark.seconds'] ?? params['benchmarkSeconds'] ?? params['seconds'] ?? 12);
    const iterations = Number(params['winehua.benchmark.iterations'] ?? params['benchmarkIterations'] ?? params['iterations'] ?? 1);
    const presenter = String(params['winehua.benchmark.presenter'] ?? params['benchmarkPresenter'] ?? params['presenter'] ?? 'auto');
    const revision = Number(AppStorage.get<number>('winehua.benchmark.revision') ?? 0) + 1;

    AppStorage.setOrCreate('winehua.benchmark', mode);
    AppStorage.setOrCreate('winehua.benchmark.seconds', seconds);
    AppStorage.setOrCreate('winehua.benchmark.iterations', iterations);
    AppStorage.setOrCreate('winehua.benchmark.presenter', presenter);
    AppStorage.setOrCreate('winehua.benchmark.revision', revision);
    hilog.info(DOMAIN, 'testTag',
      '[Bench] %{public}s params=%{public}s parsed mode=%{public}s presenter=%{public}s seconds=%{public}d iterations=%{public}d revision=%{public}d',
      source, JSON.stringify(params), mode, presenter, seconds, iterations, revision);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    this.applyBenchmarkParams(want, 'onCreate');
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.applyBenchmarkParams(want, 'onNewWant');
    hilog.info(DOMAIN, 'testTag', 'Ability onNewWant launchReason=%{public}d', launchParam.launchReason);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 初始化多窗口管理器
    WineWindowManager.getInstance().init(windowStage, this.context);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // loadContent 成功后隐藏窗口装饰
      let mainWin = windowStage.getMainWindowSync();
      if (mainWin) {
        mainWin.setWindowDecorVisible(false);
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
