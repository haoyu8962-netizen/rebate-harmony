// APP-10 §2 第 4 条：StreamClient（界面无关）。一次 run 一个实例：发 sendAgentMessage → 按响应 Content-Type 分流
// （text/event-stream → 增量喂 AgentSse；其他 → 统一外壳 JSON 错误，G24）→ 每一帧连同发起时的 run 票据交给控制器（控制器先比票据）。
// - 30 秒内没收到任何一行（含 `: ping` 与空行）→ 断线（G33：从请求发出起算，连接建立前的等待也计入；只有收到完整的 SSE 行才重置，
//   响应头与半行都不延长期限（harmony-review-r1 R1-09）；计时器绑定本实例）。
// - 响应头的 X-Trace-Id 随每个事件交回（流内 error 帧没有 trace_id，5xxxx 文案的 trace6 用它，R1-07）。
// - cancel()：同步关闭连接、停计时、本实例作废；之后到达的任何字节一律丢弃（不解析、不交付）。
// APP-10b（F-X-04）：契约 40cfc268 有 7 个 /v1/agent operation，真实端口 ApiAgentContractPort 经 ApiClient 管线实现（流式经 ApiClient.stream，
// 鸿蒙 RCP 增量回调，G37）；Debug / Staging 的本机假服务在同一个实际传输入口按 DebugMockGate 接管。控制器与 Reducer 代码路径不变。
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentSse, AgentSseKind } from './AgentSse';
import { AgentFrame, AgentFrameDecoder, AgentFrameResult } from './AgentDecoder';
import { AgentSeqDecision, AgentSeqGuard } from './AgentTransport';
import { ApiStreamRoutingPolicy } from '../network/ApiStream';
import { StreamUtf8Decoder } from '../network/StreamUtf8Decoder';

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
  /** 归属键与子归属之间的分隔符（cancelOwned(scoped(key, scope)) 只取消这个子归属，harmony-review-r1 R1-11）。 */
  static readonly SCOPE_SEP: string = '\u0002';
  readonly identityKey: string;
  /** 基本模式不发（BR-ID-11）；游客为 true 时不带令牌由端口自己处理（x-auth: optional）。 */
  readonly anonymous: boolean;
  readonly sendAllowed: () => boolean;
  readonly owner: () => boolean;
  /** 子归属（如某一轮的 run：【停止】只同步取消这一轮的建会话请求）；空串 = 只按归属键。 */
  scope: string = '';

  constructor(identityKey: string, anonymous: boolean, sendAllowed: () => boolean, owner: () => boolean) {
    this.identityKey = identityKey;
    this.anonymous = anonymous;
    this.sendAllowed = sendAllowed;
    this.owner = owner;
  }

  /** cancelOwned 的子归属键：归属键 + 分隔符 + 子归属。 */
  static scoped(identityKey: string, scope: string): string {
    return identityKey + AgentCall.SCOPE_SEP + scope;
  }

  /** 「除这个子归属以外」的取消键（R1-11 的反向；子归属前加 EXCEPT）。 */
  static readonly EXCEPT: string = '!';

  /**
   * cancelOwned 的反向子归属键（harmony-review-r2 R2-03）：取消这个归属键下除该子归属以外的全部在途请求——【停止】同步取消历史 / 翻页 / 反馈 /
   * 举报 / 重载 / 建会话，只留下这一轮的流（meta 前停止最多等 30 秒取 run_id，G26）。不认识的实现按不匹配处理（什么都不取消）。
   */
  static except(identityKey: string, scope: string): string {
    return identityKey + AgentCall.SCOPE_SEP + AgentCall.EXCEPT + scope;
  }
}

/**
 * 流式响应的接收端（端口按到达顺序调用；cancel 之后端口可能仍回调，StreamClient 丢弃并计数）。APP-10b：字节入口（onBytes，原始字节，
 * 解码只在 Core 的 StreamUtf8Decoder 做一次）；真实端口经 ApiClient.stream 已解好统一外壳的非流结果交 onResult。
 */
export interface AgentStreamSink {
  onHeaders(status: number, headers: Record<string, string>): void;

  onBytes(chunk: ArrayBuffer): void;

  onEnd(): void;

