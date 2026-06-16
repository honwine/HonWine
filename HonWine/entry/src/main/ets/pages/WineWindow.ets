import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;

@Entry
@Component
struct WineWindow {
  controller: XComponentController = new XComponentController();
  @State toplevelId: number = 0;
  @State surfacePxW: number = 1;
  @State surfacePxH: number = 1;

  aboutToAppear(): void {
    this.toplevelId = testNapi.getCurrentToplevelId() as number;
    hilog.info(DOMAIN, 'WineWindow', ' aboutToAppear tl=%{public}d', this.toplevelId);
  }

  build() {
    Stack() {
      XComponent({
        id: 'wine_sub_xc',
        type: XComponentType.SURFACE,
        controller: this.controller,
        libraryname: 'entry'
      })
        .width('100%')
        .height('100%')
        .backgroundColor('#000')
        .onLoad(() => {
          hilog.info(DOMAIN, 'WineWindow', ' onLoad: calling initXComponent (post-Init)...');
          try {
            testNapi.initXComponent();
            hilog.info(DOMAIN, 'WineWindow', 'onLoad: initXComponent returned OK');
          } catch (e) {
            hilog.error(DOMAIN, 'WineWindow', 'ERR onLoad initXComponent EXCEPTION: %{public}s', JSON.stringify(e));
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000')
    .focusable(true)
    .defaultFocus(true)
    // -- 输入事件绑定在父 Stack 上 --
    //  HarmonyOS 自动把触控转为 Mouse 事件, 不需要同时监听 .onTouch
    // (否则同一点击触发两次: Touch + Mouse -> Wine 收到双重 PRESS/RELEASE)
    .onMouse((event: MouseEvent) => {
      if (this.toplevelId <= 0) return;
      //  vp2px: MouseEvent 坐标是 vp, 需要转 px 才能和 surface 物理尺寸对齐
      const px = vp2px(event.x);
      const py = vp2px(event.y);
      if (event.action !== MouseAction.Move) {
        hilog.info(DOMAIN, 'WineWindow', '[CLICK-PIPE]  [ArkTS-Mouse] tl=%{public}d action=%{public}d vp=(%{public}d,%{public}d) px=(%{public}d,%{public}d) btn=%{public}d', this.toplevelId, event.action, Math.round(event.x), Math.round(event.y), Math.round(px), Math.round(py), event.button);
      }
      testNapi.forwardMouseEvent(this.toplevelId, event.action, px, py, event.button);
    })
    .onKeyEvent((event: KeyEvent) => {
      if (this.toplevelId <= 0) return;
      event.stopPropagation();
      hilog.info(DOMAIN, 'WineWindow', '[CLICK-PIPE]  [ArkTS-Key] tl=%{public}d keyCode=%{public}d type=%{public}d', this.toplevelId, event.keyCode, event.type);
      testNapi.forwardKeyEvent(this.toplevelId, event.keyCode, event.type);
    })
    .onAreaChange((_o: Area, n: Area) => {
      this.surfacePxW = vp2px(n.width as number);
      this.surfacePxH = vp2px(n.height as number);
      hilog.info(DOMAIN, 'WineWindow', '[CLICK-PIPE]  [ArkTS-Area] tl=%{public}d surfacePx=%{public}dx%{public}d', this.toplevelId, this.surfacePxW, this.surfacePxH);
    })
  }
}
