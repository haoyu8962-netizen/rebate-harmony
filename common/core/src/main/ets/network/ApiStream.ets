// APP-10b §2 第 1 条（F-X-04）：ApiClient 的流式通道的类型与纯判定（三端同名：ApiStreamRequest、ApiStreamSink、ApiStreamHandle、
// ApiClient.stream）。执行在 ApiClient.stream（与普通请求共用 operation 查表、路径参数编码、公共头、可选 Authorization、调用归属、
// 每次实际写出前的 admit / sendAllowed、单飞刷新、10402 重新注册、10405、撤回 / 切环境的同步取消）。
// - 只给契约里登记为流式的 operation 用（ApiStreamOperations；表外本地拒绝）。
// - 请求头另加 Accept: text/event-stream（G18）与 Accept-Encoding: identity（G17）；不签名、不带 Idempotency-Key（7 个 agent operation
//   都是 x-signed:false、x-idempotent:false）。
// - 响应头到达后按 Content-Type 分流（G19，ApiStreamRoutingPolicy）：text/event-stream（忽略大小写与参数）且 2xx → 头交 onHeaders，之后原始
//   字节块交 onBytes；其他 → 读完整正文按统一外壳解包，交 onEnvelope(ApiResult)。不按 HTTP 状态码分支。
// - 10002 / 10402：只在拿到 JSON 外壳、尚未收到任何 SSE 字节时，单飞刷新 / 重新注册成功后以同一请求体（同一 client_msg_id）至多重放一次，
//   重放前重新核对归属与 admit（G23，ApiStreamRequestPolicy.replay）。
import { ApiOperation, ApiOperations } from 'generated';
import { ApiResult } from './ApiClient';
import { HeaderDecision, NetworkHeaders, NetworkPrivacy, NetworkRequestState, RequestHeaderPolicy, SessionScope } from './NetworkPolicy';

/** 契约里响应为 text/event-stream 的 operation（40cfc268 openapi：只有 sendAgentMessage）。表外 operation 一律本地拒绝。 */
export class ApiStreamOperations {
  static readonly STREAMING: string[] = ['sendAgentMessage'];

  static isStreaming(operationId: string): boolean {
    return ApiStreamOperations.STREAMING.indexOf(operationId) >= 0 && ApiOperations.byId(operationId) !== undefined;
  }
}

/** 一次流式请求（只有 POST 请求体；路径参数照普通请求编码）。 */
export class ApiStreamRequest {
  readonly operationId: string;
  readonly pathParams: Record<string, string>;
  readonly body: string;
  /** 调用归属守卫（同 ApiRequest.owner）：每次实际写出前、每个响应分块交付前核对；cancelOwned(owner) 同步取消。 */
  owner: (() => boolean) | null = null;
  /** 发送闸门（同 ApiRequest.sendAllowed）：每次实际写出前核对（含刷新 / 重新注册后的重放与 TransportRequest.admit）。 */
  sendAllowed: (() => boolean) | null = null;
  /** 写出观察（同 ApiRequest.onAdmit）。 */
  onAdmit: ((admitted: boolean) => void) | null = null;

  constructor(operationId: string, pathParams: Record<string, string>, body: string) {
    this.operationId = operationId;
    this.pathParams = pathParams;
    this.body = body;
  }
}

/** 流式结果的接收端（同一请求至多一个终结：onEnd / onFailure / onEnvelope）。 */
export interface ApiStreamSink {
  /** SSE 响应头（小写键）。只在分流为流之后调用一次。 */
  onHeaders(status: number, headers: Record<string, string>): void;

  /** 原始字节块（不解码、不切行）。 */
  onBytes(chunk: ArrayBuffer): void;

  /** 流正常结束。 */
  onEnd(): void;

  /** 流开始之后的传输失败（断连、超时、被取消）：TransportFailure 值。 */
  onFailure(failure: string): void;

  /** 没有成为流：JSON 外壳（含 10002 重放后的最终结果）、无外壳、本地没发出、传输失败，都是一个 ApiResult（与普通请求同一结果路径）。 */
  onEnvelope(result: ApiResult): void;
}

/** 流式请求的句柄：cancel 同步关闭连接，之后到达的字节一律不再交付。 */
export class ApiStreamHandle {
  private canceller: () => void = (): void => {
  };
  private stopped: boolean = false;
  /** 已交付给 sink 的字节块数（抓包断言「作废之后 0 块」用）。 */
  delivered: number = 0;
  /** 作废之后到达、被丢弃的字节块数。 */
  dropped: number = 0;

  get cancelled(): boolean {
    return this.stopped;
  }

  /** ApiClient 内部：登记真正的取消动作。 */
  bind(canceller: () => void): void {
    this.canceller = canceller;
  }

  /** ApiClient 内部：标记已结束（不再交付）。 */
  markStopped(): void {
    this.stopped = true;
  }

