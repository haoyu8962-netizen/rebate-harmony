import { ApiOperation } from 'generated';

/**
 * 请求发出前的纯判定（APP-03a；03 §4.1、§4.2，04 §5，BR-ID-01 细则「受限会话」、BR-ID-09、BR-ID-11）：
 * 发不发、带哪些头，以及传输重试与超时。实际头值、签名与发送在 ApiClient。三端同名，向量 specs/network-vectors.json。
 */

/** 请求头名（03 §4.2 公共请求头；04 §5）。 */
export class NetworkHeaders {
  static readonly AUTHORIZATION: string = 'Authorization';
  static readonly APP_ID: string = 'X-App-Id';
  static readonly PLATFORM: string = 'X-Platform';
  static readonly APP_VERSION: string = 'X-App-Version';
  static readonly BUILD: string = 'X-Build';
  static readonly DEVICE_ID: string = 'X-Device-Id';
  static readonly CHANNEL: string = 'X-Channel';
  static readonly TRACE_ID: string = 'X-Trace-Id';
  static readonly IDEMPOTENCY_KEY: string = 'Idempotency-Key';
  static readonly TIMESTAMP: string = 'X-Timestamp';
  static readonly NONCE: string = 'X-Nonce';
  static readonly SIGN: string = 'X-Sign';
  static readonly STEP_UP_TOKEN: string = 'X-Step-Up-Token';
  static readonly CONTENT_TYPE: string = 'Content-Type';
  /** 条件请求（03 §4.3：回前台带 ETag 拉 /v1/config；APP-03b）。 */
  static readonly IF_NONE_MATCH: string = 'If-None-Match';
  /** APP-12 G03：个性化推荐关闭（值 off）。 */
  static readonly PERSONALIZATION: string = 'X-Personalization';
  /** APP-10b G18：流式请求带 Accept: text/event-stream。 */
  static readonly ACCEPT: string = 'Accept';
  /** APP-10b G17：流式请求带 Accept-Encoding: identity（流不压缩）。 */
  static readonly ACCEPT_ENCODING: string = 'Accept-Encoding';
}

/** 本地拒绝的原因（不发出请求）。 */
export class LocalRejectReason {
  /** 环境闸门未 SETTLED（X-01）：不发任何请求。 */
  static readonly ENVIRONMENT_UNSETTLED: string = 'environment_unsettled';
  /** 基本模式（或首启尚未同意）下不在匿名白名单（BR-ID-11）。 */
  static readonly BASIC_MODE_DENIED: string = 'basic_mode_denied';
  /** deletion_only 会话下不在受限会话表（BR-ID-01 细则「受限会话」）。 */
  static readonly SESSION_SCOPE_DENIED: string = 'session_scope_denied';
  /** 需要 X-Device-Id 与签名的接口在设备注册成功前（或凭据不可读时）不可用（BR-ID-09）。 */
  static readonly DEVICE_NOT_READY: string = 'device_not_ready';
  /** operationId 不在契约里。 */
  static readonly UNKNOWN_OPERATION: string = 'unknown_operation';
  /** 受限会话下请求体不满足该接口的放行条件（BR-ID-01 细则「受限会话」表里「按请求体字段才接受」的几项）。 */
  static readonly SESSION_SCOPE_BODY_DENIED: string = 'session_scope_body_denied';
  /**
   * 四个 step-up 操作：同账号有结果未知的上一笔，或该键已在途（BR-ID-10 细则「敏感操作的幂等键」）。
   * 三端统一名（编排者裁定 2026-10-07；原名 pending_key_blocked）。
   */
  static readonly PENDING_KEY_UNRESOLVED: string = 'pending_key_unresolved';
  /** 撤回同意的清理未完成（凭据不可读）：与基本模式同一张匿名白名单（lessons R1-02）。 */
  static readonly CREDENTIALS_UNREADABLE: string = 'credentials_unreadable';
  /** 在途请求被作废（撤回同意、切换环境）。 */
  static readonly CANCELLED: string = 'cancelled';
  /** 四个 step-up 操作取不到可信会话里的账号（或没有未决键存储），不发送（lessons R1-11）。 */
  static readonly ACCOUNT_UNKNOWN: string = 'account_unknown';
  /**
   * 四个 step-up 操作的未决记录没能写入安全存储，不发送（R1-11：持久化成功是发送的前置条件）；或这个账号的未决状态
   * 确认不了——读取失败、记录损坏（恢复未完成）、终结记录删除失败（清理待重试），下次调用重试（harmony-review-r3
   * R3-01、R3-03，lessons 38）。
   */
  static readonly PENDING_STORE_FAILED: string = 'pending_store_failed';
  /** 未决记录属于别的账号：当前会话账号与记录或本调用绑定的账号不一致，不查、不发（lessons 15，R1-02）。 */
  static readonly ACCOUNT_MISMATCH: string = 'account_mismatch';
  /** 路径参数缺失。 */
  static readonly BAD_REQUEST: string = 'bad_request';
  /**
   * 调用方的发送闸门（ApiRequest.sendAllowed）此刻不准发：这次（含 GET 自动重试、10401 重签、刷新或重新注册后的重放）没有发出
   * （APP-08 harmony-review-r2 R2-01：订单 42901 共享限流在每次实际发包前拦截）。
   */
  static readonly SEND_BLOCKED: string = 'send_blocked';
  /**
   * 发出后会话换了（登录、退出、切换账号，或令牌已不属于这次请求的账号）：不替新会话重放或重试旧请求
   * （harmony-review-r1 R1-01、R1-02）。
   */
  static readonly SESSION_CHANGED: string = 'session_changed';
  /**
   * 等待的刷新失败、会话已清：这次请求没有发出，按刷新失败的会话级 Effect 收口（R1-03）。本世代因刷新失败被清之后
   * 晚到的 10002 也复用那次失败的结论返回本原因，不再刷新、不再清会话（lessons 37；与 session_changed 区分）。
   */
  static readonly SESSION_CLEARED: string = 'session_cleared';
  /**
   * 登录响应里的令牌没能写入安全存储：不算登录成功（lessons 40）。三端统一名（编排者裁定：鸿蒙原名 session_store_failed，
   * APP-03b 改名）。
   */
  static readonly SESSION_SAVE_FAILED: string = 'session_save_failed';
  /**
   * 登录响应 code=0 但缺 data.tokens，或其中缺 access_token / refresh_token：不算登录成功，当前会话原样保留
   * （harmony-review-r2 R2-03；三端统一名，APP-03a 名字对齐裁定）。与令牌写不进安全存储（session_save_failed）分开。
   */
  static readonly INVALID_SESSION_TOKENS: string = 'invalid_session_tokens';
  /**
   * 会话此刻读不出（安全存储读取失败；不是「没有会话」，也不是内容损坏）：需要会话的接口（x-auth 不为 none）本地拒绝，
   * 不当成游客匿名发出（编排者裁定 iOS 第 2 轮，三端统一名；APP-03b）。下次请求重新读取。
   */
  static readonly SESSION_UNREADABLE: string = 'session_unreadable';
}

