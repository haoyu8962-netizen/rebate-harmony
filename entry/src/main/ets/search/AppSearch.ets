import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, ConfigStore, CouliPreferences, CreditNote,
  CardPatch, DetailIdentity, DetailPurchasePort, OpenPurchaseController, PageRestorer, PageStateStore, PurchasePhase,
  PurchaseState, PurchaseTimeoutBinding, PurchaseTimeoutView, TransportFailure, PrivacyDecision,
  ProductDetailController, RouteDestination, SearchApiPort, SearchConfigPort, SearchController, SearchPageRecord,
  SearchPageStates, SearchRoutes
} from 'core';
import { CouliColors } from 'designsystem';
import { ProductDetailView, ProductPageConfig, ProductPurchaseUi, ProductTexts } from 'product';
import { SearchPageConfig, SearchPurchaseUi, SearchTexts, SearchView } from 'search';
import { AppTrade } from '../trade/AppTrade';
import { PageTradeEnv, TradeBinder, TradeCardHost } from '../trade/TradeBinder';
import { TradeDraftTexts } from '../trade/TradeDraftTexts';
import { TradeKeys, TradeOverlay } from '../trade/TradeOverlay';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { SearchDraftTexts } from './SearchDraftTexts';
import { AppClipboard } from '../clipboard/AppClipboard';
import { SearchPasteArea } from '../clipboard/ClipboardViews';
import { AppOrders, PendingTrackHost } from '../orders/AppOrders';
import { PendingTrackArea } from '../orders/PendingTrackViews';
import { CouliSpacing } from 'designsystem';
import { ClipboardPageMark, PendingTrackJumpWatcher } from 'core';

const DOMAIN: number = 0x0000;
const TAG: string = 'CouliSearch';
// 路由名集中在 Core SearchRoutes（共性第 23 条：测试逐个核对它们在 routes.json 里存在；「问问 AI」是 AgentChat）。
const SEARCH_ROUTE: string = SearchRoutes.SEARCH;
const PRODUCT_ROUTE: string = SearchRoutes.PRODUCT;
const AGENT_ROUTE: string = SearchRoutes.ASK_AI;
/** 页面状态持久化的键（couli_app 命名空间：切换环境时随业务数据一起清，03 §3.6「页面缓存」）。 */
const PAGE_STATE_KEY: string = 'search.page_state';
/** 本进程搜索历史条数（TODO(N-27)：上限未规定，按设计稿一屏可见的量）。 */
const HISTORY_LIMIT: number = 10;

/** 两个页面共用的文案来源：契约字典 → 草稿表（SearchDraftTexts，待定稿不得提审）。 */
class AppSearchTexts implements SearchTexts, ProductTexts {
  text(key: string): string {
    return SearchDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    return SearchDraftTexts.format(key, vars);
  }
}

/** 网络组合之前的端口：一律当网络失败（页面显示错误态 + 重试；不发任何请求）。 */
class UnavailablePort implements SearchApiPort {
  request(_request: ApiRequest): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null,
      null, null));
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }
}

/**
 * 每次请求现取网络组合的端口（F-HM-13 防护）：页面建好那一刻网络还没组合好（AppNetwork.client 为 null）时，不把「不可用端口」定死在
 * 页面上——之后的【重试】按此刻的组合发请求；仍没组合好时按网络失败收口（不发任何请求）。
 */
class CurrentClientPort implements SearchApiPort {
  private readonly unavailable: UnavailablePort = new UnavailablePort();

  private current(): SearchApiPort {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? this.unavailable : new ApiClientSearchPort(client);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.current().request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.current().cancelOwned(owner);
  }
}

/**
 * 搜索页的配置能力（BR-PROD-10、error-codes 50304 search_disabled）：刷新 = ConfigStore.requestFresh（同一时刻最多一个在途；
 * 有在途拉取时结算后再发一次）；分界 / 已用编号 = ConfigStore 的拉取编号（R2-02 恢复 Tab 只认分界之后的配置）；订阅 = ConfigStore.subscribe（页面出栈时由 SearchController.leave 取消订阅）。
 */
