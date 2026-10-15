// APP-13a 注销页与换号子页的公共执行层：会话协调（AccountSession）、依赖（AccountDeps）、固定身份（AccountIdentity）与消息（AccountMessage）。
// 请求归属与页面世代（brief §0「通用」）：getDeletion、getWalletSummary、getMe、requestDeletion、确认、放弃、cancelDeletion、发码、stepUp、
// bindPhone 都绑定隐私、环境、会话世代、会话作用域（full / deletion_only）与发起页面实例。会话换代（失效、登出、换账号、撤回同意、
// 切环境、作用域变化）时 AccountSession.reset 在状态同步的同步区里清空全部账号页（资金区与勾选、换号两步输入与倒计时、内存 token、
// 注销进度快照），并通知页面作废旧控制器、按新身份重建（APP-12 第 18 条）。未决记录本身按账号保留在 PendingKeyStore，不随换代删除。
import { ApiRequest, ApiResult } from '../../network/ApiClient';
import { EffectKind } from '../../network/ErrorActionMapper';
import { RetryAfterGate } from '../../network/RetryAfterGate';
import { trace6Of, withTrace6 } from '../../search/SearchController';
import { StepUpDeps, StepUpSessionPort, StepUpShared } from '../../stepup/StepUpPorts';
import { StepUpTokenCache } from '../../wallet/WalletPresentation';
import { SmsResendClock, WalletApiPort, WalletLoadFailure } from '../../wallet/WalletSession';
import { AccountDraftTexts } from './AccountDraftTexts';
import { AccountRecord } from './AccountJson';
import { AccountOutcome, AccountResultInput } from './AccountPolicies';

/** 执行器构造时一次性取得的固定身份（APP-09 第 39、52、59、60、63、65 条，S0）：之后对当前会话只做比较，不再赋值。 */
export class AccountIdentity {
  readonly account: string | null;
  /** 会话归属键（ApiClient.captureScope 的键 + 会话作用域）。 */
  readonly key: string;
  readonly sessionScope: string;
  /** AccountSession 的会话世代。 */
  readonly epoch: number;
  /**
   * 不含会话作用域的会话归属键（FU-HM-0722，APP-13a 共性 48）：账号 + 登录序号 + 会话世代 + 隐私 / 环境世代。同账号刷新令牌只把作用域
   * 从 deletion_only 换成 full（或反过来）时它不变。只用于「已写出的请求」的存活与共享结算，不用于发送前检查。
   */
  readonly ownerKey: string;

  constructor(account: string | null, key: string, sessionScope: string, epoch: number, ownerKey: string | null = null) {
    this.account = account;
    this.key = key;
    this.sessionScope = sessionScope;
    this.epoch = epoch;
    this.ownerKey = ownerKey ?? key;
  }

  static capture(d: AccountDeps): AccountIdentity {
    // 同一次读取：账号、归属键、作用域、世代都来自这一刻（第 65 条）。
    return new AccountIdentity(d.account(), d.scope(), d.sessionScope(), d.session.epoch, d.ownerScope());
  }

  /**
   * 仍是当前会话（只比较）：完整固定身份——账号、归属键（含登录序号、会话世代、隐私 / 环境世代与会话作用域）、AccountSession 世代。
   * 写请求的发送前检查（首次派发、等待刷新结束、每次实际写出前）用它（APP-13a 共性 45）。
   */
  valid(d: AccountDeps): boolean {
    return this.account !== null && d.account() === this.account && d.scope() === this.key
      && d.session.epoch === this.epoch;
  }

  /**
   * 已写出的写请求仍归这个会话（FU-HM-0722，APP-13a 共性 48，Android RC-02）：同账号、同登录序号与会话世代、同隐私 / 环境世代，
   * 不看会话作用域与 AccountSession 世代（作用域换代会 reset，但同一登录会话里已到服务端的请求照常完成共享结算，不落成结果未知）。
   * 只决定共享结算（进度变了、token 作废），页面更新仍看 valid。
   */
  writeAlive(d: AccountDeps): boolean {
    return this.account !== null && d.account() === this.account && d.ownerScope() === this.ownerKey;
  }

