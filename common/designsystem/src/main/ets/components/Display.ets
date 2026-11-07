import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliFocus, CouliInteraction, CouliRadius, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { DesignTokens } from 'generated';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';

/**
 * DS-02 列表与展示、反馈（清单 §3.5 / §3.6）：系统 List / ListItem、Divider、Badge、LoadingProgress、Tabs 套令牌；
 * 系统没有的（标签、头像、图片占位、时间线、折叠行、提示条）由组件库自绘，三端一致。
 */

function token(key: string): number {
  return DesignTokens.component.get(key) ?? 0;
}

export enum ListRowAccessory {
  ARROW = 'arrow',
  VALUE = 'value',
  SWITCH = 'switch'
}

/**
 * 列表行（清单 §3.5）：系统 ListItem（按压反馈随系统），外观按白卡片里的行：标题 17、副标题 14、右侧箭头（SymbolGlyph）/ 值 / 开关；
 * 最小高 48。必须放在 List 里（CouliListCard）。禁用置灰不可点。
 */
@ComponentV2
export struct ListRow {
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param value: string = '';
  @Param accessory: ListRowAccessory = ListRowAccessory.ARROW;
  @Param switchOn: boolean = false;
  @Param disabled: boolean = false;
  @Param pressedPreview: boolean = false;
  @Param rowId: string = '';
  @Event onTap: () => void = () => {
  };
  @Event onSwitch: (on: boolean) => void = (_o: boolean) => {
  };

  build() {
    Row({ space: CouliSpacing.space3 }) {
      Column({ space: 2 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body,
            this.disabled ? CouliColors.textSecondary : CouliColors.textPrimary))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.accessory === ListRowAccessory.VALUE && this.value.length > 0) {
        Text(this.value)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
      if (this.accessory === ListRowAccessory.SWITCH) {
        Toggle({ type: ToggleType.Switch, isOn: this.switchOn })
          .selectedColor(CouliColors.controlChecked)
          .switchPointColor(CouliColors.textInverse)
          .enabled(!this.disabled)
          .accessibilityText(this.title)
          .onChange((on: boolean) => {
            if (!this.disabled && on !== this.switchOn) {
              this.onSwitch(on);
            }
          })
      } else {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(token('icon.medium'))
          .fontColor([CouliColors.textSecondary])
          .accessibilityLevel('no')
      }
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .backgroundColor(this.pressedPreview ? CouliColors.backgroundMuted : CouliColors.backgroundSurface)
    .enabled(!this.disabled)
    .opacity(this.disabled ? 0.6 : 1)
    .accessibilityGroup(this.accessory !== ListRowAccessory.SWITCH)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .id(this.rowId.length > 0 ? this.rowId : undefined)
    .onClick(() => {
      if (!this.disabled && this.accessory !== ListRowAccessory.SWITCH) {
        this.onTap();
      }
    })
  }
}

/** 分隔线（清单 §3.5）：系统 Divider，颜色 border.subtle；inset 左缩 16；带文字时两段线夹文字。 */
@ComponentV2
export struct CouliDivider {
  @Param inset: boolean = false;
  @Param text: string = '';

  build() {
    if (this.text.length > 0) {
      Row({ space: CouliSpacing.space3 }) {
        Divider().color(CouliColors.borderSubtle).strokeWidth(CouliComponentMetrics.controlBorderWidth).layoutWeight(1)
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        Divider().color(CouliColors.borderSubtle).strokeWidth(CouliComponentMetrics.controlBorderWidth).layoutWeight(1)
      }
      .width('100%')
    } else {
      Divider()
        .color(CouliColors.borderSubtle)
        .strokeWidth(CouliComponentMetrics.controlBorderWidth)
        .margin({ left: this.inset ? CouliSpacing.space4 : 0 })
    }
  }
}

export enum CouliTagTone {
  PENDING = 'pending',
  SUCCESS = 'success',
  WARNING = 'warning',
  ERROR = 'error',
  /** 优惠：白底描边。 */
  BENEFIT = 'benefit',
  /** 强调：品牌浅底 + 深橙字。 */
  EMPHASIS = 'emphasis'
}

/**
 * 标签（清单 §3.5；鸿蒙原名 CouliChip，与筛选胶囊分开）：状态标签总带图标 + 文字（钟表 / 对勾 / 感叹，14，T11）；最小高 22（T11）。
 */
@ComponentV2
export struct CouliTag {
  @Param label: string = '';
  @Param tone: CouliTagTone = CouliTagTone.PENDING;

