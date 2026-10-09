import { display } from '@kit.ArkUI';
import {
  OpenPurchaseController, PurchaseButtons, PurchaseDialog, PurchaseDialogKind, PurchasePhase, PurchaseState, TradeJson,
  withTrace6
} from 'core';
import {
  CouliButton, CouliButtonVariant, CouliColors, CouliFocus, CouliFocusReturn, CouliFontWeight, CouliFormat, CouliIcon,
  CouliInteraction, CouliLayout, CouliRadius, CouliShadow, CouliShadowMask, CouliSpacing, CouliTextModifier,
  CouliTypography, CouliFontScale, PriceConfirmLabel, PriceTagModel, PriceTerms
} from 'designsystem';
import { TradeDraftTexts } from './TradeDraftTexts';

/** 文案键（契约有的读契约；没有的在 TradeDraftTexts，三端同名）。 */
export class TradeKeys {
  static readonly OPENING: string = 'buy.opening';
  static readonly OPENING_CANCEL: string = 'buy.opening.cancel';
  static readonly TIMEOUT: string = 'buy.timeout';
  static readonly RETRY: string = 'external_page.retry';
  static readonly BROWSER_NOTICE: string = 'trade.browser_notice';
  static readonly PRICE_TITLE: string = 'trade.price_changed.title';
  static readonly PRICE_BEFORE: string = 'trade.price_changed.before';
  static readonly PRICE_NOW: string = 'trade.price_changed.now';
  /** 券额仍未知时「现在」一行不带口径词（不把新券后价说成「售价」，BR-PRICE-14，共性第 21 条）。 */
  static readonly PRICE_NOW_PLAIN: string = 'trade.price_changed.now_plain';
  static readonly PRICE_ASK: string = 'trade.price_changed.ask';
  static readonly COUPON_TITLE: string = 'trade.coupon_gone.title';
  static readonly REBATE_GONE_LINE: string = 'trade.rebate_gone.line';
  static readonly REBATE_GONE_NOTE: string = 'trade.rebate_gone.note';
  static readonly REBATE_GONE_TITLE: string = 'trade.rebate_gone.title';
  static readonly REBATE_GONE_BODY: string = 'trade.rebate_gone.body';
  static readonly CANCEL: string = 'trade.cancel';
  static readonly CONTINUE: string = 'trade.continue';
  static readonly COMPARE_TITLE: string = 'no_rebate.price_compare.confirm';
  static readonly COMPARE_BODY: string = 'trade.compare.body';
  static readonly COMPARE_EXPLAIN: string = 'trade.compare.explain';
  static readonly COMPARE_SIMILAR: string = 'no_rebate.price_compare.similar';
  static readonly BUY_NO_REBATE: string = 'trade.buy_no_rebate';
  static readonly CLOSE: string = 'trade.close';
  static readonly AUTH_REASON: string = 'trade.auth.reason';
  static readonly AUTH_PRIVACY: string = 'trade.auth.privacy';
  static readonly REBIND_NOTE: string = 'auth_manage.rebind_note';
  static readonly AUTHORIZE: string = 'auth_manage.action.authorize';
  static readonly DECLINED_TITLE: string = 'trade.auth_declined.title';
  static readonly DECLINED_BODY: string = 'trade.auth_declined.body';
  static readonly FAILED_TITLE: string = 'error.30104.credential_invalid';
  static readonly FAILED_BODY: string = 'trade.auth_failed.body';
  static readonly UNAVAILABLE_BODY: string = 'trade.auth_unavailable.body';
  static readonly OK: string = 'trade.ok';
  static readonly TIP_TITLE: string = 'trade.jump_tip.title';
  static readonly TIP_LINE_1: string = 'trade.jump_tip.line1';
  static readonly TIP_LINE_2: string = 'trade.jump_tip.line2';
  static readonly TIP_GO: string = 'trade.jump_tip.go';
  static readonly SDK_FAILED_TITLE: string = 'jump.taobao_sdk_unavailable';
  static readonly SDK_FAILED_BODY: string = 'trade.sdk_failed.body';
  static readonly NOT_INSTALLED: string = 'trade.not_installed';
  static readonly CONTACT: string = 'trade.contact';
  static readonly COPY_TPWD: string = 'share_page.copy_tpwd';
  static readonly GENERIC: string = 'error.50001';

