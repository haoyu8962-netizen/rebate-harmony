// Debug / Staging（core 模块 staging target）：7 个 /v1/agent operation 的本机假服务，接在 ApiClient 下面的实际传输入口（APP-10b §2 第 12、13 条）。
// 只在 product=staging 编译，Release 没有本文件（release-scan 查同一标记 COULI_AGENT_FAKE_APP10_7d3e15）。由 entry 的 DebugFakeServer 经
// DebugMockTransport 同一道闸门（假服务打开 + 当前环境允许 MOCK_DATA，prod 不允许）接管；真实端口 ApiAgentContractPort 与 ApiClient 管线
// （公共头、可选 Authorization、admit、单飞刷新、10405、Retry-After）照常运行，假的只是「服务端」。不连任何地址、不做真实账号操作。
// - 流：fixture 的 ndjson 逐行转成 SSE 文本，再按字节切块下发（chunkSizes 循环，例如 1、3、17；多字节字符跨块），可加 BOM、\r\n、
//   一块多帧、指定行后断开 / 挂起、缺号、70 KiB 单帧、401 帧；非 200 的 JSON 外壳（42901 带 / 不带 Retry-After、10002、50401、50001）、
//   text/html 网关错误页、慢 JSON 正文。
// - 历史：按场景返回构造的历史页（契约 openapi active / expired 示例、收益卡历史形状、未知卡、误带金额的坏历史卡、多页游标、30504、10004）。
// - 反馈 / 举报 / 停止：可配置结果码与延迟。
// 只记次数（不保存任何请求正文、举报原因；APP-10 共性第 11 条）。
import { util } from '@kit.ArkTS';
import { AgentJson, AgentJsonObject } from '../../../main/ets/agent/AgentJson';
import { AgentSse } from '../../../main/ets/agent/AgentSse';
import { AgentTimer } from '../../../main/ets/agent/StreamClient';
import {
  HttpStreamTransport, HttpTransport, TransportFailure, TransportRequest, TransportResponse, TransportStreamSink
} from '../../../main/ets/network/HttpTransport';
import { AGENT_FAKE_MARKER, AgentFakeScript } from './AgentFakeService';

/** 一次在途的假流（取消时清掉全部计时）。 */
class FakeFlow {
  private ids: number[] = [];
  closed: boolean = false;
  private readonly timer: AgentTimer;

  constructor(timer: AgentTimer) {
    this.timer = timer;
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

  close(): void {
    this.closed = true;
    for (const id of this.ids) {
      this.timer.cancel(id);
    }
    this.ids = [];
  }
}

export class AgentFakeHistoryScenario {
  static readonly ACTIVE: string = 'active';
  static readonly EXPIRED: string = 'expired';
  static readonly PAGED: string = 'paged';
  static readonly BAD_AMOUNT: string = 'bad_amount';
  static readonly UNKNOWN_CARD: string = 'unknown_card';
  static readonly NONE: string = 'none';
}

export class AgentFakeTransport implements HttpTransport, HttpStreamTransport {
  static readonly marker: string = AGENT_FAKE_MARKER;
  private readonly timer: AgentTimer;
  private readonly script: (body: string) => AgentFakeScript;
  private readonly flows: Map<TransportRequest, FakeFlow> = new Map<TransportRequest, FakeFlow>();
  private readonly waits: Map<TransportRequest, FakeFlow> = new Map<TransportRequest, FakeFlow>();
  /** 当前会话（null = getCurrentAgentSession 回 session=null）。 */
  currentSessionId: string | null = null;
  /** 历史场景（AgentFakeHistoryScenario）。 */
  historyScenario: string = AgentFakeHistoryScenario.NONE;
  /** 历史 / 反馈 / 举报 / 停止 / 取会话 / 建会话的结果码（0 成功；-1 断网）。 */
  historyCode: number = 0;
  feedbackCode: number = 0;
  reportCode: number = 0;
  cancelCode: number = 0;
  currentCode: number = 0;
  createCode: number = 0;
  /** 非 0 时的 Retry-After（42901 用；null 不带）。 */
  retryAfter: string | null = '12';
  /** JSON 回答的延迟（毫秒）。 */
  delayMs: number = 300;
  /** 字节切块（循环使用；空 = 每行一块）。 */
  chunkSizes: number[] = [];
  /** 流开头加 BOM、行尾用 \r\n。 */
  bom: boolean = false;
  crlf: boolean = false;
  /** AI 同意已记录（recordConsent 成功后由 App 告知；没记录时发送、建会话、取会话回 10004）。 */
  consentGranted: boolean = true;
  /** 统计（只记次数）。 */
  sent: number = 0;
  streams: number = 0;
  cancels: number = 0;
  historyRequests: number = 0;
  feedbacks: number = 0;
  reports: number = 0;
  private sessionSeq: number = 0;

