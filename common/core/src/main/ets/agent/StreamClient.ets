// APP-10 §2 第 4 条：StreamClient（界面无关）。一次 run 一个实例：发 sendAgentMessage → 按响应 Content-Type 分流
// （text/event-stream → 增量喂 AgentSse；其他 → 统一外壳 JSON 错误，G24）→ 每一帧连同发起时的 run 票据交给控制器（控制器先比票据）。
// - 30 秒内没收到任何一行（含 `: ping` 与空行）→ 断线（G33：从请求发出起算，连接建立前的等待也计入；只有收到完整的 SSE 行才重置，
//   响应头与半行都不延长期限（harmony-review-r1 R1-09）；计时器绑定本实例）。
// - 响应头的 X-Trace-Id 随每个事件交回（流内 error 帧没有 trace_id，5xxxx 文案的 trace6 用它，R1-07）。
// - cancel()：同步关闭连接、停计时、本实例作废；之后到达的任何字节一律丢弃（不解析、不交付）。
// 待定 operation（G01）：锁定契约没有 /v1/agent/*，四个接口只由 Debug / Staging 的本地假服务实现（AgentContractPort）；Release 没有端口，
// Agent 页显示「未开放」、不发请求。契约补上后由 ApiClient 管线实现同一端口（真实 requestInStream），控制器与 Reducer 代码路径不变
// （rule-gaps 鸿蒙 H02）。TODO(N-36)。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentSse, AgentSseKind } from './AgentSse';
import { AgentFrame, AgentFrameDecoder } from './AgentDecoder';

/** 一次待定 operation 的 JSON 结果（统一外壳 {code, msg, data, trace_id}）。 */
export class AgentHttpResult {
  /** 拿到了 HTTP 响应且外壳 code=0。 */
  readonly ok: boolean;
  readonly httpStatus: number;
  /** 外壳 code；没有外壳（断网、超时、本地拒绝）为 -1。 */
  readonly code: number;
  readonly msg: string;
  readonly data: AgentJsonObject;
  /** 外壳 trace_id，没有时取响应头 X-Trace-Id，都没有为空串。 */
  readonly traceId: string;
  /** 响应头 Retry-After 原值。 */
  readonly retryAfter: string | null;
  /** 本地没有发出（闸门、归属失效）。 */
  readonly notSent: boolean;

  constructor(ok: boolean, httpStatus: number, code: number, msg: string, data: AgentJsonObject, traceId: string,
    retryAfter: string | null, notSent: boolean = false) {
    this.ok = ok;
    this.httpStatus = httpStatus;
    this.code = code;
    this.msg = msg;
    this.data = data;
    this.traceId = traceId;
    this.retryAfter = retryAfter;
    this.notSent = notSent;
  }

  static network(): AgentHttpResult {
    return new AgentHttpResult(false, 0, -1, '', {}, '', null);
  }

  static notSentResult(): AgentHttpResult {
    return new AgentHttpResult(false, 0, -1, '', {}, '', null, true);
  }

  /** 响应头（键小写）+ 正文 → 结果；正文不是统一外壳按网络错误。 */
  static of(status: number, headers: Record<string, string>, body: string): AgentHttpResult {
    const env: AgentJsonObject | null = AgentJson.objectOf(AgentJson.parse(body));
    const headerTrace: string = headers['x-trace-id'] ?? '';
    const retryAfter: string | null = headers['retry-after'] ?? null;
    if (env === null || AgentJson.intOf(env['code']) === null) {
      return new AgentHttpResult(false, status, -1, '', {}, headerTrace, retryAfter);
    }
    const code: number = env['code'] as number;
    const trace: string = AgentJson.stringOf(env['trace_id']) ?? headerTrace;
    const data: AgentJsonObject = AgentJson.objectOf(env['data']) ?? {};
    return new AgentHttpResult(code === 0 && status >= 200 && status < 300, status, code,
      AgentJson.stringOf(env['msg']) ?? '', data, trace.length > 0 ? trace : headerTrace, retryAfter);
  }

  /** 10004 的 consent_type（在 data 里；没有为 null）。 */
  get consentType(): string | null {
    return AgentJson.stringOf(this.data['consent_type']);
  }
}

/** 发起一次请求时固定的归属（控制器构造时的身份键）与两道闸门：sendAllowed 在每次实际发包前核对，owner 在响应到达后核对。 */
export class AgentCall {
  readonly identityKey: string;
  /** 基本模式不发（BR-ID-11）；游客为 true 时不带令牌由端口自己处理（x-auth: optional）。 */
  readonly anonymous: boolean;
  readonly sendAllowed: () => boolean;
  readonly owner: () => boolean;

  constructor(identityKey: string, anonymous: boolean, sendAllowed: () => boolean, owner: () => boolean) {
    this.identityKey = identityKey;
    this.anonymous = anonymous;
    this.sendAllowed = sendAllowed;
    this.owner = owner;
  }
}

