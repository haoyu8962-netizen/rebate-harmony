import { bundleManager, common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppConfig, DeepLinkParser, EnvironmentGate, GuardDecision, GuardDecisionKind, GuardState, LaunchIntent, LaunchQueue,
  LaunchReadiness, MemoryPendingBackend, PendingActionBackend, PendingActionStore, PreferencesPendingBackend,
  PrivacyState, PushLanding, RouteDestination, RouteRequest, RouteSource, RouteTable,
  RouteTargetAllowlist, Router, RoutingSync, SessionState, StackNavigator, PathStack,
  UPGRADE_PROMPT_PAGE as CORE_UPGRADE_PROMPT_PAGE, UpdateState
} from 'core';
import { RouteSpec } from 'generated';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppUpdate } from '../update/AppUpdate';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliRouting';

/** 内置升级提示页在 NavPathStack 里的名字（routes.json 没有它的路由名，rule-gaps G03；常量在 Core）。 */
export const UPGRADE_PROMPT_PAGE: string = CORE_UPGRADE_PROMPT_PAGE;

/** NavPathStack 适配成 Core 的 PathStack（ArkTS 不做结构类型匹配，逐个方法转交）。 */
class NavPathStackAdapter implements PathStack {
  private readonly stack: NavPathStack;

  constructor(stack: NavPathStack) {
    this.stack = stack;
  }

  pushPathByName(name: string, param: Object): void {
    this.stack.pushPathByName(name, param);
  }

  clear(): void {
    this.stack.clear();
  }

  removeByName(name: string): void {
    this.stack.removeByName(name);
  }

  getAllPathName(): string[] {
    return this.stack.getAllPathName();
  }
}

/**
 * NavPathStack 版的 RouteNavigator：逻辑在 Core StackNavigator（登录集成测试用同一份代码，APP-05a R1-02）；这里只把
 * NavPathStack 接上。只有 Router 往业务页面栈里推页（外部拉起不直接碰 Navigation）。
 */
export class NavStackNavigator extends StackNavigator {
  attach(stack: NavPathStack): void {
    this.attachStack(new NavPathStackAdapter(stack));
  }

  requestConsent(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'consent requested');
    super.requestConsent();
  }
}

/**
 * 守卫状态里由其他任务提供的几项：本任务先用可注入的占位值（与 iOS / Android 同口径）。
 */
export class RoutingPlaceholders {
  // 强更检查已接 AppUpdate（APP-02c）：readiness() / guardState() 读 AppUpdate.shared.routerStatus()。
  // 会话（APP-05a）：EntryAbility 接上 AppLogin.sessionState（游客 / 已绑手机 / 受限会话，按 ApiClient 的有效会话现算）。
  session: () => SessionState = () => SessionState.GUEST;
  // TODO(APP-05): 接实名结论；未知按未实名（auth=realname 进实名前置）。
  realnameVerified: boolean = false;
  /**
   * ExternalPage / WebPage 的目标白名单（APP-04 起由 AppBridge.routeTargets 接 /v1/config：external_hosts 与
   * 验签通过的 bridge_origins）；缺省空 = 深链进 ExternalPage、任何来源进 WebPage 全拒。
   */
  targets: () => RouteTargetAllowlist = () => RouteTargetAllowlist.EMPTY;
}

/**
 * App 侧的 Router 接线（APP-02a 最小外壳）：本构建的路由表、守卫状态源、深链入站配置、启动排队的定时。
 * 外部拉起（冷启动 / 热启动的 want）只取 want.uri 交给 DeepLinkParser；want 里的其他参数一律不看，
 * 也不能让 Navigation 直接打开页面——页面只由 Router 按 EntryGuard 的结论推入。
 */
export class AppRouting {
  static readonly shared: AppRouting = new AppRouting();

  readonly placeholders: RoutingPlaceholders = new RoutingPlaceholders();
  readonly navigator: NavStackNavigator = new NavStackNavigator();
  /**
   * 隐私闸门的结论（APP-02b：AppPrivacy 每次结论变化时写入，替换 APP-02a 的占位）。闸门在冷启动读出决定之前按未决：
   * 守卫等待、不放行任何启动意图。
   */
  privacyState: PrivacyState = PrivacyState.NOT_DECIDED;
  /** Tab 外壳已显示（03 §4.4「Tab 就绪」）：AppShell 出现时为 true、消失时为 false。 */
  private shellReady: boolean = false;
  private backend: PendingActionBackend = new MemoryPendingBackend();
  private routerInstance: Router | null = null;
  private appVersion: string = '';
  private retryTimer: number = -1;

