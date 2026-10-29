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
import { ClipboardPromptLayout } from '../logic/ClipboardPromptLayout';

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

/** 提示条里文字栏与按钮区之间的间距（vp）。 */
const PROMPT_GAP: number = 8;
/** 提示条左右内边距（右侧关闭按钮自带 48 命中区，所以右边距小）。 */
const PROMPT_PADDING_LEFT: number = 12;
const PROMPT_PADDING_RIGHT: number = 4;

/**
 * 首页剪贴板提示条（HomeClipboardInvite-v3；FU-CLIP C7 系统分享提示条同版式）：白底圆角 16 浮起卡，左文案 14/600，右浅底按钮
 * （brand.subtle 底 + brand.emphasis 14/600，命中 48；邀请条为【绑定】、读屏「绑定邀请人」）与独立【关闭】（命中 48）。
 * 问句（文案最后一个全角逗号之后，如「绑定为邀请人？」）不拆行（HM-07v-b A6）：整句放不下当前行时问句另起一行；文字栏连问句都放不下
 * （320 宽 / 200% 字号）时按钮与关闭整体移到文字下方靠右（ClipboardPromptLayout.stacked），不缩字、不截断。读屏读完整一句。
 * 出现时播报一次（liveRegion 由调用方 CouliAnnounce 播报）。鸿蒙只在商品入口的 PasteButton 读到邀请内容后出邀请确认（读取已完成，
 * 按钮不再读剪贴板，是普通按钮）。系统分享提示条另带 badge（平台标签，F-X-05a 官方图标）与 detail（第二行：平台名 + 缩略主机），
 * 文字区整体读作 barLabel；按钮的读屏名不变。
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
  /** 条内容区宽（去掉左右内边距，vp）与按钮区（按钮 + 关闭）宽：量到后决定同行 / 下移、问句要不要另起一行。 */
  @Local rowWidth: number = 0;
  @Local actionsWidth: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  /** 100% 字号下 14/600 文字的宽（vp）× 当前字号倍数。 */
  private measure(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    try {
      const ui: UIContext = this.getUIContext();
      const px: number = ui.getMeasureUtils().measureText({
        textContent: text, fontSize: CouliTypography.footnote.size + 'vp', fontWeight: CouliFontWeight.semibold
      }) as number;
      return ui.px2vp(px) * this.fontScale.scale;
    } catch (e) {
      return text.length * CouliTypography.footnote.size * this.fontScale.scale;
    }
  }

  private stacked(): boolean {
    const q: string | null = ClipboardPromptLayout.question(this.text);
    return ClipboardPromptLayout.stacked(this.rowWidth, this.actionsWidth, q === null ? 0 : this.measure(q) + 1, PROMPT_GAP);
  }

  /** 文字栏宽（vp）：下移时为整行，同行时为整行减按钮区与间距；还没量到为 0。 */
  private columnWidth(): number {
    if (this.rowWidth <= 0) {
      return 0;
    }
    return this.stacked() ? this.rowWidth : Math.max(0, this.rowWidth - this.actionsWidth - PROMPT_GAP);
  }

  /** 显示用的文字：整句放得下一行就原样；放不下时问句另起一行（问句本身不拆，读屏仍读 text 原句）。 */
  private shownText(): string {
    const q: string | null = ClipboardPromptLayout.question(this.text);
    const width: number = this.columnWidth();
    if (q === null || width <= 0 || this.measure(this.text) + 1 <= width) {
      return this.text;
    }
    return this.text.substring(0, this.text.length - q.length) + '\n' + q;
  }

  @Builder
  textBlock() {
    if (this.detail.length === 0 && this.badge.length === 0) {
      Text(this.shownText())
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, CouliFontWeight.semibold))
        .width('100%')
        .accessibilityText(this.text)
        .id(this.barId + '_text')
    } else {
      Column({ space: CouliSpacing.space1 }) {
        Text(this.shownText())
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary,
            CouliFontWeight.semibold))
          .width('100%')
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
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .accessibilityGroup(true)
      .accessibilityText(this.barLabel.length > 0 ? this.barLabel : this.text + ' ' + this.detail)
      .id(this.barId + '_body')
    }
  }

  @Builder
  actions() {
    Row({ space: CouliSpacing.space1 }) {
      Button({ type: ButtonType.Capsule, stateEffect: true }) {
        Text(this.actionText)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
            this.disabled ? CouliColors.textSecondary : CouliColors.brandEmphasis, CouliFontWeight.semibold))
          .maxLines(1)
      }
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
      // 可用态浅底 brand.subtle（HomeClipboardInvite-v3）；禁用态（42901 / 在途）回中性底（Android b 同口径）。
      .backgroundColor(this.disabled ? CouliColors.backgroundMuted : CouliColors.brandSubtle)
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
    .alignItems(VerticalAlign.Center)
    .onAreaChange((_old: Area, now: Area) => {
      this.actionsWidth = now.width as number;
    })
  }

  build() {
    Column({ space: CouliSpacing.space1 }) {
      if (this.stacked()) {
        Column() {
          this.textBlock()
        }
        .width('100%')
        Row() {
          this.actions()
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      } else {
        Row({ space: PROMPT_GAP }) {
          Column() {
            this.textBlock()
          }
          .layoutWeight(1)
          this.actions()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: PROMPT_PADDING_LEFT, right: PROMPT_PADDING_RIGHT, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.floating)
    .onAreaChange((_old: Area, now: Area) => {
      this.rowWidth = Math.max(0, (now.width as number) - PROMPT_PADDING_LEFT - PROMPT_PADDING_RIGHT);
      CouliFontScale.refresh();
    })
    .id(this.barId)
  }
}

/**
 * 剪贴板结果提示（内联在发起入口下方）。两种版式：
 * - 默认（轻提示：30131 / 42901 / 5xxxx 等，及多卡半屏里的行内结果）：错误底色圆角 12，图标 + 文案（+【用商品名搜索】链接样式）+ 关闭。
 * - card = true（HomeClipboardResults-v3 ① 识别不了、⑤ 网络失败，HM-07v-b A18）：白卡圆角 16 + shadow.card，左 20 图标（icon）
 *   + 文案 14 主文字色，右侧描边次按钮（【用商品名搜索】/【重试】，brand.emphasis 14/600、命中 48）；放不下时按钮整块换到下一行靠右，
 *   文案不截断。①⑤ 不设关闭（调用方按 ClipboardResultView.closable 给 closeLabel）。
 * actionDisabled：共享 42901 禁用期 / 在途时按钮置灰（enabled(false)，APP-07 共性第 31 条），执行层另外拦截。出现时由调用方播报。
 */
@ComponentV2
export struct ClipboardNotice {
  @Param text: string = '';
  @Param actionText: string = '';
  @Param actionDisabled: boolean = false;
  @Param closeLabel: string = '';
  @Param noticeId: string = 'clipboard_notice';
  /** 卡内版式（①⑤，HomeClipboardResults-v3）；false 为轻提示版式（默认，不变）。 */
  @Param card: boolean = false;
  /** 卡内版式左侧图标名（① info、⑤ alert）。 */
  @Param icon: string = 'alert';
  /** 这条结果的编号（渲染键）：按钮回调在渲染时固定，结果换代时随之重新登记（R1-03）。 */
  @Param actionKey: number = 0;
  @Event onAction: () => void = () => {
  };
  @Event onClose: () => void = () => {
  };

  /** 卡内版式：文字区宽（图标右侧，vp）与按钮宽，量到后决定按钮同行还是换到文字下方靠右。 */
  @Local cardRowWidth: number = 0;
  @Local cardActionWidth: number = 0;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  /** 100% 字号下 14/400 文案一行的宽（vp）× 当前字号倍数。 */
  private measureText(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    try {
      const ui: UIContext = this.getUIContext();
      const px: number = ui.getMeasureUtils().measureText({
        textContent: text, fontSize: CouliTypography.footnote.size + 'vp'
      }) as number;
      return ui.px2vp(px) * this.fontScale.scale;
    } catch (e) {
      return text.length * CouliTypography.footnote.size * this.fontScale.scale;
    }
  }

  /** 文案一行放不下「文案 + 间距 + 按钮」时按钮换到文案下方靠右（不缩字、不截断、按钮命中区不压缩）。 */
  private cardStacked(): boolean {
    if (this.actionText.length === 0) {
      return false;
    }
    return ClipboardPromptLayout.stacked(this.cardRowWidth, this.cardActionWidth, this.measureText(this.text) + 1,
      CouliSpacing.space3);
  }

  @Builder
  cardText() {
    Text(this.text)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
      .id(this.noticeId + '_text')
  }

  @Builder
  cardAction() {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      Text(this.actionText)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
          this.actionDisabled ? CouliColors.textSecondary : CouliColors.brandEmphasis, CouliFontWeight.semibold))
    }
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
    .backgroundColor(CouliColors.backgroundSurface)
    .border({ width: 1, color: this.actionDisabled ? CouliColors.borderSubtle : CouliColors.borderControl })
    .enabled(!this.actionDisabled)
    .focusBox(CouliFocus.box)
    .id(this.noticeId + '_action')
    .onClick(CouliFixedTap.of(this.onAction, this.actionKey))
    .onAreaChange((_old: Area, now: Area) => {
      this.cardActionWidth = now.width as number;
    })
  }

  @Builder
  cardBody() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: this.icon, iconSize: 20, color: CouliColors.textSecondary })
        .margin({ top: 1 })
      // 文案与按钮：一行放得下同行（按钮靠右）；放不下（320 宽 / 200% 字号）按钮换到文案下方靠右。
      Column({ space: CouliSpacing.space2 }) {
        if (this.cardStacked()) {
          Row() {
            this.cardText()
          }
          .width('100%')
          Row() {
            this.cardAction()
          }
          .width('100%')
          .justifyContent(FlexAlign.End)
        } else {
          Row({ space: CouliSpacing.space3 }) {
            Row() {
              this.cardText()
            }
            .layoutWeight(1)
            if (this.actionText.length > 0) {
              this.cardAction()
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .layoutWeight(1)
      .onAreaChange((_old: Area, now: Area) => {
        this.cardRowWidth = now.width as number;
      })
      if (this.closeLabel.length > 0) {
        Button({ type: ButtonType.Normal, stateEffect: true }) {
          CouliIcon({ name: 'close', iconSize: 18, color: CouliColors.textSecondary })
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
    .alignItems(VerticalAlign.Center)
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space3, top: CouliSpacing.space3,
      bottom: CouliSpacing.space3 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .shadow(CouliShadow.card)
    .id(this.noticeId)
  }

  build() {
    if (this.card) {
      this.cardBody()
    } else {
      this.lightBody()
    }
  }

  @Builder
  lightBody() {
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
