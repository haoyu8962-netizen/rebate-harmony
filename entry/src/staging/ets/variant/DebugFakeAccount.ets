// Debug / Staging 专用：注销账号与换手机号的本机假服务（APP-13a §2 第 11 项；冒烟与设计稿截图）。只在 product=staging 编译，Release 没有
// 本文件（tools/ci/release-scan.sh 查 COULI_FAKE_ACCOUNT_SERVER_APP13A_2d7f90、couli_debug_account_scene）。由 DebugFakeServer 在传输入口
// 闸门放行时调用（DebugMockTransport：假服务打开且当前环境允许 MOCK_DATA，FU-HM-0711b F-X-02），不发任何网络请求，不做真实注销与换号。
// 号码只用测试值：会话测试号 13800005678（二次验证发码，DebugFakeWallet.DEBUG_STEP_UP_PHONE），新号 13900001234。
// 状态（注销进度、绑定号码）按账号（Authorization 里的令牌）保存；场景切换、撤回同意与切环境（AppConfig 清理前第一步）、换号成功时同步清掉
// （APP-10 第 11 条）。请求正文不保存。
// 场景（`--ps couli_debug_account_scene <scene>`，可用逗号组合）：
// - 进度：cooling / cooling_expired（can_cancel=false）/ processing / cancelled_negative / deletion_fail（getDeletion 50001）；
// - 资金：negative200 / negative567（钱包摘要 negative_fen）/ wallet_fail；getMe：unbound（phone_bound=false）；
// - 申请：timeout（无外壳）/ busy（40901）/ rate（42901 Retry-After 30）/ server（50401）/ 30412 / 30416 / 30416_noamount / 20903 /
//   10007 / 10007p（processing）/ 10405 / outside（表外 30414）；撤回：cancel_10007 / cancel_timeout / cancel_rate / cancel_server；
// - 换号：phone_10003（第一次提交回 10003）/ phone_timeout / phone_30411 / phone_30414 / phone_44001 / phone_20903 / phone_rate / phone_server / phone_10405；新号验证码 200020 → 20002、
//   200030 → 20003；首次绑定：bind_timeout；
// - 作废：abandon_busy（40901）/ abandon_completed（原结果成功）/ abandon_completed_3xxxx / abandon_10405；
// - 受限：restricted（短信登录与刷新给 deletion_only）。
import { FakeAnswer } from './DebugFakeSearch';

export const DEBUG_FAKE_ACCOUNT_MARKER: string = 'COULI_FAKE_ACCOUNT_SERVER_APP13A_2d7f90';
export const DEBUG_ACCOUNT_SCENE_KEY: string = 'couli_debug_account_scene';

class AccountState {
  deletion: string = 'null';
  phone: string = '13800005678';
}

export class DebugFakeAccount {
  static readonly marker: string = DEBUG_FAKE_ACCOUNT_MARKER;
  private static scenes: string[] = [];
  private static changeCalls: number = 0;
  private static readonly states: Map<string, AccountState> = new Map<string, AccountState>();

  static reset(scene: string): void {
    DebugFakeAccount.scenes = scene.split(',').map((x: string): string => x.trim()).filter((x: string) => x.length > 0);
    DebugFakeAccount.states.clear();
    DebugFakeAccount.changeCalls = 0;
  }

  /** 撤回同意、切换环境的清理前第一步：假服务按账号保存的状态同步清掉。 */
  static clearState(): void {
    DebugFakeAccount.states.clear();
  }

  private static has(scene: string): boolean {
    return DebugFakeAccount.scenes.indexOf(scene) >= 0;
  }

  private static state(auth: string | undefined): AccountState {
    const key: string = auth ?? '';
    const s: AccountState | undefined = DebugFakeAccount.states.get(key);
    if (s !== undefined) {
      return s;
    }
    const n: AccountState = new AccountState();
    if (DebugFakeAccount.has('cooling')) {
      n.deletion = DebugFakeAccount.record('cooling', true, null);
    } else if (DebugFakeAccount.has('cooling_expired')) {
      n.deletion = DebugFakeAccount.record('cooling', false, null);
    } else if (DebugFakeAccount.has('processing')) {
      n.deletion = DebugFakeAccount.record('processing', false, null);
    } else if (DebugFakeAccount.has('cancelled_negative')) {
      n.deletion = DebugFakeAccount.record('cancelled', false, 'negative_balance');
    }
    DebugFakeAccount.states.set(key, n);
    return n;
  }

  private static record(status: string, canCancel: boolean, reason: string | null): string {
    const r: Record<string, Object | null> = {};
    r['status'] = status;
    r['apply_at'] = '2026-10-12T10:00:00+08:00';
    r['cooling_until'] = '2026-10-19T10:00:00+08:00';
    r['can_cancel'] = canCancel;
    r['cancelled_at'] = status === 'cancelled' ? '2026-10-19T10:00:00+08:00' : null;
    r['cancel_reason'] = reason;
    r['processed_at'] = null;
    return JSON.stringify(r);
  }

