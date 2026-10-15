// APP-13a 换手机号（Settings 的页内子页，不注册路由、不接受任何外部输入，G22；brief §2 第 5 项；BR-ID-06、BR-ID-08、BR-ID-10）。
// - 第 1 步：验证当前手机号（step-up phone_change）。号码只用本机绑定了账号归属的规范化号码（G02），取不到不编造、不让用户另填，
//   【获取验证码】【下一步】置灰；不显示当前号码（G03）。发码倒计时与限流用二次验证的共享服务（APP-09 第 6、17、26、27、40 条）。
// - 第 2 步：新号（只去首尾空白、原样提交，G33）+ purpose=bind 验证码（按「账号 + 新号 + bind」单独倒计时）→【提交】生成新键，带第 1 步
//   的 token（未过期才带）发 bindPhone；结局按 PhoneChangeOutcomePolicy。
// - 进入时本账号 bindPhone 有结果未知的未决记录（首次绑定留下的也算，G07）：直接显示待确认，跳过第 1 步。
// - 成功：结果页显示本次实际发出请求的固定脱敏摘要（harmony-review-r2 R2-03）；立即刷新 GET /v1/me、丢弃全部 action 的 token；不清会话、不强制重新登录（G04）。
// - 身份固定（S0）：构造时一次性取得身份；输入、发码、验证、生成键、读凭据、发包只用这份身份，对当前会话只比较。
import { PhoneNumber } from '../../login/LoginFlow';
import { ApiRequest, ApiResult } from '../../network/ApiClient';
import { RetryAfterGate } from '../../network/RetryAfterGate';
import { StepUpController, StepUpSnapshot } from '../../stepup/StepUpController';
import { DeferredResult, PageNavGate } from '../../wallet/SensitiveFlow';
import { WalletJson } from '../../wallet/WalletJson';
import { WalletLoadFailure } from '../../wallet/WalletSession';
import { AccountRecord } from './AccountJson';
import { AccountOutcome, AccountPhase, PhoneChangeOutcomePolicy, PhoneMask } from './AccountPolicies';
import { AccountPendingView, AccountSensitiveFlow, AccountStep, bindPhoneBody } from './AccountSensitiveFlow';
import {
  AccountClick, AccountDeps, AccountIdentity, AccountMessage, AccountMessages, AccountSessionAware, AccountSettle,
  KeyedDeadlines, PendingSettlement
} from './AccountSession';

type JSONValue = Object | null;

export class PhoneChangeStep {
  static readonly STEP1: string = 'step1';
  static readonly STEP2: string = 'step2';
  static readonly DONE: string = 'done';
  static readonly PENDING: string = 'pending';
}

/** 44001 弹窗（PhoneChangeNewBlocked）。 */
export class PhoneBlockedDialog {
  readonly title: string;
  readonly desc: string;
  readonly seq: number;

  constructor(title: string, desc: string, seq: number) {
    this.title = title;
    this.desc = desc;
    this.seq = seq;
  }
}

/**
 * 第 1 步两个按钮各自的限制（harmony-review-r3 R3-04，brief §0 两个限流范围）：【获取验证码】只看发码限制（按键 42901），【下一步】只看
 * 验证限制（verifyGate）。两者分开保存、分开随到期通知刷新，不能合并成一个「第 1 步被限」。
 */
export class PhoneChangeStep1Buttons {
  /** 【获取验证码】被发码限流挡住。 */
  static sendBlocked(s1: StepUpSnapshot): boolean {
    return s1.sendBlocked;
  }

  /** 【下一步】被验证限流挡住。 */
  static nextBlocked(s1: StepUpSnapshot): boolean {
    return s1.verifyBlocked;
  }

  /** 【下一步】可点：号码已知、输满 6 位、验证没被限流（与发码限流无关）。 */
  static nextEnabled(s1: StepUpSnapshot, phoneKnown: boolean): boolean {
    return phoneKnown && s1.code.length === 6 && !PhoneChangeStep1Buttons.nextBlocked(s1);
  }
}

export class PhoneChangeSnapshot {
  step: string = PhoneChangeStep.STEP1;
  /** 本机取得到绑定账号归属的号码（G02）：取不到时第 1 步置灰。 */
  phoneKnown: boolean = false;
  /** 第 1 步（二次验证执行器的快照：已发送、倒计时、验证码、错误、限流）。 */
  step1: StepUpSnapshot = new StepUpSnapshot();
  newPhone: string = '';
  code: string = '';
  phoneError: AccountMessage | null = null;
  codeError: AccountMessage | null = null;
  banner: AccountMessage | null = null;
  notice: AccountMessage | null = null;
  /** 第 2 步 bind 发码：发送中、倒计时秒数、已发送、42901 禁用中。 */
  sending: boolean = false;
  countdown: number = 0;
  codeSent: boolean = false;
  sendRateLimited: boolean = false;
  submitting: boolean = false;
  submitBlocked: boolean = false;
  /** 30414：页内提示加【联系客服】（G05）。 */
  showCustomerService: boolean = false;
  blocked: PhoneBlockedDialog | null = null;
  pending: AccountPendingView | null = null;
  pendingBusy: boolean = false;
  /** 二次验证面板要打开（第 2 步提交或确认得到 10003）。 */
  stepUpAction: string | null = null;
  /** 结果页：本次实际发出请求的固定脱敏摘要（不落盘、不缓存；取不到为 null，R2-03）。 */
  doneMasked: string | null = null;
  guideRoute: string | null = null;
  guideCode: number = 0;
  storeUnavailable: boolean = false;
  version: number = 0;
  pendingVersion: number = 0;
  dead: boolean = false;
}

