import {
  CouliChip, CouliChipTone, CouliColors, CouliComponentMetrics, CouliFontWeight, CouliInteraction, CouliRadius, CouliShadow,
  CouliSpacing, CouliTextModifier, CouliTypography, PriceTerms
} from 'designsystem';

/**
 * 账号状态 / 申诉页的私有视图件（APP-12w-c-harmony，brief-c-harmony H-R01：MeKit / DS 一字不动，本组私有件放这里）。
 * 只收渲染时的值与 @Event 回调；执行逻辑、身份核对、去向全在两个视图里。本文件不出现中文字面量（HM-LINT-1），颜色只取令牌。
 * 新加的功能图标用系统图标集 SymbolGlyph（H-R13 / D10-559），图标是装饰、读屏不读；胶囊用 DS CouliChip（内部 CouliIcon 14）。
 * 视觉节点 id：信息行容器 = <valueId>_row、胶囊 = <valueId>_chip、提示条图标 = <barId>_icon、时间线第 n 步 = <timelineId>_<n>，
 * 其图标 = _<n>_icon、其下连线 = _<n>_line（tests-c-harmony-handback §3.2）。
 */

/** 头部内 Symbol 32（画板 RiskNotice* / AppealResultLifted*；图标块 96 写在 RiskHero 里）。 */
const HERO_SYMBOL: number = 32;
/** 时间线图标列 20；未到的空心圆 10、描边 1.75；连线宽 2、最小 16。 */
const STEP_ICON: number = 20;
const STEP_RING: number = 10;
const STEP_RING_STROKE: number = 1.75;
const STEP_LINE_W: number = 2;
const STEP_LINE_MIN: number = 16;
/** 「接下来可以」圆点 4。 */
const BULLET_DOT: number = 4;

function iconVp(size: number): string {
  return size + 'vp';
}

@Builder
function riskPartsEmptyBuilder() {
}

// ---------------------------------------------------------------- 纯函数（只读参数；run-logic 与宿主检查按取值表断言）

/** R12 / R24：当前状态胶囊色只按本次 getMe 的 risk.state：banned → error；frozen → warning；其余 → muted。 */
export function appealStateChipTone(riskState: string | null): CouliChipTone {
  if (riskState === 'banned') {
    return CouliChipTone.ERROR;
  }
  if (riskState === 'frozen') {
    return CouliChipTone.WARNING;
  }
  return CouliChipTone.MUTED;
}

/** R12 / R24：banned / frozen 带三角；其余不带图标。 */
export function appealStateChipIcon(riskState: string | null): string {
  return riskState === 'banned' || riskState === 'frozen' ? 'alert' : '';
}

/** R4：账号状态信息卡按行 id 选件：申诉中 → pending + 时钟；维持 → warning + 三角；其余行不是胶囊。 */
export function riskRowChipTone(rowId: string): CouliChipTone | null {
  if (rowId === 'risk_appeal') {
    return CouliChipTone.MUTED;
  }
  if (rowId === 'risk_upheld') {
    return CouliChipTone.WARNING;
  }
  return null;
}

export function riskRowChipIcon(rowId: string): string {
  if (rowId === 'risk_appeal') {
    return 'clock';
  }
  if (rowId === 'risk_upheld') {
    return 'alert';
  }
  return '';
}

/** R17 / R23：时间线步态只由版式决定：处理中 = 完成 / 当前 / 未到；维持 = 完成 / 完成 / 警示。 */
export function timelineStates(upheld: boolean): string[] {
  return upheld ? ['done', 'done', 'warning'] : ['done', 'current', 'pending'];
}

// ---------------------------------------------------------------- 头部

/**
 * R2 / R20 头部：图标块 96（圆角 radius.card 16、muted / success 底）内 Symbol 32 → 16 → 标题 title 22/600（标题角色）→ 8 → 说明 14 次文字。
 * 图标块读屏不读。symbol：lock（封禁）/ pause_circle（冻结）/ clock（normal）/ checkmark_circle（已解除）。
 */