  get restricted(): boolean {
    return this.sessionScope === 'deletion_only';
  }
}

/** 点【确认】【放弃】【提交】【申请】时固定的身份与原键（APP-09 第 14 条）。 */
export class AccountClick {
  readonly identity: AccountIdentity;
  readonly key: string;

  constructor(identity: AccountIdentity, key: string) {
    this.identity = identity;
    this.key = key;
  }

  valid(d: AccountDeps): boolean {
    return this.identity.valid(d);
  }
}

/** 一条要给用户看的消息。seq 每次新消息加 1（页面据此播报一次）。 */
export class AccountMessage {
  readonly textKey: string;
  readonly text: string;
  readonly seq: number;
  /** 失败类 assertive；成功、已放弃、已处理完 polite。 */
  readonly assertive: boolean;

  constructor(textKey: string, text: string, seq: number, assertive: boolean) {
    this.textKey = textKey;
    this.text = text;
    this.seq = seq;
    this.assertive = assertive;
  }
}

/** 统一消息函数：trace6 独立追加；字典没有的回落服务端 msg（G26），再回落 error.50001。 */
export class AccountMessages {
  static readonly GENERIC_KEY: string = 'error.50001';
  private static counter: number = 0;

  static of(textKey: string, vars: Map<string, string> = new Map<string, string>(), traceId: string = '',
    assertive: boolean = true, useFallback: boolean = false): AccountMessage {
    const v: Map<string, string> = new Map<string, string>();
    vars.forEach((value: string, name: string) => {
      v.set(name, value);
    });
    v.set('trace6', traceId.length > 0 ? trace6Of(traceId) : '');
    let text: string = AccountDraftTexts.format(textKey, v, useFallback);
    if (text.length === 0) {
      text = AccountDraftTexts.format(AccountMessages.GENERIC_KEY, v);
    }
    if (traceId.length > 0) {
      text = withTrace6(text, traceId);
    }
    AccountMessages.counter++;
    return new AccountMessage(textKey, text, AccountMessages.counter, assertive);
  }

  static raw(text: string, assertive: boolean = true): AccountMessage {
    AccountMessages.counter++;
    return new AccountMessage('', text, AccountMessages.counter, assertive);
  }

  static polite(textKey: string): AccountMessage {
    return AccountMessages.of(textKey, new Map<string, string>(), '', false);
  }
}

/** 按「账号 + 号码 + purpose」隔离的发码截止时间与 42901（换号第 2 步 bind 发码，brief §0 Retry-After）。 */
export class KeyedDeadlines {
  private readonly sent: Map<string, number> = new Map<string, number>();
  private readonly rate: Map<string, number> = new Map<string, number>();
  private readonly inFlight: Map<string, number> = new Map<string, number>();
  private ticketSeq: number = 0;

  static key(account: string, phone: string, purpose: string): string {
    return account + '|' + phone + '|' + purpose;
  }

  /** 还要等多久才能再发（倒计时或 42901）。 */
  remainingMs(key: string, now: number): number {
    return Math.max(0, (this.sent.get(key) ?? 0) - now, (this.rate.get(key) ?? 0) - now);
  }

  rateLimited(key: string, now: number): boolean {
    return (this.rate.get(key) ?? 0) > now;
  }

  sending(key: string): boolean {
    return this.inFlight.has(key);
  }

  /** 实际发送前的核对：截止没过或在途 → 0（不发）；通过返回票号。 */
  begin(key: string, now: number): number {
    if (this.inFlight.has(key) || this.remainingMs(key, now) > 0) {
      return 0;
    }
    const t: number = ++this.ticketSeq;
    this.inFlight.set(key, t);
    return t;
  }

