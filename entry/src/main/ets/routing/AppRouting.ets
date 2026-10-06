import { bundleManager, common, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppConfig, DeepLinkParser, EnvironmentGate, GuardState, LaunchIntent, LaunchQueue, LaunchReadiness,
  MemoryPendingBackend, PendingActionBackend, PendingActionStore, PreferencesPendingBackend, PrivacyState, PushLanding,
  RouteDestination, RouteNavigator, RouteRequest, RouteTable, RouteTargetAllowlist, Router, SessionState,
  UpdateCheckStatus, UpdateState
} from 'core';
import { RouteSpec } from 'generated';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliRouting';

/** 内置升级提示页在 NavPathStack 里的名字（routes.json 没有它的路由名，rule-gaps G03）。 */
export const UPGRADE_PROMPT_PAGE: string = 'CouliUpgradePrompt';

/** NavPathStack 版的 RouteNavigator：只有 Router 往业务页面栈里推页（外部拉起不直接碰 Navigation）。 */
export class NavStackNavigator implements RouteNavigator {
  private stack: NavPathStack | null = null;

  attach(stack: NavPathStack): void {
    this.stack = stack;
  }

  get attached(): boolean {
    return this.stack !== null;
  }

  push(destination: RouteDestination): void {
    if (this.stack === null) {
      return;
    }
    this.stack.pushPathByName(destination.route ?? UPGRADE_PROMPT_PAGE, destination);
  }

  reset(destinations: RouteDestination[]): void {
    if (this.stack === null) {
      return;
    }
    this.stack.clear();
    for (const d of destinations) {
      this.push(d);
    }
  }

  requestConsent(): void {
    // TODO(APP-02b): 弹隐私二次说明；处理完调 AppRouting.shared.router.consentHandled(granted)。
    hilog.info(DOMAIN, TAG, '%{public}s', 'consent requested');
  }
}

/**
 * 守卫状态里由其他任务提供的几项：本任务先用可注入的占位值（与 iOS / Android 同口径）。
 */
export class RoutingPlaceholders {
  // TODO(APP-02b): 接 PrivacyGate 的首启弹窗结论（同意 / 基本模式 / 未决）。
  privacy: PrivacyState = PrivacyState.CONSENTED;
  // TODO(APP-02c): 接强更检查（检查中 / 结果 / 超时按 unknown）。
  update: UpdateCheckStatus = UpdateCheckStatus.finished(UpdateState.OK);
  // TODO(APP-05): 接 Session（游客 / 已登录 / 已绑手机 / 受限会话）。
  session: SessionState = SessionState.GUEST;
  // TODO(APP-05): 接实名结论；未知按未实名（auth=realname 进实名前置）。
  realnameVerified: boolean = false;
  // TODO(APP-03): 接 /v1/config 的 external_hosts 与 bridge_origins；缺省空 = ExternalPage、WebPage 全拒。
  targets: RouteTargetAllowlist = RouteTargetAllowlist.EMPTY;
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
  private backend: PendingActionBackend = new MemoryPendingBackend();
  private routerInstance: Router | null = null;
  private appVersion: string = '';
  private retryTimer: number = -1;

  /** EntryAbility.onCreate 调一次：注册调试路由（仅 Debug / Staging）、pending_action 落 Preferences、读版本号。 */
  start(context: common.Context): void {
    BuildVariant.registerDebugOnlyTable();
    this.backend = new PreferencesPendingBackend(context);
    this.appVersion = AppRouting.readVersionName();
  }

  get router(): Router {
    if (this.routerInstance === null) {
      this.routerInstance = new Router(new PendingActionStore(this.backend), (): GuardState => this.guardState(),
        this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
        (): LaunchReadiness => this.readiness());
    }
    return this.routerInstance;
  }

  /** RootPage 的 NavPathStack 就绪（Navigation 已建好）后调用；之后才恢复 pending_action、放行排队的启动意图。 */
  attachNavigation(stack: NavPathStack): void {
    this.navigator.attach(stack);
    this.stateChanged();
  }

  /**
   * 外部拉起（EntryAbility.onCreate / onNewWant）：只认 want.uri 的深链；解析失败丢弃。
   * 成功的作为启动意图排队，等环境、隐私闸门、强更检查都有结论且导航就绪后交给 Router（03 §4.4 冷启动顺序）。
   * TODO(APP-推送): 推送点击的消息编号由推送 SDK 回调交给 router.openPush，不从 want.parameters 读。
   */
  handleWant(want: Want): void {
    const uri: string | undefined = want.uri;
    if (uri === undefined || uri.length === 0) {
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
   * 推送点击（热启动 / 冷启动的推送 SDK 回调）：Router 记下回查器，强更检查中排队；随后走一次 stateChanged，
   * 确保等待到期定时器已设，检查完成或等满 5 秒时 Router 用记下的回查器继续回查（R2-01）。
   * TODO(APP-推送): 推送 SDK 回调接到这里；回查器由 APP-03 的网络层提供。
   */
  openPush(messageId: string, landing: PushLanding): Promise<void> | null {
    const run: Promise<void> | null = this.router.openPush(messageId, landing);
    this.stateChanged();
    return run;
  }

  /** 切换环境（调试面板）后调用：作废进行中的推送回查、排队的启动意图与 pending_action。 */
  environmentChanged(): void {
    this.router.environmentChanged();
  }

  readiness(): LaunchReadiness {
    return new LaunchReadiness(AppConfig.gate() === EnvironmentGate.SETTLED, this.placeholders.privacy,
      this.placeholders.update);
  }

  /**
   * 守卫状态。强更「检查中」在这里先记为 unknown，只对 App 内用户自己的操作生效；外部请求、pending_action 恢复
   * 与推送回查由 Router 的等待协调器（readiness 源）先等结果，到时 Router 自己换成 unknown（R1-01）。
   */
  guardState(): GuardState {
    const update: UpdateState | null = LaunchQueue.effectiveUpdate(this.placeholders.update, Date.now());
    return new GuardState(this.placeholders.privacy, update ?? UpdateState.UNKNOWN, this.placeholders.session,
      AppConfig.gate() === EnvironmentGate.SETTLED, this.appVersion, BuildVariant.IS_DEBUG_BUILD, false,
      this.placeholders.realnameVerified, this.placeholders.targets);
  }

  /**
   * 状态变化（环境就绪、隐私结论、强更结果、会话变化、导航就绪）后调用；02b、02c、APP-05 接入后由它们调。
   * 先记下闸门通过的时刻（与外壳是否就绪无关，等待计时不因外壳未就绪推迟）；外壳就绪后交给 Router.stateChanged：
   * 冷启动与前置条件变化后恢复持久化的 pending_action（BR-ID-10），再放行排队的启动意图。
   * 强更仍在检查时只设一个到期定时器（满 5 秒按 unknown）；闸门未就绪或不在等待时不设定时器，不空转。
   */
  stateChanged(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const readiness: LaunchReadiness = this.readiness();
    const now: number = Date.now();
    this.router.observeReadiness(readiness, now);
    // TODO(APP-02b): 「Tab 就绪」接入后以它为准；本任务以 Navigation 就绪代替。
    if (this.navigator.attached) {
      this.router.stateChanged(readiness, now);
    }
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
