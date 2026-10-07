// APP-05a 短信登录的集成测试：本地假服务（FakeServer，不连任何地址）+ 真实 ApiClient + 真实 Router + 生产的登录出口与路由同步
// （RouterLoginHost、StackNavigator、RoutingSync——与 entry AppLogin / AppRouting 同一份代码，harmony-review-r1 R1-01 / R1-02：
// 不用会重置导航栈的测试替身）。导航栈是内存版 PathStack（NavPathStack 的同名方法、同一语义），Tab 根路由按外壳处理（切 Tab、
// 不入栈）。强更模块按生产的 UpdateNetworkPort 接到网络层，on10405 与 AppUpdate 一样直接进 below_min。
// 覆盖任务书 §2.5：发码成功并倒计时、42901 带 Retry-After、验证码错误与过期、登录成功后恢复 pending_action、
// deletion_only 且强更未知时进强更页、注销中的账号、登出后回到游客；另有等待后复核、保存失败、协议未勾选不发出，
// 以及第 1 轮评审 R1-01（作废后的迟到响应）、R1-02（强更页进入的受限登录关闭登录页）、R1-03（登出遇 10404 仍完成清理）、
// R1-04（deletion_only 与 supported 并存不丢待办）、R1-05（同号码倒计时内不再发码）；第 2 轮 R2-01（出栈的同步出口作废尝试）、
// R2-02（受限会话复查带归属、作废后只同步会话不恢复待办）、R2-03（发码与登录的限流截止时间分开）；第 3 轮 R3-01（发码限流期间仍能回验证码步用已收到的码）。
import { describe, it, expect } from '@ohos/hypium';
import {
  AfterLoginAction, GuardDecision, GuardDecisionKind, GuardState, LaunchReadiness, LegalVersions,
  LoginHost, LoginOutcome, LoginRateLimits, LoginService, MemoryPendingBackend, MemorySessionTokens, NetworkHeaders, PathStack,
  PendingActionStore, PhoneEntry, PrivacyState, RouteDestination, RouteRequest, RouteSource, Router, RouterLoginHost, RouteTable,
  RoutingSync,
  SendCodeOutcome, SessionTokenSet, StackNavigator, TransportRequest, TransportResponse, UpdateCheckStatus,
  UpdateNetworkPort, UpdateState
} from '../../Index';
import { RouteSpec } from 'generated';
import { envelope, flush, header, Rig, tokenPair } from './NetworkTestRig';

/** 内存导航栈：与 NavPathStack 的 pushPathByName / clear / removeByName / getAllPathName 同义。 */
class MemoryPathStack implements PathStack {
  names: string[] = [];

  pushPathByName(name: string, _param: Object): void {
    this.names.push(name);
  }

  clear(): void {
    this.names = [];
  }

  removeByName(name: string): void {
    this.names = this.names.filter((n: string) => n !== name);
  }

  getAllPathName(): string[] {
    return this.names.slice();
  }
}

const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];

/** 只记录调用顺序、每个调用都原样交给生产出口 RouterLoginHost（不改变任何行为）。 */
class RecordingHost implements LoginHost {
  readonly calls: string[] = [];
  private readonly inner: RouterLoginHost;

  constructor(inner: RouterLoginHost) {
    this.inner = inner;
  }

  updateState(): string {
    return this.inner.updateState();
  }

  hasPendingAction(): boolean {
    return this.inner.hasPendingAction();
  }

  closeLogin(): void {
    this.calls.push('closeLogin');
    this.inner.closeLogin();
  }

  resumePending(): void {
    this.calls.push('resumePending');
    this.inner.resumePending();
  }

  discardPending(): void {
    this.calls.push('discardPending');
    this.inner.discardPending();
  }

  enterForceUpdate(): void {
    this.calls.push('enterForceUpdate');
    this.inner.enterForceUpdate();
  }

  sessionChanged(): void {
    this.calls.push('sessionChanged');
    this.inner.sessionChanged();
  }

  sessionEnded(): void {
    this.calls.push('sessionEnded');
    this.inner.sessionEnded();
  }

  sessionSynced(): void {
    this.calls.push('sessionSynced');
    this.inner.sessionSynced();
  }
}

class Fixture {
  readonly rig: Rig;
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly store: PendingActionStore;
  readonly router: Router;
  readonly sync: RoutingSync;
  readonly host: RecordingHost;
  /** 生产出口（RecordingHost 原样转给它）。 */
  readonly inner: RouterLoginHost;
  readonly service: LoginService;
  /** 强更检查进度（AppUpdate.routerStatus 的对应物）。 */
  status: UpdateCheckStatus = UpdateCheckStatus.finished(UpdateState.OK);
  /** 当前 Tab（外壳）。 */
  tab: string = 'Home';
  readonly forceUpdateCalls: (string | null)[] = [];

