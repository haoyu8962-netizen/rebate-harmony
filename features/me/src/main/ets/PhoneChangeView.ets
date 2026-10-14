import { KeyboardAvoidMode } from '@kit.ArkUI';
import {
  AccountPendingView, PhoneBlockedDialog, PhoneChangeController, PhoneChangeSnapshot, PhoneChangeStep,
  PhoneChangeStep1Buttons, StepUpController, StepUpSnapshot
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogOptions, CouliFocus,
  CouliFocusReturn, CouliFontWeight, CouliFormat, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier,
  CouliToast, CouliTypography, PendingConfirmCard, PendingSummaryRow, PriceTerms, stepUpWillDismiss
} from 'designsystem';
import { AccountAnnouncer, AccountBound, AccountStepUpPanel } from './AccountKit';
import { fmt1, MeLink, MeNoticeBar, MePageFrame, MeTexts } from './MeKit';

const ID_NEXT: string = 'phone_change_next';
const ID_SUBMIT: string = 'phone_change_submit';
const ID_STEP1_CODE: string = 'phone_change_step1_code';
const ID_NEW_PHONE: string = 'phone_change_new_phone';
const ID_CODE: string = 'phone_change_code';
const ID_ABANDON: string = 'phone_change_pending_abandon';

@ObservedV2
class PhoneChangeModel {
  @Trace version: number = 0;
  @Trace step: string = PhoneChangeStep.STEP1;
  @Trace step1Code: string = '';
  @Trace step1Error: string = '';
  @Trace step1Sent: boolean = false;
  @Trace step1Countdown: number = 0;
  @Trace step1Sending: boolean = false;
  @Trace step1Verifying: boolean = false;
  /** R3-04：第 1 步发码限制与验证限制分开保存（【获取验证码】只看前者，【下一步】只看后者）。 */
  @Trace step1SendBlocked: boolean = false;
  @Trace step1VerifyBlocked: boolean = false;
  @Trace newPhone: string = '';
  @Trace code: string = '';
  @Trace phoneError: string = '';
  @Trace codeError: string = '';
  @Trace bannerText: string = '';
  @Trace countdown: number = 0;
  @Trace sending: boolean = false;
  @Trace submitting: boolean = false;
  @Trace pendingBusy: boolean = false;
  @Trace stepUp: boolean = false;
  @Trace dead: boolean = false;
}

/**
 * 换手机号子页（Settings 的页内子页，G22；PhoneChange、PhoneChangeNew、PhoneChangeDone、PhoneChangeNewBlocked、PhoneChangePending*）。
 * 不显示当前号码（G03）；新号带 +86 前缀标签、手机号键盘；验证码一个整串输入框，读「验证码，已输入 n 位，共 6 位」；字段错误即时播报一次、
 * 焦点移到错误提示、保留输入；底部主按钮随键盘上移（页面按键盘可视区收缩）。回调只用渲染时捕获的版本（AccountBound）。
 */
@ComponentV2
export struct PhoneChangeView {
  @Param @Require controller: PhoneChangeController;
  @Param @Require texts: MeTexts;
  @Param stepUpViewport: number = 0;
  @Event onBack: () => void = () => {
  };
  @Local model: PhoneChangeModel = new PhoneChangeModel();
  private snap: PhoneChangeSnapshot = new PhoneChangeSnapshot();
  private stepUpController: StepUpController | null = null;
  private readonly announcer: AccountAnnouncer = new AccountAnnouncer();
  private lastNotice: number = 0;
  private lastStep1Error: number = 0;
  private lastBlocked: number = 0;
  private lastPendingKey: string = '';
  /** 在途的是放弃（转圈落在放弃按钮上）。 */
  private abandoning: boolean = false;
  private dialogSerial: number = 0;
  private closeDialog: () => void = () => {
  };
  private savedAvoid: KeyboardAvoidMode | null = null;

  aboutToAppear(): void {
    try {
      const ui: UIContext = this.getUIContext();
      this.savedAvoid = ui.getKeyboardAvoidMode();
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      this.savedAvoid = null;
    }
    this.controller.onChange = (s: PhoneChangeSnapshot): void => this.apply(s);
    this.apply(this.controller.snapshot);
  }

