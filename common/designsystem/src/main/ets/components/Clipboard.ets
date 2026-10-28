import { CouliColors } from '../CouliColors';
import { CouliFocus, CouliInteraction, CouliRadius, CouliShadow, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { PlatformBadge } from './Basics';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';
import { CouliFixedTap } from '../logic/CouliFixedTap';
import { LARGE_TEXT_SCALE } from '../logic/TextScale';
import { PriceTerms } from '../format/PriceTerms';
import { CouliFontScale } from './FontScale';

/** PasteButton 的视觉高（命中区 ≥ 48：系统安全控件按自身尺寸响应，所以视觉高就取 48）。 */
const PASTE_HEIGHT: number = 48;

/**
 * 鸿蒙的系统粘贴控件（BR-ID-16、CAP-X-02：只用系统 PasteButton，只用系统提供的图标与文字选项「粘贴」，读屏名称由系统提供）。
 * onClick 结果为 SUCCESS 时才交出 true（临时授权成功，调用方这时才读剪贴板）；其余结果交出 false，调用方不读。
 * 安全控件的约束：不得被遮挡、透明或缩到看不清（否则系统拒绝授权），所以这里只换颜色、圆角与字号，不加蒙层。
 * disabled：42901 禁用期等（enabled(false)，API 18 起），执行层另外拦截。
 */
@ComponentV2
export struct CouliPasteButton {
  @Param disabled: boolean = false;
  @Param buttonId: string = '';
  /** 整行宽（SearchTyping 的整行按钮）；否则按内容宽的胶囊。 */
  @Param fullWidth: boolean = false;
  /** 品牌浅底（SearchTyping 用；false 为白底胶囊）。 */
  @Param tinted: boolean = true;
  /**
   * 实心主按钮配色（HM-07v H5，首页粘贴卡）：主按钮底 + 主按钮字 / 图标（对比度足够，系统安全控件不拒绝授权）。
   * 只换颜色，文字与图标仍是系统枚举（BR-ID-16：鸿蒙不换成「粘贴查返利」）。
   */
  @Param solid: boolean = false;
  @Event onResult: (success: boolean) => void = (_s: boolean) => {
  };

  build() {
    PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
      .fontSize(CouliTypography.body.fontSize as Dimension)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.solid ? CouliColors.buttonPrimaryDefaultText : CouliColors.brandEmphasis)
      .iconColor(this.solid ? CouliColors.buttonPrimaryDefaultText : CouliColors.brandEmphasis)
      .backgroundColor(this.solid ? CouliColors.buttonPrimaryDefaultBackground
        : (this.tinted ? CouliColors.brandSubtle : CouliColors.backgroundSurface))
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
        bottom: CouliSpacing.space2 })
      .width(this.fullWidth ? '100%' : 'auto')
      .constraintSize({ minHeight: PASTE_HEIGHT, minWidth: CouliInteraction.minTouchTarget })
      .enabled(!this.disabled)
      .id(this.buttonId)
      .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
        this.onResult(result === PasteButtonOnClickResult.SUCCESS);
      })
  }
}

/** 首页粘贴卡最小高（Main-v3 约 132）。 */
const PASTE_CARD_MIN_HEIGHT: number = 132;
/** 示意插图尺寸（Main-v3 的 132×112 视口）。 */
const PASTE_ART_WIDTH: number = 132;
const PASTE_ART_HEIGHT: number = 112;
/** 卡宽小于此值时不画插图（按钮列留足宽度）。 */
const PASTE_ART_MIN_CARD: number = 300;

/**
 * 首页粘贴卡右侧的示意插图「链接 → 带预估返的卡」（照 Main-v3 132×112 SVG 用形状重画，颜色全部取令牌，深色随令牌）。
 * 纯装饰：整块对读屏隐藏（no-hide-descendants），不可点。
 */