  finish(key: string, ticket: number, sentUntil: number | null, rateUntil: number | null): void {
    if (this.inFlight.get(key) !== ticket) {
      return;
    }
    this.inFlight.delete(key);
    if (sentUntil !== null) {
      this.sent.set(key, sentUntil);
    }
    if (rateUntil !== null) {
      this.rate.set(key, rateUntil);
    }
  }

  clear(): void {
    this.sent.clear();
    this.rate.clear();
    this.inFlight.clear();
  }
}

/**
 * 账号页与绑手机页共用的结算（harmony-review-r1 R1-04、R1-07、R1-08）。三处以前各写一份、各漏一块，统一收在这里：
 * - 10405 只消费网络层已确定的 Effect（R1-07，G41）；
 * - 读取失败（getMe、钱包摘要、getDeletion）的 42901 写进与已有路径共享的闸门（APP-12 第 32、33 条，R1-08）；
 * - bindPhone 成功（换号页、BindPhone 页；提交、确认、放弃得知 completed 0）核对原身份后丢弃全部 action 的 token（R1-04，编排者补充 5）。
 */
export class AccountSettle {
  /** 网络层已判定要进强更（FORCE_UPDATE）。REFRESH_ONLY（遗留受限令牌只刷新）与刷新失败清会话沿用网络层结论，不进强更。 */
  static forcesUpdate(result: ApiResult): boolean {
    return result.effect !== null && result.effect.effectKindRaw === EffectKind.FORCE_UPDATE;
  }

  /**
   * 写请求结果的判定输入：网络层没有判定强更的 10405（REFRESH_ONLY / 刷新失败）按「本地没有业务结果」处理（R1-07，G41），
   * 不让页面按错误码再判一次强更。其余同 AccountResultInput.fromResult。
   */
  static inputOf(result: ApiResult): AccountResultInput {
    const input: AccountResultInput = AccountResultInput.fromResult(result);
    if (input.kind === AccountResultInput.ERROR && input.code === 10405 && !AccountSettle.forcesUpdate(result)) {
      return new AccountResultInput(AccountResultInput.LOCAL, 0, null, 0, result.traceId);
    }
    return input;
  }

  /** 读取失败的共享结算：身份仍是发起时的才写；42901 按 Retry-After 写进共享闸门（缺省 5 秒）；FORCE_UPDATE 进强更。 */
  static readFailed(result: ApiResult, gate: RetryAfterGate, sameIdentity: boolean, forceUpdate: () => void): void {
    if (result.ok || !sameIdentity) {
      return;
    }
    const failure: WalletLoadFailure = WalletLoadFailure.of(result);
    if (failure.kind === WalletLoadFailure.RATE && failure.disableMs > 0) {
      gate.start(failure.disableMs);
    }
    if (AccountSettle.forcesUpdate(result)) {
      forceUpdate();
    }
  }

  /** bindPhone 成功：原身份仍是当前会话才清（别的账号的 token 不动）；返回是否清了。 */
  static bindPhoneSucceeded(tokens: StepUpTokenCache, sameIdentity: boolean): boolean {
    if (!sameIdentity) {
      return false;
    }
    tokens.onSessionChanged();
    return true;
  }
}

/**
 * 未决键的终结结果（harmony-review-r3 R3-02）：随共享未决通知一起给出（只在通知期间可取），订阅页按它在自己的页面落地——
 * abandoned / 20903（nextState=step1）回第 1 步、清空、重新验证；已完成（done）进结果页。不能只凭未决记录消失推断去向。
 */
export class PendingSettlement {
  readonly key: string;
  readonly account: string | null;
  /** 结局策略的 nextState（PhoneChangeOutcomePolicy / DeletionOutcomePolicy）。 */
  readonly nextState: string;
  readonly textKey: string | null;
  /** 这次实际发出的那份固定摘要（取不到为 null）。 */
  readonly summary: string | null;
  /**
   * 完整终结结局（FU-HM-0722，APP-13a 共性 47，Android RC-01）：终结业务错误（确认 30411 / 30414、放弃 completed 原 3xxxx 等）落第 2 步时，
   * 订阅页按它恢复第 2 步、错误提示（字段 / 横幅、30414 客服入口、已处理完轻提示）与字段保留策略。null = 发送方没给（按 nextState 处理）。
   */
  readonly outcome: AccountOutcome | null;
  /** 这次响应的 trace_id（提示独立附加 trace6）；没有为空串。 */
  readonly traceId: string;
  /** 表外码时的服务端 msg（outcome.serverMsg，G26）；没有为空串。 */
  readonly serverMsg: string;

