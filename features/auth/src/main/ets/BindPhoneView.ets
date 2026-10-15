import { KeyboardAvoidMode } from '@kit.ArkUI';
import {
  AccountPendingView, AuthAnnouncement, AuthFeedback, BindOutcome, BindPhoneAction, BindPhoneAnnouncer, BindPhoneFields, BindPhoneForm,
  BindPhoneFormBinding, BindPhoneIdentity, BindPhonePagePermit, BindPhoneService, CodeInput, LoginSendState, MergeDecision, MergeResult, PhoneNumber, PhoneResult,
  BindPhoneTicker, SendCodeOutcome, SmsCountdown
} from 'core';
import {
  CouliAnnounce, CouliButton, CouliColors, CouliDialog, CouliDialogOptions, CouliFocus, CouliFocusReturn, CouliFontWeight, CouliIcon,
  CouliInteraction, CouliLayout, CouliRadius, CouliShadow, CouliSpacing, CouliTextModifier, CouliToast, CouliTypography,
  TABULAR_FEATURE, CouliFormat, PendingConfirmCard, PendingSummaryRow, PriceTerms
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
  /**
   * 绑定成功（会话状态已刷新）：entry 只退出本页这一个导航实例并恢复待办。R3-03：只在本页许可仍有效时调（离页后迟到的成功不调）。
   */
  onBound: () => void = () => {
  };
  /**
   * 错误码要求跳页（10007 stage=cooling → DeleteAccount，R2-03）：entry 经 Router 打开（守卫照常判定），本页不弹提示。
   */
  onNavigate: (route: string) => void = (_route: string) => {
  };
  /** 页面回到可见（entry 的 NavDestination.onShown 调）：按未决记录恢复待确认。由视图设置。 */
  pageShown: () => void = () => {
  };
  /**
   * 页面被盖住 / 进后台（entry 的 NavDestination.onHidden 调，FU-HM-0720，APP-05b 共性 22）：之前发起的写请求结果不再弹窗、提示、改页面。
   * 由视图设置。
   */
  pageHidden: () => void = () => {
  };
  /**
   * 页面确定出栈（entry 的 NavDestination.onWillDisappear 调，早于 aboutToDisappear）：同步作废本页实例的页面许可（R3-01、R3-03）。
   * 由视图设置。
   */
  pageLeft: () => void = () => {
  };
  /**
   * 本页实例建好表单时调（视图 aboutToAppear）：entry 按需做老用户 phone_bound 补查（F-HM-31），补查持有本页许可。
   */
  recheck: (form: BindPhoneForm) => void = (_form: BindPhoneForm) => {
  };
  /**
   * 补查已绑且本页许可仍有效（F-HM-31）：entry 只退出本页这一个导航实例（不按路由名移除）。
   */
  onRecheckBound: () => void = () => {
  };

  constructor(service: BindPhoneService, texts: LoginTexts) {
    this.service = service;
    this.texts = texts;
  }
}

@ObservedV2
export class BindPhoneModel implements BindPhoneFields {
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
  /** APP-13a G07：本账号 bindPhone 出现过结果未知的未决记录（首次绑定与换号共用）：待确认卡，表单置灰。 */
  @Trace pending: AccountPendingView | null = null;
  @Trace pendingBusy: boolean = false;
  @Trace pendingWarning: string = '';
  /** 待确认版本（结算一次加 1）：确认 / 放弃回调绑定渲染时的版本。 */
  @Trace pendingVersion: number = 0;
  /** 换号与绑手机共用的 phoneGate（42901）禁用中（harmony-review-r1 R1-03）：【绑定】与待确认两个按钮置灰。 */
  @Trace gateActive: boolean = false;
}

/** 待确认卡按钮的渲染时绑定（原键、版本、渲染时的页面固定身份；R1-01：执行时只比较）。 */
class PendingBinding {
  readonly key: string;
  readonly version: number;
  readonly identity: BindPhoneIdentity;