  constructor(timer: AgentTimer, script: (body: string) => AgentFakeScript) {
    this.timer = timer;
    this.script = script;
  }

  static handles(url: string): boolean {
    return url.indexOf('/v1/agent/') >= 0;
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    if (!request.admit()) {
      return Promise.resolve(TransportResponse.failed(TransportFailure.CANCELLED));
    }
    this.sent++;
    const url: string = request.url;
    let code: number = 0;
    let data: string = '{}';
    if (url.indexOf('/v1/agent/sessions/current') >= 0) {
      code = !this.consentGranted ? 10004 : this.currentCode;
      data = code === 10004 ? '{"consent_type":"ai_third_party"}' : (this.currentSessionId === null ? '{"session":null}' :
        '{"session":' + AgentFakeTransport.session(this.currentSessionId as string) + '}');
    } else if (url.indexOf('/messages') >= 0 && request.method === 'GET') {
      this.historyRequests++;
      code = this.historyCode;
      data = code === 0 ? this.historyPage(url) : (code === 10004 ? '{"consent_type":"ai_third_party"}' : '{}');
    } else if (url.indexOf('/v1/agent/sessions') >= 0 && request.method === 'POST') {
      code = !this.consentGranted ? 10004 : this.createCode;
      this.sessionSeq++;
      const id: string = '019a0000-0000-7000-8000-0000000009' + String(10 + this.sessionSeq);
      if (code === 0) {
        this.currentSessionId = id;
      }
      data = code === 10004 ? '{"consent_type":"ai_third_party"}' : AgentFakeTransport.session(id);
    } else if (url.indexOf('/cancel') >= 0) {
      this.cancels++;
      code = this.cancelCode;
    } else if (url.indexOf('/feedback') >= 0) {
      this.feedbacks++;
      code = this.feedbackCode;
      data = code === 10004 ? '{"consent_type":"ai_third_party"}' : '{}';
    } else if (url.indexOf('/report') >= 0) {
      this.reports++;
      code = this.reportCode;
      data = code === 20001 ? '{"fields":["reason"]}' : (code === 10004 ? '{"consent_type":"ai_third_party"}' : '{}');
    } else {
      code = 50001;
    }
    const flow: FakeFlow = new FakeFlow(this.timer);
    this.waits.set(request, flow);
    return new Promise<TransportResponse>((resolve: (r: TransportResponse) => void): void => {
      flow.later(this.delayMs, (): void => {
        this.waits.delete(request);
        resolve(code === -1 ? TransportResponse.failed(TransportFailure.DISCONNECT) : this.envelope(code, data));
      });
    });
  }

  cancel(request: TransportRequest): void {
    const flow: FakeFlow | undefined = this.waits.get(request);
    this.waits.delete(request);
    flow?.close();
  }

  stream(request: TransportRequest, sink: TransportStreamSink): void {
    if (!request.admit()) {
      sink.onFailure(TransportFailure.CANCELLED);
      return;
    }
    this.sent++;
    this.streams++;
    const flow: FakeFlow = new FakeFlow(this.timer);
    this.flows.set(request, flow);
    if (!this.consentGranted) {
      this.json(flow, sink, 403, 10004, '{"consent_type":"ai_third_party"}', null);
      return;
    }
    const s: AgentFakeScript = this.script(request.body ?? '');
    if (s.ndjson === null) {
      this.json(flow, sink, s.errorStatus, s.errorCode === 0 ? 50001 : s.errorCode, JSON.stringify(s.errorData),
        s.retryAfter);
      return;
    }
    const lines: string[] = (s.ndjson as string).split('\n').filter((l: string): boolean => l.trim().length > 0);
    const headers: Record<string, string> = {};
    headers['content-type'] = 'text/event-stream; charset=utf-8';
    headers['cache-control'] = 'no-cache';
    if (s.headerTraceId.length > 0) {
      headers['x-trace-id'] = s.headerTraceId;
    }
    flow.later(s.headersDelayMs, (): void => sink.onHeaders(200, headers));
    let at: number = s.headersDelayMs;
    let first: boolean = true;
    for (let i: number = 0; i < lines.length; i++) {
      at += s.intervalMs;
      let text: string = AgentSse.sseTextOfNdjsonLine(lines[i]);
      if (this.crlf) {
        text = text.split('\n').join('\r\n');
      }
      const bytes: Uint8Array = AgentFakeTransport.utf8((first && this.bom ? '﻿' : '') + text);
      first = false;
      for (const piece of this.pieces(bytes)) {
        flow.later(at, (): void => sink.onBytes(piece));
      }
      const n: number = i + 1;
      if (s.hangAfterLine !== null && n >= (s.hangAfterLine as number)) {
        return;
      }
      if (s.disconnectAfterLine !== null && n >= (s.disconnectAfterLine as number)) {
        flow.later(at + 1, (): void => this.end(request, sink));
        return;
      }
    }
    flow.later(at + 1, (): void => this.end(request, sink));
  }

