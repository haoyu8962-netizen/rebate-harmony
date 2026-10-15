// APP-13a 两个 x-step-up 写操作（requestDeletion、bindPhone）的提交 / 确认 / 放弃（brief §0 第 1 条、§2 第 3、5、6 项；BR-ID-10 细则
// 「敏感操作的幂等键」）。与 APP-09 SensitiveFlow 同一套机制，结局按 APP-13a 的键结束口径（AccountPolicies，G40）：
// - 每次用户点【申请注销】/【提交】生成新键（ApiClient 发首包前由 PendingKeyStore 写未决记录：键、operation、请求体、脱敏摘要、账号）；
// - 10003 打开二次验证，拿到 token 后沿用原键重放 1 次（预算按一次用户提交 / 确认计，APP-09 第 16 条）；10002 / 10402 由网络层自动重发；
// - 结果未知不换键、不自动重发，进待确认；只有用户点的【确认上一次提交】（原键原体）与【放弃上一次提交】；
// - 待确认有自己的版本号：一个键结束后，其余在途响应只用于核对，不再改变页面；
// - 写请求离开页面不取消（flow-map §21 B 类）；42901 在执行层（sendAllowed，每次实际发包前）与页面两处生效；
// - 点击身份（AccountClick）在读取凭据、登记未决记录、每次实际发包前核对（APP-09 第 39、52、65 条，S0）。
import { ApiRequest, ApiResult } from '../../network/ApiClient';
import { LocalRejectReason } from '../../network/NetworkPolicy';
import { PendingKeyRecord, PendingKeyStateRaw } from '../../network/PendingKeyStore';
import { RetryAfterGate } from '../../network/RetryAfterGate';
import { AccountRecord } from './AccountJson';
import {
  AccountOutcome, AccountPhase, AccountResultInput, DeletionOutcomePolicy, KeyEnd, PhoneChangeOutcomePolicy, PhoneMask
} from './AccountPolicies';
import { AccountClick, AccountDeps, AccountMessage, AccountMessages, AccountSettle, PendingSettlement } from './AccountSession';

/** 未决记录在页面上的样子（摘要只用本机生成的脱敏串，G24）。 */
export class AccountPendingView {
  readonly key: string;
  readonly operationId: string;
  readonly everUnknown: boolean;
  readonly inFlight: boolean;
  readonly createdAtMillis: number;
  /** 换号 / 绑手机：本机脱敏的新号（取不到为 null → fallbacks 的句子）。 */
  readonly maskedPhone: string | null;

  constructor(record: PendingKeyRecord) {
    this.key = record.key;
    this.operationId = record.operationId;
    this.everUnknown = record.everUnknown || record.stateRaw === 'unknown';
    this.inFlight = record.stateRaw === 'in_flight';
    this.createdAtMillis = record.createdAtMillis;
    this.maskedPhone = PhoneMask.fromSummary(record.summary);
  }
}

/** 一次判定的结果（交给页面状态机落地）。 */
export class AccountStep {
  readonly outcome: AccountOutcome;
  readonly phase: string;
  readonly result: ApiResult;
  readonly key: string | null;
  /** 页面要显示的消息（错误条或轻提示）；null 不显示。 */
  readonly message: AccountMessage | null;
  /** completed + 3xxxx 时的「已处理完成」轻提示（G39）。 */
  readonly toast: AccountMessage | null;
  /**
   * 这次实际发出的请求的固定脱敏摘要（harmony-review-r2 R2-03）：提交 / 重放取提交开始时固定的那份，确认 / 放弃取点击时该键的未决
   * 记录摘要；取不到为 null。结果页只用它，不从可编辑表单推断成功号码。
   */
  readonly sentSummary: string | null;
  /**
   * 换号提交实际发出的新号原文（FU-HM-0722，F-X-15）：复用 held 原键原体时是原请求体里的号码；确认 / 放弃与注销为 null。
   * 页面按它核对号码类反馈是否仍属于当前输入。
   */
  sentPhone: string | null = null;

  constructor(outcome: AccountOutcome, phase: string, result: ApiResult, key: string | null,
    message: AccountMessage | null, toast: AccountMessage | null, sentSummary: string | null = null) {
    this.outcome = outcome;
    this.phase = phase;
    this.result = result;
    this.key = key;
    this.message = message;
    this.toast = toast;
    this.sentSummary = sentSummary;
  }
}

/** 提交开始时固定的实际请求（R2-02）：原键（新键在发出后回填）、原体、脱敏摘要。10003 后的重放只从这里取。 */
class FixedSubmit {
  readonly body: string;
  readonly summary: string;
  key: string | null;

  constructor(body: string, summary: string, key: string | null) {
    this.body = body;
    this.summary = summary;
    this.key = key;
  }
}

