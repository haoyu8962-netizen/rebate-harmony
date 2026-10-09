// APP-09 两个敏感写操作（提现 createWithdrawal、收款账号 savePayoutAccount）共用的提交 / 确认 / 放弃流程（brief §0 第 3、4 条，§2.5、§2.7；
// BR-ID-10 细则「敏感操作的幂等键」）。页面状态机在 WithdrawController / PayoutAccountController，这里只管：
// - 每次用户点【提交】/【保存】生成新键（ApiClient 发首包前由 PendingKeyStore 写未决记录：键、operation、请求体、脱敏摘要、账号）；
// - 10003 打开二次验证，拿到 token 后沿用原键重放 1 次；10002 / 10402 由网络层沿用原键自动重发；
// - 结果未知（超时、断连、进程被杀、没有统一外壳）不换键、不自动重发，进入待确认，只有用户点的【确认上一笔】（原键原体）与【放弃上一笔】；
// - 待确认状态有自己的版本号：一个键结束后，其余在途请求的响应只用于核对，不再改变页面；
// - 提交、确认、放弃的请求离开页面不取消（flow-map §21 B 类）：响应回来后不改已出栈的页面，结论只落到未决记录。
// - 42901：提交、确认、放弃共用一个截止时间（gate），在执行层（sendAllowed）与页面两处都生效。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { PendingKeyRecord } from '../network/PendingKeyStore';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { WalletDeps } from './WalletController';
import { WalletRecord } from './WalletJson';
import { SensitiveOutcome } from './WalletPresentation';
import { PendingView, SensitiveResultInput, WalletMessage, WalletMessages } from './WalletSession';

type JSONValue = Object | null;

/** 一次判定的结果（交给页面状态机落地）。 */
export class SensitiveStep {
  /** SensitiveOutcome 的输出。 */
  readonly outcome: WalletRecord;
  readonly phase: string;
  readonly result: ApiResult;
  /** 页面要显示的消息（错误条或轻提示）；null 不显示。 */
  readonly message: WalletMessage | null;
  /** 这次结果对应的键。 */
  readonly key: string | null;

  constructor(outcome: WalletRecord, phase: string, result: ApiResult, message: WalletMessage | null,
    key: string | null) {
    this.outcome = outcome;
    this.phase = phase;
    this.result = result;
    this.message = message;
    this.key = key;
  }

  get action(): string {
    const a: JSONValue | undefined = this.outcome['actionRaw'];
    return typeof a === 'string' ? a as string : SensitiveOutcome.PENDING_CONFIRM;
  }

  get route(): string | null {
    const r: JSONValue | undefined = this.outcome['route'];
    return typeof r === 'string' ? r as string : null;
  }

  get textKey(): string | null {
    const t: JSONValue | undefined = this.outcome['textKey'];
    return typeof t === 'string' ? t as string : null;
  }

  get disableMs(): number {
    const v: JSONValue | undefined = this.outcome['disableMs'];
    return typeof v === 'number' ? v as number : 0;
  }

  /** 成功结果的 data（completed 时为原结果的 data）。 */
  get data(): WalletRecord {
    return this.result.data as WalletRecord;
  }
}

/**
 * 点击【确认上一笔】/【放弃上一笔】时捕获的不可变身份（共性第 14 条）：账号、会话世代与原键。占用记录前与每次实际发包前都核对，
 * 账号或会话变了就不发（本地拒绝，未决键保持原样）；不在执行时按 operationId 重新挑当前记录。
 */
export class PendingClick {
  readonly account: string | null;
  readonly epoch: number;
  readonly key: string;

  constructor(account: string | null, epoch: number, key: string) {
    this.account = account;
    this.epoch = epoch;
    this.key = key;
  }

  valid(d: WalletDeps): boolean {
    return this.account !== null && d.account() === this.account && d.session.epoch === this.epoch;
  }
}

/** 一个敏感操作的提交 / 确认 / 放弃（每个发起页实例一份）。 */
export class SensitiveFlow {
  readonly op: string;
  readonly operationId: string;
  readonly stepUpAction: string;
  private readonly d: WalletDeps;
  private readonly gate: RetryAfterGate;
  /** 待确认状态的版本号：一个键结束（或换了键）加 1。 */
  private version: number = 0;
  /** 二次验证之后沿用原键重放过一次的键（再得到 10003 不再弹面板）。 */
  private replayedKey: string | null = null;

