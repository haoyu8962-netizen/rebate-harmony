import { RouteEntry, RouteSpec } from 'generated';
import { EntryGuard, RouteLookup } from './EntryGuard';
import { GuardDecision, GuardDecisionKind, GuardReason } from './GuardDecision';
import { GuardState, PrivacyState, UpdateState } from './GuardState';
import { LaunchIntent, LaunchQueue, LaunchReadiness, LaunchRelease } from './LaunchQueue';
import { PendingAction, PendingActionStore } from './PendingActionStore';
import { PushLanding, PushLandingResult } from './PushLanding';
import { RouteParamValidator } from './RouteParamValidator';
import { RoutePolicy, RouteTable } from './RoutePolicy';
import { emptyParams, paramCount, RouteRequest, RouteSource } from './RouteRequest';

/** 导航栈里的一页。route 为 null 表示内置的升级提示页（routes.json 没有它的路由名，rule-gaps G03）。 */
export class RouteDestination {
  readonly route: string | null;
  readonly params: Record<string, Object>;
  /** 只读打开（基本模式、强更检查结果未知）：页面不得自动发起写请求或授权（03 §4.4）。 */
  readonly readonly: boolean;

  constructor(route: string | null, params: Record<string, Object> = emptyParams(), readonly: boolean = false) {
    this.route = route;
    this.params = params;
    this.readonly = readonly;
  }

  get isUpgradePrompt(): boolean {
    return this.route === null;
  }
}

/** Router 对导航容器的要求（entry 用 NavPathStack 实现；单测用记录型替身）。Home 是栈底，不入栈。 */
export interface RouteNavigator {
  /** 推入一页。 */
  push(destination: RouteDestination): void;

  /** 清空到栈底后依次推入（空数组 = 回到首页）。 */
  reset(destinations: RouteDestination[]): void;

  /** 守卫要求先补隐私同意（02b 接隐私弹窗）。 */
  requestConsent(): void;
}

/**
 * Router：EntryGuard.decide → 按结论推入页面 / 登记 pending_action / 进前置页 / 排队（03 §4.4）。
 * 原生页面、首页卡片、JSBridge nav.open、推送点击、深链、Agent 卡片都走 open（同一入口函数）。
 * Router 不认识任何 Feature 类型：页面由 entry 按路由名在注册表里取（03 §3.1 依赖方向）。
 */
export class Router {
  /** pending_action 里「打开路由」动作的标签（rule-gaps G13：动作编码表未定）。 */
  static readonly OPEN_ROUTE_ACTION: string = 'open_route';

