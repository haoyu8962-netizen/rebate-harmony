// 隐私闸门的接线单测（APP-02b，向量之外）：命名空间清理边界、撤回只跑凭据清理项、Router.privacyChanged、
// 冷启动与闸门变化后按真实 PrivacyGate 的结论恢复 pending_action、撤回后再同意的初始化周期、退避间隔；
// 撤回两阶段写入的故障注入（R1-01）、同意恢复与冷启动推送等 Navigation / Tab 就绪（R1-02 / R1-03）。
import { describe, it, expect } from '@ohos/hypium';
import { Routes, RouteSpec } from 'generated';
import {
  CleanReport,
  EntryGuard,
  GuardDecision,
  GuardDecisionKind,
  GuardReason,
  RouteRequest,
  CouliPreferences,
  GuardState,
  LaunchReadiness,
  LocalDataCleaner,
  LocalDataCleanerRegistry,
  MemoryPendingBackend,
  MemoryPrivacyStore,
  parsePrivacyState,
  PendingAction,
  PendingActionStore,
  PreferencesNamespaceCleaner,
  PrivacyDecision,
  PrivacyGate,
  PrivacyGateState,
  PrivacyInitSteps,
  PrivacyPromptStage,
  PrivacyState,
  PrivacyStore,
  PrivacyWithdrawalCleaners,
  PushLanding,
  PushLookupResult,
  RetryScheduler,
  RouteDestination,
  RouteLookup,
  RouteNavigator,
  Router,
  RouteSource,
  UpdateCheckStatus,
  UpdateState
} from '../../Index';

class SpyCleaner implements LocalDataCleaner {
  readonly name: string;
  calls: number = 0;

  constructor(name: string) {
    this.name = name;
  }

  clean(): Promise<void> {
    this.calls++;
    return Promise.resolve();
  }
}

class NavSpy implements RouteNavigator {
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

class NoopScheduler implements RetryScheduler {
  delays: number[] = [];
  actions: (() => void)[] = [];

  schedule(delayMillis: number, action: () => void): void {
    this.delays.push(delayMillis);
    this.actions.push(action);
  }
}

/** 模拟磁盘：决定记录与撤回意图是两个独立文件；进程重启 = 用同一个磁盘新建存储与 Gate（内存全丢）。 */
class SimDisk {
  decisionRaw: string = PrivacyDecision.NOT_DECIDED;
  consentedVersion: string | null = null;
  consentedAtMillis: number | null = null;
  basicMode: boolean = false;
  withdrawalCleanupPending: boolean = false;
  withdrawalIntent: boolean = false;
  /** 故障注入：决定记录 / 撤回意图的写入（含 flush）失败。 */
  failRecord: boolean = false;
  failIntent: boolean = false;
  recordWrites: number = 0;
  intentWrites: number = 0;

  static consented(version: string): SimDisk {
    const d: SimDisk = new SimDisk();
    d.decisionRaw = PrivacyDecision.CONSENTED;
    d.consentedVersion = version;
    d.consentedAtMillis = 1;
    return d;
  }
}

/** 读写 SimDisk 的存储：字段是内存副本，persist 失败时磁盘保持旧值。 */
class SimDiskStore implements PrivacyStore {
  decisionRaw: string;
  consentedVersion: string | null;
  consentedAtMillis: number | null;
  basicMode: boolean;
  withdrawalCleanupPending: boolean;
  withdrawalIntent: boolean;
  private readonly disk: SimDisk;

  constructor(disk: SimDisk) {
    this.disk = disk;
    this.decisionRaw = disk.decisionRaw;
    this.consentedVersion = disk.consentedVersion;
    this.consentedAtMillis = disk.consentedAtMillis;
    this.basicMode = disk.basicMode;
    this.withdrawalCleanupPending = disk.withdrawalCleanupPending;
    this.withdrawalIntent = disk.withdrawalIntent;
  }

  persist(): void {
    if (this.disk.failRecord) {
      throw new Error('flush failed');
    }
    this.disk.recordWrites++;
    this.disk.decisionRaw = this.decisionRaw;
    this.disk.consentedVersion = this.consentedVersion;
    this.disk.consentedAtMillis = this.consentedAtMillis;
    this.disk.basicMode = this.basicMode;
    this.disk.withdrawalCleanupPending = this.withdrawalCleanupPending;
  }

  persistWithdrawalIntent(): void {
    if (this.disk.failIntent) {
      throw new Error('flush failed');
    }
    this.disk.intentWrites++;
    this.disk.withdrawalIntent = this.withdrawalIntent;
  }
}

/** 一次进程：Gate + 清理器（cleanupOk 控制清理器是否报告全部成功）+ 已调用的初始化步骤。 */
class SimProcess {
  readonly gate: PrivacyGate;
  cleanups: number = 0;
  cleanupOk: boolean = false;
  inits: string[] = [];

