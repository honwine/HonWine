import testNapi from 'libentry.so';
import { WineWindowManager } from './WineWindowManager';

export enum ScaleMode {
  Fit = 'fit',
  Fill = 'fill',
  Stretch = 'stretch',
  IntegerScale = 'integer',
  Original = 'original'
}

export interface DisplayConfig {
  guestWidth: number;
  guestHeight: number;
  hostWidth: number;
  hostHeight: number;
  dpr: number;
  scale: number;
  scaleMode: ScaleMode;
}

export class GameSession {
  private static instance: GameSession | null = null;

  static getInstance(): GameSession {
    if (!GameSession.instance) {
      GameSession.instance = new GameSession();
    }
    return GameSession.instance;
  }

  getCurrentToplevelId(): number {
    return testNapi.getCurrentToplevelId() as number;
  }

  getEffectiveScale(): number {
    const scale = WineWindowManager.getInstance().getEffectiveScale();
    return scale > 0 ? scale : 2.0;
  }

  createRenderer(toplevelId: number, surfaceId: string): void {
    testNapi.createRenderer(toplevelId, BigInt(surfaceId));
  }

  destroyRenderer(toplevelId: number): void {
    testNapi.destroyRenderer(toplevelId);
  }

  resize(toplevelId: number, surfaceWidth: number, surfaceHeight: number): DisplayConfig {
    const scale = this.getEffectiveScale();
    const guestWidth = Math.round(surfaceWidth / scale);
    const guestHeight = Math.round(surfaceHeight / scale);

    testNapi.resizeRenderer(toplevelId, surfaceWidth, surfaceHeight);
    testNapi.notifyToplevelResize(toplevelId, guestWidth, guestHeight);

    return {
      guestWidth,
      guestHeight,
      hostWidth: surfaceWidth,
      hostHeight: surfaceHeight,
      dpr: 1.0,
      scale,
      scaleMode: ScaleMode.Fit
    };
  }

  sendPointerEvent(toplevelId: number, action: number, px: number, py: number, button: number): void {
    testNapi.sendPointerEvent(toplevelId, action, px, py, button);
  }

  sendKeyEvent(toplevelId: number, evdevCode: number, pressed: boolean): void {
    testNapi.sendKeyEvent(toplevelId, evdevCode, pressed);
  }

  sendScrollEvent(toplevelId: number, axis: number, value: number, scrollStep: number, px: number, py: number): void {
    testNapi.sendScrollEvent(toplevelId, axis, value, scrollStep, px, py);
  }

  raiseToplevel(toplevelId: number): void {
    testNapi.raiseToplevel(toplevelId);
  }

  findToplevelAtHostPx(hostPx: number, hostPy: number): number {
    const scale = this.getEffectiveScale();
    return testNapi.findToplevelAt(Math.round(hostPx / scale), Math.round(hostPy / scale)) as number;
  }

  getGraphicsStatus() {
    return testNapi.getGraphicsBackendState();
  }
}
