import { ComponentUtils, componentUtils } from '@kit.ArkUI';
import { AmountMaskStore, WalletDraftTexts, WalletMessage } from 'core';
import {
  CouliColors, CouliFocus, CouliFontWeight, CouliFormat, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliTypography, PriceTerms
} from 'designsystem';

/**
 * 钱包类页面的文案来源（entry 给：契约字典 → Core WalletDraftTexts 草稿表，TODO(N-32)）。本模块不出现中文（HM-LINT-1）。
 */
export interface WalletTexts {
  text(key: string): string;

  format(key: string, vars: Map<string, string>): string;
}

/** 缺省文案来源：Core 的集中草稿表（契约字典优先）。 */
export class DraftWalletTexts implements WalletTexts {
  text(key: string): string {
    return WalletDraftTexts.text(key);
  }

  format(key: string, vars: Map<string, string>): string {
    return WalletDraftTexts.format(key, vars);
  }
}

/** 一个变量的 format。 */
/**
 * 按钮构建时捕获的不可变数据（共性第 4 条，鸿蒙 R1-04）：版本与对应的金额 / 未决键 / 记录编号 / 路由。经 ForEach 的条目参数传进
 * @Builder（按值），回调只读这里的字段，不在点击时读页面模型的最新版本冒充渲染版本。ForEach 的键带上这些字段，数据一变按钮就重建。
 */
export class RenderBound {
  readonly version: number;
  readonly text: string;
  readonly num: number;
  readonly extra: string;

  constructor(version: number, text: string = '', num: number = 0, extra: string = '') {
    this.version = version;
    this.text = text;
    this.num = num;
    this.extra = extra;
  }

  get id(): string {
    return this.version + '|' + this.text + '|' + this.num + '|' + this.extra;
  }
}

/**
 * 表单字段错误（20001）：按表单顺序取第一个出错的字段（共性第 24 条）。errors 的键是服务端 / 本地给的字段名，顺序不可靠。
 */
export function firstErrorField(order: string[], errors: Map<string, string>): string | undefined {
  for (const f of order) {
    if (errors.has(f)) {
      return f;
    }
  }
  return Array.from(errors.keys())[0];
}

/**
 * 把可滚动区域滚到指定控件（字段错误时滚到首个出错字段，共性第 24 条）。按两者的窗口坐标差加上当前偏移计算，取不到坐标时不滚。
 */
export function scrollToComponent(ui: UIContext, scroller: Scroller, scrollId: string, targetId: string): void {
  try {
    const utils: ComponentUtils = ui.getComponentUtils();
    const scroll: componentUtils.ComponentInfo = utils.getRectangleById(scrollId);
    const target: componentUtils.ComponentInfo = utils.getRectangleById(targetId);
    const delta: number = ui.px2vp(target.windowOffset.y - scroll.windowOffset.y);
    const y: number = scroller.currentOffset().yOffset + delta - 16;
    scroller.scrollTo({ xOffset: 0, yOffset: Math.max(0, y), animation: false });
  } catch (e) {
    // 控件尚未布局：只移焦点与播报。
  }
}

export function fmt1(texts: WalletTexts, key: string, name: string, value: string): string {
  const vars: Map<string, string> = new Map<string, string>();
  vars.set(name, value);
  return texts.format(key, vars);
}

/** 金额（分）→ 显示（BR-TEXT-10，经 CouliFormat）；隐藏时「****」。 */
export function money(fen: number, masked: boolean = false): string {
  return masked ? PriceTerms.amountMask : CouliFormat.money(fen);
}

/** 金额（分）→ 读屏（「12.34 元」）；隐藏时「金额已隐藏」。 */
export function moneySpoken(fen: number, masked: boolean = false): string {
  return masked ? PriceTerms.amountHiddenSpoken : CouliFormat.moneySpoken(fen);
}

/** 脱敏号读屏（「138 星号 5678」：连续的 * 读一次「星号」）。 */
export function maskedSpoken(text: string, star: string): string {
  return text.replace(/\*+/g, ' ' + star + ' ').replace(/\s+/g, ' ').trim();
}

