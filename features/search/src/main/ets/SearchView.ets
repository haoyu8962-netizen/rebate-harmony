import { LengthMetrics } from '@kit.ArkUI';
import {
  PURCHASE_NOT_LAUNCHED, PURCHASE_ON, ScrollKeeperHost, SearchController, SearchDraft, SearchErrorText, SearchLayout,
  SearchPageLife, SearchPageRecord, SearchPhase, SearchResultView, SearchRows, SearchScrollKeeper, SearchSnapshot,
  SearchTextFormatter, ViewportTop
} from 'core';
import {
  CouliButton, CouliButtonSize, CouliLayout, CouliButtonVariant, CouliColors, CouliFocus, CouliFontWeight, CouliFormat, CouliIcon,
  CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography, DisclaimerFooter, DisclaimerMode,
  EmptyState, ErrorState, ProductCard, ProductCardData, ProductCardKeys, ProductCardMapper, ProductCardTexts,
  ProductCardVariant, SkeletonProductCard, CouliAnnounce, CouliFocusReturn, SearchDisclaimers
} from 'designsystem';

/**
 * 搜索页的文案键（三端同名）。契约 texts.default.json 已有的（error.*、external_page.retry）直接取；其余是 entry 草稿表
 * SearchDraftTexts 里「待定稿，不得提审」的键（TODO(N-27)）。本模块不出现中文（HM-LINT-1）。
 */
export class SearchKeys {
  static readonly BACK: string = 'search.back';
  static readonly PLACEHOLDER: string = 'search.placeholder';
  static readonly CLEAR: string = 'search.clear';
  static readonly SUBMIT: string = 'search.submit';
  static readonly FILTER_COUPON: string = 'search.filter.coupon';
  static readonly FILTER_PRICE: string = 'search.filter.price';
  static readonly FILTER_RANGE: string = 'search.filter.price_range';
  static readonly FILTER_MIN_ONLY: string = 'search.filter.price_min_only';
  static readonly FILTER_MAX_ONLY: string = 'search.filter.price_max_only';
  static readonly SHEET_MIN: string = 'search.filter.sheet.min';
  static readonly SHEET_MAX: string = 'search.filter.sheet.max';
  static readonly SHEET_NOTE: string = 'search.filter.sheet.note';
  static readonly SHEET_RESET: string = 'search.filter.sheet.reset';
  static readonly SHEET_CONFIRM: string = 'search.filter.sheet.confirm';
  static readonly SHEET_INVALID: string = 'search.filter.sheet.invalid';
  static readonly EMPTY_TITLE: string = 'search.empty.title';
  static readonly EMPTY_MESSAGE: string = 'search.empty.message';
  static readonly FALLBACK_TITLE: string = 'search.fallback.title';
  static readonly FALLBACK_NOTE: string = 'search.fallback.note';
  static readonly HISTORY_TITLE: string = 'search.history.title';
  static readonly HISTORY_CLEAR: string = 'search.history.clear';
  static readonly LOAD_MORE: string = 'search.load_more';
  static readonly LOADING: string = 'search.loading';
  static readonly END: string = 'search.end';
  static readonly RETRY: string = 'external_page.retry';
  static readonly UNAVAILABLE: string = 'error.50304';
  static readonly GENERIC: string = 'error.50001';
  /** 结果里有缓存降级报价时的顶部提示（BR-PROD-07「价格可能已变化，下单前以平台为准」；契约无键，TODO(N-27) 草稿表）。 */
  static readonly STALE_NOTICE: string = 'search.stale_notice';
  /** 比价无返利的原因与相似入口（契约 no_rebate.price_compare、no_rebate.price_compare.similar）。 */
  static readonly COMPARE_REASON: string = 'no_rebate.price_compare';
  static readonly SIMILAR: string = 'no_rebate.price_compare.similar';

  static sort(sort: string): string {
    return 'search.sort.' + sort;
  }
}

/** 排序选项（契约 SortCode 顺序，BR-PRICE-18 的显示名）。 */
const SORTS: string[] = ['relevance', 'sales_desc', 'final_price_asc', 'rebate_desc'];

/** 文案来源（entry 实现：DefaultTexts → 草稿表）。缺键返回空串。 */
export interface SearchTexts extends ProductCardTexts, SearchTextFormatter {
  text(key: string): string;

  /** {name} 替换为 vars[name]；带 trace6 等占位而没给值时用 fallback 文案。 */
  format(key: string, vars: Map<string, string>): string;
}

/**
 * 购买流程在搜索页内的展示（APP-06b；文字由 App 给，本模块不写中文）：
 * - 弹层打开时列表对读屏隐藏（弹层是模态，adaptation-a11y-spec §8）；
 * - 超时提示条（ProductBuyTimeout，与详情页一致，H-R1-02）：列表底部「网络不稳定，请重试」+【重试】（沿用原键，TRADE-22）+ 关闭（放弃本次）。
 */
@ObservedV2
export class SearchPurchaseUi {
  @Trace modal: boolean = false;
  @Trace timeoutVisible: boolean = false;
  @Trace timeoutText: string = '';
  @Trace retryText: string = '';
  @Trace closeText: string = '';
  /** 42901 限时禁用期间【重试】置灰。 */
  @Trace retryDisabled: boolean = false;
  /**
   * 购买触发 42901 后按 Retry-After 限时禁用（H-R2-07，APP-06b 共性第 36 条）：卡片购买按钮置灰、不可点、读屏读作不可用，
   * 到期恢复（与详情一致）；购买执行器仍在执行层拦截。
   */
  @Trace buyLimited: boolean = false;
  onRetryTimeout: () => void = () => {
  };
  onDismissTimeout: () => void = () => {
  };
}

/**
 * 剪贴板粘贴区在搜索页的显示（APP-07；内容由 entry 的 pasteSlot 画，本模块不写中文）：
 * - entryVisible：粘贴入口（系统 PasteButton）显示——还没搜（SearchTyping）、没有可搜平台、或 search_disabled 回落到其他平台后
 *   （共性第 11 条：不只在 IDLE 或全平台不可用时）；
 * 粘贴结果（30132 与【用商品名搜索】、轻提示）由 entry 在 pasteSlot 里按自己的状态显示，与搜索 phase 无关（共性第 10 条）。
 */
@ObservedV2
export class SearchPasteUi {
  @Trace entryVisible: boolean = true;
}

