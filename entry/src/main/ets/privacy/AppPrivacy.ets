import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppConfig, CleanReport, GuardDecision, GuardDecisionKind, parsePrivacyState, PreferencesPrivacyStore, PrivacyDecision,
  PrivacyGate, PrivacyGateState, PrivacyPromptCover, PrivacyPromptStage, PrivacyWithdrawalCleaners, RouteDestination
} from 'core';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { ShellState } from '../shell/ShellState';
import { AppUpdate } from '../update/AppUpdate';

/** 一次结论变化由什么引起（决定是否通知 Router 前置完成 / 丢弃待办）。 */
enum PrivacyEvent {
  NONE,
  AGREED,
  REFUSED
}

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliPrivacy';

/**
 * 包内隐私政策的版本（整数，BR-ID-12）。TODO(N-16)：包内协议副本（BR-ID-11 细则「包内协议副本」）与它的版本号
 * 由法务定稿后随构建导出；在那之前按 1。
 */
export class BundledLegal {
  static readonly PRIVACY_POLICY_VERSION: string = '1';
}

/** routes.json Agreement.type 的取值。 */
export class AgreementType {
  static readonly PRIVACY: string = 'privacy';
  static readonly AGREEMENT: string = 'agreement';
  static readonly SDK_LIST: string = 'sdk_list';
}

/**
 * App 侧的隐私闸门（界面观察的状态 + 把结论接到 Router）。逻辑与持久化全在 Core 的 PrivacyGate。
 *
 * 每次结论可能变化之后（冷启动读出、同意、不同意、仍不同意、开启完整功能、撤回）都走 publish()：
 * 1. 把结论写给 AppRouting（守卫状态与放行条件的隐私来源，替换 APP-02a 的占位）；
 * 2. 调 Router.privacyChanged()（未同意时删除 Agent 卡片来源的 pending_action）；
 * 3. 守卫发起的补同意有了结论时调 Router.consentHandled(granted)；
 * 4. 调 AppRouting.stateChanged()：环境、隐私、强更都就绪且 Tab 外壳已显示时恢复 pending_action、放行启动意图（03 §4.4）。
 * SDK 初始化：环境闸门 SETTLED 且结论为「已同意当前版本」时调 PrivacyGate.onConsented()（冷启动一次、同意后一次；
 * 同一周期内重复调用无副作用）。设备注册要用当前环境的地址，所以等环境闸门。
 */
@ObservedV2
export class AppPrivacy {
  private static instance: AppPrivacy | null = null;

  /**
   * 惰性创建：静态字段初始化发生在 @ObservedV2 装饰类之前，在类体里 new 出来的实例不可观察（实测界面不刷新），
   * 所以第一次取用时再创建（同 CouliFontScale.shared()）。
   */
  static get shared(): AppPrivacy {
    if (AppPrivacy.instance === null) {
      AppPrivacy.instance = new AppPrivacy();
    }
    return AppPrivacy.instance;
  }

  /** 闸门结论（界面据此决定显示启动背景、基本模式还是正常首页）。 */
  @Trace decision: PrivacyDecision = PrivacyDecision.NOT_DECIDED;
  /** 当前要显示的弹窗。 */
  @Trace stage: PrivacyPromptStage = PrivacyPromptStage.NONE;
  /** 弹窗里点了协议链接、协议页盖在弹窗上面：回到打开协议前的宿主页（导航根或强更页等）时恢复显示弹窗（R2-02）。 */
  @Trace promptCovered: boolean = false;
  /** 协议页盖住弹窗时的宿主页记录（promptCovered 的依据）。 */
  private readonly cover: PrivacyPromptCover = new PrivacyPromptCover();
  /** 冷启动已读出本机决定。 */
  @Trace loaded: boolean = false;

  private gate: PrivacyGate | null = null;
  private environmentReady: boolean = false;
  /** 守卫（Router.requestConsent）发起的补同意正在等结论。 */
  private consentRequested: boolean = false;
  /** 这次弹窗是基本模式用户点【开启完整功能】或需同意的功能触发的（仍不同意时丢弃本次登记的待办）。 */
  private repromptFromBasic: boolean = false;

