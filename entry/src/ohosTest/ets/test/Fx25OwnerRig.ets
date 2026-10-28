// 只在 ohosTest（F-X-25 t1，E05，R3-04）：生产沙盒文件（FileTrustedAuthJournal + FileTrustedWebOwnerRecord，FileSlot + 真实 fileIo）
// 下的冷启动：盘上没有待清标记，归属记录写着 A，会话是 B → 第一个可信页加载前必须先补清。scheme handler 记下每一次入口文档请求带的
// Cookie 请求头：任何一次带着 A 的 Cookie 都说明「先加载、后清」。
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { FileSlot, FileTrustedAuthJournal, FileTrustedWebOwnerRecord, SessionTokenSet } from 'core';
import { TrustedWebConfig } from 'web';
import { Fx25AuthWiring } from './Fx25AuthWiring';
import { Fx25Controllers, fx25Respond } from './Fx25Controllers';
import { Fx25NetworkRig, Fx25BridgeState } from './Fx25TestPorts';

export const FX25_E05_URL: string = 'https://h5.example.test/fx25-e05';
export const FX25_E05_COOKIE: string = 'fx25_e05=user-a';

function encode(text: string): ArrayBuffer {
  return new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer;
}

export class Fx25OwnerRig {
  static readonly shared: Fx25OwnerRig = new Fx25OwnerRig();
  readonly network: Fx25NetworkRig = new Fx25NetworkRig(new SessionTokenSet('e05-access-b', 'e05-refresh-b', 'full', 'user-b', 'epoch-b'));
  readonly handler: webview.WebSchemeHandler = new webview.WebSchemeHandler();
  readonly controllers: Fx25Controllers;
  /** 每一次入口文档请求的 Cookie 请求头（没有为空串）。 */
  readonly requestCookies: string[] = [];
  private pending: FileTrustedAuthJournal | null = null;
  private owner: FileTrustedWebOwnerRecord | null = null;
  private trustedConfig: TrustedWebConfig | null = null;

  constructor() {
    this.controllers = new Fx25Controllers(this.handler);
    this.handler.onRequestStart((request: webview.WebSchemeHandlerRequest, output: webview.WebResourceHandler): boolean => {
      const url: string = request.getRequestUrl();
      if (url === FX25_E05_URL) {
        let cookie: string = '';
        for (const header of request.getHeader()) {
          if (header.headerKey.toLowerCase() === 'cookie') {
            cookie = header.headerValue;
          }
        }
        this.requestCookies.push(cookie);
        fx25Respond(output, url, 200, 'text/html', '<!doctype html><title>FX25 E05</title><script>window.fx25Ready=true;' +
          'window.fx25Cookie=document.cookie;</script>', encode);
      } else {
        fx25Respond(output, url, 404, 'text/plain', 'miss', encode);
      }
      return true;
    });
  }

  initialize(filesDir: string): void {
    if (this.pending !== null) return;
    this.pending = new FileTrustedAuthJournal(FileSlot.at(filesDir, 'fx25_e05_trusted_web.pending'));
    this.owner = new FileTrustedWebOwnerRecord(FileSlot.at(filesDir, 'fx25_e05_trusted_web.owner'));
  }

  /** Ability 已拿到沙盒目录（onWindowStageCreate 之后）。 */
  initialized(): boolean {
    return this.pending !== null;
  }

  get journal(): FileTrustedAuthJournal {
    const pending: FileTrustedAuthJournal | null = this.pending;
    if (pending === null) throw new Error('FX25 test Ability has not initialized E05 storage');
    return pending;
  }

  get record(): FileTrustedWebOwnerRecord {
    const owner: FileTrustedWebOwnerRecord | null = this.owner;
    if (owner === null) throw new Error('FX25 test Ability has not initialized E05 storage');
    return owner;
  }

  /**
   * 布置「上一个进程」留下的盘面：没有标记、归属 A（会话是 B）。只写盘，不建切号处理——用例先核对这个前置条件。
   * t2：原先 prepare() 一步写盘并建切号处理，用例在建完之后才核对「没有标记」。可是切号处理构造时就做冷启动比对（不符 →
   * 先持久登记补清事务，I3），标记此刻本来就该在盘上；前置条件的核对放错了时刻（设备上读到 user-a，不是产品问题）。
   */
  seed(): void {
    this.journal.clearPending();
    this.record.writeOwner('account:user-a');
  }

  /** 冷启动：在 seed() 布置好的盘面上建切号处理（构造时就做归属比对）。生产 pending === null 时 AppBridge 正是这个组合。 */
  prepare(): TrustedWebConfig {
    const existing: TrustedWebConfig | null = this.trustedConfig;
    if (existing !== null) return existing;
    const config: TrustedWebConfig = Fx25AuthWiring.trustedConfig(FX25_E05_URL, new Fx25BridgeState(),
      this.network.client, this.network.tokens, this.journal, this.record);
    this.controllers.wire(config);
    this.trustedConfig = config;
    return config;
  }

  get config(): TrustedWebConfig {
    const config: TrustedWebConfig | null = this.trustedConfig;
    if (config === null) throw new Error('FX25 E05 not prepared');
    return config;
  }
}