  aboutToDisappear(): void {
    this.dropDialog();
    this.stepUpController?.close();
    this.stepUpController = null;
    const saved: KeyboardAvoidMode | null = this.savedAvoid;
    if (saved !== null) {
      try {
        this.getUIContext().setKeyboardAvoidMode(saved);
      } catch (e) {
        // 忽略。
      }
    }
  }

  private t(key: string): string {
    return this.texts.text(key);
  }

  private focus(id: string): void {
    const ui: UIContext = this.getUIContext();
    setTimeout(() => {
      try {
        ui.getFocusController().requestFocus(id);
      } catch (e) {
        // 节点还没挂上时忽略。
      }
    }, 300);
  }

  private apply(s: PhoneChangeSnapshot): void {
    this.snap = s;
    const m: PhoneChangeModel = this.model;
    const ui: UIContext = this.getUIContext();
    m.dead = s.dead;
    m.step = s.step;
    const s1: StepUpSnapshot = s.step1;
    m.step1Code = s1.code;
    m.step1Sent = s1.sent;
    m.step1Countdown = s1.countdown;
    m.step1Sending = s1.sending;
    m.step1Verifying = s1.verifying;
    // R3-04：两种限制分开保存、分开随到期通知刷新（StepUpController 的按键发码限流到期与 verifyGate 到期都会 emit）。
    m.step1SendBlocked = PhoneChangeStep1Buttons.sendBlocked(s1);
    m.step1VerifyBlocked = PhoneChangeStep1Buttons.nextBlocked(s1);
    m.step1Error = s1.error === null ? '' : s1.error.text;
    if (s1.error !== null && s1.error.seq !== this.lastStep1Error) {
      // 20002 / 20003：清空并 assertive 播报，焦点回输入框。
      this.lastStep1Error = s1.error.seq;
      CouliAnnounce.say(ui, s1.error.text);
      this.focus(ID_STEP1_CODE);
    }
    m.newPhone = s.newPhone;
    m.code = s.code;
    m.phoneError = s.phoneError === null ? '' : s.phoneError.text;
    m.codeError = s.codeError === null ? '' : s.codeError.text;
    m.bannerText = s.banner === null ? '' : s.banner.text;
    m.countdown = s.countdown;
    m.sending = s.sending;
    m.submitting = s.submitting;
    m.pendingBusy = s.pendingBusy;
    this.announcer.say(ui, s.phoneError);
    if (s.phoneError !== null) {
      this.focus('phone_change_phone_error');
    }
    this.announcer.say(ui, s.codeError);
    if (s.codeError !== null) {
      this.focus('phone_change_code_error');
    }
    this.announcer.say(ui, s.banner);
    if (s.notice !== null && s.notice.seq !== this.lastNotice) {
      this.lastNotice = s.notice.seq;
      if (s.notice.textKey !== 'phone_change.code_sent') {
        CouliToast.show(ui, s.notice.text);
      }
      // 「验证码已发送」polite 播报一次，倒计时不逐秒读（adaptation-a11y-spec §10）。
      CouliAnnounce.say(ui, s.notice.text);
    }
    const p: AccountPendingView | null = s.pending;
    if (p !== null && p.key !== this.lastPendingKey) {
      this.lastPendingKey = p.key;
      CouliAnnounce.say(ui, this.t('pending_confirm.title') + PriceTerms.comma + this.pendingDesc(p));
    }
    if (p === null && this.lastPendingKey.length > 0) {
      // 待确认结束（别处结算、确认或放弃有了结论）：关掉还开着的放弃确认框（一次性编号随之作废）。
      this.lastPendingKey = '';
      this.dropDialog();
    }
    const blocked: PhoneBlockedDialog | null = s.blocked;
    if (blocked !== null && blocked.seq !== this.lastBlocked) {
      this.lastBlocked = blocked.seq;
      this.openBlocked(blocked);
    }
    if (s.stepUpAction !== null && this.stepUpController === null) {
      this.stepUpController = this.controller.createStepUp();
      m.stepUp = this.stepUpController !== null;
    } else if (s.stepUpAction === null && this.stepUpController !== null) {
      this.stepUpController.close();
      this.stepUpController = null;
      m.stepUp = false;
    }
    m.version = s.version * 1000 + s.pendingVersion;
  }

  private dropDialog(): void {
    this.dialogSerial++;
    const close: () => void = this.closeDialog;
    this.closeDialog = () => {
    };
    close();
  }