class AppSearchConfigPort implements SearchConfigPort {
  refresh(): void {
    AppClientCore.shared.config?.requestFresh();
  }

  issuedMark(): number {
    const store: ConfigStore | null = AppClientCore.shared.config;
    return store === null ? 0 : store.issuedFetchId;
  }

  appliedMark(): number {
    const store: ConfigStore | null = AppClientCore.shared.config;
    return store === null ? 0 : store.appliedFetchId;
  }

  subscribe(listener: () => void): () => void {
    return subscribeStatus(listener);
  }
}

/**
 * 订阅平台状态的变化：配置（ConfigStore）与点击结果确认的平台状态（APP-06b 50301，AppTrade.overrides，共性第 5、6 条）。
 * 返回取消订阅。
 */
function subscribeStatus(listener: () => void): () => void {
  const store: ConfigStore | null = AppClientCore.shared.config;
  const offStore: () => void = store === null ? (): void => {
  } : store.subscribe((): void => listener());
  const offOverrides: () => void = AppTrade.shared.overrides.subscribe((): void => listener());
  return (): void => {
    offStore();
    offOverrides();
  };
}

/** 当前配置的 features（JSON 对象）；拿不到为 null。 */
function currentFeatures(): Record<string, Object> | null {
  const store: ConfigStore | null = AppClientCore.shared.config;
  const json: string | null = store === null ? null : store.value('features');
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

/**
 * 平台购买状态：点击结果确认的 50301（APP-06b，AppTrade.overrides，新配置到达前有效）优先，其次 features.platform_status
 * （共性第 27 条，ConfigStore 当前生效的配置）；订阅两者的变化。
 */
class AppPurchasePort implements DetailPurchasePort {
  status(platform: string): string {
    return AppTrade.shared.platformStatus(platform);
  }

  subscribe(listener: () => void): () => void {
    return subscribeStatus(listener);
  }
}

/** 页面状态的持久化（Preferences couli_app；共性第 20 条）。读写失败不影响页面，按没有记录处理。 */
class PreferencesPageStateStore implements PageStateStore {
  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /** 每次现取（切换环境的清理会删掉这个命名空间的文件与缓存，不持有旧实例）。 */
  private get prefs(): preferences.Preferences | null {
    try {
      return preferences.getPreferencesSync(this.context, { name: CouliPreferences.APP_NAMESPACE });
    } catch (e) {
      return null;
    }
  }

  read(): string | null {
    const prefs: preferences.Preferences | null = this.prefs;
    if (prefs === null) {
      return null;
    }
    try {
      const value: preferences.ValueType = prefs.getSync(PAGE_STATE_KEY, '');
      return typeof value === 'string' && value.length > 0 ? value : null;
    } catch (e) {
      return null;
    }
  }

  write(value: string | null): void {
    const prefs: preferences.Preferences | null = this.put(value);
    if (prefs === null) {
      return;
    }
    prefs.flush().catch((): void => {
      hilog.warn(DOMAIN, TAG, 'page state flush failed');
    });
  }

  /**
   * 同步落盘（被覆盖、进后台前；共性第 33 条）：putSync 后 flushSync（API 14 起，最低兼容 API 20 可用），返回时已写进文件，
   * 进程随后被回收也不丢最新位置。
   */
  writeNow(value: string | null): void {
    const prefs: preferences.Preferences | null = this.put(value);
    if (prefs === null) {
      return;
    }
    try {
      prefs.flushSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'page state flushSync failed');
    }
  }

  /** 写进 Preferences 的内存缓存；失败返回 null。 */
  private put(value: string | null): preferences.Preferences | null {
    const prefs: preferences.Preferences | null = this.prefs;
    if (prefs === null) {
      return null;
    }
    try {
      if (value === null) {
        prefs.deleteSync(PAGE_STATE_KEY);
      } else {
        prefs.putSync(PAGE_STATE_KEY, value);
      }
      return prefs;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'page state write failed');
      return null;
    }
  }
}

