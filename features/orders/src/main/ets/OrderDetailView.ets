import {
  AgentAskEntry, OrderDetailActions, OrderDetailController, OrderDetailEntries, OrderDetailSnapshot, OrderJson, OrderPhase, OrderRecord,
  OrderTimelineView, PriceCompareEntry, ViewProductEntry, WhyNoRebate
} from 'core';
import {
  AmountGrid, CouliButton, CouliButtonSize, CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliFocus,
  CouliFontWeight, CouliIcon, CouliInteraction, CouliLayout, CouliRadius, CouliSpacing, CouliTextModifier,
  CouliTypography, EmptyState, ErrorState, NavBar, PlatformBadge, PriceTerms
} from 'designsystem';
import { RouteSpec } from 'generated';
import {
  DraftOrderTexts, OrderKeys, OrderMaskUi, OrderNumberRow, OrderStaleBanner, OrderTexts, OrderThumb, OrderView,
  orderErrorText, staleText
} from './OrderViewKit';

/** 详情页的出口（entry 接 Router、剪贴板写入口、配置 help_links）。 */
export class OrderDetailPageConfig {
  readonly controller: OrderDetailController;
  readonly mask: OrderMaskUi;
  readonly orderId: string;
  texts: OrderTexts = new DraftOrderTexts();
  now: () => number = Date.now;
  /** Config 的 help_links（JSON 对象；没有为 null）。 */
  helpLinks: () => OrderRecord | null = () => null;
  /** 路由表（routes.json；「查看说明」的目标按它校验）。 */
  routes: Map<string, RouteSpec> = new Map<string, RouteSpec>();
  onBack: () => void = () => {
  };
  /**
   * 跳转入口（Core OrderDetailEntries；entry 注入经 Router 打开与统一客服出口）：状态卡 / 底部按钮、「查看商品」、「查看说明」、
   * 【查看申诉进度】的按钮回调直接调它的方法（R2-06），执行前复核页面仍在。
   */
  entries: OrderDetailEntries;
  onCopy: (item: OrderRecord) => void = (_i: OrderRecord) => {
  };
  /**
   * APP-10 G27：【问问 AI】（entry 交 AppAgent，带 {order_id}；null 不显示）。FU-HM-0715 R1-05：构造详情时固定文字、来源票据与回调，
   * 显示与否随 Config 入口开关动态变化（关着时建页、之后打开，原页即显示）。
   */
  askAi: AgentAskEntry | null = null;

  constructor(controller: OrderDetailController, mask: OrderMaskUi, orderId: string) {
    this.controller = controller;
    this.mask = mask;
    this.orderId = orderId;
    this.entries = new OrderDetailEntries((_r: string, _p: Record<string, Object>) => {
    }, () => {
    }, (): boolean => controller.alive());
  }
}

/** 时间线的一行（显示用）。 */
class TimelineRow {
  readonly key: string;
  readonly label: string;
  readonly time: string;
  readonly grey: boolean;
  readonly last: boolean;
  readonly spoken: string;

  constructor(key: string, label: string, time: string, grey: boolean, last: boolean, spoken: string) {
    this.key = key;
    this.label = label;
    this.time = time;
    this.grey = grey;
    this.last = last;
    this.spoken = spoken;
  }
}

/** 底部 / 卡内按钮（显示用；回调绑定渲染时的详情与动作）。 */
class ActionButton {
  readonly action: string;
  readonly primary: boolean;
  readonly label: string;
  readonly detail: OrderRecord;

  constructor(action: string, primary: boolean, label: string, detail: OrderRecord) {
    this.action = action;
    this.primary = primary;
    this.label = label;
    this.detail = detail;
  }
}

@ObservedV2
class OrderDetailModel {
  @Trace phase: string = OrderPhase.LOADING;
  @Trace view: OrderView | null = null;
  /** 渲染时的详情（「查看商品」「查看说明」【查看申诉进度】的回调按它判定）。 */
  detail: OrderRecord | null = null;
  /** 每次换一份详情数据加 1（显示缓存 → 重试成功等）：状态卡与商品卡按它整体重建（@Builder 的对象参数按值传递，不随状态刷新）。 */
  @Trace viewVersion: number = 0;
  @Trace errorText: string = '';
  @Trace staleText: string = '';
  @Trace blocked: boolean = false;
  /** 显示缓存时下拉刷新在途（R3-04）。 */
  @Trace refreshing: boolean = false;
  @Trace hint: string = '';
  @Trace monthChip: string = '';
  @Trace whyHeader: string = '';
  @Trace whyTitle: string = '';
  @Trace whyDesc: string = '';
  @Trace compareHint: string = '';
  @Trace helpRoute: string = '';
  @Trace appealPending: boolean = false;
  @Trace productRoute: string = '';
  @Trace buttons: ActionButton[] = [];
  @Trace timeline: TimelineRow[] = [];
}