export class AccountSensitiveFlow {
  static readonly DELETION: string = 'deletion';
  static readonly PHONE: string = 'phone';
  readonly kind: string;
  readonly operationId: string;
  readonly stepUpAction: string;
  private readonly d: AccountDeps;
  private readonly gate: RetryAfterGate;
  /** 构造时固定的账号（第 65 条：未决记录只认属于它的）。 */
  private readonly boundAccount: string | null;
  /** 构造时固定的会话归属键（token 绑定它，G23）。 */
  private readonly binding: string;
  private version: number = 0;
  private replayedKey: string | null = null;
  /** 最近一次提交实际发出的请求（R2-02）。 */
  private fixed: FixedSubmit | null = null;
  /** 换号：本次提交带的 token 仍有效（结局的 keepsToken 口径）。 */
  tokenValid: boolean = false;

  constructor(deps: AccountDeps, kind: string, gate: RetryAfterGate, boundAccount: string | null, binding: string) {
    this.d = deps;
    this.kind = kind;
    this.operationId = kind === AccountSensitiveFlow.DELETION ? 'requestDeletion' : 'bindPhone';
    this.stepUpAction = kind === AccountSensitiveFlow.DELETION ? 'account_deletion' : 'phone_change';
    this.gate = gate;
    this.boundAccount = boundAccount;
    this.binding = binding;
  }

  get pendingVersion(): number {
    return this.version;
  }

  private ownRecord(): PendingKeyRecord | null {
    const record: PendingKeyRecord | null = this.d.api.pendingFor(this.operationId);
    return record !== null && this.boundAccount !== null && record.account === this.boundAccount ? record : null;
  }

  /** 本账号这个操作出现过结果未知的未决记录（待确认）。 */
  pending(): AccountPendingView | null {
    const record: PendingKeyRecord | null = this.ownRecord();
    if (record === null) {
      return null;
    }
    const v: AccountPendingView = new AccountPendingView(record);
    return v.everUnknown ? v : null;
  }

  /** 首次发送还在途（别的页面实例发起、还没有结论）。 */
  inFlightElsewhere(): boolean {
    const record: PendingKeyRecord | null = this.ownRecord();
    return record !== null && !record.everUnknown && record.stateRaw === 'in_flight';
  }

  keyOpen(key: string): boolean {
    const record: PendingKeyRecord | null = this.ownRecord();
    return record !== null && record.key === key;
  }

  keySuperseded(key: string): boolean {
    const record: PendingKeyRecord | null = this.ownRecord();
    return record !== null && record.key !== key;
  }

  /**
   * 本账号这个操作保留着的键（R1-02：从未结果未知、收到 10007 / 5xxxx / 10405 等不结束键的响应）：下一次用户提交沿用原键原体，
   * 不生成新键。没有为 null。
   */
  heldRecord(): PendingKeyRecord | null {
    const record: PendingKeyRecord | null = this.ownRecord();
    return record !== null && !record.everUnknown && record.stateRaw === PendingKeyStateRaw.HELD ? record : null;
  }

  storeUnavailable(): boolean {
    return this.d.api.pendingStoreUnavailable();
  }

