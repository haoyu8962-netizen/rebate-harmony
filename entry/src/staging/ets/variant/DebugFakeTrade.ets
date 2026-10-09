// Debug / Staging 专用：购买、外跳与授权的本机假数据（APP-06b 冒烟与设计稿截图）。只在 product=staging 编译，Release 没有本文件
// （tools/ci/release-scan.sh 查 COULI_FAKE_TRADE_SERVER_APP06B_5d1e93）。由 DebugFakeServer 在启动参数打开时调用，不发任何网络请求。
// 场景由启动参数 `--ps couli_debug_trade_scene <scene>` 选（见 DebugFakeTrade.answer）；值都是示例，不是任何平台的真实报文。
import { AuthStepResult, WebCodeAuthorizer } from 'core';
import { FakeAnswer } from './DebugFakeSearch';

/** 固定标记（release-scan 的内容标记）。 */
export const DEBUG_FAKE_TRADE_MARKER: string = 'COULI_FAKE_TRADE_SERVER_APP06B_5d1e93';
/** 启动参数键。 */
export const DEBUG_TRADE_SCENE_KEY: string = 'couli_debug_trade_scene';

const ATTEMPT: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a80';
const NEW_LINK: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a71';

function far(): string {
  return new Date(Date.now() + 15 * 60 * 1000).toISOString();
}

function step(type: string, value: string): string {
  return '{"type":"' + type + '","value":' + JSON.stringify(value) + '}';
}

function plan(primary: string, fallbacks: string[]): string {
  return '{"primary":' + primary + ',"fallbacks":[' + fallbacks.join(',') + '],"expire_at":"' + far() + '"}';
}

const SCHEME: string = step('scheme', 'couli-debug-target://item?id=example');
const H5: string = step('h5', 'https://u.example.test/abc');
const SDK: string = step('sdk', 'https://s.click.example.test/t?e=abc');
const TPWD: string = step('copy_tpwd', 'example-token-not-real');

/**
 * 场景（启动参数 couli_debug_trade_scene）：
 * - 空 / ok：成功，方案 scheme → h5（模拟器没有目标 App：scheme 失败后交浏览器，先显示「将通过浏览器打开」）；
 * - slow：open 6 秒后才回答（ProductBuyOpening）；timeout：20 秒后才回答（8 秒出 ProductBuyTimeout）；
 * - price / price_rebate / rebate_gone / compare / coupon / requote：改价、改价 + 返利归零、返利归零、比价无返利、券失效、复核失败；
 * - tip：getTips 未读（ProductJumpTip）；browser：只有 h5（ProductJumpBrowser）；sdk_failed：只有 sdk（ProductJumpSdkFailed）；
 * - not_installed：安装状态 false + 只有复制口令（ProductJumpNotInstalled）；harmony_h5：sdk → h5（ProductJumpHarmonyH5）；
 * - auth：30101（sdk_token、web_code），假 web_code 授权后绑定成功，再次 open 成功；auth_fail：绑定一直 30104 credential_invalid
 *   （换不到方式 → ProductAuthFailed）；auth_unavailable：30101 auth_unavailable；pdd_auth：30111 + auth_jump（h5）；
 * - blocked：open 30153；授权管理 pdd 为 blocked（AuthManageBlocked）；manage_30153：授权管理【去授权】回 30153；
 * - 游客（请求没有 Authorization）open 一律 10001。
 */
export class DebugFakeTrade {
  static readonly marker: string = DEBUG_FAKE_TRADE_MARKER;
  static scene: string = '';
  private static bound: boolean = false;
  /** 这次进程里已经回过改价类的 open（之后详情的权威重取按新报价回答，演示补齐价格字段）。 */
  private static repriced: boolean = false;

  /**
   * 改价类场景 open 之后，详情 tb:milk 的权威报价（券前、券额、券后，分）：price / price_rebate 券后 49.90（券 10）；coupon 换成新券
   * （券 5，券后 56.78）。没有为 null（按原样本）。
   */
  static milkQuote(): number[] | null {
    if (!DebugFakeTrade.repriced) {
      return null;
    }
    const s: string = DebugFakeTrade.scene;
    if (s === 'price' || s === 'price_rebate') {
      return [5990, 1000, 4990];
    }
    return s === 'coupon' ? [6178, 500, 5678] : null;
  }

