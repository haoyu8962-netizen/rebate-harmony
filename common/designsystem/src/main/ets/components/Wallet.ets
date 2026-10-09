import { LengthMetrics } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliInteraction, CouliRadius, CouliShadow, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { PriceTerms } from '../format/PriceTerms';
import { CouliButton, CouliButtonVariant } from './Basics';
import { CouliIcon } from './CouliIcon';
import { CouliFormat } from '../format/CouliFormat';
import { rangeBreakable } from './Price';
import { CouliTextModifier } from './CouliText';
import { CouliFontScale } from './FontScale';

/**
 * 两列数字格：200% 一律纵排（GUIDE §7.2 / adaptation-a11y-spec §2）；200% 以下按实测——任一格的任一不可拆分金额段
 * （单值「¥1.23」或区间两端「¥1.23」「–¥2.34」）在当前字号下宽于本列可用宽度，两列改上下排（R1-04）。
 */
const AMOUNT_GRID_ALWAYS_STACK_SCALE: number = 2;

/** 测量误差余量：measureText 不带等宽数字特性（tnum），等宽数字略宽，按 6% + 2vp 留余量。 */
const MEASURE_SLACK_RATIO: number = 1.06;
const MEASURE_SLACK_VP: number = 2;

/** 商品卡大字号阈值（保守取 130%）：价格区改占整卡宽、网格改单列（编排者第 2 轮裁定，三端统一）。 */
export const LARGE_TEXT_SCALE: number = 1.3;

export enum AmountTone {
  /** 普通金额（余额、实付等）：墨棕。 */
  NORMAL = 'normal',
  /** 返利类金额（预估返、预估收益、推广收益）：深橙 + 钟表（GUIDE §7.1）。 */
  REBATE = 'rebate'
}

/** 数字格的一格。value 是已格式化的显示文字；spoken 是读屏用（如「56.78 元」），空串时读 value。 */
export class AmountGridItem {
  readonly label: string;
  readonly value: string;
  readonly spoken: string;
  readonly tone: AmountTone;
  /** 问号说明按钮的读屏名称；空串不显示按钮。 */
  readonly helpLabel: string;
  /** 数值下的小字（如「其中已收货 ¥34.56」）。 */
  readonly note: string;
  /** 是金额（金额隐藏开关打开时隐藏数值与小字）；「10 月结算」这类非金额为 false。 */
  readonly maskable: boolean;
  /**
   * 数值里不可拆分的金额段（单值一段；区间两段「¥a」「–¥b」），参与纵排判断（R1-04 / R2-01）。
   * 只由工厂在构造时算出：money / range 从「分」格式化得到，text 从文字里取含「¥」的词；构造器不公开，不能留空绕过。
   */
  readonly segments: string[];
  /** 小字里不可拆分的金额段（如「¥34.56」），按小字字号参与纵排判断。 */
  readonly noteSegments: string[];

  private constructor(label: string, value: string, spoken: string, tone: AmountTone, helpLabel: string, note: string,
    maskable: boolean, segments: string[]) {
    this.label = label;
    this.value = value;
    this.spoken = spoken;
    this.tone = tone;
    this.helpLabel = helpLabel;
    this.note = note;
    this.maskable = maskable;
    this.segments = segments;
    this.noteSegments = AmountGridItem.moneyWords(note);
  }

  /** 文字里含「¥」的词（按空白切分）：作为不可拆分段参与测量。 */
  static moneyWords(text: string): string[] {
    const out: string[] = [];
    for (const word of text.split(/\s+/)) {
      if (word.indexOf('¥') >= 0) {
        out.push(word);
      }
    }
    return out;
  }

  /** 单个金额（分）：显示、朗读、不可拆分段统一经 CouliFormat。 */
  static money(label: string, fen: number, tone?: AmountTone, helpLabel?: string, note?: string): AmountGridItem {
    // 返利格为 0 或负时不用返利橙（GUIDE §7.1「无返利 / 返利 ¥0 不用橙」）。
    const t: AmountTone = (tone === AmountTone.REBATE && fen <= 0) ? AmountTone.NORMAL : (tone ?? AmountTone.NORMAL);
    const shown: string = CouliFormat.money(fen);
    return new AmountGridItem(label, shown, CouliFormat.moneySpoken(fen), t, helpLabel ?? '', note ?? '', true,
      [shown]);
  }

