import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  FundPageFactory, ApiClient, ApiClientWalletPort, ApiOutcome, ApiRequest, ApiResult, AppConfig, SessionIdentity, WalletSessionReconciler, ClientEvents,
  ClipboardController,
  ConfigStore, CouliPreferences, FileSlot, OrderCacheStore,
  OrderPendingMark, PendingKeyRecord, RealNameRemote, RouteDestination,
  RouteTable, TransportFailure, WalletApiPort, WalletCacheCleaner, WalletConfigPort, WalletController, WalletDeps,
  WalletHelpLink, WalletJson, WalletRecord, WalletSession, WalletStaleCache,
  WithdrawInputBackend, WithdrawInputDraft
} from 'core';
import { CouliAnnounce } from 'designsystem';
import { EventRouteParamsDroppedRoute, Routes, RouteSpec } from 'generated';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppClipboard } from '../clipboard/AppClipboard';
import { AppLogin } from '../login/AppLogin';
import { AppMe } from '../me/AppMe';
import { AppNetwork } from '../network/AppNetwork';
import { BundledLegal } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliWallet';
/** 钱包摘要缓存目录（filesDir 下，按账号分子目录）与「待清理」标记文件（在缓存目录之外，APP-08 第 28 条）。 */
const CACHE_DIR: string = 'couli_wallet_cache';
const CACHE_PENDING_FILE: string = 'couli_wallet_cache.pending';
/** 提现页已输入金额（进程回收后按账号归属恢复，不恢复估算；couli_app 命名空间，切换环境随业务数据清）。 */
const WITHDRAW_INPUT_KEY: string = 'wallet.withdraw_input';

/**
 * 提现金额草稿的存储（F-X-08 ①，FU-HM-0719）：Preferences couli_app 的一个键，每次现取实例（切换环境的清理会删掉这个命名空间的文件与缓存）。
 * write 只改内存缓存；flushSync 失败抛错（撤回同意 / 切换环境的删除据此判失败）；flushLater 是平常保存用的异步落盘。
 */
class PreferencesWithdrawInputBackend implements WithdrawInputBackend {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: CouliPreferences.APP_NAMESPACE });
  }

  read(): string | null {
    const raw: preferences.ValueType = this.prefs().getSync(WITHDRAW_INPUT_KEY, '');
    return typeof raw === 'string' && raw.length > 0 ? raw : null;
  }

  write(value: string | null): void {
    const p: preferences.Preferences = this.prefs();
    if (value === null) {
      p.deleteSync(WITHDRAW_INPUT_KEY);
    } else {
      p.putSync(WITHDRAW_INPUT_KEY, value);
    }
  }

  flushSync(): void {
    this.prefs().flushSync();
  }

  flushLater(): void {
    this.prefs().flush().catch((): void => {
    });
  }
}

/** 钱包缓存的文件实现：filesDir/couli_wallet_cache/<账号短标识>/summary.json，FileSlot 原子写（临时文件 + fsync + 改名）。 */
class FileWalletCacheStore implements OrderCacheStore {
  private readonly root: string;
  private readonly pending: OrderPendingMark;

  constructor(filesDir: string) {
    this.root = filesDir + '/' + CACHE_DIR;
    this.pending = new OrderPendingMark(FileSlot.at(filesDir, CACHE_PENDING_FILE));
  }

  read(account: string, name: string): string | null {
    return new FileSlot(this.root + '/' + account + '/' + name).read();
  }

  write(account: string, name: string, value: string): void {
    const dir: string = this.root + '/' + account;
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    new FileSlot(dir + '/' + name).write(value);
  }

  /** 删除整个缓存目录（含临时文件）；删完再核对一次不存在，否则抛出（目录不存在算已删；核对本身出错抛出）。 */
  clearAll(): void {
    if (fileIo.accessSync(this.root)) {
      fileIo.rmdirSync(this.root);
    }
    if (fileIo.accessSync(this.root)) {
      throw new Error('wallet cache dir still exists');
    }
  }

  pendingClear(): boolean {
    return this.pending.isSet();
  }

  setPendingClear(pending: boolean): void {
    this.pending.set(pending);
  }
}

