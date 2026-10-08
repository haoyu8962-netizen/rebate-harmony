// APP-05b 第三方登录、绑手机与并号的本地假服务集成测试（brief §2.6）：第三方登录成功、取消、迟到回调丢弃、新号进绑手机引导、
// 绑手机成功、被占用进并号、并号确认 / 取消、登录中另一会话变化时不误存。真实 ApiClient、Router、StackNavigator、RouterLoginHost、
// LoginService、OAuthLoginService、BindPhoneService；只有第三方 SDK 用可控适配器。不连任何地址；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  BindOutcome, BindPhoneAction, LoginOutcome, MergeDecision, MergeResult, OAuthLoginErrorAction, OAuthLoginOutcome,
  OAuthLoginRoute, OAuthLoginService, OAuthProvider, PhoneBindingState, SendCodeOutcome, SessionState, ThirdPartyAuthKind,
  ThirdPartyAuthResult, TransportRequest, TransportResponse, UnavailableWechatAdapter
} from '../../Index';
import { Deferred, envelope, flush } from './NetworkTestRig';
import { FakeAuthAdapter, OAuthFixture, oauthLoginData } from './App05bFixture';

const CONSENT_AT: number = 1790661600000;

/** 适配器带回本次 nonce 作为 state。 */
function answerWithNonce(f: OAuthFixture, code: string): void {
  const nonce: string = f.adapter.nonces[f.adapter.nonces.length - 1];
  f.adapter.resolve(FakeAuthAdapter.credential(code, nonce));
}

function startWechat(f: OAuthFixture): Promise<OAuthLoginOutcome> {
  return f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
}

