import { LengthMetrics } from '@kit.ArkUI';
import {
  AgentCardKind, AgentCardType, AgentCardView, AgentDraftTexts, AgentChipTap, AgentErrorView, AgentFeedbackView,
  AgentProductView, AgentReportEntryView, AgentRetryMode, AgentTap, AgentTextBlock, AgentTextBlockKind, AgentTextSpan,
  AgentTool, AgentTurnView, EarningsShape, EarningsView
} from 'core';
import {
  AiLabel, BuyButtonState, CouliButton, CouliButtonSize, CouliButtonVariant, CouliChip, CouliChipTone, CouliColors, CouliFocus,
  CouliFontScale, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography, MatchBadge,
  ProductCard, ProductCardData, ProductCardVariant, ProductGridLayout
} from 'designsystem';
import { AgentScreenPort } from './AgentScreenModel';

@Builder
function emptyContent() {
}

/** 卡片外框（与搜索结果卡同族：白底、圆角、描边）。 */
@ComponentV2
struct AgentCardFrame {
  @BuilderParam content: () => void = emptyContent;

  build() {
    Column({ space: CouliSpacing.space2 }) {
      this.content()
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .border({ width: 1, color: CouliColors.borderSubtle })
    .alignItems(HorizontalAlign.Start)
  }
}

/** 受限渲染的模型文字（只渲染段落、加粗、无序列表；文字一律不可点，G23）。 */
@ComponentV2
export struct AgentTextView {
  @Param blocks: AgentTextBlock[] = [];

  build() {
    Column({ space: CouliSpacing.space2 }) {
      ForEach(this.blocks, (b: AgentTextBlock, i: number) => {
        Row({ space: CouliSpacing.space2 }) {
          if (b.kind === AgentTextBlockKind.LIST_ITEM) {
            Text('•')
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          }
          Text() {
            ForEach(b.spans, (s: AgentTextSpan, j: number) => {
              Span(s.text)
                .fontWeight(s.bold ? FontWeight.Bold : FontWeight.Normal)
            }, (s: AgentTextSpan, j: number) => String(j) + ':' + s.text)
          }
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .layoutWeight(1)
          .copyOption(CopyOptions.None)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (b: AgentTextBlock, i: number) => String(i) + ':' + b.plain)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 工具状态：进行中显示 display_text，结束后折叠为一行（只显示 display_text，BR-AI-06）。 */
@ComponentV2
export struct AgentToolRow {
  @Param tool: AgentTool = new AgentTool('', 'start', '');

  build() {
    Row({ space: CouliSpacing.space2 }) {
      if (this.tool.running) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color(CouliColors.textSecondary)
      } else {
        CouliIcon({
          name: this.tool.phase === 'failed' ? 'info' : 'check', iconSize: 16,
          color: this.tool.phase === 'failed' ? CouliColors.statusWarningText : CouliColors.statusSuccessText
        })
      }
      Text(this.tool.displayText)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .layoutWeight(1)
    }
    .width('100%')
  }
}

/** 一个按钮（命中区 48vp；读屏完整名称）。 */
@ComponentV2
export struct AgentActionButton {
  @Param label: string = '';
  @Param spoken: string = '';
  @Param variant: CouliButtonVariant = CouliButtonVariant.SECONDARY;
  @Param disabled: boolean = false;
  @Param buttonId: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    CouliButton({
      text: this.label,
      variant: this.variant,
      buttonSize: CouliButtonSize.COMPACT,
      disabled: this.disabled,
      accessibilityName: this.spoken.length > 0 ? this.spoken : this.label,
      buttonId: this.buttonId,
      onTap: () => {
        this.onTap();
      }
    })
  }
}

/** 快捷追问胶囊（用户点击才发送，绑定渲染时的对话世代）。 */
@ComponentV2
export struct AgentChipRow {
  @Param chips: AgentChipTap[] = [];
  @Param disabled: boolean = false;
  @Param port: AgentScreenPort | undefined = undefined;

  build() {
    Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
      ForEach(this.chips, (c: AgentChipTap, i: number) => {
        Row() {
          CouliChip({ label: c.text, tone: CouliChipTone.OUTLINE })
        }
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .opacity(this.disabled ? 0.4 : 1)
        .accessibilityGroup(true)
        .accessibilityText(c.text)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          if (!this.disabled) {
            this.port?.chip(c);
          }
        })
      }, (c: AgentChipTap, i: number) => String(c.conversation) + ':' + String(i) + ':' + c.sendText)
    }
    .width('100%')
  }
}

/** 商品卡（与搜索结果相同的紧凑布局，F-AGENT-11）+ match_tag / spec_text（AI-04，G20）+「换一批」「这个券已领完」（G25）。 */
@ComponentV2
export struct AgentProductItem {
  @Param item: AgentProductView | undefined = undefined;
  @Param port: AgentScreenPort | undefined = undefined;
  @Param grid: boolean = false;
  @Param disabled: boolean = false;

