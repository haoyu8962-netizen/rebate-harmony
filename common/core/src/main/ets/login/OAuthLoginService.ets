import { ApiClient, ApiOutcome, ApiRequest, ApiResult, ClientScope } from '../network/ApiClient';
import { ErrorEffect } from '../network/ErrorActionMapper';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { LegalVersions, PhoneNumber, PhoneResult } from './LoginFlow';
import { AttemptTicket, LoginOutcome, LoginService } from './LoginService';
import {
  OAuthAttemptSession, OAuthErrorResult, OAuthLoginErrorAction, OAuthLoginRoute, OAuthProvider, OAuthRouteResult,
  ThirdPartyButtons
} from './OAuthLoginFlow';

/** 第三方授权的结果种类。 */
export class ThirdPartyAuthKind {
  /** 拿到授权凭证。 */
  static readonly CREDENTIAL: string = 'credential';
  /** 用户在第三方取消。 */
  static readonly CANCELLED: string = 'cancelled';
  /** 拉不起（未安装、没有 SDK / AppID）：提示 login.wechat_unavailable，保留其他方式。 */
  static readonly UNAVAILABLE: string = 'unavailable';
  /** 第三方报错。 */
  static readonly FAILED: string = 'failed';
}

/**
 * 第三方 SDK 带回的结果。凭证只在内存里，不落盘、不进日志（BR-ID-04 细则「最小化」）：toString 不输出凭证。
 * 微信：code + state（state 应等于本次尝试的 nonce，客户端自查）；Apple：identityToken + authorizationCode。
 */
export class ThirdPartyAuthResult {
  readonly kind: string;
  readonly code: string | null;
  readonly identityToken: string | null;
  readonly authorizationCode: string | null;
  /** SDK 回传的 state / nonce；没有为 null。 */
  readonly state: string | null;

  constructor(kind: string, code: string | null = null, state: string | null = null, identityToken: string | null = null,
    authorizationCode: string | null = null) {
    this.kind = kind;
    this.code = code;
    this.state = state;
    this.identityToken = identityToken;
    this.authorizationCode = authorizationCode;
  }

  static of(kind: string): ThirdPartyAuthResult {
    return new ThirdPartyAuthResult(kind);
  }

  toString(): string {
    return 'ThirdPartyAuthResult(' + this.kind + ')';
  }
}

/**
 * 第三方登录适配层（brief §2.2）：每个 provider 一个实现。
 * - adapterAvailable：适配器已允许启用（有 SDK、AppID 等并验证过）。鸿蒙正式微信适配器恒为 false（无 SDK、无 AppID，
 *   06 Q-C12 验证前不启用）；Debug 假适配器为 true，只用于测试与截图。
 * - installed：本机是否装了对应 App（只查 contracts/apps.json 登记的查询项，不读应用列表）；检测失败或没有登记的查询项为 null
 *   （未知：BR-ID-04 细则按「照常显示」，再与 adapterAvailable 相与）。
 * - authorize(nonce)：拉起第三方授权，nonce 作为微信的 state / Apple 的 nonce。不得抛出。
 */
export interface ThirdPartyAuthAdapter {
  readonly provider: string;

  adapterAvailable(): boolean;

  installed(): boolean | null;

  authorize(nonce: string): Promise<ThirdPartyAuthResult>;
}

/**
 * 鸿蒙正式的微信适配器：不可用（brief §0、§2.2：不引入微信 SDK，无 AppID / 通用链接）。按钮不显示；万一被调用，按「拉不起」
 * 返回，不发任何请求。installed：contracts/apps.json 还没有微信的查询项（sdk_queries 为空，querySchemes 由 CT-05 从它生成、
 * 不手写），检测不了，返回 null（TODO(N-29)【鸿蒙实现发现】WECHAT-QUERY）。
 */
export class UnavailableWechatAdapter implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.WECHAT;

  adapterAvailable(): boolean {
    return false;
  }

  installed(): boolean | null {
    return null;
  }

  authorize(_nonce: string): Promise<ThirdPartyAuthResult> {
    return Promise.resolve(ThirdPartyAuthResult.of(ThirdPartyAuthKind.UNAVAILABLE));
  }
}

