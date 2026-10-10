import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ApiOperation, ApiOperations } from 'generated';
import { EnvironmentEndpoints } from '../config/AppEnvironment';
import { SessionReadStatus, SessionTokens, SessionTokenSet } from '../session/SessionTokens';
import {
  EffectKind, ErrorActionInput, ErrorActionMapper, ErrorActionState, ErrorEffect, ErrorUpdateState, ReplayKind
} from './ErrorActionMapper';
import { HttpTransport, TransportFailure, TransportRequest, TransportResponse } from './HttpTransport';
import {
  HeaderDecision, LocalRejectReason, NetworkHeaders, NetworkPrivacy, NetworkRequestState, PendingResolution,
  RequestHeaderPolicy, RetryPlan,
  RetryPolicy, SessionScope
} from './NetworkPolicy';
import { PendingKeyRecord, PendingKeyState, PendingKeyStateRaw, PendingKeyStore, PendingResponseKind } from './PendingKeyStore';
import { RefreshCompletion, RefreshCoordinator, RefreshRequest } from './RefreshCoordinator';
import { DigestPort, CryptoKitDigest, RequestSigner, SigningInput } from './RequestSigner';

/** 本 App 的公共头取值（X-App-Id、X-Platform、X-App-Version、X-Build、X-Channel）。 */
export class ApiAppIdentity {
  readonly appId: string;
  readonly platform: string;
  readonly appVersion: string;
  readonly build: string;
  readonly channel: string;

  constructor(appId: string, platform: string, appVersion: string, build: string, channel: string) {
    this.appId = appId;
    this.platform = platform;
    this.appVersion = appVersion;
    this.build = build;
    this.channel = channel;
  }
}

/**
 * 设备凭据（device_id、install_secret）。生产实现是 DeviceRegistry（APP-03b：服务端签发、install_secret 只在安全存储）；
 * ApiClient 每次实际发送前现取（不缓存），签名用真实的 install_secret。
 */
export interface CredentialSource {
  deviceId(): string | null;

  installSecret(): string | null;
}

/** 设备还没注册（APP-03b 之前）：没有任何设备凭据。 */
export class NoDeviceCredentials implements CredentialSource {
  deviceId(): string | null {
    return null;
  }

  installSecret(): string | null {
    return null;
  }
}

/** 网络层要读的 App 状态。 */
export interface NetworkContext {
  /** 当前环境基址；环境闸门不是 SETTLED 时为 undefined（不发任何请求）。 */
  endpoints(): EnvironmentEndpoints | undefined;

  /** full / basic / not_decided（NetworkPrivacy）。 */
  privacy(): string;

  /** 撤回同意的清理已完成、凭据可读。 */
  credentialsReadable(): boolean;
}

/** 强更（Update 模块）的接口：结论与 10405 入口。 */
export interface UpdatePort {
  /** supported / below / unknown（ErrorUpdateState）。 */
  state(): string;

  on10405(minSupported: string | null): void;
}

/**
 * 10402 → 重新注册设备（APP-03b；生产实现是 DeviceRegistry）：单飞，同时收到 10402 的请求共用一次注册；
 * usedDeviceId 是被拒请求带的 device_id（注册期间已换成别的 device_id 的直接算成功，复用那次结果）。兑现 true 后原请求重放 1 次。
 */
export interface DeviceRegistrar {
  /**
   * caller（harmony-review-r3 R3-03，APP-04 共性 58）：发起这次重新注册的调用方有效性——普通请求为 ApiRequest.owner
   * （桥调用为 call.valid，到截止时间即失效，剩余预算由它体现），共享刷新为这一轮的「还有有效调用方」；null 为独立的
   * 原生调用方。实现方在等待结束、读取标识前、实际发送前检查它。
   */
  reregister(usedDeviceId: string | null, caller: (() => boolean) | null): Promise<boolean>;

  /** 调用方有效性可能变了（cancelOwned）：重新注册已没有有效调用方时取消它的底层请求（R3-03）。 */
  callersChanged(): void;

  /**
   * 不走重新注册的 10402（重放里再收到、注册请求自己收到）：只把这次请求所用的凭据从可读凭据中隔离，恢复交给唯一一条
   * 退避链（F-ALL-08 / APP-03b 共性 25，I-R2-02）。重新注册与重放预算另算，不在这里触发。
   */
  isolate(usedDeviceId: string | null): void;
}

/** 没有设备注册（单测替身的缺省）：不能重新注册，10402 按兜底处理。 */
export class NoDeviceRegistrar implements DeviceRegistrar {
  reregister(_usedDeviceId: string | null, _caller: (() => boolean) | null): Promise<boolean> {
    return Promise.resolve(false);
  }

  callersChanged(): void {
  }

  isolate(_usedDeviceId: string | null): void {
  }
}

/** 定时（退避与超时）。生产用 setTimeout，单测注入可控实现。 */
export interface NetworkTimer {
  delay(millis: number): Promise<void>;
}

export class SystemNetworkTimer implements NetworkTimer {
  delay(millis: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => resolve(), millis);
    });
  }
}

/** 随机值（X-Nonce、X-Trace-Id、Idempotency-Key）。 */
export interface NetworkRandom {
  /** 32 位小写十六进制（16 字节随机）。 */
  nonce(): string;

  /** UUID（Trace 与幂等键用；字符集 [A-Za-z0-9-]）。 */
  uuid(): string;
}

export class SystemNetworkRandom implements NetworkRandom {
  nonce(): string {
    const random: cryptoFramework.Random = cryptoFramework.createRandom();
    return RequestSigner.hex(random.generateRandomSync(16).data);
  }

  uuid(): string {
    return util.generateRandomUUID(false);
  }
}

/** ApiClient 的依赖（必填在构造参数里，其余有缺省）。 */
export class ApiClientDeps {
  readonly transport: HttpTransport;
  readonly context: NetworkContext;
  readonly identity: ApiAppIdentity;
  readonly tokens: SessionTokens;
  readonly update: UpdatePort;
  credentials: CredentialSource = new NoDeviceCredentials();
  digest: DigestPort = new CryptoKitDigest();
  /** 四个 step-up 操作的未决键；null 时不记录。 */
  pendingKeys: PendingKeyStore | null = null;
  deviceRegistrar: DeviceRegistrar = new NoDeviceRegistrar();
  timer: NetworkTimer = new SystemNetworkTimer();
  random: NetworkRandom = new SystemNetworkRandom();
  /** 毫秒时钟。 */
  clock: () => number = () => Date.now();
  /**
   * 刷新失败（清会话）时的会话级 Effect：跳登录或停在强更页（每次刷新失败一次）。clearedGeneration（APP-05a 共性 26）：
   * 网络层在同一同步区里确定清理确实已发生的那一刻，被清掉的那个会话世代；旧世代的清理没有发生就不发。App 用它绑定
   * 这次清理（Router 记下「原会话被清除」的分界），不在回调里读「当前世代」补作归属。
   */
  sessionEffect: (effect: ErrorEffect, clearedGeneration: number) => void = (_e: ErrorEffect, _g: number) => {
  };
  /**
   * 异步刷新（受限会话屏障、10002 单飞刷新）保存了新令牌、且作用域变了（如 deletion_only → full）时的状态通知
   * （APP-05a 共性 14，F-HM-08）：带保存那一刻的会话世代。App 在主线程核对世代仍是当前世代后，交 Router 重算守卫状态；
   * 需要恢复待办时由 Router 先过守卫再恢复。通知出错不影响刷新结果。
   */
  sessionRefreshed: (generation: number, scope: string) => void = (_g: number, _s: string) => {
  };
  /**
   * F-HM-09（APP-05a 共性 19）：同一通知带触发来源。resumePending=true：这一轮是 App 级受限会话屏障（冷启动、强更恢复为
   * 「不低于」）发起的，App 核对世代后交启动协调器经 Router 守卫恢复待办；false：这一轮由登录尝试的复查（或业务请求的
   * 10002）发起——登录尝试有效时由 LoginService 自己按登录后计划恢复，已取消时只同步状态、不恢复待办。
   * 设置了它时代替 sessionRefreshed 调用。
   */
  sessionRefreshedFrom: ((generation: number, scope: string, resumePending: boolean) => void) | null = null;

  constructor(transport: HttpTransport, context: NetworkContext, identity: ApiAppIdentity, tokens: SessionTokens,
    update: UpdatePort) {
    this.transport = transport;
    this.context = context;
    this.identity = identity;
    this.tokens = tokens;
    this.update = update;
  }
}

/** 一次业务请求。 */
export class ApiRequest {
  readonly operationId: string;
  /** 路径参数（按 openapi 路径模板替换，值会做 URL 编码）。 */
  readonly pathParams: Record<string, string>;
  /** 原样 query（不含 '?'；签名与发送一致）。 */
  readonly query: string;
  /** 请求体原文（JSON）；没有为 null。 */
  readonly body: string | null;
  /** 沿用的幂等键（重放、确认上一笔）；null 时写操作新生成。 */
  idempotencyKey: string | null = null;
  /** X-Step-Up-Token（只对带 x-step-up 的操作发送）。 */
  stepUpToken: string | null = null;
  /** 未决记录的展示摘要（脱敏，调用方给）。 */
  summary: string = '';
  /** 发起页有可重新转链的商品卡（30144 输出 refetch_product）；App 内链接落地页 LinkLanding 传 false（R1-08）。 */
  fromProductCard: boolean = true;
  /** If-None-Match（只用于 GET；03 §4.3 回前台带 ETag 拉配置，APP-03b）。服务端回 304 时结果为 not_modified。 */
  ifNoneMatch: string | null = null;
  /**
   * 调用方的归属守卫（cross-platform-lessons 13、16）：设备注册、埋点上报等后台任务带上开始时的 ticket（隐私、环境、清理
   * 世代）。ApiClient 在每次实际发送前（含 TransportRequest.admit）、每次异步等待之后、每个响应处理之前与自己的调用归属
   * 一起核对；返回 false（或抛错）就按 cancelled 结束，不改绑到当前环境或会话。null = 没有额外守卫。
   */
  owner: (() => boolean) | null = null;
  /**
   * 写出观察（F-HM-10，APP-05a 共性 22）：传输层每次在真正发出前核对（TransportRequest.admit）后，以核对结果调用它；
   * 最后一次为 true 表示这次发送已交给底层发出（之后结果可能未知），false 表示没有发出。发码用它区分「请求还没写出」与
   * 「已写出但结果未知」。null = 不观察。
   */
  onAdmit: ((admitted: boolean) => void) | null = null;
  /**
   * 发送闸门（APP-08 harmony-review-r2 R2-01，共性第 13 条）：每一次实际发送前（首发、GET 自动重试退避之后、10401 校时重签、
   * 刷新或设备重新注册后的重放，以及 TransportRequest.admit）都核对；返回 false（或抛错）就不发，以 local_reject /
   * send_blocked 结束。与 owner 不同，它不参与响应到达后的归属核对（已发出的请求照常收响应）。null = 不限制。
   */
  sendAllowed: (() => boolean) | null = null;

  constructor(operationId: string, pathParams: Record<string, string> = {}, query: string = '',
    body: string | null = null) {
    this.operationId = operationId;
    this.pathParams = pathParams;
    this.query = query;
    this.body = body;
  }
}

export class ApiOutcome {
  static readonly SUCCESS: string = 'success';
  /** 带统一外壳的业务错误码。 */
  static readonly BUSINESS_ERROR: string = 'business_error';
  /** 超时、断连、没有统一外壳。 */
  static readonly NETWORK_ERROR: string = 'network_error';
  /** 本地拒绝，没有发出。 */
  static readonly LOCAL_REJECT: string = 'local_reject';
  /** 条件请求（带 If-None-Match）得到 304：内容没变（APP-03b）。 */
  static readonly NOT_MODIFIED: string = 'not_modified';
}

/** 请求结果。 */
export class ApiResult {
  readonly outcome: string;
  /** 外壳的 code（成功 0）；没有外壳为 -1。 */
  readonly code: number;
  readonly msg: string;
  /** 外壳的 data（没有为 {}）。 */
  readonly data: Record<string, Object>;
  readonly traceId: string;
  readonly httpStatus: number;
  /**
   * none / timeout / disconnect / cancelled / no_envelope / session_cleanup_failed（刷新失败后清会话本身出错）/
   * refresh_unavailable（等待的刷新没有服务端结论，原请求没有发出，R2-03）。
   */
  readonly failure: string;
  readonly localRejectReason: string | null;
  /** 页面要执行的动作（成功为 null）。 */
  readonly effect: ErrorEffect | null;
  /** 这次用的幂等键（没有为 null）。 */
  readonly idempotencyKey: string | null;
  /**
   * 放弃上一笔（abandonPending）的结局：abandoned（已放弃）/ completed（原请求已完成，本结果是解包后的原结果）；
   * 其余调用与没有明确结局时为 null（PendingResolution，R2-04）。
   */
  pendingResolution: string | null = null;
  /** 成功与 304 时响应头 ETag 的原值（不透明字符串；没有为 null，APP-03b）。 */
  etag: string | null = null;

  constructor(outcome: string, code: number, msg: string, data: Record<string, Object>, traceId: string,
    httpStatus: number, failure: string, localRejectReason: string | null, effect: ErrorEffect | null,
    idempotencyKey: string | null) {
    this.outcome = outcome;
    this.code = code;
    this.msg = msg;
    this.data = data;
    this.traceId = traceId;
    this.httpStatus = httpStatus;
    this.failure = failure;
    this.localRejectReason = localRejectReason;
    this.effect = effect;
    this.idempotencyKey = idempotencyKey;
  }

  get ok(): boolean {
    return this.outcome === ApiOutcome.SUCCESS;
  }

  /** trace_id 后 6 位（通用错误态附注，BR-TEXT-14）。 */
  get trace6(): string {
    return this.traceId.length <= 6 ? this.traceId : this.traceId.substring(this.traceId.length - 6);
  }

  static rejected(reason: string): ApiResult {
    return new ApiResult(ApiOutcome.LOCAL_REJECT, -1, '', {}, '', 0, TransportFailure.NONE, reason, null, null);
  }
}

/** 统一外壳 {code, msg, data, trace_id}。 */
class Envelope {
  readonly code: number;
  readonly msg: string;
  readonly data: Record<string, Object>;
  readonly traceId: string;

  constructor(code: number, msg: string, data: Record<string, Object>, traceId: string) {
    this.code = code;
    this.msg = msg;
    this.data = data;
    this.traceId = traceId;
  }

  static parse(text: string): Envelope | null {
    try {
      const parsed: Object | null = JSON.parse(text) as Object | null;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return null;
      }
      const record: Record<string, Object> = parsed as Record<string, Object>;
      const code: Object | undefined = record['code'];
      if (typeof code !== 'number' || !Number.isInteger(code as number)) {
        return null;
      }
      const msg: Object | undefined = record['msg'];
      const data: Object | undefined = record['data'];
      const trace: Object | undefined = record['trace_id'];
      const dataRecord: Record<string, Object> =
        data !== undefined && data !== null && typeof data === 'object' && !Array.isArray(data) ?
          data as Record<string, Object> : {};
      return new Envelope(code as number, typeof msg === 'string' ? msg as string : '', dataRecord,
        typeof trace === 'string' ? trace as string : '');
    } catch (e) {
      return null;
    }
  }
}