/** 未决键的作废接口给出的结局（ApiResult.pendingResolution；harmony-review-r2 R2-04，lessons 27）。 */
export class PendingResolution {
  /** outcome=abandoned：键已作废，由用户用新键重新提交。 */
  static readonly ABANDONED: string = 'abandoned';
  /** outcome=completed：原请求其实已完成，结果按原操作解包（code / data / effect 是原结果）。 */
  static readonly COMPLETED: string = 'completed';
}

/** 隐私闸门在网络层的取值：full = 已同意当前隐私政策；basic = 基本模式；其余（首启尚未同意）按 not_decided。 */
export class NetworkPrivacy {
  static readonly FULL: string = 'full';
  static readonly BASIC: string = 'basic';
  static readonly NOT_DECIDED: string = 'not_decided';
}

/** 会话作用域（04 §2.5 session_scope）。 */
export class SessionScope {
  static readonly FULL: string = 'full';
  static readonly DELETION_ONLY: string = 'deletion_only';
}

/** 一次请求发出前的本机状态（全部取原始字符串，三端测试接线一致）。 */
export class NetworkRequestState {
  /** full / basic / not_decided。 */
  readonly privacy: string;
  /** full / deletion_only（无会话时 full）。 */
  readonly sessionScope: string;
  readonly hasAccessToken: boolean;
  /** 服务端签发的 device_id；未注册为 null。 */
  readonly deviceId: string | null;
  /** EnvironmentGate 为 SETTLED。 */
  readonly environmentSettled: boolean;
  /** 撤回同意的清理已完成、凭据可读（APP-02b credentialsReadable）。 */
  readonly credentialsReadable: boolean;

  constructor(privacy: string, sessionScope: string, hasAccessToken: boolean, deviceId: string | null,
    environmentSettled: boolean, credentialsReadable: boolean) {
    this.privacy = privacy;
    this.sessionScope = sessionScope;
    this.hasAccessToken = hasAccessToken;
    this.deviceId = deviceId;
    this.environmentSettled = environmentSettled;
    this.credentialsReadable = credentialsReadable;
  }
}