/**
 * 本机已知的「是否绑了手机」（守卫的会话状态用：没查清已绑 → LOGGED_IN，BR-ID-02）。按账号记在内存里：
 * 短信登录 → true；第三方新号登录 → false；getMe 回来按 phone_bound；bindPhone 成功 → true；不知道为 null。
 * harmony-review-r2 R2-01（共性 8）：冷启动后内存丢失，不知道 = 未验证，守卫不当已绑；App 随状态同步查 getMe
 * （OAuthLoginService.verifyPhoneBinding）后按结果更新。
 */
export class PhoneBindingState {
  private readonly byAccount: Map<string, boolean> = new Map<string, boolean>();
  /**
   * 第三方老用户登录后、getMe 还没查清 phone_bound 的账号（APP-05b R1-02）：未知不能当已绑——守卫按「已登录未绑手机」
   * 处理（需要手机号的路由先进 BindPhone），查清后按结果更新。
   */
  private readonly unverified: Set<string> = new Set<string>();
  /**
   * 更新世代（harmony-review-r3 R3-01）：绑定成功时推进。getMe 发起时捕获，回来时世代变了就丢弃——绑定前发出的旧查询
   * （如冷启动补查读到 false 但回包延迟）不能覆盖绑定结果。
   */
  private updateGeneration: number = 0;

  /** 当前更新世代（getMe 发起时捕获）。 */
  generation(): number {
    return this.updateGeneration;
  }

  /** 绑定成功：记为已绑并推进更新世代，使绑定前发出的 getMe 回包作废。 */
  bindSucceeded(account: string | null): void {
    this.updateGeneration++;
    this.set(account, true);
  }

  set(account: string | null, bound: boolean): void {
    if (account !== null && account.length > 0) {
      this.byAccount.set(account, bound);
      this.unverified.delete(account);
    }
  }

  /** 这个账号的 phone_bound 待查（第三方老用户登录，R1-02）。 */
  markUnverified(account: string | null): void {
    if (account !== null && account.length > 0) {
      this.byAccount.delete(account);
      this.unverified.add(account);
    }
  }

  /** 这个账号的 phone_bound 是否待查（第三方登录后还没查清）。 */
  isUnverified(account: string | null): boolean {
    return account !== null && this.unverified.has(account);
  }

  /** 守卫不能把这个账号当作已绑手机：只有查清是 true 才算已绑；已知 false、待查、不知道（冷启动）都按未绑（R1-02、R2-01）。 */
  treatAsUnbound(account: string | null): boolean {
    return this.get(account) !== true;
  }

  get(account: string | null): boolean | null {
    if (account === null) {
      return null;
    }
    const value: boolean | undefined = this.byAccount.get(account);
    return value === undefined ? null : value;
  }

  /** 从 getMe 的 data 读 phone_bound（不是布尔时不改）。 */
  applyMe(account: string | null, data: Record<string, Object>): void {
    const bound: Object | undefined = data['phone_bound'];
    if (typeof bound === 'boolean') {
      this.set(account, bound as boolean);
    }
  }
}

/** 第三方登录的结果。 */
export class OAuthLoginOutcome {
  static readonly LOGGED_IN: string = 'logged_in';
  static readonly CANCELLED: string = 'cancelled';
  static readonly UNAVAILABLE: string = 'unavailable';
  static readonly TIMEOUT: string = 'timeout';

  /**
   * logged_in / cancelled（用户在第三方取消）/ unavailable（拉不起）/ timeout / stale（离页、换方式、迟到）/ busy /
   * agreement_required / 错误时为 OAuthErrorResult.actionRaw（reauthorize、provider_unavailable、risk_blocked、
   * force_update、service_error、retry_after、network_error、field_error、message）。
   */
  readonly stateRaw: string;
  /** 登录成功的分流（done / bind_phone_guide）；其余为 null。 */
  readonly routeRaw: string | null;
  readonly textKey: string | null;
  readonly trace6: string;
  readonly disableMillis: number;
  /** 登录成功时短信登录同一份结果（执行了的登录后计划）。 */
  readonly login: LoginOutcome | null;