/** 页面的出口（entry 接 Router、网络与 App 能力）。 */
export class SearchPageConfig {
  readonly controller: SearchController;
  readonly texts: SearchTexts;
  /**
   * 这个页面实例的生命周期（共性第 39 条）：entry 在 onWillDisappear 经 SearchPageStates.willDisappear 调 exit，同步作废执行器、
   * 滚动恢复任务与页面回调；entry 的持久化入口凭它拒绝已出栈页面的写入。
   */
  readonly life: SearchPageLife;
  /** 路由参数（routes.json Search：q、platform 都可选）。 */
  initialQuery: string | null = null;
  initialPlatform: string | null = null;
  /** 本进程内的搜索历史（新的在前；SearchTyping「搜索历史」）。TODO(N-27)：是否持久化、条数上限未规定，不落盘。 */
  history: string[] = [];
  onHistory: (keyword: string) => void = (_k: string) => {
  };
  onClearHistory: () => void = () => {
  };
  onBack: () => void = () => {
  };
  /** 打开详情（Router：ProductDetail，platform + product_key + item_ref）。 */
  onOpenProduct: (platform: string, productKey: string, itemRef: string | null) => void =
    (_p: string, _k: string, _r: string | null) => {
    };
  /** 卡片上的购买：交给 App 的购买执行器（APP-06b open 流程）。 */
  onBuyIntent: (card: Record<string, Object>) => void = (_c: Record<string, Object>) => {
  };
  /** 比价无返利卡的【看看相似商品】（BR-PRICE-08；关闭比价弹窗后也在卡下保留，APP-06b 共性第 15 条）。 */
  onSimilar: (card: Record<string, Object>) => void = (_c: Record<string, Object>) => {
  };
  /** 购买流程的页内展示（App 的购买执行器写入）。 */
  readonly purchase: SearchPurchaseUi = new SearchPurchaseUi();
  /** 剪贴板粘贴区的显示状态（APP-07；本页按搜索快照写 entryVisible）。 */
  readonly paste: SearchPasteUi = new SearchPasteUi();
  /**
   * 进程被系统回收后重开时恢复的页面状态（共性第 20 条；entry 的 PageRestorer 交接，只给恢复出来的那一个页面实例）。
   * 有它时不看路由参数，按它恢复条件、未提交的输入与弹层草稿、滚动锚点。
   */
  restored: SearchPageRecord | null = null;
  /** 页面被覆盖 / 回到前台（entry 的 NavDestination onHidden / onShown 调；页面接上后由 SearchView 设置）。 */
  onCovered: (covered: boolean) => void = (_c: boolean) => {
  };
  /** 页面状态变化（条件、草稿、滚动锚点）：entry 持久化（共性第 17、20、29 条）。 */
  onPersist: (record: SearchPageRecord) => void = (_r: SearchPageRecord) => {
  };
  /** 同上，但要同步落盘后才返回（被覆盖、进后台前；共性第 33 条）。 */
  onPersistNow: (record: SearchPageRecord) => void = (_r: SearchPageRecord) => {
  };
  /**
   * 进后台前（EntryAbility.onBackground 经 entry 调）：按实际视口采集最新位置并同步落盘。页面接上后由 SearchView 设置。
   */
  saveNow: () => void = () => {
  };
  /**
   * 把文字填进本页搜索框并搜索（APP-07：粘贴识别 30132 的【用商品名搜索】从本页发起时不另开一页，rule-gaps A15）。页面接上后由
   * SearchView 设置；空串只清空输入、不搜。
   */
  fillAndSearch: (q: string) => void = (_q: string) => {
  };

  constructor(controller: SearchController, texts: SearchTexts) {
    this.controller = controller;
    this.texts = texts;
    this.life = new SearchPageLife(controller);
  }
}

/** 一张结果卡：原始 ProductCard（跳详情、购买意图用）+ 显示内容（limited：购买限流期间的同一张卡，购买按钮禁用）。 */
class ResultCard {
  readonly raw: Record<string, Object>;
  readonly data: ProductCardData;
  readonly limited: ProductCardData;
  readonly key: string;

  constructor(raw: Record<string, Object>, data: ProductCardData, limited: ProductCardData, key: string) {
    this.raw = raw;
    this.data = data;
    this.limited = limited;
    this.key = key;
  }
}

/** 页面状态（从执行器快照拷贝）。 */
@ObservedV2
export class SearchModel {
  @Trace inputText: string = '';
  @Trace phase: string = SearchPhase.IDLE;
  @Trace tabs: string[] = [];
  @Trace platform: string = '';
  @Trace sort: string = 'relevance';
  @Trace hasCoupon: boolean = false;
  @Trace priceMinFen: number | null = null;
  @Trace priceMaxFen: number | null = null;
  @Trace cards: ResultCard[] = [];
  @Trace fallbackCards: ResultCard[] = [];
  @Trace endReached: boolean = true;
  @Trace loadingMore: boolean = false;
  @Trace loadMoreFailed: boolean = false;
  /** 翻页失败的错误文案（带 trace6；R2-03）：列表底部先显示它，再给【重试】。 */
  @Trace loadMoreErrorText: string = '';
  @Trace errorText: string = '';
  /** 50304 search_disabled 的提示（该平台 Tab 已移除；不带重试）。 */
  @Trace noticeText: string = '';
  /** 平台 Tab、排序、筛选行是否显示（SearchLayout.showsConditionRows：平台恢复后等待用户操作时也显示，共性第 36 条）。 */
  @Trace showConditions: boolean = false;
  /** 输入态上方显示保留的关闭提示（SearchLayout.showsIdleNotice）。 */
  @Trace idleNotice: boolean = false;
  /** 结果里有缓存降级报价：顶部「价格可能已变化」提示。 */
  @Trace stale: boolean = false;
  /** 42901 限时禁用：搜索、Tab、排序、筛选、翻页、重试都置灰。 */
  @Trace blocked: boolean = false;
  /** 常驻说明区当前显示的句子（按可见卡片选，共性第 14 条）。 */
  @Trace disclaimers: string[] = [];
  /** 常驻说明区预留高度用的句子（已加载结果的全部适用说明，共性第 21 条：高度不随可见卡片来回变化）。 */
  @Trace reserveDisclaimers: string[] = [];
  @Trace history: string[] = [];
  @Trace sheetOpen: boolean = false;
  @Trace sheetMin: string = '';
  @Trace sheetMax: string = '';
  @Trace sheetError: string = '';
  @Trace generation: number = 0;
}

const ID_BACK: string = 'search_back';
const ID_INPUT: string = 'search_input';
const ID_CLEAR: string = 'search_clear';
const ID_SUBMIT: string = 'search_submit';
const ID_FILTER_COUPON: string = 'search_filter_coupon';
const ID_FILTER_PRICE: string = 'search_filter_price';
const CHIP_HEIGHT: number = 36;
const ID_LOAD_MORE_RETRY: string = 'search_load_more_retry';
/** 常驻说明区最多占结果区的比例（窄屏、200% 字号下句子多时区内滚动，不挤掉列表）。 */
const DISCLAIMER_MAX_RATIO: number = 0.3;
const TAB_BAR_HEIGHT: number = 3;
/** 价格输入：元，最多两位小数（整数分在 BR-PRICE-15 边界内另由 SearchQuery 判）。 */
const YUAN_PATTERN: RegExp = /^(\d{1,8})(?:\.(\d{1,2}))?$/;

