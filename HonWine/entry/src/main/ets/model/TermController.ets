import util from '@ohos.util';
import { buffer } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import napi from 'libentry.so';

const DOMAIN = 0x0001;

interface Size {
  width: number,
  height: number
}

function stringToArrayBuffer(str: string, encoding: buffer.BufferEncoding = 'utf-8'): ArrayBuffer {
  const buf = buffer.from(str, encoding);
  return buf.buffer;
}

export class TermController {
  webviewController: webview.WebviewController
  close: () => void

  constructor(close: () => void) {
    this.webviewController = new webview.WebviewController()
    this.close = close;
  }

  shutdown() {
    hilog.info(DOMAIN, 'WebTerminal', 'close');
    napi.termClose()
  }

  sendInput(data: string): void {
    hilog.info(DOMAIN, 'WebTerminal', 'sendInput, data: %{public}s', data);
    let buf = stringToArrayBuffer(data, 'utf-8');
    napi.termSend(buf)
  }

  async resize(): Promise<void> {
    const s = await this.getSize();
    hilog.info(DOMAIN, 'WebTerminal', 'resize (%{public}d, %{public}d)', s.width, s.height)
    napi.termResize(s.width, s.height)
  }

  async load(): Promise<void> {
    hilog.info(DOMAIN, 'WebTerminal', 'load start')
    this.webviewController.runJavaScript('exports.setFocused(true)')
    const s: Size = await this.getSize();
    hilog.info(DOMAIN, 'WebTerminal', 'got size %{public}dx%{public}d', s.width, s.height)
    napi.termRun(s.width, s.height, (a: ArrayBuffer) => {
      hilog.info(DOMAIN, 'WebTerminal', 'onData len=%{public}d', a.byteLength)
      let enc = new util.Base64Helper().encodeToStringSync(new Uint8Array(a))
      this.webviewController.runJavaScript(`exports.write('${enc}')`)
    }, () => {
      hilog.info(DOMAIN, 'WebTerminal', 'onExit')
      this.close()
    })
  }

  private async getSize(): Promise<Size> {
    const ext = await this.webviewController.runJavaScriptExt('exports.getSize()');
    const arr = ext.getArray();
    return { width: arr[0] as number, height: arr[1] as number };
  }
}