  constructor(stateRaw: string, routeRaw: string | null = null, textKey: string | null = null, trace6: string = '',
    disableMillis: number = 0, login: LoginOutcome | null = null) {
    this.stateRaw = stateRaw;
    this.routeRaw = routeRaw;
    this.textKey = textKey;
    this.trace6 = trace6;
    this.disableMillis = disableMillis;
    this.login = login;
  }
}

/**
 * 第三方登录的执行器（APP-05b；BR-ID-04 细则；03 §4.2、§4.4）：
 * createOauthAttempt → 拉起第三方（nonce 作 state）→ 拿到授权凭证 → loginByWechat / loginByApple；只上送 attempt_id 与授权
 * 凭证（加协议版本与同意时刻），不在客户端换 token。
 * - 归属：与短信登录共用 LoginService 的尝试序号（attemptTicket）——离开登录页、换号、登出时 LoginService.invalidateAttempt
 *   作废本次尝试并取消它的请求；本地授权尝试（OAuthAttemptSession）随之按「离开」终止，迟到的回调只丢弃，同一尝试只提交一次。
 * - 用户取消、超时（ATTEMPT_TIMEOUT_MILLIS，BR-ID-04 尝试 600 秒）同样终止；回前台后迟到的回调丢弃。
 * - SDK 回传的 state 与本次 nonce 不一致：不提交（客户端自查），按需重新授权。
 * - 登录保存沿用 APP-05a：ApiClient 原子保存与世代检查；LoginService.finishSessionLogin 执行登录后计划。第三方新号（routeRaw =
 *   bind_phone_guide）先保留待办，引导结束后再恢复（BR-INV-03 细则 ①）。
 * 单线程（UI 线程）使用。
 */
export class OAuthLoginService {
  /** 授权等待上限（BR-ID-04：尝试 600 秒过期；配置 auth.oauth_attempt_ttl_sec 未下发时按缺省）。 */
  static readonly ATTEMPT_TIMEOUT_MILLIS: number = 600 * 1000;
  static readonly CREATE_OPERATION: string = 'createOauthAttempt';
  static readonly GET_ME_OPERATION: string = 'getMe';
  static readonly PLATFORM: string = 'harmony';

  private readonly client: ApiClient;
  private readonly login: LoginService;
  private readonly adapters: Map<string, ThirdPartyAuthAdapter> = new Map<string, ThirdPartyAuthAdapter>();
  private readonly legal: LegalVersions;
  private readonly delay: (millis: number) => Promise<void>;
  readonly phoneBinding: PhoneBindingState;
  /** 本地授权尝试（观测：submitted / dropped）。 */
  readonly session: OAuthAttemptSession = new OAuthAttemptSession();
  /** 绑手机引导是否开启（/v1/config.invite.bind_phone_guide，缺省 on，BR-INV-21）。 */
  guideEnabled: () => boolean = () => true;
  private running: boolean = false;
  private callbackSeq: number = 0;
  /** 当前等待中的授权：作废时立即结束等待（不等 SDK 回来）。 */
  private abandon: (() => void) | null = null;
  /** 在途的 getMe（R2-01：同一会话世代、同一账号只查一次，登录流程与状态同步共用结果）。 */
  private meInFlight: Promise<boolean> | null = null;
  private meInFlightGeneration: number = -1;
  private meInFlightAccount: string | null = null;
  private meInFlightBinding: number = -1;

  constructor(client: ApiClient, login: LoginService, adapters: ThirdPartyAuthAdapter[],
    phoneBinding: PhoneBindingState, legal: LegalVersions = LegalVersions.bundled(),
    delay: (millis: number) => Promise<void> = (millis: number): Promise<void> => new Promise<void>(
      (resolve: () => void): void => {
        setTimeout(resolve, millis);
      })) {
    this.client = client;
    this.login = login;
    for (const adapter of adapters) {
      this.adapters.set(adapter.provider, adapter);
    }
    this.phoneBinding = phoneBinding;
    this.legal = legal;
    this.delay = delay;
    login.onAttemptInvalidated((): void => this.leave());
  }