/**
 * 订单详情（OrderDetail 路由；设计稿 OrderDetail* 各态、AdaptLargeTextOrderDetail、A11yAnnounce）。
 * 状态与金额卡（标题有标题角色；金额格返利在前、实付在后，放不下或 200% 时纵排）→ 原因区「为什么没返利？」/ 比价说明「查看说明」/
 * 申诉中块 → 卡内按钮（最多 2 个）；平台 +「查看商品」（不占按钮名额）+ 商品卡（订单号 + 自购单【复制】）；时间线（列表，未发生节点
 * 读「未发生」）。「问问 AI」（APP-10 G27）只在 Agent 可用时显示，带 {order_id}。只有状态固有的【去提现】时放底部整宽按钮（设计稿 OrderDetailSettled）。
 */
@ComponentV2
export struct OrderDetailView {
  @Param @Require config: OrderDetailPageConfig;
  @Local model: OrderDetailModel = new OrderDetailModel();
  /** G56（FU-HM-0715）：【问问 AI】随 Config agent.entry.visible 显示 / 隐藏（R1-05：可见性动态，文字与回调构造时固定）。 */
  @Local askAiVisible: boolean = false;
  private unsubscribeAskAi: (() => void) | null = null;

  aboutToAppear(): void {
    const askAi: AgentAskEntry | null = this.config.askAi;
    if (askAi !== null) {
      this.unsubscribeAskAi = askAi.subscribe((shown: boolean): void => {
        this.askAiVisible = shown;
      });
      this.askAiVisible = askAi.refresh();
    }
    this.config.controller.onChange = (s: OrderDetailSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  aboutToDisappear(): void {
    const off: (() => void) | null = this.unsubscribeAskAi;
    this.unsubscribeAskAi = null;
    if (off !== null) {
      off();
    }
  }

  private askAiText(): string {
    const askAi: AgentAskEntry | null = this.config.askAi;
    return askAi === null ? '' : askAi.text;
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: OrderDetailSnapshot): void {
    const m: OrderDetailModel = this.model;
    const texts: OrderTexts = this.config.texts;
    const now: number = this.config.now();
    m.phase = s.phase;
    m.blocked = s.blocked;
    m.refreshing = s.refreshing;
    m.staleText = s.stale ? staleText(texts, s.staleFetchedAt, now) : '';
    m.errorText = s.error === null ? '' : orderErrorText(texts, s.error.textKey, s.error.traceId, s.error.showTrace6);
    const d: OrderRecord | null = s.detail;
    m.detail = d;
    if (d === null) {
      m.view = null;
      return;
    }
    const view: OrderView = new OrderView(d, texts, now);
    m.view = view;
    m.viewVersion++;
    // 状态区：WAITING「预计 M 月结算」胶囊；PAID 入账句；其余状态 hint（UNKNOWN「请稍后查看」）。
    m.monthChip = view.monthLine;
    m.hint = '';
    if (view.status === 'PAID') {
      m.hint = this.t('order_status.PAID.hint');
    } else if (view.status !== 'WAITING' && view.status !== 'NO_REBATE' && view.status !== 'INVALID'
      && view.status !== 'CLAWED_BACK' && view.status !== 'CREDITED' && view.status !== 'CREDITED_PART_CLAWED') {
      m.hint = this.t('order_status.' + view.status + '.hint');
    }
    const why: Record<string, Object | null> = WhyNoRebate.of(d);
    m.whyHeader = '';
    m.whyTitle = '';
    m.whyDesc = '';
    m.compareHint = '';
    if (why['show'] === true) {
      if (typeof why['hintKey'] === 'string') {
        m.compareHint = this.t(why['hintKey'] as string);
      } else {
        m.whyHeader = typeof why['headerKey'] === 'string' ? this.t(why['headerKey'] as string) : '';
        m.whyTitle = typeof why['titleKey'] === 'string' ? this.t(why['titleKey'] as string) : '';
        const desc: string = typeof why['descKey'] === 'string' ? this.t(why['descKey'] as string) : '';
        const extra: string = typeof why['extraKey'] === 'string' ? this.t(why['extraKey'] as string) : '';
        m.whyDesc = desc.length > 0 && extra.length > 0 ? desc + this.t('order_reason.extra_separator') + extra
          : desc + extra;
      }
    }
    const help: Record<string, Object | null> = PriceCompareEntry.of(d, this.config.helpLinks(), this.config.routes);
    m.helpRoute = help['show'] === true ? help['route'] as string : '';
    const actions: Record<string, Object | null> = OrderDetailActions.of(d);
    m.appealPending = actions['appealPendingBlock'] === true;
    m.buttons = (actions['buttons'] as Record<string, Object | null>[]).map((b: Record<string, Object | null>) =>
      new ActionButton(b['actionRaw'] as string, b['primary'] === true,
        this.t(OrderDetailActions.labelKey(b['actionRaw'] as string)), d));
    const product: Record<string, Object | null> = ViewProductEntry.of(d);
    m.productRoute = product['show'] === true ? product['route'] as string : '';
    const rows: Record<string, Object | null>[] = OrderTimelineView.of(view.status, OrderJson.timeline(d), now);
    m.timeline = rows.map((r: Record<string, Object | null>, i: number): TimelineRow => {
      const vars: Map<string, string> = new Map<string, string>();
      if (typeof r['monthText'] === 'string') {
        vars.set('credit_period', r['monthText'] as string);
      }
      // 预售两节点的契约键带 {time}：标题只取不带时间的部分，时间在下一行（设计稿 OrderDetailPresale）。
      const label: string = texts.format(r['labelKey'] as string, vars);
      const time: string = typeof r['time'] === 'string' ? r['time'] as string : '';
      const grey: boolean = r['grey'] === true;
      const spoken: string = label + (time.length > 0 ? PriceTerms.comma + time
        : (grey ? PriceTerms.comma + this.t(OrderKeys.NOT_HAPPENED) : ''));
      return new TimelineRow((r['node'] as string) + i, label, time, grey, i === rows.length - 1, spoken);
    });
  }

  /** 「查看说明」「查看商品」【查看申诉进度】：按渲染时的详情经 OrderDetailEntries 打开（执行前复核页面仍在）。 */
  private tapHelp(): void {
    const d: OrderRecord | null = this.model.detail;
    if (d !== null) {
      this.config.entries.priceCompare(d, this.config.helpLinks(), this.config.routes);
    }
  }

  private tapProduct(): void {
    const d: OrderRecord | null = this.model.detail;
    if (d !== null) {
      this.config.entries.viewProduct(d);
    }
  }

  private tapAppeal(): void {
    const d: OrderRecord | null = this.model.detail;
    if (d !== null) {
      this.config.entries.appealProgress(d);
    }
  }

  /** 只有【去提现】一个按钮时放底部（设计稿 OrderDetailSettled）；其余放在状态卡里。 */
  private bottomButton(): ActionButton | null {
    const b: ActionButton[] = this.model.buttons;
    return b.length === 1 && b[0].action === 'withdraw' ? b[0] : null;
  }

  @Builder
  statusCard(view: OrderView) {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: view.statusTone === 'pending' ? 'clock' : (view.statusTone === 'success' ? 'check'
          : (view.statusTone === 'warning' ? 'alert' : 'info')), iconSize: 20,
          color: view.statusTone === 'success' ? CouliColors.statusSuccessText : CouliColors.textPrimary })
          .accessibilityLevel('no')
        Text(this.config.mask.masked ? view.statusLabelMasked : view.statusLabel)
          .id('order_detail_status')
          .attributeModifier(new CouliTextModifier(CouliTypography.title, view.statusTone === 'success'
            ? CouliColors.statusSuccessText : CouliColors.textPrimary, CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .layoutWeight(1)
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: this.config.mask.masked ? 'eye-off' : 'eye', iconSize: 22, color: CouliColors.textSecondary })
        }
        .id('order_detail_mask')
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, right: -CouliSpacing.space3 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.t(this.config.mask.masked ? OrderKeys.MASK_SHOW : OrderKeys.MASK_HIDE))
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => this.config.mask.toggle())
      }
      .width('100%')
      if (view.detailAmounts.length > 0) {
        AmountGrid({ items: view.detailAmounts, stackedItems: view.detailStacked, large: true, masked: this.config.mask.masked })
      }
      if (this.model.monthChip.length > 0) {
        CouliChip({ label: this.model.monthChip, tone: CouliChipTone.MUTED })
      }
      if (this.model.hint.length > 0) {
        Text(this.model.hint)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .width('100%')
      }
      if (this.model.whyTitle.length > 0 || this.model.compareHint.length > 0) {
        Divider().color(CouliColors.borderSubtle)
        this.reasonArea()
      }
      if (this.model.appealPending) {
        this.appealBlock()
      }
      if (this.model.buttons.length > 0 && this.bottomButton() === null) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.model.buttons, (b: ActionButton, i: number) => {
            CouliButton({
              text: b.label,
              variant: b.primary && this.model.buttons.length > 1 ? CouliButtonVariant.PRIMARY
                : CouliButtonVariant.SECONDARY,
              buttonSize: CouliButtonSize.COMPACT,
              buttonId: 'order_detail_action_' + b.action,
              onTap: () => {
                this.config.entries.action(b.detail, b.action);
              }
            })
              .margin({ right: CouliSpacing.space2, bottom: CouliSpacing.space2 })
          }, (b: ActionButton) => b.action)
        }
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  @Builder
  reasonArea() {
    Column({ space: CouliSpacing.space1 }) {
      if (this.model.compareHint.length > 0) {
        this.lineWithHelp(this.model.compareHint, CouliColors.textPrimary)
      } else {
        if (this.model.whyHeader.length > 0) {
          Text(this.model.whyHeader)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
              CouliFontWeight.semibold))
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        }
        this.lineWithHelp(this.model.whyTitle, CouliColors.textPrimary)
        if (this.model.whyDesc.length > 0) {
          Text(this.model.whyDesc)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .width('100%')
        }
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .id('order_detail_reason')
  }

  /** 一行文字 + 行尾「查看说明」（help_links.price_compare 已配置且合法时；不占按钮位）。 */
  @Builder
  lineWithHelp(text: string, color: ResourceColor) {
    Row({ space: CouliSpacing.space2 }) {
      Text(text)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, color))
        .layoutWeight(1)
      if (this.model.helpRoute.length > 0) {
        Text(this.t(OrderKeys.HELP_ENTRY))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink, CouliFontWeight.medium))
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .textAlign(TextAlign.End)
          .id('order_detail_help')
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => this.tapHelp())
      }
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
  }

  @Builder
  appealBlock() {
    Column({ space: CouliSpacing.space2 }) {
      CouliChip({ label: this.t(OrderKeys.APPEAL_PENDING), tone: CouliChipTone.MUTED, icon: 'clock' })
      Row({ space: CouliSpacing.space1 }) {
        Text(this.t(OrderKeys.APPEAL_PROGRESS))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink,
            CouliFontWeight.semibold))
        CouliIcon({ name: 'chevron', iconSize: 16, color: CouliColors.textLink })
          .accessibilityLevel('no')
      }
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .id('order_detail_appeal_progress')
      .accessibilityGroup(true)
      .accessibilityText(this.t(OrderKeys.APPEAL_PROGRESS))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      // G08：Appeal 路由没有参数，带不了 order_id。
      .onClick(() => this.tapAppeal())
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  productCard(view: OrderView) {
    Column({ space: CouliSpacing.space3 }) {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        PlatformBadge({ label: view.platformName, platform: view.platformCode })
        if (this.model.productRoute.length > 0) {
          Row({ space: CouliSpacing.space1 }) {
            Text(this.t(OrderKeys.VIEW_PRODUCT))
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textLink,
                CouliFontWeight.medium))
            CouliIcon({ name: 'chevron', iconSize: 16, color: CouliColors.textLink })
              .accessibilityLevel('no')
          }
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .id('order_detail_view_product')
          .accessibilityGroup(true)
          .accessibilityText(this.t(OrderKeys.VIEW_PRODUCT))
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          // 只带 platform 与 product_key（不带 item_ref、订单或 link 信息）：之后的购买是一次新的 open（F-ORD-16）。
          .onClick(() => this.tapProduct())
        }
      }
      .width('100%')
      Row({ space: CouliSpacing.space3 }) {
        OrderThumb({ url: view.imageUrl, placeholder: this.t(OrderKeys.IMAGE_PLACEHOLDER), thumbSize: 64 })
        Column({ space: CouliSpacing.space1 }) {
          if (view.title.length > 0) {
            Text(view.title)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
                CouliFontWeight.semibold))
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
              rowId: 'order_detail',
              onCopy: () => {
                // FU-HM-0712 R1-01：页面仍有效、正在显示的仍是这一单且单号一致，才走统一写入口。
                if (this.config.controller.copyValid(view.raw)) {
                  this.config.onCopy(view.raw);
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
      // APP-10 G27：【问问 AI】带 {order_id}（只在 Agent 可用的构建与环境里显示；不自动发送，附在用户发的第一条消息上）。
      // G56（FU-HM-0715）：入口开关关时一起隐藏。
      if (this.askAiVisible && this.askAiText().length > 0) {
        Row({ space: CouliSpacing.space1 }) {
          CouliIcon({ name: 'chat', iconSize: 16, color: CouliColors.textLink })
            .accessibilityLevel('no')
          Text(this.askAiText())
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textLink, CouliFontWeight.medium))
        }
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .id('order_detail_ask_ai')
        .accessibilityGroup(true)
        .accessibilityText(this.askAiText())
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          this.config.askAi?.tap();
        })
      }
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  @Builder
  timeline() {
    Column() {
      ForEach(this.model.timeline, (row: TimelineRow) => {
        Row() {
          Circle({ width: 9, height: 9 })
            .fill(row.grey ? CouliColors.backgroundSurface : CouliColors.textPrimary)
            .stroke(row.grey ? CouliColors.textSecondary : CouliColors.textPrimary)
            .margin({ top: 7 })
            .zIndex(1)
            .accessibilityLevel('no')
          // 连线：文字列的左边框（与圆点中心对齐，最后一行没有）。
          Column({ space: 2 }) {
            Text(row.label)
              .attributeModifier(new CouliTextModifier(CouliTypography.body,
                row.grey ? CouliColors.textSecondary : CouliColors.textPrimary))
            if (row.time.length > 0) {
              Text(row.time)
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary,
                  undefined, true))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: -5 })
          .padding({ left: CouliSpacing.space4, bottom: row.last ? 0 : CouliSpacing.space4 })
          .border({ width: { left: row.last ? 0 : 1 }, color: CouliColors.borderSubtle })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .accessibilityGroup(true)
        .accessibilityText(row.spoken)
        .accessibilityRole(AccessibilityRoleType.LIST_ITEM)
      }, (row: TimelineRow) => row.key)
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .id('order_detail_timeline')
    .accessibilityRole(AccessibilityRoleType.LIST)
    .accessibilityText(this.t(OrderKeys.TIMELINE))
  }

  build() {
    Column() {
      NavBar({ title: this.t(OrderKeys.DETAIL_TITLE), backLabel: this.t(OrderKeys.DETAIL_BACK) })
        .backgroundColor(CouliColors.backgroundCanvas)
      if (this.model.phase === OrderPhase.IDLE) {
        // 会话已变（R1-01）：旧账号的详情已清空，页面随即移出导航栈；这一帧什么都不显示。
        Column()
          .layoutWeight(1)
      } else if (this.model.phase === OrderPhase.LOADING && this.model.view === null) {
        Column() {
          LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .accessibilityText(this.t(OrderKeys.LOADING))
      } else if (this.model.phase === OrderPhase.EMPTY) {
        Column() {
          EmptyState({ icon: 'orders', title: this.model.errorText })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.model.phase === OrderPhase.ERROR || this.model.view === null) {
        Column() {
          ErrorState({
            title: this.model.errorText,
            retryText: this.t(OrderKeys.RETRY),
            retryId: 'order_detail_retry',
            retryDisabled: this.model.blocked,
            onRetry: () => {
              this.config.controller.retry();
            }
          })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 显示断网缓存时可下拉刷新（R3-04；共性第 26 条）：走 stale 重试路径，共享 42901 禁用期内不可拉；成功后更新内容并移除提示条。
        Refresh({ refreshing: this.model.refreshing }) {
          Scroll() {
            Column({ space: CouliSpacing.space3 }) {
              if (this.model.staleText.length > 0) {
                OrderStaleBanner({ text: this.model.staleText })
              }
              ForEach([this.model.viewVersion], (_v: number) => {
                this.statusCard(this.model.view as OrderView)
                this.productCard(this.model.view as OrderView)
              }, (v: number) => 'detail_view_' + v)
              if (this.model.timeline.length > 0) {
                this.timeline()
              }
            }
            .padding(CouliSpacing.space4)
            .width('100%')
            .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
          }
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }
        .layoutWeight(1)
        .width('100%')
        .refreshOffset(64)
        .pullToRefresh(this.model.staleText.length > 0 && !this.model.blocked)
        .onRefreshing(() => {
          this.model.refreshing = true;
          if (!this.config.controller.refreshStale()) {
            setTimeout(() => {
              this.model.refreshing = false;
            }, 0);
          }
        })
        if (this.bottomButton() !== null) {
          Column() {
            CouliButton({
              text: (this.bottomButton() as ActionButton).label,
              variant: CouliButtonVariant.PRIMARY,
              fullWidth: true,
              buttonId: 'order_detail_action_withdraw',
              onTap: () => {
                const b: ActionButton | null = this.bottomButton();
                if (b !== null) {
                  this.config.entries.action(b.detail, b.action);
                }
              }
            })
          }
          .width('100%')
          .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
          .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
            bottom: CouliSpacing.space2 })
          .backgroundColor(CouliColors.backgroundSurface)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
