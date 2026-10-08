import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { EffectKind, ErrorEffect } from '../network/ErrorActionMapper';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { CodeInput, LoginErrorMapper, PhoneNumber, PhoneResult, SmsCountdown, SmsCountdownResult } from './LoginFlow';
import { LoginSendState, SendCodeOutcome, SendDeadline, SmsSendDeadlines } from './LoginService';
import { BindActionResult, BindPhoneAction, MergeDecision, MergeResult } from './OAuthLoginFlow';
import { PhoneBindingState } from './OAuthLoginService';

/** 绑手机的结果。 */
export class BindOutcome {
  static readonly STALE: string = 'stale';
  static readonly BUSY: string = 'busy';
  static readonly CODE_INCOMPLETE: string = 'code_incomplete';
  static readonly PHONE_INVALID: string = 'phone_invalid';
  /**
   * 错误码要求跳页（ErrorActionMapper navigate，APP-05b harmony-review-r2 R2-03）：10007 stage=cooling → DeleteAccount（注销进度页，
   * 可撤回），不弹处理中提示（BR-TEXT-14 表 A）；stage=processing 不是这个，仍按提示。
   */
  static readonly NAVIGATE: string = 'navigate';

  /** BindPhoneAction 的 actionRaw（done / merge_confirm / retry_after / error）或 stale / busy / code_incomplete / phone_invalid。 */
  readonly actionRaw: string;
  readonly textKey: string | null;
  readonly trace6: string;
  readonly disableMillis: number;
  /** 并号确认时显示的手机号账号（脱敏）；其余为空串。 */
  readonly maskedPhone: string;
  /** navigate 时要经 Router 打开的路由；其余为 null。 */
  readonly route: string | null;

  constructor(actionRaw: string, textKey: string | null = null, trace6: string = '', disableMillis: number = 0,
    maskedPhone: string = '', route: string | null = null) {
    this.actionRaw = actionRaw;
    this.textKey = textKey;
    this.trace6 = trace6;
    this.disableMillis = disableMillis;
    this.maskedPhone = maskedPhone;
    this.route = route;
  }

  /** 网络层 Effect 要求跳页（navigate 且给了路由）时的结果；否则 null（R2-03）。 */
  static navigation(effect: ErrorEffect, trace6: string): BindOutcome | null {
    if (effect.effectKindRaw !== EffectKind.NAVIGATE || effect.route === null) {
      return null;
    }
    return new BindOutcome(BindOutcome.NAVIGATE, effect.textKey, trace6, 0, '', effect.route);
  }
}

/** BindPhoneService 要 App 提供的出口。 */
export interface BindPhoneHost {
  /** 绑定成功、getMe 已刷新：会话状态变化（守卫重算）并恢复因绑手机而登记的待办（Router.prerequisiteCompleted）。 */
  phoneBound(): void;
}

/**
 * 绑手机页的执行器（APP-05b；BR-ID-05、BR-ID-06；openapi bindPhone、sendSmsCode purpose=bind、getMe）：
 * - 发码：purpose=bind；与短信登录共用按规范化号码的截止时间（SmsSendDeadlines：成功 60 秒、42901 Retry-After），同一号码
 *   截止前不再发出；50401 按错误提示（trace6）。
 * - 绑定：手机号 + 6 位码。首次绑定不带 step-up（契约：step-up 只用于换号）。成功 → 刷新 getMe（phone_bound）→ 通知会话状态
 *   变化并恢复待办；30411 mergeable（带 merge_ticket）→ 并号确认（不自动并号，ticket 只在内存）；其余按 BindPhoneAction。
 * - 并号：取消 → 不发请求、不并号、不保存会话；确认 → 锁定契约没有并号接口（TODO(N-29) MERGE-SUCCESS），不伪造请求，
 *   给出明确的「暂不可用」结果。
 * - 归属：页面离开、换号时 invalidate，在途请求取消、迟到结果不改页面。
 * 单线程（UI 线程）使用。
 */
export class BindPhoneService {
  static readonly BIND_OPERATION: string = 'bindPhone';
  static readonly GET_ME_OPERATION: string = 'getMe';
  static readonly MERGE_UNAVAILABLE_KEY: string = 'bind_phone.merge.unavailable';

  private readonly client: ApiClient;
  private readonly deadlines: SmsSendDeadlines;
  private readonly phoneBinding: PhoneBindingState;
  private readonly host: BindPhoneHost;
  private readonly clock: () => number;
  private serial: number = 0;
  private owners: (() => boolean)[] = [];
  private sending: boolean = false;
  private binding: boolean = false;
  /** 并号凭据（30411 mergeable 的 merge_ticket）：只在内存，取消、离页、换号时清除。 */
  private mergeTicket: string | null = null;

