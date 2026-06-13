import { hilog } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import testNapi from 'libentry.so';

const DOMAIN = 0x0000;
const SOCK = '/data/storage/el2/base/files/wine-wayland';
const WINE_BIN = '/data/service/hnp/winebox.org/winebox_0.1.0/opt/winebox';
const WINE_LIB = `${WINE_BIN}/bin/x86_64-unix`;

@Entry
@Component
struct Index {
  @State message: string = 'Wine for HarmonyOS';
  @State state: string = 'idel';
  controller: XComponentController = new XComponentController();

  aboutToAppear(): void {
    testNapi.setStateCallback((s: string) => {
      hilog.info(DOMAIN, 'wine', 'state: %{public}s', s);
      this.state = s;
    });
  }

  // 启动 Wayland compositor + Wine
  startWine = () => {
    this.message = '启动 Wayland compositor...';
    const ok: boolean = testNapi.startServer(SOCK);
    hilog.info(DOMAIN, 'wine', 'wayland server: %{public}s', ok ? 'OK' : 'FAIL');
    if (!ok) {
      this.message = 'Wayland compositor 启动失败';
      return;
    }

    this.message = '启动 Wine...';
    const pid: number = testNapi.launchClient(
      `${WINE_BIN}/bin/box64`,
      [`${WINE_BIN}/bin/box64`, `${WINE_BIN}/bin/wine`, `${WINE_BIN}/bin/notepad.exe`],
      SOCK,
      `${WINE_BIN}/bin:${WINE_LIB}`
    );
    hilog.info(DOMAIN, 'wine', 'wine pid: %{public}d', pid);
    if (pid <= 0) {
      this.message = 'Wine 启动失败';
      return;
    }
    this.message = `Wine running, pid=${pid}`;
  }

  build() {
    Column() {
      Text(this.message)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 10 })

      Text(`状态: ${this.state}`)
        .fontSize(14)
        .fontColor('#888')
        .margin({ bottom: 20 })

      Button('启动 Wine')
        .onClick(this.startWine)
        .margin({ bottom: 10 })

      Button('打开终端')
        .onClick(() => router.pushUrl({ url: 'pages/TerminalPage' }))
        .margin({ bottom: 10 })

      Button('mmap 权限测试')
        .onClick(() => {
          const r: string = testNapi.runMmapTests();
          hilog.info(DOMAIN, 'wine', 'mmap test result:\n%{public}s', r);
          this.message = 'mmap 测试完成, 查看 hilog';
        })
        .margin({ bottom: 20 })

      // XComponent — 承载 EGL/GLES 渲染
      XComponent({ id: 'wine-xc', type: XComponentType.SURFACE, controller: this.controller, libraryname: 'entry' })
        .width('100%')
        .height('60%')
        .backgroundColor('#000')
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .justifyContent(FlexAlign.Center)
  }
}
