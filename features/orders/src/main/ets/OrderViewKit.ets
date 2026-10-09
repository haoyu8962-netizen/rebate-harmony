import {
  CreditPeriodText, OrderAmountCells, OrderDraftTexts, OrderJson, OrderNumberDisplay, OrderRecord, OrderStatus,
  OrderMessages, OrderStatusText, OrderTitleImage
} from 'core';
import {
  AmountGridItem, AmountTone, CouliChip, CouliChipTone, CouliColors, CouliFocus, CouliFormat, CouliIcon,
  CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography, CouliFontWeight
} from 'designsystem';

/**
 * 订单页的文案来源（entry 给：契约字典 → Core OrderDraftTexts 草稿表，TODO(N-31)）。本模块不出现中文（HM-LINT-1）。
 */
export interface OrderTexts {
  text(key: string): string;

  format(key: string, vars: Map<string, string>): string;
}

/** 缺省文案来源：Core 的集中草稿表（契约字典优先）。 */
export class DraftOrderTexts implements OrderTexts {
  text(key: string): string {
    return OrderDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    return OrderDraftTexts.format(key, vars);
  }
}

/** 订单页的文案键（三端同名；契约已有的直接取，其余在草稿表）。 */
export class OrderKeys {
  static readonly TITLE: string = 'order_list.title';
  static readonly CLAIM_ENTRY: string = 'order_list.claim_entry';
  static readonly SCOPE_SELF: string = 'order_list.scope.self';
  static readonly SCOPE_SHARE: string = 'order_list.scope.share';
  static readonly SEARCH_LABEL: string = 'order_list.search.label';
  static readonly SEARCH_PLACEHOLDER: string = 'order_list.search.placeholder';
  static readonly SEARCH_PLACEHOLDER_SHARE: string = 'order_list.search.placeholder_share';
  static readonly SEARCH_CLEAR: string = 'order_list.search.clear';
  static readonly SEARCH_FOUND: string = 'order_list.search.found';
  static readonly SEARCH_EMPTY: string = 'order_list.search.empty';
  static readonly SEARCH_SHARE_NOTE: string = 'order_list.search.share_note';
  static readonly EMPTY_SELF_TITLE: string = 'order_list.empty.self.title';
  static readonly EMPTY_SELF_DESC: string = 'order_list.empty.self.desc';
  static readonly EMPTY_SHARE_TITLE: string = 'order_list.empty.share.title';
  static readonly EMPTY_SHARE_DESC: string = 'order_list.empty.share.desc';
  static readonly GO_HOME: string = 'order_list.empty.go_home';
  static readonly FILTER_PLATFORM: string = 'order_list.filter.platform';
  static readonly FILTER_MONTH: string = 'order_list.filter.month';
  static readonly ALL_PLATFORMS: string = 'order_list.filter.all_platforms';
  static readonly ALL_MONTHS: string = 'order_list.filter.all_months';
  static readonly MONTH_NOTE: string = 'order_list.filter.month_note';
  static readonly MONTH_ITEM: string = 'order_list.filter.month_item';
  static readonly CLOSE: string = 'order_list.filter.close';
  static readonly EXPANDED: string = 'order_list.filter.expanded';
  static readonly COLLAPSED: string = 'order_list.filter.collapsed';
  static readonly LOAD_MORE: string = 'order_list.load_more';
  static readonly LOADING: string = 'order_list.loading';
  static readonly END: string = 'order_list.end';
  static readonly HISTORY_HINT: string = 'order_list.history_hint';
  static readonly QUANTITY: string = 'order_list.quantity';
  static readonly ORDER_NO: string = 'order_list.order_no';
  static readonly ORDER_NO_SPOKEN: string = 'order_list.order_no_spoken';
  static readonly STAR: string = 'order_list.star';
  static readonly COPY: string = 'order_list.copy';
  static readonly COPY_SPOKEN: string = 'order_list.copy_spoken';
  static readonly IMAGE_PLACEHOLDER: string = 'order_list.image_placeholder';
  static readonly RETRY: string = 'order_list.retry';
  static readonly STALE: string = 'net.stale_data';
  static readonly MASK_HIDE: string = 'amount_mask.hide';
  static readonly MASK_SHOW: string = 'amount_mask.show';
  static readonly DETAIL_TITLE: string = 'order_detail.title';
  static readonly DETAIL_BACK: string = 'order_detail.back';
  static readonly VIEW_PRODUCT: string = 'order_detail.view_product';
  static readonly HELP_ENTRY: string = 'order_detail.help_entry';
  static readonly APPEAL_PENDING: string = 'order_detail.appeal_pending';
  static readonly APPEAL_PROGRESS: string = 'order_detail.appeal_progress';
  static readonly TIMELINE: string = 'order_timeline.list';
  static readonly NOT_HAPPENED: string = 'order_timeline.not_happened';
  static readonly GENERIC: string = 'error.50001';