  /** 最近一次结论（调试显示、埋点用）。 */
  lastDecision: GuardDecision | null = null;
  private readonly pendingStore: PendingActionStore;
  private readonly state: () => GuardState;
  private readonly navigator: RouteNavigator;
  private readonly routes: RouteLookup;
  private readonly launchQueue: LaunchQueue = new LaunchQueue();
  /**
   * 放行条件的状态源（环境、隐私、强更检查进度）。给了它，外部请求、pending_action 恢复与推送回查在强更「检查中」
   * 时等待（闸门通过后最长 5 秒，到时按 unknown），不立即交给 EntryGuard；为 null 时不做这层等待（纯守卫单测）。
   */
  private readonly readiness: (() => LaunchReadiness) | null;
  /** 会话 / 环境代次：退出登录、切换账号、切换环境时递增，进行中的推送回查结果据此作废。 */
  private generation: number = 0;
  /**
   * pending_action 的登记序号（APP-05a 共性 25，本进程内存）：每次登记推进；savedPendingSerial 是现存记录的序号（冷启动读到的
   * 旧记录为 0）。sessionClearedBoundary 是网络层清掉会话（10404、刷新失败）那一刻的登记序号——之后登记的待办属于游客或
   * 新会话，不归原会话。-1 = 本进程没有记下过「原会话被别处清除」。
   */
  private pendingSerial: number = 0;
  private savedPendingSerial: number = 0;
  private sessionClearedBoundary: number = -1;
  /** 被网络层清除的会话世代（ApiClient 的会话世代，随 Effect 传入；诊断与测试用）。 */
  private clearedSessionGeneration: number = -1;
  /**
   * 排队推送的回查器（R2-01）：openPush 时记下（或由 App 用 setPushLanding 注入），等待结束后 stateChanged /
   * drainLaunchQueue 未传回查器时用它继续回查，不把推送永远留在队列里。
   */
  private pushLanding: PushLanding | null = null;
  /**
   * 用户刚完成一个前置步骤、恢复因强更检查而暂停（R2-02）：等待结束时按 enterPrerequisite=true 继续
   * （还缺前置时进下一个前置页）；冷启动与普通状态变化的静默恢复为 false。
   */
  private prerequisiteResumeDeferred: boolean = false;
  /**
   * 用户在 App 内主动发起、被隐私阻断而正在等隐私弹窗结论的动作已登记（R2-03）：只有这种情况下自动恢复遇到
   * 隐私阻断才保留记录，由 consentHandled 决定去留；其余自动恢复被守卫 reject（含 basic_mode_blocked）一律删除。
   */
  private consentAwaited: boolean = false;
  /**
   * 展示层就绪（03 §4.4「Tab 就绪」：Navigation 已挂载且 Tab 外壳已显示；APP-02b R1-02 / R1-03）。App 接上；
   * 缺省恒为 true（纯守卫单测）。未就绪时：外部请求与推送只排队（推送不回查）、pending_action 恢复暂停（同意 / 前置完成
   * 记为「刚完成前置」）、stateChanged 与 drainLaunchQueue 什么都不放行；就绪后 App 调 stateChanged 继续。
   */
  presentationReady: () => boolean = () => true;
  /**
   * 待办暂缓中（APP-05b harmony-review-r2 R2-02，共性 9）：第三方新号等绑手机引导、老用户等 phone_bound 查清期间为 true（登录
   * 出口 RouterLoginHost 接 LoginService.pendingHeld，绑定在当前会话世代上）。为 true 时所有自动恢复入口——stateChanged（含
   * 版本检查完成、等满 5 秒、外壳就绪、会话同步）、resumePending、prerequisiteCompleted——都只保留记录、不执行；也不消耗
   * 「刚完成前置」的暂停标记。只有引导跳过、关闭或绑定完成时由登录流程明确释放。缺省恒为 false。
   */
  pendingHold: () => boolean = () => false;

  constructor(pendingStore: PendingActionStore, state: () => GuardState, navigator: RouteNavigator,
    routes: RouteLookup = (name: string): RouteSpec | undefined => RouteTable.spec(name),
    readiness: (() => LaunchReadiness) | null = null) {
    this.pendingStore = pendingStore;
    this.state = state;
    this.navigator = navigator;
    this.routes = routes;
    this.readiness = readiness;
  }

  // ---------------------------------------------------------------- 强更检查的等待

  /** 闸门已通过、强更检查中且未满 5 秒（03 §4.4 状态表「检查中：等待，最长 5 秒」）。 */
  private awaitingUpdate(): boolean {
    if (this.readiness === null) {
      return false;
    }
    return this.launchQueue.awaitingUpdate(this.readiness(), this.pendingStore.now());
  }

  /** 守卫用的状态：强更结果按等待协调器的口径（检查中未满 5 秒保持 state() 原值，满 5 秒按 unknown）。 */
  private currentState(): GuardState {
    const s: GuardState = this.state();
    if (this.readiness === null) {
      return s;
    }
    const r: LaunchReadiness = this.readiness();
    const update: UpdateState | null = this.launchQueue.updateFor(r, this.pendingStore.now());
    return update === null ? s : s.withLaunch(s.environmentSettled, s.privacyState, update);
  }

  private static waitingDecision(): GuardDecision {
    return new GuardDecision(GuardDecisionKind.DEFER, null, GuardReason.UPDATE_CHECKING);
  }

  private static shellWaitingDecision(): GuardDecision {
    return new GuardDecision(GuardDecisionKind.DEFER, null, GuardReason.SHELL_NOT_READY);
  }