  constructor(key: string, account: string | null, nextState: string, textKey: string | null,
    summary: string | null = null, outcome: AccountOutcome | null = null, traceId: string = '', serverMsg: string = '') {
    this.key = key;
    this.account = account;
    this.nextState = nextState;
    this.textKey = textKey;
    this.summary = summary;
    this.outcome = outcome;
    this.traceId = traceId;
    this.serverMsg = serverMsg;
  }

  /**
   * 终结业务错误的页面提示（与发起页 AccountSensitiveFlow.message 同一口径）：表外码用服务端 msg；文案键按 trace6 策略独立附加 trace6。
   * 没有 outcome 或没有可显示的提示为 null。
   */
  message(): AccountMessage | null {
    const o: AccountOutcome | null = this.outcome;
    if (o === null) {
      return null;
    }
    if (o.serverMsg) {
      return this.serverMsg.length > 0 ? AccountMessages.raw(this.serverMsg) : AccountMessages.of(AccountMessages.GENERIC_KEY);
    }
    if (o.textKey === null) {
      return null;
    }
    return AccountMessages.of(o.textKey, new Map<string, string>(), o.trace6 !== null ? this.traceId : '');
  }
}

/** BindPhone 页要用的账号会话共享项（AccountSession 结构上满足；App 注入给 BindPhoneService）。 */
export interface BindPhoneAccountPort {
  /** 换号与绑手机的提交、确认、放弃共用的 42901 闸门（brief §0 Retry-After，R1-03）。 */
  readonly phoneGate: RetryAfterGate;
  /** getMe 读取闸门（与「我的」等已有路径共享，R1-08）。 */
  readonly meReadGate: RetryAfterGate;
  /** 内存 step_up_token（成功后全部丢弃，R1-04）。 */
  readonly tokens: StepUpTokenCache;
  /**
   * bindPhone 未决记录结算后通知其他发起页（换号页与 BindPhone 页共用，harmony-review-r2 R2-04）；键终结时带上终结结果（R3-02）。
   */
  notifyPending(operationId: string, source: Object, settled?: PendingSettlement | null): void;
  subscribePending(operationId: string, listener: (source: Object) => void): () => void;
  /** 正在通知的这次结算携带的终结结果（FU-HM-0722 R1-01：BindPhone 接收方按它恢复表单与错误）；不在通知期间为 null。 */
  settledNow(operationId: string): PendingSettlement | null;
}

/** 会话换代时要清空的执行器。 */
export interface AccountSessionAware {
  resetForSession(): void;
}

/**
 * 账号页的会话协调（App 一份）。闸门的共享范围（brief §0「Retry-After」）：注销的申请、确认、放弃一个（deletionGate）；换号的提交、
 * 确认、放弃一个（phoneGate）；撤回注销一个（cancelGate）；getDeletion 读取一个（deletionReadGate）；step_up 发码与验证用二次验证的
 * 共享服务（与钱包同一份 StepUpShared）；bind 发码按「账号 + 新号 + purpose」（bindSms）；getMe 与钱包摘要的读取截止时间与已有路径
 * 共享（meReadGate = MeSession.readGate，walletReadGate = WalletSession.readGate，APP-12 第 32、33 条）。
 */
