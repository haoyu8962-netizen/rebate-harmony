// FU-HM-1112：APP-05b 共性第 13–18 条在鸿蒙上的回归测试。真实 ApiClient、Router、StackNavigator、RouterLoginHost、LoginService、
// OAuthLoginService、BindPhoneService；第三方 SDK 用可控适配器。不连任何地址；无像密钥的字面量。只新增，不改已有测试。
import { describe, it, expect } from '@ohos/hypium';
import {
  AuthAnnouncement, BindOutcome, BindPhoneAnnouncer, GuardDecision, GuardDecisionKind,
  NetworkHeaders, OAuthLoginOutcome, OAuthProvider, RouterLoginHost, SendCodeOutcome, SessionState, SessionTokenSet,
  TransportRequest, TransportResponse
} from '../../Index';
import { Deferred, envelope, flush, header } from './NetworkTestRig';
import { FakeAuthAdapter, OAuthFixture } from './App05bFixture';

const CONSENT_AT: number = 1790661600000;
const PHONE: string = '13800138000';
const OTHER_PHONE: string = '13900139000';

async function loginWechat(f: OAuthFixture, code: string): Promise<OAuthLoginOutcome> {
  const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
  await flush();
  const nonce: string = f.adapter.nonces[f.adapter.nonces.length - 1];
  f.adapter.resolve(FakeAuthAdapter.credential(code, nonce));
  return await running;
}