@Builder
function pasteIllustration() {
  Stack({ alignContent: Alignment.TopStart }) {
    Circle({ width: 116, height: 116 })
      .fill(CouliColors.backgroundSurface)
      .opacity(0.55)
      .position({ x: 18, y: -2 })
    Rect({ width: 104, height: 36 })
      .radius(10)
      .fill(CouliColors.backgroundSurface)
      .stroke(CouliColors.borderSubtle)
      .position({ x: 10, y: 10 })
    Stack() {
      CouliIcon({ name: 'link', iconSize: 22, color: CouliColors.brandEmphasis })
    }
    .position({ x: 18, y: 17 })
    Rect({ width: 56, height: 5 }).radius(2.5).fill(CouliColors.borderSubtle).position({ x: 46, y: 20 })
    Rect({ width: 36, height: 5 }).radius(2.5).fill(CouliColors.borderSubtle).position({ x: 46, y: 30 })
    Column() {
      Rect({ width: 1.75, height: 7 }).fill(CouliColors.borderControl)
      CouliIcon({ name: 'chevron-down', iconSize: 12, color: CouliColors.borderControl })
        .margin({ top: -6 })
    }
    .position({ x: 56, y: 50 })
    Rect({ width: 116, height: 42 })
      .radius(10)
      .fill(CouliColors.backgroundSurface)
      .stroke(CouliColors.borderSubtle)
      .position({ x: 10, y: 64 })
    Rect({ width: 26, height: 26 }).radius(6).fill(CouliColors.backgroundPlaceholder).position({ x: 18, y: 72 })
    Rect({ width: 14, height: 16 }).radius(2).fill(CouliColors.backgroundSurface).position({ x: 24, y: 78 })
    Rect({ width: 14, height: 6 }).fill(CouliColors.statusSuccessText).position({ x: 24, y: 88 })
    Rect({ width: 54, height: 5 }).radius(2.5).fill(CouliColors.borderSubtle).position({ x: 50, y: 74 })
    Row({ space: 2 }) {
      CouliIcon({ name: 'clock', iconSize: 9, color: CouliColors.rebateText })
      Text(PriceTerms.rebate)
        .fontSize(9)
        .fontWeight(CouliFontWeight.semibold)
        .fontColor(CouliColors.rebateText)
        .maxFontScale(1)
    }
    .width(68)
    .height(15)
    .padding({ left: 4 })
    .borderRadius(7.5)
    .backgroundColor(CouliColors.rebateBackground)
    .position({ x: 50, y: 84 })
  }
  .width(PASTE_ART_WIDTH)
  .height(PASTE_ART_HEIGHT)
  .accessibilityLevel('no-hide-descendants')
  .hitTestBehavior(HitTestMode.None)
}

/** PasteEntry 的版式。 */
export enum PasteEntryStyle {
  /**
   * 首页常驻粘贴卡（Main-v3 / HomeGuest-v3，HM-07v H5）：品牌浅底圆角 16、高约 132；左列标题 17/600（卡标题即按钮说明，
   * BR-ID-16）+ 下方实心系统粘贴按钮；右侧「链接 → 带预估返的卡」示意插图（装饰，读屏隐藏，不压按钮）。无副标题。
   */
  CARD = 'card',
  /** SearchTyping「粘贴查返利」：白卡内上方说明文字 12 + 整行系统粘贴按钮（品牌浅底）。 */
  ROW = 'row'
}

/**
 * 用户主动粘贴的入口（brief §2.5，三端同名 PasteEntry；鸿蒙实现 = 系统 PasteButton + 旁边的说明文字，说明文字可被读屏读到）。
 * 文案全部由调用方给（文案键在 entry 的草稿表，TODO(N-30)）。
 */
