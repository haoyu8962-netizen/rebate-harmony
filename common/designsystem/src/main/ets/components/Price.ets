import { LengthMetrics } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliInteraction, CouliRadius, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTextStyle, CouliTypography } from '../CouliTypography';
import {
  BuyButtonModel, PresaleDisplay, PriceTagContent, PriceTagModel, RebateKind, RebateTagContent, RebateTagModel
} from '../format/PriceModels';
import { PriceTerms } from '../format/PriceTerms';
import { CouliButton, CouliButtonSize, CouliButtonVariant, CouliChip } from './Basics';
import { CouliIcon } from './CouliIcon';
import { DisclaimerNote } from './DisclaimerNote';
import { CouliTextModifier, TABULAR_FEATURE } from './CouliText';

export enum PriceTagSize {
  /** 搜索列表卡、网格卡：主价 22/700。 */
  LIST = 'list',
  /** AI 结果卡：主价 17/700。 */
  AI = 'ai',
  /** 详情页大卡：主价 34/700。 */
  DETAIL = 'detail'
}

/** 区间只在破折号前折行：破折号前放零宽空格（可断），后放词连接符（不可断）；两段各自整体不拆。 */
export function rangeBreakable(parts: string[]): string {
  if (parts.length < 2) {
    return parts.length === 1 ? parts[0] : '';
  }
  const tail: string = parts[1];
  return parts[0] + '​' + tail.substring(0, 1) + '⁠' + tail.substring(1);
}

/**
 * 价格（BR-PRICE-04/05/22；GUIDE §3「价格」）：口径词 12 灰棕 + 主价墨棕粗体等宽；不用删除线；不用橙。
 * showSub = true 时在下面接副行（「券前 ¥x · 券 ¥y」或「无券」）。
 * 预售（R2-02，03 §10.2）：presale = INLINE（默认）时组件自己显示「预售」标签（主价前，放不下整块换行）与预售说明
 * （presale.price_note，PriceTerms.presaleNote，TODO(N-11)，副行下），读屏名称包含两者；
 * 商品卡把标签放进优惠标签行、说明放进说明行时传 EXTERNAL，PriceTag 不再重复显示与朗读。
 * 读屏合为一项：「预售，券后 29.9 元，券前 39.9 元，券 10 元，定金与尾款以下单页为准」。
 */
@ComponentV2
export struct PriceTag {
  @Param content: PriceTagContent = new PriceTagContent('', '', null, true, null, '', null);
  @Param tagSize: PriceTagSize = PriceTagSize.LIST;
  @Param showSub: boolean = false;
  @Param presale: PresaleDisplay = PresaleDisplay.INLINE;

  private amountStyle(): CouliTextStyle {
    switch (this.tagSize) {
      case PriceTagSize.DETAIL:
        return CouliTypography.display;
      case PriceTagSize.AI:
        return CouliTypography.body;
      default:
        return CouliTypography.title;
    }
  }

  private noteStyle(): CouliTextStyle {
    return this.tagSize === PriceTagSize.DETAIL ? CouliTypography.footnote : CouliTypography.caption;
  }

  private inlinePresale(): boolean {
    return this.presale === PresaleDisplay.INLINE;
  }

  @Builder
  mainText() {
    Text() {
      Span(this.content.mainLabel)
        .fontSize(CouliTypography.caption.fontSize)
        .fontColor(CouliColors.textSecondary)
        .fontWeight(CouliFontWeight.regular)
      Span(' ')
        .fontSize(CouliTypography.caption.fontSize)
      Span(this.content.mainAmount)
        .fontSize(this.amountStyle().fontSize)
        .fontColor(CouliColors.priceText)
        .fontWeight(CouliFontWeight.bold)
    }
    .lineHeight(this.amountStyle().lineHeight)
    .fontFeature(TABULAR_FEATURE)
    // 口径词与金额之间可折行；金额本身不拆（不在数字中间或小数点前断开），不设 maxLines、不裁切。
    // 一个金额段整行都放不下时由外层改布局（价格区占整卡宽 / 网格改单列）。
    .wordBreak(WordBreak.NORMAL)
  }

