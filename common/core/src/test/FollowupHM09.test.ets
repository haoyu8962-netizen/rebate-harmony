// F-HM-09（APP-05a-ios R1 的鸿蒙核对，随 APP-06a 第 2 轮处理）：
// APP-05a 共性 18（会话失效经 Router 打开 Login，测试从生产网络层回调触发）、19（受限会话刷新成 full 按触发来源决定是否恢复
// 待办）、20（页面重新出现时按当前时钟重算倒计时与限流）、21（发码禁用与倒计时按号码读 LoginService 的截止时间）；
// APP-04 共性 65（桥导航 deferred 不进启动队列、不补执行）。
import { describe, it, expect } from '@ohos/hypium';
import { Routes, RouteSpec } from 'generated';
import {
  ApiRequest, BridgeRouteOpening, EffectKind, ErrorEffect, GuardDecision, GuardDecisionKind, GuardState, LaunchReadiness,
  LegalVersions, LoginHost, LoginSendState, LoginService, MemoryPendingBackend, PendingActionStore, PrivacyState,
  RouteDestination, RouteNavigator, RouteRequest, RouteSource, RouteTargetAllowlist, Router, SessionEffectHost,
  SessionEffectRouting, SessionTokenSet, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState
} from '../../Index';
import { envelope, flush, Rig, tokenPair } from './NetworkTestRig';

class RecordingSessionHost implements SessionEffectHost {
  readonly calls: string[] = [];

  markSessionExpired(): void {
    this.calls.push('markSessionExpired');
  }

  open(route: string): void {
    this.calls.push('open:' + route);
  }

  stateChanged(): void {
    this.calls.push('stateChanged');
  }
}

class QuietLoginHost implements LoginHost {
  updateState(): string {
    return 'supported';
  }

  hasPendingAction(): boolean {
    return false;
  }

  closeLogin(): void {
  }

  resumePending(): void {
  }

  discardPending(): void {
  }

  enterForceUpdate(): void {
  }

  sessionChanged(): void {
  }

  sessionSynced(): void {
  }

  sessionEnded(): void {
  }
}

class StackNavigator implements RouteNavigator {
  stack: string[] = [];

  push(destination: RouteDestination): void {
    this.stack.push(destination.route ?? '<upgrade>');
  }

  reset(destinations: RouteDestination[]): void {
    this.stack = [];
    for (const d of destinations) {
      this.push(d);
    }
  }

  requestConsent(): void {
  }

  top(): string {
    return this.stack.length === 0 ? 'Home' : this.stack[this.stack.length - 1];
  }
}

const PHONE_A: string = '13900000000';
const PHONE_B: string = '13800138000';

/** 发码假服务：A 回 42901（Retry-After 120），其余成功（重发 60 秒）。 */
function smsRig(): Rig {
  const rig: Rig = new Rig(null);
  rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
    if (request.url.indexOf('/v1/auth/sms-codes') >= 0) {
      if (request.body !== null && request.body.indexOf(PHONE_A) >= 0) {
        const headers: Record<string, string> = {};
        headers['retry-after'] = '120';
        return Promise.resolve(envelope(42901, '{}', headers));
      }
      return Promise.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
    }
    return Promise.resolve(envelope(0, '{}'));
  };
  return rig;
}

