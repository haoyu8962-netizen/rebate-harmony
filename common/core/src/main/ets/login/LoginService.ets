import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { ErrorEffect } from '../network/ErrorActionMapper';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { SessionTokens } from '../session/SessionTokens';
import {
  AfterLogin, AfterLoginAction, CodeInput, InviteField, LegalVersions, LoginErrorMapper, LoginErrorResult, PhoneNumber,
  PhoneResult, SmsCountdown, SmsCountdownResult
} from './LoginFlow';

/** 登录执行器要 App 提供的出口（生产实现是 Core RouterLoginHost，entry 的 AppLogin 组合；集成测试也用它）。 */
export interface LoginHost {
  /** 强更状态（AfterLoginUpdate：supported / below / unknown / checking），取这一刻的值。 */
  updateState(): string;

  /** 本机有没有持久化的 pending_action。 */
  hasPendingAction(): boolean;

  /** 关闭登录页，回到发起页（恢复 pending_action、进强更页之前都先出栈：原意图不压在登录页上，受限登录也不停在验证码页）。 */
  closeLogin(): void;

  /** 交给 Router 守卫恢复 pending_action（Router.prerequisiteCompleted：再过一次守卫，执行一次后删除）。 */
  resumePending(): void;

  /** 删除 pending_action，不执行。 */
  discardPending(): void;

  /** 进入强更页（网络层已按受限会话调用 UpdatePort.on10405 时这里是幂等的确认）。执行器先 closeLogin 再调它。 */
  enterForceUpdate(): void;

  /** 会话建立或结束（登录成功、登出）：守卫的会话状态、各模块据此刷新；Router 随之恢复满足条件的 pending_action。 */
  sessionChanged(): void;

  /**
   * 只通知会话变了，不恢复 pending_action（R2-02，共性 10）：已作废的登录尝试（用户已取消、页面已出栈）在会话确已保存或被
   * 清除时用——守卫的会话状态、强更页照常同步，待办留给有效的流程处理。
   */
  sessionSynced(): void;

  /** 登出：Router 清 pending_action、作废推送回查（Router.sessionEnded）。 */
  sessionEnded(): void;
}

/** 发码结果。 */
export class SendCodeOutcome {
  /**
   * code_sent / rate_limited / field_error / … / stale（页面已换手机号或离开，忽略）/ busy（已有在途请求）/
   * countdown_active（这个号码上次成功发码的 60 秒还没到：不再发出，页面直接进验证码步继续输入已收到的码，R1-05）。
   */
  readonly stateRaw: string;
  readonly countdownSec: number;
  readonly textKey: string | null;
  readonly field: string | null;
  /** 规范化后的号码（发码成功时页面显示脱敏号码用）。 */
  readonly phone: string | null;
  /** 服务端外壳的 trace_id 后 6 位（通用错误态附注，BR-TEXT-14）；没有为空串。 */
  readonly trace6: string;

  constructor(stateRaw: string, countdownSec: number, textKey: string | null, field: string | null,
    phone: string | null, trace6: string = '') {
    this.stateRaw = stateRaw;
    this.countdownSec = countdownSec;
    this.textKey = textKey;
    this.field = field;
    this.phone = phone;
    this.trace6 = trace6;
  }
}

/** 某个号码的发码截止时刻（毫秒）与种类。 */
class SendDeadline {
  readonly untilMillis: number;
  /** code_sent（成功发码后的重发倒计时）/ rate_limited（42901 的 Retry-After）。 */
  readonly kind: string;

  constructor(untilMillis: number, kind: string) {
    this.untilMillis = untilMillis;
    this.kind = kind;
  }
}

/**
 * 发码截止时间，按规范化后的手机号维护（harmony-review-r1 R1-05，APP-05a 共性 5）：成功发码记 60 秒（或服务端更长的
 * resend_after_sec），42901 记 Retry-After。所有发码入口（手机号页【获取验证码】、验证码页【重新获取】、确认框同意后继续）
 * 都经 LoginService.sendCode，同一个号码在截止前不再发出。随执行器存活（App 内一个），关掉登录页再进来照样生效。
 */
export class SmsSendDeadlines {
  private readonly byPhone: Map<string, SendDeadline> = new Map<string, SendDeadline>();

  record(phone: string, untilMillis: number, kind: string): void {
    this.byPhone.set(phone, new SendDeadline(untilMillis, kind));
  }