export class PhoneChangeController implements AccountSessionAware {
  static readonly SEND_OPERATION: string = 'sendSmsCode';
  static readonly ME_OPERATION: string = 'getMe';
  private static instances: number = 0;
  readonly identity: AccountIdentity;
  readonly flow: AccountSensitiveFlow;
  readonly pageInstance: string;
  private readonly d: AccountDeps;
  private readonly nav: PageNavGate = new PageNavGate();
  private state: PhoneChangeSnapshot = new PhoneChangeSnapshot();
  private left: boolean = false;
  private step1Ctl: StepUpController | null = null;
  private timer: number = -1;
  private countdownUntil: number = 0;
  private countdownKey: string = '';
  private readonly unsubscribers: (() => void)[] = [];
  private stepUpKey: string | null = null;
  private stepUpPhase: string = AccountPhase.SUBMIT;
  private submitClick: AccountClick | null = null;
  private pendingClick: AccountClick | null = null;
  private submitTicket: number = 0;
  private submitBody: string = '';
  private submitSummary: string = '';
  private deferredStepUp: DeferredResult | null = null;
  private blockedSeq: number = 0;
  /**
   * 第 2 步表单世代（F-HM-32，harmony-recheck-r3fix RC-01）：表单被清空重来（返回第 1 步、回第 1 步重新验证）时加 1，作废旧表单的
   * 发码结果许可。发码回调捕获世代与号码；迟到的结果只结算共享倒计时 / 限流，不把错误、提示、已发码写进换代后的表单。
   */
  private step2Gen: number = 0;
  /**
   * 第 2 步新号输入的修订号（FU-HM-0722，F-X-13 / APP-05b 共性 34）：新号内容每变一次加 1（清空再粘回、改成等价写法都算）。发码回调捕获它；
   * 对不上时旧结果的提示 / 字段错误 / 已发码标记丢弃，但共享倒计时 / 限流照常按当前规范化号码重算并启动计时器。
   */
  private phoneRev: number = 0;
  /**
   * R1-06：页面不可见或导航世代已变时到达的 44001：只存结局（登记时的页面实例、会话世代与归属键），回到有效页面再弹；
   * 出栈、会话变化时作废（同 APP-09 R3-04 的延后浮层）。
   */
  private deferredBlocked: PhoneBlockedDialog | null = null;
  private deferredBlockedAt: DeferredResult | null = null;
  onChange: (snapshot: PhoneChangeSnapshot) => void = (_s: PhoneChangeSnapshot) => {
  };
  /** 结果页【完成】：关掉本子页回 Settings 主页（唯一的设置页实例；页面接）。 */
  onFinished: (() => void) | null = null;

  constructor(deps: AccountDeps) {
    this.d = deps;
    this.identity = AccountIdentity.capture(deps);
    PhoneChangeController.instances++;
    this.pageInstance = 'P' + PhoneChangeController.instances;
    this.flow = new AccountSensitiveFlow(deps, AccountSensitiveFlow.PHONE, deps.session.phoneGate,
      this.identity.account, this.identity.key);
    const account: string | null = this.identity.account;
    this.state.phoneKnown = account !== null && deps.stepUpPhone(account) !== null;
    const refresh: () => void = (): void => {
      if (this.alive) {
        this.emit();
      }
    };
    this.unsubscribers.push(deps.session.phoneGate.subscribe(refresh));
    this.unsubscribers.push(deps.session.subscribePending(this.flow.operationId, (src: Object): void => {
      if (src !== this.flow && this.alive) {
        // R3-02：别处（旧换号页、BindPhone 页）结算了这个键：按随通知带来的终结结果落地，不只看记录消失。
        this.syncPending(deps.session.settledNow(this.flow.operationId));
        this.state.version++;
        this.emit();
      }
    }));
    deps.session.add(this);
    this.syncPending();
    if (this.state.pending === null) {
      this.startStep1();
    }
  }

  get snapshot(): PhoneChangeSnapshot {
    return this.state;
  }

  get alive(): boolean {
    return !this.left && this.identity.valid(this.d);
  }

  private click(key: string): AccountClick {
    return new AccountClick(this.identity, key);
  }

  onShown(): void {
    if (this.left) {
      return;
    }
    this.nav.back();
    this.surfaceDeferred();
    this.surfaceBlocked();
    this.syncPending();
    this.emit();
  }