  /**
   * 不受金额隐藏影响的单个金额（分）：订单的实付金额、已付定金（BR-TEXT-10 细则「金额隐藏」：实付是否隐藏由 UI 稿定，订单稿不隐藏，
   * rule-gaps G21）。显示、朗读、纵排判断与 money 相同，只是 maskable 为 false。
   */
  static moneyPlain(label: string, fen: number, tone?: AmountTone): AmountGridItem {
    const shown: string = CouliFormat.money(fen);
    return new AmountGridItem(label, shown, CouliFormat.moneySpoken(fen), tone ?? AmountTone.NORMAL, '', '', false,
      [shown]);
  }

  /** 区间金额（分）：「¥a–¥b」只在破折号处折行；朗读「a 元到 b 元」；min=max 读单值。 */
  static range(label: string, minFen: number, maxFen: number, tone?: AmountTone, helpLabel?: string,
    note?: string): AmountGridItem {
    // TODO(N-13)：0/0、负数、min>max 按「暂无返利」处理，用常规文字色（不用返利橙）。
    if (minFen < 0 || maxFen <= 0 || minFen > maxFen) {
      return AmountGridItem.text(label, PriceTerms.noRebate, AmountTone.NORMAL, helpLabel, note);
    }
    const parts: string[] = minFen === maxFen ? [CouliFormat.money(minFen)]
      : [CouliFormat.money(minFen), PriceTerms.rangeDash + CouliFormat.money(maxFen)];
    return new AmountGridItem(label, rangeBreakable(parts), CouliFormat.rebateRangeSpoken(minFen, maxFen) ?? '',
      tone ?? AmountTone.NORMAL, helpLabel ?? '', note ?? '', true, parts);
  }

  /**
   * 非金额文字格（如「最早到账 / 10 月结算」「暂无返利」）：不受金额隐藏影响，可在本列内换行。
   * 金额请用 money / range；万一文字里带「¥」金额，含「¥」的词仍作为不可拆分段参与纵排判断。
   */
  static text(label: string, text: string, tone?: AmountTone, helpLabel?: string, note?: string): AmountGridItem {
    return new AmountGridItem(label, text, text, tone ?? AmountTone.NORMAL, helpLabel ?? '', note ?? '', false,
      AmountGridItem.moneyWords(text));
  }
}

/** 估算等宽数字金额段宽度用的字宽（em）：作为 measureText 的下限，测量失败（如本机单测无 UI 上下文）时也能判断。 */
function glyphEm(ch: string): number {
  if (ch >= '0' && ch <= '9') {
    return 0.56;
  }
  switch (ch) {
    case '.':
    case ',':
      return 0.28;
    case '-':
      return 0.36;
    case '¥':
    case '+':
    case '–':
      return 0.56;
    case '*':
      return 0.5;
    default:
      return ch.charCodeAt(0) < 0x2000 ? 0.56 : 1;
  }
}

/** 测量函数：文字、字号（vp，已乘字号缩放）、字重 → 宽度（vp，不含余量）。 */
export type AmountMeasure = (text: string, fontSizeVp: number, fontWeight: number) => number;

/** 数字格纵排判断（纯函数，组件与单测共用）。 */
export class AmountGridLayout {
  /** 按字宽表估算的金额段宽（vp，不含余量）。 */
  static estimate(text: string, fontSizeVp: number): number {
    let em: number = 0;
    for (let i = 0; i < text.length; i++) {
      em += glyphEm(text.charAt(i));
    }
    return em * fontSizeVp;
  }

  /** 金额段宽（vp，含余量）：实测与估算取大。 */
  static segmentWidth(text: string, fontSizeVp: number, fontWeight: number, measure?: AmountMeasure): number {
    let measured: number = 0;
    if (measure !== undefined) {
      try {
        measured = measure(text, fontSizeVp, fontWeight);
      } catch (e) {
        measured = 0;
      }
    }
    return Math.max(measured, AmountGridLayout.estimate(text, fontSizeVp)) * MEASURE_SLACK_RATIO + MEASURE_SLACK_VP;
  }

