import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 一次 HTTP 发送（ApiClient 已填好全部头与请求体）。 */
export class TransportRequest {
  readonly method: string;
  readonly url: string;
  readonly headers: Record<string, string>;
  /** 请求体原文；GET 等无请求体为 null。 */
  readonly body: string | null;
  readonly timeoutMillis: number;
  /**
   * 真正交给底层发出前的最后核对（lessons 22）：调用归属（账号、会话世代、隐私、环境）仍然有效才返回 true。
   * 传输层在实际发出前调用；返回 false 时不发出，按 cancelled 返回。
   */
  readonly admit: () => boolean;

  constructor(method: string, url: string, headers: Record<string, string>, body: string | null,
    timeoutMillis: number, admit: () => boolean = () => true) {
    this.method = method;
    this.url = url;
    this.headers = headers;
    this.body = body;
    this.timeoutMillis = timeoutMillis;
    this.admit = admit;
  }
}

/** 传输层结果：拿到了 HTTP 响应（任意状态码），或失败（超时 / 断连）。 */
export class TransportResponse {
  /** HTTP 状态码；失败时 0。 */
  readonly status: number;
  readonly headers: Record<string, string>;
  readonly body: string;
  /** none / timeout / disconnect。 */
  readonly failure: string;

  constructor(status: number, headers: Record<string, string>, body: string, failure: string) {
    this.status = status;
    this.headers = headers;
    this.body = body;
    this.failure = failure;
  }

  static ok(status: number, headers: Record<string, string>, body: string): TransportResponse {
    return new TransportResponse(status, headers, body, TransportFailure.NONE);
  }

  static failed(failure: string): TransportResponse {
    return new TransportResponse(0, {}, '', failure);
  }
}

export class TransportFailure {
  static readonly NONE: string = 'none';
  static readonly TIMEOUT: string = 'timeout';
  static readonly DISCONNECT: string = 'disconnect';
  /** 发出前核对不通过，或被取消（撤回同意、切换环境；lessons 22）。 */
  static readonly CANCELLED: string = 'cancelled';
}

/** 可注入的传输接口（单测用本地假服务；生产用 RcpTransport）。不得抛出：失败以 TransportResponse.failed 返回。 */
export interface HttpTransport {
  send(request: TransportRequest): Promise<TransportResponse>;

  /** 取消一个已交给 send、还没有结果的请求（还在等连接 / TLS 的不再发出）。不得抛出。 */
  cancel(request: TransportRequest): void;
}

/** 交给 RCP 的一次请求（可注入层：单测核对配置项，生产由 SystemRcpSender 转成 rcp.Request）。 */
export class RcpRequestSpec {
  readonly url: string;
  readonly method: string;
  readonly headers: Record<string, string>;
  readonly body: string | null;
  /** 请求级配置（关闭自动重定向、连接与传输超时）。 */
  readonly configuration: rcp.Configuration;
  /** 交给 Session.fetch 前的最后核对（TransportRequest.admit）。 */
  readonly admit: () => boolean;

  constructor(url: string, method: string, headers: Record<string, string>, body: string | null,
    configuration: rcp.Configuration, admit: () => boolean = () => true) {
    this.url = url;
    this.method = method;
    this.headers = headers;
    this.body = body;
    this.configuration = configuration;
    this.admit = admit;
  }
}

/** RCP 返回的原始响应（头名转小写）。 */
export class RcpRawResponse {
  readonly statusCode: number;
  readonly headers: Record<string, string>;
  readonly body: string;

  constructor(statusCode: number, headers: Record<string, string>, body: string) {
    this.statusCode = statusCode;
    this.headers = headers;
    this.body = body;
  }
}

/** 真正发出 RCP 请求的一层（可注入）。失败时以 BusinessError 拒绝。 */
export interface RcpSender {
  send(spec: RcpRequestSpec): Promise<RcpRawResponse>;

  /** 取消这个 spec 对应的 RCP 请求（Session.cancel，API 11 起）；没有对应请求时什么都不做。不得抛出。 */
  cancel(spec: RcpRequestSpec): void;
}

/**
 * 系统 RCP（@kit.RemoteCommunicationKit，rule-gaps 编排者裁定 2026-10-07）：一个会话复用连接，配置放在每个请求上。
 * 用到的接口（createSession、Session.fetch、Request、Response.toString、TransferConfiguration.autoRedirect、
 * Timeout.connectMs / transferMs）都是 API 11 / 12 起就有，最低兼容 API 20 可用。
 */
export class SystemRcpSender implements RcpSender {
  private session: rcp.Session | null = null;
  /** 已交给 Session.fetch、还没有结果的请求（撤回同意 / 切换环境时 cancel，lessons 22）。 */
  private readonly live: Map<RcpRequestSpec, rcp.Request> = new Map<RcpRequestSpec, rcp.Request>();

  cancel(spec: RcpRequestSpec): void {
    const request: rcp.Request | undefined = this.live.get(spec);
    this.live.delete(spec);
    if (request === undefined || this.session === null) {
      return;
    }
    try {
      this.session.cancel(request);
    } catch (e) {
      // 取消失败（请求已结束）不影响调用方：ApiClient 自己也按取消收口。
    }
  }

  send(spec: RcpRequestSpec): Promise<RcpRawResponse> {
    try {
      return this.fetch(spec);
    } catch (e) {
      // createSession / Request 构造同步抛出（参数错误、会话数达上限）：按失败返回，由 RcpTransport 记为断连。
      return Promise.reject(e);
    }
  }

