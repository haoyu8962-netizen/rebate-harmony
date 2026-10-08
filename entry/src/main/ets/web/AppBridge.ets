import { bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiRequest, ApiResult, AppConfig, BridgeBinding, BridgeLoginWait, LoginService, BridgeHandlers, BridgeHost, BridgeOrigins, BridgeRouteOpening,
  BridgeStatePort, ClientEvent, ConfigStore, CouliPreferences, EnvironmentGate, EnvironmentSwitchGate,
  ExternalNavDecision, ExternalNavEvents, ExternalNavHooks, ExternalNavPolicy, ExternalPageOptions, GuardDecision,
  GuardState, LocalRejectReason, OriginRules, PendingContractBridgeOriginsVerifier, PermissionResult,
  PrivacyState, RequestSigner, RouteRequest, RouteSource, RouteTargetAllowlist, Sha256, UpdateCheckStatus, UpdateState
} from 'core';
import { BundledConfig } from 'generated';
import { BridgeEnvInfo, ExternalWebConfig, TrustedWebConfig } from 'web';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { HARMONY_CHANNEL } from '../update/HarmonyStoreAccess';
import { WebDraftTexts } from './WebDraftTexts';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliBridge';
/** 剪贴板自动识别开关（clipboard.setAutoDetect）在 couli_app 里的键；随环境清理（TODO(APP-剪贴板识别)：识别器读它）。 */
const AUTO_DETECT_KEY: string = 'clipboard.auto_detect';
const LOGIN_ROUTE: string = 'Login';

/**
 * 宿主读取的 App 状态（每次调用取当时的值）。生产容器一律用它；Debug / Staging 的一致性入口在 entry/src/staging 里包一层
 * 自己的实现（R1-02：Release 不编译任何替换值、假登录或调试探针）。
 */
export class AppBridgeState implements BridgeStatePort {
  private readonly forcePage: boolean;

  constructor(forcePage: boolean) {
    this.forcePage = forcePage;
  }

  trustedOrigins(): string[] {
    return AppBridge.trustedOrigins();
  }

  linkPatterns(): string {
    return AppBridge.linkPatterns() ?? '';
  }

  shareDomains(): string[] {
    return AppBridge.stringList('share_domains');
  }

  privacy(): string {
    // 撤回清理未完成（凭据不可读）按未决定：桥只放行基本模式也能用的方法。
    if (!AppPrivacy.shared.credentialsReadable() && AppRouting.shared.privacyState === PrivacyState.CONSENTED) {
      return PrivacyState.NOT_DECIDED;
    }
    return AppRouting.shared.privacyState;
  }

  loggedIn(): boolean {
    const client: ApiClient | null = AppNetwork.client;
    return client !== null && client.sessionAccount() !== null;
  }

  update(): UpdateCheckStatus {
    return AppUpdate.shared.routerStatus();
  }

  fromForceUpdatePage(): boolean {
    return this.forcePage;
  }

  /** 隐私取值与同意周期、环境世代（切换中为 none）、会话世代与当前账号（R1-04、R2-03，core BridgeBinding）。 */
  binding(): string {
    const client: ApiClient | null = AppNetwork.client;
    return BridgeBinding.of(this.privacy(), AppClientCore.shared.consentCycle(), EnvironmentSwitchGate.shared.token(),
      client === null ? null : client.sessionGenerationId(), client === null ? null : client.sessionAccount());
  }
}

/**
 * App 组合处的 JSBridge 与两类容器接线（APP-04；03 §5）：
 * - 可信 origin：只来自验签通过的 bridge_origins（core BridgeOrigins：当前 → LKG → 包内，R1-03）。契约还没给出它的形状与
 *   签名（TODO(N-22)），现在任何一层都验不了，白名单为空、WebPage 一律不加载；不拿 h5_base_url 等别的配置项代替。
 *   Debug 构建另加本机一致性测试源（BuildVariant.debugTrustedOrigins，Release 为空、产物里没有回环地址）。
 * - 宿主：登记 Core 能力（app.getConfig、auth.getUser / getH5Token / login、net.signedRequest、nav.open、perm.*、
 *   clipboard.write / setAutoDetect、track.event），容器再登记 app.getEnv、ui.*、nav.close。trade.*、share.open、media.*、
 *   ext.*、cs.open 不登记（返回 90001，TODO 见 BridgeHost）。
 * - Router 的 WebPage / ExternalPage 目标白名单（03 §4.4）：bridgeOrigins = 可信 origin（只认 https），externalHosts =
 *   /v1/config.external_hosts。
 */
