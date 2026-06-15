import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import testNapi from 'libentry.so';
import { WineWindowManager } from '../service/WineWindowManager';

const DOMAIN = 0x0000;
const TAG = 'WWA';

export default class WineWindowAbility extends UIAbility {
  private toplevelId: number = 0;
  private cleanedUp: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const params = want.parameters ?? {};
    this.toplevelId = Number(params.toplevelId) || 0;
    const title = params.title as string ?? '';

    hilog.info(DOMAIN, TAG, 'onCreate: toplevelId=%{public}d title="%{public}s" launchReason=%{public}d params=%{public}s',
      this.toplevelId, title, launchParam.launchReason, JSON.stringify(params));

    if (this.toplevelId === 0) {
      hilog.error(DOMAIN, TAG, 'onCreate: no toplevelId in want.parameters, terminating');
      this.context.terminateSelf();
      return;
    }

    // 检查是否在启动期间已经被销毁
    if (WineWindowManager.getInstance().isDestroyed(this.toplevelId)) {
      hilog.warn(DOMAIN, TAG, '#%{public}d already marked destroyed before onCreate, terminating', this.toplevelId);
      this.context.terminateSelf();
      return;
    }

    // 注册 context (供 WineWindowManager 调 terminateSelf)
    WineWindowManager.getInstance().registerAbility(this.toplevelId, this.context);

    hilog.info(DOMAIN, TAG, '#%{public}d onCreate ✓', this.toplevelId);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '#%{public}d onWindowStageCreate', this.toplevelId);

    // ★ 关键: 必须在 loadContent 之前设置 pending toplevel
    hilog.info(DOMAIN, TAG, '#%{public}d → setPendingToplevel', this.toplevelId);
    testNapi.setPendingToplevel(this.toplevelId);

    let mainWindow = windowStage.getMainWindowSync();
    hilog.info(DOMAIN, TAG, '#%{public}d mainWindow=%{public}s', this.toplevelId, mainWindow ? 'ok' : 'NULL');

    // 注册 Window 引用 (供 WineWindowManager 直接操作 resize/title)
    WineWindowManager.getInstance().registerWindow(this.toplevelId, mainWindow);

    // 应用已经在 WineWindowManager 中积压的 pending 事件 (resize/title)
    WineWindowManager.getInstance().flushPendingEvents(this.toplevelId);

    hilog.info(DOMAIN, TAG, '#%{public}d → loadContent pages/WineWindow...', this.toplevelId);
    windowStage.loadContent('pages/WineWindow', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, '#%{public}d loadContent FAILED: %{public}s',
          this.toplevelId, JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, '#%{public}d loadContent ✓', this.toplevelId);
    });

    // 监听窗口事件 (关闭 / 最小化 / 最大化等)
    mainWindow.on('windowEvent', (eventType: number) => {
      hilog.info(DOMAIN, TAG, '#%{public}d windowEvent type=%{public}d', this.toplevelId, eventType);
      if (eventType === window.WindowEventType.WINDOW_DESTROYED) {
        hilog.info(DOMAIN, TAG, '#%{public}d ▶ WINDOW_DESTROYED (user closed)', this.toplevelId);
        this.cleanup();
      }
    });

    hilog.info(DOMAIN, TAG, '#%{public}d onWindowStageCreate ✓', this.toplevelId);
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '#%{public}d onForeground', this.toplevelId);
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '#%{public}d onBackground', this.toplevelId);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '#%{public}d onDestroy (cleanedUp=%{public}s)',
      this.toplevelId, this.cleanedUp ? 'yes' : 'no');
    if (!this.cleanedUp) {
      this.cleanup();
    }
    hilog.info(DOMAIN, TAG, '#%{public}d onDestroy ✓', this.toplevelId);
  }

  private cleanup(): void {
    if (this.cleanedUp) return;
    this.cleanedUp = true;
    hilog.info(DOMAIN, TAG, '#%{public}d cleanup: sendToplevelClose + destroyToplevel + unregister', this.toplevelId);
    testNapi.sendToplevelClose(this.toplevelId);
    testNapi.destroyToplevel(this.toplevelId);
    WineWindowManager.getInstance().unregisterAbility(this.toplevelId);
  }
}
