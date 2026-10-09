import { ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { TransportFailure } from '../network/HttpTransport';
import { SearchApiPort } from '../search/SearchController';
import { BaichuanAdapter, BaichuanAuthResult } from '../tradejump/Baichuan';
import { AuthMethodPicker } from './OpenTradeFlow';
import { TradeJson } from './TradeJson';

/** 契约 operationId（ApiOperations）。 */
export class TradeOperations {
  static readonly OPEN_LINK: string = 'openLink';
  static readonly GET_UNION_AUTH_URL: string = 'getUnionAuthUrl';
  static readonly BIND_UNION: string = 'bindUnion';
  static readonly LIST_UNION_BINDINGS: string = 'listUnionBindings';
  static readonly GET_TIPS: string = 'getTips';
  static readonly MARK_TIP_READ: string = 'markTipRead';
}

/** 端口不该抛错（ApiClient 不抛）；万一抛了，按断网收口。 */
export function tradeGuarded(promise: Promise<ApiResult>): Promise<ApiResult> {
  return promise.catch((): ApiResult => new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0,
    TransportFailure.DISCONNECT, null, null, null));
}

/**
 * 购买的 pending_action（BR-ID-10）：App 用 Router 的同一份本地记录（只存 1 条、10 分钟、完成一步重新计时、退出登录清除）实现。
 * 动作名 PURCHASE_PENDING_ACTION；params 不含令牌、验证码（只有 kind、link_id、平台、商品键与本次的幂等键）。
 */
export interface PurchasePending {
  /** 登记（新的覆盖旧的）；失败返回 false。 */
  register(params: Record<string, Object>): boolean;

  /** 有效的购买待办（未过期、动作名对）；没有为 null。不删除。 */
  peek(): Record<string, Object> | null;

  /** 完成了一个前置步骤（登录、授权）：重新计时。 */
  stepDone(): void;

  /** 删除（执行前、放弃、页面出栈）。只删购买待办，别的动作的记录不动。 */
  clear(): void;
}

export const PURCHASE_PENDING_ACTION: string = 'open_link';

/** 内存实现（测试、没有持久化的场合）。 */
export class MemoryPurchasePending implements PurchasePending {
  static readonly TTL_MILLIS: number = 600000;
  private params: Record<string, Object> | null = null;
  private startedAt: number = 0;
  private readonly clock: () => number;

  constructor(clock: () => number = Date.now) {
    this.clock = clock;
  }

  register(params: Record<string, Object>): boolean {
    this.params = params;
    this.startedAt = this.clock();
    return true;
  }

  peek(): Record<string, Object> | null {
    if (this.params !== null && this.clock() - this.startedAt > MemoryPurchasePending.TTL_MILLIS) {
      this.params = null;
    }
    return this.params;
  }

  stepDone(): void {
    if (this.peek() !== null) {
      this.startedAt = this.clock();
    }
  }

  clear(): void {
    this.params = null;
  }
}

/**
 * AuthSheet 自动弹出计数（BR-ID-18）：每次因 30101 / 30102 / 30111 自动弹出记 1 次，按平台存在内存；同一会话每个平台最多 2 次，
 * 第 3 次起点击购买直接给「未授权将无法获得返利」二选一。进程冷启动或在后台停留 ≥ 1800 秒后回前台时清零（登录 / 退出是否清零未规定，
 * 不清零，TODO(N-28)）。App 里一个进程一份。
 */
export class AuthSheetCounter {
  static readonly MAX_AUTO_POPS: number = 2;
  static readonly RESET_AFTER_MILLIS: number = 1800000;
  private readonly counts: Map<string, number> = new Map<string, number>();
  private backgroundAt: number | null = null;
  private readonly clock: () => number;

  constructor(clock: () => number = Date.now) {
    this.clock = clock;
  }

  /** 这次还能自动弹出：能就记 1 次并返回 true。 */
  tryAutoPop(platform: string): boolean {
    const n: number = this.counts.get(platform) ?? 0;
    if (n >= AuthSheetCounter.MAX_AUTO_POPS) {
      return false;
    }
    this.counts.set(platform, n + 1);
    return true;
  }

