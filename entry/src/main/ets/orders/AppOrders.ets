import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import {
  ApiClient, ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, AppConfig, ClipboardController, ConfigStore,
  CouliPreferences, FileSlot, OrderAnchorKeeper, OrderCacheCleaner, OrderCacheStore, OrderCopy, OrderDetailController,
  OrderDetailDeps, OrderDetailEntries, OrderDraftTexts, OrderJson, OrderListController,
  OrderListDeps, OrderListEntries, OrderPageRestorer, OrderRecord, OrderSessionHub, OrderStaleCache, PendingTrackController,
  PendingTrackDeps, PendingTrackJumpWatcher, PermissionResult, RouteDestination, SearchApiPort, SessionState,
  TransportFailure
} from 'core';
import { CouliAnnounce, CouliToast } from 'designsystem';
import { Routes } from 'generated';
import { OrderDetailPageConfig, OrderListPageConfig, OrderMaskUi } from 'orders';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppClipboard } from '../clipboard/AppClipboard';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppRouting } from '../routing/AppRouting';
import { ShellState } from '../shell/ShellState';
import { AppUpdate } from '../update/AppUpdate';
import { PendingTrackUi } from './PendingTrackViews';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliOrders';
const ORDER_LIST_ROUTE: string = 'OrderList';
/** 订单缓存目录（filesDir 下，按账号分子目录）与「待清理」标记文件。 */
const CACHE_DIR: string = 'couli_orders_cache';
const CACHE_PENDING_FILE: string = 'couli_orders_cache.pending';
/** 页面状态（子 Tab、分组、平台、月份、搜索词、输入框；进程回收后恢复）：couli_app 命名空间（切换环境随业务数据清）。 */
const PAGE_STATE_KEY: string = 'orders.page_state';
/**
 * 本机偏好（不随账号、不随环境，卸载即清）：金额隐藏开关（G21，APP-09 的「我的」、钱包复用）、待跟单卡里点过【开启通知】（G22）。
 * 不在 CouliPreferences.ALL_NAMESPACES 里（切换环境不删）。
 */
const DEVICE_PREFS: string = 'couli_device_prefs';
const MASK_KEY: string = 'amount_mask.hidden';
const PUSH_ROW_KEY: string = 'orders.push_row_used';

/** 订单缓存的文件实现：filesDir/couli_orders_cache/<账号短标识>/<名字>，FileSlot 原子写（临时文件 + fsync + 改名）。 */
class FileOrderCacheStore implements OrderCacheStore {
  private readonly root: string;
  private readonly pending: FileSlot;

  constructor(filesDir: string) {
    this.root = filesDir + '/' + CACHE_DIR;
    this.pending = FileSlot.at(filesDir, CACHE_PENDING_FILE);
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

  /** 删除整个缓存目录（含临时文件）；删完再核对一次不存在，否则抛出。 */
  clearAll(): void {
    if (fileIo.accessSync(this.root)) {
      fileIo.rmdirSync(this.root);
    }
    if (fileIo.accessSync(this.root)) {
      throw new Error('order cache dir still exists');
    }
  }

  pendingClear(): boolean {
    return this.pending.read() !== null;
  }

  setPendingClear(pending: boolean): void {
    this.pending.write(pending ? '1' : null);
  }
}

/** 网络组合之前：按网络失败收口（不发请求）。 */
class OfflinePort implements SearchApiPort {
  request(_request: ApiRequest): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
      null, null));
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

/** 每次请求现取网络组合（F-HM-13 防护）。 */
class LivePort implements SearchApiPort {
  private readonly offline: OfflinePort = new OfflinePort();

  private current(): SearchApiPort {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? this.offline : new ApiClientSearchPort(client);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.current().request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.current().cancelOwned(owner);
  }
}

/** 路由参数里的字符串（Router 已按 routes.json 校验）。 */
export function routeString(param: Object, name: string): string | null {
  if (param instanceof RouteDestination) {
    const value: Object | undefined = (param as RouteDestination).params[name];
    return typeof value === 'string' ? value as string : null;
  }
  return null;
}

/** 一个显示位置的待跟单卡（执行器 + 页面模型）。 */
export class PendingTrackHost {
  readonly controller: PendingTrackController;
  readonly ui: PendingTrackUi;

