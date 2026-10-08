import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, ConfigStore, CouliPreferences, CreditNote,
  DetailIdentity, DetailPurchasePort, PageRestorer, PageStateStore, PlatformPurchase, TransportFailure, PrivacyDecision,
  ProductDetailController, RouteDestination, SearchApiPort, SearchConfigPort, SearchController, SearchPageRecord,
  SearchPageStates, SearchRoutes
} from 'core';
import { CouliColors, CouliToast } from 'designsystem';
import { ProductDetailView, ProductPageConfig, ProductTexts } from 'product';
import { SearchPageConfig, SearchTexts, SearchView } from 'search';
import { BuildVariant } from 'entry/ets/variant/BuildVariant';
import { AppClientCore } from '../clientcore/AppClientCore';
import { AppLogin } from '../login/AppLogin';
import { AppNetwork } from '../network/AppNetwork';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { SearchDraftTexts } from './SearchDraftTexts';

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
    const store: ConfigStore | null = AppClientCore.shared.config;
    if (store === null) {
      return (): void => {
      };
    }
    return store.subscribe((): void => listener());
  }
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

/** 平台购买状态（features.platform_status，共性第 27 条）：读 ConfigStore 当前生效的配置，订阅它的变化。 */
class AppPurchasePort implements DetailPurchasePort {
  status(platform: string): string {
    return PlatformPurchase.statusOf(currentFeatures(), platform);
  }

  subscribe(listener: () => void): () => void {
    const store: ConfigStore | null = AppClientCore.shared.config;
    if (store === null) {
      return (): void => {
      };
    }
    return store.subscribe((): void => listener());
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
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? new UnavailablePort() : new ApiClientSearchPort(client);
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
    config.onBuyIntent = (card: Record<string, Object>): void => {
      this.buyIntent(card, AppSearch.publicMode());
    };
    return config;
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
    config.onAskAi = (): void => {
      // TODO(AgentChat 任务)：带商品上下文（routes.json AgentChat.context）；APP-06a 只打开 AI 助手。
      AppRouting.shared.openInApp(AGENT_ROUTE);
    };
    config.onResearch = (): void => {
      AppRouting.shared.openInApp(SEARCH_ROUTE);
    };
    config.onBuyIntent = (product: Record<string, Object>, publicMode: boolean): void => {
      this.buyIntent(product, publicMode);
    };
    return config;
  }

  private static publicMode(): boolean {
    return !AppLogin.shared.loggedIn || AppPrivacy.shared.decision === PrivacyDecision.BASIC_MODE;
  }

  /**
   * 购买意图（APP-06a 只到这里）。TODO(APP-06b)：POST /v1/links/{link_id}/open（8 秒超时、同键重试、可取消加载层）、
   * TradeJump、JumpTip、AuthSheet、link_jump 上报；基本模式与游客的购买守卫随之实现。
   */
  private buyIntent(card: Record<string, Object>, publicMode: boolean): void {
    const linkId: Object | undefined = card['link_id'];
    hilog.info(DOMAIN, TAG, 'buy intent link=%{public}s public=%{public}s',
      typeof linkId === 'string' ? 'set' : 'none', String(publicMode));
    if (BuildVariant.IS_DEBUG_BUILD && this.ui !== null) {
      CouliToast.show(this.ui, SearchDraftTexts.text('product.buy_intent.debug'));
    }
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

  aboutToAppear(): void {
    this.config = AppSearch.shared.searchConfig(this.param);
    this.config.onBack = (): void => {
      this.queryNavigationInfo()?.pathStack.pop();
    };
  }

  build() {
    NavDestination() {
      if (this.config !== null) {
        SearchView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onHidden((): void => {
      // 被详情等页面盖住：冻结滚动记录（共性第 29、32 条）。
      this.config?.onCovered(true);
    })
    .onShown((): void => {
      this.config?.onCovered(false);
    })
    .onWillDisappear((): void => {
      // 真正出栈的同步出口：执行器、滚动恢复任务、页面回调一起作废，页面状态作废（之后重开不恢复；共性第 29、39 条）。
      if (this.config !== null) {
        AppSearch.shared.searchWillDisappear(this.config);
      }
    })
  }
}

/** 路由 ProductDetail（APP-06a）。出栈规则同 Search。 */
@ComponentV2
export struct AppProductPage {
  @Param param: Object = new RouteDestination(PRODUCT_ROUTE);
  private config: ProductPageConfig | null = null;

  private identity: DetailIdentity = new DetailIdentity();

  aboutToAppear(): void {
    this.config = AppSearch.shared.productConfig(this.param);
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
      if (this.config !== null) {
        ProductDetailView({ config: this.config })
      }
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onBackPressed((): boolean => AppPrivacy.shared.blocksBack)
    .onWillDisappear((): void => {
      this.config?.controller.leave();
      AppSearch.shared.detailLeft(this.identity);
    })
  }
}