  constructor(client: ApiClient, deadlines: SmsSendDeadlines, phoneBinding: PhoneBindingState, host: BindPhoneHost,
    clock: () => number = () => Date.now()) {
    this.client = client;
    this.deadlines = deadlines;
    this.phoneBinding = phoneBinding;
    this.host = host;
    this.clock = clock;
  }

  /** 离开页面、换号：在途请求作废并取消，并号凭据清除。 */
  invalidate(): void {
    this.serial++;
    this.mergeTicket = null;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.client.cancelOwned(owner);
    }
  }

  get busy(): boolean {
    return this.sending || this.binding;
  }

  /** 有待确认的并号（30411 mergeable）。 */
  get mergePending(): boolean {
    return this.mergeTicket !== null;
  }

  /** 这个号码此刻的发码状态（按规范化号码的截止时间现算）。 */
  sendState(rawPhone: string): LoginSendState {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (phone.normalized === null) {
      return new LoginSendState(0, 0);
    }
    const now: number = this.clock();
    const remaining: number = this.deadlines.remainingSec(phone.normalized, now);
    const gate: SendDeadline | null = this.deadlines.active(phone.normalized, now);
    if (gate === null) {
      return new LoginSendState(0, 0);
    }
    return gate.kind === SmsCountdown.STATE_SENT ? new LoginSendState(remaining, 0) : new LoginSendState(0, remaining);
  }

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

  /** 绑手机发码（purpose=bind）。 */
  async sendCode(rawPhone: string): Promise<SendCodeOutcome> {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (phone.normalized === null) {
      return new SendCodeOutcome('field_error', 0, 'error.20001.phone_invalid', 'phone', null);
    }
    const normalized: string = phone.normalized;
    const now: number = this.clock();
    const gate: SendDeadline | null = this.deadlines.active(normalized, now);
    if (gate !== null) {
      const remaining: number = Math.ceil((gate.untilMillis - now) / 1000);
      return gate.kind === SmsCountdown.STATE_SENT
        ? new SendCodeOutcome('countdown_active', remaining, null, null, normalized)
        : new SendCodeOutcome(SmsCountdown.STATE_RATE_LIMITED, remaining, 'error.42901', null, normalized);
    }
    if (this.sending) {
      return new SendCodeOutcome(BindOutcome.BUSY, 0, null, null, null);
    }
    const issued: number = this.serial;
    const body: Record<string, Object> = {};
    body['phone'] = normalized;
    body['purpose'] = 'bind';
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
      this.deadlines.record(normalized, this.clock() + sent.countdownSec * 1000, SmsCountdown.STATE_SENT);
      if (issued !== this.serial) {
        return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
      }
      return new SendCodeOutcome(sent.stateRaw, sent.countdownSec, null, null, normalized);
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.effect !== null) {
      const effect: ErrorEffect = result.effect;
      const countdown: SmsCountdownResult = SmsCountdown.fromMillis(result.code, effect.disableMillis, result.data);
      if (countdown.stateRaw === SmsCountdown.STATE_RATE_LIMITED) {
        this.deadlines.record(normalized, this.clock() + countdown.countdownSec * 1000, SmsCountdown.STATE_RATE_LIMITED);
      }
      if (issued !== this.serial) {
        return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
      }
      // R2-03：10007 冷静期等要求跳页的码——保留导航（页面经 Router 打开），不降为普通错误。
      const navigation: BindOutcome | null = BindOutcome.navigation(effect, result.trace6);
      if (navigation !== null) {
        return new SendCodeOutcome(BindOutcome.NAVIGATE, 0, navigation.textKey, null, normalized, result.trace6,
          navigation.route);
      }
      const mapped: BindActionResult = BindPhoneAction.ofCode(LoginErrorMapper.SEND_SMS_CODE, result.code, result.data);
      return new SendCodeOutcome(countdown.stateRaw, countdown.countdownSec, mapped.textKey ?? effect.textKey,
        effect.fields.length > 0 ? effect.fields[0] : null, normalized, result.trace6);
    }
    if (issued !== this.serial || result.outcome === ApiOutcome.LOCAL_REJECT) {
      return new SendCodeOutcome(BindOutcome.STALE, 0, null, null, null);
    }
    return new SendCodeOutcome('network_error', 0, 'error.50001', null, normalized, result.trace6);
  }

  /** 绑定（首次绑定，不带 step-up）。 */
  async bind(rawPhone: string, code: string): Promise<BindOutcome> {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    if (phone.normalized === null) {
      return new BindOutcome(BindOutcome.PHONE_INVALID, 'error.20001.phone_invalid');
    }
    if (!CodeInput.accept(code).complete) {
      return new BindOutcome(BindOutcome.CODE_INCOMPLETE);
    }
    if (this.binding) {
      return new BindOutcome(BindOutcome.BUSY);
    }
    this.mergeTicket = null;
    const issued: number = this.serial;
    const generation: number = this.client.sessionGenerationId();
    const account: string | null = this.client.sessionAccount();
    const body: Record<string, Object> = {};
    body['phone'] = phone.normalized;
    body['code'] = code;
    const request: ApiRequest = new ApiRequest(BindPhoneService.BIND_OPERATION, {}, '', JSON.stringify(body));
    request.summary = PhoneNumber.masked(phone.normalized);
    const owner: () => boolean = this.ownerFor(issued);
    request.owner = owner;
    this.binding = true;
    let result: ApiResult;
    try {
      result = await this.client.request(request);
    } finally {
      this.binding = false;
      this.release(owner);
    }
    if (result.ok) {
      // 绑定已在服务端完成：不论页面是否还在，这个会话已绑手机（会话换了就不记到别人身上）。
      if (this.client.sessionGenerationId() === generation) {
        this.phoneBinding.bindSucceeded(account);
      }
      await this.refreshMe(generation, account);
      if (issued !== this.serial || this.client.sessionGenerationId() !== generation) {
        return new BindOutcome(BindOutcome.STALE);
      }
      this.host.phoneBound();
      return new BindOutcome(BindPhoneAction.DONE);
    }
    if (issued !== this.serial) {
      return new BindOutcome(BindOutcome.STALE);
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.effect !== null) {
      // R2-03：10007 stage=cooling → ErrorActionMapper 给出 navigate DeleteAccount：保留并传给页面（当前请求仍有效，上面已核对），
      // 页面经 Router 打开注销进度页、不弹「处理中」提示；stage=processing 是 toast，走下面的普通提示。
      const navigation: BindOutcome | null = BindOutcome.navigation(result.effect, result.trace6);
      if (navigation !== null) {
        return navigation;
      }
      const mapped: BindActionResult = BindPhoneAction.ofCode(BindPhoneService.BIND_OPERATION, result.code,
        result.data);
      if (mapped.actionRaw === BindPhoneAction.MERGE_CONFIRM) {
        this.mergeTicket = BindPhoneAction.mergeTicket(result.data);
        return new BindOutcome(mapped.actionRaw, mapped.textKey ?? null, result.trace6, 0,
          PhoneNumber.masked(phone.normalized));
      }
      return new BindOutcome(mapped.actionRaw, mapped.textKey ?? null, result.trace6, result.effect.disableMillis);
    }
    if (result.outcome === ApiOutcome.LOCAL_REJECT) {
      const reason: string | null = result.localRejectReason;
      if (reason === LocalRejectReason.CANCELLED || reason === LocalRejectReason.SESSION_CHANGED) {
        return new BindOutcome(BindOutcome.STALE);
      }
      // 未决键未结、账号未知等：不发出，提示通用错误（TODO(N-29)【鸿蒙实现发现】BIND-PENDING）。
      return new BindOutcome(BindPhoneAction.ERROR, 'error.50001');
    }
    return new BindOutcome(BindPhoneAction.ERROR, 'error.50001', result.trace6);
  }

  /** getMe（绑定成功后，契约「The client fetches GET /v1/me again after success」）：按 phone_bound 更新。 */
  private async refreshMe(generation: number, account: string | null): Promise<void> {
    const result: ApiResult = await this.client.request(new ApiRequest(BindPhoneService.GET_ME_OPERATION));
    if (result.ok && this.client.sessionGenerationId() === generation) {
      this.phoneBinding.applyMe(account, result.data);
    }
  }

  /**
   * 并号确认框的决定（BR-ID-06 OPS-04）：
   * - cancel：请求发出前取消，不并号、不保存会话，清除凭据；留在绑手机页（落点未规定，TODO(N-29) MERGE-CANCEL）。
   * - confirm：锁定契约（9cd1e6f）没有 POST /v1/auth/merge 的 operation 与成功 schema——不伪造接口、不发请求，返回
   *   unavailable（页面提示「暂不可用」），凭据清除（TODO(N-29) MERGE-SUCCESS）。
   */
  decideMerge(decision: string): MergeResult {
    const hadTicket: boolean = this.mergeTicket !== null;
    this.mergeTicket = null;
    if (decision === MergeDecision.CONFIRM && hadTicket) {
      return MergeDecision.apply(MergeDecision.CONFIRM, undefined);
    }
    return MergeDecision.apply(MergeDecision.CANCEL, undefined);
  }
}