  cancel(): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    try {
      this.canceller();
    } catch (e) {
      // 取消不得抛出。
    }
  }
}

/** G19 分流结论。 */
export class ApiStreamRoute {
  static readonly STREAM: string = 'stream';
  static readonly ENVELOPE: string = 'envelope';
  static readonly NO_ENVELOPE: string = 'no_envelope';
  readonly route: string;
  /** 外壳 code（流与无外壳为 null）。 */
  readonly code: number | null;
  /** 外壳 code=0 但不是流：协议错误，本条按连接中断、同键【重试】。 */
  readonly protocolError: boolean;

  constructor(route: string, code: number | null, protocolError: boolean) {
    this.route = route;
    this.code = code;
    this.protocolError = protocolError;
  }
}

type JsonValue = Object | null;
type JsonObject = Record<string, JsonValue>;

export class ApiStreamRoutingPolicy {
  /** text/event-stream（忽略大小写与参数）且 2xx。 */
  static isStream(status: number, contentType: string | null): boolean {
    if (status < 200 || status > 299 || contentType === null) {
      return false;
    }
    const media: string = contentType.split(';')[0].trim().toLowerCase();
    return media === 'text/event-stream';
  }

  /** 响应头 + 完整正文（只在不是流时才读完整正文）→ 分流结论。正文能解出统一外壳就是外壳（不看状态码与类型），否则无外壳。 */
  static route(status: number, contentType: string | null, body: string): ApiStreamRoute {
    if (ApiStreamRoutingPolicy.isStream(status, contentType)) {
      return new ApiStreamRoute(ApiStreamRoute.STREAM, null, false);
    }
    const code: number | null = ApiStreamRoutingPolicy.envelopeCode(body);
    if (code === null) {
      return new ApiStreamRoute(ApiStreamRoute.NO_ENVELOPE, null, false);
    }
    return new ApiStreamRoute(ApiStreamRoute.ENVELOPE, code, code === 0);
  }

  static envelopeCode(body: string): number | null {
    try {
      const parsed: Object | null = JSON.parse(body) as Object | null;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return null;
      }
      const code: Object | undefined = (parsed as Record<string, Object>)['code'];
      return typeof code === 'number' && Number.isInteger(code as number) ? code as number : null;
    } catch (e) {
      return null;
    }
  }

  /** 向量接线（contentRouting 组的分流行）：{http, contentType, body} → 路由、交给哪个 sink 回调、外壳 code、本条状态。 */
  static of(input: JsonObject, _nowMs: number): JsonObject {
    const http: number = typeof input['http'] === 'number' ? input['http'] as number : 0;
    const type: JsonValue | undefined = input['contentType'];
    const body: JsonValue | undefined = input['body'];
    const r: ApiStreamRoute = ApiStreamRoutingPolicy.route(http, typeof type === 'string' ? type as string : null,
      typeof body === 'string' ? body as string : '');
    const o: JsonObject = {};
    o['routeRaw'] = r.route;
    o['sinkRaw'] = r.route === ApiStreamRoute.STREAM ? 'onBytes' : 'onEnvelope';
    o['code'] = r.code;
    o['protocolError'] = r.protocolError;
    if (r.route === ApiStreamRoute.NO_ENVELOPE || r.protocolError) {
      // 没有外壳 / 外壳成功却不是流：本条「连接中断」，【重试】沿用同一 client_msg_id（G19）。
      o['statusRaw'] = 'disconnected';
      o['reuseClientMsgId'] = true;
    }
    return o;
  }
}

/** G23 重放的恢复方式。 */
export class ApiStreamRecovery {
  static readonly REFRESH: string = 'single_flight_refresh';
  static readonly REGISTER: string = 'register_device';
}

export class ApiStreamRequestPolicy {
  /** 流式请求另加的头（G17、G18）。 */
  static readonly ACCEPT: string = 'text/event-stream';
  static readonly ACCEPT_ENCODING: string = 'identity';
  /** 刷新 / 重新注册后的重放上限（G23）。 */
  static readonly MAX_REPLAYS: number = 1;

  static extraHeaders(headers: Record<string, string>): void {
    headers[NetworkHeaders.ACCEPT] = ApiStreamRequestPolicy.ACCEPT;
    headers[NetworkHeaders.ACCEPT_ENCODING] = ApiStreamRequestPolicy.ACCEPT_ENCODING;
  }

  /**
   * 外壳错误码 → 重放的恢复方式（null = 不重放）：10002 → 单飞刷新，10402 → 重新注册；已经收到 SSE 字节、或已经重放过一次就不再重放。
   */
  static replay(code: number, sseBytesReceived: number, priorReplays: number): string | null {
    if (sseBytesReceived > 0 || priorReplays >= ApiStreamRequestPolicy.MAX_REPLAYS) {
      return null;
    }
    if (code === 10002) {
      return ApiStreamRecovery.REFRESH;
    }
    return code === 10402 ? ApiStreamRecovery.REGISTER : null;
  }

