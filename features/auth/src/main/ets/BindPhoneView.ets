import { KeyboardAvoidMode } from '@kit.ArkUI';
import {
  AuthAnnouncement, AuthFeedback, BindOutcome, BindPhoneAction, BindPhoneAnnouncer, BindPhoneService, CodeInput, LoginSendState, MergeDecision, MergeResult, PhoneNumber, PhoneResult,
  SendCodeOutcome, SmsCountdown
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliColors, CouliDialog, CouliDialogOptions, CouliFocus, CouliFocusReturn, CouliFontWeight, CouliIcon,
  CouliInteraction, CouliLayout, CouliRadius, CouliShadow, CouliSpacing, CouliTextModifier, CouliToast, CouliTypography,
  TABULAR_FEATURE
} from 'designsystem';
import { LoginTexts } from './LoginView';

/**
 * 绑手机页与并号确认用到的文案键（三端同名）。契约已有的（invite.bind_phone_guide.*、error.*）直接取；其余是 entry 草稿表
 * LoginDraftTexts 里「待定稿，不得提审」的键（TODO(N-26) / TODO(N-29)）。本模块不出现中文（HM-LINT-1）。
 */
export class BindPhoneKeys {
  static readonly TITLE: string = 'invite.bind_phone_guide.title';
  static readonly NOTE: string = 'invite.bind_phone_guide.body';
  static readonly BACK: string = 'login.back';
  static readonly PHONE_LABEL: string = 'login.phone.label';
  static readonly PHONE_PREFIX: string = 'login.phone.prefix';
  static readonly PHONE_PLACEHOLDER: string = 'login.phone.placeholder';
  static readonly PHONE_CLEAR: string = 'login.phone.clear';
  static readonly CODE_LABEL: string = 'login.code.label';
  static readonly CODE_PLACEHOLDER: string = 'bind_phone.code.placeholder';
  static readonly GET_CODE: string = 'login.get_code';
  static readonly COUNTDOWN: string = 'bind_phone.countdown';
  static readonly SUBMIT: string = 'bind_phone.submit';
  static readonly DONE: string = 'bind_phone.done';
  static readonly MERGE_TITLE: string = 'bind_phone.merge.title';
  static readonly MERGE_INTO: string = 'bind_phone.merge.into';
  static readonly MERGE_ACCOUNT: string = 'bind_phone.merge.account';
  static readonly MERGE_CANCEL: string = 'bind_phone.merge.cancel';
  static readonly MERGE_OK: string = 'bind_phone.merge.ok';
  static readonly MERGE_UNAVAILABLE: string = 'bind_phone.merge.unavailable';
  static readonly GENERIC: string = 'error.50001';
  /** 44001 风控拦截弹窗（BR-TEXT-14 表 A「给申诉入口」）：【知道了】与【联系客服申诉】。 */
  static readonly RISK_OK: string = 'login.risk_blocked.ok';
  static readonly APPEAL: string = 'cs.appeal_entry';
}

/** 绑手机页的出口（entry 接 Router 与 App 能力）。 */
export class BindPhonePageConfig {
  readonly service: BindPhoneService;
  readonly texts: LoginTexts;
  /** 当前第三方登录方式的显示名（error.30411.mergeable 的 {provider_name}）；不知道时用草稿「当前登录方式」由 fallback 处理。 */
  providerName: string = '';
  clock: () => number = () => Date.now();
  /** 返回 / 关闭本页。 */
  onClose: () => void = () => {
  };
  /** 统一客服出口（44001 的【联系客服申诉】，与登录页同一出口）。 */
  onCustomerService: () => void = () => {
  };
  /** 绑定成功（会话状态已刷新）：entry 关闭本页。 */
  onBound: () => void = () => {
  };
  /**
   * 错误码要求跳页（10007 stage=cooling → DeleteAccount，R2-03）：entry 经 Router 打开（守卫照常判定），本页不弹提示。
   */
  onNavigate: (route: string) => void = (_route: string) => {
  };

  constructor(service: BindPhoneService, texts: LoginTexts) {
    this.service = service;
    this.texts = texts;
  }
}