  constructor(tokens: MemorySessionTokens | null = null) {
    const port: UpdateNetworkPort = new UpdateNetworkPort((): UpdateState => this.status.result ?? UpdateState.UNKNOWN,
      (minSupported: string | null): void => this.markBelow(minSupported));
    this.rig = new Rig(null, null, tokens, null, port);
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => {
      if (d.route === null || TAB_ROOTS.indexOf(d.route) < 0) {
        return false;
      }
      this.tab = d.route;
      return true;
    };
    this.store = new PendingActionStore(new MemoryPendingBackend(), (): number => this.rig.nowMillis);
    this.router = new Router(this.store, (): GuardState => this.guardState(false), this.navigator,
      (name: string): RouteSpec | undefined => RouteTable.spec(name), (): LaunchReadiness => this.readiness());
    this.sync = new RoutingSync(this.router, this.navigator, (): boolean => true);
    this.inner = new RouterLoginHost(this.router, this.navigator, (): UpdateCheckStatus => this.status,
      (): void => this.markBelow(null), (resumePending: boolean): void => this.stateChanged(resumePending));
    this.host = new RecordingHost(this.inner);
    this.service = new LoginService(this.rig.client, this.rig.tokens, this.host, new LegalVersions(3, 2),
      (): number => this.rig.nowMillis);
    // 与 entry AppLogin.loginService 同一接线（R2-01）：登录页确定出栈的同步出口作废本次尝试。
    this.inner.watchLoginPage(this.service);
  }

  /** AppUpdate.on10405：直接进 below_min，再同步路由（与生产一样经状态变化）。 */
  markBelow(minSupported: string | null): void {
    this.forceUpdateCalls.push(minSupported);
    this.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
  }

  readiness(): LaunchReadiness {
    return new LaunchReadiness(true, PrivacyState.CONSENTED, this.status);
  }

  guardState(fromForceUpdatePage: boolean): GuardState {
    return new GuardState('consented', this.status.result ?? UpdateState.UNKNOWN,
      RouterLoginHost.sessionState(this.rig.client, this.rig.tokens), true, '1.0.0', false, fromForceUpdatePage);
  }

  /** AppRouting.stateChanged 的 Router 部分（生产代码 RoutingSync；App 另有的强更检查同步与等待定时器这里不需要）。 */
  stateChanged(resumePending: boolean = true): void {
    this.sync.sync(this.readiness(), this.rig.nowMillis, resumePending);
  }

  /** 游客在 App 内点需登录的入口（AppRouting.openInApp）。 */
  openInApp(route: string): GuardDecision {
    return this.router.open(RouteRequest.of(route, RouteSource.IN_APP));
  }

  bodyOf(pathPart: string): Record<string, Object> {
    return JSON.parse(this.rig.server.last(pathPart).body ?? '{}') as Record<string, Object>;
  }

  stackJson(): string {
    return JSON.stringify(this.stack.names);
  }
}

function loginData(scope: string, isNew: boolean, inviteBind: string = ''): string {
  return '{"user_id":"user-9","is_new_user":' + isNew + ',"tokens":{"access_token":"login-access","access_expires_at":'
    + '"2026-10-08T11:30:00+08:00","refresh_token":"login-refresh","refresh_expires_at":"2026-11-07T09:30:00+08:00",'
    + '"session_scope":"' + scope + '"}' + inviteBind + '}';
}

function routeLogin(f: Fixture, scope: string, isNew: boolean = false, inviteBind: string = ''): void {
  f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
      return Promise.resolve(envelope(0, loginData(scope, isNew, inviteBind)));
    }
    return Promise.resolve(envelope(0, '{}'));
  };
}

class ThrowingTokens extends MemorySessionTokens {
  save(_tokens: SessionTokenSet): void {
    throw new Error('secure store unavailable');
  }
}

const CONSENT_AT: number = 1790661600000;