  constructor(key: string, version: number, identity: BindPhoneIdentity) {
    this.key = key;
    this.version = version;
    this.identity = identity;
  }
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
  /** 倒计时 / 限流每秒刷新（FU-HM-0720 R2-01：Core BindPhoneTicker，aboutToAppear 里建）。 */
  private ticker: BindPhoneTicker | null = null;
  /** 进页前的键盘避让方式（离页时恢复）。 */
  private savedAvoidMode: KeyboardAvoidMode | null = null;
  /** 页面出现以来的最大高度（判断键盘是否弹起）。 */
  private maxHeight: number = 0;
  private readonly scroller: Scroller = new Scroller();
  /** 当前获焦的输入框（phone / code）：键盘弹起后把它滚到可见区（adaptation-a11y-spec §3：当前输入项完整露出）。 */
  private focusedField: string = '';
  /** 读屏状态播报（R2-04）：发码成功播报一次脱敏发送对象；倒计时结束、可重发时播报一次；离页后不播报。 */
  private readonly announcer: BindPhoneAnnouncer = new BindPhoneAnnouncer();
  /**
   * 本页实例的固定身份（harmony-review-r1 R1-01，S0）：账号、登录世代、会话作用域、页面实例号。会话换代时同步作废旧实例与弹窗、清空
   * 全部输入与倒计时，再按新身份建新实例（resetForSession）。
   */
  private identity: BindPhoneIdentity | null = null;
  /**
   * 普通表单回调的渲染时绑定（harmony-review-r2 R2-01，S0）：手机号 / 验证码输入、清空、发码、提交都经 form 用渲染时捕获的
   * BindPhoneFormBinding（页面实例、固定身份、当时的模型）执行，执行时只比较；会话换代（form.reset）后旧回调零写入、零请求。
   */
  private form: BindPhoneForm | null = null;
  /** 本页打开着的弹窗的关闭函数；dialogSerial 每次作废加 1（旧弹窗的回调按它失效）。 */
  private dialogClosers: (() => void)[] = [];
  private dialogSerial: number = 0;
  private unsubscribers: (() => void)[] = [];