  /** 本机假服务里的安装状态覆盖（not_installed 场景为 false，其余 null = 按真实检测）。 */
  static installed(_platform: string): string | null {
    return DebugFakeTrade.scene === 'not_installed' ? 'false' : null;
  }

  /** 浏览器提示停留时长：截图场景放长到 5 秒（只在 Debug）。 */
  static browserNoticeMillis(defaultMillis: number): number {
    const s: string = DebugFakeTrade.scene;
    return s === 'browser' || s === 'harmony_h5' || s === 'pdd_auth' || s === '' || s === 'ok' ? 5000 : defaultMillis;
  }

  static answer(url: string, method: string, authorized: boolean): FakeAnswer | null {
    if (url.indexOf('/v1/links/') >= 0 && url.indexOf('/open') >= 0) {
      return authorized ? DebugFakeTrade.open() : new FakeAnswer(10001, '{}', 400);
    }
    if (url.indexOf('/v1/me/tips') >= 0) {
      if (method === 'POST') {
        return new FakeAnswer(0, '{}', 200);
      }
      const read: string = DebugFakeTrade.scene === 'tip' ? 'null' : '"2026-10-01T09:30:00+08:00"';
      return new FakeAnswer(0, '{"jump_tip":{"taobao":' + read + ',"jd":' + read + ',"pdd":' + read
        + '},"inviter_before_buy":null}', 200);
    }
    if (url.indexOf('/v1/unions/bindings') >= 0) {
      if (DebugFakeTrade.scene === 'pdd_limited') {
        // 授权回流查询被限流（H-R1-08 截图）：42901 + Retry-After 30 秒
        return new FakeAnswer(42901, '{}', 400, '30');
      }
      const pdd: string = DebugFakeTrade.scene === 'blocked' ? 'blocked' : 'unbound';
      const tb: string = DebugFakeTrade.bound || DebugFakeTrade.scene === '' ? 'active' : 'unbound';
      return new FakeAnswer(0, '{"items":[{"platform":"taobao","status":"' + tb + '"},{"platform":"jd","status":"unbound"},'
        + '{"platform":"pdd","status":"' + pdd + '"}]}', 400);
    }
    if (url.indexOf('/auth-url') >= 0) {
      if (DebugFakeTrade.scene === 'manage_30153') {
        return new FakeAnswer(30153, '{}', 400);
      }
      if (url.indexOf('/pdd/') >= 0) {
        return new FakeAnswer(0, '{"auth_url":"https://auth.example.test/pdd/authorize?state=st_02","state":"st_02",'
          + '"auth_jump":' + plan(step('h5', 'https://auth.example.test/pdd/authorize?state=st_02'), []) + '}', 400);
      }
      return new FakeAnswer(0, '{"auth_url":"https://oauth.example.test/authorize?state=st_03","state":"st_03",'
        + '"auth_methods":["web_code"]}', 400);
    }
    if (url.indexOf('/v1/unions/') >= 0 && url.indexOf('/bindings') >= 0) {
      if (DebugFakeTrade.scene === 'auth_fail') {
        return new FakeAnswer(30104, '{"reason":"credential_invalid"}', 600);
      }
      DebugFakeTrade.bound = true;
      return new FakeAnswer(0, '{"platform":"taobao","status":"active"}', 600);
    }
    return null;
  }

  private static ok(jump: string, extra: string = '', price: number = 4678, rebate: number = 234): FakeAnswer {
    return new FakeAnswer(0, '{"attempt_id":"' + ATTEMPT + '","jump":' + jump + ',"price_changed":false,'
      + '"old_final_price_fen":4678,"new_final_price_fen":' + price + ',"new_link_id":null,"requote_failed":false,'
      + '"new_rebate_min_fen":' + (rebate === 0 ? 0 : 123) + ',"new_rebate_max_fen":' + rebate + ',"availability":"ok",'
      + '"quoted_at":"' + new Date().toISOString() + '"' + extra + '}', 700);
  }