@ComponentV2
export struct RiskHero {
  @Param symbol: string = 'clock';
  @Param tone: string = 'muted';
  @Param title: string = '';
  @Param desc: string = '';
  @Param iconId: string = '';
  @Param titleId: string = '';

  private glyph(): Resource {
    if (this.symbol === 'lock') {
      return $r('sys.symbol.lock');
    }
    if (this.symbol === 'pause_circle') {
      return $r('sys.symbol.pause_circle');
    }
    if (this.symbol === 'checkmark_circle') {
      return $r('sys.symbol.checkmark_circle');
    }
    return $r('sys.symbol.clock');
  }

  private success(): boolean {
    return this.tone === 'success';
  }

  build() {
    Column({ space: CouliSpacing.space4 }) {
      Column() {
        SymbolGlyph(this.glyph())
          .fontSize(iconVp(HERO_SYMBOL))
          .fontColor([this.success() ? CouliColors.statusSuccessText : CouliColors.textSecondary])
          .width(HERO_SYMBOL)
          .height(HERO_SYMBOL)
          .accessibilityLevel('no')
      }
      .id(this.iconId)
      .width(96)
      .height(96)
      .borderRadius(CouliRadius.card)
      .backgroundColor(this.success() ? CouliColors.statusSuccessBackground : CouliColors.backgroundMuted)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .accessibilityLevel('no')
      Column({ space: CouliSpacing.space2 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
          .textAlign(TextAlign.Center)
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .id(this.titleId)
        if (this.desc.length > 0) {
          Text(this.desc)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}

// ---------------------------------------------------------------- 账号状态信息卡

/**
 * R3 / R4 信息行：标签 footnote 14 次文字、值 14/500 主文字右对齐（等宽数字、可折行）；行最小高 48（命中下限，画板 44，C5）——最小高放在外层，
 * 上下 8 放在内层（ArkUI 设备上 constraintSize.minHeight 不含 padding，12w-a dev1）。chipTone 非 null 时值用 DS CouliChip。整行读一次「标签，值」。
 */
@ComponentV2
export struct RiskInfoRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param valueId: string = '';
  @Param divider: boolean = true;
  @Param chipTone: CouliChipTone | null = null;
  @Param chipIcon: string = '';
  /** 胶囊节点 id；空串时用 <valueId>_chip。 */
  @Param chipId: string = '';

  build() {
    Column() {
      Column() {
        Row({ space: CouliSpacing.space3 }) {
          Text(this.label)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .flexShrink(0)
          if (this.chipTone !== null) {
            Row() {
              CouliChip({ label: this.value, tone: this.chipTone as CouliChipTone, icon: this.chipIcon })
            }
            .id(this.chipId.length > 0 ? this.chipId : this.valueId + '_chip')
            .flexShrink(1)
          } else {
            Text(this.value)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, CouliFontWeight.medium,
                true))
              .textAlign(TextAlign.End)
              .flexShrink(1)
              .id(this.valueId)
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .justifyContent(FlexAlign.Center)
      if (this.divider) {
        Divider().color(CouliColors.borderSubtle).strokeWidth(1)
      }
    }
    .id(this.valueId + '_row')
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(this.label.length > 0 ? this.label + PriceTerms.comma + this.value : this.value)
  }
}

// ---------------------------------------------------------------- 提示条

/** R6 / R14 提示条：muted 底、info_circle 20 次文字色、14/400 主文字、圆角 12、内边距 12；静态文字，整条读一次。 */
@ComponentV2
export struct RiskNoteStrip {
  @Param text: string = '';
  @Param barId: string = '';

  build() {
    Row({ space: CouliSpacing.space2 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(iconVp(CouliComponentMetrics.iconMedium))
        .fontColor([CouliColors.textSecondary])
        .width(CouliComponentMetrics.iconMedium)
        .height(CouliComponentMetrics.iconMedium)
        .accessibilityLevel('no')
        .id(this.barId + '_icon')
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, CouliFontWeight.regular))
        .layoutWeight(1)
    }
    .id(this.barId)
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.backgroundMuted)
    .accessibilityGroup(true)
    .accessibilityText(this.text)
  }
}

// ---------------------------------------------------------------- 出口行分隔符

/** R8 / F-HM-74 ③：出口行分隔符（footnote、border.subtle、读屏不读）；页面把它和后一个链接放进同一个 Row，折行时不挂在行尾。 */
@ComponentV2
export struct RiskExitSep {
  build() {
    Text('|')
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.borderSubtle))
      .accessibilityLevel('no')
  }
}

// ---------------------------------------------------------------- 申诉卡

/** R12 / R18 / R24 申诉卡：白卡（左右 16、上下 16、圆角 16、阴影）内卡内标题 body 17/600（标题角色）→ 8 → 内容。 */
@ComponentV2
export struct AppealInfoCard {
  @Param title: string = '';
  @Param cardId: string = '';
  @BuilderParam content: () => void = riskPartsEmptyBuilder;

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      this.content()
    }
    .id(this.cardId)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .alignItems(HorizontalAlign.Start)
  }
}