@ComponentV2
export struct PasteEntry {
  @Param entryStyle: PasteEntryStyle = PasteEntryStyle.ROW;
  @Param title: string = '';
  @Param subtitle: string = '';
  /** 系统按钮旁边的说明文字（ROW 版在按钮上方）。 */
  @Param caption: string = '';
  @Param disabled: boolean = false;
  @Param entryId: string = '';
  @Event onResult: (success: boolean) => void = (_s: boolean) => {
  };
  @Local cardWidth: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  @Builder
  card() {
    Row({ space: CouliSpacing.space3 }) {
      Column({ space: CouliSpacing.space4 }) {
        Text(this.title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
        }
        CouliPasteButton({
          disabled: this.disabled,
          buttonId: this.entryId + '_paste',
          solid: true,
          onResult: (success: boolean) => this.onResult(success)
        })
      }
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      // 插图在 200% 字号或卡太窄时不画（不挤按钮、不压按钮：安全控件被遮挡会拒绝授权，brief-harmony §3.2）。
      if (this.fontScale.scale <= LARGE_TEXT_SCALE && this.cardWidth >= PASTE_ART_MIN_CARD) {
        pasteIllustration()
      }
    }
    .width('100%')
    .constraintSize({ minHeight: PASTE_CARD_MIN_HEIGHT })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space3, top: CouliSpacing.space4,
      bottom: CouliSpacing.space4 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.brandSubtle)
    .alignItems(VerticalAlign.Center)
    .id(this.entryId)
    .onAreaChange((_old: Area, now: Area) => {
      this.cardWidth = now.width as number;
      CouliFontScale.refresh();
    })
  }

  @Builder
  row() {
    Column({ space: CouliSpacing.space2 }) {
      if (this.caption.length > 0) {
        Text(this.caption)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .width('100%')
      }
      // 安全控件拉满整行时图标与文字会分到两端：整行用品牌浅底，系统按钮按内容宽居中（同一底色，视觉上是一整行按钮）
      Row() {
        CouliPasteButton({
          disabled: this.disabled,
          buttonId: this.entryId + '_paste',
          onResult: (success: boolean) => this.onResult(success)
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.brandSubtle)
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .id(this.entryId)
  }

  build() {
    if (this.entryStyle === PasteEntryStyle.CARD) {
      this.card()
    } else {
      this.row()
    }
  }
}

/**
 * 首页剪贴板提示条（HomeClipboard / HomeClipboardInvite）：白底圆角 16 浮起卡，左文案 14/600，右浅灰胶囊按钮与独立【关闭】（命中区 48）。
 * 出现时播报一次（liveRegion 由调用方 CouliAnnounce 播报）；按钮读屏名由 actionLabel 给（邀请条为「粘贴并绑定邀请人」）。
 * 鸿蒙只在商品入口的 PasteButton 读到邀请内容后出邀请确认（读取已完成，这里的按钮不再读剪贴板，是普通按钮）。
 * FU-CLIP C7：系统分享提示条另带 badge（平台标签；F-X-05a 起按 badgePlatform 带内置官方图标，暂缺平台只有文字）与 detail（第二行：平台名 + 缩略主机），
 * 文字区整体读作 barLabel（「检测到淘宝商品链接，查返利」）；按钮的读屏名不变。字号放大时文字换行、不截断。
 */
@ComponentV2
export struct ClipboardPromptBar {
  @Param text: string = '';
  @Param detail: string = '';
  @Param badge: string = '';
  /** 平台标签的平台标识键（F-X-05a：有内置图时标签带 14vp 官方图标；暂缺 / 未知只显示文字）。 */
  @Param badgePlatform: string = '';
  @Param barLabel: string = '';
  @Param actionText: string = '';
  @Param actionLabel: string = '';
  @Param closeLabel: string = '';
  @Param disabled: boolean = false;
  @Param barId: string = 'clipboard_prompt';
  /** 这条提示的编号（渲染键）：按钮回调在渲染时固定，提示换代时随之重新登记（R1-03）。 */
  @Param actionKey: number = 0;
  @Event onAction: () => void = () => {
  };
  @Event onClose: () => void = () => {
  };

  build() {
    Row({ space: CouliSpacing.space2 }) {
      if (this.detail.length === 0 && this.badge.length === 0) {
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, CouliFontWeight.semibold))
          .layoutWeight(1)
          .id(this.barId + '_text')
      } else {
        Column({ space: CouliSpacing.space1 }) {
          Text(this.text)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
              CouliFontWeight.semibold))
            .id(this.barId + '_text')
          Row({ space: CouliSpacing.space1 }) {
            if (this.badge.length > 0) {
              // 文字区整体读 barLabel（已含平台名）：标签自身对读屏隐藏，平台名不重复读。
              PlatformBadge({ label: this.badge, platform: this.badgePlatform })
                .accessibilityLevel('no-hide-descendants')
            }
            if (this.detail.length > 0) {
              Text(this.detail)
                .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
                .layoutWeight(1)
                .id(this.barId + '_detail')
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .accessibilityGroup(true)
        .accessibilityText(this.barLabel.length > 0 ? this.barLabel : this.text + ' ' + this.detail)
        .id(this.barId + '_body')
      }
      Button({ type: ButtonType.Capsule, stateEffect: true }) {
        Text(this.actionText)
          .attributeModifier(new CouliTextModifier(CouliTypography.caption,
            this.disabled ? CouliColors.textSecondary : CouliColors.textPrimary))
          .maxLines(1)
      }
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
      .backgroundColor(CouliColors.backgroundMuted)
      .enabled(!this.disabled)
      .accessibilityText(this.actionLabel)
      .focusBox(CouliFocus.box)
      .id(this.barId + '_action')
      .onClick(CouliFixedTap.of(this.onAction, this.actionKey))
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'close', iconSize: 20, color: CouliColors.textSecondary })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.closeLabel)
      .focusBox(CouliFocus.box)
      .id(this.barId + '_close')
      .onClick(CouliFixedTap.of(this.onClose, this.actionKey))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: CouliSpacing.space3, right: CouliSpacing.space1, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.floating)
    .id(this.barId)
  }
}

