import {
  CouliColors, CouliComponentMetrics, CouliFocus, CouliFontWeight, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing,
  CouliShadow, CouliTextModifier, CouliTypography, PriceTerms
} from 'designsystem';

/**
 * 设置一族私有视图件（APP-12w-a-harmony，brief-a-harmony H-S01：MeKit 一字不动，设置一族的 52 行 / 链接 / 提示条 / 协议行 / 通知条与服务行 /
 * 昵称错误行放这里）。只收渲染时的值与 @Event 回调；执行逻辑、身份核对与跳转全在 SettingsView。本文件不出现中文（HM-LINT-1）。
 */

/** 设置主页行高：画板 min-height 44 + 上下 4（11-02 14:45「三端以画板为准」）= 52，加 1px 分隔节距 53。 */
const NAV_ROW_MIN_HEIGHT: number = CouliInteraction.minTouchTarget + CouliSpacing.space1;

/** 文字链接的行高（footnote 14 × 1.5，fp）：命中区向外扩到 48 时用。 */
function footnoteLine(): number {
  return CouliTypography.footnote.size * CouliTypography.footnote.lineHeightRatio;
}

/**
 * 设置主页导航行（照 MeRow 写法：Flex 可折行、标题 body 17、值 footnote 14 次文字、chevron 20、值到箭头 4、标题右 12；读屏「标题，值」+
 * 按钮）。差别：行高 52（含上下 4）；showChevron=false 时不画箭头（「重新显示下单须知」动作行，仍是按钮）。
 */
@ComponentV2
export struct SettingsNavRow {
  @Param label: string = '';
  @Param value: string = '';
  @Param rowId: string = '';
  @Param clickable: boolean = true;
  @Param showChevron: boolean = true;
  @Param divider: boolean = true;
  @Event onTap: () => void = () => {
  };

  build() {
    Column() {
      // 设备实测（dev1）：constraintSize 的最小高不含 padding（MeRow 写法会得 52 + 8）。最小高放在外层，内层只留上下 4（200% 时行高 = 内容 + 8）。
      Column() {
      Flex({ justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center, wrap: FlexWrap.Wrap }) {
        Text(this.label)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .margin({ right: CouliSpacing.space3 })
          .flexShrink(1)
        Row({ space: CouliSpacing.space1 }) {
          if (this.value.length > 0) {
            Text(this.value)
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
              .textAlign(TextAlign.End)
              .flexShrink(1)
          }
          if (this.clickable && this.showChevron) {
            CouliIcon({ name: 'chevron', iconSize: CouliComponentMetrics.iconMedium, color: CouliColors.textSecondary })
              .accessibilityLevel('no')
          }
        }
        .flexShrink(1)
      }
      .width('100%')
      .padding({ top: CouliSpacing.space1, bottom: CouliSpacing.space1 })
      }
      .width('100%')
      .constraintSize({ minHeight: NAV_ROW_MIN_HEIGHT })
      .justifyContent(FlexAlign.Center)
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
 * 游客页脚「去登录」文字链接（14/600、text.link、下划线）：外框 = 文字行高（宽至少 48），命中区从外框顶向下扩到 48（不压上方说明句）；
 * 下外边距让出扩出去的那一段，父容器随之包住命中区（越出父框的命中区收不到点击）。
 */
@ComponentV2
export struct GuestLoginLink {
  @Param text: string = '';
  @Param linkId: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Text(this.text)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink, CouliFontWeight.semibold))
      .decoration({ type: TextDecorationType.Underline, color: CouliColors.textLink })
      .textAlign(TextAlign.Center)
      .constraintSize({ minWidth: CouliInteraction.minTouchTarget })
      .responseRegion([
        { x: 0, y: 0, width: '100%', height: '100%' },
        { x: 0, y: 0, width: '100%', height: CouliInteraction.minTouchTarget }
      ])
      .margin({ bottom: CouliInteraction.minTouchTarget - footnoteLine() })
      .id(this.linkId)
      .accessibilityText(this.text)
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => this.onTap())
  }
}

/** 基本模式提示条（muted 底、信息图标 20 次文字色、14/500 主文字、圆角 12、内边距 12）：静态文字，整条读一次。 */
@ComponentV2
export struct BasicModeNotice {
  @Param text: string = '';
  @Param noticeId: string = '';

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'info', iconSize: CouliComponentMetrics.iconMedium, color: CouliColors.textSecondary })
        .accessibilityLevel('no')
      Text(this.text)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, CouliFontWeight.medium))
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

/**
 * 协议半屏的列表行（H-S04：行高 48 = 命中区；17 主文字、chevron 20、行间 1px 分隔；文字与半屏标题左齐）。读屏「标题」+ 按钮。
 */
