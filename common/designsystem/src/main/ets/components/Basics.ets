import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction, CouliRadius, CouliSpacing, CouliFocus } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';
import { PlatformIconSize, PlatformIconSource } from './PlatformIconSource';

export enum CouliButtonVariant {
  /** 主按钮：狸橙底白字（一个区域一个）。 */
  PRIMARY = 'primary',
  /** 次按钮：白底 + 控件边界描边 + 墨棕字。 */
  SECONDARY = 'secondary',
  /** 文字按钮：深橙字、无底。 */
  TEXT = 'text',
  /** 狸橙实底卡内的白底按钮（GUIDE §7.1：白底 + 深橙字 600；清单变体名 onSolid，颜色读 T1 color.button.inverse.*）。 */
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
  /** 按钮文字 Text 的组件 id（目录页大字号测量用）；空串不设。 */
  @Param textId: string = '';
  /** 目录页静态展示「按下」：系统按压是瞬时变暗，样例直接画按下底色（主按钮 color.button.primary.pressed.*）。 */
  @Param pressedPreview: boolean = false;
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
      return this.pressedPreview && !this.disabled ? CouliColors.brandSubtle : Color.Transparent;
    }
    if (this.disabled) {
      return CouliColors.buttonPrimaryDisabledBackground;
    }
    if (this.variant === CouliButtonVariant.PRIMARY) {
      return this.pressedPreview ? CouliColors.buttonPrimaryPressedBackground : CouliColors.buttonPrimaryDefaultBackground;
    }
    if (this.variant === CouliButtonVariant.ON_BRAND) {
      // T1：狸橙实底卡内的白底按钮，深色下仍白底（color.button.inverse.background）。
      return this.pressedPreview ? CouliColors.brandSubtle : CouliColors.buttonInverseBackground;
    }
    return this.pressedPreview ? CouliColors.backgroundMuted : CouliColors.backgroundSurface;
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
      case CouliButtonVariant.ON_BRAND:
        return CouliColors.buttonInverseText;
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
          .id(this.textId.length > 0 ? this.textId : undefined)
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

/** 平台标识内置图的资源（资源名按变量拼出，原因见 couliColorResource）。 */
function platformMedia(mediaName: string): Resource {
  return $r('app.media.' + mediaName);
}

/**
 * 平台官方图标（F-X-05a）：按平台标识键取内置原图（PlatformIconSource，design/icons/platform/ 原样字节），
 * 两档边长 14（徽标）/ 44（APP-11v 金刚区）是同一张图。图标是装饰，对读屏隐藏；不着色、不滤色，深色模式下原样显示。
 * 没有内置图的编码（暂缺、未知、空）什么都不画、不占位。
 * remoteUrl 为 F-X-05（后台下发替换图）预留：本任务一律显示内置图，远程加载与失败回内置在 F-X-05 做。
 */
@ComponentV2
export struct PlatformIcon {
  /** 平台标识键（taobao / jd / pdd …）。 */
  @Param platform: string = '';
  @Param iconSize: PlatformIconSize = PlatformIconSize.BADGE;
  /** F-X-05 预留：远程图地址，可空；本任务不使用。 */
  @Param remoteUrl: string = '';

  build() {
    if (PlatformIconSource.hasBuiltin(this.platform)) {
      Image(platformMedia(PlatformIconSource.mediaName(this.platform)))
        .width(this.iconSize)
        .height(this.iconSize)
        .objectFit(ImageFit.Contain)
        .accessibilityLevel('no')
    }
  }
}

/**
 * 平台来源标签（GUIDE §7.1）：白底 + 1px 装饰描边、灰棕字、胶囊、最小高 20（T11）；字号放大时增高不截断。
 * F-X-05a：有内置官方图的平台（淘宝 / 京东 / 拼多多）在名字左侧放 14vp 图标（PlatformIcon 同一入口），左内边距 4、图文间距 4、右内边距 8；
 * 暂缺（天猫等）、未知或空编码只显示文字，尺寸与不传 platform 的旧调用完全一样（左右内边距 8），不画占位。
 * 读屏：整个徽标成组只读平台中文名一次（根节点 accessibilityText），文字子节点与图标都对读屏隐藏。
 */
@ComponentV2
export struct PlatformBadge {
  @Param label: string = '';
  /** 平台标识键（taobao / jd / pdd …）；空串、暂缺或未知只显示文字。 */
  @Param platform: string = '';
  /** F-X-05 预留：远程图地址，可空；本任务一律显示内置图。 */
  @Param remoteUrl: string = '';

  build() {
    Row({ space: CouliSpacing.space1 }) {
      if (PlatformIconSource.hasBuiltin(this.platform)) {
        PlatformIcon({ platform: this.platform, iconSize: PlatformIconSize.BADGE, remoteUrl: this.remoteUrl })
      }
      Text(this.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.sourceText))
        .maxLines(1)
        .accessibilityLevel('no')
    }
    .padding({
      left: PlatformIconSource.hasBuiltin(this.platform) ? CouliSpacing.space1 : CouliSpacing.space2,
      right: CouliSpacing.space2
    })
    .constraintSize({ minHeight: CouliComponentMetrics.platformBadgeMinHeight })
    .backgroundColor(CouliColors.sourceBackground)
    .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.sourceBorder })
    .borderRadius(CouliRadius.pill)
    .accessibilityGroup(true)
    .accessibilityText(this.label)
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

/**
 * AI 匹配标签（如「规格待确认」）：文字由调用方从字典给（agent.match.*）；中性浅底（清单 §4：三端统一中性款，绿色只留给已结算）。
 * 普通带信息图标；规格待确认（unconfirmed）带问号图标。
 */
@ComponentV2
export struct MatchBadge {
  @Param text: string = '';
  @Param unconfirmed: boolean = false;

  build() {
    CouliChip({ label: this.text, tone: CouliChipTone.MUTED, icon: this.unconfirmed ? 'help' : 'info' })
  }
}

/** AI 生成内容标识（BR-TEXT-16）：文字由调用方从字典给（ai_label）；清单 §4 按 AgentResult 稿统一为 12 号次要色纯文字。 */
@ComponentV2
export struct AiLabel {
  @Param text: string = '';

  build() {
    Text(this.text)
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
  }
}
