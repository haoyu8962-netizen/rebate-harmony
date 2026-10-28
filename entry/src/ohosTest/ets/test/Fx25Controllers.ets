// 只在 ohosTest（F-X-25 t1）：可信容器的控制器端口（TrustedWebConfig.controllerFactory / onController，plan-teardown 附表 A）。
// 产品每要一个新控制器（第一次挂 Web、切号后的清理载体）都从 controllerFactory 拿；onController(c) 在 c 挂上（onControllerAttached）
// 之后、产品在它上面发起任何加载之前回调——这时装本机 scheme handler（SDK：setWebSchemeHandler 要求已挂上），之后的请求都由本机应答。
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { TrustedWebConfig } from 'web';

export const FX25_NOT_ATTACHED: number = 17100001;

export class Fx25Controllers {
  readonly made: webview.WebviewController[] = [];
  readonly reported: webview.WebviewController[] = [];
  current: webview.WebviewController | null = null;
  handlerErrors: number = 0;
  private readonly handler: webview.WebSchemeHandler;
  /** t6（D10-396，只 E02 用）：产品要新控制器时怎么造；缺省就是 new webview.WebviewController()。 */
  private readonly make: () => webview.WebviewController;

  constructor(handler: webview.WebSchemeHandler,
    make: () => webview.WebviewController = (): webview.WebviewController => new webview.WebviewController()) {
    this.handler = handler;
    this.make = make;
  }

  wire(config: TrustedWebConfig): void {
    config.controllerFactory = (): webview.WebviewController => {
      const made: webview.WebviewController = this.make();
      this.made.push(made);
      return made;
    };
    config.onController = (attached: webview.WebviewController): void => {
      this.reported.push(attached);
      this.current = attached;
      try {
        attached.setWebSchemeHandler('https', this.handler);
      } catch (e) {
        this.handlerErrors++;
      }
    };
  }

  controller(): webview.WebviewController {
    const current: webview.WebviewController | null = this.current;
    if (current === null) {
      throw new Error('FX25: no trusted controller attached yet');
    }
    return current;
  }

  /** 控制器已和 Web 解绑（任何调用抛 17100001）；其他错误不算。 */
  static detached(target: webview.WebviewController): boolean {
    try {
      target.getWebId();
      return false;
    } catch (e) {
      // t2：设备（emulator 6.0.0.48，API 20）上 webview 的 BusinessError.code 实际是字符串 "17100001"（hilog 里 JSON 为
      // {"code":"17100001"}），按数字严格相等永远是 false。按数值比。
      return Number((e as BusinessError).code) === FX25_NOT_ATTACHED;
    }
  }
}

/** 本机 scheme handler 的统一应答（全部请求本机应答，不回退到网络）。 */
export function fx25Respond(output: webview.WebResourceHandler, url: string, status: number, mime: string, body: string,
  encode: (text: string) => ArrayBuffer): void {
  const response: webview.WebSchemeHandlerResponse = new webview.WebSchemeHandlerResponse();
  // t2：不调 setUrl（重定向后的地址）：设成请求地址本身，ArkWeb 会把它当重定向一直跟到上限，主框架以 main_frame_error 结束
  // （设备上入口请求连续 20 次后报错，fx25Ready 永远读不到）。
  response.setStatus(status);
  response.setMimeType(mime);
  response.setEncoding('utf-8');
  output.didReceiveResponse(response);
  output.didReceiveResponseBody(encode(body));
  output.didFinish();
}
