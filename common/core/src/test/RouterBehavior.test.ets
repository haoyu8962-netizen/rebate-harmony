// Router 行为单测（APP-02a 三端统一要求）：向量之外的生成字段、since=null、参数 schema、外部网页白名单、
// 实名前置、pending_action 的 origin 与不登记路由、隐私同意后的恢复、推送回查的异步重判、启动排队。
import { describe, it, expect } from '@ohos/hypium';
import { RouteEntry, RouteKind, Routes, RouteSpec } from 'generated';
import {
  DeepLinkConfig,
  DeepLinkParser,
  EntryGuard,
  GuardDecision,
  GuardDecisionKind,
  GuardReason,
  GuardState,
  LaunchIntent,
  LaunchQueue,
  LaunchReadiness,
  LaunchRelease,
  MemoryPendingBackend,
  PendingAction,
  PendingActionStore,
  PrivacyState,
  PushLanding,
  PushLandingResult,
  PushLookupResult,
  RouteDestination,
  RouteLookup,
  RouteNavigator,
  RouteRequest,
  RouteTargetAllowlist,
  Router,
  UpdateCheckStatus,
  UpdateState
} from '../../Index';

class RecordingNavigator implements RouteNavigator {
  stack: string[] = [];
  consentRequests: number = 0;
  readonlyFlags: boolean[] = [];

  push(destination: RouteDestination): void {
    this.stack.push(destination.route ?? '<upgrade>');
    this.readonlyFlags.push(destination.readonly);
  }

  reset(destinations: RouteDestination[]): void {
    this.stack = [];
    for (const d of destinations) {
      this.push(d);
    }
  }

  requestConsent(): void {
    this.consentRequests++;
  }

  top(): string {
    return this.stack.length === 0 ? 'Home' : this.stack[this.stack.length - 1];
  }
}

/** 可变的守卫状态源（Router 每次判定时取最新值）。 */
class StateBox {
  privacy: string = 'consented';
  update: string = 'ok';
  session: string = 'guest';
  settled: boolean = true;
  realname: boolean = false;
  targets: RouteTargetAllowlist = RouteTargetAllowlist.EMPTY;

  current(): GuardState {
    return new GuardState(this.privacy, this.update, this.session, this.settled, '1.0.0', false, false,
      this.realname, this.targets);
  }
}

/** 可变的放行条件源（环境、隐私、强更检查进度）。 */
class ReadinessBox {
  settled: boolean = true;
  privacy: PrivacyState = PrivacyState.CONSENTED;
  update: UpdateCheckStatus = UpdateCheckStatus.finished(UpdateState.OK);

  current(): LaunchReadiness {
    return new LaunchReadiness(this.settled, this.privacy, this.update);
  }
}

class Harness {
  readonly box: StateBox = new StateBox();
  readonly ready: ReadinessBox = new ReadinessBox();
  readonly nav: RecordingNavigator = new RecordingNavigator();
  readonly backend: MemoryPendingBackend;
  nowMillis: number = 1000000;
  readonly store: PendingActionStore;
  readonly router: Router;

  /** waitsForUpdate：给 Router 接上放行条件源（App 的接法），强更检查中外部请求要等待。 */
  constructor(waitsForUpdate: boolean = false, backend?: MemoryPendingBackend) {
    this.backend = backend ?? new MemoryPendingBackend();
    this.store = new PendingActionStore(this.backend, (): number => this.nowMillis);
    this.router = new Router(this.store, (): GuardState => this.box.current(), this.nav, RELEASE_ROUTES,
      waitsForUpdate ? (): LaunchReadiness => this.ready.current() : null);
  }

  /** 状态变化（App 的 stateChanged）：按当前放行条件恢复 pending_action、放行启动意图。 */
  settle(landing: PushLanding | null = null): Promise<void> | null {
    return this.router.stateChanged(this.ready.current(), this.nowMillis, landing);
  }

  /** 强更检查从 nowMillis 开始；守卫状态源照 App 的接法把「检查中」记作 unknown。 */
  startChecking(): void {
    this.ready.update = UpdateCheckStatus.checking(this.nowMillis);
    this.box.update = 'unknown';
  }

  finishCheck(result: UpdateState): void {
    this.ready.update = UpdateCheckStatus.finished(result);
    this.box.update = result;
  }

  pending(): PendingAction | null {
    return this.store.load(this.nowMillis);
  }
}

/** Release 构建的路由表（不含 debug_only 路由）。 */
const RELEASE_ROUTES: RouteLookup = (name: string): RouteSpec | undefined => Routes.spec(name);

function params(entries: [string, Object][]): Record<string, Object> {
  const out: Record<string, Object> = {};
  for (const e of entries) {
    out[e[0]] = e[1];
  }
  return out;
}

function req(route: string, source: string, p?: Record<string, Object>): RouteRequest {
  return new RouteRequest(route, p === undefined ? params([]) : p, source);
}

function state(privacy: string, update: string, session: string, realname: boolean = false,
  targets: RouteTargetAllowlist = RouteTargetAllowlist.EMPTY): GuardState {
  return new GuardState(privacy, update, session, true, '1.0.0', false, false, realname, targets);
}

function decide(r: RouteRequest, s: GuardState): string {
  return EntryGuard.decide(r, s, RELEASE_ROUTES).toString();
}

class Deferred {
  resolve: (value: PushLookupResult) => void = () => {
  };
  readonly promise: Promise<PushLookupResult>;

  constructor() {
    this.promise = new Promise<PushLookupResult>((resolve: (value: PushLookupResult) => void) => {
      this.resolve = resolve;
    });
  }
}