  /** 向量接线（contentRouting 组的 request / replay 行）。判定与 ApiClient.stream 共用 RequestHeaderPolicy.decide 与 replay。 */
  static of(input: JsonObject, _nowMs: number): JsonObject {
    return input['modeRaw'] === 'replay' ? ApiStreamRequestPolicy.replayJson(input) : ApiStreamRequestPolicy.requestJson(input);
  }

  private static requestJson(input: JsonObject): JsonObject {
    const o: JsonObject = {};
    const op: string = typeof input['operationRaw'] === 'string' ? input['operationRaw'] as string : '';
    const identity: string = typeof input['identityRaw'] === 'string' ? input['identityRaw'] as string : 'guest';
    const credentialsAllowed: boolean = input['credentialsAllowed'] === true;
    const privacyCurrent: boolean = input['privacyCurrent'] === true;
    const token: JsonValue | undefined = input['token'];
    const operation: ApiOperation | undefined = ApiOperations.byId(op);
    // 读凭据之前的三道闸门（与 ApiClient 同序）：表外 operation；会员但账号未知（Agent 入口层，FU-AND-0714 第 4 条）；
    // 隐私未同意当前版本 / 凭据读取屏障关闭（ApiClient.credentialsAllowed）——不通过一次都不读凭据。
    let credentialReads: number = 0;
    let decision: HeaderDecision | null = null;
    if (operation !== undefined && ApiStreamOperations.isStreaming(op) && identity !== 'member_unknown') {
      const readable: boolean = credentialsAllowed && privacyCurrent;
      const hasToken: boolean = readable && typeof token === 'string';
      if (readable) {
        credentialReads = 1;
      }
      decision = RequestHeaderPolicy.decide(new NetworkRequestState(privacyCurrent ? NetworkPrivacy.FULL :
        NetworkPrivacy.NOT_DECIDED, SessionScope.FULL, hasToken, readable ? 'synthetic-device' : null, true,
        credentialsAllowed), operation as ApiOperation);
    }
    const sends: boolean = decision !== null && decision.send && input['admitted'] === true;
    o['sendsRequests'] = sends;
    o['credentialReads'] = credentialReads;
    if (!sends || decision === null) {
      o['resultRaw'] = 'notSent';
      return o;
    }
    const d: HeaderDecision = decision as HeaderDecision;
    const base: JsonValue | undefined = input['streamBaseUrl'];
    o['resultRaw'] = 'sent';
    o['signed'] = d.has(NetworkHeaders.SIGN);
    o['idempotencyKeyPresent'] = d.has(NetworkHeaders.IDEMPOTENCY_KEY);
    o['authorizationPresent'] = d.has(NetworkHeaders.AUTHORIZATION);
    o['accept'] = ApiStreamRequestPolicy.ACCEPT;
    o['acceptEncoding'] = ApiStreamRequestPolicy.ACCEPT_ENCODING;
    // G15：流式基址缺省等于 API 基址（stream. 子域待部署确定）。
    o['baseUrl'] = typeof base === 'string' ? base as string : (input['baseUrl'] ?? null);
    o['publicHeaderNames'] = d.headerNames.filter((n: string): boolean => n !== NetworkHeaders.AUTHORIZATION
      && n !== NetworkHeaders.IDEMPOTENCY_KEY && n !== NetworkHeaders.TIMESTAMP && n !== NetworkHeaders.NONCE
      && n !== NetworkHeaders.SIGN);
    return o;
  }

  private static replayJson(input: JsonObject): JsonObject {
    const o: JsonObject = {};
    const code: number = typeof input['code'] === 'number' ? input['code'] as number : 0;
    const sse: number = typeof input['sseBytesReceived'] === 'number' ? input['sseBytesReceived'] as number : 0;
    const prior: number = typeof input['priorReplays'] === 'number' ? input['priorReplays'] as number : 0;
    const recovery: string | null = ApiStreamRequestPolicy.replay(code, sse, prior);
    const body: JsonObject | null = input['body'] !== null && typeof input['body'] === 'object' ?
      input['body'] as JsonObject : null;
    o['recoveryRaw'] = recovery;
    o['rebindIdentity'] = false;
    if (recovery === null) {
      o['replays'] = 0;
      return o;
    }
    if (input['recoverySucceeded'] !== true || input['replayAdmitted'] !== true) {
      // 恢复失败、恢复后归属变了（换号、切环境）：这一条按没发出结束，不改绑到新身份，输入框不恢复（G23、APP-10 H11）。
      o['replays'] = 0;
      o['resultRaw'] = 'notSent';
      o['restoreInput'] = false;
      return o;
    }
    o['replays'] = 1;
    o['sameBody'] = true;
    o['clientMsgId'] = body === null ? null : (body['client_msg_id'] ?? null);
    return o;
  }
}