  /** 受限登录场景：短信登录与刷新给 deletion_only（03 §4.1）。 */
  static sessionScope(): string {
    return DebugFakeAccount.has('restricted') ? 'deletion_only' : 'full';
  }

  /** 首次绑定的超时场景（G07 BindPhone 待确认截图）。 */
  static bindTimeout(): boolean {
    return DebugFakeAccount.has('bind_timeout');
  }

  /** 本服务的接口（注销三个、换号、作废、负余额摘要、未绑手机的 getMe、刷新）；其余为 null。 */
  static answer(url: string, method: string, body: string | null, auth: string | undefined,
    stepUpToken: string | undefined): FakeAnswer | null {
    const path: string = url.split('?')[0];
    if (path.endsWith('/v1/me/deletion/cancel')) {
      return DebugFakeAccount.cancel(auth);
    }
    if (path.endsWith('/v1/me/deletion')) {
      return method === 'POST' ? DebugFakeAccount.apply(auth, stepUpToken) : DebugFakeAccount.get(auth);
    }
    if (path.endsWith('/v1/me/phone') && (stepUpToken !== undefined || DebugFakeAccount.changeScene())) {
      return DebugFakeAccount.change(auth, body, stepUpToken);
    }
    if (path.endsWith('/v1/me/phone') && DebugFakeAccount.bindTimeout()) {
      return new FakeAnswer(-1, '', 800);
    }
    if (path.endsWith('/v1/idempotency-keys/abandon') && body !== null
      && (body.indexOf('"phone_change"') >= 0 || body.indexOf('"account_deletion"') >= 0)) {
      return DebugFakeAccount.abandon(auth, body);
    }
    if (path.endsWith('/v1/wallet/summary')) {
      return DebugFakeAccount.summary();
    }
    if (path.endsWith('/v1/me') && method === 'GET' && DebugFakeAccount.has('unbound')) {
      return new FakeAnswer(0, '{"user_id":"debug-stub-user","phone_bound":false,"realname_status":"verified"}', 200);
    }
    if (path.endsWith('/v1/auth/refresh') && DebugFakeAccount.has('restricted')) {
      return new FakeAnswer(0, '{"access_token":"stub-access-r","access_expires_at":"2026-10-08T11:30:00+08:00",'
        + '"refresh_token":"stub-refresh-r","refresh_expires_at":"2026-11-07T09:30:00+08:00","session_scope":"'
        + DebugFakeAccount.sessionScope() + '"}', 300);
    }
    return null;
  }

  private static changeScene(): boolean {
    for (const s of DebugFakeAccount.scenes) {
      if (s.startsWith('phone_')) {
        return true;
      }
    }
    return false;
  }

  private static get(auth: string | undefined): FakeAnswer {
    if (DebugFakeAccount.has('deletion_fail')) {
      return new FakeAnswer(50001, '{}', 300);
    }
    return new FakeAnswer(0, DebugFakeAccount.state(auth).deletion, 300);
  }

  private static apply(auth: string | undefined, token: string | undefined): FakeAnswer {
    if (DebugFakeAccount.has('timeout')) {
      return new FakeAnswer(-1, '', 800);
    }
    if (token === undefined || token.length === 0) {
      return new FakeAnswer(10003, '{}', 400);
    }
    const codes: Map<string, number> = new Map<string, number>();
    codes.set('busy', 40901);
    codes.set('rate', 42901);
    codes.set('server', 50401);
    codes.set('30412', 30412);
    codes.set('20903', 20903);
    codes.set('10405', 10405);
    codes.set('outside', 30414);
    for (const s of DebugFakeAccount.scenes) {
      const c: number | undefined = codes.get(s);
      if (c !== undefined) {
        return new FakeAnswer(c, c === 10405 ? '{"min_supported_version":"9.0.0"}' : '{}', 400, c === 42901 ? '30' : null);
      }
    }
    if (DebugFakeAccount.has('30416')) {
      return new FakeAnswer(30416, '{"amount_fen":567}', 400);
    }
    if (DebugFakeAccount.has('30416_noamount')) {
      return new FakeAnswer(30416, '{}', 400);
    }
    if (DebugFakeAccount.has('10007') || DebugFakeAccount.has('10007p')) {
      return new FakeAnswer(10007, DebugFakeAccount.has('10007p') ? '{"stage":"processing"}' : '{"stage":"cooling"}', 400);
    }
    const s: AccountState = DebugFakeAccount.state(auth);
    s.deletion = DebugFakeAccount.record('cooling', true, null);
    return new FakeAnswer(0, s.deletion, 600);
  }

  private static cancel(auth: string | undefined): FakeAnswer {
    if (DebugFakeAccount.has('cancel_timeout')) {
      return new FakeAnswer(-1, '', 800);
    }
    if (DebugFakeAccount.has('cancel_10007')) {
      return new FakeAnswer(10007, '{"stage":"processing"}', 400);
    }
    if (DebugFakeAccount.has('cancel_rate')) {
      return new FakeAnswer(42901, '{}', 400, '30');
    }
    if (DebugFakeAccount.has('cancel_server')) {
      return new FakeAnswer(50401, '{}', 400);
    }
    const s: AccountState = DebugFakeAccount.state(auth);
    s.deletion = DebugFakeAccount.record('cancelled', false, 'user');
    return new FakeAnswer(0, s.deletion, 600);
  }