/** 判定结果：send=false 时 localRejectReason 说明原因、headerNames 为空。 */
export class HeaderDecision {
  readonly send: boolean;
  readonly localRejectReason: string | null;
  /** 要带的请求头名（值由 ApiClient 填）。X-Step-Up-Token 不在这里：只有调用方给了 token 才带（ApiClient）。 */
  readonly headerNames: string[];
  /** 带凭据（Authorization / X-Device-Id / 签名）——基本模式、凭据不可读时为 false。 */
  readonly anonymous: boolean;

  constructor(send: boolean, localRejectReason: string | null, headerNames: string[], anonymous: boolean) {
    this.send = send;
    this.localRejectReason = localRejectReason;
    this.headerNames = headerNames;
    this.anonymous = anonymous;
  }

  static reject(reason: string): HeaderDecision {
    return new HeaderDecision(false, reason, [], true);
  }

  has(name: string): boolean {
    return this.headerNames.indexOf(name) >= 0;
  }
}

/**
 * 发不发、带哪些头（03 §4.2 中间件「公共头 → 签名」之前的判定）。顺序：
 * ① 环境未 SETTLED → 不发；
 * ② 隐私：基本模式只放行 BR-ID-11 匿名白名单，且一律匿名（剥离 Authorization、X-Device-Id、签名头与任何设备标识）；
 *    首启尚未同意只放行配置（03 §4.1「只允许请求协议文本与配置」，协议文本先用包内副本）；
 * ③ 受限会话（deletion_only）只发 x-session-scopes 含 deletion_only 的接口（未标注按 [full]）；
 * ④ 凭据不可读（撤回清理未完成）→ 与基本模式同一张匿名白名单，不读不带凭据；需要签名的接口没有 device_id 或凭据不可读 → 不发（BR-ID-09）；
 * ⑤ 公共头；Authorization 只在 x-auth 不为 none、有令牌时带；写操作带 Idempotency-Key（作废接口例外）；
 *    x-signed 带 X-Timestamp / X-Nonce / X-Sign。
 */
export class RequestHeaderPolicy {
  /**
   * 基本模式匿名白名单（BR-ID-11 细则：首页、搜索、详情 + 帮助与规则文章 GET /v1/articles；配置）。
   * 首页（getPage、listPageSectionItems，FU-X-HOME-PAGE-API）已在白名单。TODO(N-19)：文章详情 getArticle 的基本模式用途（协议与帮助文章的类别）
   * 未表达，按路径前缀扩白名单会放宽，暂不放行（rule-gaps 第 2 条，保守）。
   */
  static readonly BASIC_MODE_ALLOWLIST: string[] = ['getConfig', 'searchProducts', 'getProduct', 'listArticles', 'getPage',
    'listPageSectionItems'];
  /** 首启尚未同意时只放行配置（03 §4.1）。TODO(N-19)：线上协议文本的 operation 待契约给出。 */
  static readonly UNDECIDED_ALLOWLIST: string[] = ['getConfig'];
  /**
   * 不带 Idempotency-Key 的写操作：作废接口（BR-ID-10 细则「作废接口」：原键放请求体）；Agent 的 5 个写 operation（契约 x-idempotent:false，
   * APP-10b brief §0 第 3 条：不带 Idempotency-Key；发送靠 client_msg_id 去重，反馈 / 举报不幂等）。
   */
  static readonly NO_IDEMPOTENCY_HEADER: string[] = ['abandonIdempotencyKey', 'createAgentSession', 'sendAgentMessage',
    'cancelAgentRun', 'setAgentMessageFeedback', 'reportAgentMessage'];