  /**
   * 按当前隐私结论与环境闸门同步版本检查（EntryAbility 接上 AppUpdate.syncPrivacy）：基本模式按 unknown（保留已知
   * below_min）；冷启动或离开基本模式后能查了就立即发检查，Router 随即读到「检查中」（03 §4.4 冷启动顺序：隐私闸门 →
   * 强更检查）。stateChanged 开头调一次；AppPrivacy.publish 写入隐私结论后、consentHandled 与任何待办恢复之前也调（R1-01）。
   */
  syncUpdateCheck: () => void = () => {
  };
  /**
   * 会话的 phone_bound 没查清时补查（APP-05b R2-01：冷启动未知按未验证，AppLogin.ensurePhoneBindingKnown）。stateChanged 开头
   * 调一次；查清后由登录模块再触发一次 stateChanged。缺省什么都不做。
   */
  syncSession: () => void = () => {
  };

  /** EntryAbility.onCreate 调一次：注册调试路由（仅 Debug / Staging）、pending_action 落 Preferences、读版本号。 */
  start(context: common.Context): void {
    BuildVariant.registerDebugOnlyTable();
    this.backend = new PreferencesPendingBackend(context);
    this.navigator.homeReadonly = (): boolean => {
      const last: GuardDecision | null = this.routerInstance === null ? null : this.routerInstance.lastDecision;
      if (last !== null && last.route === 'Home') {
        return last.kind === GuardDecisionKind.OPEN_READONLY;
      }
      return this.privacyState === PrivacyState.BASIC_MODE;
    };
    this.appVersion = AppRouting.readVersionName();
  }

  get router(): Router {
    if (this.routerInstance === null) {
      this.routerInstance = new Router(new PendingActionStore(this.backend), (): GuardState => this.guardState(),
        // APP-13a 编排者补充 G01：路由可用性统一经 BuildVariant.routeSpec（Release 原样取 RouteTable；Debug / Staging 的覆盖开关只在
        // src/staging 编译）。
        this.navigator, (name: string): RouteSpec | undefined => BuildVariant.routeSpec(name),
        (): LaunchReadiness => this.readiness());
      // 03 §4.4「Tab 就绪」交给 Router 统一判定（R1-02 / R1-03）：同意回调与前置完成的恢复、冷启动推送的回查、
      // 外部请求与启动队列的放行，都要等导航栈已交给 Router 且 Tab 外壳已显示。
      this.routerInstance.presentationReady = (): boolean => this.presentationReady;
      // APP-09（AC-S1-81 ⑫）：资金与实名页面丢弃路由参数时的埋点（AppWallet 接 route_params_dropped）。
      this.routerInstance.onParamsDropped = (route: string, count: number): void => this.paramsDropped(route, count);
    }
    return this.routerInstance;
  }

  private syncInstance: RoutingSync | null = null;

  /** 状态变化后的路由同步（Core RoutingSync）。 */
  get sync(): RoutingSync {
    if (this.syncInstance === null) {
      this.syncInstance = new RoutingSync(this.router, this.navigator, (): boolean => this.presentationReady);
    }
    return this.syncInstance;
  }

  /** Navigation 已挂载（导航栈交给 Router）且 Tab 外壳已显示。 */
  get presentationReady(): boolean {
    return this.navigator.attached && this.shellReady;
  }

  /** RootPage 的 NavPathStack 就绪（Navigation 已建好）后调用；之后才恢复 pending_action、放行排队的启动意图。 */
  attachNavigation(stack: NavPathStack): void {
    this.navigator.attach(stack);
    this.stateChanged();
  }

  /** Tab 外壳出现 / 消失（AppShell 调）。出现后才恢复 pending_action、放行排队的启动意图。 */
  setShellReady(ready: boolean): void {
    if (this.shellReady === ready) {
      return;
    }
    this.shellReady = ready;
    if (ready) {
      this.stateChanged();
    }
  }

  /** 本端版本号（app.json5 的 versionName）。 */
  get appVersionName(): string {
    return this.appVersion;
  }

  /** App 内用户自己的操作打开一个路由（经 Router + EntryGuard，不直接碰 Navigation）。 */
  openInApp(route: string, params?: Record<string, Object>): GuardDecision {
    return this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
  }