  /** AuthSheet 标题：30101 / 30102 / 30111 的提示原文（ProductAuthSheet）。 */
  static authTitle(platform: string): string {
    return platform === 'pdd' ? 'error.30111' : 'error.30101';
  }
}

/** 购买浮层的界面模型（页面把 controller 的状态写进来）。 */
@ObservedV2
export class TradeOverlayModel {
  @Trace state: PurchaseState = new PurchaseState();
  /** 比价说明【查看说明】入口是否可见（/v1/config.help_links.price_compare）。 */
  @Trace explanation: boolean = false;
  /** 关闭弹层后焦点回到的控件 id（购买按钮；A11yFocusAuthSheet「返回」）。 */
  returnFocusId: string = 'product_buy';
  controller: OpenPurchaseController | null = null;

  get visible(): boolean {
    const s: PurchaseState = this.state;
    return s.phase === PurchasePhase.LOADING || s.browserNotice || s.dialog !== null;
  }

  /** 系统返回：有弹层时按「取消 / 关闭」处理并吃掉返回（返回 true）。 */
  back(): boolean {
    const c: OpenPurchaseController | null = this.controller;
    if (c === null || !this.visible) {
      return false;
    }
    if (this.state.phase === PurchasePhase.LOADING) {
      c.cancelLoading();
    } else if (this.state.browserNotice) {
      c.cancelBrowser();
    } else {
      c.dismissDialog();
    }
    return true;
  }
}

const LAYER_WIDTH: number = 240;

function vars(platform: string): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set('platform_name', TradeDraftTexts.platformName(platform));
  return m;
}

function t(key: string): string {
  return TradeDraftTexts.text(key);
}

/** 主价口径词（券后 / 售价 / 拼单券后 / 拼单价）：按卡片的价格字段，缺失时用「券后」。 */
function priceLabel(card: Record<string, Object> | null, platform: string): string {
  const price: number | null = TradeJson.fen(card, 'price_fen');
  const coupon: number | null = TradeJson.fen(card, 'coupon_fen');
  const final: number | null = TradeJson.fen(card, 'final_price_fen');
  if (price === null || coupon === null || final === null) {
    return platform === 'pdd' ? PriceTerms.pddAfterCoupon : PriceTerms.afterCoupon;
  }
  return PriceTagModel.make(platform, price, coupon, final, false).mainLabel;
}

/**
 * 购买浮层（APP-06b）：加载层（ProductBuyOpening，可取消）、「将通过浏览器打开」（ProductJumpBrowser）、各确认框
 * （ProductPriceChanged / RebateGone / PriceCompareNoRebate / AuthDeclined / AuthFailed / AuthUnavailable / JumpSdkFailed）与半屏
 * （ProductAuthSheet / ProductJumpTip）。只写平台名、不显示任何金额的加载层（03 §4.5）。打开时焦点进标题，关闭后回到购买按钮
 * （A11yFocusAuthSheet）。没有弹层时不占用触摸。
 */