/** 路由参数里的字符串（Router 已按 routes.json 校验）。 */
function stringParam(param: Object, name: string): string | null {
  if (param instanceof RouteDestination) {
    const value: Object | undefined = (param as RouteDestination).params[name];
    return typeof value === 'string' ? value as string : null;
  }
  return null;
}

/**
 * App 侧的搜索与详情（APP-06a）：组合 SearchController / ProductDetailController（ApiClient、ConfigStore 的 search_status、
 * 会话与隐私状态），给页面配置，跨页跳转一律经 Router（openInApp）。
 */
export class AppSearch {
  static readonly shared: AppSearch = new AppSearch();
  private readonly texts: AppSearchTexts = new AppSearchTexts();
  /** 本进程的搜索历史（新的在前；不落盘，TODO(N-27)）。 */
  private history: string[] = [];
  private ui: UIContext | null = null;
  /**
   * 页面状态的持久化入口（Core SearchPageStates）：当前的页面状态、栈里的搜索页实例；只接受仍在栈里的最上面那个搜索页的写入，
   * 已出栈页面迟到的回调一律拒绝（共性第 39 条）。
   */
  private readonly states: SearchPageStates = new SearchPageStates();
  /** 进程回收后恢复：交给下一个打开的搜索页（一次性）。 */
  private restoreNext: SearchPageRecord | null = null;
  private restorer: PageRestorer | null = null;

  attachUi(ui: UIContext): void {
    this.ui = ui;
  }

  /**
   * 启动（EntryAbility.onCreate）：读上次进程留下的页面状态；有就交给 PageRestorer，等 Router 允许自动执行（外壳就绪、隐私有结论、
   * 本轮版本检查有结果或等满 5 秒，共性第 28 条）再恢复搜索页与盖在上面的详情页（共性第 20 条）。每次状态同步后尝试一次。
   */
  start(context: common.Context): void {
    const store: PageStateStore = new PreferencesPageStateStore(context);
    this.states.store = store;
    const routing: AppRouting = AppRouting.shared;
    const restorer: PageRestorer = new PageRestorer(routing.router,
      (): boolean => routing.navigator.pathNames().length === 0);
    restorer.onRestoreSearch = (record: SearchPageRecord): void => {
      this.restoreNext = record;
      this.states.adopt(record);
    };
    restorer.onDropped = (): void => {
      // 不恢复：只作废上次进程留下的那条；用户这次已经自己打开的搜索页（current 是它的状态）不受影响。
      const restoring: SearchPageRecord | null = this.restoreNext;
      this.restoreNext = null;
      this.states.drop(restoring);
    };
    this.restorer = restorer;
    let loaded: boolean = false;
    routing.afterSync = (): void => {
      if (this.restorer === null) {
        return;
      }
      if (!loaded) {
        // 记录在 Router 允许自动执行之后才读（那时环境对账与切换环境的清理都已结束，不会读到旧环境的记录）。
        if (!routing.router.automaticOpenAllowed()) {
          return;
        }
        loaded = true;
        const saved: SearchPageRecord | null = SearchPageRecord.decode(store.read());
        if (saved === null) {
          store.write(null);
          this.restorer = null;
          return;
        }
        this.restorer.arm(saved);
      }
      this.restorer.tryRestore();
      if (!this.restorer.armed) {
        this.restorer = null;
      }
    };
  }

  /**
   * 进后台（EntryAbility.onBackground）：搜索页在栈里时请它按实际视口采集最新位置并同步落盘；不在时把已有记录同步落盘
   * （共性第 33 条：不能只依赖滚动停下的回调与异步 flush）。
   */
  saveNow(): void {
    this.states.saveNow();
  }

  /**
   * 搜索页确定出栈（AppSearchPage.onWillDisappear，早于退场动画）：同步作废这个页面实例的执行器、滚动恢复任务与页面回调，
   * 页面状态作废（之后重开不恢复）。退场动画期间到达的布局、隐藏、滚动停止回调不再滚动、不再写记录（共性第 39 条）。
   */
  searchWillDisappear(config: SearchPageConfig): void {
    this.states.willDisappear(config.life);
    this.restoreNext = null;
  }