  static platform(platform: string): string {
    return 'platform.' + platform;
  }
}

/** 金额隐藏（G21）：本机偏好的页面状态（订单列表与详情共用一个实例；entry 读写本机偏好）。 */
@ObservedV2
export class OrderMaskUi {
  @Trace masked: boolean = false;
  onToggle: (masked: boolean) => void = (_m: boolean) => {
  };

  toggle(): void {
    this.masked = !this.masked;
    this.onToggle(this.masked);
  }
}

/** 一张订单卡（列表）或详情头部的显示内容（纯显示；原始记录留着给按钮回调绑定渲染时的数据）。 */
export class OrderView {
  readonly raw: OrderRecord;
  readonly orderId: string;
  readonly status: string;
  readonly platformName: string;
  readonly timeText: string;
  /** 标题（is_other_product 时为「好友购买的其他商品」；null 标题为空串，标题区留空）。 */
  readonly title: string;
  readonly imageUrl: string | null;
  readonly quantityText: string;
  readonly orderNoLabel: string;
  readonly orderNo: string;
  readonly orderNoSpoken: string;
  readonly copyable: boolean;
  readonly statusLabel: string;
  readonly statusTone: string;
  /** 列表：WAITING 的「预计 M 月结算」（BR-TEXT-04）；其余为空串。 */
  readonly monthLine: string;
  readonly listAmounts: AmountGridItem[];
  readonly detailAmounts: AmountGridItem[];
  /** 纵排时的顺序（返利在上）。 */
  readonly listStacked: AmountGridItem[];
  readonly detailStacked: AmountGridItem[];
  /** 金额隐藏时的状态标题（部分扣回不带金额）。 */
  readonly statusLabelMasked: string;

  constructor(raw: OrderRecord, texts: OrderTexts, nowMs: number) {
    this.raw = raw;
    this.orderId = OrderJson.text(raw, 'order_id') ?? '';
    this.status = OrderStatus.ofItem(raw);
    const platform: string = OrderJson.text(raw, 'platform') ?? '';
    this.platformName = texts.text(OrderKeys.platform(platform));
    const paid: number | null = OrderJson.millis(OrderJson.text(raw, 'paid_at'));
    this.timeText = paid === null ? '' : CouliFormat.timeListPast(paid, nowMs);
    const titled: Record<string, Object | null> = OrderTitleImage.of(raw);
    const titleKey: Object | null | undefined = titled['titleKey'];
    this.title = typeof titleKey === 'string' ? texts.text(titleKey as string)
      : (typeof titled['title'] === 'string' ? titled['title'] as string : '');
    this.imageUrl = titled['usePlaceholderImage'] === true ? null : titled['imageUrl'] as string | null;
    const qty: number | null = OrderJson.int(raw, 'quantity');
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('n', qty === null ? '' : String(qty));
    this.quantityText = qty === null ? '' : texts.format(OrderKeys.QUANTITY, vars);
    const no: Record<string, Object | null> = OrderNumberDisplay.of(raw);
    this.orderNo = typeof no['text'] === 'string' ? no['text'] as string : '';
    this.copyable = no['copyable'] === true;
    this.orderNoLabel = texts.text(OrderKeys.ORDER_NO);
    const spokenVars: Map<string, string> = new Map<string, string>();
    spokenVars.set('no', this.copyable ? this.orderNo : OrderNumberDisplay.spoken(this.orderNo, texts.text(OrderKeys.STAR)));
    this.orderNoSpoken = texts.format(OrderKeys.ORDER_NO_SPOKEN, spokenVars);
    const statusText: Record<string, Object | null> = OrderStatusText.of(this.status);
    const labelKey: string = statusText['labelKey'] as string;
    if (this.status === 'CREDITED_PART_CLAWED') {
      const z: number | null = OrderJson.fen(raw, 'clawback_fen');
      const zv: Map<string, string> = new Map<string, string>();
      if (z !== null) {
        zv.set('z', CouliFormat.money(z));
      }
      this.statusLabel = z === null ? texts.text(labelKey + '_plain') : texts.format(labelKey, zv);
      this.statusLabelMasked = texts.text(labelKey + '_plain');
    } else {
      this.statusLabel = texts.text(labelKey);
      this.statusLabelMasked = this.statusLabel;
    }
    this.statusTone = OrderStatus.tone(this.status);
    this.monthLine = OrderView.creditLine(raw, this.status, texts, nowMs);
    const cells: Record<string, Object | null> = OrderAmountCells.of(raw, false);
    const left: AmountGridItem | null = OrderView.cell(cells['left'] as Record<string, Object | null> | null, texts);
    const right: AmountGridItem | null = OrderView.cell(cells['right'] as Record<string, Object | null> | null, texts);
    // 横排与纵排各一套顺序（R1-05）：列表横排左实付右返利、纵排返利在上；详情一律返利在前。
    this.listAmounts = OrderView.arrange(OrderAmountCells.LIST, false, left, right);
    this.listStacked = OrderView.arrange(OrderAmountCells.LIST, true, left, right);
    this.detailAmounts = OrderView.arrange(OrderAmountCells.DETAIL, false, left, right);
    this.detailStacked = OrderView.arrange(OrderAmountCells.DETAIL, true, left, right);
  }