  constructor(deps: WalletDeps, op: string, operationId: string, stepUpAction: string, gate: RetryAfterGate) {
    this.d = deps;
    this.op = op;
    this.operationId = operationId;
    this.stepUpAction = stepUpAction;
    this.gate = gate;
  }

  get pendingVersion(): number {
    return this.version;
  }

  /** 当前账号这个操作的未决记录（只要出现过结果未知或停在结果未知，才算待确认）。 */
  pending(): PendingView | null {
    const record: PendingKeyRecord | null = this.d.api.pendingFor(this.operationId);
    if (record === null) {
      return null;
    }
    const view: PendingView = new PendingView(record);
    return view.everUnknown ? view : null;
  }

  /** 有未决记录但还在首次发送的在途中（别的页面实例发起、还没有结论）。 */
  inFlightElsewhere(): boolean {
    const record: PendingKeyRecord | null = this.d.api.pendingFor(this.operationId);
    return record !== null && !record.everUnknown && record.stateRaw === 'in_flight';
  }

  storeUnavailable(): boolean {
    return this.d.api.pendingStoreUnavailable();
  }

  /** 新键提交（idempotencyKey 为 null → ApiClient 生成新键）；replayKey 非 null 时为二次验证后沿用原键重放。 */
  submit(body: string, summary: string, replayKey: string | null = null, token: string | null = null):
    Promise<SensitiveStep> {
    const account: string | null = this.d.account();
    const request: ApiRequest = new ApiRequest(this.operationId, {}, '', body);
    request.summary = summary;
    request.idempotencyKey = replayKey;
    request.stepUpToken = token ?? (account === null ? null
      : this.d.session.tokens.take(this.stepUpAction, account, this.d.clock()));
    // B 类写请求：不设 owner（离开页面不取消）；42901 闸门在每次实际发包前核对。
    request.sendAllowed = this.gate.sendAllowed;
    // 二次验证后原键重放至多一次，预算按一次用户提交计（共性第 16 条）：用户的新提交（replayKey 为 null）重置预算。
    this.replayedKey = replayKey;
    return this.d.api.request(request).then((result: ApiResult) =>
    this.judge(SensitiveOutcome.SUBMIT, false, result, result.idempotencyKey ?? replayKey));
  }