  /** 从搜索页打开的详情显示 / 出栈：记下或去掉盖在上面的详情页。 */
  detailShown(identity: DetailIdentity): void {
    this.states.detailShown(identity);
  }

  detailLeft(identity: DetailIdentity): void {
    this.states.detailLeft(identity);
  }

  private port(): SearchApiPort {
    return new CurrentClientPort();
  }

  private statusLayers(): Record<string, Object> {
    const store: ConfigStore | null = AppClientCore.shared.config;
    return store === null ? {} : store.searchStatusLayers();
  }

  searchConfig(param: Object): SearchPageConfig {
    const purchase: AppPurchasePort = new AppPurchasePort();
    const controller: SearchController = new SearchController(this.port(), () => this.statusLayers(),
      new AppSearchConfigPort(), Date.now, (platform: string): string => purchase.status(platform));
    const config: SearchPageConfig = new SearchPageConfig(controller, this.texts);
    config.initialQuery = stringParam(param, 'q');
    config.initialPlatform = stringParam(param, 'platform');
    config.restored = this.restoreNext;
    this.restoreNext = null;
    // 持久化回调带上页面实例：已出栈、或已不是最上面的搜索页时写入被拒绝（共性第 39 条）。
    config.onPersist = this.states.persister(config.life, false);
    config.onPersistNow = this.states.persister(config.life, true);
    this.states.attach(config.life, (): void => config.saveNow());
    config.history = this.history;
    config.onHistory = (keyword: string): void => {
      const next: string[] = [keyword].concat(this.history.filter((k: string) => k !== keyword));
      this.history.splice(0, this.history.length);
      for (const k of next.slice(0, HISTORY_LIMIT)) {
        this.history.push(k);
      }
    };
    config.onClearHistory = (): void => {
      this.history.splice(0, this.history.length);
    };
    config.onOpenProduct = (platform: string, productKey: string, itemRef: string | null): void => {
      const params: Record<string, Object> = {};
      params['platform'] = platform;
      params['product_key'] = productKey;
      if (itemRef !== null) {
        params['item_ref'] = itemRef;
      }
      AppRouting.shared.openInApp(PRODUCT_ROUTE, params);
    };
    // 购买（APP-06b）：执行器与浮层由页面在 aboutToAppear 里经 searchTrade 接上（config.onBuyIntent 在那里设置）。
    return config;
  }

  /** 搜索页的购买执行器（APP-06b）：卡片更新与重取只动那一张卡（SearchController.updateCard / refetchCard）。 */
  searchTrade(config: SearchPageConfig): TradeBinder {
    const controller: SearchController = config.controller;
    const host: SearchCardHost = new SearchCardHost(controller);
    const binder: TradeBinder = new TradeBinder(AppTrade.shared.purchaseController(new PageTradeEnv(host)));
    binder.overlay.returnFocusId = '';
    const ui: SearchPurchaseUi = config.purchase;
    ui.timeoutText = TradeDraftTexts.text(TradeKeys.TIMEOUT);
    ui.retryText = TradeDraftTexts.text(TradeKeys.RETRY);
    ui.closeText = TradeDraftTexts.text(TradeKeys.CLOSE);
    // 超时提示与同键重试（ProductBuyTimeout，TRADE-22，H-R1-02）：与详情页同一个接线；关闭 = 放弃本次
    // 购买 42901 → 卡片购买按钮按 Retry-After 置灰、到期恢复（H-R2-07，共性第 36 条；与详情一致）
    const timeout: PurchaseTimeoutBinding = new PurchaseTimeoutBinding(binder.controller, new SearchTimeoutView(ui),
      (limited: boolean): void => {
        ui.buyLimited = limited;
      });
    binder.onState = (s: PurchaseState, modal: boolean): void => {
      ui.modal = modal;
      // APP-07：模态购买弹层（AuthSheet、授权跳转等）出现即作废本页发起的粘贴读取与 parse（共性第 4 条）
      AppClipboard.shared.purchaseModal(binder.controller, SEARCH_ROUTE, modal);
      timeout.apply(s);
    };
    ui.onRetryTimeout = (): void => timeout.retry();
    ui.onDismissTimeout = (): void => timeout.dismiss();
    config.onBuyIntent = (card: Record<string, Object>): void => {
      binder.controller.buy(card, 'Search.list.buy');
    };
    config.onSimilar = (card: Record<string, Object>): void => {
      AppRouting.shared.openInApp(SEARCH_ROUTE, OpenPurchaseController.similarParams(card));
    };
    return binder;
  }