  /** PhoneChangeNewBlocked：标题 risk_msg / error.44001，正文 phone_change.risk_blocked.desc；【知道了】【联系客服申诉】。 */
  private openBlocked(d: PhoneBlockedDialog): void {
    this.dropDialog();
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = d.title;
    options.message = d.desc;
    options.primaryText = this.t('phone_change.risk_blocked.ok');
    options.secondaryText = this.t('cs.appeal_entry');
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.returnFocusId = ID_SUBMIT;
    options.onPrimary = (): void => this.controller.dismissBlocked();
    options.onSecondary = (): void => {
      this.controller.contactCs();
    };
    options.onDismissed = (): void => this.controller.dismissBlocked();
    this.closeDialog = CouliDialog.open(this.getUIContext(), options);
  }

  private confirmAbandon(b: AccountBound): void {
    const p: AccountPendingView | null = this.snap.pending;
    if (p === null || p.key !== b.key || this.snap.pendingVersion !== b.version) {
      return;
    }
    this.dropDialog();
    const serial: number = this.dialogSerial;
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('pending_confirm.abandon');
    options.message = this.t('pending_confirm.abandon.confirm') + '\n'
      + this.t('pending_confirm.abandon.note.phone_change');
    if (p.maskedPhone !== null) {
      options.detailLabel = this.t('pending_confirm.summary.new_phone');
      options.detailValue = p.maskedPhone;
    }
    options.primaryText = this.t('pending_confirm.abandon.ok');
    options.secondaryText = this.t('pending_confirm.abandon.cancel');
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.returnFocusId = ID_ABANDON;
    options.onPrimary = (): void => {
      if (serial !== this.dialogSerial) {
        return;
      }
      this.dialogSerial++;
      this.abandoning = true;
      this.controller.abandon(b.version, b.key);
    };
    this.closeDialog = CouliDialog.open(this.getUIContext(), options);
  }

  private pendingDesc(p: AccountPendingView): string {
    if (p.maskedPhone === null) {
      // G24：取不到号码（不是 11 位）用 fallbacks 的句子。
      return this.texts.format('pending_confirm.phone_change.desc', new Map<string, string>());
    }
    return fmt1(this.texts, 'pending_confirm.phone_change.desc', 'phone', p.maskedPhone);
  }

  /** 渲染时的绑定；读 model.version（@Trace）让 ForEach 在版本变化时重算数组与键（回调拿到新版本）。 */
  private bound(): AccountBound[] {
    const traced: number = this.model.version;
    const p: AccountPendingView | null = this.snap.pending;
    return [new AccountBound(p === null ? this.snap.version : this.snap.pendingVersion, p === null ? '' : p.key,
      this.controller.identity.key + '|' + this.snap.version + '|' + traced)];
  }

