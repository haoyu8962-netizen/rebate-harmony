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

/**
 * 流式响应的接收端（APP-10b §2 第 1 条，F-X-04）：响应头到达后 onHeaders（状态码 + 小写键的头），之后原始字节块按到达顺序 onBytes，
 * 正常结束 onEnd；没有完整响应（断连、超时、发出前核对不通过、被取消）onFailure(TransportFailure 值)。四个回调合计至多一个终结
 * （onEnd / onFailure），之后不再回调。传输层不解码、不切行、不缓冲整包（字节解码只在 Core 的 StreamUtf8Decoder 做一次）。
 */
export interface TransportStreamSink {
  onHeaders(status: number, headers: Record<string, string>): void;

  onBytes(chunk: ArrayBuffer): void;

  onEnd(): void;

  onFailure(failure: string): void;
}

/**
 * 可注入的流式传输接口（APP-10b，鸿蒙 §3）：与 HttpTransport 分开，免得既有的整包替身全部要实现它。生产由 RcpTransport 实现
 * （同一个 RCP 会话，Request 的 tracing.httpEventsHandler 增量取字节，G37）；单测用替身逐块喂 ArrayBuffer。
 * - stream 在真正交给底层发出前调用 request.admit()（与 send 同一道最后核对），不通过按 onFailure(cancelled) 结束、不发出。
 * - 不自行重发、不跟随重定向；整体调用不设超时（空闲与总时长由 StreamClient 计时，G16），连接建立超时用 request.timeoutMillis。
 * - cancelStream 同步取消（之后到达的字节一律不交付）。不得抛出。
 */
export interface HttpStreamTransport {
  stream(request: TransportRequest, sink: TransportStreamSink): void;

  cancelStream(request: TransportRequest): void;
}

/** RCP 流式发送层（可注入；SystemRcpSender 实现）。 */
export interface RcpStreamSender {
  stream(spec: RcpRequestSpec, sink: TransportStreamSink): void;

  cancel(spec: RcpRequestSpec): void;
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
export class SystemRcpSender implements RcpSender, RcpStreamSender {
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