@ObservedV2
export class BindPhoneModel {
  @Trace phoneText: string = '';
  @Trace codeText: string = '';
  @Trace phoneError: string = '';
  @Trace codeError: string = '';
  @Trace sending: boolean = false;
  @Trace submitting: boolean = false;
  @Trace now: number = 0;
  /** 42901（绑定）禁用截止时刻。 */
  @Trace bindUntil: number = 0;
  /** 软键盘弹起（页面按键盘可视区收缩，R1-07）：底部按钮栏贴键盘上沿，下内边距改 8。 */
  @Trace keyboardShown: boolean = false;
}

const INPUT_HEIGHT: number = 52;
const ID_TITLE: string = 'bind_phone_title';
const ID_SUBMIT: string = 'bind_phone_submit';
const ID_SEND: string = 'bind_phone_send';
const ID_PHONE_ERROR: string = 'bind_phone_phone_error';
const ID_CODE_ERROR: string = 'bind_phone_code_error';
/** 错误提示出现后再移读屏焦点（等节点挂上）。 */
const A11Y_ERROR_DELAY_MS: number = 300;
/** 页面高度比最高时少这么多（vp）就按键盘弹起处理。 */
const KEYBOARD_THRESHOLD_VP: number = 120;

/**
 * 绑手机页（BindPhone 画板；并号确认 BindPhoneMerge 画板为页上的弹窗）。BR-ID-05、BR-ID-06：
 * - 发码 purpose=bind，按号码的倒计时与 42901 禁用由 BindPhoneService（共享 SmsSendDeadlines）现算；
 * - 绑定成功 → 刷新 getMe 与会话状态 → 关闭本页；30411 mergeable → 并号确认（取消 / 并入都有明确结果）；
 * - 读屏顺序：返回 → 标题 → 说明 → 手机号 → 清除 → 验证码 → 获取验证码 → 绑定。
 */
@ComponentV2
export struct BindPhoneView {
  @Param @Require config: BindPhonePageConfig;
  @Local model: BindPhoneModel = new BindPhoneModel();
  private timer: number = -1;
  /** 进页前的键盘避让方式（离页时恢复）。 */
  private savedAvoidMode: KeyboardAvoidMode | null = null;
  /** 页面出现以来的最大高度（判断键盘是否弹起）。 */
  private maxHeight: number = 0;
  private readonly scroller: Scroller = new Scroller();
  /** 当前获焦的输入框（phone / code）：键盘弹起后把它滚到可见区（adaptation-a11y-spec §3：当前输入项完整露出）。 */
  private focusedField: string = '';
  /** 读屏状态播报（R2-04）：发码成功播报一次脱敏发送对象；倒计时结束、可重发时播报一次；离页后不播报。 */
  private readonly announcer: BindPhoneAnnouncer = new BindPhoneAnnouncer();

  aboutToAppear(): void {
    this.model.now = this.config.clock();
    // R1-07（APP-05b 共性 7）：键盘弹起时按可视区收缩页面（RESIZE），底部【绑定】随键盘上移、输入区在 Scroll 内滚动，
    // 不再整页上推把按钮压在键盘后。只在本页生效，离页恢复原方式。
    try {
      const ui: UIContext = this.getUIContext();
      this.savedAvoidMode = ui.getKeyboardAvoidMode();
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      this.savedAvoidMode = null;
    }
  }