  /** 回到本页：延后的 44001 弹窗仍属于本页实例与身份、仍停在第 2 步才弹（R1-06）。 */
  private surfaceBlocked(): void {
    const d: PhoneBlockedDialog | null = this.deferredBlocked;
    const at: DeferredResult | null = this.deferredBlockedAt;
    this.deferredBlocked = null;
    this.deferredBlockedAt = null;
    if (d === null || at === null || !this.alive || !this.nav.visible
      || !at.matches(at.key, this.pageInstance, this.identity.epoch, this.identity.key)
      || this.state.step !== PhoneChangeStep.STEP2) {
      return;
    }
    this.state.blocked = d;
    this.state.version++;
  }

  onHidden(): void {
    this.nav.away();
  }

  // ---------------------------------------------------------------- 第 1 步

  /** 第 1 步的执行器（StepUpController，phone_change；沿用本子页的固定身份）。页面不自动发码，用户点【获取验证码】。 */
  private startStep1(): void {
    const account: string | null = this.identity.account;
    this.step1Ctl?.close();
    this.step1Ctl = null;
    const s: PhoneChangeSnapshot = this.state;
    s.step = PhoneChangeStep.STEP1;
    if (account === null) {
      return;
    }
    const c: StepUpController = new StepUpController(this.d, 'phone_change', account, this.identity.key,
      this.identity.epoch);
    c.onChange = (snap: StepUpSnapshot): void => {
      if (this.alive && this.step1Ctl === c) {
        s.step1 = snap;
        this.emit();
      }
    };
    c.onToken = (_t: string): void => {
      // token 已按本子页身份记进共享缓存（只在内存，G23）；进第 2 步。
      if (this.alive && this.step1Ctl === c) {
        s.step = PhoneChangeStep.STEP2;
        s.version++;
        this.emit();
      }
    };
    this.step1Ctl = c;
    s.step1 = c.snapshot;
  }

  /** 【获取验证码】（第 1 步，绑定渲染时版本）。G02：取不到号码不发。 */
  sendStep1(renderVersion: number): boolean {
    const c: StepUpController | null = this.step1Ctl;
    if (!this.alive || c === null || renderVersion !== this.state.version || this.state.step !== PhoneChangeStep.STEP1
      || !this.state.phoneKnown) {
      return false;
    }
    this.nav.capture();
    return c.send();
  }

  setStep1Code(renderVersion: number, text: string): boolean {
    const c: StepUpController | null = this.step1Ctl;
    if (!this.alive || c === null || renderVersion !== this.state.version || this.state.step !== PhoneChangeStep.STEP1) {
      return false;
    }
    c.setCode(text);
    return true;
  }

  /** 【下一步】：输满 6 位才可用，stepUp {action: phone_change, code}。 */
  next(renderVersion: number): boolean {
    const c: StepUpController | null = this.step1Ctl;
    if (!this.alive || c === null || renderVersion !== this.state.version || this.state.step !== PhoneChangeStep.STEP1
      || !this.state.phoneKnown) {
      return false;
    }
    return c.verify();
  }

  get canNext(): boolean {
    const c: StepUpController | null = this.step1Ctl;
    return this.alive && this.state.phoneKnown && c !== null && c.canVerify;
  }

  // ---------------------------------------------------------------- 第 2 步

  /** 新号输入（只去首尾空白；不做规范化与号段判断，G33）。 */
  setNewPhone(renderVersion: number, text: string): boolean {
    const s: PhoneChangeSnapshot = this.state;
    if (!this.alive || renderVersion !== s.version || s.step !== PhoneChangeStep.STEP2 || s.submitting) {
      return false;
    }
    if (text !== s.newPhone) {
      this.phoneRev++;
    }
    s.newPhone = text;
    s.phoneError = null;
    this.refreshCountdown();
    this.emit();
    return true;
  }

  setCode(renderVersion: number, text: string): boolean {
    const s: PhoneChangeSnapshot = this.state;
    if (!this.alive || renderVersion !== s.version || s.step !== PhoneChangeStep.STEP2 || s.submitting) {
      return false;
    }
    s.code = text.replace(/[^0-9]/g, '').substring(0, 6);
    if (s.code.length > 0) {
      s.codeError = null;
    }
    this.emit();
    return true;
  }

  /**
   * bind 发码的倒计时 / 限流键（FU-HM-0722，APP-13a 共性 30，Android R1-13）：账号 + 规范化新号（国家码、空格、连字符、全角统一，
   * PhoneNumber.normalize）+ bind。规范化不了的输入按去首尾空白的原文。请求体仍按原始输入提交（G33）。
   */
  static bindKeyPhone(raw: string): string {
    const trimmed: string = raw.trim();
    return PhoneNumber.normalize(trimmed).normalized ?? trimmed;
  }

  /**
   * 归属于提交时那个新号 / 验证码的字段反馈（FU-HM-0722 R1-05，F-X-15 的过滤范围）：20001 号码错误、20002 / 20003 验证码、304xx 号码已被
   * 占用等、44001 风控弹窗，以及策略标了字段错误的结局。5xxxx、42901 限流、10xxx 补办等不属于字段反馈，held 重发时照常显示。
   */
  static fieldFeedback(o: AccountOutcome, code: number): boolean {
    return o.fieldError !== 'none' || o.nextState === PhoneChangeOutcomePolicy.BLOCKED || code === 20001 || code === 20002
      || code === 20003 || code === 44001 || (code >= 30000 && code <= 39999);
  }

