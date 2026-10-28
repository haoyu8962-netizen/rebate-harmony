// 真实 ExternalWebView 的隐私 profile；被测的是 ArkWeb 自己的 HTTP 缓存，不是 JS Map/CacheStorage。
// t2（设备实测后改布置方式）：原先用 injectOfflineResources 注入 CLASSIC_JS、再用 fetch(only-if-cached) 读。设备上两条都不成立：
// fetch 不命中注入的资源；改成 <script src> 也不命中——读 ASSET 的请求每次都直接到了 scheme handler（拦或不拦都一样）。
// 现在改成真实的 HTTP 缓存：第一次读时由本机 handler 回一份带 Cache-Control: max-age 的脚本（标记值），之后 handler 对 ASSET 一律
// 回「MISS」脚本。所以之后读到标记值 = 由 ArkWeb 缓存供给；读到 MISS = 请求到了「网络」（缓存没了）。判定与原用例相同。
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { ExternalNavPolicy, ExternalPageOptions, FileSlot, FileTrustedAuthJournal, SessionTokenSet, TrustedAuthSync } from 'core';
import { ExternalWebConfig } from 'web';
import { Fx25AuthWiring } from './Fx25AuthWiring';
import { Fx25NetworkRig, Fx25BridgeState } from './Fx25TestPorts';

const PAGE: string = 'https://external.example.test/fx25-cache';
const ASSET: string = 'https://external.example.test/fx25-cache-body.js';
export const FX25_CACHE_MARK: string = 'external-cache-response-v3';
const CACHED_BODY: string = 'window.fx25CacheRead=' + JSON.stringify(FX25_CACHE_MARK) + ';';
const MISS_BODY: string = 'window.fx25CacheRead="MISS";';

let fx25ExternalCache: Fx25ExternalCacheRig | null = null;

@ObservedV2
export class Fx25ExternalCacheRig {
  // t2：同 Fx25Scene——静态字段在 @ObservedV2 / @Trace 装饰之前求值，externalOnly 改了页面也不重建（设备上 E02 的外部页从没挂上）。
  static get shared(): Fx25ExternalCacheRig {
    if (fx25ExternalCache === null) {
      fx25ExternalCache = new Fx25ExternalCacheRig();
    }
    return fx25ExternalCache;
  }
  @Trace externalOnly: boolean = false;
  readonly controller: webview.WebviewController = new webview.WebviewController();
  readonly network: Fx25NetworkRig = new Fx25NetworkRig(new SessionTokenSet('external-test-access',
    'external-test-refresh', 'full', 'user-a', 'epoch-a'));
  readonly config: ExternalWebConfig;
  readonly handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  installed: boolean = false;
  /** 走到本机 handler 的 ASSET 请求数（只用于诊断）。 */
  assetRequests: number = 0;
  /** 下一次 ASSET 请求是否回可缓存的标记脚本（seedCache 置位，用一次即清）。 */
  private serveAsset: boolean = false;
  /** 本机应答过的外部页文档数（每份文档带自己的序号 window.fx25CacheDoc）。 */
  pageLoads: number = 0;
  sync: TrustedAuthSync | null = null;
  private pending: FileTrustedAuthJournal | null = null;

  constructor() {
    const state: Fx25BridgeState = new Fx25BridgeState();
    this.config = new ExternalWebConfig(new ExternalPageOptions(PAGE),
      new ExternalNavPolicy(state.linkPatterns()), (): string => state.linkPatterns(), 'FX25-device-test');
    // v3 最小可注入系统端口，与 TrustedWebConfig.controller 同形；尚未实现时应编译红，不用类型断言绕过。
    this.config.controller = this.controller;
    this.handler.onRequestStart((request: webview.WebSchemeHandlerRequest, output: webview.WebResourceHandler): boolean => {
      const url: string = request.getRequestUrl();
      const response: webview.WebSchemeHandlerResponse = new webview.WebSchemeHandlerResponse();
      // t2：不调 setUrl——它设的是「重定向后的地址」，设成请求地址本身会自我重定向到上限（设备上主框架 main_frame_error）。
      let body: string = 'miss';
      if (url === PAGE) {
        this.pageLoads++;
        response.setStatus(200);
        response.setMimeType('text/html');
        body = '<!doctype html><title>FX25 external cache</title><script>window.fx25CacheDoc=' + this.pageLoads +
          ';window.fx25CacheReady=true;</script>';
      } else if (url === ASSET) {
        this.assetRequests++;
        response.setStatus(200);
        response.setMimeType('application/javascript');
        if (this.serveAsset) {
          // 只有布置这一次回可缓存的标记脚本。
          this.serveAsset = false;
          response.setHeaderByName('Cache-Control', 'public, max-age=86400', true);
          body = CACHED_BODY;
        } else {
          response.setHeaderByName('Cache-Control', 'no-store', true);
          body = MISS_BODY;
        }
      } else {
        response.setStatus(404);
        response.setMimeType('text/plain');
      }
      response.setEncoding('utf-8');
      output.didReceiveResponse(response);
      output.didReceiveResponseBody(new util.TextEncoder().encodeInto(body).buffer as ArrayBuffer);
      output.didFinish();
      return true; // 全部请求本机应答，不回源。
    });
  }

  tryAttach(): boolean {
    if (this.installed) return true;
    try {
      this.controller.setWebSchemeHandler('https', this.handler);
      this.controller.loadUrl(PAGE);
      this.installed = true;
      return true;
    } catch (e) { return false; }
  }

  /** 布置：下一次 ASSET 请求由本机回一份可缓存的标记脚本（之后的请求都回 MISS）。调用方随后读一次，读到标记值才算布置成功。 */
  seedCache(): void {
    this.serveAsset = true;
  }

  /** 读一次 ASSET：在当前外部文档里插一个新的 <script src=ASSET>；结果（标记值 / "MISS"）由调用方有上限轮询 cacheReadIs。 */
  async startCacheRead(): Promise<void> {
    await this.controller.runJavaScript('window.fx25CacheRead="PENDING";(function(){var s=document.createElement("script");' +
      's.src=' + JSON.stringify(ASSET) + ';s.onerror=function(){window.fx25CacheRead="LOAD_ERROR";};document.head.appendChild(s);})();');
  }

  /** 当前外部文档里 fx25CacheRead 是否等于 expected（runJavaScript 返回 JSON 形式，故在页内比较）。 */
  async cacheReadIs(expected: string): Promise<boolean> {
    try {
      return await this.controller.runJavaScript('window.fx25CacheRead===' + JSON.stringify(expected)) === 'true';
    } catch (e) {
      return false;
    }
  }

  initialize(filesDir: string): void {
    if (this.pending !== null) return;
    // 两个夹具使用不同 ApiClient / 标记文件；不清除上次未完成的事务。
    this.pending = new FileTrustedAuthJournal(FileSlot.at(filesDir, 'fx25_e02_trusted_web.pending'));
  }

  prepareAuth(): void {
    // 与 App 启动相同的切号订阅（AppBridge.trustedAuth 的接线，v7 起由 Fx25AuthWiring 照抄）；不创建任何 TrustedWebConfig/TrustedWebView。
    const pending: FileTrustedAuthJournal | null = this.pending;
    if (pending === null) throw new Error('FX25 test Ability has not initialized external test storage');
    this.sync = Fx25AuthWiring.trustedAuth(this.network.client, this.network.tokens, pending);
  }
}