export default function followupHM09Test() {
  describe('FollowupHM09', () => {
    // ---------------------------------------------------------------- 共性 18
    it('item18_business_10404_routes_to_login_via_network_callback', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10404, '{}'));
      await rig.client.request(new ApiRequest('getMe'));
      // 生产网络层的会话级回调（ApiClientDeps.sessionEffect）发出跳登录，不靠发起页自己处理 Effect。
      expect(rig.sessionEffects.length).assertEqual(1);
      const effect: ErrorEffect = rig.sessionEffects[0];
      expect(effect.effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      expect(effect.route).assertEqual('Login');
      expect(rig.tokens.accessToken()).assertNull();
      const host: RecordingSessionHost = new RecordingSessionHost();
      SessionEffectRouting.apply(effect, host);
      expect(JSON.stringify(host.calls)).assertEqual('["markSessionExpired","open:Login"]');
    });

    it('item18_force_update_keeps_force_update_page', 0, async () => {
      const rig: Rig = new Rig();
      rig.update.stateRaw = 'below';
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10404, '{}'));
      await rig.client.request(new ApiRequest('getMe'));
      expect(rig.sessionEffects.length).assertEqual(1);
      expect(rig.sessionEffects[0].effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE);
      const host: RecordingSessionHost = new RecordingSessionHost();
      SessionEffectRouting.apply(rig.sessionEffects[0], host);
      expect(JSON.stringify(host.calls)).assertEqual('["stateChanged"]');
    });

    it('item18_refresh_failure_also_routes_and_logout_10404_does_not', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ? envelope(10404, '{}') : envelope(10002, '{}'));
      await rig.client.request(new ApiRequest('getMe'));
      expect(rig.sessionEffects.length).assertEqual(1);
      expect(rig.sessionEffects[0].route).assertEqual('Login');
      // 用户自己登出时回 10404：不跳登录（LoginService 完成登出清理）。
      const out: Rig = new Rig();
      out.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10404, '{}'));
      await out.client.request(new ApiRequest('logout'));
      expect(out.sessionEffects.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 共性 19
    it('item19_barrier_refresh_to_full_resumes_pending', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ?
        envelope(0, tokenPair('new-access', 'new-refresh', 'full')) : envelope(0, '{}'));
      // 冷启动 / 强更恢复的 App 级屏障（没有调用方归属）。
      expect(await rig.client.refreshRestrictedSession()).assertTrue();
      expect(JSON.stringify(rig.refreshResume)).assertEqual('[true]');
    });

    it('item19_login_recheck_refresh_to_full_only_syncs', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ?
        envelope(0, tokenPair('new-access', 'new-refresh', 'full')) : envelope(0, '{}'));
      // 登录尝试触发的复查（带本次尝试的归属守卫）：只同步状态，是否恢复交给 LoginService（作废的尝试不恢复）。
      const owner: () => boolean = (): boolean => true;
      expect(await rig.client.refreshRestrictedSession(owner)).assertTrue();
      expect(rig.refreshNotices.length).assertEqual(1);
      expect(JSON.stringify(rig.refreshResume)).assertEqual('[false]');
    });

    // ---------------------------------------------------------------- 共性 20、21
    it('item21_send_limit_follows_phone_number', 0, async () => {
      const rig: Rig = smsRig();
      const service: LoginService = new LoginService(rig.client, rig.tokens, new QuietLoginHost(),
        LegalVersions.bundled(), (): number => rig.nowMillis);
      await service.sendCode(PHONE_A);
      expect(service.sendState(PHONE_A).rateLimitedSec).assertEqual(120);
      // 换成没被限流的 B：发码不禁用、没有倒计时。
      const b: LoginSendState = service.sendState(PHONE_B);
      expect(b.rateLimitedSec).assertEqual(0);
      expect(b.countdownSec).assertEqual(0);
      await service.sendCode(PHONE_B);
      expect(service.sendState(PHONE_B).countdownSec).assertEqual(60);
      expect(service.sendState(PHONE_B).rateLimitedSec).assertEqual(0);
      // 换回 A：旧限制仍然生效（不同写法按规范化号码）。
      expect(service.sendState('139 0000 0000').rateLimitedSec).assertEqual(120);
      expect(service.sendState('139 0000 0000').countdownSec).assertEqual(0);
    });

    it('item20_reappear_recomputes_from_clock_and_deadline', 0, async () => {
      const rig: Rig = smsRig();
      const service: LoginService = new LoginService(rig.client, rig.tokens, new QuietLoginHost(),
        LegalVersions.bundled(), (): number => rig.nowMillis);
      await service.sendCode(PHONE_B);
      expect(service.sendState(PHONE_B).needsTimer(false)).assertTrue();
      // 打开协议页 30 秒后返回：倒计时按截止时间是 30 秒，仍要计时器。
      rig.nowMillis += 30 * 1000;
      const back: LoginSendState = service.sendState(PHONE_B);
      expect(back.countdownSec).assertEqual(30);
      expect(back.needsTimer(false)).assertTrue();
      // 超过截止时间才返回：倒计时为 0，重发入口立即可用，不再需要计时器（登录限流还在时仍要）。
      rig.nowMillis += 40 * 1000;
      const late: LoginSendState = service.sendState(PHONE_B);
      expect(late.countdownSec).assertEqual(0);
      expect(late.needsTimer(false)).assertFalse();
      expect(late.needsTimer(true)).assertTrue();
      await service.sendCode(PHONE_A);
      rig.nowMillis += 121 * 1000;
      expect(service.sendState(PHONE_A).rateLimitedSec).assertEqual(0);
      await flush();
    });

    // ---------------------------------------------------------------- APP-04 共性 65
    it('item65_deferred_bridge_navigation_is_not_queued', 0, () => {
      const nav: StackNavigator = new StackNavigator();
      let settled: boolean = false;
      const guard: () => GuardState = (): GuardState => new GuardState('consented', 'ok', 'guest', settled, '1.0.0',
        false, false, false, RouteTargetAllowlist.EMPTY);
      const router: Router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => 1000), guard,
        nav, (name: string): RouteSpec | undefined => Routes.spec(name), null);
      const request: RouteRequest = RouteRequest.of('Search', RouteSource.BRIDGE);
      const decision: GuardDecision = router.decide(request, guard());
      expect(decision.kind).assertEqual(GuardDecisionKind.DEFER);
      const opening: BridgeRouteOpening = BridgeRouteOpening.rechecked(request, decision, guard,
        (r: RouteRequest, s: GuardState): GuardDecision => router.decide(r, s),
        (d: GuardDecision, r: RouteRequest): void => router.apply(d, r));
      opening.commit();
      // 直接交给 Router.apply 也不排队。
      router.apply(decision, request);
      expect(router.hasPendingLaunchIntent).assertFalse();
      // 条件满足后也不补执行。
      settled = true;
      router.stateChanged(new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        2000);
      expect(nav.top()).assertEqual('Home');
      // 对照：外部深链的 deferred 照常排队（03 §4.4）。
      settled = false;
      router.apply(decision, RouteRequest.of('Search', RouteSource.DEEPLINK));
      expect(router.hasPendingLaunchIntent).assertTrue();
    });
  });
}
