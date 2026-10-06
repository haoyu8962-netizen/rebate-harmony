// APP-02c 鸿蒙修复轮（harmony-review-r1 R1-01…R1-03 与 Android 评审同类问题）的时序单测：
// UpdateCheckCoordinator + Router 按 entry 的调用顺序接线（AppPrivacy.publish：写隐私结论 → syncUpdateCheck →
// privacyChanged → consentHandled → stateChanged；AppRouting.stateChanged：syncUpdateCheck → observeReadiness →
// router.stateChanged），检查器用手动应答的替身，复现评审场景。
import { describe, it, expect } from '@ohos/hypium';
import { Routes, RouteSpec } from 'generated';
import {
  EntryGuard,
  GuardDecision,
  GuardDecisionKind,
  GuardReason,
  GuardState,
  LaunchQueue,
  LaunchReadiness,
  MemoryPendingBackend,
  MemoryUpdateStore,
  PendingActionStore,
  PrivacyPromptCover,
  PrivacyState,
  RouteDestination,
  RouteLookup,
  RouteNavigator,
  RouteRequest,
  RouteSource,
  RouteTargetAllowlist,
  Router,
  UpdateCheckCoordinator,
  UpdateCheckOutcome,
  UpdateChecker,
  UpdateCheckResult,
  UpdateGate,
  UpdateGateState,
  UpdateState,
  UpdateStatusRaw,
  UpdateStoreListing
} from '../../Index';

const RELEASE_ROUTES: RouteLookup = (name: string): RouteSpec | undefined => Routes.spec(name);
const INTERVAL_MS: number = 1800 * 1000;

/** 手动应答的检查器：check() 挂起，测试调 respond 才返回。 */
class ManualChecker implements UpdateChecker {
  calls: number = 0;
  private resolvers: ((o: UpdateCheckOutcome) => void)[] = [];

  check(): Promise<UpdateCheckOutcome> {
    this.calls++;
    return new Promise<UpdateCheckOutcome>((resolve: (o: UpdateCheckOutcome) => void) => {
      this.resolvers.push(resolve);
    });
  }

  get outstanding(): number {
    return this.resolvers.length;
  }

  async respond(outcome: UpdateCheckOutcome): Promise<void> {
    const resolve: ((o: UpdateCheckOutcome) => void) | undefined = this.resolvers.shift();
    if (resolve !== undefined) {
      resolve(outcome);
    }
    await flush();
  }
}

async function flush(): Promise<void> {
  for (let i: number = 0; i < 20; i++) {
    await Promise.resolve();
  }
}

function okResult(): UpdateCheckResult {
  return new UpdateCheckResult('1.0.0', null, '1.0.0', 'huawei', [new UpdateStoreListing('huawei', '1.0.0')], 1800);
}

function forceResult(): UpdateCheckResult {
  return new UpdateCheckResult('1.1.0', '1.1.0', '1.3.0', 'huawei', [new UpdateStoreListing('huawei', '1.3.0')], 1800);
}

