// 只在 ohosTest（F-X-25 t1，E04 合并门槛，D10-279 c）：可信容器与隐私模式的 ExternalWebView 同屏。证明切号清 Cookie（产品用的是
// 没有参数的 WebCookieManager.clearAllCookies()）不波及 ExternalWebView 的 incognito Cookie。两边都由本机 scheme handler 应答。
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { ExternalNavPolicy, ExternalPageOptions, FileSlot, FileTrustedAuthJournal, SessionTokenSet } from 'core';
import { ExternalWebConfig, TrustedWebConfig } from 'web';
import { Fx25AuthWiring } from './Fx25AuthWiring';
import { Fx25Controllers, fx25Respond } from './Fx25Controllers';
import { Fx25NetworkRig, Fx25BridgeState } from './Fx25TestPorts';

export const FX25_E04_TRUSTED: string = 'https://h5.example.test/fx25-e04';
export const FX25_E04_EXTERNAL: string = 'https://external.example.test/fx25-e04';

function encode(text: string): ArrayBuffer {
  return new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer;
}

export class Fx25CookieRig {
  static readonly shared: Fx25CookieRig = new Fx25CookieRig();
  readonly network: Fx25NetworkRig = new Fx25NetworkRig(new SessionTokenSet('e04-access-a', 'e04-refresh-a', 'full', 'user-a', 'epoch-a'));
  readonly trustedHandler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  readonly externalHandler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  readonly controllers: Fx25Controllers;
  readonly externalController: webview.WebviewController = new webview.WebviewController();
  readonly external: ExternalWebConfig;
  private trustedConfig: TrustedWebConfig | null = null;
  documents: number = 0;
  trustedLoaded: boolean = false;
  externalLoaded: boolean = false;

  constructor() {
    this.controllers = new Fx25Controllers(this.trustedHandler);
    const state: Fx25BridgeState = new Fx25BridgeState();
    this.external = new ExternalWebConfig(new ExternalPageOptions(FX25_E04_EXTERNAL),
      new ExternalNavPolicy(state.linkPatterns()), (): string => state.linkPatterns(), 'FX25-E04');
    this.external.controller = this.externalController;
    this.trustedHandler.onRequestStart((request: webview.WebSchemeHandlerRequest, output: webview.WebResourceHandler): boolean => {
      const url: string = request.getRequestUrl();
      if (url === FX25_E04_TRUSTED) {
        this.documents++;
        fx25Respond(output, url, 200, 'text/html', '<!doctype html><title>FX25 E04 trusted</title><script>window.fx25Document=' +
          this.documents + ';window.fx25Ready=true;</script>', encode);
      } else {
        fx25Respond(output, url, 404, 'text/plain', 'miss', encode);
      }
      return true;
    });
    this.externalHandler.onRequestStart((request: webview.WebSchemeHandlerRequest, output: webview.WebResourceHandler): boolean => {
      const url: string = request.getRequestUrl();
      fx25Respond(output, url, url === FX25_E04_EXTERNAL ? 200 : 404, 'text/html',
        url === FX25_E04_EXTERNAL ? '<!doctype html><title>FX25 E04 external</title><script>window.fx25ExtReady=true;</script>' : 'miss', encode);
      return true;
    });
  }

  initialize(filesDir: string): void {
    if (this.trustedConfig !== null) return;
    const pending: FileTrustedAuthJournal = new FileTrustedAuthJournal(FileSlot.at(filesDir, 'fx25_e04_trusted_web.pending'));
    const config: TrustedWebConfig = Fx25AuthWiring.trustedConfig(FX25_E04_TRUSTED, new Fx25BridgeState(),
      this.network.client, this.network.tokens, pending, null);
    this.controllers.wire(config);
    this.trustedConfig = config;
  }

  get config(): TrustedWebConfig {
    const config: TrustedWebConfig | null = this.trustedConfig;
    if (config === null) throw new Error('FX25 test Ability has not initialized E04 storage');
    return config;
  }

  /** 两个容器都挂上后各自加载本机页面一次（只用于布置；切号后的可信入口加载由产品发起）。 */
  tryAttach(): boolean {
    if (!this.trustedLoaded) {
      const current: webview.WebviewController | null = this.controllers.current;
      if (current === null) return false;
      try {
        current.loadUrl(FX25_E04_TRUSTED);
        this.trustedLoaded = true;
      } catch (e) {
        return false;
      }
    }
    if (!this.externalLoaded) {
      try {
        this.externalController.setWebSchemeHandler('https', this.externalHandler);
        this.externalController.loadUrl(FX25_E04_EXTERNAL);
        this.externalLoaded = true;
      } catch (e) {
        return false;
      }
    }
    return true;
  }

  /** 读 Cookie（incognito = 隐私模式那一份）；没有任何 Cookie 时 SDK 可能抛 17100002，按空串。 */
  static cookies(url: string, incognito: boolean): string {
    try {
      return webview.WebCookieManager.fetchCookieSync(url, incognito);
    } catch (e) {
      return '';
    }
  }
}