/** 网络组合之前：按网络失败收口（不发请求）。 */
class OfflineWalletPort implements WalletApiPort {
  request(_request: ApiRequest): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
      null, null));
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }

  pendingFor(_operationId: string): PendingKeyRecord | null {
    return null;
  }

  pendingStoreUnavailable(): boolean {
    return true;
  }

  confirmPending(_key: string, _token: string | null, _sendAllowed: () => boolean): Promise<ApiResult> {
    return this.request(new ApiRequest('createWithdrawal'));
  }

  abandonPending(_key: string, _sendAllowed: () => boolean): Promise<ApiResult> {
    return this.request(new ApiRequest('abandonIdempotencyKey'));
  }
}

/** 每次请求现取网络组合（F-HM-13 防护）。 */
class LiveWalletPort implements WalletApiPort {
  private readonly offline: OfflineWalletPort = new OfflineWalletPort();

  private current(): WalletApiPort {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? this.offline : new ApiClientWalletPort(client);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.current().request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.current().cancelOwned(owner);
  }

  pendingFor(operationId: string): PendingKeyRecord | null {
    return this.current().pendingFor(operationId);
  }

  pendingStoreUnavailable(): boolean {
    return this.current().pendingStoreUnavailable();
  }

  confirmPending(key: string, token: string | null, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.current().confirmPending(key, token, sendAllowed);
  }

  abandonPending(key: string, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.current().abandonPending(key, sendAllowed);
  }
}

/** Config 端口（ConfigStore 的当前生效配置）。 */
class StoreWalletConfig implements WalletConfigPort {
  private json(key: string): WalletRecord | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const text: string | null = store === null ? null : store.value(key);
    if (text === null) {
      return null;
    }
    try {
      return WalletJson.objectOf(JSON.parse(text) as Object);
    } catch (e) {
      return null;
    }
  }

  slaText(): string | null {
    const texts: WalletRecord | null = this.json('texts');
    const v: string | null = texts === null ? null : WalletJson.text(texts, 'withdraw.sla_text');
    return v !== null && v.trim().length > 0 ? v : null;
  }

  earningsFlag(): boolean | null {
    const features: WalletRecord | null = this.json('features');
    const flags: WalletRecord | null = features === null ? null : WalletJson.objectOf(features['flags']);
    const v: Object | null | undefined = flags === null ? undefined : flags['earnings.dashboard.visible'];
    return typeof v === 'boolean' ? v as boolean : null;
  }

  withdrawRulesHelp(): Record<string, Object> | null {
    return WalletHelpLink.withdrawRules(this.json('help_links'), Routes.all);
  }
}

/**
 * App 侧的钱包（APP-09 鸿蒙）：组合 Core 的钱包类执行器（ApiClient、钱包缓存、本机偏好、Router、统一剪贴板写入口、强更分流、统一客服
 * 出口），页面在 features/wallet。
 * - 会话变化（登出、换账号、会话失效、撤回同意、切换环境）在 AppRouting.stateChanged 的同步区里处理（WalletSession.reset）：清空全部钱包
 *   页面的显示与已填内容、内存里的 step_up_token，并把旧会话的资金页面移出导航栈；账号变了另删钱包缓存（确认删除成功，失败保留待清理标记）。
 * - 撤回同意与切换环境：钱包缓存登记为 AppConfig.cleaners 的「清理前第一步」（WalletCacheCleaner，APP-08 H02 的接法）。
 * - 实名状态（GET /v1/me realname_status，按账号）接到守卫的 realnameVerified（Withdraw、PayoutAccount 是 realname 档）。
 */
