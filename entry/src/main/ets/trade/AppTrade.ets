import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, AuthManageController, AuthSheetCounter, ConfigStore,
  ConsentResume,
  HelpLink, JumpTipService, LinkJumpSink, OpenPurchaseController, PlatformPurchase, PlatformStatusOverrides,
  PURCHASE_PENDING_ACTION, PurchaseDeps, PurchaseEnv, PurchasePending, SearchApiPort, TradeJson, TradeJumpExecutor,
  TransportFailure, UnavailableBaichuan
} from 'core';
import {
  ClientEvents, ClientEvent, EventLinkJumpInstalled, EventLinkJumpPhase, EventLinkJumpResult, EventLinkJumpStep,
  EventLinkJumpUnionPlatform
} from 'generated';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { HarmonyJumpPorts } from './HarmonyJumpPorts';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliTrade';
/** link_jump 公共字段 page：购买从详情或搜索结果发起都记 ProductDetail（events.yaml 未规定，rule-gaps A14 同口径）。 */
const LINK_JUMP_PAGE: string = 'ProductDetail';

/** 网络组合之前的端口：一律当网络失败（不发任何请求）。 */
class UnavailableTradePort implements SearchApiPort {
  request(_request: ApiRequest): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
      null, null));
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

/** 每次现取网络端口（网络组合在 EntryAbility.onCreate 之后才有）。 */
class LiveTradePort implements SearchApiPort {
  private port(): SearchApiPort {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? new UnavailableTradePort() : new ApiClientSearchPort(client);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.port().request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.port().cancelOwned(owner);
  }
}

/** link_jump → Tracker 本地队列（业务代码只能调生成函数，03 §4.7；上报 sink 仍为 TODO(N-20)）。字段不在枚举里的不上报。 */
class TrackerLinkJumpSink implements LinkJumpSink {
  report(fields: Record<string, Object>): void {
    const phase: EventLinkJumpPhase | null = TrackerLinkJumpSink.phase(TradeJson.text(fields, 'phase'));
    const platform: EventLinkJumpUnionPlatform | null =
      TrackerLinkJumpSink.platform(TradeJson.text(fields, 'union_platform'));
    const step: EventLinkJumpStep | null = TrackerLinkJumpSink.step(TradeJson.text(fields, 'step'));
    const result: EventLinkJumpResult | null = TrackerLinkJumpSink.result(TradeJson.text(fields, 'result'));
    if (phase === null || platform === null || step === null || result === null) {
      return;
    }
    const installed: EventLinkJumpInstalled | null = TrackerLinkJumpSink.installed(TradeJson.text(fields, 'installed'));
    try {
      const event: ClientEvent = ClientEvents.linkJump(LINK_JUMP_PAGE, phase, platform, step, result,
        TradeJson.text(fields, 'attempt_id'), TradeJson.text(fields, 'link_id'), TradeJson.fen(fields, 'duration_ms'),
        installed);
      AppClientCore.shared.track(event);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '%{public}s', 'link_jump rejected by generator');
    }
  }

  private static phase(raw: string | null): EventLinkJumpPhase | null {
    return raw === 'purchase' ? EventLinkJumpPhase.PURCHASE : (raw === 'startup' ? EventLinkJumpPhase.STARTUP : null);
  }

  private static platform(raw: string | null): EventLinkJumpUnionPlatform | null {
    switch (raw) {
      case 'taobao':
        return EventLinkJumpUnionPlatform.TAOBAO;
      case 'jd':
        return EventLinkJumpUnionPlatform.JD;
      case 'pdd':
        return EventLinkJumpUnionPlatform.PDD;
      case 'meituan':
        return EventLinkJumpUnionPlatform.MEITUAN;
      case 'vip':
        return EventLinkJumpUnionPlatform.VIP;
      case 'douyin':
        return EventLinkJumpUnionPlatform.DOUYIN;
      case 'eleme':
        return EventLinkJumpUnionPlatform.ELEME;
      case 'kuaishou':
        return EventLinkJumpUnionPlatform.KUAISHOU;
      case 'suning':
        return EventLinkJumpUnionPlatform.SUNING;
      default:
        return null;
    }
  }

  private static step(raw: string | null): EventLinkJumpStep | null {
    switch (raw) {
      case 'sdk':
        return EventLinkJumpStep.SDK;
      case 'scheme':
        return EventLinkJumpStep.SCHEME;
      case 'universal_link':
        return EventLinkJumpStep.UNIVERSAL_LINK;
      case 'h5':
        return EventLinkJumpStep.H5;
      case 'copy_tpwd':
        return EventLinkJumpStep.COPY_TPWD;
      default:
        return null;
    }
  }

  private static result(raw: string | null): EventLinkJumpResult | null {
    switch (raw) {
      case 'launched':
        return EventLinkJumpResult.LAUNCHED;
      case 'failed':
        return EventLinkJumpResult.FAILED;
      case 'sdk_init_failed':
        return EventLinkJumpResult.SDK_INIT_FAILED;
      case 'copied':
        return EventLinkJumpResult.COPIED;
      default:
        return null;
    }
  }

  private static installed(raw: string | null): EventLinkJumpInstalled | null {
    return raw === 'true' ? EventLinkJumpInstalled.TRUE
      : (raw === 'false' ? EventLinkJumpInstalled.FALSE : (raw === 'unknown' ? EventLinkJumpInstalled.UNKNOWN : null));
  }
}

