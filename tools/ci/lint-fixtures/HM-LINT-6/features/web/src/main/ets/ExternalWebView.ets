// HM-LINT-6 违反样例：第三方页容器注入了脚本代理（CSB-10）。
import { webview } from '@kit.ArkWeb';

@ComponentV2
export struct ExternalWebView {
  private controller: webview.WebviewController = new webview.WebviewController();

  build() {
    Web({ src: 'https://example.com/', controller: this.controller })
      .javaScriptProxy({ object: this, name: 'x', methodList: [], controller: this.controller })
  }
}
