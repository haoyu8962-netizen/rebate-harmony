// APP-05b harmony-review-r2 的回归测试（R2-01…R2-04；APP-05b 共性 8–11）。真实 ApiClient、Router、StackNavigator、
// RouterLoginHost、LoginService、OAuthLoginService、BindPhoneService；第三方 SDK 用可控适配器。不连任何地址；无像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  AuthAnnouncement, AuthFeedback, BindOutcome, BindPhoneAnnouncer, GuardDecision, LoginOutcome, OAuthLoginOutcome,
  OAuthProvider, SendCodeOutcome, SessionState, SessionTokenSet, TransportRequest, TransportResponse, UpdateCheckStatus,
  UpdateState
} from '../../Index';
import { Deferred, envelope, flush } from './NetworkTestRig';
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

/** 只改一个接口的回答，其余照假服务。 */
function answerFor(f: OAuthFixture, pathPart: string, response: TransportResponse, exact: boolean = false): void {
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    const hit: boolean = exact ? r.url.endsWith(pathPart) : r.url.indexOf(pathPart) >= 0;
    return hit ? Promise.resolve(response) : f.answer(r);
  };
}

/**
 * 第三方新号登录、不绑手机（引导【暂不】）、留下 InviteShare 待办，然后「冷启动」：同一份令牌与持久化的待办交给新的装配
 * （内存里的 phone_bound 丢失），状态同步前补查 getMe（与 App 的 syncSession 同义）。
 */
async function coldStartAfterNewUserSkippedBinding(serverPhoneBound: boolean): Promise<OAuthFixture> {
  const before: OAuthFixture = new OAuthFixture();
  before.newUser = true;
  before.openInApp('InviteShare');
  const outcome: OAuthLoginOutcome = await loginWechat(before, 'code-new');
  expect(outcome.routeRaw).assertEqual('bind_phone_guide');
  before.service.resumeHeldPending();
  expect(before.router.hasPendingAction).assertTrue();
  expect(before.stack.names.indexOf('InviteShare')).assertEqual(-1);
  const after: OAuthFixture = new OAuthFixture(before.rig.tokens, before.backend);
  after.phoneBound = serverPhoneBound;
  after.verifyOnSync = true;
  return after;
}

