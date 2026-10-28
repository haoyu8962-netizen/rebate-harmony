// 只在 ohosTest（F-X-25 t4，E02 改写，评审新 r1 NR1-02）：可信容器与隐私模式的 ExternalWebView 同屏，两边各有一份真实的 ArkWeb
// HTTP 缓存。原 E02 只挂外部页、不挂可信页：新方案下没有可信 Web 时产品一项都不清（延期），「外部缓存还在」必然成立，换成全局
// removeAllCache(true) 也照样绿（空跑）。现在产品真的要走「拆 → 载体 → 实例 removeCache(true)」：
//   正向：可信页在清理前种下、读两次都由缓存供给的资源，清理后在新文档里读到 MISS（可信 HTTP 缓存真被清了）；
//   I6：同屏外部 incognito 页的缓存仍命中；阳性对照：全局 removeAllCache(true) 之后外部页读到 MISS。
// t6（D10-396 ②）：产品切号不再清 HTTP 缓存（removeCache 不论经哪个控制器都清全应用所有 Web 的缓存，SDK 6.1.1 文档 + t5 设备取证）。
//   E02 改为：切号流程不调用任何缓存清理（产品经 controllerFactory 拿到的每个可信控制器都是 Fx25SpyController，记下 removeCache 调用；
//   静态 removeAllCache 由 Node V43 守，效果上由下面的外部页读法守），同屏外部 incognito 页缓存仍命中；正向对照：同一读法切号前
//   未清时读到 HIT、显式全局清缓存后读到 MISS。原「可信页清理后读到 MISS」作废（t5 归因对照证明它空跑，且现在本来就不清）。
// 缓存的布置与读法同 t2 的 Fx25ExternalCacheRig：本机 handler 只在布置那一次回带 Cache-Control: max-age 的标记脚本，之后一律回
// no-store 的「MISS」脚本；所以读到标记值 = 由 ArkWeb 缓存供给，读到 MISS = 请求到了「网络」。
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { ExternalNavPolicy, ExternalPageOptions, FileSlot, FileTrustedAuthJournal, SessionTokenSet } from 'core';
import { ExternalWebConfig, TrustedWebConfig } from 'web';
import { Fx25AuthWiring } from './Fx25AuthWiring';
import { Fx25Controllers } from './Fx25Controllers';
import { Fx25NetworkRig, Fx25BridgeState } from './Fx25TestPorts';

export const FX25_E02_TRUSTED: string = 'https://h5.example.test/fx25-e02';
export const FX25_E02_EXTERNAL: string = 'https://external.example.test/fx25-e02';
const TRUSTED_ASSET: string = 'https://h5.example.test/fx25-e02-asset.js';
const EXTERNAL_ASSET: string = 'https://external.example.test/fx25-e02-asset.js';
export const FX25_E02_TRUSTED_MARK: string = 'trusted-cache-response-t4';
export const FX25_E02_EXTERNAL_MARK: string = 'external-cache-response-t4';

function encode(text: string): ArrayBuffer {
  return new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer;
}

/** 一边（可信 / 外部）的本机应答：入口页 + 只布置一次可缓存的资源。 */
class Fx25CacheSide {
  readonly handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  readonly page: string;
  readonly asset: string;
  readonly mark: string;
  readonly ready: string;
  pageLoads: number = 0;
  assetRequests: number = 0;
  private serveAsset: boolean = false;

  constructor(page: string, asset: string, mark: string, ready: string) {
    this.page = page;
    this.asset = asset;
    this.mark = mark;
    this.ready = ready;
    this.handler.onRequestStart((request: webview.WebSchemeHandlerRequest, output: webview.WebResourceHandler): boolean => {
      const url: string = request.getRequestUrl();
      const response: webview.WebSchemeHandlerResponse = new webview.WebSchemeHandlerResponse();
      // 不调 setUrl（t2：设成请求地址本身会自我重定向到上限）。
      let body: string = 'miss';
      if (url === this.page) {
        this.pageLoads++;
        response.setStatus(200);
        response.setMimeType('text/html');
        body = '<!doctype html><title>FX25 E02</title><script>window.fx25Document=' + this.pageLoads + ';window.' + this.ready +
          '=true;</script>';
      } else if (url === this.asset) {
        this.assetRequests++;
        response.setStatus(200);
        response.setMimeType('application/javascript');
        if (this.serveAsset) {
          this.serveAsset = false;
          response.setHeaderByName('Cache-Control', 'public, max-age=86400', true);
          body = 'window.fx25CacheRead=' + JSON.stringify(this.mark) + ';';
        } else {
          response.setHeaderByName('Cache-Control', 'no-store', true);
          body = 'window.fx25CacheRead="MISS";';
        }
      } else {
        response.setStatus(404);
        response.setMimeType('text/plain');
      }
      response.setEncoding('utf-8');
      output.didReceiveResponse(response);
      output.didReceiveResponseBody(encode(body));
      output.didFinish();
      return true; // 全部请求本机应答，不回源。
    });
  }

  /** 下一次资源请求回一份可缓存的标记脚本（用一次即清）。 */
  seed(): void {
    this.serveAsset = true;
  }

