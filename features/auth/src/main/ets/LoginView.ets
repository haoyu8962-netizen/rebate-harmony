import {
  AgreementState, AuthFeedback, CodeInput, InviteDecision, InviteField, LoginOutcome, LoginRateLimits, LoginService, OAuthLoginErrorAction,
  OAuthLoginOutcome, OAuthLoginService, OAuthProvider, PhoneNumber, PhoneEntry, PhoneResult, SendCodeOutcome, SmsCountdown
} from 'core';
import {
  CodeCellLayout, CouliButton, CouliLayout, CouliButtonVariant, CouliColors, CouliDialog, CouliDialogLink, CouliDialogOptions, CouliFocus,
  CouliFocusReturn, CouliFontScale, CouliFontWeight, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliToast, CouliTypography, TABULAR_FEATURE
} from 'designsystem';

/**
 * 登录页用到的文案键（BR-TEXT-14；三端同名）。契约 texts.default.json 已有的键（error.*、invite.notice_inviter、
 * login.help_entry）直接取；其余是 entry 草稿表 LoginDraftTexts 里「待定稿，不得提审」的键（TODO(N-26) TEXT-01）。
 * 本模块不出现中文（HM-LINT-1），文案一律经 LoginTexts 取。
 */
export class LoginKeys {
  static readonly BRAND: string = 'login.brand';
  static readonly CLOSE: string = 'login.close';
  static readonly BACK: string = 'login.back';
  static readonly SETTINGS: string = 'login.settings';
  static readonly TITLE: string = 'login.title';
  static readonly PHONE_LABEL: string = 'login.phone.label';
  static readonly PHONE_PREFIX: string = 'login.phone.prefix';
  static readonly PHONE_PLACEHOLDER: string = 'login.phone.placeholder';
  static readonly PHONE_CLEAR: string = 'login.phone.clear';
  static readonly AGREE_PREFIX: string = 'login.agree.prefix';
  static readonly AGREE_AGREEMENT: string = 'login.agree.agreement';
  static readonly AGREE_AND: string = 'login.agree.and';
  static readonly AGREE_PRIVACY: string = 'login.agree.privacy';
  static readonly AGREE_SUFFIX: string = 'login.agree.suffix';
  static readonly AGREE_HINT: string = 'login.agree.hint';
  static readonly GET_CODE: string = 'login.get_code';
  static readonly INVITE_ENTRY: string = 'login.invite.entry';
  static readonly CONTINUE_CODE: string = 'login.code.continue';
  static readonly OTHER_METHODS: string = 'login.other_methods';
  static readonly HUAWEI: string = 'login.huawei';
  /** 微信登录按钮的读屏名称（Login 画板 aria-label「微信登录」）。 */
  static readonly WECHAT: string = 'login.wechat';
  /** 微信按钮下方的短标签（「微信」）。 */
  static readonly WECHAT_SHORT: string = 'login.wechat.short';
  /** 文案变量 {provider_name} 的取值（error.50305、error.30411.mergeable）。 */
  static readonly PROVIDER_PREFIX: string = 'login.provider.';
  static readonly WECHAT_UNAVAILABLE: string = 'login.wechat_unavailable';
  static readonly CONFIRM_TITLE: string = 'login.agree_confirm.title';
  static readonly CONFIRM_BODY: string = 'login.agree_confirm.body';
  static readonly CONFIRM_CANCEL: string = 'login.agree_confirm.cancel';
  static readonly CONFIRM_OK: string = 'login.agree_confirm.ok';
  static readonly CODE_TITLE: string = 'login.code.title';
  static readonly CODE_SENT_TO: string = 'login.code.sent_to';
  static readonly CODE_LABEL: string = 'login.code.label';
  static readonly CODE_COUNTDOWN: string = 'login.code.countdown';
  static readonly CODE_RESEND: string = 'login.code.resend';
  static readonly INVITE_LABEL: string = 'login.invite.label';
  static readonly INVITE_PLACEHOLDER: string = 'login.invite.placeholder';
  static readonly INVITE_CLEAR: string = 'login.invite.clear';
  static readonly SUBMIT: string = 'login.submit';
  static readonly HELP: string = 'login.help_entry';
  static readonly RISK_BLOCKED_DESC: string = 'login.risk_blocked.desc';
  static readonly RISK_BLOCKED_OK: string = 'login.risk_blocked.ok';
  static readonly APPEAL: string = 'cs.appeal_entry';
  static readonly DELETION_TITLE: string = 'error.10007';
  static readonly DELETION_BODY: string = 'login.deletion.body';
  static readonly DELETION_CS: string = 'login.deletion.cs';
  static readonly DELETION_OK: string = 'login.deletion.ok';
  static readonly SESSION_EXPIRED: string = 'error.10404';
  static readonly GENERIC: string = 'error.50001';
}

/** 文案来源（entry 实现：DefaultTexts → 草稿表）。缺键返回空串。 */
export interface LoginTexts {
  text(key: string): string;

  /** 带变量：{name} 替换为 vars[name]；带 trace6 等占位而没给值时用 fallback 文案。 */
  format(key: string, vars: Map<string, string>): string;
}