  /** 弹窗正在显示（没有被协议页盖住）：返回键不响应（BR-ID-11）。 */
  get blocksBack(): boolean {
    return this.stage !== PrivacyPromptStage.NONE && !this.promptCovered;
  }

  get isPrompting(): boolean {
    return this.stage !== PrivacyPromptStage.NONE;
  }

  /**
   * EntryAbility.onCreate 调：读本机决定、冷启动判定是否弹首启弹窗、重试未完成的撤回写入与清理。
   * 同一进程里 Ability 重建时复用已有的 Gate（R1-01）：没落盘的撤回写入只记在 Gate 内存里，新建 Gate 会丢掉重试状态；
   * coldStart 会先重试写入再判定。
   */
  start(context: common.Context): void {
    const gate: PrivacyGate = this.gate ?? AppPrivacy.createGate(context);
    gate.coldStart(Date.now());
    gate.retryPendingWithdrawalCleanup();
    this.gate = gate;
    const routing: AppRouting = AppRouting.shared;
    routing.navigator.onConsentRequested = () => {
      this.consentRequested = true;
      this.requestFullFunction();
    };
    routing.navigator.tabRootHandler = (destination: RouteDestination): boolean =>
      ShellState.shared.showRoot(destination);
    routing.privacyPromptShowing = (): boolean => this.isPrompting;
    // 埋点批次的隐私世代（撤回同意加 1，lessons 16）：在第一次 publish 创建埋点队列之前接上。
    AppClientCore.shared.consentCycle = (): number => this.consentCycle();
    this.publish(PrivacyEvent.NONE);
  }

  private static createGate(context: common.Context): PrivacyGate {
    const gate: PrivacyGate = new PrivacyGate(new PreferencesPrivacyStore(context), (): number => Date.now(),
      BundledLegal.PRIVACY_POLICY_VERSION);
    // 撤回同意：只跑令牌与设备身份的清理项（APP-01 清理器注册表里的占位，BR-ID-13）。全部成功才清除撤回痕迹；
    // 失败则痕迹保留，下次冷启动重试，痕迹在时 gate.credentialsReadable() 为 false，会话层不得读凭据（TODO(APP-05)）。
    gate.withdrawalCleanup = (): void => {
      PrivacyWithdrawalCleaners.run(AppConfig.cleaners).then((report: CleanReport) => {
        hilog.info(DOMAIN, TAG, 'withdrawal cleanup ok=%{public}s failed=%{public}s', String(report.ok),
          report.failed.join(','));
        if (report.ok) {
          gate.withdrawalCleanupDone();
          // 撤回清理（含埋点队列）确认完成：埋点按当前结论恢复（之前一律按未同意，R1-06）。
          AppClientCore.shared.privacyChanged(AppRouting.shared.privacyState, gate.credentialsReadable());
        }
      });
    };
    gate.registerSdkInitSteps();
    // 设备注册（APP-03b）：DeviceRegistry.register 是异步的，PrivacyGate 按 1s、2s、4s…上限 60s 退避重试到成功。
    gate.registerDeviceRegistration((): Promise<boolean> => AppNetwork.registerDevice());
    return gate;
  }

  /**
   * 重新开始设备注册（DeviceRegistry.onRestartNeeded）：immediate = false 是 10402 后重新注册失败（交给退避流程）；
   * true 是运行中切换环境完成（新环境已提交，立即开始，R1-02）。
   */
  restartDeviceRegistration(immediate: boolean): void {
    const gate: PrivacyGate | null = this.gate;
    if (gate !== null) {
      gate.restartDeviceRegistration(immediate);
    }
  }

  /** 回前台：上次撤回同意的清理没确认完成（如埋点队列删除失败）就再跑一次（R1-06）。 */
  retryWithdrawalCleanup(): void {
    const gate: PrivacyGate | null = this.gate;
    if (gate !== null) {
      gate.retryPendingWithdrawalCleanup();
    }
  }

  /** 隐私世代（PrivacyGate.consentCycle：撤回同意加 1）：设备注册与埋点上报的 ticket 用（lessons 12、16）。 */
  consentCycle(): number {
    return this.gate === null ? 0 : this.gate.consentCycle;
  }