@ComponentV2
export struct TradeOverlay {
  @Param @Require model: TradeOverlayModel;
  @Local fontScale: CouliFontScale = CouliFontScale.shared();

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
  }

  private c(): OpenPurchaseController | null {
    return this.model.controller;
  }

  private focusTitle(id: string): void {
    CouliFocusReturn.to(this.getUIContext(), id);
  }

  private returnFocus(): void {
    CouliFocusReturn.to(this.getUIContext(), this.model.returnFocusId);
  }

  @Builder
  blockingLayer(message: string, onCancel: () => void, layerId: string) {
    Column({ space: CouliSpacing.space3 }) {
      LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
      Text(message)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .textAlign(TextAlign.Center)
        .id(layerId + '_title')
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onAppear(() => this.focusTitle(layerId + '_title'))
      Text(t(TradeKeys.OPENING_CANCEL))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textLink))
        .constraintSize({ minWidth: 88, minHeight: CouliInteraction.minTouchTarget })
        .textAlign(TextAlign.Center)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .id(layerId + '_cancel')
        .onClick(() => {
          onCancel();
          this.returnFocus();
        })
    }
    .id(layerId)
    .width(LAYER_WIDTH)
    .padding({ top: CouliSpacing.space6, left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space2 })
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.panel)
    .shadow(CouliShadow.floating)
  }

  /** 弹层标题。 */
  private titleOf(d: PurchaseDialog): string {
    switch (d.kind) {
      case PurchaseDialogKind.CONFIRM_PRICE:
        return t(d.coupon ? TradeKeys.COUPON_TITLE : TradeKeys.PRICE_TITLE);
      case PurchaseDialogKind.CONFIRM_REBATE_GONE:
        return t(TradeKeys.REBATE_GONE_TITLE);
      case PurchaseDialogKind.COMPARE_NO_REBATE:
        return t(TradeKeys.COMPARE_TITLE);
      case PurchaseDialogKind.AUTH_DECLINED:
        return t(d.failed ? TradeKeys.FAILED_TITLE : TradeKeys.DECLINED_TITLE);
      case PurchaseDialogKind.AUTH_UNAVAILABLE:
        return this.errorText(d.textKey, null, d.platform);
      case PurchaseDialogKind.SDK_FAILED:
        return t(TradeKeys.SDK_FAILED_TITLE);
      default:
        // AUTH_CHECK_FAILED、NOTICE（30103 / 30121 / 30151 / 30153 / 50303）：标题就是错误文案（5xxxx 带 trace6）
        return this.errorText(d.textKey, d.traceId, d.platform);
    }
  }

  @Builder
  dialogBody(d: PurchaseDialog) {
    if (d.kind === PurchaseDialogKind.CONFIRM_PRICE) {
      this.priceBody(d)
    } else if (d.kind === PurchaseDialogKind.CONFIRM_REBATE_GONE) {
      this.message(this.rebateGoneBody(d))
    } else if (d.kind === PurchaseDialogKind.COMPARE_NO_REBATE) {
      this.compareBody()
    } else if (d.kind === PurchaseDialogKind.AUTH_DECLINED) {
      this.message(TradeDraftTexts.format(d.failed ? TradeKeys.FAILED_BODY : TradeKeys.DECLINED_BODY, vars(d.platform)))
    } else if (d.kind === PurchaseDialogKind.AUTH_UNAVAILABLE) {
      this.message(t(TradeKeys.UNAVAILABLE_BODY))
    } else if (d.kind === PurchaseDialogKind.SDK_FAILED) {
      this.message(t(TradeKeys.SDK_FAILED_BODY))
    }
  }

  @Builder
  dialogActions(d: PurchaseDialog) {
    if (d.kind === PurchaseDialogKind.CONFIRM_PRICE || d.kind === PurchaseDialogKind.CONFIRM_REBATE_GONE) {
      this.twoButtons(t(TradeKeys.CANCEL), () => this.dismiss(), t(TradeKeys.CONTINUE), () => this.c()?.confirm(), false,
        false, false)
    } else if (d.kind === PurchaseDialogKind.COMPARE_NO_REBATE) {
      this.twoButtons(t(TradeKeys.BUY_NO_REBATE), () => this.c()?.confirm(), t(TradeKeys.COMPARE_SIMILAR),
        () => this.c()?.similar(null), false, false, false)
    } else if (d.kind === PurchaseDialogKind.AUTH_DECLINED) {
      // 42901 限时禁用期间（Retry-After）：会被执行层拦下的按钮同时置灰、读屏报不可用（共性第 19 条，03 §4.2）
      this.twoButtons(t(TradeKeys.BUY_NO_REBATE), () => this.c()?.buyWithoutRebate(), t(TradeKeys.RETRY),
        () => this.c()?.retryPurchase(), true, PurchaseButtons.noRebateDisabled(this.model.state),
        PurchaseButtons.retryDisabled(this.model.state))
    } else if (d.kind === PurchaseDialogKind.AUTH_CHECK_FAILED) {
      // 授权回流查询被限流（H-R1-08）：【重试】视觉与可点都禁用到 Retry-After 到期，【取消】始终可用
      this.twoButtons(t(TradeKeys.CANCEL), () => this.dismiss(), t(TradeKeys.RETRY), () => this.c()?.recheckAuth(), false,
        false, PurchaseButtons.retryDisabled(this.model.state))
    } else if (d.kind === PurchaseDialogKind.NOTICE) {
      this.noticeButtons(d)
    } else {
      CouliButton({ text: t(TradeKeys.OK), variant: CouliButtonVariant.PRIMARY, fullWidth: true,
        buttonId: 'trade_primary', onTap: () => this.dismiss() })
    }
  }

  @Builder
  dialogFrame(d: PurchaseDialog) {
    Column({ space: CouliSpacing.space4 }) {
      Text(this.titleOf(d))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .id('trade_dialog_title')
        .focusable(true)
        .focusBox(CouliFocus.box)
        .width('100%')
        .textAlign(d.kind === PurchaseDialogKind.COMPARE_NO_REBATE ? TextAlign.Center : TextAlign.Start)
        .padding({ left: d.kind === PurchaseDialogKind.COMPARE_NO_REBATE ? 28 : 0,
          right: d.kind === PurchaseDialogKind.COMPARE_NO_REBATE ? 28 : 0 })
        .onAppear(() => this.focusTitle('trade_dialog_title'))
      Scroll() {
        Column({ space: CouliSpacing.space2 }) {
          this.dialogBody(d)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .flexShrink(1)
      .edgeEffect(EdgeEffect.None)
      .scrollBar(BarState.Off)
      Column() {
        this.dialogActions(d)
      }
      .width('100%')
    }
    .padding(CouliSpacing.space5)
    .backgroundColor(CouliColors.backgroundSurface)
    .borderRadius(CouliRadius.card)
    .shadow(CouliShadow.floating)
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth, maxHeight: '90%' })
  }

  /**
   * 一主一次两颗按钮。secondaryDisabled / primaryDisabled：限流期间（Retry-After）置灰且不可点（CouliButton disabled：视觉与读屏
   * 都是不可用）；限流状态变化时弹层按键重建（build 里的 ForEach 键带 rateLimited），按值传入的参数随之更新。
   */
  @Builder
  twoButtons(secondary: string, onSecondary: () => void, primary: string, onPrimary: () => void, stacked: boolean,
    secondaryDisabled: boolean, primaryDisabled: boolean) {
    if (stacked) {
      Column({ space: CouliSpacing.space3 }) {
        CouliButton({ text: primary, variant: CouliButtonVariant.PRIMARY, fullWidth: true, buttonId: 'trade_primary',
          disabled: primaryDisabled, onTap: () => onPrimary() })
        CouliButton({ text: secondary, variant: CouliButtonVariant.SECONDARY, fullWidth: true, buttonId: 'trade_secondary',
          disabled: secondaryDisabled, onTap: () => onSecondary() })
      }
      .width('100%')
    } else {
      // 一主一次并排（次左主右，GUIDE §6）；字号放大放不下时整块换行、主按钮在上
      if (this.wideText(secondary, primary)) {
        Column({ space: CouliSpacing.space3 }) {
          CouliButton({ text: primary, variant: CouliButtonVariant.PRIMARY, fullWidth: true, buttonId: 'trade_primary',
            disabled: primaryDisabled, onTap: () => onPrimary() })
          CouliButton({ text: secondary, variant: CouliButtonVariant.SECONDARY, fullWidth: true, buttonId: 'trade_secondary',
            disabled: secondaryDisabled, onTap: () => onSecondary() })
        }
        .width('100%')
      } else {
        Row({ space: CouliSpacing.space3 }) {
          CouliButton({ text: secondary, variant: CouliButtonVariant.SECONDARY, fullWidth: true, buttonId: 'trade_secondary',
            disabled: secondaryDisabled, onTap: () => onSecondary() })
            .layoutWeight(1)
          CouliButton({ text: primary, variant: CouliButtonVariant.PRIMARY, fullWidth: true, buttonId: 'trade_primary',
            disabled: primaryDisabled, onTap: () => onPrimary() })
            .layoutWeight(1)
        }
        .width('100%')
      }
    }
  }

  @Builder
  priceRow(label: string, amount: string, emphasized: boolean) {
    Row({ space: CouliSpacing.space3 }) {
      Text(label)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .layoutWeight(1)
      Text(amount)
        .attributeModifier(new CouliTextModifier(emphasized ? CouliTypography.body : CouliTypography.footnote,
          CouliColors.textPrimary, emphasized ? CouliFontWeight.bold : undefined))
    }
    .width('100%')
  }

  @Builder
  priceBody(d: PurchaseDialog) {
    Column({ space: CouliSpacing.space3 }) {
      Column({ space: CouliSpacing.space1 }) {
        this.priceRow(TradeDraftTexts.format(TradeKeys.PRICE_BEFORE, this.labelVars(true)),
          d.oldFen === null ? '' : CouliFormat.money(d.oldFen), false)
        // 「现在」一行直接读 this.model.state（不经按值传参的 @Builder）：权威重取补齐券额后口径词随之刷新（H-R1-05）
        Row({ space: CouliSpacing.space3 }) {
          Text(this.nowLabel(d))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
            .layoutWeight(1)
          Text(d.newFen === null ? '' : CouliFormat.money(d.newFen))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.bold))
        }
        .width('100%')
      }
      .padding(CouliSpacing.space3)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.backgroundPlaceholder)
      .width('100%')
      if (d.rebateGone) {
        Row({ space: CouliSpacing.space2 }) {
          CouliIcon({ name: 'alert', iconSize: 20, color: CouliColors.statusWarningText })
          Column({ space: CouliSpacing.space1 }) {
            Text(t(TradeKeys.REBATE_GONE_LINE))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText,
                CouliFontWeight.semibold))
            Text(t(TradeKeys.REBATE_GONE_NOTE))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusWarningText))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .padding(CouliSpacing.space3)
        .borderRadius(CouliRadius.button)
        .backgroundColor(CouliColors.statusWarningBackground)
        .width('100%')
      }
      Text(t(TradeKeys.PRICE_ASK))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .width('100%')
    }
    .width('100%')
  }

  /** 两颗按钮并排放不下（按「字数 × 字号 × 字号倍数」估，弹窗宽按屏宽减边距）就整块换行（同 CouliDialogPanel 的口径）。 */
  private wideText(a: string, b: string): boolean {
    const scale: number = this.fontScale.scale;
    let width: number = 360;
    try {
      width = this.getUIContext().px2vp(display.getDefaultDisplaySync().width);
    } catch (e) {
      width = 360;
    }
    // 大屏限宽（03 §10.4）：弹窗内容最宽 CouliLayout.maxContentWidth
    const panel: number = CouliLayout.dialogContentWidth(width, CouliSpacing.space6) - 2 * CouliSpacing.space5;
    const half: number = (panel - CouliSpacing.space3) / 2;
    const need: number = Math.max(a.length, b.length) * CouliTypography.body.size * scale + 40;
    return need > half;
  }

  private labelVars(before: boolean): Map<string, string> {
    const m: Map<string, string> = new Map<string, string>();
    const c: OpenPurchaseController | null = this.c();
    const s: PurchaseState = this.model.state;
    const card: Record<string, Object> | null = before ? (c === null ? s.card : c.cardBeforeResponse) : s.card;
    m.set('price_label', priceLabel(before ? card : (c === null ? card : c.cardBeforeResponse), s.platform));
    return m;
  }

  /**
   * 「现在」一行的口径（H-R1-05，BR-PRICE-14，共性第 21 条）：coupon_gone 只说明原券失效，新价格可能用了新券，不能推断成无券「售价」。
   * 按同一次结果的最新卡（open 写入、权威重取补齐后的 latest，券后价与弹窗新价一致）的券额定口径词：有券「券后」、无券「售价」
   * （拼多多「拼单券后 / 拼单价」）；券额仍未知时，券失效与普通改价确认都不带口径词（只写「现在」，H-R2-08，共性第 37 条）。
   */
  private nowLabel(d: PurchaseDialog): string {
    const s: PurchaseState = this.model.state;
    const label: string | null = PriceConfirmLabel.now(s.platform, s.latest, d.newFen);
    if (label === null) {
      return t(TradeKeys.PRICE_NOW_PLAIN);
    }
    const m: Map<string, string> = new Map<string, string>();
    m.set('price_label', label);
    return TradeDraftTexts.format(TradeKeys.PRICE_NOW, m);
  }

  @Builder
  message(text: string) {
    Text(text)
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      .width('100%')
  }

  @Builder
  compareBody() {
    Text(t(TradeKeys.COMPARE_BODY))
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
      .width('100%')
    if (this.model.explanation) {
      Text(t(TradeKeys.COMPARE_EXPLAIN))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink, CouliFontWeight.medium))
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .accessibilityRole(AccessibilityRoleType.HYPERLINK)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .onClick(() => this.c()?.viewExplanation())
    }
  }

  @Builder
  bullets(lines: string[]) {
    Column({ space: CouliSpacing.space2 }) {
      ForEach(lines, (line: string) => {
        Row({ space: CouliSpacing.space2 }) {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(CouliColors.textSecondary)
            .margin({ top: 8 })
            .accessibilityLevel('no')
          Text(line)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
      }, (line: string) => line)
    }
    .width('100%')
  }

  private authLines(platform: string): string[] {
    const lines: string[] = [TradeDraftTexts.format(TradeKeys.AUTH_REASON, vars(platform))];
    if (platform === 'taobao') {
      lines.push(t(TradeKeys.AUTH_PRIVACY));
      lines.push(t(TradeKeys.REBIND_NOTE));
    }
    return lines;
  }

  @Builder
  authActions(d: PurchaseDialog) {
    CouliButton({
      text: t(TradeKeys.AUTHORIZE),
      variant: CouliButtonVariant.PRIMARY,
      fullWidth: true,
      loading: d.busy,
      buttonId: 'trade_authorize',
      onTap: () => this.c()?.authorize()
    })
  }

  @Builder
  tipActions(d: PurchaseDialog) {
    CouliButton({
      text: TradeDraftTexts.format(TradeKeys.TIP_GO, vars(d.platform)),
      variant: CouliButtonVariant.PRIMARY,
      fullWidth: true,
      buttonId: 'trade_tip_go',
      onTap: () => this.c()?.confirm()
    })
  }

  /**
   * 半屏（GUIDE §3「半屏」，同 DesignSystem CouliSheetPanel 的版式：把手、标题 → 关闭、正文、操作；上两角 24），按内容定高、贴底。
   * 不直接用 CouliSheetPanel：它的纵向 Flex 在页面内的模态层里会撑满整屏（它是给 bindSheet 承载的）。
   */
  @Builder
  sheet(d: PurchaseDialog) {
    Column() {
      Column({ space: CouliSpacing.space4 }) {
        Row()
          .width(36)
          .height(CouliSpacing.space1)
          .borderRadius(CouliRadius.pill)
          .backgroundColor(CouliColors.borderSubtle)
          .accessibilityLevel('no')
        Row() {
          Text(t(d.kind === PurchaseDialogKind.AUTH_SHEET ? TradeKeys.authTitle(d.platform) : TradeKeys.TIP_TITLE))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
            .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
            .layoutWeight(1)
            .id('trade_sheet_title')
            .focusable(true)
            .focusBox(CouliFocus.box)
            .onAppear(() => this.focusTitle('trade_sheet_title'))
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            CouliIcon({ name: 'close', iconSize: 24, color: CouliColors.textPrimary })
          }
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .margin({ top: -CouliSpacing.space3, bottom: -CouliSpacing.space3, right: -CouliSpacing.space3 })
          .backgroundColor(Color.Transparent)
          .accessibilityText(t(TradeKeys.CLOSE))
          .focusable(true)
          .focusBox(CouliFocus.box)
          .id('trade_sheet_close')
          .onClick(() => this.dismiss())
        }
        .width('100%')
        Scroll() {
          if (d.kind === PurchaseDialogKind.AUTH_SHEET) {
            this.bullets(this.authLines(d.platform))
          } else {
            this.bullets([t(TradeKeys.TIP_LINE_1), t(TradeKeys.TIP_LINE_2)])
          }
        }
        .flexShrink(1)
        .edgeEffect(EdgeEffect.None)
        .scrollBar(BarState.Off)
        if (d.kind === PurchaseDialogKind.AUTH_SHEET) {
          this.authActions(d)
        } else {
          this.tipActions(d)
        }
      }
      .padding({ top: CouliSpacing.space3, left: CouliSpacing.space4, right: CouliSpacing.space4,
        bottom: CouliSpacing.space5 })
      .backgroundColor(CouliColors.backgroundSurface)
      .borderRadius({ topLeft: CouliRadius.panel, topRight: CouliRadius.panel })
      .width('100%')
      // 折叠屏内屏、平板：半屏内容限宽居中（03 §10.4，与已有大屏规范一致），遮罩仍覆盖全窗口
      .constraintSize({ maxWidth: CouliLayout.maxContentWidth, maxHeight: '90%' })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.End)
  }

  @Builder
  centerDialog(d: PurchaseDialog) {
    Column() {
      if (d.kind === PurchaseDialogKind.COMPARE_NO_REBATE) {
        Stack({ alignContent: Alignment.TopEnd }) {
          this.dialogFrame(d)
          this.closeButton()
        }
        .width('100%')
        .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      } else {
        this.dialogFrame(d)
      }
    }
    .padding({ left: CouliSpacing.space6, right: CouliSpacing.space6 })
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  noticeButtons(d: PurchaseDialog) {
    if (d.retry && d.noRebate) {
      this.twoButtons(t(TradeKeys.BUY_NO_REBATE), () => this.c()?.buyWithoutRebate(), t(TradeKeys.RETRY),
        () => this.c()?.retryPurchase(), true, PurchaseButtons.noRebateDisabled(this.model.state),
        PurchaseButtons.retryDisabled(this.model.state))
    } else if (d.noRebate && d.contact) {
      this.twoButtons(t(TradeKeys.CONTACT), () => this.c()?.contactService(), t(TradeKeys.BUY_NO_REBATE),
        () => this.c()?.buyWithoutRebate(), true, false, PurchaseButtons.noRebateDisabled(this.model.state))
    } else if (d.noRebate) {
      this.twoButtons(t(TradeKeys.CANCEL), () => this.dismiss(), t(TradeKeys.BUY_NO_REBATE),
        () => this.c()?.buyWithoutRebate(), true, false, PurchaseButtons.noRebateDisabled(this.model.state))
    } else {
      CouliButton({ text: t(TradeKeys.OK), variant: CouliButtonVariant.PRIMARY, fullWidth: true,
        buttonId: 'trade_primary', onTap: () => this.dismiss() })
    }
  }

  @Builder
  closeButton() {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      CouliIcon({ name: 'close', iconSize: 24, color: CouliColors.textSecondary })
    }
    .width(CouliInteraction.minTouchTarget)
    .height(CouliInteraction.minTouchTarget)
    .margin({ top: CouliSpacing.space1, right: CouliSpacing.space1 })
    .backgroundColor(Color.Transparent)
    .accessibilityText(t(TradeKeys.CLOSE))
    .focusable(true)
    .focusBox(CouliFocus.box)
    .id('trade_dialog_close')
    .onClick(() => this.dismiss())
  }

  private dismiss(): void {
    this.c()?.dismissDialog();
    this.returnFocus();
  }

  private rebateGoneBody(d: PurchaseDialog): string {
    const m: Map<string, string> = new Map<string, string>();
    const c: OpenPurchaseController | null = this.c();
    m.set('price_label', priceLabel(c === null ? this.model.state.card : c.cardBeforeResponse, d.platform));
    m.set('price', d.priceFen === null ? '' : CouliFormat.money(d.priceFen));
    return TradeDraftTexts.format(TradeKeys.REBATE_GONE_BODY, m);
  }

  private errorText(key: string | null, traceId: string | null, platform: string): string {
    const m: Map<string, string> = vars(platform);
    m.set('trace6', traceId === null ? '' : (traceId.length > 6 ? traceId.substring(traceId.length - 6) : traceId));
    const text: string = TradeDraftTexts.format(key ?? TradeKeys.GENERIC, m);
    return traceId === null ? text : withTrace6(text, traceId);
  }

  build() {
    if (this.model.visible) {
      Stack() {
        // 遮罩：点了不关（加载层、确认框都要用户明确选择，adaptation-a11y-spec §4）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(CouliShadowMask.color)
          .accessibilityLevel('no')
          .onClick(() => {
          })
        if (this.model.state.phase === PurchasePhase.LOADING) {
          this.blockingLayer(TradeDraftTexts.format(TradeKeys.OPENING, vars(this.model.state.platform)),
            () => this.c()?.cancelLoading(), 'trade_loading')
        } else if (this.model.state.browserNotice) {
          this.blockingLayer(TradeDraftTexts.format(TradeKeys.BROWSER_NOTICE, vars(this.model.state.platform)),
            () => this.c()?.cancelBrowser(), 'trade_browser_notice')
        } else if (this.model.state.dialog !== null) {
          // 每个弹层对象一个键：换弹层（含 AuthSheet 进入等待）时整块重建，按值传入的参数不会停留在旧对象上
          ForEach([this.model.state.dialog], (d: PurchaseDialog) => {
            if (d.kind === PurchaseDialogKind.AUTH_SHEET || d.kind === PurchaseDialogKind.JUMP_TIP) {
              this.sheet(d)
            } else {
              this.centerDialog(d)
            }
          }, (d: PurchaseDialog) => 'trade-dialog-' + d.seq + (this.model.state.rateLimited ? ':limited' : ''))
        }
      }
      .width('100%')
      .height('100%')
    }
  }
}
