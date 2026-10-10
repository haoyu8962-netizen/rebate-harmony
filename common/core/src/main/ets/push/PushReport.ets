// APP-12 推送令牌上报（G17、G18；BR-ID-07 细则「推送令牌与会话」）：纯策略 PushReportPolicy（向量 specs/me-vectors.json pushReport）、
// 令牌来源接口 PushTokenSource 与会话级执行器 PushTokenReporter。真实推送 SDK（MobPush 鸿蒙 SDK）未接入、没有任何推送凭据：Release 的
// 令牌来源恒为「无令牌」（不初始化 SDK、不上报、不报错），Debug 假实现给测试令牌。令牌值不进日志、埋点、诊断信息。
// TODO(N-33) G17：负责人给 MobPush AppKey、SDK 引入许可与版本、AGC 开通 Push Kit 与 client_id 后，在 PrivacyGate.onConsented 的推送步骤里
// 初始化 SDK 并实现真实 PushTokenSource（AppKey 等不写进源码字面量）。
import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';

type JSONValue = Object | null;
type PushRecord = Record<string, Object | null>;

/** 策略的事件。 */
export class PushEvent {
  static readonly LOGIN_SUCCESS: string = 'login_success';
  static readonly COLD_START: string = 'cold_start';
  static readonly TOKEN_CHANGED: string = 'token_changed';
  static readonly SESSION_CHANGED: string = 'session_changed';
  static readonly RESPONSE_OK: string = 'response_ok';
  static readonly RESPONSE_ERROR: string = 'response_error';
  static readonly RESPONSE_10405: string = 'response_10405';
  static readonly LOGOUT: string = 'logout';
  static readonly CONSENT_WITHDRAWN: string = 'consent_withdrawn';
}

/** 策略的动作。 */
export class PushAction {
  static readonly NONE: string = 'none';
  static readonly SEND: string = 'send';
  static readonly MARK_PENDING: string = 'mark_pending';
  static readonly DROP: string = 'drop';
  static readonly FORCE_UPDATE: string = 'force_update';
}

/**
 * 推送上报的纯策略（G18）。状态：当前会话的身份档、会话作用域、有无令牌、令牌值、强更结论、会话世代；在途的会话世代；待报标记。
 * - 触发只有三种：登录成功（新会话保存之后）、已登录冷启动（强更检查有结果且不低于）、已登录期间令牌值变化。
 * - 同一时刻只一条在途：在途期间同一会话的新触发只记待报；在途结束后按当时的会话与令牌值再发一次（只发最新值）。
 * - 每条绑定发起时的会话世代：响应的会话不是在途那条的 → drop（不改任何状态）；会话换代（session_changed）清掉在途与待报。
 * - 不报：未同意 / 基本模式 / 游客（levelRaw 不是 member）、deletion_only、没有令牌、强更低于最低版本。
 * - 失败不自动重试；10405 交强更分流（force_update），不重发。
 * - 退出、撤回之后本实例终止，所有事件 none（重新启用另建实例）。
 * 非响应事件的 state 是当前状态补丁；响应事件的 state.session 是原请求的会话世代，不覆盖当前会话。
 */
export class PushReportPolicy {
  private level: string = '';
  private scope: string = '';
  private hasToken: boolean = false;
  private token: string = '';
  private update: string = 'unknown';
  private session: string = '';
  private inFlightSession: string | null = null;
  private pendingFlag: boolean = false;
  private terminated: boolean = false;

  get inFlight(): boolean {
    return this.inFlightSession !== null;
  }

  get pending(): boolean {
    return this.pendingFlag;
  }

  get stopped(): boolean {
    return this.terminated;
  }

  private apply(patch: PushRecord): void {
    const level: JSONValue | undefined = patch['levelRaw'];
    if (typeof level === 'string') {
      this.level = level as string;
    }
    const scope: JSONValue | undefined = patch['sessionScopeRaw'];
    if (typeof scope === 'string') {
      this.scope = scope as string;
    }
    const has: JSONValue | undefined = patch['hasToken'];
    if (typeof has === 'boolean') {
      this.hasToken = has as boolean;
    }
    const token: JSONValue | undefined = patch['token'];
    if (typeof token === 'string') {
      this.token = token as string;
    }
    const update: JSONValue | undefined = patch['forceUpdateRaw'];
    if (typeof update === 'string') {
      this.update = update as string;
    }
    const session: JSONValue | undefined = patch['session'];
    if (typeof session === 'string') {
      this.session = session as string;
    }
  }