  /** 断连、超时等传输失败（没有完整的 HTTP 响应，或流中途断开）。 */
  onFailure(): void;

  /** 没有成为流：统一外壳（含 10002 刷新重放后的最终结果）、无外壳、本地没发出。 */
  onResult(result: AgentHttpResult): void;
}

export interface AgentStreamHandle {
  /** 同步关闭连接（还没发出的不再发出）。 */
  cancel(): void;
}

/** 历史、反馈、举报（APP-10b §2 第 3 条新增的三个能力；与 AgentContractPort 分开声明，APP-10 的测试替身不必实现，鸿蒙追加 H 号）。 */
export interface AgentConversationPort {
  /** GET /v1/agent/sessions/{id}/messages（cursor 不透明、limit 1–50）。autoRetry=false：断线类重载自己退避，不叠 GET 自动重试（G35）。 */
  listMessages(sessionId: string, cursor: string | null, limit: number, call: AgentCall, autoRetry: boolean):
    Promise<AgentHttpResult>;

  /** POST /v1/agent/messages/{message_id}/feedback {feedback: up|down}（不幂等、不带 Idempotency-Key）。 */
  setFeedback(messageId: string, value: string, call: AgentCall): Promise<AgentHttpResult>;

  /** POST /v1/agent/messages/{message_id}/report {reason}（1–200 字；没有 x-step-up）。 */
  report(messageId: string, reason: string, call: AgentCall): Promise<AgentHttpResult>;
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

  /**
   * 作废这个归属键的全部在途请求（控制器作废、新对话、AI 10004、30501 时同步调用）；传 AgentCall.scoped(key, scope) 时只取消该子归属
   * （【停止】这一轮的建会话请求）；传 AgentCall.except(key, scope) 时取消除该子归属以外的全部（【停止】留下这一轮的流，R2-03）。
   * 不认识子归属的实现按不匹配处理（什么都不取消）。
   */
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
  /** 单轮总时长到（G16，代拟 90 秒）：按断线收尾。 */
  static readonly ROUND_LIMIT: string = 'round_limit';
  /** 发现缺号（AgentSeqGuard）：本条 incomplete，连接保持只等终止帧或断线（G11、G36）。 */
  static readonly SEQ_GAP: string = 'seq_gap';
  /** 缺号之后到达的终止帧（不交 Reducer；10004 仍要锁同意闸门，其余触发重载）。 */
  static readonly GAP_TERMINAL: string = 'gap_terminal';
  /** 单帧 data / 半行超过字节上限（G22）：本轮 limited、关连接。 */
  static readonly LIMITED: string = 'limited';
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

/**
 * 一次 run 的流客户端（APP-10b 改造）。deliver 由控制器给：每个事件都带发起时的票据（这里不认识票据的结构，只原样交回）。
 * - 字节入口：响应头按 Content-Type 分流（G19）；SSE 字节交 AgentSse.feedBytes（字节上限在解码前计，超限 → LIMITED 并关连接）。
 * - 30 秒空闲：从请求发出起算，只有完整的 SSE 行重置；响应头、半行、JSON 正文的分块都不重置（APP-10 G33、H26）。另加单轮总时长上限
 *   ROUND_LIMIT_MS（G16，代拟 90 秒，编排者补充第 6 条），到时按断线收尾。
 * - 帧交 Reducer 之前经 AgentSeqGuard（缺号 → SEQ_GAP，之后不再交内容帧，只等终止帧或断线）。
 * - cancel()：同步关闭连接、停全部计时、本实例作废；之后到达的任何字节一律丢弃（dropped 计数，delivered 不再增加）。
 */
export class StreamClient<T> {
  static readonly IDLE_TIMEOUT_MS: number = 30000;
  static readonly ROUND_LIMIT_MS: number = 90000;
  /** 非流响应正文的读取上限（统一外壳很小；超出按没有统一外壳）。 */
  static readonly JSON_MAX_BYTES: number = 1048576;
  private readonly port: AgentContractPort;
  private readonly timer: AgentTimer;
  private readonly ticket: T;
  private readonly deliver: (ticket: T, event: AgentStreamEvent) => void;
  private readonly sse: AgentSse = new AgentSse();
  private readonly guard: AgentSeqGuard = new AgentSeqGuard();
  private handle: AgentStreamHandle | null = null;
  private timerId: number = -1;
  private roundId: number = -1;
  private live: boolean = false;
  private streaming: boolean = false;
  private jsonChunks: Uint8Array[] = [];
  private jsonSize: number = 0;
  private status: number = 0;
  private headers: Record<string, string> = {};
  private lines: number = 0;
  private gapReported: boolean = false;
  /** 交给控制器的帧数（FRAME 事件；抓包断言「作废之后 0 帧」）。 */
  delivered: number = 0;
  /** 作废之后到达、被丢弃的回调数。 */
  dropped: number = 0;
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