  /**
   * 是否纵排：200% 及以上一律纵排；否则任一格的任一不可拆分金额段（数值或小字里的）宽于本列可用宽度就纵排。
   * gridWidth 未知（≤ 0）时按横排（onAreaChange 后重算）。
   */
  static shouldStack(items: AmountGridItem[], gridWidth: number, scale: number, large: boolean, onBrand: boolean,
    masked: boolean, measure?: AmountMeasure): boolean {
    if (scale >= AMOUNT_GRID_ALWAYS_STACK_SCALE - 0.001) {
      return true;
    }
    const n: number = items.length;
    if (n < 2 || gridWidth <= 0) {
      return false;
    }
    const column: number = (gridWidth - CouliSpacing.space4 * (n - 1)) / n;
    const valueSize: number = (large ? CouliTypography.title : CouliTypography.body).size * scale;
    const valueWeight: number = onBrand ? CouliFontWeight.bold : CouliFontWeight.semibold;
    const noteSize: number = CouliTypography.footnote.size * scale;
    for (const item of items) {
      const hidden: boolean = masked && item.maskable;
      const segs: string[] = hidden ? [PriceTerms.amountMask] : item.segments;
      for (const seg of segs) {
        if (AmountGridLayout.segmentWidth(seg, valueSize, valueWeight, measure) > column) {
          return true;
        }
      }
      if (!hidden) {
        for (const seg of item.noteSegments) {
          if (AmountGridLayout.segmentWidth(seg, noteSize, CouliFontWeight.regular, measure) > column) {
            return true;
          }
        }
      }
    }
    return false;
  }
}

/**
 * 两列数字格（GUIDE §7.2「数字格」）：上标签（12 灰棕，可带问号按钮）下数值（等宽，17 或 22 / 600）；两列等宽左对齐。
 * 字号放大超过阈值时两列改上下排（返利在上由调用方按顺序给）。onBrand：狸橙实底卡内一律白字、标签 14（GUIDE §7.2）。
 * 读屏：每格「标签，数值」合为一项（adaptation-a11y-spec §9）。
 */
@ComponentV2
export struct AmountGrid {
  @Param items: AmountGridItem[] = [];
  /**
   * 纵排时的顺序（同一组格子，返利在上；空数组 = 与 items 同序）。横排与纵排顺序不同的调用方（订单列表卡：横排左实付右返利、纵排返利
   * 在上）分别给两套（APP-08 R1-05）。onHelp 的序号按当前排列。
   */
  @Param stackedItems: AmountGridItem[] = [];
  @Param large: boolean = true;
  @Param onBrand: boolean = false;
  /** 金额隐藏开关已打开：金额一律显示「****」，分项小字不显示，读屏读「金额已隐藏」（BR-TEXT-10 细则「金额隐藏」）。 */
  @Param masked: boolean = false;
  @Event onHelp: (index: number) => void = (_index: number) => {
  };
  /** 字号（运行中变化时布局随之切换，R1-03）。 */
  @Local fontScale: CouliFontScale = CouliFontScale.shared();
  /** 本组件可用宽度（vp），onAreaChange 更新。 */
  @Local gridWidth: number = 0;

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  /** 实测金额段宽（vp，不含余量）；measureText 不可用时返回 0（由估算兜底）。 */
  private measure(text: string, fontSizeVp: number, fontWeight: number): number {
    const px: number = this.getUIContext().getMeasureUtils().measureText({
      textContent: text,
      // 按当前缩放换算成 vp 测量（与渲染时 fp 的实际大小一致）。
      fontSize: fontSizeVp + 'vp',
      fontWeight: fontWeight
    });
    return this.getUIContext().px2vp(px);
  }

  /**
   * 是否纵排（AmountGridLayout.shouldStack）。依赖 fontScale.scale（@Trace）、gridWidth、items、masked，任一变化都重算。
   */
  private stacked(): boolean {
    return AmountGridLayout.shouldStack(this.items, this.gridWidth, this.fontScale.scale, this.large, this.onBrand,
      this.masked, (text: string, size: number, weight: number): number => this.measure(text, size, weight));
  }

  private hides(item: AmountGridItem): boolean {
    return this.masked && item.maskable;
  }