function promptResult(latest: string): UpdateCheckResult {
  return new UpdateCheckResult('1.0.0', '1.1.0', latest, 'huawei', [new UpdateStoreListing('huawei', latest)], 1800);
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

/** 照 entry 接线：AppUpdate（协调器）+ AppRouting（Router 的状态源与守卫状态）+ AppPrivacy.publish 的顺序。 */
class Harness {
  now: number = 10000000;
  readonly checker: ManualChecker = new ManualChecker();
  readonly updates: MemoryUpdateStore = new MemoryUpdateStore();
  readonly nav: RecordingNavigator = new RecordingNavigator();
  readonly pending: PendingActionStore;
  readonly router: Router;
  readonly coord: UpdateCheckCoordinator;
  privacy: PrivacyState;
  finishedCount: number = 0;

  constructor(privacy: PrivacyState) {
    this.privacy = privacy;
    const gate: UpdateGate = new UpdateGate(this.updates, (): number => this.now, '1.0.0', 'harmony', 'agc', null);
    this.coord = new UpdateCheckCoordinator(gate, this.checker, (): number => this.now);
    this.coord.environmentSettled = (): boolean => true;
    this.coord.privacy = (): PrivacyState => this.privacy;
    this.coord.changed = (notify: boolean): void => {
      if (notify) {
        this.stateChanged();
      }
    };
    this.coord.finished = (_o: UpdateCheckOutcome, _p: boolean): void => {
      this.finishedCount++;
    };
    this.pending = new PendingActionStore(new MemoryPendingBackend(), (): number => this.now);
    this.router = new Router(this.pending, (): GuardState => this.guardState(), this.nav, RELEASE_ROUTES,
      (): LaunchReadiness => this.readiness());
  }

  readiness(): LaunchReadiness {
    return new LaunchReadiness(true, this.privacy, this.coord.routerStatus());
  }

  guardState(fromForceUpdatePage: boolean = false): GuardState {
    const update: UpdateState | null = LaunchQueue.effectiveUpdate(this.coord.routerStatus(), this.now);
    return new GuardState(this.privacy, update ?? this.coord.inAppUpdate(), 'guest', true, '1.0.0', false,
      fromForceUpdatePage, false, RouteTargetAllowlist.EMPTY);
  }

  /** AppRouting.stateChanged。 */
  stateChanged(): void {
    this.coord.syncPrivacy(false);
    const r: LaunchReadiness = this.readiness();
    this.router.observeReadiness(r, this.now);
    this.router.stateChanged(r, this.now);
  }

  /** AppPrivacy.publish（agreed = 用户点了【同意】）。 */
  publish(privacy: PrivacyState, agreed: boolean): void {
    this.privacy = privacy;
    this.coord.syncPrivacy(false);
    this.router.privacyChanged();
    if (agreed) {
      this.router.consentHandled(true);
    }
    this.stateChanged();
  }

  status(): string {
    return this.coord.gate.state(this.now).statusRaw;
  }

  routerResult(): string {
    return String(this.coord.routerStatus().result);
  }

  top(): string {
    return this.nav.stack.length === 0 ? 'Home' : this.nav.stack[this.nav.stack.length - 1];
  }

  hasPending(): boolean {
    return this.pending.load(this.now) !== null;
  }
}

function savePending(h: Harness, route: string): void {
  const p: Record<string, Object> = {};
  p['route'] = route;
  h.pending.save(Router.OPEN_ROUTE_ACTION, p, h.now, RouteSource.DEEPLINK);
}

/** 已同意、冷启动检查成功（ok）的 Harness。 */
async function consentedOk(): Promise<Harness> {
  const h: Harness = new Harness(PrivacyState.CONSENTED);
  h.stateChanged();
  await h.checker.respond(UpdateCheckOutcome.success(okResult()));
  return h;
}

export default function updateCoordinatorTest() {
  describe('UpdateCoordinator', () => {
    // ------------------------------------------------------------ R1-01：同意后先发检查，恢复等结果
    it('r1_01_basic_mode_agent_chat_restored_after_consent_and_ok', 0, async () => {
      const h: Harness = new Harness(PrivacyState.BASIC_MODE);
      h.stateChanged();
      expect(h.checker.calls).assertEqual(0); // 基本模式不发检查
      expect(h.routerResult()).assertEqual('unknown');
      // 基本模式点 AI 助手 → 要先同意，登记待办。
      const tap: GuardDecision = h.router.open(RouteRequest.of('AgentChat', RouteSource.IN_APP));
      expect(tap.kind).assertEqual(GuardDecisionKind.REQUIRE_CONSENT);
      expect(h.hasPending()).assertTrue();
      // 同意：检查在 consentHandled 之前发出，恢复 defer，待办保留（不因同意那一刻的 unknown 被删）。
      h.publish(PrivacyState.CONSENTED, true);
      expect(h.checker.calls).assertEqual(1);
      expect(h.coord.routerStatus().result === null).assertTrue();
      expect(h.hasPending()).assertTrue();
      expect(h.top() === 'AgentChat').assertFalse();
      // 未满 5 秒的状态变化同样不动待办。
      h.now += 4999;
      h.stateChanged();
      expect(h.hasPending()).assertTrue();
      // 检查成功（ok）→ 助手入口恢复，待办执行后删除。
      await h.checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(h.top()).assertEqual('AgentChat');
      expect(h.hasPending()).assertFalse();
    });

    it('r1_01_restore_waits_at_most_5s_then_unknown', 0, async () => {
      const h: Harness = new Harness(PrivacyState.BASIC_MODE);
      h.stateChanged();
      h.router.open(RouteRequest.of('AgentChat', RouteSource.IN_APP));
      h.publish(PrivacyState.CONSENTED, true);
      expect(h.hasPending()).assertTrue();
      // 满 5 秒没结果：按 unknown 判定（AgentChat 不在只读清单 → 拒绝并删除，不补执行）。
      h.now += 5000;
      h.stateChanged();
      expect(h.hasPending()).assertFalse();
      expect(h.top() === 'AgentChat').assertFalse();
      expect(String(h.router.lastDecision?.reason)).assertEqual(GuardReason.UPDATE_UNKNOWN_BLOCKED);
    });

    // ------------------------------------------------------------ R1-02：回前台复查中 Router 拿到 checking
    it('r1_02_foreground_recheck_defers_external_and_pending', 0, async () => {
      const h: Harness = await consentedOk();
      expect(h.routerResult()).assertEqual('ok');
      // 未超过间隔：不查。
      h.now += INTERVAL_MS;
      expect(h.coord.onForeground()).assertFalse();
      // 超过间隔回前台：复查在途。
      h.now += 1;
      expect(h.coord.onForeground()).assertTrue();
      expect(h.checker.calls).assertEqual(2);
      // 界面保留旧投影，但 Router 的状态源是 checking。
      expect(h.status()).assertEqual(UpdateStatusRaw.OK);
      expect(h.coord.routerStatus().result === null).assertTrue();
      // 外部入口（Search 深链）defer update_checking；待办恢复保留。
      const link: GuardDecision = h.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK));
      expect(link.toString()).assertEqual('defer - update_checking');
      savePending(h, 'Search');
      h.router.resumePending();
      h.stateChanged();
      expect(h.hasPending()).assertTrue();
      expect(h.top()).assertEqual('Home');
      // App 内用户操作不等，按本进程已知结论（ok）判定。
      const inApp: GuardDecision = h.router.open(RouteRequest.of('AgentChat', RouteSource.IN_APP));
      expect(inApp.kind + ' ' + String(inApp.route)).assertEqual('open AgentChat');
      // 复查结果回来：排队的深链与待办放行。
      await h.checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(h.top()).assertEqual('Search');
      expect(h.hasPending()).assertFalse();
    });

    it('r1_02_foreground_recheck_known_below_min_stays_forced', 0, async () => {
      const h: Harness = new Harness(PrivacyState.CONSENTED);
      h.stateChanged();
      await h.checker.respond(UpdateCheckOutcome.success(forceResult()));
      h.now += INTERVAL_MS + 1;
      expect(h.coord.onForeground()).assertTrue();
      // 复查在途时已知 below_min 照旧强更（不改成 checking）。
      expect(h.routerResult()).assertEqual('below_min');
      expect(h.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK)).kind)
        .assertEqual(GuardDecisionKind.FORCE_UPDATE);
    });

    // ------------------------------------------------------------ R1-03：离开基本模式立即补发检查
    it('r1_03_reconsent_after_basic_mode_checks_again', 0, async () => {
      const h: Harness = await consentedOk();
      expect(h.checker.calls).assertEqual(1);
      // 撤回同意 → 基本模式：旧 ok 不再作数，按 unknown（不等待），基本模式不发检查。
      h.publish(PrivacyState.BASIC_MODE, false);
      expect(h.status()).assertEqual(UpdateStatusRaw.UNKNOWN);
      expect(h.routerResult()).assertEqual('unknown');
      h.now += INTERVAL_MS + 1;
      expect(h.coord.onForeground()).assertFalse();
      expect(h.checker.calls).assertEqual(1);
      // 重新同意：立即补发检查，Router 读到 checking（不再用旧 ok）。
      h.publish(PrivacyState.CONSENTED, true);
      expect(h.checker.calls).assertEqual(2);
      expect(h.coord.routerStatus().result === null).assertTrue();
      expect(h.status()).assertEqual(UpdateStatusRaw.CHECKING);
      await h.checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(h.routerResult()).assertEqual('ok');
      // 未超过间隔也一样：每次离开基本模式都查。
      h.publish(PrivacyState.BASIC_MODE, false);
      h.publish(PrivacyState.CONSENTED, true);
      expect(h.checker.calls).assertEqual(3);
      // 重新同意后检查失败：unknown，不恢复旧 ok。
      await h.checker.respond(UpdateCheckOutcome.failure());
      expect(h.routerResult()).assertEqual('unknown');
    });

    it('r1_03_basic_mode_keeps_known_below_min', 0, async () => {
      const h: Harness = new Harness(PrivacyState.CONSENTED);
      h.stateChanged();
      await h.checker.respond(UpdateCheckOutcome.success(forceResult()));
      h.publish(PrivacyState.BASIC_MODE, false);
      expect(h.routerResult()).assertEqual('below_min');
      h.publish(PrivacyState.CONSENTED, true);
      expect(h.checker.calls).assertEqual(2);
      expect(h.routerResult()).assertEqual('below_min');
    });

    it('r1_03_result_arriving_in_basic_mode_does_not_restore_ok', 0, async () => {
      const h: Harness = new Harness(PrivacyState.CONSENTED);
      h.stateChanged();
      // 检查在途时撤回同意，结果在基本模式里回来：仍按 unknown；重新同意再查。
      h.publish(PrivacyState.BASIC_MODE, false);
      await h.checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(h.routerResult()).assertEqual('unknown');
      h.publish(PrivacyState.CONSENTED, true);
      expect(h.checker.calls).assertEqual(2);
    });

    // ------------------------------------------------------------ R2-01：复查失败后 Router 按 unknown
    it('r2_01_recheck_failure_after_ok_routes_as_unknown_until_next_success', 0, async () => {
      const h: Harness = await consentedOk();
      h.now += INTERVAL_MS + 1;
      expect(h.coord.onForeground()).assertTrue();
      // 复查在途：前置（如登录）完成后待办等检查结果——这里直接登记待办并恢复来模拟。
      savePending(h, 'AgentChat');
      h.router.resumePending();
      h.stateChanged();
      expect(h.hasPending()).assertTrue();
      // 复查失败：Gate 界面状态保留旧 ok（向量 G14），但 Router 的状态源是 unknown。
      await h.checker.respond(UpdateCheckOutcome.failure());
      expect(h.status()).assertEqual(UpdateStatusRaw.OK);
      expect(h.routerResult()).assertEqual('unknown');
      // 待办恢复受未知限制：AgentChat 不在只读清单 → 拒绝并删除，不自动打开。
      expect(h.hasPending()).assertFalse();
      expect(h.top() === 'AgentChat').assertFalse();
      expect(String(h.router.lastDecision?.reason)).assertEqual(GuardReason.UPDATE_UNKNOWN_BLOCKED);
      // 外部入口只读：Search 深链 open_readonly（不是 open）。
      const link: GuardDecision = h.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK));
      expect(link.kind).assertEqual(GuardDecisionKind.OPEN_READONLY);
      // 失败后再遇到状态变化也不借用旧 ok。
      h.now += 60000;
      h.stateChanged();
      expect(h.routerResult()).assertEqual('unknown');
      // App 内用户自己的操作不拦（03 §4.1）：仍按本进程已知结论。
      expect(String(h.coord.inAppUpdate())).assertEqual('ok');
      const inApp: GuardDecision = h.router.open(RouteRequest.of('AgentChat', RouteSource.IN_APP));
      expect(inApp.kind + ' ' + String(inApp.route)).assertEqual('open AgentChat');
      // 下一次成功检查后恢复正常：深链正常打开。
      h.now += INTERVAL_MS + 1;
      expect(h.coord.onForeground()).assertTrue();
      await h.checker.respond(UpdateCheckOutcome.success(okResult()));
      expect(h.routerResult()).assertEqual('ok');
      const again: GuardDecision = h.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK));
      expect(again.kind + ' ' + String(again.route)).assertEqual('open Search');
    });

    it('r2_01_recheck_failure_keeps_known_below_min', 0, async () => {
      const h: Harness = new Harness(PrivacyState.CONSENTED);
      h.stateChanged();
      await h.checker.respond(UpdateCheckOutcome.success(forceResult()));
      h.now += INTERVAL_MS + 1;
      expect(h.coord.onForeground()).assertTrue();
      await h.checker.respond(UpdateCheckOutcome.failure());
      // 已知 below_min 不降级为 unknown，照旧强更。
      expect(h.routerResult()).assertEqual('below_min');
      expect(h.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK)).kind)
        .assertEqual(GuardDecisionKind.FORCE_UPDATE);
    });

    it('r2_01_recheck_failure_after_below_recommended_routes_as_unknown', 0, async () => {
      const h: Harness = new Harness(PrivacyState.CONSENTED);
      h.stateChanged();
      await h.checker.respond(UpdateCheckOutcome.success(promptResult('1.2.0')));
      expect(h.routerResult()).assertEqual('below_recommended');
      h.now += INTERVAL_MS + 1;
      h.coord.onForeground();
      await h.checker.respond(UpdateCheckOutcome.failure());
      expect(h.status()).assertEqual(UpdateStatusRaw.BELOW_RECOMMENDED);
      expect(h.routerResult()).assertEqual('unknown');
      // 失败后的【重试】在途仍报 checking，成功后恢复。
      expect(h.coord.recheck(false)).assertTrue();
      expect(h.coord.routerStatus().result === null).assertTrue();
      await h.checker.respond(UpdateCheckOutcome.success(promptResult('1.2.0')));
      expect(h.routerResult()).assertEqual('below_recommended');
    });

    // ------------------------------------------------------------ R2-02：强更页上的隐私弹窗经协议页返回后恢复
    it('r2_02_force_update_basic_mode_consent_agreement_back_then_restricted_login', 0, async () => {
      const h: Harness = new Harness(PrivacyState.BASIC_MODE);
      h.stateChanged();
      h.coord.gate.on10405('1.1.0', h.now);
      h.stateChanged();
      // 命中 below_min：任何页面进入强更页（AppRouting.syncForceUpdatePage 同口径）。
      h.router.open(RouteRequest.of('Search', RouteSource.IN_APP));
      expect(h.nav.stack.join(',')).assertEqual('ForceUpdate');
      // 强更页「注销账号」（游客 → 受限登录）：基本模式先补同意，弹窗盖在强更页上。
      const tap: GuardDecision = h.router.openWith(RouteRequest.of('Login', RouteSource.IN_APP), h.guardState(true));
      expect(tap.kind).assertEqual(GuardDecisionKind.REQUIRE_CONSENT);
      expect(h.nav.consentRequests).assertEqual(1);
      // 弹窗里点协议链接（AppPrivacy.openAgreement：按强更页来源打开，记下宿主页栈深）。
      const cover: PrivacyPromptCover = new PrivacyPromptCover();
      const hostDepth: number = h.nav.stack.length;
      const params: Record<string, Object> = {};
      params['type'] = 'privacy';
      const link: GuardDecision =
        h.router.openWith(RouteRequest.of('Agreement', RouteSource.IN_APP, params), h.guardState(true));
      expect(link.kind + ' ' + String(link.route)).assertEqual('open Agreement');
      cover.cover(hostDepth, 'Agreement');
      expect(cover.shown(h.nav.stack)).assertFalse(); // 协议页显示：弹窗让出
      expect(cover.covered).assertTrue();
      // 返回强更页（目标是 NavDestination，不是导航根）：弹窗恢复。
      h.nav.stack.pop();
      expect(h.nav.stack.join(',')).assertEqual('ForceUpdate');
      expect(cover.shown(h.nav.stack)).assertTrue();
      expect(cover.covered).assertFalse();
      // 同意：仍是强更（已知 below_min），从强更页进入受限登录。
      h.publish(PrivacyState.CONSENTED, true);
      await h.checker.respond(UpdateCheckOutcome.failure());
      expect(h.routerResult()).assertEqual('below_min');
      const login: GuardDecision = h.router.openWith(RouteRequest.of('Login', RouteSource.IN_APP), h.guardState(true));
      expect(login.kind + ' ' + String(login.route)).assertEqual('open Login');
      expect(h.top()).assertEqual('Login');
    });

    it('r2_02_prompt_cover_rules', 0, () => {
      const cover: PrivacyPromptCover = new PrivacyPromptCover();
      expect(cover.shown([])).assertFalse(); // 没盖住时无事发生
      // 导航根上打开协议：返回根恢复。
      cover.cover(0, 'Agreement');
      expect(cover.shown(['Agreement'])).assertFalse();
      expect(cover.shown(['Agreement', 'WebPage'])).assertFalse(); // 协议页之上再压页面：保持让出
      expect(cover.shown(['Agreement'])).assertFalse();
      expect(cover.shown([])).assertTrue();
      // 栈被重建（命中 below_min 只留强更页）：协议页已离开，恢复。
      cover.cover(0, 'Agreement');
      expect(cover.shown(['ForceUpdate'])).assertTrue();
      // 强更页上打开协议，返回强更页恢复；返回更低同样恢复。
      cover.cover(1, 'Agreement');
      expect(cover.shown(['ForceUpdate', 'Agreement'])).assertFalse();
      expect(cover.shown(['ForceUpdate'])).assertTrue();
      cover.cover(1, 'Agreement');
      expect(cover.shown([])).assertTrue();
      // reset（隐私有了结论）。
      cover.cover(1, 'Agreement');
      cover.reset();
      expect(cover.covered).assertFalse();
    });

    // ------------------------------------------------------------ Android 评审同类问题
    it('agreement_link_over_force_update_page_opens', 0, () => {
      // 强更页上叠隐私弹窗（未决 / 基本模式补同意）：弹窗里的协议链接按强更页来源判定才能打开（F-ALL-06）。
      for (const privacy of [PrivacyState.NOT_DECIDED, PrivacyState.BASIC_MODE]) {
        const h: Harness = new Harness(privacy);
        h.coord.gate.on10405('1.1.0', h.now);
        const params: Record<string, Object> = {};
        params['type'] = 'privacy';
        const request: RouteRequest = RouteRequest.of('Agreement', RouteSource.IN_APP, params);
        expect(EntryGuard.decide(request, h.guardState(false), RELEASE_ROUTES).kind)
          .assertEqual(GuardDecisionKind.FORCE_UPDATE);
        const d: GuardDecision = EntryGuard.decide(request, h.guardState(true), RELEASE_ROUTES);
        expect(d.kind + ' ' + String(d.route)).assertEqual('open Agreement');
        // 标记不放行强更次要入口以外的路由（未决时先按隐私等待，基本模式回强更页；都不打开）。
        const other: GuardDecision =
          EntryGuard.decide(RouteRequest.of('Search', RouteSource.IN_APP), h.guardState(true), RELEASE_ROUTES);
        expect(other.kind).assertEqual(privacy === PrivacyState.NOT_DECIDED ? GuardDecisionKind.DEFER
          : GuardDecisionKind.FORCE_UPDATE);
      }
    });

    it('force_update_retry_without_any_success_does_not_loop', 0, async () => {
      // 只有 10405、从未成功检查：【重试】只发一次检查，失败后停下等用户再点，不自动重试。
      const h: Harness = new Harness(PrivacyState.CONSENTED);
      h.stateChanged();
      h.coord.gate.on10405('1.1.0', h.now);
      await h.checker.respond(UpdateCheckOutcome.failure());
      expect(h.checker.calls).assertEqual(1);
      expect(h.routerResult()).assertEqual('below_min');
      expect(h.coord.recheck(true)).assertTrue();
      expect(h.coord.recheck(true)).assertFalse(); // 在途时不重复发
      await h.checker.respond(UpdateCheckOutcome.failure());
      await flush();
      expect(h.checker.calls).assertEqual(2);
      expect(h.checker.outstanding).assertEqual(0);
      expect(h.finishedCount).assertEqual(2);
      expect(h.routerResult()).assertEqual('below_min');
    });

    it('dismissed_prompt_reappears_for_higher_latest_in_same_process', 0, async () => {
      const h: Harness = new Harness(PrivacyState.CONSENTED);
      h.stateChanged();
      await h.checker.respond(UpdateCheckOutcome.success(promptResult('1.2.0')));
      expect(h.coord.gate.state(h.now).showPrompt).assertTrue();
      h.coord.gate.dismissPrompt(h.now);
      expect(h.coord.gate.state(h.now).showPrompt).assertFalse();
      // 同一 latest：复查后仍不提示。
      h.now += INTERVAL_MS + 1;
      h.coord.onForeground();
      await h.checker.respond(UpdateCheckOutcome.success(promptResult('1.2.0')));
      expect(h.coord.gate.state(h.now).showPrompt).assertFalse();
      // 同进程出现更高 latest：再提示。
      h.now += INTERVAL_MS + 1;
      h.coord.onForeground();
      await h.checker.respond(UpdateCheckOutcome.success(promptResult('1.3.0')));
      const s: UpdateGateState = h.coord.gate.state(h.now);
      expect(s.statusRaw + ' ' + String(s.showPrompt) + ' ' + String(s.targetVersion))
        .assertEqual('below_recommended true 1.3.0');
    });
  });
}