  /** 当前状态可以上报（不含强更「检查中」的判断：冷启动另要求 supported）。 */
  private eligible(): boolean {
    return !this.terminated && this.level === 'member' && this.scope === 'full' && this.hasToken
      && this.token.length > 0 && this.session.length > 0 && this.update !== 'below';
  }

  private send(): PushRecord {
    this.inFlightSession = this.session;
    this.pendingFlag = false;
    const out: PushRecord = {};
    out['actionRaw'] = PushAction.SEND;
    out['sendToken'] = this.token;
    out['sendSession'] = this.session;
    return out;
  }

  private action(raw: string): PushRecord {
    const out: PushRecord = {};
    out['actionRaw'] = raw;
    return out;
  }

  /** 一个触发（登录成功、冷启动、令牌变化）：可报时发送；同一会话已有在途时记待报。 */
  private trigger(): PushRecord {
    if (!this.eligible()) {
      return this.action(PushAction.NONE);
    }
    if (this.inFlightSession !== null && this.inFlightSession === this.session) {
      this.pendingFlag = true;
      return this.action(PushAction.MARK_PENDING);
    }
    return this.send();
  }

  on(event: string, state: PushRecord): PushRecord {
    if (this.terminated) {
      return this.action(PushAction.NONE);
    }
    switch (event) {
      case PushEvent.LOGIN_SUCCESS:
        this.apply(state);
        return this.trigger();
      case PushEvent.COLD_START:
        this.apply(state);
        if (this.update !== 'supported') {
          return this.action(PushAction.NONE);
        }
        return this.trigger();
      case PushEvent.TOKEN_CHANGED:
        this.apply(state);
        return this.trigger();
      case PushEvent.SESSION_CHANGED:
        this.apply(state);
        this.inFlightSession = null;
        this.pendingFlag = false;
        return this.action(PushAction.NONE);
      case PushEvent.RESPONSE_OK:
      case PushEvent.RESPONSE_ERROR:
      case PushEvent.RESPONSE_10405: {
        const origin: JSONValue | undefined = state['session'];
        if (this.inFlightSession === null || origin !== this.inFlightSession) {
          return this.action(PushAction.DROP);
        }
        this.inFlightSession = null;
        if (event === PushEvent.RESPONSE_10405) {
          this.pendingFlag = false;
          return this.action(PushAction.FORCE_UPDATE);
        }
        if (this.pendingFlag) {
          this.pendingFlag = false;
          // 在途期间有新触发：按当时的会话与令牌值补发最新值（失败的那条不重发——这是新的触发）。
          return this.trigger();
        }
        return this.action(PushAction.NONE);
      }
      case PushEvent.LOGOUT:
      case PushEvent.CONSENT_WITHDRAWN:
        this.terminated = true;
        this.inFlightSession = null;
        this.pendingFlag = false;
        return this.action(PushAction.NONE);
      default:
        return this.action(PushAction.NONE);
    }
  }
}

/**
 * 推送令牌来源（G17）：当前令牌、令牌变化通知、启动 / 停止。真实实现接 MobPush 鸿蒙 SDK（未接入）。
 * 令牌值只交给上报管线，不进日志、埋点、诊断信息与界面。
 */
export interface PushTokenSource {
  /** PrivacyGate.onConsented 的推送步骤调用（Release 为空操作）。 */
  start(): void;

  /** 撤回同意时停止（不再给令牌、不再通知）。 */
  stop(): void;

  current(): string | null;

  /** 令牌值变化（含第一次拿到）；返回退订函数。 */
  subscribe(listener: () => void): () => void;
}

/** Release 的令牌来源：恒为无令牌（不初始化任何推送 SDK、不上报、不报错）。 */
export class NoPushTokenSource implements PushTokenSource {
  start(): void {
  }

  stop(): void {
  }

  current(): string | null {
    return null;
  }

  subscribe(_listener: () => void): () => void {
    return (): void => {
    };
  }
}