  aboutToDisappear(): void {
    this.announcer.dispose();
    this.stopTimer();
    this.config.service.invalidate();
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

  private fmt(key: string, vars: Map<string, string>): string {
    return this.config.texts.format(key, vars);
  }

  // ---------------------------------------------------------------- 计时

  /** 页面重新出现、发码结果、换号时调：按号码的截止时间现算，还有没到期的就（重新）启动每秒刷新。 */
  refreshTimers(): void {
    this.tick();
    if (this.timer < 0 && this.timerNeeded()) {
      this.timer = setInterval(() => this.tick(), 1000);
    }
  }

  private timerNeeded(): boolean {
    const state: LoginSendState = this.config.service.sendState(this.model.phoneText);
    return state.countdownSec > 0 || state.rateLimitedSec > 0 || this.model.now < this.model.bindUntil;
  }

  private tick(): void {
    this.model.now = this.config.clock();
    // R2-04：等待由有效变为可重发时播报一次（不逐秒播报；换号只记状态）。
    const state: LoginSendState = this.config.service.sendState(this.model.phoneText);
    this.announce(this.announcer.tick(this.model.phoneText, state.countdownSec + state.rateLimitedSec));
    if (!this.timerNeeded()) {
      this.stopTimer();
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private countdown(): number {
    return this.model.now >= 0 ? this.config.service.sendState(this.model.phoneText).countdownSec : 0;
  }

  private sendRateLimited(): boolean {
    return this.model.now >= 0 && this.config.service.sendState(this.model.phoneText).rateLimitedSec > 0;
  }

  private bindBlocked(): boolean {
    return this.model.now < this.model.bindUntil;
  }

  // ---------------------------------------------------------------- 动作

  /** 读屏播报一次（文案经字典取，缺键用草稿键）。 */
  private announce(announcement: AuthAnnouncement | null): void {
    if (announcement === null) {
      return;
    }
    const text: string = this.fmt(announcement.textKey, announcement.vars);
    if (text.length > 0) {
      CouliAnnounce.say(this.getUIContext(), text);
    }
  }

  private toast(key: string | null, trace6: string): void {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('trace6', trace6);
    vars.set('provider_name', this.config.providerName);
    const text: string = this.fmt(key ?? BindPhoneKeys.GENERIC, vars);
    if (text.length > 0) {
      CouliToast.show(this.getUIContext(), text);
    }
  }

  private async sendCode(): Promise<void> {
    if (this.model.sending || this.countdown() > 0 || this.sendRateLimited()) {
      return;
    }
    const phone: PhoneResult = PhoneNumber.normalize(this.model.phoneText);
    if (!phone.valid) {
      this.fieldError(true, this.t('error.20001.phone_invalid'));
      return;
    }
    this.model.sending = true;
    let outcome: SendCodeOutcome;
    try {
      outcome = await this.config.service.sendCode(this.model.phoneText);
    } finally {
      this.model.sending = false;
    }
    switch (outcome.stateRaw) {
      case SmsCountdown.STATE_SENT:
        // R2-04：当前有效请求的发送成功播报一次脱敏发送对象（换号、离页后的旧结果不播报）。
        this.announce(this.announcer.sendResult(outcome, this.model.phoneText));
        this.refreshTimers();
        return;
      case 'countdown_active':
        this.refreshTimers();
        return;
      case SmsCountdown.STATE_RATE_LIMITED:
        this.refreshTimers();
        this.toast(outcome.textKey, outcome.trace6);
        return;
      default:
        this.present(AuthFeedback.ofBindSend(outcome), outcome.trace6);
    }
  }

  /**
   * 失败的呈现（AuthFeedback；R1-05、R1-06）：风控拦截弹窗给申诉入口；字段错误显示在输入框下、即时播报一次并把读屏焦点
   * 移到错误提示（输入框的读屏说明同时带上这句）；手机号与验证码一律保留。只处理本页当前有效请求的结果（stale 已在前面丢弃）。
   */
  private present(feedback: AuthFeedback, trace6: string): void {
    switch (feedback.kind) {
      case AuthFeedback.NONE:
        return;
      case AuthFeedback.RISK_DIALOG:
        this.showRiskBlocked(feedback);
        return;
      case AuthFeedback.NAVIGATE:
        // R2-03：10007 冷静期——经 Router 打开注销进度页（可撤回），不弹「处理中」提示。
        if (feedback.route !== null) {
          this.config.onNavigate(feedback.route);
        }
        return;
      case AuthFeedback.PHONE_ERROR:
        this.fieldError(true, this.t(feedback.textKey ?? 'error.20001'));
        return;
      case AuthFeedback.CODE_ERROR:
        this.fieldError(false, this.t(feedback.textKey ?? 'error.20002'));
        return;
      default:
        this.toast(feedback.textKey, trace6);
    }
  }

  private fieldError(phone: boolean, text: string): void {
    if (phone) {
      this.model.phoneError = text;
    } else {
      this.model.codeError = text;
    }
    const ui: UIContext = this.getUIContext();
    CouliAnnounce.say(ui, text);
    const id: string = phone ? ID_PHONE_ERROR : ID_CODE_ERROR;
    // 键盘弹起、可视区变小时，把出错的字段连同错误提示滚进可见区。
    setTimeout(() => {
      this.scroller.scrollEdge(phone ? Edge.Top : Edge.Bottom);
    }, 50);
    setTimeout(() => CouliFocusReturn.accessibilityFocus(ui, id), A11Y_ERROR_DELAY_MS);
  }

  /** 44001：标题 error.44001（risk_msg 未下发时的默认句），【知道了】/【联系客服申诉】；输入保留。 */
  private showRiskBlocked(feedback: AuthFeedback): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t(feedback.textKey ?? AuthFeedback.RISK_KEY);
    options.message = feedback.descKey === null ? '' : this.t(feedback.descKey);
    options.primaryText = this.t(BindPhoneKeys.RISK_OK);
    options.secondaryText = this.t(BindPhoneKeys.APPEAL);
    options.dismissOnMask = false;
    options.returnFocusId = ID_SUBMIT;
    options.onSecondary = () => this.config.onCustomerService();
    CouliDialog.open(this.getUIContext(), options);
  }

  private canSubmit(): boolean {
    return PhoneNumber.normalize(this.model.phoneText).valid && CodeInput.accept(this.model.codeText).complete
      && !this.bindBlocked();
  }

  private async bind(): Promise<void> {
    if (!this.canSubmit() || this.model.submitting) {
      return;
    }
    this.model.submitting = true;
    let outcome: BindOutcome;
    try {
      outcome = await this.config.service.bind(this.model.phoneText, this.model.codeText);
    } finally {
      this.model.submitting = false;
    }
    switch (outcome.actionRaw) {
      case BindPhoneAction.DONE:
        this.stopTimer();
        CouliToast.show(this.getUIContext(), this.t(BindPhoneKeys.DONE));
        this.config.onBound();
        return;
      case BindPhoneAction.MERGE_CONFIRM:
        this.confirmMerge(outcome);
        return;
      case BindPhoneAction.RETRY_AFTER:
        this.model.bindUntil = this.config.clock() + Math.max(0, outcome.disableMillis);
        this.refreshTimers();
        this.toast(outcome.textKey, outcome.trace6);
        return;
      default:
        this.present(AuthFeedback.ofBind(outcome), outcome.trace6);
    }
  }

  /** BindPhoneMerge：并入原账号的确认（取消 / 并入）。点遮罩、系统返回按取消。 */
  private confirmMerge(outcome: BindOutcome): void {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('provider_name', this.config.providerName);
    const accountVars: Map<string, string> = new Map<string, string>();
    accountVars.set('phone', outcome.maskedPhone);
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t(BindPhoneKeys.MERGE_TITLE);
    options.message = this.fmt(outcome.textKey ?? 'error.30411.mergeable', vars);
    options.detailIcon = 'merge';
    options.detailLabel = this.t(BindPhoneKeys.MERGE_INTO);
    options.detailValue = this.fmt(BindPhoneKeys.MERGE_ACCOUNT, accountVars);
    options.primaryText = this.t(BindPhoneKeys.MERGE_OK);
    options.secondaryText = this.t(BindPhoneKeys.MERGE_CANCEL);
    options.dismissOnMask = false;
    options.returnFocusId = ID_SUBMIT;
    options.onPrimary = () => this.mergeDecided(MergeDecision.CONFIRM);
    options.onSecondary = () => this.mergeDecided(MergeDecision.CANCEL);
    options.onDismissed = () => this.mergeDecided(MergeDecision.CANCEL);
    CouliDialog.open(this.getUIContext(), options);
  }

  private mergeDecided(decision: string): void {
    const result: MergeResult = this.config.service.decideMerge(decision);
    if (result.resultRaw === MergeDecision.UNAVAILABLE) {
      // TODO(N-29) MERGE-SUCCESS：锁定契约没有并号接口——不发请求、不并号、不保存会话，明确告知暂不可用。
      CouliToast.show(this.getUIContext(), this.t(BindPhoneKeys.MERGE_UNAVAILABLE));
    }
    // cancelled：不并号、不保存会话，留在本页（手机号、验证码保留，用户可换号或返回）。
  }

  // ---------------------------------------------------------------- 界面

  @Builder
  topBar() {
    Row() {
      Row() {
        CouliIcon({ name: 'back', iconSize: 24 })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .justifyContent(FlexAlign.Center)
      .accessibilityGroup(true)
      .accessibilityText(this.t(BindPhoneKeys.BACK))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .id('bind_phone_back')
      .onClick(() => this.config.onClose())
      Text(this.t(BindPhoneKeys.TITLE))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary, CouliFontWeight.semibold))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        .focusable(true)
        .id(ID_TITLE)
        .onAppear(() => CouliFocusReturn.accessibilityFocus(this.getUIContext(), ID_TITLE))
      Row().width(CouliInteraction.minTouchTarget).height(CouliInteraction.minTouchTarget)
    }
    .width('100%')
    .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
  }

  @Builder
  note() {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'info', iconSize: 20, color: CouliColors.textSecondary })
      Text(this.t(BindPhoneKeys.NOTE))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding(CouliSpacing.space3)
    .borderRadius(CouliRadius.button)
    .backgroundColor(CouliColors.backgroundMuted)
  }

  @Builder
  phoneField() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t(BindPhoneKeys.PHONE_LABEL))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .accessibilityLevel('no')
      Row() {
        Text(this.t(BindPhoneKeys.PHONE_PREFIX))
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
          .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
          .accessibilityLevel('no')
        Divider().vertical(true).height(24).color(CouliColors.borderSubtle)
        TextInput({ text: this.model.phoneText, placeholder: this.t(BindPhoneKeys.PHONE_PLACEHOLDER) })
          // 不预先过滤或截断（APP-05a 共性 15）：原样交 PhoneNumber.normalize 校验。
          .type(InputType.Normal)
          .fontSize(CouliTypography.title.fontSize)
          .fontColor(CouliColors.textPrimary)
          .fontFeature(TABULAR_FEATURE)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          // 高度随字号增长（200% 时固定 52vp 会把数字上下截掉）。
          .constraintSize({ minHeight: INPUT_HEIGHT })
          .accessibilityText(this.t(BindPhoneKeys.PHONE_LABEL) + ' ' + this.t(BindPhoneKeys.PHONE_PREFIX))
          // R1-06：错误说明关联到输入框（读屏聚焦输入框时一并读出）。
          .accessibilityDescription(this.model.phoneError)
          .id('bind_phone_phone')
          .onFocus(() => this.fieldFocused('phone'))
          .onChange((value: string) => {
            if (value !== this.model.phoneText) {
              this.model.phoneText = value;
              this.model.phoneError = '';
              // 换号：作废在途请求（旧号的结果不改页面）、清除并号凭据；倒计时随号码切换。
              this.config.service.invalidate();
              this.refreshTimers();
            }
          })
        if (this.model.phoneText.length > 0) {
          Row() {
            CouliIcon({ name: 'close', iconSize: 16, color: CouliColors.textSecondary })
          }
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .justifyContent(FlexAlign.Center)
          .accessibilityGroup(true)
          .accessibilityText(this.t(BindPhoneKeys.PHONE_CLEAR))
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .onClick(() => {
            this.model.phoneText = '';
            this.config.service.invalidate();
            this.refreshTimers();
          })
        }
      }
      .width('100%')
      .constraintSize({ minHeight: INPUT_HEIGHT })
      .borderRadius(CouliRadius.button)
      .border({ width: 1, color: this.model.phoneError.length > 0 ? CouliColors.statusErrorText : CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      if (this.model.phoneError.length > 0) {
        Text(this.model.phoneError)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .accessibilityRole(AccessibilityRoleType.TEXT)
          .focusable(true)
          .id(ID_PHONE_ERROR)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  codeField() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t(BindPhoneKeys.CODE_LABEL))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .accessibilityLevel('no')
      // 窄屏 / 大字号时发码按钮换到输入框下方（Flex 换行），不截断倒计时文字。
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        TextInput({ text: this.model.codeText, placeholder: this.t(BindPhoneKeys.CODE_PLACEHOLDER) })
          .type(InputType.Number)
          .maxLength(CodeInput.LENGTH)
          .fontSize(CouliTypography.title.fontSize)
          .fontColor(CouliColors.textPrimary)
          .fontFeature(TABULAR_FEATURE)
          .letterSpacing(2)
          .backgroundColor(Color.Transparent)
          .flexGrow(1)
          // 高度随字号增长（200% 时固定 52vp 会把数字上下截掉）。
          .constraintSize({ minWidth: 120, minHeight: INPUT_HEIGHT })
          .accessibilityText(this.t(BindPhoneKeys.CODE_LABEL))
          .accessibilityDescription(this.model.codeError)
          .id('bind_phone_code')
          .onFocus(() => this.fieldFocused('code'))
          .onChange((value: string) => {
            this.model.codeText = CodeInput.sanitize(value);
            this.model.codeError = '';
          })
        Text(this.countdown() > 0 ? this.countdownText() : this.t(BindPhoneKeys.GET_CODE))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote,
            this.countdown() > 0 || this.sendRateLimited() ? CouliColors.textSecondary : CouliColors.brandEmphasis,
            CouliFontWeight.medium, true))
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3 })
          .border({ width: { left: 1 }, color: CouliColors.borderSubtle })
          .textAlign(TextAlign.Center)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .enabled(this.countdown() <= 0 && !this.sendRateLimited() && !this.model.sending)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .id(ID_SEND)
          .onClick(() => {
            this.sendCode();
          })
      }
      .width('100%')
      .constraintSize({ minHeight: INPUT_HEIGHT })
      .padding({ left: CouliSpacing.space1, right: CouliSpacing.space1 })
      .borderRadius(CouliRadius.button)
      .border({ width: 1, color: this.model.codeError.length > 0 ? CouliColors.statusErrorText : CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      if (this.model.codeError.length > 0) {
        Text(this.model.codeError)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .accessibilityRole(AccessibilityRoleType.TEXT)
          .focusable(true)
          .id(ID_CODE_ERROR)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  /** 输入框获焦：键盘已弹起时立即把它滚进可见区；没弹起时等页面收缩后（onAreaChange）再滚。 */
  private fieldFocused(field: string): void {
    this.focusedField = field;
    if (this.model.keyboardShown) {
      this.revealFocused();
    }
  }

  /** 验证码在卡片底部：滚到底（连同发码按钮）；手机号在顶部：滚到顶。 */
  private revealFocused(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(this.focusedField === 'code' ? Edge.Bottom : Edge.Top);
    }, 50);
  }

  private countdownText(): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('sec', String(this.countdown()));
    return this.fmt(BindPhoneKeys.COUNTDOWN, vars);
  }

  build() {
    Column() {
      this.topBar()
      Scroll(this.scroller) {
        Column({ space: CouliSpacing.space3 }) {
          this.note()
          Column({ space: CouliSpacing.space4 }) {
            this.phoneField()
            this.codeField()
          }
          .width('100%')
          .padding(CouliSpacing.space4)
          .borderRadius(CouliRadius.card)
          .backgroundColor(CouliColors.backgroundSurface)
          .shadow(CouliShadow.card)
        }
        .width('100%')
        .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2 })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.None)
      .scrollBar(BarState.Off)
      Column() {
        CouliButton({
          text: this.t(BindPhoneKeys.SUBMIT),
          fullWidth: true,
          loading: this.model.submitting,
          disabled: !this.canSubmit(),
          buttonId: ID_SUBMIT,
          onTap: () => {
            this.bind();
          }
        })
      }
      .width('100%')
      .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      // 键盘弹起时按钮栏贴键盘上沿，下内边距改 8（adaptation-a11y-spec §3）。
      .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space3,
        bottom: this.model.keyboardShown ? CouliSpacing.space2 : CouliSpacing.space6 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    .onAreaChange((_old: Area, now: Area) => {
      const height: number = now.height as number;
      this.maxHeight = Math.max(this.maxHeight, height);
      const shown: boolean = this.maxHeight - height > KEYBOARD_THRESHOLD_VP;
      const opened: boolean = shown && !this.model.keyboardShown;
      this.model.keyboardShown = shown;
      if (opened && this.focusedField.length > 0) {
        this.revealFocused();
      }
    })
  }
}