  private data(): ProductCardData {
    const p: AgentScreenPort | undefined = this.port;
    if (p === undefined || this.item === undefined) {
      return new ProductCardData();
    }
    const d: ProductCardData = p.productCard(this.item.json as Record<string, Object>);
    if (this.item.buy === null && d.buyState === BuyButtonState.NORMAL) {
      // 没有购买票据（【停止】过的这一轮、没有 link_id）：按钮置灰，不给可点的入口（R1-03）。
      d.buyState = BuyButtonState.DISABLED;
    }
    return d;
  }

  private matchText(): string {
    const tag: Object | null | undefined = this.item?.json['match_tag'];
    return typeof tag === 'string' && this.port !== undefined ? this.port.text('agent.match.' + (tag as string)) : '';
  }

  private specText(): string {
    const spec: Object | null | undefined = this.item?.json['spec_text'];
    if (typeof spec !== 'string' || this.port === undefined) {
      return '';
    }
    return this.port.text('agent.match.title_shows').split('{spec}').join(spec as string);
  }

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Column() {
        ProductCard({
          data: this.data(),
          variant: this.grid ? ProductCardVariant.GRID : ProductCardVariant.AI,
          // 网格项同样画购买按钮（R1-13：layout=grid 也要能直接购买，03 §7.4）。
          showBuy: true,
          onBuy: () => {
            const buy = this.item?.buy;
            if (buy !== null && buy !== undefined) {
              this.port?.buy(buy);
            }
          }
        })
      }
      .width('100%')
      .onClick(() => {
        const detail = this.item?.detail;
        if (detail !== null && detail !== undefined) {
          this.port?.tap(detail);
        }
      })
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
        if (this.matchText().length > 0) {
          MatchBadge({ text: this.matchText() })
        }
        if (this.specText().length > 0) {
          MatchBadge({ text: this.specText() })
        }
      }
      if (this.item !== undefined && this.item.couponGone) {
        Text(this.port?.text('agent.draft.coupon_gone') ?? '')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText))
      }
      if (this.item !== undefined && this.item.refresh !== null) {
        AgentChipRow({ chips: [this.item.refresh as AgentChipTap], disabled: this.disabled, port: this.port })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 收益卡（D32，无高保真稿 G31：用钱包汇总的字号与颜色，两列数字 + 一行提现摘要 + 两个按钮；待补稿）。 */
@ComponentV2
export struct AgentEarningsCard {
  @Param view: EarningsView | undefined = undefined;
  @Param taps: AgentTap[] = [];
  @Param port: AgentScreenPort | undefined = undefined;

  private t(key: string): string {
    return this.port?.text(key) ?? '';
  }

  @Builder
  amountCell(label: string, value: string, sub: string) {
    Column({ space: CouliSpacing.space1 }) {
      Text(label)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      Text(value)
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
        .accessibilityText(this.view !== undefined && this.view.masked ? this.t('agent.draft.amount_hidden') : value)
      if (sub.length > 0) {
        Text(sub)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .accessibilityGroup(true)
  }

  /** 「最早预计 11 月结算」（BR-TEXT-04，R1-15；文字在 Core 的 AgentDraftTexts.earningsCredit 里取好）。 */
  private creditSub(v: EarningsView): string {
    return AgentDraftTexts.earningsCredit(v.creditPeriod, v.creditOverdue);
  }

  build() {
    if (this.view !== undefined) {
      Column({ space: CouliSpacing.space3 }) {
        Text(this.t('agent.draft.earnings.title'))
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
        if (this.view.shape === EarningsShape.LIVE) {
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space4), cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
            this.amountCell(this.t('agent.draft.earnings.withdrawable'), this.view.withdrawable ?? '', '')
            this.amountCell(this.t('agent.draft.earnings.estimated'), this.view.estimatedTotal ?? '',
              this.creditSub(this.view))
          }
          .width('100%')
          if (this.view.latestWithdrawalShown) {
            Row({ space: CouliSpacing.space2 }) {
              Text(this.t('agent.draft.earnings.latest') + ' · ' + (this.view.latestTitle ?? ''))
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
                .layoutWeight(1)
              Text(this.t('agent.earnings.applied_amount') + ' ' + (this.view.appliedAmount ?? ''))
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
                .accessibilityText(this.view.masked ? this.t('agent.earnings.applied_amount') + ' '
                  + this.t('agent.draft.amount_hidden') : '')
            }
            .width('100%')
          }
          if (this.view.updatedAt !== null) {
            Text(this.t('agent.draft.earnings.updated_at').split('{time}').join(this.view.updatedAt as string))
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          }
        } else {
          Text(this.t('agent.earnings.history'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        }
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
          ForEach(this.taps, (tap: AgentTap, i: number) => {
            AgentActionButton({
              label: tap.label,
              variant: i === 0 ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,
              onTap: () => {
                this.port?.tap(tap);
              }
            })
          }, (tap: AgentTap, i: number) => tap.run + ':' + tap.cardId + ':' + String(i))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/** 一张卡：已注册类型按类型渲染；未知 / 不合 schema / 版本过高只显示 fallback_text（纯文字、不可点）。 */
@ComponentV2
export struct AgentCardItem {
  @Param view: AgentCardView | undefined = undefined;
  @Param port: AgentScreenPort | undefined = undefined;
  @Param disabled: boolean = false;
  /** 卡片可用宽度（vp，onAreaChange 更新）与字号：layout=grid 按商品数量、宽度、字号定列数（R1-13）。 */
  @Local areaWidth: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private gridColumns(): number {
    const v: AgentCardView | undefined = this.view;
    if (v === undefined || v.layout !== 'grid') {
      return 1;
    }
    return ProductGridLayout.columns(v.products.length, this.areaWidth, this.fontScale.scale);
  }

  private t(key: string): string {
    return this.port?.text(key) ?? '';
  }

  @Builder
  lines(v: AgentCardView) {
    if (v.title.length > 0) {
      Text(v.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
    }
    ForEach(v.lines, (line: string, i: number) => {
      Text(line)
        .attributeModifier(new CouliTextModifier(i === 0 ? CouliTypography.body : CouliTypography.footnote,
          i === 0 ? CouliColors.textPrimary : CouliColors.textSecondary))
        .copyOption(CopyOptions.None)
    }, (line: string, i: number) => String(i) + ':' + line)
    if (v.amountText !== null) {
      Text(v.amountLabel + ' ' + (v.amountText as string))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
    }
  }

  @Builder
  tapButton(tap: AgentTap | null, primary: boolean) {
    if (tap !== null) {
      AgentActionButton({
        label: tap.text,
        spoken: tap.label,
        variant: primary ? CouliButtonVariant.PRIMARY : CouliButtonVariant.SECONDARY,
        onTap: () => {
          this.port?.tap(tap);
        }
      })
    }
  }

  build() {
    if (this.view !== undefined) {
      if (this.view.card.kind !== AgentCardKind.KNOWN) {
        // 受限渲染后的纯文字（共性第 30 条：剥离 URL / scheme / 口令，不可点、无按钮）。
        Text(this.view.fallbackPlain)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .copyOption(CopyOptions.None)
          .width('100%')
      } else if (this.view.card.type === AgentCardType.PRODUCT_LIST || this.view.card.type === AgentCardType.REBATE_QUOTE) {
        Column({ space: CouliSpacing.space3 }) {
          // layout=grid：两列网格（1 件、窄屏、字号放大时单列）；list / 单商品卡：一列（R1-13）。
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space3),
            cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
            ForEach(this.view.products, (p: AgentProductView, i: number) => {
              Column() {
                AgentProductItem({ item: p, port: this.port, grid: this.view?.layout === 'grid', disabled: this.disabled })
              }
              .width(this.gridColumns() === 1 ? '100%' : 'calc(50% - 6vp)')
            }, (p: AgentProductView, i: number) => String(i) + ':' + JSON.stringify(p.json['card_id']) + ':'
              + JSON.stringify(p.json['link_id']) + ':' + JSON.stringify(p.json['availability']) + ':'
              + String(p.buy !== null))
          }
          .width('100%')
          .onAreaChange((_old: Area, now: Area) => {
            this.areaWidth = now.width as number;
            CouliFontScale.refresh();
          })
          if (this.view.lines.length > 0) {
            AgentCardFrame() {
              this.lines(this.view as AgentCardView)
            }
          }
        }
        .width('100%')
      } else if (this.view.card.type === AgentCardType.EARNINGS_SUMMARY) {
        AgentCardFrame() {
          AgentEarningsCard({ view: this.view?.earnings ?? undefined, taps: this.view?.earningsTaps ?? [], port: this.port })
        }
      } else if (this.view.card.type === AgentCardType.PAGE_GUIDE) {
        // 页面引导卡（D31，无高保真稿 G31）：notice 同族版式（说明 + 一个次要按钮），待补稿。
        AgentCardFrame() {
          Text(this.view?.guideText ?? '')
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          this.tapButton(this.view?.guide ?? null, false)
        }
      } else if (this.view.card.type === AgentCardType.NOTICE) {
        AgentCardFrame() {
          this.lines(this.view as AgentCardView)
          AgentChipRow({ chips: this.view?.chips ?? [], disabled: this.disabled, port: this.port })
        }
      } else {
        AgentCardFrame() {
          this.lines(this.view as AgentCardView)
          this.tapButton(this.view?.rule ?? null, false)
          this.tapButton(this.view?.order ?? null, false)
          this.tapButton(this.view?.auth ?? null, true)
          this.tapButton(this.view?.handoff ?? null, false)
        }
      }
    }
  }
}

/** 错误与收尾提示（连接中断 +【重试】、流内 error +【去搜索】、额度用完、【新对话】）。 */
@ComponentV2
export struct AgentErrorBlock {
  @Param error: AgentErrorView | undefined = undefined;
  @Param port: AgentScreenPort | undefined = undefined;
  @Param retryDisabled: boolean = false;

  private t(key: string): string {
    return this.port?.text(key) ?? '';
  }

  build() {
    if (this.error !== undefined) {
      Column({ space: CouliSpacing.space2 }) {
        Row({ space: CouliSpacing.space2 }) {
          CouliIcon({ name: 'info', iconSize: 18, color: CouliColors.statusWarningText })
          Text(this.error.text)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .focusable(true)
        .accessibilityGroup(true)
        if (this.error.quotaHint.length > 0) {
          Text(this.error.quotaHint)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        if (this.error.searchHint.length > 0) {
          Text(this.error.searchHint)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
          if (this.error.retry !== null) {
            AgentActionButton({
              // 「回复中」/ duplicate 30506 的【刷新】（G40）；其余【重试】。
              label: this.t(this.error.retry.mode === AgentRetryMode.REFRESH ? 'agent.draft.refresh' : 'agent.draft.retry'),
              variant: CouliButtonVariant.PRIMARY, disabled: this.retryDisabled,
              onTap: () => {
                const r = this.error?.retry;
                if (r !== null && r !== undefined) {
                  this.port?.retry(r);
                }
              }
            })
          }
          if (this.error.search !== null) {
            AgentActionButton({
              label: this.error.searchLabel, variant: CouliButtonVariant.PRIMARY,
              onTap: () => {
                const s = this.error?.search;
                if (s !== null && s !== undefined) {
                  this.port?.tap(s);
                }
              }
            })
          }
          if (this.error.login !== null) {
            AgentActionButton({
              label: (this.error.login as AgentTap).label,
              onTap: () => {
                const l = this.error?.login;
                if (l !== null && l !== undefined) {
                  this.port?.tap(l);
                }
              }
            })
          }
          if (this.error.newChat !== null) {
            AgentActionButton({
              label: this.t('agent.draft.new_chat'),
              onTap: () => {
                const n = this.error?.newChat;
                if (n !== null && n !== undefined) {
                  this.port?.newChat(n);
                }
              }
            })
          }
        }
      }
      .width('100%')
      .padding(CouliSpacing.space3)
      .backgroundColor(CouliColors.statusWarningBackground)
      .borderRadius(CouliRadius.card)
      .alignItems(HorizontalAlign.Start)
    }
  }
}

/**
 * 【赞】【踩】（AgentResult 稿，与 AiLabel 同一行；APP-10b G28）：点后图标实心（品牌色）并读屏「已赞 / 已踩」；在途两个都不可点；
 * 举报（AgentReported 稿）：已举报的回复显示「已举报」。回调只交回渲染时的回复票据。
 */
@ComponentV2
export struct AgentFeedbackBar {
  @Param feedback: AgentFeedbackView | undefined = undefined;
  @Param report: AgentReportEntryView | undefined = undefined;
  @Param port: AgentScreenPort | undefined = undefined;
  @Param disabled: boolean = false;
  /** 读屏等价入口拿到键盘焦点（此时才画出来，免得焦点框落在看不见的地方）。 */
  @Local reportFocused: boolean = false;

  private t(key: string): string {
    return this.port?.text(key) ?? '';
  }

  @Builder
  thumb(value: string, icon: string, label: string, selectedLabel: string) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      CouliIcon({
        name: icon, iconSize: 20,
        color: this.feedback !== undefined && this.feedback.selected === value ? CouliColors.brandPrimary : CouliColors.textSecondary
      })
    }
    .width(CouliInteraction.minTouchTarget)
    .height(CouliInteraction.minTouchTarget)
    .backgroundColor(Color.Transparent)
    .enabled(this.feedback !== undefined && this.feedback.enabled && !this.disabled)
    .accessibilityText(this.feedback !== undefined && this.feedback.selected === value ? selectedLabel : label)
    .accessibilitySelected(this.feedback !== undefined && this.feedback.selected === value)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      const f = this.feedback;
      if (f !== undefined) {
        this.port?.feedback(f.ticket, value);
      }
    })
  }

  build() {
    Row({ space: CouliSpacing.space1 }) {
      if (this.report !== undefined && this.report.reported) {
        Text(this.t('agent.draft.report.reported'))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: 2, bottom: 2 })
          .backgroundColor(CouliColors.backgroundMuted)
          .borderRadius(CouliRadius.pill)
      }
      if (this.feedback !== undefined) {
        this.thumb('up', 'thumb-up', this.t('agent.draft.feedback.up'), this.t('agent.draft.feedback.up_selected'))
        this.thumb('down', 'thumb-down', this.t('agent.draft.feedback.down'), this.t('agent.draft.feedback.down_selected'))
      }
      if (this.report !== undefined && !this.report.reported) {
        // 读屏等价入口（G29：长按不可达时）：「更多操作，举报」。G54（FU-HM-0715，设计确认前的保守处理）：不占视觉空间、只给读屏与
        // 键盘——绝对定位（不参与行布局，【赞】【踩】位置与稿一致）、透明、不接触摸（点在它下面的【赞】照常生效）；读屏的点击动作与
        // 键盘回车不经触摸命中，仍可打开举报。拿到键盘焦点时才画出来（焦点框可见）。视觉用户的入口是长按回复气泡。
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Text(this.t('agent.draft.report.entry'))
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
        .height(CouliInteraction.minTouchTarget)
        .position({ x: 0, y: 0 })
        .opacity(this.reportFocused ? 1 : 0)
        .hitTestBehavior(HitTestMode.None)
        .backgroundColor(this.reportFocused ? CouliColors.backgroundSurface : Color.Transparent)
        .id('agent_report_a11y_entry')
        .accessibilityLevel('yes')
        .accessibilityText(this.t('agent.draft.report.more_entry'))
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onFocus(() => {
          this.reportFocused = true;
        })
        .onBlur(() => {
          this.reportFocused = false;
        })
        .onClick(() => {
          const r = this.report;
          if (r !== undefined) {
            this.port?.reportOpen(r.ticket);
          }
        })
      }
    }
    .alignItems(VerticalAlign.Center)
  }
}

/** 一轮对话：用户消息（右）+ assistant（工具状态、受限文本、卡片、错误、追问胶囊、AiLabel）。读屏顺序即时间顺序。 */
@ComponentV2
export struct AgentTurnItemView {
  @Param turn: AgentTurnView | undefined = undefined;
  @Param port: AgentScreenPort | undefined = undefined;
  @Param busy: boolean = false;
  @Param limited: boolean = false;
  /** 消息内【重试】/【刷新】的禁用（R2-06：重连查询与刷新用读取闸门，同键重发与新消息用发送闸门；由页面按快照给）。 */
  @Param retryLimited: boolean = false;
  @Param actionLimited: boolean = false;

  build() {
    if (this.turn !== undefined) {
      Column({ space: CouliSpacing.space3 }) {
        if (!this.turn.hideUser && this.turn.userText.length > 0) {
          // 用户原文原样纯文本显示（G41：不剥离、不识别链接、不可点）。
          Row() {
            Blank()
            Text(this.turn.userText)
              .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.buttonPrimaryDefaultText))
              .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3, top: CouliSpacing.space2,
                bottom: CouliSpacing.space2 })
              .backgroundColor(CouliColors.brandPrimary)
              .borderRadius(CouliRadius.card)
              .constraintSize({ maxWidth: '80%' })
              .copyOption(CopyOptions.None)
          }
          .width('100%')
        }
        Column({ space: CouliSpacing.space3 }) {
          ForEach(this.turn.tools, (tool: AgentTool, i: number) => {
            AgentToolRow({ tool: tool })
          }, (tool: AgentTool, i: number) => String(i) + ':' + tool.phase + ':' + tool.displayText)
          if (this.turn.blocks.length > 0) {
            AgentTextView({ blocks: this.turn.blocks })
          }
          ForEach(this.turn.cards, (c: AgentCardView, i: number) => {
            AgentCardItem({ view: c, port: this.port, disabled: this.busy || this.limited })
          }, (c: AgentCardView, i: number) => c.card.cardId + ':' + String(i))
          if (this.turn.streaming && this.turn.statusText.length === 0) {
            Row({ space: CouliSpacing.space2 }) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(CouliColors.textSecondary)
              Text(this.port?.text('agent.draft.streaming_hint') ?? '')
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            }
          }
          if (this.turn.statusText.length > 0) {
            // 「正在停止」（G26）/「已停止」/ 超限说明（limited）。
            Row({ space: CouliSpacing.space2 }) {
              if (this.turn.streaming) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color(CouliColors.textSecondary)
              }
              Text(this.turn.statusText)
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            }
          } else if (this.turn.status === 'cancelled' && this.turn.error === null) {
            Text(this.port?.text('agent.draft.cancelled') ?? '')
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
          if (this.turn.genericError.length > 0) {
            Text(this.turn.genericError)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          }
          if (this.turn.error !== null) {
            AgentErrorBlock({ error: this.turn.error, port: this.port, retryDisabled: this.busy || this.retryLimited })
          }
          if (this.turn.chips.length > 0) {
            AgentChipRow({ chips: this.turn.chips, disabled: this.busy || this.limited, port: this.port })
          }
          if (this.turn.aiLabel !== null || this.turn.feedback !== null || this.turn.report !== null) {
            // 大字号 / 窄屏时换行（AiLabel 一行、【赞】【踩】与举报另起一行），不截断。
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
              if (this.turn.aiLabel !== null) {
                // 每条已结束的回复（含以 error 结束的）都有 AiLabel，读屏能读到（R1-08）。
                Row() {
                  AiLabel({ text: this.turn.aiLabel as string })
                }
                .accessibilityGroup(true)
                .accessibilityLevel('yes')
                .accessibilityText(this.turn.aiLabel as string)
              }
              AgentFeedbackBar({
                feedback: this.turn.feedback ?? undefined, report: this.turn.report ?? undefined, port: this.port,
                disabled: this.actionLimited
              })
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .gesture(LongPressGesture({ repeat: false }).onAction(() => {
          // 长按回复气泡 → 举报（G29；与反馈同一显示条件，已举报的不再提供）。
          const r = this.turn?.report;
          if (r !== null && r !== undefined && !r.reported) {
            this.port?.reportOpen(r.ticket);
          }
        }))
      }
      .width('100%')
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
        bottom: CouliSpacing.space2 })
    }
  }
}