  cancelStream(request: TransportRequest): void {
    const flow: FakeFlow | undefined = this.flows.get(request);
    this.flows.delete(request);
    flow?.close();
  }

  private end(request: TransportRequest, sink: TransportStreamSink): void {
    this.flows.delete(request);
    sink.onEnd();
  }

  /** 按 chunkSizes 循环切块（同一时刻按顺序下发）。 */
  private pieces(bytes: Uint8Array): ArrayBuffer[] {
    if (this.chunkSizes.length === 0) {
      return [AgentFakeTransport.buffer(bytes)];
    }
    const out: ArrayBuffer[] = [];
    let offset: number = 0;
    let index: number = 0;
    while (offset < bytes.length) {
      const size: number = Math.max(1, this.chunkSizes[index % this.chunkSizes.length]);
      out.push(AgentFakeTransport.buffer(bytes.subarray(offset, Math.min(bytes.length, offset + size))));
      offset += size;
      index++;
    }
    return out;
  }

  private json(flow: FakeFlow, sink: TransportStreamSink, status: number, code: number, data: string,
    retryAfter: string | null): void {
    const headers: Record<string, string> = {};
    headers['content-type'] = code === 50302 && status === 502 ? 'text/html' : 'application/json';
    if (retryAfter !== null) {
      headers['retry-after'] = retryAfter;
    }
    const body: string = headers['content-type'] === 'text/html' ? '<html>bad gateway</html>' :
      '{"code":' + String(code) + ',"msg":"error","data":' + data + ',"trace_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b"}';
    flow.later(0, (): void => {
      sink.onHeaders(status, headers);
      // 慢 JSON 正文：分两块（APP-10 H26：JSON 分块不重置 30 秒）。
      const bytes: Uint8Array = AgentFakeTransport.utf8(body);
      const half: number = Math.floor(bytes.length / 2);
      sink.onBytes(AgentFakeTransport.buffer(bytes.subarray(0, half)));
      sink.onBytes(AgentFakeTransport.buffer(bytes.subarray(half)));
      sink.onEnd();
    });
  }

  private envelope(code: number, data: string): TransportResponse {
    const headers: Record<string, string> = {};
    headers['content-type'] = 'application/json';
    if (code === 42901 && this.retryAfter !== null) {
      headers['retry-after'] = this.retryAfter as string;
    }
    const status: number = code === 0 ? 200 : code === 42901 ? 429 : code >= 50000 ? 503 : 400;
    return TransportResponse.ok(status, headers, '{"code":' + String(code) + ',"msg":"","data":' + data
      + ',"trace_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b"}');
  }