  /**
   * 【确认上一笔】：原键、原请求体重发；二次验证后带 token。click 是点击时捕获的账号、会话世代与原键（共性第 14 条）：占用记录前与
   * 每次实际发包前（含二次验证后的续发）都核对，连同 42901 闸门（共性第 15 条）。
   */
  confirm(key: string, token: string | null = null, click: PendingClick | null = null): Promise<SensitiveStep> {
    const account: string | null = this.d.account();
    if (click !== null && (!click.valid(this.d) || click.key !== key)) {
      return Promise.resolve(this.judge(SensitiveOutcome.CONFIRM, true,
        ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH), key));
    }
    const t: string | null = token ?? (account === null ? null
      : this.d.session.tokens.take(this.stepUpAction, account, this.d.clock()));
    // 用户点的确认重置重放预算；二次验证后带 token 的续发占用这次预算（共性第 16 条）。
    this.replayedKey = token !== null ? key : null;
    return this.d.api.confirmPending(key, t, this.sendGuard(click)).then((result: ApiResult) =>
    this.judge(SensitiveOutcome.CONFIRM, true, result, key));
  }

  /** 【放弃上一笔】（用户已二次确认）；click 同上。 */
  abandon(key: string, click: PendingClick | null = null): Promise<SensitiveStep> {
    if (click !== null && (!click.valid(this.d) || click.key !== key)) {
      return Promise.resolve(this.judge(SensitiveOutcome.ABANDON, true,
        ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH), key));
    }
    return this.d.api.abandonPending(key, this.sendGuard(click)).then((result: ApiResult) =>
    this.judge(SensitiveOutcome.ABANDON, true, result, key));
  }

  /** 实际发包前的核对：42901 闸门 + 点击时的账号与会话世代。 */
  private sendGuard(click: PendingClick | null): () => boolean {
    const gate: RetryAfterGate = this.gate;
    return (): boolean => gate.sendAllowed() && (click === null || click.valid(this.d));
  }

  private judge(phase: string, everUnknown: boolean, result: ApiResult, key: string | null): SensitiveStep {
    const input: WalletRecord = SensitiveResultInput.of(result);
    let outcome: WalletRecord = SensitiveOutcome.of(this.op, phase, everUnknown, input);
    if (SensitiveResultInput.localReject(result)) {
      // 没有发出（存储失败、上一笔还没结清、账号不符）：键状态以存储为准，页面提示稍后再试。
      outcome = {};
      outcome['actionRaw'] = SensitiveOutcome.PENDING_CONFIRM;
      outcome['keyEnds'] = false;
      outcome['nextSubmitNewKey'] = false;
      outcome['textKey'] = 'pending_confirm.retry_later';
      outcome['local'] = true;
    }
    const action: JSONValue | undefined = outcome['actionRaw'];
    // 二次验证之后沿用原键重放仍得到 10003：不再弹面板（自动重发至多 1 次），按失败提示。
    if (action === SensitiveOutcome.STEP_UP && key !== null && this.replayedKey === key) {
      outcome['actionRaw'] = phase === SensitiveOutcome.SUBMIT ? SensitiveOutcome.SHOW_ERROR_KEY_ENDS
        : SensitiveOutcome.SHOW_ERROR_KEEP_PENDING;
      outcome['keyEnds'] = phase === SensitiveOutcome.SUBMIT;
    }
    if (action === SensitiveOutcome.STEP_UP) {
      this.d.session.tokens.on10003(this.stepUpAction);
    }
    if (action === SensitiveOutcome.DONE || (action === SensitiveOutcome.ALREADY_DONE && result.code === 0)) {
      this.d.session.tokens.onSuccess(this.stepUpAction);
    }
    // 42901：提交、确认、放弃共用的截止时间（闸门本地拦下的不再延长）。
    const disable: JSONValue | undefined = outcome['disableMs'];
    if (typeof disable === 'number' && (disable as number) > 0 && input['blockedLocally'] !== true) {
      this.gate.start(disable as number);
    }
    if (action === SensitiveOutcome.FORCE_UPDATE) {
      this.d.forceUpdate();
    }
    if (outcome['keyEnds'] === true) {
      this.version++;
      this.replayedKey = null;
    }
    // 未决记录已按这次结果结算（ApiClient 已落盘）：通知同一操作的其他发起页实例重新同步（共性第 1 条）。发起页自己按 step 落地。
    this.d.session.notifyPending(this.operationId, this);
    return new SensitiveStep(outcome, phase, result, SensitiveFlow.message(outcome, phase, result), key);
  }

  /** 页面要显示的消息：错误类 assertive，已放弃 / 已处理完成 polite；提交得到结果未知不另出消息（待确认卡本身就是提示）。 */
  private static message(outcome: WalletRecord, phase: string, result: ApiResult): WalletMessage | null {
    const action: JSONValue | undefined = outcome['actionRaw'];
    const key: JSONValue | undefined = outcome['textKey'];
    if (typeof key !== 'string') {
      return null;
    }
    if (action === SensitiveOutcome.DONE || action === SensitiveOutcome.STEP_UP) {
      return null;
    }
    if (action === SensitiveOutcome.PENDING_CONFIRM && phase === SensitiveOutcome.SUBMIT && outcome['local'] !== true) {
      return null;
    }
    const polite: boolean = action === SensitiveOutcome.ABANDONED
      || (action === SensitiveOutcome.ALREADY_DONE && key === 'pending_confirm.already_done');
    const trace: boolean = outcome['showTrace6'] === true;
    const useFallback: boolean = SensitiveFlow.useFallback(key as string);
    return WalletMessages.of(key as string, trace ? result.traceId : '', trace, !polite, useFallback);
  }

  /** 30303 子键的限制值取不到（G06）：有 fallbacks 版本就用它（没有 fallback 的子键本来就不带占位符，用原文）。 */
  private static useFallback(key: string): boolean {
    return key.startsWith('error.30303.');
  }
}
