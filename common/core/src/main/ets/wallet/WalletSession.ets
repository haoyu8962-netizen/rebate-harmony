// APP-09 钱包类页面的公共执行层：网络端口、契约缺口端口（G01、G02）、配置端口、会话协调（WalletSession）与统一错误消息。
// 请求归属与页面世代（APP-03a 第 14、25、30、34 条，APP-04 第 4、15、22 条，APP-07 第 2、12 条）：每个读请求绑定会话归属与发起页面实例，
// 等待之后复核；会话换代（失效、登出、换账号、撤回同意、切换环境）时 WalletSession.reset 在状态同步的同步区里清空全部钱包页面
// （已显示的摘要、金额输入与估算、收款账号与实名的已填内容、内存里的 step_up_token），并把旧会话的资金页面移出导航栈（APP-08 第 1、19 条）。
// 未决记录本身按账号保留在 PendingKeyStore，不随换代删除（brief §0 第 3 条）。
import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { PendingKeyRecord } from '../network/PendingKeyStore';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { TransportFailure } from '../network/HttpTransport';
import { trace6Of, withTrace6 } from '../search/SearchController';
import { WalletDraftTexts } from './WalletDraftTexts';
import { WalletJson, WalletRecord } from './WalletJson';
import { StepUpTokenCache } from './WalletPresentation';
import { WalletStaleCache } from './WalletStaleCache';

/** 钱包类请求的网络端口（生产：ApiClient；测试：同一个 ApiClient + 本地假服务）。 */
export interface WalletApiPort {
  request(request: ApiRequest): Promise<ApiResult>;

  cancelOwned(owner: () => boolean): number;

  /** 当前会话账号该操作的未决记录（先核对账号）。 */
  pendingFor(operationId: string): PendingKeyRecord | null;

  /** 未决状态现在确认不了（存储读失败等）：为 true 时敏感写操作一律不发。 */
  pendingStoreUnavailable(): boolean;

  /** 【确认上一笔】：原键、原请求体重发（sendAllowed：提交 / 确认 / 放弃共用的 42901 闸门）。 */
  confirmPending(key: string, stepUpToken: string | null, sendAllowed: () => boolean): Promise<ApiResult>;

  /** 【放弃上一笔】：调作废接口。 */
  abandonPending(key: string, sendAllowed: () => boolean): Promise<ApiResult>;
}

export class ApiClientWalletPort implements WalletApiPort {
  private readonly client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.client.request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.client.cancelOwned(owner);
  }

  pendingFor(operationId: string): PendingKeyRecord | null {
    return this.client.pendingFor(operationId);
  }

  pendingStoreUnavailable(): boolean {
    return this.client.pendingStoreUnavailable();
  }

  confirmPending(key: string, stepUpToken: string | null, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.client.confirmPending(key, stepUpToken, sendAllowed);
  }

  abandonPending(key: string, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.client.abandonPending(key, sendAllowed);
  }
}

/**
 * 契约里还没有的实名提交与劳务协议接口（G01、G02，标「需契约」）：手写的待定 operation，不进生成的 ApiOperations，只由 Debug 假服务实现；
 * Release 构建为 null（页面置灰、不发任何请求）。结果用 ApiResult 表达（成功 / 业务错误 / 网络错误），与真实接口同一种分流。
 * TODO(N-32)：契约补上 POST /v1/me/realname、GET /v1/me/labor-agreement、POST /v1/me/labor-agreement/sign 后改为真实接口。
 */
export interface WalletContractPort {
  /** submitRealname：姓名、身份证号；签名，带 Idempotency-Key（04 §6.1、BR-ID-25）。同意记录在假服务里与提交一起发生。 */
  submitRealname(name: string, idNo: string): Promise<ApiResult>;

  /** getLaborAgreement：{version, text, text_sha256, need_sign}（04 §6.1）。 */
  getLaborAgreement(): Promise<ApiResult>;

  /** signLaborAgreement：{version, text_sha256, agreed: true}；sha256 原样回传服务端给的值。 */
  signLaborAgreement(version: string, textSha256: string): Promise<ApiResult>;
}

/** 钱包页面用到的配置（生产：ConfigStore；测试：固定值）。 */
export interface WalletConfigPort {
  /** Config texts["withdraw.sla_text"]；没下发为 null。 */
  slaText(): string | null;

