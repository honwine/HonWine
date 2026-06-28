import { OH2EVDEV } from '../common/KeyMap';
import { mapMouseButton } from '../common/MouseMap';
import { GameSession } from './GameSession';

export type VpToPx = (value: number) => number;

export class InputBridge {
  private readonly session: GameSession = GameSession.getInstance();

  onMouseEventForToplevel(toplevelId: number, event: MouseEvent, vpToPx: VpToPx): void {
    if (toplevelId <= 0) return;
    const px = vpToPx(event.x);
    const py = vpToPx(event.y);
    const btn = mapMouseButton(event.button);
    this.session.sendPointerEvent(toplevelId, event.action, px, py, btn);
  }

  onAxisEventForToplevel(toplevelId: number, event: AxisEvent | undefined, vpToPx: VpToPx): void {
    if (toplevelId <= 0 || !event) return;
    const px = vpToPx(event.x);
    const py = vpToPx(event.y);
    const vert = event.getVerticalAxisValue();
    const horiz = event.getHorizontalAxisValue();
    const step = event.scrollStep ?? 0;
    if (vert !== 0) this.session.sendScrollEvent(toplevelId, 0, vert, step, px, py);
    if (horiz !== 0) this.session.sendScrollEvent(toplevelId, 1, horiz, step, px, py);
  }

  onKeyEventForToplevel(toplevelId: number, event: KeyEvent): void {
    if (toplevelId <= 0) return;
    event.stopPropagation();
    const evdevCode = OH2EVDEV[event.keyCode] ?? 0;
    if (evdevCode <= 0) return;
    this.session.sendKeyEvent(toplevelId, evdevCode, event.type === KeyType.Down);
  }

  onTouchEventForDesktop(event: TouchEvent, vpToPx: VpToPx): void {
    const touch = event.changedTouches[0];
    if (!touch) return;

    const hostPx = Math.round(vpToPx(touch.x));
    const hostPy = Math.round(vpToPx(touch.y));
    const toplevelId = this.session.findToplevelAtHostPx(hostPx, hostPy);
    if (toplevelId <= 0) return;

    if (event.type === TouchType.Down) {
      this.session.raiseToplevel(toplevelId);
      this.session.sendPointerEvent(toplevelId, MouseAction.Press, hostPx, hostPy, 0x110);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.session.sendPointerEvent(toplevelId, MouseAction.Release, hostPx, hostPy, 0x110);
    }
  }

  onAxisEventForDesktop(event: AxisEvent | undefined, vpToPx: VpToPx): void {
    if (!event) return;
    const hostPx = Math.round(vpToPx(event.x));
    const hostPy = Math.round(vpToPx(event.y));
    const toplevelId = this.session.findToplevelAtHostPx(hostPx, hostPy);
    if (toplevelId <= 0) return;

    const vert = event.getVerticalAxisValue();
    const horiz = event.getHorizontalAxisValue();
    const step = event.scrollStep ?? 0;
    if (vert !== 0) this.session.sendScrollEvent(toplevelId, 0, vert, step, hostPx, hostPy);
    if (horiz !== 0) this.session.sendScrollEvent(toplevelId, 1, horiz, step, hostPx, hostPy);
  }

  onKeyEventForDesktop(rootToplevelId: number, event: KeyEvent): void {
    if (rootToplevelId <= 0) return;
    event.stopPropagation();
    const evdevCode = OH2EVDEV[event.keyCode] ?? 0;
    if (evdevCode <= 0) return;
    this.session.sendKeyEvent(rootToplevelId, evdevCode, event.type === KeyType.Down);
  }
}