/** 购买 pending_action：Router 的同一份本地记录（BR-ID-10：只存 1 条、10 分钟、完成一步重新计时、退出登录清除）。 */
class RouterPurchasePending implements PurchasePending {
  register(params: Record<string, Object>): boolean {
    return AppRouting.shared.router.registerAction(PURCHASE_PENDING_ACTION, params);
  }

  peek(): Record<string, Object> | null {
    return AppRouting.shared.router.pendingAction(PURCHASE_PENDING_ACTION);
  }

  stepDone(): void {
    AppRouting.shared.router.markActionStepDone(PURCHASE_PENDING_ACTION);
  }

  clear(): void {
    AppRouting.shared.router.clearAction(PURCHASE_PENDING_ACTION);
  }
}

/** 一个活着的发起页执行器与它的页面可见状态。 */
class LiveController {
  readonly controller: OpenPurchaseController;
  visible: boolean = true;

  constructor(controller: OpenPurchaseController) {
    this.controller = controller;
  }
}

/**
 * App 侧的购买、外跳与授权接线（APP-06b）：
 * - 每个发起页（商品详情、搜索结果）一份 OpenPurchaseController，共用本进程的百川适配层、外跳执行器、AuthSheet 计数、JumpTip 已读与
 *   购买 pending_action（Router 的同一份本地记录）；
 * - link_jump 经 Tracker 本地队列（ClientEvents 生成函数；上报 sink 仍为 TODO(N-20)）；
 * - 登录完成后：登记了购买待办的发起页回到前台时自动执行一次 open（页面 onShown → resumeAfterLogin，BR-ID-10）；
 * - 基本模式下点购买：登记待办后弹补同意；同意会清栈回首页（AppPrivacy 结论变化），这时重开那件商品的详情并自动执行一次购买（H01）；
 * - 平台购买状态：点击结果确认的 50301（overrides，新配置到达前有效，共性第 5、6 条）优先，其次 features.platform_status。
 */
export class AppTrade {
  static readonly shared: AppTrade = new AppTrade();
  readonly ports: HarmonyJumpPorts = new HarmonyJumpPorts();
  readonly baichuan: UnavailableBaichuan = new UnavailableBaichuan();
  readonly counter: AuthSheetCounter = new AuthSheetCounter();
  readonly sink: LinkJumpSink = new TrackerLinkJumpSink();
  readonly api: SearchApiPort = new LiveTradePort();
  readonly executor: TradeJumpExecutor = new TradeJumpExecutor(this.ports, this.baichuan, this.sink);
  readonly pending: PurchasePending = new RouterPurchasePending();
  readonly tips: JumpTipService = new JumpTipService(this.api, (): string | null => AppTrade.sessionKey());
  readonly overrides: PlatformStatusOverrides = new PlatformStatusOverrides(
    (): number => AppTrade.store()?.issuedFetchId ?? 0, (): number => AppTrade.store()?.appliedFetchId ?? 0);
  private live: LiveController[] = [];
  /** 授权管理页的执行器（拼多多授权回来后按前台刷新）。 */
  private authManage: AuthManageController | null = null;
  /** 基本模式下点购买、补同意的弹窗正在等结论。 */
  consentInFlight: boolean = false;
  /** 补同意后重开的详情页要自动执行一次的购买（一次性）。 */
  private consentResume: ConsentResume | null = null;
  /** 补同意前那次点击的购买意图（原 link_id 与报价、返利基准；H-R1-01）：同意后清栈，交给重开的详情页。 */
  private consentOrigin: ConsentResume | null = null;