  build() {
    Column({ space: this.tagSize === PriceTagSize.DETAIL ? CouliSpacing.space1 : 0 }) {
      if (this.inlinePresale() && this.content.presaleLabel !== null) {
        // 「预售」标签在主价前；放不下时主价整块换到下一行（不缩字号、不截断）。
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
          space: { main: LengthMetrics.vp(CouliSpacing.space2), cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
          CouliChip({ label: this.content.presaleLabel })
          this.mainText()
        }
      } else {
        this.mainText()
      }

      if (this.showSub) {
        Text(this.content.noCoupon ? PriceTerms.noCoupon : (this.content.subLine ?? ''))
          .attributeModifier(new CouliTextModifier(this.noteStyle(), CouliColors.textSecondary, undefined, true))
      }
      if (this.inlinePresale() && this.content.presaleNote !== null) {
        Text(this.content.presaleNote)
          .attributeModifier(new CouliTextModifier(this.noteStyle(), CouliColors.textSecondary))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .accessibilityGroup(true)
    .accessibilityText(PriceTagModel.spoken(this.content, this.showSub, this.presale))
  }
}

export enum RebateTagSize {
  /** 列表 / AI 卡：12/18，胶囊，钟表 14。 */
  SMALL = 'small',
  /** 详情页：金额 22/700，标签词 17。 */
  LARGE = 'large',
  /** 窄卡（宽 < 180，首页网格）两行：「钟表 + 预估返」一行、完整金额一行（GUIDE §6）。 */
  BLOCK = 'block'
}

/**
 * 返利标签（GUIDE §7.1：浅底 #FBEFE8、钟表 + 标签词 + 金额都用深橙，金额 600；状态不只靠颜色：有钟表图标与「预估返」）。
 * 区间只在破折号处折行；放不下时整块换行由外层 Flex 处理；不截断、不缩字号。
 * 「暂无返利」：inList = true 时不显示（BR-TEXT-10 列表隐藏）；显示时用中性浅底，不用橙（GUIDE §7.1）。
 */
@ComponentV2
export struct RebateTag {
  @Param content: RebateTagContent = RebateTagModel.make('no_rebate', 0, 0, false);
  @Param tagSize: RebateTagSize = RebateTagSize.SMALL;
  @Param inList: boolean = false;

  private neutral(): boolean {
    return this.content.kind === RebateKind.NONE;
  }

  private fg(): ResourceColor {
    return this.neutral() ? CouliColors.statusPendingText : CouliColors.rebateText;
  }

  private labelStyle(): CouliTextStyle {
    return this.tagSize === RebateTagSize.LARGE ? CouliTypography.body : CouliTypography.caption;
  }

  private amountStyle(): CouliTextStyle {
    if (this.tagSize === RebateTagSize.LARGE) {
      return CouliTypography.title;
    }
    return this.tagSize === RebateTagSize.BLOCK ? CouliTypography.footnote : CouliTypography.caption;
  }

  private label(): string {
    return this.content.hasAmount ? PriceTerms.rebate : this.content.text;
  }

  @Builder
  amountText() {
    Text(rangeBreakable(this.content.amountParts))
      .fontSize(this.amountStyle().fontSize)
      .lineHeight(this.amountStyle().lineHeight)
      .fontWeight(this.tagSize === RebateTagSize.SMALL ? CouliFontWeight.semibold : CouliFontWeight.bold)
      .fontColor(this.fg())
      .fontFeature(TABULAR_FEATURE)
      .wordBreak(WordBreak.NORMAL)
  }

  build() {
    if (!(this.inList && this.content.kind === RebateKind.NONE)) {
      if (this.tagSize === RebateTagSize.BLOCK) {
        Column({ space: 0 }) {
          Row({ space: CouliSpacing.space1 }) {
            CouliIcon({ name: 'clock', iconSize: 14, color: this.fg() })
            Text(this.label())
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, this.fg()))
              .flexShrink(1)
          }

          if (this.content.hasAmount) {
            this.amountText()
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: CouliSpacing.space1,
          bottom: CouliSpacing.space1 })
        .backgroundColor(this.neutral() ? CouliColors.statusPendingBackground : CouliColors.rebateBackground)
        .borderRadius(CouliRadius.small)
        .accessibilityGroup(true)
        .accessibilityText(this.content.spokenText)
      } else {
        Row({ space: CouliSpacing.space1 }) {
          if (!this.neutral()) {
            CouliIcon({
              name: 'clock',
              iconSize: this.tagSize === RebateTagSize.LARGE ? 20 : 14,
              color: this.fg()
            })
          }
          Text() {
            Span(this.label() + (this.content.hasAmount ? ' ' : ''))
              .fontSize(this.labelStyle().fontSize)
              .fontColor(this.fg())
              .fontWeight(CouliFontWeight.regular)
            if (this.content.hasAmount) {
              Span(rangeBreakable(this.content.amountParts))
                .fontSize(this.amountStyle().fontSize)
                .fontColor(this.fg())
                .fontWeight(this.tagSize === RebateTagSize.LARGE ? CouliFontWeight.bold : CouliFontWeight.semibold)
            }
          }
          .lineHeight(this.amountStyle().lineHeight)
          .fontFeature(TABULAR_FEATURE)
          .wordBreak(WordBreak.NORMAL)
          .flexShrink(1)
        }
        .constraintSize({ minHeight: this.tagSize === RebateTagSize.LARGE ? CouliSpacing.space10 : 22, maxWidth: '100%' })
        .padding(this.tagSize === RebateTagSize.LARGE
          ? { left: CouliSpacing.space3, right: CouliSpacing.space3, top: CouliSpacing.space1, bottom: CouliSpacing.space1 }
          : { left: CouliSpacing.space2, right: CouliSpacing.space2, top: 2, bottom: 2 })
        .backgroundColor(this.neutral() ? CouliColors.statusPendingBackground : CouliColors.rebateBackground)
        .borderRadius(this.tagSize === RebateTagSize.LARGE ? CouliRadius.card : CouliRadius.button)
        .accessibilityGroup(true)
        .accessibilityText(this.content.spokenText)
      }
    }
  }
}

