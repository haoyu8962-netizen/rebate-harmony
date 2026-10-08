// APP-05b harmony-review-r1 的回归测试（R1-01…R1-06；APP-05b 共性 1–6）。真实 ApiClient、Router、StackNavigator、
// RouterLoginHost、LoginService、OAuthLoginService、BindPhoneService；第三方 SDK 用可控适配器。不连任何地址；无像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiRequest, AuthFeedback, BindOutcome, LoginOutcome, OAuthLoginOutcome, OAuthProvider, PendingAction, SendCodeOutcome,
  SessionState, SessionTokenSet, TransportRequest, TransportResponse
} from '../../Index';
import { envelope, flush } from './NetworkTestRig';
import { FakeAuthAdapter, OAuthFixture } from './App05bFixture';

const CONSENT_AT: number = 1790661600000;
const MINUTE: number = 60 * 1000;

function answerWithNonce(f: OAuthFixture, code: string): void {
  const nonce: string = f.adapter.nonces[f.adapter.nonces.length - 1];
  f.adapter.resolve(FakeAuthAdapter.credential(code, nonce));
}

async function loginWechat(f: OAuthFixture, code: string): Promise<OAuthLoginOutcome> {
  const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
  await flush();
  answerWithNonce(f, code);
  return await running;
}

function timerStart(f: OAuthFixture): number {
  const pending: PendingAction | null = f.store.load(f.rig.nowMillis);
  return pending === null ? -1 : pending.timerStartedAt;
}

/** 只改一个接口的回答，其余照假服务。 */
function answerFor(f: OAuthFixture, pathPart: string, response: TransportResponse, exact: boolean = false): void {
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    const hit: boolean = exact ? r.url.endsWith(pathPart) : r.url.indexOf(pathPart) >= 0;
    return hit ? Promise.resolve(response) : f.answer(r);
  };
}

