// UpdateGate 向量之外的行为单测（APP-02c）：三端统一裁定 G15（升级后按新 appVersion 重比）、调试假结果与 Release 分开存储、
// 落盘编解码、契约示例适配、Gate → Router 状态源接线（检查中外部来源 defer update_checking、App 内操作不等、below_min 进强更页
// 并删待办、基本模式不清掉强更页、强更页次要入口只放行 PrivacyCenter / Agreement / Login）。
import { describe, it, expect } from '@ohos/hypium';
import { Routes, RouteSpec } from 'generated';
import {
  CouliPreferences,
  GuardDecision,
  GuardDecisionKind,
  GuardReason,
  GuardState,
  LaunchQueue,
  LaunchReadiness,
  MemoryPendingBackend,
  MemoryUpdateStore,
  PendingActionStore,
  PreferencesUpdateStore,
  PrivacyState,
  RouteDestination,
  RouteLookup,
  RouteNavigator,
  RouteRequest,
  RouteSource,
  RouteTargetAllowlist,
  Router,
  UpdateCheckAdapter,
  UpdateCheckResult,
  UpdateCheckStatus,
  UpdateGate,
  UpdateGateState,
  UpdatePersisted,
  UpdateRouting,
  UpdateState,
  UpdateStatusRaw,
  UpdateStoreListing
} from '../../Index';

const RELEASE_ROUTES: RouteLookup = (name: string): RouteSpec | undefined => Routes.spec(name);

class Clock {
  now: number = 1000;
}

function gate(store: MemoryUpdateStore, clock: Clock, appVersion: string): UpdateGate {
  return new UpdateGate(store, (): number => clock.now, appVersion, 'harmony', 'agc', null);
}

function forceResult(min: string): UpdateCheckResult {
  return new UpdateCheckResult(min, '1.2.0', '1.3.0', 'huawei',
    [new UpdateStoreListing('huawei', '1.3.0')], 1800);
}

/** 冷启动重建 Gate（换成 appVersion），本次检查失败后的结论。 */
function coldFailure(store: MemoryUpdateStore, clock: Clock, appVersion: string): string {
  const g: UpdateGate = gate(store, clock, appVersion);
  g.onColdStart(clock.now);
  g.applyFailure(clock.now + 1);
  return g.state(clock.now + 1).statusRaw;
}

class RecordingNavigator implements RouteNavigator {
  stack: string[] = [];
  consentRequests: number = 0;

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
    this.consentRequests++;
  }
}

/** 照 entry 的 AppRouting 接线：Router 的放行条件与守卫状态都从 UpdateGate 来。 */
class Wiring {
  readonly clock: Clock = new Clock();
  readonly updates: MemoryUpdateStore = new MemoryUpdateStore();
  readonly nav: RecordingNavigator = new RecordingNavigator();
  readonly pending: PendingActionStore;
  readonly router: Router;
  privacy: PrivacyState = PrivacyState.CONSENTED;
  g: UpdateGate;
  checkStartedAt: number = 0;
  fromForceUpdatePage: boolean = false;

  constructor(appVersion: string = '1.0.0') {
    this.clock.now = 1000000;
    this.g = gate(this.updates, this.clock, appVersion);
    this.pending = new PendingActionStore(new MemoryPendingBackend(), (): number => this.clock.now);
    this.router = new Router(this.pending, (): GuardState => this.guardState(), this.nav, RELEASE_ROUTES,
      (): LaunchReadiness => this.readiness());
  }

  status(): UpdateCheckStatus {
    return UpdateRouting.status(this.g.state(this.clock.now), this.checkStartedAt);
  }

  readiness(): LaunchReadiness {
    return new LaunchReadiness(true, this.privacy, this.status());
  }

  /** AppRouting.guardState：检查中对 App 内操作按 unknown（外部来源由 Router 的等待协调器先等）。 */
  guardState(): GuardState {
    const update: UpdateState | null = LaunchQueue.effectiveUpdate(this.status(), this.clock.now);
    return new GuardState(this.privacy, update ?? UpdateState.UNKNOWN, 'guest', true, '1.0.0', false,
      this.fromForceUpdatePage, false, RouteTargetAllowlist.EMPTY);
  }

