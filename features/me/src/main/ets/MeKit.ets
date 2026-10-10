import { AmountMaskStore, MeDraftTexts, MeMessage } from 'core';
import {
  CouliColors, CouliFocus, CouliFontWeight, CouliIcon, CouliInteraction, CouliLayout, CouliRadius, CouliShadow,
  CouliSpacing, CouliTextModifier, CouliTypography, NavBar, PriceTerms
} from 'designsystem';

/**
 * 「我的」类页面的文案来源（entry 给：契约字典 → Core MeDraftTexts 草稿表 → 已有草稿表，TODO(N-33)）。本模块不出现中文（HM-LINT-1）。
 */
export interface MeTexts {
  text(key: string): string;

  format(key: string, vars: Map<string, string>): string;
}

/** 缺省文案来源：Core 的集中草稿表（契约字典优先）。 */
export class DraftMeTexts implements MeTexts {
  text(key: string): string {
    return MeDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    return MeDraftTexts.format(key, vars);
  }
}

export function fmt1(texts: MeTexts, key: string, name: string, value: string): string {
  const vars: Map<string, string> = new Map<string, string>();
  vars.set(name, value);
  return texts.format(key, vars);
}

export function messageText(m: MeMessage | null): string {
  return m === null ? '' : m.text;
}

/** 开关的读屏名：「{名称}，开关，已打开 / 已关闭」（A11yFocusStyles）。 */
export function switchSpoken(texts: MeTexts, label: string, on: boolean): string {
  return label + PriceTerms.comma + texts.text('me.switch.role') + PriceTerms.comma
    + texts.text(on ? 'me.switch.on' : 'me.switch.off');
}

/**
 * 按钮构建时捕获的不可变数据（APP-07 第 18、26 条，APP-09 第 4、25 条）：渲染时的表单身份（会话归属）、版本与对应的值（邀请码、路由、开关目标）。
 * 经 ForEach 的条目参数传进 @Builder（按值），回调只读这里的字段。
 */
export class Bound {
  readonly identity: string;
  readonly version: number;
  readonly value: string;
  readonly flag: boolean;

  constructor(identity: string, version: number, value: string = '', flag: boolean = false) {
    this.identity = identity;
    this.version = version;
    this.value = value;
    this.flag = flag;
  }

  get id(): string {
    return this.identity + '|' + this.version + '|' + this.value + '|' + this.flag;
  }
}

/** 金额隐藏开关（本机偏好，订单页、钱包页、「我的」页共用 Core 的 AmountMaskStore；G06）。 */
@ObservedV2
export class MeMaskUi {
  @Trace masked: boolean = AmountMaskStore.shared.hidden;
  private readonly unsubscribe: () => void;

  constructor() {
    this.unsubscribe = AmountMaskStore.shared.subscribe((hidden: boolean): void => {
      if (this.masked !== hidden) {
        this.masked = hidden;
      }
    });
  }

  toggle(): void {
    AmountMaskStore.shared.set(!this.masked);
  }

  dispose(): void {
    this.unsubscribe();
  }
}

@Builder
function meEmptyBuilder() {
}

/**
 * 二级页骨架：NavBar（返回在左，命中区 48）+ 可滚动内容区（大屏限宽居中，03 §10.4）+ 可选底部固定操作区。
 */
@ComponentV2
export struct MePageFrame {
  @Param title: string = '';
  @Param backLabel: string = '';
  @Param showBack: boolean = true;
  @Param scrollId: string = '';
  @BuilderParam content: () => void = meEmptyBuilder;
  @BuilderParam footer: () => void = meEmptyBuilder;
  @Param scroller: Scroller = new Scroller();
  @Event onBack: () => void = () => {
  };

  build() {
    Column() {
      NavBar({
        title: this.title,
        backLabel: this.backLabel,
        showBack: this.showBack,
        onBack: () => this.onBack()
      })
      Scroll(this.scroller) {
        Column({ space: CouliSpacing.space3 }) {
          this.content()
        }
        .width('100%')
        .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
          bottom: CouliSpacing.space4 })
        .alignItems(HorizontalAlign.Start)
      }
      .id(this.scrollId)
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      Column() {
        this.footer()
      }
      .width('100%')
      .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

/** 白卡片（圆角 16、阴影）。 */
@ComponentV2
export struct MeCard {
  @Param cardId: string = '';
  @Param vertical: number = CouliSpacing.space1;
  @BuilderParam content: () => void = meEmptyBuilder;