  /** 会话层读取令牌、device_id、install_secret 前必须确认（撤回清理未完成时为 false）。TODO(APP-05) 接入。 */
  credentialsReadable(): boolean {
    return this.gate !== null && this.gate.credentialsReadable();
  }

  /**
   * 环境闸门 SETTLED（EntryAbility.loadRoot、阻断页重试成功后）：配置冷启动（读 LKG、后台拉 /v1/config，APP-03b），
   * 已同意当前版本时开始初始化。
   */
  environmentSettled(): void {
    this.environmentReady = true;
    AppClientCore.shared.environmentSettled();
    this.initializeIfConsented();
    AppRouting.shared.stateChanged();
  }

  /** 弹窗里点【同意】：记为完成一个前置步骤（Router.consentHandled(true) → 重置计时；就绪后进下一个前置页或恢复待办）。 */
  agree(): void {
    this.withGate((gate: PrivacyGate) => gate.agree(gate.now()), PrivacyEvent.AGREED);
    this.initializeIfConsented();
  }

  disagree(): void {
    this.withGate((gate: PrivacyGate) => gate.disagree(gate.now()), PrivacyEvent.NONE);
  }

  stillDisagree(): void {
    this.withGate((gate: PrivacyGate) => gate.stillDisagree(gate.now()), PrivacyEvent.REFUSED);
  }

  /** 基本模式页【开启完整功能】、需同意的功能（含基本模式下点 AI 助手 / 订单 / 我的 Tab）。 */
  requestFullFunction(): void {
    if (this.decision === PrivacyDecision.BASIC_MODE) {
      this.repromptFromBasic = true;
    }
    this.withGate((gate: PrivacyGate) => gate.requestFullFunction(gate.now()), PrivacyEvent.NONE);
  }

  /**
   * 撤回同意（BR-ID-13）：清本地令牌、device_id、install_secret 后进入基本模式。撤回清掉了本地令牌，等同退出登录：
   * 按 BR-ID-10 清除 pending_action、作废进行中的推送回查。隐私中心页面与服务端撤回记录在 APP-12（TODO(APP-12)）。
   *
   * 返回撤回是否已可靠落盘（R1-01）。false = 撤回失败，调用方（APP-12 隐私中心）必须提示用户撤回没有生效、稍后重试；
   * 此时内存里已按基本模式运行（不初始化、凭据不可读），PrivacyGate 在每次冷启动与读取凭据前重试写入。
   */
  withdraw(): boolean {
    const gate: PrivacyGate | null = this.gate;
    if (gate === null) {
      return false;
    }
    const saved: boolean = gate.withdraw(gate.now());
    if (!saved) {
      hilog.error(DOMAIN, TAG, '%{public}s', 'withdraw not persisted; running in basic mode, will retry');
    }
    AppRouting.shared.router.sessionEnded();
    this.publish(PrivacyEvent.NONE);
    return saved;
  }

  /**
   * 弹窗里的协议链接：经 Router 打开 Agreement（未决时只读放行）；打开了就暂时让出弹窗，回到导航根时恢复。
   * 强更（below_min）背景上的隐私弹窗（F-ALL-06）：弹窗盖在强更页上，协议链接按「从强更页进入」的次要入口判定
   * （强更状态下守卫只放行 PrivacyCenter / Agreement / Login / DeleteAccount），否则守卫给出 ForceUpdate、协议页打不开。
   * 标记只在这里（App 内、用户点弹窗里的协议链接）带上，只对 Agreement 生效；返回后弹窗与强更页都还在。
   */
  openAgreement(type: string): void {
    const params: Record<string, Object> = {};
    params['type'] = type;
    const routing: AppRouting = AppRouting.shared;
    // 打开前的栈深就是宿主页的位置（导航根 0；强更页上为 1）：返回到它（或更低、栈被重建）时恢复弹窗。
    const hostDepth: number = routing.navigator.pathNames().length;
    const decision: GuardDecision = AppUpdate.shared.belowMin ? routing.openFromForceUpdatePage('Agreement', params)
      : routing.openInApp('Agreement', params);
    if (decision.kind === GuardDecisionKind.OPEN || decision.kind === GuardDecisionKind.OPEN_READONLY) {
      this.cover.cover(hostDepth, decision.route ?? 'Agreement');
      this.promptCovered = true;
    }
  }