/** 「预估返后 ¥x」一行（BR-PRICE-09；墨棕不用橙，GUIDE §7.1）。text = EstNetModel.make(...)，为 null 时不显示。 */
@ComponentV2
export struct EstNetLine {
  @Param text: string | null = null;
  @Param large: boolean = false;
  /** 同卡的返利内容：只有可显示金额（amount / range）时才显示这一行；异常判为「暂无返利」等情况不显示。 */
  @Param rebate: RebateTagContent | null = null;

  build() {
    if (this.text !== null && (this.rebate === null || this.rebate.hasAmount)) {
      Text(this.text)
        .attributeModifier(new CouliTextModifier(this.large ? CouliTypography.footnote : CouliTypography.caption,
          CouliColors.textSecondary, undefined, true))
    }
  }
}

/** 口径 i 按钮的 id 序号（每个实例唯一，弹层关闭后焦点回到它）。 */
class DisclaimerIds {
  private static counter: number = 0;

  static next(): string {
    DisclaimerIds.counter++;
    return 'couli-disclaimer-info-' + DisclaimerIds.counter;
  }
}

export enum DisclaimerMode {
  /** 详情 / 列表底部：常驻全文（每行一个图标 + 文字）。 */
  FULL = 'full',
  /** 卡片：可选前缀（如「以结算为准」）+ i 图标按钮，点开展开全文（BR-PRICE-03）。 */
  CARD = 'card'
}

/**
 * 口径说明（BR-PRICE-03 / 17）。文字（price_basis、rebate_estimate、rebate_compare 等）由调用方按 disclaimer_keys 取好传入。
 * CARD 模式的 i 按钮：视觉 16、命中区 48×48，用负外边距不撑高底行（GUIDE §7.2.1）；读屏名称由调用方给（如「口径说明」）。
 */
@ComponentV2
export struct DisclaimerFooter {
  @Param lines: string[] = [];
  /** FULL 模式每行图标（与 lines 对应，缺省 info）。 */
  @Param icons: string[] = [];
  @Param mode: DisclaimerMode = DisclaimerMode.FULL;
  /** CARD 模式 i 按钮前的短句（如「以结算为准」）；空串不显示。 */
  @Param prefix: string = '';
  @Param buttonLabel: string = '';
  /** FULL 模式是否带浅底框（详情页说明区）。 */
  @Param boxed: boolean = false;
  /**
   * CARD 模式：给了弹层标题与关闭文字时，点 i 打开口径说明弹层（DisclaimerNote，设计稿 SearchDisclaimerNote：正文换行、可滚动、
   * 【知道了】关闭、焦点回到 i）；没给时沿用气泡（DS-01 原行为）。
   */
  @Param noteTitle: string = '';
  @Param noteCloseText: string = '';
  @Local expanded: boolean = false;
  /** i 按钮的 id（弹层关闭后焦点回到这里）。 */
  private infoId: string = DisclaimerIds.next();

  private usesNote(): boolean {
    return DisclaimerNote.available(this.noteTitle, this.lines, this.noteCloseText);
  }