@ComponentV2
export struct AgreementSheetRow {
  @Param text: string = '';
  @Param rowId: string = '';
  @Param divider: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Column() {
      Column() {
      Row({ space: CouliSpacing.space3 }) {
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .layoutWeight(1)
        CouliIcon({ name: 'chevron', iconSize: CouliComponentMetrics.iconMedium, color: CouliColors.textSecondary })
          .accessibilityLevel('no')
      }
      .width('100%')
      .padding({ top: CouliSpacing.space1, bottom: CouliSpacing.space1 })
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      .justifyContent(FlexAlign.Center)
      if (this.divider) {
        Divider().color(CouliColors.borderSubtle).strokeWidth(1)
      }
    }
    .id(this.rowId)
    .width('100%')
    .accessibilityGroup(true)
    .accessibilityText(this.text)
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => this.onTap())
  }
}

/**
 * 昵称页错误行（字段错误 / 本地长度提示 / 保存消息同一位置同一写法：警告三角 16 + 14 错误色文字，在输入框下）。整行是一个文字节点
 * （图标画在左侧内边距里的浮层上，读屏不读），读屏一个单元；focusTarget=true 时可获焦（字段错误：SettingsView.applyNick 把焦点移到
 * 这里）。设备实测（dev2）：Row 容器设 focusable 也拿不到焦点，所以用可获焦的 Text 承载。
 */
@ComponentV2
export struct NicknameErrorRow {
  @Param text: string = '';
  @Param rowId: string = '';
  @Param focusTarget: boolean = false;

  @Builder
  icon() {
    CouliIcon({ name: 'alert', iconSize: CouliComponentMetrics.iconInline, color: CouliColors.statusErrorText })
      .accessibilityLevel('no')
  }

  build() {
    Text(this.text)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
      .width('100%')
      .padding({ left: CouliComponentMetrics.iconInline + CouliSpacing.space1 })
      .overlay(this.icon(), {
        align: Alignment.TopStart,
        offset: { x: 0, y: (footnoteLine() - CouliComponentMetrics.iconInline) / 2 }
      })
      .id(this.rowId)
      .accessibilityText(this.text)
      .focusable(this.focusTarget)
      .focusBox(CouliFocus.box)
  }
}

/**
 * 通知设置的系统通知关闭提示条（警告底 / 字、警告三角 20、14 字、内边距 12、圆角 12），条内文字链接（600、警告字色、下划线）。
 * 链接外框 = 文字行高（宽至少 48），命中区从外框底向上扩到 48（在条内、不撑高条）。读屏：句子一次、链接单独一次（按钮）。
 */
@ComponentV2
export struct NotifyWarningBar {
  @Param text: string = '';
  @Param linkText: string = '';
  @Param barId: string = '';
  @Param linkId: string = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: CouliComponentMetrics.iconMedium, color: CouliColors.statusWarningText })
        .accessibilityLevel('no')
      Column({ space: CouliSpacing.space1 }) {
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText))
        Text(this.linkText)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText,
            CouliFontWeight.semibold))
          .decoration({ type: TextDecorationType.Underline, color: CouliColors.statusWarningText })
          .constraintSize({ minWidth: CouliInteraction.minTouchTarget })
          .responseRegion([
            { x: 0, y: 0, width: '100%', height: '100%' },
            { x: 0, y: footnoteLine() - CouliInteraction.minTouchTarget, width: '100%', height: CouliInteraction.minTouchTarget }
          ])
          .id(this.linkId)
          .accessibilityText(this.linkText)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .onClick(() => this.onTap())
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .id(this.barId)
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.statusWarningBackground)
  }
}

/**
 * 通知服务开关行（H-S06：沿用 MeSwitchRow 的自绘开关 52×32 与整行 SWITCH 读屏，只把说明移到标题 + 开关这一行的下方、通栏）。
 * 读屏：accessibilityText = 名称 + 状态（spoken），说明作 accessibilityDescription。
 */
@ComponentV2
export struct NotifyServiceRow {
  @Param label: string = '';
  @Param desc: string = '';
  @Param on: boolean = false;
  @Param disabled: boolean = false;
  @Param rowId: string = '';
  @Param spoken: string = '';
  @Event onToggle: (target: boolean) => void = (_t: boolean) => {
  };

  build() {
    Column({ space: CouliSpacing.space1 }) {
      Row({ space: CouliSpacing.space3 }) {
        Text(this.label)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
          .layoutWeight(1)
        // 开关本体（52×32 胶囊、28 圆点，与 MeSwitchRow 同）：只是视觉，读屏与点击在整行上。
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
        .backgroundColor(this.on ? CouliColors.controlChecked : CouliColors.borderControl)
        .opacity(this.disabled ? 0.5 : 1)
        .accessibilityLevel('no')
        .id(this.rowId + '_knob_' + (this.on ? 'on' : 'off'))
      }
      .width('100%')
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
      if (this.desc.length > 0) {
        Text(this.desc)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .width('100%')
      }
    }
    .id(this.rowId)
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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