/** 上报管线读的 App 状态（App 组合处给）。 */
export interface PushReportState {
  /** member（已同意且已登录）/ guest / basic（未同意、基本模式、撤回清理未完成）。 */
  level(): string;

  /** full / deletion_only（没有会话为空串）。 */
  sessionScope(): string;

  /** 强更结论：supported / below / unknown。 */
  forceUpdate(): string;

  /** 当前会话世代的标识（ApiClient 会话世代 + 账号；没有会话为空串）。 */
  sessionKey(): string;

  /** 10405：交已有的强更分流（不另弹提示）。 */
  onForceUpdate(): void;
}

/**
 * 推送令牌上报执行器（会话级服务，不依赖页面）。按 PushReportPolicy 的结论发 POST /v1/devices/push-token {provider: mobpush, token}；
 * 请求绑定发起时的会话世代（owner：会话变了即作废，旧会话的响应只按原世代结算，不改新会话）。退出、撤回后终止并另建策略实例。
 */
export class PushTokenReporter {
  static readonly OPERATION: string = 'reportPushToken';
  static readonly PROVIDER: string = 'mobpush';
  private policy: PushReportPolicy = new PushReportPolicy();
  private readonly source: PushTokenSource;
  private readonly state: PushReportState;
  private readonly client: () => ApiClient | null;
  private unsubscribe: (() => void) | null = null;
  /**
   * 会话级停报（R1-02，G18 ④）：撤回同意、退出登录在确认生效的同步入口调用 halt() 记下当时的会话标识；这个会话里不再发送、不再结算补发。
   * null = 没有停报。会话换成别的（新登录）后自然失效。
   */
  private haltedSession: string | null = null;
  /**
   * 已登录冷启动在等隐私与版本检查（R1-03）：期间令牌变化不单独触发，合并到这次冷启动上报（冷启动按当时的令牌值发）。
   */
  private coldStartHeld: boolean = false;
  /**
   * 上报请求的 10006 导航许可（后台请求没有发起页面，单独定义，R1-08）：App 给「发出时的导航标记与响应时一致」的守卫工厂；
   * 缺省 null（只按网络层调用入口时的导航标记核对）。
   */
  navigationPermit: () => ((() => boolean) | null) = () => null;
  /** 本次运行是否有一条上报成功（诊断信息「推送是否已上报」，AC-S1-136）。 */
  private reported: boolean = false;
  /** 发出的条数（测试与诊断用；不含令牌）。 */
  sent: number = 0;

  constructor(source: PushTokenSource, state: PushReportState, client: () => ApiClient | null) {
    this.source = source;
    this.state = state;
    this.client = client;
    this.unsubscribe = source.subscribe((): void => this.tokenChanged());
  }

  get reportedThisRun(): boolean {
    return this.reported;
  }

  get inFlight(): boolean {
    return this.policy.inFlight;
  }

  get pending(): boolean {
    return this.policy.pending;
  }

  /** 当前会话处于停报中（撤回同意、退出登录进行中）。 */
  get halted(): boolean {
    const key: string | null = this.haltedSession;
    if (key === null) {
      return false;
    }
    let now: string = '';
    try {
      now = this.state.sessionKey();
    } catch (e) {
      return true;
    }
    return now === key;
  }

  get holdingForColdStart(): boolean {
    return this.coldStartHeld;
  }

  /**
   * 撤回同意、退出登录在确认生效的同步入口调用（R1-02）：设会话级停报、清待报、作废旧上报许可——在途请求的 owner 随之失效（之后的
   * 重试、重放都不发），它的结算不再补发；本会话里之后的触发一律不发。
   */
  halt(): void {
    let key: string = '';
    try {
      key = this.state.sessionKey();
    } catch (e) {
      key = '';
    }
    this.haltedSession = key;
    this.coldStartHeld = false;
    this.policy.on(PushEvent.LOGOUT, {});
    this.policy = new PushReportPolicy();
  }

  /** 冷启动等待隐私与版本检查期间：令牌变化合并到冷启动上报（R1-03）。 */
  holdForColdStart(): void {
    this.coldStartHeld = true;
  }