export class AccountSession implements StepUpSessionPort, BindPhoneAccountPort {
  readonly smsGate: RetryAfterGate;
  readonly verifyGate: RetryAfterGate;
  readonly sms: SmsResendClock;
  readonly tokens: StepUpTokenCache;
  readonly stepUp: StepUpShared;
  readonly deletionGate: RetryAfterGate;
  readonly phoneGate: RetryAfterGate;
  readonly cancelGate: RetryAfterGate;
  readonly deletionReadGate: RetryAfterGate;
  readonly walletReadGate: RetryAfterGate;
  readonly meReadGate: RetryAfterGate;
  readonly bindSms: KeyedDeadlines = new KeyedDeadlines();
  epoch: number = 0;
  /** getDeletion 的读取世代：申请、撤回成功后推进，旧读取不得把冷静期态覆盖回初始态（反之亦然，APP-12 第 29、35 条）。 */
  deletionGeneration: number = 0;
  private readonly scope: () => string;
  private lastScope: string | undefined = undefined;
  private members: AccountSessionAware[] = [];
  private pendingListeners: Map<string, ((source: Object) => void)[]> = new Map<string, ((source: Object) => void)[]>();
  /** 正在通知的终结结果（R3-02：只在 notifyPending 期间可取）。 */
  private settling: Map<string, PendingSettlement> = new Map<string, PendingSettlement>();
  private resetListeners: (() => void)[] = [];

  constructor(clock: () => number, scope: () => string, stepUp: StepUpShared, walletReadGate: RetryAfterGate | null = null,
    meReadGate: RetryAfterGate | null = null) {
    this.scope = scope;
    this.stepUp = stepUp;
    this.smsGate = stepUp.smsGate;
    this.verifyGate = stepUp.verifyGate;
    this.sms = stepUp.sms;
    this.tokens = stepUp.tokens;
    this.deletionGate = new RetryAfterGate(clock, scope);
    this.phoneGate = new RetryAfterGate(clock, scope);
    this.cancelGate = new RetryAfterGate(clock, scope);
    this.deletionReadGate = new RetryAfterGate(clock, scope);
    this.walletReadGate = walletReadGate ?? new RetryAfterGate(clock, scope);
    this.meReadGate = meReadGate ?? new RetryAfterGate(clock, scope);
  }

  add(member: AccountSessionAware): void {
    this.members.push(member);
  }

  remove(member: AccountSessionAware): void {
    this.members = this.members.filter((m: AccountSessionAware): boolean => m !== member);
  }

  get openPages(): number {
    return this.members.length;
  }

  /** 未决记录结算了（source：发起这次请求的流程）：通知同一操作的其他发起页实例按存储重新同步（APP-09 第 1 条）。 */
  subscribePending(operationId: string, listener: (source: Object) => void): () => void {
    const list: ((source: Object) => void)[] = this.pendingListeners.get(operationId) ?? [];
    list.push(listener);
    this.pendingListeners.set(operationId, list);
    return (): void => {
      const now: ((source: Object) => void)[] = this.pendingListeners.get(operationId) ?? [];
      this.pendingListeners.set(operationId, now.filter((l: (source: Object) => void): boolean => l !== listener));
    };
  }

  notifyPending(operationId: string, source: Object, settled: PendingSettlement | null = null): void {
    if (settled !== null) {
      this.settling.set(operationId, settled);
    }
    try {
      for (const l of (this.pendingListeners.get(operationId) ?? []).slice()) {
        try {
          l(source);
        } catch (e) {
          // 单个页面出错不影响其余。
        }
      }
    } finally {
      this.settling.delete(operationId);
    }
  }

  /** 正在通知的这次结算携带的终结结果（R3-02；不是终结或不在通知期间为 null）。 */
  settledNow(operationId: string): PendingSettlement | null {
    return this.settling.get(operationId) ?? null;
  }