  private static arrange(target: string, stacked: boolean, left: AmountGridItem | null,
    right: AmountGridItem | null): AmountGridItem[] {
    const out: AmountGridItem[] = [];
    for (const slot of OrderAmountCells.sequence(target, stacked)) {
      const cell: AmountGridItem | null = slot === 'left' ? left : right;
      if (cell !== null) {
        out.push(cell);
      }
    }
    return out;
  }

  /** WAITING 的「预计 M 月结算」（列表与详情的状态区）；其余空串。PAID 的入账句只在详情显示（hintLine）。 */
  static creditLine(raw: OrderRecord, status: string, texts: OrderTexts, nowMs: number): string {
    if (status !== 'WAITING') {
      return '';
    }
    const credit: Record<string, Object | null> = CreditPeriodText.of(status,
      OrderJson.text(raw, 'expected_credit_period'), nowMs);
    const key: Object | null | undefined = credit['textKey'];
    const month: Object | null | undefined = credit['monthText'];
    if (typeof key !== 'string' || typeof month !== 'string') {
      return '';
    }
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('credit_period', month as string);
    return texts.format(key as string, vars);
  }

  /** 金额格的一格：字段为 null 时整格不显示（不补 0、不推算）。实付与已付定金不受金额隐藏影响。 */
  static cell(cell: Record<string, Object | null> | null, texts: OrderTexts): AmountGridItem | null {
    if (cell === null) {
      return null;
    }
    const fen: Object | null | undefined = cell['fen'];
    if (typeof fen !== 'number') {
      return null;
    }
    const labelKey: string = cell['labelKey'] as string;
    const rebate: boolean = cell['rebate'] === true;
    if (!rebate) {
      // 「已付定金 {amount}」：标签取键里的固定部分（去掉占位）。
      const label: string = texts.format(labelKey, new Map<string, string>());
      return AmountGridItem.moneyPlain(label, fen as number);
    }
    const label: string = texts.text(labelKey);
    if (cell['sign'] === 'minus') {
      return AmountGridItem.money(label, -(fen as number), AmountTone.NORMAL);
    }
    return AmountGridItem.money(label, fen as number, AmountTone.REBATE);
  }
}

/** 状态胶囊（图标 + 文字，状态不只靠颜色）。 */
@ComponentV2
export struct OrderStatusChip {
  @Param label: string = '';
  @Param tone: string = 'neutral';

  private chipTone(): CouliChipTone {
    if (this.tone === 'success') {
      return CouliChipTone.SUCCESS;
    }
    if (this.tone === 'warning') {
      return CouliChipTone.WARNING;
    }
    return CouliChipTone.MUTED;
  }