/** 申诉卡内的一行「标签 值」（14 次文字 + 14 主文字，间距 8；值可折行、顶对齐）；chipTone 非 null 时值是 DS 胶囊。整行读一次。 */
@ComponentV2
export struct InlineRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param valueId: string = '';
  @Param chipTone: CouliChipTone | null = null;
  @Param chipIcon: string = '';
  @Param chipId: string = '';

  build() {
    Row({ space: CouliSpacing.space2 }) {
      Text(this.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .flexShrink(0)
      if (this.chipTone !== null) {
        Row() {
          CouliChip({ label: this.value, tone: this.chipTone as CouliChipTone, icon: this.chipIcon })
        }
        .id(this.chipId)
        .flexShrink(1)
      } else {
        Text(this.value)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
          .layoutWeight(1)
          .id(this.valueId)
      }
    }
    .width('100%')
    .alignItems(this.chipTone !== null ? VerticalAlign.Center : VerticalAlign.Top)
    .accessibilityGroup(true)
    .accessibilityText(this.label + PriceTerms.comma + this.value)
  }
}

// ---------------------------------------------------------------- 时间线

/**
 * R17 / R23 时间线：图标列 20（done = 圆勾 success、current = 时钟主文字、warning = 三角 warning、pending = 10 空心圆 border.control 1.75），
 * 非末步下接 2px border.subtle 连线（撑满、最小 16）；列间 12；标题 body 17（current / warning 600，pending 次文字）+ 说明 14 次文字。
 * 图标与连线读屏不读，每步一个读屏单元「标题，说明」。
 */
@ComponentV2
export struct AppealTimeline {
  @Param timelineId: string = '';
  @Param titles: string[] = [];
  @Param descs: string[] = [];
  @Param states: string[] = [];
  /** 各步文字列的实测高（vp）：连线高 = 文字列高 − 图标 − 上下间距，下限 16（不用 layoutWeight 撑，避免在可滚动容器里被撑到整屏）。 */
  @Local textHeights: number[] = [];

  private stateAt(i: number): string {
    return i < this.states.length ? this.states[i] : 'pending';
  }

  private descAt(i: number): string {
    return i < this.descs.length ? this.descs[i] : '';
  }

  private stepGlyph(state: string): Resource {
    if (state === 'done') {
      return $r('sys.symbol.checkmark_circle');
    }
    if (state === 'warning') {
      return $r('sys.symbol.exclamationmark_triangle');
    }
    return $r('sys.symbol.clock');
  }

  private stepColor(state: string): ResourceColor {
    if (state === 'done') {
      return CouliColors.statusSuccessText;
    }
    if (state === 'warning') {
      return CouliColors.statusWarningText;
    }
    return CouliColors.textPrimary;
  }

  private lineHeight(i: number): number {
    const h: number = i < this.textHeights.length ? this.textHeights[i] : 0;
    return Math.max(STEP_LINE_MIN, h - STEP_ICON - 2 * CouliSpacing.space1);
  }

