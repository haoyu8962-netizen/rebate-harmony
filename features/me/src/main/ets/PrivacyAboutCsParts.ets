import {
  CouliColors, CouliComponentMetrics, CouliFocus, CouliFontWeight, CouliIcon, CouliInteraction, CouliLayout, CouliRadius,
  CouliShadow, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { CouliLogoSpec, CouliLogoVariant } from 'designsystem/Brand';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

/**
 * 隐私中心 / 关于 / 联系客服半屏的私有视图件（APP-12w-b-harmony，brief-b-harmony H-P01：MeKit / DS 一字不动，本组私有件放这里）。
 * 只收渲染时的值与 @Event 回调；执行逻辑、身份核对、去向与提示全在三个视图里。本文件不出现中文（HM-LINT-1），颜色只取令牌。
 * 新加的功能图标用系统图标集 SymbolGlyph（H-P10 / D10-559）；图标是装饰，读屏不读。私有件图标节点 id = 所在控件 id + '_icon'。
 */

/** 自绘开关（与 MeSwitchRow 同：52×32 胶囊、28 圆点、内边距 2）。 */
const KNOB_TRACK_W: number = 52;
const KNOB_TRACK_H: number = 32;
const KNOB_DOT: number = 28;
const KNOB_INSET: number = 2;
/** 关于页 App 图标（画板 80×80；主图形反白约 56，H-P08）。圆角取令牌 radius.card 16（画板 18 无令牌，compare 记差异）。 */
const APP_ICON_SIZE: number = 80;
const APP_ICON_MARK: number = 56;
/** 客服半屏图标块 56、内图标 32（画板 CsOpenFailed-v2 / CsWechatMissing-v2）。 */
const CS_BADGE_SIZE: number = 56;
const CS_BADGE_ICON: number = 32;
/** 半屏把手 36×4（与 MeSheetPanel 同）。 */
const SHEET_HANDLE_W: number = 36;
/** 中段最小可视高（P28：200% / 短屏时正文至少留这么多可滚动区）。 */
const SHEET_BODY_MIN: number = 120;

function iconVp(size: number): string {
  return size + 'vp';
}

@Builder
function partsEmptyBuilder() {
}

/**
 * 隐私中心个性化开关行（H-P03）：版式与自绘开关照 MeSwitchRow（标题 body 17 + 说明 caption 12、纵向 4、上下 12、开关 52×32 垂直居中）；
 * 整行一个读屏单元：accessibilityText = 名称，开关，状态（spoken）+ 说明作 accessibilityDescription（MeSwitchRow 不读说明）。
 */
@ComponentV2
export struct PrivacySwitchRow {
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
      // 开关本体：只是视觉，读屏与点击在整行上。
      Row() {
        Column()
          .width(KNOB_DOT)
          .height(KNOB_DOT)
          .borderRadius(CouliRadius.pill)
          .backgroundColor(CouliColors.backgroundSurface)
          .shadow(CouliShadow.card)
      }
      .width(KNOB_TRACK_W)
      .height(KNOB_TRACK_H)
      .padding(KNOB_INSET)
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
    .accessibilityDescription(this.desc)
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

/** 基本模式提示条（P8：muted 底、info 20 次文字色、14/400 主文字、圆角 12、内边距 12）：静态文字，整条读一次。 */
@ComponentV2
export struct PrivacyBasicNotice {
  @Param text: string = '';
  @Param noticeId: string = '';

  build() {
    Row({ space: CouliSpacing.space2 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(iconVp(CouliComponentMetrics.iconMedium))
        .fontColor([CouliColors.textSecondary])
        .width(CouliComponentMetrics.iconMedium)
        .height(CouliComponentMetrics.iconMedium)
        .accessibilityLevel('no')
        .id(this.noticeId + '_icon')
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, CouliFontWeight.regular))
        .layoutWeight(1)
    }
    .id(this.noticeId)
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.backgroundMuted)
    .accessibilityGroup(true)
    .accessibilityText(this.text)
  }
}

/** 关于页 App 图标（P13 / H-P08）：80 品牌底 + Logo 主图形着反白约 56；brand.primary / text.inverse 深浅同值，深色不变色。装饰图，读屏不读。 */
@ComponentV2
export struct AboutAppIcon {
  @Param iconId: string = '';

  build() {
    Stack() {
      Image(CouliLogoSpec.resource(CouliLogoVariant.Mark))
        .width(APP_ICON_MARK)
        .height(APP_ICON_MARK)
        .objectFit(ImageFit.Contain)
        .fillColor(CouliColors.textInverse)
        .draggable(false)
        .accessibilityLevel('no')
    }
    .id(this.iconId)
    .width(APP_ICON_SIZE)
    .height(APP_ICON_SIZE)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.brandPrimary)
    .clip(true)
    .accessibilityLevel('no-hide-descendants')
  }
}