export default function routerBehaviorTest() {
  describe('RouterGeneratedFields', () => {
    it('agent_guide_and_account_are_generated', 0, () => {
      const wallet: RouteSpec = Routes.spec('Wallet') as RouteSpec;
      expect(wallet.agentGuide).assertTrue();
      expect(wallet.agentGuideAccount).assertNull();
      const bind: RouteSpec = Routes.spec('BindPhone') as RouteSpec;
      expect(bind.agentGuide).assertFalse();
      expect(bind.agentGuideAccount).assertEqual('phone');
      expect((Routes.spec('Withdraw') as RouteSpec).agentGuideAccount).assertEqual('fund');
      expect((Routes.spec('DeleteAccount') as RouteSpec).agentGuideAccount).assertEqual('delete');
      const home: RouteSpec = Routes.spec('Home') as RouteSpec;
      expect(home.agentGuide).assertFalse();
      expect(home.agentGuideAccount).assertNull();
      const guided: string[] = [];
      Routes.all.forEach((spec: RouteSpec, name: string) => {
        if (spec.agentGuide) {
          guided.push(name);
        }
      });
      expect(guided.sort().join(',')).assertEqual('AuthManage,InviteShare,Messages,OrderList,WithdrawRecords,Wallet'
        .split(',').sort().join(','));
    });

    it('params_schema_is_generated', 0, () => {
      const product: RouteSpec = Routes.spec('ProductDetail') as RouteSpec;
      expect(product.requiredParams.join(',')).assertEqual('platform,product_key');
      expect(product.additionalParams).assertFalse();
      expect(product.param('product_key')?.minLength).assertEqual(3);
      expect(product.param('item_ref')?.maxLength).assertEqual(1024);
      expect((Routes.spec('ExternalPage') as RouteSpec).param('url')?.pattern).assertEqual('^https://');
    });

    it('since_null_routes_are_unknown', 0, () => {
      for (const name of ['Earnings', 'LinkLanding', 'DeleteAccount', 'InvitedFriends', 'LevelUpgrade']) {
        expect((Routes.spec(name) as RouteSpec).sinceHarmony).assertNull();
        expect(decide(req(name, 'in_app'), state('consented', 'ok', 'phone_bound', true)))
          .assertEqual('upgrade - unknown_route');
      }
    });

    it('release_table_has_no_debug_route', 0, () => {
      const s: GuardState = new GuardState('consented', 'ok', 'guest', true, '1.0.0', true, false);
      const r: RouteRequest = req('HomePreview', 'deeplink', params([['page_key', 'home'], ['token', 'x']]));
      expect(EntryGuard.decide(r, s, RELEASE_ROUTES).toString()).assertEqual('upgrade - unknown_route');
    });
  });

  describe('RouterParamsSchema', () => {
    const consented: GuardState = state('consented', 'ok', 'phone_bound', true);
    it('wrong_type_rejected_for_every_source', 0, () => {
      for (const source of ['in_app', 'push', 'bridge', 'pending_action']) {
        expect(decide(req('Search', source, params([['q', 123]])), consented))
          .assertEqual('reject - params_invalid');
      }
      expect(decide(req('Search', 'deeplink', params([['q', 123]])), consented)).assertEqual('reject - params_invalid');
    });

    it('missing_required_rejected', 0, () => {
      expect(decide(req('ProductDetail', 'in_app', params([['platform', 'jd']])), consented))
        .assertEqual('reject - params_invalid');
      expect(decide(req('OrderDetail', 'push', params([])), consented)).assertEqual('reject - params_invalid');
    });

    it('extra_enum_and_length_rejected', 0, () => {
      expect(decide(req('Home', 'in_app', params([['x', 'y']])), consented)).assertEqual('reject - params_invalid');
      expect(decide(req('OrderList', 'in_app', params([['scope', 'all']])), consented))
        .assertEqual('reject - params_invalid');
      expect(decide(req('ProductDetail', 'in_app', params([['platform', 'jd'], ['product_key', 'ab']])), consented))
        .assertEqual('reject - params_invalid');
      expect(decide(req('AgentChat', 'in_app', params([['context', 'text']])), consented))
        .assertEqual('reject - params_invalid');
    });

    it('valid_params_open', 0, () => {
      expect(decide(req('AgentChat', 'in_app', params([['context', params([['a', 1]])]])), consented))
        .assertEqual('open AgentChat allowed');
      expect(decide(req('Search', 'in_app', params([['q', '\u{1F600}'.repeat(100)]])), consented))
        .assertEqual('open Search allowed');
    });

    it('sensitive_pages_drop_params_before_validation', 0, () => {
      const r: RouteRequest = req('Withdraw', 'push', params([['amount', 100]]));
      expect(EntryGuard.effectiveParams(r)).assertDeepEquals(params([]));
      expect(decide(r, consented)).assertEqual('open Withdraw params_dropped');
    });
  });

  describe('RouterTargets', () => {
    const allow: RouteTargetAllowlist = new RouteTargetAllowlist(['shop.example.com'], ['https://h5.example.com']);
    it('empty_allowlist_rejects_all', 0, () => {
      const s: GuardState = state('consented', 'ok', 'guest');
      expect(decide(req('ExternalPage', 'deeplink', params([['url', 'https://shop.example.com/a']])), s))
        .assertEqual('reject - target_not_allowed');
      expect(decide(req('WebPage', 'in_app', params([['url', 'https://h5.example.com/a']])), s))
        .assertEqual('reject - target_not_allowed');
    });

    it('external_hosts_exact_match', 0, () => {
      const s: GuardState = state('consented', 'ok', 'guest', false, allow);
      expect(decide(req('ExternalPage', 'deeplink', params([['url', 'https://shop.example.com/a?b=1']])), s))
        .assertEqual('open ExternalPage allowed');
      expect(decide(req('ExternalPage', 'push', params([['url', 'https://SHOP.example.com']])), s))
        .assertEqual('open ExternalPage allowed');
      for (const url of ['https://evil.shop.example.com/', 'https://shop.example.com.evil.com/',
        'https://user@shop.example.com/', 'https://shop.example.com:8443/', 'http://shop.example.com/']) {
        expect(decide(req('ExternalPage', 'deeplink', params([['url', url]])), s).startsWith('reject')).assertTrue();
      }
    });

    it('bridge_origins_for_web_page', 0, () => {
      const s: GuardState = state('consented', 'ok', 'guest', false, allow);
      expect(decide(req('WebPage', 'in_app', params([['url', 'https://h5.example.com:443/x']])), s))
        .assertEqual('open WebPage allowed');
      expect(decide(req('WebPage', 'in_app', params([['url', 'https://shop.example.com/x']])), s))
        .assertEqual('reject - target_not_allowed');
      expect(decide(req('WebPage', 'in_app', params([['url', 'https://h5.example.com:8443/x']])), s))
        .assertEqual('reject - target_not_allowed');
    });
  });

  describe('RouterRealname', () => {
    it('phone_bound_is_not_realname', 0, () => {
      for (const route of ['Withdraw', 'PayoutAccount', 'LaborAgreement']) {
        expect(decide(req(route, 'in_app'), state('consented', 'ok', 'phone_bound')))
          .assertEqual('require_realname RealName realname_required');
        expect(decide(req(route, 'in_app'), state('consented', 'ok', 'phone_bound', true)))
          .assertEqual('open ' + route + ' allowed');
        expect(decide(req(route, 'in_app'), state('consented', 'ok', 'logged_in')))
          .assertEqual('require_bind_phone BindPhone phone_required');
        expect(decide(req(route, 'in_app'), state('consented', 'ok', 'guest')))
          .assertEqual('require_login Login login_required');
      }
    });

    it('guard_state_defaults', 0, () => {
      const s: GuardState = new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false, false);
      expect(s.realnameVerified).assertFalse();
      expect(s.targets.externalHosts.length + s.targets.bridgeOrigins.length).assertEqual(0);
      const odd: GuardState = new GuardState('x', 'y', 'z', true, '1.0.0', false, false);
      expect(odd.privacy + ' ' + odd.update + ' ' + odd.session).assertEqual('not_decided unknown guest');
    });
  });

  describe('RouterPendingAction', () => {
    it('prerequisite_registers_with_origin_and_resumes', 0, () => {
      const h: Harness = new Harness();
      const d: GuardDecision = h.router.open(req('Wallet', 'in_app'));
      expect(d.kind).assertEqual(GuardDecisionKind.REQUIRE_LOGIN);
      expect(h.nav.top()).assertEqual('Login');
      const p: PendingAction = h.pending() as PendingAction;
      expect(p.action).assertEqual(Router.OPEN_ROUTE_ACTION);
      expect(p.origin).assertEqual('in_app');
      expect(p.params['route'] as string).assertEqual('Wallet');
      h.box.session = 'logged_in';
      h.nowMillis += 60000;
      h.router.prerequisiteCompleted();
      expect(h.nav.top()).assertEqual('Wallet');
      expect(h.pending()).assertNull();
    });

    it('chained_prerequisites_keep_record', 0, () => {
      const h: Harness = new Harness();
      h.router.open(req('InviteShare', 'in_app'));
      expect(h.nav.top()).assertEqual('Login');
      h.box.session = 'logged_in';
      h.router.prerequisiteCompleted();
      expect(h.nav.top()).assertEqual('BindPhone');
      expect(h.pending() !== null).assertTrue();
      h.box.session = 'phone_bound';
      h.router.prerequisiteCompleted();
      expect(h.nav.top()).assertEqual('InviteShare');
      expect(h.pending()).assertNull();
    });

    it('sensitive_routes_do_not_register', 0, () => {
      for (const route of ['Withdraw', 'PayoutAccount', 'LaborAgreement', 'RealName']) {
        const h: Harness = new Harness();
        h.box.session = 'guest';
        h.router.open(req(route, 'in_app'));
        expect(h.nav.top()).assertEqual('Login');
        expect(h.pending()).assertNull();
        expect(h.backend.read()).assertNull();
      }
      const realname: Harness = new Harness();
      realname.box.session = 'phone_bound';
      const d: GuardDecision = realname.router.open(req('Withdraw', 'in_app'));
      expect(d.kind).assertEqual(GuardDecisionKind.REQUIRE_REALNAME);
      expect(realname.nav.top()).assertEqual('RealName');
      expect(realname.pending()).assertNull();
      const bind: Harness = new Harness();
      bind.box.session = 'logged_in';
      bind.router.open(req('RealName', 'push'));
      expect(bind.nav.top()).assertEqual('BindPhone');
      expect(bind.pending()).assertNull();
      expect(Router.registersPendingAction('DeleteAccount')).assertFalse();
      expect(Router.registersPendingAction('Wallet')).assertTrue();
    });

    it('agent_card_record_dropped_on_privacy_block', 0, () => {
      const h: Harness = new Harness();
      h.router.open(req('Wallet', 'agent_card'));
      expect(h.nav.top()).assertEqual('Login');
      expect((h.pending() as PendingAction).origin).assertEqual('agent_card');
      h.box.privacy = 'basic_mode';
      h.box.session = 'logged_in';
      h.router.prerequisiteCompleted();
      expect(h.pending()).assertNull();
      expect(h.nav.top()).assertEqual('Login');
    });

    it('agent_card_record_dropped_after_consent', 0, () => {
      const h: Harness = new Harness();
      h.router.open(req('Wallet', 'agent_card'));
      h.router.consentHandled(true);
      expect(h.pending()).assertNull();
    });

    it('agent_card_consent_not_registered', 0, () => {
      const h: Harness = new Harness();
      h.box.privacy = 'not_decided';
      h.box.session = 'logged_in';
      const d: GuardDecision = h.router.open(req('Wallet', 'agent_card'));
      expect(d.reason).assertEqual(GuardReason.AGENT_CONSENT_NO_REPLAY);
      expect(h.nav.consentRequests).assertEqual(1);
      expect(h.pending()).assertNull();
    });

    it('consent_registers_and_resumes_through_prerequisites', 0, () => {
      const h: Harness = new Harness();
      h.box.privacy = 'basic_mode';
      const d: GuardDecision = h.router.open(req('Wallet', 'in_app'));
      expect(d.kind).assertEqual(GuardDecisionKind.REQUIRE_CONSENT);
      expect(h.nav.consentRequests).assertEqual(1);
      expect((h.pending() as PendingAction).params['route'] as string).assertEqual('Wallet');
      h.box.privacy = 'consented';
      h.router.consentHandled(true);
      expect(h.nav.top()).assertEqual('Login');
      expect(h.pending() !== null).assertTrue();
      h.box.session = 'logged_in';
      h.router.prerequisiteCompleted();
      expect(h.nav.top()).assertEqual('Wallet');
      expect(h.pending()).assertNull();
    });

    it('agent_card_record_dropped_when_later_open_hits_privacy_block', 0, () => {
      const h: Harness = new Harness();
      h.router.open(req('Wallet', 'agent_card'));
      expect((h.pending() as PendingAction).origin).assertEqual('agent_card');
      h.box.privacy = 'not_decided';
      h.router.open(req('Home', 'deeplink'));
      expect(h.pending()).assertNull();
    });

    it('registered_params_are_cleaned_and_valid', 0, () => {
      const h: Harness = new Harness();
      h.router.open(req('OrderDetail', 'in_app', params([['order_id', 'o-1']])));
      const p: PendingAction = h.pending() as PendingAction;
      expect(JSON.stringify(p.params)).assertEqual('{"route":"OrderDetail","params":{"order_id":"o-1"}}');
      const agent: Harness = new Harness();
      agent.router.open(req('OrderList', 'agent_card'));
      expect(JSON.stringify((agent.pending() as PendingAction).params)).assertEqual('{"route":"OrderList"}');
    });

    it('consent_declined_clears', 0, () => {
      const h: Harness = new Harness();
      h.box.privacy = 'basic_mode';
      h.router.open(req('Search', 'in_app', params([['q', 'x']])));
      h.router.open(req('Wallet', 'in_app'));
      h.router.consentHandled(false);
      expect(h.pending()).assertNull();
    });

    it('session_end_clears', 0, () => {
      const h: Harness = new Harness();
      h.router.open(req('Wallet', 'in_app'));
      h.router.sessionEnded();
      expect(h.pending()).assertNull();
    });

    it('readonly_and_home_navigation', 0, () => {
      const h: Harness = new Harness();
      h.box.privacy = 'basic_mode';
      h.router.open(req('Search', 'in_app'));
      expect(h.nav.readonlyFlags[0]).assertTrue();
      h.router.open(req('Home', 'in_app'));
      expect(h.nav.stack.length).assertEqual(0);
      h.box.privacy = 'consented';
      h.router.open(req('NoSuchRoute', 'in_app'));
      expect(h.nav.top()).assertEqual('<upgrade>');
      h.box.update = 'below_min';
      h.router.open(req('Search', 'in_app'));
      expect(h.nav.stack.join(',')).assertEqual('ForceUpdate');
    });
  });

  describe('RouterPush', () => {
    it('lookup_result_redecided_with_latest_state', 0, async () => {
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const pending: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => pending.promise, 60000);
      h.router.enqueueLaunch(LaunchIntent.push('m1'));
      const ready: LaunchReadiness = new LaunchReadiness(true, PrivacyState.CONSENTED,
        UpdateCheckStatus.finished(UpdateState.OK));
      const run: Promise<void> | null = h.router.drainLaunchQueue(ready, h.nowMillis, landing);
      expect(run !== null).assertTrue();
      // 回查期间版本被判为低于最低版本：结果回来按最新状态进强更页。
      h.box.update = 'below_min';
      pending.resolve(PushLookupResult.found('Wallet'));
      await run;
      expect(h.nav.stack.join(',')).assertEqual('ForceUpdate');
    });

    it('lookup_result_dropped_after_logout', 0, async () => {
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const pending: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => pending.promise, 60000);
      h.router.enqueueLaunch(LaunchIntent.push('m1'));
      const run: Promise<void> | null = h.router.drainLaunchQueue(
        new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        h.nowMillis, landing);
      h.router.sessionEnded();
      h.box.session = 'guest';
      pending.resolve(PushLookupResult.found('Wallet'));
      await run;
      expect(h.nav.stack.length).assertEqual(0);
    });

    it('stale_lookup_dropped_after_account_switch', 0, async () => {
      // A 登录 → 回查挂起 → 退出 → B 登录：旧结果不得打开。
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const pending: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => pending.promise, 60000);
      h.router.enqueueLaunch(LaunchIntent.push('m-a'));
      const run: Promise<void> | null = h.router.drainLaunchQueue(
        new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        h.nowMillis, landing);
      h.router.sessionEnded();
      h.box.session = 'logged_in';
      pending.resolve(PushLookupResult.found('Wallet'));
      await run;
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.pending()).assertNull();
    });

    it('stale_lookup_dropped_after_environment_switch', 0, async () => {
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const pending: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => pending.promise, 60000);
      h.router.enqueueLaunch(LaunchIntent.push('m-a'));
      const run: Promise<void> | null = h.router.drainLaunchQueue(
        new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        h.nowMillis, landing);
      h.router.environmentChanged();
      pending.resolve(PushLookupResult.found('Wallet'));
      await run;
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.router.hasPendingLaunchIntent).assertFalse();
    });

    it('timeout_falls_back_immediately_and_late_result_dropped', 0, async () => {
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const never: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => never.promise, 20);
      h.router.enqueueLaunch(LaunchIntent.push('m1'));
      const started: number = Date.now();
      const run: Promise<void> | null = h.router.drainLaunchQueue(
        new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        h.nowMillis, landing);
      await run;
      expect(Date.now() - started < 2000).assertTrue();
      expect(h.nav.stack.join(',')).assertEqual('Messages');
      never.resolve(PushLookupResult.found('Wallet'));
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 10);
      });
      expect(h.nav.stack.join(',')).assertEqual('Messages');
    });

    it('environment_change_during_lookup_requeues', 0, async () => {
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const pending: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => pending.promise, 60000);
      h.router.enqueueLaunch(LaunchIntent.push('m1'));
      const run: Promise<void> | null = h.router.drainLaunchQueue(
        new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        h.nowMillis, landing);
      h.box.settled = false;
      pending.resolve(PushLookupResult.found('Wallet'));
      await run;
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
    });

    it('fallbacks_open_messages', 0, async () => {
      const s: GuardState = state('consented', 'ok', 'logged_in');
      const notFound: PushLanding = new PushLanding((id: string) => Promise.resolve(PushLookupResult.notFound()));
      expect((await notFound.land('m', (): GuardState => s))?.decision.toString()).assertEqual('open Messages allowed');
      const empty: PushLanding = new PushLanding((id: string) => Promise.resolve(PushLookupResult.found(null)));
      expect((await empty.land('m', (): GuardState => s))?.decision.toString()).assertEqual('open Messages allowed');
      const failing: PushLanding = new PushLanding((id: string) => Promise.reject(new Error('x')));
      expect((await failing.land('m', (): GuardState => s))?.decision.toString()).assertEqual('open Messages allowed');
      const slow: PushLanding = new PushLanding((id: string) => new Deferred().promise, 10);
      expect((await slow.land('m', (): GuardState => s))?.decision.toString()).assertEqual('open Messages allowed');
      const login: PushLanding = new PushLanding((id: string) => Promise.resolve(PushLookupResult.found('Login')));
      expect((await login.land('m', (): GuardState => s))?.decision.toString()).assertEqual('open Messages push_entry_fallback');
    });

    it('land_drops_result_when_generation_changed', 0, async () => {
      const s: GuardState = state('consented', 'ok', 'logged_in');
      let generation: number = 0;
      const pending: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => pending.promise, 60000);
      const issued: number = generation;
      const run: Promise<PushLandingResult | null> = landing.land('m', (): GuardState => s,
        (): boolean => issued === generation, RELEASE_ROUTES);
      generation++;
      pending.resolve(PushLookupResult.found('Wallet'));
      expect(await run).assertNull();
      // 结果回来时状态已变：按最新状态重判（游客 → 登录）。
      let latest: GuardState = s;
      const again: Deferred = new Deferred();
      const landing2: PushLanding = new PushLanding((id: string) => again.promise, 60000);
      const run2: Promise<PushLandingResult | null> = landing2.land('m', (): GuardState => latest);
      latest = state('consented', 'ok', 'guest');
      again.resolve(PushLookupResult.found('Wallet'));
      expect((await run2)?.decision.toString()).assertEqual('require_login Login login_required');
    });

    it('hot_push_uses_same_guarded_path', 0, async () => {
      // 热启动推送：前置不满足不回查；回查期间退出登录则丢弃。
      const blocked: Harness = new Harness();
      blocked.box.update = 'below_min';
      blocked.box.session = 'logged_in';
      let lookups: number = 0;
      const counting: PushLanding = new PushLanding((id: string) => {
        lookups++;
        return Promise.resolve(PushLookupResult.found('Wallet'));
      });
      expect(blocked.router.openPush('m1', counting)).assertNull();
      expect(lookups).assertEqual(0);
      expect(blocked.nav.top()).assertEqual('ForceUpdate');

      const unsettled: Harness = new Harness();
      unsettled.box.settled = false;
      unsettled.box.session = 'logged_in';
      expect(unsettled.router.openPush('m1', counting)).assertNull();
      expect(lookups).assertEqual(0);
      expect(unsettled.router.hasPendingLaunchIntent).assertTrue();

      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const pending: Deferred = new Deferred();
      const run: Promise<void> | null = h.router.openPush('m1',
        new PushLanding((id: string) => pending.promise, 60000));
      expect(run !== null).assertTrue();
      const before: number = h.router.sessionGeneration;
      h.router.sessionEnded();
      expect(h.router.sessionGeneration).assertEqual(before + 1);
      pending.resolve(PushLookupResult.found('Wallet'));
      await run;
      expect(h.nav.stack.length).assertEqual(0);

      const ok: Harness = new Harness();
      ok.box.session = 'logged_in';
      await ok.router.openPush('m1', new PushLanding((id: string) => Promise.resolve(PushLookupResult.found('Wallet'))));
      expect(ok.nav.top()).assertEqual('Wallet');
    });

    it('no_lookup_when_gate_blocks', 0, () => {
      const cases: string[][] = [['below_min', 'logged_in', 'ForceUpdate'], ['ok', 'restricted', 'Login']];
      for (const c of cases) {
        const h: Harness = new Harness();
        h.box.update = c[0];
        h.box.session = c[1];
        let lookups: number = 0;
        const landing: PushLanding = new PushLanding((id: string) => {
          lookups++;
          return Promise.resolve(PushLookupResult.found('Wallet'));
        });
        h.router.enqueueLaunch(LaunchIntent.push('m1'));
        const run: Promise<void> | null = h.router.drainLaunchQueue(new LaunchReadiness(true, PrivacyState.CONSENTED,
          UpdateCheckStatus.finished(c[0] === 'below_min' ? UpdateState.BELOW_MIN : UpdateState.OK)), h.nowMillis,
          landing);
        expect(run).assertNull();
        expect(lookups).assertEqual(0);
        expect(h.nav.top()).assertEqual(c[2]);
      }
      // 环境未就绪、隐私未决：排队器本身不放行，也不回查。
      const h: Harness = new Harness();
      let lookups: number = 0;
      const landing: PushLanding = new PushLanding((id: string) => {
        lookups++;
        return Promise.resolve(PushLookupResult.found('Wallet'));
      });
      h.router.enqueueLaunch(LaunchIntent.push('m1'));
      expect(h.router.drainLaunchQueue(new LaunchReadiness(false, PrivacyState.CONSENTED,
        UpdateCheckStatus.finished(UpdateState.OK)), h.nowMillis, landing)).assertNull();
      expect(h.router.drainLaunchQueue(new LaunchReadiness(true, PrivacyState.NOT_DECIDED,
        UpdateCheckStatus.finished(UpdateState.OK)), h.nowMillis, landing)).assertNull();
      expect(lookups).assertEqual(0);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
    });

    it('messages_fallback_goes_through_guard', 0, () => {
      // 回查到未声明 push 的路由、强更未知时的兜底：Messages 照样过守卫，游客要先登录。
      expect(decide(req('Login', 'push'), state('consented', 'ok', 'guest')))
        .assertEqual('require_login Login login_required');
      expect(decide(req('AuthManage', 'push'), state('consented', 'unknown', 'guest')))
        .assertEqual('require_login Login login_required');
      expect(decide(req('Login', 'push'), state('consented', 'ok', 'logged_in')))
        .assertEqual('open Messages push_entry_fallback');
    });

    it('router_open_push_never_lets_guest_into_messages', 0, () => {
      // 兜底改落 Messages 时 EntryGuard 自己对 Messages 完整判定：任何调用路径（含直接 Router.open(source=push)）游客都进不了 Messages。
      const cases: string[][] = [['Login', 'ok'], ['AuthManage', 'unknown'], ['Messages', 'ok'], ['Messages', 'unknown'],
        ['LaborAgreement', 'ok']];
      for (const c of cases) {
        const h: Harness = new Harness();
        h.box.update = c[1];
        const d: GuardDecision = h.router.open(req(c[0], 'push'));
        expect(d.toString()).assertEqual('require_login Login login_required');
        expect(h.nav.stack.join(',')).assertEqual('Login');
        expect(h.nav.stack.indexOf('Messages')).assertEqual(-1);
        // 登记的是兜底后的 Messages（LaborAgreement 也落 Messages，可登记）。
        expect((h.pending() as PendingAction).params['route'] as string).assertEqual('Messages');
        h.box.session = 'logged_in';
        h.router.prerequisiteCompleted();
        expect(h.nav.top()).assertEqual('Messages');
      }
      // 登录后：入口不允许 / 强更未知的兜底才打开 Messages。
      const ok: Harness = new Harness();
      ok.box.session = 'logged_in';
      expect(ok.router.open(req('Login', 'push')).toString()).assertEqual('open Messages push_entry_fallback');
      const unknown: Harness = new Harness();
      unknown.box.session = 'logged_in';
      unknown.box.update = 'unknown';
      expect(unknown.router.open(req('AuthManage', 'push')).toString())
        .assertEqual('open_readonly Messages update_unknown_push_fallback');
      expect(unknown.nav.top()).assertEqual('Messages');
    });

    it('lookup_result_needing_login_after_logout_without_session_end', 0, async () => {
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const pending: Deferred = new Deferred();
      const landing: PushLanding = new PushLanding((id: string) => pending.promise, 60000);
      h.router.enqueueLaunch(LaunchIntent.push('m1'));
      const run: Promise<void> | null = h.router.drainLaunchQueue(
        new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        h.nowMillis, landing);
      h.box.session = 'guest';
      pending.resolve(PushLookupResult.found('Wallet'));
      await run;
      expect(h.nav.top()).assertEqual('Login');
      expect((h.pending() as PendingAction).params['route'] as string).assertEqual('Messages');
    });

    it('guest_goes_to_login_then_messages_without_lookup', 0, async () => {
      const h: Harness = new Harness();
      let lookups: number = 0;
      const landing: PushLanding = new PushLanding((id: string) => {
        lookups++;
        return Promise.resolve(PushLookupResult.found('Wallet'));
      });
      h.router.enqueueLaunch(LaunchIntent.push('m1'));
      const run: Promise<void> | null = h.router.drainLaunchQueue(
        new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)),
        h.nowMillis, landing);
      expect(run).assertNull();
      expect(lookups).assertEqual(0);
      expect(h.nav.top()).assertEqual('Login');
      h.box.session = 'logged_in';
      h.router.prerequisiteCompleted();
      expect(h.nav.top()).assertEqual('Messages');
    });
  });

  describe('RouterLaunchQueue', () => {
    it('waits_for_environment_privacy_and_update', 0, () => {
      const q: LaunchQueue = new LaunchQueue();
      q.enqueue(LaunchIntent.route(req('Home', 'deeplink')));
      const checking: UpdateCheckStatus = UpdateCheckStatus.checking(1000);
      // 闸门长期未就绪：不放行，也不需要定时器（不空转）。
      const closed: LaunchReadiness = new LaunchReadiness(false, PrivacyState.CONSENTED, checking);
      expect(q.release(closed, 20000)).assertNull();
      expect(q.nextDeadline(closed)).assertNull();
      const undecided: LaunchReadiness = new LaunchReadiness(true, PrivacyState.NOT_DECIDED, checking);
      expect(q.release(undecided, 30000)).assertNull();
      expect(q.nextDeadline(undecided)).assertNull();
      // 闸门在 40000 通过：5 秒从这里起算，不从入队或检查开始（1000）起算。
      const open: LaunchReadiness = new LaunchReadiness(true, PrivacyState.CONSENTED, checking);
      expect(q.release(open, 40000)).assertNull();
      expect(q.nextDeadline(open)).assertEqual(45000);
      expect(q.release(open, 44999)).assertNull();
      const released: LaunchRelease | null = q.release(open, 45000);
      expect(released?.update).assertEqual(UpdateState.UNKNOWN);
      expect(q.pending).assertNull();
      expect(q.nextDeadline(open)).assertNull();
    });

    it('check_started_after_gates_counts_from_check_start', 0, () => {
      const q: LaunchQueue = new LaunchQueue();
      q.enqueue(LaunchIntent.route(req('Home', 'deeplink')));
      expect(q.release(new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.checking(2000)), 1000))
        .assertNull();
      const later: LaunchReadiness = new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.checking(3000));
      expect(q.nextDeadline(later)).assertEqual(8000);
      expect(q.release(later, 7999)).assertNull();
      expect(q.release(later, 8000)?.update).assertEqual(UpdateState.UNKNOWN);
    });

    it('finished_result_releases_immediately', 0, () => {
      const q: LaunchQueue = new LaunchQueue();
      q.enqueue(LaunchIntent.push('m'));
      const r: LaunchRelease | null = q.release(new LaunchReadiness(true, PrivacyState.BASIC_MODE,
        UpdateCheckStatus.finished(UpdateState.BELOW_MIN)), 0);
      expect(r?.update).assertEqual(UpdateState.BELOW_MIN);
      expect(r?.intent.messageId).assertEqual('m');
    });

    it('deferred_external_request_is_queued_and_drained', 0, () => {
      const h: Harness = new Harness();
      h.box.settled = false;
      const d: GuardDecision = h.router.open(req('Search', 'deeplink', params([['q', 'a']])));
      expect(d.kind).assertEqual(GuardDecisionKind.DEFER);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
      h.box.settled = true;
      h.router.drainLaunchQueue(new LaunchReadiness(true, PrivacyState.CONSENTED,
        UpdateCheckStatus.finished(UpdateState.OK)), h.nowMillis);
      expect(h.nav.top()).assertEqual('Search');
    });
  });

  describe('RouterUpdateWait', () => {
    // R1-01：强更检查中，pending_action 恢复、启动意图、推送回查都等结果（闸门通过后最长 5 秒），不立即按 unknown。
    it('pending_action_waits_for_check_result', 0, () => {
      const h: Harness = new Harness(true);
      h.router.open(req('AuthManage', 'in_app'));
      expect(h.nav.top()).assertEqual('Login');
      h.startChecking();
      h.box.session = 'logged_in';
      h.nowMillis += 1000;
      h.router.prerequisiteCompleted();
      // 检查中：不判 update_unknown_blocked，不删除记录，不打开。
      expect(h.pending() !== null).assertTrue();
      expect(h.nav.top()).assertEqual('Login');
      expect(h.router.updateWaitDeadline(h.ready.current(), h.nowMillis)).assertEqual(1005000);
      h.nowMillis += 2000;
      h.finishCheck(UpdateState.OK);
      expect(h.settle()).assertNull();
      expect(h.nav.top()).assertEqual('AuthManage');
      expect(h.pending()).assertNull();
      expect(h.router.updateWaitDeadline(h.ready.current(), h.nowMillis)).assertNull();
    });

    it('pending_action_unknown_only_after_timeout', 0, () => {
      const h: Harness = new Harness(true);
      h.router.open(req('AuthManage', 'in_app'));
      h.startChecking();
      h.box.session = 'logged_in';
      h.router.prerequisiteCompleted();
      h.nowMillis += 4999;
      h.settle();
      expect(h.pending() !== null).assertTrue();
      expect(h.nav.top()).assertEqual('Login');
      h.nowMillis += 1;
      h.settle();
      // 满 5 秒按 unknown：AuthManage 不在只读清单，丢弃，不打开。
      expect(h.router.lastDecision?.toString()).assertEqual('reject - update_unknown_blocked');
      expect(h.pending()).assertNull();
      expect(h.nav.top()).assertEqual('Login');
      expect(h.router.updateWaitDeadline(h.ready.current(), h.nowMillis)).assertNull();
      // 只读清单里的动作超时后只读打开。
      const ro: Harness = new Harness(true);
      ro.box.session = 'logged_in';
      ro.box.privacy = 'basic_mode';
      ro.router.open(req('OrderList', 'in_app'));
      ro.box.privacy = 'consented';
      ro.startChecking();
      ro.nowMillis += 5000;
      ro.settle();
      expect(ro.nav.top()).assertEqual('OrderList');
      expect(ro.nav.readonlyFlags[ro.nav.readonlyFlags.length - 1]).assertTrue();
    });

    it('wait_counts_from_gate_passage_not_shell', 0, () => {
      const h: Harness = new Harness(true);
      h.ready.privacy = PrivacyState.NOT_DECIDED;
      h.startChecking();
      h.router.observeReadiness(h.ready.current(), h.nowMillis);
      expect(h.router.updateWaitDeadline(h.ready.current(), h.nowMillis)).assertNull();
      // 闸门在 +10000 通过：外壳尚未就绪也记下时刻（App 只调 observeReadiness），5 秒从这里起算。
      h.nowMillis += 10000;
      h.ready.privacy = PrivacyState.CONSENTED;
      h.router.observeReadiness(h.ready.current(), h.nowMillis);
      expect(h.router.updateWaitDeadline(h.ready.current(), h.nowMillis)).assertEqual(1015000);
      h.router.enqueueLaunch(LaunchIntent.route(req('Search', 'deeplink')));
      // 外壳在 +15000 才就绪：已到期，立即按 unknown 放行（Search 在只读清单）。
      h.nowMillis += 5000;
      h.settle();
      expect(h.nav.top()).assertEqual('Search');
      expect(h.nav.readonlyFlags[0]).assertTrue();
    });

    it('external_requests_wait_in_app_does_not', 0, () => {
      const h: Harness = new Harness(true);
      h.box.session = 'phone_bound';
      h.startChecking();
      for (const source of ['deeplink', 'bridge', 'agent_card', 'push']) {
        // deeplink 对 Wallet 未声明，这里只看等待：检查中一律先排队，不交给 EntryGuard。
        const d: GuardDecision = h.router.open(req('Wallet', source));
        expect(d.toString()).assertEqual('defer - update_checking');
        expect(h.router.hasPendingLaunchIntent).assertTrue();
      }
      expect(h.nav.stack.length).assertEqual(0);
      // App 内用户自己的操作不在等待表里，照 App 给的状态判定。
      expect(h.router.open(req('Search', 'in_app')).toString()).assertEqual('open Search allowed');
      h.nav.reset([]);
      h.nowMillis += 300;
      h.finishCheck(UpdateState.OK);
      h.settle();
      expect(h.nav.top()).assertEqual('Wallet');
    });

    it('hot_push_waits_then_looks_up', 0, async () => {
      const h: Harness = new Harness(true);
      h.box.session = 'logged_in';
      h.startChecking();
      let lookups: number = 0;
      const landing: PushLanding = new PushLanding((id: string) => {
        lookups++;
        return Promise.resolve(PushLookupResult.found('Wallet'));
      });
      expect(h.router.openPush('m1', landing)).assertNull();
      expect(lookups).assertEqual(0);
      expect(h.router.lastDecision?.reason).assertEqual(GuardReason.UPDATE_CHECKING);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
      expect(h.nav.stack.length).assertEqual(0);
      h.nowMillis += 1000;
      h.finishCheck(UpdateState.OK);
      const run: Promise<void> | null = h.settle(landing);
      expect(run !== null).assertTrue();
      await (run as Promise<void>);
      expect(lookups).assertEqual(1);
      expect(h.nav.top()).assertEqual('Wallet');
    });

    it('hot_push_after_timeout_falls_back_readonly', 0, async () => {
      const h: Harness = new Harness(true);
      h.box.session = 'logged_in';
      h.startChecking();
      const landing: PushLanding = new PushLanding((id: string) =>
        Promise.resolve(PushLookupResult.found('AuthManage')));
      expect(h.router.openPush('m1', landing)).assertNull();
      h.nowMillis += 5000;
      const run: Promise<void> | null = h.settle(landing);
      expect(run !== null).assertTrue();
      await (run as Promise<void>);
      expect(h.router.lastDecision?.toString()).assertEqual('open_readonly Messages update_unknown_push_fallback');
      expect(h.nav.top()).assertEqual('Messages');
    });

    it('basic_mode_does_not_wait', 0, () => {
      const h: Harness = new Harness(true);
      h.ready.privacy = PrivacyState.BASIC_MODE;
      h.box.privacy = 'basic_mode';
      h.startChecking();
      expect(h.router.updateWaitDeadline(h.ready.current(), h.nowMillis)).assertNull();
      expect(h.router.open(req('Search', 'deeplink')).kind).assertEqual(GuardDecisionKind.OPEN_READONLY);
    });
  });

  describe('RouterColdStartResume', () => {
    // R1-02：冷启动与前置条件变化后，闸门、强更、外壳都就绪时按 BR-ID-10 处理持久化的 pending_action。
    it('resumes_persisted_action_once', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const before: Harness = new Harness(true, backend);
      before.router.open(req('OrderList', 'in_app'));
      expect(before.nav.top()).assertEqual('Login');
      // 进程被回收后重启：新 Router、同一份持久化记录，已登录且闸门都通过。
      const h: Harness = new Harness(true, backend);
      h.nowMillis = before.nowMillis + 9 * 60000;
      h.box.session = 'logged_in';
      h.settle();
      expect(h.nav.stack.join(',')).assertEqual('OrderList');
      expect(h.pending()).assertNull();
      expect(backend.read()).assertNull();
      h.settle();
      expect(h.nav.stack.join(',')).assertEqual('OrderList');
    });

    it('expired_record_deleted', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const before: Harness = new Harness(true, backend);
      before.router.open(req('OrderList', 'in_app'));
      const h: Harness = new Harness(true, backend);
      h.nowMillis = before.nowMillis + PendingActionStore.TTL_MILLIS + 1;
      h.box.session = 'logged_in';
      h.settle();
      expect(h.nav.stack.length).assertEqual(0);
      expect(backend.read()).assertNull();
    });

    it('unmet_prerequisite_keeps_record_silently', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const before: Harness = new Harness(true, backend);
      before.router.open(req('InviteShare', 'in_app'));
      const h: Harness = new Harness(true, backend);
      h.nowMillis = before.nowMillis + 60000;
      h.box.session = 'logged_in';
      h.settle();
      // 还缺绑手机：保留，不自动弹前置页。
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.pending() !== null).assertTrue();
      h.box.session = 'phone_bound';
      h.settle();
      expect(h.nav.top()).assertEqual('InviteShare');
      expect(h.pending()).assertNull();
    });

    it('not_ready_keeps_record', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const before: Harness = new Harness(true, backend);
      before.router.open(req('OrderList', 'in_app'));
      const h: Harness = new Harness(true, backend);
      h.box.session = 'logged_in';
      h.ready.privacy = PrivacyState.NOT_DECIDED;
      h.box.privacy = 'not_decided';
      h.settle();
      h.ready.privacy = PrivacyState.CONSENTED;
      h.box.privacy = 'consented';
      h.ready.settled = false;
      h.box.settled = false;
      h.settle();
      h.ready.settled = true;
      h.box.settled = true;
      h.startChecking();
      h.settle();
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.nav.consentRequests).assertEqual(0);
      expect(h.pending() !== null).assertTrue();
      h.finishCheck(UpdateState.OK);
      h.settle();
      expect(h.nav.top()).assertEqual('OrderList');
      expect(h.pending()).assertNull();
    });

    it('privacy_block_keeps_record_until_consent', 0, () => {
      const h: Harness = new Harness(true);
      h.box.privacy = 'basic_mode';
      h.ready.privacy = PrivacyState.BASIC_MODE;
      h.box.session = 'logged_in';
      h.router.open(req('Wallet', 'in_app'));
      expect(h.nav.consentRequests).assertEqual(1);
      h.settle();
      expect(h.pending() !== null).assertTrue();
      expect(h.nav.consentRequests).assertEqual(1);
      expect(h.nav.stack.length).assertEqual(0);
      h.box.privacy = 'consented';
      h.ready.privacy = PrivacyState.CONSENTED;
      h.router.consentHandled(true);
      expect(h.nav.top()).assertEqual('Wallet');
      expect(h.pending()).assertNull();
    });

    it('below_min_drops_into_force_update', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const before: Harness = new Harness(true, backend);
      before.router.open(req('OrderList', 'in_app'));
      const h: Harness = new Harness(true, backend);
      h.box.session = 'logged_in';
      h.finishCheck(UpdateState.BELOW_MIN);
      h.settle();
      expect(h.nav.stack.join(',')).assertEqual('ForceUpdate');
      expect(h.pending()).assertNull();
    });
  });

  describe('RouterPushLookupFailure', () => {
    // R1-03：回查函数同步抛错、拒绝、超时都落到 Messages（经 EntryGuard 再判定），openPush 不失败。
    it('sync_throw_rejection_and_timeout_open_messages', 0, async () => {
      const lookups: PushLanding[] = [
        new PushLanding((id: string): Promise<PushLookupResult> => {
          throw new Error('sync');
        }),
        new PushLanding((id: string) => Promise.reject(new Error('async'))),
        new PushLanding((id: string) => new Deferred().promise, 10)
      ];
      for (const landing of lookups) {
        const h: Harness = new Harness();
        h.box.session = 'logged_in';
        const run: Promise<void> | null = h.router.openPush('m1', landing);
        expect(run !== null).assertTrue();
        let failed: boolean = false;
        try {
          await (run as Promise<void>);
        } catch (e) {
          failed = true;
        }
        expect(failed).assertFalse();
        expect(h.router.lastDecision?.toString()).assertEqual('open Messages allowed');
        expect(h.nav.stack.join(',')).assertEqual('Messages');
      }
    });

    it('sync_throw_rechecked_by_guard', 0, async () => {
      // 回查期间强更结果变为 unknown：兜底的 Messages 仍经守卫，只读打开。
      const h: Harness = new Harness();
      h.box.session = 'logged_in';
      const run: Promise<void> | null = h.router.openPush('m1',
        new PushLanding((id: string): Promise<PushLookupResult> => {
          throw new Error('sync');
        }));
      h.box.update = 'unknown';
      await (run as Promise<void>);
      expect(h.router.lastDecision?.toString()).assertEqual('open_readonly Messages update_unknown_readonly');
      // 冷启动排队的推送同样兜底。
      const q: Harness = new Harness();
      q.box.session = 'logged_in';
      q.router.enqueueLaunch(LaunchIntent.push('m2'));
      const throwing: PushLanding = new PushLanding((id: string): Promise<PushLookupResult> => {
        throw new Error('sync');
      });
      const queued: Promise<void> | null = q.router.drainLaunchQueue(new LaunchReadiness(true, PrivacyState.CONSENTED,
        UpdateCheckStatus.finished(UpdateState.OK)), q.nowMillis, throwing);
      expect(queued !== null).assertTrue();
      await (queued as Promise<void>);
      expect(q.nav.top()).assertEqual('Messages');
      const fallback: RouteRequest = await throwing.lookUp('m3');
      expect(fallback.route + ' ' + fallback.source).assertEqual('Messages push');
    });
  });

  describe('RouterDeepLinkScheme', () => {
    it('debug_scheme_only_when_configured', 0, () => {
      const debug: DeepLinkConfig = new DeepLinkConfig(['couli-debug'], []);
      const parsed: RouteRequest | null = DeepLinkParser.parse('couli-debug://r/Search?q=a', debug, RELEASE_ROUTES);
      expect(parsed?.route).assertEqual('Search');
      expect(DeepLinkParser.parse('couli-debug://r/Search?q=a', DeepLinkConfig.EMPTY, RELEASE_ROUTES)).assertNull();
      expect(DeepLinkParser.parse('couli-debug://r/Search?q=a#x', debug, RELEASE_ROUTES)).assertNull();
      expect(DeepLinkParser.parse('couli-debug://r/Search?q=%E0%A4', debug, RELEASE_ROUTES)).assertNull();
      expect(DeepLinkParser.parse('couli-debug://r/Search?q=a&q=b', debug, RELEASE_ROUTES)).assertNull();
      // 未知路由名照常解析，由守卫进升级提示。
      expect(DeepLinkParser.parse('couli-debug://r/Future', debug, RELEASE_ROUTES)?.route).assertEqual('Future');
    });
  });

  describe('RouterReviewR2', () => {
    // R2-01：排队的推送保留回查器；等待结束后 stateChanged 不传回查器也能继续回查，按最新状态打开目标或 Messages。
    it('queued_push_keeps_landing_after_check_finishes', 0, async () => {
      const h: Harness = new Harness(true);
      h.box.session = 'logged_in';
      h.startChecking();
      let lookups: number = 0;
      const landing: PushLanding = new PushLanding((id: string) => {
        lookups++;
        return Promise.resolve(PushLookupResult.found('Wallet'));
      });
      expect(h.router.openPush('m1', landing)).assertNull();
      expect(lookups).assertEqual(0);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
      h.nowMillis += 1000;
      h.finishCheck(UpdateState.OK);
      // App 的接线：stateChanged 不带回查器（AppRouting.stateChanged 的调用方式）。
      const run: Promise<void> | null = h.settle();
      expect(run !== null).assertTrue();
      await (run as Promise<void>);
      expect(lookups).assertEqual(1);
      expect(h.nav.stack.join(',')).assertEqual('Wallet');
      expect(h.router.hasPendingLaunchIntent).assertFalse();
      // 再次状态变化不重复回查。
      expect(h.settle()).assertNull();
      expect(lookups).assertEqual(1);
    });

    it('queued_push_keeps_landing_after_timeout', 0, async () => {
      const h: Harness = new Harness(true);
      h.box.session = 'logged_in';
      h.startChecking();
      let lookups: number = 0;
      const landing: PushLanding = new PushLanding((id: string) => {
        lookups++;
        return Promise.resolve(PushLookupResult.found('AuthManage'));
      });
      expect(h.router.openPush('m1', landing)).assertNull();
      h.nowMillis += 4999;
      expect(h.settle()).assertNull();
      expect(lookups).assertEqual(0);
      h.nowMillis += 1;
      const run: Promise<void> | null = h.settle();
      expect(run !== null).assertTrue();
      await (run as Promise<void>);
      expect(lookups).assertEqual(1);
      // 满 5 秒按 unknown：AuthManage 不在只读清单，改开只读 Messages。
      expect(h.router.lastDecision?.toString()).assertEqual('open_readonly Messages update_unknown_push_fallback');
      expect(h.nav.stack.join(',')).assertEqual('Messages');
    });

    it('injected_landing_used_for_queued_push', 0, async () => {
      const h: Harness = new Harness(true);
      h.box.session = 'logged_in';
      let lookups: number = 0;
      h.router.setPushLanding(new PushLanding((id: string) => {
        lookups++;
        return Promise.resolve(PushLookupResult.found('OrderList'));
      }));
      h.startChecking();
      h.router.enqueueLaunch(LaunchIntent.push('m9'));
      h.nowMillis += 200;
      h.finishCheck(UpdateState.OK);
      const run: Promise<void> | null = h.settle();
      expect(run !== null).assertTrue();
      await (run as Promise<void>);
      expect(lookups).assertEqual(1);
      expect(h.nav.top()).assertEqual('OrderList');
    });

    // R2-02：前置完成后因强更等待暂停，等待结束时按「刚完成前置」继续进下一个前置页。
    it('prerequisite_completed_during_check_enters_next_prerequisite', 0, () => {
      const h: Harness = new Harness(true);
      h.router.open(req('InviteShare', 'in_app'));
      expect(h.nav.stack.join(',')).assertEqual('Login');
      h.startChecking();
      h.box.session = 'logged_in';
      h.nowMillis += 1000;
      h.router.prerequisiteCompleted();
      expect(h.nav.stack.join(',')).assertEqual('Login');
      expect(h.pending() !== null).assertTrue();
      h.nowMillis += 1000;
      h.finishCheck(UpdateState.OK);
      h.settle();
      expect(h.router.lastDecision?.kind).assertEqual(GuardDecisionKind.REQUIRE_BIND_PHONE);
      expect(h.nav.stack.join(',')).assertEqual('Login,BindPhone');
      expect(h.pending() !== null).assertTrue();
      // 只继续一次：后续普通状态变化回到静默恢复，不再重复推前置页。
      h.settle();
      expect(h.nav.stack.join(',')).assertEqual('Login,BindPhone');
      h.box.session = 'phone_bound';
      h.router.prerequisiteCompleted();
      expect(h.nav.top()).assertEqual('InviteShare');
      expect(h.pending()).assertNull();
    });

    it('prerequisite_completed_during_check_continues_after_timeout', 0, () => {
      const h: Harness = new Harness(true);
      h.router.open(req('InviteShare', 'in_app'));
      h.startChecking();
      h.box.session = 'logged_in';
      h.router.prerequisiteCompleted();
      h.nowMillis += 5000;
      h.settle();
      // 满 5 秒按 unknown，与未等待时 prerequisiteCompleted 同口径：InviteShare 不在只读清单，删除、不进前置页。
      expect(h.router.lastDecision?.toString()).assertEqual('reject - update_unknown_blocked');
      expect(h.nav.stack.join(',')).assertEqual('Login');
      expect(h.pending()).assertNull();
      // 只读清单内、登录后还要处理的动作：等满 5 秒后按「刚完成前置」直接只读打开。
      const w: Harness = new Harness(true);
      w.router.open(req('Wallet', 'in_app'));
      w.startChecking();
      w.box.session = 'logged_in';
      w.router.prerequisiteCompleted();
      w.nowMillis += 5000;
      w.settle();
      expect(w.nav.stack.join(',')).assertEqual('Login,Wallet');
      expect(w.nav.readonlyFlags[w.nav.readonlyFlags.length - 1]).assertTrue();
      expect(w.pending()).assertNull();
    });

    it('silent_resume_still_silent_without_completed_prerequisite', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const before: Harness = new Harness(true, backend);
      before.router.open(req('InviteShare', 'in_app'));
      const h: Harness = new Harness(true, backend);
      h.box.session = 'logged_in';
      h.startChecking();
      h.settle();
      h.finishCheck(UpdateState.OK);
      h.settle();
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.pending() !== null).assertTrue();
    });

    // R2-03：自动恢复遇到守卫 reject 删除记录、不补执行；只有等待类与前置未满足保留。
    it('basic_mode_blocked_on_auto_resume_deletes_record', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const before: Harness = new Harness(true, backend);
      before.router.open(req('OrderList', 'in_app'));
      expect(before.nav.top()).assertEqual('Login');
      // 10 分钟内冷启动，当前为基本模式。
      const h: Harness = new Harness(true, backend);
      h.nowMillis = before.nowMillis + 9 * 60000;
      h.box.privacy = 'basic_mode';
      h.ready.privacy = PrivacyState.BASIC_MODE;
      h.settle();
      expect(h.router.lastDecision?.toString()).assertEqual('reject - basic_mode_blocked');
      expect(h.pending()).assertNull();
      expect(backend.read()).assertNull();
      // 之后同意隐私并登录：不补执行旧 OrderList。
      h.box.privacy = 'consented';
      h.ready.privacy = PrivacyState.CONSENTED;
      h.settle();
      h.box.session = 'logged_in';
      h.settle();
      h.router.prerequisiteCompleted();
      expect(h.nav.stack.length).assertEqual(0);
    });

    it('params_invalid_on_auto_resume_deletes_record', 0, () => {
      const h: Harness = new Harness(true);
      h.box.session = 'logged_in';
      const values: Record<string, Object> = params([['route', 'OrderList'], ['params', params([['scope', 'bad']])]]);
      h.store.save(Router.OPEN_ROUTE_ACTION, values, h.nowMillis, 'in_app');
      h.settle();
      expect(h.router.lastDecision?.toString()).assertEqual('reject - params_invalid');
      expect(h.pending()).assertNull();
      expect(h.nav.stack.length).assertEqual(0);
    });

    it('entry_not_allowed_on_auto_resume_deletes_record', 0, () => {
      const pushOnly: RouteSpec = new RouteSpec('PushOnly', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.PUSH], null,
        false);
      const routes: RouteLookup = (name: string): RouteSpec | undefined =>
        name === 'PushOnly' ? pushOnly : Routes.spec(name);
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      let now: number = 1000000;
      const store: PendingActionStore = new PendingActionStore(backend, (): number => now);
      const nav: RecordingNavigator = new RecordingNavigator();
      const ready: ReadinessBox = new ReadinessBox();
      const router: Router = new Router(store, (): GuardState => state('consented', 'ok', 'logged_in'), nav, routes,
        (): LaunchReadiness => ready.current());
      const values: Record<string, Object> = params([['route', 'PushOnly']]);
      store.save(Router.OPEN_ROUTE_ACTION, values, now, 'push');
      router.stateChanged(ready.current(), now);
      expect(router.lastDecision?.toString()).assertEqual('reject - entry_not_allowed');
      expect(store.load(now)).assertNull();
      expect(nav.stack.length).assertEqual(0);
    });

    it('defer_and_unmet_prerequisite_keep_record', 0, () => {
      const h: Harness = new Harness(true);
      h.router.open(req('OrderList', 'in_app'));
      // 环境未就绪：等待类，保留。
      h.box.settled = false;
      h.router.prerequisiteCompleted();
      expect(h.pending() !== null).assertTrue();
      h.box.settled = true;
      // 还未登录：前置未满足，保留。
      h.settle();
      expect(h.pending() !== null).assertTrue();
      h.box.session = 'logged_in';
      h.settle();
      expect(h.nav.top()).assertEqual('OrderList');
      expect(h.pending()).assertNull();
    });

    it('user_consent_flow_kept_only_while_awaiting_dialog', 0, () => {
      const backend: MemoryPendingBackend = new MemoryPendingBackend();
      const h: Harness = new Harness(true, backend);
      h.box.privacy = 'basic_mode';
      h.ready.privacy = PrivacyState.BASIC_MODE;
      h.box.session = 'logged_in';
      h.router.open(req('Wallet', 'in_app'));
      expect(h.nav.consentRequests).assertEqual(1);
      // 弹窗结论未出：自动恢复保留用户主动发起的动作。
      h.settle();
      expect(h.pending() !== null).assertTrue();
      // 进程重启后不再有等待中的弹窗：基本模式下的自动恢复删除记录。
      const r: Harness = new Harness(true, backend);
      r.box.privacy = 'basic_mode';
      r.ready.privacy = PrivacyState.BASIC_MODE;
      r.box.session = 'logged_in';
      r.settle();
      expect(r.pending()).assertNull();
      expect(r.nav.stack.length).assertEqual(0);
    });
  });
}