  /**
   * 商品回流意图（BR-ATTR-29 ②(a)；APP-04 R1-08）：ExternalWebView 取消了去往商品页的导航，交来去掉 # 之后的地址。
   * 返回 true 表示已接手（识别并打开原生 ProductDetail，压在容器之上）；false 表示现在处理不了，容器给出
   * external_page.product_unresolved 的失败提示，原页面不动。
   * TODO(APP-08)：POST /v1/inputs/parse 识别出 platform 与 product_key 后，经 openInApp('ProductDetail', …) 打开；在此之前
   * 拿不到 ProductDetail 的必填参数，一律按处理不了返回 false（不打开占位详情、不加载平台页面）。
   */
  productIntent(_urlWithoutFragment: string): boolean {
    return false;
  }

  /**
   * 强更页上用户自己点的次要入口（03 §4.1）：带「从强更页进入」标记经 EntryGuard 判定，强更状态下只放行
   * PrivacyCenter、Agreement、Login、DeleteAccount（其余回强更页）。打开的页面压在强更页之上，返回回到强更页。
   */
  openFromForceUpdatePage(route: string, params?: Record<string, Object>): GuardDecision {
    return this.router.openWith(RouteRequest.of(route, RouteSource.IN_APP, params), this.guardState(true));
  }

  /** 当前会话（强更页【注销账号】据此决定先进登录页还是注销页）。 */
  get sessionState(): SessionState {
    return this.placeholders.session();
  }

  /**
   * 隐私弹窗正在显示（AppPrivacy.start 接上）。运行中弹窗显示时新收到的深链与推送丢弃（03 §4.4「热启动时停在首启弹窗」）；
   * 冷启动带来的照常排队等闸门结论。
   */
  privacyPromptShowing: () => boolean = () => false;

  /**
   * 外部拉起（EntryAbility.onCreate / onNewWant）：只认 want.uri 的深链；解析失败丢弃。
   * 成功的作为启动意图排队，等环境、隐私闸门、强更检查都有结论且导航就绪后交给 Router（03 §4.4 冷启动顺序）。
   * TODO(APP-推送): 推送点击的消息编号由推送 SDK 回调交给 router.openPush，不从 want.parameters 读。
   */
  handleWant(want: Want, hot: boolean = false): void {
    const uri: string | undefined = want.uri;
    if (uri === undefined || uri.length === 0) {
      return;
    }
    if (hot && this.privacyPromptShowing()) {
      hilog.info(DOMAIN, TAG, '%{public}s', 'deep link dropped: privacy prompt showing');
      return;
    }
    const request: RouteRequest | null = DeepLinkParser.parse(uri, BuildVariant.deepLinkConfig());
    if (request === null) {
      hilog.info(DOMAIN, TAG, '%{public}s', 'deep link ignored');
      return;
    }
    this.router.enqueueLaunch(LaunchIntent.route(request));
    this.stateChanged();
  }

  /**
   * 推送点击（热启动 / 冷启动的推送 SDK 回调）：Router 记下回查器；强更检查中、或 Navigation / Tab 外壳未就绪（冷启动，
   * R1-03）时不回查，消息编号留在启动队列。随后走一次 stateChanged：确保等待到期定时器已设；检查完成或等满 5 秒、
   * 且外壳就绪（setShellReady(true) 也会调 stateChanged）时 Router 用记下的回查器回查并执行（R2-01）。
   * TODO(APP-推送): 推送 SDK 回调接到这里；回查器由 APP-03 的网络层提供。
   */
  openPush(messageId: string, landing: PushLanding, hot: boolean = true): Promise<void> | null {
    if (hot && this.privacyPromptShowing()) {
      // 运行中首启弹窗显示时新到的推送点击丢弃（03 §4.4）。
      hilog.info(DOMAIN, TAG, '%{public}s', 'push dropped: privacy prompt showing');
      return null;
    }
    const run: Promise<void> | null = this.router.openPush(messageId, landing);
    this.stateChanged();
    return run;
  }

  /** 切换环境（调试面板）后调用：作废进行中的推送回查、排队的启动意图与 pending_action。 */
  environmentChanged(): void {
    this.router.environmentChanged();
  }

  readiness(): LaunchReadiness {
    return new LaunchReadiness(AppConfig.gate() === EnvironmentGate.SETTLED, this.privacyState,
      AppUpdate.shared.routerStatus());
  }