export default function app05bReviewR2Test() {
  describe('App05bReviewR2', () => {
    // ---------------------------------------------------------------- R2-01 冷启动 phone_bound 未知按未验证
    it('r2_01_cold_start_new_user_without_phone_keeps_invite_share_and_queries_get_me', 0, async () => {
      const f: OAuthFixture = await coldStartAfterNewUserSkippedBinding(false);
      // 冷启动时还不知道 phone_bound：不能当已绑。
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
      f.stateChanged();
      // 没有直接进入 InviteShare，待办保留，冷启动不自动弹前置页。
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.router.hasPendingAction).assertTrue();
      await flush();
      expect(f.count('/v1/me')).assertEqual(1);
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.stack.names.indexOf('BindPhone')).assertEqual(-1);
      expect(f.router.hasPendingAction).assertTrue();
      expect(f.phoneBinding.get(f.rig.client.sessionAccount())).assertFalse();
    });

    it('r2_01_cold_start_get_me_bound_resumes_through_router', 0, async () => {
      const f: OAuthFixture = await coldStartAfterNewUserSkippedBinding(true);
      f.stateChanged();
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      await flush();
      expect(f.count('/v1/me')).assertEqual(1);
      // 查清已绑（且仍是发起查询的会话）后经 Router 守卫恢复：执行一次并删除。
      expect(f.stack.names.indexOf('InviteShare') >= 0).assertTrue();
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.guardState().sessionState).assertEqual(SessionState.PHONE_BOUND);
    });

    it('r2_01_cold_start_get_me_failure_keeps_pending_and_retries_on_next_sync', 0, async () => {
      const f: OAuthFixture = await coldStartAfterNewUserSkippedBinding(true);
      answerFor(f, '/v1/me', envelope(50001, '{}'), true);
      f.stateChanged();
      await flush();
      expect(f.count('/v1/me')).assertEqual(1);
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.router.hasPendingAction).assertTrue();
      expect(f.guardState().sessionState).assertEqual(SessionState.LOGGED_IN);
      // 下一次状态同步再查；这次成功即恢复。
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => f.answer(r);
      f.stateChanged();
      await flush();
      expect(f.count('/v1/me')).assertEqual(2);
      expect(f.stack.names.indexOf('InviteShare') >= 0).assertTrue();
    });

    it('r2_01_cold_start_get_me_of_replaced_session_is_not_applied', 0, async () => {
      const f: OAuthFixture = await coldStartAfterNewUserSkippedBinding(true);
      const me: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
        r.url.endsWith('/v1/me') ? me.promise : f.answer(r);
      f.stateChanged();
      await flush();
      // getMe 在途时换成另一账号的会话。
      f.rig.client.onSessionChanged();
      f.rig.tokens.save(new SessionTokenSet('other-access', 'other-refresh', 'full', 'user-7'));
      me.resolve(envelope(0, '{"user_id":"user-9","phone_bound":true}'));
      await flush();
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      expect(f.phoneBinding.get('user-9')).assertNull();
      expect(f.phoneBinding.get('user-7')).assertNull();
    });

    it('r2_01_sms_login_marks_session_phone_bound', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.openInApp('InviteShare');
      const outcome: LoginOutcome = await f.service.login(PHONE, '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual(LoginOutcome.LOGGED_IN);
      expect(f.guardState().sessionState).assertEqual(SessionState.PHONE_BOUND);
      expect(f.stack.names.indexOf('InviteShare') >= 0).assertTrue();
      expect(f.count('/v1/me')).assertEqual(0);
    });

    // ---------------------------------------------------------------- R2-02 暂缓是持续状态
    it('r2_02_update_check_finishing_during_guide_does_not_consume_pending', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = true;
      f.openInApp('OrderList');
      expect(f.router.hasPendingAction).assertTrue();
      // 登录完成时版本检查尚未结束。
      f.status = UpdateCheckStatus.checking(f.rig.nowMillis);
      const outcome: OAuthLoginOutcome = await loginWechat(f, 'code-new');
      expect(outcome.routeRaw).assertEqual('bind_phone_guide');
      expect(f.tab).assertEqual('Home');
      // 引导还开着：版本检查返回正常、触发状态同步——不得恢复待办。
      f.status = UpdateCheckStatus.finished(UpdateState.OK);
      f.stateChanged();
      expect(f.tab).assertEqual('Home');
      expect(f.router.hasPendingAction).assertTrue();
      // 其他自动入口同样遵守。
      f.router.resumePending();
      f.router.prerequisiteCompleted();
      expect(f.tab).assertEqual('Home');
      expect(f.router.hasPendingAction).assertTrue();
      // 【暂不】明确释放后才恢复。
      f.service.resumeHeldPending();
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
    });

    it('r2_02_hold_is_released_by_bind_completion_and_ends_with_session', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = true;
      f.openInApp('InviteShare');
      await loginWechat(f, 'code-new');
      expect(f.service.pendingHeld()).assertTrue();
      f.stateChanged();
      expect(f.stack.names.indexOf('InviteShare')).assertEqual(-1);
      // 绑定完成（AppLogin.phoneBound：释放暂缓后按完成前置恢复）。
      f.phoneBinding.set(f.rig.client.sessionAccount(), true);
      f.service.endHold();
      f.router.prerequisiteCompleted();
      expect(f.stack.names.indexOf('InviteShare') >= 0).assertTrue();
      expect(f.router.hasPendingAction).assertFalse();
      // 暂缓绑定在会话世代上：换了会话自动失效。
      const g: OAuthFixture = new OAuthFixture();
      g.newUser = true;
      g.openInApp('OrderList');
      await loginWechat(g, 'code-new');
      expect(g.service.pendingHeld()).assertTrue();
      g.rig.client.onSessionChanged();
      expect(g.service.pendingHeld()).assertFalse();
    });

    // ---------------------------------------------------------------- R2-03 10007 冷静期跳注销进度页
    it('r2_03_bind_10007_cooling_navigates_to_delete_account_without_toast', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      answerFor(f, '/v1/me/phone', envelope(10007, '{"stage":"cooling"}'));
      const outcome: BindOutcome = await f.bind.bind(PHONE, '123456');
      expect(outcome.actionRaw).assertEqual(BindOutcome.NAVIGATE);
      expect(outcome.route).assertEqual('DeleteAccount');
      const feedback: AuthFeedback = AuthFeedback.ofBind(outcome);
      expect(feedback.kind).assertEqual(AuthFeedback.NAVIGATE);
      expect(feedback.route).assertEqual('DeleteAccount');
      expect(feedback.textKey).assertNull();
      // 页面经 Router 打开（守卫照常判定），不是自己推页。
      const decision: GuardDecision = f.openInApp(feedback.route ?? '');
      expect(f.router.lastDecision === decision).assertTrue();
    });

    it('r2_03_bind_10007_processing_only_prompts', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      answerFor(f, '/v1/me/phone', envelope(10007, '{"stage":"processing"}'));
      const outcome: BindOutcome = await f.bind.bind(PHONE, '123456');
      expect(outcome.route).assertNull();
      const feedback: AuthFeedback = AuthFeedback.ofBind(outcome);
      expect(feedback.kind).assertEqual(AuthFeedback.TOAST);
      expect(feedback.textKey).assertEqual('error.10007');
    });

    it('r2_03_bind_send_10007_cooling_navigates_and_stale_result_does_not', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      answerFor(f, '/v1/auth/sms-codes', envelope(10007, '{"stage":"cooling"}'));
      const sent: SendCodeOutcome = await f.bind.sendCode(PHONE);
      expect(AuthFeedback.ofBindSend(sent).kind).assertEqual(AuthFeedback.NAVIGATE);
      expect(AuthFeedback.ofBindSend(sent).route).assertEqual('DeleteAccount');
      // 请求已失效（离页、换号）：不跳转。
      const pending: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
        r.url.indexOf('/v1/me/phone') >= 0 ? pending.promise : f.answer(r);
      const running: Promise<BindOutcome> = f.bind.bind(PHONE, '123456');
      await flush();
      f.bind.invalidate();
      pending.resolve(envelope(10007, '{"stage":"cooling"}'));
      const late: BindOutcome = await running;
      expect(late.actionRaw).assertEqual(BindOutcome.STALE);
      expect(AuthFeedback.ofBind(late).kind).assertEqual(AuthFeedback.NONE);
    });

    // ---------------------------------------------------------------- R2-04 发码成功与可重发的读屏播报
    it('r2_04_code_sent_announces_masked_target_once_for_current_request', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const announcer: BindPhoneAnnouncer = new BindPhoneAnnouncer();
      expect(announcer.tick(PHONE, 0)).assertNull();
      const sent: SendCodeOutcome = await f.bind.sendCode(PHONE);
      const said: AuthAnnouncement | null = announcer.sendResult(sent, PHONE);
      expect(said === null).assertFalse();
      expect((said as AuthAnnouncement).textKey).assertEqual('login.code.sent_to');
      expect((said as AuthAnnouncement).vars.get('phone')).assertEqual('138****8000');
      // 已换号：旧号码的结果不播报；没有新发出（countdown_active）也不播报。
      expect(announcer.sendResult(sent, OTHER_PHONE)).assertNull();
      const again: SendCodeOutcome = await f.bind.sendCode(PHONE);
      expect(again.stateRaw).assertEqual('countdown_active');
      expect(announcer.sendResult(again, PHONE)).assertNull();
      // 迟到（stale）不播报。
      expect(announcer.sendResult(new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null), PHONE)).assertNull();
    });

    it('r2_04_countdown_end_announces_resend_once_and_not_per_second', 0, () => {
      const announcer: BindPhoneAnnouncer = new BindPhoneAnnouncer();
      expect(announcer.sendResult(new SendCodeOutcome('code_sent', 60, null, null, PHONE), PHONE) === null).assertFalse();
      expect(announcer.tick(PHONE, 60)).assertNull();
      expect(announcer.tick(PHONE, 30)).assertNull();
      expect(announcer.tick(PHONE, 1)).assertNull();
      const ready: AuthAnnouncement | null = announcer.tick(PHONE, 0);
      expect(ready === null).assertFalse();
      expect((ready as AuthAnnouncement).textKey).assertEqual('bind_phone.a11y.resend_ready');
      expect(announcer.tick(PHONE, 0)).assertNull();
      // 42901 的等待结束同样播报一次。
      expect(announcer.tick(PHONE, 5)).assertNull();
      expect(announcer.tick(PHONE, 0) === null).assertFalse();
    });

    it('r2_04_phone_change_and_leaving_page_suppress_announcements', 0, () => {
      const announcer: BindPhoneAnnouncer = new BindPhoneAnnouncer();
      announcer.sendResult(new SendCodeOutcome('code_sent', 60, null, null, PHONE), PHONE);
      expect(announcer.tick(PHONE, 40)).assertNull();
      // 换号：新号码没有在等待，不播报旧号码的倒计时结束。
      expect(announcer.tick(OTHER_PHONE, 0)).assertNull();
      expect(announcer.tick(OTHER_PHONE, 0)).assertNull();
      // 离页之后一律不播报。
      announcer.tick(PHONE, 10);
      announcer.dispose();
      expect(announcer.tick(PHONE, 0)).assertNull();
      expect(announcer.sendResult(new SendCodeOutcome('code_sent', 60, null, null, PHONE), PHONE)).assertNull();
    });
  });
}