  private measured(i: number, height: number): void {
    if (!(height > 0) || (i < this.textHeights.length && Math.abs(this.textHeights[i] - height) < 0.5)) {
      return;
    }
    const next: number[] = this.textHeights.slice();
    while (next.length <= i) {
      next.push(0);
    }
    next[i] = height;
    this.textHeights = next;
  }

  private spoken(i: number): string {
    const desc: string = this.descAt(i);
    return desc.length > 0 ? this.titles[i] + PriceTerms.comma + desc : this.titles[i];
  }

  @Builder
  stepIcon(i: number) {
    if (this.stateAt(i) === 'pending') {
      Row() {
        Circle({ width: STEP_RING, height: STEP_RING })
          .fill(Color.Transparent)
          .stroke(CouliColors.borderControl)
          .strokeWidth(STEP_RING_STROKE)
          .id(this.timelineId + '_' + i + '_icon')
      }
      .width(STEP_ICON)
      .height(STEP_ICON)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .accessibilityLevel('no')
    } else {
      SymbolGlyph(this.stepGlyph(this.stateAt(i)))
        .fontSize(iconVp(STEP_ICON))
        .fontColor([this.stepColor(this.stateAt(i))])
        .width(STEP_ICON)
        .height(STEP_ICON)
        .accessibilityLevel('no')
        .id(this.timelineId + '_' + i + '_icon')
    }
  }

  build() {
    Column() {
      ForEach(this.titles, (title: string, i: number) => {
        Row({ space: CouliSpacing.space3 }) {
          Column({ space: CouliSpacing.space1 }) {
            this.stepIcon(i)
            if (i < this.titles.length - 1) {
              Column()
                .id(this.timelineId + '_' + i + '_line')
                .width(STEP_LINE_W)
                .height(this.lineHeight(i))
                .backgroundColor(CouliColors.borderSubtle)
                .accessibilityLevel('no')
            }
          }
          .width(STEP_ICON)
          .alignItems(HorizontalAlign.Center)
          Column({ space: 2 }) {
            Text(title)
              .attributeModifier(new CouliTextModifier(CouliTypography.body,
                this.stateAt(i) === 'pending' ? CouliColors.textSecondary : CouliColors.textPrimary,
                this.stateAt(i) === 'current' || this.stateAt(i) === 'warning' ? CouliFontWeight.semibold :
                CouliFontWeight.regular))
            if (this.descAt(i).length > 0) {
              Text(this.descAt(i))
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .padding({ bottom: i < this.titles.length - 1 ? CouliSpacing.space4 : 0 })
          .onAreaChange((_old: Area, area: Area) => {
            this.measured(i, Number(area.height));
          })
        }
        .id(this.timelineId + '_' + i)
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .accessibilityGroup(true)
        .accessibilityText(this.spoken(i))
      }, (title: string, i: number) => this.timelineId + '_' + i + '_' + title + '_' + this.stateAt(i) + '_' + this.descAt(i))
    }
    .id(this.timelineId)
    .width('100%')
    .padding({ top: CouliSpacing.space3, bottom: CouliSpacing.space3 })
  }
}

// ---------------------------------------------------------------- 接下来可以

/** R25「接下来可以」：白卡内卡内标题 body 17/600 → 圆点条目（圆点 4 次文字色、条目 14 主文字、纵向 8）。 */
@ComponentV2
export struct BulletCard {
  @Param title: string = '';
  @Param cardId: string = '';
  @Param lines: string[] = [];

  build() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.title)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
      ForEach(this.lines, (line: string) => {
        Row({ space: CouliSpacing.space2 }) {
          Column()
            .width(BULLET_DOT)
            .height(BULLET_DOT)
            .borderRadius(BULLET_DOT / 2)
            .backgroundColor(CouliColors.textSecondary)
            .margin({ top: 8 })
            .accessibilityLevel('no')
          Text(line)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (line: string, i: number) => this.cardId + '_' + i + '_' + line)
    }
    .id(this.cardId)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .alignItems(HorizontalAlign.Start)
  }
}