  constructor(disk: SimDisk, version: string = '1') {
    this.gate = new PrivacyGate(new SimDiskStore(disk), (): number => 0, version);
    this.gate.retryScheduler = new NoopScheduler();
    for (const name of PrivacyInitSteps.ORDER) {
      this.gate.registerInitStep(name, (): void => {
        this.inits.push(name);
      });
    }
    this.gate.withdrawalCleanup = (): void => {
      this.cleanups++;
      if (this.cleanupOk) {
        this.gate.withdrawalCleanupDone();
      }
    };
    this.gate.coldStart(0);
  }

  /** App 冷启动的顺序：coldStart（构造里）→ 重试撤回清理 → 已同意时初始化。 */
  boot(): SimProcess {
    this.gate.retryPendingWithdrawalCleanup();
    this.gate.onConsented(0);
    return this;
  }

  /** 撤回生效时应有的样子：基本模式、不弹窗、凭据不可读、onConsented 不再初始化。 */
  assertBlocked(label: string): void {
    const st: PrivacyGateState = this.gate.state(0);
    expect(label + ':' + st.decisionRaw).assertEqual(label + ':' + PrivacyDecision.BASIC_MODE);
    expect(st.mustPrompt).assertFalse();
    expect(this.gate.credentialsReadable()).assertFalse();
    const before: number = this.inits.length;
    this.gate.onConsented(0);
    expect(label + ':new_inits=' + (this.inits.length - before)).assertEqual(label + ':new_inits=0');
  }
}

const ROUTES: RouteLookup = (name: string): RouteSpec | undefined => Routes.spec(name);

/** App 的接法（AppPrivacy + AppRouting）：闸门结论 → 守卫状态与放行条件；每次变化 privacyChanged + stateChanged。 */
class PrivacyHarness {
  nowMillis: number = 1000000;
  readonly store: MemoryPrivacyStore = new MemoryPrivacyStore();
  readonly backend: MemoryPendingBackend = new MemoryPendingBackend();
  readonly pending: PendingActionStore;
  readonly nav: NavSpy = new NavSpy();
  readonly router: Router;
  gate: PrivacyGate;
  update: UpdateCheckStatus = UpdateCheckStatus.finished(UpdateState.OK);
  session: string = 'guest';
  /** Navigation 已挂载且 Tab 外壳已显示（App 的 AppRouting.presentationReady）。 */
  shellReady: boolean = true;

  constructor() {
    this.pending = new PendingActionStore(this.backend, (): number => this.nowMillis);
    this.gate = new PrivacyGate(this.store, (): number => this.nowMillis, '2');
    this.router = new Router(this.pending, (): GuardState => this.guard(), this.nav, ROUTES,
      (): LaunchReadiness => this.readiness());
    this.router.presentationReady = (): boolean => this.shellReady;
  }

  privacy(): PrivacyState {
    return parsePrivacyState(this.gate.state(this.nowMillis).decisionRaw);
  }

  guard(): GuardState {
    return new GuardState(this.privacy(), UpdateState.OK, this.session, true, '1.0.0', false);
  }

  readiness(): LaunchReadiness {
    return new LaunchReadiness(true, this.privacy(), this.update);
  }

  /** 冷启动：新建 Gate（复用存储）。 */
  coldStart(): void {
    this.gate = new PrivacyGate(this.store, (): number => this.nowMillis, '2');
    this.gate.coldStart(this.nowMillis);
    this.publish();
  }

  publish(): void {
    this.router.privacyChanged();
    this.router.stateChanged(this.readiness(), this.nowMillis);
  }

  savePending(route: string, origin: RouteSource): void {
    const params: Record<string, Object> = {};
    params['route'] = route;
    this.pending.save(Router.OPEN_ROUTE_ACTION, params, this.nowMillis, origin);
  }

