import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameSession } from '../service/GameSession';
import { InputBridge } from '../service/InputBridge';

const DOMAIN = 0x0000;

// 自定义 XComponentController: 通过 surfaceId 管理 XComponent 生命周期
// 不再使用 libraryname='entry', 从根本上消除多窗口 XComponent exports 冲突
class WineXComponentController extends XComponentController {
  toplevelId: number = 0;
  private readonly session: GameSession = GameSession.getInstance();

  onSurfaceCreated(surfaceId: string): void {
    hilog.info(DOMAIN, 'WineWindow', '[Ctrl] onSurfaceCreated tl=%{public}d surfaceId=%{public}s',
      this.toplevelId, surfaceId);
    try {
      this.session.createRenderer(this.toplevelId, surfaceId);
    } catch (e) {
      hilog.error(DOMAIN, 'WineWindow', 'ERR onSurfaceCreated createRenderer: %{public}s', JSON.stringify(e));
    }
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    hilog.info(DOMAIN, 'WineWindow', '[Ctrl] onSurfaceChanged tl=%{public}d surfaceId=%{public}s rect=%{public}s',
      this.toplevelId, surfaceId, JSON.stringify(rect));
    try {
      this.session.resize(this.toplevelId, rect.surfaceWidth, rect.surfaceHeight);
    } catch (e) {
      hilog.error(DOMAIN, 'WineWindow', 'ERR onSurfaceChanged resizeRenderer: %{public}s', JSON.stringify(e));
    }
  }

  onSurfaceDestroyed(surfaceId: string): void {
    hilog.info(DOMAIN, 'WineWindow', '[Ctrl] onSurfaceDestroyed tl=%{public}d surfaceId=%{public}s',
      this.toplevelId, surfaceId);
    try {
      this.session.destroyRenderer(this.toplevelId);
    } catch (e) {
      hilog.error(DOMAIN, 'WineWindow', 'ERR onSurfaceDestroyed destroyRenderer: %{public}s', JSON.stringify(e));
    }
  }
}

@Entry
@Component
struct WineWindow {
  controller: WineXComponentController = new WineXComponentController();
  session: GameSession = GameSession.getInstance();
  inputBridge: InputBridge = new InputBridge();
  @State toplevelId: number = 0;
  @State surfacePxW: number = 1;
  @State surfacePxH: number = 1;

  private vpToPx(value: number): number {
    return this.getUIContext().vp2px(value);
  }

  aboutToAppear(): void {
    // 关键: aboutToAppear 是 loadContent 的同步调用, 在下一个 Ability 覆盖前读取
    this.toplevelId = this.session.getCurrentToplevelId();
    // 同步设置给 controller: 保证 onSurfaceCreated 拿到正确的 toplevelId
    this.controller.toplevelId = this.toplevelId;
    hilog.info(DOMAIN, 'WineWindow', 'aboutToAppear tl=%{public}d', this.toplevelId);
  }

  build() {
    Stack() {
      XComponent({
        id: 'wine_sub_xc',
        type: XComponentType.SURFACE,
        controller: this.controller
        // 不再设置 libraryname: 使用自定义 Controller 的 surfaceId 回调
      })
        .width('100%')
        .height('100%')
        .backgroundColor('#000')
        .focusable(false)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000')
    .focusable(true)
    .defaultFocus(true)

    // -- 鼠标事件 --
    .onMouse((event: MouseEvent) => {
      if (this.toplevelId <= 0) return;
      if (event.action !== MouseAction.Move) {
        const px = this.vpToPx(event.x);
        const py = this.vpToPx(event.y);
        hilog.info(DOMAIN, 'CLICK-PIPE', '[ArkTS] MOUSE tl=%{public}d action=%{public}d px=(%{public}d,%{public}d) btn=0x%{public}x',
          this.toplevelId, event.action, Math.round(px), Math.round(py), event.button);
      }
      this.inputBridge.onMouseEventForToplevel(this.toplevelId, event, (value: number) => this.vpToPx(value));
    })

    // -- 键盘事件 --
    .onKeyEvent((event: KeyEvent) => {
      hilog.info(DOMAIN, 'KBD-PIPE', '[ArkTS] onKeyEvent keyCode=%{public}d type=%{public}d tl=%{public}d',
        event.keyCode, event.type, this.toplevelId);
      if (this.toplevelId <= 0) return;
      this.inputBridge.onKeyEventForToplevel(this.toplevelId, event);
    })

    // -- 滚轮事件 (轴事件, API 17+) --
    .onAxisEvent((event?: AxisEvent) => {
      this.inputBridge.onAxisEventForToplevel(this.toplevelId, event, (value: number) => this.vpToPx(value));
    })

    .onAreaChange((_o: Area, n: Area) => {
      this.surfacePxW = this.vpToPx(n.width as number);
      this.surfacePxH = this.vpToPx(n.height as number);
    })
  }
}
