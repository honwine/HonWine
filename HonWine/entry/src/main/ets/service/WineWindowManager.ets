import { common, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'WineWM';

export class WineWindowManager {
  private static instance: WineWindowManager | null = null;
  private windowStage: window.WindowStage | null = null;
  private mainWindow: window.Window | null = null;
  private uiAbilityContext: common.UIAbilityContext | null = null;
  // 设备显示密度 + 屏幕尺寸 (用于缩放)
  private displayScale: number = 1.0;
  private displayWidth: number = 1920;
  private displayHeight: number = 1080;

  // toplevelId → UIAbilityContext (用于 terminateSelf)
  private abilityContexts: Map<number, common.UIAbilityContext> = new Map();
  // toplevelId → window.Window (用于直接操作 resize/title)
  private windows: Map<number, window.Window> = new Map();
  // toplevelId → 已销毁标记 (用于竞态检测)
  private destroyed: Set<number> = new Set();
  // 正在启动中的 toplevel (防止重复 startAbility)
  private pendingStarts: Set<number> = new Set();
  // 窗口就绪前到达的 pending 事件
  private pendingEvents: Map<number, Array<[string, string]>> = new Map();

  static getInstance(): WineWindowManager {
    if (!WineWindowManager.instance) {
      WineWindowManager.instance = new WineWindowManager();
    }
    return WineWindowManager.instance;
  }

  getMainWindow(): window.Window | null {
    return this.mainWindow;
  }

  // ── dump 当前状态 (诊断用) ──
  dumpState(): void {
    hilog.info(DOMAIN, TAG, '[MW-DUMP] state: abilityCtx=%{public}d windows=%{public}d pendingStarts=%{public}d pendingEvents=%{public}d destroyed=%{public}d',
      this.abilityContexts.size, this.windows.size, this.pendingStarts.size,
      this.pendingEvents.size, this.destroyed.size);
    this.pendingStarts.forEach(id => {
      hilog.info(DOMAIN, TAG, '[MW-DUMP]   pendingStart: #%{public}d', id);
    });
    this.pendingEvents.forEach((events, id) => {
      hilog.info(DOMAIN, TAG, '[MW-DUMP]   pendingEvents #%{public}d: %{public}d items', id, events.length);
    });
    this.windows.forEach((_, id) => {
      hilog.info(DOMAIN, TAG, '[MW-DUMP]   active window: #%{public}d', id);
    });
  }

  async init(windowStage: window.WindowStage, abilityContext: common.UIAbilityContext): Promise<void> {
    this.windowStage = windowStage;
    this.mainWindow = windowStage.getMainWindowSync();
    this.uiAbilityContext = abilityContext;

    hilog.info(DOMAIN, TAG, '[MW] init: mainWindow=%{public}s ctx=%{public}s',
      this.mainWindow ? 'ok' : 'NULL', this.uiAbilityContext ? 'ok' : 'NULL');

    // 获取设备显示密度
    try {
      const d = display.getDefaultDisplaySync();
      this.displayScale = d.densityPixels;
      this.displayWidth = d.width;
      this.displayHeight = d.height;
      hilog.info(DOMAIN, TAG, '[MW] display %{public}dx%{public}d scale=%{public}s',
        this.displayWidth, this.displayHeight, this.displayScale.toFixed(2));
    } catch (_) {
      this.displayScale = 1.0;
      hilog.warn(DOMAIN, TAG, '[MW] display query failed, using scale=1.0');
    }

    hilog.info(DOMAIN, TAG, '[MW] registering toplevel callback...');
    testNapi.setToplevelCallback((id: number, event: string, data: string) => {
      hilog.info(DOMAIN, TAG, '[MW] ▶ cb toplevel #%{public}d event=%{public}s data=%{public}s',
        id, event, data);
      this.onToplevelEvent(id, event, data);
    });
    hilog.info(DOMAIN, TAG, '[MW] toplevel callback registered ✓');

    hilog.info(DOMAIN, TAG, '[MW] initialized scale=%{public}s display=%{public}dx%{public}d',
      this.displayScale.toFixed(2), this.displayWidth, this.displayHeight);
  }

  // ── WineWindowAbility 调用: 注册 / 注销 ──

  registerAbility(toplevelId: number, ctx: common.UIAbilityContext): void {
    this.abilityContexts.set(toplevelId, ctx);
    hilog.info(DOMAIN, TAG, '[MW] ◉ registerAbility #%{public}d (total=%{public}d)',
      toplevelId, this.abilityContexts.size);
  }

  registerWindow(toplevelId: number, win: window.Window): void {
    this.windows.set(toplevelId, win);
    hilog.info(DOMAIN, TAG, '[MW] ◉ registerWindow #%{public}d (total=%{public}d, pendingStarts=%{public}s)',
      toplevelId, this.windows.size, this.pendingStarts.has(toplevelId) ? 'yes' : 'no');
  }

  unregisterAbility(toplevelId: number): void {
    const hadCtx = this.abilityContexts.has(toplevelId);
    const hadWin = this.windows.has(toplevelId);
    const hadPend = this.pendingEvents.has(toplevelId);
    const hadStart = this.pendingStarts.has(toplevelId);
    this.abilityContexts.delete(toplevelId);
    this.windows.delete(toplevelId);
    this.pendingEvents.delete(toplevelId);
    this.pendingStarts.delete(toplevelId);
    hilog.info(DOMAIN, TAG, '[MW] ◉ unregisterAbility #%{public}d (hadCtx=%{public}s hadWin=%{public}s hadPend=%{public}s hadStart=%{public}s)',
      toplevelId, hadCtx ? 'yes' : 'no', hadWin ? 'yes' : 'no',
      hadPend ? 'yes' : 'no', hadStart ? 'yes' : 'no');
  }

  isDestroyed(toplevelId: number): boolean {
    const result = this.destroyed.has(toplevelId);
    if (result) {
      hilog.warn(DOMAIN, TAG, '[MW] isDestroyed #%{public}d = true', toplevelId);
    }
    return result;
  }

  // ── WineWindowAbility 在 onWindowStageCreate 中调用: 应用积压的事件 ──
  flushPendingEvents(toplevelId: number): void {
    const pending = this.pendingEvents.get(toplevelId);
    if (!pending || pending.length === 0) {
      hilog.info(DOMAIN, TAG, '[MW] flushPendingEvents #%{public}d: none', toplevelId);
      return;
    }
    this.pendingEvents.delete(toplevelId);

    hilog.info(DOMAIN, TAG, '[MW] ▶▶ flushPendingEvents #%{public}d: %{public}d items', toplevelId, pending.length);
    for (let i = 0; i < pending.length; i++) {
      hilog.info(DOMAIN, TAG, '[MW]   flush[%{public}d/%{public}d] event=%{public}s data=%{public}s',
        i + 1, pending.length, pending[i][0], pending[i][1]);
      this.applyEvent(toplevelId, pending[i][0], pending[i][1]);
    }
    hilog.info(DOMAIN, TAG, '[MW] flushPendingEvents #%{public}d done', toplevelId);
  }

  // ── toplevel 事件分发 ──
  private onToplevelEvent(id: number, event: string, data: string): void {
    hilog.info(DOMAIN, TAG, '[MW] onToplevelEvent #%{public}d event=%{public}s hasWindow=%{public}s',
      id, event, this.windows.has(id) ? 'yes' : 'no');

    switch (event) {
      case 'created':
        hilog.info(DOMAIN, TAG, '[MW] → startWineWindowAbility(#%{public}d)', id);
        this.startWineWindowAbility(id, data);
        break;
      case 'destroyed':
        hilog.info(DOMAIN, TAG, '[MW] → onToplevelDestroyed(#%{public}d)', id);
        this.onToplevelDestroyed(id);
        break;
      case 'title':
      case 'resize':
        if (this.windows.has(id)) {
          hilog.info(DOMAIN, TAG, '[MW] → applyEvent directly #%{public}d %{public}s', id, event);
          this.applyEvent(id, event, data);
        } else {
          hilog.info(DOMAIN, TAG, '[MW] → queue pending #%{public}d %{public}s (window not ready)', id, event);
          let q = this.pendingEvents.get(id);
          if (!q) { q = []; this.pendingEvents.set(id, q); }
          q.push([event, data]);
          hilog.info(DOMAIN, TAG, '[MW]   pending queue size now: %{public}d', q.length);
        }
        break;
      default:
        hilog.warn(DOMAIN, TAG, '[MW] unknown event #%{public}d %{public}s', id, event);
        break;
    }
  }

  // ── apply 单个事件到 window.Window ──
  private applyEvent(toplevelId: number, event: string, data: string): void {
    const win = this.windows.get(toplevelId);
    if (!win) {
      hilog.warn(DOMAIN, TAG, '[MW] applyEvent #%{public}d: window NOT FOUND (unregistered?)', toplevelId);
      return;
    }

    switch (event) {
      case 'title':
        try {
          const obj: Record<string, string | number> = JSON.parse(data) as Record<string, string | number>;
          if (obj.title) {
            hilog.info(DOMAIN, TAG, '[MW] setWindowTitle #%{public}d → "%{public}s"', toplevelId, obj.title as string);
            win.setWindowTitle(obj.title as string);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, '[MW] applyEvent title parse error: %{public}s', JSON.stringify(e));
        }
        break;
      case 'resize':
        try {
          const obj: Record<string, string | number> = JSON.parse(data) as Record<string, string | number>;
          const w = obj.w as number;
          const h = obj.h as number;
          if (w && h) {
            const scaledW = Math.round(w * this.displayScale);
            const scaledH = Math.round(h * this.displayScale);
            hilog.info(DOMAIN, TAG, '[MW] resize #%{public}d: wine=%{public}dx%{public}d → scaled=%{public}dx%{public}d (scale=%{public}s)',
              toplevelId, w, h, scaledW, scaledH, this.displayScale.toFixed(2));
            win.resize(scaledW, scaledH);
          }
        } catch (e) {
          hilog.warn(DOMAIN, TAG, '[MW] applyEvent resize parse error: %{public}s', JSON.stringify(e));
        }
        break;
    }
  }

  // ── startAbility 启动 multiton 实例 ──
  private startWineWindowAbility(id: number, data: string): void {
    if (this.pendingStarts.has(id)) {
      hilog.warn(DOMAIN, TAG, '[MW] startWineWindowAbility #%{public}d: already in flight, skip', id);
      return;
    }
    this.pendingStarts.add(id);
    hilog.info(DOMAIN, TAG, '[MW] startWineWindowAbility #%{public}d: pendingStarts now %{public}d',
      id, this.pendingStarts.size);

    // 解析初始参数
    let title = '';
    try {
      const obj: Record<string, string | number> = JSON.parse(data) as Record<string, string | number>;
      if (obj.title) title = obj.title as string;
    } catch (_) { /* use defaults */ }

    hilog.info(DOMAIN, TAG, '[MW] ▶▶▶ startAbility(WineWindowAbility) #%{public}d title="%{public}s"',
      id, title);

    if (!this.uiAbilityContext) {
      hilog.error(DOMAIN, TAG, '[MW] FATAL: no uiAbilityContext, cannot start ability');
      this.pendingStarts.delete(id);
      return;
    }

    const want: Want = {
      bundleName: 'app.hackeris.honwine',
      abilityName: 'WineWindowAbility',
      parameters: { toplevelId: id, title: title }
    };

    hilog.info(DOMAIN, TAG, '[MW] startAbility want: bundle=%{public}s ability=%{public}s params=%{public}s',
      want.bundleName ?? '', want.abilityName ?? '', JSON.stringify(want.parameters));

    this.uiAbilityContext.startAbility(want).then(() => {
      hilog.info(DOMAIN, TAG, '[MW] ✓ startAbility #%{public}d resolved (AMS accepted)', id);
      this.pendingStarts.delete(id);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, '[MW] ✗ startAbility #%{public}d REJECTED: %{public}s',
        id, JSON.stringify(err));
      this.pendingStarts.delete(id);
      // 通知 Wine 窗口创建失败
      hilog.info(DOMAIN, TAG, '[MW] → sendToplevelClose #%{public}d (fail recovery)', id);
      testNapi.sendToplevelClose(id);
    });
  }

  // ── Wine toplevel destroyed → terminateSelf ──
  private onToplevelDestroyed(id: number): void {
    hilog.info(DOMAIN, TAG, '[MW] onToplevelDestroyed #%{public}d', id);
    this.destroyed.add(id);

    // 如果 ability 侧已经清理过 (用户先关窗), 跳过
    if (!this.abilityContexts.has(id) && !this.pendingStarts.has(id)) {
      hilog.info(DOMAIN, TAG, '[MW] onToplevelDestroyed #%{public}d: already cleaned up by ability, skip', id);
      return;
    }

    // 清理 C++ renderer
    hilog.info(DOMAIN, TAG, '[MW] → destroyToplevel #%{public}d', id);
    testNapi.destroyToplevel(id);

    const ctx = this.abilityContexts.get(id);
    if (ctx) {
      hilog.info(DOMAIN, TAG, '[MW] → terminateSelf #%{public}d', id);
      ctx.terminateSelf().catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, '[MW] ✗ terminateSelf #%{public}d failed: %{public}s',
          id, JSON.stringify(err));
      });
    }
    this.unregisterAbility(id);
    hilog.info(DOMAIN, TAG, '[MW] onToplevelDestroyed #%{public}d done', id);
  }
}