/** 消息正文（Core 已组好，含 trace6）。 */
export function messageText(m: WalletMessage | null): string {
  return m === null ? '' : m.text;
}

/** 金额隐藏开关（本机偏好，订单页与钱包页共用 Core 的 AmountMaskStore；G23、G24）。 */
@ObservedV2
export class WalletMaskUi {
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

/** 提示条（断网缓存 role=status、风控暂停、待抵扣、错误条）。tone：warning / info / error。 */
@ComponentV2
export struct WalletNoticeBar {
  @Param text: string = '';
  @Param tone: string = 'warning';
  @Param barId: string = '';
  @Param tappable: boolean = false;
  @Event onTap: () => void = () => {
  };

  private bg(): ResourceColor {
    if (this.tone === 'error') {
      return CouliColors.statusErrorBackground;
    }
    return this.tone === 'info' ? CouliColors.backgroundMuted : CouliColors.statusWarningBackground;
  }

  private fg(): ResourceColor {
    if (this.tone === 'error') {
      return CouliColors.statusErrorText;
    }
    return this.tone === 'info' ? CouliColors.textSecondary : CouliColors.statusWarningText;
  }

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: this.tone === 'info' ? 'info' : 'alert', iconSize: 18, color: this.fg() })
        .accessibilityLevel('no')
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
          this.tone === 'info' ? CouliColors.textPrimary : this.fg()))
        .flexShrink(1)
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
    .focusable(this.tappable)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (this.tappable) {
        this.onTap();
      }
    })
  }
}

/** 白卡片里的一行「标签 … 值」（详情明细、收款账号信息）。值可换行。 */
@ComponentV2
export struct WalletKeyValueRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param spoken: string = '';
  @Param tabular: boolean = false;

  build() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
      Text(this.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
        .margin({ right: CouliSpacing.space3 })
      Text(this.value)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, undefined,
          this.tabular))
        .textAlign(TextAlign.End)
        .flexShrink(1)
    }
    .width('100%')
    .padding({ top: CouliSpacing.space1, bottom: CouliSpacing.space1 })
    .accessibilityGroup(true)
    .accessibilityText(this.label + PriceTerms.comma + (this.spoken.length > 0 ? this.spoken : this.value))
  }
}

/** 文字链接按钮（深橙、命中区 48）。 */
@ComponentV2
export struct WalletLink {
  @Param text: string = '';
  @Param linkId: string = '';
  @Param chevron: boolean = false;
  @Param disabled: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: CouliSpacing.space1 }) {
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
          this.disabled ? CouliColors.textSecondary : CouliColors.textLink, CouliFontWeight.semibold))
      if (this.chevron) {
        CouliIcon({ name: 'chevron', iconSize: 16, color: this.disabled ? CouliColors.textSecondary
          : CouliColors.textLink })
          .accessibilityLevel('no')
      }
    }
    .id(this.linkId)
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
    .justifyContent(FlexAlign.Center)
    .accessibilityGroup(true)
    .accessibilityText(this.text)
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .enabled(!this.disabled)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => {
      if (!this.disabled) {
        this.onTap();
      }
    })
  }
}

/** 待确认卡（WithdrawPendingConfirm / PayoutAccountPendingConfirm 一族）：警示底 + 标题 + 正文，alert 角色。 */
@ComponentV2
export struct PendingAlertCard {
  @Param title: string = '';
  @Param desc: string = '';

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 18, color: CouliColors.statusWarningText })
        .accessibilityLevel('no')
        .margin({ top: 2 })
      Column({ space: CouliSpacing.space1 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.statusWarningText,
            CouliFontWeight.semibold))
        Text(this.desc)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.statusWarningText))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.statusWarningBackground)
    .id('pending_alert')
    .accessibilityGroup(true)
    .accessibilityText(this.title + PriceTerms.comma + this.desc)
    // ArkUI 没有 alert 角色：用 ROLE_NONE + 出现时 assertive 播报（页面负责）。
    .accessibilityRole(AccessibilityRoleType.ROLE_NONE)
  }
}