export class AppWallet {
  static readonly shared: AppWallet = new AppWallet();
  private context: common.Context | null = null;
  private cacheInstance: WalletStaleCache | null = null;
  /** 提现金额草稿（compose 之后可用；F-X-08 ① 撤回同意时确认删除落盘）。 */
  private draft: WithdrawInputDraft | null = null;
  readonly session: WalletSession = new WalletSession(Date.now, (): string => AppWallet.scopeKey());
  readonly pages: FundPageFactory = new FundPageFactory(this.session, (): WalletDeps => this.deps(),
    (): WithdrawInputDraft | null => this.draft, (): string | null => AppNetwork.loginEpoch(), (): void => this.sync());
  private readonly api: WalletApiPort = new LiveWalletPort();
  private readonly config: WalletConfigPort = new StoreWalletConfig();
  /** F-X-17（FU-HM-0723）：会话变化对账——账号变了、或同账号的登录世代分区变了都删钱包缓存与金额草稿。 */
  private reconciler: WalletSessionReconciler | null = null;
  private ui: UIContext | null = null;
  /** 当前可见的钱包类页面（回到前台时重取，G05、flow-map §16）。 */
  private visible: (() => void) | null = null;
  /** 当前可见的钱包类页面切到后台时的出口（APP-09 共性第 57 条：作废等待中的导航许可，可见世代换代）。 */
  private hidden: (() => void) | null = null;

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  /** EntryAbility.onCreate（网络组合与 AppClientCore 之后、环境对账之前）。 */
  compose(context: common.Context): void {
    this.context = context;
    // F-HM-34：按账号 + 持久化登录世代分区（同 AppOrders）。
    const cache: WalletStaleCache = new WalletStaleCache(new FileWalletCacheStore(context.filesDir),
      (): string | null => AppWallet.account(), Date.now, (): string | null => AppNetwork.loginEpoch());
    this.cacheInstance = cache;
    // 启动时先核验落盘的「待清理」标记（在缓存目录之外），上次没删完就在任何读取之前补删（APP-08 第 28 条）。
    if (!cache.retryPendingClear()) {
      hilog.warn(DOMAIN, TAG, 'wallet cache pending clear not finished at launch');
    }
    WalletCacheCleaner.install(AppConfig.cleaners, cache, (): void => {
      this.session.reset();
    });
    // F-X-08 ①（FU-HM-0719）：提现金额草稿单独登记清理前第一步——删除 + 同步落盘 + 读回核对，没确认就抛错（撤回清理不算完成、痕迹保留、
    // 冷启动 / 回前台 / 【重试】再删）。原先放在上面的页面作废回调里，删除结果不看、异步 flush。
    const draft: WithdrawInputDraft = new WithdrawInputDraft(new PreferencesWithdrawInputBackend(context));
    this.draft = draft;
    this.reconciler = new WalletSessionReconciler(this.session, cache, (): SessionIdentity => {
      return AppNetwork.sessionIdentity();
    }, (): void => this.clearWithdrawInput());
    draft.installCleaner(AppConfig.cleaners);
    this.session.removePages = (route: string): void => AppRouting.shared.navigator.remove(route);
    this.session.realname.subscribe((): void => this.syncRealname());
    AppRouting.shared.syncWallet = (): void => this.sync();
    // AC-S1-81 ⑫：资金与实名页面丢弃路由参数时记 route_params_dropped（只有路由名与个数）。
    AppRouting.shared.paramsDropped = (route: string, count: number): void => {
      const r: EventRouteParamsDroppedRoute | null = AppWallet.fundRoute(route);
      if (r !== null) {
        AppClientCore.shared.track(ClientEvents.routeParamsDropped(route, r, count));
      }
    };
  }

  private static fundRoute(route: string): EventRouteParamsDroppedRoute | null {
    switch (route) {
      case 'Withdraw':
        return EventRouteParamsDroppedRoute.WITHDRAW;
      case 'PayoutAccount':
        return EventRouteParamsDroppedRoute.PAYOUTACCOUNT;
      case 'LaborAgreement':
        return EventRouteParamsDroppedRoute.LABORAGREEMENT;
      case 'RealName':
        return EventRouteParamsDroppedRoute.REALNAME;
      default:
        return null;
    }
  }

  /** 当前会话账号（经过会话隔离判断；游客、读不出为 null）。 */
  private static account(): string | null {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? null : client.sessionAccount();
  }

  private static scopeKey(): string {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? '' : ClipboardController.scopeKey(client.captureScope());
  }

  /** 每次状态同步：会话归属变了就作废并清空；账号或同账号的登录世代分区变了再删钱包缓存与金额草稿（失败保留待清理标记、之后每次同步重试）。 */
  sync(): void {
    const result = this.reconciler?.sync();
    if (result !== undefined && result.clearFailed) {
      hilog.warn(DOMAIN, TAG, 'wallet cache clear failed; pending');
    }
    this.syncRealname();
  }

  /** 守卫的实名结论只认当前账号明确的 verified（未知按未实名，BR-ID-02）。 */
  private syncRealname(): void {
    AppRouting.shared.placeholders.realnameVerified = this.session.realname.verified(AppWallet.account());
  }

  /** 回到前台：可见的钱包类页面重取一次（提现页按未决记录恢复待确认、重取 rules）。 */
  onAppForeground(): void {
    const v: (() => void) | null = this.visible;
    if (v !== null) {
      v();
    }
  }