export class AppBridge {
  /** 平台页面被拦后「去搜索」的去向（routes.json Search）。 */
  static readonly SEARCH_ROUTE: string = 'Search';

  /** 可信 origin 白名单（规范化、去重）。 */
  static trustedOrigins(): string[] {
    const out: string[] = BridgeOrigins.fromConfig(AppClientCore.shared.config,
      new PendingContractBridgeOriginsVerifier());
    for (const extra of BuildVariant.debugTrustedOrigins()) {
      const origin: string | null = OriginRules.normalize(extra);
      if (origin !== null && out.indexOf(origin) < 0) {
        out.push(origin);
      }
    }
    return out;
  }

  /** Router 的 WebPage / ExternalPage 目标白名单。 */
  static routeTargets(): RouteTargetAllowlist {
    const https: string[] = AppBridge.trustedOrigins().filter((o: string): boolean => o.startsWith('https://'));
    return new RouteTargetAllowlist(AppBridge.stringList('external_hosts'), https);
  }

  /** 完整 link_patterns（当前 → 上一次成功 → 包内）。 */
  static linkPatterns(): string | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    return store === null ? AppBridge.bundledLinkPatterns() : store.linkPatterns();
  }

  static bundledLinkPatterns(): string {
    try {
      const data: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
      const patterns: Object | undefined = data['link_patterns'];
      return patterns === undefined ? '' : JSON.stringify(patterns);
    } catch (e) {
      return '';
    }
  }

  static stringList(key: string): string[] {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value(key);
    if (text === null) {
      return [];
    }
    try {
      const value: Object = JSON.parse(text) as Object;
      if (!Array.isArray(value)) {
        return [];
      }
      const out: string[] = [];
      for (const item of value as Object[]) {
        if (typeof item === 'string') {
          out.push(item as string);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 新建一个容器用的宿主（每个容器一个：在途 id 按容器隔离）。 */
  static createHost(page: string, state: BridgeStatePort): BridgeHost {
    const host: BridgeHost = new BridgeHost(state);
    host.page = page;
    host.track = (event: ClientEvent): void => {
      AppClientCore.shared.track(event);
    };
    // APP-04 共性 45：调用到截止时间，取消它已交给传输层的请求（owner = call.valid）。
    host.onCallExpired = (valid: () => boolean): void => {
      AppNetwork.client?.cancelOwned(valid);
    };
    const api = (request: ApiRequest): Promise<ApiResult> => {
      const client: ApiClient | null = AppNetwork.client;
      return client === null ? Promise.resolve(ApiResult.rejected(LocalRejectReason.CANCELLED)) : client.request(request);
    };
    host.register('app.getConfig', BridgeHandlers.config((key: string): string | null => {
      const store: ConfigStore | null = AppClientCore.shared.config;
      return store === null ? null : store.value(key);
    }));
    host.register('auth.getUser', BridgeHandlers.user(api));
    host.register('auth.getH5Token', BridgeHandlers.h5Token(api));
    host.register('auth.login', BridgeHandlers.login((hostValid: () => boolean): Promise<boolean> =>
    AppBridge.login(hostValid)));
    host.register('net.signedRequest', BridgeHandlers.signedRequest(api));
    // R1-10：nav.open 先判定并回复，回复交出后再执行导航（打开 Home 清栈会让本容器出栈）。
    host.register('nav.open', BridgeHandlers.navOpenAfterReply((route: string, params: Record<string, Object>,
      update: UpdateState): BridgeRouteOpening => AppBridge.openRoute(route, params, update)));
    host.register('perm.getPushStatus', BridgeHandlers.pushStatus((): Promise<boolean> => {
      try {
        return Promise.resolve(notificationManager.isNotificationEnabledSync());
      } catch (e) {
        return Promise.resolve(false);
      }
    }));
    host.register('perm.request', BridgeHandlers.permission((type: string, valid: () => boolean): Promise<boolean> =>
    AppClientCore.shared.requestPermission(type, false, valid).then((r: PermissionResult): boolean => r.granted)));
    host.register('clipboard.write', BridgeHandlers.clipboardWrite((text: string): Promise<boolean> =>
    AppBridge.writeClipboard(text)));
    host.register('clipboard.setAutoDetect', BridgeHandlers.clipboardAutoDetect((enabled: boolean): boolean =>
    AppBridge.saveAutoDetect(enabled)));
    host.register('track.event', BridgeHandlers.track(page, (event: ClientEvent): boolean =>
    AppClientCore.shared.track(event)));
    return host;
  }

  /** nav.open：来源 bridge，强更结论用本次调用守卫取得的值，不进启动排队、不补执行。 */
  static openRoute(route: string, params: Record<string, Object>, update: UpdateState): BridgeRouteOpening {
    const routing: AppRouting = AppRouting.shared;
    const base: GuardState = routing.guardState();
    const state: GuardState = base.withLaunch(AppConfig.gate() === EnvironmentGate.SETTLED, base.privacyState, update);
    const request: RouteRequest = RouteRequest.of(route, RouteSource.BRIDGE, params);
    const decision: GuardDecision = routing.router.decide(request, state);
    // R3-02：回复执行完、真正导航前，用那时的会话、隐私、环境与强更状态重新过 Router 守卫（不执行等待前的结论）。
    return BridgeRouteOpening.rechecked(request, decision, (): GuardState => routing.guardState(),
      (r: RouteRequest, s: GuardState): GuardDecision => routing.router.decide(r, s),
      (d: GuardDecision, r: RouteRequest): void => routing.router.apply(d, r),
      // F-HM-08（共性 63）：执行时强更检查在途（Router 状态源 result 为 null）→ 保守取消，不用上一轮结论。
      (): boolean => AppUpdate.shared.routerStatus().result === null);
  }

  /**
   * auth.login（F-HM-10，APP-04 共性 66–68；core BridgeLoginWait）：经 Router 打开登录页，以本次导航是否真的压入登录页为准；
   * 等这次登录完成（会话已保存 → true，绑定这次登录保存的会话世代）或离开登录页（→ false）再结算；等待期间核对页面、隐私、
   * 环境与截止时间（hostValid）。
   */
  static login(hostValid: () => boolean): Promise<boolean> {
    const routing: AppRouting = AppRouting.shared;
    const wait: BridgeLoginWait = new BridgeLoginWait(routing.navigator, (): LoginService | null =>
    AppLogin.shared.loginService(), (): number => AppNetwork.client?.sessionGenerationId() ?? -1,
      (): boolean => new AppBridgeState(false).loggedIn(), (): void => {
        routing.openInApp(LOGIN_ROUTE);
      });
    return wait.run(hostValid);
  }

  /** 剪贴板最近一次由本 App 写入的文本哈希（03 §4.6：之后识别时不把它当成用户复制的口令）。 */
  static lastWrittenHash: string | null = null;

  static async writeClipboard(text: string): Promise<boolean> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      AppBridge.lastWrittenHash = RequestSigner.hex(Sha256.digest(RequestSigner.utf8(text)));
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clipboard write failed');
      return false;
    }
  }

  private static context: common.UIAbilityContext | null = null;

  static attach(context: common.UIAbilityContext): void {
    AppBridge.context = context;
  }

  static saveAutoDetect(enabled: boolean): boolean {
    const context: common.UIAbilityContext | null = AppBridge.context;
    if (context === null) {
      return false;
    }
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: CouliPreferences.APP_NAMESPACE });
      store.putSync(AUTO_DETECT_KEY, enabled);
      store.flush();
      return true;
    } catch (e) {
      return false;
    }
  }

  static envInfo(): BridgeEnvInfo {
    let build: string = '';
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      build = String(info.versionCode);
    } catch (e) {
      build = '';
    }
    let os: string = '';
    try {
      os = deviceInfo.osFullName;
    } catch (e) {
      os = '';
    }
    return new BridgeEnvInfo(AppNetwork.appVersion, build, os, HARMONY_CHANNEL);
  }

  /** 可信容器配置（WebPage 路由；Debug 一致性入口传自己的 state）。 */
  static trustedConfig(url: string, fromForceUpdatePage: boolean, onClose: () => void,
    state: BridgeStatePort = new AppBridgeState(fromForceUpdatePage)): TrustedWebConfig {
    const config: TrustedWebConfig = new TrustedWebConfig(url, AppBridge.createHost('WebPage', state),
      (): string[] => state.trustedOrigins(), AppBridge.envInfo());
    config.onClose = onClose;
    config.onExternal = (target: string): void => {
      const params: Record<string, Object> = {};
      params['url'] = target;
      AppRouting.shared.openInApp('ExternalPage', params);
    };
    config.onDiagnostic = (kind: string): void => {
      hilog.info(DOMAIN, TAG, 'trusted web %{public}s', kind);
    };
    return config;
  }

  /** 第三方页容器配置（ExternalPage 路由）。 */
  static externalConfig(options: ExternalPageOptions, onClose: () => void): ExternalWebConfig {
    const hooks: ExternalNavHooks = new ExternalNavHooks();
    // BR-ATTR-29 ②(a) 的前提：已同意（非基本模式）且 features.external_page.product_intercept 开；取不到开关按关（保守，
    // 商品页按 (b) 拦下，绝不加载）。
    hooks.productIntercept = (): boolean => AppRouting.shared.privacyState === PrivacyState.CONSENTED
      && AppBridge.flag('external_page.product_intercept');
    // 商品回流意图交 Router 的后续处理入口（R1-08）；处理不了时容器出 product_unresolved 提示。
    hooks.dispatchProduct = (urlWithoutFragment: string): boolean =>
    AppRouting.shared.productIntent(urlWithoutFragment);
    // 埋点：框架类型（initial / main / subframe / new_window）在 core ExternalNavEvents 里逐一映射（R2-08）。
    hooks.blockedNav = (kind: string, frame: string): void => {
      AppClientCore.shared.track(ExternalNavEvents.blockedNav('ExternalPage', kind, frame));
    };
    hooks.unionHost = (decision: ExternalNavDecision, frame: string, outcome: string): void => {
      const event: ClientEvent | null = ExternalNavEvents.unionHost('ExternalPage', decision, frame, outcome);
      if (event !== null) {
        AppClientCore.shared.track(event);
      }
    };
    hooks.navHost = (registeredDomain: string, frame: string, hit: boolean): void => {
      AppClientCore.shared.track(ExternalNavEvents.navHost('ExternalPage', registeredDomain, frame, hit));
    };
    hooks.sampleBp = (): number => AppBridge.navHostSampleBp();
    const config: ExternalWebConfig = new ExternalWebConfig(options,
      new ExternalNavPolicy(AppBridge.bundledLinkPatterns()), (): string | null => AppBridge.linkPatterns(),
      'Couli/' + AppNetwork.appVersion, hooks);
    config.onClose = onClose;
    // BR-ATTR-29 ②(b)（R2-09）：平台页面被拦时「去搜索」经 Router 打开 Search。文案键契约里还没有，先用草稿（TODO(N-22)）。
    config.searchLabel = WebDraftTexts.GO_SEARCH;
    config.onSearch = (): void => {
      AppRouting.shared.openInApp(AppBridge.SEARCH_ROUTE);
    };
    return config;
  }

  /**
   * /v1/config external_page.nav_host_sample_bp（万分比，当前 → LKG → 包内）。没有下发或不合法按缺省 1000，显式 0 关闭采样
   * （APP-04 共性 39，F-HM-07；core ExternalNavHooks.sampleBpFrom）。
   */
  static navHostSampleBp(): number {
    const store: ConfigStore | null = AppClientCore.shared.config;
    return ExternalNavHooks.sampleBpFrom(store === null ? null : store.value('external_page'));
  }

  /** features.flags.<name>（当前 → LKG → 包内）；取不到为 false。 */
  static flag(name: string): boolean {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value('features');
    if (text === null) {
      return false;
    }
    try {
      const features: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const flags: Object | undefined = features['flags'];
      if (flags === undefined || flags === null || typeof flags !== 'object') {
        return false;
      }
      return (flags as Record<string, Object>)[name] === true;
    } catch (e) {
      return false;
    }
  }
}