  /** 已发现缺号（本条 incomplete）。 */
  get incomplete(): boolean {
    return this.guard.incomplete;
  }

  start(sessionId: string, body: string, call: AgentCall): void {
    if (this.live || this.handle !== null) {
      return;
    }
    this.live = true;
    this.arm();
    this.roundId = this.timer.schedule(StreamClient.ROUND_LIMIT_MS, (): void => {
      this.roundId = -1;
      this.expire(AgentStreamEventKind.ROUND_LIMIT);
    });
    const sink: AgentStreamSink = new ClientSink<T>(this);
    let handle: AgentStreamHandle | null = null;
    try {
      handle = this.port.sendMessage(sessionId, body, call, sink);
    } catch (e) {
      handle = null;
    }
    if (!this.live) {
      // 发出前已被同步取消或同步收尾（端口同步回调了终结）。
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
    this.disarmAll();
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
      this.dropped++;
      return;
    }
    this.status = status;
    const lower: Record<string, string> = {};
    for (const k of Object.keys(headers)) {
      lower[k.toLowerCase()] = headers[k];
    }
    this.headers = lower;
    this.streaming = ApiStreamRoutingPolicy.isStream(status, lower['content-type'] ?? null);
    if (lower['content-encoding'] !== undefined && lower['content-encoding'] !== 'identity') {
      // G17：请求了 identity 仍收到压缩：由网络栈透明解压，只记本机日志。
      this.log('agent stream content-encoding ' + lower['content-encoding']);
    }
    // R1-09（G33）：响应头不算「一行」，不重置 30 秒计时（首行等待期限从请求发出起算）。
  }

  /** 响应头的 X-Trace-Id（还没收到响应头为空串）。 */
  get headerTraceId(): string {
    return this.headers['x-trace-id'] ?? '';
  }

  onBytes(chunk: ArrayBuffer): void {
    if (!this.live) {
      this.dropped++;
      return;
    }
    if (!this.streaming) {
      // JSON 正文的分块不重置计时（H26）。
      this.jsonSize += chunk.byteLength;
      if (this.jsonSize <= StreamClient.JSON_MAX_BYTES) {
        this.jsonChunks.push(new Uint8Array(chunk.slice(0)));
      }
      return;
    }
    const items: AgentJsonObject[] = this.sse.feedBytes(chunk);
    if (this.sse.linesSeen !== this.lines) {
      this.lines = this.sse.linesSeen;
      this.arm();
    }
    for (const item of items) {
      if (!this.live) {
        return;
      }
      const kind: AgentJsonValue | undefined = item['kindRaw'];
      if (kind === AgentSseKind.PING) {
        this.emit(new AgentStreamEvent(AgentStreamEventKind.PING));
        continue;
      }
      if (kind === AgentSseKind.TOO_LARGE) {
        // G22：只记事件名与两个数字（G13 不发 agent_stream_frame_too_large）。
        this.log('agent stream too_large lines=' + String(this.lines));
        this.close();
        this.finish(new AgentStreamEvent(AgentStreamEventKind.LIMITED));
        return;
      }
      if (kind !== AgentSseKind.FRAME) {
        continue;
      }
      const frame: AgentFrame = AgentFrameDecoder.frame(item);
      if (frame.result === AgentFrameResult.INVALID) {
        // 只记事件名与结果（不记 data，G05、G15）。
        const name: AgentJsonValue | undefined = item['event'];
        this.log('agent frame dropped ' + (typeof name === 'string' ? name as string : '-') + ' ' + frame.result);
        continue;
      }
      this.route(frame);
    }
    if (this.sse.invalidUtf8 > 0 && this.lines > 0 && this.sse.invalidUtf8 === 1) {
      this.log('agent stream invalid utf8');
    }
  }