  private fg(): ResourceColor {
    switch (this.tone) {
      case CouliTagTone.SUCCESS:
        return CouliColors.statusSuccessText;
      case CouliTagTone.WARNING:
        return CouliColors.statusWarningText;
      case CouliTagTone.ERROR:
        return CouliColors.statusErrorText;
      case CouliTagTone.BENEFIT:
        return CouliColors.textPrimary;
      case CouliTagTone.EMPHASIS:
        return CouliColors.textLink;
      default:
        return CouliColors.statusPendingText;
    }
  }

  private bg(): ResourceColor {
    switch (this.tone) {
      case CouliTagTone.SUCCESS:
        return CouliColors.statusSuccessBackground;
      case CouliTagTone.WARNING:
        return CouliColors.statusWarningBackground;
      case CouliTagTone.ERROR:
        return CouliColors.statusErrorBackground;
      case CouliTagTone.BENEFIT:
        return CouliColors.backgroundSurface;
      case CouliTagTone.EMPHASIS:
        return CouliColors.brandSubtle;
      default:
        return CouliColors.statusPendingBackground;
    }
  }

  private icon(): string {
    switch (this.tone) {
      case CouliTagTone.PENDING:
        return 'clock';
      case CouliTagTone.SUCCESS:
        return 'check';
      case CouliTagTone.WARNING:
      case CouliTagTone.ERROR:
        return 'alert';
      default:
        return '';
    }
  }

  build() {
    Row({ space: CouliSpacing.space1 }) {
      if (this.icon().length > 0) {
        CouliIcon({ name: this.icon(), iconSize: token('icon.small'), color: this.fg() })
      }
      Text(this.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, this.fg()))
        .flexShrink(1)
    }
    .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: 1, bottom: 1 })
    .constraintSize({ minHeight: token('tag.min-height') })
    .backgroundColor(this.bg())
    .border(this.tone === CouliTagTone.BENEFIT
      ? { width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle } : { width: 0 })
    .borderRadius(CouliRadius.pill)
    .accessibilityGroup(true)
  }
}

/**
 * 角标（清单 §3.5）：系统 Badge 容器；红点 8、数字高 18（T4 component.count-badge.size），底色 T4 color.badge.background、白字。
 * 读屏写成文字（如「有未读」「3 条未读」），由调用方给。
 */
@ComponentV2
export struct CouliBadge {
  /** 0 表示红点。 */
  @Param count: number = 0;
  @Param accessibilityName: string = '';
  @BuilderParam content: () => void = emptyContent;

  build() {
    if (this.count > 0) {
      Badge({ count: this.count, maxCount: 99, position: BadgePosition.RightTop,
        style: { badgeSize: token('count-badge.size'), badgeColor: CouliColors.badgeBackground,
          color: CouliColors.textInverse, fontSize: CouliTypography.caption.fontSize } }) {
        this.content()
      }
      .accessibilityText(this.accessibilityName)
    } else {
      Badge({ value: '', position: BadgePosition.RightTop,
        style: { badgeSize: 8, badgeColor: CouliColors.badgeBackground } }) {
        this.content()
      }
      .accessibilityText(this.accessibilityName)
    }
  }
}

@Builder
function emptyContent() {
}

/** 头像（清单 §3.5）：圆形 56 / 32；无图时暖灰底 + 人形（凑狸自有矢量）。读屏名称由调用方给。 */
@ComponentV2
export struct Avatar {
  @Param avatarSize: number = 56;
  /** 图片地址或资源；undefined 为占位。 */
  @Param source: ResourceStr | undefined = undefined;
  @Param accessibilityName: string = '';

  build() {
    Stack() {
      if (this.source !== undefined) {
        Image(this.source)
          .width(this.avatarSize)
          .height(this.avatarSize)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.avatarSize / 2)
      } else {
        CouliIcon({ name: 'user', iconSize: this.avatarSize * 0.6, color: CouliColors.textSecondary })
      }
    }
    .width(this.avatarSize)
    .height(this.avatarSize)
    .borderRadius(this.avatarSize / 2)
    .backgroundColor(CouliColors.backgroundPlaceholder)
    .clip(true)
    .accessibilityText(this.accessibilityName)
  }
}

export enum ImagePlaceholderState {
  LOADING = 'loading',
  SUCCESS = 'success',
  ERROR = 'error'
}

/**
 * 图片占位 / 商品图容器（清单 §3.5，GUIDE §6）：占位底 background.placeholder + 1vp border.subtle + 圆角 8；
 * 加载中转圈、失败显示文字（由调用方给，如「图片加载失败」）；成功显示图（详情完整显示 Contain）。
 */
