import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction, CouliRadius, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';

export enum CouliButtonVariant {
  /** 主按钮：狸橙底白字（一个区域一个）。 */
  PRIMARY = 'primary',
  /** 次按钮：白底 + 控件边界描边 + 墨棕字。 */
  SECONDARY = 'secondary',
  /** 文字按钮：深橙字、无底。 */
  TEXT = 'text',
  /** 狸橙实底卡内的白底按钮（GUIDE §7.1：白底 + 深橙字 600）。 */
  ON_BRAND = 'on_brand'
}

export enum CouliButtonSize {
  /** 主按钮：17/600，内边距 12/20（component.button），最小高 48。 */
  REGULAR = 'regular',
  /** 列表卡底行按钮：14/600，内边距 8/16，视觉最小高 44；命中区上下各扩 2 到 48（GUIDE §6 / §7.2.1）。 */
  COMPACT = 'compact'
}

/** 视觉 44 与命中 48 之间的差（命中区按 interaction.target.harmony 扩展，视觉不变）。 */
const COMPACT_VISUAL_HEIGHT: number = 44;

/**
 * 通用按钮：主 / 次 / 文字 / 实底卡内白底；loading（转圈 + 文案，禁用）、禁用（底 #E9E2D9 字 #655E57，读屏读「不可用」）。
 * 文字不截断：放不下时换行、按钮增高（adaptation-a11y-spec §2）。
 */
@ComponentV2
export struct CouliButton {
  @Param text: string = '';
  @Param variant: CouliButtonVariant = CouliButtonVariant.PRIMARY;
  @Param buttonSize: CouliButtonSize = CouliButtonSize.REGULAR;
  @Param loading: boolean = false;
  @Param disabled: boolean = false;
  @Param fullWidth: boolean = false;
  /** 读屏名称；空串时用可见文字。可见文字必须在名称开头（WCAG 2.5.3）。 */
  @Param accessibilityName: string = '';
  /** 组件 id（弹层关闭后把焦点还给它：CouliFocusReturn.to）；空串不设。 */
  @Param buttonId: string = '';
  @Event onTap: () => void = () => {
  };
  /** 按钮实际高度（vp）：紧凑按钮的命中区按它上下各扩 (48 − 44) / 2（R1-01）。 */
  @Local actualHeight: number = 0;

  private inactive(): boolean {
    return this.disabled || this.loading;
  }

  /**
   * 命中区。responseRegion 会替换默认区域，所以高度必须写成「实际高度 + 上下扩展」，不能写 100%：
   * 紧凑按钮视觉高 44（字号放大时更高），命中区 = 视觉区域上下各外扩 2vp，总高 ≥ 48 且覆盖整个视觉区域；
   * 宽度 100%（minWidth 已 ≥ 48）。高度未测得前（首帧）退回整按钮区域。
   */
  private hitRegion(): Rectangle {
    if (this.buttonSize !== CouliButtonSize.COMPACT || this.actualHeight <= 0) {
      return { x: 0, y: 0, width: '100%', height: '100%' };
    }
    const extra: number = Math.max(0, (CouliInteraction.minTouchTarget - this.actualHeight) / 2);
    return { x: 0, y: -extra, width: '100%', height: this.actualHeight + 2 * extra };
  }

  private bgColor(): ResourceColor {
    if (this.variant === CouliButtonVariant.TEXT) {
      return Color.Transparent;
    }
    if (this.disabled) {
      return CouliColors.buttonPrimaryDisabledBackground;
    }
    if (this.variant === CouliButtonVariant.PRIMARY) {
      return CouliColors.buttonPrimaryDefaultBackground;
    }
    return CouliColors.backgroundSurface;
  }

  private foreground(): ResourceColor {
    if (this.disabled) {
      return CouliColors.buttonPrimaryDisabledText;
    }
    switch (this.variant) {
      case CouliButtonVariant.PRIMARY:
        return CouliColors.buttonPrimaryDefaultText;
      case CouliButtonVariant.SECONDARY:
        return CouliColors.textPrimary;
      default:
        return CouliColors.brandEmphasis;
    }
  }