  /**
   * 详情页的购买执行器（APP-06b）：open 结果写回页面上的商品（ProductDetailController.replaceProduct）、价格字段给不全时静默重取；
   * 按钮覆盖、超时条、安装提示写进 config.purchase。补同意后重开的同一件商品自动执行一次购买（H01）。
   */
  productTrade(config: ProductPageConfig): TradeBinder {
    const controller: ProductDetailController = config.controller;
    const binder: TradeBinder = new TradeBinder(AppTrade.shared.purchaseController(new PageTradeEnv(
      new ProductCardHost(controller))));
    const timeout: PurchaseTimeoutBinding = new PurchaseTimeoutBinding(binder.controller,
      new ProductTimeoutView(config.purchase));
    binder.onState = (s: PurchaseState, modal: boolean): void => {
      AppClipboard.shared.purchaseModal(binder.controller, PRODUCT_ROUTE, modal);
      const ui: ProductPurchaseUi = config.purchase;
      ui.buyState = s.phase === PurchasePhase.LOADING ? 'loading' : (s.rateLimited ? 'disabled' : '');
      ui.buyText = s.notInstalledCopied ? TradeDraftTexts.text(TradeKeys.COPY_TPWD) : '';
      timeout.apply(s);
      ui.timeoutText = TradeDraftTexts.text(TradeKeys.TIMEOUT);
      ui.retryText = TradeDraftTexts.text(TradeKeys.RETRY);
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('platform_name', TradeDraftTexts.platformName(s.platform));
      ui.jumpNote = s.notInstalled ? TradeDraftTexts.format(TradeKeys.NOT_INSTALLED, vars) : '';
      ui.modal = modal;
    };
    config.purchase.onRetryTimeout = (): void => timeout.retry();
    config.onBuyIntent = (product: Record<string, Object>, _publicMode: boolean): void => {
      binder.controller.buy(product, 'ProductDetail.bottom.buy');
    };
    config.onSimilar = (product: Record<string, Object>): void => {
      AppRouting.shared.openInApp(SEARCH_ROUTE, OpenPurchaseController.similarParams(product));
    };
    // 补同意清栈后重开的同一件商品：按原点击的购买意图（原 link_id、原报价与返利基准）恢复一次，不拿新卡当基准（H-R1-01）
    config.onProduct = OpenPurchaseController.resumeConsentHook(binder.controller, config.productKey,
      (productKey: string) => AppTrade.shared.takeConsentResume(productKey), (): boolean => controller.buyAllowed());
    return binder;
  }

  productConfig(param: Object): ProductPageConfig {
    const controller: ProductDetailController = new ProductDetailController(this.port(), (): Record<string, Object> => {
      const context: Record<string, Object> = {};
      context['loggedIn'] = AppLogin.shared.loggedIn;
      context['privacy'] = AppPrivacy.shared.decision === PrivacyDecision.BASIC_MODE ? 'basic' : 'consented';
      return context;
    }, Date.now, new AppPurchasePort(),
      // 平台入账开关（BR-TEXT-04；锁定契约没有下发，按 features.flags 的 credit.enabled.<platform> 读，TODO(N-27)）。
      // 与购买状态同一个 ConfigStore 订阅：只切换入账开关也更新已打开的详情（共性第 35 条）。
      (platform: string): boolean | null => CreditNote.switchOf(currentFeatures(), platform),
      (product: Record<string, Object>, creditSwitch: boolean | null): boolean => CreditNote.visible(product, creditSwitch));
    const config: ProductPageConfig = new ProductPageConfig(controller, this.texts);
    config.platform = stringParam(param, 'platform') ?? '';
    config.productKey = stringParam(param, 'product_key') ?? '';
    config.itemRef = stringParam(param, 'item_ref');
    // APP-07 G09：从剪贴板 parse 打开的详情，以进程内的卡片种子显示（不重取，购买沿用 parse 卡的 link_id）
    config.seed = AppClipboard.shared.takeSeed(param);
    config.onAskAi = (): void => {
      // TODO(AgentChat 任务)：带商品上下文（routes.json AgentChat.context）；APP-06a 只打开 AI 助手。
      AppRouting.shared.openInApp(AGENT_ROUTE);
    };
    config.onResearch = (): void => {
      AppRouting.shared.openInApp(SEARCH_ROUTE);
    };
    return config;
  }
}

