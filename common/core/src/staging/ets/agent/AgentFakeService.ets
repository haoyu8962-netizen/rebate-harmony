// Debug / Staging（core 模块 staging target）：Agent 四个待定 operation 的本机假服务（APP-10 §2 第 4 条，G01）。只在 product=staging 编译，
// Release 没有本文件（release-scan 查 COULI_AGENT_FAKE_APP10_7d3e15）。不连任何地址、不做真实账号操作；数据是契约 fixture 与合成数据。
// 环境闸门（APP-11 第 10、16 条）：每一次实际「发包」（建会话、取当前会话、发消息、停止）都在这里统一核对「假服务打开 + 当前环境允许调试假数据」
// （DebugMockGate，prod 不允许）与调用方的 sendAllowed；不通过就不发（notSent / 传输失败），测试包连 prod 时不注入假流。
// fixture 的 ndjson 逐行转成 SSE 文本（event / id / data 三行 + 空行，ping → `: ping`），可配置每帧间隔、在某行后断开、在某行后挂起不发（测 30 秒）。
import { util } from '@kit.ArkTS';
import { AppEnvironment } from '../../../main/ets/config/AppEnvironment';
import { AgentJson, AgentJsonObject } from '../../../main/ets/agent/AgentJson';
import { AgentSse } from '../../../main/ets/agent/AgentSse';
import {
  AgentCall, AgentContractPort, AgentHttpResult, AgentStreamHandle, AgentStreamSink, AgentTimer
} from '../../../main/ets/agent/StreamClient';
import { DebugMockGate } from '../network/DebugMockTransport';

export const AGENT_FAKE_MARKER: string = 'COULI_AGENT_FAKE_APP10_7d3e15';

/** 一次 sendAgentMessage 的回答脚本。 */
export class AgentFakeScript {
  /** fixture 原文（ndjson）；为 null 时按 errorCode 回 JSON。 */
  ndjson: string | null = null;
  /** 每行之间的间隔（毫秒）。 */
  intervalMs: number = 60;
  /** 在第 n 行（从 1 起，计 ping）之后断开（连接正常结束、没有终止帧）；null = 不断开。 */
  disconnectAfterLine: number | null = null;
  /** 在第 n 行之后挂起不发（不结束，测 30 秒断线）；null = 不挂起。 */
  hangAfterLine: number | null = null;
  /** JSON 错误（非 SSE）：code、HTTP 状态、data、Retry-After、trace_id。 */
  errorCode: number = 0;
  errorStatus: number = 422;
  errorData: AgentJsonObject = {};
  retryAfter: string | null = null;
  traceId: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';
  /** SSE 响应头 X-Trace-Id（空串不带；流内 error 帧没有 trace_id，5xxxx 文案用它，R1-07）。 */
  headerTraceId: string = '';
  /** 响应头在请求发出后多少毫秒到达（测 G33：响应头不重置 30 秒首行计时）；之后的行在它之后按间隔下发。 */
  headersDelayMs: number = 0;
}

class FakeStream implements AgentStreamHandle {
  readonly owner: string;
  private readonly timer: AgentTimer;
  private ids: number[] = [];
  private closed: boolean = false;

  constructor(owner: string, timer: AgentTimer) {
    this.owner = owner;
    this.timer = timer;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  later(ms: number, run: () => void): void {
    if (this.closed) {
      return;
    }
    this.ids.push(this.timer.schedule(ms, (): void => {
      if (!this.closed) {
        run();
      }
    }));
  }

  cancel(): void {
    this.closed = true;
    for (const id of this.ids) {
      this.timer.cancel(id);
    }
    this.ids = [];
  }
}

export class AgentFakeService implements AgentContractPort {
  static readonly marker: string = AGENT_FAKE_MARKER;
  private readonly enabled: () => boolean;
  private readonly environment: () => AppEnvironment | undefined;
  private readonly timer: AgentTimer;
  private readonly script: (body: string) => AgentFakeScript;
  private streams: FakeStream[] = [];
  private sessionSeq: number = 0;
  /** 本机假的「AI 同意已记录」（recordConsent 成功后由 App 告知；撤回清零）。 */
  consentGranted: boolean = true;
  /** 第一次进页面返回 10004（ai_third_party）的场景。 */
  consentOnLoad: boolean = false;
  /**
   * 统计（测试与冒烟核对：实际「发出」的次数）。只记次数，不保存任何请求正文（text / context 不在假服务里长期留存；撤回同意、换号、切环境后
   * 不可再读到，harmony-review-r1 R1-12）。测试要看正文时在测试替身里包一层端口自己记。
   */
  sent: number = 0;
  cancels: number = 0;

  constructor(enabled: () => boolean, environment: () => AppEnvironment | undefined, timer: AgentTimer,
    script: (body: string) => AgentFakeScript) {
    this.enabled = enabled;
    this.environment = environment;
    this.timer = timer;
    this.script = script;
  }

  /** 此刻能不能由本机假服务回答（与传输入口同一道检查）。 */
  allowed(call: AgentCall): boolean {
    let ok: boolean = false;
    try {
      ok = DebugMockGate.allowed(this.enabled(), this.environment()) && call.sendAllowed();
    } catch (e) {
      ok = false;
    }
    return ok;
  }

  private answer(code: number, data: AgentJsonObject, status: number = 200): Promise<AgentHttpResult> {
    const body: AgentJsonObject = {};
    body['code'] = code;
    body['msg'] = code === 0 ? 'ok' : 'error';
    body['data'] = data;
    body['trace_id'] = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';
    return Promise.resolve(AgentHttpResult.of(status, {}, JSON.stringify(body)));
  }