  /** 冷启动不再等待（版本低于最低、会话换代、退出）：不发，只解除合并。 */
  releaseColdStart(): void {
    this.coldStartHeld = false;
  }

  private snapshot(): PushRecord {
    const s: PushRecord = {};
    const token: string | null = this.source.current();
    s['levelRaw'] = this.state.level();
    s['sessionScopeRaw'] = this.state.sessionScope();
    s['hasToken'] = token !== null && token.length > 0;
    s['token'] = token ?? '';
    s['forceUpdateRaw'] = this.state.forceUpdate();
    s['session'] = this.state.sessionKey();
    return s;
  }

  /** 已登录冷启动（隐私闸门通过、强更检查不低于、会话 full 之后）；初始化期间的令牌变化合并到这一次。 */
  coldStart(): void {
    this.coldStartHeld = false;
    if (this.halted) {
      return;
    }
    this.run(this.policy.on(PushEvent.COLD_START, this.snapshot()));
  }

  /** 登录成功（新会话已保存）。 */
  loginSucceeded(): void {
    this.coldStartHeld = false;
    if (this.halted) {
      return;
    }
    this.run(this.policy.on(PushEvent.LOGIN_SUCCESS, this.snapshot()));
  }

  /** 会话换代（换账号、会话失效）：作废在途与待报。 */
  sessionChanged(): void {
    this.coldStartHeld = false;
    this.policy.on(PushEvent.SESSION_CHANGED, this.snapshot());
  }

  /** 退出登录、会话失效到游客：终止本实例并另建（之后的登录用新实例）。 */
  loggedOut(): void {
    this.coldStartHeld = false;
    this.policy.on(PushEvent.LOGOUT, {});
    this.policy = new PushReportPolicy();
  }

  /** 撤回同意：终止、停令牌来源、清待报；另建策略实例（重新同意并登录后再启用）。 */
  consentWithdrawn(): void {
    this.coldStartHeld = false;
    this.policy.on(PushEvent.CONSENT_WITHDRAWN, {});
    this.policy = new PushReportPolicy();
    this.reported = false;
    try {
      this.source.stop();
    } catch (e) {
      // 来源出错不影响撤回。
    }
  }

  private tokenChanged(): void {
    if (this.coldStartHeld || this.halted) {
      // 冷启动等待中：合并到冷启动上报；停报中：不发（R1-02、R1-03）。
      return;
    }
    this.run(this.policy.on(PushEvent.TOKEN_CHANGED, this.snapshot()));
  }

  private run(action: PushRecord): void {
    if (action['actionRaw'] !== PushAction.SEND) {
      return;
    }
    if (this.halted) {
      return;
    }
    const token: JSONValue | undefined = action['sendToken'];
    const session: JSONValue | undefined = action['sendSession'];
    if (typeof token !== 'string' || typeof session !== 'string') {
      return;
    }
    const client: ApiClient | null = this.client();
    const policy: PushReportPolicy = this.policy;
    const body: PushRecord = {};
    body['provider'] = PushTokenReporter.PROVIDER;
    body['token'] = token as string;
    const request: ApiRequest = new ApiRequest(PushTokenReporter.OPERATION, {}, '', JSON.stringify(body));
    // 发送前与收到响应后都核对：会话已换代就作废（不改绑到新会话）。
    request.owner = (): boolean => this.policy === policy && !this.halted && this.state.sessionKey() === session;
    try {
      request.navigationPermit = this.navigationPermit();
    } catch (e) {
      request.navigationPermit = null;
    }
    const origin: PushRecord = {};
    origin['session'] = session as string;
    if (client === null) {
      this.settle(policy, PushEvent.RESPONSE_ERROR, origin);
      return;
    }
    this.sent++;
    client.request(request).then((result: ApiResult): void => {
      if (result.outcome === ApiOutcome.SUCCESS) {
        if (this.policy === policy && this.state.sessionKey() === session) {
          this.reported = true;
        }
        this.settle(policy, PushEvent.RESPONSE_OK, origin);
        return;
      }
      this.settle(policy, result.code === 10405 ? PushEvent.RESPONSE_10405 : PushEvent.RESPONSE_ERROR, origin);
    }).catch((): void => {
      this.settle(policy, PushEvent.RESPONSE_ERROR, origin);
    });
  }

