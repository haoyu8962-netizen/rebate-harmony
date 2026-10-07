// Debug / Staging 专用：模拟器冒烟与设计稿截图用的本机假服务（APP-05a）。只在 product=staging 编译，Release 没有本文件
// （tools/ci/release-scan.sh 查 COULI_FAKE_LOGIN_SERVER_APP05A_9d2c41、couli_debug_fake_server、DebugFakeServer）。
// 只有启动参数 `--pd couli_debug_fake_server 1` 打开时才接管请求，且一律在本机回答、不发出任何网络请求；没打开时原样交给真实传输层。
import {
  HttpTransport, RcpTransport, TransportFailure, TransportRequest, TransportResponse
} from 'core';
import { DebugFakeSearch, FakeAnswer } from './DebugFakeSearch';

class Waiting {
  readonly timer: number;
  readonly resolve: (r: TransportResponse) => void;

  constructor(timer: number, resolve: (r: TransportResponse) => void) {
    this.timer = timer;
    this.resolve = resolve;
  }
}

/** 固定标记（release-scan 的内容标记；调试面板不显示）。 */
export const DEBUG_FAKE_SERVER_MARKER: string = 'COULI_FAKE_LOGIN_SERVER_APP05A_9d2c41';
/** 启动参数键（aa start --pd couli_debug_fake_server 1）。 */
export const DEBUG_FAKE_SERVER_KEY: string = 'couli_debug_fake_server';

/**
 * 场景按输入的值选（一次启动走遍各画板）：
 * - 发码：13900000000 → 42901（Retry-After 120）；其余合法号码 → 成功（resend_after_sec 60）。
 * - 登录验证码：123456 → 成功（新号；带邀请码时语法合法 → bound，否则 failed 30401）；654321 → 成功（老号，邀请码忽略）；
 *   200020 → 20002；200030 → 20003；444444 → 44001；100070 → 10007 processing；104050 → 10405 no_account；
 *   429010 → 42901（Retry-After 30）；其余 → 20002。
 * - 设备注册、退出登录 → 成功；其余接口 → 50001（不连任何地址）。
 * - APP-06a：/v1/config（三个平台搜索开关都打开）、搜索与商品详情（场景见 DebugFakeSearch）。被 ApiClient 取消的请求
 *   （换关键词、换 Tab、离开页面）立即按 cancelled 结束，不再回答（与真实传输层一样）。
 */
export class DebugFakeServer implements HttpTransport {
  static enabled: boolean = false;
  static readonly marker: string = DEBUG_FAKE_SERVER_MARKER;
  static readonly searchMarker: string = DebugFakeSearch.marker;
  private readonly real: HttpTransport = new RcpTransport();
  private serial: number = 0;
  /** 等待回答中的请求：取消时清掉计时器并按 cancelled 结束。 */
  private readonly waiting: Map<TransportRequest, Waiting> = new Map<TransportRequest, Waiting>();

  send(request: TransportRequest): Promise<TransportResponse> {
    if (!DebugFakeServer.enabled) {
      return this.real.send(request);
    }
    if (!request.admit()) {
      return Promise.resolve(TransportResponse.failed(TransportFailure.CANCELLED));
    }
    const search: FakeAnswer | null = this.searchAnswer(request.url);
    const delay: number = search === null ? 400 : search.delayMillis;
    return new Promise<TransportResponse>((resolve: (r: TransportResponse) => void) => {
      const timer: number = setTimeout(() => {
        this.waiting.delete(request);
        resolve(search === null ? this.answer(request) : DebugFakeServer.envelope(search.code, search.data,
          search.retryAfter));
      }, delay);
      this.waiting.set(request, new Waiting(timer, resolve));
    });
  }

  cancel(request: TransportRequest): void {
    if (!DebugFakeServer.enabled) {
      this.real.cancel(request);
      return;
    }
    const w: Waiting | undefined = this.waiting.get(request);
    if (w !== undefined) {
      this.waiting.delete(request);
      clearTimeout(w.timer);
      w.resolve(TransportResponse.failed(TransportFailure.CANCELLED));
    }
  }