  constructor(controller: PendingTrackController, ui: PendingTrackUi) {
    this.controller = controller;
    this.ui = ui;
  }
}

/**
 * App 侧的订单（APP-08 鸿蒙）：组合 Core 的列表 / 详情 / 待跟单卡执行器与订单缓存（ApiClient、文件、本机偏好、Router、统一剪贴板写入口、
 * 强更分流、PermissionRequester），页面在 features/orders。
 * - 订单 Tab 是 Tab 根：执行器整个进程一份，Tab 被切走只是被覆盖（不作废）；第一次显示时才加载（ShellState.onRootShown）。
 * - 会话变化（登出、换账号、会话失效、撤回同意、切换环境）在 AppRouting.stateChanged 的同步区里处理：作废在途请求、清空列表与
 *   待跟单卡、删订单缓存（换账号 / 登出），新账号断网时看到网络错误态而不是旧账号数据（G10）。
 * - 撤回同意与切换环境：订单缓存登记为 AppConfig.cleaners 的「清理前第一步」（OrderCacheCleaner），删不掉时撤回清理不算完成。
 */
export class AppOrders {
  static readonly shared: AppOrders = new AppOrders();
  private context: common.Context | null = null;
  private cacheInstance: OrderStaleCache | null = null;
  private listInstance: OrderListController | null = null;
  private listConfigInstance: OrderListPageConfig | null = null;
  private listPending: PendingTrackHost | null = null;
  private maskUi: OrderMaskUi | null = null;
  private ui: UIContext | null = null;
  private readonly api: SearchApiPort = new LivePort();
  /**
   * 会话协调（Core OrderSessionHub）：按会话共享的 42901 闸门（列表、详情、各待跟单卡位置共用，R1-02）；会话变化时清空列表、卡片与
   * 已显示的详情快照并把旧会话的详情页移出导航栈（R1-01）。
   */
  private readonly hub: OrderSessionHub = new OrderSessionHub(Date.now, (): string => AppOrders.scopeKey());
  /** 上次状态同步时的账号（undefined = 还没同步过）。 */
  private lastAccount: string | null | undefined = undefined;
  /** 订单 Tab 显示过（之后会话变化时立即重新加载）。 */
  private tabShown: boolean = false;
  /** 进程回收后要恢复的条件与输入（只给第一次显示的列表；账号不同不恢复）。 */
  private restoreInput: string = '';
  /**
   * 滚动锚点（共性第 10、17 条；同一账号、同一条件才恢复）：恢复进行中保留原持久化锚点、冻结普通滚动记录，对齐完成后才更新（R2-05）。
   */
  private readonly anchorKeeper: OrderAnchorKeeper = new OrderAnchorKeeper();
  /**
   * 页面状态的恢复与持久化（R3-01；共性第 23 条）：冷启动时订单 Tab 根被隐藏挂载，页面的初始快照早于 Tab 第一次显示；恢复决策（读取并
   * 校验同一账号的记录）完成前不写盘，默认条件与空锚点不覆盖恢复记录。
   */
  private readonly restorer: OrderPageRestorer = new OrderPageRestorer((): string | null => this.readPageState(),
    (value: string | null): void => this.writePageState(value), (): string | null => AppOrders.account(),
    this.anchorKeeper);

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  /** EntryAbility.onCreate（网络组合与 AppClientCore 之后）。 */
  compose(context: common.Context): void {
    this.context = context;
    const store: FileOrderCacheStore = new FileOrderCacheStore(context.filesDir);
    const cache: OrderStaleCache = new OrderStaleCache(store, (): string | null => AppOrders.account(), Date.now);
    this.cacheInstance = cache;
    // 撤回同意与切换环境：先作废订单页面与在途请求，再删缓存；删不掉报失败（撤回痕迹保留、冷启动重试）。
    OrderCacheCleaner.install(AppConfig.cleaners, cache, (): void => this.hub.reset());
    this.hub.removePages = (route: string): void => AppRouting.shared.navigator.remove(route);
    const deps: OrderListDeps = new OrderListDeps(this.api);
    deps.cache = cache;
    deps.scope = (): string => AppOrders.scopeKey();
    this.hub.attachList(deps);
    this.listInstance = new OrderListController(deps);
    this.hub.setList(this.listInstance);
    ShellState.onRootShown = (destination: RouteDestination): void => {
      if (destination.route === ORDER_LIST_ROUTE) {
        this.showTab(destination);
      }
    };
    AppRouting.shared.syncOrders = (): void => this.sync();
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

  get mask(): OrderMaskUi {
    if (this.maskUi === null) {
      const ui: OrderMaskUi = new OrderMaskUi();
      ui.masked = this.readDevice(MASK_KEY);
      ui.onToggle = (masked: boolean): void => this.writeDevice(MASK_KEY, masked);
      this.maskUi = ui;
    }
    return this.maskUi;
  }

  // ---------------------------------------------------------------- 会话与状态同步

  /**
   * 每次状态同步（AppRouting.stateChanged：隐私、会话、环境变化都会走到）。会话归属变了：作废并清空；账号变了（换账号、登出、会话
   * 失效）再删订单缓存（确认删除成功，失败保留待清理标记、之后每次同步重试）。
   */
  sync(): void {
    const cache: OrderStaleCache | null = this.cacheInstance;
    const scope: string = AppOrders.scopeKey();
    const account: string | null = AppOrders.account();
    if (this.hub.sync()) {
      if (this.lastAccount !== account && cache !== null && !cache.clear()) {
        hilog.warn(DOMAIN, TAG, 'order cache clear failed; pending');
      }
      // 会话变化：持久化的页面状态（条件、输入、锚点）、恢复锚点与待恢复输入一并清掉（共性第 19 条）。
      this.restorer.reset();
      this.restoreInput = '';
      if (this.listConfigInstance !== null) {
        this.listConfigInstance.initialInput = '';
      }
      if (this.tabShown && ShellState.shared.selected === ShellState.indexOf(ORDER_LIST_ROUTE)) {
        this.loadTab();
      }
    } else if (cache !== null) {
      cache.retryPendingClear();
    }
    // 订单 Tab 显示着、待跟单卡还没按当前会话拉成功过（登录完成后的第一次显示等）：补拉一次。
    const pending: PendingTrackHost | null = this.listPending;
    if (pending !== null && this.tabShown && pending.controller.fetchedScope !== scope
      && ShellState.shared.selected === ShellState.indexOf(ORDER_LIST_ROUTE)) {
      pending.controller.fetch(null);
    }
    this.lastAccount = account;
  }

  // ---------------------------------------------------------------- 列表（订单 Tab 根）

  /** Router 打开了 OrderList（点 Tab、推送等）：scope=share 时直接进分享子 Tab；第一次显示才加载。 */
  private showTab(destination: RouteDestination): void {
    const list: OrderListController | null = this.listInstance;
    if (list === null) {
      return;
    }
    if (!this.tabShown) {
      this.tabShown = true;
      this.restoreConditions(list, routeString(destination, 'scope'));
    } else {
      const scope: string | null = routeString(destination, 'scope');
      if (scope !== null) {
        list.setScope(scope);
      }
    }
    this.loadTab();
  }

  private loadTab(): void {
    this.listInstance?.ensureLoaded();
    this.listPending?.controller.fetch(null);
  }

  /**
   * 进程回收后恢复子 Tab、筛选与搜索词（同一账号的记录才恢复）；路由 scope 优先。恢复决策在这里完成之后页面持久化才写盘（R3-01）。
   */
  private restoreConditions(list: OrderListController, routeScope: string | null): void {
    this.restorer.restore(list, routeScope);
    if (this.restorer.input.length > 0) {
      this.restoreInput = this.restorer.input;
    }
  }

  listConfig(): OrderListPageConfig {
    if (this.listConfigInstance !== null) {
      return this.listConfigInstance;
    }
    const list: OrderListController = this.listInstance ?? this.fallbackList();
    const config: OrderListPageConfig = new OrderListPageConfig(list, this.mask);
    config.initialInput = this.restoreInput;
    // 页面按钮直接调 Core 的入口方法（整卡 → OrderDetail、「未跟单？去找回」→ FindOrder、【去首页逛逛】→ Home；R2-06）。
    config.entries = new OrderListEntries((route: string, params: Record<string, Object>): void => {
      AppRouting.shared.openInApp(route, params);
    });
    config.onCopy = (item: OrderRecord): void => this.copy(item);
    config.onPersist = (): void => this.persistPage(list);
    config.anchor = this.anchorKeeper;
    this.listConfigInstance = config;
    return config;
  }

  /** compose 之前（不应发生）的兜底列表：同样接共享闸门。 */
  private fallbackList(): OrderListController {
    const deps: OrderListDeps = new OrderListDeps(this.api);
    this.hub.attachList(deps);
    return new OrderListController(deps);
  }

  /** 页面状态：账号短标识 + 条件 + 滚动锚点（稳定 order_id）；恢复决策完成前不写（R3-01）。 */
  private persistPage(list: OrderListController): void {
    this.restorer.persist(list);
  }

  /** 订单列表自购子 Tab 顶部的待跟单卡（全部未关闭的卡）。 */
  listPendingHost(): PendingTrackHost {
    if (this.listPending === null) {
      this.listPending = this.pendingHost();
    }
    return this.listPending;
  }

  // ---------------------------------------------------------------- 详情

  detailConfig(param: Object, back: () => void): OrderDetailPageConfig {
    const deps: OrderDetailDeps = new OrderDetailDeps(this.api);
    deps.cache = this.cacheInstance;
    deps.scope = (): string => AppOrders.scopeKey();
    this.hub.attachDetail(deps);
    const controller: OrderDetailController = new OrderDetailController(deps);
    const orderId: string = routeString(param, 'order_id') ?? '';
    const config: OrderDetailPageConfig = new OrderDetailPageConfig(controller, this.mask, orderId);
    config.routes = Routes.all;
    config.helpLinks = (): OrderRecord | null => AppOrders.helpLinks();
    config.onBack = back;
    // 页面按钮直接调 Core 的入口方法（R2-06）；CONTACT_CS（G09）走统一客服出口（客服任务接入前打开帮助中心）。
    config.entries = new OrderDetailEntries((route: string, params: Record<string, Object>): void => {
      AppRouting.shared.openInApp(route, params);
    }, (): void => AppLogin.openCustomerService(), (): boolean => controller.alive());
    config.onCopy = (item: OrderRecord): void => this.copy(item);
    // G17：本次详情请求成功时，返回列表只替换同 order_id 的那一行。
    controller.onLoaded = (detail: OrderRecord): void => {
      this.listInstance?.replaceRow(detail);
    };
    this.hub.addDetail(controller);
    return config;
  }

  /** 详情页出栈（onWillDisappear 的同步出口）：作废请求、取消传输。 */
  detailLeft(controller: OrderDetailController): void {
    controller.leave();
    this.hub.removeDetail(controller);
  }

  private static helpLinks(): OrderRecord | null {
    const store: ConfigStore | null = AppClientCore.shared.config;
    const json: string | null = store === null ? null : store.value('help_links');
    if (json === null) {
      return null;
    }
    try {
      return OrderJson.objectOf(JSON.parse(json) as Object);
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 复制

  /** 订单号复制：只经统一写入口（先记自写 hash 并确认落盘，记录失败就不写）；成功轻提示一次（系统 Toast 礼貌播报）。 */
  copy(item: OrderRecord): void {
    OrderCopy.copy(item, (text: string): Promise<boolean> => AppClipboard.shared.write(text)).then((result: string) => {
      const ui: UIContext | null = this.ui;
      if (ui === null || result === OrderCopy.NOT_COPYABLE) {
        return;
      }
      CouliToast.show(ui, OrderDraftTexts.text(result === OrderCopy.DONE ? OrderCopy.DONE_KEY : OrderCopy.FAILED_KEY));
    });
  }

  // ---------------------------------------------------------------- 待跟单卡

  /** 一个显示位置的待跟单卡（列表顶部、商品详情、搜索页）；页面出栈时调 releaseHost。 */
  pendingHost(): PendingTrackHost {
    const deps: PendingTrackDeps = new PendingTrackDeps(this.api);
    deps.scope = (): string => AppOrders.scopeKey();
    deps.session = (): string => AppRouting.shared.sessionState === SessionState.GUEST ? 'guest' : 'member';
    deps.notification = (): string => AppOrders.notificationState();
    deps.requestedBefore = (): boolean => this.readDevice(PUSH_ROW_KEY);
    deps.markRequested = (): void => this.writeDevice(PUSH_ROW_KEY, true);
    // 卡内通知行本身就是用途说明（BR-ID-13、AC-S1-84④）：经统一权限入口申请，声明入口已展示说明、不再重复弹（R1-04）。
    deps.requestPush = PendingTrackDeps.pushVia((permission: string, fromSettings: boolean, valid: () => boolean,
      purposeShown: boolean): Promise<PermissionResult> => AppClientCore.shared.requestPermission(permission,
      fromSettings, valid, purposeShown));
    this.hub.attachPending(deps);
    // 10405（x-min-version-gate）：服务端已判定强更，进强更闸门本身并落盘；没有最近一次检查结果时由 AppUpdate 立即补查。
    deps.forceUpdate = (): void => AppUpdate.shared.onServerForced();
    deps.open = (route: string, params: Record<string, Object>): void => {
      AppRouting.shared.openInApp(route, params);
    };
    const ui: PendingTrackUi = new PendingTrackUi();
    const controller: PendingTrackController = new PendingTrackController(deps);
    ui.bind(controller, (key: string, trace: string): void => this.toast(key, trace));
    const host: PendingTrackHost = new PendingTrackHost(controller, ui);
    this.hub.addPending(controller);
    return host;
  }

  releaseHost(host: PendingTrackHost): void {
    host.controller.leave();
    this.hub.removePending(host.controller);
  }

  /** 发起购买的页面：外跳后回到前台拉一次，只显示同平台那一张（G07 ②）。 */
  jumpWatcher(host: PendingTrackHost): PendingTrackJumpWatcher {
    const watcher: PendingTrackJumpWatcher = new PendingTrackJumpWatcher();
    watcher.onReturn = (platform: string): void => host.controller.fetch(platform);
    return watcher;
  }

  /**
   * 系统通知状态（G22）：已开启 → granted；未开启 → not_determined（鸿蒙查不出「从未询问」，是否申请过只认本机记录）。
   * 读不出 → system_default（不出通知行）。
   */
  private static notificationState(): string {
    try {
      return notificationEnabled() ? 'granted' : 'not_determined';
    } catch (e) {
      return 'system_default';
    }
  }

  private toast(key: string, trace: string): void {
    const ui: UIContext | null = this.ui;
    if (ui === null) {
      return;
    }
    // 统一错误消息函数：trace6 独立追加，不依赖文案里有 {trace6}（R2-04，共性第 8、16 条）。
    const text: string = PendingTrackController.toastText(key, trace);
    CouliToast.show(ui, text);
    CouliAnnounce.say(ui, text);
  }

  // ---------------------------------------------------------------- 本机偏好与页面状态

  private prefs(name: string): preferences.Preferences | null {
    const context: common.Context | null = this.context;
    if (context === null) {
      return null;
    }
    try {
      return preferences.getPreferencesSync(context, { name: name });
    } catch (e) {
      return null;
    }
  }

  private readDevice(key: string): boolean {
    const p: preferences.Preferences | null = this.prefs(DEVICE_PREFS);
    if (p === null) {
      return false;
    }
    try {
      return p.getSync(key, false) === true;
    } catch (e) {
      return false;
    }
  }

  private writeDevice(key: string, value: boolean): void {
    const p: preferences.Preferences | null = this.prefs(DEVICE_PREFS);
    if (p === null) {
      return;
    }
    try {
      p.putSync(key, value);
      p.flushSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'device pref write failed');
    }
  }

  private readPageState(): string | null {
    const p: preferences.Preferences | null = this.prefs(CouliPreferences.APP_NAMESPACE);
    if (p === null) {
      return null;
    }
    try {
      const value: preferences.ValueType = p.getSync(PAGE_STATE_KEY, '');
      return typeof value === 'string' && value.length > 0 ? value : null;
    } catch (e) {
      return null;
    }
  }

  private writePageState(value: string | null): void {
    const p: preferences.Preferences | null = this.prefs(CouliPreferences.APP_NAMESPACE);
    if (p === null) {
      return;
    }
    try {
      if (value === null) {
        p.deleteSync(PAGE_STATE_KEY);
      } else {
        p.putSync(PAGE_STATE_KEY, value);
      }
      p.flush().catch((): void => {
      });
    } catch (e) {
      // 写不进：不影响页面。
    }
  }
}

/** 通知是否已开启（notificationManager.isNotificationEnabledSync，API 12）。 */
function notificationEnabled(): boolean {
  return notificationManager.isNotificationEnabledSync();
}