  /** features.flags["earnings.dashboard.visible"]；没下发为 null。 */
  earningsFlag(): boolean | null;

  /** help_links.withdraw_rules 经校验后的 Help 参数（G26；未配置或不合法为 null）。 */
  withdrawRulesHelp(): Record<string, Object> | null;
}

/** 缺省配置（测试与配置未就绪时）：都没下发。 */
export class EmptyWalletConfig implements WalletConfigPort {
  slaText(): string | null {
    return null;
  }

  earningsFlag(): boolean | null {
    return null;
  }

  withdrawRulesHelp(): Record<string, Object> | null {
    return null;
  }
}

/** 会话换代时要清空的执行器。 */
export interface WalletSessionAware {
  resetForSession(): void;
}

/**
 * 实名状态（GET /v1/me 的 realname_status；按账号，给 Router 守卫与以后的「我的」、设置页用）。
 * 请求世代（鸿蒙 R1-09，共性第 9 条）：每次查询前 begin() 取一个新世代，响应只经 offer(世代, …) 落地，且只有最新世代才算数；
 * 实名提交成功（markVerified）也开新世代，之前发出的旧查询（可能还是 none）回来一律作废，不能把实名完成后的结论改回去。
 */
export class RealnameState {
  private account: string | null = null;
  private status: string | null = null;
  private listeners: (() => void)[] = [];
  private generation: number = 0;

  /** 发起一次 realname_status 查询：返回这次的世代（之前的查询随即作废）。 */
  begin(): number {
    this.generation++;
    return this.generation;
  }

  /** 查询结果：只有最新世代才落地；返回是否采用。 */
  offer(generation: number, account: string | null, status: string | null): boolean {
    if (generation !== this.generation || account === null || status === null) {
      return false;
    }
    this.set(account, status);
    return true;
  }

  /** 实名提交成功：开新世代（作废在途的旧查询），本账号记为 verified。返回新世代（成功后的复查用它）。 */
  markVerified(account: string): number {
    const g: number = this.begin();
    this.set(account, 'verified');
    return g;
  }

  set(account: string | null, status: string | null): void {
    if (this.account === account && this.status === status) {
      return;
    }
    this.account = account;
    this.status = status;
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 订阅方出错不影响其他页面。
      }
    }
  }

  /** 这个账号明确已实名（未知、别的账号一律为 false：未知按未实名，BR-ID-02）。 */
  verified(account: string | null): boolean {
    return account !== null && this.account === account && this.status === 'verified';
  }

  statusFor(account: string | null): string | null {
    return account !== null && this.account === account ? this.status : null;
  }

  clear(): void {
    this.generation++;
    this.set(null, null);
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }
}

/** 一次发码的结算（共享发码服务发布给所有订阅同一键的面板；鸿蒙 R2-01，共性第 26 条）。 */
export class SmsSendOutcome {
  readonly ok: boolean;
  /** 失败时面板显示的提示（成功为 null）。 */
  readonly error: WalletMessage | null;

  constructor(ok: boolean, error: WalletMessage | null) {
    this.ok = ok;
    this.error = error;
  }
}

/**
 * 短信发码的重发截止时间（鸿蒙 R1-06，共性第 6 条；APP-05a 第 5、20、21 条）：放在会话共享服务里，按账号、规范化号码与 action 隔离。
 * 二次验证面板关闭重开时恢复倒计时；每次实际发送前都核对同一个截止时间与「发送在途」，同一时刻不会发两次。会话换代时清空。
 */
export class SmsResendClock {
  private readonly deadlines: Map<string, number> = new Map<string, number>();
  private readonly inFlight: Set<string> = new Set<string>();
  private listeners: Map<string, ((outcome: SmsSendOutcome) => void)[]> =
    new Map<string, ((outcome: SmsSendOutcome) => void)[]>();

  static key(account: string, phone: string, action: string): string {
    return account + '|' + phone + '|' + action;
  }

  /** 还要等多少毫秒才能再发（0 = 可以发）。 */
  remainingMs(key: string, now: number): number {
    const until: number | undefined = this.deadlines.get(key);
    return until === undefined ? 0 : Math.max(0, until - now);
  }

  /** 这个号码 + action 已经发过码（截止时间还没过，面板显示「验证码已发送」）。 */
  sent(key: string, now: number): boolean {
    return this.remainingMs(key, now) > 0;
  }