  private icon(): string {
    if (this.tone === 'pending') {
      return 'clock';
    }
    if (this.tone === 'success') {
      return 'check';
    }
    if (this.tone === 'warning') {
      return 'alert';
    }
    return 'info';
  }

  build() {
    CouliChip({ label: this.label, tone: this.chipTone(), icon: this.icon() })
  }
}

/**
 * 商品图（brief §0「图片」，APP-06a 第 22 条）：接 image_url，只在加载中、为 null 或加载失败时显示占位；占位是装饰，读屏不读。
 */
@ComponentV2
export struct OrderThumb {
  @Param url: string | null = null;
  @Param placeholder: string = '';
  @Param thumbSize: number = 64;
  @Local loaded: boolean = false;
  @Local failed: boolean = false;

  build() {
    Stack() {
      if (this.url === null || !this.loaded || this.failed) {
        Text(this.placeholder)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .textAlign(TextAlign.Center)
          .width('100%')
          .height('100%')
          .backgroundColor(CouliColors.backgroundPlaceholder)
          .accessibilityLevel('no')
      }
      if (this.url !== null && !this.failed) {
        Image(this.url)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(this.loaded ? 1 : 0)
          .accessibilityLevel('no')
          .onComplete(() => {
            this.loaded = true;
          })
          .onError(() => {
            this.failed = true;
          })
      }
    }
    .width(this.thumbSize)
    .height(this.thumbSize)
    .borderRadius(CouliRadius.button)
    .clip(true)
  }
}

/**
 * 订单号行：「订单号 xxx」+ 自购单独立的【复制】（48vp 命中区，点击不穿透到整卡）。分享单只显示脱敏号：不可选中
 * （copyOption None）、不绑长按、没有复制按钮，读屏读出「星号」。
 */
@ComponentV2
export struct OrderNumberRow {
  @Param label: string = '';
  @Param orderNo: string = '';
  @Param spoken: string = '';
  @Param copyable: boolean = false;
  @Param copyText: string = '';
  @Param copySpoken: string = '';
  @Param rowId: string = '';
  @Event onCopy: () => void = () => {
  };

  build() {
    Row({ space: CouliSpacing.space2 }) {
      Text(this.label + ' ' + this.orderNo)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
        .copyOption(CopyOptions.None)
        .wordBreak(WordBreak.BREAK_ALL)
        .accessibilityText(this.spoken)
        .flexShrink(1)
      if (this.copyable) {
        Text(this.copyText)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink, CouliFontWeight.medium))
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: CouliInteraction.minTouchTarget, minHeight: CouliInteraction.minTouchTarget })
          .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3 })
          .id(this.rowId + '_copy')
          .accessibilityText(this.copySpoken)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => this.onCopy())
      }
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
  }
}

/** 顶部状态提示条（OrdersStale：role=status，可变长文案按宽度换行）。 */
@ComponentV2
export struct OrderStaleBanner {
  @Param text: string = '';

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 18, color: CouliColors.statusWarningText })
        .accessibilityLevel('no')
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .flexShrink(1)
    }
    .id('orders_stale_banner')
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.statusWarningBackground)
    .accessibilityGroup(true)
    .accessibilityText(this.text)
    .accessibilityRole(AccessibilityRoleType.ROLE_NONE)
  }
}

/** 缓存获取时刻（BR-TEXT-11 列表过去时间：今天 HH:mm / 昨天 HH:mm / MM-DD / YYYY-MM-DD）。 */
export function staleText(texts: OrderTexts, fetchedAt: number, nowMs: number): string {
  const vars: Map<string, string> = new Map<string, string>();
  vars.set('time', CouliFormat.timeListPast(fetchedAt, nowMs));
  return texts.format(OrderKeys.STALE, vars);
}

/** 错误正文：经 Core 的统一错误消息函数（OrderMessages.compose：键缺省用通用失败，trace6 独立追加、不依赖占位；共性第 8、16 条）。 */
export function orderErrorText(texts: OrderTexts, textKey: string | null, traceId: string, showTrace6: boolean): string {
  return OrderMessages.compose((key: string, vars: Map<string, string>): string => texts.format(key, vars), textKey,
    traceId, showTrace6);
}