/**
 * 30132 的提示样式（ShareHubInvalid：错误底色圆角 12，图标 + 文案 +【用商品名搜索】600，窄屏换行）；actionText 为空时只有文案
 * （30131 / 42901 / 5xxxx 等轻提示也用这一块，内联在发起入口下方）。出现时由调用方播报。
 * actionDisabled：共享 42901 禁用期内【用商品名搜索】置灰（enabled(false)，APP-07 共性第 31 条），执行层另外拦截。
 */
@ComponentV2
export struct ClipboardNotice {
  @Param text: string = '';
  @Param actionText: string = '';
  @Param actionDisabled: boolean = false;
  @Param closeLabel: string = '';
  @Param noticeId: string = 'clipboard_notice';
  /** 这条结果的编号（渲染键）：按钮回调在渲染时固定，结果换代时随之重新登记（R1-03）。 */
  @Param actionKey: number = 0;
  @Event onAction: () => void = () => {
  };
  @Event onClose: () => void = () => {
  };

  build() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'alert', iconSize: 20, color: CouliColors.statusErrorText })
        .margin({ top: 1 })
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Text(this.text)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .margin({ right: CouliSpacing.space3 })
          .id(this.noticeId + '_text')
        if (this.actionText.length > 0) {
          Text(this.actionText)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
              this.actionDisabled ? CouliColors.textSecondary : CouliColors.brandEmphasis, CouliFontWeight.semibold))
            .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
            .accessibilityRole(AccessibilityRoleType.BUTTON)
            .focusable(true)
            .focusBox(CouliFocus.box)
            .enabled(!this.actionDisabled)
            .id(this.noticeId + '_action')
            .onClick(CouliFixedTap.of(this.onAction, this.actionKey))
        }
      }
      .layoutWeight(1)
      if (this.closeLabel.length > 0) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 18, color: CouliColors.statusErrorText })
        }
        .width(CouliInteraction.minTouchTarget)
        .height(CouliInteraction.minTouchTarget)
        .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, right: -CouliSpacing.space2 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.closeLabel)
        .focusBox(CouliFocus.box)
        .onClick(CouliFixedTap.of(this.onClose, this.actionKey))
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.statusErrorBackground)
    .id(this.noticeId)
  }
}