  sending(key: string): boolean {
    return this.inFlight.has(key);
  }

  /** 实际发送前的核对：截止时间没过或已有发送在途 → 不发。通过时登记「发送在途」。 */
  tryBegin(key: string, now: number): boolean {
    if (this.inFlight.has(key) || this.remainingMs(key, now) > 0) {
      return false;
    }
    this.inFlight.add(key);
    return true;
  }

  /**
   * 发送结束：成功时记下截止时间（发起面板关了也记），失败只解除在途；然后把结算发布给订阅这个键的面板（发起面板与在途期间
   * 重新打开的面板都靠这里解除 sending、恢复倒计时或重试状态，鸿蒙 R2-01）。
   */
  finish(key: string, untilMs: number | null, outcome: SmsSendOutcome | null = null): void {
    this.inFlight.delete(key);
    if (untilMs !== null) {
      this.deadlines.set(key, untilMs);
    }
    const ls: ((outcome: SmsSendOutcome) => void)[] = (this.listeners.get(key) ?? []).slice();
    const o: SmsSendOutcome = outcome ?? new SmsSendOutcome(untilMs !== null, null);
    for (const l of ls) {
      try {
        l(o);
      } catch (e) {
        // 一个面板出错不影响其他面板。
      }
    }
  }

  /** 订阅某个键（账号 + 号码 + action）的发码结算；返回退订函数。 */
  subscribe(key: string, listener: (outcome: SmsSendOutcome) => void): () => void {
    const ls: ((outcome: SmsSendOutcome) => void)[] = this.listeners.get(key) ?? [];
    ls.push(listener);
    this.listeners.set(key, ls);
    return (): void => {
      const cur: ((outcome: SmsSendOutcome) => void)[] = (this.listeners.get(key) ?? [])
        .filter((l: (outcome: SmsSendOutcome) => void): boolean => l !== listener);
      if (cur.length === 0) {
        this.listeners.delete(key);
      } else {
        this.listeners.set(key, cur);
      }
    };
  }

  /** 订阅者个数（测试用：面板关闭后必须退订）。 */
  listenerCount(key: string): number {
    return (this.listeners.get(key) ?? []).length;
  }

  clear(): void {
    this.deadlines.clear();
    this.inFlight.clear();
  }
}

/**
 * 钱包类页面的会话协调（App 一份）：42901 闸门、内存里的 step_up_token、钱包需要刷新的标记、实名状态，以及打开着的执行器登记。
 * 闸门的共享范围（brief §0「Retry-After」，APP-05a 第 11 条）：
 * - read：摘要、rules（含估算）、收款账号读取、提现记录列表与详情的刷新 / 重试；
 * - withdraw：提现的提交、确认、放弃；payout：收款账号的保存、确认、放弃；
 * - sms：二次验证发码；verify：【验证并提交】；realname：【提交认证】；labor：【同意并签署】。
 */
export class WalletSession {
  static readonly FUND_ROUTES: string[] = ['Withdraw', 'PayoutAccount', 'RealName', 'LaborAgreement',
    'WithdrawRecords', 'Wallet'];
  readonly readGate: RetryAfterGate;
  readonly withdrawGate: RetryAfterGate;
  readonly payoutGate: RetryAfterGate;
  readonly smsGate: RetryAfterGate;
  readonly verifyGate: RetryAfterGate;
  readonly realnameGate: RetryAfterGate;
  readonly laborGate: RetryAfterGate;
  readonly tokens: StepUpTokenCache = new StepUpTokenCache();
  readonly realname: RealnameState = new RealnameState();
  readonly sms: SmsResendClock = new SmsResendClock();
  /** 提交成功（或放弃时得知已受理）后钱包摘要要重取（G19）。 */
  walletNeedsRefresh: boolean = false;
  /** 会话世代：每次 reset 加 1。 */
  epoch: number = 0;
  /** 把这些路由的页面全部移出导航栈（App：StackNavigator.remove）。 */
  removePages: (route: string) => void = (_r: string) => {
  };
  private readonly scope: () => string;
  private members: WalletSessionAware[] = [];
  private lastScope: string | undefined = undefined;
  private pendingListeners: Map<string, ((source: Object) => void)[]> = new Map<string, ((source: Object) => void)[]>();