  private fetch(spec: RcpRequestSpec): Promise<RcpRawResponse> {
    if (this.session === null) {
      const sessionConfig: rcp.SessionConfiguration = {
        requestConfiguration: spec.configuration
      };
      this.session = rcp.createSession(sessionConfig);
    }
    const session: rcp.Session = this.session;
    const headers: rcp.RequestHeaders = {};
    for (const name of Object.keys(spec.headers)) {
      headers[name] = spec.headers[name];
    }
    const request: rcp.Request = new rcp.Request(spec.url, spec.method, headers,
      spec.body === null ? undefined : spec.body);
    request.configuration = spec.configuration;
    if (!spec.admit()) {
      // 交给 Session.fetch 前最后一次核对（lessons 22）：归属已失效的不发出。
      const cancelled: BusinessError = { name: 'BusinessError', message: 'Request is canceled', code: 1007900992 };
      return Promise.reject(cancelled);
    }
    this.live.set(spec, request);
    return session.fetch(request).then((response: rcp.Response): RcpRawResponse => {
      this.live.delete(spec);
      const text: string | null = response.toString();
      return new RcpRawResponse(response.statusCode, SystemRcpSender.headers(response.headers), text ?? '');
    }, (e: BusinessError): RcpRawResponse => {
      this.live.delete(spec);
      throw e as Error;
    });
  }

  private static headers(raw: rcp.ResponseHeaders): Record<string, string> {
    const out: Record<string, string> = {};
    if (raw === null || raw === undefined) {
      return out;
    }
    for (const key of Object.keys(raw)) {
      const value: string | string[] | undefined = raw[key];
      if (value === undefined) {
        continue;
      }
      out[key.toLowerCase()] = Array.isArray(value) ? (value as string[]).join(', ') : String(value);
    }
    return out;
  }
}

/**
 * 生产传输层：系统 RCP。
 * - 重定向：autoRedirect=false（API 11 起有），3xx 原样交给 ApiClient（契约没有 3xx，按无统一外壳处理），
 *   不跟随到任何地址，免得绕过白名单与凭据检查（lessons R1-05 / 4）。
 * - 超时：connectMs、transferMs 都设为 ApiClient 给的值（10 秒；POST /v1/links/{link_id}/open 8 秒）。
 * - 自动重发：RCP 没有按状态码（如 503 + Retry-After）自动重发的行为，重试只由 ApiClient 决定（lessons R1-03）；
 *   不配置 cache（API 20 的 ResponseCache 不启用），不用拦截器。
 * - RCP 错误码 1007900028（超时）记为 timeout，1007900992（已取消）记为 cancelled，其余错误记为 disconnect（03 §4.2：超时 / 断连）。
 * - 取消（lessons 22）：交给 RCP 之前与交给 Session.fetch 之前各核对一次 TransportRequest.admit，不通过不发出；
 *   cancel 经 Session.cancel 取消还在等连接 / TLS / 响应的请求。
 */
export class RcpTransport implements HttpTransport {
  static readonly TIMEOUT_CODE: number = 1007900028;
  static readonly CANCELLED_CODE: number = 1007900992;
  private readonly sender: RcpSender;
  private readonly specs: Map<TransportRequest, RcpRequestSpec> = new Map<TransportRequest, RcpRequestSpec>();

  constructor(sender: RcpSender = new SystemRcpSender()) {
    this.sender = sender;
  }

  /** 每个请求的 RCP 配置：关闭自动重定向，连接与传输超时都用给定毫秒数。 */
  static configuration(timeoutMillis: number): rcp.Configuration {
    const timeout: rcp.Timeout = {
      connectMs: timeoutMillis,
      transferMs: timeoutMillis
    };
    const transfer: rcp.TransferConfiguration = {
      autoRedirect: false,
      timeout: timeout
    };
    const configuration: rcp.Configuration = {
      transfer: transfer
    };
    return configuration;
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    if (!request.admit()) {
      return Promise.resolve(TransportResponse.failed(TransportFailure.CANCELLED));
    }
    const spec: RcpRequestSpec = new RcpRequestSpec(request.url, request.method, request.headers, request.body,
      RcpTransport.configuration(request.timeoutMillis), request.admit);
    let pending: Promise<RcpRawResponse>;
    try {
      pending = this.sender.send(spec);
    } catch (e) {
      return Promise.resolve(TransportResponse.failed(RcpTransport.failureOf(e as BusinessError)));
    }
    this.specs.set(request, spec);
    return pending
      .then((raw: RcpRawResponse): TransportResponse => TransportResponse.ok(raw.statusCode, raw.headers, raw.body))
      .catch((e: BusinessError): TransportResponse => TransportResponse.failed(RcpTransport.failureOf(e)))
      .finally((): void => {
        this.specs.delete(request);
      });
  }

  cancel(request: TransportRequest): void {
    const spec: RcpRequestSpec | undefined = this.specs.get(request);
    this.specs.delete(request);
    if (spec === undefined) {
      return;
    }
    try {
      this.sender.cancel(spec);
    } catch (e) {
      // 发送层不得抛出；万一抛出也不影响调用方（ApiClient 已按取消收口）。
    }
  }

  private static failureOf(e: BusinessError | null | undefined): string {
    if (e === null || e === undefined) {
      return TransportFailure.DISCONNECT;
    }
    if (e.code === RcpTransport.TIMEOUT_CODE) {
      return TransportFailure.TIMEOUT;
    }
    return e.code === RcpTransport.CANCELLED_CODE ? TransportFailure.CANCELLED : TransportFailure.DISCONNECT;
  }
}