  /** EntryAbility.onCreate：接上 Ability 上下文（openLink / startAbility）与调试用的安装状态覆盖。 */
  start(context: common.UIAbilityContext): void {
    this.ports.attach(context);
    this.ports.installedOverride = (platform: string): string | null => BuildVariant.tradeInstalledOverride(platform);
  }

  /** 百川初始化（只由 PrivacyGate.onConsented 的「联盟」步骤调用）：失败时 phase=startup 上报 sdk_init_failed（BR-ATTR-27）。 */
  initializeUnionSdk(): void {
    if (!this.baichuan.initialize()) {
      this.executor.reportStartupInitFailed();
    }
  }

  /** 一个发起页的购买执行器；页面出栈时调 release。 */
  purchaseController(env: PurchaseEnv): OpenPurchaseController {
    const deps: PurchaseDeps = new PurchaseDeps(this.api, this.executor, this.ports, env, this.pending, this.counter,
      this.tips, BuildVariant.webCodeAuthorizer(), this.baichuan);
    deps.browserNoticeMillis = BuildVariant.browserNoticeMillis(OpenPurchaseController.BROWSER_NOTICE_MILLIS);
    const controller: OpenPurchaseController = new OpenPurchaseController(deps);
    this.live.push(new LiveController(controller));
    return controller;
  }

  /** 页面出栈：作废执行器；补同意导致的清栈保留补同意待办（H01）。 */
  release(controller: OpenPurchaseController): void {
    controller.leave(this.consentInFlight);
    this.live = this.live.filter((l: LiveController) => l.controller !== controller);
  }

  /** 发起页被盖住 / 回到前台（NavDestination onHidden / onShown）。 */
  pageVisible(controller: OpenPurchaseController, visible: boolean): void {
    for (const l of this.live) {
      if (l.controller === controller) {
        l.visible = visible;
      }
    }
    if (visible) {
      controller.onForeground();
      // 登录页关掉、回到发起页：本页登记的购买待办（10001）自动重放一次（BR-ID-10；不在前台时 controller 自己等前台）
      controller.resumeAfterLogin();
    } else {
      controller.onBackground();
    }
  }

  /** 授权管理页的执行器（页面出栈时调 releaseAuthManage）。 */
  authManageController(): AuthManageController {
    const c: AuthManageController = new AuthManageController(this.api, this.executor, this.ports,
      BuildVariant.webCodeAuthorizer(), this.baichuan);
    this.authManage = c;
    return c;
  }

  releaseAuthManage(c: AuthManageController): void {
    c.leave();
    if (this.authManage === c) {
      this.authManage = null;
    }
  }

  /** App 回到前台 / 进入后台（AuthSheet 计数：后台 ≥ 1800 秒清零，BR-ID-18；发起页的续执行许可）。 */
  onAppForeground(): void {
    this.counter.onForeground();
    this.authManage?.onForeground();
    for (const l of this.live.slice()) {
      if (l.visible) {
        l.controller.onForeground();
      }
    }
  }

  onAppBackground(): void {
    this.counter.onBackground();
    // 授权管理页的授权外跳许可同样随进入后台作废（H-R1-03）
    this.authManage?.onBackground();
    for (const l of this.live.slice()) {
      l.controller.onBackground();
    }
  }

