import { KeyboardAvoidMode, LengthMetrics } from '@kit.ArkUI';
import {
  FundPageLayout, PendingView, StepUpController, WalletRecord, WithdrawAmountInput, WithdrawController, WithdrawPhase,
  WithdrawSnapshot
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogOptions,
  CouliFocus, CouliFocusReturn, CouliFontWeight, CouliIcon, CouliInteraction, CouliLayout, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliToast, CouliTypography, ErrorState, NavBar, PriceTerms
} from 'designsystem';
import { StepUpPanel, stepUpWillDismiss } from './StepUpSheet';
import {
  DraftWalletTexts, fmt1, maskedSpoken, money, moneySpoken, PendingAlertCard, RenderBound, WalletLink,
  WalletNoticeBar, WalletTexts
} from './WalletViewKit';

type JSONValue = Object | null;

const ID_SUBMIT: string = 'withdraw_submit';

/** 提现页的出口（entry 接 Router、配置）。 */
export class WithdrawPageConfig {
  readonly controller: WithdrawController;
  texts: WalletTexts = new DraftWalletTexts();
  /** 二次验证半屏的视口高覆盖（vp；0 = 窗口实际高度；只有 Debug / Staging 的截图参数会给）。 */
  stepUpViewport: number = 0;
  onBack: () => void = () => {
  };

  constructor(controller: WithdrawController) {
    this.controller = controller;
  }
}

@ObservedV2
class WithdrawModel {
  @Trace phase: string = WithdrawPhase.LOADING;
  /** 读取内容那一块（FundPageLayout.body）。 */
  @Trace body: string = FundPageLayout.LOADING;
  @Trace version: number = 0;
  @Trace view: WalletRecord | null = null;
  @Trace guide: WalletRecord | null = null;
  @Trace estimate: JSONValue = 'hidden';
  @Trace inputText: string = '';
  @Trace inputValid: boolean = false;
  @Trace payoutLine: string = '';
  @Trace payoutError: string = '';
  @Trace rulesError: string = '';
  @Trace errorText: string = '';
  @Trace bannerText: string = '';
  @Trace pending: PendingView | null = null;
  @Trace pendingBusy: boolean = false;
  @Trace pendingVersion: number = 0;
  @Trace submitBlocked: boolean = false;
  @Trace readBlocked: boolean = false;
  @Trace canSubmit: boolean = false;
  @Trace editable: boolean = true;
  @Trace stepUp: boolean = false;
  @Trace rulesLink: boolean = false;
  @Trace busyElsewhere: boolean = false;
  /** 不合法输入被拒绝时加 1：金额卡按它重建，输入框回到原值。 */
  @Trace inputReset: number = 0;
}

/**
 * 提现申请（Withdraw 路由，不接受任何参数；设计稿 Withdraw、WithdrawRealName、WithdrawCalculating、WithdrawEstimateFailed、WithdrawNoteNet、
 * WithdrawStepUp、WithdrawSubmitting、WithdrawBlocked、WithdrawPending*、WithdrawAbandon*、AdaptKeyboardWithdraw、AdaptNarrowWithdraw、
 * AdaptLargeTextWithdraw、A11yFocusWithdraw）。顺序：待确认卡（alert）→ 可提现余额 → 金额（输入、【全部提现】、上限、档位、估算）→
 * block 引导 → 收款账号 → 时效 → 不能撤销 → 底部【提交】与【提现规则】（键盘弹起时随键盘上移；读屏顺序在内容之后）。
 */
@ComponentV2
export struct WithdrawView {
  @Param @Require config: WithdrawPageConfig;
  @Local model: WithdrawModel = new WithdrawModel();
  @Local stepUpController: StepUpController | null = null;
  private savedAvoidMode: KeyboardAvoidMode | null = null;
  private lastBannerSeq: number = 0;
  private lastNoticeSeq: number = 0;
  private lastRiskSeq: number = 0;
  private lastAnnounce: number = 0;
  private announcePending: boolean = false;
  private lastSubmitted: number = 0;
  private lastPendingKey: string = '';

