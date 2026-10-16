import { LengthMetrics } from '@kit.ArkUI';
import {
  OrderAnchorKeeper, OrderListScrollSync, OrderListViewport, OrderInputHandlers, OrderInputModel, OrderListController, OrderListEntries, OrderListSnapshot,
  OrderMonthOptions, OrderPhase, OrderListPage, OrderPlatformOptions, OrderRecord, OrderStatusGroup, OrderQuery
} from 'core';
import {
  AmountGrid, CouliAnnounce, CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliFocus, CouliFocusReturn,
  CouliFontWeight, CouliFormat, CouliIcon, CouliInteraction, CouliLayout, CouliRadius, CouliSheetPanel, CouliSpacing,
  CouliTextModifier, CouliTypography, EmptyState, ErrorState, PlatformBadge
} from 'designsystem';
import {
  DraftOrderTexts, OrderKeys, OrderMaskUi, OrderNumberRow, OrderStaleBanner, OrderStatusChip, OrderTexts, OrderThumb,
  OrderView, orderErrorText, staleText
} from './OrderViewKit';

/** 列表页的出口（entry 接 Router、剪贴板写入口、本机偏好与页面状态持久化）。 */
export class OrderListPageConfig {
  readonly controller: OrderListController;
  readonly mask: OrderMaskUi;
  texts: OrderTexts = new DraftOrderTexts();
  now: () => number = Date.now;
  /** 进程回收后恢复的输入框文字（未提交的不算条件）。 */
  initialInput: string = '';
  /**
   * 跳转入口（Core OrderListEntries；entry 注入经 Router 打开）：整卡 → OrderDetail {order_id}（带渲染时的那一行）、
   * 「未跟单？去找回」→ FindOrder（G06：标题栏常驻，不做置顶）、空态【去首页逛逛】→ Home。页面按钮直接调它的方法（R2-06）。
   */
  entries: OrderListEntries = new OrderListEntries((_r: string, _p: Record<string, Object>) => {
  });
  /** 自购单【复制】：经统一写入口写 order_no（entry 提示结果）。回调带渲染时的那一行。 */
  onCopy: (item: OrderRecord) => void = (_i: OrderRecord) => {
  };
  /** 持久化页面状态（子 Tab、分组、平台、月份、搜索词与 anchor.anchor；进程回收后恢复）。 */
  onPersist: () => void = () => {
  };
  /**
   * 滚动锚点（Core OrderAnchorKeeper；共性第 10、17 条）：进程回收后恢复时目标未加载就等、加载到后只顶对齐一次；恢复进行中保留原持久化
   * 锚点并冻结普通滚动记录，对齐完成（或用户换条件放弃）后才解冻。
   */
  anchor: OrderAnchorKeeper = new OrderAnchorKeeper();

  constructor(controller: OrderListController, mask: OrderMaskUi) {
    this.controller = controller;
    this.mask = mask;
  }
}

/** 列表卡的数据源（LazyForEach；每次快照整体换新，键带世代号）。 */
class OrderCardSource implements IDataSource {
  private cards: OrderView[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.cards.length;
  }