  /** 会话换代的同步通知（页面据此作废旧控制器并按新身份重建）。 */
  subscribeReset(listener: () => void): () => void {
    this.resetListeners.push(listener);
    return (): void => {
      this.resetListeners = this.resetListeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  /** 申请 / 撤回成功：推进读取世代（作废之前发出的 getDeletion）。 */
  advanceDeletion(): number {
    this.deletionGeneration++;
    return this.deletionGeneration;
  }

  /** 每次状态同步：归属（含会话作用域）变了就 reset 并返回 true；第一次同步只记下。 */
  sync(): boolean {
    const scope: string = this.scope();
    const changed: boolean = this.lastScope !== undefined && this.lastScope !== scope;
    this.lastScope = scope;
    if (changed) {
      this.reset();
    }
    return changed;
  }

  /** 作废并清空全部账号页（撤回同意、切环境的清理前第一步也调）。 */
  reset(): void {
    this.epoch++;
    this.deletionGeneration++;
    for (const g of [this.deletionGate, this.phoneGate, this.cancelGate, this.deletionReadGate]) {
      g.reset();
    }
    this.stepUp.reset();
    this.bindSms.clear();
    const members: AccountSessionAware[] = this.members;
    this.members = [];
    for (const m of members) {
      try {
        m.resetForSession();
      } catch (e) {
        // 单个页面出错不影响其余清空。
      }
    }
    for (const l of this.resetListeners.slice()) {
      try {
        l();
      } catch (e) {
        // 同上。
      }
    }
  }
}

/** 账号页执行器的依赖（App 注入；测试用同一套接线）。实现 StepUpDeps：二次验证面板直接用它。 */
export class AccountDeps implements StepUpDeps {
  readonly api: WalletApiPort;
  readonly session: AccountSession;
  clock: () => number = Date.now;
  /** 会话归属键（captureScope 的键 + 会话作用域）。 */
  scope: () => string = () => '';
  /**
   * 不含会话作用域的会话归属键（captureScope 的键；FU-HM-0722，共性 48）：已写出的写请求的存活条件与共享结算用。没接时同 scope（作用域
   * 变化也算失效，口径偏严）。
   */
  ownerScope: () => string = (): string => this.scope();
  account: () => string | null = () => null;
  /** 会话作用域：full / deletion_only（没有会话为 full）。 */
  sessionScope: () => string = () => 'full';
  stepUpPhone: (account: string) => string | null = (_a: string) => null;
  stepUpRestricted: () => boolean = () => false;
  forceUpdate: () => void = () => {
  };
  /** 经 Router 打开（App 内用户操作）。 */
  open: (route: string, params: Record<string, Object>) => void = (_r: string, _p: Record<string, Object>) => {
  };
  /** 统一客服出口（APP-12 AppLogin.openCustomerService）。 */
  customerService: () => void = () => {
  };
  /** privacy / agreement 的重新同意组件（10004）。 */
  reconsent: (consentType: string) => void = (_t: string) => {
  };
  /** 金额格式化（DesignSystem CouliFormat.money；Core 不依赖 DesignSystem，由 App 注入）。 */
  money: (fen: number) => string = (fen: number) => String(fen);
  /** getMe 成功（换号成功后的刷新等）：交给「我的」快照与绑手机状态（账号是发起时固定的）。 */
  meLoaded: (account: string, me: AccountRecord) => void = (_a: string, _m: AccountRecord) => {
  };
  /** 注销进度变了（申请 / 撤回成功）：强更页标签与设置入口按新进度重算。 */
  deletionChanged: () => void = () => {
  };
  /** 本端的服务端校准时钟（展示时间用，BR-TEXT-11）。 */
  displayNow: () => number = () => Date.now();
  /** 只打脱敏日志（不含手机号原文、验证码、token、请求体）。 */
  log: (message: string) => void = (_m: string) => {
  };

  constructor(api: WalletApiPort, session: AccountSession) {
    this.api = api;
    this.session = session;
  }

  /** 绑定发起页的读请求（owner：页面与本轮仍有效；sendAllowed：读取闸门）。 */
  read(operationId: string, owner: () => boolean, gate: RetryAfterGate): Promise<ApiResult> {
    const request: ApiRequest = new ApiRequest(operationId);
    request.owner = owner;
    request.sendAllowed = gate.sendAllowed;
    return this.api.request(request);
  }
}