  private route(frame: AgentFrame): void {
    const decision: string = this.guard.check(frame.id, frame.event);
    if (decision === AgentSeqDecision.DELIVER) {
      this.delivered++;
      this.emit(new AgentStreamEvent(AgentStreamEventKind.FRAME, frame));
      return;
    }
    if (decision === AgentSeqDecision.DUPLICATE) {
      return;
    }
    if (!this.gapReported) {
      this.gapReported = true;
      // G13：agent_stream_seq_gap 不发，只记本机日志（两个数字）。
      this.log('agent stream seq_gap expected=' + String(this.guard.lastApplied + 1) + ' got=' + String(frame.id));
      this.emit(new AgentStreamEvent(AgentStreamEventKind.SEQ_GAP));
    }
    if (AgentSeqGuard.isTerminal(frame.event) && frame.ok && this.live) {
      this.emit(new AgentStreamEvent(AgentStreamEventKind.GAP_TERMINAL, frame));
    }
  }

  onEnd(): void {
    if (!this.live) {
      this.dropped++;
      return;
    }
    if (!this.streaming) {
      this.finish(new AgentStreamEvent(AgentStreamEventKind.JSON, null,
        AgentHttpResult.of(this.status, this.headers, this.jsonText())));
      return;
    }
    this.sse.finish();
    this.finish(new AgentStreamEvent(AgentStreamEventKind.EOF));
  }

  onFailure(): void {
    if (!this.live) {
      this.dropped++;
      return;
    }
    this.finish(new AgentStreamEvent(AgentStreamEventKind.FAILED, null, AgentHttpResult.network()));
  }

  onResult(result: AgentHttpResult): void {
    if (!this.live) {
      this.dropped++;
      return;
    }
    this.finish(new AgentStreamEvent(AgentStreamEventKind.JSON, null, result));
  }

  /** 已收到 SSE 响应头（流已开始）。 */
  get started(): boolean {
    return this.streaming;
  }

  private jsonText(): string {
    if (this.jsonSize > StreamClient.JSON_MAX_BYTES) {
      return '';
    }
    const all: Uint8Array = new Uint8Array(this.jsonSize);
    let at: number = 0;
    for (const c of this.jsonChunks) {
      all.set(c, at);
      at += c.length;
    }
    this.jsonChunks = [];
    return StreamUtf8Decoder.decodeAll(all);
  }

  /** 本地关闭连接（不交付终结事件）。 */
  private close(): void {
    const h: AgentStreamHandle | null = this.handle;
    this.handle = null;
    try {
      h?.cancel();
    } catch (e) {
      // 忽略。
    }
  }

  private finish(event: AgentStreamEvent): void {
    this.live = false;
    this.disarmAll();
    this.handle = null;
    this.emit(event);
  }

  /** 交给控制器：带发起时的票据与响应头的 trace_id。 */
  private emit(event: AgentStreamEvent): void {
    event.traceId = this.headerTraceId;
    this.deliver(this.ticket, event);
  }

  private expire(kind: string): void {
    if (!this.live) {
      return;
    }
    // 断线：本地关闭连接，再交出（控制器把消息记为 disconnected 并给【重试】）。
    this.live = false;
    this.disarmAll();
    this.close();
    this.emit(new AgentStreamEvent(kind));
  }

  private arm(): void {
    this.disarm();
    this.timerId = this.timer.schedule(StreamClient.IDLE_TIMEOUT_MS, (): void => {
      this.timerId = -1;
      this.expire(AgentStreamEventKind.TIMEOUT);
    });
  }

  private disarm(): void {
    if (this.timerId !== -1) {
      this.timer.cancel(this.timerId);
      this.timerId = -1;
    }
  }

  private disarmAll(): void {
    this.disarm();
    if (this.roundId !== -1) {
      this.timer.cancel(this.roundId);
      this.roundId = -1;
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

  onBytes(chunk: ArrayBuffer): void {
    this.client.onBytes(chunk);
  }

  onEnd(): void {
    this.client.onEnd();
  }

  onFailure(): void {
    this.client.onFailure();
  }

  onResult(result: AgentHttpResult): void {
    this.client.onResult(result);
  }
}