@ComponentV2
export struct ImagePlaceholder {
  @Param imageWidth: Length = 96;
  @Param imageHeight: Length = 96;
  @Param state: ImagePlaceholderState = ImagePlaceholderState.LOADING;
  @Param source: ResourceStr | undefined = undefined;
  @Param errorText: string = '';
  @Param contain: boolean = false;

  build() {
    Stack() {
      if (this.state === ImagePlaceholderState.SUCCESS && this.source !== undefined) {
        Image(this.source)
          .width('100%')
          .height('100%')
          .objectFit(this.contain ? ImageFit.Contain : ImageFit.Cover)
      } else if (this.state === ImagePlaceholderState.ERROR) {
        Column({ space: CouliSpacing.space1 }) {
          CouliIcon({ name: 'image', iconSize: token('icon.medium'), color: CouliColors.textSecondary })
          Text(this.errorText)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
            .textAlign(TextAlign.Center)
        }
      } else if (this.state === ImagePlaceholderState.LOADING) {
        LoadingProgress().width(CouliSpacing.space6).height(CouliSpacing.space6).color(CouliColors.textSecondary)
      }
    }
    .width(this.imageWidth)
    .height(this.imageHeight)
    .backgroundColor(CouliColors.backgroundPlaceholder)
    .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle })
    .borderRadius(CouliRadius.small)
    .clip(true)
  }
}

export enum TimelineState {
  COMPLETED = 'completed',
  CURRENT = 'current',
  FUTURE = 'future'
}

export class TimelineStep {
  readonly title: string;
  readonly detail: string;
  readonly state: TimelineState;

  constructor(title: string, detail: string, state: TimelineState) {
    this.title = title;
    this.detail = detail;
    this.state = state;
  }
}

/** 进度时间线（清单 §3.5，自绘）：已完成绿对勾、当前狸橙实心、未到空心；状态另有文字，不只靠颜色。 */
@ComponentV2
export struct Timeline {
  @Param steps: TimelineStep[] = [];

  private dotColor(state: TimelineState): ResourceColor {
    if (state === TimelineState.COMPLETED) {
      return CouliColors.statusSuccessText;
    }
    return state === TimelineState.CURRENT ? CouliColors.brandPrimary : CouliColors.borderControl;
  }

  build() {
    Column() {
      ForEach(this.steps, (step: TimelineStep, index: number) => {
        Row({ space: CouliSpacing.space3 }) {
          Column() {
            if (step.state === TimelineState.COMPLETED) {
              CouliIcon({ name: 'check', iconSize: token('icon.inline'), color: this.dotColor(step.state) })
            } else {
              Circle()
                .width(10)
                .height(10)
                .fill(step.state === TimelineState.CURRENT ? this.dotColor(step.state) : Color.Transparent)
                .stroke(this.dotColor(step.state))
                .strokeWidth(1.5)
                .margin(3)
            }
            if (index < this.steps.length - 1) {
              Column()
                .width(CouliComponentMetrics.controlBorderWidth)
                .layoutWeight(1)
                .constraintSize({ minHeight: CouliSpacing.space4 })
                .backgroundColor(CouliColors.borderSubtle)
            }
          }
          .width(token('icon.inline'))
          .height('100%')
          Column({ space: 2 }) {
            Text(step.title)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
                step.state === TimelineState.FUTURE ? CouliColors.textSecondary : CouliColors.textPrimary,
                step.state === TimelineState.CURRENT ? CouliFontWeight.semibold : CouliFontWeight.regular))
            Text(step.detail)
              .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          }
          .alignItems(HorizontalAlign.Start)
          .padding({ bottom: CouliSpacing.space3 })
          .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .accessibilityGroup(true)
      }, (step: TimelineStep, index: number) => index + step.title)
    }
    .alignItems(HorizontalAlign.Start)
  }
}

/** 折叠行（清单 §3.5，自绘 + 读屏展开状态）：标题 + 向下 / 向上箭头；展开时下方显示内容。 */
@ComponentV2
export struct DisclosureRow {
  @Param title: string = '';
  @Param expanded: boolean = false;
  /** 读屏状态文字（如「已展开」「已折叠」），由调用方给。 */
  @Param stateText: string = '';
  @BuilderParam content: () => void = emptyContent;
  @Event onToggle: (expanded: boolean) => void = (_e: boolean) => {
  };

  build() {
    Column() {
      Row({ space: CouliSpacing.space2 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.medium))
          .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(token('icon.medium'))
          .fontColor([CouliColors.textSecondary])
          .rotate({ angle: this.expanded ? 180 : 0 })
          .accessibilityLevel('no')
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .accessibilityGroup(true)
      .accessibilityText(this.title)
      .accessibilityDescription(this.stateText)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => {
        this.onToggle(!this.expanded);
      })
      if (this.expanded) {
        this.content()
      }
    }
    .width('100%')
  }
}