  private static open(): FakeAnswer {
    const s: string = DebugFakeTrade.scene;
    if (s === 'price' || s === 'price_rebate' || s === 'coupon') {
      DebugFakeTrade.repriced = true;
    }
    const defaultPlan: string = plan(SCHEME, [H5]);
    switch (s) {
      case 'slow':
        return new FakeAnswer(DebugFakeTrade.ok(defaultPlan).code, DebugFakeTrade.ok(defaultPlan).data, 6000);
      case 'timeout':
        return new FakeAnswer(0, DebugFakeTrade.ok(defaultPlan).data, 20000);
      case 'price':
        return new FakeAnswer(0, DebugFakeTrade.ok(defaultPlan).data.replace('"price_changed":false', '"price_changed":true')
          .replace('"new_final_price_fen":4678', '"new_final_price_fen":4990')
          .replace('"new_link_id":null', '"new_link_id":"' + NEW_LINK + '"'), 700);
      case 'price_rebate':
        return new FakeAnswer(0, DebugFakeTrade.ok(defaultPlan, '', 4990, 0).data
          .replace('"price_changed":false', '"price_changed":true')
          .replace('"new_link_id":null', '"new_link_id":"' + NEW_LINK + '"'), 700);
      case 'rebate_gone':
        return DebugFakeTrade.ok(defaultPlan, '', 4678, 0);
      case 'compare':
        return DebugFakeTrade.ok(defaultPlan, ',"no_rebate_cause":"price_compare"', 4678, 0);
      case 'coupon':
        return new FakeAnswer(0, DebugFakeTrade.ok(defaultPlan, '', 5678).data
          .replace('"availability":"ok"', '"availability":"coupon_gone"')
          .replace('"new_link_id":null', '"new_link_id":"' + NEW_LINK + '"'), 700);
      case 'requote':
        return new FakeAnswer(0, DebugFakeTrade.ok(defaultPlan).data.replace('"requote_failed":false', '"requote_failed":true'),
          700);
      case 'browser':
        return DebugFakeTrade.ok(plan(H5, []));
      case 'sdk_failed':
        return DebugFakeTrade.ok(plan(SDK, []));
      case 'not_installed':
        return DebugFakeTrade.ok(plan(TPWD, []));
      case 'harmony_h5':
        return DebugFakeTrade.ok(plan(SDK, [H5]));
      case 'auth':
      case 'auth_fail':
        if (DebugFakeTrade.bound) {
          return DebugFakeTrade.ok(defaultPlan);
        }
        return new FakeAnswer(30101, '{"auth_url":"https://oauth.example.test/authorize?state=st_01","state":"st_01",'
          + '"auth_methods":["sdk_token","web_code"]}', 700);
      case 'auth_unavailable':
        return new FakeAnswer(30101, '{"reason":"auth_unavailable"}', 700);
      case 'off_shelf':
        // 点击时下架（H-R1-07 截图）：30141，搜索卡 / 详情按钮置灰
        return new FakeAnswer(30141, '{}', 700);
      case 'pdd_auth':
      case 'pdd_limited':
        return new FakeAnswer(30111, '{"auth_jump":' + plan(step('h5', 'https://auth.example.test/pdd/authorize?state=st_02'),
          []) + '}', 700);
      case 'blocked':
        return new FakeAnswer(30153, '{}', 700);
      default:
        return DebugFakeTrade.ok(defaultPlan);
    }
  }
}

/**
 * Debug / Staging 的 web_code 授权：本机假服务打开时可用，直接给一个假授权码（不打开任何页面、不是真实凭证），用来走通
 * 「AuthSheet → 绑定 → 自动执行一次 open」的链路与截图；没打开时与 Release 一样不可用。
 */
export class DebugWebCodeAuthorizer implements WebCodeAuthorizer {
  private readonly enabled: () => boolean;

  constructor(enabled: () => boolean) {
    this.enabled = enabled;
  }

  available(): boolean {
    return this.enabled();
  }

  authorize(_authUrl: string, _state: string): Promise<AuthStepResult> {
    return new Promise<AuthStepResult>((resolve: (r: AuthStepResult) => void) => {
      setTimeout(() => resolve(AuthStepResult.webCode('debug-fake-code')), 600);
    });
  }
}