  private bindKey(): string {
    return KeyedDeadlines.key(this.identity.account ?? '', PhoneChangeController.bindKeyPhone(this.state.newPhone), 'bind');
  }

  get canSendBind(): boolean {
    const s: PhoneChangeSnapshot = this.state;
    const phone: string = s.newPhone.trim();
    return this.alive && s.step === PhoneChangeStep.STEP2 && phone.length > 0 && !s.submitting
      && this.d.session.bindSms.remainingMs(this.bindKey(), this.d.clock()) === 0
      && !this.d.session.bindSms.sending(this.bindKey());
  }

  /** 第 2 步【获取验证码】：sendSmsCode {phone: 新号, purpose: bind}；发码不随子页关闭取消，只按会话归属结算（APP-09 第 40 条）。 */
  sendBind(renderVersion: number): boolean {
    const s: PhoneChangeSnapshot = this.state;
    if (renderVersion !== s.version || !this.canSendBind) {
      return false;
    }
    const identity: AccountIdentity = this.identity;
    const phone: string = s.newPhone.trim();
    const gen: number = this.step2Gen;
    const rev: number = this.phoneRev;
    const key: string = this.bindKey();
    const deadlines: KeyedDeadlines = this.d.session.bindSms;
    const ticket: number = deadlines.begin(key, this.d.clock());
    if (ticket === 0) {
      return false;
    }
    s.sending = true;
    s.banner = null;
    this.emit();
    const body: AccountRecord = {};
    body['phone'] = phone;
    body['purpose'] = 'bind';
    const request: ApiRequest = new ApiRequest(PhoneChangeController.SEND_OPERATION, {}, '', JSON.stringify(body));
    request.owner = (): boolean => identity.valid(this.d);
    request.sendAllowed = (): boolean => identity.valid(this.d) && !deadlines.rateLimited(key, this.d.clock());
    const d: AccountDeps = this.d;
    this.d.api.request(request).then((result: ApiResult): void => {
      // 共享部分先结算（子页关了也记）：截止时间与 42901 按发出时的会话归属。
      if (!identity.valid(d)) {
        deadlines.finish(key, ticket, null, null);
        return;
      }
      let message: AccountMessage | null = null;
      if (result.ok) {
        const sec: number = WalletJson.resendAfterSec(result.data);
        deadlines.finish(key, ticket, d.clock() + sec * 1000, null);
      } else {
        const failure: WalletLoadFailure = WalletLoadFailure.of(result);
        const rate: number | null = failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0
          ? d.clock() + failure.disableMs : null;
        deadlines.finish(key, ticket, null, rate);
        if (AccountSettle.forcesUpdate(result)) {
          // R1-07：只有网络层判定的强更才进强更（REFRESH_ONLY 沿用网络层）。
          d.forceUpdate();
        }
        message = result.code === 20001 ? AccountMessages.of('error.20001.phone_invalid')
          : AccountMessages.raw(failure.message.text);
      }
      if (!this.alive || s !== this.state) {
        return;
      }
      if (gen !== this.step2Gen || rev !== this.phoneRev || phone !== s.newPhone.trim()) {
        // F-HM-32：表单已换代（返回过第 1 步）或号码已改：只按共享截止时间刷新当前表单的倒计时 / 限流，不写错误与提示。
        // FU-HM-0722（共性 34）：在途时改过号码（含清空再粘回、等价写法）同样只刷新计时器——按当前规范化号码的共享截止时间重算并启动。
        if (s.step === PhoneChangeStep.STEP2) {
          this.refreshCountdown();
          this.emit();
        }
        return;
      }
      s.sending = false;
      if (result.ok) {
        s.codeSent = true;
        s.notice = AccountMessages.polite('phone_change.code_sent');
      } else if (result.code === 20001) {
        s.phoneError = message;
      } else {
        s.banner = message;
      }
      this.refreshCountdown();
      s.version++;
      this.emit();
    });
    return true;
  }

  private refreshCountdown(): void {
    const s: PhoneChangeSnapshot = this.state;
    const key: string = this.bindKey();
    const now: number = this.d.clock();
    const left: number = this.d.session.bindSms.remainingMs(key, now);
    s.sendRateLimited = this.d.session.bindSms.rateLimited(key, now);
    s.sending = this.d.session.bindSms.sending(key);
    s.countdown = s.sendRateLimited ? 0 : Math.ceil(left / 1000);
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (left > 0 && !this.left) {
      this.countdownKey = key;
      this.countdownUntil = now + left;
      this.timer = setTimeout((): void => {
        this.timer = -1;
        if (this.alive) {
          this.refreshCountdown();
          this.emit();
        }
      }, 1000);
    }
  }

  get canSubmit(): boolean {
    const s: PhoneChangeSnapshot = this.state;
    return this.alive && s.step === PhoneChangeStep.STEP2 && s.newPhone.trim().length > 0 && s.code.length === 6
      && !s.submitting && s.pending === null && !this.flow.storeUnavailable() && !this.d.session.phoneGate.active
      && s.stepUpAction === null && !this.flow.inFlightElsewhere();
  }