  /** 在 controller 当前文档里插一个新的 <script src=资源>；结果由调用方有上限轮询 readIs。 */
  async startRead(controller: webview.WebviewController): Promise<void> {
    await controller.runJavaScript('window.fx25CacheRead="PENDING";(function(){var s=document.createElement("script");' +
      's.src=' + JSON.stringify(this.asset) + ';s.onerror=function(){window.fx25CacheRead="LOAD_ERROR";};' +
      'document.head.appendChild(s);})();');
  }

  async readIs(controller: webview.WebviewController, expected: string): Promise<boolean> {
    try {
      return await controller.runJavaScript('window.fx25CacheRead===' + JSON.stringify(expected)) === 'true';
    } catch (e) {
      return false;
    }
  }

  /** t5：只取证（hilog）——当前文档里读到的值与本机 handler 的计数；不参与判定。 */
  async describe(controller: webview.WebviewController): Promise<string> {
    let value: string = '';
    try {
      value = await controller.runJavaScript('String(window.fx25CacheRead)');
    } catch (e) {
      value = 'runJavaScript failed: ' + JSON.stringify(e);
    }
    return 'read=' + value + ' assetRequests=' + this.assetRequests + ' pageLoads=' + this.pageLoads;
  }
}

/** t6：可信容器的控制器。只多记一样：removeCache 的调用（参数），其余原样交给 ArkWeb。 */
export class Fx25SpyController extends webview.WebviewController {
  cacheClears: boolean[] = [];

  removeCache(clearRom: boolean): void {
    this.cacheClears.push(clearRom);
    super.removeCache(clearRom);
  }
}

export class Fx25CacheRig {
  /** t6：所有可信控制器上 removeCache 的调用总数（产品不得调用，D10-396）。 */
  cacheClearCalls(): number {
    let calls: number = 0;
    for (const spy of this.spies) {
      calls += spy.cacheClears.length;
    }
    return calls;
  }

  static readonly shared: Fx25CacheRig = new Fx25CacheRig();
  readonly network: Fx25NetworkRig = new Fx25NetworkRig(new SessionTokenSet('e02-access-a', 'e02-refresh-a', 'full', 'user-a', 'epoch-a'));
  readonly trusted: Fx25CacheSide = new Fx25CacheSide(FX25_E02_TRUSTED, TRUSTED_ASSET, FX25_E02_TRUSTED_MARK, 'fx25Ready');
  readonly outside: Fx25CacheSide = new Fx25CacheSide(FX25_E02_EXTERNAL, EXTERNAL_ASSET, FX25_E02_EXTERNAL_MARK, 'fx25ExtReady');
  readonly controllers: Fx25Controllers;
  readonly externalController: webview.WebviewController = new webview.WebviewController();
  readonly external: ExternalWebConfig;
  private trustedConfig: TrustedWebConfig | null = null;
  private pending: FileTrustedAuthJournal | null = null;
  /** t6：产品经 controllerFactory 拿走的全部可信控制器（切号前的、清理载体的）。 */
  readonly spies: Fx25SpyController[] = [];
  trustedLoaded: boolean = false;
  externalLoaded: boolean = false;

  constructor() {
    this.controllers = new Fx25Controllers(this.trusted.handler, (): webview.WebviewController => {
      const made: Fx25SpyController = new Fx25SpyController();
      this.spies.push(made);
      return made;
    });
    const state: Fx25BridgeState = new Fx25BridgeState();
    this.external = new ExternalWebConfig(new ExternalPageOptions(FX25_E02_EXTERNAL),
      new ExternalNavPolicy(state.linkPatterns()), (): string => state.linkPatterns(), 'FX25-E02');
    this.external.controller = this.externalController;
  }

  initialize(filesDir: string): void {
    if (this.trustedConfig !== null) return;
    const pending: FileTrustedAuthJournal = new FileTrustedAuthJournal(FileSlot.at(filesDir, 'fx25_e02_t4_trusted_web.pending'));
    const config: TrustedWebConfig = Fx25AuthWiring.trustedConfig(FX25_E02_TRUSTED, new Fx25BridgeState(),
      this.network.client, this.network.tokens, pending, null);
    this.controllers.wire(config);
    this.trustedConfig = config;
    this.pending = pending;
  }

  get config(): TrustedWebConfig {
    const config: TrustedWebConfig | null = this.trustedConfig;
    if (config === null) throw new Error('FX25 test Ability has not initialized E02 storage');
    return config;
  }

  get journal(): FileTrustedAuthJournal {
    const pending: FileTrustedAuthJournal | null = this.pending;
    if (pending === null) throw new Error('FX25 test Ability has not initialized E02 storage');
    return pending;
  }

  /** 两个容器都挂上后各自加载本机页面一次（只用于布置；切号后的可信入口加载由产品发起）。 */
  tryAttach(): boolean {
    if (!this.trustedLoaded) {
      const current: webview.WebviewController | null = this.controllers.current;
      if (current === null) return false;
      try {
        current.loadUrl(FX25_E02_TRUSTED);
        this.trustedLoaded = true;
      } catch (e) {
        return false;
      }
    }
    if (!this.externalLoaded) {
      try {
        this.externalController.setWebSchemeHandler('https', this.outside.handler);
        this.externalController.loadUrl(FX25_E02_EXTERNAL);
        this.externalLoaded = true;
      } catch (e) {
        return false;
      }
    }
    return true;
  }
}