/** 流式响应的接收端（端口按到达顺序调用；cancel 之后端口可能仍回调，StreamClient 丢弃）。 */
export interface AgentStreamSink {
  onHeaders(status: number, headers: Record<string, string>): void;

  onData(chunk: string): void;

  onEnd(): void;

  /** 断连、超时等传输失败（没有完整的 HTTP 响应）。 */
  onFailure(): void;
}

export interface AgentStreamHandle {
  /** 同步关闭连接（还没发出的不再发出）。 */
  cancel(): void;
}

/**
 * 待定 operation（形状取 rebate-platform 47eaf92f，G01）：createAgentSession（POST /v1/agent/sessions）、getCurrentAgentSession
 * （GET /v1/agent/sessions/current，session 可为 null）、sendAgentMessage（POST /v1/agent/sessions/{id}/messages，成功 text/event-stream，
 * 失败 JSON）、cancelAgentRun（POST /v1/agent/runs/{run_id}/cancel）。都是 x-auth optional、不签名、不幂等、x-min-version-gate。
 * 每个实现都必须在实际发包前核对 call.sendAllowed()，不通过就不发（notSent）。
 */
export interface AgentContractPort {
  createSession(call: AgentCall): Promise<AgentHttpResult>;

  currentSession(call: AgentCall): Promise<AgentHttpResult>;

  sendMessage(sessionId: string, body: string, call: AgentCall, sink: AgentStreamSink): AgentStreamHandle;

  cancelRun(runId: string, call: AgentCall): Promise<AgentHttpResult>;

  /** 作废这个归属键的全部在途请求（控制器作废时同步调用）。 */
  cancelOwned(identityKey: string): void;
}

/** 计时器端口（单测注入假计时器推进 30 秒）。 */
export interface AgentTimer {
  schedule(ms: number, run: () => void): number;

  cancel(id: number): void;
}

export class SystemAgentTimer implements AgentTimer {
  schedule(ms: number, run: () => void): number {
    return setTimeout(run, ms);
  }

  cancel(id: number): void {
    clearTimeout(id);
  }
}

export class AgentStreamEventKind {
  static readonly FRAME: string = 'frame';
  static readonly PING: string = 'ping';
  /** 连接正常结束但没有终止帧。 */
  static readonly EOF: string = 'eof';
  /** 30 秒没有任何一行。 */
  static readonly TIMEOUT: string = 'timeout';
  /** 非 SSE 响应（JSON 错误外壳）。 */
  static readonly JSON: string = 'json';
  /** 传输失败（断网、本地没发出）。 */
  static readonly FAILED: string = 'failed';
}

export class AgentStreamEvent {
  readonly kind: string;
  readonly frame: AgentFrame | null;
  readonly result: AgentHttpResult | null;
  /** 本次响应头的 X-Trace-Id（没有为空串）；流内 error 帧的 5xxxx 文案按它追加 trace6（R1-07）。 */
  traceId: string = '';

  constructor(kind: string, frame: AgentFrame | null = null, result: AgentHttpResult | null = null) {
    this.kind = kind;
    this.frame = frame;
    this.result = result;
  }
}

/** 一次 run 的流客户端。deliver 由控制器给：每个事件都带发起时的票据（这里不认识票据的结构，只原样交回）。 */
export class StreamClient<T> {
  static readonly IDLE_TIMEOUT_MS: number = 30000;
  private readonly port: AgentContractPort;
  private readonly timer: AgentTimer;
  private readonly ticket: T;
  private readonly deliver: (ticket: T, event: AgentStreamEvent) => void;
  private readonly sse: AgentSse = new AgentSse();
  private handle: AgentStreamHandle | null = null;
  private timerId: number = -1;
  private live: boolean = false;
  private streaming: boolean = false;
  private jsonBody: string = '';
  private status: number = 0;
  private headers: Record<string, string> = {};
  private lines: number = 0;
  /** 本机日志（只写事件名与结果，不写 data）。 */
  log: (message: string) => void = (_m: string) => {
  };

  constructor(port: AgentContractPort, timer: AgentTimer, ticket: T, deliver: (ticket: T, event: AgentStreamEvent) => void) {
    this.port = port;
    this.timer = timer;
    this.ticket = ticket;
    this.deliver = deliver;
  }

  get active(): boolean {
    return this.live;
  }

  start(sessionId: string, body: string, call: AgentCall): void {
    if (this.live || this.handle !== null) {
      return;
    }
    this.live = true;
    this.arm();
    const sink: AgentStreamSink = new ClientSink<T>(this);
    let handle: AgentStreamHandle | null = null;
    try {
      handle = this.port.sendMessage(sessionId, body, call, sink);
    } catch (e) {
      handle = null;
    }
    if (!this.live) {
      // 发出前已被同步取消或同步收尾（端口同步回调了 onEnd / onFailure）。
      handle?.cancel();
      return;
    }
    this.handle = handle;
    if (handle === null) {
      this.finish(new AgentStreamEvent(AgentStreamEventKind.FAILED, null, AgentHttpResult.network()));
    }
  }