  count(platform: string): number {
    return this.counts.get(platform) ?? 0;
  }

  onBackground(): void {
    this.backgroundAt = this.clock();
  }

  onForeground(): void {
    const since: number | null = this.backgroundAt;
    if (since === null) {
      return;
    }
    this.backgroundAt = null;
    if (this.clock() - since >= AuthSheetCounter.RESET_AFTER_MILLIS) {
      this.counts.clear();
    }
  }
}

/**
 * JumpTip 已读（BR-ATTR-21：每个用户、每个平台首次外跳前展示一次，服务端记已读；getTips / markTipRead）。已读状态按会话缓存在内存，
 * 读取失败时按「未读」保守展示（多看一次须知不影响归属）。sessionKey 变了（换账号、退出）就重新读；游客（null）不展示。
 */
export class JumpTipService {
  private readonly api: SearchApiPort;
  private readonly sessionKey: () => string | null;
  private cachedFor: string | null = null;
  private read: string[] | null = null;

  constructor(api: SearchApiPort, sessionKey: () => string | null) {
    this.api = api;
    this.sessionKey = sessionKey;
  }

  async shouldShow(platform: string, owner: () => boolean): Promise<boolean> {
    const key: string | null = this.sessionKey();
    if (key === null) {
      return false;
    }
    if (this.cachedFor !== key || this.read === null) {
      const request: ApiRequest = new ApiRequest(TradeOperations.GET_TIPS);
      request.owner = owner;
      const result: ApiResult = await tradeGuarded(this.api.request(request));
      this.cachedFor = key;
      if (result.outcome === ApiOutcome.SUCCESS) {
        const tips: Record<string, Object> | null = TradeJson.object(result.data, 'jump_tip');
        const read: string[] = [];
        if (tips !== null) {
          for (const p of Object.keys(tips)) {
            if (typeof tips[p] === 'string') {
              read.push(p);
            }
          }
        }
        this.read = read;
      } else {
        this.read = null;
      }
    }
    const read: string[] | null = this.read;
    return read === null || read.indexOf(platform) < 0;
  }

  /** 用户点了【知道了，去X】：先本地记已读，再告诉服务端（失败不影响外跳）。 */
  async markRead(platform: string, owner: () => boolean): Promise<void> {
    const read: string[] = this.read ?? [];
    if (read.indexOf(platform) < 0) {
      read.push(platform);
    }
    this.read = read;
    this.cachedFor = this.sessionKey();
    const path: Record<string, string> = {};
    path['tip_key'] = 'jump_tip';
    const body: Record<string, Object> = {};
    body['platform'] = platform;
    const request: ApiRequest = new ApiRequest(TradeOperations.MARK_TIP_READ, path, '', JSON.stringify(body));
    request.owner = owner;
    await tradeGuarded(this.api.request(request));
  }
}

/**
 * 点击结果确认的平台购买状态（50301 maintenance / not_launched；03 §7.4「点击时以响应为准」，A-R1-05 / 06）：按平台记下，进程里一份，
 * 列表、详情的卡片映射与点击前核对都先读它。记下时取配置拉取的分界（issuedMark）；分界之后发出、已生效的配置（appliedMark 超过分界）
 * 到达后以新配置为准，这条记录作废。有效期与是否跨页面规划未写，按「同进程所有发起页、到新配置为止」（TODO(N-28)）。
 */
export class PlatformStatusOverrides {
  private readonly issuedMark: () => number;
  private readonly appliedMark: () => number;
  private readonly statuses: Map<string, string> = new Map<string, string>();
  private readonly marks: Map<string, number> = new Map<string, number>();
  private listeners: (() => void)[] = [];

  constructor(issuedMark: () => number, appliedMark: () => number) {
    this.issuedMark = issuedMark;
    this.appliedMark = appliedMark;
  }

  mark(platform: string, status: string): void {
    this.statuses.set(platform, status);
    this.marks.set(platform, this.issuedMark());
    for (const l of this.listeners.slice()) {
      l();
    }
  }