  getData(index: number): OrderView {
    return this.cards[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((l: DataChangeListener): boolean => l !== listener);
  }

  reload(cards: OrderView[]): void {
    this.cards = cards;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}

@ObservedV2
class OrderListModel implements OrderInputModel {
  @Trace scope: string = 'self';
  @Trace group: string = OrderStatusGroup.ALL;
  @Trace platform: string | null = null;
  @Trace month: string | null = null;
  @Trace q: string | null = null;
  @Trace inputText: string = '';
  @Trace phase: string = OrderPhase.IDLE;
  @Trace count: number = 0;
  @Trace hasMore: boolean = false;
  @Trace loadingMore: boolean = false;
  @Trace loadMoreText: string = '';
  @Trace errorText: string = '';
  @Trace errorKind: string = '';
  @Trace staleText: string = '';
  @Trace blocked: boolean = false;
  @Trace refreshing: boolean = false;
  @Trace historyText: string = '';
  @Trace earliest: string | null = null;
  @Trace filtered: boolean = false;
  @Trace platformSheet: boolean = false;
  @Trace monthSheet: boolean = false;
  @Trace generation: number = 0;
  /**
   * 渲染时绑定身份的输入回调（FU-HM-0712 第 2 轮评审 R2-01，APP-08 共性第 47 条）：本页签发、带页面编号 + 执行器实例 + 会话归属与世代
   * 的不可变值；会话换代时换新一份，搜索框、子 Tab、分组、平台 / 月份半屏经 ForEach 数据项捕获它，旧回调执行时核对不通过零写入。
   */
  @Trace inputs: OrderInputHandlers | null = null;
}

const ID_RETRY: string = 'orders_retry';
const ID_MORE_RETRY: string = 'orders_more_retry';
const ID_PLATFORM: string = 'orders_filter_platform';
const ID_MONTH: string = 'orders_filter_month';
const GROUP_ID_PREFIX: string = 'orders_group_';
const CHIP_HEIGHT: number = 32;

/**
 * 订单列表（OrderList 路由，订单 Tab 根；设计稿 Orders、OrdersShare、OrdersEmpty、OrdersShareEmpty、OrdersSearch、
 * OrdersSearchEmpty、OrdersFilterPlatform、OrdersFilterMonth、OrdersStale、AdaptNarrowOrders、A11yHitOrders）。
 * - 头部：标题「订单」+ 常驻「未跟单？去找回」；断网显示缓存时顶部提示条（role=status）。
 * - 子 Tab「自购 / 分享」（有选中状态）；搜索框（自购搜订单号或商品名、分享搜商品名；最多 40 字，按【搜索】或清空才发请求）；
 *   状态分组胶囊（横滑）；【平台】【月份】半屏单选（打开时焦点进标题、关闭后回到触发按钮）；眼睛按钮（金额隐藏）。
 * - 自购子 Tab 顶部：待跟单卡（entry 的 pendingSlot）。
 * - 列表卡整卡可点进详情；卡内【复制】独立、不穿透。底部：加载中 / 翻页失败（错误 + trace6 +【重试】）/「上拉加载更多」/ 可查范围提示。
 * - 内容限宽 600vp 居中（大屏）；可变长文案按宽度换行；命中区 48vp。
 */
@ComponentV2
export struct OrderListView {
  @Param @Require config: OrderListPageConfig;
  @BuilderParam pendingSlot: () => void = emptySlot;
  @Local model: OrderListModel = new OrderListModel();
  private source: OrderCardSource = new OrderCardSource();
  private cards: OrderView[] = [];
  private scroller: Scroller = new Scroller();
  /**
   * 滚动回调与恢复任务的接线（FU-HM-0723 第 2 轮修复 R2-01：Core OrderListScrollSync；顶部订单按内容区与卡片矩形测量，测量无效不当证据）。
   * sync.topOrderId 是最近一次确认过的顶部订单（R1-04：延迟对齐复核用）。
   */
  private sync: OrderListScrollSync | null = null;
  private shownFailure: number = 0;
  private shownRound: number = -1;
  private shownEpoch: number = 0;
  /** 待执行的锚点对齐回调（-1 = 没有；R3-02）。 */
  private alignTimer: number = -1;
  /**
   * 布局完成的回调（UIObserver didLayout；F-X-18，FU-HM-0723）：对齐已下发、列表布局滞后（还停在下发前的位置）时重新下发，直到目标真实
   * 成为顶部可见项（OrderAnchorKeeper.observe 确认）。
   */
  private layoutListener: () => void = (): void => {
    if (this.alive) {
      this.sync?.rescrollIfLagging(this.model.phase === OrderPhase.CONTENT);
    }
  };
  private alive: boolean = true;
  /** 本页实例的守卫（FU-HM-0712 R1-01）：签发列表卡票据；视图销毁时关闭，旧回调零写入。 */
  private page: OrderListPage | null = null;

  aboutToAppear(): void {
    this.page = new OrderListPage(this.config.controller);
    this.model.inputs = this.page.inputs(this.model);
    this.model.inputText = this.config.initialInput;
    this.shownEpoch = this.config.controller.snapshot.sessionEpoch;
    this.config.controller.onChange = (s: OrderListSnapshot): void => this.apply(s);
    this.sync = new OrderListScrollSync(this.config.anchor, new ListViewport(this.scroller, (i: number): string | null => {
      const view: OrderView | undefined = this.cards[i - 1];
      return view === undefined ? null : view.orderId;
    }), (): void => this.config.onPersist(), (listIndex: number): void => {
      try {
        this.scroller.scrollToIndex(listIndex, false, ScrollAlign.START);
      } catch (e) {
        // 还没有布局：等下一次布局回调。
      }
    });
    try {
      this.getUIContext().getUIObserver().on('didLayout', this.layoutListener);
    } catch (e) {
      // 拿不到观察者时只靠列表的 onScrollIndex 推进。
    }
    this.apply(this.config.controller.snapshot);
  }

  aboutToDisappear(): void {
    this.alive = false;
    try {
      this.getUIContext().getUIObserver().off('didLayout', this.layoutListener);
    } catch (e) {
      // 没注册成功，无需注销。
    }
    this.page?.close();
    if (this.alignTimer >= 0 || this.config.anchor.verifyingLayout) {
      // 页面没了：取消待执行的对齐 / 等布局确认并解冻（锚点保留原恢复目标，不滚动、不持久化）。
      this.cancelAlignTimer();
      this.config.anchor.aligned();
    }
  }

  private cancelAlignTimer(): void {
    if (this.alignTimer >= 0) {
      clearTimeout(this.alignTimer);
      this.alignTimer = -1;
    }
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: OrderListSnapshot): void {
    const m: OrderListModel = this.model;
    const texts: OrderTexts = this.config.texts;
    const now: number = this.config.now();
    m.generation++;
    if (s.sessionEpoch !== this.shownEpoch) {
      // 会话变化（共性第 19 条）：清空搜索框输入（可能是上一账号的订单号）并关闭筛选弹层。
      this.shownEpoch = s.sessionEpoch;
      m.inputText = '';
      m.platformSheet = false;
      m.monthSheet = false;
      // R2-01：按换代后的执行器重新签发输入回调的身份（旧回调手里的是旧值，核对不通过）。
      if (this.page !== null) {
        m.inputs = this.page.inputs(m);
      }
    }
    if (m.scope !== s.scope || m.q !== s.q) {
      m.inputText = s.q ?? '';
    }
    m.scope = s.scope;
    m.group = s.group;
    m.platform = s.platform;
    m.month = s.month;
    m.q = s.q;
    m.phase = s.phase;
    m.filtered = s.filtered;
    m.hasMore = s.hasMore;
    m.loadingMore = s.loadingMore;
    m.blocked = s.blocked;
    m.refreshing = s.refreshing;
    m.earliest = s.earliestVisibleDate;
    const stale: string = s.stale ? staleText(texts, s.staleFetchedAt, now) : '';
    if (stale.length > 0 && stale !== m.staleText) {
      // 顶部提示条相当于 role=status：出现时播报一次（ArkUI 没有 status 角色）。
      CouliAnnounce.say(this.getUIContext(), stale);
    }
    m.staleText = stale;
    m.errorKind = s.error === null ? '' : s.error.actionRaw;
    m.errorText = s.error === null ? '' : orderErrorText(texts, s.error.textKey, s.error.traceId, s.error.showTrace6);
    m.loadMoreText = s.loadMoreError === null ? '' : orderErrorText(texts, s.loadMoreError.textKey,
      s.loadMoreError.traceId, s.loadMoreError.showTrace6);
    if (s.earliestVisibleDate !== null) {
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('date', CouliFormat.dateOnly(s.earliestVisibleDate, now));
      m.historyText = texts.format(OrderKeys.HISTORY_HINT, vars);
    } else {
      m.historyText = '';
    }
    // FU-HM-0712（R1-01）：每张卡带渲染时由本页签发的票据（页面实例、会话、子 Tab、查询 / 结果版本、订单标识，一次取出的不可变值），
    // 回调执行前核对，不在执行时读当前会话。
    const page: OrderListPage | null = this.page;
    this.cards = s.items.map((item: OrderRecord): OrderView => new OrderView(item, texts, now,
      page === null ? null : page.ticket(item)));
    m.count = this.cards.length;
    this.source.reload(this.cards);
    if (s.round !== this.shownRound) {
      // 只在新一轮查询时回到顶部（被详情盖住、返回本页、G17 替换一行都不动滚动位置）。
      if (this.shownRound >= 0 && !s.refreshing) {
        try {
          this.scroller.scrollToIndex(0);
        } catch (e) {
          // 没有布局时忽略。
        }
      }
      this.shownRound = s.round;
    }
    this.restoreScroll(s);
    this.announceFailure(s);
    this.config.onPersist();
  }

  /**
   * 进程回收后的滚动锚点：目标加载出来后在布局就绪时顶对齐一次（列表第 0 项是页头，卡片从第 1 项起），对齐后解冻并持久化。
   * 恢复进行中锚点冻结（OrderAnchorKeeper），apply 里的持久化写的仍是原锚点。
   * 布局等待回调绑定页面、会话世代、查询轮次与恢复任务编号（R3-02；共性第 24 条）：条件变化（新一轮查询、会话变化）时取消待执行回调，
   * 回调执行前再经 keeper.commitAlign 复核，失效则不滚动、不持久化。
   */
  private restoreScroll(s: OrderListSnapshot): void {
    const keeper: OrderAnchorKeeper = this.config.anchor;
    if (!keeper.frozen) {
      this.cancelAlignTimer();
      return;
    }
    const index: number = keeper.resolve(s.items, this.config.controller.conditions().encode(), s.phase, s.round);
    if (index < 0) {
      if (!keeper.frozen) {
        // 对齐任务被新一轮查询取消：待执行的回调作废。
        this.cancelAlignTimer();
      }
      return;
    }
    this.cancelAlignTimer();
    const ticket: number = keeper.ticket;
    const epoch: number = s.sessionEpoch;
    this.alignTimer = setTimeout(() => {
      this.alignTimer = -1;
      const now: OrderListSnapshot = this.config.controller.snapshot;
      if (!this.alive || now.sessionEpoch !== epoch) {
        return;
      }
      // R1-04（APP-08 共性第 39 条）：执行前再复核一次实际位置（顶部订单 + 滚动偏移）；等待期间用户已滚动则恢复已取消，
      // 只按用户此刻的位置持久化，不滚动。
      const before: string = keeper.anchor;
      // F-X-18：通过后进入「等布局确认」，目标真实成为顶部可见项（onScrollIndex → observe）才结束恢复。
      const topNow: string = this.sync === null ? '' : this.sync.topOrderId;
      if (!keeper.commitAlignAndVerify(ticket, now.round, this.config.controller.conditions().encode(), topNow,
        this.scrollOffset(), index)) {
        if (keeper.anchor !== before) {
          this.config.onPersist();
        }
        return;
      }
      try {
        this.scroller.scrollToIndex(index + 1, false, ScrollAlign.START);
      } catch (e) {
        // 没有布局时放弃（退回顶部）。
      }
      this.config.onPersist();
    }, 0);
  }

  /** 列表此刻的实际滚动偏移（像素）；没有布局时 NaN（只按顶部订单判定）。 */
  private scrollOffset(): number {
    try {
      return this.scroller.currentOffset().yOffset;
    } catch (e) {
      return NaN;
    }
  }

  /** 翻页失败：底部错误文案 assertive 播报一次，焦点移到底部【重试】（整页失败由 ErrorState 负责）。 */
  private announceFailure(s: OrderListSnapshot): void {
    if (s.failureSeq === this.shownFailure) {
      return;
    }
    this.shownFailure = s.failureSeq;
    if (s.loadMoreError !== null && this.model.loadMoreText.length > 0) {
      CouliAnnounce.say(this.getUIContext(), this.model.loadMoreText);
      setTimeout(() => {
        CouliFocusReturn.to(this.getUIContext(), ID_MORE_RETRY);
      }, 0);
    }
  }

  /** 输入回调的数据项（ForEach 一项；还没签发时为空）：回调捕获的是渲染时这一份，不在执行时读 model.inputs。 */
  private handlerList(): OrderInputHandlers[] {
    const h: OrderInputHandlers | null = this.model.inputs;
    return h === null ? [] : [h];
  }

  private monthLabel(month: string): string {
    const parts: string[] = month.split('-');
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('year', parts[0]);
    vars.set('month', String(Number.parseInt(parts[1], 10)));
    return this.config.texts.format(OrderKeys.MONTH_ITEM, vars);
  }

  private platformLabel(): string {
    const p: string | null = this.model.platform;
    return p === null ? this.t(OrderKeys.FILTER_PLATFORM) : this.t(OrderKeys.platform(p));
  }

  private monthChipLabel(): string {
    const m: string | null = this.model.month;
    return m === null ? this.t(OrderKeys.FILTER_MONTH) : this.monthLabel(m);
  }

  @Builder
  header() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center,
      space: { main: LengthMetrics.vp(CouliSpacing.space3), cross: LengthMetrics.vp(0) } }) {
      Text(this.t(OrderKeys.TITLE))
        .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary,
          CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      Text(this.t(OrderKeys.CLAIM_ENTRY))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textLink, CouliFontWeight.medium))
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .id('orders_claim_entry')
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => this.config.entries.findOrder())
    }
    .width('100%')
  }

  @Builder
  scopeTabs() {
    ForEach(this.handlerList(), (h: OrderInputHandlers) => {
      this.scopeTabRow(h)
    }, (h: OrderInputHandlers) => 'scope_tabs_' + h.key)
  }

  @Builder
  scopeTabRow(h: OrderInputHandlers) {
    Row({ space: CouliSpacing.space1 }) {
      ForEach(['self', 'share'], (scope: string) => {
        Text(this.t(scope === 'self' ? OrderKeys.SCOPE_SELF : OrderKeys.SCOPE_SHARE))
          .attributeModifier(new CouliTextModifier(CouliTypography.body,
            this.model.scope === scope ? CouliColors.textPrimary : CouliColors.textSecondary,
            this.model.scope === scope ? CouliFontWeight.semibold : undefined))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .borderRadius(CouliRadius.button)
          .backgroundColor(this.model.scope === scope ? CouliColors.backgroundSurface : Color.Transparent)
          .id('orders_scope_' + scope)
          .accessibilityRole(AccessibilityRoleType.TAB_BAR)
          .accessibilitySelected(this.model.scope === scope)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            h.scope(scope);
          })
      }, (scope: string) => scope)
    }
    .width('100%')
    .padding(CouliSpacing.space1)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundMuted)
  }

  @Builder
  searchBox() {
    ForEach(this.handlerList(), (h: OrderInputHandlers) => {
      this.searchRow(h)
    }, (h: OrderInputHandlers) => 'search_' + h.key)
  }

  @Builder
  searchRow(h: OrderInputHandlers) {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'search', iconSize: 20, color: CouliColors.textSecondary })
        .accessibilityLevel('no')
      TextInput({ text: this.model.inputText, placeholder: this.t(this.model.scope === 'share'
        ? OrderKeys.SEARCH_PLACEHOLDER_SHARE : OrderKeys.SEARCH_PLACEHOLDER) })
        .id('orders_search')
        .layoutWeight(1)
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .padding({ left: 2, right: 0 })
        .backgroundColor(Color.Transparent)
        .fontSize(CouliTypography.body.fontSize)
        .fontColor(CouliColors.textPrimary)
        .placeholderColor(CouliColors.textSecondary)
        .maxLength(OrderQuery.MAX_Q)
        .enterKeyType(EnterKeyType.Search)
        .enabled(!this.model.blocked)
        .accessibilityText(this.t(OrderKeys.SEARCH_LABEL))
        .onChange((value: string) => {
          // R2-01：只经渲染时绑定身份的回调写输入框文字（换号后旧回调零写入）。
          h.change(value);
        })
        .onSubmit(() => {
          h.submit();
        })
      if (this.model.inputText.length > 0) {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 16, color: CouliColors.textSecondary })
        }
        .id('orders_search_clear')
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.t(OrderKeys.SEARCH_CLEAR))
        .focusBox(CouliFocus.box)
        .enabled(!this.model.blocked)
        .onClick(() => {
          // 清空也是一次提交（G11）：有搜索词时发不带 q 的请求；身份核对不通过零写入（R2-01）。
          h.clear();
        })
      }
    }
    .width('100%')
    .padding({ left: CouliSpacing.space3 })
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .borderRadius(CouliRadius.card)
    .border({ width: 1, color: CouliColors.borderControl })
    .backgroundColor(CouliColors.backgroundSurface)
  }

  /**
   * 胶囊的文字、选中、展开状态都在 builder 内按 id 现取 this.model（@Builder 的多个基本类型参数按值传递，传进来的 label / selected
   * 不随状态刷新：选了平台、月份、分组后胶囊仍显示未选中的旧文字，第 1 轮修复时在模拟器上发现）。
   */
  private pillLabel(id: string): string {
    if (id === ID_PLATFORM) {
      return this.platformLabel();
    }
    if (id === ID_MONTH) {
      return this.monthChipLabel();
    }
    return this.t(OrderStatusGroup.labelKey(id.substring(GROUP_ID_PREFIX.length)));
  }

  private pillSelected(id: string): boolean {
    if (id === ID_PLATFORM) {
      return this.model.platform !== null;
    }
    if (id === ID_MONTH) {
      return this.model.month !== null;
    }
    return this.model.group === id.substring(GROUP_ID_PREFIX.length);
  }

  /** 筛选按钮的展开状态（分组胶囊没有，null）。 */
  private pillExpanded(id: string): boolean | null {
    if (id === ID_PLATFORM) {
      return this.model.platformSheet;
    }
    if (id === ID_MONTH) {
      return this.model.monthSheet;
    }
    return null;
  }

  @Builder
  pill(id: string, trailing: string, action: () => void) {
    Column() {
      Row({ space: CouliSpacing.space1 }) {
        Text(this.pillLabel(id))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
            this.pillSelected(id) ? CouliColors.textLink : CouliColors.textPrimary,
            this.pillSelected(id) ? CouliFontWeight.semibold : undefined))
          .flexShrink(1)
        if (trailing.length > 0) {
          // 文字与箭头分开分配空间（共性第 11 条）：放不下时文字换行，箭头不被挤掉。
          Column() {
            CouliIcon({ name: trailing, iconSize: 14, color: CouliColors.textSecondary })
          }
          .flexShrink(0)
        }
      }
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .constraintSize({ minHeight: CHIP_HEIGHT })
      .borderRadius(CouliRadius.pill)
      .backgroundColor(this.pillSelected(id) ? CouliColors.brandSubtle : CouliColors.backgroundSurface)
      .border({ width: 1, color: this.pillSelected(id) ? CouliColors.brandSubtle : CouliColors.borderSubtle })
    }
    .justifyContent(FlexAlign.Center)
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget,
      maxWidth: '100%' })
    .id(id)
    .accessibilityGroup(true)
    .accessibilityText(this.pillLabel(id))
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .accessibilitySelected(this.pillExpanded(id) === null && this.pillSelected(id))
    .accessibilityDescription(this.pillExpanded(id) === null ? ''
      : this.t(this.pillExpanded(id) === true ? OrderKeys.EXPANDED : OrderKeys.COLLAPSED))
    .focusable(true)
    .focusBox(CouliFocus.box)
    .enabled(!this.model.blocked)
    .onClick(() => action())
  }

  @Builder
  groups() {
    ForEach(this.handlerList(), (h: OrderInputHandlers) => {
      this.groupRow(h)
    }, (h: OrderInputHandlers) => 'groups_' + h.key)
  }

  @Builder
  groupRow(h: OrderInputHandlers) {
    Scroll() {
      Row({ space: CouliSpacing.space2 }) {
        ForEach(OrderStatusGroup.ALL_GROUPS, (group: string) => {
          this.pill(GROUP_ID_PREFIX + group, '', () => {
            h.group(group);
          })
        }, (group: string) => group)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .width('100%')
    .align(Alignment.Start)
  }

  @Builder
  filters() {
    ForEach(this.handlerList(), (h: OrderInputHandlers) => {
      this.filterRow(h)
    }, (h: OrderInputHandlers) => 'filters_' + h.key)
  }

  @Builder
  filterRow(h: OrderInputHandlers) {
    Row() {
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(0) } }) {
        this.pill(ID_PLATFORM, 'chevron-down', () => {
          h.openSheet('platform');
        })
        this.pill(ID_MONTH, 'chevron-down', () => {
          h.openSheet('month');
        })
      }
      .layoutWeight(1)
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: this.config.mask.masked ? 'eye-off' : 'eye', iconSize: 22, color: CouliColors.textSecondary })
      }
      .id('orders_mask')
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .flexShrink(0)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.t(this.config.mask.masked ? OrderKeys.MASK_SHOW : OrderKeys.MASK_HIDE))
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => this.config.mask.toggle())
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .bindSheet(this.model.platformSheet, this.platformSheet(), {
      height: SheetSize.MEDIUM,
      dragBar: false,
      showClose: false,
      backgroundColor: CouliColors.backgroundSurface,
      onDisappear: () => {
        this.model.platformSheet = false;
        CouliFocusReturn.to(this.getUIContext(), ID_PLATFORM);
      }
    })
  }

  @Builder
  option(label: string, selected: boolean, id: string, action: () => void) {
    Row({ space: CouliSpacing.space2 }) {
      Text(label)
        .attributeModifier(new CouliTextModifier(CouliTypography.body,
          selected ? CouliColors.textLink : CouliColors.textPrimary, selected ? CouliFontWeight.semibold : undefined))
        .layoutWeight(1)
      if (selected) {
        CouliIcon({ name: 'check', iconSize: 20, color: CouliColors.textLink })
          .accessibilityLevel('no')
      }
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .border({ width: { bottom: 1 }, color: CouliColors.borderSubtle })
    .id(id)
    .accessibilityGroup(true)
    .accessibilityText(label)
    .accessibilityRole(AccessibilityRoleType.RADIO)
    .accessibilityChecked(selected)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => action())
  }

  @Builder
  platformSheet() {
    CouliSheetPanel({
      title: this.t(OrderKeys.FILTER_PLATFORM),
      closeLabel: this.t(OrderKeys.CLOSE),
      titleId: 'orders_platform_title',
      maxPanelHeight: CouliSheetPanel.maxHeight(this.getUIContext()),
      content: () => {
        this.platformOptions()
      },
      onClose: () => {
        this.model.platformSheet = false;
      }
    })
  }

  @Builder
  platformOptions() {
    ForEach(this.handlerList(), (h: OrderInputHandlers) => {
      this.platformList(h)
    }, (h: OrderInputHandlers) => 'platforms_' + h.key)
  }

  @Builder
  platformList(h: OrderInputHandlers) {
    Column() {
      this.option(this.t(OrderKeys.ALL_PLATFORMS), this.model.platform === null, 'orders_platform_all', () => {
        h.platform(null);
      })
      ForEach(OrderPlatformOptions.PLATFORMS, (p: string) => {
        this.option(this.t(OrderKeys.platform(p)), this.model.platform === p, 'orders_platform_' + p, () => {
          h.platform(p);
        })
      }, (p: string) => p)
    }
    .width('100%')
  }

  @Builder
  monthSheet() {
    CouliSheetPanel({
      title: this.t(OrderKeys.FILTER_MONTH),
      closeLabel: this.t(OrderKeys.CLOSE),
      titleId: 'orders_month_title',
      maxPanelHeight: CouliSheetPanel.maxHeight(this.getUIContext()),
      content: () => {
        this.monthOptions()
      },
      onClose: () => {
        this.model.monthSheet = false;
      }
    })
  }

  @Builder
  monthOptions() {
    ForEach(this.handlerList(), (h: OrderInputHandlers) => {
      this.monthList(h)
    }, (h: OrderInputHandlers) => 'months_' + h.key)
  }

  @Builder
  monthList(h: OrderInputHandlers) {
    Column() {
      Text(this.t(OrderKeys.MONTH_NOTE))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .width('100%')
        .margin({ bottom: CouliSpacing.space2 })
      this.option(this.t(OrderKeys.ALL_MONTHS), this.model.month === null, 'orders_month_all', () => {
        h.month(null);
      })
      ForEach(OrderMonthOptions.months(this.model.earliest, this.config.now()), (month: string) => {
        this.option(this.monthLabel(month), this.model.month === month, 'orders_month_' + month, () => {
          h.month(month);
        })
      }, (month: string) => month)
    }
    .width('100%')
  }

  @Builder
  card(view: OrderView) {
    Column({ space: CouliSpacing.space3 }) {
      Row() {
        PlatformBadge({ label: view.platformName })
        Blank()
        Text(view.timeText)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
      }
      .width('100%')
      Row({ space: CouliSpacing.space3 }) {
        OrderThumb({ url: view.imageUrl, placeholder: this.t(OrderKeys.IMAGE_PLACEHOLDER), thumbSize: 64 })
        Column({ space: CouliSpacing.space1 }) {
          if (view.title.length > 0) {
            Text(view.title)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
                CouliFontWeight.semibold))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (view.quantityText.length > 0) {
            Text(view.quantityText)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
          if (view.orderNo.length > 0) {
            OrderNumberRow({
              label: view.orderNoLabel,
              orderNo: view.orderNo,
              spoken: view.orderNoSpoken,
              copyable: view.copyable,
              copyText: this.t(OrderKeys.COPY),
              copySpoken: this.t(OrderKeys.COPY_SPOKEN),
              rowId: 'orders_card_' + view.orderId,
              onCopy: () => {
                // 绑定渲染时的这一行（APP-07 第 18 条）；FU-HM-0712：经本页守卫核对票据（页面已销毁、换条件、切子 Tab、会话已变的旧卡零写入）。
                const page: OrderListPage | null = this.page;
                if (page !== null) {
                  page.copy(view.ticket, view.raw, (item: OrderRecord): void => this.config.onCopy(item));
                }
              }
            })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')
      Divider().color(CouliColors.borderSubtle)
      if (view.listAmounts.length > 0) {
        AmountGrid({ items: view.listAmounts, stackedItems: view.listStacked, large: true, masked: this.config.mask.masked })
      }
      Column({ space: CouliSpacing.space2 }) {
        OrderStatusChip({
          label: this.config.mask.masked ? view.statusLabelMasked : view.statusLabel,
          tone: view.statusTone
        })
        if (view.monthLine.length > 0) {
          Text(view.monthLine)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .id('orders_card_' + view.orderId)
    .onClick(() => {
      const page: OrderListPage | null = this.page;
      if (page !== null) {
        page.openDetail(view.ticket, view.raw, (item: OrderRecord): void => {
          this.config.entries.openDetail(item);
        });
      }
    })
  }

  private emptyTitle(): string {
    if (this.model.filtered) {
      return this.t(OrderKeys.SEARCH_EMPTY);
    }
    return this.t(this.model.scope === 'share' ? OrderKeys.EMPTY_SHARE_TITLE : OrderKeys.EMPTY_SELF_TITLE);
  }

  private emptyMessage(): string {
    if (this.model.filtered) {
      return this.model.scope === 'share' ? this.t(OrderKeys.SEARCH_SHARE_NOTE) : '';
    }
    return this.t(this.model.scope === 'share' ? OrderKeys.EMPTY_SHARE_DESC : OrderKeys.EMPTY_SELF_DESC);
  }

  @Builder
  footer() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.model.loadingMore) {
        Row({ space: CouliSpacing.space2 }) {
          LoadingProgress().width(20).height(20).color(CouliColors.textSecondary)
          Text(this.t(OrderKeys.LOADING))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .height(CouliInteraction.minTouchTarget)
      } else if (this.model.loadMoreText.length > 0) {
        Text(this.model.loadMoreText)
          .id('orders_more_error')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
          .width('100%')
        CouliButton({
          text: this.t(OrderKeys.RETRY),
          variant: CouliButtonVariant.SECONDARY,
          buttonSize: CouliButtonSize.COMPACT,
          buttonId: ID_MORE_RETRY,
          disabled: this.model.blocked,
          onTap: () => {
            this.config.controller.retry();
          }
        })
      } else if (this.model.hasMore) {
        Text(this.t(OrderKeys.LOAD_MORE))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .id('orders_load_more')
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .enabled(!this.model.blocked)
          .onClick(() => {
            this.config.controller.loadMore();
          })
      } else if (this.model.q !== null && this.model.count > 0) {
        Text(this.foundText())
          .id('orders_found')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .accessibilityRole(AccessibilityRoleType.ROLE_NONE)
      }
      if (this.model.historyText.length > 0) {
        Text(this.model.historyText)
          .id('orders_history_hint')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
          .width('100%')
      }
    }
    .width('100%')
    .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space4 })
  }

  private foundText(): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('n', String(this.model.count));
    return this.config.texts.format(OrderKeys.SEARCH_FOUND, vars);
  }

  @Builder
  body() {
    if (this.model.phase === OrderPhase.LOADING || this.model.phase === OrderPhase.IDLE) {
      ListItem() {
        Column({ space: CouliSpacing.space3 }) {
          ForEach([0, 1], (i: number) => {
            Column()
              .width('100%')
              .height(180)
              .borderRadius(CouliRadius.card)
              .backgroundColor(CouliColors.backgroundSurface)
          }, (i: number) => 'skeleton' + i)
        }
        .accessibilityText(this.t(OrderKeys.LOADING))
      }
    } else if (this.model.phase === OrderPhase.ERROR) {
      ListItem() {
        ErrorState({
          title: this.model.errorText,
          retryText: this.t(OrderKeys.RETRY),
          retryId: ID_RETRY,
          retryDisabled: this.model.blocked,
          onRetry: () => {
            this.config.controller.retry();
          }
        })
      }
    } else if (this.model.phase === OrderPhase.EMPTY) {
      ListItem() {
        EmptyState({
          icon: this.model.filtered ? 'search' : 'orders',
          title: this.emptyTitle(),
          message: this.emptyMessage(),
          actionText: this.model.filtered ? '' : this.t(OrderKeys.GO_HOME),
          onAction: () => this.config.entries.goHome()
        })
      }
      ListItem() {
        this.footer()
      }
    } else {
      LazyForEach(this.source, (view: OrderView) => {
        ListItem() {
          this.card(view)
        }
      }, (view: OrderView) => this.model.generation + ':' + view.orderId)
      ListItem() {
        this.footer()
      }
    }
  }

  build() {
    Refresh({ refreshing: this.model.refreshing }) {
      List({ space: CouliSpacing.space3, scroller: this.scroller }) {
        ListItem() {
          Column({ space: CouliSpacing.space3 }) {
            this.header()
            if (this.model.staleText.length > 0) {
              OrderStaleBanner({ text: this.model.staleText })
            }
            this.scopeTabs()
            this.searchBox()
            Column() {
              this.groups()
              this.filters()
            }
            .width('100%')
            if (this.model.scope === 'self') {
              this.pendingSlot()
            }
          }
          .width('100%')
          .bindSheet(this.model.monthSheet, this.monthSheet(), {
            height: SheetSize.FIT_CONTENT,
            dragBar: false,
            showClose: false,
            backgroundColor: CouliColors.backgroundSurface,
            onDisappear: () => {
              this.model.monthSheet = false;
              CouliFocusReturn.to(this.getUIContext(), ID_MONTH);
            }
          })
        }
        this.body()
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2 })
      .contentEndOffset(CouliSpacing.space8)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .onScrollIndex((start: number) => {
        this.sync?.scrollIndex(start, this.model.phase === OrderPhase.CONTENT);
      })
      .onDidScroll((_offset: number, _state: ScrollState) => {
        // R1-04：顶部条目不变的滚动（同一卡片内的小幅滚动、惯性、无障碍滚动）同样交给锚点判定——恢复进行中偏移变化即取消恢复。
        // FU-HM-0723 第 2 轮修复 R2-01：onDidScroll 先于 onScrollIndex；顶部订单按内容区与卡片矩形现量，测量无效不当证据。
        this.sync?.didScroll(this.model.phase === OrderPhase.CONTENT);
      })
      .onTouch((event: TouchEvent) => {
        // FU-HM-0723 第 1 轮修复 R1-02：用户触摸列表（哪怕没移动）即接管——取消恢复（含等布局确认），之后布局回调不再下发定位。
        if (event.type !== TouchType.Down) {
          return;
        }
        if (this.sync !== null && this.sync.touchDown(this.model.phase === OrderPhase.CONTENT)) {
          this.cancelAlignTimer();
        }
      })
      .onReachEnd(() => {
        if (this.model.phase === OrderPhase.CONTENT && this.model.hasMore && this.model.loadMoreText.length === 0
          && !this.model.blocked) {
          this.config.controller.loadMore();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    .refreshOffset(64)
    .pullToRefresh(!this.model.blocked)
    .onRefreshing(() => {
      if (!this.config.controller.refresh()) {
        this.model.refreshing = false;
      }
    })
  }
}

@Builder
function emptySlot() {
}

/**
 * OrderListScrollSync 的生产测量端口（FU-HM-0723 第 2 轮修复 R2-01）：List 的 Scroller。顶部内边距与 build() 里 List 的
 * padding.top 同一个值（CouliSpacing.space2）。
 */
class ListViewport implements OrderListViewport {
  private readonly scroller: Scroller;
  private readonly idAt: (index: number) => string | null;

  constructor(scroller: Scroller, idAt: (index: number) => string | null) {
    this.scroller = scroller;
    this.idAt = idAt;
  }

  paddingTop(): number {
    return CouliSpacing.space2;
  }

  itemAt(x: number, y: number): number {
    return this.scroller.getItemIndex(CouliSpacing.space4 + x, y);
  }

  itemRect(index: number): number[] | null {
    const r: RectResult = this.scroller.getItemRect(index);
    return [r.x, r.y, r.width, r.height];
  }

  offset(): number {
    return this.scroller.currentOffset().yOffset;
  }

  orderIdAt(index: number): string | null {
    return this.idAt(index);
  }
}