  /**
   * 恢复 pending_action 的完整门槛（R1-02）：展示层就绪，且（接了放行条件源时）环境、隐私闸门已通过、
   * 强更有结果或已等满 5 秒。与 stateChanged 的门槛一致。
   */
  private resumeAllowed(): boolean {
    if (!this.presentationReady()) {
      return false;
    }
    if (this.readiness === null) {
      return true;
    }
    return this.launchQueue.updateFor(this.readiness(), this.pendingStore.now()) !== null;
  }

  /**
   * 记下闸门通过的时刻（等待计时的起点）。App 在每次状态变化时都调，与外壳是否就绪无关，
   * 计时从环境与隐私闸门通过、检查开始时起算，不因外壳未就绪推迟。
   */
  observeReadiness(readiness: LaunchReadiness, now: number): void {
    this.launchQueue.observe(readiness, now);
  }

  /** 正在等强更检查时，等待到期的时刻（App 据此设一个定时器，到时再调 stateChanged）；不在等待时为 null。 */
  updateWaitDeadline(readiness: LaunchReadiness, now: number): number | null {
    return this.launchQueue.waitDeadline(readiness, now);
  }

  /**
   * 冷启动与前置条件变化后（环境、隐私、强更结果、会话、外壳就绪）调用；外壳未就绪时 App 不调（只调 observeReadiness）。
   * 闸门通过且强更有结果（或等满 5 秒按 unknown）时：先按 BR-ID-10 处理持久化的 pending_action
   * （过期删除；前置未满足保留、不自动弹前置页；满足则再过守卫、执行一次并删除），再放行排队的启动意图。
   * 仍在等待时什么都不动（不删除 pending_action）。返回推送回查的 Promise（没有时为 null）。
   * resumePending = false：只同步状态（启动意图照常放行），这一次不恢复 pending_action、也不消耗「刚完成前置」的暂停标记——
   * 已作废的登录尝试通知会话变化时用（APP-05a R2-02：「通知会话变了」与「允许恢复待办」分开），待办留给有效的流程处理。
   */
  stateChanged(readiness: LaunchReadiness, now: number, pushLanding: PushLanding | null = null,
    resumePending: boolean = true): Promise<void> | null {
    if (!this.presentationReady()) {
      // Navigation / Tab 未就绪：只记闸门通过时刻，待办与启动意图都留着（R1-02 / R1-03）。
      this.launchQueue.observe(readiness, now);
      return null;
    }
    const update: UpdateState | null = this.launchQueue.updateFor(readiness, now);
    if (update !== null && resumePending && !this.pendingHold()) {
      const s: GuardState = this.state();
      // 前置完成后因强更等待而暂停的恢复：按「刚完成前置」的语义继续（R2-02）。
      const enterPrerequisite: boolean = this.prerequisiteResumeDeferred;
      this.prerequisiteResumeDeferred = false;
      this.resumeWith(s.withLaunch(readiness.environmentSettled, readiness.privacy, update), enterPrerequisite);
    }
    return this.drainLaunchQueue(readiness, now, pushLanding);
  }

  // ---------------------------------------------------------------- 打开

  /**
   * 外部带进来的请求与自动执行的动作（source 不是 in_app）在强更检查中先排队等结果（最长 5 秒），
   * 不立即按 unknown 判定；App 内用户自己的操作不等（03 §4.4「上表只管外部带进来的请求与自动执行的动作」）。
   */
  open(request: RouteRequest): GuardDecision {
    if (request.sourceKind !== RouteSource.IN_APP && this.awaitingUpdate()) {
      const waiting: GuardDecision = Router.waitingDecision();
      this.apply(waiting, request);
      return waiting;
    }
    if (request.sourceKind !== RouteSource.IN_APP && !this.presentationReady()) {
      // 外部请求在 Navigation / Tab 就绪前只排队（03 §4.4）。
      const waiting: GuardDecision = Router.shellWaitingDecision();
      this.apply(waiting, request);
      return waiting;
    }
    return this.openWith(request, this.currentState());
  }

  /**
   * 只判定、不执行（桥 nav.open 用，R1-10：先回复发起调用，再 apply；回复与执行之间是同步的，状态不会变）。
   */
  decide(request: RouteRequest, state: GuardState): GuardDecision {
    return EntryGuard.decide(request, state, this.routes);
  }