  private weight(): number {
    return this.variant === CouliButtonVariant.SECONDARY ? CouliFontWeight.medium
      : CouliFontWeight.semibold;
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: !this.inactive() }) {
      Row({ space: CouliComponentMetrics.buttonGap }) {
        if (this.loading) {
          LoadingProgress()
            .width(CouliSpacing.space5)
            .height(CouliSpacing.space5)
            .color(this.foreground())
            .accessibilityLevel('no')
        }
        Text(this.text)
          .attributeModifier(new CouliTextModifier(
            this.buttonSize === CouliButtonSize.COMPACT ? CouliTypography.footnote : CouliTypography.body,
            this.foreground(), this.weight(), true))
          .textAlign(TextAlign.Center)
          .flexShrink(1)
      }
      .justifyContent(FlexAlign.Center)
    }
    .width(this.fullWidth ? '100%' : undefined)
    .constraintSize({
      minHeight: this.buttonSize === CouliButtonSize.COMPACT ? COMPACT_VISUAL_HEIGHT : CouliComponentMetrics.buttonMinHeight,
      minWidth: CouliInteraction.minTouchTarget
    })
    .padding(this.buttonSize === CouliButtonSize.COMPACT
      ? { top: CouliSpacing.space2, bottom: CouliSpacing.space2, left: CouliSpacing.space4, right: CouliSpacing.space4 }
      : {
        top: CouliComponentMetrics.buttonPaddingBlock, bottom: CouliComponentMetrics.buttonPaddingBlock,
        left: CouliComponentMetrics.buttonPaddingInline, right: CouliComponentMetrics.buttonPaddingInline
      })
    .backgroundColor(this.bgColor())
    .border(this.variant === CouliButtonVariant.SECONDARY
      ? { width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderControl }
      : { width: 0 })
    // 圆角写在 border 之后：border() 会把圆角重置为 0。
    .borderRadius(CouliRadius.button)
    .responseRegion(this.hitRegion())
    .onAreaChange((_old: Area, now: Area) => {
      this.actualHeight = now.height as number;
    })
    .enabled(!this.inactive())
    .id(this.buttonId.length > 0 ? this.buttonId : undefined)
    .accessibilityText(this.accessibilityName.length > 0 ? this.accessibilityName : this.text)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (!this.inactive()) {
        this.onTap();
      }
    })
  }
}

/**
 * 平台来源标签（GUIDE §7.1）：白底 + 1px 装饰描边、灰棕字、胶囊、最小高 20；字号放大时增高不截断。
 * 平台 logo 未到（design/icons/platform/），先只放文字。
 */
@ComponentV2
export struct PlatformBadge {
  @Param label: string = '';

  build() {
    Text(this.label)
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.sourceText))
      .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
      .constraintSize({ minHeight: CouliSpacing.space5 })
      .backgroundColor(CouliColors.sourceBackground)
      .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.sourceBorder })
      .borderRadius(CouliRadius.pill)
      .maxLines(1)
  }
}

export enum CouliChipTone {
  /** 白底描边（预售、有券、规格以下单页为准等优惠标签）。 */
  OUTLINE = 'outline',
  /** 中性浅底（规格待确认、预估 / 等待）。 */
  MUTED = 'muted',
  /** 已结算 / 已完成：松叶绿 + 对勾。 */
  SUCCESS = 'success',
  WARNING = 'warning',
  ERROR = 'error',
  /** 已选筛选：品牌浅底 + 深橙字。 */
  SELECTED = 'selected'
}

/** 胶囊标签（GUIDE §3「标签」；放大时由固定高改为最小高，adaptation-a11y-spec §2）。状态色总配图标 + 文字。 */
@ComponentV2
export struct CouliChip {
  @Param label: string = '';
  @Param tone: CouliChipTone = CouliChipTone.OUTLINE;
  /** 前置 14 图标名；空串不放。 */
  @Param icon: string = '';

  private fg(): ResourceColor {
    switch (this.tone) {
      case CouliChipTone.SUCCESS:
        return CouliColors.statusSuccessText;
      case CouliChipTone.WARNING:
        return CouliColors.statusWarningText;
      case CouliChipTone.ERROR:
        return CouliColors.statusErrorText;
      case CouliChipTone.SELECTED:
        return CouliColors.textLink;
      case CouliChipTone.OUTLINE:
        return CouliColors.textPrimary;
      default:
        return CouliColors.statusPendingText;
    }
  }

  private bg(): ResourceColor {
    switch (this.tone) {
      case CouliChipTone.SUCCESS:
        return CouliColors.statusSuccessBackground;
      case CouliChipTone.WARNING:
        return CouliColors.statusWarningBackground;
      case CouliChipTone.ERROR:
        return CouliColors.statusErrorBackground;
      case CouliChipTone.SELECTED:
        return CouliColors.brandSubtle;
      case CouliChipTone.OUTLINE:
        return CouliColors.backgroundSurface;
      default:
        return CouliColors.statusPendingBackground;
    }
  }

  build() {
    Row({ space: CouliSpacing.space1 }) {
      if (this.icon.length > 0) {
        CouliIcon({ name: this.icon, iconSize: CouliTypography.caption.size + 2, color: this.fg() })
      }
      Text(this.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, this.fg()))
        .flexShrink(1)
    }
    .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: 1, bottom: 1 })
    .constraintSize({ minHeight: CouliSpacing.space5 + 2 })
    .backgroundColor(this.bg())
    .border(this.tone === CouliChipTone.OUTLINE
      ? { width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle } : { width: 0 })
    .borderRadius(CouliRadius.pill)
    .accessibilityGroup(true)
  }
}

/** AI 匹配标签（如「规格待确认」）：文字由调用方从字典给（agent.match.*）；中性浅底 + 信息图标。 */
@ComponentV2
export struct MatchBadge {
  @Param text: string = '';

  build() {
    CouliChip({ label: this.text, tone: CouliChipTone.MUTED, icon: 'info' })
  }
}

/** AI 生成内容标识（BR-TEXT-16）：文字由调用方从字典给（ai_label）；白底描边。 */
@ComponentV2
export struct AiLabel {
  @Param text: string = '';

  build() {
    CouliChip({ label: this.text, tone: CouliChipTone.OUTLINE, icon: 'chat' })
  }
}