/** 搜索页的超时提示条（SearchPurchaseUi）。 */
class SearchTimeoutView implements PurchaseTimeoutView {
  private readonly ui: SearchPurchaseUi;

  constructor(ui: SearchPurchaseUi) {
    this.ui = ui;
  }

  show(visible: boolean, retryDisabled: boolean): void {
    this.ui.timeoutVisible = visible;
    this.ui.retryDisabled = retryDisabled;
  }
}

/** 详情页的超时提示条（ProductPurchaseUi）。 */
class ProductTimeoutView implements PurchaseTimeoutView {
  private readonly ui: ProductPurchaseUi;

  constructor(ui: ProductPurchaseUi) {
    this.ui = ui;
  }

  show(visible: boolean, _retryDisabled: boolean): void {
    this.ui.timeoutVisible = visible;
  }
}

/** 搜索页给购买执行器的卡片能力。 */
class SearchCardHost implements TradeCardHost {
  private readonly controller: SearchController;

  constructor(controller: SearchController) {
    this.controller = controller;
  }

  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    this.controller.updateCard(target, transform);
  }

  refetchCard(target: Record<string, Object>,
    merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void {
    this.controller.refetchCard(target, merge);
  }
}

/** 详情页给购买执行器的卡片能力：只认页面上的这件商品。 */
class ProductCardHost implements TradeCardHost {
  private readonly controller: ProductDetailController;

  constructor(controller: ProductDetailController) {
    this.controller = controller;
  }

  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    const current: Record<string, Object> | null = this.controller.snapshot.product;
    if (current !== null && CardPatch.sameCard(current, target)) {
      this.controller.replaceProduct(transform);
    }
  }

  refetchCard(_target: Record<string, Object>,
    merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void {
    this.controller.refetch(merge);
  }
}

/**
 * 路由 Search（APP-06a）。页面一确定出栈（onWillDisappear，早于退场动画）就作废在途请求并取消传输（lessons：出栈即失效）；
 * 只被别的页面盖住（进详情）不触发。
 */
@ComponentV2
export struct AppSearchPage {
  @Param param: Object = new RouteDestination(SEARCH_ROUTE);
  private config: SearchPageConfig | null = null;
  private trade: TradeBinder | null = null;
  /** APP-08 G07 ②：从本页列表卡外跳购买、回到前台后拉一次待跟单卡，只显示同平台那一张。 */
  private pending: PendingTrackHost | null = null;
  private watcher: PendingTrackJumpWatcher | null = null;
  /** 剪贴板执行层的页面实例编号与这次显示的标记（FU-CLIP R2-02：退出回调只作废仍归属本页这次显示的操作）。 */
  private clipboardPage: number = 0;
  private clipboardMark: ClipboardPageMark | null = null;