  private settle(policy: PushReportPolicy, event: string, origin: PushRecord): void {
    const next: PushRecord = policy.on(event, origin);
    if (next['actionRaw'] === PushAction.FORCE_UPDATE) {
      // 10405 在后台得到：交已有分流（网络层已调 on10405 时重复调用无害），不另弹提示。
      try {
        this.state.onForceUpdate();
      } catch (e) {
        // 分流出错不影响上报管线。
      }
      return;
    }
    if (policy === this.policy && !this.halted) {
      this.run(next);
    }
  }
}

/**
 * 推送上报的会话跟踪（App 每次状态同步调用 sync；H07 的修正，R1-03）：区分「恢复已有会话」与「真实登录成功」。
 * - 真实登录成功只认 LoginService.onLoginCompleted 给的会话世代（loginCompleted）：会话标识变成这个世代时报 login_success；
 * - 其余出现的会话（进程第一次同步就有、隐私结论或环境晚到后才可读的已存会话）一律按已登录冷启动：等隐私与版本检查有结果
 *   （不低于才报，低于丢弃），期间令牌变化合并到这次冷启动；
 * - 会话标识变空：退出 / 失效（策略实例终止并另建）。
 */
export class PushSessionTracker {
  private readonly reporter: PushTokenReporter;
  private readonly sessionKey: () => string;
  private readonly generation: () => number;
  /** 强更结论：supported / below / unknown。 */
  private readonly update: () => string;
  private last: string | undefined = undefined;
  private coldPending: boolean = false;
  private loginGeneration: number = -1;

  constructor(reporter: PushTokenReporter, sessionKey: () => string, generation: () => number, update: () => string) {
    this.reporter = reporter;
    this.sessionKey = sessionKey;
    this.generation = generation;
    this.update = update;
  }

  get coldStartPending(): boolean {
    return this.coldPending;
  }

  /** LoginService.onLoginCompleted：这次登录保存的会话世代（会话已保存、尝试仍有效，在登录后的状态同步之前同步通知）。 */
  loginCompleted(generation: number): void {
    this.loginGeneration = generation;
    const key: string = this.safeKey();
    if (this.coldPending && key.length > 0 && key === this.last && this.safeGeneration() === generation) {
      // 状态同步先于完成通知到达：这个会话其实是这次登录，按登录成功报（不再等冷启动）。
      this.coldPending = false;
      this.reporter.loginSucceeded();
    }
  }

  /** 撤回、切换环境的清理第一步：不再等冷启动。 */
  cancelColdStart(): void {
    this.coldPending = false;
    this.reporter.releaseColdStart();
  }

  private safeKey(): string {
    try {
      return this.sessionKey();
    } catch (e) {
      return '';
    }
  }

  private safeGeneration(): number {
    try {
      return this.generation();
    } catch (e) {
      return -1;
    }
  }

  /** 每次状态同步。 */
  sync(): void {
    const key: string = this.safeKey();
    const last: string | undefined = this.last;
    this.last = key;
    if (last === undefined) {
      // 本进程第一次同步：已有会话即冷启动。
      this.startCold(key.length > 0);
    } else if (last !== key) {
      this.coldPending = false;
      this.reporter.releaseColdStart();
      if (key.length === 0) {
        this.reporter.loggedOut();
      } else {
        if (last.length > 0) {
          this.reporter.sessionChanged();
        }
        if (this.loginGeneration >= 0 && this.safeGeneration() === this.loginGeneration) {
          // 真实登录成功（新会话已保存之后）：用新会话上报一次。
          this.reporter.loginSucceeded();
        } else {
          // 恢复已有会话（隐私结论、环境晚到才可读）：按冷启动，等隐私与版本检查。
          this.startCold(true);
        }
      }
    }
    if (this.coldPending && key.length > 0) {
      const update: string = this.update();
      if (update === 'below') {
        this.coldPending = false;
        this.reporter.releaseColdStart();
      } else if (update === 'supported') {
        this.coldPending = false;
        this.reporter.coldStart();
      }
    }
  }

  private startCold(pending: boolean): void {
    this.coldPending = pending;
    if (pending) {
      this.reporter.holdForColdStart();
    }
  }
}