  /** 登录页要显示的第三方按钮（provider 名）。鸿蒙只有微信候选（无 Apple，BR-ID-04；华为账号登录在 HM-08）。 */
  visibleProviders(): string[] {
    const out: string[] = [];
    const wechat: ThirdPartyAuthAdapter | undefined = this.adapters.get(OAuthProvider.WECHAT);
    if (wechat !== undefined) {
      const installed: boolean | null = OAuthLoginService.safeInstalled(wechat);
      // BR-ID-04 细则：检测失败、结果未知时照常显示（再与适配器可用性相与）。
      if (ThirdPartyButtons.wechatVisible(OAuthLoginService.PLATFORM, installed === null ? true : installed,
        OAuthLoginService.safeAvailable(wechat))) {
        out.push(OAuthProvider.WECHAT);
      }
    }
    const apple: ThirdPartyAuthAdapter | undefined = this.adapters.get(OAuthProvider.APPLE);
    if (apple !== undefined && ThirdPartyButtons.appleVisible(OAuthLoginService.PLATFORM)
      && OAuthLoginService.safeAvailable(apple)) {
      out.push(OAuthProvider.APPLE);
    }
    return out;
  }

  get busy(): boolean {
    return this.running;
  }

  /** 离开登录页 / 换号 / 登出（LoginService 作废尝试时同步调用）：本地授权尝试终止，等待立即结束。 */
  private leave(): void {
    this.session.leave();
    const abandon: (() => void) | null = this.abandon;
    this.abandon = null;
    if (abandon !== null) {
      abandon();
    }
  }

  /** consentAtMillis：勾选或确认框同意的时刻（同短信登录，BR-ID-04）。 */
  async loginWith(provider: string, consentAtMillis: number | null): Promise<OAuthLoginOutcome> {
    const adapter: ThirdPartyAuthAdapter | undefined = this.adapters.get(provider);
    const operationId: string | null = OAuthProvider.loginOperation(provider);
    if (adapter === undefined || operationId === null || !OAuthLoginService.safeAvailable(adapter)) {
      return new OAuthLoginOutcome(OAuthLoginOutcome.UNAVAILABLE, null, 'login.wechat_unavailable');
    }
    if (consentAtMillis === null || !Number.isSafeInteger(consentAtMillis)) {
      return new OAuthLoginOutcome(LoginOutcome.AGREEMENT_REQUIRED);
    }
    if (this.running || this.login.busy) {
      return new OAuthLoginOutcome(LoginOutcome.BUSY);
    }
    this.running = true;
    const ticket: AttemptTicket = this.login.attemptTicket();
    try {
      return await this.run(provider, operationId, adapter, consentAtMillis, ticket);
    } finally {
      this.running = false;
      this.login.releaseTicket(ticket);
    }
  }