  /**
   * App 进后台（EntryAbility.onBackground）：可见的钱包类页面视同被覆盖（共性第 57 条）——等待实名查询 / 提交结果之后的导航许可作废，
   * 回到前台不恢复旧许可（不依赖 NavDestination 在切后台时是否回调 onHidden）。
   */
  onAppBackground(): void {
    const h: (() => void) | null = this.hidden;
    if (h !== null) {
      h();
    }
  }

  setVisible(onForeground: (() => void) | null, onBackground: (() => void) | null = null): void {
    this.visible = onForeground;
    this.hidden = onForeground === null ? null : onBackground;
  }

  /** 钱包类请求的网络端口（每次请求现取网络组合）：APP-13a 账号页（注销、换手机号）复用同一个端口。 */
  apiPort(): WalletApiPort {
    return this.api;
  }

  deps(): WalletDeps {
    const d: WalletDeps = new WalletDeps(this.api, this.session);
    d.scope = (): string => AppWallet.scopeKey();
    d.account = (): string | null => AppWallet.account();
    d.config = this.config;
    d.contract = BuildVariant.walletContract();
    // 实名提交的真实接口（Debug 假服务打开时 contract 优先）。同意 version：legal.privacy.version，取不到回落包内版本（与个性化同意同一对，D10-1033 ②）。
    d.realname = new RealNameRemote(this.api, (): number | null => AppMe.legalPrivacyVersion(), (): number | null => {
      const bundled: number = Number.parseInt(BundledLegal.PRIVACY_POLICY_VERSION, 10);
      return Number.isNaN(bundled) ? 1 : bundled;
    }, d.clock);
    d.cache = this.cacheInstance;
    d.open = (route: string, params: Record<string, Object>): void => {
      AppRouting.shared.openInApp(route, params);
    };
    d.replaceTop = (route: string, params: Record<string, Object>): void => {
      // 兜底（提现页没拿到自己的导航实例 id 时）：只打开记录页，不按路由名批量移除同名提现页（R2-04，共性第 50 条）。
      // 正常路径由 AppWithdrawPage 接 WithdrawController.replaceOwn，只替换发起页这一个实例。
      AppRouting.shared.openInApp(route, params);
    };
    // 10405：服务端已判定强更（进强更闸门本身并持久化；没有检查结果时立即补查）。
    d.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    // 统一客服出口（客服任务接入前打开帮助中心，同 APP-08 G09）。
    d.customerService = (): void => AppLogin.openCustomerService();
    // TODO(N-32) rule-gaps H05：privacy / agreement 的重新同意没有可供资金页调用的统一入口，只提示 error.10004。
    d.reconsent = (_type: string): void => {
    };
    // TODO(N-32) G31 / rule-gaps H04：本机没有保存当前账号的手机号；Release 不编造号码（发码不发出）。Debug 假服务用测试号码。
    d.stepUpPhone = (account: string): string | null => BuildVariant.stepUpPhone(account);
    d.appVersion = (): string => AppRouting.shared.appVersionName;
    d.earningsSince = (): string | null => {
      const spec: RouteSpec | undefined = RouteTable.spec('Earnings');
      return spec === undefined ? null : spec.sinceHarmony;
    };
    // G27：交易流水号复制只经 APP-07 的统一写入口（先记自写 hash 并确认落盘，记录失败就不写）。
    d.copyText = (text: string): Promise<boolean> => AppClipboard.shared.write(text);
    d.log = (message: string): void => {
      hilog.info(DOMAIN, TAG, '%{public}s', message);
    };
    return d;
  }

  // ---------------------------------------------------------------- 页面执行器

  wallet(): WalletController {
    return new WalletController(this.deps());
  }

  slaText(): string | null {
    return this.config.slaText();
  }

  announce(text: string): void {
    const ui: UIContext | null = this.ui;
    if (ui !== null) {
      CouliAnnounce.say(ui, text);
    }
  }

  // ---------------------------------------------------------------- 已输入金额的持久化（Core WithdrawInputDraft）

  private clearWithdrawInput(): void {
    this.draft?.clear();
  }

  /** 路由参数里的字符串（Router 已按 routes.json 校验）。 */
  static routeString(param: Object, name: string): string | null {
    if (param instanceof RouteDestination) {
      const value: Object | undefined = (param as RouteDestination).params[name];
      return typeof value === 'string' ? value as string : null;
    }
    return null;
  }
}