  /** 仍有效的记录；没有或已被新配置覆盖为 null。 */
  status(platform: string): string | null {
    const s: string | undefined = this.statuses.get(platform);
    const m: number | undefined = this.marks.get(platform);
    if (s === undefined || m === undefined) {
      return null;
    }
    if (this.appliedMark() > m) {
      this.statuses.delete(platform);
      this.marks.delete(platform);
      return null;
    }
    return s;
  }

  /** 记录变化时通知；返回取消订阅。 */
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void) => l !== listener);
    };
  }
}

/** 一次授权步骤（拉起授权页 / SDK）的结果。凭证只交给 bindings，不保存、不进日志。 */
export class AuthStepResult {
  static readonly CREDENTIAL: string = 'credential';
  static readonly CANCELLED: string = 'cancelled';
  static readonly FAILED: string = 'failed';
  readonly kind: string;
  /** web_code / sdk_token。 */
  readonly method: string;
  readonly code: string;
  readonly accessToken: string;
  readonly expiresIn: number;

  constructor(kind: string, method: string = '', code: string = '', accessToken: string = '', expiresIn: number = 0) {
    this.kind = kind;
    this.method = method;
    this.code = code;
    this.accessToken = accessToken;
    this.expiresIn = expiresIn;
  }

  static webCode(code: string): AuthStepResult {
    return new AuthStepResult(AuthStepResult.CREDENTIAL, AuthMethodPicker.WEB_CODE, code);
  }

  static sdkToken(accessToken: string, expiresIn: number): AuthStepResult {
    return new AuthStepResult(AuthStepResult.CREDENTIAL, AuthMethodPicker.SDK_TOKEN, '', accessToken, expiresIn);
  }
}

/**
 * 淘宝 web_code 授权的本端能力（App 给）：用系统浏览器打开 auth_url，等本 App 自己的回跳 scheme 带回授权码。回跳 scheme 在
 * apps.json inbound 登记前（为空，TODO(N-28)）生产实现 available() = false。
 */
export interface WebCodeAuthorizer {
  available(): boolean;

  authorize(authUrl: string, state: string): Promise<AuthStepResult>;
}

/** 生产：回跳 scheme 未登记，web_code 不可执行（TODO(N-28)：apps.json inbound 补上后接系统浏览器 + 回跳）。 */
export class UnavailableWebCodeAuthorizer implements WebCodeAuthorizer {
  available(): boolean {
    return false;
  }

  authorize(_authUrl: string, _state: string): Promise<AuthStepResult> {
    return Promise.resolve(new AuthStepResult(AuthStepResult.FAILED));
  }
}

/** bindings 请求体（BR-ID-17：只有 state、auth_method 与凭证字段）。 */
export function bindBody(state: string, credential: AuthStepResult): string {
  const body: Record<string, Object> = {};
  body['state'] = state;
  body['auth_method'] = credential.method;
  if (credential.method === AuthMethodPicker.WEB_CODE) {
    body['code'] = credential.code;
  } else {
    body['access_token'] = credential.accessToken;
    body['expires_in'] = credential.expiresIn;
  }
  return JSON.stringify(body);
}

/** 一次淘宝授权（含 30104 恢复）的结局。 */
export class TaobaoAuthOutcome {
  /** bindings 返回 active。 */
  static readonly BOUND: string = 'bound';
  /** 用户在授权页 / SDK 里取消。 */
  static readonly CANCELLED: string = 'cancelled';
  /** 授权失败（BR-ID-18）：本端执行不了下发的任何方式、授权步骤失败，或 30104 之后没有可换的方式。 */
  static readonly FAILED: string = 'failed';
  /** 请求失败（bindings、auth-url 的其它业务码、42901、5xxxx、传输失败）：调用方按码处理，不能当成用户没授权（A-R2-06）。 */
  static readonly REQUEST_FAILED: string = 'request_failed';
  /** 页面已离开，或第一次拉起授权前就不在前台（没有外跳过）：什么都不做 / 按钮复原。 */
  static readonly ABANDONED: string = 'abandoned';
  /**
   * 已拉起过授权、30104 恢复后要再次拉起时，用户点击发出的授权许可已撤销（进过后台、被覆盖；H-R2-01，共性第 31 条）：不再自动拉起，
   * 调用方回到前台后向服务端查询授权状态，没授权就交用户再点。
   */
  static readonly INTERRUPTED: string = 'interrupted';
  readonly kind: string;
  readonly result: ApiResult | null;