/**
 * 一次逻辑调用（首发、GET 重试、校时重签、10002 / 10402 重放、确认上一笔、屏障后继续）共享的「调用归属」
 * （harmony-review-r1 R1-01、R1-02、R1-05；r2 R2-01、R2-08；lessons 22–26、30、34）。
 * 在调用入口、进入任何异步等待之前就固定：账号、会话世代、登录序号、作废世代（撤回同意 / 切换环境）、隐私状态、环境基址。
 * 之后每一次实际发送前、每一次异步等待之后、每一个响应处理之前都用 ApiClient.ownershipLost 核对；
 * 归属变了就结束这次调用，绝不改绑到当前账号。
 */
class CallContext {
  /** 逻辑调用标识（未决键的占用绑定它，lessons 26）。 */
  readonly id: number;
  /** 入口时有会话且这个接口带 Authorization：要核对账号与会话世代。 */
  bound: boolean = false;
  /** 入口时的会话账号（没有会话为 null）。 */
  account: string | null = null;
  generation: number = 0;
  loginSerial: number = 0;
  epoch: number = 0;
  /** 入口时凭据可读（已同意隐私且撤回清理已完成）。 */
  credentialsAllowed: boolean = false;
  /** 入口时的隐私状态（NetworkPrivacy 规范值）。 */
  privacy: string = '';
  /** 入口时的环境基址（环境未就绪为空串）。 */
  apiBase: string = '';
  /** 四个 step-up 操作：beforeSend 已接受的未决键与所属账号（结算绑定原账号）。 */
  pendingKey: string | null = null;
  pendingAccount: string | null = null;
  /** 这次发送的是曾经结果未知的键（确认上一笔）：非终结的 2xxxx 改为「暂时确认不了」（lessons 39）。 */
  pendingEverUnknown: boolean = false;
  /** 调用方的归属守卫（ApiRequest.owner；lessons 13、16）。 */
  owner: (() => boolean) | null = null;
  /** 调用方的发送闸门（ApiRequest.sendAllowed；只在每次实际发送前核对）。 */
  sendAllowed: (() => boolean) | null = null;

  constructor(id: number) {
    this.id = id;
  }
}

/** 一次实际的请求执行（同一逻辑调用的各次共享 ctx）。 */
class Attempt {
  readonly request: ApiRequest;
  readonly operation: ApiOperation;
  readonly isReplay: boolean;
  /** 刷新请求本身：不按 mapper 再处理、不在这里保存令牌（performRefresh 核对后保存）。 */
  readonly internalRefresh: boolean;
  readonly ctx: CallContext;
  /** 最近一次实际发送带的 device_id（刷新请求收到 10402 时交给重新注册，R1-03）。 */
  sentDeviceId: string | null = null;

  constructor(request: ApiRequest, operation: ApiOperation, isReplay: boolean, internalRefresh: boolean,
    ctx: CallContext) {
    this.request = request;
    this.operation = operation;
    this.isReplay = isReplay;
    this.internalRefresh = internalRefresh;
    this.ctx = ctx;
  }
}

/** prepare 的结果。 */
class Prepared {
  readonly rejected: string | null;
  readonly decision: HeaderDecision | null;
  readonly endpoints: EnvironmentEndpoints | undefined;
  readonly accessToken: string | null;
  readonly deviceId: string | null;
  readonly installSecret: string | null;
  readonly scope: string;
  readonly pathWithQuery: string;
  readonly key: string | null;

  constructor(rejected: string | null, decision: HeaderDecision | null, endpoints: EnvironmentEndpoints | undefined,
    accessToken: string | null, deviceId: string | null, installSecret: string | null, scope: string,
    pathWithQuery: string, key: string | null) {
    this.rejected = rejected;
    this.decision = decision;
    this.endpoints = endpoints;
    this.accessToken = accessToken;
    this.deviceId = deviceId;
    this.installSecret = installSecret;
    this.scope = scope;
    this.pathWithQuery = pathWithQuery;
    this.key = key;
  }

  /** 这次发送带了 Authorization。 */
  get carriesToken(): boolean {
    return this.decision !== null && this.decision.has(NetworkHeaders.AUTHORIZATION) && this.accessToken !== null;
  }

  static reject(reason: string): Prepared {
    return new Prepared(reason, null, undefined, null, null, null, SessionScope.FULL, '', null);
  }
}

/** 一次单飞刷新的结论（等待者全部拿到同一个结论，R1-03）。 */
class RefreshOutcome {
  static readonly OK: string = 'ok';
  /** 服务端明确拒绝：会话已清，发出会话级 Effect。 */
  static readonly FAILED: string = 'failed';
  /** 没有服务端结论（超时、断连、响应形状不对）：不清会话，这次按网络错误收口。 */
  static readonly TRANSIENT: string = 'transient';
  /** 刷新期间会话换了（登录、退出、撤回同意、切换环境）：结果丢弃，不替新会话重放。 */
  static readonly SESSION_CHANGED: string = 'session_changed';

  readonly kind: string;
  readonly token: string | null;
  readonly effect: ErrorEffect | null;
  /** 刷新失败后清会话本身出错（R1-04：转换为明确结果，不丢等待者）。 */
  readonly cleanupFailed: boolean;

  constructor(kind: string, token: string | null, effect: ErrorEffect | null, cleanupFailed: boolean = false) {
    this.kind = kind;
    this.token = token;
    this.effect = effect;
    this.cleanupFailed = cleanupFailed;
  }

  static ok(token: string): RefreshOutcome {
    return new RefreshOutcome(RefreshOutcome.OK, token, null);
  }

  static of(kind: string): RefreshOutcome {
    return new RefreshOutcome(kind, null, null);
  }
}

/**
 * 一轮单飞刷新：屏障 promise 只在完成流程的最后一步（会话已保存或已清除、结论已定）才兑现。
 * 账号、世代与令牌快照在入队那一刻固定（lessons 24）：执行与结算都以快照为准，不再去读「当前账号」。
 */
class RefreshRound {
  readonly promise: Promise<RefreshOutcome>;
  /** 发起刷新时的 access_token（成功后记入令牌世系；失败时记为已失败令牌）。 */
  readonly usedAccess: string | null;
  /** 入队时的 refresh_token（凭据不可读时为 null）。 */
  readonly refreshToken: string | null;
  readonly account: string | null;
  readonly generation: number;
  readonly epoch: number;
  readonly credentialsAllowed: boolean;
  settled: boolean = false;
  /**
   * 登记在这一轮上的调用方（APP-04 共性 41，I-R2-02，F-HM-07）：发起刷新的调用、复用这一轮的 10002、等屏障的调用。
   * system = true 表示 App 自己发起（冷启动 / 强更恢复的受限会话屏障、手动入口），不依赖调用方。
   */
  readonly callers: CallContext[] = [];
  system: boolean = false;
  /**
   * 这一轮刷新请求（含校时重签、10402 重放）自己的归属守卫：「还有有效调用方」。所有发送共用这一个函数对象，
   * cancelOwned 据此找到并取消底层刷新传输（harmony-review-r1 R1-11，APP-04 共性 54）。
   */
  owner: (() => boolean) | null = null;
  private resolver: (outcome: RefreshOutcome) => void = (_o: RefreshOutcome) => {
  };

  constructor(usedAccess: string | null, refreshToken: string | null, account: string | null, generation: number,
    epoch: number, credentialsAllowed: boolean) {
    this.usedAccess = usedAccess;
    this.refreshToken = refreshToken;
    this.account = account;
    this.generation = generation;
    this.epoch = epoch;
    this.credentialsAllowed = credentialsAllowed;
    this.promise = new Promise<RefreshOutcome>((resolve: (outcome: RefreshOutcome) => void) => {
      this.resolver = resolve;
    });
  }

  resolve(outcome: RefreshOutcome): void {
    this.resolver(outcome);
  }
}

/** 已交给传输层、还没有结果的一次发送（撤回同意 / 切换环境时取消，lessons 22）。 */
class LiveRequest {
  readonly request: TransportRequest;
  readonly abort: () => void;
  /** 发起调用的归属守卫（ApiRequest.owner；桥调用为 call.valid）；cancelOwned 按它取消。 */
  readonly owner: (() => boolean) | null;

  constructor(request: TransportRequest, abort: () => void, owner: (() => boolean) | null = null) {
    this.request = request;
    this.abort = abort;
    this.owner = owner;
  }
}

/**
 * 请求管线（APP-03a；03 §4.2 中间件顺序）：公共头 → 签名（只对 x-signed）→ 发送（10 秒超时；open 8 秒）→ 解包外壳 →
 * ErrorActionMapper。读接口超时 / 断连自动重试 1 次（退避 500 ms），写接口不自动重试。
 *
 * - 本地拒绝（不发出）：环境未就绪、基本模式白名单外、受限会话表外（含请求体条件）、需要签名而设备未注册、
 *   未决键未结（RequestHeaderPolicy + 本类的请求体条件）。基本模式与撤回清理未完成时不读不带任何凭据。
 * - 调用归属（R1-01、R2-01、R2-08；lessons 22–26、30、34）：调用入口（任何异步等待之前）固定账号、会话世代、登录序号、
 *   作废世代、隐私状态与环境基址（CallContext）。所有自动续发路径——GET 重试、10401 校时重签、10002 刷新后重放、
 *   10402 重新注册后重放、确认上一笔、刷新 / 受限屏障之后继续——以及每个响应的处理（含登录响应保存令牌、10404 清会话），
 *   都先经 ownershipLost 同一套核对；归属变了就结束旧调用（session_changed / cancelled），不改绑到当前账号，
 *   旧响应不改动当前会话。传输层在真正发出前再核对一次（TransportRequest.admit），撤回同意 / 切换环境时取消已交给
 *   传输层、还没有结果的请求（invalidate）。
 * - 10002：单飞刷新（RefreshCoordinator 计数），成功后用新令牌、原键原体重放 1 次；只有同世代、同账号，且当前令牌是
 *   这次请求所用令牌经本客户端刷新得到的（令牌世系），才复用已完成的刷新。失败清会话并发出会话级 Effect。
 *   刷新的账号、世代与令牌快照在入队时固定（lessons 24）。刷新的收尾在同一个完成流程里依次做完：保存或清除会话 →
 *   定下结论（强更状态取这一刻的值）→ 兑现屏障（全部等待者拿到同一结论，各结算一次）。带会话的请求在刷新在途时先等屏障；
 *   屏障按完整结论结算（R2-03）：失败 → session_cleared，没有服务端结论 → 网络错误，会话换了 → session_changed，
 *   都不发出原请求。会话世代结束时在途的刷新与新世代脱钩，新会话的请求不等旧刷新。
 * - 受限会话屏障（R1-06、R2-02）：冷启动后第一次请求、或强更状态由「低于 / 未知」恢复为「不低于」后，本机会话是
 *   deletion_only 的，先自动单飞刷新，其他带令牌的请求都等它。强更状态变更由 onUpdateStateChanged 通知（App 组合处
 *   经 NetworkComposition 把 AppUpdate.onChanged 接到这里），请求入口也会核对；登录或刷新在强更未知时拿到 deletion_only、按「低于」处理时同步记下。
 * - 10402：重新注册设备后原键重放 1 次（DeviceRegistrar，APP-03b：单飞，同时收到 10402 的请求共用一次注册；
 *   注册请求本身收到 10402 不再触发重新注册）。重放前照常重新组头、取新凭据、重新签名。
 * - 会话读取失败（SessionTokens.readStatus = unreadable，APP-03b）：x-auth 不为 none 的接口本地拒绝 session_unreadable，
 *   不当成游客匿名发出；刷新时读不出 refresh_token 按没有结论（不清会话）。
 * - 条件请求（ApiRequest.ifNoneMatch，只用于 GET）：原样带 If-None-Match；304 → ApiOutcome.NOT_MODIFIED。成功与 304 的
 *   ApiResult.etag 是响应头 ETag 原值（APP-03b ConfigStore 用）。
 * - 10405：进强更（UpdatePort.on10405）；遗留受限令牌只刷新（refresh_only）。
 * - 登录 / 刷新成功：记下 session_scope；强更检查未知时拿到 deletion_only → 按低于处理（UpdatePort.on10405(null)），
 *   强更状态取处理响应那一刻的值（lessons 28）。
 * - 10401 且响应头 Date 与本机相差超过 300 秒：校正时钟偏移，用新的 X-Timestamp 与 X-Nonce 重签再发 1 次（BR-ID-09）。
 * - 四个 step-up 操作：发送前写未决记录，按响应结局更新（PendingKeyStore，结算绑定原账号与调用标识）；内部续发期间
 *   一直占用，逻辑调用结束时还在途的统一结算（R1-05、lessons 26）。查询 / 确认 / 放弃上一笔先核对记录账号与当前会话
 *   账号（R1-02）；确认 / 放弃先持久化成功再发送（R2-05）；放弃得到 completed 时按原操作解包并映射（R2-04）。
 * 单线程（UI 线程）使用。
 */
/**
 * 调用方自己固定的归属快照（APP-05b harmony-review-r1 R1-01，APP-05b 共性 1）：跨越多次请求与第三方 SDK 等待的流程（第三方
 * 登录：取授权尝试 → 等授权 → 提交凭证）在开始时记下会话、登录、隐私、环境归属，每次异步返回后用 ApiClient.scopeValid
 * 复核；变了就终止整个流程，后续请求不在新上下文里重新绑定。不含任何凭据（账号只用于比较）。
 */
export class ClientScope {
  readonly epoch: number;
  readonly loginSerial: number;
  readonly sessionGeneration: number;
  readonly credentialsAllowed: boolean;
  readonly privacy: string;
  readonly apiBase: string;
  readonly account: string | null;

  constructor(epoch: number, loginSerial: number, sessionGeneration: number, credentialsAllowed: boolean,
    privacy: string, apiBase: string, account: string | null) {
    this.epoch = epoch;
    this.loginSerial = loginSerial;
    this.sessionGeneration = sessionGeneration;
    this.credentialsAllowed = credentialsAllowed;
    this.privacy = privacy;
    this.apiBase = apiBase;
    this.account = account;
  }
}