export default function followupHM1112LoginTest() {
  describe('FollowupHM1112Login', () => {
    // ---------------------------------------------------------------- 第 13 条：未知 = 未验证，所有入口
    it('app05b_13_cold_start_unknown_phone_blocks_active_open_of_phone_route', 0, () => {
      // 冷启动：本机有 full 会话，内存里不知道是否绑了手机（没查 getMe）。
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      expect(f.phoneBinding.get('user-1')).assertNull();
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
      // 用户主动打开需要手机号的路由（不是待办恢复）：同样按未验证，先进 BindPhone，不直接打开。
      const decision: GuardDecision = f.openInApp('InviteShare');
      expect(decision.kind).assertEqual(GuardDecisionKind.REQUIRE_BIND_PHONE);
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.stack.names.indexOf('BindPhone') >= 0).assertTrue();
      // 查清已绑（或本次短信登录完成）才算已绑。
      f.phoneBinding.set('user-1', true);
      expect(f.guardState().sessionState).assertEqual(SessionState.PHONE_BOUND);
    });

    // ---------------------------------------------------------------- 第 14 条：getMe 失败解除暂缓
    it('app05b_14_get_me_failure_releases_hold_and_resumes_login_level_pending', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = false;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
        r.url.endsWith('/v1/me') ? Promise.resolve(envelope(50001, '{}')) : f.answer(r);
      // 游客打开订单列表：登记 auth=login 的待办。
      f.openInApp('OrderList');
      expect(f.router.hasPendingAction).assertTrue();
      const outcome: OAuthLoginOutcome = await loginWechat(f, 'code-old');
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.LOGGED_IN);
      await flush();
      // 暂缓已解除；登录级待办经 Router 正常恢复（订单 Tab），不再挂起。
      expect(f.service.pendingHeld()).assertFalse();
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
    });

    it('app05b_14_get_me_failure_keeps_phone_level_pending_as_unverified', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = false;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
        r.url.endsWith('/v1/me') ? Promise.resolve(envelope(50001, '{}')) : f.answer(r);
      f.openInApp('InviteShare');
      await loginWechat(f, 'code-old');
      await flush();
      expect(f.service.pendingHeld()).assertFalse();
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.router.hasPendingAction).assertTrue();
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
    });

    // ---------------------------------------------------------------- 第 15 条：绑手机在每次实际写出前核对账号归属
    it('app05b_15_bind_retry_after_refresh_is_not_written_for_another_account', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const refresh: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        if (r.url.indexOf('/v1/me/phone') >= 0) {
          // 第一次写出带账号 A 的旧令牌：令牌过期，要刷新后重发。
          return Promise.resolve(envelope(10002, '{}'));
        }
        return f.answer(r);
      };
      const running: Promise<BindOutcome> = f.bind.bind(PHONE, '123456');
      await flush();
      expect(f.count('/v1/me/phone')).assertEqual(1);
      expect(header(f.rig.server.last('/v1/me/phone'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer old-access');
      // 刷新等待期间另一处保存了账号 B 的会话（绑手机页仍在栈里、页面序号没变）。
      f.rig.client.onSessionChanged();
      f.rig.tokens.save(new SessionTokenSet('other-access', 'other-refresh', 'full', 'user-7'));
      refresh.resolve(envelope(0, '{"access_token":"new-access","access_expires_at":"2026-10-02T13:30:00+08:00",'
        + '"refresh_token":"new-refresh","refresh_expires_at":"2026-11-01T11:30:00+08:00","session_scope":"full"}'));
      const outcome: BindOutcome = await running;
      await flush();
      // 不得用 B 的令牌（或刷新后的令牌）再写出 A 输入的手机号与验证码。
      expect(f.count('/v1/me/phone')).assertEqual(1);
      expect(outcome.actionRaw === BindOutcome.STALE || outcome.actionRaw === 'error').assertTrue();
      expect(f.bindHost.bound).assertEqual(0);
      expect(f.phoneBinding.get('user-7')).assertNull();
    });

    it('app05b_15_send_code_is_not_written_after_account_switch_before_dispatch', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      // 发码前的设备注册 / 未决键等异步等待用 10402 之外的路径难以构造；这里核对入口固定的归属：先切账号再结算的发码不更新页面。
      const pending: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
        r.url.indexOf('/v1/auth/sms-codes') >= 0 ? pending.promise : f.answer(r);
      const running: Promise<SendCodeOutcome> = f.bind.sendCode(PHONE);
      await flush();
      f.rig.client.onSessionChanged();
      f.rig.tokens.save(new SessionTokenSet('other-access', 'other-refresh', 'full', 'user-7'));
      pending.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      const sent: SendCodeOutcome = await running;
      expect(sent.stateRaw).assertEqual(BindOutcome.STALE);
    });

    // ---------------------------------------------------------------- 第 17 条：倒计时结束播报绑定原号码与真实截止时间
    it('app05b_17_clearing_or_switching_number_never_announces_and_original_number_still_does', 0, () => {
      const announcer: BindPhoneAnnouncer = new BindPhoneAnnouncer();
      expect(announcer.sendResult(new SendCodeOutcome('code_sent', 60, null, null, PHONE), PHONE) === null).assertFalse();
      expect(announcer.tick(PHONE, 40)).assertNull();
      // 清空：按钮不可用，不播报「可以重新获取」。
      expect(announcer.tick('', 0)).assertNull();
      expect(announcer.tick('', 0)).assertNull();
      // 换成另一个号码：不播报旧号码的倒计时结束。
      expect(announcer.tick(OTHER_PHONE, 0)).assertNull();
      // 切回原号码时原截止时间还没到：之后真正到期再播报一次。
      expect(announcer.tick(PHONE, 25)).assertNull();
      const ended: AuthAnnouncement | null = announcer.tick(PHONE, 0);
      expect(ended === null).assertFalse();
      expect((ended as AuthAnnouncement).textKey).assertEqual(BindPhoneAnnouncer.RESEND_READY_KEY);
      // 切走后原截止时间已过、再切回：不补播。
      announcer.sendResult(new SendCodeOutcome('code_sent', 60, null, null, PHONE), PHONE);
      expect(announcer.tick(PHONE, 30)).assertNull();
      expect(announcer.tick(OTHER_PHONE, 0)).assertNull();
      expect(announcer.tick(PHONE, 0)).assertNull();
    });

    it('app05b_17_countdown_uses_deadline_of_normalized_number', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      await f.bind.sendCode(PHONE);
      // 截止时间按规范化号码记；按时钟推进，不按 tick 次数。
      expect(f.bind.sendState(PHONE).countdownSec).assertEqual(60);
      f.rig.nowMillis += 59 * 1000;
      expect(f.bind.sendState(PHONE).countdownSec).assertEqual(1);
      f.rig.nowMillis += 1000;
      expect(f.bind.sendState(PHONE).countdownSec).assertEqual(0);
      expect(f.bind.sendState(OTHER_PHONE).countdownSec).assertEqual(0);
    });

    // ---------------------------------------------------------------- 第 18 条：桥 auth.login 的「已登录」
    it('app05b_18_bridge_logged_in_counts_unbound_full_session', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = true;
      expect(RouterLoginHost.bridgeLoggedIn(f.rig.client)).assertFalse();
      await loginWechat(f, 'code-new');
      f.service.resumeHeldPending();
      // 第三方新号跳过绑手机：守卫是已登录未绑手机（LOGGED_IN），桥仍按已登录回复。
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
      expect(RouterLoginHost.bridgeLoggedIn(f.rig.client)).assertTrue();
      expect(RouterLoginHost.bridgeLoggedIn(null)).assertFalse();
    });
  });
}