export default function oauthLoginIntegrationTest() {
  describe('OAuthLoginIntegration', () => {
    it('wechat_existing_user_logs_in_saves_session_and_resumes_pending', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.openInApp('OrderList');
      expect(f.router.hasPendingAction).assertTrue();
      expect(f.stack.names.indexOf('Login') >= 0).assertTrue();
      const running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      expect(f.adapter.nonces[0]).assertEqual('nonce-1');
      answerWithNonce(f, 'code-one');
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.LOGGED_IN);
      expect(outcome.routeRaw).assertEqual(OAuthLoginRoute.DONE);
      expect(f.rig.tokens.accessToken()).assertEqual('oauth-access');
      // 只上送授权尝试与授权凭证（+ 协议版本与同意时刻），不带 union_id / open_id / nonce 等。
      const attempt: Record<string, Object> = f.bodyOf('/v1/auth/oauth-attempts');
      expect(JSON.stringify(attempt)).assertEqual('{"provider":"wechat","purpose":"login"}');
      const body: Record<string, Object> = f.bodyOf('/v1/auth/login/wechat');
      expect(JSON.stringify(Object.keys(body).sort())).assertEqual('["attempt_id","code","consent_at","legal_versions"]');
      expect(body['attempt_id'] as string).assertEqual('attempt-1');
      expect(body['code'] as string).assertEqual('code-one');
      expect(f.stack.names.indexOf('Login')).assertEqual(-1);
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
      expect(JSON.stringify(f.oauth.session.submitted.length)).assertEqual('1');
    });

    it('wechat_new_user_routes_to_bind_phone_guide_and_holds_pending_until_released', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = true;
      f.openInApp('OrderList');
      const running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      answerWithNonce(f, 'code-new');
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.LOGGED_IN);
      expect(outcome.routeRaw).assertEqual(OAuthLoginRoute.BIND_PHONE_GUIDE);
      // 第三方新号没有手机号：守卫的会话状态是「已登录未绑手机」。
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
      // 引导期间待办保留，不恢复（BR-INV-03 细则 ①）；登录页已关。
      expect(f.stack.names.indexOf('Login')).assertEqual(-1);
      expect(f.router.hasPendingAction).assertTrue();
      expect(f.tab).assertEqual('Home');
      expect(f.host.calls.indexOf('sessionSynced') >= 0).assertTrue();
      expect(f.host.calls.indexOf('resumePending')).assertEqual(-1);
      // 【暂不】：继续执行待办（OrderList 只要登录）。
      f.service.resumeHeldPending();
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
    });

    it('user_cancel_in_sdk_does_not_submit_or_save', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.adapter.next = ThirdPartyAuthResult.of(ThirdPartyAuthKind.CANCELLED);
      const outcome: OAuthLoginOutcome = await f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.CANCELLED);
      expect(f.count('/v1/auth/login/wechat')).assertEqual(0);
      expect(f.rig.tokens.accessToken()).assertNull();
    });

    it('late_callback_after_leaving_login_page_is_dropped', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.openInApp('OrderList');
      const running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      // 用户离开登录页（导航栈移除 Login 的同步出口作废本次尝试）：等待立即结束，不等 SDK。
      f.navigator.remove('Login');
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      // 回前台后迟到的回调：只丢弃。
      answerWithNonce(f, 'code-late');
      await flush();
      expect(f.oauth.session.dropped.length).assertEqual(1);
      expect(f.oauth.session.submitted.length).assertEqual(0);
      expect(f.count('/v1/auth/login/wechat')).assertEqual(0);
      expect(f.rig.tokens.accessToken()).assertNull();
    });

    it('authorization_timeout_ends_attempt_and_late_callback_is_dropped', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      f.fireTimeout();
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.TIMEOUT);
      expect(outcome.textKey).assertEqual('error.20004');
      answerWithNonce(f, 'code-late');
      await flush();
      expect(f.oauth.session.dropped.length).assertEqual(1);
      expect(f.count('/v1/auth/login/wechat')).assertEqual(0);
    });

    it('state_not_matching_nonce_is_not_submitted', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      f.adapter.resolve(FakeAuthAdapter.credential('code-x', 'another-nonce'));
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(OAuthLoginErrorAction.REAUTHORIZE);
      expect(f.count('/v1/auth/login/wechat')).assertEqual(0);
    });

    it('session_change_while_login_in_flight_does_not_save', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.loginDeferred = new Deferred();
      const running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      answerWithNonce(f, 'code-two');
      await flush();
      expect(f.count('/v1/auth/login/wechat')).assertEqual(1);
      // 登录请求在途时另一处换了会话（退出 / 切换账号）：旧登录响应不得保存。
      f.rig.client.onSessionChanged();
      (f.loginDeferred as Deferred).resolve(envelope(0, oauthLoginData(false)));
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.host.calls.indexOf('closeLogin')).assertEqual(-1);
    });

    it('leaving_login_page_while_login_in_flight_does_not_save', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.openInApp('OrderList');
      f.loginDeferred = new Deferred();
      const running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      answerWithNonce(f, 'code-three');
      await flush();
      f.navigator.remove('Login');
      (f.loginDeferred as Deferred).resolve(envelope(0, oauthLoginData(false)));
      const outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.router.hasPendingAction).assertTrue();
    });

    it('errors_map_to_reauthorize_and_provider_unavailable_without_retry', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/login/wechat') >= 0) {
          return Promise.resolve(envelope(20004, '{}'));
        }
        return f.answer(r);
      };
      let running: Promise<OAuthLoginOutcome> = startWechat(f);
      await flush();
      answerWithNonce(f, 'code-a');
      let outcome: OAuthLoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(OAuthLoginErrorAction.REAUTHORIZE);
      expect(outcome.textKey).assertEqual('error.20004');
      expect(f.count('/v1/auth/login/wechat')).assertEqual(1);
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/login/wechat') >= 0) {
          return Promise.resolve(TransportResponse.ok(503, {},
            '{"code":50305,"msg":"","data":{"provider":"wechat"},"trace_id":"trace-abcdef123456"}'));
        }
        return f.answer(r);
      };
      // 重新授权 = 重新取尝试（attempt-2），不复用原尝试。
      running = startWechat(f);
      await flush();
      answerWithNonce(f, 'code-b');
      outcome = await running;
      expect(outcome.stateRaw).assertEqual(OAuthLoginErrorAction.PROVIDER_UNAVAILABLE);
      expect(outcome.textKey).assertEqual('error.50305');
      expect(f.bodyOf('/v1/auth/login/wechat')['attempt_id'] as string).assertEqual('attempt-2');
      expect(f.count('/v1/auth/login/wechat')).assertEqual(2);
      expect(f.rig.tokens.accessToken()).assertNull();
    });

    it('agreement_required_before_any_request', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const outcome: OAuthLoginOutcome = await f.oauth.loginWith(OAuthProvider.WECHAT, null);
      expect(outcome.stateRaw).assertEqual(LoginOutcome.AGREEMENT_REQUIRED);
      expect(f.rig.server.received.length).assertEqual(0);
    });

    it('wechat_button_visibility_follows_adapter_and_install_state', 0, () => {
      const f: OAuthFixture = new OAuthFixture();
      expect(JSON.stringify(f.oauth.visibleProviders())).assertEqual('["wechat"]');
      // 检测结果未知：照常显示（BR-ID-04 细则），仍须适配器可用。
      f.adapter.installedRaw = null;
      expect(JSON.stringify(f.oauth.visibleProviders())).assertEqual('["wechat"]');
      f.adapter.installedRaw = false;
      expect(JSON.stringify(f.oauth.visibleProviders())).assertEqual('[]');
      // 鸿蒙正式适配器不可用：按钮不显示；即使被调用也不发任何请求。
      const formal: OAuthLoginService = new OAuthLoginService(f.rig.client, f.service, [new UnavailableWechatAdapter()],
        new PhoneBindingState());
      expect(JSON.stringify(formal.visibleProviders())).assertEqual('[]');
    });

    it('formal_unavailable_adapter_sends_nothing', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const formal: OAuthLoginService = new OAuthLoginService(f.rig.client, f.service, [new UnavailableWechatAdapter()],
        new PhoneBindingState());
      const outcome: OAuthLoginOutcome = await formal.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
      expect(outcome.stateRaw).assertEqual(OAuthLoginOutcome.UNAVAILABLE);
      expect(outcome.textKey).assertEqual('login.wechat_unavailable');
      expect(f.rig.server.received.length).assertEqual(0);
    });

    it('bind_phone_sends_bind_code_then_binds_refreshes_me_and_session_state', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      f.phoneBinding.set('user-1', false);
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
      const sent: SendCodeOutcome = await f.bind.sendCode('138 0013 8000');
      expect(sent.stateRaw).assertEqual('code_sent');
      expect(JSON.stringify(f.bodyOf('/v1/auth/sms-codes'))).assertEqual('{"phone":"13800138000","purpose":"bind"}');
      // 同号码 60 秒内不再发（与登录共用按号码的截止时间）。
      expect((await f.bind.sendCode('13800138000')).stateRaw).assertEqual('countdown_active');
      expect(f.count('/v1/auth/sms-codes')).assertEqual(1);
      const outcome: BindOutcome = await f.bind.bind('13800138000', '123456');
      expect(outcome.actionRaw).assertEqual(BindPhoneAction.DONE);
      // 首次绑定不带 step-up；成功后刷新 getMe。
      expect(f.rig.server.last('/v1/me/phone').headers['X-Step-Up-Token']).assertUndefined();
      expect(f.count('/v1/me')).assertEqual(2);
      expect(f.phoneBinding.get('user-1')).assertTrue();
      expect(f.guardState().sessionState).assertEqual(SessionState.PHONE_BOUND);
      expect(f.bindHost.bound).assertEqual(1);
    });

    it('occupied_mergeable_asks_confirmation_and_cancel_has_clear_result', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      f.phoneBinding.set('user-1', false);
      const outcome: BindOutcome = await f.bind.bind('13800005678', '123456');
      expect(outcome.actionRaw).assertEqual(BindPhoneAction.MERGE_CONFIRM);
      expect(outcome.textKey).assertEqual('error.30411.mergeable');
      expect(outcome.maskedPhone).assertEqual('138****5678');
      expect(f.bind.mergePending).assertTrue();
      const before: number = f.rig.server.received.length;
      const cancelled: MergeResult = f.bind.decideMerge(MergeDecision.CANCEL);
      expect(cancelled.resultRaw).assertEqual(MergeDecision.CANCELLED);
      expect(cancelled.saveSession).assertFalse();
      expect(f.bind.mergePending).assertFalse();
      expect(f.rig.server.received.length).assertEqual(before);
      expect(f.rig.tokens.accessToken()).assertEqual('old-access');
      expect(f.bindHost.bound).assertEqual(0);
    });

    it('merge_confirm_without_contract_operation_is_unavailable_and_sends_nothing', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      await f.bind.bind('13800005678', '123456');
      const before: number = f.rig.server.received.length;
      const confirmed: MergeResult = f.bind.decideMerge(MergeDecision.CONFIRM);
      // TODO(N-29) MERGE-SUCCESS：锁定契约没有并号接口——不伪造请求、不保存会话，给明确的「暂不可用」。
      expect(confirmed.resultRaw).assertEqual(MergeDecision.UNAVAILABLE);
      expect(confirmed.saveSession).assertFalse();
      expect(f.rig.server.received.length).assertEqual(before);
      expect(f.count('/v1/auth/merge')).assertEqual(0);
      expect(f.rig.tokens.accessToken()).assertEqual('old-access');
      // 没有待确认的并号时「确认」按取消处理。
      expect(f.bind.decideMerge(MergeDecision.CONFIRM).resultRaw).assertEqual(MergeDecision.CANCELLED);
    });

    it('occupied_not_mergeable_shows_30411_without_merge', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const outcome: BindOutcome = await f.bind.bind('13800001111', '123456');
      expect(outcome.actionRaw).assertEqual(BindPhoneAction.ERROR);
      expect(outcome.textKey).assertEqual('error.30411');
      expect(f.bind.mergePending).assertFalse();
    });

    it('bind_result_after_leaving_page_does_not_update_page', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const deferred: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
      r.url.indexOf('/v1/me/phone') >= 0 ? deferred.promise : f.answer(r);
      const running: Promise<BindOutcome> = f.bind.bind('13800005678', '123456');
      await flush();
      f.bind.invalidate();
      deferred.resolve(envelope(30411, '{"reason":"mergeable","merge_ticket":"test-merge-ticket"}'));
      const outcome: BindOutcome = await running;
      expect(outcome.actionRaw).assertEqual(BindOutcome.STALE);
      expect(f.bind.mergePending).assertFalse();
    });
  });
}