export default function loginIntegrationTest() {
  describe('LoginIntegration', () => {
    it('send_code_success_starts_60s_countdown_with_normalized_phone', 0, async () => {
      const f: Fixture = new Fixture();
      f.rig.server.handler = (_r: TransportRequest) =>
      Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      const outcome: SendCodeOutcome = await f.service.sendCode('+86 138-0013-8000');
      expect(outcome.stateRaw).assertEqual('code_sent');
      expect(outcome.countdownSec).assertEqual(60);
      expect(outcome.phone).assertEqual('13800138000');
      const body: Record<string, Object> = f.bodyOf('/v1/auth/sms-codes');
      expect(body['phone'] as string).assertEqual('13800138000');
      expect(body['purpose'] as string).assertEqual('login');
      // 发码是 x-signed：带签名头。
      expect(header(f.rig.server.last('/v1/auth/sms-codes'), NetworkHeaders.SIGN) !== undefined).assertTrue();
    });

    it('send_code_uses_longer_resend_after_from_server', 0, async () => {
      const f: Fixture = new Fixture();
      f.rig.server.handler = (_r: TransportRequest) =>
      Promise.resolve(envelope(0, '{"resend_after_sec":95,"expires_in_sec":300}'));
      const outcome: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(outcome.countdownSec).assertEqual(95);
    });

    it('invalid_phone_is_rejected_locally_without_request', 0, async () => {
      const f: Fixture = new Fixture();
      const outcome: SendCodeOutcome = await f.service.sendCode('12345678901');
      expect(outcome.stateRaw).assertEqual('field_error');
      expect(outcome.textKey).assertEqual('error.20001.phone_invalid');
      expect(f.rig.server.received.length).assertEqual(0);
    });

    it('rate_limit_42901_disables_for_retry_after', 0, async () => {
      const f: Fixture = new Fixture();
      const headers: Record<string, string> = {};
      headers['Retry-After'] = '120';
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(42901, '{}', headers));
      const outcome: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(outcome.stateRaw).assertEqual('rate_limited');
      expect(outcome.countdownSec).assertEqual(120);
      expect(outcome.textKey).assertEqual('error.42901');
    });

    it('rate_limit_42901_without_header_defaults_to_5s', 0, async () => {
      const f: Fixture = new Fixture();
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(42901, '{}'));
      const outcome: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(outcome.countdownSec).assertEqual(5);
    });

    it('wrong_and_expired_code_map_to_code_field', 0, async () => {
      const f: Fixture = new Fixture();
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(20002, '{}'));
      const wrong: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(wrong.stateRaw).assertEqual('code_error');
      expect(wrong.field).assertEqual('code');
      expect(wrong.textKey).assertEqual('error.20002');
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(20003, '{}'));
      const expired: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(expired.stateRaw).assertEqual('code_expired');
      expect(expired.textKey).assertEqual('error.20003');
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.host.calls.length).assertEqual(0);
    });


    it('login_request_carries_legal_versions_consent_time_and_invite', 0, async () => {
      const f: Fixture = new Fixture();
      routeLogin(f, 'full', true, ',"invite_bind":{"result":"bound","code":null}');
      const outcome: LoginOutcome = await f.service.login('0086 13800138000', '123456', CONSENT_AT, ' k7m2qx ', false);
      expect(outcome.stateRaw).assertEqual('logged_in');
      expect(outcome.inviteResult).assertEqual('bound');
      const body: Record<string, Object> = f.bodyOf('/v1/auth/login/sms');
      expect(body['phone'] as string).assertEqual('13800138000');
      expect(body['code'] as string).assertEqual('123456');
      const legal: Record<string, Object> = body['legal_versions'] as Record<string, Object>;
      expect(legal['privacy'] as number).assertEqual(3);
      expect(legal['agreement'] as number).assertEqual(2);
      expect(body['consent_at'] as string).assertEqual(new Date(CONSENT_AT).toISOString());
      expect(body['invite_code'] as string).assertEqual('K7M2QX');
    });

    it('restricted_login_never_sends_invite_code', 0, async () => {
      const f: Fixture = new Fixture();
      routeLogin(f, 'deletion_only');
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      await f.service.login('13800138000', '123456', CONSENT_AT, 'K7M2QX', true);
      const body: Record<string, Object> = f.bodyOf('/v1/auth/login/sms');
      expect(body['invite_code'] === undefined).assertTrue();
    });

    it('agreement_missing_or_code_incomplete_sends_nothing', 0, async () => {
      const f: Fixture = new Fixture();
      const noConsent: LoginOutcome = await f.service.login('13800138000', '123456', null, '', false);
      expect(noConsent.stateRaw).assertEqual(LoginOutcome.AGREEMENT_REQUIRED);
      const short: LoginOutcome = await f.service.login('13800138000', '12345', CONSENT_AT, '', false);
      expect(short.stateRaw).assertEqual(LoginOutcome.CODE_INCOMPLETE);
      expect(f.rig.server.received.length).assertEqual(0);
    });

    it('login_success_saves_session_then_resumes_pending_action', 0, async () => {
      const f: Fixture = new Fixture();
      // 游客点需登录的订单列表 → 登记 pending_action 并进登录页。
      const decision: GuardDecision = f.openInApp('OrderList');
      expect(decision.kind).assertEqual(GuardDecisionKind.REQUIRE_LOGIN);
      expect(f.stackJson()).assertEqual('["Login"]');
      expect(f.router.hasPendingAction).assertTrue();
      routeLogin(f, 'full');
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('logged_in');
      expect(JSON.stringify(outcome.actions))
        .assertEqual(JSON.stringify([AfterLoginAction.SAVE_SESSION, AfterLoginAction.RESUME_PENDING]));
      // 会话先保存（令牌已写入），再关登录页、同步状态，由 Router 恢复原意图（订单 Tab）。
      expect(f.rig.tokens.accessToken()).assertEqual('login-access');
      expect(f.rig.tokens.account()).assertEqual('user-9');
      expect(JSON.stringify(f.host.calls)).assertEqual('["closeLogin","sessionChanged","resumePending"]');
      expect(f.stackJson()).assertEqual('[]');
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
    });

    it('deletion_only_with_unknown_update_enters_force_update_and_discards_pending', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      routeLogin(f, 'deletion_only');
      f.status = UpdateCheckStatus.finished(UpdateState.UNKNOWN);
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('logged_in');
      // 网络层按「低于」处理（UpdatePort.on10405(null)），执行器先丢弃业务待办，再关登录页、进强更页。
      expect(JSON.stringify(f.forceUpdateCalls)).assertEqual('[null]');
      expect(JSON.stringify(f.host.calls))
        .assertEqual('["discardPending","closeLogin","sessionChanged","enterForceUpdate"]');
      expect(f.stackJson()).assertEqual('["ForceUpdate"]');
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.rig.tokens.scope()).assertEqual('deletion_only');
    });

    it('r1_02_restricted_login_from_force_update_page_closes_login', 0, async () => {
      const f: Fixture = new Fixture();
      // 强更页（below_min）→【注销账号】→ 登录页：导航栈 ForceUpdate → Login。
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      f.stateChanged();
      expect(f.stackJson()).assertEqual('["ForceUpdate"]');
      const login: GuardDecision = f.router.openWith(RouteRequest.of('Login', RouteSource.IN_APP), f.guardState(true));
      expect(login.kind).assertEqual(GuardDecisionKind.OPEN);
      expect(f.stackJson()).assertEqual('["ForceUpdate","Login"]');
      routeLogin(f, 'deletion_only');
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', true);
      expect(outcome.stateRaw).assertEqual('logged_in');
      expect(f.rig.tokens.scope()).assertEqual('deletion_only');
      // 受限会话已保存，登录页明确移除，落回强更页（之后从强更页进注销）；不停在验证码页。
      expect(f.stackJson()).assertEqual('["ForceUpdate"]');
      expect(f.host.calls.indexOf('closeLogin') >= 0).assertTrue();
      expect(f.guardState(true).sessionState).assertEqual('restricted');
    });

    it('account_in_deletion_processing_maps_to_deletion_page_state', 0, async () => {
      const f: Fixture = new Fixture();
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(10007, '{"stage":"processing"}'));
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('deletion_processing');
      expect(outcome.textKey).assertEqual('error.10007');
      expect(f.rig.tokens.accessToken()).assertNull();
    });

    it('registration_blocked_44001_keeps_guest', 0, async () => {
      const f: Fixture = new Fixture();
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(44001, '{}'));
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('registration_blocked');
      expect(outcome.textKey).assertEqual('error.44001');
    });

    it('session_save_failure_is_not_a_successful_login', 0, async () => {
      const f: Fixture = new Fixture(new ThrowingTokens());
      f.openInApp('OrderList');
      routeLogin(f, 'full');
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('service_error');
      expect(f.host.calls.length).assertEqual(0);
      expect(f.router.hasPendingAction).assertTrue();
    });

    it('r1_01_late_login_response_after_cancel_saves_nothing_and_keeps_pending', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      expect(f.stackJson()).assertEqual('["Login"]');
      let release: (r: TransportResponse) => void = (_r: TransportResponse) => {
      };
      f.rig.server.handler = (_r: TransportRequest) => new Promise<TransportResponse>((resolve) => {
        release = resolve;
      });
      const pending: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      await flush();
      // 用户取消（离开登录页 / 换号）：作废这次尝试，并同步取消已交给传输层的登录请求。
      f.service.invalidateAttempt();
      expect(f.rig.server.cancelled.length).assertEqual(1);
      release(envelope(0, loginData('full', false)));
      const outcome: LoginOutcome = await pending;
      await flush();
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      // 迟到的成功响应不保存会话、不通知 Router：仍是游客，订单列表没有被打开，pending_action 还在。
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.rig.client.sessionAccount()).assertNull();
      expect(f.host.calls.length).assertEqual(0);
      expect(f.tab).assertEqual('Home');
      expect(f.router.hasPendingAction).assertTrue();
    });

    it('r1_01_changing_phone_cancels_in_flight_send', 0, async () => {
      const f: Fixture = new Fixture();
      let release: (r: TransportResponse) => void = (_r: TransportResponse) => {
      };
      f.rig.server.handler = (_r: TransportRequest) => new Promise<TransportResponse>((resolve) => {
        release = resolve;
      });
      const pending: Promise<SendCodeOutcome> = f.service.sendCode('13800138000');
      await flush();
      f.service.invalidateAttempt();
      expect(f.rig.server.cancelled.length).assertEqual(1);
      release(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      expect((await pending).stateRaw).assertEqual(LoginOutcome.STALE);
    });

    it('r1_04_restricted_scope_with_supported_update_keeps_pending_and_resumes_after_recheck', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      // 登录响应在途期间本机版本检查已恢复为 supported，响应却是 deletion_only；受限会话复查（刷新）拿到 full。
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
          return Promise.resolve(envelope(0, loginData('deletion_only', false)));
        }
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(0, tokenPair('full-access', 'full-refresh', 'full')));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('logged_in');
      expect(JSON.stringify(outcome.actions)).assertEqual(JSON.stringify([AfterLoginAction.SAVE_SESSION,
        AfterLoginAction.REFRESH_RESTRICTED, AfterLoginAction.RESUME_PENDING]));
      expect(f.rig.server.count('/v1/auth/refresh')).assertEqual(1);
      expect(f.rig.tokens.scope()).assertEqual('full');
      // 待办没有被删：交给 Router 恢复，订单 Tab 打开；再点订单也不会又进登录页。
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.openInApp('OrderList').kind).assertEqual(GuardDecisionKind.OPEN);
    });

    it('r1_04_still_restricted_after_recheck_holds_pending_for_router', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
          return Promise.resolve(envelope(0, loginData('deletion_only', false)));
        }
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(0, tokenPair('r-access', 'r-refresh', 'deletion_only')));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('logged_in');
      expect(JSON.stringify(outcome.actions)).assertEqual(JSON.stringify([AfterLoginAction.SAVE_SESSION,
        AfterLoginAction.REFRESH_RESTRICTED, LoginService.HOLD_PENDING]));
      // 结论仍未定：待办保留、登录页关闭、不跳转。
      expect(f.router.hasPendingAction).assertTrue();
      expect(f.stackJson()).assertEqual('[]');
      expect(f.tab).assertEqual('Home');
      // 之后强更结论到来（below_min）：由 Router 决定——进强更页并丢弃待办。
      f.status = UpdateCheckStatus.finished(UpdateState.BELOW_MIN);
      f.stateChanged();
      expect(f.stackJson()).assertEqual('["ForceUpdate"]');
      expect(f.router.hasPendingAction).assertFalse();
    });

    it('r1_05_same_phone_within_countdown_is_not_sent_again', 0, async () => {
      const f: Fixture = new Fixture();
      f.rig.server.handler = (_r: TransportRequest) =>
      Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      expect((await f.service.sendCode('13800138000')).stateRaw).assertEqual('code_sent');
      // 5 秒后返回手机号页、号码没改（换个写法也是同一号码）再点【获取验证码】：不再发出，直接回验证码步继续输入。
      f.rig.nowMillis += 5000;
      const again: SendCodeOutcome = await f.service.sendCode('+86 138-0013-8000');
      expect(again.stateRaw).assertEqual(LoginService.STATE_COUNTDOWN);
      expect(again.countdownSec).assertEqual(55);
      expect(again.phone).assertEqual('13800138000');
      expect(f.service.resendRemainingSec('138 0013 8000')).assertEqual(55);
      expect(f.rig.server.count('/v1/auth/sms-codes')).assertEqual(1);
      // 别的号码不受影响。
      expect((await f.service.sendCode('13900139000')).stateRaw).assertEqual('code_sent');
      expect(f.rig.server.count('/v1/auth/sms-codes')).assertEqual(2);
      // 截止时间到了才能再发。
      f.rig.nowMillis += 55000;
      expect((await f.service.sendCode('13800138000')).stateRaw).assertEqual('code_sent');
      expect(f.rig.server.count('/v1/auth/sms-codes')).assertEqual(3);
    });

    it('r1_05_rate_limited_phone_stays_disabled_without_request', 0, async () => {
      const f: Fixture = new Fixture();
      const headers: Record<string, string> = {};
      headers['Retry-After'] = '120';
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(42901, '{}', headers));
      expect((await f.service.sendCode('13800138000')).countdownSec).assertEqual(120);
      f.rig.nowMillis += 20000;
      const again: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(again.stateRaw).assertEqual('rate_limited');
      expect(again.countdownSec).assertEqual(100);
      expect(f.rig.server.count('/v1/auth/sms-codes')).assertEqual(1);
    });

    it('duplicate_login_tap_is_busy', 0, async () => {
      const f: Fixture = new Fixture();
      routeLogin(f, 'full');
      const first: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      const second: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(second.stateRaw).assertEqual(LoginOutcome.BUSY);
      expect((await first).stateRaw).assertEqual('logged_in');
      expect(f.rig.server.count('/v1/auth/login/sms')).assertEqual(1);
    });

    it('logout_revokes_then_clears_session_back_to_guest', 0, async () => {
      const f: Fixture = new Fixture();
      routeLogin(f, 'full');
      await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      f.host.calls.splice(0, f.host.calls.length);
      const done: boolean = await f.service.logout();
      expect(done).assertTrue();
      const sent: TransportRequest = f.rig.server.last('/v1/auth/logout');
      expect(header(sent, NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer login-access');
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.rig.client.sessionAccount()).assertNull();
      expect(f.guardState(false).sessionState).assertEqual('guest');
      expect(JSON.stringify(f.host.calls)).assertEqual('["sessionEnded","sessionChanged"]');
      // 回到游客：再点订单又进登录页。
      expect(f.openInApp('OrderList').kind).assertEqual(GuardDecisionKind.REQUIRE_LOGIN);
    });

    it('r1_03_logout_answered_10404_still_runs_router_cleanup', 0, async () => {
      const f: Fixture = new Fixture(new MemorySessionTokens(new SessionTokenSet('a1', 'r1', 'full', 'user-1')));
      // 已登录且有一个还没恢复的 pending_action（例如上次前置没走完）。
      const values: Record<string, Object> = {};
      values['route'] = 'OrderList';
      f.store.save(Router.OPEN_ROUTE_ACTION, values, f.rig.nowMillis, RouteSource.IN_APP);
      expect(f.router.hasPendingAction).assertTrue();
      const generation: number = f.router.sessionGeneration;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(r.url.indexOf('/v1/auth/logout') >= 0 ? envelope(10404, '{}') : envelope(0, '{}'));
      const done: boolean = await f.service.logout();
      expect(done).assertTrue();
      expect(f.rig.tokens.accessToken()).assertNull();
      // 原会话被网络层清掉（不是换成了新会话）：照样完成登出清理——Router.sessionEnded 清待办、作废旧回查。
      expect(f.host.calls.indexOf('sessionEnded') >= 0).assertTrue();
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.router.sessionGeneration).assertEqual(generation + 1);
    });

    it('logout_network_failure_still_clears_local_session', 0, async () => {
      const f: Fixture = new Fixture(new MemorySessionTokens(new SessionTokenSet('a1', 'r1', 'full', 'user-1')));
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(TransportResponse.failed('disconnect'));
      const done: boolean = await f.service.logout();
      expect(done).assertTrue();
      expect(f.rig.tokens.accessToken()).assertNull();
    });

    it('logout_does_not_clear_a_session_that_changed_while_waiting', 0, async () => {
      const f: Fixture = new Fixture(new MemorySessionTokens(new SessionTokenSet('a1', 'r1', 'full', 'user-1')));
      let release: (r: TransportResponse) => void = (_r: TransportResponse) => {
      };
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/logout') >= 0) {
          return new Promise<TransportResponse>((resolve) => {
            release = resolve;
          });
        }
        return Promise.resolve(envelope(0, loginData('full', false)));
      };
      const out: Promise<boolean> = f.service.logout();
      await flush();
      // 等待期间别处换了会话（模拟新登录）：旧的登出不得清掉新会话。
      f.rig.client.onSessionChanged();
      f.rig.tokens.save(new SessionTokenSet('a2', 'r2', 'full', 'user-2'));
      release(envelope(0, '{}'));
      expect(await out).assertFalse();
      expect(f.rig.tokens.accessToken()).assertEqual('a2');
      expect(f.host.calls.indexOf('sessionEnded') < 0).assertTrue();
    });
    it('r2_01_login_removed_by_stack_clear_before_view_disposal_drops_late_success', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      expect(f.stackJson()).assertEqual('["Login"]');
      let release: (r: TransportResponse) => void = (_r: TransportResponse) => {
      };
      f.rig.server.handler = (_r: TransportRequest) => new Promise<TransportResponse>((resolve) => {
        release = resolve;
      });
      const pending: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      await flush();
      // 登录在途时导航清栈（用户在别处点了首页 Tab：Router → StackNavigator.push → 清栈）移除 Login。
      // 组件的 aboutToDisappear 还没执行（退场动画中）——测试里不调用 invalidateAttempt。
      f.openInApp('Home');
      expect(f.stackJson()).assertEqual('[]');
      // 出栈的同步出口已作废本次尝试，并同步取消登录请求。
      expect(f.rig.server.cancelled.length).assertEqual(1);
      release(envelope(0, loginData('full', false)));
      const outcome: LoginOutcome = await pending;
      await flush();
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.host.calls.length).assertEqual(0);
      expect(f.tab).assertEqual('Home');
      expect(f.router.hasPendingAction).assertTrue();
    });

    it('r2_01_login_closed_via_navigator_remove_invalidates_in_flight_send', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      let release: (r: TransportResponse) => void = (_r: TransportResponse) => {
      };
      f.rig.server.handler = (_r: TransportRequest) => new Promise<TransportResponse>((resolve) => {
        release = resolve;
      });
      const pending: Promise<SendCodeOutcome> = f.service.sendCode('13800138000');
      await flush();
      // 关闭按钮（AppLogin.onClose → navigator.remove(Login)）。
      f.navigator.remove('Login');
      expect(f.rig.server.cancelled.length).assertEqual(1);
      release(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      expect((await pending).stateRaw).assertEqual(LoginOutcome.STALE);
    });

    it('r2_02_cancel_during_restricted_recheck_ends_wait_and_keeps_pending', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      let releaseRefresh: (r: TransportResponse) => void = (_r: TransportResponse) => {
      };
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
          return Promise.resolve(envelope(0, loginData('deletion_only', false)));
        }
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return new Promise<TransportResponse>((resolve) => {
            releaseRefresh = resolve;
          });
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      // 本机 supported，登录拿到 deletion_only：进入登录触发的受限会话复查。
      const pending: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      for (let i: number = 0; i < 10 && f.rig.server.count('/v1/auth/refresh') === 0; i++) {
        await flush();
      }
      expect(f.rig.server.count('/v1/auth/refresh')).assertEqual(1);
      // 用户点返回（backToPhone → invalidateAttempt）：复查等待立即结束，只为这次尝试发出的刷新传输被取消。
      f.service.invalidateAttempt();
      expect(f.rig.server.cancelled.length).assertEqual(1);
      // 刷新随后返回 full：已取消，不能借它恢复待办。
      releaseRefresh(envelope(0, tokenPair('full-access', 'full-refresh', 'full')));
      const outcome: LoginOutcome = await pending;
      await flush();
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      // 会话确已保存（受限）：只同步会话，不关页、不恢复、不消费待办。
      expect(JSON.stringify(f.host.calls)).assertEqual('["sessionSynced"]');
      expect(f.tab).assertEqual('Home');
      expect(f.stackJson()).assertEqual('["Login"]');
      expect(f.router.hasPendingAction).assertTrue();
    });

    it('r2_02_session_sync_without_resume_keeps_pending_for_valid_flow', 0, async () => {
      const f: Fixture = new Fixture();
      f.openInApp('OrderList');
      f.navigator.remove('Login');
      expect(f.router.hasPendingAction).assertTrue();
      // 会话已建立（例如作废前保存的那次登录）。
      f.rig.client.onSessionChanged();
      f.rig.tokens.save(new SessionTokenSet('a1', 'r1', 'full', 'user-1'));
      // 只通知会话变了：守卫状态同步，待办不恢复、不删除。
      f.inner.sessionSynced();
      expect(f.tab).assertEqual('Home');
      expect(f.router.hasPendingAction).assertTrue();
      // 有效流程的会话变化（sessionChanged）才恢复待办。
      f.inner.sessionChanged();
      expect(f.tab).assertEqual('OrderList');
      expect(f.router.hasPendingAction).assertFalse();
    });

    it('r2_03_send_code_rate_limit_keeps_login_enabled_for_valid_code', 0, async () => {
      const f: Fixture = new Fixture();
      let sends: number = 0;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/sms-codes') >= 0) {
          sends++;
          if (sends === 1) {
            return Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
          }
          const headers: Record<string, string> = {};
          headers['Retry-After'] = '3600';
          return Promise.resolve(envelope(42901, '{}', headers));
        }
        if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
          return Promise.resolve(envelope(0, loginData('full', false)));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const limits: LoginRateLimits = new LoginRateLimits();
      const first: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(first.stateRaw).assertEqual('code_sent');
      expect(limits.applySend(first, f.rig.nowMillis)).assertFalse();
      // 61 秒后点「重新获取」：小时级 / IP 频控回 42901，Retry-After = 3600；旧码还有 239 秒有效期。
      f.rig.nowMillis += 61000;
      const again: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(again.stateRaw).assertEqual('rate_limited');
      expect(again.countdownSec).assertEqual(3600);
      expect(limits.applySend(again, f.rig.nowMillis)).assertTrue();
      // 只禁用发码入口；登录按钮可用，旧码照样能登录。
      expect(limits.sendBlocked(f.rig.nowMillis)).assertTrue();
      expect(limits.loginBlocked(f.rig.nowMillis)).assertFalse();
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('logged_in');
      // 反过来：登录回 42901 才禁用登录按钮（不影响发码入口的截止时间）。
      const other: LoginRateLimits = new LoginRateLimits();
      expect(other.applyLogin(new LoginOutcome('rate_limited', 'error.42901', null, 5000), f.rig.nowMillis)).assertTrue();
      expect(other.loginBlocked(f.rig.nowMillis)).assertTrue();
      expect(other.sendBlocked(f.rig.nowMillis)).assertFalse();
      expect(other.loginBlocked(f.rig.nowMillis + 5000)).assertFalse();
    });

    it('r3_01_resend_rate_limited_then_back_to_phone_continues_same_phone_login', 0, async () => {
      const f: Fixture = new Fixture();
      let sends: number = 0;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/sms-codes') >= 0) {
          sends++;
          if (sends === 1) {
            return Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
          }
          const headers: Record<string, string> = {};
          headers['Retry-After'] = '3600';
          return Promise.resolve(envelope(42901, '{}', headers));
        }
        if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
          return Promise.resolve(envelope(0, loginData('full', false)));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      // 页面同一套：LoginView.limits + LoginService.phoneEntry + backToPhone（invalidateAttempt）。
      const limits: LoginRateLimits = new LoginRateLimits();
      expect((await f.service.sendCode('13800138000')).stateRaw).assertEqual('code_sent');
      // 61 秒后在验证码页点「重新获取」：42901、Retry-After = 3600。
      f.rig.nowMillis += 61000;
      const again: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(limits.applySend(again, f.rig.nowMillis)).assertTrue();
      // 点返回回到手机号页。
      f.service.invalidateAttempt();
      f.rig.nowMillis += 1000;
      // 发码仍限流，但同一号码（换个写法）已收到的码还有 238 秒有效：可以继续进入验证码步，不发码。
      expect(limits.sendBlocked(f.rig.nowMillis)).assertTrue();
      expect(f.service.issuedCodeRemainingSec('+86 138 0013 8000')).assertEqual(238);
      const entry: PhoneEntry = f.service.phoneEntry('+86 138 0013 8000', limits.sendBlocked(f.rig.nowMillis));
      expect(entry.kind).assertEqual(PhoneEntry.CONTINUE);
      expect(entry.phone).assertEqual('13800138000');
      expect(entry.countdownSec).assertEqual(0);
      expect(f.rig.server.count('/v1/auth/sms-codes')).assertEqual(2);
      // 继续用旧码登录成功；码用掉后不再提供「继续输入」。
      const outcome: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(outcome.stateRaw).assertEqual('logged_in');
      expect(f.service.issuedCodeRemainingSec('13800138000')).assertEqual(0);
      expect(f.service.phoneEntry('13800138000', true).kind).assertEqual(PhoneEntry.SEND);
      expect(f.rig.server.count('/v1/auth/sms-codes')).assertEqual(2);
    });

    it('r3_01_no_continue_without_a_valid_received_code', 0, async () => {
      const f: Fixture = new Fixture();
      const headers: Record<string, string> = {};
      headers['Retry-After'] = '3600';
      f.rig.server.handler = (_r: TransportRequest) => Promise.resolve(envelope(42901, '{}', headers));
      // 第一次发码就被限流：没有收到过码，不能进验证码步。
      await f.service.sendCode('13800138000');
      expect(f.service.phoneEntry('13800138000', true).kind).assertEqual(PhoneEntry.SEND);
      // 码过了有效期（300 秒）也不再提供「继续输入」。
      const g: Fixture = new Fixture();
      g.rig.server.handler = (_r: TransportRequest) =>
      Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      await g.service.sendCode('13800138000');
      g.rig.nowMillis += 10000;
      const within: PhoneEntry = g.service.phoneEntry('13800138000', false);
      expect(within.kind).assertEqual(PhoneEntry.CONTINUE);
      expect(within.countdownSec).assertEqual(50);
      g.rig.nowMillis += 290000;
      expect(g.service.phoneEntry('13800138000', true).kind).assertEqual(PhoneEntry.SEND);
    });
  });
}