  private labelColor(item: AmountGridItem): ResourceColor {
    if (this.onBrand) {
      return CouliColors.textInverse;
    }
    return item.tone === AmountTone.REBATE ? CouliColors.rebateText : CouliColors.textSecondary;
  }

  private valueColor(item: AmountGridItem): ResourceColor {
    if (this.onBrand) {
      return CouliColors.textInverse;
    }
    return item.tone === AmountTone.REBATE ? CouliColors.rebateText : CouliColors.textPrimary;
  }

  @Builder
  cell(item: AmountGridItem, index: number) {
    Column({ space: CouliSpacing.space1 }) {
      Row({ space: CouliSpacing.space1 }) {
        if (item.tone === AmountTone.REBATE) {
          CouliIcon({ name: 'clock', iconSize: 16, color: this.labelColor(item) })
        }
        Text(item.label)
          .attributeModifier(new CouliTextModifier(this.onBrand ? CouliTypography.footnote : CouliTypography.footnote,
            this.labelColor(item), this.onBrand ? CouliFontWeight.semibold : undefined))
          .flexShrink(1)
        if (item.helpLabel.length > 0) {
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            CouliIcon({ name: 'help', iconSize: 16, color: this.labelColor(item) })
          }
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, left: -14, right: -14 })
          .backgroundColor(Color.Transparent)
          .accessibilityText(item.helpLabel)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            this.onHelp(index);
          })
        }
      }
      .accessibilityGroup(item.helpLabel.length === 0)

      Text(this.hides(item) ? PriceTerms.amountMask : item.value)
        .attributeModifier(new CouliTextModifier(this.large ? CouliTypography.title : CouliTypography.body,
          this.valueColor(item), this.onBrand ? CouliFontWeight.bold : CouliFontWeight.semibold, true))
        .wordBreak(WordBreak.NORMAL)
        .accessibilityText(item.label + PriceTerms.comma + (this.hides(item) ? PriceTerms.amountHiddenSpoken
          : (item.spoken.length > 0 ? item.spoken : item.value)))
      if (item.note.length > 0 && !this.hides(item)) {
        Text(item.note)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, this.onBrand ? CouliColors.textInverse
            : CouliColors.textSecondary, this.onBrand ? CouliFontWeight.semibold : undefined, true))
      }
    }
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.grid()
    }
    .width('100%')
    .onAreaChange((_old: Area, now: Area) => {
      this.gridWidth = now.width as number;
      CouliFontScale.refresh();
    })
  }

  @Builder
  grid() {
    if (this.stacked()) {
      Column({ space: CouliSpacing.space3 }) {
        ForEach(this.stackedItems.length > 0 ? this.stackedItems : this.items, (item: AmountGridItem, index: number) => {
          this.cell(item, index)
        }, (item: AmountGridItem, index: number) => index + item.label)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    } else {
      Row({ space: CouliSpacing.space4 }) {
        ForEach(this.items, (item: AmountGridItem, index: number) => {
          Column() {
            this.cell(item, index)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }, (item: AmountGridItem, index: number) => index + item.label)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')
    }
  }
}

/**
 * 钱包主卡（GUIDE §7.2）：狸橙实底、圆角 16、内边距 20；第一行「可提现余额 + 眼睛」与「提现记录 ›」flex-wrap；
 * 大数字 34/700 白字；【提现】白底深橙字，放不下时整块换到金额下一行靠左；下方白字两列数字格（冻结中 / 已提现）。
 * 卡内白字不小于 14（GUIDE §7.2）。所有文字由调用方给。
 */
@ComponentV2
export struct WalletHeroCard {
  @Param label: string = '';
  @Param amount: string = '';
  @Param amountSpoken: string = '';
  @Param amountHidden: boolean = false;
  /** 眼睛按钮读屏名称（amount_mask.hide / amount_mask.show）。 */
  @Param eyeLabel: string = '';
  @Param withdrawText: string = '';
  @Param recordText: string = '';
  @Param items: AmountGridItem[] = [];
  /** 【提现】置灰（APP-09 G11：withdraw_enabled=false、待抵扣、风控暂停、显示断网缓存）；读屏读「不可用」。 */
  @Param withdrawDisabled: boolean = false;
  /** 【提现】按钮 id（弹层关闭后焦点回到它；空串不设）。 */
  @Param withdrawId: string = '';
  @Event onToggleHidden: () => void = () => {
  };
  @Event onWithdraw: () => void = () => {
  };
  @Event onRecord: () => void = () => {
  };
  @Event onHelp: (index: number) => void = (_index: number) => {
  };

  build() {
    Column({ space: CouliSpacing.space4 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(CouliSpacing.space3), cross: LengthMetrics.vp(CouliSpacing.space1) } }) {
        Row({ space: 0 }) {
          Text(this.label)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textInverse,
              CouliFontWeight.semibold))
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            CouliIcon({ name: this.amountHidden ? 'eye-off' : 'eye', iconSize: 20, color: CouliColors.textInverse })
          }
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, left: -6 })
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.eyeLabel)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            this.onToggleHidden();
          })
        }
        .flexGrow(1)

        if (this.recordText.length > 0) {
          Row({ space: CouliSpacing.space1 }) {
            Text(this.recordText)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textInverse,
                CouliFontWeight.semibold))
            CouliIcon({ name: 'chevron', iconSize: 16, color: CouliColors.textInverse })
          }
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3 })
          .accessibilityGroup(true)
          .accessibilityText(this.recordText)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            this.onRecord();
          })
        }
      }

      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(CouliSpacing.space3), cross: LengthMetrics.vp(CouliSpacing.space3) } }) {
        Text(this.amountHidden ? PriceTerms.amountMask : this.amount)
          .attributeModifier(new CouliTextModifier(CouliTypography.display, CouliColors.textInverse,
            CouliFontWeight.bold, true))
          .wordBreak(WordBreak.NORMAL)
          .accessibilityText(this.label + PriceTerms.comma
            + (this.amountHidden ? PriceTerms.amountHiddenSpoken : this.amountSpoken))
          .flexGrow(1)
        CouliButton({
          text: this.withdrawText,
          variant: CouliButtonVariant.ON_BRAND,
          disabled: this.withdrawDisabled,
          buttonId: this.withdrawId,
          onTap: () => {
            if (!this.withdrawDisabled) {
              this.onWithdraw();
            }
          }
        })
          .constraintSize({ minWidth: 96 })
      }

      if (this.items.length > 0) {
        AmountGrid({
          items: this.items,
          large: false,
          onBrand: true,
          masked: this.amountHidden,
          onHelp: (i: number) => {
            this.onHelp(i);
          }
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(CouliSpacing.space5)
    .backgroundColor(CouliColors.rebateSolidBackground)
    .borderRadius(CouliRadius.card)
    .width('100%')
  }
}

/** 宫格入口的一项。 */
export class EntryGridItem {
  readonly label: string;
  readonly icon: string;

  constructor(label: string, icon: string) {
    this.label = label;
    this.icon = icon;
  }
}

/**
 * 宫格入口（GUIDE §7.2「宫格入口」）：白卡片内 4 列（可配），每格图标 24（墨棕线性）+ 14 文字，格高 ≥ 72，整格命中；分组标题 17/600。
 * 字号放大时格子增高、文字换行，不截断。
 */
@ComponentV2
export struct EntryGrid {
  @Param title: string = '';
  @Param items: EntryGridItem[] = [];
  /** 列数（我的页 4 列；钱包入口行 2 列）。 */
  @Param columns: number = 4;
  @Event onSelect: (index: number) => void = (_index: number) => {
  };

  build() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.title.length > 0) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.items, (item: EntryGridItem, index: number) => {
          Column({ space: CouliSpacing.space1 }) {
            CouliIcon({ name: item.icon, iconSize: 24, color: CouliColors.textPrimary })
            Text(item.label)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
              .textAlign(TextAlign.Center)
          }
          .width((100 / Math.max(1, this.columns)) + '%')
          .constraintSize({ minHeight: 72 })
          .justifyContent(FlexAlign.Center)
          .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
          .accessibilityGroup(true)
          .accessibilityText(item.label)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => {
            this.onSelect(index);
          })
        }, (item: EntryGridItem, index: number) => index + item.label)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(CouliSpacing.space4)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.card)
    .width('100%')
  }
}