  @Builder
  fullText() {
    Column({ space: CouliSpacing.space2 }) {
      ForEach(this.lines, (line: string, index: number) => {
        Row({ space: CouliSpacing.space2 }) {
          CouliIcon({ name: this.icons[index] ?? 'info', iconSize: 16, color: CouliColors.textSecondary })
            .margin({ top: 2 })
          Text(line)
            .attributeModifier(new CouliTextModifier(
              this.boxed ? CouliTypography.footnote : CouliTypography.caption, CouliColors.textSecondary))
            .flexShrink(1)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
      }, (line: string, index: number) => index + line)
    }
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    if (this.mode === DisclaimerMode.FULL) {
      Column() {
        this.fullText()
      }
      .width('100%')
      .padding(this.boxed ? CouliSpacing.space4 : { top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
      .backgroundColor(this.boxed ? CouliColors.backgroundMuted : Color.Transparent)
      .borderRadius(this.boxed ? CouliRadius.card : 0)
    } else {
      Row({ space: 0 }) {
        if (this.prefix.length > 0) {
          Text(this.prefix)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'info', iconSize: 16, color: CouliColors.textSecondary })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .backgroundColor(Color.Transparent)
        .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, left: this.prefix.length > 0 ? -6 : -14 })
        .id(this.infoId)
        .accessibilityText(this.buttonLabel)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => {
          if (this.usesNote()) {
            DisclaimerNote.open(this.getUIContext(), this.noteTitle, this.lines, this.noteCloseText, this.infoId);
            return;
          }
          this.expanded = !this.expanded;
        })
        .bindPopup(this.expanded && !this.usesNote(), {
          builder: () => {
            this.popupContent()
          },
          placement: Placement.Top,
          onStateChange: (e) => {
            if (!e.isVisible) {
              this.expanded = false;
            }
          }
        })
      }
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  popupContent() {
    Column() {
      this.fullText()
    }
    .padding(CouliSpacing.space3)
    .constraintSize({ maxWidth: 280 })
  }
}

export enum BuyButtonState {
  NORMAL = 'normal',
  LOADING = 'loading',
  DISABLED = 'disabled',
  /** 「稍后再试」：显示调用方给的 retryText（空串时 PriceTerms.retryLater），禁用；不拼返利后缀。 */
  RETRY_LATER = 'retry_later'
}

/**
 * 购买按钮：动词由调用方给（cta.text_key：领券购买 / 去购买 / 去购买（无返利））；BuyButtonModel 决定是否拼「· 预估返 ¥x」。
 * loading、禁用、「稍后再试」不拼后缀（BR-TEXT-14 表 C）。读屏名称：可见文字开头 + 区间 / 单值朗读（adaptation-a11y-spec §9）。
 */
@ComponentV2
export struct BuyButton {
  @Param base: string = '';
  @Param rebate: RebateTagContent = RebateTagModel.make('no_rebate', 0, 0, false);
  @Param amountHidden: boolean = false;
  @Param context: string = 'list';
  @Param state: BuyButtonState = BuyButtonState.NORMAL;
  @Param retryText: string = '';
  @Param compact: boolean = true;
  @Param fullWidth: boolean = false;
  @Event onTap: () => void = () => {
  };

  private label(): string {
    switch (this.state) {
      case BuyButtonState.NORMAL:
        return BuyButtonModel.text(this.base, this.rebate, this.amountHidden, this.context);
      case BuyButtonState.RETRY_LATER:
        return BuyButtonModel.retryText(this.retryText);
      default:
        return this.base;
    }
  }

  private spoken(): string {
    if (this.state !== BuyButtonState.NORMAL) {
      return this.label();
    }
    // 「领券购买，预估返 1.23 元到 2.34 元」「去购买，预估返 2.34 元」；金额隐藏或不显示金额的页面只读动词。
    return BuyButtonModel.spoken(this.base, this.rebate, this.amountHidden, this.context);
  }

  build() {
    CouliButton({
      text: this.label(),
      variant: CouliButtonVariant.PRIMARY,
      buttonSize: this.compact ? CouliButtonSize.COMPACT : CouliButtonSize.REGULAR,
      loading: this.state === BuyButtonState.LOADING,
      disabled: this.state === BuyButtonState.DISABLED || this.state === BuyButtonState.RETRY_LATER,
      fullWidth: this.fullWidth,
      accessibilityName: this.spoken(),
      onTap: () => {
        this.onTap();
      }
    })
  }
}
