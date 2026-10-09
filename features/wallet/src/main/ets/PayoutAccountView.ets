import { KeyboardAvoidMode, LengthMetrics } from '@kit.ArkUI';
import {
  FundPageLayout, PayoutAccountController, PayoutAccountForm, PayoutAccountView as PayoutAccountDisplay, PayoutPhase,
  PayoutSnapshot, PendingView,
  StepUpController, WalletMessage, WalletRecord
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonSize, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogOptions, CouliFocus,
  CouliFocusReturn, CouliFontWeight, CouliInteraction, CouliLayout, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliToast, CouliTypography, ErrorState, NavBar, PriceTerms
} from 'designsystem';
import { StepUpPanel, stepUpWillDismiss } from './StepUpSheet';
import {
  DraftWalletTexts, firstErrorField, fmt1, maskedSpoken, PendingAlertCard, RenderBound, scrollToComponent,
  WalletKeyValueRow, WalletNoticeBar, WalletTexts
} from './WalletViewKit';

/** 表单字段的显示顺序（字段错误时取第一个）。 */
const PAYOUT_FIELD_ORDER: string[] = PayoutAccountForm.FIELD_ORDER;

type JSONValue = Object | null;

const ID_SAVE: string = 'payout_save';

export class PayoutPageConfig {
  readonly controller: PayoutAccountController;
  texts: WalletTexts = new DraftWalletTexts();
  /** 二次验证半屏的视口高覆盖（vp；0 = 窗口实际高度；只有 Debug / Staging 的截图参数会给）。 */
  stepUpViewport: number = 0;
  onBack: () => void = () => {
  };

  constructor(controller: PayoutAccountController) {
    this.controller = controller;
  }
}

@ObservedV2
class PayoutModel {
  @Trace phase: string = PayoutPhase.LOADING;
  @Trace body: string = FundPageLayout.LOADING;
  @Trace pendingCard: boolean = false;
  @Trace version: number = 0;
  @Trace account: WalletRecord | null = null;
  @Trace method: string = 'alipay';
  @Trace logon: string = '';
  @Trace cardNo: string = '';
  @Trace bankName: string = '';
  @Trace payee: string = '';
  @Trace fieldErrors: Map<string, string> = new Map<string, string>();
  @Trace errorText: string = '';
  @Trace bannerText: string = '';
  @Trace pending: PendingView | null = null;
  @Trace pendingBusy: boolean = false;
  @Trace pendingVersion: number = 0;
  @Trace saveBlocked: boolean = false;
  @Trace readBlocked: boolean = false;
  @Trace canSave: boolean = false;
  @Trace stepUp: boolean = false;
  @Trace busyElsewhere: boolean = false;
  @Trace inputReset: number = 0;
}

/**
 * 收款账号（PayoutAccount 路由，不接受任何参数；设计稿 PayoutAccount、PayoutAccountBank、PayoutAccountBound、PayoutAccountBoundBank、
 * PayoutAccountBlocked、PayoutAccountPending*）。已绑定只显示服务端脱敏字段；表单只有支付宝与本人借记卡（G14），开户行由用户填写
 * （G12，与设计稿「按卡号自动识别」不同）；保存需要短信验证（首次绑定也要）。待确认摘要按 G15 本机脱敏。
 */
@ComponentV2
export struct PayoutAccountPage {
  @Param @Require config: PayoutPageConfig;
  @Local model: PayoutModel = new PayoutModel();
  @Local stepUpController: StepUpController | null = null;
  private savedAvoidMode: KeyboardAvoidMode | null = null;
  private readonly formScroller: Scroller = new Scroller();
  private lastBannerSeq: number = 0;
  private lastNoticeSeq: number = 0;
  private lastRiskSeq: number = 0;
  private lastFieldSeq: number = 0;
  private lastPendingKey: string = '';