  /** 截止前返回记录；已过期的删除并返回 null。 */
  active(phone: string, nowMillis: number): SendDeadline | null {
    const found: SendDeadline | undefined = this.byPhone.get(phone);
    if (found === undefined) {
      return null;
    }
    if (nowMillis >= found.untilMillis) {
      this.byPhone.delete(phone);
      return null;
    }
    return found;
  }

  /** 剩余秒数（向上取整；没有为 0）。 */
  remainingSec(phone: string, nowMillis: number): number {
    const found: SendDeadline | null = this.active(phone, nowMillis);
    return found === null ? 0 : Math.ceil((found.untilMillis - nowMillis) / 1000);
  }
}

/**
 * 页面显示用的发码状态（F-HM-09，APP-05a 共性 20、21）：一律按规范化号码读 LoginService 保存的截止时间，现算剩余秒数。
 * 页面不另存「是否禁用」与倒计时截止时刻：换号时随号码切换，换回旧号时旧限制仍然生效；页面重新出现时按当前时钟重算。
 */
export class LoginSendState {
  /** 成功发码后的重发倒计时剩余秒数（code_sent）；没有为 0。 */
  readonly countdownSec: number;
  /** 发码 42901 的禁用剩余秒数（rate_limited）；没有为 0。 */
  readonly rateLimitedSec: number;

  constructor(countdownSec: number, rateLimitedSec: number) {
    this.countdownSec = countdownSec;
    this.rateLimitedSec = rateLimitedSec;
  }

  /** 还有没到期的计时（页面据此决定是否保留 / 重启每秒刷新）；loginBlocked 是登录按钮的 42901 禁用。 */
  needsTimer(loginBlocked: boolean): boolean {
    return this.countdownSec > 0 || this.rateLimitedSec > 0 || loginBlocked;
  }
}

/** 手机号页【获取验证码】的去向（harmony-review-r3 R3-01，APP-05a 共性 12）。 */
export class PhoneEntry {
  /** 继续输入这个号码已收到、仍在有效期内的验证码（不发码）。 */
  static readonly CONTINUE: string = 'continue_code';
  /** 交给 LoginService.sendCode（含本地校验与截止时间门）。 */
  static readonly SEND: string = 'send';

  readonly kind: string;
  /** 规范化号码（CONTINUE 时有）。 */
  readonly phone: string | null;
  /** 进入验证码步后的重发倒计时秒数：成功发码的 60 秒还没到时为剩余秒数；发码限流中为 0（重新获取按限流禁用）。 */
  readonly countdownSec: number;

  constructor(kind: string, phone: string | null, countdownSec: number) {
    this.kind = kind;
    this.phone = phone;
    this.countdownSec = countdownSec;
  }
}

/**
 * 登录页两个入口各自的 42901 禁用截止时刻（harmony-review-r2 R2-03，APP-05a 共性 11，03 §4.2「按 Retry-After 禁用触发的
 * 按钮」）：发码（获取验证码 / 重新获取）收到 42901 只禁用发码入口，仍有效的验证码照样可以提交；登录收到 42901 才禁用登录
 * 按钮。两个截止时刻分开存，互不覆盖。页面用 now 现算，不存「是否禁用」。
 */
export class LoginRateLimits {
  private sendUntil: number = 0;
  private loginUntil: number = 0;

  /** 发码收到 42901：发码入口禁用 millis。 */
  limitSend(nowMillis: number, millis: number): void {
    this.sendUntil = Math.max(this.sendUntil, nowMillis + Math.max(0, millis));
  }

  /** 登录收到 42901：登录按钮禁用 millis。 */
  limitLogin(nowMillis: number, millis: number): void {
    this.loginUntil = Math.max(this.loginUntil, nowMillis + Math.max(0, millis));
  }

  /** 发码结果：rate_limited 时只记发码入口（Retry-After 秒数）；返回是否记了禁用。 */
  applySend(outcome: SendCodeOutcome, nowMillis: number): boolean {
    if (outcome.stateRaw !== SmsCountdown.STATE_RATE_LIMITED) {
      return false;
    }
    this.limitSend(nowMillis, outcome.countdownSec * 1000);
    return true;
  }

  /** 登录结果：rate_limited 时只记登录按钮（ErrorEffect.disableMillis）；返回是否记了禁用。 */
  applyLogin(outcome: LoginOutcome, nowMillis: number): boolean {
    if (outcome.stateRaw !== SmsCountdown.STATE_RATE_LIMITED) {
      return false;
    }
    this.limitLogin(nowMillis, outcome.disableMillis);
    return true;
  }