  constructor(clock: () => number, scope: () => string) {
    this.scope = scope;
    this.readGate = new RetryAfterGate(clock, scope);
    this.withdrawGate = new RetryAfterGate(clock, scope);
    this.payoutGate = new RetryAfterGate(clock, scope);
    this.smsGate = new RetryAfterGate(clock, scope);
    this.verifyGate = new RetryAfterGate(clock, scope);
    this.realnameGate = new RetryAfterGate(clock, scope);
    this.laborGate = new RetryAfterGate(clock, scope);
  }

  add(member: WalletSessionAware): void {
    this.members.push(member);
  }

  remove(member: WalletSessionAware): void {
    this.members = this.members.filter((m: WalletSessionAware): boolean => m !== member);
  }

  get openPages(): number {
    return this.members.length;
  }

  /**
   * 订阅某个敏感操作（createWithdrawal / savePayoutAccount）的未决记录变化（鸿蒙 R1-01，共性第 1 条）：任一页面实例发起的提交、确认、
   * 放弃结算后（含超时变为结果未知、成功、键结束），通知当前打开的发起页按未决存储重新同步；通知只带来源，不带页面状态，
   * 旧页面不直接改新页面。账号隔离由各页的 pendingFor（先核对账号）保证。
   */
  subscribePending(operationId: string, listener: (source: Object) => void): () => void {
    const list: ((source: Object) => void)[] = this.pendingListeners.get(operationId) ?? [];
    list.push(listener);
    this.pendingListeners.set(operationId, list);
    return (): void => {
      const now: ((source: Object) => void)[] = this.pendingListeners.get(operationId) ?? [];
      this.pendingListeners.set(operationId, now.filter((l: (source: Object) => void): boolean => l !== listener));
    };
  }

  /** 未决记录结算了（source：发起这次请求的 SensitiveFlow）。 */
  notifyPending(operationId: string, source: Object): void {
    const list: ((source: Object) => void)[] = (this.pendingListeners.get(operationId) ?? []).slice();
    for (const l of list) {
      try {
        l(source);
      } catch (e) {
        // 单个页面出错不影响其余页面。
      }
    }
  }

  /** 每次状态同步：会话归属变了就 reset 并返回 true；第一次同步只记下。 */
  sync(): boolean {
    const scope: string = this.scope();
    const changed: boolean = this.lastScope !== undefined && this.lastScope !== scope;
    this.lastScope = scope;
    if (changed) {
      this.reset();
    }
    return changed;
  }

  /** 作废并清空全部钱包页面（撤回同意、切换环境的清理前第一步也调）。 */
  reset(): void {
    this.epoch++;
    for (const g of [this.readGate, this.withdrawGate, this.payoutGate, this.smsGate, this.verifyGate,
      this.realnameGate, this.laborGate]) {
      g.reset();
    }
    this.tokens.onSessionChanged();
    this.realname.clear();
    this.sms.clear();
    this.walletNeedsRefresh = false;
    const members: WalletSessionAware[] = this.members;
    this.members = [];
    for (const m of members) {
      try {
        m.resetForSession();
      } catch (e) {
        // 单个页面出错不影响其余清空。
      }
    }
    if (members.length > 0) {
      for (const route of WalletSession.FUND_ROUTES) {
        try {
          this.removePages(route);
        } catch (e) {
          // 导航出错：页面数据已清空，不再显示旧账号的内容。
        }
      }
    }
  }
}

/**
 * 发起页（提现、收款账号）的分区（鸿蒙 R1-02，共性第 2 条）：待确认卡独立于 rules / 收款账号的读取状态，读取失败或加载中也显示；
 * body 只决定读取内容那一块显示什么（idle / loading / error / content）。页面按它渲染，单测按它核对。
 */
export class FundPageLayout {
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly ERROR: string = 'error';
  static readonly CONTENT: string = 'content';
  /** 显示待确认卡（确认与放弃按各自闸门、在途状态可用）。 */
  readonly pendingCard: boolean;
  /** 显示「别处的提交在途」提示（没有待确认时）。 */
  readonly busyNotice: boolean;
  readonly body: string;

  constructor(pendingCard: boolean, busyNotice: boolean, body: string) {
    this.pendingCard = pendingCard;
    this.busyNotice = busyNotice;
    this.body = body;
  }
}