export enum NoticeTone {
  INFO = 'info',
  WARNING = 'warning',
  ERROR = 'error',
  SUCCESS = 'success'
}

/** 提示条（清单 §3.6；三端统一名 NoticeBar）：状态浅底 + 图标 20（T11）+ 文字；右侧可带文字按钮（命中 48）。 */
@ComponentV2
export struct NoticeBar {
  @Param text: string = '';
  @Param tone: NoticeTone = NoticeTone.INFO;
  @Param actionText: string = '';
  @Event onAction: () => void = () => {
  };

  private fg(): ResourceColor {
    switch (this.tone) {
      case NoticeTone.WARNING:
        return CouliColors.statusWarningText;
      case NoticeTone.ERROR:
        return CouliColors.statusErrorText;
      case NoticeTone.SUCCESS:
        return CouliColors.statusSuccessText;
      default:
        return CouliColors.statusPendingText;
    }
  }

  private bg(): ResourceColor {
    switch (this.tone) {
      case NoticeTone.WARNING:
        return CouliColors.statusWarningBackground;
      case NoticeTone.ERROR:
        return CouliColors.statusErrorBackground;
      case NoticeTone.SUCCESS:
        return CouliColors.statusSuccessBackground;
      default:
        return CouliColors.statusPendingBackground;
    }
  }

  private icon(): string {
    switch (this.tone) {
      case NoticeTone.WARNING:
      case NoticeTone.ERROR:
        return 'alert';
      case NoticeTone.SUCCESS:
        return 'check';
      default:
        return 'info';
    }
  }

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: this.icon(), iconSize: token('icon.medium'), color: this.fg() })
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .layoutWeight(1)
      if (this.actionText.length > 0) {
        Button(this.actionText, { type: ButtonType.Normal, stateEffect: true })
          .fontSize(CouliTypography.footnote.fontSize)
          .fontColor(CouliColors.textLink)
          .fontWeight(CouliFontWeight.semibold)
          .backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
          .focusBox(CouliFocus.box)
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space3, right: CouliSpacing.space1 })
    .backgroundColor(this.bg())
    .borderRadius(CouliRadius.button)
  }
}

/** 加载指示（清单 §3.6）：系统 LoadingProgress；小 20（按钮内）、中 40（居中）。 */
@ComponentV2
export struct CouliLoading {
  @Param medium: boolean = false;
  @Param accessibilityName: string = '';

  build() {
    LoadingProgress()
      .width(this.medium ? CouliSpacing.space10 : CouliSpacing.space5)
      .height(this.medium ? CouliSpacing.space10 : CouliSpacing.space5)
      .color(CouliColors.brandPrimary)
      .accessibilityText(this.accessibilityName)
  }
}

/**
 * 顶部标签页（清单 §3.4）：系统 Tabs + TabContent().tabBar(SubTabBarStyle)；选中墨棕 600 + 狸橙下划线 2（T10），未选灰棕。
 * 固定：等分；可横滑：BarMode.Scrollable。内容由调用方给（只要标签行时传空内容）。
 */
@ComponentV2
export struct TopTabs {
  @Param labels: string[] = [];
  @Param selectedIndex: number = 0;
  @Param scrollable: boolean = false;
  @Param contentHeight: Length = 0;
  @Event onSelect: (index: number) => void = (_i: number) => {
  };

  build() {
    Tabs({ index: this.selectedIndex }) {
      ForEach(this.labels, (label: string) => {
        TabContent() {
          Column()
        }
        .tabBar(SubTabBarStyle.of(label)
          .indicator({ color: CouliColors.brandPrimary, height: token('tab-indicator.height'), borderRadius: 1 })
          .labelStyle({ unselectedColor: CouliColors.textSecondary, selectedColor: CouliColors.textPrimary,
            font: { size: CouliTypography.footnote.fontSize, weight: FontWeight.Medium } })
          .selectedMode(SelectedMode.INDICATOR))
      }, (label: string) => label)
    }
    .barMode(this.scrollable ? BarMode.Scrollable : BarMode.Fixed)
    .barHeight(CouliInteraction.minTouchTarget)
    .barBackgroundColor(CouliColors.backgroundSurface)
    .height(CouliInteraction.minTouchTarget + (typeof this.contentHeight === 'number' ? this.contentHeight as number : 0))
    .width('100%')
    .scrollable(false)
    .onChange((index: number) => {
      if (index !== this.selectedIndex) {
        this.onSelect(index);
      }
    })
  }
}
