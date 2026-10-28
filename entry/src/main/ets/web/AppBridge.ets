import { bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiRequest, ClipboardController, ApiResult, AppConfig, BridgeBinding, BridgeLoginWait, LoginService, RouterLoginHost, BridgeHandlers, BridgeHost, BridgeOrigins, BridgeRouteOpening,
  BridgeStatePort, ClientEvent, ConfigSnapshot, ConfigStore, EnvironmentGate, EnvironmentSwitchGate,
  ExternalNavDecision, ExternalNavEvents, ExternalNavHooks, ExternalNavPolicy, ExternalPageOptions, GuardDecision,
  GuardState, LocalRejectReason, OriginRules, PendingContractBridgeOriginsVerifier, PermissionResult,
  FileSlot, FileTrustedAuthJournal, FileTrustedWebOwnerRecord, PrivacyState, RouteRequest, RouteSource, RouteTargetAllowlist, SessionIdentity,
  SessionLoginEpochs, TrustedAuthJournal, TrustedAuthPage, TrustedAuthSync, TrustedWebOwnerRecord, UpdateCheckStatus,
  UpdateState
} from 'core';
import { BundledConfig } from 'generated';
import { BridgeEnvInfo, ExternalWebConfig, TrustedWebConfig, TrustedWebProfile } from 'web';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';
import { HARMONY_CHANNEL } from '../update/HarmonyStoreAccess';
import { WebDraftTexts } from './WebDraftTexts';
import { AppClipboard } from '../clipboard/AppClipboard';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliBridge';
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
    // APP-05b 共性第 18 条：已绑手机与已登录未绑手机都算已登录（Core RouterLoginHost.bridgeLoggedIn，测试核对）。
    return RouterLoginHost.bridgeLoggedIn(AppNetwork.client);
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

  /**
   * /v1/config bridge_disabled_methods 的生效值（core ConfigStore.bridgeDisabledMethods）；没有 ConfigStore 为 []。
   * 值不合法时整键按 [] 并记一条 warn（只记键名）；同一份生效配置只记一次，不随每次桥调用重复。
   */
  static disabledMethods(): string[] {
    const store: ConfigStore | null = AppClientCore.shared.config;
    if (store === null) {
      return [];
    }
    return store.bridgeDisabledMethods((key: string): void => {
      const mark: string = store.sourceRaw + ':' + store.appliedFetchId;
      if (mark !== AppBridge.disabledWarned) {
        AppBridge.disabledWarned = mark;
        hilog.warn(DOMAIN, TAG, 'invalid config key %{public}s', key);
      }
    });
  }

  /** 上一次记 warn 的生效配置（层 + 拉取编号）。 */
  private static disabledWarned: string = '';

  /** 网页容器实例的编号（clipboard.setAutoDetect 的临时抑制按容器实例记，APP-07 G06）。 */
  private static containerSerial: number = 0;

  /** 新建一个容器用的宿主（每个容器一个：在途 id 按容器隔离）。containerId：容器实例编号（剪贴板抑制用）。 */
  static createHost(page: string, state: BridgeStatePort, containerId: string = AppBridge.nextContainerId()): BridgeHost {
    const host: BridgeHost = new BridgeHost(state);
    host.page = page;
    host.track = (event: ClientEvent): void => {
      AppClientCore.shared.track(event);
    };
    // APP-04 共性 45：调用到截止时间，取消它已交给传输层的请求（owner = call.valid）。
    host.onCallExpired = (valid: () => boolean): void => {
      AppNetwork.client?.cancelOwned(valid);
    };
    // F-X-24：远程禁用名单读 ConfigStore 的生效值（与其他配置键同一份、同一刷新时机），每次准入时现取。
    host.disabledMethods = (): string[] => AppBridge.disabledMethods();
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
    // APP-07 G06：只对发起调用的这个容器实例生效的临时抑制，容器出栈即失效；不写本机存储、不改任何设置。
    // 鸿蒙没有自动识别（只有 PasteButton），抑制只记在执行层的判定状态里。
    host.register('clipboard.setAutoDetect', BridgeHandlers.clipboardAutoDetect((enabled: boolean): boolean => {
      const controller: ClipboardController | null = AppClipboard.shared.controller;
      if (controller === null) {
        return false;
      }
      controller.setWebAutoDetect(containerId, enabled);
      return true;
    }));
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

  static nextContainerId(): string {
    AppBridge.containerSerial++;
    return 'web-' + AppBridge.containerSerial;
  }

  /** 网页容器出栈：它的剪贴板抑制随之失效（G06）。 */
  static containerClosed(containerId: string): void {
    AppClipboard.shared.controller?.webClosed(containerId);
  }

  /**
   * clipboard.write（03 §4.6；APP-07 brief §2.3）：经 App 唯一的写剪贴板入口，写入前先记 hash（最近 10 条），之后识别时排除。
   */
  static writeClipboard(text: string): Promise<boolean> {
    return AppClipboard.shared.write(text);
  }

  private static context: common.UIAbilityContext | null = null;

  static attach(context: common.UIAbilityContext): void {
    AppBridge.context = context;
    // F-X-25：切号处理随 App 启动建立（没有在开容器时登出 / 换号也要清可信 Web 存储；上次没清完的在任何可信页面加载前补清）。
    AppBridge.trustedAuth(AppNetwork.client, AppNetwork.tokens);
  }

  /** 「Web 数据待清理」标记文件（沙盒 filesDir，F-X-25 I3；切环境 / 撤回同意的本机清理不删它）。 */
  private static readonly WEB_PENDING_FILE: string = 'couli_trusted_web.pending';
  /** 「可信 Web 数据归属」记录文件（F-X-25 R2-04 第二道防线；同在沙盒 filesDir）。 */
  private static readonly WEB_OWNER_FILE: string = 'couli_trusted_web.owner';

  /** 每个 ApiClient 一份切号处理（F-X-25）。 */
  private static readonly authSyncs: Map<ApiClient, TrustedAuthSync> = new Map<ApiClient, TrustedAuthSync>();

  /**
   * 可信 WebView 的切号处理（F-X-25，D10-131；判定与调度在 core TrustedAuthSync / AuthChangeDecision）：观察 ApiClient 的会话
   * 唤醒，身份快照与订单、钱包、首页同一入口（ApiClient.sessionIdentity + 持久化登录世代）。client 为 null（未组合）时没有。
   */
  static trustedAuth(client: ApiClient | null, epochs: SessionLoginEpochs | null,
    pending: TrustedAuthJournal | null = null, owner: TrustedWebOwnerRecord | null = null): TrustedAuthSync | null {
    if (client === null) {
      return null;
    }
    const existing: TrustedAuthSync | undefined = AppBridge.authSyncs.get(client);
    if (existing !== undefined) {
      return existing;
    }
    // 待清理标记存储缺失是配置错误（I3）：抛出，由调用方失败可见（可信页面不加载），绝不改用内存记录。
    const journal: TrustedAuthJournal = pending ?? AppBridge.webPendingJournal();
    // 归属记录与生产标记同在沙盒；注入标记存储（测试夹具）时由调用方显式给（缺省没有）。
    const ownerRecord: TrustedWebOwnerRecord | null = pending === null ? AppBridge.webOwnerRecord() : owner;
    const sync: TrustedAuthSync = new TrustedAuthSync((): SessionIdentity => client.sessionIdentity(epochs),
      new TrustedWebProfile(), journal, ownerRecord);
    client.watchSession((cleared: boolean): void => sync.changed(cleared));
    // R2-04：登录换号时先把待清标记写盘，写不进则新会话不落盘。
    client.guardSessionSave((account: string | null): boolean => sync.admit(account));
    AppBridge.authSyncs.set(client, sync);
    return sync;
  }

  /**
   * 生产的待清理标记：沙盒文件（FileSlot 原子写）。App 在 EntryAbility.onCreate 里先 attach 再有任何页面，所以生产上总有沙盒
   * 目录。还没 attach（没有可落盘的位置）即配置错误（F-X-25 I3 严格）：抛出，不用任何进程内记录兜底。
   */
  private static webPendingJournal(): TrustedAuthJournal {
    const context: common.UIAbilityContext | null = AppBridge.context;
    if (context !== null && context !== undefined) {
      return new FileTrustedAuthJournal(FileSlot.at(context.filesDir, AppBridge.WEB_PENDING_FILE));
    }
    throw new Error('trusted web pending store unavailable (AppBridge not attached)');
  }

  /** 生产的 Web 数据归属记录（沙盒文件）；调用时机同 webPendingJournal（标记已建成，context 必在）。 */
  private static webOwnerRecord(): TrustedWebOwnerRecord {
    const context: common.UIAbilityContext | null = AppBridge.context;
    if (context !== null && context !== undefined) {
      return new FileTrustedWebOwnerRecord(FileSlot.at(context.filesDir, AppBridge.WEB_OWNER_FILE));
    }
    throw new Error('trusted web owner record unavailable (AppBridge not attached)');
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

  /**
   * 可信容器配置（WebPage 路由；Debug 一致性入口传自己的 state）。authClient / authEpochs：切号处理观察的 ApiClient 与登录世代
   * 来源（F-X-25），缺省为 App 的 AppNetwork。
   */
  static trustedConfig(url: string, fromForceUpdatePage: boolean, onClose: () => void,
    state: BridgeStatePort = new AppBridgeState(fromForceUpdatePage), authClient: ApiClient | null = null,
    authEpochs: SessionLoginEpochs | null = null, authPending: TrustedAuthJournal | null = null): TrustedWebConfig {
    const containerId: string = AppBridge.nextContainerId();
    const config: TrustedWebConfig = new TrustedWebConfig(url, AppBridge.createHost('WebPage', state, containerId),
      (): string[] => state.trustedOrigins(), AppBridge.envInfo());
    AppBridge.containers.set(config, containerId);
    config.onClose = onClose;
    config.onExternal = (target: string): void => {
      const params: Record<string, Object> = {};
      params['url'] = target;
      AppRouting.shared.openInApp('ExternalPage', params);
    };
    config.onDiagnostic = (kind: string): void => {
      hilog.info(DOMAIN, TAG, 'trusted web %{public}s', kind);
    };
    // F-X-24：配置换层或换内容时，已打开页面的能力列表（has()）随之更新。
    config.watchMethods = (changed: () => void): () => void => {
      const store: ConfigStore | null = AppClientCore.shared.config;
      return store === null ? (): void => {
      } : store.subscribe((_s: ConfigSnapshot): void => changed());
    };
    // F-X-25：切号时通知并（账号变化 / 登出）清理可信 Web 存储后重载本容器。切号处理建不起来（如待清理标记存储缺失）时
    // wireAuth 失败可见（I3 严格）；其余接线出错时容器照常打开（不因此白屏）。
    try {
      AppBridge.wireAuth(config, authClient, authEpochs, authPending);
    } catch (e) {
      config.whenAuthSettled = (): Promise<boolean> => Promise.resolve(false);
    }
    return config;
  }

  /**
   * 切号处理接不上（F-X-25 I3 严格）：容器一出现即隔离并显示可重试错误页，完成屏障为 false。「重试」重新接线：仍接不上则
   * 保持错误；接上后把在开容器登记到切号处理——有待清理（含冷启动标记）时由它清完再重载，没有时直接加载入口。
   */
  private static wireAuthFailed(config: TrustedWebConfig, authClient: ApiClient | null,
    authEpochs: SessionLoginEpochs | null, authPending: TrustedAuthJournal | null): void {
    const pages: TrustedAuthPage[] = [];
    const unwatch: Map<TrustedAuthPage, () => void> = new Map<TrustedAuthPage, () => void>();
    let live: TrustedAuthSync | null = null;
    config.watchAuth = (page: TrustedAuthPage): () => void => {
      const current: TrustedAuthSync | null = live;
      if (current !== null) {
        unwatch.set(page, current.attach(page));
      } else {
        if (pages.indexOf(page) < 0) {
          pages.push(page);
        }
        page.isolate();
        page.block();
      }
      return (): void => {
        const index: number = pages.indexOf(page);
        if (index >= 0) {
          pages.splice(index, 1);
        }
        const off: (() => void) | undefined = unwatch.get(page);
        unwatch.delete(page);
        if (off !== undefined) {
          off();
        }
      };
    };
    config.whenAuthSettled = (): Promise<boolean> => live === null ? Promise.resolve(false) : live.settled();
    config.retryAuth = (): Promise<boolean> => {
      if (live !== null) {
        return live.retry();
      }
      let sync: TrustedAuthSync | null = null;
      try {
        sync = authClient === null ?
          AppBridge.trustedAuth(AppNetwork.client, authEpochs ?? AppNetwork.tokens, authPending) :
          AppBridge.trustedAuth(authClient, authEpochs, authPending);
      } catch (e) {
        sync = null;
      }
      if (sync === null) {
        return Promise.resolve(false);
      }
      const ready: TrustedAuthSync = sync;
      live = ready;
      const waiting: TrustedAuthPage[] = pages.splice(0, pages.length);
      for (const page of waiting) {
        unwatch.set(page, ready.attach(page));
      }
      if (!ready.busy()) {
        // 没有待清理：照「先拆再建」把每个容器的 Web 换到新控制器上再加载入口（不在接线失败时的控制器上解除隔离）；
        // 哪一步失败都保持隔离、显示错误页。
        for (const page of waiting) {
          AppBridge.reopen(page);
        }
      }
      return ready.settled();
    };
  }

  /**
   * 接线恢复、且没有待清理时重开一个被阻断的容器（wireAuthFailed）：拆（旧 Web 下树、旧控制器失效）→ 新控制器挂空白载体 →
   * 允许解除 → 加载入口。不挂 Web 的容器（入口被拒）只按被拒显示。任一步失败保持隔离、显示错误页。
   */
  private static reopen(page: TrustedAuthPage): void {
    let web: boolean = false;
    try {
      web = page.rendersWeb();
    } catch (e) {
      web = false;
    }
    const carrier: Promise<void> = web ?
      page.discardDocument().then((): Promise<void> => page.mountFresh()) : Promise.resolve();
    carrier.then((): Promise<void> => {
      page.release();
      return page.reload();
    }).catch((): void => page.block());
  }

  /**
   * 把容器接到切号处理（F-X-25）：client 为 null 时用 App 的 AppNetwork（未组合时不接）。切号处理建不起来（待清理标记存储
   * 缺失等，I3 严格）时不用任何兜底：容器隔离、不加载可信页面，只显示可重试的错误页。
   */
  private static wireAuth(config: TrustedWebConfig, authClient: ApiClient | null,
    authEpochs: SessionLoginEpochs | null, authPending: TrustedAuthJournal | null): void {
    let auth: TrustedAuthSync | null = null;
    try {
      auth = authClient === null ?
        AppBridge.trustedAuth(AppNetwork.client, authEpochs ?? AppNetwork.tokens, authPending) :
        AppBridge.trustedAuth(authClient, authEpochs, authPending);
    } catch (e) {
      AppBridge.wireAuthFailed(config, authClient, authEpochs, authPending);
      return;
    }
    if (auth === null) {
      return;
    }
    const sync: TrustedAuthSync = auth;
    config.watchAuth = (page: TrustedAuthPage): () => void => sync.attach(page);
    config.whenAuthSettled = (): Promise<boolean> => sync.settled();
    config.retryAuth = (): Promise<boolean> => sync.retry();
  }

  private static readonly containers: Map<TrustedWebConfig, string> = new Map<TrustedWebConfig, string>();

  /** 可信容器出栈（AppWebPage onWillDisappear）：剪贴板抑制失效。 */
  static trustedClosed(config: TrustedWebConfig): void {
    const id: string | undefined = AppBridge.containers.get(config);
    AppBridge.containers.delete(config);
    if (id !== undefined) {
      AppBridge.containerClosed(id);
    }
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