  /** 同步关闭连接、停计时、作废；之后的字节丢弃。 */
  cancel(): void {
    if (!this.live) {
      return;
    }
    this.live = false;
    this.disarm();
    const h: AgentStreamHandle | null = this.handle;
    this.handle = null;
    try {
      h?.cancel();
    } catch (e) {
      // 端口不得抛出；万一抛出也已作废。
    }
  }

  // ---------------------------------------------------------------- 端口回调（ClientSink 转进来）

  onHeaders(status: number, headers: Record<string, string>): void {
    if (!this.live) {
      return;
    }
    this.status = status;
    const lower: Record<string, string> = {};
    for (const k of Object.keys(headers)) {
      lower[k.toLowerCase()] = headers[k];
    }
    this.headers = lower;
    const type: string = (lower['content-type'] ?? '').toLowerCase();
    this.streaming = status >= 200 && status < 300 && type.indexOf('text/event-stream') >= 0;
    // R1-09（G33）：响应头不算「一行」，不重置 30 秒计时（首行等待期限从请求发出起算）。
  }

  /** 响应头的 X-Trace-Id（还没收到响应头为空串）。 */
  get headerTraceId(): string {
    return this.headers['x-trace-id'] ?? '';
  }

  onData(chunk: string): void {
    if (!this.live) {
      return;
    }
    if (!this.streaming) {
      this.jsonBody += chunk;
      return;
    }
    const items: AgentJsonObject[] = this.sse.feed(chunk);
    if (this.sse.linesSeen !== this.lines) {
      this.lines = this.sse.linesSeen;
      this.arm();
    }
    for (const item of items) {
      if (!this.live) {
        return;
      }
      if (item['kindRaw'] === AgentSseKind.PING) {
        this.emit(new AgentStreamEvent(AgentStreamEventKind.PING));
        continue;
      }
      const frame: AgentFrame = AgentFrameDecoder.frame(item);
      if (!frame.ok) {
        // 只记事件名与结果（不记 data，G05、G15）。
        const name: AgentJsonValue | undefined = item['event'];
        this.log('agent frame dropped ' + (typeof name === 'string' ? name as string : '-') + ' ' + frame.result);
      }
      this.emit(new AgentStreamEvent(AgentStreamEventKind.FRAME, frame));
    }
  }

  onEnd(): void {
    if (!this.live) {
      return;
    }
    if (!this.streaming) {
      this.finish(new AgentStreamEvent(AgentStreamEventKind.JSON, null,
        AgentHttpResult.of(this.status, this.headers, this.jsonBody)));
      return;
    }
    this.sse.finish();
    this.finish(new AgentStreamEvent(AgentStreamEventKind.EOF));
  }

  onFailure(): void {
    if (!this.live) {
      return;
    }
    this.finish(new AgentStreamEvent(AgentStreamEventKind.FAILED, null, AgentHttpResult.network()));
  }

  /** 已收到 SSE 响应头（流已开始）。 */
  get started(): boolean {
    return this.streaming;
  }

  private finish(event: AgentStreamEvent): void {
    this.live = false;
    this.disarm();
    this.handle = null;
    this.emit(event);
  }

  /** 交给控制器：带发起时的票据与响应头的 trace_id。 */
  private emit(event: AgentStreamEvent): void {
    event.traceId = this.headerTraceId;
    this.deliver(this.ticket, event);
  }

  private arm(): void {
    this.disarm();
    this.timerId = this.timer.schedule(StreamClient.IDLE_TIMEOUT_MS, (): void => {
      this.timerId = -1;
      if (!this.live) {
        return;
      }
      // 断线：本地关闭连接，再交出 timeout（控制器把消息记为 disconnected 并给【重试】）。
      const h: AgentStreamHandle | null = this.handle;
      this.handle = null;
      this.live = false;
      try {
        h?.cancel();
      } catch (e) {
        // 忽略。
      }
      this.emit(new AgentStreamEvent(AgentStreamEventKind.TIMEOUT));
    });
  }

  private disarm(): void {
    if (this.timerId !== -1) {
      this.timer.cancel(this.timerId);
      this.timerId = -1;
    }
  }
}

class ClientSink<T> implements AgentStreamSink {
  private readonly client: StreamClient<T>;

  constructor(client: StreamClient<T>) {
    this.client = client;
  }

  onHeaders(status: number, headers: Record<string, string>): void {
    this.client.onHeaders(status, headers);
  }

  onData(chunk: string): void {
    this.client.onData(chunk);
  }

  onEnd(): void {
    this.client.onEnd();
  }

  onFailure(): void {
    this.client.onFailure();
  }
}
