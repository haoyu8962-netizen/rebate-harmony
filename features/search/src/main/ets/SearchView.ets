import { LengthMetrics } from '@kit.ArkUI';
import {
  SearchController, SearchErrorText, SearchPhase, SearchResultView, SearchSnapshot, SearchTextFormatter
} from 'core';
import {
  CouliButton, CouliButtonSize, CouliLayout, CouliButtonVariant, CouliColors, CouliFocus, CouliFontWeight, CouliFormat, CouliIcon,
  CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography, DisclaimerFooter, DisclaimerMode,
  EmptyState, ErrorState, ProductCard, ProductCardData, ProductCardKeys, ProductCardMapper, ProductCardTexts,
  ProductCardVariant, SkeletonProductCard
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

/** 页面的出口（entry 接 Router、网络与 App 能力）。 */
export class SearchPageConfig {
  readonly controller: SearchController;
  readonly texts: SearchTexts;
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
  /** 卡片上的购买：只发出购买意图（TODO(APP-06b)：open 流程）。 */
  onBuyIntent: (card: Record<string, Object>) => void = (_c: Record<string, Object>) => {
  };

  constructor(controller: SearchController, texts: SearchTexts) {
    this.controller = controller;
    this.texts = texts;
  }
}

/** 一张结果卡：原始 ProductCard（跳详情、购买意图用）+ 显示内容。 */
class ResultCard {
  readonly raw: Record<string, Object>;
  readonly data: ProductCardData;
  readonly key: string;

  constructor(raw: Record<string, Object>, data: ProductCardData, key: string) {
    this.raw = raw;
    this.data = data;
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
  /** 结果里有缓存降级报价：顶部「价格可能已变化」提示。 */
  @Trace stale: boolean = false;
  /** 42901 限时禁用：搜索、Tab、排序、筛选、翻页、重试都置灰。 */
  @Trace blocked: boolean = false;
  @Trace disclaimers: string[] = [];
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
  @Local model: SearchModel = new SearchModel();
  private inputController: TextInputController = new TextInputController();
  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.model.history = this.config.history.slice();
    this.config.controller.onChange = (s: SearchSnapshot): void => {
      this.apply(s);
    };
    if (this.config.initialQuery !== null) {
      this.model.inputText = this.config.initialQuery;
    }
    this.config.controller.open(this.config.initialQuery, this.config.initialPlatform);
    if (this.config.initialQuery !== null) {
      this.remember(this.model.inputText);
    }
  }

  aboutToDisappear(): void {
    this.config.controller.leave();
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private platformName(platform: string | null): string {
    return platform === null ? '' : this.t(ProductCardKeys.platform(platform));
  }

  private toCards(items: Record<string, Object>[], prefix: string): ResultCard[] {
    return items.map((raw: Record<string, Object>, index: number) => {
      const key: Object | undefined = raw['product_key'];
      return new ResultCard(raw, ProductCardMapper.fromCard(raw, this.config.texts),
        prefix + this.model.generation + ':' + index + ':' + (typeof key === 'string' ? key as string : ''));
    });
  }

  private apply(s: SearchSnapshot): void {
    const m: SearchModel = this.model;
    if (s.phase === SearchPhase.LOADING && m.phase !== SearchPhase.LOADING) {
      // 新条件的第一页：列表回到顶部（不沿用上一组结果的滚动位置）。
      this.listScroller.scrollToIndex(0);
    }
    m.generation++;
    m.phase = s.phase;
    m.tabs = s.tabs.slice();
    m.platform = s.platform ?? '';
    m.sort = s.sort;
    m.hasCoupon = s.hasCoupon;
    m.priceMinFen = s.priceMinFen;
    m.priceMaxFen = s.priceMaxFen;
    m.cards = this.toCards(s.items, 'r');
    m.fallbackCards = this.toCards(s.fallbackItems, 'f');
    m.endReached = s.endReached;
    m.loadingMore = s.loadingMore;
    m.loadMoreFailed = s.loadMoreFailed;
    m.loadMoreErrorText = SearchErrorText.loadMoreFooter(s, this.config.texts,
      (platform: string | null): string => this.platformName(platform), SearchKeys.GENERIC);
    m.errorText = this.errorText(s.error);
    m.noticeText = s.notice === null ? '' : this.errorText(s.notice);
    m.stale = s.stale;
    m.blocked = s.blocked;
    m.disclaimers = this.disclaimerLines(s.items.length > 0 ? s.items : s.fallbackItems);
  }

  /** 错误文案（SearchErrorText.of）：平台名用页面的显示名。 */
  private errorText(error: SearchResultView | null): string {
    return SearchErrorText.of(error, this.config.texts, (platform: string | null): string => this.platformName(platform),
      this.model.platform.length > 0 ? this.model.platform : null, SearchKeys.GENERIC);
  }

  /** 页面底部口径说明：本页卡片 disclaimer_keys 的并集，按首次出现的顺序（BR-PRICE-17）。 */
  private disclaimerLines(items: Record<string, Object>[]): string[] {
    const keys: string[] = [];
    for (const item of items) {
      for (const key of ProductCardMapper.disclaimerKeys(item)) {
        if (keys.indexOf(key) < 0) {
          keys.push(key);
        }
      }
    }
    // 有券、无券混排的列表只放一条价格口径：price_basis.general（BR-PRICE-03 细则「无券商品与混排列表的口径说明」）。
    const mixed: boolean = keys.indexOf('price_basis') >= 0 && keys.indexOf('price_basis.general') >= 0;
    const out: string[] = [];
    for (const key of keys) {
      if (mixed && key === 'price_basis') {
        continue;
      }
      const line: string = ProductCardMapper.disclaimerText(key, this.config.texts);
      if (line.length > 0 && out.indexOf(line) < 0) {
        out.push(line);
      }
    }
    return out;
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
          .defaultFocus(this.config.initialQuery === null)
          .accessibilityText(this.t(SearchKeys.PLACEHOLDER))
          .onChange((value: string) => {
            this.model.inputText = value;
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
        })
        Text('–').attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .accessibilityLevel('no')
        this.priceInput(this.model.sheetMax, this.t(SearchKeys.SHEET_MAX), 'search_price_max', (v: string) => {
          this.model.sheetMax = v;
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

  @Builder
  cardItem(card: ResultCard) {
    Column() {
      ProductCard({
        data: card.data,
        variant: ProductCardVariant.LIST,
        onBuy: () => this.config.onBuyIntent(card.raw)
      })
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
          buttonId: 'search_load_more_retry',
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
      if (this.model.disclaimers.length > 0) {
        DisclaimerFooter({ lines: this.model.disclaimers, mode: DisclaimerMode.FULL })
      }
    }
    .width('100%')
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
        if (this.model.phase !== SearchPhase.IDLE) {
          this.tabsRow()
          this.sortRow()
          this.filterRow()
        }
      }
      .width('100%')
      .backgroundColor(CouliColors.backgroundSurface)
      .border({ width: { bottom: 1 }, color: CouliColors.borderSubtle })

      if (this.model.phase === SearchPhase.IDLE) {
        Scroll() {
          this.history()
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .backgroundColor(CouliColors.backgroundCanvas)
      } else {
        this.results()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
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