export default function app05bReviewR1Test() {
  describe('App05bReviewR1', () => {
    // ---------------------------------------------------------------- R1-01 授权等待期间换了会话
    it('r1_01_session_saved_while_authorizing_ends_attempt_without_submit', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.openInApp('OrderList');
      const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
      await flush();
      expect(f.adapter.nonces.length).assertEqual(1);
      // 等授权时另一处保存了别的账号的会话（登录页尝试序号不变）。
      f.rig.client.onSessionChanged();
      f.rig.tokens.save(new SessionTokenSet('other-access', 'other-refresh', 'full', 'user-7'));
      answerWithNonce(f, 'code-late');
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      expect(f.count('/v1/auth/login/wechat')).assertEqual(0);
      expect(f.oauth.session.submitted.length).assertEqual(0);
      expect(f.rig.tokens.account()).assertEqual('user-7');
      expect(f.rig.tokens.accessToken()).assertEqual('other-access');
    });

    it('r1_01_privacy_or_environment_change_after_create_ends_attempt', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
      await flush();
      // 撤回同意 / 切换环境：作废世代推进。
      f.rig.client.invalidate();
      answerWithNonce(f, 'code-x');
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      expect(f.count('/v1/auth/login/wechat')).assertEqual(0);
    });

    // ---------------------------------------------------------------- R1-02 老用户先查 phone_bound 再恢复
    it('r1_02_existing_user_without_phone_goes_through_bind_phone_guard', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = false;
      f.phoneBound = false;
      f.openInApp('InviteShare');
      expect(f.router.hasPendingAction).assertTrue();
      const outcome: OAuthLoginOutcome = await loginWechat(f, 'code-old');
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.LOGGED_IN);
      expect(f.count('/v1/me')).assertEqual(1);
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.stack.names.indexOf('BindPhone') >= 0).assertTrue();
      expect(f.router.hasPendingAction).assertTrue();
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
    });

    it('r1_02_existing_user_with_phone_resumes_after_get_me', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = false;
      f.phoneBound = true;
      f.openInApp('InviteShare');
      await loginWechat(f, 'code-old');
      expect(f.stack.names.indexOf('InviteShare') >= 0).assertTrue();
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.guardState().sessionState).assertEqual(SessionState.PHONE_BOUND);
    });

    it('r1_02_get_me_failure_keeps_pending_and_does_not_treat_unknown_as_bound', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = false;
      answerFor(f, '/v1/me', envelope(50001, '{}'), true);
      f.openInApp('InviteShare');
      await loginWechat(f, 'code-old');
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.router.hasPendingAction).assertTrue();
      // 未知不能当已绑：守卫按已登录未绑手机。
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
      expect(f.phoneBinding.isUnverified(f.rig.client.sessionAccount())).assertTrue();
    });

    it('r1_02_get_me_result_of_replaced_session_is_not_applied', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = false;
      f.phoneBound = true;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.endsWith('/v1/me')) {
          // getMe 在途时换成另一账号的会话。
          f.rig.client.onSessionChanged();
          f.rig.tokens.save(new SessionTokenSet('other-access', 'other-refresh', 'full', 'user-7'));
        }
        return f.answer(r);
      };
      f.openInApp('InviteShare');
      await loginWechat(f, 'code-old');
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.phoneBinding.get('user-9')).assertNull();
      expect(f.phoneBinding.get('user-7')).assertNull();
    });

    // ---------------------------------------------------------------- R1-03 计时：登录时重置、引导结束只恢复
    it('r1_03_new_user_login_resets_timer_and_skip_only_resumes', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = true;
      const t0: number = f.rig.nowMillis;
      f.openInApp('OrderList');
      expect(timerStart(f)).assertEqual(t0);
      f.rig.nowMillis = t0 + 9 * MINUTE;
      const outcome: OAuthLoginOutcome = await loginWechat(f, 'code-new');
      expect(outcome.routeRaw).assertEqual('bind_phone_guide');
      // 登录成功即完成一个前置步骤：计时从登录时刻重算，但暂缓执行。
      expect(timerStart(f)).assertEqual(t0 + 9 * MINUTE);
      expect(f.tab).assertEqual('Home');
      f.rig.nowMillis = t0 + 11 * MINUTE;
      f.service.resumeHeldPending();
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
    });

    it('r1_03_skip_does_not_extend_timer_and_expired_pending_is_not_revived', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = true;
      const t0: number = f.rig.nowMillis;
      f.openInApp('InviteShare');
      f.rig.nowMillis = t0 + MINUTE;
      await loginWechat(f, 'code-new');
      // 【暂不】：需要手机号的待办经守卫进 BindPhone，记录保留，计时不因跳过而延长。
      f.rig.nowMillis = t0 + 8 * MINUTE;
      f.service.resumeHeldPending();
      expect(f.stack.names.indexOf('BindPhone') >= 0).assertTrue();
      expect(timerStart(f)).assertEqual(t0 + MINUTE);
      // 登录后 11 分钟才绑定成功：待办已过期，不得复活。
      f.rig.nowMillis = t0 + 12 * MINUTE;
      // 绑定成功（AppLogin.phoneBound：会话状态更新后按完成前置恢复）。
      f.phoneBinding.set(f.rig.client.sessionAccount(), true);
      f.router.prerequisiteCompleted();
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
    });

    // ---------------------------------------------------------------- R1-04 登出清理边界绑定被清的会话
    it('r1_04_logout_10404_after_earlier_network_clear_clears_current_pending', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      // 本进程先因 getMe 10404 清过一次会话（Router 记下那次的分界）。
      answerFor(f, '/v1/me', envelope(10404, '{}'), true);
      await f.rig.client.request(new ApiRequest('getMe'));
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.router.lastClearedSessionGeneration >= 0).assertTrue();
      // 重新登录（第三方老用户、未绑手机），再从 InviteShare 留下等待绑手机的待办。
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => f.answer(r);
      f.newUser = false;
      f.phoneBound = false;
      await loginWechat(f, 'code-again');
      f.openInApp('InviteShare');
      expect(f.router.hasPendingAction).assertTrue();
      // 主动登出，logout 自己回 10404。
      answerFor(f, '/v1/auth/logout', envelope(10404, '{}'));
      expect(await f.service.logout()).assertTrue();
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.host.calls.indexOf('sessionEnded') >= 0).assertTrue();
    });

    // ---------------------------------------------------------------- R1-05 风控拦截给申诉入口
    it('r1_05_bind_44001_presents_risk_dialog_with_appeal', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      answerFor(f, '/v1/me/phone', envelope(44001, '{}'));
      const outcome: BindOutcome = await f.bind.bind('13800138000', '123456');
      const feedback: AuthFeedback = AuthFeedback.ofBind(outcome);
      expect(feedback.kind).assertEqual(AuthFeedback.RISK_DIALOG);
      expect(feedback.textKey).assertEqual('error.44001');
      expect(feedback.appeal).assertTrue();
      expect(AuthFeedback.APPEAL_KEY).assertEqual('cs.appeal_entry');
    });

    it('r1_05_bind_send_44001_presents_risk_dialog', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      answerFor(f, '/v1/auth/sms-codes', envelope(44001, '{}'));
      const sent: SendCodeOutcome = await f.bind.sendCode('13800138000');
      const feedback: AuthFeedback = AuthFeedback.ofBindSend(sent);
      expect(feedback.kind).assertEqual(AuthFeedback.RISK_DIALOG);
      expect(feedback.appeal).assertTrue();
    });

    it('r1_05_oauth_risk_blocked_presents_appeal_without_sms_wording', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      answerFor(f, '/v1/auth/login/wechat', envelope(44001, '{}'));
      const outcome: OAuthLoginOutcome = await loginWechat(f, 'code-risk');
      expect(outcome.stateRaw).assertEqual('risk_blocked');
      const feedback: AuthFeedback = AuthFeedback.ofOAuth(outcome);
      expect(feedback.kind).assertEqual(AuthFeedback.RISK_DIALOG);
      expect(feedback.appeal).assertTrue();
      // 不套用短信登录专用说明（login.risk_blocked.desc 讲的是验证码）。
      expect(feedback.descKey).assertNull();
    });

    // ---------------------------------------------------------------- R1-06 字段错误落到字段（播报 + 焦点）
    it('r1_06_code_and_phone_errors_map_to_field_feedback', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const wrong: BindOutcome = await f.bind.bind('13800138000', '654321');
      expect(AuthFeedback.ofBind(wrong).kind).assertEqual(AuthFeedback.CODE_ERROR);
      expect(AuthFeedback.ofBind(wrong).textKey).assertEqual('error.20002');
      answerFor(f, '/v1/me/phone', envelope(20003, '{}'));
      const expired: BindOutcome = await f.bind.bind('13800138000', '654321');
      expect(AuthFeedback.ofBind(expired).kind).assertEqual(AuthFeedback.CODE_ERROR);
      expect(AuthFeedback.ofBind(expired).textKey).assertEqual('error.20003');
      const invalid: BindOutcome = await f.bind.bind('12', '123456');
      expect(AuthFeedback.ofBind(invalid).kind).assertEqual(AuthFeedback.PHONE_ERROR);
      const localSend: SendCodeOutcome = await f.bind.sendCode('12');
      expect(AuthFeedback.ofBindSend(localSend).kind).assertEqual(AuthFeedback.PHONE_ERROR);
      // 迟到 / 忙：不提示。
      expect(AuthFeedback.ofBind(new BindOutcome(BindOutcome.STALE)).kind).assertEqual(AuthFeedback.NONE);
      expect(AuthFeedback.ofBind(new BindOutcome('error', 'error.50001')).kind).assertEqual(AuthFeedback.TOAST);
    });
  });
}