/** 一条要给用户看的消息（错误条、轻提示）。seq 每次新消息加 1（页面据此播报一次，APP-07 第 33 条）。 */
export class WalletMessage {
  readonly textKey: string;
  readonly traceId: string;
  readonly showTrace6: boolean;
  /** 已组好的正文（带 trace6）。 */
  readonly text: string;
  readonly seq: number;
  /** 失败类（assertive 播报）。 */
  readonly assertive: boolean;

  constructor(textKey: string, traceId: string, showTrace6: boolean, seq: number, assertive: boolean = true,
    useFallback: boolean = false) {
    this.textKey = textKey;
    this.traceId = traceId;
    this.showTrace6 = showTrace6;
    this.seq = seq;
    this.assertive = assertive;
    this.text = WalletMessages.compose(textKey, traceId, showTrace6, useFallback);
  }
}

/** 统一错误消息函数：trace6 独立追加，不依赖文案里有 {trace6}；未收录的 5xxxx 回落 error.50001（APP-06a 第 6、12 条，APP-08 第 8、16 条）。 */
export class WalletMessages {
  static readonly GENERIC_KEY: string = 'error.50001';
  private static counter: number = 0;

  static nextSeq(): number {
    WalletMessages.counter++;
    return WalletMessages.counter;
  }

  static compose(textKey: string, traceId: string, showTrace6: boolean, useFallback: boolean = false): string {
    const trace6: string = showTrace6 ? trace6Of(traceId) : '';
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('trace6', trace6);
    let text: string = WalletDraftTexts.format(textKey, vars, useFallback);
    if (text.length === 0) {
      text = WalletDraftTexts.format(WalletMessages.GENERIC_KEY, vars);
    }
    return showTrace6 ? withTrace6(text, traceId) : text;
  }

  static of(textKey: string, traceId: string = '', showTrace6: boolean = false, assertive: boolean = true,
    useFallback: boolean = false): WalletMessage {
    return new WalletMessage(textKey, traceId, showTrace6, WalletMessages.nextSeq(), assertive, useFallback);
  }
}

/** 读请求（摘要、rules、收款账号、提现记录）失败的分类。 */
export class WalletLoadFailure {
  /** 断网、超时、没有统一外壳（钱包摘要用缓存，其余显示错误态与【重试】）。 */
  static readonly NETWORK: string = 'network';
  /** 42901（或被闸门拦下）：按 Retry-After 禁用刷新与重试。 */
  static readonly RATE: string = 'rate';
  static readonly SERVER: string = 'server';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly CODE: string = 'code';
  /** 字段缺失或类型不符（坏数据）。 */
  static readonly BAD_DATA: string = 'bad_data';
  static readonly NETWORK_KEY: string = 'wallet.network_error';

  readonly kind: string;
  readonly code: number;
  readonly message: WalletMessage;
  readonly disableMs: number;

  constructor(kind: string, code: number, message: WalletMessage, disableMs: number = 0) {
    this.kind = kind;
    this.code = code;
    this.message = message;
    this.disableMs = disableMs;
  }

  static badData(): WalletLoadFailure {
    return new WalletLoadFailure(WalletLoadFailure.BAD_DATA, 0, WalletMessages.of(WalletMessages.GENERIC_KEY));
  }

  /** 失败结果的分类（成功不要调）。 */
  static of(result: ApiResult): WalletLoadFailure {
    if (result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason === LocalRejectReason.SEND_BLOCKED) {
      return new WalletLoadFailure(WalletLoadFailure.RATE, 42901, WalletMessages.of('error.42901'), 0);
    }
    if (result.outcome === ApiOutcome.NETWORK_ERROR || result.outcome === ApiOutcome.LOCAL_REJECT
      || result.code < 0) {
      return new WalletLoadFailure(WalletLoadFailure.NETWORK, -1, WalletMessages.of(WalletLoadFailure.NETWORK_KEY));
    }
    const code: number = result.code;
    if (code === 42901) {
      const ms: number = result.effect !== null && result.effect.disableMillis > 0 ? result.effect.disableMillis
        : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
      return new WalletLoadFailure(WalletLoadFailure.RATE, code, WalletMessages.of('error.42901'), ms);
    }
    if (code >= 50000 && code <= 59999) {
      // 5xxxx 不伪装成空结果或「余额为 0」（APP-06b 第 19 条）。
      return new WalletLoadFailure(WalletLoadFailure.SERVER, code,
        WalletMessages.of(ErrorActionMapper.textKey(code, null) ?? WalletMessages.GENERIC_KEY, result.traceId, true));
    }
    if (code === 10405) {
      return new WalletLoadFailure(WalletLoadFailure.FORCE_UPDATE, code, WalletMessages.of(WalletMessages.GENERIC_KEY));
    }
    return new WalletLoadFailure(WalletLoadFailure.CODE, code,
      WalletMessages.of(ErrorActionMapper.textKey(code, null) ?? WalletMessages.GENERIC_KEY));
  }