  openWith(request: RouteRequest, state: GuardState): GuardDecision {
    const decision: GuardDecision = EntryGuard.decide(request, state, this.routes);
    this.apply(decision, request);
    return decision;
  }

  /** 按守卫结论执行。 */
  apply(decision: GuardDecision, request: RouteRequest): void {
    this.lastDecision = decision;
    if (decision.isPrivacyBlock) {
      this.dropAgentCardPending();
    }
    switch (decision.kind) {
      case GuardDecisionKind.OPEN:
      case GuardDecisionKind.OPEN_READONLY: {
        if (decision.route === null) {
          return;
        }
        // 推送兜底的 Messages 不带原请求的参数；资金与实名页面丢弃全部参数（03 §4.4）。
        const keepsParams: boolean = decision.route === request.route;
        this.show(new RouteDestination(decision.route, keepsParams ? EntryGuard.effectiveParams(request) : emptyParams(),
          decision.kind === GuardDecisionKind.OPEN_READONLY));
        return;
      }
      case GuardDecisionKind.FORCE_UPDATE:
        this.navigator.reset([new RouteDestination(RoutePolicy.FORCE_UPDATE)]);
        return;
      case GuardDecisionKind.REQUIRE_LOGIN:
      case GuardDecisionKind.REQUIRE_BIND_PHONE:
      case GuardDecisionKind.REQUIRE_REALNAME:
        // 资金、实名与注销类路由不登记：只去前置页，完成后回到发起页由用户重新点击（BR-ID-10「不适用的动作」）。
        // 推送改落 Messages 的兜底：登记的是 Messages，不是原路由。
        this.remember(this.pushTarget(request));
        if (decision.route !== null) {
          this.show(new RouteDestination(decision.route));
        }
        return;
      case GuardDecisionKind.REQUIRE_CONSENT:
        // 普通 App 内请求先登记，同意后按前置继续并恢复原路由；Agent 卡片要用户重新点击，不登记（BR-ID-10 Agent 卡片 ②）。
        if (request.sourceKind !== RouteSource.AGENT_CARD) {
          this.remember(request);
          this.consentAwaited = true;
        }
        this.navigator.requestConsent();
        return;
      case GuardDecisionKind.UPGRADE:
        this.show(new RouteDestination(null));
        return;
      case GuardDecisionKind.DEFER:
        // 外部带进来的请求排队，等条件满足后再交给 Router；App 内的操作不排队。
        // F-HM-09（APP-04 共性 65）：桥导航（nav.open）的结果以回复为准，deferred 时不进启动队列、事后也不补执行。
        if (request.sourceKind !== RouteSource.IN_APP && request.sourceKind !== RouteSource.BRIDGE) {
          this.launchQueue.enqueue(LaunchIntent.route(request));
        }
        return;
      default:
        // REJECT：不打开，停在当前页（冷启动时即首页）。TODO(APP-03): 记埋点 route_entry_blocked（只带路由名与入口类别）。
        return;
    }
  }

  /**
   * 推送请求实际要去的路由：原路由没声明 push，或强更结果未知且不在只读清单时，改为 Messages（BR-ID-10）；
   * 与 EntryGuard 的兜底同口径，只用于登记 pending_action。
   */
  private pushTarget(request: RouteRequest): RouteRequest {
    if (request.sourceKind !== RouteSource.PUSH) {
      return request;
    }
    const spec: RouteSpec | undefined = this.routes(request.route);
    const unknownUpdate: boolean = this.currentState().updateState === UpdateState.UNKNOWN
      && RoutePolicy.UPDATE_UNKNOWN_READONLY_ROUTES.indexOf(request.route) < 0;
    if (spec === undefined || spec.entries.indexOf(RouteEntry.PUSH) < 0 || unknownUpdate) {
      return PushLanding.messages();
    }
    return request;
  }

  private show(destination: RouteDestination): void {
    if (destination.route === RoutePolicy.HOME) {
      this.navigator.reset([]);
    } else {
      this.navigator.push(destination);
    }
  }

  /** 该请求是否登记 pending_action（不登记的路由见 RoutePolicy.NO_PENDING_ACTION_ROUTES）。 */
  static registersPendingAction(route: string): boolean {
    return RoutePolicy.NO_PENDING_ACTION_ROUTES.indexOf(route) < 0;
  }