  /** 基本模式下点购买：弹补同意（经 Router 的补同意入口，AppPrivacy 记为守卫发起的补同意，仍不同意时删除待办）。 */
  requestConsent(resume: ConsentResume): void {
    this.consentInFlight = true;
    this.consentOrigin = resume;
    AppRouting.shared.navigator.requestConsent();
  }

  /**
   * 隐私结论变化（AppPrivacy.publish 之后调）：补同意等结论时——同意 → 本页还在就让它恢复一次；本页已随清栈出栈就按购买待办重开那件
   * 商品的详情，详情加载出同一件商品后自动执行一次购买（新键，H01）；仍不同意 → Router 已删除待办，这里只收尾。
   */
  privacyDecided(consented: boolean, basicMode: boolean): void {
    if (!this.consentInFlight || (!consented && !basicMode)) {
      return;
    }
    this.consentInFlight = false;
    const origin: ConsentResume | null = this.consentOrigin;
    this.consentOrigin = null;
    if (!consented) {
      return;
    }
    for (const l of this.live.slice()) {
      l.controller.resumeAfterConsent();
    }
    const record: Record<string, Object> | null = this.pending.peek();
    if (record === null || TradeJson.text(record, 'kind') !== OpenPurchaseController.PENDING_CONSENT) {
      return;
    }
    const platform: string | null = TradeJson.text(record, 'platform');
    const productKey: string | null = TradeJson.text(record, 'product_key');
    const linkId: string | null = TradeJson.text(record, 'link_id');
    this.pending.clear();
    if (platform === null || productKey === null || linkId === null) {
      return;
    }
    // 原点击的购买意图（带原 link_id 与报价、返利基准）对得上待办才自动恢复；对不上只重开详情、等用户自己点（保守，共性第 24 条）
    this.consentResume = origin !== null && origin.productKey === productKey && origin.linkId === linkId ? origin : null;
    const params: Record<string, Object> = {};
    params['platform'] = platform;
    params['product_key'] = productKey;
    const itemRef: string | null = TradeJson.text(record, 'item_ref');
    if (itemRef !== null) {
      params['item_ref'] = itemRef;
    }
    AppRouting.shared.openInApp('ProductDetail', params);
  }

  /** 重开的详情页取走补同意后的自动购买（一次性；商品对不上不执行）。 */
  takeConsentResume(productKey: string): ConsentResume | null {
    const r: ConsentResume | null = this.consentResume;
    if (r === null || r.productKey !== productKey) {
      return null;
    }
    this.consentResume = null;
    return r;
  }

  /** 此刻的平台购买状态：点击结果确认的 50301 优先，其次 features.platform_status（ConfigStore 当前生效的配置）。 */
  platformStatus(platform: string): string {
    return this.overrides.status(platform) ?? PlatformPurchase.statusOf(AppTrade.features(), platform);
  }

  /** /v1/config.help_links.<key>：{route, params}（没有配置为 null）。 */
  helpLink(key: string): HelpLink | null {
    const json: string | null = AppTrade.store()?.value('help_links') ?? null;
    if (json === null) {
      return null;
    }
    try {
      const links: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const entry: Record<string, Object> | null = TradeJson.object(links, key);
      const route: string | null = TradeJson.text(entry, 'route');
      if (entry === null || route === null) {
        return null;
      }
      return new HelpLink(route, TradeJson.object(entry, 'params') ?? {});
    } catch (e) {
      return null;
    }
  }

  static loggedIn(): boolean {
    return AppLogin.shared.loggedIn;
  }

  /** JumpTip 已读缓存的会话键：游客为 null（不展示），换账号、退出后重新读。 */
  private static sessionKey(): string | null {
    const client: ApiClient | null = AppNetwork.client;
    return client === null || !AppLogin.shared.loggedIn ? null : client.sessionAccount();
  }

  private static store(): ConfigStore | null {
    return AppClientCore.shared.config;
  }

  private static features(): Record<string, Object> | null {
    const json: string | null = AppTrade.store()?.value('features') ?? null;
    if (json === null) {
      return null;
    }
    try {
      const parsed: Object = JSON.parse(json) as Object;
      return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? parsed as Record<string, Object>
        : null;
    } catch (e) {
      return null;
    }
  }
}