/**
 * 关于页【复制诊断信息】（P17 / H-P09）：照 DS CouliButton SECONDARY 的令牌（白底、border.control 1、圆角 12、17/500、最小高 48、按压态、
 * 通栏）+ 复制图标 20、图标到文字 8、整体居中。读屏一个单元：只读文字（图标不读）。点击回调由视图给（id 与回调体留在 AboutView）。
 */
@ComponentV2
export struct AboutCopyButton {
  @Param text: string = '';
  @Param buttonId: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: CouliSpacing.space2 }) {
        SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
          .fontSize(iconVp(CouliComponentMetrics.iconMedium))
          .fontColor([CouliColors.textPrimary])
          .width(CouliComponentMetrics.iconMedium)
          .height(CouliComponentMetrics.iconMedium)
          .accessibilityLevel('no')
          .id(this.buttonId + '_icon')
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.medium, true))
          .textAlign(TextAlign.Center)
          .flexShrink(1)
      }
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .constraintSize({ minHeight: CouliComponentMetrics.buttonMinHeight, minWidth: CouliInteraction.minTouchTarget })
    .padding({
      top: CouliComponentMetrics.buttonPaddingBlock, bottom: CouliComponentMetrics.buttonPaddingBlock,
      left: CouliComponentMetrics.buttonPaddingInline, right: CouliComponentMetrics.buttonPaddingInline
    })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderControl })
    // 圆角写在 border 之后：border() 会把圆角重置为 0（同 CouliButton）。
    .borderRadius(CouliRadius.button)
    .id(this.buttonId)
    .accessibilityGroup(true)
    .accessibilityText(this.text)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => this.onTap())
  }
}

/**
 * 客服半屏面板（P20 / H-P05；照 MeSheetPanel 写法，bindSheet FIT_CONTENT 承载）：把手 36×4 → 图标块（读屏不读）→ 标题行（标题 17/600 居中、
 * 左右各让出 48；关闭 48 在标题之后、视觉在标题行右侧）→ 中段（说明与安全提示，超过最大高时滚动）→ 底部按钮列（固定可见）。
 * 源码顺序：标题 → 关闭 → 正文 → 按钮（adaptation-a11y-spec §8）。内边距 上 20 / 左右 16 / 下 24，纵向 16。
 * 中段最大高 = 面板最大高（视图按 CouliSheetPanel.maxHeight 给）− 实测的固定部分（头部、按钮列、内边距与间距），下限 120（P28）。
 * 下内边距 = 24 + 系统导航条避让区（brief P20「+ 系统安全区」）：设备实测（探针 c）不让出时「去帮助中心」命中区下缘落进系统手势区，
 * 那一段点不到。
 */
@ComponentV2
export struct CsSheetPanel {
  @Param title: string = '';
  @Param closeLabel: string = '';
  @Param titleId: string = '';
  @Param closeId: string = '';
  @Param panelId: string = '';
  @Param panelMaxHeight: number = 560;
  @BuilderParam badge: () => void = partsEmptyBuilder;
  @BuilderParam content: () => void = partsEmptyBuilder;
  @BuilderParam footer: () => void = partsEmptyBuilder;
  @Event onClose: () => void = () => {
  };
  @Local headerHeight: number = 0;
  @Local footerHeight: number = 0;
  /** 系统导航条（手势条）避让区高（vp）；取不到为 0。 */
  @Local bottomInset: number = 0;

