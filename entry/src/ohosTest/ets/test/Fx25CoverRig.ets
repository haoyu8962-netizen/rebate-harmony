// 只在 ohosTest（F-X-25 t1，E06）：Navigation 里宿主 NavDestination（TrustedWebView）被另一个 NavDestination 压着时切号。
// 宿主页的 onShown / onHidden 照生产 WebPages.ets 的写法接 TrustedWebConfig.hostVisible（plan-teardown 风险 3：被压页载体等不到
// attach 按延期）。只用 Navigation + NavPathStack。
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { ApiRequest, ApiResult, FileSlot, FileTrustedAuthJournal, SessionTokenSet, TransportRequest, TransportResponse } from 'core';
import { TrustedWebConfig } from 'web';
import { Fx25AuthWiring } from './Fx25AuthWiring';
import { Fx25Controllers, fx25Respond } from './Fx25Controllers';
import { Fx25NetworkRig, Fx25BridgeState, envelope, tokenPair } from './Fx25TestPorts';

export const FX25_E06_URL: string = 'https://h5.example.test/fx25-e06';
export const FX25_E06_HOST: string = 'Fx25Host';
export const FX25_E06_COVER: string = 'Fx25Cover';

function encode(text: string): ArrayBuffer {
  return new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer;
}

export class Fx25CoverRig {
  static readonly shared: Fx25CoverRig = new Fx25CoverRig();
  readonly network: Fx25NetworkRig = new Fx25NetworkRig(new SessionTokenSet('e06-access-a', 'e06-refresh-a', 'full', 'user-a', 'epoch-a'));
  readonly handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  readonly controllers: Fx25Controllers;
  readonly stack: NavPathStack = new NavPathStack();
  private trustedConfig: TrustedWebConfig | null = null;
  documents: number = 0;
  firstLoaded: boolean = false;
  shown: number = 0;
  hidden: number = 0;

  constructor() {
    this.controllers = new Fx25Controllers(this.handler);
    this.handler.onRequestStart((request: webview.WebSchemeHandlerRequest, output: webview.WebResourceHandler): boolean => {
      const url: string = request.getRequestUrl();
      if (url === FX25_E06_URL) {
        this.documents++;
        fx25Respond(output, url, 200, 'text/html', '<!doctype html><title>FX25 E06</title><script>window.fx25Document=' +
          this.documents + ';window.fx25Ready=true;</script>', encode);
      } else {
        fx25Respond(output, url, 404, 'text/plain', 'miss', encode);
      }
      return true;
    });
  }

  initialize(filesDir: string): void {
    if (this.trustedConfig !== null) return;
    const pending: FileTrustedAuthJournal = new FileTrustedAuthJournal(FileSlot.at(filesDir, 'fx25_e06_trusted_web.pending'));
    const config: TrustedWebConfig = Fx25AuthWiring.trustedConfig(FX25_E06_URL, new Fx25BridgeState(),
      this.network.client, this.network.tokens, pending, null);
    this.controllers.wire(config);
    this.trustedConfig = config;
  }

  get config(): TrustedWebConfig {
    const config: TrustedWebConfig | null = this.trustedConfig;
    if (config === null) throw new Error('FX25 test Ability has not initialized E06 storage');
    return config;
  }

  /** 宿主页 NavDestination 的 onShown / onHidden（与生产 WebPages.ets 同一接法）。 */
  hostShown(visible: boolean): void {
    if (visible) this.shown++; else this.hidden++;
    this.config.hostVisible(visible);
  }

  tryAttach(): boolean {
    if (this.firstLoaded) return true;
    const current: webview.WebviewController | null = this.controllers.current;
    if (current === null) return false;
    try {
      current.loadUrl(FX25_E06_URL);
      this.firstLoaded = true;
      return true;
    } catch (e) {
      return false;
    }
  }

  async switchAccount(): Promise<ApiResult> {
    this.network.server.handler = (_request: TransportRequest): Promise<TransportResponse> => Promise.resolve(
      envelope(0, '{"user_id":"user-b","is_new_user":false,"tokens":' +
        tokenPair('e06-access-b', 'e06-refresh-b', 'full') + '}'));
    return this.network.client.request(new ApiRequest('loginBySms', {}, '', '{"phone":"13800138000","code":"123456"}'));
  }
}