  /**
   * 登记 pending_action：动作为打开该路由，params 为路由名与经校验、清洗后的路由参数（不含令牌，BR-ID-10），
   * 并记下原始来源（origin）。参数不符合 routes.json schema 的不登记。
   */
  private remember(request: RouteRequest): void {
    if (!Router.registersPendingAction(request.route)) {
      return;
    }
    // Agent 卡片只带路由名；资金与实名页面不带参数。
    const params: Record<string, Object> = request.sourceKind === RouteSource.AGENT_CARD ? emptyParams()
      : EntryGuard.effectiveParams(request);
    const spec: RouteSpec | undefined = this.routes(request.route);
    if (spec !== undefined && !RouteParamValidator.isValid(params, spec)) {
      return;
    }
    const values: Record<string, Object> = {};
    values['route'] = request.route;
    if (paramCount(params) > 0) {
      values['params'] = params;
    }
    if (this.pendingStore.save(Router.OPEN_ROUTE_ACTION, values, this.pendingStore.now(), request.sourceKind)) {
      this.pendingSerial++;
      this.savedPendingSerial = this.pendingSerial;
    }
  }

  // ---------------------------------------------------------------- pending_action

  /** 完成了一个前置步骤（登录、绑手机、实名、隐私同意等）：重置计时后尝试恢复。 */
  prerequisiteCompleted(): void {
    this.pendingStore.markStepDone(this.pendingStore.now());
    this.resumePending();
  }

  /**
   * 完成了一个前置步骤、但暂缓恢复（APP-05b harmony-review-r1 R1-03，BR-ID-10、BR-INV-03）：第三方新号登录成功时先弹绑手机
   * 引导、老用户登录先查 phone_bound——这一刻只把未超时的待办计时重置为现在（已超时的删除，不得续活），不执行；之后由
   * resumePending 只恢复、不再重置。
   */
  prerequisiteDoneHeld(): void {
    this.pendingStore.markStepDone(this.pendingStore.now());
  }

  /**
   * 恢复 pending_action：再过一次守卫（source=pending_action，用当时最新状态）。
   * 还缺前置时保留记录并进前置页；其余情况执行 1 次后删除。
   * Agent 卡片登记的动作遇隐私阻断直接删除，不自动执行（BR-ID-10）。
   */
  resumePending(): void {
    if (this.pendingHold()) {
      // R2-02：待办暂缓中（绑手机引导未结束）：保留记录，等登录流程明确释放后再恢复。
      return;
    }
    if (!this.resumeAllowed()) {
      // 强更检查中（R2-02），或环境 / 隐私闸门未通过、Navigation / Tab 未就绪（APP-02b R1-02）：保留记录，
      // 全部就绪（强更有结果或满 5 秒）后由 stateChanged 按「刚完成前置」恢复（还缺前置时进下一个前置页）。
      this.prerequisiteResumeDeferred = true;
      return;
    }
    this.prerequisiteResumeDeferred = false;
    this.resumeWith(this.currentState(), true);
  }