  /**
   * 用户新提交（replayKey 为 null → ApiClient 生成新键）；replayKey 非 null 为二次验证后沿用原键重放。
   * R2-02：提交开始时固定实际使用的原键、原体、摘要（held 记录在则取 held 的）；replayKey 重放只用这份固定请求，不回退到调用方传来的
   * （可能已在 held 之后被编辑过的）body / summary。
   */
  submit(body: string, summary: string, replayKey: string | null, token: string | null, click: AccountClick,
    source: string): Promise<AccountStep> {
    const phase: string = this.kind === AccountSensitiveFlow.DELETION ? AccountPhase.APPLY : AccountPhase.SUBMIT;
    if (!click.valid(this.d)) {
      return Promise.resolve(this.judge(phase, false, ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH), replayKey,
        source, click));
    }
    const account: string = click.identity.account as string;
    let fixed: FixedSubmit;
    const prior: FixedSubmit | null = this.fixed;
    if (replayKey !== null && prior !== null && prior.key === replayKey) {
      // R2-02：10003 后沿用原键重放——原体、摘要都取提交开始时固定的那份。
      fixed = prior;
    } else if (replayKey !== null) {
      fixed = new FixedSubmit(body, summary, replayKey);
    } else {
      // R1-02：本账号保留着的键（上一次提交得到不结束键的明确响应）：这次提交沿用原键与原请求体，禁止重新生成键（brief §0 第 1 条）。
      const held: PendingKeyRecord | null = this.heldRecord();
      fixed = held !== null ? new FixedSubmit(held.body, held.summary, held.key) : new FixedSubmit(body, summary, null);
    }
    this.fixed = fixed;
    const request: ApiRequest = new ApiRequest(this.operationId, {}, '', fixed.body.length > 0 ? fixed.body : null);
    request.summary = fixed.summary;
    request.idempotencyKey = fixed.key;
    request.stepUpToken = token ?? this.d.session.tokens.take(this.stepUpAction, account, this.d.clock(), this.binding);
    if (this.kind === AccountSensitiveFlow.PHONE) {
      this.tokenValid = request.stepUpToken !== null;
    }
    // B 类写请求：不设 owner（离开页面不取消）；42901 闸门与点击身份在每次实际发包前核对。
    request.sendAllowed = this.sendGuard(click);
    this.replayedKey = replayKey;
    return this.d.api.request(request).then((result: ApiResult) => {
      const key: string | null = result.idempotencyKey ?? request.idempotencyKey;
      if (fixed.key === null) {
        fixed.key = key;
      }
      const step: AccountStep = this.judge(phase, false, result, key, source, click, fixed.summary);
      step.sentPhone = AccountSensitiveFlow.phoneOf(fixed.body);
      return step;
    });
  }

  /** 请求体里的 phone（换号；读不出或没有为 null）。 */
  private static phoneOf(body: string): string | null {
    if (body.length === 0) {
      return null;
    }
    try {
      const parsed: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const phone: Object | undefined = parsed['phone'];
      return typeof phone === 'string' ? phone as string : null;
    } catch (e) {
      return null;
    }
  }

  /** 点击时这个键的未决记录摘要（确认 / 放弃的结果页用，R2-03）。 */
  private summaryOf(key: string): string | null {
    const record: PendingKeyRecord | null = this.ownRecord();
    return record !== null && record.key === key ? record.summary : null;
  }

  /** 【确认上一次提交】：原键、原请求体重发；二次验证后带 token。 */
  confirm(key: string, token: string | null, click: AccountClick, source: string): Promise<AccountStep> {
    if (!click.valid(this.d) || click.key !== key) {
      return Promise.resolve(this.judge(AccountPhase.CONFIRM, true,
        ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH), key, source, click));
    }
    const account: string = click.identity.account as string;
    const t: string | null = token ?? this.d.session.tokens.take(this.stepUpAction, account, this.d.clock(),
      this.binding);
    if (this.kind === AccountSensitiveFlow.PHONE) {
      this.tokenValid = t !== null;
    }
    this.replayedKey = token !== null ? key : null;
    const sent: string | null = this.summaryOf(key);
    return this.d.api.confirmPending(key, t, this.sendGuard(click)).then((result: ApiResult) =>
    this.judge(AccountPhase.CONFIRM, true, result, key, source, click, sent));
  }

  /** 【放弃上一次提交】（用户已二次确认）。 */
  abandon(key: string, click: AccountClick, source: string): Promise<AccountStep> {
    if (!click.valid(this.d) || click.key !== key) {
      return Promise.resolve(this.judge(AccountPhase.ABANDON, true,
        ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH), key, source, click));
    }
    const sent: string | null = this.summaryOf(key);
    return this.d.api.abandonPending(key, this.sendGuard(click)).then((result: ApiResult) =>
    this.judge(AccountPhase.ABANDON, true, result, key, source, click, sent));
  }

  private sendGuard(click: AccountClick): () => boolean {
    const gate: RetryAfterGate = this.gate;
    return (): boolean => gate.sendAllowed() && click.valid(this.d);
  }

  private judge(phase: string, everUnknown: boolean, result: ApiResult, key: string | null,
    source: string, click: AccountClick, sentSummary: string | null = null): AccountStep {
    // R1-07（G41）：网络层判定为只刷新令牌（REFRESH_ONLY，遗留 deletion_only 且本机版本不低于 min）或刷新失败已清会话的 10405：
    // 沿用网络层结论，不按错误码重判强更；这次没有业务结果，键状态以存储为准。
    const input: AccountResultInput = AccountSettle.inputOf(result);
    if (input.kind === AccountResultInput.LOCAL) {
      // 只记本地拒绝的原因码（不含正文、号码、token）。
      this.d.log(this.operationId + ' not sent: ' + (result.localRejectReason ?? ''));
    }
    const outcome: AccountOutcome = this.kind === AccountSensitiveFlow.DELETION
      ? DeletionOutcomePolicy.decide(phase, input, source, everUnknown)
      : PhoneChangeOutcomePolicy.decide(phase, input, this.tokenValid);
    if (outcome.autoResendSameKey && key !== null && this.replayedKey === key) {
      // 二次验证后原键重放仍得到 10003：停止续发并提示（至多 1 次，APP-09 第 16 条）；曾结果未知的键保持待确认。
      outcome.autoResendSameKey = false;
      outcome.stepUpAction = null;
      if (phase === AccountPhase.CONFIRM) {
        outcome.nextState = DeletionOutcomePolicy.PENDING;
      } else {
        outcome.keyEnds = true;
        outcome.nextKey = KeyEnd.NEW;
        outcome.nextState = this.kind === AccountSensitiveFlow.DELETION ? DeletionOutcomePolicy.INITIAL
          : PhoneChangeOutcomePolicy.STEP2;
      }
    }
    if (outcome.autoResendSameKey) {
      this.d.session.tokens.on10003(this.stepUpAction);
    }
    const succeeded: boolean = input.kind === AccountResultInput.OK
      || (input.kind === AccountResultInput.COMPLETED && input.code === 0);
    if (succeeded) {
      if (this.kind === AccountSensitiveFlow.PHONE) {
        // G04 / R1-04：bindPhone 成功的共享结算（与 BindPhone 页同一处）：核对原身份后丢弃全部 action 的 step_up_token。
        // FU-HM-0722（共性 48）：已写出的请求按「同账号 + 同登录会话」结算，作用域在途中换代也照常作废 token。
        AccountSettle.bindPhoneSucceeded(this.d.session.tokens, click.identity.writeAlive(this.d));
      } else {
        this.d.session.tokens.onSuccess(this.stepUpAction);
      }
    }
    // FU-HM-0722 R3-02：限流写入前复核发起时的完整身份（账号 + 登录世代 + 作用域 + AccountSession 世代）。作用域换代后 gate 已 reset，
    // start 会按当前作用域记归属，迟到的旧作用域 42901 不能写进去；网络结算与成功分支的 writeAlive 结算不受影响。
    if (outcome.disableMs > 0 && !outcome.blockedLocally && click.valid(this.d)) {
      this.gate.start(outcome.disableMs);
    }
    if (outcome.nextState === DeletionOutcomePolicy.FORCE_UPDATE && AccountSettle.forcesUpdate(result)) {
      this.d.forceUpdate();
    }
    if (outcome.keyEnds) {
      this.version++;
      this.replayedKey = null;
    }
    // R3-02：键终结时把终结结果随通知带给其他发起页（abandoned / 20903 回第 1 步，已完成进结果页）。
    // FU-HM-0722（共性 47）：带上完整结局与 trace_id / 服务端 msg，终结业务错误（落第 2 步）在别的实例上同样恢复第 2 步与错误提示。
    this.d.session.notifyPending(this.operationId, this, outcome.keyEnds && key !== null
      ? new PendingSettlement(key, click.identity.account, outcome.nextState, outcome.textKey, sentSummary, outcome,
        result.traceId, result.msg) : null);
    return new AccountStep(outcome, phase, result, key, this.message(outcome, phase, result),
      outcome.toastKey === null ? null : AccountMessages.polite(outcome.toastKey), sentSummary);
  }

  /** 页面要显示的消息：错误类 assertive；已放弃、已处理完 polite；成功、二次验证、提交得到结果未知不另出消息。 */
  private message(outcome: AccountOutcome, phase: string, result: ApiResult): AccountMessage | null {
    if (outcome.autoResendSameKey) {
      return null;
    }
    if (outcome.nextState === DeletionOutcomePolicy.COOLING || outcome.nextState === PhoneChangeOutcomePolicy.DONE) {
      return outcome.textKey === 'pending_confirm.already_done' ? AccountMessages.polite(outcome.textKey) : null;
    }
    if (outcome.textKey === 'pending_confirm.title' && !outcome.local) {
      return null;
    }
    if (outcome.serverMsg) {
      return result.msg.length > 0 ? AccountMessages.raw(result.msg) : AccountMessages.of(AccountMessages.GENERIC_KEY);
    }
    const key: string | null = outcome.textKey;
    if (key === null) {
      return null;
    }
    const polite: boolean = key === 'pending_confirm.abandoned' || key === 'pending_confirm.already_done';
    const vars: Map<string, string> = new Map<string, string>();
    let useFallback: boolean = false;
    if (key === 'error.30416') {
      if (outcome.negativeAmountFen !== null) {
        vars.set('amount', this.d.money(outcome.negativeAmountFen));
      } else {
        useFallback = true;
      }
    }
    return AccountMessages.of(key, vars, outcome.trace6 !== null ? result.traceId : '', !polite, useFallback);
  }
}

/** 换号 / 绑手机的请求体（新号只去掉首尾空白、原样提交，由服务端规范化，AC-S1-78、G33）。 */
export function bindPhoneBody(phone: string, code: string): string {
  const body: AccountRecord = {};
  body['phone'] = phone;
  body['code'] = code;
  return JSON.stringify(body);
}