  /** 获取验证码 / 重新获取是否因 42901 禁用。 */
  sendBlocked(nowMillis: number): boolean {
    return nowMillis < this.sendUntil;
  }

  /** 登录按钮是否因 42901 禁用。 */
  loginBlocked(nowMillis: number): boolean {
    return nowMillis < this.loginUntil;
  }

  /** 还有没有没到期的禁用（页面据此决定是否保留每秒刷新）。 */
  anyActive(nowMillis: number): boolean {
    return this.sendBlocked(nowMillis) || this.loginBlocked(nowMillis);
  }
}

/** 登录结果。 */
export class LoginOutcome {
  static readonly LOGGED_IN: string = 'logged_in';
  static readonly STALE: string = 'stale';
  static readonly BUSY: string = 'busy';
  static readonly AGREEMENT_REQUIRED: string = 'agreement_required';
  static readonly CODE_INCOMPLETE: string = 'code_incomplete';

  /** logged_in / LoginErrorResult.stateRaw 的取值 / stale / busy / agreement_required / code_incomplete。 */
  readonly stateRaw: string;
  readonly textKey: string | null;
  readonly field: string | null;
  readonly disableMillis: number;
  /** 执行了的登录后计划（AfterLogin.plan）；没有登录成功为空。 */
  readonly actions: string[];
  /** invite_bind.result（bound / failed / ignored_existing_user）；响应没有或受限登录为 null。 */
  readonly inviteResult: string | null;
  /** invite_bind.code（failed 时的原因码）。 */
  readonly inviteCode: number | null;
  readonly trace6: string;

  constructor(stateRaw: string, textKey: string | null = null, field: string | null = null, disableMillis: number = 0,
    actions: string[] = [], inviteResult: string | null = null, inviteCode: number | null = null, trace6: string = '') {
    this.stateRaw = stateRaw;
    this.textKey = textKey;
    this.field = field;
    this.disableMillis = disableMillis;
    this.actions = actions;
    this.inviteResult = inviteResult;
    this.inviteCode = inviteCode;
    this.trace6 = trace6;
  }
}

/**
 * 短信登录的执行器（APP-05a；03 §4.2、§4.4；BR-ID-04、BR-ID-05、BR-ID-10；lessons：归属与世代、先持久化、等待后复核）：
 * - 发码：先按 normalize_phone 规范化，不合法本地给 20001 同一文案、不发出；同一号码在发码截止时间前不再发出
 *   （SmsSendDeadlines，R1-05）；成功按 60 秒倒计时，42901 按 Retry-After；
 * - 登录：手机号、6 位码、协议勾选时刻齐全才发；请求体带包内当前协议版本与勾选 / 确认时刻；受限登录（从强更页进入）
 *   不带邀请码；ApiClient 保存会话成功才算登录成功（session_save_failed / invalid_session_tokens 不算），之后按
 *   AfterLogin.plan 依次执行；
 * - 归属（R1-01，APP-05a 共性 1）：发码与登录请求都带本次尝试的归属守卫（ApiRequest.owner）。换号、取消、离开页面、登出
 *   推进尝试序号（invalidateAttempt），并同步取消这次尝试已交给传输层的请求（ApiClient.cancelOwned）。ApiClient 在保存
 *   会话之前核对归属：迟到的旧登录响应不保存会话、不通知 Router、不恢复 pending_action；
 * - 登出：带当前会话调 logout（结果不论成败），回来时会话世代没变就清本机会话；世代变了要区分「已换成新会话」（不清，
 *   只通知会话变化）和「原会话已被清除」（10404、刷新失败清会话：照样完成 Router.sessionEnded 等清理，R1-03）。
 * 单线程（UI 线程）使用。
 */
export class LoginService {
  /** 受限会话复查之后仍是 deletion_only、强更结论仍是 supported：待办保留，交给 Router 随强更结论决定（R1-04）。 */
  static readonly HOLD_PENDING: string = 'hold_pending';
  static readonly STATE_COUNTDOWN: string = 'countdown_active';
  /** 验证码有效期缺省秒数（BR-ID-05）。 */
  static readonly CODE_VALIDITY_SEC: number = 300;