  constructor(kind: string, result: ApiResult | null = null) {
    this.kind = kind;
    this.result = result;
  }
}

/**
 * 淘宝授权的执行与 30104 恢复（BR-ID-17 细则「凭证无效」「幂等键」、契约 30104 action；A-R2-05，APP-06b 共性第 18 条）。购买流程的
 * AuthSheet 与授权管理页共用：
 * - 按下发的 auth_methods 取本端能执行的第一种（web_code 要有 auth_url；sdk_token 要百川支持换令牌），执行后用 state + 凭证调
 *   bindings，每次绑定尝试一个新的幂等键；
 * - bindings 返回 30104：重新调 auth-url 取新的 state 与方式列表，这是一次新的绑定尝试（新 state、新凭证、新幂等键）：
 *   credential_invalid 记这种方式失效、改用新列表里下一种本端可执行且没失效过的方式；method_not_allowed 只按新下发的列表执行；
 *   没有 reason（state 过期或已用）按新列表重新发起；恢复最多 MAX_RECOVERIES 次，之后按授权失败；
 * - 其它失败原样交给调用方（REQUEST_FAILED）。每次等待之后复核 alive（页面离开即 ABANDONED）。
 */
export class TaobaoAuthFlow {
  static readonly MAX_RECOVERIES: number = 3;
  static readonly STATE_OR_CREDENTIAL: number = 30104;
  private readonly api: SearchApiPort;
  private readonly webCode: WebCodeAuthorizer;
  private readonly baichuan: BaichuanAdapter;
  private readonly keyGenerator: () => string;
  private readonly owner: () => (() => boolean);
  private readonly alive: () => boolean;
  private readonly installed: (platform: string) => string;
  /**
   * 每次拉起授权（外跳）之前复核：用户点击发出的授权许可仍有效（进过后台即撤销，回前台也不恢复）、页面在前台（共性第 25、31 条）；
   * 不满足就不拉起：还没拉起过返回 ABANDONED，30104 恢复中返回 INTERRUPTED。
   */
  private readonly canJump: () => boolean;

  constructor(api: SearchApiPort, webCode: WebCodeAuthorizer, baichuan: BaichuanAdapter, keyGenerator: () => string,
    owner: () => (() => boolean), alive: () => boolean, installed: (platform: string) => string,
    canJump: () => boolean = (): boolean => true) {
    this.api = api;
    this.webCode = webCode;
    this.baichuan = baichuan;
    this.keyGenerator = keyGenerator;
    this.owner = owner;
    this.alive = alive;
    this.installed = installed;
    this.canJump = canJump;
  }

  /** 本端能执行的方式（按本端能力，不看下发顺序）。 */
  private supported(): string[] {
    const out: string[] = [];
    if (this.webCode.available()) {
      out.push(AuthMethodPicker.WEB_CODE);
    }
    if (this.baichuan.supportsSdkToken()) {
      out.push(AuthMethodPicker.SDK_TOKEN);
    }
    return out;
  }

  /** data 里本端此刻能执行的第一种方式（排除 excluded）；state、auth_url 不全也算不能执行。 */
  pick(platform: string, data: Record<string, Object>, excluded: string[] = []): string | null {
    const methods: string[] = TradeJson.texts(data, 'auth_methods').filter((m: string) => excluded.indexOf(m) < 0);
    const method: string | null = AuthMethodPicker.pick(platform, methods, this.supported());
    if (method === null) {
      return null;
    }
    const ready: boolean = TradeJson.text(data, 'state') !== null
      && (method !== AuthMethodPicker.WEB_CODE || TradeJson.text(data, 'auth_url') !== null);
    return ready ? method : null;
  }