  private async run(provider: string, operationId: string, adapter: ThirdPartyAuthAdapter, consentAtMillis: number,
    ticket: AttemptTicket): Promise<OAuthLoginOutcome> {
    // R1-01（APP-05b 共性 1）：开始时固定会话、登录、隐私、环境归属；每次异步返回后、提交凭证前复核，变了就终止整个尝试，
    // 后续请求不在新上下文里重新绑定（等待授权期间保存了另一账号的会话 → 不提交、不覆盖）。
    const scope: ClientScope = this.client.captureScope();
    // 1. 取一次性的授权尝试（BR-ID-04 细则「授权尝试」）。
    const createBody: Record<string, Object> = {};
    createBody['provider'] = provider;
    createBody['purpose'] = 'login';
    const create: ApiRequest = new ApiRequest(OAuthLoginService.CREATE_OPERATION, {}, '', JSON.stringify(createBody));
    create.owner = ticket.owner;
    const created: ApiResult = await this.client.request(create);
    if (!this.login.ticketValid(ticket) || !this.client.scopeValid(scope)) {
      return new OAuthLoginOutcome(LoginOutcome.STALE);
    }
    if (!created.ok) {
      return this.failure(provider, created);
    }
    const attemptId: Object | undefined = created.data['attempt_id'];
    const nonce: Object | undefined = created.data['nonce'];
    if (typeof attemptId !== 'string' || typeof nonce !== 'string' || (attemptId as string).length === 0
      || (nonce as string).length === 0) {
      return new OAuthLoginOutcome(OAuthLoginErrorAction.SERVICE_ERROR, null, LoginService.GENERIC_KEY, created.trace6);
    }
    // 2. 拉起第三方。迟到的回调（取消、离页、超时之后）只交给 session 记为丢弃。
    const handle: string = this.session.create();
    this.session.launch(handle);
    this.callbackSeq++;
    const seq: number = this.callbackSeq;
    const authorized: Promise<ThirdPartyAuthResult | null> = OAuthLoginService.safeAuthorize(adapter, nonce as string)
      .then((result: ThirdPartyAuthResult): ThirdPartyAuthResult | null => {
        if (result.kind !== ThirdPartyAuthKind.CREDENTIAL) {
          return result;
        }
        return this.session.callback(handle, seq) ? result : null;
      });
    const abandoned: Promise<ThirdPartyAuthResult | null> = new Promise<ThirdPartyAuthResult | null>(
      (resolve: (value: ThirdPartyAuthResult | null) => void): void => {
        this.abandon = (): void => resolve(null);
      });
    let timedOut: boolean = false;
    const timeout: Promise<ThirdPartyAuthResult | null> = this.delay(OAuthLoginService.ATTEMPT_TIMEOUT_MILLIS)
      .then((): ThirdPartyAuthResult | null => {
        timedOut = true;
        return null;
      });
    const outcome: ThirdPartyAuthResult | null = await Promise.race([authorized, abandoned, timeout]);
    this.abandon = null;
    if (!this.login.ticketValid(ticket) || !this.session.isLive(handle)) {
      return new OAuthLoginOutcome(LoginOutcome.STALE);
    }
    if (!this.client.scopeValid(scope)) {
      // 等待授权期间归属变了（另一账号的会话已保存、登出、撤回同意、切换环境）：整个尝试终止，凭证不提交。
      this.session.leave();
      return new OAuthLoginOutcome(LoginOutcome.STALE);
    }
    if (outcome === null) {
      if (timedOut) {
        this.session.timeout();
        return new OAuthLoginOutcome(OAuthLoginOutcome.TIMEOUT, null, 'error.20004');
      }
      // 回调被拒（不应发生在有效尝试上）：按需重新授权。
      this.session.leave();
      return new OAuthLoginOutcome(LoginOutcome.STALE);
    }
    if (outcome.kind === ThirdPartyAuthKind.CANCELLED) {
      this.session.cancel();
      return new OAuthLoginOutcome(OAuthLoginOutcome.CANCELLED);
    }
    if (outcome.kind === ThirdPartyAuthKind.UNAVAILABLE) {
      this.session.cancel();
      return new OAuthLoginOutcome(OAuthLoginOutcome.UNAVAILABLE, null, 'login.wechat_unavailable');
    }
    if (outcome.kind !== ThirdPartyAuthKind.CREDENTIAL) {
      this.session.cancel();
      return new OAuthLoginOutcome(OAuthLoginErrorAction.REAUTHORIZE, null, 'error.20004');
    }
    // 3. 客户端自查：SDK 回传的 state 必须等于本次 nonce（微信 state；Apple 由服务端核对 nonce，这里不重复）。
    if (provider === OAuthProvider.WECHAT && outcome.state !== nonce) {
      this.session.cancel();
      return new OAuthLoginOutcome(OAuthLoginErrorAction.REAUTHORIZE, null, 'error.20004');
    }
    const body: Record<string, Object> | null = this.loginBody(provider, attemptId as string, outcome, consentAtMillis);
    if (body === null) {
      this.session.cancel();
      return new OAuthLoginOutcome(OAuthLoginErrorAction.REAUTHORIZE, null, 'error.20004');
    }
    // 4. 唯一提交边界：同一尝试只提交一次。提交与归属复核在同一同步区（请求在这里按已复核的归属绑定）。
    if (!this.client.scopeValid(scope)) {
      this.session.leave();
      return new OAuthLoginOutcome(LoginOutcome.STALE);
    }
    if (!this.session.submit(handle)) {
      return new OAuthLoginOutcome(LoginOutcome.STALE);
    }
    const request: ApiRequest = new ApiRequest(operationId, {}, '', JSON.stringify(body));
    request.owner = ticket.owner;
    const result: ApiResult = await this.client.request(request);
    if (!result.ok) {
      if (!this.login.ticketValid(ticket)) {
        return new OAuthLoginOutcome(LoginOutcome.STALE);
      }
      return this.failure(provider, result);
    }
    const route: OAuthRouteResult = OAuthLoginRoute.ofData(result.data);
    const account: string | null = this.client.sessionAccount();
    const isNew: boolean = result.data['is_new_user'] === true;
    if (isNew) {
      // 第三方新号没有手机号（BR-ID-04：第三方首次登录即注册、不强制绑手机）。
      this.phoneBinding.set(account, false);
    } else {
      // R1-02（共性 2）：老用户是否绑了手机要等 getMe——未知不能当已绑。
      this.phoneBinding.markUnverified(account);
    }
    const guide: boolean = route.routeRaw === OAuthLoginRoute.BIND_PHONE_GUIDE && this.guideEnabled();
    // 新号等引导结束再恢复待办；老用户先查清 phone_bound 再交 Router 守卫恢复（两者都在登录成功时重置计时，R1-03）。
    const hold: boolean = guide || !isNew;
    const finished: LoginOutcome = await this.login.finishSessionLogin(result, ticket, hold);
    if (finished.stateRaw !== LoginOutcome.LOGGED_IN) {
      return new OAuthLoginOutcome(finished.stateRaw, null, finished.textKey, finished.trace6, 0, finished);
    }
    if (!isNew) {
      // R1-02：先取得当前会话的 phone_bound；查清（且仍是这次登录的会话）才经 Router 守卫恢复待办。
      if (await this.refreshMe()) {
        this.login.resumeHeldPending();
      } else {
        // 查询失败保留待办（守卫按未验证：需要手机号的待办不执行）；暂缓释放给守卫，之后的状态同步由 verifyPhoneBinding 重查。
        this.login.endHold();
      }
    }
    return new OAuthLoginOutcome(OAuthLoginOutcome.LOGGED_IN, guide ? OAuthLoginRoute.BIND_PHONE_GUIDE :
      OAuthLoginRoute.DONE, null, '', 0, finished);
  }