  /** 【提交】：生成新键，带第 1 步的 token（未过期才带）发 bindPhone。 */
  submit(renderVersion: number): boolean {
    const s: PhoneChangeSnapshot = this.state;
    if (renderVersion !== s.version || !this.canSubmit) {
      return false;
    }
    s.submitting = true;
    s.banner = null;
    s.phoneError = null;
    s.codeError = null;
    s.showCustomerService = false;
    s.guideRoute = null;
    // 新提交：上一次延后的 44001 弹窗不再弹。
    this.deferredBlocked = null;
    this.deferredBlockedAt = null;
    s.version++;
    this.emit();
    const phone: string = s.newPhone.trim();
    this.submitBody = bindPhoneBody(phone, s.code);
    this.submitSummary = PhoneMask.pendingSummary(phone);
    this.submitClick = this.click('');
    this.submitTicket++;
    this.send(null, null);
    return true;
  }

  private send(replayKey: string | null, token: string | null): void {
    const click: AccountClick = this.submitClick ?? this.click('');
    const gen: number = this.nav.capture();
    this.flow.submit(this.submitBody, this.submitSummary, replayKey, token, click, '')
      .then((step: AccountStep): void => this.applyStep(step, null, gen));
  }

  // ---------------------------------------------------------------- 待确认

  confirm(renderVersion: number, renderKey: string): boolean {
    const s: PhoneChangeSnapshot = this.state;
    const p: AccountPendingView | null = s.pending;
    if (!this.alive || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion || renderKey !== p.key
      || p.inFlight || this.d.session.phoneGate.active) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const click: AccountClick = this.click(p.key);
    this.pendingClick = click;
    const version: number = this.flow.pendingVersion;
    const gen: number = this.nav.capture();
    this.flow.confirm(p.key, null, click, '').then((step: AccountStep): void => this.applyStep(step, version, gen));
    return true;
  }

  abandon(renderVersion: number, renderKey: string): boolean {
    const s: PhoneChangeSnapshot = this.state;
    const p: AccountPendingView | null = s.pending;
    if (!this.alive || p === null || s.pendingBusy || renderVersion !== this.flow.pendingVersion || renderKey !== p.key
      || p.inFlight || this.d.session.phoneGate.active) {
      return false;
    }
    s.pendingBusy = true;
    s.banner = null;
    this.emit();
    const version: number = this.flow.pendingVersion;
    const gen: number = this.nav.capture();
    this.flow.abandon(p.key, this.click(p.key), '').then((step: AccountStep): void =>
    this.applyStep(step, version, gen));
    return true;
  }

  // ---------------------------------------------------------------- 二次验证（10003）

  createStepUp(): StepUpController | null {
    const account: string | null = this.identity.account;
    if (!this.alive || this.state.stepUpAction === null || account === null) {
      return null;
    }
    const c: StepUpController = new StepUpController(this.d, 'phone_change', account, this.identity.key,
      this.identity.epoch);
    c.onToken = (token: string): void => this.afterStepUp(token);
    return c;
  }

  private afterStepUp(token: string): void {
    const s: PhoneChangeSnapshot = this.state;
    const key: string | null = this.stepUpKey;
    if (!this.alive || s.stepUpAction === null || key === null) {
      return;
    }
    s.stepUpAction = null;
    if (this.stepUpPhase === AccountPhase.SUBMIT) {
      if (this.submitClick === null || !this.submitClick.valid(this.d) || this.flow.keySuperseded(key)) {
        s.submitting = false;
        this.emit();
        return;
      }
      s.submitting = true;
      this.emit();
      this.send(key, token);
      return;
    }
    const click: AccountClick | null = this.pendingClick !== null && this.pendingClick.key === key ? this.pendingClick
      : null;
    if (click === null || !this.flow.keyOpen(key)) {
      this.syncPending();
      this.emit();
      return;
    }
    s.pendingBusy = true;
    this.emit();
    const version: number = this.flow.pendingVersion;
    const gen: number = this.nav.capture();
    this.flow.confirm(key, token, click, '').then((step: AccountStep): void => this.applyStep(step, version, gen));
  }

  stepUpClosed(): void {
    const s: PhoneChangeSnapshot = this.state;
    if (s.stepUpAction === null) {
      return;
    }
    s.stepUpAction = null;
    s.submitting = false;
    s.pendingBusy = false;
    this.syncPending();
    s.version++;
    this.emit();
  }

  private surfaceDeferred(): void {
    const at: DeferredResult | null = this.deferredStepUp;
    this.deferredStepUp = null;
    const key: string | null = this.stepUpKey;
    if (at === null || key === null || !this.alive
      || !at.matches(key, this.pageInstance, this.identity.epoch, this.identity.key)) {
      return;
    }
    const open: boolean = this.stepUpPhase === AccountPhase.SUBMIT
      ? at.ticket === this.submitTicket && !this.flow.keySuperseded(key) : this.flow.keyOpen(key);
    if (open) {
      this.state.stepUpAction = 'phone_change';
    } else {
      this.state.submitting = false;
      this.state.pendingBusy = false;
      this.syncPending();
    }
    this.state.version++;
  }