  record(): PendingAction | null {
    return this.pending.load(this.nowMillis);
  }
}

export default function privacyBehaviorTest() {
  describe('PrivacyBehavior', () => {
    it('privacy_namespace_survives_environment_cleanup', 0, () => {
      const kept: string[] = PreferencesNamespaceCleaner.deletable([CouliPreferences.APP_NAMESPACE,
        CouliPreferences.PRIVACY_DECISION_NAMESPACE, CouliPreferences.ENVIRONMENT_RECORD_NAMESPACE]);
      expect(JSON.stringify(kept)).assertEqual(JSON.stringify([CouliPreferences.APP_NAMESPACE]));
      expect(CouliPreferences.ALL_NAMESPACES.indexOf(CouliPreferences.PRIVACY_DECISION_NAMESPACE)).assertEqual(-1);
    });

    it('withdrawal_runs_only_credential_cleaners', 0, async () => {
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      const prefs: SpyCleaner = new SpyCleaner('preferences');
      const tokens: SpyCleaner = new SpyCleaner(PrivacyWithdrawalCleaners.SESSION_TOKENS);
      registry.register(prefs);
      registry.register(tokens);
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      // 已注册的真实清理器不被占位替换。
      // APP-03b R1-06：撤回清理名单加入埋点队列（tracker_queue）。
      expect(JSON.stringify(registry.names())).assertEqual(JSON.stringify(['preferences',
        PrivacyWithdrawalCleaners.SESSION_TOKENS, PrivacyWithdrawalCleaners.DEVICE_IDENTITY,
        PrivacyWithdrawalCleaners.TRACKER_QUEUE]));
      const report: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(report.ok).assertTrue();
      expect(JSON.stringify(report.cleaned)).assertEqual(JSON.stringify(PrivacyWithdrawalCleaners.NAMES));
      expect(tokens.calls).assertEqual(1);
      expect(prefs.calls).assertEqual(0);
      // 环境切换的全部清理同样包含凭据清理项（03 §3.6）。
      const all: CleanReport = await registry.cleanAll();
      expect(all.cleaned.length).assertEqual(4);
    });

    it('withdrawal_reports_missing_cleaner_as_failure', 0, async () => {
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      const report: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(report.ok).assertFalse();
      expect(report.failed.length).assertEqual(PrivacyWithdrawalCleaners.NAMES.length);
    });

    it('gate_withdraw_uses_cleanup_then_basic_mode', 0, () => {
      const store: MemoryPrivacyStore = new MemoryPrivacyStore();
      const gate: PrivacyGate = new PrivacyGate(store, (): number => 5, '1');
      gate.agree(5);
      const order: string[] = [];
      gate.withdrawalCleanup = (): void => {
        order.push('cleanup:' + store.decisionRaw);
      };
      const persistsBefore: number = store.persistCount;
      gate.withdraw(6);
      // 基本模式、清除同意记录与「待清理」在同一次落盘里完成，之后才发起清理。
      expect(JSON.stringify(order)).assertEqual(JSON.stringify(['cleanup:basic_mode']));
      expect(store.persistCount - persistsBefore).assertEqual(1);
      expect(store.withdrawalCleanupPending).assertTrue();
      expect(gate.credentialsReadable()).assertFalse();
      expect(store.decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      expect(store.basicMode).assertTrue();
      expect(store.consentedVersion).assertNull();
      expect(store.consentedAtMillis).assertNull();
    });

    it('withdrawal_cleanup_failure_retried_on_next_cold_start', 0, () => {
      const store: MemoryPrivacyStore = new MemoryPrivacyStore();
      let gate: PrivacyGate = new PrivacyGate(store, (): number => 0, '1');
      gate.agree(1);
      let attempts: number = 0;
      let succeed: boolean = false;
      const wire = (g: PrivacyGate): void => {
        g.withdrawalCleanup = (): void => {
          attempts++;
          if (succeed) {
            g.withdrawalCleanupDone();
          }
        };
      };
      wire(gate);
      gate.withdraw(2);
      expect(attempts).assertEqual(1);
      expect(gate.withdrawalCleanupPending).assertTrue();
      // 下次冷启动：仍待清理 → 重试；这次成功 → 标记清除，凭据可读。
      gate = new PrivacyGate(store, (): number => 3, '1');
      wire(gate);
      gate.coldStart(3);
      succeed = true;
      expect(gate.retryPendingWithdrawalCleanup()).assertTrue();
      expect(attempts).assertEqual(2);
      expect(store.withdrawalCleanupPending).assertFalse();
      expect(gate.credentialsReadable()).assertTrue();
      // 已清干净：再次冷启动不重试，决定仍是基本模式。
      gate = new PrivacyGate(store, (): number => 4, '1');
      wire(gate);
      expect(gate.retryPendingWithdrawalCleanup()).assertFalse();
      expect(gate.state(4).decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
    });

    it('withdrawal_interruption_points', 0, () => {
      // ① 落盘前中断（withdraw 没走到）：仍是已同意，不清理。
      const store: MemoryPrivacyStore = new MemoryPrivacyStore();
      store.decisionRaw = PrivacyDecision.CONSENTED;
      store.consentedVersion = '1';
      store.consentedAtMillis = 0;
      let gate: PrivacyGate = new PrivacyGate(store, (): number => 0, '1');
      gate.coldStart(0);
      expect(gate.state(0).decisionRaw).assertEqual(PrivacyDecision.CONSENTED);
      expect(gate.retryPendingWithdrawalCleanup()).assertFalse();
      // ② 落盘后、清理前中断（清理器没跑）：冷启动按基本模式、不弹窗、重试清理、凭据不可读。
      gate.withdraw(1);
      let cleanups: number = 0;
      gate = new PrivacyGate(store, (): number => 2, '1');
      gate.withdrawalCleanup = (): void => {
        cleanups++;
      };
      gate.coldStart(2);
      expect(gate.state(2).decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      expect(gate.state(2).mustPrompt).assertFalse();
      expect(gate.retryPendingWithdrawalCleanup()).assertTrue();
      expect(cleanups).assertEqual(1);
      expect(gate.credentialsReadable()).assertFalse();
      // ③ 只有「待清理」标记留下、decision 字段却是 consented（写入不完整）：仍强制按基本模式。
      store.decisionRaw = PrivacyDecision.CONSENTED;
      store.consentedVersion = '1';
      gate = new PrivacyGate(store, (): number => 3, '1');
      gate.coldStart(3);
      expect(gate.state(3).decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      gate.onConsented(3);
      // ④ 清理成功只删标记：之后按存储里的决定（这里 decision 字段被改坏成 consented，仅用于说明标记的优先级）。
      store.decisionRaw = PrivacyDecision.BASIC_MODE;
      gate.withdrawalCleanupDone();
      expect(store.withdrawalCleanupPending).assertFalse();
      expect(store.decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      expect(gate.credentialsReadable()).assertTrue();
    });

    it('undecided_in_app_agreement_opens_readonly', 0, () => {
      const undecided: GuardState = new GuardState('not_decided', 'ok', 'guest', true, '1.0.0', false);
      const params: Record<string, Object> = {};
      params['type'] = 'privacy';
      const d: GuardDecision = EntryGuard.decide(new RouteRequest('Agreement', params, 'in_app'), undecided, ROUTES);
      expect(d.kind).assertEqual(GuardDecisionKind.OPEN_READONLY);
      expect(d.route).assertEqual('Agreement');
      expect(d.reason).assertEqual(GuardReason.PRIVACY_UNDECIDED_READONLY);
      expect(d.reason).assertEqual('privacy_undecided_readonly');
      // 深链、推送、pending_action 仍等待；其他 App 内路由也等待。
      for (const source of ['deeplink', 'push', 'pending_action']) {
        const w: GuardDecision = EntryGuard.decide(new RouteRequest('Agreement', params, source), undecided, ROUTES);
        expect(w.kind).assertEqual(GuardDecisionKind.DEFER);
      }
      const search: GuardDecision = EntryGuard.decide(RouteRequest.of('Search', RouteSource.IN_APP), undecided, ROUTES);
      expect(search.kind).assertEqual(GuardDecisionKind.DEFER);
      // 参数仍按 schema 校验。
      const bad: Record<string, Object> = {};
      bad['type'] = 'nope';
      const invalid: GuardDecision = EntryGuard.decide(new RouteRequest('Agreement', bad, 'in_app'), undecided, ROUTES);
      expect(invalid.kind).assertEqual(GuardDecisionKind.REJECT);
    });

    it('router_privacy_changed_drops_agent_card_record_unless_consented', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.CONSENTED;
      h.store.consentedVersion = '2';
      h.gate = new PrivacyGate(h.store, (): number => h.nowMillis, '2');
      h.savePending('Wallet', RouteSource.AGENT_CARD);
      h.router.privacyChanged();
      expect((h.record() as PendingAction).origin).assertEqual('agent_card');
      h.gate.withdraw(h.nowMillis);
      h.router.privacyChanged();
      expect(h.record()).assertNull();
    });

    it('basic_mode_agree_completes_prerequisite_then_login', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.BASIC_MODE;
      h.store.basicMode = true;
      h.coldStart();
      // 基本模式下点「订单」Tab（App 内，需同意）：登记待办、请求补同意。
      h.router.open(RouteRequest.of('OrderList', RouteSource.IN_APP));
      expect(h.nav.consentRequests).assertEqual(1);
      expect(h.record()).not().assertNull();
      h.gate.requestFullFunction(h.nowMillis);
      h.publish();
      // 弹窗显示期间的自动恢复（stateChanged）不得删除这条待办（Router 的内存标记 consentAwaited）。
      expect(h.record()).not().assertNull();
      h.nowMillis += 60000;
      h.gate.agree(h.nowMillis);
      h.router.privacyChanged();
      // 用户主动同意 = 完成一个前置步骤：计时重置，进下一个前置页（游客 → 登录），待办保留到登录后恢复。
      h.router.consentHandled(true);
      expect(h.nav.stack[h.nav.stack.length - 1]).assertEqual('Login');
      const rec: PendingAction = h.record() as PendingAction;
      expect(rec.timerStartedAt).assertEqual(h.nowMillis);
    });

    it('basic_mode_refusal_again_drops_registered_pending', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.BASIC_MODE;
      h.store.basicMode = true;
      h.coldStart();
      h.router.open(RouteRequest.of('Me', RouteSource.IN_APP));
      expect(h.record()).not().assertNull();
      h.gate.requestFullFunction(h.nowMillis);
      h.gate.disagree(h.nowMillis);
      h.gate.stillDisagree(h.nowMillis);
      h.router.privacyChanged();
      h.router.consentHandled(false);
      h.publish();
      expect(h.record()).assertNull();
      expect(h.nav.stack.length).assertEqual(0);
    });

    it('basic_mode_reprompt_record_rejected_after_restart', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.BASIC_MODE;
      h.store.basicMode = true;
      h.savePending('OrderList', RouteSource.IN_APP);
      // 进程重启后没有内存标记：基本模式下自动恢复照常 reject 并删除。
      h.coldStart();
      expect(h.record()).assertNull();
    });

    it('push_fallback_to_messages_registers_messages_for_login', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.CONSENTED;
      h.store.consentedVersion = '2';
      h.coldStart();
      // Login 没有声明 push 入口：推送兜底到 Messages，游客要先登录，登记的待办是 Messages。
      h.router.open(RouteRequest.of('Login', RouteSource.PUSH));
      const rec: PendingAction = h.record() as PendingAction;
      expect(JSON.stringify(rec.params['route'])).assertEqual(JSON.stringify('Messages'));
    });

    it('kept_pending_after_update_timeout_does_not_spin', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.CONSENTED;
      h.store.consentedVersion = '2';
      h.update = UpdateCheckStatus.checking(h.nowMillis);
      h.savePending('OrderList', RouteSource.IN_APP);
      h.coldStart();
      expect(h.router.updateWaitDeadline(h.readiness(), h.nowMillis)).assertEqual(h.nowMillis + 5000);
      h.nowMillis += 6000;
      h.router.stateChanged(h.readiness(), h.nowMillis);
      // 超时按 unknown：OrderList 前置未满足（游客）→ 保留待办；之后不再给出过去的重试时刻。
      expect(h.record()).not().assertNull();
      expect(h.router.updateWaitDeadline(h.readiness(), h.nowMillis)).assertNull();
      expect(h.router.launchDeadline(h.readiness())).assertNull();
    });

    it('router_privacy_changed_keeps_in_app_record', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.savePending('Search', RouteSource.IN_APP);
      h.router.privacyChanged();
      expect(h.record()).not().assertNull();
    });

    it('cold_start_resumes_pending_only_after_gate_concludes', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.savePending('Search', RouteSource.IN_APP);
      h.coldStart();
      // 未决：首启弹窗显示，pending_action 保留、不执行。
      expect(h.gate.state(h.nowMillis).promptStageRaw).assertEqual(PrivacyPromptStage.FIRST);
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.record()).not().assertNull();
      h.nowMillis += 1000;
      h.gate.agree(h.nowMillis);
      h.publish();
      // 闸门全部就绪：恢复执行一次并删除。
      expect(JSON.stringify(h.nav.stack)).assertEqual(JSON.stringify(['Search']));
      expect(h.record()).assertNull();
    });

    it('basic_mode_conclusion_rejects_and_deletes_pending', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.savePending('Wallet', RouteSource.IN_APP);
      h.coldStart();
      h.gate.disagree(h.nowMillis);
      h.publish();
      expect(h.record()).not().assertNull();
      h.gate.stillDisagree(h.nowMillis);
      h.publish();
      // 基本模式下自动恢复被守卫 reject（basic_mode_blocked）：删除、不补执行。
      expect(h.record()).assertNull();
      expect(h.nav.stack.length).assertEqual(0);
    });

    it('basic_mode_reprompt_keeps_basic_mode_for_router', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.BASIC_MODE;
      h.store.basicMode = true;
      h.coldStart();
      expect(h.gate.state(h.nowMillis).mustPrompt).assertFalse();
      h.gate.requestFullFunction(h.nowMillis);
      const s: PrivacyGateState = h.gate.state(h.nowMillis);
      expect(s.mustPrompt).assertTrue();
      expect(s.decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
    });

    it('policy_upgrade_reprompt_reports_not_decided', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.CONSENTED;
      h.store.consentedVersion = '1';
      h.coldStart();
      expect(h.privacy()).assertEqual(PrivacyState.NOT_DECIDED);
      expect(h.gate.state(h.nowMillis).promptStageRaw).assertEqual(PrivacyPromptStage.FIRST);
    });

    it('onconsented_new_cycle_after_withdraw', 0, () => {
      const store: MemoryPrivacyStore = new MemoryPrivacyStore();
      const gate: PrivacyGate = new PrivacyGate(store, (): number => 0, '1');
      const scheduler: NoopScheduler = new NoopScheduler();
      gate.retryScheduler = scheduler;
      const calls: string[] = [];
      for (const name of PrivacyInitSteps.ORDER) {
        gate.registerInitStep(name, (): void => {
          calls.push(name);
          if (name === PrivacyInitSteps.DEVICE_REGISTER) {
            throw new Error('offline');
          }
        });
      }
      gate.agree(1);
      gate.onConsented(1);
      gate.onConsented(2);
      expect(JSON.stringify(calls)).assertEqual(JSON.stringify(PrivacyInitSteps.ORDER));
      gate.withdraw(3);
      // 撤回后上一周期排队的设备注册重试作废。
      scheduler.actions[0]();
      expect(calls.length).assertEqual(5);
      gate.onConsented(4);
      expect(calls.length).assertEqual(5);
      gate.requestFullFunction(5);
      gate.agree(6);
      gate.onConsented(6);
      expect(calls.length).assertEqual(10);
    });

    it('unknown_init_step_rejected', 0, () => {
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      let threw: boolean = false;
      try {
        gate.registerInitStep('analytics', (): void => {
        });
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('retry_delay_doubles_and_caps', 0, () => {
      const delays: number[] = [];
      for (let i = 0; i < 8; i++) {
        delays.push(PrivacyGate.retryDelay(i));
      }
      expect(JSON.stringify(delays)).assertEqual(JSON.stringify([1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000]));
    });

    it('invalid_stored_version_reprompts', 0, () => {
      const store: MemoryPrivacyStore = new MemoryPrivacyStore();
      store.decisionRaw = PrivacyDecision.CONSENTED;
      store.consentedVersion = 'v2';
      const gate: PrivacyGate = new PrivacyGate(store, (): number => 0, '2');
      gate.coldStart(0);
      expect(gate.state(0).mustPrompt).assertTrue();
      store.decisionRaw = 'garbage';
      gate.coldStart(0);
      expect(gate.state(0).decisionRaw).assertEqual(PrivacyDecision.NOT_DECIDED);
    });
    // ---------------------------------------------------------------- R1-01 撤回两阶段写入的故障注入

    it('withdraw_record_write_fails_restart_reads_old_consented_but_stays_blocked', 0, () => {
      const disk: SimDisk = SimDisk.consented('1');
      const p1: SimProcess = new SimProcess(disk).boot();
      expect(p1.inits.length).assertEqual(5);
      disk.failRecord = true;
      // 第二阶段（决定记录）写入失败：撤回整体失败、报告给调用方；内存里立即按基本模式。
      expect(p1.gate.withdraw(0)).assertFalse();
      expect(p1.gate.withdrawalUnsaved).assertTrue();
      expect(p1.gate.state(0).decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      expect(p1.gate.credentialsReadable()).assertFalse();
      expect(disk.decisionRaw).assertEqual(PrivacyDecision.CONSENTED);
      expect(disk.withdrawalIntent).assertTrue();
      // 清理器报告成功也不清除痕迹（写入还没落盘）。
      p1.cleanupOk = true;
      p1.gate.withdrawalCleanupDone();
      expect(disk.withdrawalIntent).assertTrue();
      // 进程被回收后重启：磁盘上决定记录仍是旧的 consented，但撤回意图在 → 不得放行。
      const p2: SimProcess = new SimProcess(disk).boot();
      p2.assertBlocked('restart_record_failed');
      expect(p2.cleanups).assertEqual(1);
      expect(disk.decisionRaw).assertEqual(PrivacyDecision.CONSENTED);
      // 磁盘恢复：下一次冷启动把决定记录补成基本模式 + 待清理，清理成功后痕迹全部清除（撤回意图最后清）。
      disk.failRecord = false;
      const p3: SimProcess = new SimProcess(disk);
      expect(disk.decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      expect(disk.withdrawalCleanupPending).assertTrue();
      expect(disk.consentedVersion).assertNull();
      p3.cleanupOk = true;
      p3.boot();
      expect(disk.withdrawalCleanupPending).assertFalse();
      expect(disk.withdrawalIntent).assertFalse();
      expect(p3.gate.credentialsReadable()).assertTrue();
      expect(p3.gate.state(0).decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      expect(p3.inits.length).assertEqual(0);
    });

    it('withdraw_intent_write_fails_record_saved_restart_blocked', 0, () => {
      const disk: SimDisk = SimDisk.consented('1');
      const p1: SimProcess = new SimProcess(disk).boot();
      disk.failIntent = true;
      expect(p1.gate.withdraw(0)).assertFalse();
      p1.assertBlocked('same_process');
      expect(disk.withdrawalIntent).assertFalse();
      expect(disk.decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      const p2: SimProcess = new SimProcess(disk).boot();
      p2.assertBlocked('restart_intent_failed');
      expect(p2.cleanups).assertEqual(1);
    });

    it('withdraw_both_writes_fail_retries_before_reading_credentials', 0, () => {
      const disk: SimDisk = SimDisk.consented('1');
      const p1: SimProcess = new SimProcess(disk).boot();
      disk.failRecord = true;
      disk.failIntent = true;
      p1.cleanupOk = true;
      expect(p1.gate.withdraw(0)).assertFalse();
      // 清理照常发起（只删凭据），但写入成功前不初始化、凭据不可读、不清除痕迹。
      expect(p1.cleanups).assertEqual(1);
      p1.assertBlocked('both_failed');
      // 用户在同一进程里重新同意：仍不初始化（撤回写入没落盘）。
      p1.gate.requestFullFunction(0);
      p1.gate.agree(0);
      p1.gate.onConsented(0);
      expect(p1.inits.length).assertEqual(5);
      expect(p1.gate.credentialsReadable()).assertFalse();
      // 磁盘恢复：读取凭据前重试写入 → 成功 → 清理器早已报告成功 → 清除痕迹。
      disk.failRecord = false;
      disk.failIntent = false;
      const writesBefore: number = disk.intentWrites;
      expect(p1.gate.credentialsReadable()).assertTrue();
      expect(disk.intentWrites - writesBefore).assertEqual(2);
      expect(disk.withdrawalIntent).assertFalse();
      expect(disk.withdrawalCleanupPending).assertFalse();
      expect(p1.gate.withdrawalUnsaved).assertFalse();
    });

    it('withdraw_both_writes_fail_then_disk_recovers_on_cold_start_retry', 0, () => {
      const disk: SimDisk = SimDisk.consented('1');
      const p1: SimProcess = new SimProcess(disk).boot();
      disk.failRecord = true;
      disk.failIntent = true;
      expect(p1.gate.withdraw(0)).assertFalse();
      // 同一进程里再次冷启动（Ability 重建、Gate 复用）：coldStart 先重试写入。
      disk.failIntent = false;
      p1.gate.coldStart(0);
      expect(disk.withdrawalIntent).assertTrue();
      expect(p1.gate.withdrawalUnsaved).assertTrue();
      p1.assertBlocked('partial_retry');
      // 此时被回收：撤回意图已落盘，重启仍挡住。
      const p2: SimProcess = new SimProcess(disk).boot();
      p2.assertBlocked('restart_after_partial_retry');
    });

    it('withdraw_success_path_interruption_points', 0, () => {
      // ① 两阶段都落盘、清理前被回收。
      let disk: SimDisk = SimDisk.consented('1');
      let p: SimProcess = new SimProcess(disk).boot();
      expect(p.gate.withdraw(0)).assertTrue();
      expect(disk.intentWrites).assertEqual(1);
      expect(disk.decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
      new SimProcess(disk).boot().assertBlocked('after_writes');
      // ② 清理成功、清「待清理」写失败后被回收：撤回意图与待清理都还在 → 挡住并重试清理。
      disk = SimDisk.consented('1');
      p = new SimProcess(disk).boot();
      p.gate.withdraw(0);
      disk.failRecord = true;
      p.gate.withdrawalCleanupDone();
      expect(disk.withdrawalCleanupPending).assertTrue();
      expect(disk.withdrawalIntent).assertTrue();
      expect(p.gate.credentialsReadable()).assertFalse();
      disk.failRecord = false;
      new SimProcess(disk).boot().assertBlocked('clear_pending_failed');
      // ③ 「待清理」已清、清撤回意图写失败后被回收：撤回意图在 → 挡住、补回「待清理」并重试清理。
      disk = SimDisk.consented('1');
      p = new SimProcess(disk).boot();
      p.gate.withdraw(0);
      disk.failIntent = true;
      p.gate.withdrawalCleanupDone();
      expect(disk.withdrawalCleanupPending).assertFalse();
      expect(disk.withdrawalIntent).assertTrue();
      expect(p.gate.credentialsReadable()).assertFalse();
      disk.failIntent = false;
      const p3: SimProcess = new SimProcess(disk);
      expect(disk.withdrawalCleanupPending).assertTrue();
      p3.assertBlocked('clear_intent_failed');
      p3.cleanupOk = true;
      expect(p3.gate.retryPendingWithdrawalCleanup()).assertTrue();
      expect(disk.withdrawalIntent).assertFalse();
      expect(disk.withdrawalCleanupPending).assertFalse();
      expect(p3.gate.credentialsReadable()).assertTrue();
      // ④ 全部完成后重启：基本模式、凭据可读、不再清理。
      const p4: SimProcess = new SimProcess(disk).boot();
      expect(p4.cleanups).assertEqual(0);
      expect(p4.gate.credentialsReadable()).assertTrue();
      expect(p4.gate.state(0).decisionRaw).assertEqual(PrivacyDecision.BASIC_MODE);
    });

    // ---------------------------------------------------------------- R1-02 同意恢复等 Tab 就绪与强更结果

    it('consent_resume_waits_for_tab_ready', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.CONSENTED;
      h.store.consentedVersion = '1';
      h.savePending('OrderList', RouteSource.IN_APP);
      // 政策升级：冷启动重弹首启弹窗；Navigation 已挂载、Tab 外壳还没出现。
      h.shellReady = false;
      h.coldStart();
      expect(h.gate.state(h.nowMillis).mustPrompt).assertTrue();
      h.nowMillis += 60000;
      h.gate.agree(h.nowMillis);
      h.router.privacyChanged();
      h.router.consentHandled(true);
      // 立即记前置完成（计时重置），但不推页、不删待办。
      expect(h.nav.stack.length).assertEqual(0);
      expect((h.record() as PendingAction).timerStartedAt).assertEqual(h.nowMillis);
      h.publish();
      expect(h.nav.stack.length).assertEqual(0);
      // Tab 就绪：按「刚完成前置」继续 → 游客进登录页，待办保留。
      h.shellReady = true;
      h.publish();
      expect(JSON.stringify(h.nav.stack)).assertEqual(JSON.stringify(['Login']));
      expect(h.record()).not().assertNull();
    });

    it('consent_resume_executes_only_after_tab_ready', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.session = 'phone_bound';
      h.savePending('Search', RouteSource.IN_APP);
      h.shellReady = false;
      h.coldStart();
      h.gate.agree(h.nowMillis);
      h.router.privacyChanged();
      h.router.consentHandled(true);
      h.publish();
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.record()).not().assertNull();
      h.shellReady = true;
      h.publish();
      expect(JSON.stringify(h.nav.stack)).assertEqual(JSON.stringify(['Search']));
      expect(h.record()).assertNull();
    });

    it('consent_resume_waits_for_update_result', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.store.decisionRaw = PrivacyDecision.BASIC_MODE;
      h.store.basicMode = true;
      h.coldStart();
      h.router.open(RouteRequest.of('OrderList', RouteSource.IN_APP));
      h.gate.requestFullFunction(h.nowMillis);
      h.publish();
      // 强更检查开始，Tab 已就绪：同意后等结果。
      h.update = UpdateCheckStatus.checking(h.nowMillis);
      h.gate.agree(h.nowMillis);
      h.router.privacyChanged();
      h.router.consentHandled(true);
      h.publish();
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.record()).not().assertNull();
      h.nowMillis += 4000;
      h.publish();
      expect(h.nav.stack.length).assertEqual(0);
      // 强更有结果：按「刚完成前置」继续 → 游客进登录页（满 5 秒按 unknown 的路径由 RouterBehavior 覆盖）。
      h.update = UpdateCheckStatus.finished(UpdateState.OK);
      h.publish();
      expect(JSON.stringify(h.nav.stack)).assertEqual(JSON.stringify(['Login']));
    });

    // ---------------------------------------------------------------- R1-03 冷启动推送等 Navigation 与 Tab

    it('cold_start_push_waits_for_navigation_and_tab', 0, async () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.session = 'phone_bound';
      h.store.decisionRaw = PrivacyDecision.CONSENTED;
      h.store.consentedVersion = '2';
      h.shellReady = false;
      h.coldStart();
      const looked: string[] = [];
      const landing: PushLanding = new PushLanding((id: string): Promise<PushLookupResult> => {
        looked.push(id);
        return Promise.resolve(PushLookupResult.found('Messages'));
      });
      // 冷启动推送：闸门与强更都有结论，但外壳未就绪 → 不回查，消息编号留在启动队列。
      expect(h.router.openPush('m1', landing)).assertNull();
      expect(looked.length).assertEqual(0);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
      expect((h.router.lastDecision as GuardDecision).reason).assertEqual(GuardReason.SHELL_NOT_READY);
      expect(h.router.stateChanged(h.readiness(), h.nowMillis)).assertNull();
      expect(h.router.drainLaunchQueue(h.readiness(), h.nowMillis)).assertNull();
      expect(looked.length).assertEqual(0);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
      // Navigation 与 Tab 就绪：stateChanged 用记下的回查器回查并执行。
      h.shellReady = true;
      const run: Promise<void> | null = h.router.stateChanged(h.readiness(), h.nowMillis);
      expect(run === null).assertFalse();
      await run;
      expect(JSON.stringify(looked)).assertEqual(JSON.stringify(['m1']));
      expect(JSON.stringify(h.nav.stack)).assertEqual(JSON.stringify(['Messages']));
      expect(h.router.hasPendingLaunchIntent).assertFalse();
    });

    it('external_request_queues_until_tab_ready', 0, () => {
      const h: PrivacyHarness = new PrivacyHarness();
      h.session = 'phone_bound';
      h.store.decisionRaw = PrivacyDecision.CONSENTED;
      h.store.consentedVersion = '2';
      h.shellReady = false;
      h.coldStart();
      const d: GuardDecision = h.router.open(RouteRequest.of('Search', RouteSource.DEEPLINK));
      expect(d.reason).assertEqual(GuardReason.SHELL_NOT_READY);
      expect(h.nav.stack.length).assertEqual(0);
      expect(h.router.hasPendingLaunchIntent).assertTrue();
      h.shellReady = true;
      h.publish();
      expect(JSON.stringify(h.nav.stack)).assertEqual(JSON.stringify(['Search']));
    });
  });
}