  private readonly client: ApiClient;
  private readonly tokens: SessionTokens;
  private readonly host: LoginHost;
  private readonly legal: LegalVersions;
  private readonly clock: () => number;
  /** 发码截止时间（按规范化号码）。 */
  readonly deadlines: SmsSendDeadlines = new SmsSendDeadlines();
  /**
   * 成功发出的验证码的有效期截止时刻（按规范化号码，毫秒；R3-01）。与发码截止时间分开存：42901 覆盖的只是「能不能再发」，
   * 不影响「已收到的码还能不能用」。登录成功（码已用掉）或服务端回 code_expired 时删除。
   */
  private readonly issuedCodes: Map<string, number> = new Map<string, number>();
  /** 尝试序号：换号、离开页面、登出时推进；旧请求的响应据此作废。 */
  private serial: number = 0;
  /** 本次尝试已发出请求的归属守卫（invalidateAttempt 时据此取消传输）。 */
  private owners: (() => boolean)[] = [];
  private sending: boolean = false;
  private loggingIn: boolean = false;
  private loggingOut: boolean = false;

  constructor(client: ApiClient, tokens: SessionTokens, host: LoginHost, legal: LegalVersions = LegalVersions.bundled(),
    clock: () => number = () => Date.now()) {
    this.client = client;
    this.tokens = tokens;
    this.host = host;
    this.legal = legal;
    this.clock = clock;
  }