  coldStart(): void {
    this.checkStartedAt = this.clock.now;
    this.g.onColdStart(this.clock.now);
  }

  settle(): void {
    this.router.stateChanged(this.readiness(), this.clock.now);
  }

  top(): string {
    return this.nav.stack.length === 0 ? 'Home' : this.nav.stack[this.nav.stack.length - 1];
  }
}

function savePending(w: Wiring, route: string): void {
  const p: Record<string, Object> = {};
  p['route'] = route;
  w.pending.save(Router.OPEN_ROUTE_ACTION, p, w.clock.now, RouteSource.DEEPLINK);
}

export default function updateBehaviorTest() {
  describe('UpdateBehavior', () => {
    // ------------------------------------------------------------ G15：本机版本升级后按新 appVersion 与缓存 min 重比
    it('g15_cached_below_min_rechecked_after_upgrade', 0, () => {
      for (const v of ['1.1.0', '1.2.0', '1.0.9']) {
        const store: MemoryUpdateStore = new MemoryUpdateStore();
        const clock: Clock = new Clock();
        const old: UpdateGate = gate(store, clock, '1.0.0');
        old.apply(forceResult('1.1.0'), clock.now);
        expect(old.state(clock.now).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
        clock.now = 2000;
        const rebuilt: UpdateGate = gate(store, clock, v);
        expect(rebuilt.onColdStart(clock.now)).assertTrue();
        // 升级到等于或高于缓存 min：已知强更不再成立，冷启动按检查中、失败按 unknown；仍低于则 below_min。
        const stillBelow: boolean = v === '1.0.9';
        expect(rebuilt.state(clock.now).statusRaw)
          .assertEqual(stillBelow ? UpdateStatusRaw.BELOW_MIN : UpdateStatusRaw.CHECKING);
        rebuilt.applyFailure(clock.now + 1);
        expect(rebuilt.state(clock.now + 1).statusRaw)
          .assertEqual(stillBelow ? UpdateStatusRaw.BELOW_MIN : UpdateStatusRaw.UNKNOWN);
      }
    });

    it('g15_10405_with_min_rechecked_after_upgrade', 0, () => {
      const results: string[] = [];
      for (const v of ['1.0.0', '1.0.9', '1.1.0', '2.0.0']) {
        const store: MemoryUpdateStore = new MemoryUpdateStore();
        const clock: Clock = new Clock();
        gate(store, clock, '1.0.0').on10405('1.1.0', clock.now);
        results.push(v + '=' + coldFailure(store, clock, v));
      }
      expect(results.join(',')).assertEqual('1.0.0=below_min,1.0.9=below_min,1.1.0=unknown,2.0.0=unknown');
    });

    it('g15_10405_without_min_only_binds_same_app_version', 0, () => {
      const store: MemoryUpdateStore = new MemoryUpdateStore();
      const clock: Clock = new Clock();
      const g: UpdateGate = gate(store, clock, '1.0.0');
      g.on10405(null, clock.now);
      const s: UpdateGateState = g.state(clock.now);
      expect(s.statusRaw + ' ' + String(s.targetVersion)).assertEqual('below_min null');
      expect(coldFailure(store, clock, '1.0.0')).assertEqual(UpdateStatusRaw.BELOW_MIN);
      expect(coldFailure(store, clock, '1.0.1')).assertEqual(UpdateStatusRaw.UNKNOWN);
    });

    it('10405_ignored_when_app_not_below_its_min', 0, () => {
      const store: MemoryUpdateStore = new MemoryUpdateStore();
      const clock: Clock = new Clock();
      const g: UpdateGate = gate(store, clock, '1.2.0');
      g.on10405('1.1.0', clock.now);
      g.on10405('1.2.0', clock.now);
      expect(store.load().forcedBy10405).assertFalse();
      expect(g.state(clock.now).statusRaw).assertEqual(UpdateStatusRaw.UNKNOWN);
    });

    it('success_after_upgrade_clears_10405', 0, () => {
      const store: MemoryUpdateStore = new MemoryUpdateStore();
      const clock: Clock = new Clock();
      const g: UpdateGate = gate(store, clock, '1.0.0');
      g.on10405('1.1.0', clock.now);
      g.apply(new UpdateCheckResult('1.0.0', null, '1.3.0', 'huawei', [], 1800), clock.now + 1);
      expect(g.state(clock.now + 1).statusRaw).assertEqual(UpdateStatusRaw.OK);
      expect(store.load().forcedBy10405).assertFalse();
    });

    it('invalid_app_version_is_unknown', 0, () => {
      const store: MemoryUpdateStore = new MemoryUpdateStore();
      const clock: Clock = new Clock();
      const g: UpdateGate = gate(store, clock, '1.0.0-beta');
      g.apply(forceResult('1.1.0'), clock.now);
      expect(g.state(clock.now).statusRaw).assertEqual(UpdateStatusRaw.UNKNOWN);
      expect(UpdateGate.compareOrNull('1..0', '1.0')).assertNull();
    });

    // ------------------------------------------------------------ 存储
    it('debug_fake_results_use_separate_namespace', 0, () => {
      // 三端统一裁定：调试假结果不写进 Release 读取的同一存储；两者都随环境切换清理，都不在保留名单里。
      expect(CouliPreferences.UPDATE_DEBUG_NAMESPACE === CouliPreferences.UPDATE_NAMESPACE).assertFalse();
      expect(CouliPreferences.ALL_NAMESPACES.indexOf(CouliPreferences.UPDATE_NAMESPACE) >= 0).assertTrue();
      expect(CouliPreferences.ALL_NAMESPACES.indexOf(CouliPreferences.UPDATE_DEBUG_NAMESPACE) >= 0).assertTrue();
      expect(CouliPreferences.PRESERVED_NAMESPACES.indexOf(CouliPreferences.UPDATE_NAMESPACE)).assertEqual(-1);
    });

    it('preferences_store_round_trip', 0, () => {
      const value: UpdatePersisted = new UpdatePersisted();
      value.result = new UpdateCheckResult('1.1.0', null, '1.3.0', 'huawei',
        [new UpdateStoreListing('huawei', '1.3.0'), new UpdateStoreListing('xiaomi', '1.1.0')], 600, '新版本', null);
      value.lastSuccessAtMillis = 42;
      value.forcedBy10405 = true;
      value.forcedMinimum = '1.2.0';
      value.forcedAppVersion = '1.0.0';
      value.dismissedLatest = '1.3.0';
      const back: UpdatePersisted = PreferencesUpdateStore.decode(PreferencesUpdateStore.encode(value));
      expect(PreferencesUpdateStore.encode(back)).assertEqual(PreferencesUpdateStore.encode(value));
      const empty: UpdatePersisted = PreferencesUpdateStore.decode(PreferencesUpdateStore.encode(new UpdatePersisted()));
      expect(empty.result === null && empty.lastSuccessAtMillis === null && !empty.forcedBy10405).assertTrue();
    });

    it('adapter_drops_null_listings_and_keeps_order', 0, () => {
      const r: UpdateCheckResult | null = UpdateCheckAdapter.fromJson(
        '{"latest_version":"1.2.0","min_supported_version":null,"recommended_version":"1.1.0","update_title":"t",' +
          '"update_notes":"n","store_url":"https://x.invalid/a","default_store":"huawei","stores":[' +
          '{"store":"xiaomi","listed_version":"1.2.0"},{"store":"huawei","listed_version":null},' +
          '{"store":"oppo","listed_version":"1.1.0"}]}');
      expect(r === null).assertFalse();
      const result: UpdateCheckResult = r as UpdateCheckResult;
      expect(result.stores.map((s: UpdateStoreListing) => s.store + ':' + s.version).join(','))
        .assertEqual('xiaomi:1.2.0,oppo:1.1.0');
      expect(String(result.minSupported) + ' ' + result.defaultStore + ' ' + result.recheckIntervalSec)
        .assertEqual('null huawei 1800');
      expect(UpdateCheckAdapter.fromJson('not json')).assertNull();
    });

    // ------------------------------------------------------------ Gate → Router 接线
    it('routing_status_mapping', 0, () => {
      const checking: UpdateCheckStatus =
        UpdateRouting.status(new UpdateGateState(UpdateStatusRaw.CHECKING, false, null), 77);
      expect(checking.result === null && checking.startedAt === 77).assertTrue();
      const raws: string[] = [UpdateStatusRaw.OK, UpdateStatusRaw.BELOW_RECOMMENDED, UpdateStatusRaw.BELOW_MIN,
        UpdateStatusRaw.UNKNOWN];
      const mapped: string[] = raws.map((raw: string) =>
        String(UpdateRouting.status(new UpdateGateState(raw, false, null), 0).result));
      expect(mapped.join(',')).assertEqual('ok,below_recommended,below_min,unknown');
    });

    it('checking_defers_external_and_pending_but_not_in_app', 0, () => {
      const w: Wiring = new Wiring();
      w.coldStart();
      savePending(w, 'Search');
      // 外部来源（深链）：defer update_checking，排队等结果。
      const link: GuardDecision = w.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK));
      expect(link.toString()).assertEqual('defer - update_checking');
      // pending 恢复：检查中不动记录。
      w.router.resumePending();
      expect(w.pending.load(w.clock.now) === null).assertFalse();
      w.settle();
      expect(w.pending.load(w.clock.now) === null).assertFalse();
      // App 内操作不等：直接判定、打开（不 defer、不排队）。
      const inApp: GuardDecision = w.router.open(RouteRequest.of('Search', RouteSource.IN_APP));
      expect(inApp.kind + ' ' + String(inApp.route)).assertEqual('open Search');
      // 不在只读清单的 App 内操作按 unknown 拒绝，同样不等。
      const blocked: GuardDecision = w.router.open(RouteRequest.of('AgentChat', RouteSource.IN_APP));
      expect(blocked.kind === GuardDecisionKind.DEFER).assertFalse();
      // 检查结果 ok：排队的深链放行，待办恢复后删除。
      w.g.apply(new UpdateCheckResult('1.0.0', '1.0.0', '1.2.0', 'huawei', [], 1800), w.clock.now);
      w.settle();
      expect(w.pending.load(w.clock.now)).assertNull();
      expect(w.top()).assertEqual('Search');
    });

    it('below_min_enters_force_update_and_drops_pending', 0, () => {
      const w: Wiring = new Wiring();
      w.coldStart();
      savePending(w, 'Search');
      w.g.apply(forceResult('1.1.0'), w.clock.now);
      w.settle();
      expect(w.pending.load(w.clock.now)).assertNull();
      expect(w.nav.stack.join(',')).assertEqual('ForceUpdate');
      // 任何页面的 App 内打开（含 Tab 根、Home）都回强更页。
      const d: GuardDecision = w.router.open(RouteRequest.of('OrderList', RouteSource.IN_APP));
      expect(d.reason).assertEqual(GuardReason.FORCE_UPDATE_REQUIRED);
      expect(w.nav.stack.join(',')).assertEqual('ForceUpdate');
    });

    it('basic_mode_keeps_force_update_page', 0, () => {
      // 冷启动缓存 below_min + 隐私「仍不同意」进入基本模式：外壳经 Router 重开 Home，结论仍是强更页（不清掉强更页）。
      const w: Wiring = new Wiring();
      w.g.apply(forceResult('1.1.0'), w.clock.now);
      w.g = gate(w.updates, w.clock, '1.0.0');
      w.privacy = PrivacyState.BASIC_MODE;
      // 基本模式不发检查：已知 below_min 照旧，不等待。
      expect(w.status().result).assertEqual(UpdateState.BELOW_MIN);
      const home: GuardDecision = w.router.open(RouteRequest.of('Home', RouteSource.IN_APP));
      expect(home.kind).assertEqual(GuardDecisionKind.FORCE_UPDATE);
      expect(w.nav.stack.join(',')).assertEqual('ForceUpdate');
      // 基本模式没有已知强更：直接按 unknown，不等待（03 §4.4）。
      const fresh: Wiring = new Wiring();
      fresh.privacy = PrivacyState.BASIC_MODE;
      expect(fresh.status().result).assertEqual(UpdateState.UNKNOWN);
      expect(fresh.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK)).reason === GuardReason.UPDATE_CHECKING)
        .assertFalse();
    });

    it('force_update_secondary_entries', 0, () => {
      const w: Wiring = new Wiring();
      w.g.apply(forceResult('1.1.0'), w.clock.now);
      w.router.open(RouteRequest.of('Home', RouteSource.IN_APP));
      // 不是从强更页发起：一律回强更页。
      expect(w.router.open(RouteRequest.of('PrivacyCenter', RouteSource.IN_APP)).kind)
        .assertEqual(GuardDecisionKind.FORCE_UPDATE);
      w.fromForceUpdatePage = true;
      const opened: string[] = [];
      for (const route of ['PrivacyCenter', 'Login', 'Agreement', 'Settings']) {
        w.router.open(RouteRequest.of('Home', RouteSource.IN_APP));
        const d: GuardDecision = w.router.open(RouteRequest.of(route, RouteSource.IN_APP));
        opened.push(route + ':' + d.kind);
      }
      expect(opened.join(',')).assertEqual('PrivacyCenter:open,Login:open,Agreement:open,Settings:force_update');
      // 强更页之上只压次要入口页；返回后回到强更页。
      w.router.open(RouteRequest.of('Login', RouteSource.IN_APP));
      expect(w.nav.stack.join(',')).assertEqual('ForceUpdate,Login');
      // 外部来源即使带着强更页标记也不放行。
      expect(w.router.open(RouteRequest.of('Agreement', RouteSource.DEEPLINK)).kind)
        .assertEqual(GuardDecisionKind.FORCE_UPDATE);
    });

    // F-ALL-06（APP-03b 核对）：强更页上叠着隐私重新同意弹窗（隐私未决）时，弹窗里的协议链接带强更来源标记
    // （AppPrivacy.openAgreement 在 below_min 时走 AppRouting.openFromForceUpdatePage），协议页能打开；不带标记则回强更页。
    it('f_all_06_agreement_from_privacy_prompt_over_force_update', 0, () => {
      const w: Wiring = new Wiring();
      w.g.apply(forceResult('1.1.0'), w.clock.now);
      w.privacy = PrivacyState.NOT_DECIDED;
      w.router.open(RouteRequest.of('Home', RouteSource.IN_APP));
      // 不带标记：协议页打不开（F-ALL-06 原问题）。
      const unmarked: GuardDecision = w.router.open(RouteRequest.of('Agreement', RouteSource.IN_APP));
      expect(unmarked.kind === GuardDecisionKind.OPEN || unmarked.kind === GuardDecisionKind.OPEN_READONLY).assertFalse();
      w.fromForceUpdatePage = true;
      const decision: GuardDecision = w.router.open(RouteRequest.of('Agreement', RouteSource.IN_APP));
      expect(decision.kind === GuardDecisionKind.OPEN || decision.kind === GuardDecisionKind.OPEN_READONLY).assertTrue();
      expect(decision.route).assertEqual('Agreement');
      // 标记只放行强更页的次要入口：别的路由仍打不开。
      const search: GuardDecision = w.router.open(RouteRequest.of('Search', RouteSource.IN_APP));
      expect(search.kind === GuardDecisionKind.OPEN || search.kind === GuardDecisionKind.OPEN_READONLY).assertFalse();
    });
  });
}