export class ApiClient {
  /** 签发会话的操作（响应 data 为 TokenPair）。 */
  static readonly SESSION_ISSUING: string[] = ['loginBySms', 'loginByWechat', 'loginByApple', 'loginByHuawei',
    'refreshToken'];
  static readonly REFRESH_OPERATION: string = 'refreshToken';
  /** 登出（settings.logout）：回 10404 时不发会话级跳登录 Effect。 */
  static readonly LOGOUT_OPERATION: string = 'logout';
  /** 设备注册（APP-03b，DeviceRegistry 发出）。 */
  static readonly REGISTER_DEVICE_OPERATION: string = 'registerDevice';
  static readonly ABANDON_OPERATION: string = 'abandonIdempotencyKey';
  /** BR-ID-09：Date 与本机相差超过 300 秒才校时重签。 */
  static readonly CLOCK_SKEW_LIMIT_SECONDS: number = 300;
  /** 等待的刷新没有服务端结论（R2-03）。 */
  static readonly REFRESH_UNAVAILABLE: string = 'refresh_unavailable';
  /** 令牌世系最多回溯的刷新次数。 */
  /** 等一个布尔结果；守卫被 cancelOwned 取消时立即以 null 结束（与 waitOwned 同一套登记，F-HM-08 共性 64）。 */
  private waitOwnedFlag(promise: Promise<boolean>, owner: () => boolean): Promise<boolean | null> {
    const wrapped: Promise<RefreshOutcome> = promise.then((ok: boolean): RefreshOutcome =>
    RefreshOutcome.of(ok ? ApiClient.FLAG_TRUE : ApiClient.FLAG_FALSE));
    return this.waitOwned(wrapped, owner).then((outcome: RefreshOutcome | null): boolean | null =>
    outcome === null ? null : outcome.kind === ApiClient.FLAG_TRUE);
  }

  private static readonly FLAG_TRUE: string = 'flag_true';
  private static readonly FLAG_FALSE: string = 'flag_false';

  private static readonly LINEAGE_DEPTH: number = 16;

  private readonly deps: ApiClientDeps;
  private readonly signer: RequestSigner;
  private readonly refresher: RefreshCoordinator;
  /** 在途的单飞刷新（屏障）；没有为 null。 */
  private refreshRound: RefreshRound | null = null;
  /** 带归属守卫等待受限会话复查的调用方（refreshRestrictedSession(owner)，R2-02）：cancelOwned 按守卫立即结束等待。 */
  private ownedWaits: Map<() => boolean, (() => void)[]> = new Map<() => boolean, (() => void)[]>();
  /** 最近一次明确失败的刷新所用的 access_token：同一旧令牌晚到的 10002 不再刷新、不再清会话（lessons R1-06）。 */
  private failedAccessToken: string | null = null;
  /**
   * 因刷新明确失败而清掉的会话世代与那次的结论（lessons 37）：这个世代晚到的 10002 / 屏障等待者复用它，
   * 返回 session_cleared，不再刷新、不再清会话；与用户换了会话（session_changed）区分开。
   */
  private clearedGeneration: number = -1;
  private clearedOutcome: RefreshOutcome | null = null;
  /** 作废世代：撤回同意、切换环境时加一，在途请求、重试与刷新结果一律作废。 */
  private epoch: number = 0;
  /** 会话世代：登录、退出、清会话、作废时加一（R1-01）。 */
  private sessionGeneration: number = 0;
  /** 登录序号：登录成功、onSessionChanged、作废时加一（不随刷新失败清会话变化；不带令牌的调用核对它，lessons 23）。 */
  private loginSerial: number = 0;
  /** 本世代内本客户端完成的刷新：旧 access_token → 新 access_token。 */
  private lineage: Map<string, string> = new Map<string, string>();
  /** 当前会话已确认不需要受限会话刷新（R1-06）；冷启动为 false。 */
  private restrictedChecked: boolean = false;
  /** 上次看到的强更状态（检测「低于 / 未知 → 不低于」，R2-02）。 */
  private lastUpdateState: string | null = null;
  /** 强更未知时拿到 deletion_only、已按「低于」处理（UpdatePort.on10405(null)）；恢复为「不低于」时清除。 */
  private treatedAsBelow: boolean = false;
  private sequence: number = 0;
  private callSequence: number = 0;
  /** 服务端时间 − 本机时间（秒），由 10401 的 Date 校正。 */
  private clockOffsetSeconds: number = 0;
  /**
   * 展示用的服务端时钟偏移（毫秒，BR-TEXT-11；APP-08 共性第 34 条）：每个带 Date 头的响应都校一次，偏差超过 5 分钟才采用，否则为 0。
   * 只用于相对时间（今天 / 昨天）等展示，不参与签名（签名仍按 10401 校时，BR-ID-09）。
   */
  private displayOffsetMillis: number = 0;
  /** 已交给传输层、还没有结果的发送。 */
  private readonly live: Set<LiveRequest> = new Set<LiveRequest>();

  constructor(deps: ApiClientDeps) {
    this.deps = deps;
    this.signer = new RequestSigner(deps.digest);
    this.refresher = new RefreshCoordinator(
      (completion: RefreshCompletion): void => {
        this.runRefreshRound(completion);
      },
      (_request: RefreshRequest, _token: string): void => {
        // 等待者由 RefreshRound 的屏障统一结算（R1-03），这里不逐个回调。
      },
      (): void => {
        // 清会话在 finishRound 的完成流程里做（R1-03、R1-04）。
      },
      deps.clock,
      (): boolean => this.deps.update.state() === ErrorUpdateState.BELOW);
  }

  /**
   * 撤回同意、切换环境（清理器里调用）：作废全部在途请求、它们的重试与在途刷新的结果（lessons R1-01、R1-07），
   * 并取消已交给传输层、还没有结果的请求（还在等连接 / TLS 的不再发出，lessons 22）。
   */
  invalidate(): void {
    this.epoch++;
    this.loginSerial++;
    this.endSessionGeneration();
    const live: LiveRequest[] = Array.from(this.live.values());
    this.live.clear();
    for (const entry of live) {
      try {
        this.deps.transport.cancel(entry.request);
      } catch (e) {
        // 传输层不得抛出；万一抛出，下面照样按取消收口。
      }
      entry.abort();
    }
  }

  /**
   * 取消归属于这个守卫的、已交给传输层还没有结果的请求（APP-04 共性 45：桥调用到截止时间时由 BridgeHost.onCallExpired 调用）。
   * 被取消的发送按 cancelled 收口；之后的重试、恢复由归属核对（守卫此时已返回 false）结束。返回取消的个数。
   */
  cancelOwned(owner: () => boolean): number {
    let count: number = this.cancelLive(owner);
    // APP-05a R2-02：这个守卫在等受限会话复查——立即结束等待（结果按「没有复查结论」）。
    const waits: (() => void)[] | undefined = this.ownedWaits.get(owner);
    if (waits !== undefined) {
      this.ownedWaits.delete(owner);
      for (const wake of waits) {
        wake();
      }
    }
    // R1-11（APP-04 共性 54）：这个调用方登记在在途的共享刷新上，而它到期后这一轮已没有任何有效调用方——刷新请求用的是
    // 这一轮自己的守卫（RefreshRound.owner），按它取消底层刷新传输；刷新随即以「没有结论」结束，等待者全部结算。
    // 还有别的有效调用方时保留共享刷新。
    const round: RefreshRound | null = this.refreshRound;
    if (round !== null && !round.system) {
      const roundOwner: (() => boolean) | null = round.owner;
      if (roundOwner !== null && !this.roundHasLiveCaller(round)
        && round.callers.some((caller: CallContext): boolean => caller.owner === owner)) {
        count += this.cancelLive(roundOwner);
      }
    }
    // R3-03（共性 58）：普通请求或共享刷新进入的设备重新注册，调用方全部失效时取消底层注册请求。
    this.notifyRegistrar();
    return count;
  }

  /** R3-03：设备重新注册已没有有效调用方时，取消它的底层注册请求（独立的启动注册不受影响）。 */
  private notifyRegistrar(): void {
    try {
      this.deps.deviceRegistrar.callersChanged();
    } catch (e) {
      // 注册方出错不影响取消。
    }
  }

  private cancelLive(owner: () => boolean): number {
    let count: number = 0;
    for (const entry of Array.from(this.live.values())) {
      if (entry.owner === owner) {
        this.live.delete(entry);
        this.cancelQuietly(entry.request);
        entry.abort();
        count++;
      }
    }
    return count;
  }

  /**
   * 登录流程以外换了会话（退出登录、切换账号，APP-05 调用）：旧世代的请求不再重试或重放，未决记录跟随当前账号。
   */
  onSessionChanged(): void {
    this.loginSerial++;
    this.endSessionGeneration();
    this.syncPendingAccount();
  }

  /**
   * 登录世代（F-HM-10，APP-05a 共性 23）：登录保存成功、onSessionChanged、作废时推进的计数（即 loginSerial）。刷新失败清会话
   * 不推进它——原会话被清除不等于换成了新会话。登出在发请求之前记下它，回来后交给 clearSessionIfEpoch。
   */
  loginEpoch(): number {
    return this.loginSerial;
  }

  /**
   * 按登录世代清会话（F-HM-10，APP-05a 共性 23）：核对世代与删除会话在同一同步区内完成，与登录响应保存令牌（onSuccess）
   * 用同一个 UI 线程同步区（「同一把锁」）——两者之间不可能插进别的登录保存。expected 与当前登录世代相同（期间没有新登录
   * 保存，可能有刷新失败清会话）→ 结束会话世代、删除令牌，返回 true；不同（已换成新登录）→ 什么都不动，返回 false，
   * 新会话不会被旧会话的登出删除。删除失败按 SecureSessionTokens 的隔离与重试处理（lessons 38），仍返回 true。
   * afterClear 在同一同步区内执行（Router 的清理绑定这次被清除的原会话）。
   */
  clearSessionIfEpoch(expected: number, afterClear: () => void = () => {
  }): boolean {
    if (expected !== this.loginSerial) {
      return false;
    }
    this.onSessionChanged();
    try {
      this.deps.tokens.clear();
    } catch (e) {
      // 删除失败：SecureSessionTokens 已在内存里作废旧令牌并持续重试删除（lessons 38），按已清除处理。
    }
    this.syncPendingAccount();
    try {
      afterClear();
    } catch (e) {
      // 清理出口出错不影响已清除的会话。
    }
    return true;
  }

  /**
   * 强更状态变更通知（R2-02、R3-04；App 组合处经 NetworkComposition.install 把 AppUpdate.onChanged 接到这里）。
   * 由「低于 / 未知」恢复为「不低于」且本机会话是 deletion_only：立即发起受限会话刷新屏障，不等下一个请求。
   */
  onUpdateStateChanged(): void {
    this.observeUpdateState();
    this.ensureRestrictedBarrier();
  }

  /** 单飞刷新的计数（测试与诊断用）。 */
  get refreshCalls(): number {
    return this.refresher.refreshCalls;
  }

