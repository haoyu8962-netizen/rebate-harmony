// 只在 ohosTest：真实 TrustedWebView + 真实 ApiClient，HTTPS 文档由本机 scheme handler 应答。
// t1（D10-279 c，E01 合并门槛）：控制器改由 controllerFactory / onController 提供（Fx25Controllers），E01 经「当前控制器」读页面；
// 旧文档的写回攻击（pagehide / unload / setInterval）每次写完都发一个同步 /fx25-tick 回执，带文档号和页面时钟，用来判断卸下后还写没写。
// t5（D10-391 ②）：旧文档收到 A 时的回执改为不走网络——写 document.title（「fx25A|」+ 到目前为止收到的全部 data 的 JSON 数组），
// 测试在旧控制器解绑之前轮询 getTitle() 读到（observeTitle）。原先的同步 XHR /fx25-event 回执发在隔离中，被产品「隔离起子资源
// 一律本地 403」（NR1-01 ①，D10-391 ① 保留为普通 fetch / XHR 的纵深）拦下，永远到不了 handler（nr1 verify E01 红在 received=0）。
// 那个 XHR 保留，改作纵深探针：它必然发在隔离中（A 只在隔离起投递），记在 eventRequests，产品拦下时报 auth_isolated_request
// （diagnostics）。回执写完后页面忙等 300 ms（只拖住旧文档自己的脚本，产品对 A 的期限是 15 s），让 title 的变化在旧 Web 下树前
// 一定能被 2 ms 的轮询读到。
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { ApiRequest, ApiResult, FileSlot, FileTrustedAuthJournal, SessionTokenSet, TransportRequest, TransportResponse } from 'core';
import { TrustedWebConfig } from 'web';
import { Fx25AuthWiring } from './Fx25AuthWiring';
import { Fx25Controllers, fx25Respond } from './Fx25Controllers';
import { Fx25NetworkRig, Fx25BridgeState, envelope, tokenPair } from './Fx25TestPorts';

export const FX25_URL: string = 'https://h5.example.test/fx25-device';
const TICK: string = 'https://h5.example.test/fx25-tick?';

/** 旧文档写回攻击的一次回执：哪份文档（window.fx25Document）、页面时钟（Date.now）、写的标签。 */
export class Fx25Tick {
  readonly doc: number;
  readonly at: number;
  readonly tag: string;

  constructor(doc: number, at: number, tag: string) {
    this.doc = doc;
    this.at = at;
    this.tag = tag;
  }
}

function encode(text: string): ArrayBuffer {
  return new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer;
}

function query(url: string, key: string): string {
  const start: number = url.indexOf(key + '=');
  if (start < 0) {
    return '';
  }
  const rest: string = url.substring(start + key.length + 1);
  const end: number = rest.indexOf('&');
  return decodeURIComponent(end < 0 ? rest : rest.substring(0, end));
}

export class Fx25DeviceRig {
  static readonly shared: Fx25DeviceRig = new Fx25DeviceRig();
  readonly network: Fx25NetworkRig = new Fx25NetworkRig(new SessionTokenSet('device-access-a', 'device-refresh-a', 'full', 'user-a', 'epoch-a'));
  private trustedConfig: TrustedWebConfig | null = null;
  /** 旧文档收到的 A（每条是 data 的 JSON）：从旧文档的 document.title 读（observeTitle），不走网络。 */
  readonly received: string[] = [];
  /** 旧文档在收到 A 时发的同步 XHR /fx25-event（隔离中，应被产品拦下，一条都不该到这里）。 */
  readonly eventRequests: string[] = [];
  /** 产品的诊断事件（TrustedWebConfig.onDiagnostic）。 */
  readonly diagnostics: string[] = [];
  readonly ticks: Fx25Tick[] = [];
  readonly handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  readonly controllers: Fx25Controllers;
  documents: number = 0;
  firstLoaded: boolean = false;