  // ---------------------------------------------------------------- 结局落地

  private applyStep(step: AccountStep, version: number | null, gen: number): void {
    const s: PhoneChangeSnapshot = this.state;
    const o: AccountOutcome = step.outcome;
    if (o.refetchMe && this.identity.valid(this.d)) {
      // G04：成功（含放弃得知已完成）立即刷新 GET /v1/me（按原会话；子页已关也刷新「我的」快照与绑手机状态）。
      this.refreshMe();
    }
    if (!this.alive) {
      return;
    }
    if (version !== null && version !== this.flow.pendingVersion - (o.keyEnds ? 1 : 0)) {
      this.syncPending();
      this.emit();
      return;
    }
    const current: boolean = this.nav.current(gen);
    s.submitting = false;
    s.pendingBusy = false;
    if (o.autoResendSameKey && o.stepUpAction !== null) {
      this.stepUpKey = step.key;
      this.stepUpPhase = step.phase === AccountPhase.CONFIRM ? AccountPhase.CONFIRM : AccountPhase.SUBMIT;
      if (current) {
        s.stepUpAction = o.stepUpAction;
      } else {
        this.deferredStepUp = new DeferredResult(step.key, this.pageInstance, this.identity.epoch, this.identity.key,
          this.stepUpPhase === AccountPhase.SUBMIT ? this.submitTicket : -1);
        if (this.nav.visible) {
          this.surfaceDeferred();
        }
      }
      s.submitting = this.stepUpPhase === AccountPhase.SUBMIT;
      s.pendingBusy = this.stepUpPhase === AccountPhase.CONFIRM;
      s.version++;
      this.emit();
      return;
    }
    if (step.toast !== null) {
      s.notice = step.toast;
    }
    // FU-HM-0722（F-X-15）：held 原键原体重发的是旧号码、用户之后改了新号：号码类反馈（20001 字段错误、30411 / 30414 横幅、44001 弹窗）
    // 与验证码错误都属于原提交，不落到当前输入上，也不按结局清空当前输入（键已结束，下一次提交按当前输入用新键）。
    // FU-HM-0722 R1-05（APP-05b 共性 36）：只过滤号码类 / 验证码类字段反馈；5xxxx、限流等非字段结局（横幅、trace6）照常显示。
    const foreign: boolean = step.phase === AccountPhase.SUBMIT && step.sentPhone !== null
      && PhoneChangeController.fieldFeedback(o, step.result.code)
      && PhoneChangeController.bindKeyPhone(step.sentPhone) !== PhoneChangeController.bindKeyPhone(s.newPhone);
    switch (o.nextState) {
      case PhoneChangeOutcomePolicy.DONE: {
        // R2-03：结果页只用这次实际发出的请求的固定脱敏摘要（提交 / held 重提 / 10003 重放取提交开始时固定的那份，确认 / 放弃取
        // 点击时的未决记录），不从当前可编辑的表单推断成功号码。
        const fromPending: string | null = s.pending !== null ? s.pending.maskedPhone : null;
        s.doneMasked = step.sentSummary !== null ? PhoneMask.fromSummary(step.sentSummary) : fromPending;
        s.step = PhoneChangeStep.DONE;
        s.pending = null;
        s.code = '';
        if (step.message !== null) {
          s.notice = step.message;
        }
        this.step1Ctl?.close();
        this.step1Ctl = null;
        break;
      }
      case PhoneChangeOutcomePolicy.STEP1:
        this.resetForm();
        this.startStep1();
        if (o.textKey === 'pending_confirm.abandoned') {
          s.notice = step.message;
        } else {
          s.banner = step.message;
        }
        break;
      case PhoneChangeOutcomePolicy.BLOCKED: {
        s.step = PhoneChangeStep.STEP2;
        if (foreign) {
          break;
        }
        s.code = '';
        this.blockedSeq++;
        const title: string = AccountMessages.of(o.dialogTitleKey ?? 'error.44001').text;
        const dialog: PhoneBlockedDialog = new PhoneBlockedDialog(title,
          AccountMessages.of('phone_change.risk_blocked.desc').text, this.blockedSeq);
        if (current) {
          s.blocked = dialog;
        } else {
          // R1-06：发起后页面被覆盖、进后台或导航世代变了：只存结局，不弹；回到本页（onShown）再弹。
          s.blocked = null;
          this.deferredBlocked = dialog;
          this.deferredBlockedAt = new DeferredResult(step.key, this.pageInstance, this.identity.epoch, this.identity.key);
          if (this.nav.visible) {
            this.surfaceBlocked();
          }
        }
        break;
      }
      case PhoneChangeOutcomePolicy.PENDING:
        s.step = PhoneChangeStep.PENDING;
        if (o.clearsCode) {
          s.code = '';
        }
        s.banner = step.message;
        break;
      case PhoneChangeOutcomePolicy.FORCE_UPDATE:
        s.banner = null;
        break;
      default:
        if (s.step === PhoneChangeStep.PENDING) {
          // 待确认的键因 3xxxx 结束：回第 2 步（新号来自本机摘要以外的输入，不预填原文）。
          s.step = PhoneChangeStep.STEP2;
        }
        if (foreign) {
          break;
        }
        if (!o.keepsNewPhone) {
          s.newPhone = '';
        }
        if (o.clearsCode) {
          s.code = '';
        }
        s.showCustomerService = o.showCustomerService;
        if (o.fieldError === 'phone') {
          s.phoneError = step.message;
        } else if (o.fieldError === 'code') {
          s.codeError = step.message;
        } else {
          s.banner = step.message;
        }
        break;
    }
    if (o.guideRoute !== null || o.guideCode !== 0) {
      this.guide(o.guideRoute, o.guideCode, step.result, current);
    }
    this.syncPending();
    this.refreshCountdown();
    s.version++;
    this.emit();
  }