  createSession(call: AgentCall): Promise<AgentHttpResult> {
    if (!this.allowed(call)) {
      return Promise.resolve(AgentHttpResult.notSentResult());
    }
    this.sent++;
    this.sessionSeq++;
    const session: AgentJsonObject = {};
    session['id'] = 'fake-session-' + String(this.sessionSeq);
    const data: AgentJsonObject = {};
    data['session'] = session;
    return this.answer(0, data);
  }

  currentSession(call: AgentCall): Promise<AgentHttpResult> {
    if (!this.allowed(call)) {
      return Promise.resolve(AgentHttpResult.notSentResult());
    }
    this.sent++;
    if (this.consentOnLoad && !this.consentGranted) {
      const data: AgentJsonObject = {};
      data['consent_type'] = 'ai_third_party';
      return this.answer(10004, data, 403);
    }
    const data: AgentJsonObject = {};
    data['session'] = null;
    return this.answer(0, data);
  }

  sendMessage(_sessionId: string, body: string, call: AgentCall, sink: AgentStreamSink): AgentStreamHandle {
    const stream: FakeStream = new FakeStream(call.identityKey, this.timer);
    if (!this.allowed(call)) {
      stream.later(0, (): void => sink.onFailure());
      return stream;
    }
    this.sent++;
    this.streams.push(stream);
    if (!this.consentGranted) {
      const data: AgentJsonObject = {};
      data['consent_type'] = 'ai_third_party';
      this.json(stream, sink, 403, 10004, data, null, '');
      return stream;
    }
    const s: AgentFakeScript = this.script(body);
    if (s.ndjson === null) {
      this.json(stream, sink, s.errorStatus, s.errorCode === 0 ? 50001 : s.errorCode, s.errorData, s.retryAfter,
        s.traceId);
      return stream;
    }
    const lines: string[] = (s.ndjson as string).split('\n').filter((l: string): boolean => l.trim().length > 0);
    const headers: Record<string, string> = {};
    headers['content-type'] = 'text/event-stream; charset=utf-8';
    if (s.headerTraceId.length > 0) {
      headers['x-trace-id'] = s.headerTraceId;
    }
    stream.later(s.headersDelayMs, (): void => sink.onHeaders(200, headers));
    let at: number = s.headersDelayMs;
    for (let i: number = 0; i < lines.length; i++) {
      at += s.intervalMs;
      const text: string = AgentSse.sseTextOfNdjsonLine(lines[i]);
      const n: number = i + 1;
      // 字节块下发（APP-10b：sink 只有字节入口，解码在 Core 的 StreamUtf8Decoder 里做一次）。
      stream.later(at, (): void => sink.onBytes(AgentFakeService.utf8(text)));
      if (s.hangAfterLine !== null && n >= (s.hangAfterLine as number)) {
        return stream;
      }
      if (s.disconnectAfterLine !== null && n >= (s.disconnectAfterLine as number)) {
        stream.later(at + 1, (): void => sink.onEnd());
        return stream;
      }
    }
    stream.later(at + 1, (): void => sink.onEnd());
    return stream;
  }

  private json(stream: FakeStream, sink: AgentStreamSink, status: number, code: number, data: AgentJsonObject,
    retryAfter: string | null, traceId: string): void {
    const headers: Record<string, string> = {};
    headers['content-type'] = 'application/json';
    if (retryAfter !== null) {
      headers['retry-after'] = retryAfter;
    }
    const env: AgentJsonObject = {};
    env['code'] = code;
    env['msg'] = 'error';
    env['data'] = data;
    env['trace_id'] = traceId;
    stream.later(0, (): void => {
      sink.onHeaders(status, headers);
      sink.onBytes(AgentFakeService.utf8(JSON.stringify(env)));
      sink.onEnd();
    });
  }

  cancelRun(_runId: string, call: AgentCall): Promise<AgentHttpResult> {
    if (!this.allowed(call)) {
      return Promise.resolve(AgentHttpResult.notSentResult());
    }
    this.sent++;
    this.cancels++;
    return this.answer(0, {});
  }

  cancelOwned(identityKey: string): void {
    for (const s of this.streams) {
      if (s.owner === identityKey) {
        s.cancel();
      }
    }
    this.streams = this.streams.filter((s: FakeStream): boolean => !s.isClosed);
  }

  /** 文本 → UTF-8 字节（util.TextEncoder；只编码，解码仍只在 StreamUtf8Decoder）。 */
  static utf8(text: string): ArrayBuffer {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    const copy: Uint8Array = new Uint8Array(bytes.length);
    copy.set(bytes);
    return copy.buffer as ArrayBuffer;
  }

  /** 由请求体取 client_msg_id（同 ID 重发时回 duplicate 两帧，BR-AI-23 ⑥）。 */
  static clientMsgId(body: string): string | null {
    const o: AgentJsonObject | null = AgentJson.objectOf(AgentJson.parse(body));
    return o === null ? null : AgentJson.stringOf(o['client_msg_id']);
  }
}

export class AgentDebugSources {
  /** 假服务打开且当前环境允许调试假数据才给端口；否则与 Release 一样为 null（Agent 页「未开放」、不发请求）。 */
  static contract(fakeEnabled: boolean, environment: AppEnvironment | undefined, fake: AgentContractPort):
    AgentContractPort | null {
    return DebugMockGate.allowed(fakeEnabled, environment) ? fake : null;
  }
}