  /**
   * enterPrerequisite：还缺前置时是否进前置页。用户刚完成一个前置步骤时为 true（接着进下一个前置页）；
   * 冷启动与状态变化触发的自动恢复为 false（只保留记录，不自动弹登录等页面）。
   */
  private resumeWith(state: GuardState, enterPrerequisite: boolean): void {
    const pending: PendingAction | null = this.pendingStore.load(this.pendingStore.now());
    if (pending === null) {
      return;
    }
    const request: RouteRequest | null = Router.requestOf(pending);
    if (request === null) {
      this.pendingStore.clear();
      return;
    }
    const decision: GuardDecision = EntryGuard.decide(request, state, this.routes);
    this.lastDecision = decision;
    if (pending.origin === RouteSource.AGENT_CARD && decision.isPrivacyBlock) {
      this.pendingStore.clear();
      return;
    }
    if (decision.kind === GuardDecisionKind.REJECT && decision.isPrivacyBlock && this.consentAwaited) {
      // 用户在 App 内主动发起、正在等隐私弹窗结论的动作：保留，由 consentHandled 决定去留。
      return;
    }
    if (decision.kind === GuardDecisionKind.REJECT) {
      // 守卫明确拒绝（basic_mode_blocked、entry_not_allowed、params_invalid、update_unknown_blocked 等）：
      // 删除记录、不补执行（R2-03，03 §4.4）。只有等待类（defer）与前置未满足保留。
      this.pendingStore.clear();
      this.lastDecision = decision;
      return;
    }
    if (decision.isPrerequisite) {
      if (enterPrerequisite && decision.route !== null) {
        this.show(new RouteDestination(decision.route));
      }
      return;
    }
    if (decision.kind === GuardDecisionKind.DEFER) {
      return;
    }
    if (decision.kind === GuardDecisionKind.REQUIRE_CONSENT) {
      // 恢复来源在基本模式下按外部请求丢弃，正常走不到这里；保守起见保留记录，只在用户操作触发时请求同意。
      if (enterPrerequisite) {
        this.navigator.requestConsent();
      }
      return;
    }
    this.pendingStore.clear();
    this.apply(decision, request);
  }

  /** origin=agent_card 的 pending_action 任何时刻遇到隐私阻断（打开时或恢复时）都删除，同意后不补执行（BR-ID-10）。 */
  private dropAgentCardPending(): void {
    const pending: PendingAction | null = this.pendingStore.load(this.pendingStore.now());
    if (pending !== null && pending.origin === RouteSource.AGENT_CARD) {
      this.pendingStore.clear();
    }
  }

  /**
   * 隐私闸门的结论变化（APP-02b：同意、仍不同意、版本升级重新提示、开启完整功能、撤回同意，每次都调）。
   * 结论不是「已同意」（未决、基本模式）时删除 origin=agent_card 的 pending_action（BR-ID-10 Agent 卡片 ②，与 iOS 同口径）。
   * pending_action 的恢复与排队启动意图的放行不在这里：App 随后调 stateChanged，闸门全部就绪时才恢复。
   */
  privacyChanged(): void {
    if (this.state().privacyState !== PrivacyState.CONSENTED) {
      this.dropAgentCardPending();
    }
  }

  /** 本机有没有未过期的 pending_action（登录成功后的计划 AfterLogin.plan 用；过期的记录随读取删除）。 */
  get hasPendingAction(): boolean {
    return this.pendingStore.load(this.pendingStore.now()) !== null;
  }

  /**
   * 登录拿到受限会话或强更低于时丢弃 pending_action（APP-05a AfterLogin discard_pending）：删除记录、不执行，
   * 也清掉「刚完成前置、等待恢复」的标记，免得强更结论回来后再补执行。
   */
  discardPendingAction(): void {
    this.pendingStore.clear();
    this.resetResumeFlags();
  }

  /** 退出登录、切换账号：清除 pending_action（BR-ID-10），并作废进行中的推送回查。 */
  sessionEnded(): void {
    this.pendingStore.clear();
    this.resetResumeFlags();
    this.generation++;
  }

  /**
   * 网络层清掉了会话（10404、刷新失败；APP-05a 共性 25、26）：在会话级 Effect 的同步回调里调用，记下这一刻的待办登记序号
   * 作为「原会话」与之后（游客、新会话）的分界。clearedGeneration 是网络层确定清理时随 Effect 传出的被清世代。
   */
  markSessionCleared(clearedGeneration: number): void {
    this.sessionClearedBoundary = this.pendingSerial;
    this.clearedSessionGeneration = clearedGeneration;
  }

  /** 最近一次被网络层清除的会话世代（没有为 -1）。 */
  get lastClearedSessionGeneration(): number {
    return this.clearedSessionGeneration;
  }