  /**
   * 成功后的 getMe（G04）：与注销页、「我的」同一套读取结算（R1-08）——按本子页固定身份发与收；42901 写进共享 meReadGate（双向：
   * 那边限流时这里在发包前就被拦下，这里收到的 42901 那边也立即生效）；其余失败按网络层 Effect（强更）处理，不重试，由受闸门约束的
   * 已有读取路径（「我的」、注销页【重试】）恢复。
   */
  private refreshMe(): void {
    const identity: AccountIdentity = this.identity;
    const gate: RetryAfterGate = this.d.session.meReadGate;
    const request: ApiRequest = new ApiRequest(PhoneChangeController.ME_OPERATION);
    request.owner = (): boolean => identity.valid(this.d);
    request.sendAllowed = (): boolean => identity.valid(this.d) && gate.sendAllowed();
    this.d.api.request(request).then((result: ApiResult): void => {
      if (!identity.valid(this.d) || identity.account === null) {
        return;
      }
      if (result.ok) {
        this.d.meLoaded(identity.account, result.data as AccountRecord);
        return;
      }
      AccountSettle.readFailed(result, gate, true, this.d.forceUpdate);
      this.d.log('getMe after phone change failed: ' + result.code);
    });
  }

  private guide(route: string | null, code: number, result: ApiResult, current: boolean): void {
    if (!current) {
      this.state.guideRoute = route;
      this.state.guideCode = code;
      return;
    }
    if (route !== null) {
      this.nav.away();
      this.d.open(route, {});
      return;
    }
    if (code === 10004) {
      const t: JSONValue | undefined = (result.data as AccountRecord)['consent_type'];
      if (typeof t === 'string') {
        this.d.reconsent(t as string);
      }
    }
  }

  openGuide(renderVersion: number, renderRoute: string): boolean {
    const s: PhoneChangeSnapshot = this.state;
    if (!this.alive || !this.nav.visible || renderVersion !== s.version || s.guideRoute !== renderRoute) {
      return false;
    }
    s.guideRoute = null;
    this.nav.away();
    this.d.open(renderRoute, {});
    s.version++;
    this.emit();
    return true;
  }

  /** 44001 弹窗【知道了】。 */
  dismissBlocked(): void {
    this.state.blocked = null;
    this.emit();
  }

  /** 【联系客服申诉】/「原手机号不能用了？联系客服」/ 30414 的【联系客服】：统一客服出口。 */
  contactCs(): boolean {
    if (!this.alive) {
      return false;
    }
    this.state.blocked = null;
    this.nav.away();
    this.d.customerService();
    this.emit();
    return true;
  }

  /** 结果页【完成】：回 Settings（关掉本子页）。 */
  finish(renderVersion: number): boolean {
    if (this.left || renderVersion !== this.state.version || this.state.step !== PhoneChangeStep.DONE) {
      return false;
    }
    const done: (() => void) | null = this.onFinished;
    if (done !== null) {
      done();
    }
    return true;
  }

  private resetForm(): void {
    const s: PhoneChangeSnapshot = this.state;
    // F-HM-32：旧第 2 步表单的发码结果许可作废。
    this.step2Gen++;
    s.newPhone = '';
    s.code = '';
    s.phoneError = null;
    s.codeError = null;
    s.codeSent = false;
    s.showCustomerService = false;
    s.blocked = null;
    s.pending = null;
    // G23：重新发起要重新验证当前手机号（上一次的 token 不复用）。
    this.d.session.tokens.on10003('phone_change');
  }

  syncPending(settled: PendingSettlement | null = null): void {
    if (!this.alive) {
      return;
    }
    const s: PhoneChangeSnapshot = this.state;
    s.storeUnavailable = this.flow.storeUnavailable();
    const was: AccountPendingView | null = s.pending;
    const p: AccountPendingView | null = this.flow.pending();
    s.pending = p;
    if (p !== null && s.step !== PhoneChangeStep.DONE && s.stepUpAction === null) {
      // 待确认：跳过第 1 步（flow-map §11 共同约定）；表单置灰。
      s.step = PhoneChangeStep.PENDING;
      s.submitting = false;
    } else if (p === null && s.step === PhoneChangeStep.PENDING) {
      if (settled !== null && was !== null && settled.key === was.key && settled.account === this.identity.account
        && this.landSettled(settled, was)) {
        return;
      }
      s.step = PhoneChangeStep.STEP2;
    }
  }