  @Builder
  pendingSlot() {
    if (this.pending !== null) {
      Column() {
        PendingTrackArea({ ui: this.pending.ui })
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2 })
    }
  }

  /** APP-07：SearchTyping「粘贴查返利」与粘贴结果（30132【用商品名搜索】填进本页搜索框，rule-gaps A15）。 */
  @Builder
  pasteSlot() {
    if (this.config !== null) {
      SearchPasteArea({
        paste: this.config.paste,
        fill: (q: string): void => {
          this.config?.fillAndSearch(q);
        }
      })
    }
  }

  aboutToAppear(): void {
    this.clipboardPage = AppClipboard.shared.pageInstance();
    this.config = AppSearch.shared.searchConfig(this.param);
    this.config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // APP-06b：卡片上的购买交给本页的购买执行器（浮层盖在列表上）。
    this.trade = AppSearch.shared.searchTrade(this.config);
    this.trade.attachUi(this.getUIContext());
    this.attachPending(this.config, this.trade);
  }

  /** 待跟单卡：点购买时开始计，外跳执行后回到前台拉一次（APP-06b 的外跳回前台时机）。 */
  private attachPending(config: SearchPageConfig, trade: TradeBinder): void {
    const host: PendingTrackHost = AppOrders.shared.pendingHost();
    const watcher: PendingTrackJumpWatcher = AppOrders.shared.jumpWatcher(host);
    this.pending = host;
    this.watcher = watcher;
    const buy: (card: Record<string, Object>) => void = config.onBuyIntent;
    config.onBuyIntent = (card: Record<string, Object>): void => {
      const platform: Object | undefined = card['platform'];
      if (typeof platform === 'string') {
        watcher.buyStarted(platform as string);
      }
      buy(card);
    };
    trade.controller.onJumped = (platform: string): void => watcher.jumpedOut(platform);
  }

  build() {
    NavDestination() {
      Stack() {
        if (this.config !== null) {
          SearchView({
            config: this.config, pasteSlot: (): void => {
              this.pasteSlot()
            }, pendingSlot: (): void => {
              this.pendingSlot()
            }
          })
        }
        if (this.trade !== null) {
          TradeOverlay({ model: this.trade.overlay })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack || (this.trade !== null && this.trade.overlay.back()))
    .onHidden((): void => {
      // APP-07：被盖住即作废本页发起的粘贴读取与 parse（回到同一实例也不恢复，共性第 2 条）；只作废仍归属本页这次显示的（R2-02）。
      AppClipboard.shared.pageLeft(this.clipboardMark);
      // 被详情等页面盖住：冻结滚动记录（共性第 29、32 条）；作废购买的续执行许可（APP-06b 共性第 3 条）。
      this.config?.onCovered(true);
      if (this.trade !== null) {
        AppTrade.shared.pageVisible(this.trade.controller, false);
      }
      this.watcher?.onBackground();
      // FU-HM-0712 R1-02：被盖住即离开待跟单卡的显示位置（卡片与通知许可同步作废）。
      this.pending?.ui.position?.setCovered(true);
    })
    .onShown((): void => {
      // FU-CLIP R2-02：登记为当前界面的主人（新的显示世代）。
      this.clipboardMark = AppClipboard.shared.pageShown(this.clipboardPage);
      this.config?.onCovered(false);
      if (this.trade !== null) {
        AppTrade.shared.pageVisible(this.trade.controller, true);
      }
      this.watcher?.onForeground();
      // 回到可见：取新的位置世代（外跳回来的拉取已由 watcher 发起时不重复拉）。
      this.pending?.ui.position?.setCovered(false);
    })
    .onWillDisappear((): void => {
      // APP-07：出栈的同步出口，本页发起的粘贴读取与 parse 一并作废；界面已换主人（如分享清栈回首页）时不动新界面（R2-02）。
      AppClipboard.shared.pageLeft(this.clipboardMark);
      this.clipboardMark = null;
      // 真正出栈的同步出口：执行器、滚动恢复任务、页面回调一起作废，页面状态作废（之后重开不恢复；共性第 29、39 条）。
      if (this.config !== null) {
        AppSearch.shared.searchWillDisappear(this.config);
      }
      // 购买执行器同步作废：在途 open 取消、本页登记的购买待办删除（APP-06b）。
      if (this.trade !== null) {
        AppTrade.shared.release(this.trade.controller);
      }
      if (this.pending !== null) {
        AppOrders.shared.releaseHost(this.pending);
        this.pending = null;
      }
    })
  }
}

/** 路由 ProductDetail（APP-06a）。出栈规则同 Search。 */
@ComponentV2
export struct AppProductPage {
  @Param param: Object = new RouteDestination(PRODUCT_ROUTE);
  private config: ProductPageConfig | null = null;
  private trade: TradeBinder | null = null;
  /** APP-08 G07 ②：从本页外跳购买、回到前台后拉一次待跟单卡，只显示同平台那一张（设计稿 ProductPendingTrack）。 */
  private pending: PendingTrackHost | null = null;
  private watcher: PendingTrackJumpWatcher | null = null;

  @Builder
  pendingSlot() {
    if (this.pending !== null) {
      PendingTrackArea({ ui: this.pending.ui })
    }
  }

  private identity: DetailIdentity = new DetailIdentity();

  aboutToAppear(): void {
    this.config = AppSearch.shared.productConfig(this.param);
    // APP-06b：购买交给本页的购买执行器（浮层盖在详情上）。
    this.trade = AppSearch.shared.productTrade(this.config);
    this.trade.attachUi(this.getUIContext());
    const host: PendingTrackHost = AppOrders.shared.pendingHost();
    const watcher: PendingTrackJumpWatcher = AppOrders.shared.jumpWatcher(host);
    this.pending = host;
    this.watcher = watcher;
    const productConfig: ProductPageConfig = this.config;
    const buy: (product: Record<string, Object>, publicMode: boolean) => void = productConfig.onBuyIntent;
    productConfig.onBuyIntent = (product: Record<string, Object>, publicMode: boolean): void => {
      watcher.buyStarted(productConfig.platform);
      buy(product, publicMode);
    };
    this.trade.controller.onJumped = (platform: string): void => watcher.jumpedOut(platform);
    this.identity.platform = this.config.platform;
    this.identity.productKey = this.config.productKey;
    this.identity.itemRef = this.config.itemRef;
    // 盖在搜索页上的详情：记进页面状态，进程回收后一起恢复（共性第 20 条）。
    AppSearch.shared.detailShown(this.identity);
    this.config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
    // 30143【重新搜索】：从搜索页进来的回到搜索页（保留关键词与条件）；否则经 Router 打开搜索页。
    this.config.onResearch = (): void => {
      const stack: NavPathStack | undefined = this.queryNavigationInfo()?.pathStack;
      if (stack !== undefined && stack.getAllPathName().indexOf(SEARCH_ROUTE) >= 0) {
        stack.pop();
      } else {
        AppRouting.shared.openInApp(SEARCH_ROUTE);
      }
    };
  }

  build() {
    NavDestination() {
      Stack() {
        if (this.config !== null) {
          ProductDetailView({
            config: this.config, pendingSlot: (): void => {
              this.pendingSlot()
            }
          })
        }
        if (this.trade !== null) {
          TradeOverlay({ model: this.trade.overlay })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack || (this.trade !== null && this.trade.overlay.back()))
    .onHidden((): void => {
      // 被登录页等盖住：作废购买的续执行许可（APP-06b 共性第 3 条）。
      if (this.trade !== null) {
        AppTrade.shared.pageVisible(this.trade.controller, false);
      }
      this.watcher?.onBackground();
      // FU-HM-0712 R1-02：被盖住即离开待跟单卡的显示位置（卡片与通知许可同步作废）。
      this.pending?.ui.position?.setCovered(true);
    })
    .onShown((): void => {
      // 回到本页（含登录页关掉）：等前台的自动动作、登录后的购买待办（BR-ID-10）。
      if (this.trade !== null) {
        AppTrade.shared.pageVisible(this.trade.controller, true);
      }
      this.watcher?.onForeground();
      // 回到可见：取新的位置世代（外跳回来的拉取已由 watcher 发起时不重复拉）。
      this.pending?.ui.position?.setCovered(false);
    })
    .onWillDisappear((): void => {
      if (this.pending !== null) {
        AppOrders.shared.releaseHost(this.pending);
        this.pending = null;
      }
      this.config?.controller.leave();
      AppSearch.shared.detailLeft(this.identity);
      // 购买执行器同步作废：在途 open 取消、本页登记的购买待办删除（APP-06b）。
      if (this.trade !== null) {
        AppTrade.shared.release(this.trade.controller);
      }
    })
  }
}