  /**
   * 流式发送（APP-10b，G37）：同一个 RCP 会话；请求级配置挂 tracing.httpEventsHandler——onHeaderReceive 记响应头，onStatusCodeReceive
   * （API 20）记状态码，onDataReceive 逐块交原始字节（注册了它，Response.body 不再有整包），fetch 结束交 onEnd。
   * 模拟器实测（rule-gaps 鸿蒙追加 H 号）：字节按服务端每次写出逐块到达；但 onHeaderReceive 先于 onStatusCodeReceive——响应头先记下，
   * 状态码到了才一起交给 onHeaders（Content-Type 分流要两者都有）；状态码之前到达的字节按序暂存、交头之后补交。
   * 交给 Session.fetch 前最后核对 admit。
   */
  stream(spec: RcpRequestSpec, sink: TransportStreamSink): void {
    let ended: boolean = false;
    let status: number = 0;
    let headersSent: boolean = false;
    let pendingHeaders: rcp.ResponseHeaders | undefined = undefined;
    let held: ArrayBuffer[] = [];
    const finish = (failure: string | null): void => {
      if (ended) {
        return;
      }
      ended = true;
      this.live.delete(spec);
      if (failure === null) {
        sink.onEnd();
      } else {
        sink.onFailure(failure);
      }
    };
    const headersOnce = (raw: rcp.ResponseHeaders | undefined): void => {
      if (headersSent || ended) {
        return;
      }
      headersSent = true;
      sink.onHeaders(status, SystemRcpSender.headers(raw === undefined ? {} : raw));
      const queued: ArrayBuffer[] = held;
      held = [];
      for (const chunk of queued) {
        if (!ended) {
          sink.onBytes(chunk);
        }
      }
    };
    try {
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
      const handler: rcp.HttpEventsHandler = {
        onStatusCodeReceive: (code: number): void => {
          status = code;
          if (pendingHeaders !== undefined) {
            headersOnce(pendingHeaders);
          }
        },
        onHeaderReceive: (raw: rcp.ResponseHeaders): void => {
          pendingHeaders = raw;
          if (status > 0) {
            headersOnce(raw);
          }
        },
        onDataReceive: (incoming: ArrayBuffer): void => {
          if (ended || incoming.byteLength === 0) {
            return;
          }
          if (!headersSent) {
            // 状态码还没到：按序暂存（不交付、不解析），交头之后补交。
            held.push(incoming.slice(0));
            return;
          }
          sink.onBytes(incoming);
        }
      };
      const tracing: rcp.TracingConfiguration = {
        httpEventsHandler: handler
      };
      const configuration: rcp.Configuration = {
        transfer: spec.configuration.transfer,
        tracing: tracing
      };
      request.configuration = configuration;
      if (!spec.admit()) {
        finish(TransportFailure.CANCELLED);
        return;
      }
      this.live.set(spec, request);
      session.fetch(request).then((response: rcp.Response): void => {
        if (ended) {
          return;
        }
        if (!headersSent) {
          status = response.statusCode;
          headersOnce(pendingHeaders ?? response.headers);
        }
        const body: ArrayBuffer | undefined = response.body;
        if (body !== undefined && body !== null && body.byteLength > 0 && !ended) {
          // 没有走增量回调的实现（整包）：原样作为一块交付（G37 退路，不重复交付：增量回调注册后 body 为 undefined）。
          sink.onBytes(body);
        }
        finish(null);
      }, (e: BusinessError): void => {
        finish(RcpTransport.failureOf(e));
      });
    } catch (e) {
      finish(TransportFailure.DISCONNECT);
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
export class RcpTransport implements HttpTransport, HttpStreamTransport {
  static readonly TIMEOUT_CODE: number = 1007900028;
  static readonly CANCELLED_CODE: number = 1007900992;
  private readonly sender: RcpSender;
  private readonly specs: Map<TransportRequest, RcpRequestSpec> = new Map<TransportRequest, RcpRequestSpec>();
  private readonly streamSender: RcpStreamSender;
  private readonly streams: Map<TransportRequest, RcpRequestSpec> = new Map<TransportRequest, RcpRequestSpec>();
  /** 流式请求的总传输上限（毫秒）：大于 StreamClient 的单轮 90 秒（G16），整体时长由 StreamClient 计时负责。 */
  static readonly STREAM_TRANSFER_MS: number = 120000;

  constructor(sender: RcpSender = new SystemRcpSender(), streamSender: RcpStreamSender | null = null) {
    this.sender = sender;
    // 流式与整包共用同一个 RCP 会话（G37：与 ApiClient 同一会话与配置）；注入了别的整包发送层时另建系统发送层。
    this.streamSender = streamSender ?? (sender instanceof SystemRcpSender ? sender as SystemRcpSender :
      new SystemRcpSender());
  }

  /** 流式请求的 RCP 配置：关闭自动重定向；连接超时用给定毫秒数，传输上限放宽到 STREAM_TRANSFER_MS（不设空闲超时）。 */
  static streamConfiguration(connectMillis: number): rcp.Configuration {
    const timeout: rcp.Timeout = {
      connectMs: connectMillis,
      transferMs: RcpTransport.STREAM_TRANSFER_MS
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

  stream(request: TransportRequest, sink: TransportStreamSink): void {
    if (!request.admit()) {
      sink.onFailure(TransportFailure.CANCELLED);
      return;
    }
    const spec: RcpRequestSpec = new RcpRequestSpec(request.url, request.method, request.headers, request.body,
      RcpTransport.streamConfiguration(request.timeoutMillis), request.admit);
    this.streams.set(request, spec);
    const forget = (): void => {
      this.streams.delete(request);
    };
    const inner: TransportStreamSink = new ForgetfulSink(sink, forget);
    try {
      this.streamSender.stream(spec, inner);
    } catch (e) {
      forget();
      sink.onFailure(TransportFailure.DISCONNECT);
    }
  }

  cancelStream(request: TransportRequest): void {
    const spec: RcpRequestSpec | undefined = this.streams.get(request);
    this.streams.delete(request);
    if (spec === undefined) {
      return;
    }
    try {
      this.streamSender.cancel(spec);
    } catch (e) {
      // 发送层不得抛出。
    }
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

  static failureOf(e: BusinessError | null | undefined): string {
    if (e === null || e === undefined) {
      return TransportFailure.DISCONNECT;
    }
    if (e.code === RcpTransport.TIMEOUT_CODE) {
      return TransportFailure.TIMEOUT;
    }
    return e.code === RcpTransport.CANCELLED_CODE ? TransportFailure.CANCELLED : TransportFailure.DISCONNECT;
  }
}

/** 终结时先撤销登记再转交的接收端（RcpTransport.stream 用）。 */
class ForgetfulSink implements TransportStreamSink {
  private readonly sink: TransportStreamSink;
  private readonly forget: () => void;

  constructor(sink: TransportStreamSink, forget: () => void) {
    this.sink = sink;
    this.forget = forget;
  }

  onHeaders(status: number, headers: Record<string, string>): void {
    this.sink.onHeaders(status, headers);
  }

  onBytes(chunk: ArrayBuffer): void {
    this.sink.onBytes(chunk);
  }

  onEnd(): void {
    this.forget();
    this.sink.onEnd();
  }

  onFailure(failure: string): void {
    this.forget();
    this.sink.onFailure(failure);
  }
}