  aboutToAppear(): void {
    try {
      const ui: UIContext = this.getUIContext();
      const context: common.UIAbilityContext = ui.getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window): void => {
        try {
          const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
          this.bottomInset = Math.max(0, ui.px2vp(nav.bottomRect.height));
        } catch (e) {
          // 取不到避让区：按 0。
        }
      }).catch((): void => {
        // 取不到窗口：按 0。
      });
    } catch (e) {
      // 上下文不可用：按 0。
    }
  }

  private bottomPadding(): number {
    return CouliSpacing.space6 + this.bottomInset;
  }

  private bodyMaxHeight(): number {
    const fixed: number = CouliSpacing.space5 + this.bottomPadding() + CouliSpacing.space4 * 2 + this.headerHeight + this.footerHeight;
    return Math.max(SHEET_BODY_MIN, this.panelMaxHeight - fixed);
  }

  build() {
    Column({ space: CouliSpacing.space4 }) {
      Column({ space: CouliSpacing.space4 }) {
        Row()
          .width(SHEET_HANDLE_W)
          .height(CouliSpacing.space1)
          .borderRadius(CouliRadius.pill)
          .backgroundColor(CouliColors.borderSubtle)
          .accessibilityLevel('no')
        this.badge()
        Row() {
          // 左侧让出与关闭同宽的 48，标题在面板中线居中。
          Column()
            .width(CouliInteraction.minTouchTarget)
            .accessibilityLevel('no')
          Text(this.title)
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
            .textAlign(TextAlign.Center)
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
            .layoutWeight(1)
            .id(this.titleId)
            .focusable(true)
            .focusBox(CouliFocus.box)
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            CouliIcon({ name: 'close', iconSize: CouliComponentMetrics.iconDefault, color: CouliColors.textPrimary })
          }
          .id(this.closeId)
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3 })
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.closeLabel)
          .focusBox(CouliFocus.box)
          .onClick(() => this.onClose())
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .onAreaChange((_old: Area, now: Area) => {
        this.headerHeight = now.height as number;
      })
      Scroll() {
        Column() {
          this.content()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .constraintSize({ maxHeight: this.bodyMaxHeight() })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.None)
      .align(Alignment.Top)
      Column() {
        this.footer()
      }
      .width('100%')
      .onAreaChange((_old: Area, now: Area) => {
        this.footerHeight = now.height as number;
      })
    }
    .id(this.panelId)
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
    .padding({ top: CouliSpacing.space5, left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: this.bottomPadding() })
    .backgroundColor(CouliColors.backgroundSurface)
  }
}

/** 客服半屏图标块（P21）：56、圆角 16；warning = 警告底 / 字 + 警告三角 32；muted = muted 底 + 次文字色消息气泡 32。装饰，读屏不读。 */
@ComponentV2
export struct CsBadge {
  @Param tone: string = 'muted';
  @Param badgeId: string = '';

  private warning(): boolean {
    return this.tone === 'warning';
  }

  build() {
    Stack() {
      SymbolGlyph(this.warning() ? $r('sys.symbol.exclamationmark_triangle') : $r('sys.symbol.message'))
        .fontSize(iconVp(CS_BADGE_ICON))
        .fontColor([this.warning() ? CouliColors.statusWarningText : CouliColors.textSecondary])
        .width(CS_BADGE_ICON)
        .height(CS_BADGE_ICON)
        .accessibilityLevel('no')
        .id(this.badgeId + '_icon')
    }
    .id(this.badgeId)
    .width(CS_BADGE_SIZE)
    .height(CS_BADGE_SIZE)
    .borderRadius(CouliRadius.card)
    .backgroundColor(this.warning() ? CouliColors.statusWarningBackground : CouliColors.backgroundMuted)
    .accessibilityLevel('no-hide-descendants')
  }
}

/** 客服安全提示条（P23）：muted 底、圆角 12、内边距 12、盾牌对勾 20 次文字色 + 14 主文字；整条读一次（图标不读）。 */
@ComponentV2
export struct CsSafetyStrip {
  @Param text: string = '';
  @Param stripId: string = '';

  build() {
    Row({ space: CouliSpacing.space2 }) {
      SymbolGlyph($r('sys.symbol.checkmark_shield'))
        .fontSize(iconVp(CouliComponentMetrics.iconMedium))
        .fontColor([CouliColors.textSecondary])
        .width(CouliComponentMetrics.iconMedium)
        .height(CouliComponentMetrics.iconMedium)
        .accessibilityLevel('no')
        .id(this.stripId + '_icon')
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .id(this.stripId)
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.backgroundMuted)
    .accessibilityGroup(true)
    .accessibilityText(this.text)
  }
}

/**
 * 客服半屏「去帮助中心」文字链接（P24，只在打不开半屏用）：14、text.link、下划线、居中；文字外框 = 行高（视觉不撑高），外层容器最小高 48
 * （语义盒与命中区都 ≥ 48，不只靠 responseRegion，避开 F-HM-82 小字号命中约 45 的缺口）；读屏读子文字一次。
 */
@ComponentV2
export struct CsHelpLink {
  @Param text: string = '';
  @Param linkId: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
        .decoration({ type: TextDecorationType.Underline, color: CouliColors.textLink })
        .textAlign(TextAlign.Center)
    }
    .id(this.linkId)
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    // 容器不成组、不另设读屏文字（成组时容器会带上子文字，按文字找到的就成了 48 高的容器）：读屏读子文字节点，角色在可点的容器上。
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => this.onTap())
  }
}