/** 元（文本）→ 整数分：空串 null；格式不对 undefined。不经浮点（AGENTS §3.3）。 */
export function yuanToFen(text: string): number | null | undefined {
  const t: string = text.trim();
  if (t.length === 0) {
    return null;
  }
  const m: RegExpMatchArray | null = t.match(YUAN_PATTERN);
  if (m === null) {
    return undefined;
  }
  const frac: string = m[2] === undefined ? '' : m[2];
  return Number.parseInt(m[1], 10) * 100 + (frac.length === 0 ? 0 : Number.parseInt((frac + '0').substring(0, 2), 10));
}

/** 整数分 → 输入框里的元文本（「12.5」）；用 DesignSystem 的金额格式去掉「¥」。 */
function fenToYuanText(fen: number | null): string {
  if (fen === null) {
    return '';
  }
  return CouliFormat.money(fen).replace('¥', '');
}

/**
 * 搜索页（APP-06a；设计稿 Search、SearchTyping、SearchEmpty、SearchFilterPrice、SearchCardCompare、SearchDisclaimerNote、
 * AdaptNarrowSearch、A11yHitSearch）。
 * - 头部：返回 + 搜索框（清除）+【搜索】；还没搜时显示搜索历史（SearchTyping；粘贴查返利在 APP-07）。
 * - 平台 Tab：只显示 search_status=on 的平台（SearchTabs）；排序行、筛选行放不下时横滑。
 * - 结果：加载骨架 / 列表卡 / 空态 + 该平台推荐 / 错误态；滚到底自动加载更多，失败时底部【重试】；底部口径说明。
 * - 归属：页面出栈由 entry 在 onWillDisappear 调 controller.leave()（迟到响应只丢弃）；aboutToDisappear 兜底。
 */
@ComponentV2
export struct SearchView {
  @Param @Require config: SearchPageConfig;
  /** 剪贴板粘贴区（APP-07，entry 给）：固定在头部下方，不随搜索 phase 切换（共性第 10、11 条）。 */
  @BuilderParam pasteSlot: () => void = emptyPasteSlot;
  @Local model: SearchModel = new SearchModel();
  private inputController: TextInputController = new TextInputController();
  private listScroller: Scroller = new Scroller();
  /** 已处理到的失败序号（共性第 16 条）。 */
  private shownFailure: number = 0;
  /** 当前显示的卡片（列表结果，或无结果时的推荐）。 */
  private shownItems: Record<string, Object>[] = [];
  /** 每一行对应的卡片（不是卡片为 null），与 results() 的行顺序一致（SearchRows.of）。 */
  private rows: (Record<string, Object> | null)[] = [];
  /**
   * 滚动保持（共性第 17、20、29、32、33、37 条）：锚点按实际视口记、覆盖时冻结、只有新一轮查询才清；进程回收后的恢复是
   * 一个任务对象（轮次 + 目标卡 + 偏移 + 生命周期标识），拖动 / 新查询 / 出栈即取消，被覆盖暂停，按布局就绪推进。
   */
  private keeper: SearchScrollKeeper = new SearchScrollKeeper(new ListScrollHost(
    (): void => this.listScroller.scrollToIndex(0),
    (row: number, extra: number): void => this.listScroller.scrollToIndex(row, false, ScrollAlign.START,
      { extraOffset: LengthMetrics.vp(extra) }),
    (): boolean => this.config.controller.loadMore(),
    (): ViewportTop | null => this.measureTop()));
  /** 最近一次 onScrollIndex 给的可见行范围（量视口时的兜底）。 */
  private visibleFirst: number = 0;
  private visibleLast: number = -1;
  /** 布局完成的回调（UIObserver didLayout）：推进等布局的恢复任务。 */
  private layoutListener: () => void = (): void => {
    this.keeper.layoutReady();
  };
  /** 各平台购买状态（快照里的 purchase）。 */
  private purchase: Record<string, string> = {};
  /** 平台 not_launched 的卡不显示返利（共性第 31 条）：说明区也不放它的返利句。 */
  private rebateHidden: (item: Record<string, Object>) => boolean = (item: Record<string, Object>): boolean => {
    const platform: Object | undefined = item['platform'];
    return typeof platform === 'string' && this.purchase[platform as string] === PURCHASE_NOT_LAUNCHED;
  };
  /** 结果区高度（常驻说明区的上限按它算）。 */
  @Local resultsHeight: number = 0;

  aboutToAppear(): void {
    const life: SearchPageLife = this.config.life;
    // 出栈的同步出口（onWillDisappear → life.exit）同时作废：恢复任务、布局观察、被覆盖 / 进后台回调（共性第 39 条）。
    this.keeper.bindLife(life);
    life.onExit((): void => this.detach());
    // 恢复任务发现列表被读屏、键盘等移动而让位时，保存用户当前的位置（共性第 38 条）。
    this.keeper.onTakeover = (): void => this.persist();
    this.config.onCovered = (covered: boolean): void => this.setCovered(covered);
    this.config.fillAndSearch = (q: string): void => {
      this.model.inputText = q;
      if (q.trim().length > 0) {
        this.submit();
      }
    };
    this.config.saveNow = (): void => {
      if (!life.alive) {
        return;
      }
      this.keeper.capture();
      this.config.onPersistNow(this.record());
    };
    try {
      this.getUIContext().getUIObserver().on('didLayout', this.layoutListener);
    } catch (e) {
      // 拿不到观察者时只靠列表自己的回调（onAreaChange、onScrollIndex）推进。
    }
    this.model.history = this.config.history.slice();
    this.config.controller.onChange = (s: SearchSnapshot): void => {
      this.apply(s);
    };
    const restored: SearchPageRecord | null = this.config.restored;
    // 先完整装入恢复条件（锚点、轮次、恢复任务）再让执行器打开并订阅配置（共性第 37 条）。同时恢复了详情时页面一打开就被覆盖：
    // 恢复任务暂停，等 onShown（返回本页）再推进。
    this.keeper.begin(restored, restored !== null && restored.detail !== null);
    if (restored !== null) {
      // 进程回收后恢复（共性第 20 条）：输入、弹层草稿照保存的值；条件交给执行器（轮次不变，不算新查询）。
      this.model.inputText = restored.draft.inputText;
      this.model.sheetMin = restored.draft.sheetMin;
      this.model.sheetMax = restored.draft.sheetMax;
      this.model.sheetOpen = restored.draft.sheetOpen;
      this.config.controller.open(null, null, restored.conditions);
      return;
    }
    if (this.config.initialQuery !== null) {
      this.model.inputText = this.config.initialQuery;
    }
    this.config.controller.open(this.config.initialQuery, this.config.initialPlatform);
    if (this.config.initialQuery !== null) {
      this.remember(this.model.inputText);
    }
  }