  /** 构造的历史页（标「构造」；active / expired 取契约 openapi 示例原文的形状）。 */
  private historyPage(url: string): string {
    const older: boolean = url.indexOf('cursor=') >= 0;
    switch (this.historyScenario) {
      case AgentFakeHistoryScenario.EXPIRED:
        return '{"items":[' + AgentFakeTransport.item('231', 'user', '2026-10-12T21:00:00+08:00', '返利什么时候到账', '[]', null)
          + ',' + AgentFakeTransport.item('232', 'assistant', '2026-10-12T21:00:05+08:00', '', '[]', 'cancelled')
          + '],"next_cursor":null,"expired":true}';
      case AgentFakeHistoryScenario.PAGED:
        if (older) {
          return '{"items":[' + AgentFakeTransport.item('201', 'user', '2026-10-14T09:00:00+08:00', '怎么提现', '[]', null)
            + ',' + AgentFakeTransport.item('202', 'assistant', '2026-10-14T09:00:03+08:00', '提现入口在钱包页。', '[]', 'stop')
            + '],"next_cursor":null,"expired":false}';
        }
        return AgentFakeTransport.activeData('opaque-cursor-older-page');
      case AgentFakeHistoryScenario.BAD_AMOUNT:
        return '{"items":[' + AgentFakeTransport.item('223', 'user', '2026-10-14T10:01:00+08:00', '我现在有多少收益', '[]', null)
          + ',' + AgentFakeTransport.item('224', 'assistant', '2026-10-14T10:01:04+08:00', '这是你当时的收益概况，以钱包页为准。',
            '[{"card_id":"c2","type":"earnings_summary","schema_version":1,"data":{"as_of":"2026-10-14T10:01:03+08:00",'
            + '"withdrawable_fen":1000,"estimated_total_fen":5678,"next_credit_period":"2026-11","credit_overdue":false,'
            + '"latest_withdrawal":{"title_key":"withdrawal_status.PENDING_REVIEW.label","amount_fen":2000},'
            + '"actions":[{"route":"Wallet","text_key":"agent.earnings.open_wallet"},{"route":"WithdrawRecords",'
            + '"text_key":"agent.earnings.open_records"}]},"fallback_text":"收益以钱包页显示为准。"}]', 'stop')
          + '],"next_cursor":null,"expired":false}';
      case AgentFakeHistoryScenario.UNKNOWN_CARD:
        return '{"items":[' + AgentFakeTransport.item('241', 'user', '2026-10-14T10:02:00+08:00', '有什么新功能', '[]', null)
          + ',' + AgentFakeTransport.item('242', 'assistant', '2026-10-14T10:02:03+08:00', '看看这个。',
            '[{"card_id":"c3","type":"future_card","schema_version":1,"data":{},"fallback_text":"当前版本暂不支持显示这张卡片，请升级后查看。"}]',
            'stop') + '],"next_cursor":null,"expired":false}';
      case AgentFakeHistoryScenario.ACTIVE:
        return AgentFakeTransport.activeData('opaque-cursor-older-page');
      default:
        return '{"items":[],"next_cursor":null,"expired":false}';
    }
  }

  private static activeData(cursor: string | null): string {
    const guide: string = '[{"card_id":"c1","type":"page_guide","schema_version":1,"data":{"route":"WithdrawRecords",'
      + '"text_key":"agent.guide.WithdrawRecords"},"fallback_text":"提现进度在提现记录里查看。"}]';
    const earnings: string = '[{"card_id":"c2","type":"earnings_summary","schema_version":1,"data":{"as_of":'
      + '"2026-10-14T10:01:03+08:00","actions":[{"route":"Wallet","text_key":"agent.earnings.open_wallet"},'
      + '{"route":"WithdrawRecords","text_key":"agent.earnings.open_records"}]},"fallback_text":"收益以钱包页显示为准。"}]';
    return '{"items":[' + AgentFakeTransport.item('221', 'user', '2026-10-14T10:00:00+08:00', '提现记录在哪看', '[]', null)
      + ',' + AgentFakeTransport.item('222', 'assistant', '2026-10-14T10:00:03+08:00', '提现进度在提现记录里查看。', guide, 'stop')
      + ',' + AgentFakeTransport.item('223', 'user', '2026-10-14T10:01:00+08:00', '我现在有多少收益', '[]', null)
      + ',' + AgentFakeTransport.item('224', 'assistant', '2026-10-14T10:01:04+08:00', '这是你当时的收益概况，以钱包页为准。',
        earnings, 'stop')
      + '],"next_cursor":' + (cursor === null ? 'null' : '"' + cursor + '"') + ',"expired":false}';
  }

  private static item(id: string, role: string, at: string, text: string, cards: string, finish: string | null): string {
    return '{"message_id":"019a0000-0000-7000-8000-000000000' + id + '","role":"' + role + '","created_at":"' + at
      + '","text":' + JSON.stringify(text) + ',"cards":' + cards + ',"finish_reason":'
      + (finish === null ? 'null' : '"' + finish + '"') + '}';
  }

  private static session(id: string): string {
    return '{"session_id":"' + id + '","started_at":"2026-10-14T10:00:00+08:00","last_active_at":"2026-10-14T10:01:04+08:00"}';
  }

  static utf8(text: string): Uint8Array {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    const copy: Uint8Array = new Uint8Array(bytes.length);
    copy.set(bytes);
    return copy;
  }

  private static buffer(bytes: Uint8Array): ArrayBuffer {
    const copy: Uint8Array = new Uint8Array(bytes.length);
    copy.set(bytes);
    return copy.buffer as ArrayBuffer;
  }

  /** 由请求体取 client_msg_id（同 ID 重发时回 duplicate 两帧）。不保存正文。 */
  static clientMsgId(body: string | null): string | null {
    const o: AgentJsonObject | null = body === null ? null : AgentJson.objectOf(AgentJson.parse(body));
    return o === null ? null : AgentJson.stringOf(o['client_msg_id']);
  }
}