  aboutToAppear(): void {
    const ui: UIContext = this.getUIContext();
    try {
      this.savedAvoidMode = ui.getKeyboardAvoidMode();
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      this.savedAvoidMode = null;
    }
    this.config.controller.onChange = (s: PayoutSnapshot): void => this.apply(s);
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

  private apply(s: PayoutSnapshot): void {
    const m: PayoutModel = this.model;
    const c: PayoutAccountController = this.config.controller;
    m.phase = s.phase;
    m.version = s.version;
    m.account = s.account;
    m.method = s.form.method;
    m.logon = s.form.alipayLogonId;
    m.cardNo = s.form.cardNo;
    m.bankName = s.form.bankName;
    m.payee = s.form.payeeName;
    const errors: Map<string, string> = new Map<string, string>();
    s.fieldErrors.forEach((v: WalletMessage, k: string) => {
      errors.set(k, v.text);
    });
    m.fieldErrors = errors;
    m.errorText = s.error === null ? '' : s.error.text;
    m.bannerText = s.banner === null ? '' : s.banner.text;
    m.pending = s.pending;
    m.pendingBusy = s.pendingBusy;
    m.pendingVersion = s.pendingVersion;
    m.saveBlocked = s.saveBlocked;
    m.readBlocked = s.readBlocked;
    m.canSave = c.canSave;
    const layout: FundPageLayout = c.layout();
    m.body = layout.body;
    m.pendingCard = layout.pendingCard;
    m.busyElsewhere = layout.busyNotice;
    const ui: UIContext = this.getUIContext();
    if (s.banner !== null && s.banner.seq !== this.lastBannerSeq) {
      this.lastBannerSeq = s.banner.seq;
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
    if (s.fieldErrorSeq !== this.lastFieldSeq) {
      this.lastFieldSeq = s.fieldErrorSeq;
      // 字段错误：即时播报一次，焦点移到第一个出错的输入框（保留输入，APP-05b 第 6 条）。
      const first: string | undefined = firstErrorField(PAYOUT_FIELD_ORDER, errors);
      if (first !== undefined) {
        CouliAnnounce.say(ui, errors.get(first) ?? '');
        setTimeout(() => {
          // 滚到首个出错字段并移焦点（共性第 24 条），保留输入。
          // 收款方式组没有输入框：焦点落到当前选中的选项（R3-03，共性第 36 条）。
          const target: string = PayoutAccountForm.errorFocusId(first, this.model.method);
          scrollToComponent(ui, this.formScroller, 'payout_scroll', target);
          try {
            ui.getFocusController().requestFocus(target);
          } catch (e) {
            // 输入框尚未出现时忽略。
          }
        }, 0);
      }
    }
    const key: string = s.pending === null ? '' : s.pending.key;
    if (key.length > 0 && key !== this.lastPendingKey) {
      CouliAnnounce.say(ui, this.t('pending_confirm.title'));
    }
    this.lastPendingKey = key;
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

  private openRiskDialog(title: string): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = title;
    options.message = this.t('payout_account.blocked_desc');
    options.primaryText = this.t('withdraw.ok');
    options.secondaryText = this.t('cs.appeal_entry');
    options.dismissOnMask = false;
    options.returnFocusId = ID_SAVE;
    options.onPrimary = () => this.config.controller.dismissRisk();
    options.onSecondary = () => this.config.controller.appeal();
    options.onDismissed = () => this.config.controller.dismissRisk();
    CouliDialog.open(this.getUIContext(), options);
  }

  private pendingAccount(p: PendingView): string {
    const summary: WalletRecord | null = p.summary;
    if (summary === null || typeof summary['account'] !== 'string') {
      return '';
    }
    const method: JSONValue | undefined = summary['payout_method'];
    const prefix: string = method === 'alipay' ? this.t('payout_account.alipay') + ' ' : '';
    return prefix + (summary['account'] as string);
  }

  private pendingPayee(p: PendingView): string {
    const summary: WalletRecord | null = p.summary;
    return summary !== null && typeof summary['payee'] === 'string' ? summary['payee'] as string : '';
  }

  private pendingDesc(p: PendingView): string {
    const account: string = this.pendingAccount(p);
    const vars: Map<string, string> = new Map<string, string>();
    if (account.length > 0) {
      vars.set('payout_account', account);
    }
    return this.config.texts.format('pending_confirm.payout_account.desc', vars);
  }

  /** 【放弃上一笔】的二次确认：绑定按钮构建时的待确认版本与未决键（共性第 4 条）。 */
  private confirmAbandon(bound: RenderBound): void {
    const p: PendingView | null = this.model.pending;
    if (p === null || p.key !== bound.text || this.model.pendingVersion !== bound.version) {
      return;
    }
    const version: number = bound.version;
    const key: string = bound.text;
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('pending_confirm.abandon');
    options.message = this.t('pending_confirm.abandon.confirm') + '\n' + this.t('payout_account.abandon.note');
    options.detailLabel = this.t('payout_account.pending.submitted');
    options.detailValue = this.pendingAccount(p);
    options.primaryText = this.t('pending_confirm.abandon.ok');
    options.secondaryText = this.t('pending_confirm.abandon.cancel');
    options.dismissOnMask = false;
    options.returnFocusId = 'payout_abandon';
    options.onPrimary = () => {
      this.config.controller.abandon(version, key);
    };
    CouliDialog.open(this.getUIContext(), options);
  }

  private display(): WalletRecord | null {
    const a: WalletRecord | null = this.model.account;
    return a === null ? null : PayoutAccountDisplay.of(a);
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

  private pendingBound(): RenderBound[] {
    const p: PendingView | null = this.model.pending;
    return p === null ? [] : [new RenderBound(this.model.pendingVersion, p.key)];
  }

  /** 待确认卡与「别处在途」提示：独立于收款账号读取状态（读取失败、加载中也显示，R1-02，共性第 2 条）。 */
  @Builder
  pendingSection() {
    if (this.model.busyElsewhere && this.model.pending === null) {
      WalletNoticeBar({ text: this.t('error.40901'), tone: 'info', barId: 'payout_busy' })
    }
    ForEach(this.pendingBound(), (bound: RenderBound) => {
      this.pendingCard(bound)
    }, (bound: RenderBound) => 'payout_pending_' + bound.id)
  }

  @Builder
  errorBlock() {
    Column({ space: CouliSpacing.space3 }) {
      ErrorState({
        title: this.model.errorText,
        retryText: this.t('wallet.retry'),
        retryId: 'payout_retry',
        retryDisabled: this.model.readBlocked,
        onRetry: () => {
          this.config.controller.retry();
        }
      })
      if (this.model.errorText === this.t('error.30304')) {
        CouliButton({
          text: this.t('withdraw.guide.realname'),
          variant: CouliButtonVariant.SECONDARY,
          buttonId: 'payout_realname',
          onTap: () => this.config.controller.openRealName()
        })
      }
    }
    .width('100%')
  }

  @Builder
  pendingCard(bound: RenderBound) {
    Column({ space: CouliSpacing.space3 }) {
      PendingAlertCard({
        title: this.t('pending_confirm.title'),
        desc: this.pendingDesc(this.model.pending as PendingView)
      })
      Column() {
        WalletKeyValueRow({ label: this.t('payout_account.pending.submitted'),
          value: this.pendingAccount(this.model.pending as PendingView),
          spoken: maskedSpoken(this.pendingAccount(this.model.pending as PendingView), this.t('wallet.star')) })
        WalletKeyValueRow({ label: this.t('payout_account.payee_label'),
          value: this.pendingPayee(this.model.pending as PendingView),
          spoken: maskedSpoken(this.pendingPayee(this.model.pending as PendingView), this.t('wallet.star')) })
      }
      .width('100%')
      .padding(CouliSpacing.space3)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.backgroundMuted)
      Row({ space: CouliSpacing.space3 }) {
        CouliButton({
          text: this.t('pending_confirm.abandon'),
          buttonSize: CouliButtonSize.COMPACT,
          fullWidth: true,
          variant: CouliButtonVariant.SECONDARY,
          disabled: this.model.pendingBusy || this.model.saveBlocked || (this.model.pending as PendingView).inFlight,
          buttonId: 'payout_abandon',
          onTap: () => this.confirmAbandon(bound)
        })
          .layoutWeight(1)
        CouliButton({
          text: this.t('pending_confirm.payout_account.action'),
          buttonSize: CouliButtonSize.COMPACT,
          fullWidth: true,
          loading: this.model.pendingBusy,
          disabled: this.model.pendingBusy || this.model.saveBlocked || (this.model.pending as PendingView).inFlight,
          buttonId: 'payout_confirm',
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
      Text(this.t('payout_account.pending.blocked_hint'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .width('100%')
    }
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  @Builder
  boundCard(version: number) {
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space2 }) {
        Text(this.t('payout_account.current'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .layoutWeight(1)
        Text(this.methodLabel())
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .padding({ left: CouliSpacing.space2, right: CouliSpacing.space2, top: 2, bottom: 2 })
          .borderRadius(CouliRadius.pill)
          .backgroundColor(CouliColors.backgroundMuted)
      }
      .width('100%')
      Text(this.accountLine())
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary,
          CouliFontWeight.semibold, true))
        .wordBreak(WordBreak.BREAK_ALL)
        .accessibilityText(maskedSpoken(this.accountLine(), this.t('wallet.star')))
      Divider().color(CouliColors.borderSubtle)
      if ((this.display() as WalletRecord)['known'] === true) {
        WalletKeyValueRow({ label: this.t('payout_account.payee_label'),
          value: (this.display() as WalletRecord)['maskedPayee'] as string ?? '',
          spoken: maskedSpoken((this.display() as WalletRecord)['maskedPayee'] as string ?? '', this.t('wallet.star')) })
        WalletKeyValueRow({ label: this.t('payout_account.change_remaining'),
          value: fmt1(this.config.texts, 'payout_account.times', 'n',
            String((this.display() as WalletRecord)['changeRemaining'] as number)) })
        CouliButton({
          text: this.t('payout_account.change'),
          variant: CouliButtonVariant.SECONDARY,
          fullWidth: true,
          disabled: this.model.pending !== null || this.model.phase !== PayoutPhase.VIEW,
          buttonId: 'payout_change',
          onTap: () => {
            // 绑定构建时的版本（共性第 4 条）。
            this.config.controller.startChange(version);
          }
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(CouliSpacing.space4)
    .borderRadius(CouliRadius.card)
    .backgroundColor(CouliColors.backgroundSurface)
  }

  private methodLabel(): string {
    const d: WalletRecord | null = this.display();
    const method: JSONValue | undefined = d === null ? null : d['methodRaw'];
    if (method === 'alipay') {
      return this.t('payout_account.alipay');
    }
    return method === 'bank_card' ? this.t('payout_account.bank_label') : this.t('payout_account.other_method');
  }

  private accountLine(): string {
    const d: WalletRecord | null = this.display();
    if (d === null) {
      return '';
    }
    const masked: string = d['maskedAccount'] as string ?? '';
    const bank: JSONValue | undefined = d['bankName'];
    return typeof bank === 'string' && (bank as string).length > 0 && masked.indexOf(bank as string) < 0
      ? (bank as string) + ' ' + masked : masked;
  }

  @Builder
  methodOption(method: string, title: string, hint: string) {
    Row({ space: CouliSpacing.space3 }) {
      Radio({ value: method, group: 'payout_method' })
        .checked(this.model.method === method)
        .width(24)
        .height(24)
        .radioStyle({ checkedBackgroundColor: CouliColors.brandPrimary })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
      Column({ space: 2 }) {
        Text(title)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary,
            CouliFontWeight.semibold))
        Text(hint)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
    .padding({ top: CouliSpacing.space2, bottom: CouliSpacing.space2 })
    .id('payout_method_' + method)
    .accessibilityGroup(true)
    .accessibilityText(title + PriceTerms.comma + hint)
    .accessibilityRole(AccessibilityRoleType.RADIO)
    .accessibilityChecked(this.model.method === method)
    // 收款方式组的字段错误（R3-03）：读屏在选项上读出原因。
    .accessibilityDescription(this.model.fieldErrors.get('payout_method') ?? '')
    .focusable(true)
    .focusBox(CouliFocus.box)
    .onClick(() => this.config.controller.setMethod(method))
  }

  private fieldValue(name: string): string {
    switch (name) {
      case 'alipay_logon_id':
        return this.model.logon;
      case 'card_no':
        return this.model.cardNo;
      case 'bank_name':
        return this.model.bankName;
      default:
        return this.model.payee;
    }
  }

  @Builder
  field(name: string, label: string, value: string, placeholder: string, type: InputType, max: number) {
    Column({ space: CouliSpacing.space2 }) {
      Text(label)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      // @Builder 的参数按值传递（鸿蒙 H22）：输入框的值按字段名现取页面状态。
      TextInput({ text: this.fieldValue(name), placeholder: placeholder })
        .type(type)
        .maxLength(max)
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .borderRadius(CouliRadius.button)
        .border({ width: 1, color: this.model.fieldErrors.has(name) ? CouliColors.statusErrorText
          : CouliColors.borderControl })
        .backgroundColor(CouliColors.backgroundSurface)
        .id('payout_' + name)
        .accessibilityText(label)
        .accessibilityDescription(this.model.fieldErrors.get(name) ?? '')
        .onChange((v: string) => {
          if (!this.config.controller.setField(name, v)) {
            this.model.inputReset++;
          }
        })
      if (this.model.fieldErrors.has(name)) {
        Text(this.model.fieldErrors.get(name) ?? '')
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .id('payout_' + name + '_error')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  form() {
    Column({ space: CouliSpacing.space3 }) {
      Column() {
        Text(this.t('payout_account.method'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          .width('100%')
        this.methodOption('alipay', this.t('payout_account.alipay'), this.t('payout_account.alipay_hint'))
        Divider().color(CouliColors.borderSubtle)
        this.methodOption('bank_card', this.t('payout_account.bank'), this.t('payout_account.bank_hint'))
        if (this.model.fieldErrors.has('payout_method')) {
          // 收款方式组的字段错误（如服务端关闭了所选方式，20001 fields=[payout_method]）：在组内可见显示（R3-03，G14）。
          Text(this.model.fieldErrors.get('payout_method') ?? '')
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
            .width('100%')
            .id('payout_payout_method_error')
        }
      }
      .width('100%')
      .id('payout_payout_method')
      .padding(CouliSpacing.space4)
      .borderRadius(CouliRadius.card)
      .backgroundColor(CouliColors.backgroundSurface)
      ForEach([this.model.inputReset], (_r: number) => {
        Column({ space: CouliSpacing.space3 }) {
          if (this.model.method === 'alipay') {
            this.field('alipay_logon_id', this.t('payout_account.alipay_account'), this.model.logon,
              this.t('payout_account.alipay_placeholder'), InputType.Normal, 128)
          } else {
            this.field('card_no', this.t('payout_account.card_no'), this.model.cardNo,
              this.t('payout_account.card_placeholder'), InputType.Normal, 32)
            this.field('bank_name', this.t('payout_account.bank_name'), this.model.bankName,
              this.t('payout_account.bank_name_placeholder'), InputType.Normal, 64)
          }
          this.field('payee_name', this.t('payout_account.payee'), this.model.payee,
            this.t('payout_account.payee_placeholder'), InputType.Normal, 64)
          Text(this.t('payout_account.payee_hint'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(CouliSpacing.space4)
        .borderRadius(CouliRadius.card)
        .backgroundColor(CouliColors.backgroundSurface)
      }, (r: number) => 'payout_fields_' + r + '_' + this.model.method)
      WalletNoticeBar({
        text: this.t(this.model.method === 'bank_card' ? 'payout_account.bank_sms_hint' : 'payout_account.sms_hint'),
        tone: 'info',
        barId: 'payout_sms_hint'
      })
    }
    .width('100%')
  }

  build() {
    Column() {
      NavBar({ title: this.t('payout_account.title'), backLabel: this.t('wallet.back'),
        onBack: () => this.config.onBack() })
        .backgroundColor(CouliColors.backgroundCanvas)
      if (this.model.body === FundPageLayout.IDLE) {
        Column().layoutWeight(1)
      } else if (this.model.body === FundPageLayout.LOADING && !this.model.pendingCard) {
        Column() {
          LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.model.body === FundPageLayout.ERROR && !this.model.pendingCard) {
        Column() {
          this.errorBlock()
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.model.body !== FundPageLayout.CONTENT) {
        // 读取失败（或加载中）也显示待确认卡：确认与放弃按各自闸门、在途状态可用；读取失败只影响账号区域（R1-02）。
        Scroll() {
          Column({ space: CouliSpacing.space3 }) {
            this.pendingSection()
            if (this.model.body === FundPageLayout.LOADING) {
              LoadingProgress().width(32).height(32).color(CouliColors.textSecondary)
            } else {
              this.errorBlock()
            }
          }
          .padding(CouliSpacing.space4)
          .width('100%')
          .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      } else {
        Scroll(this.formScroller) {
          Column({ space: CouliSpacing.space3 }) {
            if (this.model.bannerText.length > 0) {
              WalletNoticeBar({ text: this.model.bannerText, tone: 'error', barId: 'payout_banner' })
            }
            this.pendingSection()
            if (this.model.phase === PayoutPhase.FORM || this.model.phase === PayoutPhase.SAVING
              || (this.model.phase === PayoutPhase.STEP_UP)) {
              Text(this.t('payout_account.intro'))
                .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
                .width('100%')
              this.form()
            } else if (this.display() !== null && (this.display() as WalletRecord)['bound'] === true) {
              ForEach([this.model.version], (v: number) => {
                this.boundCard(v)
              }, (v: number) => 'payout_bound_' + v + '_' + (this.model.pending !== null))
              WalletNoticeBar({ text: this.t('payout_account.no_unbind'), tone: 'info', barId: 'payout_no_unbind' })
            }
          }
          .padding(CouliSpacing.space4)
          .width('100%')
          .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
        }
        .id('payout_scroll')
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        if (this.model.phase === PayoutPhase.FORM || this.model.phase === PayoutPhase.SAVING
          || this.model.phase === PayoutPhase.STEP_UP) {
          Column() {
            CouliButton({
              text: this.model.phase === PayoutPhase.SAVING ? this.t('payout_account.saving')
                : this.t('payout_account.save'),
              fullWidth: true,
              loading: this.model.phase === PayoutPhase.SAVING,
              disabled: !this.model.canSave,
              buttonId: ID_SAVE,
              onTap: () => {
                try {
                  this.getUIContext().getFocusController().clearFocus();
                } catch (e) {
                  // 没有焦点时忽略。
                }
                this.config.controller.save();
              }
            })
          }
          .width('100%')
          .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
          .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
            bottom: CouliSpacing.space2 })
        }
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
        CouliFocusReturn.to(this.getUIContext(), ID_SAVE);
      }
    })
  }
}
