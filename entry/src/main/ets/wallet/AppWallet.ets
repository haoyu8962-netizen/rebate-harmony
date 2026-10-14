import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientWalletPort, ApiOutcome, ApiRequest, ApiResult, AppConfig, ClientEvents, ClipboardController,
  ConfigStore, CouliPreferences, FileSlot, LaborAgreementController, OrderCacheStore,
  OrderPendingMark, OrderStaleCache, PayoutAccountController, PendingKeyRecord, RealNameController, RouteDestination,
  RouteTable, TransportFailure, WalletApiPort, WalletCacheCleaner, WalletConfigPort, WalletController, WalletDeps,
  WalletHelpLink, WalletJson, WalletRecord, WalletSession, WalletStaleCache, WithdrawController,
  WithdrawRecordsController
} from 'core';
import { CouliAnnounce } from 'designsystem';
import { EventRouteParamsDroppedRoute, Routes, RouteSpec } from 'generated';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppClipboard } from '../clipboard/AppClipboard';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { AppUpdate } from '../update/AppUpdate';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliWallet';
/** 钱包摘要缓存目录（filesDir 下，按账号分子目录）与「待清理」标记文件（在缓存目录之外，APP-08 第 28 条）。 */
const CACHE_DIR: string = 'couli_wallet_cache';
const CACHE_PENDING_FILE: string = 'couli_wallet_cache.pending';
/** 提现页已输入金额（进程回收后按账号归属恢复，不恢复估算；couli_app 命名空间，切换环境随业务数据清）。 */
const WITHDRAW_INPUT_KEY: string = 'wallet.withdraw_input';

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
  readonly session: WalletSession = new WalletSession(Date.now, (): string => AppWallet.scopeKey());
  private readonly api: WalletApiPort = new LiveWalletPort();
  private readonly config: WalletConfigPort = new StoreWalletConfig();
  private lastAccount: string | null | undefined = undefined;
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
      this.clearWithdrawInput();
    });
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

  /** 每次状态同步：会话归属变了就作废并清空；账号变了再删钱包缓存（失败保留待清理标记、之后每次同步重试）。 */
  sync(): void {
    const cache: WalletStaleCache | null = this.cacheInstance;
    const account: string | null = AppWallet.account();
    if (this.session.sync()) {
      if (this.lastAccount !== account) {
        this.clearWithdrawInput();
        if (cache !== null && !cache.clear()) {
          hilog.warn(DOMAIN, TAG, 'wallet cache clear failed; pending');
        }
      }
    } else if (cache !== null) {
      cache.retryPendingClear();
    }
    this.lastAccount = account;
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

  withdraw(): WithdrawController {
    const c: WithdrawController = new WithdrawController(this.deps());
    // 进程回收后恢复已输入金额（按账号归属校验，不恢复估算）。
    // FU-HM-0712（共性第 65 条）：恢复的金额按提现页表单构建时固定的账号核对，不在恢复时另读一次当前会话。
    const saved: string | null = this.readWithdrawInput(c.formAccount);
    if (saved !== null) {
      c.restoreInput(saved);
    }
    // APP-09 共性第 59 条（S0）：按提现页表单固定的账号与归属键保存，写前核对当前会话；不按执行时的当前账号保存。
    c.onInputChanged = (text: string, account: string | null, scope: string): void =>
      this.saveWithdrawInput(text, account, scope);
    return c;
  }

  /** 提现页正常出栈：清掉持久化的金额（只给进程回收后恢复用）。 */
  withdrawLeft(c: WithdrawController): void {
    c.leave();
    this.clearWithdrawInput();
  }

  payout(): PayoutAccountController {
    return new PayoutAccountController(this.deps());
  }

  realName(): RealNameController {
    return new RealNameController(this.deps());
  }

  labor(): LaborAgreementController {
    return new LaborAgreementController(this.deps());
  }

  records(): WithdrawRecordsController {
    return new WithdrawRecordsController(this.deps());
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

  // ---------------------------------------------------------------- 已输入金额的持久化

  private prefs(): preferences.Preferences | null {
    const context: common.Context | null = this.context;
    if (context === null) {
      return null;
    }
    try {
      return preferences.getPreferencesSync(context, { name: CouliPreferences.APP_NAMESPACE });
    } catch (e) {
      return null;
    }
  }

  private readWithdrawInput(account: string | null): string | null {
    const p: preferences.Preferences | null = this.prefs();
    // 表单账号此刻仍是当前会话账号才恢复（当前会话只用于比较）。
    if (p === null || account === null || AppWallet.account() !== account) {
      return null;
    }
    try {
      const raw: preferences.ValueType = p.getSync(WITHDRAW_INPUT_KEY, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return null;
      }
      const r: WalletRecord | null = WalletJson.objectOf(JSON.parse(raw) as Object);
      if (r === null || WalletJson.text(r, 'account') !== OrderStaleCache.accountTag(account)) {
        return null;
      }
      return WalletJson.text(r, 'text');
    } catch (e) {
      return null;
    }
  }

  /**
   * 提现页表单的金额保存（共性第 59 条）：清除（空文字）任何归属都执行；写入只用表单固定的账号打标签，且当前会话的归属键与账号都还是
   * 这张表单的——会话已变（即使清空通知还没到）的旧回调不写，避免把旧表单的金额记到新账号名下。
   */
  private saveWithdrawInput(text: string, account: string | null, scope: string): void {
    if (text.length === 0) {
      this.clearWithdrawInput();
      return;
    }
    if (account === null || AppWallet.scopeKey() !== scope || AppWallet.account() !== account) {
      return;
    }
    this.writeWithdrawInputFor(account, text);
  }

  private writeWithdrawInputFor(account: string | null, text: string): void {
    const p: preferences.Preferences | null = this.prefs();
    if (p === null) {
      return;
    }
    try {
      if (account === null || text.length === 0) {
        p.deleteSync(WITHDRAW_INPUT_KEY);
      } else {
        const r: Record<string, string> = {};
        r['account'] = OrderStaleCache.accountTag(account);
        r['text'] = text;
        p.putSync(WITHDRAW_INPUT_KEY, JSON.stringify(r));
      }
      p.flush().catch((): void => {
      });
    } catch (e) {
      // 写不进：不影响页面。
    }
  }

  private clearWithdrawInput(): void {
    this.writeWithdrawInputFor(null, '');
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