  aboutToAppear(): void {
    this.model.now = this.config.clock();
    this.ticker = new BindPhoneTicker((): void => this.tick(), (): boolean => this.timerNeeded());
    const form: BindPhoneForm = new BindPhoneForm(this.config.service, this.model);
    this.form = form;
    // FU-HM-0720 R2-01：发码结果因发起时的许可失效被丢弃、但页面此刻可见且身份未变（先回可见、后成功 / 42901）——按共享截止时间
    // 重算倒计时并启动每秒刷新，到期自动恢复【获取验证码】；不补弹窗、提示、播报。
    form.deadlinesChanged = (): void => this.refreshTimers();
    this.identity = form.pageIdentity;
    // R3-01：同步离页出口（onWillDisappear）作废本实例的页面许可；aboutToDisappear 里再调一次。
    this.config.pageLeft = (): void => form.leave();
    // F-HM-31：老用户 phone_bound 补查持有本页许可（迟到结果不动后来打开的同名页）。
    this.config.recheck(form);
    this.model.gateActive = this.config.service.phoneGateActive;
    this.refreshPending();
    this.config.pageHidden = (): void => form.pageHidden();
    this.config.pageShown = (): void => {
      // FU-HM-0720（共性 22）：被盖住期间绑定已成功——回到栈顶再退出自己的导航实例并恢复待办（不补弹旧结果）。
      if (form.pageShown()) {
        this.stopTimer();
        CouliToast.show(this.getUIContext(), this.t(BindPhoneKeys.DONE));
        this.config.onBound();
        return;
      }
      // 回到可见：身份已不是当前会话（换代通知若没送到）也在这里重建。
      if (this.identity === null || !this.config.service.identityValid(this.identity)) {
        this.resetForSession();
        return;
      }
      this.refreshPending();
      // FU-HM-0720 R1-03：被盖住期间到达的发码结果不交给页面，但截止时间已在共享状态里记下——回到可见按它重算倒计时 / 限流显示。
      this.refreshTimers();
    };
    this.unsubscribers.push(this.config.service.subscribeSession((): void => this.resetForSession()));
    this.unsubscribers.push(this.config.service.subscribeGate((): void => {
      this.model.gateActive = this.config.service.phoneGateActive;
    }));
    // R2-04：bindPhone 未决记录有结论了（本页、别的实例或换号页发起的）：从存储重新同步待确认（inFlight 不残留）。
    // FU-HM-0720 R3-01：经本页表单订阅——被盖住、进后台、已离页未退订、身份已换代时不更新、不提示、不播报；回到可见由 onShown 重读。
    this.unsubscribers.push(form.subscribePending((): void => this.refreshPending()));
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
    // R3-01：先作废页面许可——在途的确认、放弃、绑定照常共享结算，但不再导航、弹窗、提示或改本页。
    this.form?.leave();
    for (const u of this.unsubscribers) {
      u();
    }
    this.unsubscribers = [];
    this.dropDialogs();
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

  /**
   * 会话换代（R1-01）：作废旧实例与弹窗、清空手机号 / 验证码 / 倒计时 / 错误 / 待确认显示，再按新身份建新实例。
   * 未决记录本身按账号保留在网络层，新身份是原账号时由 refreshPending 恢复待确认。
   */
  private resetForSession(): void {
    this.dropDialogs();
    this.stopTimer();
    this.model = new BindPhoneModel();
    this.model.now = this.config.clock();
    const form: BindPhoneForm | null = this.form;
    // R2-01：新身份与新模型一起换上，之前渲染出的全部表单回调失效。
    this.identity = form !== null ? form.reset(this.model) : this.config.service.capturePage();
    this.model.gateActive = this.config.service.phoneGateActive;
    // FU-HM-0720 R3-01：被盖住 / 进后台期间换代时不读待确认（不播报），回到可见由 onShown 按新身份读一次。
    if (form === null || form.presentable()) {
      this.refreshPending();
    }
  }

  private openDialog(options: CouliDialogOptions): void {
    this.dialogClosers.push(CouliDialog.open(this.getUIContext(), options));
  }

  private dropDialogs(): void {
    this.dialogSerial++;
    const closers: (() => void)[] = this.dialogClosers;
    this.dialogClosers = [];
    for (const close of closers) {
      try {
        close();
      } catch (e) {
        // 已关闭的忽略。
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
    this.ticker?.refresh();
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
  }

  private stopTimer(): void {
    this.ticker?.stop();
  }

  private countdown(): number {
    return this.model.now >= 0 ? this.config.service.sendState(this.model.phoneText).countdownSec : 0;
  }

  private sendRateLimited(): boolean {
    return this.model.now >= 0 && this.config.service.sendState(this.model.phoneText).rateLimitedSec > 0;
  }

  private bindBlocked(): boolean {
    return this.model.now < this.model.bindUntil || this.model.gateActive;
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

  /** 【获取验证码】（b：渲染时捕获的绑定，R2-01）。 */
  private async sendCode(b: BindPhoneFormBinding): Promise<void> {
    const form: BindPhoneForm | null = this.form;
    if (form === null || !form.live(b)) {
      return;
    }
    const model: BindPhoneModel = this.model;
    if (model.sending || this.countdown() > 0 || this.sendRateLimited()) {
      return;
    }
    const phone: PhoneResult = PhoneNumber.normalize(b.fields.phoneText);
    if (!phone.valid) {
      this.fieldError(true, this.t('error.20001.phone_invalid'));
      return;
    }
    model.sending = true;
    let outcome: SendCodeOutcome | null;
    try {
      outcome = await form.sendCode(b);
    } finally {
      model.sending = false;
    }
    // FU-HM-0720 R1-03：null 含「发起后页面被盖住 / 进后台」（Core 按发起时的页面许可核对）——不弹框、不提示、不播报、不改字段。
    if (outcome === null || !form.live(b)) {
      return;
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
    this.openDialog(options);
  }

  private canSubmit(): boolean {
    return PhoneNumber.normalize(this.model.phoneText).valid && CodeInput.accept(this.model.codeText).complete
      && !this.bindBlocked() && this.model.pending === null;
  }

  /** 【绑定】（b：渲染时捕获的绑定，R2-01）。 */
  private async bind(b: BindPhoneFormBinding): Promise<void> {
    const form: BindPhoneForm | null = this.form;
    if (form === null || !form.live(b) || !this.canSubmit() || this.model.submitting) {
      return;
    }
    const identity: BindPhoneIdentity = b.identity;
    const model: BindPhoneModel = this.model;
    model.submitting = true;
    let outcome: BindOutcome | null;
    try {
      outcome = await form.submit(b);
    } finally {
      model.submitting = false;
    }
    if (outcome === null || identity !== this.identity) {
      // R1-01：等待期间会话换代、页面已按新身份重建：旧结果不改新页面。
      return;
    }
    switch (outcome.actionRaw) {
      case BindPhoneAction.DONE:
        this.stopTimer();
        CouliToast.show(this.getUIContext(), this.t(BindPhoneKeys.DONE));
        this.config.onBound();
        return;
      case BindOutcome.PENDING:
        // G07：结果未知——不换键、不自动重发，进待确认（只有用户点的确认与放弃）。
        this.refreshPending();
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
    this.openDialog(options);
  }

  private mergeDecided(decision: string): void {
    const result: MergeResult = this.config.service.decideMerge(decision);
    if (result.resultRaw === MergeDecision.UNAVAILABLE) {
      // TODO(N-29) MERGE-SUCCESS：锁定契约没有并号接口——不发请求、不并号、不保存会话，明确告知暂不可用。
      CouliToast.show(this.getUIContext(), this.t(BindPhoneKeys.MERGE_UNAVAILABLE));
    }
    // cancelled：不并号、不保存会话，留在本页（手机号、验证码保留，用户可换号或返回）。
  }

  // ---------------------------------------------------------------- 待确认（APP-13a G07）

  /** 进入、回到可见、每次结算后：按 pendingFor(bindPhone) 恢复待确认。 */
  refreshPending(): void {
    const p: AccountPendingView | null = this.identity === null ? null : this.config.service.pendingView(this.identity);
    const was: AccountPendingView | null = this.model.pending;
    this.model.pending = p;
    if (p !== null && (was === null || was.key !== p.key)) {
      this.model.pendingVersion++;
      CouliAnnounce.say(this.getUIContext(), this.t('pending_confirm.title') + PriceTerms.comma + this.pendingDesc(p));
    }
    if (p === null && was !== null) {
      this.model.pendingVersion++;
    }
  }

  private pendingDesc(p: AccountPendingView): string {
    const vars: Map<string, string> = new Map<string, string>();
    if (p.maskedPhone !== null) {
      vars.set('phone', p.maskedPhone);
    }
    return this.fmt('pending_confirm.phone_change.desc', vars);
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

  private pendingBindings(): PendingBinding[] {
    const p: AccountPendingView | null = this.model.pending;
    const identity: BindPhoneIdentity | null = this.identity;
    return p === null || identity === null ? [] : [new PendingBinding(p.key, this.model.pendingVersion, identity)];
  }

  /** 【确认上一次提交】：原键、原请求体；会话身份在点击时固定（执行时只比较）。 */
  private async confirmPending(b: PendingBinding): Promise<void> {
    const p: AccountPendingView | null = this.model.pending;
    if (p === null || p.key !== b.key || b.version !== this.model.pendingVersion || this.model.pendingBusy
      || b.identity !== this.identity || this.model.gateActive) {
      return;
    }
    const form: BindPhoneForm | null = this.form;
    if (form === null) {
      return;
    }
    // R3-01：点击时取页面许可（页面实例 + 渲染时的固定身份）；离页、换代后结果为 null。
    const permit: BindPhonePagePermit = form.permit();
    const model: BindPhoneModel = this.model;
    model.pendingBusy = true;
    model.pendingWarning = '';
    let outcome: BindOutcome | null;
    try {
      // R1-01：渲染时捕获的身份，执行时服务端只比较。
      outcome = await form.confirmPending(b.key, permit);
    } finally {
      model.pendingBusy = false;
    }
    if (outcome === null || b.identity !== this.identity) {
      return;
    }
    this.pendingSettled(outcome);
  }

  /** 【放弃上一次提交】的二次确认（点遮罩不关、系统返回同【再想想】）。 */
  private confirmAbandon(b: PendingBinding): void {
    const p: AccountPendingView | null = this.model.pending;
    if (p === null || p.key !== b.key || b.version !== this.model.pendingVersion || b.identity !== this.identity
      || this.model.gateActive) {
      return;
    }
    const serial: number = this.dialogSerial;
    const options: CouliDialogOptions = new CouliDialogOptions();
    options.title = this.t('pending_confirm.abandon');
    options.message = this.t('pending_confirm.abandon.confirm') + '\n' + this.t('pending_confirm.abandon.note.phone_change');
    if (p.maskedPhone !== null) {
      options.detailLabel = this.t('pending_confirm.summary.new_phone');
      options.detailValue = p.maskedPhone;
    }
    options.primaryText = this.t('pending_confirm.abandon.ok');
    options.secondaryText = this.t('pending_confirm.abandon.cancel');
    options.dismissOnMask = false;
    options.backDismisses = true;
    options.returnFocusId = 'bind_phone_pending_abandon';
    options.onPrimary = (): void => {
      // 弹窗是本页实例的：会话换代后已作废（serial 变了）的旧弹窗回调不执行。
      if (serial === this.dialogSerial && b.identity === this.identity) {
        this.abandonNow(b);
      }
    };
    this.openDialog(options);
  }

  private async abandonNow(b: PendingBinding): Promise<void> {
    if (b.version !== this.model.pendingVersion || this.model.pendingBusy || this.model.gateActive) {
      return;
    }
    const form: BindPhoneForm | null = this.form;
    if (form === null || b.identity !== this.identity) {
      return;
    }
    // R3-01：同确认——点击时的页面许可，离页后结果不导航、不提示、不改页面。
    const permit: BindPhonePagePermit = form.permit();
    const model: BindPhoneModel = this.model;
    model.pendingBusy = true;
    let outcome: BindOutcome | null;
    try {
      outcome = await form.abandonPending(b.key, permit);
    } finally {
      model.pendingBusy = false;
    }
    if (outcome === null || b.identity !== this.identity) {
      return;
    }
    this.pendingSettled(outcome);
  }

  private pendingSettled(outcome: BindOutcome): void {
    switch (outcome.actionRaw) {
      case BindOutcome.STALE:
        return;
      case BindPhoneAction.DONE:
        // 确认成功（或放弃得知已完成）：沿用 APP-05b 绑定成功的后续（会话状态已刷新、待办按完成前置恢复）。
        this.refreshPending();
        this.stopTimer();
        CouliToast.show(this.getUIContext(), this.t(outcome.textKey ?? BindPhoneKeys.DONE));
        this.config.onBound();
        return;
      case BindOutcome.ABANDONED:
        this.refreshPending();
        this.model.codeText = '';
        // FU-HM-0721（共性 29）：不经 setCode 的清码也推进验证码修订号。
        if (this.form !== null) {
          this.form.codeReset();
        }
        CouliToast.show(this.getUIContext(), this.t(outcome.textKey ?? 'pending_confirm.abandoned'));
        CouliAnnounce.say(this.getUIContext(), this.t(outcome.textKey ?? 'pending_confirm.abandoned'));
        return;
      case BindPhoneAction.MERGE_CONFIRM:
        this.refreshPending();
        this.confirmMerge(outcome);
        return;
      case BindOutcome.PENDING: {
        this.refreshPending();
        const vars: Map<string, string> = new Map<string, string>();
        vars.set('trace6', outcome.trace6);
        this.model.pendingWarning = this.fmt(outcome.textKey ?? 'pending_confirm.retry_later', vars);
        CouliAnnounce.say(this.getUIContext(), this.model.pendingWarning);
        if (outcome.route !== null) {
          this.config.onNavigate(outcome.route);
        }
        return;
      }
      default:
        this.refreshPending();
        this.toast(outcome.textKey, outcome.trace6);
    }
  }

  @Builder
  pendingCard() {
    ForEach(this.pendingBindings(), (b: PendingBinding) => {
      PendingConfirmCard({
        title: this.t('pending_confirm.title'),
        desc: this.pendingDesc(this.model.pending as AccountPendingView),
        rows: this.pendingRows(this.model.pending as AccountPendingView),
        abandonLabel: this.t('pending_confirm.abandon'),
        confirmLabel: this.t('pending_confirm.phone_change.action'),
        busy: this.model.pendingBusy,
        busyText: this.t('error.40901'),
        warning: this.model.pendingWarning,
        hint: this.t('bind_phone.pending_hint'),
        disabled: (this.model.pending as AccountPendingView).inFlight || this.model.gateActive,
        idPrefix: 'bind_phone_pending',
        onAbandon: () => this.confirmAbandon(b),
        onConfirm: () => {
          this.confirmPending(b);
        }
      })
    }, (b: PendingBinding) => 'bind_pending_' + b.key + '_' + b.version)
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

  /** 表单的渲染时绑定（R2-01）：读 this.model 让会话换代换模型时 ForEach 按新键（页面实例号）重建全部回调。 */
  private formBindings(): BindPhoneFormBinding[] {
    const form: BindPhoneForm | null = this.form;
    const model: BindPhoneModel = this.model;
    if (form === null) {
      return [];
    }
    const b: BindPhoneFormBinding = form.binding();
    return b.fields === model ? [b] : [];
  }

  @Builder
  phoneField(b: BindPhoneFormBinding) {
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
          .enabled(this.model.pending === null)
          .onFocus(() => this.fieldFocused('phone'))
          .onChange((value: string) => {
            // R2-01：只写渲染时捕获的模型（换号作废在途结果、清除并号凭据，不取消传输）；倒计时随号码切换。
            if (this.form !== null && this.form.setPhone(b, value)) {
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
            if (this.form !== null && this.form.clearPhone(b)) {
              this.refreshTimers();
            }
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
  codeField(b: BindPhoneFormBinding) {
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
          .enabled(this.model.pending === null)
          .onFocus(() => this.fieldFocused('code'))
          .onChange((value: string) => {
            if (this.form !== null) {
              this.form.setCode(b, value);
            }
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
          .enabled(this.countdown() <= 0 && !this.sendRateLimited() && !this.model.sending && this.model.pending === null)
          .focusable(true)
          .focusBox(CouliFocus.box)
          .id(ID_SEND)
          .onClick(() => {
            this.sendCode(b);
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
          if (this.model.pending !== null) {
            this.pendingCard()
          }
          this.note()
          ForEach(this.formBindings(), (b: BindPhoneFormBinding) => {
            Column({ space: CouliSpacing.space4 }) {
              this.phoneField(b)
              this.codeField(b)
            }
            .width('100%')
            .padding(CouliSpacing.space4)
            .borderRadius(CouliRadius.card)
            .backgroundColor(CouliColors.backgroundSurface)
            .shadow(CouliShadow.card)
          }, (b: BindPhoneFormBinding) => 'bind_form_' + b.identity.page)
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
        ForEach(this.formBindings(), (b: BindPhoneFormBinding) => {
          CouliButton({
            text: this.t(BindPhoneKeys.SUBMIT),
            fullWidth: true,
            loading: this.model.submitting,
            disabled: !this.canSubmit(),
            buttonId: ID_SUBMIT,
            onTap: () => {
              this.bind(b);
            }
          })
        }, (b: BindPhoneFormBinding) => 'bind_submit_' + b.identity.page)
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