  /** 发一个业务请求。不抛出。 */
  request(request: ApiRequest): Promise<ApiResult> {
    const operation: ApiOperation | undefined = ApiOperations.byId(request.operationId);
    if (operation === undefined) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.UNKNOWN_OPERATION));
    }
    // 冷启动 / 强更恢复后的受限会话刷新（R1-06、R2-02）先发起，再在任何等待之前绑定调用归属（R2-01）。
    this.observeUpdateState();
    this.ensureRestrictedBarrier();
    const ctx: CallContext = this.bind(operation);
    ctx.owner = request.owner;
    ctx.sendAllowed = request.sendAllowed;
    return this.runCall(new Attempt(request, operation, false, false, ctx));
  }

  /**
   * 受限会话刷新屏障的手动入口（冷启动与强更恢复已自动接入，R1-06、R2-02）：本机会话是 deletion_only 的
   * 立即单飞刷新，刷新期间新发的请求等它结束。返回刷新后是否仍有会话。
   *
   * owner（APP-05a R2-02，共性 10）：登录触发的复查带本次尝试的归属守卫。这一轮刷新登记它为调用方（由它发起时不是 App 级
   * 屏障：只为它而发，它失效且没有别的有效调用方就取消刷新传输，R1-11 同一口径）；cancelOwned(owner) 立即结束这次等待并
   * 返回 false。守卫在等待前已失效时不发起、直接返回 false。
   */
  async refreshRestrictedSession(owner: (() => boolean) | null = null): Promise<boolean> {
    if (owner !== null && !ApiClient.safeOwner(owner)) {
      return false;
    }
    this.observeUpdateState();
    this.restrictedChecked = false;
    let caller: CallContext | null = null;
    if (owner !== null) {
      caller = this.bind(ApiOperations.byId(ApiClient.REFRESH_OPERATION) as ApiOperation);
      caller.owner = owner;
    }
    this.ensureRestrictedBarrier(caller);
    const round: RefreshRound | null = this.refreshRound;
    if (round === null) {
      return this.credentialsAllowed() && this.deps.tokens.accessToken() !== null;
    }
    if (owner === null || caller === null) {
      const outcome: RefreshOutcome = await round.promise;
      return outcome.kind === RefreshOutcome.OK;
    }
    if (round.callers.indexOf(caller) < 0) {
      // 已有在途的一轮（App 级屏障或别的调用方发起）：登记为调用方，共用同一个结论。
      round.callers.push(caller);
    }
    const outcome: RefreshOutcome | null = await this.waitOwned(round.promise, owner);
    return outcome !== null && outcome.kind === RefreshOutcome.OK;
  }

  /** 等 promise；守卫被 cancelOwned 取消时立即以 null 结束。 */
  private waitOwned(promise: Promise<RefreshOutcome>, owner: () => boolean): Promise<RefreshOutcome | null> {
    return new Promise<RefreshOutcome | null>((resolve: (value: RefreshOutcome | null) => void): void => {
      let done: boolean = false;
      const wake: () => void = (): void => {
        if (!done) {
          done = true;
          resolve(null);
        }
      };
      const list: (() => void)[] = this.ownedWaits.get(owner) ?? [];
      list.push(wake);
      this.ownedWaits.set(owner, list);
      const forget: () => void = (): void => {
        const current: (() => void)[] | undefined = this.ownedWaits.get(owner);
        if (current === undefined) {
          return;
        }
        const rest: (() => void)[] = current.filter((w: () => void): boolean => w !== wake);
        if (rest.length === 0) {
          this.ownedWaits.delete(owner);
        } else {
          this.ownedWaits.set(owner, rest);
        }
      };
      promise.then((outcome: RefreshOutcome): void => {
        forget();
        if (!done) {
          done = true;
          resolve(outcome);
        }
      }, (): void => {
        forget();
        if (!done) {
          done = true;
          resolve(null);
        }
      });
    });
  }

  private static safeOwner(owner: () => boolean): boolean {
    try {
      return owner();
    } catch (e) {
      return false;
    }
  }

  /**
   * 当前有效会话的账号（埋点 user_id 用，cross-platform-lessons 9）：与请求管线同一套判断——隐私已同意且撤回清理已完成、
   * 本机有可用会话（SessionTokens 的清会话隔离期间、读不出时为没有），且不是刚因刷新明确失败而被清掉的那个令牌。
   * 其余一律为 null（游客：只带 device_id）。
   */
  sessionAccount(): string | null {
    const account: string | null = this.trustedAccount();
    if (account === null) {
      return null;
    }
    const failed: string | null = this.failedAccessToken;
    return failed !== null && this.deps.tokens.accessToken() === failed ? null : account;
  }

  /**
   * 会话世代（APP-04 R2-03）：不含任何凭据的计数，登录、退出、换账号、清会话、作废都会推进；同一账号退出后重新登录也是新世代。
   * 桥调用把它绑进 binding，旧调用不会在新会话下执行。
   */
  sessionGenerationId(): number {
    return this.sessionGeneration;
  }

  /** 固定此刻的会话、登录、隐私、环境归属（ClientScope；APP-05b R1-01）。 */
  captureScope(): ClientScope {
    const allowed: boolean = this.credentialsAllowed();
    const endpoints: EnvironmentEndpoints | undefined = this.deps.context.endpoints();
    return new ClientScope(this.epoch, this.loginSerial, this.sessionGeneration, allowed,
      RequestHeaderPolicy.normalizePrivacy(this.deps.context.privacy()), endpoints === undefined ? '' : endpoints.apiBase,
      allowed && this.deps.tokens.accessToken() !== null ? this.deps.tokens.account() : null);
  }

  /**
   * 归属快照此刻仍成立：撤回同意 / 切换环境（作废世代）、登录保存或换会话（登录序号、会话世代）、清会话、隐私或凭据状态、
   * 环境端点、会话账号，任何一项变了都返回 false。
   */
  scopeValid(scope: ClientScope): boolean {
    const now: ClientScope = this.captureScope();
    return now.epoch === scope.epoch && now.loginSerial === scope.loginSerial
      && now.sessionGeneration === scope.sessionGeneration && now.credentialsAllowed === scope.credentialsAllowed
      && now.privacy === scope.privacy && now.apiBase === scope.apiBase && now.account === scope.account;
  }

  /** 发起页查询：当前会话账号该操作的未决记录（先核对账号，R1-02）。 */
  pendingFor(operationId: string): PendingKeyRecord | null {
    const store: PendingKeyStore | null = this.deps.pendingKeys;
    const account: string | null = this.trustedAccount();
    if (store === null || account === null) {
      return null;
    }
    this.syncPendingAccount();
    const record: PendingKeyRecord | null = store.pendingFor(operationId);
    return record !== null && record.account === account ? record : null;
  }

  /** 某个键的状态（只看当前会话账号的记录，R1-02）。 */
  pendingState(key: string): PendingKeyState {
    const store: PendingKeyStore | null = this.deps.pendingKeys;
    const account: string | null = this.trustedAccount();
    if (store === null || account === null) {
      return new PendingKeyState(PendingKeyStateRaw.NONE, null);
    }
    this.syncPendingAccount();
    const state: PendingKeyState = store.state(key);
    if (state.record !== null && state.record.account !== account) {
      return new PendingKeyState(PendingKeyStateRaw.NONE, null);
    }
    return state;
  }

  /**
   * 【确认上一笔】：原键、原请求体重发。记录必须属于当前可信会话账号（R1-02），调用在入口绑定这个账号与会话世代，
   * 等屏障、发送前都再核对；结算绑定原账号与本调用标识。先把「在途」持久化成功才发送；持久化失败保持结果未知并返回
   * pending_store_failed（R2-05）。结果未知后 10003 → 二次验证后带新 token 再调本方法。
   */
  confirmPending(key: string, stepUpToken: string | null = null,
    sendAllowed: (() => boolean) | null = null): Promise<ApiResult> {
    const store: PendingKeyStore | null = this.deps.pendingKeys;
    const account: string | null = this.trustedAccount();
    if (store === null || account === null) {
      return Promise.resolve(ApiResult.rejected(store === null ? LocalRejectReason.PENDING_KEY_UNRESOLVED :
      LocalRejectReason.ACCOUNT_UNKNOWN));
    }
    const owned: string | null = this.pendingOwner(store, key, account);
    if (owned !== null) {
      return Promise.resolve(ApiResult.rejected(owned));
    }
    if (!this.pendingStoreReady(store, account)) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.PENDING_STORE_FAILED));
    }
    const record: PendingKeyRecord | null = store.state(key).record;
    const operation: ApiOperation | undefined = record === null ? undefined : ApiOperations.byId(record.operationId);
    if (record === null || operation === undefined || record.stateRaw !== PendingKeyStateRaw.UNKNOWN) {
      return Promise.resolve(ApiResult.rejected(operation === undefined && record !== null ?
      LocalRejectReason.UNKNOWN_OPERATION : LocalRejectReason.PENDING_KEY_UNRESOLVED));
    }
    this.observeUpdateState();
    this.ensureRestrictedBarrier();
    const ctx: CallContext = this.bind(operation);
    if (!ctx.bound || ctx.account !== account) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH));
    }
    try {
      if (!store.confirm(key, ctx.id)) {
        return Promise.resolve(ApiResult.rejected(LocalRejectReason.PENDING_KEY_UNRESOLVED));
      }
    } catch (e) {
      return Promise.resolve(ApiResult.rejected(LocalRejectReason.PENDING_STORE_FAILED));
    }
    ctx.pendingKey = key;
    ctx.pendingAccount = account;
    ctx.pendingEverUnknown = true;
    // APP-09：发起页的 42901 发送闸门（提现 / 收款账号的提交、确认、放弃共用一个截止时间），每次实际发包前核对。
    ctx.sendAllowed = sendAllowed;
    const request: ApiRequest = new ApiRequest(record.operationId, {}, '', record.body);
    request.idempotencyKey = record.key;
    request.stepUpToken = stepUpToken;
    request.summary = record.summary;
    // 本地被拒绝、发送前出错、归属变了：逻辑调用结束时 runCall 把记录从在途恢复为结果未知（lessons R1-13、R1-05）。
    return this.runCall(new Attempt(request, operation, false, false, ctx));
  }

  /**
   * 【放弃上一笔】（用户已二次确认）：调 POST /v1/idempotency-keys/abandon（不带 Idempotency-Key，原键放请求体）。
   * 记录必须属于当前可信会话账号，作废请求在入口绑定这个账号（R1-02）；结算绑定原账号。先持久化成功才发送（R2-05）。
   * outcome=abandoned → 键结束，结果带 pendingResolution=abandoned；outcome=completed → 按附带的原结果结算（成功或 3xxxx
   * 结束），并按记录里的原 operation 解包成原业务结果、经 ErrorActionMapper 给出 Effect（R2-04，lessons 27）；
   * 其余响应或没有明确响应 → 保持待确认。
   */
  async abandonPending(key: string, sendAllowed: (() => boolean) | null = null): Promise<ApiResult> {
    const store: PendingKeyStore | null = this.deps.pendingKeys;
    const account: string | null = this.trustedAccount();
    if (store === null || account === null) {
      return ApiResult.rejected(store === null ? LocalRejectReason.PENDING_KEY_UNRESOLVED :
      LocalRejectReason.ACCOUNT_UNKNOWN);
    }
    const owned: string | null = this.pendingOwner(store, key, account);
    if (owned !== null) {
      return ApiResult.rejected(owned);
    }
    if (!this.pendingStoreReady(store, account)) {
      return ApiResult.rejected(LocalRejectReason.PENDING_STORE_FAILED);
    }
    const record: PendingKeyRecord | null = store.state(key).record;
    const operation: ApiOperation | undefined = record === null ? undefined : ApiOperations.byId(record.operationId);
    const abandonOp: ApiOperation | undefined = ApiOperations.byId(ApiClient.ABANDON_OPERATION);
    if (record === null || operation === undefined || operation.stepUp === null || abandonOp === undefined
      || record.stateRaw !== PendingKeyStateRaw.UNKNOWN) {
      return ApiResult.rejected(LocalRejectReason.PENDING_KEY_UNRESOLVED);
    }
    this.observeUpdateState();
    this.ensureRestrictedBarrier();
    const ctx: CallContext = this.bind(abandonOp);
    if (!ctx.bound || ctx.account !== account) {
      return ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH);
    }
    try {
      if (!store.abandon(key, ctx.id)) {
        return ApiResult.rejected(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      }
    } catch (e) {
      return ApiResult.rejected(LocalRejectReason.PENDING_STORE_FAILED);
    }
    ctx.sendAllowed = sendAllowed;
    const body: string = JSON.stringify(new AbandonBody(operation.stepUp, key));
    let result: ApiResult = ApiResult.rejected(LocalRejectReason.CANCELLED);
    try {
      result = await this.runCall(new Attempt(new ApiRequest(ApiClient.ABANDON_OPERATION, {}, '', body), abandonOp,
        false, false, ctx));
    } finally {
      try {
        store.onResponse(key, ApiClient.abandonOutcomeKind(result), account, ctx.id);
      } catch (e) {
        // 记录写不进存储：持久记录仍是在途，下次恢复时按结果未知处理。
      }
      try {
        store.settleIfInFlight(key, account, ctx.id);
      } catch (e) {
        // 同上。
      }
    }
    return this.abandonResult(result, operation);
  }

  /**
   * 作废接口结果的解包（R2-04，lessons 27）：completed → 原业务结果（code、msg、data 取 original，Effect 按原 operation
   * 经 ErrorActionMapper，30304 等照常引导）；abandoned → 原样返回并标 abandoned；其余原样返回。
   */
  private abandonResult(result: ApiResult, operation: ApiOperation): ApiResult {
    if (!result.ok) {
      return result;
    }
    const outcome: Object | undefined = result.data['outcome'];
    if (outcome === PendingResolution.ABANDONED) {
      const abandoned: ApiResult = new ApiResult(result.outcome, result.code, result.msg, result.data, result.traceId,
        result.httpStatus, result.failure, result.localRejectReason, result.effect, result.idempotencyKey);
      abandoned.pendingResolution = PendingResolution.ABANDONED;
      return abandoned;
    }
    const original: Record<string, Object> | null = ApiClient.originalOf(result.data);
    if (outcome !== PendingResolution.COMPLETED || original === null) {
      return result;
    }
    const code: number = original['code'] as number;
    const msgRaw: Object | undefined = original['msg'];
    const dataRaw: Object | undefined = original['data'];
    const msg: string = typeof msgRaw === 'string' ? msgRaw as string : '';
    const data: Record<string, Object> = dataRaw !== undefined && dataRaw !== null && typeof dataRaw === 'object'
      && !Array.isArray(dataRaw) ? dataRaw as Record<string, Object> : {};
    let effect: ErrorEffect | null = null;
    if (code !== 0) {
      effect = ErrorActionMapper.map(new ErrorActionInput(code, data, operation, {}, false,
        this.errorState(this.currentScope())));
    }
    const unwrapped: ApiResult = new ApiResult(code === 0 ? ApiOutcome.SUCCESS : ApiOutcome.BUSINESS_ERROR, code, msg,
      data, result.traceId, result.httpStatus, TransportFailure.NONE, null, effect, result.idempotencyKey);
    unwrapped.pendingResolution = PendingResolution.COMPLETED;
    return unwrapped;
  }

  /** data.original（completed 时是原响应外壳 {code, msg, data}；形状不对为 null）。 */
  private static originalOf(data: Record<string, Object>): Record<string, Object> | null {
    const original: Object | undefined = data['original'];
    if (original === undefined || original === null || typeof original !== 'object' || Array.isArray(original)) {
      return null;
    }
    const record: Record<string, Object> = original as Record<string, Object>;
    const code: Object | undefined = record['code'];
    return typeof code === 'number' && Number.isInteger(code as number) ? record : null;
  }

  /**
   * 确认 / 放弃之前核对账号（R1-02）：store 还停在别的账号、且那个账号有这条记录 → account_mismatch；
   * 之后把 store 切到当前账号。返回 null 表示可以继续（记录是否存在由调用方再查）。
   */
  private pendingOwner(store: PendingKeyStore, key: string, account: string): string | null {
    const before: PendingKeyRecord | null = store.state(key).record;
    if (before !== null && before.account !== account) {
      this.syncPendingAccount();
      return LocalRejectReason.ACCOUNT_MISMATCH;
    }
    this.syncPendingAccount();
    const after: PendingKeyRecord | null = store.state(key).record;
    return after !== null && after.account !== account ? LocalRejectReason.ACCOUNT_MISMATCH : null;
  }

  /**
   * 未决存储能否确认这个账号的状态（R3-01、R3-03，lessons 38）：恢复未完成就重读、清理待重试就重删；仍失败返回 false，
   * 调用方本地拒绝（pending_store_failed），不把读取失败当成「没有未决记录」。
   */
  private pendingStoreReady(store: PendingKeyStore, account: string): boolean {
    try {
      store.ensureReady(account);
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 发起页查询：当前会话账号的未决状态现在确认不了（存储读失败、记录损坏或删除待重试；每次调用都会重试）。
   * 为 true 时 pendingFor 的 null 不代表「没有未决记录」，四个敏感操作本地拒绝（pending_store_failed）。
   */
  pendingStoreUnavailable(): boolean {
    const store: PendingKeyStore | null = this.deps.pendingKeys;
    const account: string | null = this.trustedAccount();
    if (store === null || account === null) {
      return false;
    }
    return !this.pendingStoreReady(store, account);
  }

  private static abandonOutcomeKind(result: ApiResult): string {
    if (result.outcome === ApiOutcome.LOCAL_REJECT) {
      return PendingResponseKind.NO_RESULT;
    }
    if (result.outcome === ApiOutcome.NETWORK_ERROR) {
      return PendingResponseKind.NO_ENVELOPE;
    }
    if (result.code === 10002 || result.code === 10402) {
      // 作废请求自己的 10002 / 10402 已在管线里重放或放弃；到这里说明没有结果（R1-05）。
      return PendingResponseKind.NO_RESULT;
    }
    if (result.code !== 0) {
      return PendingResponseKind.ofCode(result.code);
    }
    const outcome: Object | undefined = result.data['outcome'];
    if (outcome === PendingResolution.ABANDONED) {
      return PendingResponseKind.ABANDONED;
    }
    const original: Record<string, Object> | null = ApiClient.originalOf(result.data);
    if (outcome === PendingResolution.COMPLETED && original !== null) {
      const code: number = original['code'] as number;
      if (code !== 10002 && code !== 10402) {
        return PendingResponseKind.ofCode(code);
      }
    }
    // 形状不符：说明不了结果，保持待确认（保守）。
    return PendingResponseKind.NO_RESULT;
  }

  // ------------------------------------------------------------------ 调用归属

  /** 在调用入口（任何异步等待之前）固定调用归属（R2-01）。 */
  private bind(op: ApiOperation): CallContext {
    this.callSequence++;
    const ctx: CallContext = new CallContext(this.callSequence);
    const allowed: boolean = this.credentialsAllowed();
    const access: string | null = allowed ? this.deps.tokens.accessToken() : null;
    const endpoints: EnvironmentEndpoints | undefined = this.deps.context.endpoints();
    ctx.credentialsAllowed = allowed;
    ctx.privacy = RequestHeaderPolicy.normalizePrivacy(this.deps.context.privacy());
    ctx.apiBase = endpoints === undefined ? '' : endpoints.apiBase;
    ctx.epoch = this.epoch;
    ctx.generation = this.sessionGeneration;
    ctx.loginSerial = this.loginSerial;
    ctx.account = access !== null ? this.deps.tokens.account() : null;
    ctx.bound = access !== null && op.auth !== 'none';
    return ctx;
  }

  /**
   * 调用归属是否还有效（所有自动续发路径与响应处理共用的同一套核对，lessons 30、34）。返回 null 表示有效；否则返回
   * 结束旧调用的本地原因：撤回同意 / 隐私或凭据状态变化 / 切换环境 → cancelled；登录、退出、换账号、会话世代结束
   * → session_changed。不带令牌的调用（登录、刷新、匿名白名单）不随刷新失败清会话结束，但出现了别的账号的会话、
   * 或登录序号变了，同样结束（不改绑到新会话，lessons 23）。
   */
  private ownershipLost(ctx: CallContext): string | null {
    if (ctx.epoch !== this.epoch || !ApiClient.ownerValid(ctx)) {
      return LocalRejectReason.CANCELLED;
    }
    const allowed: boolean = this.credentialsAllowed();
    if (allowed !== ctx.credentialsAllowed
      || RequestHeaderPolicy.normalizePrivacy(this.deps.context.privacy()) !== ctx.privacy) {
      return LocalRejectReason.CANCELLED;
    }
    const endpoints: EnvironmentEndpoints | undefined = this.deps.context.endpoints();
    if ((endpoints === undefined ? '' : endpoints.apiBase) !== ctx.apiBase) {
      return LocalRejectReason.CANCELLED;
    }
    if (ctx.loginSerial !== this.loginSerial) {
      return LocalRejectReason.SESSION_CHANGED;
    }
    const account: string | null = allowed && this.deps.tokens.accessToken() !== null ? this.deps.tokens.account() :
      null;
    if (ctx.bound) {
      if (ctx.generation !== this.sessionGeneration && ctx.generation === this.clearedGeneration
        && this.clearedOutcome !== null && account === null) {
        // 这个世代因刷新明确失败被清掉，之后没有新会话：复用那次失败的结论（lessons 37）。
        return LocalRejectReason.SESSION_CLEARED;
      }
      if (ctx.generation !== this.sessionGeneration || (allowed && account !== ctx.account)) {
        return LocalRejectReason.SESSION_CHANGED;
      }
    } else if (account !== null && account !== ctx.account) {
      return LocalRejectReason.SESSION_CHANGED;
    }
    return null;
  }

  /** 把传输层发出前的核对结果交给调用方的写出观察（ApiRequest.onAdmit；观察方出错不影响发送）。 */
  private static observeAdmit(request: ApiRequest, admitted: boolean): boolean {
    const observe: ((admitted: boolean) => void) | null = request.onAdmit;
    if (observe !== null) {
      try {
        observe(admitted);
      } catch (e) {
        // 观察方出错不影响发送判定。
      }
    }
    return admitted;
  }

  /** 调用方的发送闸门此刻放行（没有闸门为放行；闸门抛错按不放行）。 */
  private static sendPermitted(ctx: CallContext): boolean {
    const gate: (() => boolean) | null = ctx.sendAllowed;
    if (gate === null) {
      return true;
    }
    try {
      return gate();
    } catch (e) {
      return false;
    }
  }

  /** 调用方的归属守卫仍成立（没有守卫为成立；守卫抛错按不成立）。 */
  private static ownerValid(ctx: CallContext): boolean {
    const owner: (() => boolean) | null = ctx.owner;
    if (owner === null) {
      return true;
    }
    try {
      return owner();
    } catch (e) {
      return false;
    }
  }

  // ------------------------------------------------------------------ 管线

  /** 一次逻辑调用：不抛出；结束时还停在本进程在途、且由本调用占用的未决记录统一结算（R1-05、lessons 26）。 */
  private async runCall(attempt: Attempt): Promise<ApiResult> {
    try {
      return await this.execute(attempt);
    } catch (e) {
      return ApiResult.rejected(LocalRejectReason.CANCELLED);
    } finally {
      const ctx: CallContext = attempt.ctx;
      const store: PendingKeyStore | null = this.deps.pendingKeys;
      if (ctx.pendingKey !== null && store !== null) {
        try {
          store.settleIfInFlight(ctx.pendingKey, ctx.pendingAccount, ctx.id);
        } catch (e) {
          // 存储出错：持久记录仍是在途，下次进程恢复时按结果未知处理。
        }
      }
    }
  }

  /** 发送前的全部判定与凭据（每次实际发送前都重新取：重试、重签、重放都不复用旧请求，lessons R1-01）。 */
  private prepare(op: ApiOperation, request: ApiRequest, fixedKey: string | null): Prepared {
    const allowed: boolean = this.credentialsAllowed();
    const accessToken: string | null = allowed ? this.deps.tokens.accessToken() : null;
    const deviceId: string | null = allowed ? this.deps.credentials.deviceId() : null;
    const scope: string = allowed && accessToken !== null ? this.deps.tokens.scope() : SessionScope.FULL;
    const endpoints: EnvironmentEndpoints | undefined = this.deps.context.endpoints();
    const state: NetworkRequestState = new NetworkRequestState(this.deps.context.privacy(), scope,
      accessToken !== null, deviceId, endpoints !== undefined, this.deps.context.credentialsReadable());
    const decision: HeaderDecision = RequestHeaderPolicy.decide(state, op);
    if (!decision.send || endpoints === undefined) {
      return Prepared.reject(decision.localRejectReason ?? LocalRejectReason.ENVIRONMENT_UNSETTLED);
    }
    if (allowed && op.auth !== 'none' && accessToken === null
      && this.deps.tokens.readStatus() === SessionReadStatus.UNREADABLE) {
      // 会话此刻读不出（不是没有会话）：需要会话的接口不当成游客匿名发出（APP-03b session_unreadable，三端统一裁定）。
      return Prepared.reject(LocalRejectReason.SESSION_UNREADABLE);
    }
    if (scope === SessionScope.DELETION_ONLY && !ApiClient.restrictedBodyAllowed(op.operationId, request.body)) {
      return Prepared.reject(LocalRejectReason.SESSION_SCOPE_BODY_DENIED);
    }
    const path: string | null = ApiClient.buildPath(op.pathTemplate, request.pathParams);
    if (path === null) {
      return Prepared.reject(LocalRejectReason.BAD_REQUEST);
    }
    const installSecret: string | null = decision.has(NetworkHeaders.SIGN) ? this.deps.credentials.installSecret() : null;
    if (decision.has(NetworkHeaders.SIGN) && (installSecret === null || installSecret.length === 0)) {
      return Prepared.reject(LocalRejectReason.DEVICE_NOT_READY);
    }
    const key: string | null = decision.has(NetworkHeaders.IDEMPOTENCY_KEY) ?
      (fixedKey ?? request.idempotencyKey ?? this.newIdempotencyKey()) : null;
    const pathWithQuery: string = request.query.length > 0 ? path + '?' + request.query : path;
    return new Prepared(null, decision, endpoints, accessToken, deviceId, installSecret, scope, pathWithQuery, key);
  }

  /**
   * 带会话的调用等在途的刷新屏障（R1-03、R2-01、R2-03）。按完整结论结算：刷新失败 → session_cleared；没有服务端结论 →
   * 网络错误；会话换了 → session_changed；都不发出原请求。旧世代的刷新（已与新会话脱钩）不影响新世代的调用。
   * 返回 null 表示可以继续发送。
   */
  private async awaitBarrier(ctx: CallContext): Promise<ApiResult | null> {
    for (let waits: number = 0; waits < ApiClient.LINEAGE_DEPTH && this.refreshRound !== null; waits++) {
      const round: RefreshRound = this.refreshRound as RefreshRound;
      round.callers.push(ctx);
      const outcome: RefreshOutcome = await round.promise;
      const lost: string | null = this.ownershipLost(ctx);
      if (lost === LocalRejectReason.CANCELLED) {
        return this.lostResult(lost);
      }
      if (round.generation !== ctx.generation || round.account !== ctx.account) {
        // 不是这个会话的刷新：它的结论与本调用无关，归属照常核对。
        if (lost !== null) {
          return this.lostResult(lost);
        }
        continue;
      }
      if (outcome.kind === RefreshOutcome.FAILED) {
        // 刷新失败、会话已清：原本要带会话的请求不再发出（不得带旧令牌，R1-03），按刷新失败的 Effect 收口。
        return ApiClient.sessionClearedResult(outcome);
      }
      if (lost !== null) {
        return this.lostResult(lost);
      }
      if (outcome.kind === RefreshOutcome.TRANSIENT) {
        // 没有服务端结论：会话保留，但这次调用结束，不带旧（受限）令牌发出（R2-03）。
        return new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, ApiClient.REFRESH_UNAVAILABLE, null,
          ApiClient.networkEffect(), null);
      }
      if (outcome.kind === RefreshOutcome.SESSION_CHANGED) {
        return ApiResult.rejected(LocalRejectReason.SESSION_CHANGED);
      }
    }
    return null;
  }

  /** 响应对应的未决结局（归属失效时按真实响应结算原账号的记录；10002 / 10402 不再重放 → 没有结果）。 */
  private static responseKind(response: TransportResponse): string {
    if (response.failure !== TransportFailure.NONE) {
      return PendingResponseKind.NO_ENVELOPE;
    }
    const envelope: Envelope | null = Envelope.parse(response.body);
    if (envelope === null) {
      return PendingResponseKind.NO_ENVELOPE;
    }
    if (envelope.code === 10002 || envelope.code === 10402) {
      return PendingResponseKind.NO_RESULT;
    }
    return PendingResponseKind.ofCode(envelope.code);
  }

  private async execute(attempt: Attempt): Promise<ApiResult> {
    const op: ApiOperation = attempt.operation;
    const request: ApiRequest = attempt.request;
    const ctx: CallContext = attempt.ctx;
    if (op.operationId !== ApiClient.REFRESH_OPERATION && ctx.bound) {
      const barrier: ApiResult | null = await this.awaitBarrier(ctx);
      if (barrier !== null) {
        return barrier;
      }
    }
    const initiallyLost: string | null = this.ownershipLost(ctx);
    if (initiallyLost !== null) {
      return this.lostResult(initiallyLost);
    }
    let prepared: Prepared = this.prepare(op, request, null);
    if (prepared.rejected !== null) {
      return ApiResult.rejected(prepared.rejected);
    }
    const key: string | null = prepared.key;
    // 四个 step-up 操作：账号必须来自调用入口绑定的可信会话（登录响应的 user_id）；未决记录写成功才发送
    // （lessons R1-11）。
    if (op.stepUp !== null) {
      const store: PendingKeyStore | null = this.deps.pendingKeys;
      const account: string | null = ctx.bound ? ctx.account : null;
      if (store === null || account === null || account.length === 0 || key === null) {
        return ApiResult.rejected(LocalRejectReason.ACCOUNT_UNKNOWN);
      }
      if (ctx.pendingAccount !== null && ctx.pendingAccount !== account) {
        return ApiResult.rejected(LocalRejectReason.ACCOUNT_MISMATCH);
      }
      let accepted: boolean = false;
      try {
        accepted = store.beforeSend(op.operationId, key, request.body ?? '', account, request.summary, ctx.id);
      } catch (e) {
        return ApiResult.rejected(LocalRejectReason.PENDING_STORE_FAILED);
      }
      if (!accepted) {
        return ApiResult.rejected(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      }
      ctx.pendingKey = key;
      ctx.pendingAccount = account;
    }
    const plan: RetryPlan = RetryPolicy.forOperation(op);
    const traceId: string = this.deps.random.uuid();
    let resigned: boolean = false;
    let lastKind: string = PendingResponseKind.NO_RESULT;
    let response: TransportResponse = TransportResponse.failed(TransportFailure.DISCONNECT);
    for (let sent: number = 0; ; sent++) {
      // 每次实际发送前（含 GET 重试、校时重签）都核对归属并重新组头、重新签名（lessons R1-01、25）。
      const lost: string | null = this.ownershipLost(ctx);
      if (lost !== null) {
        this.settle(ctx, lastKind);
        return this.lostResult(lost);
      }
      if (!ApiClient.sendPermitted(ctx)) {
        // 调用方的发送闸门（如订单 42901 共享限流）此刻不准发：退避、重签、重放之后同样不发（R2-01）。
        this.settle(ctx, lastKind);
        return ApiResult.rejected(LocalRejectReason.SEND_BLOCKED);
      }
      if (sent > 0) {
        prepared = this.prepare(op, request, key);
        if (prepared.rejected !== null) {
          this.settle(ctx, lastKind);
          return ApiResult.rejected(prepared.rejected);
        }
      }
      const endpoints: EnvironmentEndpoints = prepared.endpoints as EnvironmentEndpoints;
      attempt.sentDeviceId = prepared.deviceId;
      const headers: Record<string, string> = this.headers(prepared.decision as HeaderDecision, op, request,
        prepared.accessToken, prepared.deviceId, key, traceId);
      if (prepared.installSecret !== null) {
        this.sign(headers, op.method, prepared.pathWithQuery, request.body ?? '', prepared.installSecret);
      }
      // APP-09 共性第 62 条：传输层最终核对（admit）被发送闸门拒绝时，当场记下这个明确原因；响应回来后按它结算为 SEND_BLOCKED，
      // 不用回调时刻的闸门状态反推（拒绝之后、结果交回之前禁用期可能已经到期）。
      const admitBlocked: boolean[] = [];
      response = await this.send(new TransportRequest(op.method, endpoints.apiBase + prepared.pathWithQuery, headers,
        request.body, plan.timeoutMillis, (): boolean => {
          const owned: boolean = this.ownershipLost(ctx) === null;
          const permitted: boolean = owned && ApiClient.sendPermitted(ctx);
          if (owned && !permitted) {
            admitBlocked.push(true);
          }
          return ApiClient.observeAdmit(request, permitted);
        }),
        ctx.owner);
      const afterSend: string | null = this.ownershipLost(ctx);
      if (afterSend !== null) {
        // 撤回同意、切换环境、换了会话：旧响应不改动当前会话（不保存登录令牌、不清会话、不刷新、不重试，lessons 23、34），
        // 未决记录按真实响应结算到原账号。
        this.settle(ctx, ApiClient.responseKind(response));
        return this.lostResult(afterSend);
      }
      if (response.failure === TransportFailure.CANCELLED && admitBlocked.length > 0) {
        // 传输层交出前的最后核对（admit）被发送闸门拦下：没有发出（R2-01）。按拒绝当时记下的原因结算（共性第 62 条）。
        this.settle(ctx, lastKind);
        return ApiResult.rejected(LocalRejectReason.SEND_BLOCKED);
      }
      if (response.failure === TransportFailure.NONE) {
        this.observeServerDate(response.headers);
        const envelope: Envelope | null = Envelope.parse(response.body);
        if (envelope !== null && envelope.code === 10401 && prepared.installSecret !== null && !resigned
          && this.adjustClock(response.headers)) {
          // BR-ID-09：校时后用新的 X-Timestamp 与 X-Nonce 重签再发 1 次（不是重放原签名）。
          resigned = true;
          lastKind = PendingResponseKind.NO_RESULT;
          continue;
        }
        break;
      }
      if (sent >= plan.autoRetries || response.failure === TransportFailure.CANCELLED) {
        break;
      }
      lastKind = PendingResponseKind.NO_ENVELOPE;
      await this.deps.timer.delay(plan.backoffMillis);
    }

    if (response.failure !== TransportFailure.NONE) {
      this.settle(ctx, PendingResponseKind.NO_ENVELOPE);
      return new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, traceId, 0, response.failure, null,
        ApiClient.networkEffect(), key);
    }
    if (response.status === 304 && request.ifNoneMatch !== null && op.method === 'GET') {
      // 条件请求的 304（03 §4.3）：内容没变，没有外壳。
      this.settle(ctx, PendingResponseKind.NO_RESULT);
      const notModified: ApiResult = new ApiResult(ApiOutcome.NOT_MODIFIED, -1, '', {}, traceId, response.status,
        TransportFailure.NONE, null, null, key);
      notModified.etag = ApiClient.headerValue(response.headers, 'etag');
      return notModified;
    }
    const envelope: Envelope | null = Envelope.parse(response.body);
    if (envelope === null) {
      this.settle(ctx, PendingResponseKind.NO_ENVELOPE);
      return new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, traceId, response.status, 'no_envelope', null,
        ApiClient.networkEffect(), key);
    }
    const responseTrace: string = envelope.traceId.length > 0 ? envelope.traceId : traceId;
    if (envelope.code === 0) {
      this.settle(ctx, PendingResponseKind.SUCCESS);
      const notSaved: string | null = attempt.internalRefresh ? null :
        this.onSuccess(op, envelope.data, prepared.accessToken);
      if (notSaved !== null) {
        // 登录响应缺令牌（invalid_session_tokens）或令牌没能保存（session_save_failed，lessons 40）：不返回登录成功
        // （harmony-review-r2 R2-03、lessons 19）。
        return ApiResult.rejected(notSaved);
      }
      const success: ApiResult = new ApiResult(ApiOutcome.SUCCESS, 0, envelope.msg, envelope.data, responseTrace,
        response.status, TransportFailure.NONE, null, null, key);
      success.etag = ApiClient.headerValue(response.headers, 'etag');
      return success;
    }
    const effect: ErrorEffect = ApiClient.unknownKeyEffect(ctx, envelope.code,
      ErrorActionMapper.map(new ErrorActionInput(envelope.code, envelope.data, op, response.headers, attempt.isReplay,
        this.errorState(prepared.scope), request.fromProductCard)));
    // 只有网络层确实要沿用原键自动重放时，未决记录才保持在途（且仍由本调用占用）；否则这次没有业务结果（R1-05）。
    const willReplay: boolean = !attempt.internalRefresh && (effect.effectKindRaw === EffectKind.REFRESH_REPLAY
      || effect.effectKindRaw === EffectKind.REGISTER_DEVICE_REPLAY);
    const replayCode: boolean = envelope.code === 10002 || envelope.code === 10402;
    this.settle(ctx, willReplay || !replayCode ? PendingResponseKind.ofCode(envelope.code) :
    PendingResponseKind.NO_RESULT);
    const failed: ApiResult = new ApiResult(ApiOutcome.BUSINESS_ERROR, envelope.code, envelope.msg, envelope.data,
      responseTrace, response.status, TransportFailure.NONE, null, effect, key);
    if (envelope.code === 10402 && !attempt.internalRefresh
      && effect.effectKindRaw !== EffectKind.REGISTER_DEVICE_REPLAY && this.ownershipLost(ctx) === null) {
      // 有效世代的 10402 一律隔离这次所用的凭据，重放里再收到也一样（F-ALL-08 / 共性 25）；走重新注册的那条由
      // reregister 自己隔离，刷新请求的 10402 在 performRefresh 里处理。
      try {
        this.deps.deviceRegistrar.isolate(prepared.deviceId);
      } catch (e) {
        // 凭据源出错不影响本次结果。
      }
    }
    if (attempt.internalRefresh) {
      return failed;
    }
    return this.applyEffect(attempt, effect, failed, key, prepared.carriesToken ? prepared.accessToken : null,
      prepared.deviceId);
  }

  /**
   * 归属失效的结束结果。session_cleared（本世代因刷新失败被清，lessons 37）复用那次刷新失败的结论：同一个会话级
   * Effect，不再刷新、不再清会话；其余为本地拒绝。
   */
  private lostResult(reason: string): ApiResult {
    if (reason === LocalRejectReason.SESSION_CLEARED && this.clearedOutcome !== null) {
      return ApiClient.sessionClearedResult(this.clearedOutcome);
    }
    return ApiResult.rejected(reason);
  }

  /** 未决记录结算（绑定原账号与本调用标识，R1-02、lessons 26）。 */
  private settle(ctx: CallContext, kind: string): void {
    const store: PendingKeyStore | null = this.deps.pendingKeys;
    if (store !== null && ctx.pendingKey !== null) {
      try {
        store.onResponse(ctx.pendingKey, kind, ctx.pendingAccount, ctx.id);
      } catch (e) {
        // 存储出错：逻辑调用结束时 settleIfInFlight 再兜一次。
      }
    }
  }

  /**
   * 执行 mapper 给出的、网络层自己完成的动作（刷新重放、重新注册重放、强更、清会话）。每个异步等待之后、每个会话级
   * 副作用之前都核对调用归属（R2-08，lessons 30、34）。
   */
  private async applyEffect(attempt: Attempt, effect: ErrorEffect, failed: ApiResult, key: string | null,
    usedToken: string | null, usedDeviceId: string | null): Promise<ApiResult> {
    const op: ApiOperation = attempt.operation;
    const ctx: CallContext = attempt.ctx;
    switch (effect.effectKindRaw) {
      case EffectKind.REFRESH_REPLAY: {
        const outcome: RefreshOutcome = await this.singleFlightRefresh(usedToken, ctx);
        const lost: string | null = this.ownershipLost(ctx);
        if (lost === LocalRejectReason.CANCELLED) {
          this.settle(ctx, PendingResponseKind.NO_RESULT);
          return this.lostResult(lost);
        }
        if (outcome.kind === RefreshOutcome.OK && lost === null) {
          return this.execute(new Attempt(ApiClient.sameKey(attempt.request, key), op, true, false, ctx));
        }
        this.settle(ctx, PendingResponseKind.NO_RESULT);
        if (outcome.kind === RefreshOutcome.FAILED || outcome.kind === RefreshOutcome.TRANSIENT) {
          return this.withRefreshFailure(failed, outcome);
        }
        // 令牌已属于另一个会话 / 账号：不替它重放（R1-01）。
        return this.lostResult(lost ?? LocalRejectReason.SESSION_CHANGED);
      }
      case EffectKind.REGISTER_DEVICE_REPLAY: {
        if (op.operationId === ApiClient.REGISTER_DEVICE_OPERATION) {
          // 注册请求自己不会带被吊销的 device_id；万一收到 10402 也不再触发重新注册（否则会等自己这次注册，单飞死锁）。
          this.settle(ctx, PendingResponseKind.NO_RESULT);
          return this.withEffect(failed,
            new ErrorEffect(EffectKind.GENERIC_ERROR, null, null, ReplayKind.NONE, false, 0, true));
        }
        let registered: boolean = false;
        try {
          // R3-03：调用方有效性一并传入（没有归属守卫的原生请求为 null = 独立调用方）。
          // F-HM-08（APP-04 共性 64）：共享的重新注册用它自己的请求超时；每个调用方各管自己的等待预算——这个调用方失效
          // （桥调用到期、页面离开，经 cancelOwned）就立即停止等待，不跟着共享注册等到底，也不把自己的截止时间加给它。
          const owner: (() => boolean) | null = ctx.owner;
          const shared: Promise<boolean> = this.deps.deviceRegistrar.reregister(usedDeviceId, owner);
          registered = owner === null ? await shared : ((await this.waitOwnedFlag(shared, owner)) ?? false);
        } catch (e) {
          registered = false;
        }
        const lost: string | null = this.ownershipLost(ctx);
        if (lost !== null) {
          this.settle(ctx, PendingResponseKind.NO_RESULT);
          return this.lostResult(lost);
        }
        if (!registered) {
          this.settle(ctx, PendingResponseKind.NO_RESULT);
          return this.withEffect(failed,
            new ErrorEffect(EffectKind.GENERIC_ERROR, null, null, ReplayKind.NONE, false, 0, true));
        }
        return this.execute(new Attempt(ApiClient.sameKey(attempt.request, key), op, true, false, ctx));
      }
      case EffectKind.FORCE_UPDATE:
        this.deps.update.on10405(ErrorActionMapper.minSupportedVersion(failed.data));
        return failed;
      case EffectKind.REFRESH_ONLY: {
        const outcome: RefreshOutcome = await this.singleFlightRefresh(usedToken, ctx);
        // 只刷新失败：结束原调用，清会话后跳登录（强更状态下停在强更页，lessons R1-09）。
        if (outcome.kind === RefreshOutcome.FAILED || outcome.kind === RefreshOutcome.TRANSIENT) {
          return this.withRefreshFailure(failed, outcome);
        }
        const lost: string | null = this.ownershipLost(ctx);
        return lost !== null ? this.lostResult(lost) : failed;
      }
      case EffectKind.CLEAR_SESSION_LOGIN: {
        // 10404：只清这个调用所属的会话；旧世代 / 别的账号的迟到响应不得清掉当前会话（R2-08）。
        const lost: string | null = this.ownershipLost(ctx);
        if (lost !== null) {
          return this.lostResult(lost);
        }
        let hadSession: boolean = false;
        try {
          hadSession = this.deps.tokens.accessToken() !== null || this.deps.tokens.refreshToken() !== null;
        } catch (e) {
          hadSession = true;
        }
        const clearedGeneration: number = this.sessionGeneration;
        try {
          this.deps.tokens.clear();
        } catch (e) {
          // 清不掉也要让旧世代失效；页面按 Effect 跳登录。
        }
        this.endSessionGeneration();
        this.syncPendingAccount();
        // F-HM-09（APP-05a 共性 18）：业务请求直接收到 10404 也是会话失效，和刷新失败一样交 App 的会话级回调——普通状态经
        // Router 打开 Login 并提示失效，强更状态停在 ForceUpdate（sessionFailureEffect 读这一刻的强更状态）。
        // 不靠发起页自己处理 Effect（搜索等页面不认识它）。登出请求回 10404 是用户自己在退出，不跳登录（LoginService 完成登出清理）。
        if (hadSession && op.operationId !== ApiClient.LOGOUT_OPERATION) {
          try {
            this.deps.sessionEffect(this.sessionFailureEffect(), clearedGeneration);
          } catch (e) {
            // App 的回调出错不影响本次结果。
          }
        }
        return failed;
      }
      default:
        return failed;
    }
  }

  /** 曾经结果未知的键（确认上一笔）收到非终结的 2xxxx（20903 除外）的页面动作文案键（lessons 39）。 */
  static readonly CANNOT_CONFIRM_TEXT: string = 'pending_confirm.cannot_confirm';

  /**
   * lessons 39：曾经结果未知的键收到非终结的 2xxxx（20903 除外）——键不能换（记录仍待确认），统一覆盖为页面动作
   * 「暂时确认不了」（pending_confirm.cannot_confirm），保留确认 / 放弃入口；不输出换新键重新提交、不重放。
   */
  private static unknownKeyEffect(ctx: CallContext, code: number, effect: ErrorEffect): ErrorEffect {
    if (!ctx.pendingEverUnknown || code < 20000 || code > 29999 || code === 20903) {
      return effect;
    }
    return new ErrorEffect(EffectKind.PAGE_ACTION, null, ApiClient.CANNOT_CONFIRM_TEXT, ReplayKind.NONE, false);
  }

  private withEffect(result: ApiResult, effect: ErrorEffect): ApiResult {
    return new ApiResult(result.outcome, result.code, result.msg, result.data, result.traceId, result.httpStatus,
      result.failure, result.localRejectReason, effect, result.idempotencyKey);
  }

  private withRefreshFailure(result: ApiResult, outcome: RefreshOutcome): ApiResult {
    const effect: ErrorEffect = outcome.kind === RefreshOutcome.FAILED && outcome.effect !== null ? outcome.effect :
    ApiClient.networkEffect();
    return new ApiResult(result.outcome, result.code, result.msg, result.data, result.traceId, result.httpStatus,
      outcome.cleanupFailed ? 'session_cleanup_failed' : result.failure, result.localRejectReason, effect,
      result.idempotencyKey);
  }

  /** 等待的刷新失败：请求没有发出，带刷新失败的会话级 Effect（R1-03）。 */
  private static sessionClearedResult(outcome: RefreshOutcome): ApiResult {
    return new ApiResult(ApiOutcome.LOCAL_REJECT, -1, '', {}, '', 0,
      outcome.cleanupFailed ? 'session_cleanup_failed' : TransportFailure.NONE, LocalRejectReason.SESSION_CLEARED,
      outcome.effect, null);
  }

  private static sameKey(request: ApiRequest, key: string | null): ApiRequest {
    const copy: ApiRequest = new ApiRequest(request.operationId, request.pathParams, request.query, request.body);
    copy.idempotencyKey = key;
    copy.stepUpToken = request.stepUpToken;
    copy.summary = request.summary;
    copy.fromProductCard = request.fromProductCard;
    copy.ifNoneMatch = request.ifNoneMatch;
    return copy;
  }

  private static networkEffect(): ErrorEffect {
    return new ErrorEffect(EffectKind.NETWORK_ERROR, null, null, ReplayKind.NONE, false);
  }

  /** 刷新失败的会话级 Effect：读这一刻的强更状态（R1-07）。 */
  private sessionFailureEffect(): ErrorEffect {
    let below: boolean = false;
    try {
      below = this.deps.update.state() === ErrorUpdateState.BELOW;
    } catch (e) {
      below = false;
    }
    const kind: string = below ? EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE : EffectKind.CLEAR_SESSION_LOGIN;
    return new ErrorEffect(kind, below ? null : 'Login', null, ReplayKind.NONE, false);
  }

  private errorState(scope: string): ErrorActionState {
    return new ErrorActionState(this.deps.update.state(), scope, this.deps.identity.appVersion);
  }

  /** 当前会话作用域（凭据不可读或没有会话为 full）。 */
  private currentScope(): string {
    return this.credentialsAllowed() && this.deps.tokens.accessToken() !== null ? this.deps.tokens.scope() :
    SessionScope.FULL;
  }

  /** 已同意隐私、撤回清理已完成：可以读、带凭据。 */
  private credentialsAllowed(): boolean {
    return RequestHeaderPolicy.normalizePrivacy(this.deps.context.privacy()) === NetworkPrivacy.FULL
      && this.deps.context.credentialsReadable();
  }

  /** 可信会话里的账号（凭据不可读时为 null）。 */
  private trustedAccount(): string | null {
    if (!this.credentialsAllowed() || this.deps.tokens.accessToken() === null) {
      return null;
    }
    const account: string | null = this.deps.tokens.account();
    return account !== null && account.length > 0 ? account : null;
  }

  /**
   * 旧世代失效：登录、退出、清会话、作废。在途的刷新与新会话脱钩（它仍按自己的快照结算等待它的旧调用），
   * 新世代的请求不再等它（R2-01）。
   */
  private endSessionGeneration(): void {
    this.sessionGeneration++;
    this.lineage = new Map<string, string>();
    this.restrictedChecked = false;
    if (this.refreshRound !== null) {
      this.refreshRound = null;
      this.refresher.detach();
    }
  }

  /** 未决记录跟随当前会话账号（登录、切换账号后；R1-02）。 */
  private syncPendingAccount(): void {
    const store: PendingKeyStore | null = this.deps.pendingKeys;
    if (store === null) {
      return;
    }
    try {
      const account: string | null = this.trustedAccount();
      if (account === null) {
        if (store.currentAccount !== null) {
          store.signOut();
        }
      } else if (store.currentAccount !== account) {
        store.restore(account);
      }
    } catch (e) {
      // 存储读不出：保持原状；确认与放弃仍会核对记录账号。
    }
  }

  private headers(decision: HeaderDecision, op: ApiOperation, request: ApiRequest, accessToken: string | null,
    deviceId: string | null, key: string | null, traceId: string): Record<string, string> {
    const identity: ApiAppIdentity = this.deps.identity;
    const headers: Record<string, string> = {};
    headers[NetworkHeaders.APP_ID] = identity.appId;
    headers[NetworkHeaders.PLATFORM] = identity.platform;
    headers[NetworkHeaders.APP_VERSION] = identity.appVersion;
    headers[NetworkHeaders.BUILD] = identity.build;
    headers[NetworkHeaders.CHANNEL] = identity.channel;
    headers[NetworkHeaders.TRACE_ID] = traceId;
    if (decision.has(NetworkHeaders.AUTHORIZATION) && accessToken !== null) {
      headers[NetworkHeaders.AUTHORIZATION] = 'Bearer ' + accessToken;
    }
    if (decision.has(NetworkHeaders.DEVICE_ID) && deviceId !== null) {
      headers[NetworkHeaders.DEVICE_ID] = deviceId;
    }
    if (key !== null) {
      headers[NetworkHeaders.IDEMPOTENCY_KEY] = key;
    }
    if (op.stepUp !== null && !decision.anonymous && request.stepUpToken !== null && request.stepUpToken.length > 0) {
      headers[NetworkHeaders.STEP_UP_TOKEN] = request.stepUpToken;
    }
    if (request.body !== null) {
      headers[NetworkHeaders.CONTENT_TYPE] = 'application/json';
    }
    if (request.ifNoneMatch !== null && request.ifNoneMatch.length > 0 && op.method === 'GET') {
      // ETag 是不透明字符串：原样发送（不拆引号、不去 W/ 前缀）。
      headers[NetworkHeaders.IF_NONE_MATCH] = request.ifNoneMatch;
    }
    return headers;
  }

  private sign(headers: Record<string, string>, method: string, pathWithQuery: string, body: string,
    installSecret: string): void {
    const timestamp: string = String(Math.floor(this.deps.clock() / 1000) + this.clockOffsetSeconds);
    const nonce: string = this.deps.random.nonce();
    headers[NetworkHeaders.TIMESTAMP] = timestamp;
    headers[NetworkHeaders.NONCE] = nonce;
    headers[NetworkHeaders.SIGN] = this.signer.sign(new SigningInput(method, pathWithQuery, body, timestamp, nonce),
      installSecret);
  }

  /** 响应头（名字不分大小写）；没有为 null。 */
  private static headerValue(headers: Record<string, string>, name: string): string | null {
    let value: string | null = null;
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === name) {
        value = headers[key];
      }
    }
    return value;
  }

  /**
   * 服务端校准后的「现在」（毫秒；BR-TEXT-11，APP-08 共性第 34 条）：最近一次响应的 Date 与本机相差超过 5 分钟时按它校准，否则就是
   * 本机时间。订单相对时间、缓存提示时间等展示用它做基准。
   */
  serverNow(): number {
    return this.deps.clock() + this.displayOffsetMillis;
  }

  /** 记下响应头 Date 的偏差（展示用；不足 5 分钟按 0）。 */
  private observeServerDate(headers: Record<string, string>): void {
    const date: string | null = ApiClient.headerValue(headers, 'date');
    if (date === null) {
      return;
    }
    const serverMillis: number = Date.parse(date);
    if (Number.isNaN(serverMillis)) {
      return;
    }
    const skew: number = serverMillis - this.deps.clock();
    this.displayOffsetMillis = Math.abs(skew) > ApiClient.CLOCK_SKEW_LIMIT_SECONDS * 1000 ? skew : 0;
  }

  /** 响应头 Date 与本机相差超过 300 秒时记下偏移并返回 true（BR-ID-09）。 */
  private adjustClock(headers: Record<string, string>): boolean {
    let date: string | null = null;
    for (const name of Object.keys(headers)) {
      if (name.toLowerCase() === 'date') {
        date = headers[name];
      }
    }
    if (date === null) {
      return false;
    }
    const serverMillis: number = Date.parse(date);
    if (Number.isNaN(serverMillis)) {
      return false;
    }
    const skew: number = Math.round((serverMillis - this.deps.clock()) / 1000);
    if (Math.abs(skew) <= ApiClient.CLOCK_SKEW_LIMIT_SECONDS) {
      return false;
    }
    this.clockOffsetSeconds = skew;
    return true;
  }

  /**
   * 发送并按计划超时（传输层自己也设了超时；这里再兜一层，open 8 秒即结束；超时后取消底层请求）。
   * 登记为在途：invalidate 时取消并以 cancelled 收口（lessons 22）。
   */
  private send(request: TransportRequest, owner: (() => boolean) | null = null): Promise<TransportResponse> {
    let abort: () => void = () => {
    };
    const aborted: Promise<TransportResponse> = new Promise<TransportResponse>(
      (resolve: (response: TransportResponse) => void) => {
        abort = () => resolve(TransportResponse.failed(TransportFailure.CANCELLED));
      });
    const entry: LiveRequest = new LiveRequest(request, abort, owner);
    this.live.add(entry);
    const timeout: Promise<TransportResponse> = this.deps.timer.delay(request.timeoutMillis)
      .then((): TransportResponse => {
        this.cancelQuietly(request);
        return TransportResponse.failed(TransportFailure.TIMEOUT);
      });
    let sent: Promise<TransportResponse>;
    try {
      sent = this.deps.transport.send(request)
        .catch((): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT));
    } catch (e) {
      sent = Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
    }
    return Promise.race([sent, timeout, aborted]).then((response: TransportResponse): TransportResponse => {
      this.live.delete(entry);
      return response;
    });
  }

  private cancelQuietly(request: TransportRequest): void {
    try {
      this.deps.transport.cancel(request);
    } catch (e) {
      // 传输层不得抛出。
    }
  }

  // ------------------------------------------------------------------ 会话

  /**
   * 登录 / 刷新成功：保存令牌并记下作用域；强更检查未知时拿到 deletion_only → 按低于处理（强更状态取这一刻的值，
   * lessons 28）。调用方已核对调用归属（旧世代、撤回同意、切换环境之后到达的登录响应不会走到这里，lessons 23）。
   * 登录开始新的会话世代（旧世代的在途请求不再重放），未决记录切到新账号（R1-01、R1-02）。
   * 返回 null = 成功（或不是签发会话的操作）；否则返回不算登录成功的本地原因（harmony-review-r2 R2-03、lessons 19，
   * 三端同名）：登录响应缺 data.tokens 或其中的 access_token / refresh_token → invalid_session_tokens（当前会话原样保留，
   * 不结束会话世代）；令牌写不进安全存储 → session_save_failed。页面直接调刷新接口时缺令牌按原样返回（与 Android 一致）。
   */
  private onSuccess(op: ApiOperation, data: Record<string, Object>, usedAccess: string | null): string | null {
    if (ApiClient.SESSION_ISSUING.indexOf(op.operationId) < 0) {
      return null;
    }
    // 登录：data = LoginData（令牌在 data.tokens，账号为 data.user_id）；刷新：data = TokenPair。
    const login: boolean = op.operationId !== ApiClient.REFRESH_OPERATION;
    let pair: Record<string, Object> = data;
    let account: string | null = null;
    if (login) {
      const tokens: Object | undefined = data['tokens'];
      const userId: Object | undefined = data['user_id'];
      if (tokens === undefined || tokens === null || typeof tokens !== 'object' || Array.isArray(tokens)) {
        return LocalRejectReason.INVALID_SESSION_TOKENS;
      }
      pair = tokens as Record<string, Object>;
      account = typeof userId === 'string' ? userId as string : null;
    }
    const set: SessionTokenSet | null = ApiClient.tokenSet(pair, account);
    if (set === null) {
      return login ? LocalRejectReason.INVALID_SESSION_TOKENS : null;
    }
    const previous: string | null = this.deps.tokens.accessToken();
    if (login) {
      this.loginSerial++;
      this.endSessionGeneration();
    }
    try {
      this.deps.tokens.save(set);
    } catch (e) {
      // 令牌写不进安全存储（lessons 40）：不算登录 / 刷新成功；登录已让旧世代失效，旧请求不会再被重放。
      return LocalRejectReason.SESSION_SAVE_FAILED;
    }
    this.failedAccessToken = null;
    // 新登录或刷新拿到的作用域是服务端当下的结论：不需要再做受限会话屏障。
    this.restrictedChecked = true;
    if (login) {
      this.syncPendingAccount();
    } else if (previous !== null) {
      this.lineage.set(previous, set.accessToken);
    } else if (usedAccess !== null) {
      this.lineage.set(usedAccess, set.accessToken);
    }
    this.restrictedScopeIssued(set.scope);
    return null;
  }

  /**
   * 03 §4.2：强更检查结果未知期间拿到 deletion_only，说明本机版本已低于最低支持版本：按「低于」处理（调用 Update 进入
   * 强更），并同步记下，之后强更状态恢复为「不低于」时重新做受限会话刷新（R2-02）。强更状态取这一刻的值（lessons 28）。
   */
  private restrictedScopeIssued(scope: string): void {
    if (scope !== SessionScope.DELETION_ONLY) {
      return;
    }
    let state: string = ErrorUpdateState.UNKNOWN;
    try {
      state = this.deps.update.state();
    } catch (e) {
      state = ErrorUpdateState.UNKNOWN;
    }
    if (state === ErrorUpdateState.UNKNOWN) {
      this.treatedAsBelow = true;
      this.lastUpdateState = ErrorUpdateState.BELOW;
      this.deps.update.on10405(null);
    } else if (state === ErrorUpdateState.BELOW) {
      this.lastUpdateState = ErrorUpdateState.BELOW;
    }
  }

  private static tokenSet(pair: Record<string, Object>, account: string | null): SessionTokenSet | null {
    const access: Object | undefined = pair['access_token'];
    const refresh: Object | undefined = pair['refresh_token'];
    const scope: Object | undefined = pair['session_scope'];
    if (typeof access !== 'string' || typeof refresh !== 'string' || (access as string).length === 0
      || (refresh as string).length === 0) {
      return null;
    }
    const scopeRaw: string = scope === SessionScope.DELETION_ONLY ? SessionScope.DELETION_ONLY : SessionScope.FULL;
    return new SessionTokenSet(access as string, refresh as string, scopeRaw, account);
  }

  /**
   * 看强更状态（R1-06、R2-02）：由「低于」或「未知」恢复为「不低于」时，受限会话要重新做刷新屏障。
   * 只在恢复为 supported 时触发（未知期间按「低于」处理的会话不在未知期间刷新，免得反复拿到 deletion_only）。
   */
  private observeUpdateState(): void {
    let now: string = ErrorUpdateState.UNKNOWN;
    try {
      now = this.deps.update.state();
    } catch (e) {
      return;
    }
    if (this.lastUpdateState !== null && this.lastUpdateState !== ErrorUpdateState.SUPPORTED
      && now === ErrorUpdateState.SUPPORTED) {
      this.restrictedChecked = false;
      this.treatedAsBelow = false;
    }
    this.lastUpdateState = now;
  }

  /**
   * 03 §4.2「受限会话」：冷启动时、强更状态恢复为「不低于」时，本机会话是 deletion_only 的先单飞刷新令牌，
   * 再发其他带令牌的请求（R1-06）。强更状态「低于」（或未知期间已按低于处理）时不刷新（停在强更页，恢复后再做）；
   * 环境未就绪不发。
   */
  private ensureRestrictedBarrier(caller: CallContext | null = null): void {
    if (this.restrictedChecked || this.refreshRound !== null || !this.credentialsAllowed()) {
      return;
    }
    const access: string | null = this.deps.tokens.accessToken();
    if (access === null || this.deps.tokens.scope() !== SessionScope.DELETION_ONLY) {
      return;
    }
    const state: string = this.deps.update.state();
    if (state === ErrorUpdateState.BELOW || (this.treatedAsBelow && state !== ErrorUpdateState.SUPPORTED)
      || this.deps.context.endpoints() === undefined) {
      return;
    }
    this.restrictedChecked = true;
    this.startRefresh(access, caller).then((outcome: RefreshOutcome): void => {
      if (outcome.kind === RefreshOutcome.TRANSIENT) {
        // 没有服务端结论：下一个请求再做一次屏障。
        this.restrictedChecked = false;
      }
    });
  }

  /**
   * 收到 10002（或 10405 遗留受限令牌）时取刷新结论。令牌世代检查、复用已完成结果、入队在同一个同步区内完成：
   * - 这个调用的归属已经失效（登录、退出、换账号、撤回同意、切换环境）→ session_changed，不重放（R1-01）；
   * - 有本会话的刷新在途 → 等同一个屏障；
   * - 当前令牌已不是这次用的令牌：只有它是这次令牌经本客户端刷新得到的（同世代的令牌世系）才复用；否则 session_changed；
   * - 同一旧令牌的刷新已明确失败 → 不再刷新、不再清会话；
   * - 否则发起单飞刷新。
   */
  private singleFlightRefresh(usedToken: string | null, ctx: CallContext): Promise<RefreshOutcome> {
    if (this.ownershipLost(ctx) !== null) {
      return Promise.resolve(RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED));
    }
    const round: RefreshRound | null = this.refreshRound;
    if (round !== null) {
      round.callers.push(ctx);
      return round.promise;
    }
    const current: string | null = this.credentialsAllowed() ? this.deps.tokens.accessToken() : null;
    if (usedToken !== null && current !== null && current !== usedToken) {
      return Promise.resolve(this.descends(usedToken, current) ? RefreshOutcome.ok(current) :
      RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED));
    }
    if (usedToken !== null && usedToken === this.failedAccessToken) {
      return Promise.resolve(new RefreshOutcome(RefreshOutcome.FAILED, null, this.sessionFailureEffect()));
    }
    if (usedToken !== null && current === null) {
      // 会话已被清掉（退出、撤回同意）：不再刷新，也不替别的会话重放。
      return Promise.resolve(RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED));
    }
    return this.startRefresh(current, ctx);
  }

  /**
   * 这一轮刷新还有没有有效的调用方（共性 41）：App 自己发起的一轮总是有；否则至少一个登记的调用方仍属于当前作废世代、
   * 归属守卫（ApiRequest.owner，如桥调用的有效性）仍成立。都失效了就不再续发（刷新请求、校时重签、10402 重新注册与重放）。
   */
  private roundHasLiveCaller(round: RefreshRound): boolean {
    if (round.system) {
      return true;
    }
    for (const caller of round.callers) {
      if (caller.epoch === this.epoch && ApiClient.ownerValid(caller)) {
        return true;
      }
    }
    return false;
  }

  /** to 是 from 在本世代里经本客户端刷新（一次或多次）得到的令牌。 */
  private descends(from: string, to: string): boolean {
    let cursor: string = from;
    for (let i: number = 0; i < ApiClient.LINEAGE_DEPTH; i++) {
      const next: string | undefined = this.lineage.get(cursor);
      if (next === undefined) {
        return false;
      }
      if (next === to) {
        return true;
      }
      cursor = next;
    }
    return false;
  }

  /** 发起一轮单飞刷新（经 RefreshCoordinator 计数），返回屏障。账号、世代与令牌快照在这里固定（lessons 24）。 */
  private startRefresh(usedAccess: string | null, caller: CallContext | null = null): Promise<RefreshOutcome> {
    const allowed: boolean = this.credentialsAllowed();
    const round: RefreshRound = new RefreshRound(usedAccess, allowed ? this.deps.tokens.refreshToken() : null,
      allowed ? this.deps.tokens.account() : null, this.sessionGeneration, this.epoch, allowed);
    if (caller === null) {
      round.system = true;
    } else {
      round.callers.push(caller);
    }
    this.refreshRound = round;
    this.sequence++;
    const operation: ApiOperation = ApiOperations.byId(ApiClient.REFRESH_OPERATION) as ApiOperation;
    if (this.refresher.refreshing) {
      // 协调器还停在上一轮（不应发生）：不排进去等一个不会来的结论。
      this.finishRound(round, RefreshOutcome.of(RefreshOutcome.TRANSIENT));
      return round.promise;
    }
    try {
      this.refresher.run([new RefreshRequest('refresh-round-' + this.sequence, operation, '', '')],
        this.deps.update.state() === ErrorUpdateState.BELOW);
    } catch (e) {
      this.finishRound(round, RefreshOutcome.of(RefreshOutcome.TRANSIENT));
    }
    return round.promise;
  }

  /** RefreshCoordinator 的 refresh 回调：执行刷新请求，再走完成流程。 */
  private runRefreshRound(completion: RefreshCompletion): void {
    const round: RefreshRound | null = this.refreshRound;
    if (round === null) {
      completion(null);
      return;
    }
    let work: Promise<RefreshOutcome>;
    try {
      work = this.performRefresh(round);
    } catch (e) {
      work = Promise.resolve(RefreshOutcome.of(RefreshOutcome.TRANSIENT));
    }
    work.catch((): RefreshOutcome => RefreshOutcome.of(RefreshOutcome.TRANSIENT))
      .then((outcome: RefreshOutcome): void => {
        try {
          completion(outcome.kind === RefreshOutcome.OK ? outcome.token : null);
        } catch (e) {
          // 协调器回调出错不影响结算。
        }
        this.finishRound(round, outcome);
      });
  }

  /**
   * 刷新的完成流程（R1-03、R1-04、R1-07）：明确失败时先记下失败令牌并清会话（清理出错转成 cleanupFailed）、结束会话世代，
   * 再按这一刻的强更状态定下会话级 Effect 并通知 App（通知出错不影响）；最后（finally）解除屏障并把同一个结论交给
   * 全部等待者——每个等待者只结算一次。
   */
  private finishRound(round: RefreshRound, outcome: RefreshOutcome): void {
    if (round.settled) {
      return;
    }
    round.settled = true;
    let result: RefreshOutcome = outcome;
    try {
      if (outcome.kind === RefreshOutcome.FAILED && this.refreshStale(round)) {
        // harmony-review-r3 R3-02：结论定下之后、清会话之前（同步区内）会话已换（登录、退出、撤回同意、切换环境）：
        // 这轮按 session_changed 结算等待者，不清当前会话、不发会话级 Effect。
        result = RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED);
      } else if (outcome.kind === RefreshOutcome.FAILED) {
        this.failedAccessToken = round.usedAccess;
        const clearedGeneration: number = this.sessionGeneration;
        let cleanupFailed: boolean = false;
        try {
          this.deps.tokens.clear();
        } catch (e) {
          cleanupFailed = true;
        }
        this.endSessionGeneration();
        this.syncPendingAccount();
        const effect: ErrorEffect = this.sessionFailureEffect();
        result = new RefreshOutcome(RefreshOutcome.FAILED, null, effect, cleanupFailed);
        this.clearedGeneration = round.generation;
        this.clearedOutcome = result;
        try {
          // 03 §4.2：刷新失败清会话并跳登录；强更状态下只清会话、停在 ForceUpdate（每次刷新失败一次）。
          this.deps.sessionEffect(effect, clearedGeneration);
        } catch (e) {
          // App 的回调出错不影响等待者结算。
        }
      }
    } catch (e) {
      result = new RefreshOutcome(RefreshOutcome.FAILED, null, this.sessionFailureEffect(), true);
    } finally {
      if (this.refreshRound === round) {
        this.refreshRound = null;
      }
      round.resolve(result);
    }
  }

  /**
   * POST /v1/auth/refresh（签名，不带 Authorization）。用入队时固定的快照（refresh_token、账号、世代，lessons 24）。
   * 成功保存新令牌对与作用域（账号取快照）；服务端拒绝（任何业务码）记为刷新失败；超时、断连、响应形状不对记为没有结论
   * （TODO(N-19)：传输失败是否也要清会话未规定，保守：不清会话，按网络错误收口）。
   * 结果晚于撤回同意、切换环境、登录、换账号或清会话到达（与快照不符）：丢弃，不把会话恢复回来（lessons R1-07）。
   */
  private async performRefresh(round: RefreshRound): Promise<RefreshOutcome> {
    if (!round.credentialsAllowed) {
      return RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED);
    }
    const refreshToken: string | null = round.refreshToken;
    if (refreshToken === null) {
      // 会话此刻读不出（session_unreadable）不是「刷新被拒」：没有结论，不清会话。
      return this.deps.tokens.readStatus() === SessionReadStatus.UNREADABLE ? RefreshOutcome.of(RefreshOutcome.TRANSIENT) :
      RefreshOutcome.of(RefreshOutcome.FAILED);
    }
    if (!this.roundHasLiveCaller(round)) {
      // 共性 41：调用方全部失效（页面关闭、桥调用作废）：不发刷新，也不清会话（没有结论）。
      return RefreshOutcome.of(RefreshOutcome.TRANSIENT);
    }
    const body: string = JSON.stringify(new RefreshBody(refreshToken));
    const operation: ApiOperation = ApiOperations.byId(ApiClient.REFRESH_OPERATION) as ApiOperation;
    const firstCtx: CallContext = this.bind(operation);
    // 刷新请求自己的归属守卫：每次实际发送（含 10401 校时重签）前都核对这一轮仍有有效调用方。同一个函数对象记在这一轮上，
    // 最后一个有效调用方到期时 cancelOwned 按它取消刷新传输（R1-11）。
    const roundOwner: () => boolean = (): boolean => this.roundHasLiveCaller(round);
    round.owner = roundOwner;
    firstCtx.owner = roundOwner;
    const first: Attempt = new Attempt(new ApiRequest(ApiClient.REFRESH_OPERATION, {}, '', body), operation, true, true,
      firstCtx);
    let result: ApiResult = await this.execute(first);
    if (this.refreshStale(round)) {
      return RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED);
    }
    if (ApiClient.isDeviceRejected(result)) {
      // R1-03（lessons 6）：刷新请求的 10402 是设备凭据被拒，不是刷新被拒——不清会话。走与普通请求同一个设备注册单飞入口
      // （DeviceRegistrar.reregister），成功后重新组头、用新凭据重新签名，沿用原键至多重放刷新 1 次。设备重放次数与令牌刷新
      // 互不相干：这里不再触发刷新，也不经 applyEffect（不会等自己这轮刷新）。
      if (!this.roundHasLiveCaller(round)) {
        // 没有有效调用方：不重新注册；被拒凭据仍隔离并交给唯一的退避链（R3-03，与 iOS、Android 一致）。
        try {
          this.deps.deviceRegistrar.isolate(first.sentDeviceId);
        } catch (e) {
          // 凭据源出错不影响结果。
        }
        return RefreshOutcome.of(RefreshOutcome.TRANSIENT);
      }
      let registered: boolean = false;
      try {
        // R3-03：共享刷新以这一轮的「还有有效调用方」作为调用方（App 自己发起的一轮为独立调用方）。
        registered = await this.deps.deviceRegistrar.reregister(first.sentDeviceId, round.system ? null : roundOwner);
      } catch (e) {
        registered = false;
      }
      if (this.refreshStale(round)) {
        return RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED);
      }
      if (!registered) {
        // 设备没注册上：会话有没有失效没有结论，保留会话（退避流程继续注册）。
        return RefreshOutcome.of(RefreshOutcome.TRANSIENT);
      }
      if (!this.roundHasLiveCaller(round)) {
        return RefreshOutcome.of(RefreshOutcome.TRANSIENT);
      }
      const replayCtx: CallContext = this.bind(operation);
      replayCtx.owner = roundOwner;
      const replay: Attempt = new Attempt(ApiClient.sameKey(first.request, result.idempotencyKey), operation, true,
        true, replayCtx);
      result = await this.execute(replay);
      if (this.refreshStale(round)) {
        return RefreshOutcome.of(RefreshOutcome.SESSION_CHANGED);
      }
      if (ApiClient.isDeviceRejected(result)) {
        // 重放仍是 10402：不再重新注册（BR-TEXT-14 表 A 按其他 5xxxx），同样不清会话；重放所用的凭据照样隔离，恢复交给
        // 退避链（F-ALL-08 / 共性 25）。
        try {
          this.deps.deviceRegistrar.isolate(replay.sentDeviceId);
        } catch (e) {
          // 凭据源出错不影响结果。
        }
        return RefreshOutcome.of(RefreshOutcome.TRANSIENT);
      }
    }
    if (result.ok) {
      const set: SessionTokenSet | null = ApiClient.tokenSet(result.data, round.account);
      if (set === null) {
        return RefreshOutcome.of(RefreshOutcome.TRANSIENT);
      }
      const scopeBefore: string = this.deps.tokens.scope();
      this.deps.tokens.save(set);
      this.failedAccessToken = null;
      this.restrictedChecked = true;
      if (round.usedAccess !== null) {
        this.lineage.set(round.usedAccess, set.accessToken);
      }
      this.restrictedScopeIssued(set.scope);
      if (scopeBefore !== set.scope) {
        // F-HM-08（APP-05a 共性 14）：作用域在异步刷新里变了，带世代通知 App 更新 Router。
        // F-HM-09（共性 19）：按这一轮的发起来源决定是否恢复待办（system = 冷启动 / 强更恢复的 App 级屏障）。
        try {
          const from: ((generation: number, scope: string, resumePending: boolean) => void) | null =
            this.deps.sessionRefreshedFrom;
          if (from !== null) {
            from(this.sessionGenerationId(), set.scope, round.system);
          } else {
            this.deps.sessionRefreshed(this.sessionGenerationId(), set.scope);
          }
        } catch (e) {
          // 通知方出错不影响刷新结果。
        }
      }
      return RefreshOutcome.ok(set.accessToken);
    }
    if (result.outcome === ApiOutcome.NETWORK_ERROR || result.outcome === ApiOutcome.LOCAL_REJECT) {
      return RefreshOutcome.of(RefreshOutcome.TRANSIENT);
    }
    return RefreshOutcome.of(RefreshOutcome.FAILED);
  }

  /** 服务端以 10402 拒绝了设备凭据。 */
  private static isDeviceRejected(result: ApiResult): boolean {
    return result.outcome === ApiOutcome.BUSINESS_ERROR && result.code === 10402;
  }

  /** 刷新结果与入队快照不符（作废、换世代、凭据不可读、令牌或账号已换）。 */
  private refreshStale(round: RefreshRound): boolean {
    return round.epoch !== this.epoch || round.generation !== this.sessionGeneration || !this.credentialsAllowed()
      || this.deps.tokens.refreshToken() !== round.refreshToken || this.deps.tokens.account() !== round.account;
  }

  // ------------------------------------------------------------------ 工具

  private newIdempotencyKey(): string {
    return this.deps.random.uuid();
  }

  /** 路径模板替换（参数值做 URL 编码）；缺参数返回 null。 */
  static buildPath(template: string, params: Record<string, string>): string | null {
    let missing: boolean = false;
    const path: string = template.replace(/\{([A-Za-z0-9_]+)\}/g, (_m: string, name: string): string => {
      const value: string | undefined = params[name];
      if (value === undefined || value.length === 0) {
        missing = true;
        return '';
      }
      return encodeURIComponent(value);
    });
    return missing ? null : path;
  }

  /**
   * 受限会话下「按请求体字段才接受」的接口（BR-ID-01 细则「受限会话」表）：
   * sms-codes / oauth-attempts 只接受 purpose=login，或 purpose=step_up 且 action=account_deletion；
   * step-up 与作废只接受 action=account_deletion；consents 只接受撤回（accepted=false）或 privacy、agreement 的记录。
   * 解析不了请求体按不满足（保守，本地拒绝）。
   */
  static restrictedBodyAllowed(operationId: string, body: string | null): boolean {
    const rules: string[] = ['sendSmsCode', 'createOauthAttempt', 'stepUp', ApiClient.ABANDON_OPERATION, 'recordConsent'];
    if (rules.indexOf(operationId) < 0) {
      return true;
    }
    let fields: Record<string, Object> = {};
    try {
      const parsed: Object | null = body === null ? null : JSON.parse(body) as Object | null;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return false;
      }
      fields = parsed as Record<string, Object>;
    } catch (e) {
      return false;
    }
    const purpose: Object | undefined = fields['purpose'];
    const action: Object | undefined = fields['action'];
    switch (operationId) {
      case 'sendSmsCode':
      case 'createOauthAttempt':
        return purpose === 'login' || (purpose === 'step_up' && action === 'account_deletion');
      case 'stepUp':
      case ApiClient.ABANDON_OPERATION:
        return action === 'account_deletion';
      default: {
        const accepted: Object | undefined = fields['accepted'];
        const type: Object | undefined = fields['type'];
        return accepted === false || type === 'privacy' || type === 'agreement';
      }
    }
  }
}

class RefreshBody {
  refresh_token: string;

  constructor(refreshToken: string) {
    this.refresh_token = refreshToken;
  }
}

class AbandonBody {
  action: string;
  idempotency_key: string;

  constructor(action: string, key: string) {
    this.action = action;
    this.idempotency_key = key;
  }
}