  /**
   * 冷启动等 phone_bound 未知时查清（harmony-review-r2 R2-01，共性 8）：App 每次状态同步前调用。当前有会话、且这个账号的
   * phone_bound 没查清（不知道或待查）时请求 getMe（同一会话已在查就不重复发）；结果核对仍是发起查询的会话（世代与账号都没变）
   * 才记下，记下后通知会话状态变化——Router 按冷启动口径经守卫恢复（已绑 → 执行；未绑 → 保留、不弹前置页）。查询失败保留待办，
   * 下一次状态同步再查。返回这一次是否查清。
   */
  async verifyPhoneBinding(): Promise<boolean> {
    const account: string | null = this.client.sessionAccount();
    if (account === null || this.phoneBinding.get(account) !== null) {
      return false;
    }
    const joined: boolean = this.meInFlight !== null;
    const known: boolean = await this.refreshMe();
    if (known && !joined && this.client.sessionAccount() === account) {
      this.login.notifySessionState();
    }
    return known;
  }

  /** 拉取 getMe，按 phone_bound 更新本机会话状态（绑定在当前会话世代与账号上：会话换了就丢弃）。返回是否查清。 */
  refreshMe(): Promise<boolean> {
    const generation: number = this.client.sessionGenerationId();
    const account: string | null = this.client.sessionAccount();
    if (account === null) {
      return Promise.resolve(false);
    }
    // R3-01：同时捕获手机号绑定状态的更新世代；绑定成功后发起的查询不复用绑定前在途的那次。
    const binding: number = this.phoneBinding.generation();
    const inFlight: Promise<boolean> | null = this.meInFlight;
    if (inFlight !== null && this.meInFlightGeneration === generation && this.meInFlightAccount === account
      && this.meInFlightBinding === binding) {
      return inFlight;
    }
    const run: Promise<boolean> = this.fetchMe(generation, account, binding);
    this.meInFlight = run;
    this.meInFlightGeneration = generation;
    this.meInFlightAccount = account;
    this.meInFlightBinding = binding;
    return run;
  }