  aboutToAppear(): void {
    const ui: UIContext = this.getUIContext();
    try {
      this.savedAvoidMode = ui.getKeyboardAvoidMode();
      // 键盘弹起时底部主操作随键盘上移（AdaptKeyboardWithdraw，APP-05b 第 7 条）。
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      this.savedAvoidMode = null;
    }
    this.config.controller.onChange = (s: WithdrawSnapshot): void => this.apply(s);
    this.apply(this.config.controller.snapshot);
  }

  aboutToDisappear(): void {
    const saved: KeyboardAvoidMode | null = this.savedAvoidMode;
    if (saved !== null) {
      try {
        this.getUIContext().setKeyboardAvoidMode(saved);
      } catch (e) {
        // 窗口已销毁时忽略。
      }
    }
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private apply(s: WithdrawSnapshot): void {
    const m: WithdrawModel = this.model;
    const c: WithdrawController = this.config.controller;
    m.phase = s.phase;
    m.version = s.version;
    m.view = c.view();
    m.guide = c.guide();
    m.estimate = s.estimate;
    m.inputText = s.inputText;
    m.inputValid = s.inputFen !== null;
    m.payoutLine = s.payoutLine ?? '';
    m.payoutError = s.payoutError === null ? '' : s.payoutError.text;
    m.rulesError = s.rulesError === null ? '' : s.rulesError.text;
    m.errorText = s.error === null ? '' : s.error.text;
    m.bannerText = s.banner === null ? '' : s.banner.text;
    m.pending = s.pending;
    m.pendingBusy = s.pendingBusy;
    m.pendingVersion = s.pendingVersion;
    m.submitBlocked = s.submitBlocked;
    m.readBlocked = s.readBlocked;
    m.canSubmit = c.canSubmit;
    m.editable = c.editable;
    const layout: FundPageLayout = c.layout();
    m.body = layout.body;
    m.busyElsewhere = layout.busyNotice;
    m.rulesLink = c.rulesAvailable;
    const ui: UIContext = this.getUIContext();
    if (s.banner !== null && s.banner.seq !== this.lastBannerSeq) {
      this.lastBannerSeq = s.banner.seq;
      // 提交失败等：assertive 播报一次。
      CouliAnnounce.say(ui, s.banner.text);
    }
    if (s.notice !== null && s.notice.seq !== this.lastNoticeSeq) {
      this.lastNoticeSeq = s.notice.seq;
      CouliToast.show(ui, s.notice.text);
      CouliAnnounce.say(ui, s.notice.text);
    }
    if (s.riskDialog !== null && s.riskDialog.seq !== this.lastRiskSeq) {
      this.lastRiskSeq = s.riskDialog.seq;
      this.openRiskDialog(s.riskDialog.text);
    }
    const key: string = s.pending === null ? '' : s.pending.key;
    if (key.length > 0 && key !== this.lastPendingKey) {
      // 待确认卡出现：assertive 播报（ArkUI 没有 alert 角色）。
      CouliAnnounce.say(ui, this.t('pending_confirm.title'));
    }
    this.lastPendingKey = key;
    if (s.announceSeq !== this.lastAnnounce) {
      this.lastAnnounce = s.announceSeq;
      this.announcePending = true;
    }
    if (this.announcePending && s.estimate !== 'calculating') {
      // 快捷档位 / 全部提现：播报「提现金额 10 元，预计到账 10 元」（计算中不播报，只读结果）。
      this.announcePending = false;
      CouliAnnounce.say(ui, this.amountAnnouncement(s));
    }
    if (s.submittedSeq !== this.lastSubmitted) {
      this.lastSubmitted = s.submittedSeq;
      // TODO(N-32)：「提现申请已提交，审核中」设计稿标「待商量」。
      CouliAnnounce.say(ui, this.t('withdraw.submitted_announce'));
    }
    if (s.stepUpAction !== null && this.stepUpController === null) {
      this.stepUpController = c.createStepUp();
      m.stepUp = this.stepUpController !== null;
      // 半屏打开期间页面不避让键盘（NONE，由半屏自己按键盘高度布局，R1-11）；关闭后恢复 RESIZE。
      this.pageAvoid(false);
    } else if (s.stepUpAction === null && this.stepUpController !== null) {
      this.stepUpController.close();
      this.stepUpController = null;
      m.stepUp = false;
      this.pageAvoid(true);
    }
  }

  private pageAvoid(resize: boolean): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(resize ? KeyboardAvoidMode.RESIZE : KeyboardAvoidMode.NONE);
    } catch (e) {
      // 窗口不可用时忽略。
    }
  }

  private amountAnnouncement(s: WithdrawSnapshot): string {
    const amount: string = s.inputFen === null ? '' : moneySpoken(s.inputFen);
    const est: string = this.estimateSpoken(s.estimate);
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('amount', amount);
    vars.set('estimate', est);
    return est.length > 0 ? this.config.texts.format('withdraw.estimate_announce', vars)
      : this.t('withdraw.amount_label') + PriceTerms.comma + amount;
  }

  private num(r: WalletRecord, key: string): number {
    const v: JSONValue | undefined = r[key];
    return typeof v === 'number' ? v as number : 0;
  }

  /** 估算行的显示（服务端 est_*，经 CouliFormat；不推算）。 */
  private estimateText(e: JSONValue): string {
    if (e === null || typeof e !== 'object') {
      return e === 'calculating' ? this.t('withdraw.estimate.calculating') : '';
    }
    const r: WalletRecord = e as WalletRecord;
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('net', money(this.num(r, 'net')));
    if (r['key'] === 'withdraw.estimate') {
      vars.set('fee', money(this.num(r, 'fee')));
      vars.set('tax', money(this.num(r, 'tax')));
    }
    return this.config.texts.format(r['key'] as string, vars);
  }

  private estimateSpoken(e: JSONValue): string {
    if (e === null || typeof e !== 'object') {
      return '';
    }
    const r: WalletRecord = e as WalletRecord;
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('net', moneySpoken(this.num(r, 'net')));
    if (r['key'] === 'withdraw.estimate') {
      vars.set('fee', moneySpoken(this.num(r, 'fee')));
      vars.set('tax', moneySpoken(this.num(r, 'tax')));
    }
    return this.config.texts.format(r['key'] as string, vars);
  }

  private openRiskDialog(title: string): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = title;
    options.message = this.t('withdraw.risk_blocked.desc');
    options.primaryText = this.t('withdraw.ok');
    options.secondaryText = this.t('cs.appeal_entry');
    options.dismissOnMask = false;
    options.returnFocusId = ID_SUBMIT;
    options.onPrimary = () => this.config.controller.dismissRisk();
    options.onSecondary = () => this.config.controller.appeal();
    options.onDismissed = () => this.config.controller.dismissRisk();
    CouliDialog.open(this.getUIContext(), options);
  }

  private pendingAmount(p: PendingView): string {
    return p.amountFen === null ? '' : money(p.amountFen);
  }

  private pendingDesc(p: PendingView): string {
    const vars: Map<string, string> = new Map<string, string>();
    if (p.amountFen !== null) {
      vars.set('amount', money(p.amountFen));
    }
    if (this.model.payoutLine.length > 0) {
      vars.set('payout_account', this.model.payoutLine);
    }
    // 取不到收款账号或金额时：fallback 句（上一笔提现还没有收到结果，请先确认）。
    return this.config.texts.format('pending_confirm.withdraw.desc', vars);
  }

  /** 【放弃上一笔提现】的二次确认：绑定按钮构建时的待确认版本与未决键（共性第 4 条）。 */
  private confirmAbandon(bound: RenderBound): void {
    const p: PendingView | null = this.model.pending;
    if (p === null || p.key !== bound.text || this.model.pendingVersion !== bound.version) {
      return;
    }
    const version: number = bound.version;
    const key: string = bound.text;
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('pending_confirm.withdraw.abandon');
    options.message = this.t('pending_confirm.abandon.confirm');
    options.detailLabel = this.t('withdraw.abandon.amount_label');
    options.detailValue = this.pendingAmount(p) + (this.model.payoutLine.length > 0 ? '  ' + this.model.payoutLine : '');
    options.primaryText = this.t('pending_confirm.abandon.ok');
    options.secondaryText = this.t('pending_confirm.abandon.cancel');
    options.dismissOnMask = false;
    options.returnFocusId = 'withdraw_abandon';
    options.onPrimary = () => {
      this.config.controller.abandon(version, key);
    };
    CouliDialog.open(this.getUIContext(), options);
  }

  private helpFeeTax(): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('wallet.help.title.fee_tax');
    options.message = this.t('wallet.help.fee_tax');
    options.primaryText = this.t('wallet.help.ok');
    CouliDialog.open(this.getUIContext(), options);
  }

  private hideKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
      // 没有焦点时忽略。
    }
  }

  /** 待确认卡的构建数据（版本 + 未决键）。 */
  private pendingBound(): RenderBound[] {
    const p: PendingView | null = this.model.pending;
    return p === null ? [] : [new RenderBound(this.model.pendingVersion, p.key)];
  }

  @Builder
  pendingCard(bound: RenderBound) {
    Column({ space: CouliSpacing.space3 }) {
      PendingAlertCard({
        title: this.t('pending_confirm.title'),
        desc: this.pendingDesc(this.model.pending as PendingView)
      })
      Row({ space: CouliSpacing.space3 }) {
        CouliButton({
          text: this.t('pending_confirm.withdraw.abandon'),
          buttonSize: CouliButtonSize.COMPACT,
          fullWidth: true,
          variant: CouliButtonVariant.SECONDARY,
          disabled: this.model.pendingBusy || this.model.submitBlocked || (this.model.pending as PendingView).inFlight,
          buttonId: 'withdraw_abandon',
          onTap: () => this.confirmAbandon(bound)
        })
          .layoutWeight(1)
        CouliButton({
          text: this.t('pending_confirm.withdraw.action'),
          buttonSize: CouliButtonSize.COMPACT,
          fullWidth: true,
          variant: CouliButtonVariant.PRIMARY,
          loading: this.model.pendingBusy,
          disabled: this.model.pendingBusy || this.model.submitBlocked || (this.model.pending as PendingView).inFlight,
          buttonId: 'withdraw_confirm',
          onTap: () => {
            this.config.controller.confirm(bound.version, bound.text);
          }
        })
          .layoutWeight(1)
      }
      .width('100%')
      if (this.model.pendingBusy) {
        Text(this.t('error.40901'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Center }) {
        Text(this.t('withdraw.pending.blocked_hint'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .flexShrink(1)
        WalletLink({
          text: this.t('withdraw.pending.view_records'),
          linkId: 'withdraw_view_records',
          chevron: true,
          onTap: () => this.config.controller.openRecords()
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  @Builder
  balanceCard() {
    Column({ space: CouliSpacing.space1 }) {
      Column({ space: CouliSpacing.space1 }) {
        Text(this.t('withdraw.balance_label'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
        Text(money(this.num((this.model.view as WalletRecord)['balanceLine'] as WalletRecord, 'fen')))
          .attributeModifier(new CouliTextModifier(CouliTypography.display, CouliColors.textPrimary,
            CouliFontWeight.bold, true))
          .wordBreak(WordBreak.NORMAL)
      }
      .alignItems(HorizontalAlign.Start)
      .accessibilityGroup(true)
      .accessibilityText(this.t('withdraw.balance_label') + PriceTerms.comma
        + moneySpoken(this.num((this.model.view as WalletRecord)['balanceLine'] as WalletRecord, 'fen')))
      Text(this.remainingText())
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  private remainingText(): string {
    const r: WalletRecord = (this.model.view as WalletRecord)['remaining'] as WalletRecord;
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('daily', String(this.num(r, 'daily')));
    vars.set('monthly', String(this.num(r, 'monthly')));
    return this.config.texts.format('withdraw.remaining_counts', vars);
  }

  private allFen(): number {
    const v: WalletRecord | null = this.model.view;
    const all: WalletRecord | null = v === null ? null : v['allButton'] as WalletRecord;
    const fen: JSONValue | undefined = all === null ? undefined : all['fen'];
    return typeof fen === 'number' ? fen as number : -1;
  }

  private quickBound(): RenderBound[] {
    return this.quick().map((fen: number): RenderBound => new RenderBound(this.model.version, '', fen));
  }

  private allEnabled(): boolean {
    const v: WalletRecord | null = this.model.view;
    const all: WalletRecord | null = v === null ? null : v['allButton'] as WalletRecord;
    return all !== null && all['enabled'] === true && this.model.editable;
  }

  private quick(): number[] {
    const v: WalletRecord | null = this.model.view;
    const q: JSONValue | undefined = v === null ? undefined : v['quick'];
    return Array.isArray(q) ? q as number[] : [];
  }

  private maxLine(): string {
    const v: WalletRecord | null = this.model.view;
    const line: JSONValue | undefined = v === null ? undefined : v['maxLine'];
    if (line === null || line === undefined || typeof line !== 'object') {
      return '';
    }
    return fmt1(this.config.texts, 'withdraw.max_line', 'amount', money(this.num(line as WalletRecord, 'fen')));
  }

  @Builder
  amountCard() {
    Column({ space: CouliSpacing.space3 }) {
      Text(this.t('withdraw.amount_label'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      Row({ space: CouliSpacing.space3 }) {
        Row({ space: CouliSpacing.space2 }) {
          Text(this.t('withdraw.currency'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
            .accessibilityLevel('no')
          TextInput({ text: this.model.inputText,
            placeholder: this.model.editable ? '' : this.t('withdraw.realname_locked') })
            .type(InputType.NUMBER_DECIMAL)
            .maxLength(12)
            .fontSize(24)
            .fontWeight(CouliFontWeight.bold)
            .backgroundColor(Color.Transparent)
            .padding(0)
            .layoutWeight(1)
            .enabled(this.model.editable)
            .id('withdraw_amount')
            .accessibilityText(this.t('withdraw.amount_label'))
            .onChange((value: string) => {
              if (!this.config.controller.setInput(value)) {
                // 不合法整段不接受：输入框回到原值（按键重建输入框）。
                this.model.inputReset++;
              }
            })
        }
        .layoutWeight(1)
        .constraintSize({ minHeight: 56 })
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
        .borderRadius(CouliRadius.button)
        .border({ width: 1, color: CouliColors.borderControl })
        .backgroundColor(this.model.editable ? CouliColors.backgroundSurface : CouliColors.backgroundMuted)
        ForEach([new RenderBound(this.model.version, '', this.allFen())], (bound: RenderBound) => {
          WalletLink({
            text: this.t('withdraw.all'),
            linkId: 'withdraw_all',
            disabled: !this.allEnabled(),
            onTap: () => {
              // 绑定构建时的版本与金额：旧画面的按钮不能填入新 rules 的金额（共性第 4 条）。
              this.config.controller.fillAll(bound.version, bound.num);
            }
          })
        }, (bound: RenderBound) => 'withdraw_all_' + bound.id + '_' + this.allEnabled())
      }
      .width('100%')
      if (this.maxLine().length > 0) {
        Text(this.maxLine())
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
      if (this.quick().length > 0) {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(CouliSpacing.space2),
          cross: LengthMetrics.vp(CouliSpacing.space2) } }) {
          ForEach(this.quickBound(), (bound: RenderBound) => {
            Text(money(bound.num))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary, undefined, true))
              .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: 64 })
              .textAlign(TextAlign.Center)
              .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4 })
              .borderRadius(CouliRadius.pill)
              .border({ width: 1, color: CouliColors.borderSubtle })
              .backgroundColor(this.model.editable ? CouliColors.backgroundSurface : CouliColors.backgroundMuted)
              .accessibilityText(moneySpoken(bound.num))
              .accessibilityRole(AccessibilityRoleType.BUTTON)
              .enabled(this.model.editable)
              .focusable(true)
              .focusBox(CouliFocus.box)
              .id('withdraw_quick_' + bound.num)
              .onClick(() => {
                this.config.controller.fillQuick(bound.num, bound.version);
              })
          }, (bound: RenderBound) => 'q' + bound.id + '_' + this.model.editable)
        }
        .width('100%')
      }
      if (this.estimateText(this.model.estimate).length > 0) {
        Divider().color(CouliColors.borderSubtle)
        Row({ space: CouliSpacing.space1 }) {
          Text(this.estimateText(this.model.estimate))
            .attributeModifier(new CouliTextModifier(CouliTypography.body,
              this.model.estimate === 'calculating' ? CouliColors.textSecondary : CouliColors.textPrimary, undefined, true))
            .flexShrink(1)
            .id('withdraw_estimate')
            // 「计算中」不播报，只读结果。
            .accessibilityLevel(this.model.estimate === 'calculating' ? 'no' : 'auto')
          if (this.model.estimate !== 'calculating') {
            Button({ type: ButtonType.Normal, stateEffect: true }) {
              CouliIcon({ name: 'help', iconSize: 16, color: CouliColors.textSecondary })
            }
            .width(CouliInteraction.minTouchTarget)
            .height(CouliInteraction.minTouchTarget)
            .margin({ top: -12, bottom: -12, left: -12 })
            .backgroundColor(Color.Transparent)
            .accessibilityText(this.t('wallet.help.label.fee_tax'))
            .focusable(true)
            .focusBox(CouliFocus.box)
            .onClick(() => this.helpFeeTax())
          }
        }
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  private guideBound(): RenderBound[] {
    const g: WalletRecord | null = this.model.guide;
    const route: JSONValue | undefined = g === null ? undefined : g['route'];
    return [new RenderBound(this.model.version, typeof route === 'string' ? route as string : '')];
  }

  @Builder
  guideCard() {
    Column({ space: CouliSpacing.space3 }) {
      Text(this.t((this.model.guide as WalletRecord)['textKey'] as string))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.statusWarningText))
        .width('100%')
        .id('withdraw_guide_text')
      if (typeof (this.model.guide as WalletRecord)['buttonKey'] === 'string') {
        ForEach(this.guideBound(), (bound: RenderBound) => {
          CouliButton({
            text: this.t((this.model.guide as WalletRecord)['buttonKey'] as string),
            variant: CouliButtonVariant.SECONDARY,
            buttonSize: CouliButtonSize.COMPACT,
            buttonId: 'withdraw_guide_button',
            onTap: () => {
              this.config.controller.openGuide(bound.version, bound.text);
            }
          })
        }, (bound: RenderBound) => 'withdraw_guide_' + bound.id)
      }
      if ((this.model.guide as WalletRecord)['rulesLink'] === true && this.model.rulesLink) {
        WalletLink({
          text: this.t('withdraw.rules_link'),
          linkId: 'withdraw_guide_rules',
          onTap: () => {
            this.config.controller.openRules();
          }
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.statusWarningBackground)
  }

  @Builder
  payoutRow() {
    Row({ space: CouliSpacing.space2 }) {
      Text(this.t('withdraw.payout_label'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      Text(this.model.payoutLine)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
        .wordBreak(WordBreak.NORMAL)
        .textAlign(TextAlign.End)
        .layoutWeight(1)
      CouliIcon({ name: 'chevron', iconSize: 16, color: CouliColors.textSecondary })
        .accessibilityLevel('no')
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space3, top: CouliSpacing.space3,
      bottom: CouliSpacing.space3 })
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
    .id('withdraw_payout_row')
    .accessibilityGroup(true)
    .accessibilityText(this.t('withdraw.payout_label') + PriceTerms.comma + maskedSpoken(this.model.payoutLine,
      this.t('wallet.star')))
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => this.config.controller.openPayout())
  }

  @Builder
  stepUpSheet() {
    if (this.stepUpController !== null) {
      StepUpPanel({
        controller: this.stepUpController as StepUpController,
        texts: this.config.texts,
        viewportOverride: this.config.stepUpViewport,
        onClose: () => {
          this.closeStepUp();
        }
      })
    }
  }

  private closeStepUp(): void {
    if (this.stepUpController !== null) {
      this.stepUpController.close();
      this.stepUpController = null;
    }
    this.model.stepUp = false;
    this.pageAvoid(true);
    this.config.controller.stepUpClosed();
  }

  /** 待确认卡与「别处在途」提示：独立于 rules 与收款账号的读取状态（rules 失败、加载中也显示，R1-02，共性第 2 条）。 */
  @Builder
  pendingSection() {
    ForEach(this.pendingBound(), (bound: RenderBound) => {
      this.pendingCard(bound)
    }, (bound: RenderBound) => 'withdraw_pending_' + bound.id)
    if (this.model.busyElsewhere && this.model.pending === null) {
      WalletNoticeBar({ text: this.t('error.40901'), tone: 'info', barId: 'withdraw_busy' })
    }
  }

  @Builder
  content() {
    Column({ space: CouliSpacing.space3 }) {
      if (this.model.bannerText.length > 0) {
        WalletNoticeBar({ text: this.model.bannerText, tone: 'error', barId: 'withdraw_banner' })
      }
      if (this.model.rulesError.length > 0) {
        // 已有 rules 时重取失败（5xxxx 带 trace6）：常驻提示 +【重试】（共性第 30 条）。
        WalletNoticeBar({
          text: this.model.rulesError + '\n' + this.t('wallet.retry'),
          tone: 'error',
          barId: 'withdraw_rules_error',
          tappable: !this.model.readBlocked,
          onTap: () => {
            this.config.controller.retryRules();
          }
        })
      }
      this.pendingSection()
      this.balanceCard()
      ForEach([this.model.version], (_v: number) => {
        this.amountCard()
      }, (_v: number) => 'withdraw_amount_' + this.model.editable + '_' + (this.model.pending !== null) + '_'
        + this.model.inputReset)
      if (this.model.guide !== null && (this.model.guide as WalletRecord)['actionRaw'] !== 'none') {
        this.guideCard()
      }
      if (this.model.payoutLine.length > 0) {
        this.payoutRow()
      } else if (this.model.payoutError.length > 0) {
        // 收款账号读取失败（42901 / 5xxxx 带 trace6 / 断网）：在收款账号行的位置提示，点按重试（R1-03）。
        WalletNoticeBar({
          text: this.model.payoutError + '\n' + this.t('wallet.retry'),
          tone: 'error',
          barId: 'withdraw_payout_error',
          tappable: !this.model.readBlocked,
          onTap: () => {
            this.config.controller.retryPayout();
          }
        })
      }
      WalletNoticeBar({
        text: (this.model.view as WalletRecord)['slaKeyOrText'] as string,
        tone: 'info',
        barId: 'withdraw_sla'
      })
      Text(this.t('withdraw.no_cancel'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .width('100%')
        .padding({ left: CouliSpacing.space1 })
    }
    .padding(CouliSpacing.space4)
    .width('100%')
    .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
  }

  build() {
      Column() {
        NavBar({ title: this.t('withdraw.title'), backLabel: this.t('wallet.back'),
          onBack: () => this.config.onBack() })
          .backgroundColor(CouliColors.backgroundCanvas)
        if (this.model.body === FundPageLayout.IDLE) {
          Column().layoutWeight(1)
        } else if (this.model.body !== FundPageLayout.CONTENT || this.model.view === null) {
          // rules 还没取到或读取失败：待确认卡照常显示（确认、放弃按各自闸门与在途状态可用），读取失败只影响 rules 区域（R1-02）。
          Scroll() {
            Column({ space: CouliSpacing.space3 }) {
              if (this.model.bannerText.length > 0) {
                WalletNoticeBar({ text: this.model.bannerText, tone: 'error', barId: 'withdraw_banner' })
              }
              this.pendingSection()
              if (this.model.body === FundPageLayout.ERROR) {
                ErrorState({
                  title: this.model.errorText,
                  retryText: this.t('wallet.retry'),
                  retryId: 'withdraw_retry',
                  retryDisabled: this.model.readBlocked,
                  onRetry: () => {
                    this.config.controller.retry();
                  }
                })
              } else {
                Column() {
                  LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
                }
                .width('100%')
                .padding(CouliSpacing.space8)
              }
            }
            .padding(CouliSpacing.space4)
            .width('100%')
            .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
          }
          .layoutWeight(1)
          .width('100%')
          .align(this.model.pending === null ? Alignment.Center : Alignment.Top)
          .scrollBar(BarState.Off)
        } else {
          Scroll() {
            this.content()
          }
          .layoutWeight(1)
          .width('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // 底部主操作：视觉贴底，读屏顺序在内容之后。
          Column({ space: CouliSpacing.space1 }) {
            CouliButton({
              text: this.model.phase === WithdrawPhase.SUBMITTING ? this.t('withdraw.submitting') : this.t('withdraw.submit'),
              fullWidth: true,
              loading: this.model.phase === WithdrawPhase.SUBMITTING,
              disabled: !this.model.canSubmit,
              buttonId: ID_SUBMIT,
              onTap: () => {
                // 【提交】先收起键盘，再进入二次验证或提交中。
                this.hideKeyboard();
                this.config.controller.submit();
              }
            })
            if (this.model.rulesLink) {
              WalletLink({
                text: this.t('withdraw.rules_link'),
                linkId: 'withdraw_rules',
                onTap: () => {
                  this.config.controller.openRules();
                }
              })
            }
          }
          .width('100%')
          .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
          .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
            bottom: CouliSpacing.space2 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(CouliColors.backgroundCanvas)
      .bindSheet(this.model.stepUp, this.stepUpSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: true,
        showClose: false,
        backgroundColor: CouliColors.backgroundSurface,
        // 半屏自己不避让键盘（R1-11）：StepUpPanel 按键盘后的可用高度布局（标题与按钮固定，只有中段滚动）。
        keyboardAvoidMode: SheetKeyboardAvoidMode.NONE,
      onWillDismiss: (action: DismissSheetAction) => stepUpWillDismiss(action),
        onWillSpringBackWhenDismiss: (action: SpringBackAction) => {
          action.springBack();
        },
        onDisappear: () => {
          if (this.model.stepUp) {
            this.closeStepUp();
          }
          // 关闭后焦点回到【提交】（A11yFocusStepUp）。
          CouliFocusReturn.to(this.getUIContext(), ID_SUBMIT);
        }
      })
  }
}

/** 进程回收后恢复用：已输入金额的文本是否合法（只恢复金额，不恢复估算）。 */
export function withdrawInputRestorable(text: string): boolean {
  return WithdrawAmountInput.accept(text) !== null;
}