  /** APP-06a 的接口（配置、搜索、详情）；其余为 null。 */
  private searchAnswer(url: string): FakeAnswer | null {
    if (url.indexOf('/v1/config') >= 0) {
      return DebugFakeSearch.config();
    }
    if (url.indexOf('/v1/products/search') >= 0) {
      return DebugFakeSearch.search(url);
    }
    if (url.indexOf('/v1/products/') >= 0) {
      return DebugFakeSearch.product(url);
    }
    return null;
  }

  private answer(request: TransportRequest): TransportResponse {
    const url: string = request.url;
    const body: Record<string, Object> = DebugFakeServer.parse(request.body);
    if (url.indexOf('/v1/devices') >= 0) {
      this.serial++;
      return DebugFakeServer.envelope(0, '{"device_id":"debug-stub-device-' + this.serial
        + '","install_secret":"stub-stub-stub-stub"}');
    }
    if (url.indexOf('/v1/auth/sms-codes') >= 0) {
      if (body['phone'] === '13900000000') {
        return DebugFakeServer.envelope(42901, '{}', '120');
      }
      return DebugFakeServer.envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}');
    }
    if (url.indexOf('/v1/auth/login/sms') >= 0) {
      return this.login(body);
    }
    if (url.indexOf('/v1/auth/logout') >= 0) {
      return DebugFakeServer.envelope(0, '{}');
    }
    return DebugFakeServer.envelope(50001, '{}');
  }

  private login(body: Record<string, Object>): TransportResponse {
    const code: Object | undefined = body['code'];
    switch (code) {
      case '123456':
      case '654321': {
        const isNew: boolean = code === '123456';
        const invite: Object | undefined = body['invite_code'];
        let bind: string = '';
        if (typeof invite === 'string') {
          const result: string = !isNew ? '{"result":"ignored_existing_user","code":null}' :
            /^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$/.test(invite as string) ? '{"result":"bound","code":null}' :
              '{"result":"failed","code":30401}';
          bind = ',"invite_bind":' + result;
        }
        this.serial++;
        return DebugFakeServer.envelope(0, '{"user_id":"debug-stub-user-' + this.serial + '","is_new_user":' + isNew
          + ',"tokens":{"access_token":"stub-access-' + this.serial + '","access_expires_at":"2026-10-08T11:30:00+08:00",'
          + '"refresh_token":"stub-refresh-' + this.serial + '","refresh_expires_at":"2026-11-07T09:30:00+08:00",'
          + '"session_scope":"full"}' + bind + '}');
      }
      case '200030':
        return DebugFakeServer.envelope(20003, '{}');
      case '444444':
        return DebugFakeServer.envelope(44001, '{}');
      case '100070':
        return DebugFakeServer.envelope(10007, '{"stage":"processing"}');
      case '104050':
        return DebugFakeServer.envelope(10405, '{"reason":"no_account","min_supported_version":"9.0.0"}');
      case '429010':
        return DebugFakeServer.envelope(42901, '{}', '30');
      default:
        return DebugFakeServer.envelope(20002, '{}');
    }
  }

  private static envelope(code: number, data: string, retryAfter: string | null = null): TransportResponse {
    const headers: Record<string, string> = {};
    if (retryAfter !== null) {
      headers['retry-after'] = retryAfter;
    }
    const status: number = code === 0 ? 200 : code === 42901 ? 429 : 400;
    return TransportResponse.ok(status, headers,
      '{"code":' + code + ',"msg":"","data":' + data + ',"trace_id":"debug-stub-trace-0a1b2c"}');
  }

  private static parse(text: string | null): Record<string, Object> {
    if (text === null) {
      return {};
    }
    try {
      const value: Object | null = JSON.parse(text) as Object | null;
      return value !== null && typeof value === 'object' ? value as Record<string, Object> : {};
    } catch (e) {
      return {};
    }
  }
}