  /**
   * 别处结算了本页正显示的待确认键（R3-02）：按终结结果在本页落地。abandoned / 20903 → 回第 1 步、清空、丢弃 token、重新验证当前
   * 手机号（flow-map 11.2.8）；已完成 → 结果页（11.2.7）。其余（3xxxx 等）返回 false，沿用原有处理。
   */
  private landSettled(settled: PendingSettlement, was: AccountPendingView): boolean {
    const s: PhoneChangeSnapshot = this.state;
    if (settled.nextState === PhoneChangeOutcomePolicy.STEP1) {
      this.resetForm();
      this.startStep1();
      const key: string | null = settled.textKey;
      if (key === 'pending_confirm.abandoned') {
        s.notice = AccountMessages.polite(key);
      } else if (key !== null) {
        s.banner = AccountMessages.of(key);
      }
      return true;
    }
    if (settled.nextState === PhoneChangeOutcomePolicy.DONE) {
      s.doneMasked = settled.summary !== null ? PhoneMask.fromSummary(settled.summary) : was.maskedPhone;
      s.step = PhoneChangeStep.DONE;
      s.code = '';
      if (settled.textKey === 'pending_confirm.already_done') {
        s.notice = AccountMessages.polite(settled.textKey);
      }
      this.step1Ctl?.close();
      this.step1Ctl = null;
      return true;
    }
    const o: AccountOutcome | null = settled.outcome;
    if (o !== null && o.keyEnds && settled.nextState === PhoneChangeOutcomePolicy.STEP2) {
      // FU-HM-0722（共性 44、47，Android RC-01）：别处确认 30411 / 30414、放弃 completed 原 3xxxx 等终结业务错误：恢复第 2 步与提交入口，
      // 错误提示（字段 / 横幅、trace6、30414【联系客服】、已处理完轻提示）按结局；新号、验证码、token 按结局的保留策略（本实例从未填过的
      // 字段本来就是空，G03）。不回第 1 步、不重新验证。
      s.step = PhoneChangeStep.STEP2;
      if (!o.keepsNewPhone) {
        s.newPhone = '';
      }
      if (o.clearsCode) {
        s.code = '';
      }
      if (!o.keepsToken) {
        this.d.session.tokens.on10003('phone_change');
      }
      s.showCustomerService = o.showCustomerService;
      const message: AccountMessage | null = settled.message();
      if (o.fieldError === 'phone') {
        s.phoneError = message;
      } else if (o.fieldError === 'code') {
        s.codeError = message;
      } else {
        s.banner = message;
      }
      if (o.toastKey !== null) {
        s.notice = AccountMessages.polite(o.toastKey);
      }
      this.refreshCountdown();
      return true;
    }
    return false;
  }

  /**
   * 换号的统一返回处理（harmony-review-r3 R3-05，flow-map 11.2.2「返回键回第 1 步（不提交）」）：页面返回与系统返回都调。
   * 第 2 步（没在提交、没开二次验证）→ 回第 1 步：清空新号与验证码、丢弃第 1 步的 token、重新验证当前手机号，不提交、不关子页，返回 true；
   * 第 1 步及其他状态返回 false，由设置页按原约定关掉子页（leave）。
   */
  back(): boolean {
    const s: PhoneChangeSnapshot = this.state;
    if (!this.alive || s.step !== PhoneChangeStep.STEP2 || s.submitting || s.stepUpAction !== null) {
      return false;
    }
    this.resetForm();
    s.banner = null;
    s.notice = null;
    s.sending = false;
    s.countdown = 0;
    s.sendRateLimited = false;
    this.deferredBlocked = null;
    this.deferredBlockedAt = null;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.startStep1();
    this.syncPending();
    s.version++;
    this.emit();
    return true;
  }

  /** 子页关闭（返回、系统返回、设置页出栈；同步出口）：清空输入、作废回调，丢弃第 1 步的 token（G23）。写请求不取消。 */
  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.step1Ctl?.close();
    this.step1Ctl = null;
    for (const u of this.unsubscribers) {
      u();
    }
    this.d.session.remove(this);
    if (this.identity.valid(this.d)) {
      this.d.session.tokens.on10003('phone_change');
    }
    this.deferredStepUp = null;
    this.deferredBlocked = null;
    this.deferredBlockedAt = null;
    this.onFinished = null;
    const dead: PhoneChangeSnapshot = new PhoneChangeSnapshot();
    dead.dead = true;
    dead.version = this.state.version + 1;
    this.state = dead;
  }

  resetForSession(): void {
    this.leave();
    try {
      this.onChange(this.state);
    } catch (e) {
      // 忽略。
    }
  }

  private emit(): void {
    const s: PhoneChangeSnapshot = this.state;
    s.submitBlocked = this.d.session.phoneGate.active;
    s.pendingVersion = this.flow.pendingVersion;
    try {
      this.onChange(s);
    } catch (e) {
      // 忽略。
    }
  }
}