  /**
   * 有页面显示（RootPage 的 NavPathStack didShow，目标是导航根或任意 NavDestination）：协议页已离开（回到宿主页，
   * 含强更页这类 NavDestination；或栈被清空重建）→ 弹窗恢复显示（R2-02）。
   */
  navigationShown(stack: string[]): void {
    if (this.cover.shown(stack)) {
      this.promptCovered = false;
    }
  }

  /** Android / 鸿蒙二次说明的【退出 App】（BR-ID-11）：不记为同意或拒绝，下次冷启动重新弹首启弹窗。 */
  exitApp(context: common.UIAbilityContext | undefined): void {
    if (context === undefined) {
      return;
    }
    context.terminateSelf().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}s', e.message);
    });
  }

  private withGate(action: (gate: PrivacyGate) => void, event: PrivacyEvent): void {
    const gate: PrivacyGate | null = this.gate;
    if (gate === null) {
      return;
    }
    action(gate);
    this.publish(event);
  }

  private initializeIfConsented(): void {
    const gate: PrivacyGate | null = this.gate;
    if (gate === null || !this.environmentReady) {
      return;
    }
    gate.onConsented(gate.now());
  }

  private publish(event: PrivacyEvent): void {
    const gate: PrivacyGate | null = this.gate;
    if (gate === null) {
      return;
    }
    const state: PrivacyGateState = gate.state(gate.now());
    const wasLoaded: boolean = this.loaded;
    const previous: PrivacyDecision = this.decision;
    this.decision = state.decision;
    this.stage = state.promptStage;
    if (!state.mustPrompt) {
      this.cover.reset();
      this.promptCovered = false;
    }
    this.loaded = true;
    const routing: AppRouting = AppRouting.shared;
    routing.privacyState = parsePrivacyState(state.decisionRaw);
    // 埋点（APP-03b）：第一次按读出的结论创建队列；之后不是已同意（撤回、基本模式）立即清空队列、不再上报。
    AppClientCore.shared.privacyChanged(routing.privacyState, gate.credentialsReadable());
    // 先按新结论同步版本检查（APP-02c R1-01 / R1-03）：进入基本模式按 unknown（保留已知 below_min）；同意（含离开基本模式）
    // 后立即发检查、Router 读到「检查中」。必须在 consentHandled 与任何待办恢复之前：恢复因此等检查结果（最长 5 秒），
    // 不会被同意那一刻的 unknown 判定删除。
    routing.syncUpdateCheck();
    // 每次结论（可能）变化都通知 Router（未同意时删除 Agent 卡片来源的待办）。
    routing.router.privacyChanged();
    if (wasLoaded && state.decision !== previous && state.decision !== PrivacyDecision.NOT_DECIDED) {
      // 结论变了（进入基本模式：首启仍不同意、升级后仍不同意、撤回同意；或基本模式 → 同意）：清空导航栈、
      // 经 Router 重新打开首页 Tab，首页的只读标记随新结论（基本模式页只读）。在恢复待办之前做，待办可再切到别的 Tab。
      routing.openInApp('Home');
    }
    if (event === PrivacyEvent.AGREED) {
      // 用户主动同意 = 完成一个前置步骤：立即重置计时；实际恢复（进下一个前置页或执行原路由，BR-ID-10）由 Router 统一
      // 等环境、隐私、强更结果（或满 5 秒）与 Navigation / Tab 就绪后在 stateChanged 里做（R1-02），不在这里直接执行。
      routing.router.consentHandled(true);
      this.consentRequested = false;
      this.repromptFromBasic = false;
    } else if (event === PrivacyEvent.REFUSED) {
      if (this.consentRequested || this.repromptFromBasic) {
        // 基本模式下再次不同意 / 守卫发起的补同意被拒：丢弃本次登记的待办。
        routing.router.consentHandled(false);
      }
      this.consentRequested = false;
      this.repromptFromBasic = false;
    }
    routing.stateChanged();
  }
}