  /**
   * 登出收尾时原会话已被清除（APP-05a 共性 25；APP-05b harmony-review-r1 R1-04）：originalGeneration 是登出开始时的会话世代
   * （即本次要清的那个会话）。分界只认绑定在这个会话上的那次清除：网络层清掉的正是它（markSessionCleared 记下的被清世代与
   * originalGeneration 相同），且现存待办是那之后才登记的（游客点了需登录的入口等）→ 保留、推送回查照常作废，返回 true。
   * 被清的是别的（更早的）会话、或登出请求自己回 10404 清掉了它（网络层对登出不发会话 Effect）：把本次清理记为这个会话的
   * 分界（现存待办都在它之前，归原会话），返回 false，由调用方按原会话完成 sessionEnded。
   */
  sessionEndedOriginal(originalGeneration: number): boolean {
    if (this.clearedSessionGeneration !== originalGeneration) {
      // 不沿用历史分界：本次清理归属登出的原会话。
      this.markSessionCleared(originalGeneration);
      return false;
    }
    const boundary: number = this.sessionClearedBoundary;
    if (boundary >= 0 && this.savedPendingSerial > boundary && this.pendingStore.load(this.pendingStore.now()) !== null) {
      this.generation++;
      return true;
    }
    return false;
  }

  /** 切换环境：作废进行中的推送回查与排队的启动意图（pending_action 随命名空间清理一并删除，这里也清）。 */
  environmentChanged(): void {
    this.pendingStore.clear();
    this.resetResumeFlags();
    this.launchQueue.discard();
    this.generation++;
  }

  /**
   * 隐私弹窗已处理（02b 调用）。granted = 用户同意。
   * - Agent 卡片登记的动作：一律删除，要用户重新点击（BR-ID-10）。
   * - 其余动作：同意后计为完成一个前置步骤，按前置继续（登录、绑手机、实名）并恢复原路由；不同意则删除。
   */
  consentHandled(granted: boolean): void {
    this.consentAwaited = false;
    const pending: PendingAction | null = this.pendingStore.load(this.pendingStore.now());
    if (pending === null) {
      return;
    }
    if (!granted || pending.origin === RouteSource.AGENT_CARD) {
      this.pendingStore.clear();
      return;
    }
    this.prerequisiteCompleted();
  }

  private resetResumeFlags(): void {
    this.prerequisiteResumeDeferred = false;
    this.consentAwaited = false;
  }

  private static requestOf(pending: PendingAction): RouteRequest | null {
    if (pending.action !== Router.OPEN_ROUTE_ACTION) {
      return null;
    }
    const route: Object | null | undefined = pending.params['route'];
    if (typeof route !== 'string') {
      return null;
    }
    const nested: Object | null | undefined = pending.params['params'];
    let params: Record<string, Object> = emptyParams();
    if (nested !== null && nested !== undefined) {
      if (typeof nested !== 'object' || Array.isArray(nested)) {
        return null;
      }
      params = nested as Record<string, Object>;
    }
    return new RouteRequest(route as string, params, RouteSource.PENDING_ACTION);
  }

  // ---------------------------------------------------------------- 启动意图

  enqueueLaunch(intent: LaunchIntent): void {
    this.launchQueue.enqueue(intent);
  }

  get hasPendingLaunchIntent(): boolean {
    return this.launchQueue.pending !== null;
  }

  /** 还在等强更检查时下一次该调 drainLaunchQueue 的时刻（App 据此设一个定时器）；否则 null。 */
  launchDeadline(readiness: LaunchReadiness): number | null {
    return this.launchQueue.nextDeadline(readiness);
  }

  /**
   * 条件满足时放行排队的启动意图；推送意图经 PushLanding 回查后再打开。
   * 返回推送回查的 Promise（测试可等待它结束）；没有回查时为 null。
   */
  drainLaunchQueue(readiness: LaunchReadiness, now: number, pushLanding: PushLanding | null = null): Promise<void> | null {
    if (!this.presentationReady()) {
      return null;
    }
    const released: LaunchRelease | null = this.launchQueue.release(readiness, now);
    if (released === null) {
      return null;
    }
    const state: GuardState = this.state().withLaunch(readiness.environmentSettled, readiness.privacy, released.update);
    const request: RouteRequest | null = released.intent.request;
    if (request !== null) {
      this.openWith(request, state);
      return null;
    }
    const messageId: string = released.intent.messageId ?? '';
    const landing: PushLanding | null = pushLanding ?? this.pushLanding;
    if (landing === null) {
      // 没有回查函数：放回队列，等接线后再处理。
      this.launchQueue.enqueue(released.intent);
      return null;
    }
    return this.startPush(messageId, state, landing);
  }