  constructor() {
    this.controllers = new Fx25Controllers(this.handler);
    this.handler.onRequestStart((request: webview.WebSchemeHandlerRequest,
      output: webview.WebResourceHandler): boolean => {
      const url: string = request.getRequestUrl();
      // t2：没认出的请求（如 favicon）回 404 + 非空正文。原先回 200 + 空串：TextEncoder.encodeInto('') 在设备上返回 undefined，
      // 取 .buffer 抛错，scheme handler 解析失败后进程 SIGSEGV（App died）。
      let body: string = 'miss';
      let status: number = 404;
      let mime: string = 'text/plain';
      if (url.indexOf('https://h5.example.test/fx25-event?payload=') === 0) {
        this.eventRequests.push(decodeURIComponent(url.substring(url.indexOf('payload=') + 8)));
        body = 'recorded';
        status = 200;
      } else if (url.indexOf(TICK) === 0) {
        this.ticks.push(new Fx25Tick(Number(query(url, 'doc')), Number(query(url, 'at')), query(url, 'tag')));
        body = 'tick';
        status = 200;
      } else if (url === FX25_URL) {
        this.documents++;
        status = 200;
        mime = 'text/html';
        body = '<!doctype html><meta charset="utf-8"><title>FX25</title><script>' +
          'window.fx25Document=' + this.documents + ';' +
          'window.__REBATE_BRIDGE__.subscribe(function(m){if(m.event!=="auth.changed")return;' +
          // t5：回执写 document.title（不走网络），测试在解绑前读到；不用 storage 偷存结果。
          'var d=JSON.stringify(m.data);window.fx25Received=window.fx25Received||[];window.fx25Received.push(d);' +
          'document.title="fx25A|"+JSON.stringify(window.fx25Received);' +
          // 纵深探针：隔离中的普通同步 XHR，产品应回本地 403（到不了 handler）。
          'try{var x=new XMLHttpRequest();x.open("GET","/fx25-event?payload="+encodeURIComponent(d),false);x.send();}catch(e){}' +
          'var u=Date.now()+300;while(Date.now()<u){}});' +
          'window.fx25Ready=true;</script>';
      }
      fx25Respond(output, url, status, mime, body, encode);
      // 全部请求均本机应答，不回退到网络。
      return true;
    });
  }

  // shared 会在测试 Ability 启动前创建；拿到真实沙盒目录后才接生产工厂，避免缓存缺配置的错误页。
  initialize(filesDir: string): void {
    if (this.trustedConfig !== null) return;
    const pending: FileTrustedAuthJournal = new FileTrustedAuthJournal(
      FileSlot.at(filesDir, 'fx25_e01_trusted_web.pending'));
    // v7：不再 import entry/src/main 的 AppBridge（测试包编不出，见 Fx25AuthWiring 文件头）；切号接线与 AppBridge 逐项相同。
    const config: TrustedWebConfig = Fx25AuthWiring.trustedConfig(FX25_URL, new Fx25BridgeState(),
      this.network.client, this.network.tokens, pending, null);
    this.controllers.wire(config);
    config.onDiagnostic = (kind: string): void => {
      this.diagnostics.push(kind);
    };
    this.trustedConfig = config;
  }

  /**
   * t5：读一次 controller 当前文档的 title；是 A 回执（「fx25A|」+ JSON 数组）且比已读到的多，就整份换成它（数组只增不减，最后
   * 一次读到的就是旧文档收到的全部 A）。控制器已解绑 / 不是回执时不动。
   */
  observeTitle(controller: webview.WebviewController): void {
    let title: string = '';
    try {
      title = controller.getTitle();
    } catch (e) {
      return;
    }
    if (!title.startsWith('fx25A|')) {
      return;
    }
    try {
      const all: string[] = JSON.parse(title.substring(6)) as string[];
      if (all.length > this.received.length) {
        this.received.splice(0, this.received.length);
        for (const one of all) {
          this.received.push(one);
        }
        console.info('FX25T5 e01 title receipt count=' + all.length + ' at=' + Date.now() + ' data=' + JSON.stringify(all));
      }
    } catch (e) {
      console.info('FX25T5 e01 title unparsable: ' + title);
    }
  }

  get config(): TrustedWebConfig {
    const config: TrustedWebConfig | null = this.trustedConfig;
    if (config === null) throw new Error('FX25 test Ability has not initialized trusted storage');
    return config;
  }

  get controller(): webview.WebviewController {
    return this.controllers.controller();
  }

  /**
   * 第一份文档：Web 自己的 src 在 scheme handler 装上之前就发出了，测试在第一个控制器挂上之后自己再加载一次入口（只用于布置；
   * 切号之后的入口加载全部由产品在新控制器上发起，handler 已在 onController 里装好）。
   */
  tryAttach(): boolean {
    if (this.firstLoaded) {
      return true;
    }
    const current: webview.WebviewController | null = this.controllers.current;
    if (current === null) {
      return false;
    }
    try {
      current.loadUrl(FX25_URL);
      this.firstLoaded = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  async switchAccount(): Promise<ApiResult> {
    this.network.server.handler = (_request: TransportRequest): Promise<TransportResponse> => Promise.resolve(
      envelope(0, '{"user_id":"user-b","is_new_user":false,"tokens":' +
        tokenPair('device-access-b', 'device-refresh-b', 'full') + '}'));
    return this.network.client.request(new ApiRequest('loginBySms', {}, '', '{"phone":"13800138000","code":"123456"}'));
  }
}