  /**
   * 换了手机号、取消、离开登录页：在途的发码与登录结果不再改页面、不保存会话；已交给传输层的请求同步取消
   * （归属守卫此时已返回 false，之后的重试、续发也由 ApiClient 的归属核对结束）。
   */
  invalidateAttempt(): void {
    this.serial++;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.client.cancelOwned(owner);
    }
  }

  get busy(): boolean {
    return this.sending || this.loggingIn;
  }

  /** 这个号码（任意写法）距可以再发码还有几秒（截止前不再发出）；0 = 可以发。 */
  resendRemainingSec(rawPhone: string): number {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (!phone.valid || phone.normalized === null) {
      return 0;
    }
    return this.deadlines.remainingSec(phone.normalized, this.clock());
  }

  /** 这个号码（任意写法）此刻的发码状态（按规范化号码的截止时间现算，F-HM-09）。号码不合法为 0 / 0。 */
  sendState(rawPhone: string): LoginSendState {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (!phone.valid || phone.normalized === null) {
      return new LoginSendState(0, 0);
    }
    const now: number = this.clock();
    const gate: SendDeadline | null = this.deadlines.active(phone.normalized, now);
    if (gate === null) {
      return new LoginSendState(0, 0);
    }
    const remaining: number = Math.ceil((gate.untilMillis - now) / 1000);
    return gate.kind === SmsCountdown.STATE_SENT ? new LoginSendState(remaining, 0) : new LoginSendState(0, remaining);
  }

  /** 这个号码（任意写法）已收到的验证码还有几秒有效；没有或已过期为 0。 */
  issuedCodeRemainingSec(rawPhone: string): number {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (!phone.valid || phone.normalized === null) {
      return 0;
    }
    const until: number | undefined = this.issuedCodes.get(phone.normalized);
    if (until === undefined) {
      return 0;
    }
    const now: number = this.clock();
    if (now >= until) {
      this.issuedCodes.delete(phone.normalized);
      return 0;
    }
    return Math.ceil((until - now) / 1000);
  }

  /**
   * 手机号页【获取验证码】（R1-05、R3-01）：「继续输入已收到的验证码」与「重新发码」分开。这个号码有仍在有效期内的码，且
   * 此刻不能再发（成功发码的倒计时没到、发码 42901 限流中——sendBlocked 是页面的发码限流，号码自己的限流截止也算）时，
   * 直接回验证码步继续输入，不发码；其余交给 sendCode。
   */
  phoneEntry(rawPhone: string, sendBlocked: boolean): PhoneEntry {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (!phone.valid || phone.normalized === null || this.issuedCodeRemainingSec(phone.normalized) <= 0) {
      return new PhoneEntry(PhoneEntry.SEND, null, 0);
    }
    const gate: SendDeadline | null = this.deadlines.active(phone.normalized, this.clock());
    if (gate === null && !sendBlocked) {
      return new PhoneEntry(PhoneEntry.SEND, null, 0);
    }
    const countdown: number = gate !== null && gate.kind === SmsCountdown.STATE_SENT
      ? Math.ceil((gate.untilMillis - this.clock()) / 1000) : 0;
    return new PhoneEntry(PhoneEntry.CONTINUE, phone.normalized, countdown);
  }

  /**
   * 手机号页独立的「继续输入验证码」入口（F-HM-08，APP-05a 共性 16）：这个号码有可能收到、仍在有效期内的码就提供，
   * 不看此刻能不能重发。发码结果不确定（50401 供应商超时等 5xxxx、断网 / 超时）时也算「可能已收到」。
   */
  continueEntry(rawPhone: string): PhoneEntry {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (!phone.valid || phone.normalized === null || this.issuedCodeRemainingSec(phone.normalized) <= 0) {
      return new PhoneEntry(PhoneEntry.SEND, null, 0);
    }
    const gate: SendDeadline | null = this.deadlines.active(phone.normalized, this.clock());
    const countdown: number = gate !== null && gate.kind === SmsCountdown.STATE_SENT
      ? Math.ceil((gate.untilMillis - this.clock()) / 1000) : 0;
    return new PhoneEntry(PhoneEntry.CONTINUE, phone.normalized, countdown);
  }

  /** 发码结果不确定：服务端 5xxxx（如 50401 供应商超时）或没有外壳（断网、超时）。短信可能已经发出。 */
  private static sendUncertain(result: ApiResult): boolean {
    return result.outcome === ApiOutcome.NETWORK_ERROR
      || (result.outcome === ApiOutcome.BUSINESS_ERROR && result.code >= 50000);
  }

  /** 本次尝试的归属守卫：序号没变才算有效；登记下来，作废时据此取消传输。 */
  private ownerFor(issued: number): () => boolean {
    const owner: () => boolean = (): boolean => issued === this.serial;
    this.owners.push(owner);
    return owner;
  }

  private release(owner: () => boolean): void {
    const index: number = this.owners.indexOf(owner);
    if (index >= 0) {
      this.owners.splice(index, 1);
    }
  }

  async sendCode(rawPhone: string): Promise<SendCodeOutcome> {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (!phone.valid || phone.normalized === null) {
      // 与服务端 20001 phone_invalid 同一文案，不发短信、不计频控（BR-ID-05）。
      const local: LoginErrorResult = LoginErrorMapper.map(LoginErrorMapper.SEND_SMS_CODE, 20001,
        LoginService.phoneInvalidData());
      return new SendCodeOutcome(local.stateRaw, 0, local.textKey, 'phone', null);
    }
    const normalized: string = phone.normalized;
    const gate: SendDeadline | null = this.deadlines.active(normalized, this.clock());
    if (gate !== null) {
      // R1-05：同一号码截止前不再发出。成功发码的倒计时内 → 页面直接进验证码步，用已收到的码；42901 的禁用期内 → 照旧禁用。
      const remaining: number = Math.ceil((gate.untilMillis - this.clock()) / 1000);
      if (gate.kind === SmsCountdown.STATE_SENT) {
        return new SendCodeOutcome(LoginService.STATE_COUNTDOWN, remaining, null, null, normalized);
      }
      return new SendCodeOutcome(SmsCountdown.STATE_RATE_LIMITED, remaining, 'error.42901', null, normalized);
    }
    if (this.sending) {
      return new SendCodeOutcome(LoginOutcome.BUSY, 0, null, null, null);
    }
    const issued: number = this.serial;
    const body: Record<string, Object> = {};
    body['phone'] = normalized;
    body['purpose'] = 'login';
    const request: ApiRequest = new ApiRequest(LoginErrorMapper.SEND_SMS_CODE, {}, '', JSON.stringify(body));
    const owner: () => boolean = this.ownerFor(issued);
    request.owner = owner;
    this.sending = true;
    let result: ApiResult;
    try {
      result = await this.client.request(request);
    } finally {
      this.sending = false;
      this.release(owner);
    }
    if (result.ok) {
      const sent: SmsCountdownResult = SmsCountdown.fromMillis(0, 0, result.data);
      // 发码已被服务端受理：不论页面是否还在，这个号码的截止时间都要记下（换号再换回来也不能绕过）。
      this.deadlines.record(normalized, this.clock() + sent.countdownSec * 1000, SmsCountdown.STATE_SENT);
      this.issuedCodes.set(normalized, this.clock() + LoginService.codeValiditySec(result.data) * 1000);
      if (issued !== this.serial) {
        return new SendCodeOutcome(LoginOutcome.STALE, 0, null, null, null);
      }
      return new SendCodeOutcome(sent.stateRaw, sent.countdownSec, null, null, normalized);
    }
    if (LoginService.sendUncertain(result)) {
      // F-HM-08（共性 16）：结果不确定，用户可能已收到码——记下有效期，手机号页提供「继续输入验证码」（不设重发倒计时）。
      this.issuedCodes.set(normalized, this.clock() + LoginService.CODE_VALIDITY_SEC * 1000);
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.effect !== null) {
      const effect: ErrorEffect = result.effect;
      const mapped: LoginErrorResult = LoginErrorMapper.ofEffect(LoginErrorMapper.SEND_SMS_CODE, result.code, effect);
      const countdown: SmsCountdownResult = SmsCountdown.fromMillis(result.code, effect.disableMillis, result.data);
      if (countdown.stateRaw === SmsCountdown.STATE_RATE_LIMITED) {
        this.deadlines.record(normalized, this.clock() + countdown.countdownSec * 1000, SmsCountdown.STATE_RATE_LIMITED);
      }
      if (issued !== this.serial) {
        return new SendCodeOutcome(LoginOutcome.STALE, 0, null, null, null);
      }
      return new SendCodeOutcome(countdown.stateRaw, countdown.countdownSec, mapped.textKey, mapped.field,
        normalized, result.trace6);
    }
    if (issued !== this.serial) {
      return new SendCodeOutcome(LoginOutcome.STALE, 0, null, null, null);
    }
    const failed: LoginOutcome = LoginService.transportFailure(result);
    return new SendCodeOutcome(failed.stateRaw, 0, failed.textKey, null, normalized, result.trace6);
  }

  /**
   * 短信登录。consentAtMillis：勾选或确认框同意的时刻（AgreementState.consentAtMillis）；restricted：从强更页进入的受限登录。
   */
  async login(rawPhone: string, code: string, consentAtMillis: number | null, inviteRaw: string,
    restricted: boolean): Promise<LoginOutcome> {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (!phone.valid || phone.normalized === null) {
      const local: LoginErrorResult = LoginErrorMapper.map(LoginErrorMapper.LOGIN_BY_SMS, 20001,
        LoginService.phoneInvalidData());
      return new LoginOutcome(local.stateRaw, local.textKey, 'phone');
    }
    if (!CodeInput.accept(code).complete) {
      return new LoginOutcome(LoginOutcome.CODE_INCOMPLETE, null, 'code');
    }
    if (consentAtMillis === null || !Number.isSafeInteger(consentAtMillis)) {
      // 未勾选协议不能登录（BR-ID-04）：页面先弹确认框。
      return new LoginOutcome(LoginOutcome.AGREEMENT_REQUIRED);
    }
    if (this.loggingIn) {
      return new LoginOutcome(LoginOutcome.BUSY);
    }
    const issued: number = this.serial;
    const legal: Record<string, Object> = {};
    legal['privacy'] = this.legal.privacy;
    legal['agreement'] = this.legal.agreement;
    const body: Record<string, Object> = {};
    body['phone'] = phone.normalized;
    body['code'] = code;
    body['legal_versions'] = legal;
    body['consent_at'] = new Date(consentAtMillis).toISOString();
    const invite: string | null = InviteField.wireValue(inviteRaw, restricted);
    if (invite !== null) {
      body['invite_code'] = invite;
    }
    const request: ApiRequest = new ApiRequest(LoginErrorMapper.LOGIN_BY_SMS, {}, '', JSON.stringify(body));
    // R1-01：归属守卫。作废后 ApiClient 在保存令牌之前就结束这次调用（cancelled），旧响应不保存会话。
    const owner: () => boolean = this.ownerFor(issued);
    request.owner = owner;
    this.loggingIn = true;
    let result: ApiResult;
    try {
      result = await this.client.request(request);
    } finally {
      this.loggingIn = false;
      this.release(owner);
    }
    if (result.ok) {
      // 码已用掉：手机号页不再提供「继续输入」。
      this.issuedCodes.delete(phone.normalized);
      return this.loggedIn(result, issued, restricted);
    }
    if (issued !== this.serial) {
      return new LoginOutcome(LoginOutcome.STALE);
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.effect !== null) {
      const mapped: LoginErrorResult = LoginErrorMapper.ofEffect(LoginErrorMapper.LOGIN_BY_SMS, result.code,
        result.effect);
      if (mapped.stateRaw === 'code_expired') {
        this.issuedCodes.delete(phone.normalized);
      }
      return new LoginOutcome(mapped.stateRaw, mapped.textKey, mapped.field, mapped.disableMillis, [], null, null,
        result.trace6);
    }
    return LoginService.transportFailure(result);
  }

  /** 发码成功响应的 expires_in_sec（契约 SendSmsCodeData，BR-ID-05：300）；缺失或不合法按 300。 */
  private static codeValiditySec(data: Record<string, Object>): number {
    const value: Object | undefined = data['expires_in_sec'];
    if (typeof value === 'number' && Number.isInteger(value as number) && (value as number) > 0
      && (value as number) <= 3600) {
      return value as number;
    }
    return LoginService.CODE_VALIDITY_SEC;
  }

  /**
   * 登出（settings.logout；规划/01 F-ACC-05）：返回 true = 本机已回到游客。logout 请求失败（断网等）照样清本机会话
   * （TODO(N-26) INTEGRATION-02：服务端会话只能等过期，规则未写失败时是否提示）。
   */
  async logout(): Promise<boolean> {
    if (this.loggingOut) {
      return false;
    }
    this.invalidateAttempt();
    const generation: number = this.client.sessionGenerationId();
    this.loggingOut = true;
    try {
      if (this.tokens.accessToken() !== null) {
        // F-HM-08（APP-05a 共性 13）：登出在会话级作用域（App 的 LoginService）执行，请求不带页面归属守卫，页面出栈不取消它；
        // 请求无论正常返回、出错还是抛异常，都按原会话世代完成下面的本地清理与 Router.sessionEnded。
        await this.client.request(new ApiRequest('logout'));
      }
    } catch (e) {
      // 网络层不该抛出；万一抛出照样完成清理。
    } finally {
      this.loggingOut = false;
    }
    if (this.client.sessionGenerationId() !== generation && this.client.sessionAccount() !== null) {
      // 等待期间已经换成了新会话（新登录）：不清新会话，只通知会话变化。
      this.host.sessionChanged();
      return false;
    }
    // 会话世代没变，或原会话已被清除（logout 回 10404、刷新失败清会话、撤回同意）：都要完成同一套登出清理——
    // Router.sessionEnded 让 pending_action 与旧回查全部失效（R1-03）。
    this.clearLocalSession();
    return true;
  }

  /** 本机清会话（登出、注销完成等共用）：先结束会话世代，再删令牌，最后通知 Router 与各模块。 */
  clearLocalSession(): void {
    this.client.onSessionChanged();
    try {
      this.tokens.clear();
    } catch (e) {
      // 删除失败：SecureSessionTokens 已在内存里作废旧令牌并持续重试删除（lessons 38），按已登出处理。
    }
    this.host.sessionEnded();
    this.host.sessionChanged();
  }

  /** 登录响应的作用域投影（AfterLogin.plan 的 response）。 */
  private static projection(scope: string, isNewUser: boolean): Record<string, Object> {
    const projection: Record<string, Object> = {};
    projection['session_scope'] = scope;
    projection['is_new_user'] = isNewUser;
    return projection;
  }

  private planState(): Record<string, Object> {
    const state: Record<string, Object> = {};
    state['update'] = this.host.updateState();
    state['pendingAction'] = this.host.hasPendingAction();
    return state;
  }

  private async loggedIn(result: ApiResult, issued: number, restricted: boolean): Promise<LoginOutcome> {
    // ApiClient 已核对归属并保存成功（作废的尝试在保存前就以 cancelled 结束，不会走到这里）；再确认本机确有令牌。
    if (this.tokens.accessToken() === null) {
      return new LoginOutcome('service_error', LoginService.GENERIC_KEY);
    }
    if (issued !== this.serial) {
      // 保存与这里之间（同一事件循环的微任务里）被作废：会话确已建立，只同步会话状态，不关页、不恢复待办（R2-02）。
      this.host.sessionSynced();
      return new LoginOutcome(LoginOutcome.STALE);
    }
    const tokens: Object | undefined = result.data['tokens'];
    const scope: Object | undefined = tokens !== undefined && tokens !== null && typeof tokens === 'object' ?
      (tokens as Record<string, Object>)['session_scope'] : undefined;
    const isNew: boolean = result.data['is_new_user'] === true;
    let actions: string[] = AfterLogin.plan(LoginService.projection(typeof scope === 'string' ? scope as string : 'full',
      isNew), this.planState());
    if (actions.indexOf(AfterLoginAction.REFRESH_RESTRICTED) >= 0) {
      // R1-04：deletion_only 与 supported 并存——结论未定，先不动待办。显式做一次受限会话复查（单飞刷新），再按最新的
      // 作用域与强更结论重新计划；仍是 deletion_only 且 supported 时待办保留，交给 Router 随之后的强更结论决定。
      // R2-02（共性 10）：复查带本次尝试的归属守卫。用户取消（返回手机号步、离开页面）时 invalidateAttempt 经 cancelOwned
      // 立即结束这次等待；这一轮刷新若只为本次尝试而发，同时取消刷新传输。
      const recheckOwner: () => boolean = this.ownerFor(issued);
      try {
        await this.client.refreshRestrictedSession(recheckOwner);
      } finally {
        this.release(recheckOwner);
      }
      if (issued !== this.serial) {
        // 已作废：只同步会话状态（受限会话仍在），不恢复、不消费待办。
        this.host.sessionSynced();
        return new LoginOutcome(LoginOutcome.STALE);
      }
      if (this.client.sessionAccount() === null) {
        // 复查时会话被清除（刷新明确失败）：网络层已发会话级 Effect；这里只同步一次状态（游客，不恢复待办）。
        this.host.sessionSynced();
        return new LoginOutcome('session_expired', 'error.10404');
      }
      const again: string[] = AfterLogin.plan(LoginService.projection(this.tokens.scope(), isNew), this.planState());
      const replanned: string[] = again.filter((a: string) => a !== AfterLoginAction.REFRESH_RESTRICTED);
      if (again.indexOf(AfterLoginAction.REFRESH_RESTRICTED) >= 0) {
        replanned.push(LoginService.HOLD_PENDING);
      }
      actions = [AfterLoginAction.SAVE_SESSION, AfterLoginAction.REFRESH_RESTRICTED]
        .concat(replanned.filter((a: string) => a !== AfterLoginAction.SAVE_SESSION));
    }
    this.execute(actions);
    let inviteResult: string | null = null;
    let inviteCode: number | null = null;
    const bind: Object | undefined = result.data['invite_bind'];
    if (!restricted && bind !== undefined && bind !== null && typeof bind === 'object') {
      const record: Record<string, Object> = bind as Record<string, Object>;
      inviteResult = typeof record['result'] === 'string' ? record['result'] as string : null;
      inviteCode = typeof record['code'] === 'number' ? record['code'] as number : null;
    }
    return new LoginOutcome(LoginOutcome.LOGGED_IN, null, null, 0, actions, inviteResult, inviteCode);
  }

  /**
   * 执行登录后计划（R1-02）：先删要丢弃的待办（免得会话变化的路由同步把它执行掉）→ 明确移除登录页（含从强更页进入的受限
   * 登录）→ 通知会话变化（守卫的会话状态、Router 的状态同步）→ 交 Router 恢复待办，或进入 / 同步强更页。
   */
  private execute(actions: string[]): void {
    if (actions.indexOf(AfterLoginAction.DISCARD_PENDING) >= 0) {
      this.host.discardPending();
    }
    this.host.closeLogin();
    this.host.sessionChanged();
    for (const action of actions) {
      switch (action) {
        case AfterLoginAction.RESUME_PENDING:
          this.host.resumePending();
          break;
        case AfterLoginAction.ENTER_FORCE_UPDATE:
          this.host.enterForceUpdate();
          break;
        default:
          break;
      }
    }
  }

  static readonly GENERIC_KEY: string = 'error.50001';

  private static transportFailure(result: ApiResult): LoginOutcome {
    if (result.outcome === ApiOutcome.LOCAL_REJECT) {
      const reason: string | null = result.localRejectReason;
      if (reason === LocalRejectReason.SESSION_SAVE_FAILED || reason === LocalRejectReason.INVALID_SESSION_TOKENS) {
        // 登录响应缺令牌或令牌没能保存：不算登录成功（lessons 40、APP-03b 19）。
        return new LoginOutcome('service_error', LoginService.GENERIC_KEY);
      }
      // 隐私、环境、会话世代在等待中变了（call_cancelled / session_changed 等）：本次作废，页面不提示。
      return new LoginOutcome(LoginOutcome.STALE);
    }
    return new LoginOutcome(result.outcome === ApiOutcome.NETWORK_ERROR ? 'network_error' : 'service_error',
      LoginService.GENERIC_KEY, null, 0, [], null, null, result.trace6);
  }

  private static phoneInvalidData(): Record<string, Object> {
    const data: Record<string, Object> = {};
    data['fields'] = ['phone'];
    data['reason'] = PhoneNumber.REASON_INVALID;
    return data;
  }
}