  async run(platform: string, initial: Record<string, Object>): Promise<TaobaoAuthOutcome> {
    let data: Record<string, Object> = initial;
    const invalid: string[] = [];
    let recoveries: number = 0;
    let jumped: boolean = false;
    while (true) {
      if (!this.alive()) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.ABANDONED);
      }
      const method: string | null = this.pick(platform, data, invalid);
      const state: string | null = TradeJson.text(data, 'state');
      if (method === null || state === null) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.FAILED);
      }
      if (!this.canJump()) {
        // 许可只认用户那一下（共性第 31 条）：已拉起过授权（30104 恢复中）就交调用方回前台查询，不凭「此刻在前台」再拉起
        return new TaobaoAuthOutcome(jumped ? TaobaoAuthOutcome.INTERRUPTED : TaobaoAuthOutcome.ABANDONED);
      }
      jumped = true;
      const step: AuthStepResult = await this.authorizeWith(method, TradeJson.text(data, 'auth_url') ?? '', state);
      if (!this.alive()) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.ABANDONED);
      }
      if (step.kind === AuthStepResult.CANCELLED) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.CANCELLED);
      }
      if (step.kind !== AuthStepResult.CREDENTIAL) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.FAILED);
      }
      const result: ApiResult = await this.bind(platform, state, step);
      if (!this.alive()) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.ABANDONED);
      }
      if (result.outcome === ApiOutcome.SUCCESS) {
        return new TaobaoAuthOutcome(TradeJson.text(result.data, 'status') === 'active' ? TaobaoAuthOutcome.BOUND
          : TaobaoAuthOutcome.FAILED);
      }
      if (result.outcome !== ApiOutcome.BUSINESS_ERROR || result.code !== TaobaoAuthFlow.STATE_OR_CREDENTIAL) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.REQUEST_FAILED, result);
      }
      // 30104：重新取授权上下文，一次新的绑定尝试（BR-ID-17 细则、契约 30104 action）
      recoveries++;
      if (recoveries > TaobaoAuthFlow.MAX_RECOVERIES) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.FAILED);
      }
      if (TradeJson.text(result.data, 'reason') === 'credential_invalid' && invalid.indexOf(method) < 0) {
        invalid.push(method);
      }
      const refreshed: ApiResult = await this.authUrl(platform);
      if (!this.alive()) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.ABANDONED);
      }
      if (refreshed.outcome !== ApiOutcome.SUCCESS) {
        return new TaobaoAuthOutcome(TaobaoAuthOutcome.REQUEST_FAILED, refreshed);
      }
      data = refreshed.data;
    }
  }

  private async authorizeWith(method: string, authUrl: string, state: string): Promise<AuthStepResult> {
    if (method === AuthMethodPicker.WEB_CODE) {
      return this.webCode.authorize(authUrl, state);
    }
    const r: BaichuanAuthResult = await this.baichuan.authorize();
    if (r.kind === BaichuanAuthResult.TOKEN) {
      return AuthStepResult.sdkToken(r.accessToken, r.expiresIn);
    }
    return new AuthStepResult(r.kind === BaichuanAuthResult.CANCELLED ? AuthStepResult.CANCELLED : AuthStepResult.FAILED);
  }

  /** bindings：每次绑定尝试一个新的幂等键（BR-ID-17 细则「幂等键」）。 */
  private bind(platform: string, state: string, credential: AuthStepResult): Promise<ApiResult> {
    const path: Record<string, string> = {};
    path['platform'] = platform;
    const request: ApiRequest = new ApiRequest(TradeOperations.BIND_UNION, path, '', bindBody(state, credential));
    request.idempotencyKey = this.keyGenerator();
    request.owner = this.owner();
    return tradeGuarded(this.api.request(request));
  }

  /** auth-url：重新取 state 与方式列表。 */
  authUrl(platform: string): Promise<ApiResult> {
    return TaobaoAuthFlow.requestAuthUrl(this.api, platform, this.installed(platform), this.owner());
  }

  static requestAuthUrl(api: SearchApiPort, platform: string, installed: string,
    owner: () => boolean): Promise<ApiResult> {
    const path: Record<string, string> = {};
    path['platform'] = platform;
    const request: ApiRequest = new ApiRequest(TradeOperations.GET_UNION_AUTH_URL, path,
      'installed=' + encodeURIComponent(installed));
    request.owner = owner;
    return tradeGuarded(api.request(request));
  }
}
