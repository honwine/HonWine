import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';
import { WineWindowManager } from '../service/WineWindowManager';
import { OH2EVDEV } from '../common/KeyMap';
import { mapMouseButton } from '../common/MouseMap';

const DOMAIN = 0x0000;

class DesktopController extends XComponentController {
  onSurfaceCreated(surfaceId: string): void {
    const rootId = WineWindowManager.getInstance().getDesktopRootId();
    if (rootId > 0) {
      try { testNapi.createRenderer(rootId, BigInt(surfaceId)); } catch (_) {}
    }
  }
  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    const rootId = WineWindowManager.getInstance().getDesktopRootId();
    if (rootId > 0) {
      try {
        testNapi.resizeRenderer(rootId, rect.surfaceWidth, rect.surfaceHeight);
        const s = 2.0;
        testNapi.notifyToplevelResize(rootId,
          Math.round(rect.surfaceWidth / s), Math.round(rect.surfaceHeight / s));
      } catch (_) {}
    }
  }
  onSurfaceDestroyed(_s: string): void {
    const rootId = WineWindowManager.getInstance().getDesktopRootId();
    if (rootId > 0) {
      try { testNapi.destroyRenderer(rootId); } catch (_) {}
    }
  }
}

@Entry
@Component
struct DesktopPage {
  controller: DesktopController = new DesktopController();

  build() {
    Stack() {
      XComponent({
        id: 'wine_desktop_xc',
        type: XComponentType.SURFACE,
        controller: this.controller
      }).width('100%').height('100%').backgroundColor('#000')
    }
    .width('100%').height('100%').backgroundColor('#000')
    .focusable(true).defaultFocus(true)

    .onMouse((ev: MouseEvent) => {
      const rootId = WineWindowManager.getInstance().getDesktopRootId();
      if (rootId <= 0) return;
      const px = vp2px(ev.x);
      const py = vp2px(ev.y);
      testNapi.sendPointerEvent(rootId, ev.action, px, py, mapMouseButton(ev.button));
    })

    .onKeyEvent((ev: KeyEvent) => {
      const rootId = WineWindowManager.getInstance().getDesktopRootId();
      if (rootId <= 0) return;
      ev.stopPropagation();
      const code = OH2EVDEV[ev.keyCode] ?? 0;
      if (code <= 0) return;
      testNapi.sendKeyEvent(rootId, code, ev.type === KeyType.Down);
    })

    .onAxisEvent((ev?: AxisEvent) => {
      const rootId = WineWindowManager.getInstance().getDesktopRootId();
      if (rootId <= 0 || !ev) return;
      const px = vp2px(ev.x);
      const py = vp2px(ev.y);
      const vert = ev.getVerticalAxisValue();
      const horiz = ev.getHorizontalAxisValue();
      const step = ev.scrollStep ?? 0;
      if (vert !== 0) testNapi.sendScrollEvent(rootId, 0, vert, step, px, py);
      if (horiz !== 0) testNapi.sendScrollEvent(rootId, 1, horiz, step, px, py);
    })
  }
}