  /** App 注入推送回查器（APP-03 接网络后由 App 在启动时调）；排队的推送等待结束后用它回查（R2-01）。 */
  setPushLanding(pushLanding: PushLanding | null): void {
    this.pushLanding = pushLanding;
  }

  /**
   * 热启动时的推送点击（App 已在前台或后台）：与冷启动同一路径——先过前置（环境、隐私、强更、会话），
   * 不满足就不回查（需要等待的重新排队），满足才回查；结果回来按最新状态重判，代次不符丢弃。
   */
  openPush(messageId: string, pushLanding: PushLanding): Promise<void> | null {
    // 记下回查器：排队后由 stateChanged（检查完成或等满 5 秒）继续回查（R2-01）。
    this.pushLanding = pushLanding;
    if (this.awaitingUpdate()) {
      // 强更检查中：不回查，排队等结果（或满 5 秒），由 stateChanged 放行。
      this.lastDecision = Router.waitingDecision();
      this.launchQueue.enqueue(LaunchIntent.push(messageId));
      return null;
    }
    if (!this.presentationReady()) {
      // 冷启动推送：Navigation / Tab 就绪前不回查，消息编号留在启动队列，就绪后由 stateChanged 回查并执行（R1-03）。
      this.lastDecision = Router.shellWaitingDecision();
      this.launchQueue.enqueue(LaunchIntent.push(messageId));
      return null;
    }
    return this.startPush(messageId, this.currentState(), pushLanding);
  }

  /** 当前会话 / 环境代次（发起回查时记下，结果回来时核对）。 */
  get sessionGeneration(): number {
    return this.generation;
  }

  private startPush(messageId: string, state: GuardState, pushLanding: PushLanding): Promise<void> | null {
    const blocked: PushLandingResult | null = PushLanding.probe(state, this.routes);
    if (blocked !== null) {
      this.executePush(blocked, messageId);
      return null;
    }
    const issued: number = this.generation;
    // lookUp 已把同步抛错、拒绝与超时转为 Messages 兜底；这里再兜一层，openPush 的 Promise 不因回查失败而拒绝。
    return pushLanding.lookUp(messageId).catch((): RouteRequest => PushLanding.messages())
      .then((lookedUp: RouteRequest) => {
        this.finishPush(lookedUp, messageId, issued);
      });
  }

  /**
   * 推送回查返回：会话或环境已变（退出登录、切换账号、切换环境）则丢弃旧结果；
   * 否则用当时最新的状态重新判定后执行（期间的强更、隐私、登录态变化都生效）。
   */
  finishPush(lookedUp: RouteRequest, messageId: string, issuedAt: number): void {
    if (issuedAt !== this.generation) {
      return;
    }
    if (this.awaitingUpdate()) {
      // 回查期间强更又进入检查（如回前台复查）：这条推送重新排队，等结果后再回查。
      this.lastDecision = Router.waitingDecision();
      this.launchQueue.enqueue(LaunchIntent.push(messageId));
      return;
    }
    if (!this.presentationReady()) {
      // 回查期间外壳消失（如隐私结论变化重建界面）：重新排队，就绪后再回查。
      this.lastDecision = Router.shellWaitingDecision();
      this.launchQueue.enqueue(LaunchIntent.push(messageId));
      return;
    }
    this.executePush(PushLanding.resolve(lookedUp, this.currentState(), this.routes), messageId);
  }

  private executePush(result: PushLandingResult, messageId: string): void {
    if (result.decision.kind === GuardDecisionKind.DEFER) {
      // 还要等待：这条推送重新排队，条件满足后再回查。
      this.lastDecision = result.decision;
      this.launchQueue.enqueue(LaunchIntent.push(messageId));
      return;
    }
    if (result.afterLogin !== null) {
      // 未登录：登记「登录后打开 Messages」，不拿这条消息编号回查新登录的账号。
      this.remember(result.afterLogin);
      this.lastDecision = result.decision;
      if (result.decision.route !== null) {
        this.show(new RouteDestination(result.decision.route));
      }
      return;
    }
    this.apply(result.decision, result.request ?? PushLanding.messages());
  }
}
