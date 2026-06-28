import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameSession } from '../service/GameSession';
import { WineWindowManager } from '../service/WineWindowManager';
import { InputBridge } from '../service/InputBridge';

const DOMAIN = 0x0000;

class DesktopController extends XComponentController {
  private readonly session: GameSession = GameSession.getInstance();

  onSurfaceCreated(surfaceId: string): void {
    const rootId = WineWindowManager.getInstance().getDesktopRootId();
    hilog.info(DOMAIN, 'LIFE', '[XComp] onSurfaceCreated rootId=%{public}d surfaceId=%{public}s', rootId, surfaceId);
    if (rootId > 0) {
      try { this.session.createRenderer(rootId, surfaceId); } catch (_) {}
    }
  }
  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    const rootId = WineWindowManager.getInstance().getDesktopRootId();
    hilog.info(DOMAIN, 'LIFE', '[XComp] onSurfaceChanged rootId=%{public}d %{public}dx%{public}d', rootId, rect.surfaceWidth, rect.surfaceHeight);
    if (rootId > 0) {
      try {
        this.session.resize(rootId, rect.surfaceWidth, rect.surfaceHeight);
      } catch (_) {}
    }
  }
  onSurfaceDestroyed(_s: string): void {
    const rootId = WineWindowManager.getInstance().getDesktopRootId();
    hilog.warn(DOMAIN, 'LIFE', '[XComp] onSurfaceDestroyed rootId=%{public}d', rootId);
    if (rootId > 0) {
      try { this.session.destroyRenderer(rootId); } catch (_) {}
    }
  }
}

@Entry
@Component
struct DesktopPage {
  controller: DesktopController = new DesktopController();
  inputBridge: InputBridge = new InputBridge();

  private vpToPx(value: number): number {
    return this.getUIContext().vp2px(value);
  }

  build() {
    Stack() {
      XComponent({
        id: 'wine_desktop_xc',
        type: XComponentType.SURFACE,
        controller: this.controller
      }).width('100%').height('100%').backgroundColor('#000').focusable(false)
    }
    .width('100%').height('100%').backgroundColor('#000')
    .focusable(true).defaultFocus(true)

    .onTouch((ev: TouchEvent) => {
      try {
        this.inputBridge.onTouchEventForDesktop(ev, (value: number) => this.vpToPx(value));
      } catch (e) {
        hilog.error(DOMAIN, 'CLICK-PIPE', '[ArkTS] TOUCH handler exception: %{public}s', JSON.stringify(e));
      }
    })

    .onKeyEvent((ev: KeyEvent) => {
      const rootId = WineWindowManager.getInstance().getDesktopRootId();
      this.inputBridge.onKeyEventForDesktop(rootId, ev);
    })

    .onAxisEvent((ev?: AxisEvent) => {
      this.inputBridge.onAxisEventForDesktop(ev, (value: number) => this.vpToPx(value));
    })
  }
}