  build() {
    Column() {
      this.content()
    }
    .id(this.cardId)
    .width('100%')
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: this.vertical, bottom: this.vertical })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .alignItems(HorizontalAlign.Start)
  }
}

/** 分组标题（12 号、次要色）。 */
@ComponentV2
export struct MeGroupTitle {
  @Param text: string = '';

  build() {
    Text(this.text)
      .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
      .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
      .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
  }
}

/**
 * 列表行（adaptation-a11y-spec §2：min-height 44 + 上下内边距，命中区 48）：左标题、右值 + 箭头。clickable=false 时不显示箭头、不可点
 * （不画成置灰按钮）。可变长文案不固定宽度、可换行。
 */
@ComponentV2
export struct MeRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param rowId: string = '';
  @Param clickable: boolean = true;
  @Param divider: boolean = true;
  @Param danger: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Column() {
      Flex({ justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center, wrap: FlexWrap.Wrap }) {
        Text(this.label)
          .attributeModifier(new CouliTextModifier(CouliTypography.body,
            this.danger ? CouliColors.statusErrorText : CouliColors.textPrimary))
          .margin({ right: CouliSpacing.space3 })
          .flexShrink(1)
        Row({ space: CouliSpacing.space1 }) {
          if (this.value.length > 0) {
            Text(this.value)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
              .textAlign(TextAlign.End)
              .flexShrink(1)
          }
          if (this.clickable) {
            CouliIcon({ name: 'chevron', iconSize: 20, color: CouliColors.textSecondary })
              .accessibilityLevel('no')
          }
        }
        .flexShrink(1)
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .padding({ top: CouliSpacing.space1, bottom: CouliSpacing.space1 })
      if (this.divider) {
        Divider().color(CouliColors.borderSubtle).strokeWidth(1)
      }
    }
    .id(this.rowId)
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(this.value.length > 0 ? this.label + PriceTerms.comma + this.value : this.label)
    .accessibilityRole(this.clickable ? AccessibilityRoleType.BUTTON : AccessibilityRoleType.ROLE_NONE)
    .focusable(this.clickable)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (this.clickable) {
        this.onTap();
      }
    })
  }
}

/**
 * 开关行（标题 + 说明 + Toggle）：读屏读「{名称}，开关，已打开 / 已关闭」；切换回调交出目标值（页面在构建时捕获身份）。
 */
@ComponentV2
export struct MeSwitchRow {
  @Param label: string = '';
  @Param desc: string = '';
  @Param on: boolean = false;
  @Param disabled: boolean = false;
  @Param rowId: string = '';
  @Param spoken: string = '';
  @Event onToggle: (target: boolean) => void = (_t: boolean) => {
  };

  build() {
    Row({ space: CouliSpacing.space3 }) {
      Column({ space: CouliSpacing.space1 }) {
        Text(this.label)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        if (this.desc.length > 0) {
          Text(this.desc)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 开关本体（52×32 胶囊、28 圆点；设计稿 PrivacyCenter / NotifySettingsOn）：只是视觉，读屏与点击在整行上。
      Row() {
        Column()
          .width(28)
          .height(28)
          .borderRadius(CouliRadius.pill)
          .backgroundColor(CouliColors.backgroundSurface)
          .shadow(CouliShadow.card)
      }
      .width(52)
      .height(32)
      .padding(2)
      .borderRadius(CouliRadius.pill)
      .justifyContent(this.on ? FlexAlign.End : FlexAlign.Start)
      .backgroundColor(this.on ? CouliColors.brandPrimary : CouliColors.borderControl)
      .opacity(this.disabled ? 0.5 : 1)
      .accessibilityLevel('no')
      .id(this.rowId + '_knob_' + (this.on ? 'on' : 'off'))
    }
    .id(this.rowId)
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ top: CouliSpacing.space3, bottom: CouliSpacing.space3 })
    .accessibilityGroup(true)
    .accessibilityText(this.spoken)
    .accessibilityRole(AccessibilityRoleType.SWITCH)
    .accessibilityChecked(this.on)
    .focusable(!this.disabled)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (!this.disabled) {
        this.onToggle(!this.on);
      }
    })
  }
}

/** 提示条（info / warning / error）：可点时整条命中区 48。 */
@ComponentV2
export struct MeNoticeBar {
  @Param text: string = '';
  @Param tone: string = 'info';
  @Param barId: string = '';
  @Param tappable: boolean = false;
  @Param focusTarget: boolean = false;
  @Event onTap: () => void = () => {
  };