  @Builder
  steps() {
    // 320 宽、200% 字号：两步换行显示，不截断（G32）。
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      this.stepDot('1', this.t('phone_change.step1'), this.model.step === PhoneChangeStep.STEP1)
      Divider()
        .color(CouliColors.borderSubtle)
        .strokeWidth(1)
        .width(CouliSpacing.space6)
        .margin({ left: CouliSpacing.space2, right: CouliSpacing.space2 })
        .accessibilityLevel('no')
      this.stepDot('2', this.t('phone_change.step2'), this.model.step !== PhoneChangeStep.STEP1)
    }
    .width('100%')
  }

  @Builder
  stepDot(n: string, label: string, active: boolean) {
    Row({ space: CouliSpacing.space1 }) {
      Text(n)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption,
          active ? CouliColors.textInverse : CouliColors.textSecondary, CouliFontWeight.semibold))
        .constraintSize({ minWidth: 20, minHeight: 20 })
        .padding({ left: 4, right: 4 })
        .textAlign(TextAlign.Center)
        .borderRadius(CouliRadius.pill)
        .backgroundColor(active ? CouliColors.brandPrimary : CouliColors.backgroundMuted)
      Text(label)
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
          active ? CouliColors.textPrimary : CouliColors.textSecondary))
    }
    .margin({ bottom: CouliSpacing.space1 })
    .accessibilityGroup(true)
    .accessibilityText(n + PriceTerms.comma + label)
  }

  private isStep1(id: string): boolean {
    return id === ID_STEP1_CODE;
  }

  private codeValue(id: string): string {
    return this.isStep1(id) ? this.model.step1Code : this.model.code;
  }

  private codeErrorText(id: string): string {
    return this.isStep1(id) ? this.model.step1Error : this.model.codeError;
  }

  private codeCountdown(id: string): number {
    return this.isStep1(id) ? this.model.step1Countdown : this.model.countdown;
  }

  private codeSending(id: string): boolean {
    return this.isStep1(id) ? this.model.step1Sending : this.model.sending;
  }

  private codeSendEnabled(id: string, enabled: boolean): boolean {
    return this.isStep1(id) ? enabled && !this.model.step1SendBlocked
      : enabled && this.model.newPhone.trim().length > 0 && !this.snap.sendRateLimited;
  }

  /**
   * 验证码一个整串输入框（读「验证码，已输入 n 位，共 6 位」）+ 获取验证码 / 倒计时。@Builder 的普通参数按值传、不随状态刷新，所以可变的
   * 值（输入、错误、倒计时、在途）一律在这里按 id 现读 model。
   */
  @Builder
  codeField(id: string, enabled: boolean, onChange: (v: string) => void, onSend: () => void) {
    Column({ space: CouliSpacing.space1 }) {
      Text(this.t('phone_change.code_label'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        TextInput({ text: this.codeValue(id), placeholder: '' })
          .id(id)
          .type(InputType.Number)
          .maxLength(6)
          .enabled(enabled)
          .flexGrow(1)
          .constraintSize({ minWidth: 120, minHeight: CouliInteraction.minTouchTarget })
          .fontSize(CouliTypography.body.fontSize)
          .backgroundColor(Color.Transparent)
          .accessibilityText(fmt1(this.texts, 'step_up.code_a11y', 'n', String(this.codeValue(id).length)))
          .accessibilityDescription(this.codeErrorText(id))
          .onChange((v: string) => onChange(v))
        if (this.codeCountdown(id) > 0) {
          Text(fmt1(this.texts, 'phone_change.resend_in', 'n', String(this.codeCountdown(id))))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary, undefined, true))
            .padding({ left: CouliSpacing.space2 })
        } else {
          Text(this.t('phone_change.get_code'))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
              this.codeSendEnabled(id, enabled) && !this.codeSending(id) ? CouliColors.textLink : CouliColors.textSecondary,
              CouliFontWeight.medium))
            .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
            .padding({ left: CouliSpacing.space2 })
            .accessibilityRole(AccessibilityRoleType.BUTTON)
            .enabled(this.codeSendEnabled(id, enabled) && !this.codeSending(id))
            .focusable(true)
            .focusBox(CouliFocus.box)
            .id(id + '_send')
            .onClick(() => onSend())
        }
      }
      .width('100%')
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space2 })
      .borderRadius(12)
      .border({ width: 1, color: this.codeErrorText(id).length > 0 ? CouliColors.statusErrorText : CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      if (this.codeErrorText(id).length > 0) {
        Text(this.codeErrorText(id))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .id(id === ID_CODE ? 'phone_change_code_error' : 'phone_change_step1_error')
          .focusable(true)
          .focusBox(CouliFocus.box)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  step1(b: AccountBound) {
    Column({ space: CouliSpacing.space3 }) {
      // G03：不显示当前号码。
      Text(this.model.step1Sent ? this.t('phone_change.code_sent') : this.t('phone_change.current_hint'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
      if (!this.snap.phoneKnown) {
        // G02（待补稿）：Release 取不到号码时不发码、不让用户另填。
        MeNoticeBar({ text: this.t('step_up.no_phone'), tone: 'warning', barId: 'phone_change_no_phone' })
      }
      this.codeField(ID_STEP1_CODE, this.snap.phoneKnown, (v: string) => {
        this.controller.setStep1Code(b.version, v);
      }, () => {
        this.controller.sendStep1(b.version);
      })
      Text(this.t('phone_change.intro'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      MeLink({
        text: this.t('phone_change.cant_use_old'),
        linkId: 'phone_change_cant_use_old',
        onTap: () => {
          this.controller.contactCs();
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  step2(b: AccountBound, enabled: boolean) {
    Column({ space: CouliSpacing.space3 }) {
      Column({ space: CouliSpacing.space1 }) {
        Text(this.t('phone_change.new_phone'))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        Row({ space: CouliSpacing.space2 }) {
          Text(this.t('phone_change.prefix'))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
            .accessibilityLevel('no')
          TextInput({ text: this.model.newPhone })
            .id(ID_NEW_PHONE)
            .type(InputType.PhoneNumber)
            .enabled(enabled)
            .layoutWeight(1)
            .fontSize(CouliTypography.body.fontSize)
            .backgroundColor(Color.Transparent)
            .accessibilityText(this.t('phone_change.new_phone'))
            .accessibilityDescription(this.model.phoneError)
            .onChange((v: string) => {
              this.controller.setNewPhone(b.version, v);
            })
        }
        .width('100%')
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .padding({ left: CouliSpacing.space3, right: CouliSpacing.space2 })
        .borderRadius(12)
        .border({ width: 1, color: this.model.phoneError.length > 0 ? CouliColors.statusErrorText
          : CouliColors.borderControl })
        .backgroundColor(CouliColors.backgroundSurface)
        if (this.model.phoneError.length > 0) {
          Text(this.model.phoneError)
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
            .id('phone_change_phone_error')
            .focusable(true)
            .focusBox(CouliFocus.box)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      this.codeField(ID_CODE, enabled, (v: string) => {
        this.controller.setCode(b.version, v);
      }, () => {
        this.controller.sendBind(b.version);
      })
      Text(this.t('phone_change.new_hint'))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
      if (this.snap.showCustomerService) {
        CouliButton({
          text: this.t('deletion.contact_cs'),
          variant: CouliButtonVariant.SECONDARY,
          buttonId: 'phone_change_cs',
          onTap: () => {
            this.controller.contactCs();
          }
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  pending(b: AccountBound) {
    if (this.snap.pending !== null) {
      PendingConfirmCard({
        title: this.t('pending_confirm.title'),
        desc: this.pendingDesc(this.snap.pending as AccountPendingView),
        rows: this.pendingRows(this.snap.pending as AccountPendingView),
        abandonLabel: this.t('pending_confirm.abandon'),
        confirmLabel: this.t('pending_confirm.phone_change.action'),
        busy: this.model.pendingBusy,
        busyConfirm: !this.abandoning,
        busyText: this.t('error.40901'),
        warning: this.model.bannerText,
        hint: this.t('phone_change.pending_hint'),
        disabled: this.snap.submitBlocked || (this.snap.pending as AccountPendingView).inFlight,
        idPrefix: 'phone_change_pending',
        onAbandon: () => this.confirmAbandon(b),
        onConfirm: () => {
          this.abandoning = false;
          this.controller.confirm(b.version, b.key);
        }
      })
    }
  }

  private pendingRows(p: AccountPendingView): PendingSummaryRow[] {
    const rows: PendingSummaryRow[] = [];
    if (p.maskedPhone !== null) {
      rows.push(new PendingSummaryRow(this.t('pending_confirm.summary.new_phone'), p.maskedPhone));
    }
    rows.push(new PendingSummaryRow(this.t('pending_confirm.summary.submitted_at'),
      CouliFormat.timeListFuture(p.createdAtMillis, Date.now())));
    return rows;
  }

  @Builder
  done(b: AccountBound) {
    Column({ space: CouliSpacing.space3 }) {
      Text(this.t('phone_change.done.title'))
        .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary, CouliFontWeight.semibold))
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .id('phone_change_done_title')
      Text(this.snap.doneMasked !== null ? fmt1(this.texts, 'phone_change.done.body', 'phone', this.snap.doneMasked as string)
        : this.t('phone_change.done.body_plain'))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CouliSpacing.space6 })
  }

  @Builder
  body(b: AccountBound) {
    Column({ space: CouliSpacing.space4 }) {
      if (this.model.step !== PhoneChangeStep.DONE) {
        this.steps()
      }
      if (this.model.bannerText.length > 0 && this.model.step !== PhoneChangeStep.PENDING) {
        MeNoticeBar({ text: this.model.bannerText, tone: 'error', barId: 'phone_change_banner', focusTarget: true })
      }
      if (this.snap.guideRoute !== null) {
        MeLink({
          text: this.t('error.' + this.snap.guideCode),
          linkId: 'phone_change_guide',
          onTap: () => {
            this.controller.openGuide(this.snap.version, this.snap.guideRoute as string);
          }
        })
      }
      if (this.model.step === PhoneChangeStep.STEP1) {
        this.step1(b)
      } else if (this.model.step === PhoneChangeStep.STEP2) {
        this.step2(b, !this.model.submitting)
      } else if (this.model.step === PhoneChangeStep.PENDING) {
        this.pending(b)
        this.step2(new AccountBound(-1, '', b.identity), false)
      } else {
        this.done(b)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  content() {
    if (!this.model.dead) {
      ForEach(this.bound(), (b: AccountBound) => {
        this.body(b)
      }, (b: AccountBound) => 'phone_body_' + b.id + '_' + this.model.step)
    }
  }

  @Builder
  footer() {
    if (!this.model.dead) {
      ForEach(this.bound(), (b: AccountBound) => {
        Column({ space: CouliSpacing.space2 }) {
          if (this.model.step === PhoneChangeStep.STEP1) {
            CouliButton({
              text: this.t('phone_change.next'),
              fullWidth: true,
              loading: this.model.step1Verifying,
              disabled: !PhoneChangeStep1Buttons.nextEnabled(this.snap.step1, this.snap.phoneKnown),
              buttonId: ID_NEXT,
              onTap: () => {
                this.controller.next(b.version);
              }
            })
          } else if (this.model.step === PhoneChangeStep.DONE) {
            CouliButton({
              text: this.t('phone_change.done.ok'),
              fullWidth: true,
              buttonId: 'phone_change_done_ok',
              onTap: () => {
                this.controller.finish(b.version);
              }
            })
          } else {
            Text(this.t('phone_change.submit_hint'))
              .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
              .width('100%')
              .textAlign(TextAlign.Center)
            CouliButton({
              text: this.t('phone_change.submit'),
              fullWidth: true,
              loading: this.model.submitting,
              disabled: this.model.step !== PhoneChangeStep.STEP2 || this.model.code.length !== 6
                || this.model.newPhone.trim().length === 0 || this.snap.submitBlocked || this.snap.storeUnavailable,
              buttonId: ID_SUBMIT,
              onTap: () => {
                try {
                  this.getUIContext().getFocusController().clearFocus();
                } catch (e) {
                  // 忽略。
                }
                this.controller.submit(b.version);
              }
            })
          }
        }
        .width('100%')
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
          bottom: CouliSpacing.space4 })
      }, (b: AccountBound) => 'phone_footer_' + b.id + '_' + this.model.version + '_' + this.footerState())
    }
  }

  /** 底部按钮可用性依赖的输入状态（按键时只重建按钮栏，不重建输入框、不收键盘）。 */
  private footerState(): string {
    const m: PhoneChangeModel = this.model;
    return m.step1Code.length + '|' + m.code.length + '|' + m.newPhone.trim().length + '|' + m.submitting + '|'
      + m.step1Verifying + '|' + m.step1VerifyBlocked;
  }

  @Builder
  stepUpSheet() {
    if (this.stepUpController !== null) {
      AccountStepUpPanel({
        controller: this.stepUpController as StepUpController,
        texts: this.texts,
        action: 'phone_change',
        viewportOverride: this.stepUpViewport,
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
    this.controller.stepUpClosed();
  }

  build() {
    Column() {
      MePageFrame({
        title: this.t('phone_change.title'),
        backLabel: this.t('me.back'),
        scrollId: 'phone_change_scroll',
        content: () => {
          this.content()
        },
        footer: () => {
          this.footer()
        },
        onBack: () => this.onBack()
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    .bindSheet(this.model.stepUp, this.stepUpSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: CouliColors.backgroundSurface,
      keyboardAvoidMode: SheetKeyboardAvoidMode.NONE,
      onWillDismiss: (action: DismissSheetAction) => stepUpWillDismiss(action),
      onWillSpringBackWhenDismiss: (action: SpringBackAction) => {
        action.springBack();
      },
      onDisappear: () => {
        if (this.model.stepUp) {
          this.closeStepUp();
        }
        CouliFocusReturn.to(this.getUIContext(), this.snap.pending !== null ? 'phone_change_pending_confirm' : ID_SUBMIT);
      }
    })
  }
}