  private async fetchMe(generation: number, account: string, binding: number): Promise<boolean> {
    let result: ApiResult;
    try {
      result = await this.client.request(new ApiRequest(OAuthLoginService.GET_ME_OPERATION));
    } finally {
      this.meInFlight = null;
    }
    // R1-02：结果只记到发起查询的那个会话（世代与账号都没变）；phone_bound 不是布尔按没查清。
    // R3-01：发起后绑定已成功（更新世代变了）的旧回包不应用，不覆盖绑定结果。
    if (!result.ok || this.client.sessionGenerationId() !== generation || this.client.sessionAccount() !== account
      || this.phoneBinding.generation() !== binding || typeof result.data['phone_bound'] !== 'boolean') {
      return false;
    }
    this.phoneBinding.applyMe(account, result.data);
    return true;
  }

  /** 登录请求体：只放规定的凭证字段（BR-ID-04 细则「请求体」）+ 协议版本与同意时刻。 */
  private loginBody(provider: string, attemptId: string, credential: ThirdPartyAuthResult,
    consentAtMillis: number): Record<string, Object> | null {
    const body: Record<string, Object> = {};
    body['attempt_id'] = attemptId;
    if (provider === OAuthProvider.APPLE) {
      if (credential.identityToken === null || credential.authorizationCode === null) {
        return null;
      }
      body['identity_token'] = credential.identityToken;
      body['authorization_code'] = credential.authorizationCode;
    } else if (provider === OAuthProvider.HUAWEI) {
      if (credential.authorizationCode === null) {
        return null;
      }
      body['authorization_code'] = credential.authorizationCode;
    } else {
      if (credential.code === null || credential.code.length === 0) {
        return null;
      }
      body['code'] = credential.code;
    }
    const legal: Record<string, Object> = {};
    legal['privacy'] = this.legal.privacy;
    legal['agreement'] = this.legal.agreement;
    body['legal_versions'] = legal;
    body['consent_at'] = new Date(consentAtMillis).toISOString();
    return body;
  }

  private failure(provider: string, result: ApiResult): OAuthLoginOutcome {
    if (result.outcome === ApiOutcome.LOCAL_REJECT) {
      const reason: string | null = result.localRejectReason;
      if (reason === LocalRejectReason.SESSION_SAVE_FAILED || reason === LocalRejectReason.INVALID_SESSION_TOKENS) {
        return new OAuthLoginOutcome(OAuthLoginErrorAction.SERVICE_ERROR, null, LoginService.GENERIC_KEY);
      }
      return new OAuthLoginOutcome(LoginOutcome.STALE);
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.effect !== null) {
      const effect: ErrorEffect = result.effect;
      const mapped: OAuthErrorResult = OAuthLoginErrorAction.ofEffect(result.code, effect);
      return new OAuthLoginOutcome(mapped.actionRaw, null, mapped.textKey ?? null, result.trace6, mapped.disableMillis);
    }
    return new OAuthLoginOutcome(OAuthLoginErrorAction.NETWORK_ERROR, null, LoginService.GENERIC_KEY, result.trace6);
  }

  private static safeAvailable(adapter: ThirdPartyAuthAdapter): boolean {
    try {
      return adapter.adapterAvailable();
    } catch (e) {
      return false;
    }
  }

  private static safeInstalled(adapter: ThirdPartyAuthAdapter): boolean | null {
    try {
      return adapter.installed();
    } catch (e) {
      return null;
    }
  }

  private static safeAuthorize(adapter: ThirdPartyAuthAdapter, nonce: string): Promise<ThirdPartyAuthResult> {
    try {
      return adapter.authorize(nonce).catch((): ThirdPartyAuthResult => ThirdPartyAuthResult.of(ThirdPartyAuthKind.FAILED));
    } catch (e) {
      return Promise.resolve(ThirdPartyAuthResult.of(ThirdPartyAuthKind.FAILED));
    }
  }

  /** 号码脱敏（并号确认「手机号账号 138****5678」用）。 */
  static masked(rawPhone: string): string {
    const phone: PhoneResult = PhoneNumber.normalize(rawPhone);
    return phone.normalized === null ? '' : PhoneNumber.masked(phone.normalized);
  }
}