  private bg(): ResourceColor {
    if (this.tone === 'error') {
      return CouliColors.statusErrorBackground;
    }
    return this.tone === 'warning' ? CouliColors.statusWarningBackground : CouliColors.backgroundMuted;
  }

  private fg(): ResourceColor {
    if (this.tone === 'error') {
      return CouliColors.statusErrorText;
    }
    return this.tone === 'warning' ? CouliColors.statusWarningText : CouliColors.textPrimary;
  }

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: this.tone === 'info' ? 'info' : 'alert', iconSize: 18,
        color: this.tone === 'info' ? CouliColors.textSecondary : this.fg() })
        .accessibilityLevel('no')
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, this.fg()))
        .layoutWeight(1)
      if (this.tappable) {
        CouliIcon({ name: 'chevron', iconSize: 16, color: this.fg() })
          .accessibilityLevel('no')
      }
    }
    .id(this.barId)
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .constraintSize({ minHeight: this.tappable ? CouliInteraction.minTouchTarget : 0 })
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(this.bg())
    .accessibilityGroup(true)
    .accessibilityText(this.text)
    .accessibilityRole(this.tappable ? AccessibilityRoleType.BUTTON : AccessibilityRoleType.ROLE_NONE)
    .focusable(this.tappable || this.focusTarget)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (this.tappable) {
        this.onTap();
      }
    })
  }
}

/** 白卡片里的一行「标签 … 值」（原因、限制期限、处理时间）。值可换行。 */
@ComponentV2
export struct MeKeyValue {
  @Param label: string = '';
  @Param value: string = '';
  @Param divider: boolean = true;
  @Param valueId: string = '';

  build() {
    Column() {
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Text(this.label)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .margin({ right: CouliSpacing.space3 })
        Text(this.value)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.medium))
          .textAlign(TextAlign.End)
          .flexShrink(1)
          .id(this.valueId)
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
      if (this.divider) {
        Divider().color(CouliColors.borderSubtle).strokeWidth(1)
      }
    }
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(this.label + PriceTerms.comma + this.value)
  }
}

/** 文字链接按钮（深橙、命中区 48）。 */
@ComponentV2
export struct MeLink {
  @Param text: string = '';
  @Param linkId: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
    }
    .id(this.linkId)
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
    .justifyContent(FlexAlign.Center)
    .accessibilityGroup(true)
    .accessibilityText(this.text)
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => this.onTap())
  }
}

/**
 * 内容自适应高度的半屏面板（bindSheet FIT_CONTENT 承载；CouliSheetPanel 的纵向 Flex 在 FIT_CONTENT 下会撑满整屏）：把手 → 标题 → 关闭
 * （源码顺序：标题 → 关闭 → 正文 → 按钮，adaptation-a11y-spec §8）→ 中段（超过最大高时滚动）→ 底部操作区。
 */
@ComponentV2
export struct MeSheetPanel {
  @Param title: string = '';
  @Param closeLabel: string = '';
  @Param titleId: string = 'me-sheet-title';
  /** 中段最大高（短视口时中段滚动，标题与按钮固定可见）。 */
  @Param maxBodyHeight: number = 480;
  @BuilderParam content: () => void = meEmptyBuilder;
  @BuilderParam actions: () => void = meEmptyBuilder;
  @Event onClose: () => void = () => {
  };

  build() {
    Column({ space: CouliSpacing.space3 }) {
      Row()
        .width(36)
        .height(CouliSpacing.space1)
        .borderRadius(CouliRadius.pill)
        .backgroundColor(CouliColors.borderSubtle)
        .accessibilityLevel('no')
      Row() {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .layoutWeight(1)
          .id(this.titleId)
          .focusable(true)
          .focusBox(CouliFocus.box)
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 24, color: CouliColors.textPrimary })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, right: -CouliSpacing.space3 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.closeLabel)
        .focusBox(CouliFocus.box)
        .onClick(() => this.onClose())
      }
      .width('100%')
      Scroll() {
        Column() {
          this.content()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: this.maxBodyHeight })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)
      .align(Alignment.TopStart)
      Column() {
        this.actions()
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .padding({ top: CouliSpacing.space3, left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space6 })
    .backgroundColor(CouliColors.backgroundSurface)
  }
}
