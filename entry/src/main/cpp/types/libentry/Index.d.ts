export const startServer: (sockPath: string) => boolean;
export const launchClient: (exePath: string, argv: string[], sockPath: string, libPath: string) => number;
export const stopClient: () => void;
export const stopAll: () => void;
export const setStateCallback: (cb: (state: string) => void) => void;
export const setToplevelCallback: (cb: (id: number, event: string, data: string) => void) => void;
export const setPendingToplevel: (id: number) => void;
export const getCurrentToplevelId: () => number;
export const destroyToplevel: (id: number) => void;
export const sendToplevelClose: (id: number) => void;
export const runWineExe: (binDir: string, sockPath: string, libPath: string, exePath: string, argv?: string[], options?: { origin?: string }) => void;
export const checkWinePrefix: () => boolean;
export const resetWinePrefix: () => void;
export const setOutputSize: (w: number, h: number) => void;
export const setDisplayScale: (scale: number) => void;
export const setGraphicsBackend: (backend: string) => boolean;
export const setFramePresenter: (presenter: string) => boolean;
export const getGraphicsBackendState: () => {
  requested: string,
  active: string,
  backend: string,
  presenter: string,
  runtimeReady: boolean,
  guestReceiverPresent: boolean,
  guestReceiverRuntimeDir: string,
  guestReceiverMode: string,
  guestReceiverError: string,
  virglSocketReady: boolean,
  virglLibraryPresent: boolean,
  virglSmokeAttempted: boolean,
  virglSmokeSucceeded: boolean,
  fallbackActive: boolean,
  damageUploadActive: boolean,
  zeroCopyFramePath: boolean,
  nativeBufferInUse: boolean,
  runtimeDir: string,
  virglSocketPath: string,
  virglLibraryPath: string,
  frameTransportMode: string,
  virglSmokeError: string,
  lastError: string,
  caps: {
    virglAvailable: boolean,
    xcomponentEglAvailable: boolean,
    glCompositorAvailable: boolean,
    nativeBufferAvailable: boolean,
    eglImageAvailable: boolean,
    dmaBufAvailable: boolean
  },
  stats: {
    frameCount: bigint,
    cpuCopyBytes: bigint,
    surfaceCommitCount: bigint,
    surfaceCommitBytes: bigint,
    snapshotCopyCount: bigint,
    snapshotCopyBytes: bigint,
    glUploadBytes: bigint,
    skippedFrames: bigint,
    damagePixels: bigint,
    damageRectCount: bigint,
    mergedDamagePixels: bigint,
    fullSurfaceDamageCount: bigint,
    partialDamageCount: bigint,
    fullUploadFrames: bigint,
    partialUploadFrames: bigint,
    lastPresentMs: number,
    avgPresentMs: number,
    lastUploadMs: number,
    avgUploadMs: number
  }
};
export const setDesktopMode: (enabled: boolean) => void;
export const getDesktopRootId: () => number;
export const createRenderer: (toplevelId: number, surfaceId: BigInt) => void;
export const resizeRenderer: (toplevelId: number, width: number, height: number) => void;
export const destroyRenderer: (toplevelId: number) => void;
export const sendPointerEvent: (toplevelId: number, action: number, px: number, py: number, button: number) => void;
export const sendKeyEvent: (toplevelId: number, evdevCode: number, pressed: boolean) => void;
export const sendScrollEvent: (toplevelId: number, axis: number, value: number, scrollStep: number, px: number, py: number) => void;
export const notifyToplevelResize: (toplevelId: number, w: number, h: number) => void;
export const findToplevelAt: (x: number, y: number) => number;
export const raiseToplevel: (toplevelId: number) => void;
export const setToplevelVisible: (toplevelId: number, visible: boolean) => void;
export const getProcessList: () => Array<{pid: number, name: string, path: string, state: string}>;
export const killProcess: (pid: number) => boolean;
export const runMmapTests: () => string;
export const termRun: (cols: number, rows: number, cb: (data: ArrayBuffer) => void, onExit: () => void) => number;
export const termSend: (data: ArrayBuffer) => void;
export const termResize: (cols: number, rows: number) => void;
export const termClose: () => void;