  /** 当前页面状态（持久化用）。 */
  private record(): SearchPageRecord {
    const r: SearchPageRecord = new SearchPageRecord();
    r.conditions = this.config.controller.conditions();
    const d: SearchDraft = new SearchDraft();
    d.inputText = this.model.inputText;
    d.sheetOpen = this.model.sheetOpen;
    d.sheetMin = this.model.sheetMin;
    d.sheetMax = this.model.sheetMax;
    r.draft = d;
    this.keeper.anchor.fill(r);
    return r;
  }

  private persist(): void {
    if (!this.config.life.alive) {
      return;
    }
    this.config.onPersist(this.record());
  }

  /** 页面出栈（life.exit）：注销布局观察，被覆盖 / 进后台的回调改成什么都不做。 */
  private detach(): void {
    try {
      this.getUIContext().getUIObserver().off('didLayout', this.layoutListener);
    } catch (e) {
      // 没注册成功，无需注销。
    }
    this.config.onCovered = (_c: boolean): void => {
    };
    this.config.saveNow = (): void => {
    };
  }

  aboutToDisappear(): void {
    // onWillDisappear 已执行过时这里什么都不做（exit 只执行一次）；没走到 onWillDisappear 的销毁由这里兜底。
    this.config.life.exit();
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private platformName(platform: string | null): string {
    return platform === null ? '' : this.t(ProductCardKeys.platform(platform));
  }

  private toCards(items: Record<string, Object>[], prefix: string, purchase: Record<string, string>): ResultCard[] {
    const now: number = Date.now();
    return items.map((raw: Record<string, Object>, index: number) => {
      const key: Object | undefined = raw['product_key'];
      const platform: Object | undefined = raw['platform'];
      // 平台购买状态（features.platform_status，共性第 27 条）：点击前就按状态展示。
      const status: string = typeof platform === 'string' ? (purchase[platform as string] ?? PURCHASE_ON) : PURCHASE_ON;
      return new ResultCard(raw, ProductCardMapper.fromCard(raw, this.config.texts, true, now, status),
        ProductCardMapper.fromCard(raw, this.config.texts, false, now, status),
        prefix + this.model.generation + ':' + index + ':' + (typeof key === 'string' ? key as string : ''));
    });
  }

  private apply(s: SearchSnapshot): void {
    const m: SearchModel = this.model;
    this.config.paste.entryVisible = s.phase === SearchPhase.IDLE || s.phase === SearchPhase.UNAVAILABLE
      || s.notice !== null;
    m.generation++;
    m.phase = s.phase;
    m.tabs = s.tabs.slice();
    m.platform = s.platform ?? '';
    m.sort = s.sort;
    m.hasCoupon = s.hasCoupon;
    m.priceMinFen = s.priceMinFen;
    m.priceMaxFen = s.priceMaxFen;
    m.cards = this.toCards(s.items, 'r', s.purchase);
    m.fallbackCards = this.toCards(s.fallbackItems, 'f', s.purchase);
    m.endReached = s.endReached;
    m.loadingMore = s.loadingMore;
    m.loadMoreFailed = s.loadMoreFailed;
    m.loadMoreErrorText = SearchErrorText.loadMoreFooter(s, this.config.texts,
      (platform: string | null): string => this.platformName(platform), SearchKeys.GENERIC);
    m.errorText = this.errorText(s.error);
    m.noticeText = s.notice === null ? '' : this.errorText(s.notice);
    m.showConditions = SearchLayout.showsConditionRows(s);
    m.idleNotice = SearchLayout.showsIdleNotice(s);
    m.stale = s.stale;
    m.blocked = s.blocked;
    this.shownItems = SearchRows.cards(s);
    this.rows = SearchRows.of(s);
    // 常驻说明区（共性第 13、14、21、25 条）：高度按已加载结果的全部句子预留；显示的句子先按全部结果，滚动后按可见卡片更新。
    this.purchase = s.purchase;
    m.reserveDisclaimers = SearchDisclaimers.lines(this.shownItems, this.config.texts, this.rebateHidden);
    m.disclaimers = m.reserveDisclaimers.slice(0, m.reserveDisclaimers.length);
    this.announceFailure(s);
    // 滚动保持：新一轮查询回到顶部并取消恢复；同一轮里推进恢复任务（等结果、补翻页、等布局）。
    this.keeper.onSnapshot(s);
    this.persist();
  }

  /**
   * 加载失败（共性第 16 条）：首屏失败由 ErrorState 立即播报并把焦点移到【重试】；翻页失败在这里做同样的事——底部错误文案
   * （带 trace6）assertive 播报一次，焦点移到底部【重试】（42901 时按钮保持禁用）。
   */
  private announceFailure(s: SearchSnapshot): void {
    if (s.failureSeq === this.shownFailure) {
      return;
    }
    this.shownFailure = s.failureSeq;
    if (s.loadMoreFailed && this.model.loadMoreErrorText.length > 0) {
      CouliAnnounce.say(this.getUIContext(), this.model.loadMoreErrorText);
      setTimeout(() => {
        CouliFocusReturn.to(this.getUIContext(), ID_LOAD_MORE_RETRY);
      }, 0);
    }
  }

  /**
   * 列表滚动（onScrollIndex）：说明区按可见卡片选句（没有可见卡片时保留上一次的句子）；锚点按实际视口记顶部第一张可见卡
   * （恢复任务进行中、被覆盖时不记；没有可见卡片时保留最后有效的锚点，共性第 29 条）。
   */
  private onVisibleRows(first: number, last: number): void {
    this.visibleFirst = first;
    this.visibleLast = last;
    const visible: Record<string, Object>[] | null = SearchDisclaimers.visible(this.rows, first, last);
    if (visible !== null) {
      const lines: string[] = SearchDisclaimers.lines(visible, this.config.texts, this.rebateHidden);
      if (JSON.stringify(lines) !== JSON.stringify(this.model.disclaimers)) {
        this.model.disclaimers = lines;
      }
    }
    this.keeper.track();
  }

  /**
   * 按实际视口量出顶部第一张可见卡及它顶边相对视口顶部的位置（vp）。列表顶部内边距算在视口里；先按坐标取顶部那一行
   * （getItemIndex），落在行间距里时用 onScrollIndex 的首行兜底。
   */
  private measureTop(): ViewportTop | null {
    const rows: (Record<string, Object> | null)[] = this.keeper.currentRows;
    let first: number = this.visibleFirst;
    try {
      const index: number = this.listScroller.getItemIndex(CouliSpacing.space4 + 8, CouliSpacing.space3 + 1);
      if (index >= 0) {
        first = index;
      }
    } catch (e) {
      // 没有布局：按 onScrollIndex 的首行。
    }
    const last: number = Math.max(this.visibleLast, first) + 1;
    for (let i: number = Math.max(0, first); i <= last && i < rows.length; i++) {
      if (rows[i] === null) {
        continue;
      }
      try {
        // getItemRect：相对列表组件左上角的位置（vp）。
        const top: number = this.listScroller.getItemRect(i).y - CouliSpacing.space3;
        const card: number = this.keeper.cardIndexOfRow(i);
        return card < 0 ? null : new ViewportTop(card, top);
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  /**
   * 被详情覆盖 / 回到前台（AppSearchPage 的 onHidden / onShown；进后台也会 onHidden）：覆盖前先按实际视口采集再冻结，并同步落盘
   * （进程随后可能被回收，共性第 33 条）；覆盖期间恢复任务暂停，回到前台继续。
   */
  setCovered(covered: boolean): void {
    if (!this.config.life.alive) {
      return;
    }
    this.keeper.setCovered(covered);
    if (covered) {
      this.config.onPersistNow(this.record());
    }
  }

  /** 错误文案（SearchErrorText.display：统一补 trace6，共性第 12 条）：平台名用页面的显示名。 */
  private errorText(error: SearchResultView | null): string {
    return SearchErrorText.display(error, this.config.texts,
      (platform: string | null): string => this.platformName(platform),
      this.model.platform.length > 0 ? this.model.platform : null, SearchKeys.GENERIC);
  }

  private remember(keyword: string): void {
    const k: string = keyword.trim();
    if (k.length === 0) {
      return;
    }
    this.config.onHistory(k);
    this.model.history = this.config.history.slice();
  }

  private submit(): void {
    if (this.config.controller.submit(this.model.inputText)) {
      this.remember(this.model.inputText);
      this.inputController.stopEditing();
    }
  }

  private openCard(card: ResultCard): void {
    const key: Object | undefined = card.raw['product_key'];
    const platform: Object | undefined = card.raw['platform'];
    if (typeof key !== 'string' || typeof platform !== 'string') {
      // amount_unknown 卡没有 product_key（BR-PRICE-08）：不能进详情（rule-gaps：入口承载方式待补）。
      return;
    }
    const ref: Object | undefined = card.raw['item_ref'];
    this.config.onOpenProduct(platform as string, key as string, typeof ref === 'string' ? ref as string : null);
  }

  private priceChipLabel(): string {
    const m: SearchModel = this.model;
    const vars: Map<string, string> = new Map<string, string>();
    if (m.priceMinFen !== null) {
      vars.set('min', CouliFormat.money(m.priceMinFen));
    }
    if (m.priceMaxFen !== null) {
      vars.set('max', CouliFormat.money(m.priceMaxFen));
    }
    if (m.priceMinFen !== null && m.priceMaxFen !== null) {
      return this.config.texts.format(SearchKeys.FILTER_RANGE, vars);
    }
    if (m.priceMinFen !== null) {
      return this.config.texts.format(SearchKeys.FILTER_MIN_ONLY, vars);
    }
    if (m.priceMaxFen !== null) {
      return this.config.texts.format(SearchKeys.FILTER_MAX_ONLY, vars);
    }
    return this.t(SearchKeys.FILTER_PRICE);
  }

  private openSheet(): void {
    this.model.sheetMin = fenToYuanText(this.model.priceMinFen);
    this.model.sheetMax = fenToYuanText(this.model.priceMaxFen);
    this.model.sheetError = '';
    this.model.sheetOpen = true;
    this.persist();
  }

  private confirmSheet(): void {
    const min: number | null | undefined = yuanToFen(this.model.sheetMin);
    const max: number | null | undefined = yuanToFen(this.model.sheetMax);
    if (min === undefined || max === undefined
      || !this.config.controller.setFilters(this.model.hasCoupon, min, max)) {
      this.model.sheetError = this.t(SearchKeys.SHEET_INVALID);
      return;
    }
    this.model.sheetOpen = false;
    this.persist();
  }

  @Builder
  iconButton(icon: string, label: string, id: string, action: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      CouliIcon({ name: icon, iconSize: 24, color: CouliColors.textPrimary })
    }
    .id(id)
    .width(CouliInteraction.minTouchTarget)
    .height(CouliInteraction.minTouchTarget)
    .backgroundColor(Color.Transparent)
    .accessibilityText(label)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => action())
  }

  @Builder
  header() {
    Row({ space: CouliSpacing.space2 }) {
      this.iconButton('back', this.t(SearchKeys.BACK), ID_BACK, () => this.config.onBack())
      Row({ space: CouliSpacing.space1 }) {
        CouliIcon({ name: 'search', iconSize: 20, color: CouliColors.textSecondary })
          .accessibilityLevel('no')
        TextInput({ text: this.model.inputText, placeholder: this.t(SearchKeys.PLACEHOLDER),
          controller: this.inputController })
          .id(ID_INPUT)
          .layoutWeight(1)
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .padding({ left: 2, right: 0 })
          .backgroundColor(Color.Transparent)
          .fontSize(CouliTypography.body.fontSize)
          .fontColor(CouliColors.textPrimary)
          .placeholderColor(CouliColors.textSecondary)
          .maxLength(100)
          .enterKeyType(EnterKeyType.Search)
          // 进程回收后恢复的页面不自动弹键盘（恢复的是结果列表与滚动位置）。
          .defaultFocus(this.config.initialQuery === null && this.config.restored === null)
          .accessibilityText(this.t(SearchKeys.PLACEHOLDER))
          .onChange((value: string) => {
            this.model.inputText = value;
            this.persist();
          })
          .onSubmit(() => {
            this.submit();
          })
        if (this.model.inputText.length > 0) {
          Button({ type: ButtonType.Circle, stateEffect: true }) {
            CouliIcon({ name: 'close', iconSize: 16, color: CouliColors.textSecondary })
          }
          .id(ID_CLEAR)
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.t(SearchKeys.CLEAR))
          .focusBox(CouliFocus.box)
          .onClick(() => {
            this.model.inputText = '';
          })
        }
      }
      .layoutWeight(1)
      .padding({ left: CouliSpacing.space3 })
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .borderRadius(CouliRadius.button)
      .border({ width: 1, color: CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)

      CouliButton({
        text: this.t(SearchKeys.SUBMIT),
        variant: CouliButtonVariant.PRIMARY,
        buttonSize: CouliButtonSize.REGULAR,
        buttonId: ID_SUBMIT,
        disabled: this.model.blocked,
        onTap: () => this.submit()
      })
    }
    .width('100%')
    .padding({ left: CouliSpacing.space1, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
  }

  @Builder
  history() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.model.history.length > 0) {
        Row() {
          Text(this.t(SearchKeys.HISTORY_TITLE))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.semibold))
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
            .layoutWeight(1)
          Button(this.t(SearchKeys.HISTORY_CLEAR), { type: ButtonType.Normal })
            .id('search_history_clear')
            .backgroundColor(Color.Transparent)
            .fontColor(CouliColors.textLink)
            .fontSize(CouliTypography.footnote.fontSize)
            .constraintSize({ minWidth: CouliInteraction.minTouchTarget, minHeight: CouliInteraction.minTouchTarget })
            .onClick(() => {
              this.config.onClearHistory();
              this.model.history = this.config.history.slice();
            })
        }
        .width('100%')
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space2),
          cross: LengthMetrics.vp(0) } }) {
          ForEach(this.model.history, (word: string) => {
            SearchChip({ label: word, chipId: 'search_history_' + word, onTap: () => {
              this.model.inputText = word;
              this.submit();
            } })
          }, (word: string) => word)
        }
      }
    }
    .width('100%')
    .padding(CouliSpacing.space4)
  }

  @Builder
  tabsRow() {
    Scroll() {
      Row({ space: CouliSpacing.space2 }) {
        ForEach(this.model.tabs, (platform: string) => {
          Column() {
            Text(this.platformName(platform))
              .attributeModifier(new CouliTextModifier(CouliTypography.body,
                platform === this.model.platform ? CouliColors.brandPrimary : CouliColors.textSecondary,
                platform === this.model.platform ? CouliFontWeight.semibold : undefined))
              .maxLines(1)
              .padding({ bottom: CouliSpacing.space2 })
              .border({ width: { bottom: TAB_BAR_HEIGHT },
                color: platform === this.model.platform ? CouliColors.brandPrimary : Color.Transparent })
          }
          .justifyContent(FlexAlign.End)
          .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
          .constraintSize({ minWidth: CouliInteraction.minTouchTarget, minHeight: CouliInteraction.minTouchTarget })
          .id('search_tab_' + platform)
          .accessibilityGroup(true)
          .accessibilityText(this.platformName(platform))
          .accessibilitySelected(platform === this.model.platform)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .enabled(!this.model.blocked)
          .onClick(() => this.config.controller.selectTab(platform))
        }, (platform: string) => platform)
      }
      .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start)
    .border({ width: { bottom: 1 }, color: CouliColors.borderSubtle })
  }

  @Builder
  sortRow() {
    Scroll() {
      Row({ space: CouliSpacing.space2 }) {
        ForEach(SORTS, (sort: string) => {
          Text(this.t(SearchKeys.sort(sort)))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
              sort === this.model.sort ? CouliColors.textPrimary : CouliColors.textSecondary,
              sort === this.model.sort ? CouliFontWeight.semibold : undefined))
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
            .constraintSize({ minWidth: CouliInteraction.minTouchTarget, minHeight: CouliInteraction.minTouchTarget })
            .id('search_sort_' + sort)
            .accessibilityText(this.t(SearchKeys.sort(sort)))
            .accessibilitySelected(sort === this.model.sort)
            .focusable(true)
            .focusBox(CouliFocus.box)
            .enabled(!this.model.blocked)
            .onClick(() => this.config.controller.selectSort(sort))
        }, (sort: string) => sort)
      }
      .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start)
  }

  @Builder
  filterRow() {
    Scroll() {
      Row({ space: CouliSpacing.space2 }) {
        SearchChip({ label: this.t(SearchKeys.FILTER_COUPON), selected: this.model.hasCoupon, chipId: ID_FILTER_COUPON,
          onTap: () => {
            this.config.controller.setFilters(!this.model.hasCoupon, this.model.priceMinFen, this.model.priceMaxFen);
          } })
        SearchChip({ label: this.priceChipLabel(), selected: this.model.priceMinFen !== null
          || this.model.priceMaxFen !== null, chipId: ID_FILTER_PRICE, trailing: 'chevron-down',
          onTap: () => this.openSheet() })
      }
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
      .enabled(!this.model.blocked)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start)
    .bindSheet(this.model.sheetOpen, this.priceSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      backgroundColor: CouliColors.backgroundSurface,
      showClose: false,
      onDisappear: () => {
        this.model.sheetOpen = false;
        this.persist();
      }
    })
  }

  @Builder
  priceInput(value: string, placeholder: string, id: string, onValue: (v: string) => void) {
    TextInput({ text: value, placeholder: placeholder })
      .id(id)
      .type(InputType.NUMBER_DECIMAL)
      .layoutWeight(1)
      .height(CouliInteraction.minTouchTarget)
      .fontSize(CouliTypography.body.fontSize)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.backgroundMuted)
      .accessibilityText(placeholder)
      .onChange((v: string) => onValue(v))
  }

  @Builder
  priceSheet() {
    Column({ space: CouliSpacing.space4 }) {
      Text(this.t(SearchKeys.FILTER_PRICE))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      Row({ space: CouliSpacing.space2 }) {
        this.priceInput(this.model.sheetMin, this.t(SearchKeys.SHEET_MIN), 'search_price_min', (v: string) => {
          this.model.sheetMin = v;
          this.persist();
        })
        Text('–').attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .accessibilityLevel('no')
        this.priceInput(this.model.sheetMax, this.t(SearchKeys.SHEET_MAX), 'search_price_max', (v: string) => {
          this.model.sheetMax = v;
          this.persist();
        })
      }
      .width('100%')
      Text(this.model.sheetError.length > 0 ? this.model.sheetError : this.t(SearchKeys.SHEET_NOTE))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
          this.model.sheetError.length > 0 ? CouliColors.statusErrorText : CouliColors.textSecondary))
      Row({ space: CouliSpacing.space3 }) {
        CouliButton({
          text: this.t(SearchKeys.SHEET_RESET),
          variant: CouliButtonVariant.SECONDARY,
          fullWidth: true,
          buttonId: 'search_price_reset',
          onTap: () => {
            this.model.sheetMin = '';
            this.model.sheetMax = '';
            this.model.sheetError = '';
          }
        })
          .layoutWeight(1)
        CouliButton({
          text: this.t(SearchKeys.SHEET_CONFIRM),
          variant: CouliButtonVariant.PRIMARY,
          fullWidth: true,
          buttonId: 'search_price_confirm',
          onTap: () => this.confirmSheet()
        })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(CouliSpacing.space4)
    .width('100%')
  }

  /** 购买：发出意图前再核对一次该平台此刻的购买状态（共性第 27 条）；不是 on 就不发出（卡片随配置刷新显示禁用）。 */
  private buy(card: ResultCard): void {
    const platform: Object | undefined = card.raw['platform'];
    if (typeof platform !== 'string' || this.config.controller.purchaseStatus(platform as string) !== PURCHASE_ON) {
      this.config.controller.configChanged();
      return;
    }
    this.config.onBuyIntent(card.raw);
  }

  /** 比价无返利卡（no_rebate_cause=price_compare 且暂无返利，BR-PRICE-08）：卡下保留原因行与【看看相似商品】（共性第 15 条）。 */
  private compareCard(card: ResultCard): boolean {
    return card.raw['no_rebate_cause'] === 'price_compare' && card.raw['rebate_basis'] === 'no_rebate';
  }

  @Builder
  compareRow(card: ResultCard) {
    Row({ space: CouliSpacing.space2 }) {
      Text(this.t(SearchKeys.COMPARE_REASON))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .layoutWeight(1)
      Text(this.t(SearchKeys.SIMILAR))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
        .textAlign(TextAlign.Center)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => this.config.onSimilar(card.raw))
    }
    .width('100%')
    .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
  }

  @Builder
  cardItem(card: ResultCard) {
    Column() {
      ProductCard({
        // 购买 42901 限流期间（Retry-After）按钮置灰、到期恢复（H-R2-07）
        data: this.config.purchase.buyLimited ? card.limited : card.data,
        variant: ProductCardVariant.LIST,
        onBuy: () => this.buy(card)
      })
      if (this.compareCard(card)) {
        this.compareRow(card)
      }
    }
    .width('100%')
    .onClick(() => this.openCard(card))
  }

  @Builder
  listFooter() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.model.loadingMore) {
        Row({ space: CouliSpacing.space2 }) {
          LoadingProgress().width(20).height(20).color(CouliColors.textSecondary)
          Text(this.t(SearchKeys.LOADING))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .height(CouliInteraction.minTouchTarget)
      } else if (this.model.loadMoreFailed) {
        Text(this.model.loadMoreErrorText)
          .id('search_load_more_error')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
        CouliButton({
          text: this.t(SearchKeys.RETRY),
          variant: CouliButtonVariant.SECONDARY,
          buttonSize: CouliButtonSize.COMPACT,
          buttonId: ID_LOAD_MORE_RETRY,
          disabled: this.model.blocked,
          onTap: () => this.config.controller.retry()
        })
      } else if (!this.model.endReached) {
        CouliButton({
          text: this.t(SearchKeys.LOAD_MORE),
          variant: CouliButtonVariant.TEXT,
          buttonId: 'search_load_more',
          disabled: this.model.blocked,
          onTap: () => this.config.controller.loadMore()
        })
      } else if (this.model.cards.length > 0) {
        Text(this.t(SearchKeys.END))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .padding({ top: CouliSpacing.space2 })
      }
    }
    .width('100%')
  }

  /**
   * 常驻说明区（BR-PRICE-03 搜索列表每屏底部显示一次全文；共性第 14、21 条）：放在列表下方、不随列表滚走。按已加载结果的全部
   * 句子预留高度（隐藏的一层撑高度），上面一层显示当前可见卡片的句子；最多占结果区的三成，句子多（窄屏、200% 字号）时区内滚动。
   */
  @Builder
  disclaimerArea() {
    Scroll() {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          DisclaimerFooter({ lines: this.model.reserveDisclaimers, mode: DisclaimerMode.FULL })
        }
        .opacity(0)
        .accessibilityLevel('no-hide-descendants')
        Column() {
          DisclaimerFooter({ lines: this.model.disclaimers, mode: DisclaimerMode.FULL })
        }
        .id('search_disclaimer_area')
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth,
      maxHeight: this.resultsHeight > 0 ? this.resultsHeight * DISCLAIMER_MAX_RATIO : undefined })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
    .scrollBar(BarState.Auto)
    .align(Alignment.Top)
    .backgroundColor(CouliColors.backgroundCanvas)
    .border({ width: { top: 1 }, color: CouliColors.borderSubtle })
  }

  @Builder
  results() {
    List({ space: CouliSpacing.space3, scroller: this.listScroller }) {
      if (this.model.phase === SearchPhase.LOADING) {
        ForEach([0, 1, 2], (i: number) => {
          ListItem() {
            SkeletonProductCard()
          }
        }, (i: number) => 'skeleton' + i)
      } else if (this.model.phase === SearchPhase.ERROR || this.model.phase === SearchPhase.UNAVAILABLE) {
        ListItem() {
          if (this.model.phase === SearchPhase.ERROR) {
            ErrorState({
              title: this.model.errorText,
              retryText: this.t(SearchKeys.RETRY),
              retryId: 'search_retry',
              retryDisabled: this.model.blocked,
              onRetry: () => this.config.controller.retry()
            })
          } else {
            EmptyState({ icon: 'search', title: this.model.noticeText.length > 0 ? this.model.noticeText
              : this.config.texts.format(SearchKeys.UNAVAILABLE, new Map<string, string>()) })
          }
        }
      } else {
        if (this.model.noticeText.length > 0) {
          ListItem() {
            this.banner(this.model.noticeText, 'search_notice')
          }
        }
        if (this.model.stale && this.model.phase === SearchPhase.CONTENT) {
          ListItem() {
            this.banner(this.t(SearchKeys.STALE_NOTICE), 'search_stale_notice')
          }
        }
        if (this.model.phase === SearchPhase.EMPTY) {
          ListItem() {
            EmptyState({ icon: 'search', title: this.t(SearchKeys.EMPTY_TITLE),
              message: this.t(SearchKeys.EMPTY_MESSAGE) })
          }
          if (this.model.fallbackCards.length > 0) {
            ListItem() {
              Column({ space: CouliSpacing.space1 }) {
                Text(this.fallbackText(SearchKeys.FALLBACK_TITLE))
                  .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
                    CouliFontWeight.semibold))
                  .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
                Text(this.fallbackText(SearchKeys.FALLBACK_NOTE))
                  .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }
            ForEach(this.model.fallbackCards, (card: ResultCard) => {
              ListItem() {
                this.cardItem(card)
              }
            }, (card: ResultCard) => card.key)
          }
        }
        ForEach(this.model.cards, (card: ResultCard) => {
          ListItem() {
            this.cardItem(card)
          }
        }, (card: ResultCard) => card.key)
        ListItem() {
          this.listFooter()
        }
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .layoutWeight(1)
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3 })
    .contentEndOffset(CouliSpacing.space8)
    .scrollBar(BarState.Off)
    .backgroundColor(CouliColors.backgroundCanvas)
    .onReachEnd(() => {
      if (this.model.phase === SearchPhase.CONTENT && !this.model.endReached && !this.model.loadMoreFailed
        && !this.model.blocked) {
        this.config.controller.loadMore();
      }
    })
    .onScrollIndex((first: number, last: number) => {
      this.onVisibleRows(first, last);
    })
    .onScrollStop(() => {
      // 滚动停下：按实际视口重记顶部商品与偏移（同一张卡内的滑动 onScrollIndex 不会回调），再持久化。覆盖期间、恢复中不记。
      if (this.keeper.track()) {
        this.persist();
      }
    })
    .onTouch((event: TouchEvent) => {
      // 用户拖动 / 触摸列表：取消进行中的滚动恢复（共性第 33 条），之后按用户的滚动记录。
      if (event.type === TouchType.Down || event.type === TouchType.Move) {
        this.keeper.userScroll();
      }
    })
    .onAreaChange(() => {
      this.keeper.layoutReady();
    })
  }

  /** 购买超时提示条（ProductBuyTimeout，与详情页同一版式）：出现时播报由 App 的 TradeBinder 负责。 */
  @Builder
  timeoutBanner() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 20, color: CouliColors.statusErrorText })
      Text(this.config.purchase.timeoutText)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
        .layoutWeight(1)
      Text(this.config.purchase.retryText)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, this.config.purchase.retryDisabled
          ? CouliColors.textSecondary : CouliColors.statusErrorText, CouliFontWeight.semibold))
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
        .textAlign(TextAlign.Center)
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .enabled(!this.config.purchase.retryDisabled)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .id('search_trade_timeout_retry')
        .onClick(() => this.config.purchase.onRetryTimeout())
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'close', iconSize: 20, color: CouliColors.statusErrorText })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.config.purchase.closeText)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .id('search_trade_timeout_close')
      .onClick(() => this.config.purchase.onDismissTimeout())
    }
    .id('search_trade_timeout')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .padding({ left: CouliSpacing.space3, right: CouliSpacing.space1, top: CouliSpacing.space1,
      bottom: CouliSpacing.space1 })
    .margin({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .backgroundColor(CouliColors.statusErrorBackground)
    .borderRadius(CouliRadius.button)
  }

  /** 结果顶部的一行提示（search_disabled、缓存降级）：图标 + 正文，按宽度换行，读屏合为一项。 */
  @Builder
  banner(text: string, id: string) {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'info', iconSize: 16, color: CouliColors.textSecondary })
        .margin({ top: 2 })
      Text(text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .flexShrink(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundMuted)
    .accessibilityGroup(true)
    .accessibilityText(text)
    .id(id)
  }

  private fallbackText(key: string): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('platform_name', this.platformName(this.model.platform.length > 0 ? this.model.platform : null));
    return this.config.texts.format(key, vars);
  }

  build() {
    Column() {
      Column() {
        this.header()
        if (this.model.showConditions) {
          this.tabsRow()
          this.sortRow()
          this.filterRow()
        }
      }
      .width('100%')
      .backgroundColor(CouliColors.backgroundSurface)
      .border({ width: { bottom: 1 }, color: CouliColors.borderSubtle })

      this.pasteSlot()

      if (this.model.phase === SearchPhase.IDLE) {
        Scroll() {
          Column() {
            if (this.model.idleNotice && this.model.noticeText.length > 0) {
              // 平台恢复后等待用户操作（共性第 36 条）：保留的关闭提示与恢复的 Tab 一起显示，仍不自动重搜。
              Column() {
                this.banner(this.model.noticeText, 'search_notice')
              }
              .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3 })
            }
            this.history()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .backgroundColor(CouliColors.backgroundCanvas)
      } else {
        Column() {
          this.results()
          if (this.config.purchase.timeoutVisible) {
            this.timeoutBanner()
          }
          if ((this.model.phase === SearchPhase.CONTENT || this.model.phase === SearchPhase.EMPTY)
            && this.model.reserveDisclaimers.length > 0) {
            this.disclaimerArea()
          }
        }
        .layoutWeight(1)
        .width('100%')
        .onAreaChange((_old: Area, now: Area) => {
          this.resultsHeight = now.height as number;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    // 购买弹层是模态：打开时页面内容对读屏隐藏（adaptation-a11y-spec §8）
    .accessibilityLevel(this.config.purchase.modal ? 'no-hide-descendants' : 'auto')
  }
}

/** 胶囊（只看有券、价格区间、搜索历史）：视觉 36 高，命中区 48（上下留白在命中区内，A11yHitSearch）；选中态读屏报「已选中」。 */
@ComponentV2
struct SearchChip {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Param chipId: string = '';
  @Param trailing: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    // 外层是 48 高的命中区（布局导出可核对，A11yHitSearch），里面是 36 高的视觉胶囊。
    Column() {
      Row({ space: CouliSpacing.space1 }) {
        Text(this.label)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
            this.selected ? CouliColors.textLink : CouliColors.textPrimary,
            this.selected ? CouliFontWeight.medium : undefined))
          .maxLines(1)
        if (this.trailing.length > 0) {
          CouliIcon({ name: this.trailing, iconSize: 16,
            color: this.selected ? CouliColors.textLink : CouliColors.textPrimary })
        }
      }
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
      .constraintSize({ minHeight: CHIP_HEIGHT })
      .borderRadius(CouliRadius.pill)
      .backgroundColor(this.selected ? CouliColors.brandSubtle : CouliColors.backgroundSurface)
      .border(this.selected ? { width: 0 } : { width: 1, color: CouliColors.borderSubtle })
    }
    .justifyContent(FlexAlign.Center)
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
    .id(this.chipId)
    .accessibilityGroup(true)
    .accessibilityText(this.label)
    .accessibilitySelected(this.selected)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => this.onTap())
  }
}

/** 滚动保持的页面能力（List 的 Scroller；异步一律 setTimeout 0，回调前由 SearchScrollKeeper 复核归属）。 */
class ListScrollHost implements ScrollKeeperHost {
  private readonly toTop: () => void;
  private readonly toRow: (row: number, extra: number) => void;
  private readonly more: () => boolean;
  private readonly measureFn: () => ViewportTop | null;

  constructor(toTop: () => void, toRow: (row: number, extra: number) => void, more: () => boolean,
    measureFn: () => ViewportTop | null) {
    this.toTop = toTop;
    this.toRow = toRow;
    this.more = more;
    this.measureFn = measureFn;
  }

  scrollToTop(): void {
    this.toTop();
  }

  scrollToRow(row: number, extra: number): void {
    this.toRow(row, extra);
  }

  loadMore(): boolean {
    return this.more();
  }

  later(task: () => void): void {
    setTimeout(task, 0);
  }

  measure(): ViewportTop | null {
    return this.measureFn();
  }
}

@Builder
function emptyPasteSlot() {
}