  /** 是否传输层失败（被取消不算；钱包摘要只在这种情况用缓存）。 */
  static transport(result: ApiResult): boolean {
    if (result.outcome === ApiOutcome.LOCAL_REJECT) {
      return result.localRejectReason !== LocalRejectReason.SEND_BLOCKED;
    }
    return result.outcome === ApiOutcome.NETWORK_ERROR && result.failure !== TransportFailure.CANCELLED;
  }
}

/** ApiResult → SensitiveOutcome 的判定输入（已解包）。 */
export class SensitiveResultInput {
  static of(result: ApiResult): WalletRecord {
    const out: WalletRecord = {};
    if (result.pendingResolution === 'abandoned') {
      out['kind'] = 'abandon_result';
      out['outcome'] = 'abandoned';
      return out;
    }
    if (result.pendingResolution === 'completed') {
      out['kind'] = 'abandon_result';
      out['outcome'] = 'completed';
      const original: WalletRecord = {};
      original['code'] = result.code;
      original['msg'] = result.msg;
      original['data'] = result.data as WalletRecord;
      out['original'] = original;
      return out;
    }
    if (result.outcome === ApiOutcome.SUCCESS) {
      out['kind'] = 'ok';
      return out;
    }
    if (result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason === LocalRejectReason.SEND_BLOCKED) {
      // 共享 42901 闸门在实际发包前拦下：按限流处理（没有发出）。
      out['kind'] = 'error';
      out['code'] = 42901;
      out['blockedLocally'] = true;
      return out;
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.code >= 0) {
      out['kind'] = 'error';
      out['code'] = result.code;
      out['data'] = result.data as WalletRecord;
      out['traceId'] = result.traceId;
      const headers: WalletRecord = {};
      if (result.effect !== null && result.effect.disableMillis > 0) {
        headers['Retry-After'] = String(Math.round(result.effect.disableMillis / 1000));
      }
      out['headers'] = headers;
      return out;
    }
    out['kind'] = 'transport';
    return out;
  }

  /** 本地拒绝且没有发出（存储失败、键未结清、账号不符等，不含闸门）：调用方按「暂时无法确认 / 稍后再试」提示，键状态以存储为准。 */
  static localReject(result: ApiResult): boolean {
    return result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason !== LocalRejectReason.SEND_BLOCKED;
  }
}

/** 未决记录在页面上的样子（金额取未决记录的请求体，收款账号取服务端当前绑定的脱敏串）。 */
export class PendingView {
  readonly key: string;
  readonly everUnknown: boolean;
  readonly inFlight: boolean;
  /** 提现：请求体 amount_fen；收款账号：null。 */
  readonly amountFen: number | null;
  /** 收款账号：本机脱敏摘要（G15）；提现：null。 */
  readonly summary: WalletRecord | null;
  readonly createdAtMillis: number;

  constructor(record: PendingKeyRecord) {
    this.key = record.key;
    this.everUnknown = record.everUnknown || record.stateRaw === 'unknown';
    this.inFlight = record.stateRaw === 'in_flight';
    let amount: number | null = null;
    try {
      const body: WalletRecord | null = WalletJson.objectOf(JSON.parse(record.body) as Object);
      amount = body === null ? null : WalletJson.fen(body, 'amount_fen');
    } catch (e) {
      amount = null;
    }
    this.amountFen = amount;
    let summary: WalletRecord | null = null;
    try {
      summary = record.summary.length > 0 ? WalletJson.objectOf(JSON.parse(record.summary) as Object) : null;
    } catch (e) {
      summary = null;
    }
    this.summary = summary;
    this.createdAtMillis = record.createdAtMillis;
  }
}