/** 页面的出口（entry 接 Router 与 App 能力）。 */
export class LoginPageConfig {
  readonly service: LoginService;
  readonly texts: LoginTexts;
  /** 从强更页进入的受限登录（APP-02c 内部来源标记）：不显示设置、登录遇到问题、邀请码与第三方登录。 */
  restricted: boolean = false;
  /** 刷新失败清会话后进入（LoginSessionExpired）：进入时提示 error.10404。 */
  sessionExpired: boolean = false;
  /**
   * LoginPublicHarmony 的【华为账号登录】占位：华为账号登录在 HM-08 / APP-13，本任务不做；只在 Debug 构建显示（版式比对用，
   * 点了不做事），Release 不显示。
   */
  showThirdPartySlot: boolean = false;
  /** 第三方登录执行器（APP-05b）；没有为 null（不显示第三方按钮）。显示哪些按钮由它的适配器决定（visibleProviders）。 */
  oauth: OAuthLoginService | null = null;
  /** 第三方登录成功（页面已由执行器关闭）：entry 弹绑手机引导（routeRaw = bind_phone_guide）等。 */
  onOAuthLoggedIn: (outcome: OAuthLoginOutcome) => void = (_o: OAuthLoginOutcome) => {
  };
  clock: () => number = () => Date.now();
  onClose: () => void = () => {
  };
  onSettings: () => void = () => {
  };
  onHelp: () => void = () => {
  };
  /** 协议链接：type = agreement / privacy（routes.json Agreement.type）。 */
  onAgreement: (type: string) => void = (_t: string) => {
  };
  onCustomerService: () => void = () => {
  };
  /** 登录成功（页面已由执行器关闭）：entry 显示邀请绑定结果等。 */
  onLoggedIn: (outcome: LoginOutcome) => void = (_o: LoginOutcome) => {
  };
  /** 10405（受限登录查不到账号 no_account 等）：提示先更新后回到强更页（BR-ID-01 细则「受限登录」）。 */
  onForceUpdate: () => void = () => {
  };
  /** 系统返回（页面挂上后由 LoginView 设置）：验证码步先回手机号步，返回 true；手机号步返回 false，交给导航关闭。 */
  systemBack: () => boolean = () => false;
  /**
   * 页面重新出现（NavDestination onShown：从协议页等返回、回前台）由 entry 调用（F-HM-09，APP-05a 共性 20）：LoginView 出现时
   * 设为「按当前时钟重算倒计时与限流状态，还有没到期的就重启计时器」。
   */
  pageShown: () => void = () => {
  };

  constructor(service: LoginService, texts: LoginTexts) {
    this.service = service;
    this.texts = texts;
  }
}

/** 页面状态。 */
@ObservedV2
export class LoginModel {
  /** phone：输入手机号；code：输入验证码（LoginCode）。 */
  @Trace step: string = LoginModel.STEP_PHONE;
  @Trace phoneText: string = '';
  @Trace codeText: string = '';
  @Trace inviteText: string = '';
  /** 手机号页点了「有邀请码？」：展开邀请码输入。 */
  @Trace inviteOpen: boolean = false;
  @Trace agreed: boolean = false;
  @Trace countdown: number = 0;
  @Trace sending: boolean = false;
  @Trace submitting: boolean = false;
  @Trace phoneError: string = '';
  @Trace codeError: string = '';
  @Trace sentTo: string = '';
  /** 42901 禁用有变化时递增（禁用截止时刻在 LoginView.limits，发码与登录分开，R2-03）：让按钮状态重新计算。 */
  @Trace rateLimitStamp: number = 0;
  /** 发码结束时递增：「继续输入验证码」入口重新判断（F-HM-08）。 */
  @Trace entryStamp: number = 0;
  @Trace now: number = 0;
  /** 第三方授权进行中（按钮显示加载、不重复点击）。 */
  @Trace oauthBusy: boolean = false;

  static readonly STEP_PHONE: string = 'phone';
  static readonly STEP_CODE: string = 'code';
}

const ROW_ID_CHECKBOX: string = 'login_agree_checkbox';
const ID_GET_CODE: string = 'login_get_code';
const ID_SUBMIT: string = 'login_submit';
const ID_TITLE: string = 'login_title';
const ID_LINK_AGREEMENT: string = 'login_link_agreement';
const ID_LINK_PRIVACY: string = 'login_link_privacy';
const AGREEMENT_TYPE: string = 'agreement';
const PRIVACY_TYPE: string = 'privacy';
const BRAND_SIZE: number = 72;
const BRAND_RADIUS: number = 20;
const BRAND_FONT: number = 22;
const INPUT_HEIGHT: number = 52;
const CHECKBOX: number = 20;

/**
 * 短信登录页（Login / LoginAgreeConfirm / LoginCode / LoginCodeBlocked / LoginCodeInvite / LoginSessionExpired /
 * LoginDeletionProcessing 画板；鸿蒙「其他登录方式」按 LoginPublicHarmony）。一个路由 Login，两步：手机号 → 验证码。
 * 读屏顺序按 A11yFocusLogin：关闭 → 设置 → 标题 → 手机号（含 +86）→ 清除 → 协议复选框（描述为自动注册说明）→ 两个协议链接 →
 * 获取验证码 → 邀请码入口 → 其他登录方式 → 第三方按钮 → 登录遇到问题；品牌方块是装饰。进入页面焦点落在标题，不自动弹键盘。
 */