  private static change(auth: string | undefined, body: string | null, token: string | undefined): FakeAnswer {
    if (DebugFakeAccount.has('phone_timeout')) {
      return new FakeAnswer(-1, '', 800);
    }
    if (token === undefined || token.length === 0) {
      return new FakeAnswer(10003, '{}', 400);
    }
    if (DebugFakeAccount.has('phone_10003') && DebugFakeAccount.changeCalls++ === 0) {
      // 第 1 步的 token 已过期：第一次提交回 10003（二次验证面板 phone_change，AdaptShortStepUp 截图）。
      return new FakeAnswer(10003, '{}', 400);
    }
    let phone: string = '';
    let code: string = '';
    try {
      const b: Record<string, Object> = JSON.parse(body ?? '{}') as Record<string, Object>;
      phone = typeof b['phone'] === 'string' ? b['phone'] as string : '';
      code = typeof b['code'] === 'string' ? b['code'] as string : '';
    } catch (e) {
      phone = '';
    }
    const scenes: Map<string, string> = new Map<string, string>();
    scenes.set('phone_30411', '30411:{}');
    scenes.set('phone_30414', '30414:{}');
    scenes.set('phone_44001', '44001:{"risk_msg_code":"debug_unmapped"}');
    scenes.set('phone_20903', '20903:{}');
    scenes.set('phone_rate', '42901:{}');
    scenes.set('phone_server', '50401:{}');
    scenes.set('phone_10405', '10405:{"min_supported_version":"9.0.0"}');
    for (const s of DebugFakeAccount.scenes) {
      const hit: string | undefined = scenes.get(s);
      if (hit !== undefined) {
        const i: number = hit.indexOf(':');
        const c: number = Number.parseInt(hit.substring(0, i), 10);
        return new FakeAnswer(c, hit.substring(i + 1), 400, c === 42901 ? '30' : null);
      }
    }
    if (code === '200020') {
      return new FakeAnswer(20002, '{}', 400);
    }
    if (code === '200030') {
      return new FakeAnswer(20003, '{}', 400);
    }
    if (!/^1[0-9]{10}$/.test(phone.replace(/[\s-]/g, ''))) {
      return new FakeAnswer(20001, '{"fields":["phone"],"reason":"phone_invalid"}', 400);
    }
    // 换号成功：本账号的绑定号码换成新号（不回显），旧的注销进度不变。
    DebugFakeAccount.state(auth).phone = phone;
    return new FakeAnswer(0, '{}', 600);
  }

  private static abandon(auth: string | undefined, body: string): FakeAnswer {
    if (DebugFakeAccount.has('abandon_busy')) {
      return new FakeAnswer(40901, '{}', 600);
    }
    if (DebugFakeAccount.has('abandon_10405')) {
      return new FakeAnswer(10405, '{"min_supported_version":"9.0.0"}', 400);
    }
    const deletion: boolean = body.indexOf('"account_deletion"') >= 0;
    if (DebugFakeAccount.has('abandon_completed')) {
      if (deletion) {
        const s: AccountState = DebugFakeAccount.state(auth);
        s.deletion = DebugFakeAccount.record('cooling', true, null);
        return new FakeAnswer(0, '{"outcome":"completed","original":{"code":0,"msg":"","data":' + s.deletion + '}}', 600);
      }
      return new FakeAnswer(0, '{"outcome":"completed","original":{"code":0,"msg":"","data":{}}}', 600);
    }
    if (DebugFakeAccount.has('abandon_completed_3xxxx')) {
      return new FakeAnswer(0, deletion ? '{"outcome":"completed","original":{"code":30412,"msg":""}}'
        : '{"outcome":"completed","original":{"code":30411,"msg":""}}', 600);
    }
    return new FakeAnswer(0, '{"outcome":"abandoned","original":null}', 600);
  }

  private static summary(): FakeAnswer | null {
    if (DebugFakeAccount.has('wallet_fail')) {
      return new FakeAnswer(50001, '{}', 300);
    }
    const neg: number = DebugFakeAccount.has('negative200') ? 200 : DebugFakeAccount.has('negative567') ? 567 : 0;
    if (neg === 0) {
      return null;
    }
    return new FakeAnswer(0, '{"available_fen":' + (-neg) + ',"withdrawable_fen":0,"negative_fen":' + neg
      + ',"frozen_fen":0,"estimated_total_fen":5678,"estimated_fen":2222,"pending_credit_fen":3456,'
      + '"pending_credit_paused_fen":0,"next_credit_period":"2026-10","credit_overdue":false,"withdrawn_fen":500,'
      + '"risk_paused_reason":null,"withdraw_enabled":true}', 300);
  }
}