  /**
   * 守卫状态。强更「检查中」时这里给 App 内用户自己的操作用的结论（不等待）：冷启动还没有结论为 unknown，回前台复查中
   * 保留本进程已知结论（03 §4.1「检查请求失败不拦截用户在原生页面上自己的操作」）；外部请求、pending_action 恢复与
   * 推送回查由 Router 的等待协调器（readiness 源，检查在途即 checking，R1-02）先等结果，到时 Router 自己换成 unknown。
   */
  guardState(fromForceUpdatePage: boolean = false): GuardState {
    const update: UpdateState | null = LaunchQueue.effectiveUpdate(AppUpdate.shared.routerStatus(), Date.now());
    return new GuardState(this.privacyState, update ?? AppUpdate.shared.inAppUpdate(), this.placeholders.session(),
      AppConfig.gate() === EnvironmentGate.SETTLED, this.appVersion, BuildVariant.IS_DEBUG_BUILD, fromForceUpdatePage,
      this.placeholders.realnameVerified, this.placeholders.targets());
  }

  /**
   * 状态变化（环境就绪、隐私结论、强更结果、会话变化、导航与 Tab 外壳就绪）后调用；02b 已接隐私，02c、APP-05 接入后由它们调。
   * 先记下闸门通过的时刻（与外壳是否就绪无关，等待计时不因外壳未就绪推迟）；外壳就绪后交给 Router.stateChanged：
   * 冷启动与前置条件变化后恢复持久化的 pending_action（BR-ID-10），再放行排队的启动意图。
   * 强更仍在检查时只设一个到期定时器（满 5 秒按 unknown）；闸门未就绪或不在等待时不设定时器，不空转。
   * resumePending = false：只同步状态、不恢复 pending_action（已作废的登录尝试通知会话变化时用，APP-05a R2-02）。
   */
  /** 每次状态同步之后调用（AppSearch 接页面恢复）；缺省什么都不做。 */
  afterSync: () => void = () => {
  };
  /** 每次状态同步之后调用（APP-07 剪贴板识别：隐私、会话、环境变化时作废提示与在途请求）；缺省什么都不做。 */
  syncClipboard: () => void = () => {
  };
  /** 每次状态同步之后调用（APP-08 订单：会话、隐私、环境变化时作废列表与待跟单卡、换账号删订单缓存）；缺省什么都不做。 */
  syncOrders: () => void = () => {
  };
  /** 资金与实名页面丢弃了路由参数（APP-09：AppWallet 记 route_params_dropped）；缺省什么都不做。 */
  paramsDropped: (route: string, count: number) => void = (_r: string, _n: number) => {
  };
  /** 每次状态同步之后调用（APP-09 钱包：会话、隐私、环境变化时清空钱包类页面与 step_up_token、换账号删钱包缓存）；缺省什么都不做。 */
  syncWallet: () => void = () => {
  };
  /** 每次状态同步之后调用（APP-12「我的」：会话、隐私、环境变化时清空「我的」类页面、推送上报按会话换代结算）；缺省什么都不做。 */
  syncMe: () => void = () => {
  };
  /** 每次状态同步之后调用（APP-11 首页：会话、隐私、环境变化时作废首页控制器并按新身份重建、清旧账号作用域的 LKG）；缺省什么都不做。 */
  syncHome: () => void = () => {
  };
  /** 每次状态同步之后调用（APP-10 Agent：会话、隐私、环境、AI 同意变化时在同步出口作废 Agent 控制器并按新身份重建）；缺省什么都不做。 */
  syncAgent: () => void = () => {
  };
  /** 每次状态同步之后调用（APP-13a 账号页：会话、作用域、隐私、环境变化时作废注销页与换号子页并按新身份重建）；缺省什么都不做。 */
  syncAccount: () => void = () => {
  };

  stateChanged(resumePending: boolean = true): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.syncUpdateCheck();
    this.syncSession();
    const readiness: LaunchReadiness = this.readiness();
    const now: number = Date.now();
    // Router 部分与强更页同步在 Core RoutingSync（登录集成测试用同一份代码，APP-05a R1-01 / R1-02）：
    // 03 §4.4 闸门全部就绪且外壳就绪后才恢复 pending_action、放行启动意图；below_min 时强更页与结论同步。
    this.sync.sync(readiness, now, resumePending);
    // 进程回收后的页面恢复（FU-HM-1112 共性第 28 条）：同样等闸门与本轮版本检查，由 PageRestorer 判定。
    this.afterSync();
    this.syncClipboard();
    this.syncOrders();
    this.syncWallet();
    this.syncMe();
    this.syncHome();
    this.syncAgent();
    this.syncAccount();
    const deadline: number | null = this.router.updateWaitDeadline(readiness, now);
    if (deadline === null) {
      return;
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.stateChanged();
    }, Math.max(deadline - now, 0));
  }

  /** app.json5 的 versionName（1.0.0），与 routes.json since.harmony 比较；读不到时为空串（守卫按版本过低处理）。 */
  private static readVersionName(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'read versionName failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }
}
