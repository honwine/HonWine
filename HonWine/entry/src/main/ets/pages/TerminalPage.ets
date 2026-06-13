import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { TermController } from '../model/TermController';

@Entry
@Component
struct TerminalPage {
  controller: TermController = new TermController(() => router.back());
  webviewController: WebviewController = this.controller.webviewController;

  aboutToAppear(): void {
    this.controller.load();
  }

  @Builder
  contextMenu() {
    Flex({ direction: FlexDirection.Column }) {
      MenuItem({ content: '复制' })
        .width('100%')
        .onClick(async () => {
          const sel = await this.webviewController.runJavaScript('exports.copy()');
          if (sel !== '""') {
            let text: string = JSON.parse(sel);
            const board = pasteboard.getSystemPasteboard();
            board.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
          }
        })
      MenuItem() {
        PasteButton({ buttonType: ButtonType.ROUNDED_RECTANGLE })
          .onClick(async (event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (PasteButtonOnClickResult.SUCCESS === result) {
              let board = pasteboard.getSystemPasteboard();
              const data = await board.getData();
              const text = data.getPrimaryText();
              const array = util.TextEncoder.create().encodeInto(text);
              const base64 = new util.Base64Helper().encodeToStringSync(array);
              this.webviewController.runJavaScript(`exports.paste(atob('${base64}'))`);
            }
          })
          .width('100%')
          .align(Alignment.Start)
          .backgroundColor('#292b2e')
      }
    }.width('160vp')
  }

  build() {
    Column() {
      Row() {
        Button('← 返回').onClick(() => router.back())
        Text('Terminal').fontColor(Color.White).margin({ left: 10 })
      }
      .width('100%').height(36).backgroundColor('#333').padding({ left: 8 })

      Web({ src: $rawfile('term.html'), controller: this.webviewController })
        .javaScriptProxy({
          object: this.controller,
          name: 'native',
          methodList: ['sendInput', 'resize', 'load'],
          controller: this.webviewController,
          asyncMethodList: [],
          permission: `{
            "javascriptProxyPermission": {
              "urlPermissionList": [
                { "scheme": "resource", "host": "rawfile", "port": "", "path": "" }
              ]
            }
          }`
        })
        .backgroundColor('#000')
        .layoutWeight(1)
        .bindContextMenu(this.contextMenu(), ResponseType.RightClick)
    }
    .width('100%').height('100%')
  }

  aboutToDisappear(): void {
    this.controller.shutdown();
  }
}