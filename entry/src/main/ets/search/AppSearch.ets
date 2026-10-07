import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ApiClient, ApiClientSearchPort, ApiOutcome, ApiRequest, ApiResult, ConfigStore, TransportFailure, PrivacyDecision, ProductDetailController, RouteDestination,
  SearchApiPort, SearchConfigPort, SearchController
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
const SEARCH_ROUTE: string = 'Search';
const PRODUCT_ROUTE: string = 'ProductDetail';
const AGENT_ROUTE: string = 'AgentChat';
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

  attachUi(ui: UIContext): void {
    this.ui = ui;
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
    const controller: SearchController = new SearchController(this.port(), () => this.statusLayers(),
      new AppSearchConfigPort());
    const config: SearchPageConfig = new SearchPageConfig(controller, this.texts);
    config.initialQuery = stringParam(param, 'q');
    config.initialPlatform = stringParam(param, 'platform');
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
    });
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
    .onWillDisappear((): void => {
      this.config?.controller.leave();
    })
  }
}

/** 路由 ProductDetail（APP-06a）。出栈规则同 Search。 */
@ComponentV2
export struct AppProductPage {
  @Param param: Object = new RouteDestination(PRODUCT_ROUTE);
  private config: ProductPageConfig | null = null;

  aboutToAppear(): void {
    this.config = AppSearch.shared.productConfig(this.param);
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
    })
  }
}