  static decide(state: NetworkRequestState, operation: ApiOperation): HeaderDecision {
    if (!state.environmentSettled) {
      return HeaderDecision.reject(LocalRejectReason.ENVIRONMENT_UNSETTLED);
    }
    const privacy: string = RequestHeaderPolicy.normalizePrivacy(state.privacy);
    if (privacy === NetworkPrivacy.BASIC
      && RequestHeaderPolicy.BASIC_MODE_ALLOWLIST.indexOf(operation.operationId) < 0) {
      return HeaderDecision.reject(LocalRejectReason.BASIC_MODE_DENIED);
    }
    if (privacy === NetworkPrivacy.NOT_DECIDED
      && RequestHeaderPolicy.UNDECIDED_ALLOWLIST.indexOf(operation.operationId) < 0) {
      return HeaderDecision.reject(LocalRejectReason.BASIC_MODE_DENIED);
    }
    if (privacy === NetworkPrivacy.FULL && !state.credentialsReadable
      && RequestHeaderPolicy.BASIC_MODE_ALLOWLIST.indexOf(operation.operationId) < 0) {
      // 撤回清理未完成：不只剥离请求头，白名单外（含请求体带设备标识的 registerDevice）一律本地拒绝。
      return HeaderDecision.reject(LocalRejectReason.CREDENTIALS_UNREADABLE);
    }
    if (state.sessionScope === SessionScope.DELETION_ONLY && !operation.acceptsScope(SessionScope.DELETION_ONLY)) {
      return HeaderDecision.reject(LocalRejectReason.SESSION_SCOPE_DENIED);
    }
    const anonymous: boolean = privacy !== NetworkPrivacy.FULL || !state.credentialsReadable;
    const deviceId: string | null = anonymous ? null : state.deviceId;
    if (operation.signed && (anonymous || deviceId === null || deviceId.length === 0)) {
      return HeaderDecision.reject(LocalRejectReason.DEVICE_NOT_READY);
    }
    const names: string[] = [NetworkHeaders.APP_ID, NetworkHeaders.PLATFORM, NetworkHeaders.APP_VERSION,
      NetworkHeaders.BUILD, NetworkHeaders.CHANNEL, NetworkHeaders.TRACE_ID];
    if (!anonymous && operation.auth !== 'none' && state.hasAccessToken) {
      names.push(NetworkHeaders.AUTHORIZATION);
    }
    if (deviceId !== null && deviceId.length > 0) {
      names.push(NetworkHeaders.DEVICE_ID);
    }
    if (operation.isWrite && RequestHeaderPolicy.NO_IDEMPOTENCY_HEADER.indexOf(operation.operationId) < 0) {
      names.push(NetworkHeaders.IDEMPOTENCY_KEY);
    }
    if (operation.signed) {
      names.push(NetworkHeaders.TIMESTAMP);
      names.push(NetworkHeaders.NONCE);
      names.push(NetworkHeaders.SIGN);
    }
    return new HeaderDecision(true, null, names, anonymous);
  }

  /** 'full' / 'consented' → full；'basic' / 'basic_mode' → basic；其余按首启尚未同意（最保守）。 */
  static normalizePrivacy(raw: string): string {
    if (raw === NetworkPrivacy.FULL || raw === 'consented') {
      return NetworkPrivacy.FULL;
    }
    if (raw === NetworkPrivacy.BASIC || raw === 'basic_mode') {
      return NetworkPrivacy.BASIC;
    }
    return NetworkPrivacy.NOT_DECIDED;
  }
}

/** 传输重试与超时（03 §4.2「超时、重试与弱网」，TECH-20、TRADE-22）。时间单位毫秒。 */
export class RetryPlan {
  /** 超时或断连后自动重发的次数（GET 1 次；写 0 次）。 */
  readonly autoRetries: number;
  /** 重发前的退避。 */
  readonly backoffMillis: number;
  /** 单次请求超时。 */
  readonly timeoutMillis: number;

  constructor(autoRetries: number, backoffMillis: number, timeoutMillis: number) {
    this.autoRetries = autoRetries;
    this.backoffMillis = backoffMillis;
    this.timeoutMillis = timeoutMillis;
  }
}

export class RetryPolicy {
  static readonly TIMEOUT_MILLIS: number = 10000;
  static readonly GET_RETRIES: number = 1;
  static readonly GET_BACKOFF_MILLIS: number = 500;
  /** POST /v1/links/{link_id}/open：8 秒即结束（03 §4.2 例外，TRADE-22）。 */
  static readonly OPEN_LINK_TIMEOUT_MILLIS: number = 8000;
  static readonly OPEN_LINK_PATH: string = '/v1/links/{link_id}/open';

  /**
   * 读接口超时 / 断连自动重试 1 次（退避 500 ms），写接口不自动重试。
   * TODO(N-19)：GET 收到无外壳的 HTTP 5xx 是否算「断连」未规定（rule-gaps 第 4 条）；ApiClient 只对超时与断连重试，保守。
   */
  static forOperation(operation: ApiOperation): RetryPlan {
    if (operation.method === 'POST' && operation.pathTemplate === RetryPolicy.OPEN_LINK_PATH) {
      return new RetryPlan(0, 0, RetryPolicy.OPEN_LINK_TIMEOUT_MILLIS);
    }
    if (operation.method === 'GET') {
      return new RetryPlan(RetryPolicy.GET_RETRIES, RetryPolicy.GET_BACKOFF_MILLIS, RetryPolicy.TIMEOUT_MILLIS);
    }
    return new RetryPlan(0, 0, RetryPolicy.TIMEOUT_MILLIS);
  }
}