@ComponentV2
export struct LoginView {
  @Param @Require config: LoginPageConfig;
  @Local model: LoginModel = new LoginModel();
  @Local fontScale: CouliFontScale = CouliFontScale.shared();
  /** 验证码格子行的可用宽度（vp；onAreaChange 测得前为 0，按设计稿格宽）。 */
  @Local codeAreaWidth: number = 0;
  private agreement: AgreementState = new AgreementState(() => Date.now());
  /**
   * 登录按钮的 42901 截止时刻（R2-03：发码限流不禁用登录按钮）。发码的倒计时与 42901 禁用不在页面存：按号码读
   * LoginService.sendState（F-HM-09，APP-05a 共性 21）。
   */
  private limits: LoginRateLimits = new LoginRateLimits();
  /** 第三方登录收到 42901 的禁用截止时刻（只禁第三方按钮，与短信发码 / 登录分开）。 */
  private oauthUntil: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    CouliFontScale.attach(this.getUIContext());
    this.agreement = new AgreementState(this.config.clock);
    this.model.now = this.config.clock();
    this.config.systemBack = (): boolean => this.systemBack();
    this.config.pageShown = (): void => this.refreshTimers();
    if (this.config.sessionExpired) {
      setTimeout(() => {
        CouliToast.show(this.getUIContext(), this.t(LoginKeys.SESSION_EXPIRED));
      }, 300);
    }
  }

  aboutToDisappear(): void {
    this.config.systemBack = () => false;
    this.config.pageShown = () => {
    };
    this.stopTimer();
    // 离开登录页：在途的发码与登录结果不再改页面、不恢复 pending_action（会话若已保存照常生效）。
    this.config.service.invalidateAttempt();
  }

  /** 系统返回：验证码步先回手机号步；手机号步交给导航关闭页面。 */
  systemBack(): boolean {
    if (this.model.step === LoginModel.STEP_CODE) {
      this.backToPhone();
      return true;
    }
    return false;
  }

  private t(key: string): string {
    return this.config.texts.text(key);
  }

  private fmt(key: string, name: string, value: string): string {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set(name, value);
    return this.config.texts.format(key, vars);
  }

  // ---------------------------------------------------------------- 计时

  /**
   * 按当前时钟与当前号码的截止时间重算倒计时、发码限流与登录限流；还有没到期的就（重新）启动每秒刷新，否则停掉。
   * 进入验证码步、发码结果、换号、页面重新出现时都调（F-HM-09，APP-05a 共性 20、21）。
   */
  private refreshTimers(): void {
    this.tick();
    if (this.timer < 0 && this.timerNeeded()) {
      this.timer = setInterval(() => this.tick(), 1000);
    }
  }

  private timerNeeded(): boolean {
    return this.config.service.sendState(this.model.phoneText).needsTimer(this.limits.loginBlocked(this.model.now)
      || this.model.now < this.oauthUntil);
  }

  private tick(): void {
    const now: number = this.config.clock();
    this.model.now = now;
    this.model.countdown = this.config.service.sendState(this.model.phoneText).countdownSec;
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

  /** 发码收到 42901：只禁用这个号码的获取验证码 / 重新获取（截止时间已由 LoginService 按号码记下，R2-03、F-HM-09）。 */
  private disableSend(outcome: SendCodeOutcome): void {
    if (outcome.stateRaw === SmsCountdown.STATE_RATE_LIMITED) {
      this.rateLimitChanged();
    }
  }

  /** 登录收到 42901：只禁用登录按钮（LoginRateLimits.applyLogin）。 */
  private disableLogin(outcome: LoginOutcome): void {
    if (this.limits.applyLogin(outcome, this.config.clock())) {
      this.rateLimitChanged();
    }
  }

  private rateLimitChanged(): void {
    this.model.rateLimitStamp++;
    this.refreshTimers();
  }

  /** 当前号码的发码入口是否因 42901 禁用（按号码读 LoginService；读 rateLimitStamp / now / phoneText 让界面随之刷新）。 */
  private sendRateLimited(): boolean {
    return this.model.rateLimitStamp >= 0 && this.model.now >= 0
      && this.config.service.sendState(this.model.phoneText).rateLimitedSec > 0;
  }

  /** 手机号页的【获取验证码】：发码限流中只有这个号码还有有效的已收验证码时可点（点了回验证码步，R3-01）。 */
  private phoneEntryDisabled(): boolean {
    return this.sendRateLimited() && this.config.service.issuedCodeRemainingSec(this.model.phoneText) <= 0;
  }

  /** 登录按钮是否因 42901 禁用。 */
  private loginRateLimited(): boolean {
    return this.model.rateLimitStamp >= 0 && this.limits.loginBlocked(this.model.now);
  }

  // ---------------------------------------------------------------- 协议

  private toggleAgreement(): void {
    if (this.agreement.checked) {
      this.agreement.uncheck();
    } else {
      this.agreement.check();
    }
    this.model.agreed = this.agreement.checked;
  }

  /** 未勾选时弹 LoginAgreeConfirm；同意后记下点击时刻并继续 next。 */
  private withAgreement(returnFocusId: string, next: () => void): void {
    this.agreement.tapLogin();
    if (this.agreement.consumeProceed()) {
      next();
      return;
    }
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t(LoginKeys.CONFIRM_TITLE);
    options.message = this.t(LoginKeys.CONFIRM_BODY);
    options.primaryText = this.t(LoginKeys.CONFIRM_OK);
    options.secondaryText = this.t(LoginKeys.CONFIRM_CANCEL);
    options.returnFocusId = returnFocusId;
    // R1-13：正文里的《用户协议》《隐私政策》是两个可点、读屏可单独聚焦的链接；点链接关闭确认框（不算同意）并打开协议正文。
    options.links = [new CouliDialogLink(this.t(LoginKeys.AGREE_AGREEMENT), AGREEMENT_TYPE),
      new CouliDialogLink(this.t(LoginKeys.AGREE_PRIVACY), PRIVACY_TYPE)];
    options.onLink = (type: string) => {
      this.agreement.cancel();
      this.config.onAgreement(type);
    };
    options.onPrimary = () => {
      this.agreement.confirm(this.config.clock());
      this.model.agreed = true;
      if (this.agreement.consumeProceed()) {
        next();
      }
    };
    options.onSecondary = () => {
      this.agreement.cancel();
    };
    CouliDialog.open(this.getUIContext(), options);
  }

  // ---------------------------------------------------------------- 发码与登录

  private requestCode(): void {
    const phone: PhoneResult = PhoneNumber.normalize(this.model.phoneText);
    if (!phone.valid) {
      this.model.phoneError = this.t('error.20001.phone_invalid');
      return;
    }
    this.model.phoneError = '';
    // R1-05 / R3-01：这个号码已收到的码仍有效、此刻又不能再发（成功发码的倒计时没到，或发码 42901 限流中）：不发码，
    // 直接回到验证码步继续输入已收到的码。「继续输入」与「重新发码」分开，限流只禁后者。
    if (this.model.step === LoginModel.STEP_PHONE) {
      const entry: PhoneEntry = this.config.service.phoneEntry(this.model.phoneText, this.sendRateLimited());
      if (entry.kind === PhoneEntry.CONTINUE && entry.phone !== null) {
        this.enterCodeStep(entry.phone, entry.countdownSec);
        return;
      }
      if (this.sendRateLimited()) {
        return;
      }
    }
    this.withAgreement(this.model.step === LoginModel.STEP_PHONE ? ID_GET_CODE : ID_SUBMIT, () => {
      this.sendCode();
    });
  }

  /** 当前号码的「继续输入验证码」入口；没有为 null（读 phoneText 让界面随输入刷新）。 */
  private continueEntry(): PhoneEntry | null {
    const entry: PhoneEntry = this.config.service.continueEntry(this.model.phoneText);
    return entry.kind === PhoneEntry.CONTINUE ? entry : null;
  }

  private enterCodeStep(normalizedPhone: string, _seconds: number): void {
    this.model.sentTo = PhoneNumber.masked(normalizedPhone);
    this.model.codeText = '';
    this.model.codeError = '';
    this.model.step = LoginModel.STEP_CODE;
    // 倒计时按这个号码保存的截止时间现算（_seconds 与之相同，只作说明）。
    this.refreshTimers();
  }

  private async sendCode(): Promise<void> {
    if (this.model.sending) {
      return;
    }
    this.model.sending = true;
    let outcome: SendCodeOutcome;
    try {
      outcome = await this.config.service.sendCode(this.model.phoneText);
    } finally {
      this.model.sending = false;
      this.model.entryStamp++;
    }
    switch (outcome.stateRaw) {
      case SmsCountdown.STATE_SENT:
      case LoginService.STATE_COUNTDOWN:
        // 发码成功，或这个号码的倒计时还没到（不再发出，R1-05）：进验证码步，倒计时按剩余秒数。
        if (this.model.step === LoginModel.STEP_CODE && outcome.stateRaw === LoginService.STATE_COUNTDOWN) {
          this.refreshTimers();
          return;
        }
        this.enterCodeStep(outcome.phone ?? '', outcome.countdownSec);
        return;
      case SmsCountdown.STATE_RATE_LIMITED:
        this.disableSend(outcome);
        this.toast(outcome.textKey, outcome.trace6);
        return;
      case LoginOutcome.STALE:
      case LoginOutcome.BUSY:
        return;
      default:
        if (outcome.field === 'phone') {
          this.model.phoneError = this.t(outcome.textKey ?? 'error.20001');
          if (this.model.step === LoginModel.STEP_CODE) {
            this.toast(outcome.textKey, outcome.trace6);
          }
          return;
        }
        this.toast(outcome.textKey, outcome.trace6);
    }
  }

  private submit(): void {
    if (!CodeInput.accept(this.model.codeText).complete || this.model.submitting) {
      return;
    }
    this.withAgreement(ID_SUBMIT, () => {
      this.login();
    });
  }

  private async login(): Promise<void> {
    this.model.submitting = true;
    let outcome: LoginOutcome;
    try {
      outcome = await this.config.service.login(this.model.phoneText, this.model.codeText,
        this.agreement.consentAtMillis, this.config.restricted ? '' : this.model.inviteText, this.config.restricted);
    } finally {
      this.model.submitting = false;
    }
    switch (outcome.stateRaw) {
      case LoginOutcome.LOGGED_IN:
        this.stopTimer();
        this.config.onLoggedIn(outcome);
        return;
      case LoginOutcome.STALE:
      case LoginOutcome.BUSY:
      case LoginOutcome.AGREEMENT_REQUIRED:
      case LoginOutcome.CODE_INCOMPLETE:
        return;
      case 'code_error':
        this.model.codeError = this.t(outcome.textKey ?? 'error.20002');
        return;
      case 'code_expired':
        this.model.codeError = this.t(outcome.textKey ?? 'error.20003');
        this.model.codeText = '';
        return;
      case 'rate_limited':
        this.disableLogin(outcome);
        this.toast(outcome.textKey, outcome.trace6);
        return;
      case 'registration_blocked':
        this.showBlocked(outcome);
        return;
      case 'deletion_processing':
        this.showDeletionProcessing();
        return;
      case 'field_error':
        if (outcome.field === 'phone') {
          this.backToPhone();
          this.model.phoneError = this.t(outcome.textKey ?? 'error.20001');
          return;
        }
        if (outcome.field === 'code') {
          this.model.codeError = this.t(outcome.textKey ?? 'error.20001');
          return;
        }
        this.toast(outcome.textKey, outcome.trace6);
        return;
      case 'force_update':
        // 10405：网络层已进强更状态；提示先更新（error.10405.no_account），关闭登录页回到强更页。
        this.stopTimer();
        this.toast(outcome.textKey, outcome.trace6);
        this.config.onForceUpdate();
        return;
      default:
        // session_expired、service_error、network_error 等：提示。
        this.toast(outcome.textKey, outcome.trace6);
    }
  }

  private toast(key: string | null, trace6: string): void {
    const text: string = this.fmt(key ?? LoginKeys.GENERIC, 'trace6', trace6);
    if (text.length > 0) {
      CouliToast.show(this.getUIContext(), text);
    }
  }

  /** LoginCodeBlocked：不建号，手机号保留，验证码清空需重新获取（BR-ID-05、BR-TEXT-14 login.risk_blocked.desc）。 */
  private showBlocked(outcome: LoginOutcome): void {
    this.model.codeText = '';
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t(outcome.textKey ?? 'error.44001');
    options.message = this.t(LoginKeys.RISK_BLOCKED_DESC);
    options.primaryText = this.t(LoginKeys.RISK_BLOCKED_OK);
    options.secondaryText = this.t(LoginKeys.APPEAL);
    options.dismissOnMask = false;
    options.returnFocusId = ID_SUBMIT;
    options.onSecondary = () => this.config.onCustomerService();
    CouliDialog.open(this.getUIContext(), options);
  }

  /** LoginDeletionProcessing：注销处理中的账号不能登录（10007 stage=processing，BR-ID-27）。 */
  private showDeletionProcessing(): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t(LoginKeys.DELETION_TITLE);
    options.message = this.t(LoginKeys.DELETION_BODY);
    options.primaryText = this.t(LoginKeys.DELETION_OK);
    options.secondaryText = this.t(LoginKeys.DELETION_CS);
    options.returnFocusId = ID_SUBMIT;
    options.onSecondary = () => this.config.onCustomerService();
    CouliDialog.open(this.getUIContext(), options);
  }

  // ---------------------------------------------------------------- 第三方登录（APP-05b）

  private providers(): string[] {
    const oauth: OAuthLoginService | null = this.config.oauth;
    return oauth === null || this.config.restricted ? [] : oauth.visibleProviders();
  }

  private oauthBlocked(): boolean {
    return this.model.rateLimitStamp >= 0 && this.model.now < this.oauthUntil;
  }

  private providerName(provider: string): string {
    return this.t(LoginKeys.PROVIDER_PREFIX + provider);
  }

  /** 点第三方按钮：与短信登录同一套协议确认（未勾选先弹确认框，同意时刻作 consent_at，BR-ID-04 例）。 */
  private tapProvider(provider: string, focusId: string): void {
    if (this.model.oauthBusy || this.oauthBlocked() || this.model.sending || this.model.submitting) {
      return;
    }
    this.withAgreement(focusId, () => {
      this.loginWith(provider);
    });
  }

  private async loginWith(provider: string): Promise<void> {
    const oauth: OAuthLoginService | null = this.config.oauth;
    if (oauth === null) {
      return;
    }
    this.model.oauthBusy = true;
    let outcome: OAuthLoginOutcome;
    try {
      outcome = await oauth.loginWith(provider, this.agreement.consentAtMillis);
    } finally {
      this.model.oauthBusy = false;
    }
    switch (outcome.stateRaw) {
      case OAuthLoginOutcome.LOGGED_IN:
        this.stopTimer();
        this.config.onOAuthLoggedIn(outcome);
        return;
      case OAuthLoginOutcome.CANCELLED:
      case LoginOutcome.STALE:
      case LoginOutcome.BUSY:
      case LoginOutcome.AGREEMENT_REQUIRED:
        // 用户自己取消、离页或迟到：不提示，保留全部登录方式。
        return;
      case OAuthLoginErrorAction.RETRY_AFTER:
        this.oauthUntil = Math.max(this.oauthUntil, this.config.clock() + Math.max(0, outcome.disableMillis));
        this.rateLimitChanged();
        this.oauthToast(outcome, provider);
        return;
      case OAuthLoginErrorAction.FORCE_UPDATE:
        this.stopTimer();
        this.oauthToast(outcome, provider);
        this.config.onForceUpdate();
        return;
      default: {
        // risk_blocked（44001，R1-05）：弹窗给申诉入口（BR-TEXT-14 表 A），不套用短信登录专用说明。
        const feedback: AuthFeedback = AuthFeedback.ofOAuth(outcome);
        if (feedback.kind === AuthFeedback.RISK_DIALOG) {
          this.showOAuthRiskBlocked(feedback, provider);
          return;
        }
        // reauthorize（20004、超时、state 不符：用户重新点一次即重新取尝试）、provider_unavailable（50305：改用其他方式）、
        // unavailable（拉不起）、service_error 等：提示，不自动重试。
        this.oauthToast(outcome, provider);
      }
    }
  }

  /** 第三方登录 44001：标题 error.44001，【知道了】/【联系客服申诉】（统一客服出口）；焦点回到该登录方式按钮。 */
  private showOAuthRiskBlocked(feedback: AuthFeedback, provider: string): void {
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t(feedback.textKey ?? AuthFeedback.RISK_KEY);
    options.message = feedback.descKey === null ? '' : this.t(feedback.descKey);
    options.primaryText = this.t(LoginKeys.RISK_BLOCKED_OK);
    options.secondaryText = this.t(LoginKeys.APPEAL);
    options.dismissOnMask = false;
    options.returnFocusId = 'login_oauth_' + provider;
    options.onSecondary = () => this.config.onCustomerService();
    CouliDialog.open(this.getUIContext(), options);
  }

  private oauthToast(outcome: OAuthLoginOutcome, provider: string): void {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('trace6', outcome.trace6);
    vars.set('provider_name', this.providerName(provider));
    const text: string = this.config.texts.format(outcome.textKey ?? LoginKeys.GENERIC, vars);
    if (text.length > 0) {
      CouliToast.show(this.getUIContext(), text);
    }
  }

  private backToPhone(): void {
    this.config.service.invalidateAttempt();
    this.model.step = LoginModel.STEP_PHONE;
    this.model.codeText = '';
    this.model.codeError = '';
  }

  // ---------------------------------------------------------------- 界面

  @Builder
  topBar() {
    Row() {
      Row() {
        CouliIcon({ name: this.model.step === LoginModel.STEP_CODE ? 'back' : 'close', iconSize: 24 })
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .justifyContent(FlexAlign.Center)
      .accessibilityGroup(true)
      .accessibilityText(this.t(this.model.step === LoginModel.STEP_CODE ? LoginKeys.BACK : LoginKeys.CLOSE))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .id('login_close')
      .onClick(() => {
        if (this.model.step === LoginModel.STEP_CODE) {
          this.backToPhone();
        } else {
          this.config.onClose();
        }
      })
      Blank()
      if (!this.config.restricted) {
        Text(this.t(LoginKeys.SETTINGS))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.brandEmphasis, CouliFontWeight.medium))
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
          .textAlign(TextAlign.End)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .id('login_settings')
          .onClick(() => this.config.onSettings())
      }
    }
    .width('100%')
    .padding({ left: CouliSpacing.space2, right: CouliSpacing.space4 })
  }

  /** 协议链接（R1-06）：各自至少 48vp 的独立命中区，与勾选单元分开；读屏单独聚焦（超链接角色）。 */
  @Builder
  agreementLink(key: string, type: string, id: string) {
    Text(this.t(key))
      .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textLink))
      .constraintSize({ minHeight: CouliInteraction.minTouchTarget, minWidth: CouliInteraction.minTouchTarget })
      .textAlign(TextAlign.Center)
      .accessibilityRole(AccessibilityRoleType.HYPERLINK)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .id(id)
      .onClick(() => this.config.onAgreement(type))
  }

  /**
   * 协议行（BR-ID-04；A11yFocusLogin 第 6–8 项、A11yHitLogin）：一行可换行的 Flex——
   * 「复选框 +『我已阅读并同意』」是一个读屏单元、一个命中区（复选框角色，描述为自动注册说明），点它切换勾选；
   * 《用户协议》《隐私政策》是两个独立链接，各自 48vp 命中区（R1-06：原先链接只有文字行高，点文字上下会落到父行的勾选）。
   * 窄屏、大字号时整节换行，命中区不重叠。
   */
  @Builder
  agreementRow() {
    Column({ space: CouliSpacing.space1 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Row({ space: CouliSpacing.space3 }) {
          Row() {
            if (this.model.agreed) {
              CouliIcon({ name: 'check', iconSize: 14, color: CouliColors.textInverse })
            }
          }
          .width(CHECKBOX)
          .height(CHECKBOX)
          .justifyContent(FlexAlign.Center)
          .borderRadius(CouliRadius.small)
          .border({ width: this.model.agreed ? 0 : 1.5, color: CouliColors.borderControl })
          .backgroundColor(this.model.agreed ? CouliColors.brandPrimary : CouliColors.backgroundSurface)
          Text(this.t(LoginKeys.AGREE_PREFIX))
            .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        }
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .accessibilityGroup(true)
        .accessibilityText(this.t(LoginKeys.AGREE_PREFIX))
        .accessibilityDescription(this.t(LoginKeys.AGREE_HINT))
        .accessibilityRole(AccessibilityRoleType.CHECKBOX)
        .accessibilityChecked(this.model.agreed)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .id(ROW_ID_CHECKBOX)
        .onClick(() => this.toggleAgreement())
        this.agreementLink(LoginKeys.AGREE_AGREEMENT, AGREEMENT_TYPE, ID_LINK_AGREEMENT)
        Text(this.t(LoginKeys.AGREE_AND))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .accessibilityLevel('no')
        this.agreementLink(LoginKeys.AGREE_PRIVACY, PRIVACY_TYPE, ID_LINK_PRIVACY)
        Text(this.t(LoginKeys.AGREE_SUFFIX))
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
          .accessibilityLevel('no')
      }
      .width('100%')
      Text(this.t(LoginKeys.AGREE_HINT))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .padding({ left: CHECKBOX + CouliSpacing.space3 })
        .accessibilityLevel('no')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  phoneField() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t(LoginKeys.PHONE_LABEL))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .accessibilityLevel('no')
      Row() {
        Text(this.t(LoginKeys.PHONE_PREFIX))
          .attributeModifier(new CouliTextModifier(CouliTypography.title, CouliColors.textPrimary))
          .padding({ left: CouliSpacing.space4, right: CouliSpacing.space3 })
          .accessibilityLevel('no')
        Divider().vertical(true).height(24).color(CouliColors.borderSubtle)
        TextInput({ text: this.model.phoneText, placeholder: this.t(LoginKeys.PHONE_PLACEHOLDER) })
          // F-HM-08（APP-05a 共性 15，BR-ID-05）：不预先过滤或截断字符——InputType.PhoneNumber 会吞掉字母等字符、maxLength
          // 会截断粘贴，改为普通输入，原样交给 PhoneNumber.normalize 校验（含非法字符报 phone_invalid）。
          .type(InputType.Normal)
          .fontSize(CouliTypography.title.fontSize)
          .fontColor(CouliColors.textPrimary)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(INPUT_HEIGHT)
          .accessibilityText(this.t(LoginKeys.PHONE_LABEL) + ' ' + this.t(LoginKeys.PHONE_PREFIX))
          .id('login_phone')
          .onChange((value: string) => {
            if (value !== this.model.phoneText) {
              this.model.phoneText = value;
              this.model.phoneError = '';
              // 换号：作废在途发码（旧号的结果不再改页面）；发码状态随号码切换（F-HM-09）。
              this.config.service.invalidateAttempt();
              this.refreshTimers();
            }
          })
        if (this.model.phoneText.length > 0) {
          Row() {
            CouliIcon({ name: 'close', iconSize: 18, color: CouliColors.textSecondary })
          }
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .justifyContent(FlexAlign.Center)
          .accessibilityGroup(true)
          .accessibilityText(this.t(LoginKeys.PHONE_CLEAR))
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .onClick(() => {
            this.model.phoneText = '';
            this.config.service.invalidateAttempt();
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
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  inviteField() {
    Column({ space: CouliSpacing.space2 }) {
      Text(this.t(LoginKeys.INVITE_LABEL))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
        .accessibilityLevel('no')
      Row() {
        TextInput({ text: this.model.inviteText, placeholder: this.t(LoginKeys.INVITE_PLACEHOLDER) })
          .maxLength(32)
          .fontSize(CouliTypography.title.fontSize)
          .fontColor(CouliColors.textPrimary)
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(INPUT_HEIGHT)
          .accessibilityText(this.t(LoginKeys.INVITE_LABEL))
          .id('login_invite')
          .onChange((value: string) => {
            this.model.inviteText = value;
          })
        if (this.model.inviteText.length > 0) {
          Row() {
            CouliIcon({ name: 'close', iconSize: 18, color: CouliColors.textSecondary })
          }
          .width(CouliInteraction.minTouchTarget)
          .height(CouliInteraction.minTouchTarget)
          .justifyContent(FlexAlign.Center)
          .accessibilityGroup(true)
          .accessibilityText(this.t(LoginKeys.INVITE_CLEAR))
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .onClick(() => {
            this.model.inviteText = '';
          })
        }
      }
      .width('100%')
      .padding({ left: CouliSpacing.space2 })
      .borderRadius(CouliRadius.button)
      .border({ width: 1, color: CouliColors.borderControl })
      .backgroundColor(CouliColors.backgroundSurface)
      // 告知句（BR-INV-18 细则）：输入框下方，有效码与无效码都显示；语法不对不拦登录（INVITE-01）。
      Text(this.t(this.inviteDecision().noticeKey ?? InviteField.NOTICE_KEY))
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textSecondary))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  private inviteDecision(): InviteDecision {
    const context: Record<string, Object> = {};
    context['restricted'] = this.config.restricted;
    return InviteField.decide(this.model.inviteText, context);
  }

  /** 圆形图标 + 短标签的第三方按钮（Login 画板「微信」：48vp 圆、描边、下方 12 号标签；整体一个读屏单元）。 */
  @Builder
  providerButton(provider: string) {
    Column({ space: CouliSpacing.space1 }) {
      Row() {
        if (this.model.oauthBusy) {
          LoadingProgress().width(24).height(24).color(CouliColors.textSecondary)
        } else {
          CouliIcon({ name: 'chat', iconSize: 24, color: CouliColors.textSecondary })
        }
      }
      .width(CouliInteraction.minTouchTarget)
      .height(CouliInteraction.minTouchTarget)
      .justifyContent(FlexAlign.Center)
      .borderRadius(CouliRadius.pill)
      .border({ width: 1, color: CouliColors.borderSubtle })
      .backgroundColor(CouliColors.backgroundSurface)
      Text(this.t(LoginKeys.WECHAT_SHORT))
        .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
    }
    .constraintSize({ minWidth: 64, minHeight: CouliInteraction.minTouchTarget })
    .opacity(this.oauthBlocked() ? 0.4 : 1)
    .accessibilityGroup(true)
    .accessibilityText(this.t(LoginKeys.WECHAT))
    .accessibilityRole(AccessibilityRoleType.BUTTON)
    .enabled(!this.oauthBlocked())
    .focusable(true)
    .focusBox(CouliFocus.box)
    .id('login_oauth_' + provider)
    .onClick(() => this.tapProvider(provider, 'login_oauth_' + provider))
  }

  @Builder
  thirdPartySlot() {
    // 「其他登录方式」（Login 画板的第三方按钮区；鸿蒙按 LoginPublicHarmony）。微信按钮只在适配器可用、本机装了微信（检测未知
    // 按照常显示）时出现（BR-ID-04 细则）：鸿蒙正式适配器不可用，Release 不显示；Debug 假适配器只用于测试与截图。
    // 鸿蒙没有 Apple 登录（向量 appleButton）；华为账号登录在 HM-08，Debug 只放版式占位（showThirdPartySlot）。
    Column({ space: CouliSpacing.space3 }) {
      Row({ space: CouliSpacing.space3 }) {
        Divider().color(CouliColors.borderSubtle).layoutWeight(1)
        Text(this.t(LoginKeys.OTHER_METHODS))
          .attributeModifier(new CouliTextModifier(CouliTypography.caption, CouliColors.textSecondary))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        Divider().color(CouliColors.borderSubtle).layoutWeight(1)
      }
      .width('100%')
      if (this.providers().length > 0) {
        Row({ space: 40 }) {
          ForEach(this.providers(), (provider: string) => {
            if (provider === OAuthProvider.WECHAT) {
              this.providerButton(provider)
            }
          }, (provider: string) => provider)
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
      }
      if (this.config.showThirdPartySlot) {
        CouliButton({ text: this.t(LoginKeys.HUAWEI), variant: CouliButtonVariant.SECONDARY, fullWidth: true, disabled: false })
      }
    }
    .width('100%')
  }

  @Builder
  helpEntry() {
    if (!this.config.restricted) {
      Text(this.t(LoginKeys.HELP))
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.brandEmphasis, CouliFontWeight.medium))
        .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
        .textAlign(TextAlign.Center)
        .accessibilityRole(AccessibilityRoleType.BUTTON)
        .focusable(true)
        .focusBox(CouliFocus.box)
        .id('login_help')
        .onClick(() => this.config.onHelp())
    }
  }

  @Builder
  phoneStep() {
    Column({ space: CouliSpacing.space5 }) {
      Column({ space: CouliSpacing.space4 }) {
        Text(this.t(LoginKeys.BRAND))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textInverse, CouliFontWeight.bold))
          // 品牌方块是图形（设计稿 AdaptLargeText200Login：Logo 不随字号放大）：字号不随系统字号缩放。
          .fontSize(BRAND_FONT + 'vp')
          .maxFontScale(1)
          .letterSpacing(2)
          .textAlign(TextAlign.Center)
          .width(BRAND_SIZE)
          .height(BRAND_SIZE)
          .borderRadius(BRAND_RADIUS)
          .backgroundColor(CouliColors.brandPrimary)
          .accessibilityLevel('no')
        Text(this.t(LoginKeys.TITLE))
          .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary, CouliFontWeight.bold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
          .focusable(true)
          .id(ID_TITLE)
          .onAppear(() => CouliFocusReturn.accessibilityFocus(this.getUIContext(), ID_TITLE))
      }
      .width('100%')
      .margin({ top: CouliSpacing.space4 })
      this.phoneField()
      this.agreementRow()
      CouliButton({
        text: this.t(LoginKeys.GET_CODE),
        fullWidth: true,
        loading: this.model.sending,
        disabled: this.phoneEntryDisabled(),
        buttonId: ID_GET_CODE,
        onTap: () => this.requestCode()
      })
      // F-HM-08（APP-05a 共性 16）：独立的「继续输入验证码」入口——这个号码可能收到、仍有效的码就显示，不看能否重发
      // （发码 50401 等结果不确定时同样提供）。entryStamp 让发码结束后重新判断。
      if (this.model.entryStamp >= 0 && this.continueEntry() !== null) {
        Text(this.t(LoginKeys.CONTINUE_CODE))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.brandEmphasis))
          .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
          .textAlign(TextAlign.Center)
          .accessibilityRole(AccessibilityRoleType.BUTTON)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .id('login_continue_code')
          .onClick(() => {
            const entry: PhoneEntry | null = this.continueEntry();
            if (entry !== null && entry.phone !== null) {
              this.enterCodeStep(entry.phone, entry.countdownSec);
            }
          })
      }
      if (!this.config.restricted) {
        if (this.model.inviteOpen) {
          this.inviteField()
        } else {
          Text(this.t(LoginKeys.INVITE_ENTRY))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.brandEmphasis))
            .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
            .textAlign(TextAlign.Center)
            .accessibilityRole(AccessibilityRoleType.BUTTON)
            .focusable(true)
            .focusBox(CouliFocus.box)
            .id('login_invite_entry')
            .onClick(() => {
              this.model.inviteOpen = true;
            })
        }
      }
      Blank().layoutWeight(1)
      if (!this.config.restricted && (this.config.showThirdPartySlot || this.providers().length > 0)) {
        this.thirdPartySlot()
      }
      this.helpEntry()
    }
    .width('100%')
    .constraintSize({ minHeight: '100%' })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space6 })
  }

  /**
   * 6 个验证码格子（R1-07）：格宽按可用宽度分配（320vp 宽也在一行内），数字字号随系统字号放大但不超过格子容纳得下的大小，
   * 格高随字号增高（CodeCellLayout）；六位都完整可见。上面盖一个透明输入框。
   */
  @Builder
  codeBoxes() {
    Stack() {
      Row() {
        ForEach([0, 1, 2, 3, 4, 5], (index: number) => {
          Text(index < this.model.codeText.length ? this.model.codeText.charAt(index) : '')
            .fontSize(this.codeLayout().fontSize + 'vp')
            .lineHeight(this.codeLayout().cellHeight + 'vp')
            .fontColor(CouliColors.textPrimary)
            .fontWeight(CouliFontWeight.bold)
            .fontFeature(TABULAR_FEATURE)
            .maxLines(1)
            .textAlign(TextAlign.Center)
            .width(this.codeLayout().cellWidth)
            .height(this.codeLayout().cellHeight)
            .borderRadius(CouliRadius.button)
            .border({
              width: index === this.model.codeText.length ? 2 : 1,
              color: index === this.model.codeText.length ? CouliColors.focusRing :
                (this.model.codeError.length > 0 ? CouliColors.statusErrorText : CouliColors.borderControl)
            })
            .backgroundColor(CouliColors.backgroundSurface)
        }, (index: number) => String(index))
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .accessibilityLevel('no-hide-descendants')
      // 一个透明的输入框盖在 6 个格子上：读屏读「验证码，文本框，已输入的数字」，键盘只弹数字。
      TextInput({ text: this.model.codeText })
        .type(InputType.Number)
        .maxLength(CodeInput.LENGTH)
        .opacity(0.01)
        .fontColor(Color.Transparent)
        .placeholderColor(Color.Transparent)
        .caretColor(Color.Transparent)
        .width('100%')
        .height(this.codeLayout().cellHeight)
        .accessibilityText(this.t(LoginKeys.CODE_LABEL))
        .id('login_code')
        .defaultFocus(true)
        .onChange((value: string) => {
          const clean: string = CodeInput.sanitize(value);
          this.model.codeText = clean;
          this.model.codeError = '';
        })
    }
    .width('100%')
    .onAreaChange((_old: Area, now: Area) => {
      this.codeAreaWidth = now.width as number;
    })
  }

  private codeLayout(): CodeCellLayout {
    return CodeCellLayout.compute(this.codeAreaWidth, CodeInput.LENGTH, this.fontScale.scale);
  }

  @Builder
  codeStep() {
    Column({ space: CouliSpacing.space5 }) {
      Column({ space: CouliSpacing.space2 }) {
        Text(this.t(LoginKeys.CODE_TITLE))
          .attributeModifier(new CouliTextModifier(CouliTypography.heading, CouliColors.textPrimary, CouliFontWeight.bold))
          .accessibilityRole(AccessibilityRoleType.TITLE_BAR)
        Text(this.fmt(LoginKeys.CODE_SENT_TO, 'phone', this.model.sentTo))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: CouliSpacing.space4 })
      this.codeBoxes()
      if (this.model.codeError.length > 0) {
        Text(this.model.codeError)
          .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.statusErrorText))
          .width('100%')
      }
      Row() {
        Blank()
        if (this.model.countdown > 0) {
          Text(this.fmt(LoginKeys.CODE_COUNTDOWN, 'sec', String(this.model.countdown)))
            .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary, undefined, true))
        } else {
          Text(this.t(LoginKeys.CODE_RESEND))
            .attributeModifier(new CouliTextModifier(CouliTypography.body,
              this.sendRateLimited() ? CouliColors.textSecondary : CouliColors.brandEmphasis, CouliFontWeight.medium))
            .constraintSize({ minHeight: CouliInteraction.minTouchTarget })
            .accessibilityRole(AccessibilityRoleType.BUTTON)
            .enabled(!this.sendRateLimited() && !this.model.sending)
            .focusable(true)
            .focusBox(CouliFocus.box)
            .id('login_resend')
            .onClick(() => this.requestCode())
        }
      }
      .width('100%')
      if (!this.config.restricted) {
        this.inviteField()
      }
      this.agreementRow()
      CouliButton({
        text: this.t(LoginKeys.SUBMIT),
        fullWidth: true,
        loading: this.model.submitting,
        disabled: !CodeInput.accept(this.model.codeText).complete || this.loginRateLimited(),
        buttonId: ID_SUBMIT,
        onTap: () => this.submit()
      })
      Blank().layoutWeight(1)
      this.helpEntry()
    }
    .width('100%')
    .constraintSize({ minHeight: '100%' })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, bottom: CouliSpacing.space6 })
  }

  build() {
    Column() {
      this.topBar()
      Scroll() {
        // F-HM-08（APP-05a 共性 17，03 §10.4）：大屏上内容限宽并水平居中（Scroll 的 Alignment.Top 即上方居中）。
        Column() {
          if (this.model.step === LoginModel.STEP_CODE) {
            this.codeStep()
          } else {
            this.phoneStep()
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: CouliLayout.maxContentWidth })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.None)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
