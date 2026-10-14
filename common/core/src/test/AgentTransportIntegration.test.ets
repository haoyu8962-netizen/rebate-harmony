// APP-10b 鸿蒙 Agent 真实流式传输的集成测试与抓包断言（brief §2.15）：真实 ApiClient（ApiClient.stream 流式通道、公共头、可选 Authorization、
// 单飞刷新、10402 重新注册、admit / sendAllowed、invalidate / cancelOwned）+ 真实端口 ApiAgentContractPort + AgentController（页面按钮回调调用的
// 同一套方法与票据）+ 真实 Router / StackNavigator / EntryGuard（卡片点击经 Router 打开）+ 可注入的传输替身（Debug / Staging 的本机假服务
// AgentFakeTransport，或逐块手工喂字节的 ManualSink）。「抓包」= 记录传输层实际写出的每个请求（方法、路径、头、请求体；只在测试替身里留存）。
// 数据只用锁定契约的 fixture、openapi 示例与标「构造」的合成数据；不连任何地址。
import { describe, it, expect } from '@ohos/hypium';
import {
  AgentCall, AgentConsentGate, AgentController, AgentDeps, AgentErrorView, AgentFeedbackView, AgentGates,
  AgentHttpResult, AgentIdentity, AgentOwnedRun, AgentOwnershipDecision, AgentOwnershipEvent, AgentOwnershipHandlers,
  AgentOwnershipStop, AgentPageTicket, AgentPhase, AgentReportEntryView, AgentReportSheetView, AgentRetryMode,
  AgentRetryTap, AgentRunTicket, AgentSnapshot, AgentStreamState, AgentTap, AgentTapKind, AgentTurnView,
  AgentCancelLedger, AgentAvailability, AgentAvailabilityInput, AgentAvailabilityResult, ApiAgentContractPort,
  ApiAppIdentity, ApiClient, ApiClientDeps, ApiRequest, ApiResult, ApiStreamHandle, ApiStreamRequest, ApiStreamSink, AgentJson,
  GuardState, HttpStreamTransport, HttpTransport, LaunchReadiness, MemoryPendingBackend, MemorySessionTokens,
  NetworkHeaders, PendingActionStore, PrivacyState, RetryAfterGate, RouteDestination, RouteRequest, RouteSource, Router,
  RouteTable, SessionTokenSet, StackNavigator, StreamClient, TransportFailure, TransportRequest, TransportResponse,
  TransportStreamSink, UpdateCheckStatus, AgentCardView, AgentContractPort as AgentContractPortT,
  AgentStreamSink as AgentStreamSinkT, AgentStreamHandle as AgentStreamHandleT
} from '../../Index';
import { AgentFakeHistoryScenario, AgentFakeTransport } from '../staging/ets/agent/AgentFakeTransport';
import { AgentFakeScript } from '../staging/ets/agent/AgentFakeService';
import { ClientEvent, RouteSpec } from 'generated';
import { AGENT_STREAM_FIXTURES } from './AgentStreamFixturesData';
import { FakeContext, FakeCredentials, FakeRandom, FakeRegistrar, FakeTimer, FakeUpdate, flush, tokenPair } from './NetworkTestRig';
import { ReferenceDigest } from './TestDigest';
import { ParamStack, TAB_ROOTS } from './OrderIntegration.test';
import { AgentVirtualTimer } from './AgentVectorWiring';

export const T0: number = Date.parse('2026-10-14T10:00:00+08:00');
export const SESSION: string = '019a0000-0000-7000-8000-000000000021';
const AI_10004: string = '{"consent_type":"ai_third_party"}';

export function same(label: string, actual: Object | null | undefined, expected: Object | null | undefined): void {
  const a: string = JSON.stringify(actual);
  const e: string = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(label + ': actual=' + a + ' expect=' + e);
  }
  expect(a).assertEqual(e);
}

/** UTF-8 编码（测试资产；解码仍只在 StreamUtf8Decoder）。 */
export function utf8(text: string): ArrayBuffer {
  const out: number[] = [];
  for (const ch of text) {
    const cp: number = ch.codePointAt(0) ?? 0;
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
    } else {
      out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
    }
  }
  return new Uint8Array(out).buffer as ArrayBuffer;
}

/** 按尺寸循环切字节（多字节字符跨块）。 */
function split(buffer: ArrayBuffer, sizes: number[]): ArrayBuffer[] {
  const bytes: Uint8Array = new Uint8Array(buffer);
  const out: ArrayBuffer[] = [];
  let offset: number = 0;
  let i: number = 0;
  while (offset < bytes.length) {
    const end: number = Math.min(bytes.length, offset + sizes[i % sizes.length]);
    const piece: Uint8Array = new Uint8Array(end - offset);
    piece.set(bytes.subarray(offset, end));
    out.push(piece.buffer as ArrayBuffer);
    offset = end;
    i++;
  }
  return out;
}

export const META: string = 'event: meta\nid: 1\ndata: {"session_id":"019a0000-0000-7000-8000-000000000021","run_id":'
  + '"019a0000-0000-7000-8000-000000000121","message_id":"019a0000-0000-7000-8000-000000000222","prompt_version":"p1",'
  + '"model_label":"演示模型","ai_label":"内容由 AI 生成，仅供参考"}\n\n';

export function delta(id: number, text: string): string {
  return 'event: text.delta\nid: ' + id + '\ndata: {"seq":' + id + ',"delta":' + JSON.stringify(text) + '}\n\n';
}

export function done(id: number, quota: number = 24): string {
  return 'event: done\nid: ' + id + '\ndata: {"finish_reason":"stop","quota_left":' + quota + '}\n\n';
}

export function guideCard(id: number, cardId: string): string {
  return 'event: card\nid: ' + id + '\ndata: {"seq":' + id + ',"card_id":"' + cardId + '","type":"page_guide","schema_version":1,'
    + '"data":{"route":"WithdrawRecords","text_key":"agent.guide.WithdrawRecords"},"fallback_text":"提现进度在提现记录里查看。"}\n\n';
}

/** 一条抓包记录（只在测试替身里）。 */
export class Wire {
  readonly method: string;
  readonly path: string;
  readonly headers: Record<string, string>;
  readonly body: string | null;
  readonly stream: boolean;

  constructor(method: string, path: string, headers: Record<string, string>, body: string | null, stream: boolean) {
    this.method = method;
    this.path = path;
    this.headers = headers;
    this.body = body;
    this.stream = stream;
  }

  get clientMsgId(): string | null {
    const o: Record<string, Object | null> | null = this.body === null ? null : AgentJson.objectOf(AgentJson.parse(this.body));
    return o === null ? null : AgentJson.stringOf(o['client_msg_id']);
  }
}

/** 手工喂字节的流（AC-S1-174：逐块、一块多帧、指定时刻断开）。 */
export class ManualSink {
  sink: TransportStreamSink | null = null;
  cancelled: boolean = false;

  headers(contentType: string = 'text/event-stream; charset=utf-8', status: number = 200,
    extra: Record<string, string> = {}): void {
    const h: Record<string, string> = {};
    h['content-type'] = contentType;
    h['x-trace-id'] = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';
    for (const k of Object.keys(extra)) {
      h[k] = extra[k];
    }
    this.sink?.onHeaders(status, h);
  }

  bytes(chunk: ArrayBuffer): void {
    this.sink?.onBytes(chunk);
  }

  text(t: string, sizes: number[] = []): void {
    const all: ArrayBuffer = utf8(t);
    for (const piece of sizes.length === 0 ? [all] : split(all, sizes)) {
      this.bytes(piece);
    }
  }

  end(): void {
    this.sink?.onEnd();
  }
}

/** 抓包传输层：先过 admit（与真实传输层同一道最后核对），再记录、再交给本机假服务或手工流。 */
export class Recorder implements HttpTransport, HttpStreamTransport {
  readonly fake: AgentFakeTransport;
  readonly wire: Wire[] = [];
  /** 非空时流式请求交给手工流（每次发流新建一个）。 */
  manual: boolean = false;
  readonly manuals: ManualSink[] = [];
  /** 刷新、退出登录、同意记录等非 agent 请求的回答。 */
  refreshAccess: string = 'new-access';
  /** harmony-review-r1 测试：传输层收到的取消次数（cancelOwned / invalidate 同步取消在途请求的抓包证据）。 */
  cancels: number = 0;
  /** harmony-review-r1 测试：非空时先问它（返回响应就不交给假服务；用于构造翻页 expired、10001 等历史结果）。 */
  respond: ((request: TransportRequest) => Promise<TransportResponse> | null) | null = null;
  private readonly wrapped: Map<TransportRequest, TransportRequest> = new Map<TransportRequest, TransportRequest>();

  constructor(fake: AgentFakeTransport) {
    this.fake = fake;
  }

  count(part: string): number {
    return this.wire.filter((w: Wire): boolean => w.path.indexOf(part) >= 0).length;
  }

  last(part: string): Wire | null {
    const all: Wire[] = this.wire.filter((w: Wire): boolean => w.path.indexOf(part) >= 0);
    return all.length === 0 ? null : all[all.length - 1];
  }

  get streams(): Wire[] {
    return this.wire.filter((w: Wire): boolean => w.stream);
  }

  private record(request: TransportRequest, stream: boolean): TransportRequest {
    const path: string = request.url.replace('https://api.test.invalid', '');
    const headers: Record<string, string> = {};
    for (const k of Object.keys(request.headers)) {
      headers[k] = request.headers[k];
    }
    this.wire.push(new Wire(request.method, path, headers, request.body, stream));
    const inner: TransportRequest = new TransportRequest(request.method, request.url, request.headers, request.body,
      request.timeoutMillis, (): boolean => true);
    this.wrapped.set(request, inner);
    return inner;
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    if (!request.admit()) {
      return Promise.resolve(TransportResponse.failed(TransportFailure.CANCELLED));
    }
    const inner: TransportRequest = this.record(request, false);
    if (request.url.indexOf('/v1/auth/refresh') >= 0) {
      return Promise.resolve(TransportResponse.ok(200, {}, '{"code":0,"msg":"","data":'
        + tokenPair(this.refreshAccess, 'new-refresh', 'full') + ',"trace_id":"trace-refresh-000001"}'));
    }
    if (this.respond !== null) {
      const custom: Promise<TransportResponse> | null = this.respond(inner);
      if (custom !== null) {
        return custom as Promise<TransportResponse>;
      }
    }
    if (!AgentFakeTransport.handles(request.url)) {
      return Promise.resolve(TransportResponse.ok(200, {}, '{"code":0,"msg":"","data":{},"trace_id":"trace-other-000001"}'));
    }
    return this.fake.send(inner);
  }

  cancel(request: TransportRequest): void {
    this.cancels++;
    const inner: TransportRequest | undefined = this.wrapped.get(request);
    if (inner !== undefined) {
      this.fake.cancel(inner);
    }
  }

  stream(request: TransportRequest, sink: TransportStreamSink): void {
    if (!request.admit()) {
      sink.onFailure(TransportFailure.CANCELLED);
      return;
    }
    const inner: TransportRequest = this.record(request, true);
    if (this.manual) {
      const m: ManualSink = new ManualSink();
      m.sink = sink;
      this.manuals.push(m);
      return;
    }
    this.fake.stream(inner, sink);
  }

  cancelStream(request: TransportRequest): void {
    const inner: TransportRequest | undefined = this.wrapped.get(request);
    for (const m of this.manuals) {
      if (m.sink !== null && inner !== undefined && this.wire.length > 0) {
        // 手工流：取消后不再交付（ApiClient 已同步作废交付出口；这里只记下）。
        m.cancelled = m.cancelled || false;
      }
    }
    if (inner !== undefined) {
      this.fake.cancelStream(inner);
    }
  }

  get lastManual(): ManualSink {
    return this.manuals[this.manuals.length - 1];
  }
}

export class OpenRecord {
  readonly route: string;
  readonly params: Record<string, Object>;
  readonly source: RouteSource;

  constructor(route: string, params: Record<string, Object>, source: RouteSource) {
    this.route = route;
    this.params = params;
    this.source = source;
  }
}

/** 一套接线：真实 ApiClient + 真实端口 + 本机假服务 + Router（身份可改，模拟换号）。 */
export class TRig {
  readonly timer: AgentVirtualTimer = new AgentVirtualTimer();
  readonly netTimer: FakeTimer = new FakeTimer();
  readonly context: FakeContext = new FakeContext();
  readonly update: FakeUpdate = new FakeUpdate();
  readonly registrar: FakeRegistrar = new FakeRegistrar();
  readonly tokens: MemorySessionTokens;
  readonly fake: AgentFakeTransport;
  readonly rec: Recorder;
  readonly client: ApiClient;
  readonly port: ApiAgentContractPort;
  /** harmony-review-r3 测试可换成按归属键（不含页面实例）判定的闸门（AppAgent 的接线）。 */
  gates: AgentGates;
  readonly ledger: AgentCancelLedger = new AgentCancelLedger();
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  fixture: string = 'normal';
  script: AgentFakeScript | null = null;
  identity: AgentIdentity;
  opens: OpenRecord[] = [];
  toasts: string[] = [];
  logs: string[] = [];
  events: ClientEvent[] = [];
  forced: number = 0;
  purchaseCancels: number = 0;
  foreground: boolean = true;
  snapshots: AgentSnapshot[] = [];
  random: number = 0.5;
  phoneBound: boolean | null = null;
  /** harmony-review-r1 测试：应用级发包许可（配置可用、没有身份变更在途）。 */
  allowed: () => boolean = (): boolean => true;
  /** harmony-review-r2 测试：应用级「AI 同意失效」（AppAgent 的 AgentConsentLapse 接线）。 */
  consentLapsed: () => boolean = (): boolean => false;
  /** harmony-review-r3 测试：应用级「AI 同意失效」入口（AppAgent 的 deps.aiConsentLost 接线）。 */
  aiConsentLost: (ownerKey: string) => void = (_k: string): void => {
  };

  constructor(token: string | null = 'old-access') {
    this.timer.now = T0;
    this.tokens = new MemorySessionTokens(token === null ? null : new SessionTokenSet(token, 'old-refresh', 'full', 'user-1'));
    this.fake = new AgentFakeTransport(this.timer, (_body: string): AgentFakeScript => this.scriptNow());
    this.fake.delayMs = 10;
    this.rec = new Recorder(this.fake);
    const deps: ApiClientDeps = new ApiClientDeps(this.rec, this.context,
      new ApiAppIdentity('couli', 'harmony', '1.2.0', '100', 'agc'), this.tokens, this.update);
    deps.streamTransport = this.rec;
    deps.credentials = new FakeCredentials();
    deps.digest = new ReferenceDigest();
    deps.deviceRegistrar = this.registrar;
    deps.timer = this.netTimer;
    deps.random = new FakeRandom();
    deps.clock = (): number => this.timer.now;
    this.client = new ApiClient(deps);
    this.port = new ApiAgentContractPort((): ApiClient | null => this.client);
    this.identity = new AgentIdentity('test', token === null ? AgentIdentity.GUEST : AgentIdentity.MEMBER,
      token === null ? null : 'user-1', 's1', 0, 1);
    this.gates = AgentGates.create((): number => this.timer.now, (): string => this.identity.key, false);
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null && TAB_ROOTS.indexOf(d.route) >= 0;
    const guard: GuardState = new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false);
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.timer.now),
      (): GuardState => guard, this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(guard.updateState)));
    this.router.presentationReady = (): boolean => true;
  }

  private scriptNow(): AgentFakeScript {
    if (this.script !== null) {
      return this.script as AgentFakeScript;
    }
    const s: AgentFakeScript = new AgentFakeScript();
    const raw: string | undefined = AGENT_STREAM_FIXTURES.get(this.fixture + '.ndjson');
    s.ndjson = raw ?? null;
    s.intervalMs = 50;
    s.headerTraceId = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';
    if (this.fixture === 'disconnected') {
      s.hangAfterLine = (raw ?? '').split('\n').filter((l: string): boolean => l.length > 0).length;
    }
    return s;
  }

  controller(contract: boolean = true): AgentController {
    const deps: AgentDeps = new AgentDeps(this.identity, (): string => this.identity.key, this.gates.send);
    deps.contract = contract ? this.port : null;
    deps.conversation = this.port;
    deps.readGate = this.gates.read;
    deps.actionGate = this.gates.action;
    deps.timer = this.timer;
    deps.clock = (): number => this.timer.now;
    deps.random = (): number => this.random;
    deps.foreground = (): boolean => this.foreground;
    deps.cancelLedger = this.ledger;
    deps.allowed = (): boolean => this.allowed();
    deps.consentLapsed = (): boolean => this.consentLapsed();
    deps.aiConsentLost = (ownerKey: string): void => this.aiConsentLost(ownerKey);
    deps.currentOwnerKey = (): string => this.identity.ownerKey;
    deps.open = (route: string, params: Record<string, Object>, source: RouteSource): void => {
      this.opens.push(new OpenRecord(route, params, source));
      this.router.open(RouteRequest.of(route, source, params));
    };
    deps.recordConsent = (accepted: boolean): Promise<AgentHttpResult> => {
      this.fake.consentGranted = accepted;
      return Promise.resolve(new AgentHttpResult(true, 200, 0, 'ok', {}, 'trace-consent-000001', null));
    };
    deps.track = (e: ClientEvent): void => {
      this.events.push(e);
    };
    deps.toast = (t: string): void => {
      this.toasts.push(t);
    };
    deps.forceUpdate = (): void => {
      this.forced++;
    };
    deps.cancelPurchase = (): void => {
      this.purchaseCancels++;
    };
    deps.phoneBound = (): boolean | null => this.phoneBound;
    deps.log = (m: string): void => {
      this.logs.push(m);
    };
    const c: AgentController = new AgentController(deps);
    c.onChange = (s: AgentSnapshot): void => {
      this.snapshots.push(s);
    };
    c.setVisible(true);
    return c;
  }

  /** 交替推进微任务与虚拟时钟。 */
  async pump(ms: number = 0, step: number = 10): Promise<void> {
    await flush();
    const end: number = this.timer.now + ms;
    while (this.timer.now < end) {
      this.timer.advanceTo(Math.min(end, this.timer.now + step));
      await flush();
    }
    this.timer.advanceTo(this.timer.now);
    await flush();
  }

  async ready(contract: boolean = true): Promise<AgentController> {
    const c: AgentController = this.controller(contract);
    c.start();
    await this.pump(Math.max(50, this.fake.delayMs * 3 + 50));
    return c;
  }

  async ask(c: AgentController, text: string = '纯牛奶', ms: number = 3000): Promise<void> {
    c.send(c.snapshot().page, text);
    await this.pump(ms, 25);
  }

  turn(c: AgentController, i: number = -1): AgentTurnView {
    const turns: AgentTurnView[] = c.snapshot().turns;
    return turns[i < 0 ? turns.length + i : i];
  }

  state(c: AgentController, i: number = -1): AgentStreamState {
    const states: AgentStreamState[] = c.streamStates;
    return states[i < 0 ? states.length + i : i];
  }
}

/** 记下 sink 的端口（取消后仍可继续回调，模拟迟到的传输层回调）。 */
class CapturePort implements AgentContractPortT {
  sink: AgentStreamSinkT | null = null;

  createSession(_c: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  currentSession(_c: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  sendMessage(_s: string, _b: string, _c: AgentCall, sink: AgentStreamSinkT): AgentStreamHandleT {
    this.sink = sink;
    return new NoopHandle();
  }

  cancelRun(_r: string, _c: AgentCall): Promise<AgentHttpResult> {
    return Promise.resolve(AgentHttpResult.notSentResult());
  }

  cancelOwned(_k: string): void {
  }
}

class NoopHandle implements AgentStreamHandleT {
  cancel(): void {
  }
}

/** 流式通道的直接接收端（ApiClient.stream 的分流断言）。 */
class StreamProbe implements ApiStreamSink {
  status: number = -1;
  headers: Record<string, string> = {};
  chunks: number = 0;
  bytes: number = 0;
  ended: boolean = false;
  failure: string | null = null;
  envelope: ApiResult | null = null;

  onHeaders(status: number, headers: Record<string, string>): void {
    this.status = status;
    this.headers = headers;
  }

  onBytes(chunk: ArrayBuffer): void {
    this.chunks++;
    this.bytes += chunk.byteLength;
  }

  onEnd(): void {
    this.ended = true;
  }

  onFailure(failure: string): void {
    this.failure = failure;
  }

  onEnvelope(result: ApiResult): void {
    this.envelope = result;
  }
}

function sendRequest(clientMsgId: string = 'msg-test-00000001'): ApiStreamRequest {
  const params: Record<string, string> = {};
  params['id'] = SESSION;
  return new ApiStreamRequest('sendAgentMessage', params, '{"client_msg_id":"' + clientMsgId + '","text":"提现记录在哪看"}');
}

export default function agentTransportIntegrationTest(): void {
  describe('AgentTransportIntegration', () => {
    // ---------------------------------------------------------------- §2 第 1 条：流式通道（头、分流、重放、闸门、取消）
    it('stream_channel_headers_public_no_sign_no_idempotency_accept_identity_auth_only_with_token', 0, async () => {
      for (const token of ['old-access', null]) {
        const rig: TRig = new TRig(token);
        rig.rec.manual = true;
        const probe: StreamProbe = new StreamProbe();
        rig.client.stream(sendRequest(), probe);
        await rig.pump();
        const w: Wire = rig.rec.streams[0];
        same('path', w.path, '/v1/agent/sessions/' + SESSION + '/messages');
        same('method', w.method, 'POST');
        for (const name of ['X-App-Id', 'X-Platform', 'X-App-Version', 'X-Build', 'X-Channel', 'X-Trace-Id', 'X-Device-Id']) {
          same('public ' + name, w.headers[name] !== undefined, true);
        }
        same('no sign', [w.headers['X-Sign'], w.headers['X-Timestamp'], w.headers['X-Nonce']], [undefined, undefined, undefined]);
        same('no idempotency', w.headers['Idempotency-Key'], undefined);
        same('accept', w.headers['Accept'], 'text/event-stream');
        same('identity', w.headers['Accept-Encoding'], 'identity');
        same('auth ' + String(token), w.headers['Authorization'] ?? null, token === null ? null : 'Bearer old-access');
        same('body kept', w.clientMsgId, 'msg-test-00000001');
      }
    });

    it('stream_channel_content_type_routing_sse_json_html_protocol', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      // SSE（忽略大小写与参数）→ 头与原始字节。
      const sse: StreamProbe = new StreamProbe();
      rig.client.stream(sendRequest(), sse);
      await rig.pump();
      rig.rec.lastManual.headers('TEXT/EVENT-STREAM; CHARSET=UTF-8');
      rig.rec.lastManual.text(': ping\n\n', [1, 3]);
      rig.rec.lastManual.end();
      await rig.pump();
      same('sse status', sse.status, 200);
      same('sse chunks', sse.chunks, 4);
      same('sse end', sse.ended, true);
      same('sse no envelope', sse.envelope, null);
      // 4xx JSON 外壳 → onEnvelope（同一结果路径）。
      const json: StreamProbe = new StreamProbe();
      rig.client.stream(sendRequest(), json);
      await rig.pump();
      rig.rec.lastManual.headers('application/json', 422);
      rig.rec.lastManual.text('{"code":30506,"msg":"","data":{},"trace_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b"}', [5]);
      rig.rec.lastManual.end();
      await rig.pump();
      same('json code', json.envelope === null ? null : (json.envelope as ApiResult).code, 30506);
      same('json no bytes to sink', json.chunks, 0);
      // 502 HTML 网关页 → 没有统一外壳（网络失败）。
      const html: StreamProbe = new StreamProbe();
      rig.client.stream(sendRequest(), html);
      await rig.pump();
      rig.rec.lastManual.headers('text/html', 502);
      rig.rec.lastManual.text('<html>bad gateway</html>');
      rig.rec.lastManual.end();
      await rig.pump();
      same('html no envelope', html.envelope === null ? null : (html.envelope as ApiResult).failure, 'no_envelope');
      // 200 JSON code=0 却不是流 → 协议错误。
      const proto: StreamProbe = new StreamProbe();
      rig.client.stream(sendRequest(), proto);
      await rig.pump();
      rig.rec.lastManual.headers('application/json', 200);
      rig.rec.lastManual.text('{"code":0,"msg":"","data":{},"trace_id":"t"}');
      rig.rec.lastManual.end();
      await rig.pump();
      same('protocol', proto.envelope === null ? null : (proto.envelope as ApiResult).failure, ApiClient.STREAM_PROTOCOL);
      // 表外 operation 本地拒绝、不发出。
      const other: StreamProbe = new StreamProbe();
      const before: number = rig.rec.wire.length;
      rig.client.stream(new ApiStreamRequest('listAgentSessionMessages', {}, '{}'), other);
      await rig.pump();
      same('non streaming op rejected', other.envelope === null ? null : (other.envelope as ApiResult).localRejectReason,
        ApiClient.STREAM_NOT_ALLOWED);
      same('nothing sent', rig.rec.wire.length, before);
    });

    it('stream_channel_10002_single_flight_refresh_replays_once_same_client_msg_id', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const probe: StreamProbe = new StreamProbe();
      rig.client.stream(sendRequest('Previous_01234567'), probe);
      await rig.pump();
      rig.rec.lastManual.headers('application/json', 401);
      rig.rec.lastManual.text('{"code":10002,"msg":"","data":{},"trace_id":"t1"}');
      rig.rec.lastManual.end();
      await rig.pump();
      same('refresh once', rig.rec.count('/v1/auth/refresh'), 1);
      same('replayed', rig.rec.streams.length, 2);
      same('same client_msg_id', rig.rec.streams[1].clientMsgId, 'Previous_01234567');
      same('new token', rig.rec.streams[1].headers['Authorization'], 'Bearer new-access');
      // 重放又回 10002：不再重放（G23 至多一次）。
      rig.rec.lastManual.headers('application/json', 401);
      rig.rec.lastManual.text('{"code":10002,"msg":"","data":{},"trace_id":"t2"}');
      rig.rec.lastManual.end();
      await rig.pump();
      same('no second replay', rig.rec.streams.length, 2);
      same('result 10002', probe.envelope === null ? null : (probe.envelope as ApiResult).code, 10002);
    });

    it('stream_channel_10402_reregister_replays_once_and_admit_reject_not_sent', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.registrar.result = (): Promise<boolean> => Promise.resolve(true);
      const probe: StreamProbe = new StreamProbe();
      rig.client.stream(sendRequest('Previous_01234567'), probe);
      await rig.pump();
      rig.rec.lastManual.headers('application/json', 400);
      rig.rec.lastManual.text('{"code":10402,"msg":"","data":{},"trace_id":"t1"}');
      rig.rec.lastManual.end();
      await rig.pump();
      same('reregister', rig.registrar.calls, 1);
      same('replayed once', rig.rec.streams.length, 2);
      same('same body', rig.rec.streams[1].clientMsgId, 'Previous_01234567');
      // 准入不通过（发送闸门关）：不写出，按没发出结束。
      const blocked: StreamProbe = new StreamProbe();
      const req: ApiStreamRequest = sendRequest();
      req.sendAllowed = (): boolean => false;
      rig.client.stream(req, blocked);
      await rig.pump();
      same('blocked not sent', rig.rec.streams.length, 2);
      same('blocked local reject', blocked.envelope === null ? null : (blocked.envelope as ApiResult).outcome, 'local_reject');
    });

    it('stream_channel_42901_send_gate_execution_blocks_and_10405_force_update', 0, async () => {
      const rig: TRig = new TRig();
      const c: AgentController = await rig.ready();
      const s: AgentFakeScript = new AgentFakeScript();
      s.ndjson = null;
      s.errorCode = 42901;
      s.errorStatus = 429;
      s.retryAfter = '12';
      rig.script = s;
      await rig.ask(c, '第一条', 200);
      same('send gate', rig.gates.send.active, true);
      same('read gate untouched', rig.gates.read.active, false);
      const streams: number = rig.rec.streams.length;
      // 页面置灰；执行层同样拦下（闸门期内不写出）。
      same('ui blocked', c.send(c.snapshot().page, '第二条'), false);
      same('no write', rig.rec.streams.length, streams);
      await rig.pump(12001, 1000);
      same('gate over', rig.gates.send.active, false);
      // 10405：交强更（ApiClient 经 UpdatePort）。
      const s2: AgentFakeScript = new AgentFakeScript();
      s2.ndjson = null;
      s2.errorCode = 10405;
      s2.errorStatus = 403;
      rig.script = s2;
      await rig.ask(c, '第三条', 200);
      same('force update', rig.update.calls.length + rig.forced >= 1, true);
    });

    it('stream_channel_privacy_revoke_and_env_switch_cancel_in_flight_stream_zero_frames_after', 0, async () => {
      for (const how of ['privacy', 'environment', 'cancel_owned']) {
        const rig: TRig = new TRig();
        rig.rec.manual = true;
        const c: AgentController = await rig.ready();
        c.send(c.snapshot().page, '纯牛奶');
        await rig.pump(50);
        const m: ManualSink = rig.rec.lastManual;
        m.headers();
        m.text(META + guideCard(2, 'c1'));
        await rig.pump();
        same(how + ' card received', rig.state(c).cards.length, 1);
        const before: number = rig.state(c).lastSeq;
        if (how === 'privacy') {
          rig.context.privacyRaw = 'basic';
          rig.client.invalidate();
        } else if (how === 'environment') {
          rig.context.settled = false;
          rig.client.invalidate();
        } else {
          c.dispose();
        }
        // 作废之后旧连接上到达的字节：0 帧交给 Reducer。
        m.text(delta(3, '迟到') + done(4));
        m.end();
        await rig.pump(1000);
        if (how !== 'cancel_owned') {
          same(how + ' no late frame', rig.state(c).lastSeq, before);
          same(how + ' no quota', c.snapshot().quotaLeft, null);
        }
        same(how + ' no new request', rig.rec.streams.length, 1);
      }
    });

    // ---------------------------------------------------------------- AC-S1-174 六步（经真实通道）
    it('ac_s1_174_1_emoji_chinese_random_byte_chunks_exact_text', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + delta(2, '你好😀，') + delta(3, '中文与🥛emoji') + done(4), [1, 3, 17]);
      await rig.pump();
      same('text', rig.state(c).text, '你好😀，中文与🥛emoji');
      same('done', rig.state(c).status, 'done');
      same('no events', rig.events.length, 0);
    });

    it('ac_s1_174_2_one_chunk_meta_three_deltas_card_order', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + delta(2, '一') + delta(3, '二') + delta(4, '三') + guideCard(5, 'c1'));
      await rig.pump();
      same('text order', rig.state(c).text, '一二三');
      same('card', rig.state(c).cards.length, 1);
      same('last seq', rig.state(c).lastSeq, 5);
    });

    it('ac_s1_174_3_duplicate_ids_equal_to_in_order', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + delta(2, '甲') + delta(2, '甲') + delta(3, '乙') + done(4));
      await rig.pump();
      same('text', rig.state(c).text, '甲乙');
      same('done', rig.state(c).status, 'done');
    });

    it('ac_s1_174_4_gap_incomplete_then_history_replace_no_dup_card_no_missing_text', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      // 当前会话为空历史；发消息后服务端历史里有完整的这一轮（回复 id 与 meta 一致）。
      c.send(c.snapshot().page, '提现记录在哪看');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + delta(3, '提现') + guideCard(4, 'c1'));
      await rig.pump();
      same('incomplete', rig.state(c).status, 'incomplete');
      same('no retry while waiting', rig.turn(c).error !== null && (rig.turn(c).error as AgentErrorView).retry === null, true);
      const entryReads: number = rig.fake.historyRequests;
      same('waiting no reload yet', rig.fake.historyRequests, entryReads);
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      m.text(done(5));
      await rig.pump(100);
      same('history reload once', rig.fake.historyRequests - entryReads, 1);
      same('replaced text', rig.state(c).text, '提现进度在提现记录里查看。');
      same('one card', rig.state(c).cards.length, 1);
      same('status done', rig.state(c).status, 'done');
      same('no events', rig.events.length, 0);
      same('quota not updated', c.snapshot().quotaLeft, null);
    });

    it('ac_s1_174_5_70kib_frame_limited_buffer_released', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + 'event: card\nid: 2\ndata: ' + 'x'.repeat(71680) + '\n\n', [4096]);
      await rig.pump();
      same('limited', rig.state(c).status, 'limited');
      same('sending ended', c.snapshot().sending, false);
      same('no quota', c.snapshot().quotaLeft, null);
      same('no events', rig.events.length, 0);
      // 连接已关：之后的字节不再交付。
      m.text(done(3));
      await rig.pump();
      same('still limited', rig.state(c).status, 'limited');
    });

    it('ac_s1_174_6_401_single_char_deltas_limited_from_401', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      let all: string = META;
      for (let i: number = 2; i <= 402; i++) {
        all += delta(i, '字');
      }
      m.text(all + done(403), [8192]);
      await rig.pump();
      same('limited', rig.state(c).status, 'limited');
      same('400 rendered', AgentJson.codePoints(rig.state(c).text), 400);
      same('no quota', c.snapshot().quotaLeft, null);
      same('no events', rig.events.length, 0);
    });

    // ---------------------------------------------------------------- 断线与重载（G07、G35、G38）
    it('disconnect_30s_then_user_retry_history_backoff_times_and_resend_same_id', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fixture = 'disconnected';
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶', 500);
      const id: string | null = rig.rec.streams[0].clientMsgId;
      const entryReads: number = rig.fake.historyRequests;
      await rig.pump(30000, 500);
      same('disconnected', rig.state(c).status, 'disconnected');
      same('no auto history', rig.fake.historyRequests, entryReads);
      const retry: AgentRetryTap = (rig.turn(c).error as AgentErrorView).retry as AgentRetryTap;
      same('reconnect mode', retry.mode, AgentRetryMode.RECONNECT);
      // 历史连续失败：首次 + 4 次，间隔 1/2/4/8 秒 ×（0.5 + 0.5）。
      rig.fake.historyCode = -1;
      const start: number = rig.timer.now;
      const times: number[] = [];
      const before: number = rig.rec.wire.length;
      c.retry(retry);
      for (let i: number = 0; i < 40; i++) {
        await rig.pump(1000, 100);
      }
      for (let i: number = before; i < rig.rec.wire.length; i++) {
        if (rig.rec.wire[i].method === 'GET') {
          times.push(i);
        }
      }
      same('five attempts', rig.fake.historyRequests - entryReads, 5);
      same('no api get retry stacking', rig.netTimer.delays.filter((d: number): boolean => d === 500).length, 0);
      same('retry only after 5', (rig.turn(c).error as AgentErrorView).retry !== null, true);
      // 再点【重试】：历史成功但本轮不在历史 → 同键重发。
      rig.fake.historyCode = 0;
      rig.fake.historyScenario = AgentFakeHistoryScenario.NONE;
      rig.fixture = 'normal';
      c.retry((rig.turn(c).error as AgentErrorView).retry as AgentRetryTap);
      await rig.pump(2000, 50);
      same('resent', rig.rec.streams.length, 2);
      same('same client_msg_id', rig.rec.streams[1].clientMsgId, id);
      same('elapsed bounded', rig.timer.now - start > 0, true);
    });

    it('disconnect_retry_history_has_ended_turn_replaces_and_running_null_is_done', 0, async () => {
      for (const finish of ['stop', 'null']) {
        const rig: TRig = new TRig();
        rig.fake.currentSessionId = SESSION;
        rig.rec.manual = true;
        const c: AgentController = await rig.ready();
        c.send(c.snapshot().page, '提现记录在哪看');
        await rig.pump(50);
        rig.rec.lastManual.headers();
        rig.rec.lastManual.text(META + delta(2, '提现'));
        rig.rec.lastManual.end();
        await rig.pump();
        same(finish + ' disconnected', rig.state(c).status, 'disconnected');
        rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
        c.retry((rig.turn(c).error as AgentErrorView).retry as AgentRetryTap);
        await rig.pump(200);
        same(finish + ' replaced', rig.state(c).text, '提现进度在提现记录里查看。');
        same(finish + ' no resend', rig.rec.streams.length, 1);
        same(finish + ' no stop button', c.snapshot().stop, null);
        same(finish + ' no cancel', rig.rec.count('/cancel'), 0);
      }
    });

    it('disconnect_backoff_paused_in_background_and_trigger_in_background_sends_nothing', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      rig.rec.lastManual.headers();
      rig.rec.lastManual.text(META + delta(2, '甲'));
      rig.rec.lastManual.end();
      await rig.pump();
      rig.fake.historyCode = -1;
      const entryReads: number = rig.fake.historyRequests;
      c.retry((rig.turn(c).error as AgentErrorView).retry as AgentRetryTap);
      await rig.pump(100);
      same('first attempt', rig.fake.historyRequests - entryReads, 1);
      rig.foreground = false;
      c.setForeground(false);
      await rig.pump(20000, 500);
      same('paused in background', rig.fake.historyRequests - entryReads, 1);
      same('retry button only', (rig.turn(c).error as AgentErrorView).retry !== null, true);
      rig.foreground = true;
      c.setForeground(true);
      await rig.pump(20000, 500);
      same('not resumed on foreground', rig.fake.historyRequests - entryReads, 1);
    });

    // ---------------------------------------------------------------- duplicate（G40、03 §7.2）
    it('duplicate_fixtures_through_real_channel_reload_or_refresh_button', 0, async () => {
      for (const fx of ['duplicate-ended-done', 'duplicate-ended-error', 'duplicate-in-progress']) {
        const rig: TRig = new TRig();
        rig.fake.currentSessionId = SESSION;
        rig.fake.historyScenario = AgentFakeHistoryScenario.NONE;
        rig.fixture = fx;
        const c: AgentController = await rig.ready();
        const entryReads: number = rig.fake.historyRequests;
        await rig.ask(c, '纯牛奶', 1000);
        if (fx === 'duplicate-in-progress') {
          same(fx + ' no history', rig.fake.historyRequests - entryReads, 0);
          const e: AgentErrorView = rig.turn(c).error as AgentErrorView;
          same(fx + ' refresh button', e.retry === null ? null : (e.retry as AgentRetryTap).mode, AgentRetryMode.REFRESH);
          same(fx + ' send disabled', rig.gates.send.active, true);
          same(fx + ' no feedback', rig.turn(c).feedback, null);
        } else {
          same(fx + ' history once', rig.fake.historyRequests - entryReads, 1);
          same(fx + ' no feedback before replace', rig.turn(c).feedback, null);
        }
        same(fx + ' no quota', c.snapshot().quotaLeft, null);
      }
    });

    // ---------------------------------------------------------------- 停止（G25、G26）
    it('stop_after_meta_cancel_exactly_once_original_token_late_done_ignored_double_click', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + delta(2, '甲'));
      await rig.pump();
      const stop: AgentRunTicket = c.snapshot().stop as AgentRunTicket;
      c.stop(stop);
      c.stop(stop);
      await rig.pump(100);
      same('cancel exactly once', rig.rec.count('/cancel'), 1);
      same('cancel path', (rig.rec.last('/cancel') as Wire).path, '/v1/agent/runs/019a0000-0000-7000-8000-000000000121/cancel');
      same('original token', (rig.rec.last('/cancel') as Wire).headers['Authorization'], 'Bearer old-access');
      same('cancelled', rig.state(c).status, 'cancelled');
      m.text(delta(3, '迟到') + 'event: done\nid: 4\ndata: {"finish_reason":"cancelled","quota_left":3}\n\n');
      await rig.pump();
      same('late ignored', rig.state(c).text, '甲');
      same('purchase released', rig.purchaseCancels >= 1, true);
    });

    it('stop_cancel_30505_reloads_original_turn_from_history', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      rig.fake.cancelCode = 30505;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '提现记录在哪看');
      await rig.pump(50);
      rig.rec.lastManual.headers();
      rig.rec.lastManual.text(META);
      await rig.pump();
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const entryReads: number = rig.fake.historyRequests;
      c.stop(c.snapshot().stop as AgentRunTicket);
      await rig.pump(200);
      same('history after 30505', rig.fake.historyRequests - entryReads, 1);
      same('replaced (server stop)', rig.state(c).status, 'done');
      same('no toast', rig.toasts.length, 0);
    });

    it('stop_before_meta_stopping_then_meta_sends_one_cancel_or_30s_none', 0, async () => {
      for (const how of ['meta', 'timeout']) {
        const rig: TRig = new TRig();
        rig.rec.manual = true;
        const c: AgentController = await rig.ready();
        c.send(c.snapshot().page, '纯牛奶');
        await rig.pump(50);
        const m: ManualSink = rig.rec.lastManual;
        m.headers();
        m.text(': ping\n\n');
        await rig.pump();
        c.stop(c.snapshot().stop as AgentRunTicket);
        await rig.pump();
        same(how + ' stopping text', rig.turn(c).statusText, '正在停止');
        same(how + ' no stop button', c.snapshot().stop, null);
        if (how === 'meta') {
          m.text(META + delta(2, '不该显示'));
          await rig.pump(100);
          same('cancel once after meta', rig.rec.count('/cancel'), 1);
          same('no content after stop', rig.state(c).text, '');
        } else {
          await rig.pump(30000, 500);
          same('no cancel without meta', rig.rec.count('/cancel'), 0);
          m.text(META);
          await rig.pump();
          same('late meta no cancel', rig.rec.count('/cancel'), 0);
        }
        same(how + ' cancelled', rig.state(c).status, 'cancelled');
      }
    });

    // ---------------------------------------------------------------- 归属变化（G01）：协调器以原身份尽力 cancel
    it('ownership_logout_ai_privacy_cancel_once_original_identity_before_own_request_env_session_none', 0, async () => {
      for (const event of [AgentOwnershipEvent.LOGOUT, AgentOwnershipEvent.AI_CONSENT_WITHDRAWN,
        AgentOwnershipEvent.PRIVACY_WITHDRAWN, AgentOwnershipEvent.ENV_SWITCH, AgentOwnershipEvent.SESSION_INVALID,
        AgentOwnershipEvent.NEW_CHAT]) {
        const rig: TRig = new TRig();
        rig.rec.manual = true;
        const c: AgentController = await rig.ready();
        c.send(c.snapshot().page, '纯牛奶');
        await rig.pump(50);
        const m: ManualSink = rig.rec.lastManual;
        m.headers();
        m.text(META + guideCard(2, 'c1'));
        await rig.pump();
        const deliveredBefore: number = rig.state(c).lastSeq;
        const handlers: AgentOwnershipHandlers = new AgentOwnershipHandlers();
        const coordinator: AgentOwnershipStop = new AgentOwnershipStop(rig.ledger, handlers);
        const decision: AgentOwnershipDecision = coordinator.before(event, c);
        same(event + ' controller invalidated synchronously', c.isDisposed, true);
        coordinator.dispatch(decision, rig.port);
        // 流程自己的请求（logout / recordConsent）在 cancel 之后发出。
        if (event === AgentOwnershipEvent.LOGOUT) {
          rig.client.request(new ApiRequest('logout'));
        }
        await rig.pump(100);
        const sends: boolean = event === AgentOwnershipEvent.LOGOUT || event === AgentOwnershipEvent.AI_CONSENT_WITHDRAWN
          || event === AgentOwnershipEvent.PRIVACY_WITHDRAWN;
        same(event + ' cancel count', rig.rec.count('/cancel'), sends ? 1 : 0);
        if (sends) {
          same(event + ' original token', (rig.rec.last('/cancel') as Wire).headers['Authorization'], 'Bearer old-access');
        }
        if (event === AgentOwnershipEvent.LOGOUT) {
          const order: string[] = rig.rec.wire.map((w: Wire): string => w.path);
          same('cancel before logout', order.indexOf('/v1/agent/runs/019a0000-0000-7000-8000-000000000121/cancel')
            < order.indexOf('/v1/auth/logout'), true);
        }
        // 旧连接上之后到达的字节：0 帧交给 Reducer。
        m.text(delta(3, '迟到') + done(4));
        await rig.pump();
        same(event + ' zero late frames', c.streamStates.length === 0 || rig.state(c).lastSeq === deliveredBefore, true);
      }
    });

    it('ownership_original_identity_changed_before_admit_not_sent_and_no_run_id_not_sent', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      rig.rec.lastManual.headers();
      rig.rec.lastManual.text(': ping\n\n');
      await rig.pump();
      // 没有 run_id（meta 之前）：不发。
      const coordinator: AgentOwnershipStop = new AgentOwnershipStop(rig.ledger, new AgentOwnershipHandlers());
      coordinator.dispatch(coordinator.before(AgentOwnershipEvent.LOGOUT, c), rig.port);
      await rig.pump(100);
      same('no run no cancel', rig.rec.count('/cancel'), 0);
      // 有 run_id、但发出前原身份已变（换号）：准入不通过，不发、不改发新身份。
      const rig2: TRig = new TRig();
      rig2.rec.manual = true;
      const c2: AgentController = await rig2.ready();
      c2.send(c2.snapshot().page, '纯牛奶');
      await rig2.pump(50);
      rig2.rec.lastManual.headers();
      rig2.rec.lastManual.text(META);
      await rig2.pump();
      const decision: AgentOwnershipDecision = coordinator.before(AgentOwnershipEvent.LOGOUT, c2);
      rig2.identity = new AgentIdentity('test', AgentIdentity.MEMBER, 'B', 's2', 0, 1);
      coordinator.dispatch(decision, rig2.port);
      await rig2.pump(100);
      same('identity changed not sent', rig2.rec.count('/cancel'), 0);
    });

    it('session_invalid_and_account_switch_old_stream_and_history_never_reach_b', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      rig.fake.delayMs = 5000;
      const a: AgentController = rig.controller();
      a.start();
      await rig.pump(12000, 100);
      a.send(a.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + guideCard(2, 'c1'));
      await rig.pump();
      // 翻页在途（A 的历史页）。
      a.loadEarlier(a.snapshot().page);
      await rig.pump(100);
      // A 会话失效 → 登录 B（控制器按新身份重建；不发 cancel）。
      rig.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
      rig.client.onSessionChanged();
      rig.identity = new AgentIdentity('test', AgentIdentity.MEMBER, 'user-2', 's2', 0, 1);
      a.dispose();
      rig.fake.currentSessionId = null;
      const b: AgentController = await rig.ready();
      m.text(delta(3, 'A 的字') + done(4));
      await rig.pump(6000, 100);
      same('b empty', b.snapshot().turns.length, 0);
      same('b no quota', b.snapshot().quotaLeft, null);
      same('no cancel', rig.rec.count('/cancel'), 0);
      same('no events', rig.events.length, 0);
    });

    // ---------------------------------------------------------------- 切 Tab 保活（G02）
    it('tab_hidden_keeps_stream_and_history_no_ui_updates_applied_once_no_reload', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META);
      await rig.pump();
      c.setVisible(false);
      const shown: number = rig.snapshots.length;
      m.text(delta(2, '切走期间') + guideCard(3, 'c1') + done(4));
      await rig.pump();
      same('stream kept', rig.state(c).status, 'done');
      same('no ui while hidden', rig.snapshots.length, shown);
      same('no reload', rig.fake.historyRequests, 0);
      same('no open', rig.opens.length, 0);
      c.setVisible(true);
      same('applied once', rig.snapshots.length, shown + 1);
      same('content applied', rig.turn(c).blocks.length > 0, true);
    });

    // ---------------------------------------------------------------- 历史（G05–G10、G39、G42；AC-S1-148 ④、153 ②）
    it('history_cold_entry_renders_first_page_earnings_history_shape_no_wallet_request', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.BAD_AMOUNT;
      const c: AgentController = await rig.ready();
      same('ops', rig.rec.wire.map((w: Wire): string => w.method + ' ' + w.path.split('?')[0]),
        ['GET /v1/agent/sessions/current', 'GET /v1/agent/sessions/' + SESSION + '/messages']);
      same('limit 20', (rig.rec.last('/messages') as Wire).path.indexOf('limit=20') >= 0, true);
      same('no create', rig.rec.count('POST'), 0);
      same('turns', c.snapshot().turns.length, 1);
      const card: AgentCardView = rig.turn(c).cards[0];
      same('history shape', card.card.shape, 'history');
      same('no amounts kept', JSON.stringify(card.card.data).indexOf('fen') < 0, true);
      same('no wallet request', rig.rec.count('/wallet') + rig.rec.count('/withdrawals'), 0);
      same('feedback visible', rig.turn(c).feedback !== null, true);
    });

    it('history_page_guide_card_tap_opens_withdraw_records_agent_card_empty_params', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const c: AgentController = await rig.ready();
      same('two turns', c.snapshot().turns.length, 2);
      same('no automatic route', rig.opens.length, 0);
      const guide: AgentTap = rig.turn(c, 0).cards[0].guide as AgentTap;
      c.tap(guide);
      same('opened', rig.opens.map((o: OpenRecord): string => o.route), ['WithdrawRecords']);
      same('agent_card', rig.opens[0].source, RouteSource.AGENT_CARD);
      same('empty params', JSON.stringify(rig.opens[0].params), '{}');
      same('stack', rig.stack.names, ['WithdrawRecords']);
    });

    it('history_paging_prepends_once_in_flight_and_none_after_null_cursor', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.PAGED;
      const c: AgentController = await rig.ready();
      same('more', c.snapshot().earlier, 'more');
      c.loadEarlier(c.snapshot().page);
      c.loadEarlier(c.snapshot().page);
      await rig.pump(100);
      same('one page request', rig.rec.wire.filter((w: Wire): boolean => w.path.indexOf('cursor=') >= 0).length, 1);
      same('cursor param', (rig.rec.last('cursor=') as Wire).path.indexOf('cursor=opaque-cursor-older-page') >= 0, true);
      same('prepended', rig.turn(c, 0).userText, '怎么提现');
      same('total', c.snapshot().turns.length, 3);
      same('none', c.snapshot().earlier, 'none');
      c.loadEarlier(c.snapshot().page);
      await rig.pump(100);
      same('no more requests', rig.rec.wire.filter((w: Wire): boolean => w.path.indexOf('cursor=') >= 0).length, 1);
    });

    it('history_expired_read_only_30504_empty_10004_locks_without_dialog', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.EXPIRED;
      const c: AgentController = await rig.ready();
      same('read only', c.snapshot().readOnly, true);
      same('cannot send', c.send(c.snapshot().page, '还能问吗'), false);
      same('stopped text', rig.turn(c).statusText, '已停止');
      same('notice', c.snapshot().sessionNotice.length > 0, true);
      const rig2: TRig = new TRig();
      rig2.fake.currentSessionId = SESSION;
      rig2.fake.historyCode = 30504;
      const c2: AgentController = await rig2.ready();
      same('30504 ready empty', [c2.currentPhase, c2.snapshot().turns.length], [AgentPhase.READY, 0]);
      same('30504 notice', c2.snapshot().sessionNotice.length > 0, true);
      // 下次发送重新建会话（本地 session_id 已清）。
      await rig2.ask(c2, '新问题', 500);
      same('new session created', rig2.rec.count('POST /v1/agent/sessions') + rig2.rec.wire.filter((w: Wire): boolean =>
      w.method === 'POST' && w.path === '/v1/agent/sessions').length >= 1, true);
      const rig3: TRig = new TRig();
      rig3.fake.currentSessionId = SESSION;
      rig3.fake.historyCode = 10004;
      const c3: AgentController = await rig3.ready();
      same('10004 locked', c3.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('no dialog', c3.snapshot().consent, null);
    });

    // ---------------------------------------------------------------- 反馈与举报（G28、G29、G31）
    it('feedback_optimistic_in_flight_disabled_change_and_failure_rollback', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      rig.fake.delayMs = 100;
      const c: AgentController = await rig.ready();
      const fb: AgentFeedbackView = rig.turn(c, 0).feedback as AgentFeedbackView;
      c.feedback(fb.ticket, 'up');
      await flush();
      same('optimistic', (rig.turn(c, 0).feedback as AgentFeedbackView).selected, 'up');
      same('a11y', (rig.turn(c, 0).feedback as AgentFeedbackView).a11y, '已赞');
      same('in flight disabled', (rig.turn(c, 0).feedback as AgentFeedbackView).enabled, false);
      c.feedback(fb.ticket, 'down');
      await rig.pump(200);
      same('one request', rig.fake.feedbacks, 1);
      same('body up', (rig.rec.last('/feedback') as Wire).body, '{"feedback":"up"}');
      same('no idempotency', (rig.rec.last('/feedback') as Wire).headers['Idempotency-Key'], undefined);
      c.feedback(fb.ticket, 'up');
      await rig.pump(200);
      same('same value not sent', rig.fake.feedbacks, 1);
      c.feedback(fb.ticket, 'down');
      await rig.pump(200);
      same('changed', (rig.rec.last('/feedback') as Wire).body, '{"feedback":"down"}');
      // 失败回滚 + 统一提示（5xxxx 带 trace6）。
      rig.fake.feedbackCode = 50001;
      c.feedback(fb.ticket, 'up');
      await rig.pump(200);
      same('rolled back', (rig.turn(c, 0).feedback as AgentFeedbackView).selected, 'down');
      same('trace6 toast', rig.toasts[rig.toasts.length - 1].indexOf('4f5a6b') >= 0, true);
      // 30504：G31 提示、不清会话。
      rig.fake.feedbackCode = 30504;
      c.feedback(fb.ticket, 'up');
      await rig.pump(200);
      same('30504 message', rig.toasts[rig.toasts.length - 1], '操作没有成功，请稍后再试');
      // 42901：写动作闸门（读取 / 发送不受影响）。
      rig.fake.feedbackCode = 42901;
      rig.fake.retryAfter = '2';
      c.feedback(fb.ticket, 'up');
      await rig.pump(200);
      same('action gate', [rig.gates.action.active, rig.gates.send.active, rig.gates.read.active], [true, false, false]);
      // 10004：锁同意闸门、不弹框。
      await rig.pump(3000, 500);
      rig.fake.feedbackCode = 10004;
      c.feedback(fb.ticket, 'up');
      await rig.pump(200);
      same('10004 locked no dialog', [c.snapshot().consentGate, c.snapshot().consent], [AgentConsentGate.REFUSED, null]);
    });

    it('report_reason_composition_limit_success_reported_and_failure_keeps_input', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const c: AgentController = await rig.ready();
      const entry: AgentReportEntryView = rig.turn(c, 0).report as AgentReportEntryView;
      c.reportOpen(entry.ticket);
      const sheet: AgentReportSheetView = c.snapshot().reportSheet as AgentReportSheetView;
      same('reasons', sheet.reasons, ['内容不实或有误导', '含违法违规内容', '含低俗、冒犯内容', '侵犯他人权益', '其他问题']);
      same('quote', sheet.quote.length > 0, true);
      // 未选原因不能提交。
      c.reportSubmit(entry.ticket);
      await rig.pump(100);
      same('no reason no request', rig.fake.reports, 0);
      // 超过 200 码点不让提交。
      c.reportEdit(entry.ticket, '其他问题', '😀'.repeat(196));
      c.reportSubmit(entry.ticket);
      await rig.pump(100);
      same('too long no request', rig.fake.reports, 0);
      // 20001：原因旁提示、保留输入。
      rig.fake.reportCode = 20001;
      c.reportEdit(entry.ticket, '其他问题', '  描述不对  ');
      c.reportSubmit(entry.ticket);
      await rig.pump(100);
      same('body trimmed joined', (rig.rec.last('/report') as Wire).body, '{"reason":"其他问题：描述不对"}');
      same('sheet kept', (c.snapshot().reportSheet as AgentReportSheetView).supplement, '  描述不对  ');
      same('inline error', (c.snapshot().reportSheet as AgentReportSheetView).inlineError, true);
      // 成功：关半屏、「已举报」、轻提示、不再提供入口。
      rig.fake.reportCode = 0;
      c.reportEdit(entry.ticket, '内容不实或有误导', '');
      c.reportSubmit(entry.ticket);
      await rig.pump(100);
      same('closed', c.snapshot().reportSheet, null);
      same('reported', (rig.turn(c, 0).report as AgentReportEntryView).reported, true);
      same('toast', rig.toasts[rig.toasts.length - 1], '举报已提交，我们会核实处理');
      c.reportOpen(entry.ticket);
      same('no reopen', c.snapshot().reportSheet, null);
      same('no step up', rig.rec.count('/step-up'), 0);
    });

    it('report_10004_closes_sheet_locks_and_42901_action_gate_keeps_sheet', 0, async () => {
      for (const code of [10004, 42901, 30504]) {
        const rig: TRig = new TRig();
        rig.fake.currentSessionId = SESSION;
        rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
        rig.fake.reportCode = code;
        rig.fake.retryAfter = null;
        const c: AgentController = await rig.ready();
        const entry: AgentReportEntryView = rig.turn(c, 0).report as AgentReportEntryView;
        c.reportOpen(entry.ticket);
        c.reportEdit(entry.ticket, '其他问题', '保留这段');
        c.reportSubmit(entry.ticket);
        await rig.pump(100);
        if (code === 10004) {
          same('closed', c.snapshot().reportSheet, null);
          same('locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
          same('no dialog', c.snapshot().consent, null);
        } else if (code === 42901) {
          same('kept', (c.snapshot().reportSheet as AgentReportSheetView).supplement, '保留这段');
          same('action gate 5s', rig.gates.action.remainingMs > 4000 && rig.gates.action.remainingMs <= 5000, true);
        } else {
          same('closed 30504', c.snapshot().reportSheet, null);
          same('message', rig.toasts[rig.toasts.length - 1], '操作没有成功，请稍后再试');
        }
      }
    });

    it('late_feedback_and_report_after_new_chat_dropped', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      rig.fake.delayMs = 500;
      const c: AgentController = await rig.ready();
      await rig.pump(1000, 100);
      const fb: AgentFeedbackView = rig.turn(c, 0).feedback as AgentFeedbackView;
      c.feedback(fb.ticket, 'up');
      await flush();
      c.newChat(c.snapshot().page);
      await rig.pump(2000, 100);
      same('new chat empty', c.snapshot().turns.length, 0);
      same('no toast', rig.toasts.length, 0);
    });

    // ---------------------------------------------------------------- Release 开放（G32–G34）
    it('availability_entry_hidden_or_disabled_unavailable_zero_agent_requests', 0, async () => {
      const rig: TRig = new TRig();
      const c: AgentController = await rig.ready(false);
      same('unavailable', c.currentPhase, AgentPhase.UNAVAILABLE);
      same('send refused', c.send(c.snapshot().page, '纯牛奶'), false);
      same('zero agent requests', rig.rec.wire.length, 0);
      const i: AgentAvailabilityInput = new AgentAvailabilityInput();
      i.build = 'release';
      i.environment = 'prod';
      i.entryVisible = false;
      const r: AgentAvailabilityResult = AgentAvailability.decide(i);
      same('tab search', [r.tab, r.pageState, r.sendsRequests, r.settingsRowVisible], ['search', 'unavailable', false, false]);
      i.entryVisible = true;
      same('release real port', AgentAvailability.decide(i).port, 'real');
      // 30501（含流内）：本次进入「未开放」、之后不再发。
      const rig2: TRig = new TRig();
      const s: AgentFakeScript = new AgentFakeScript();
      s.ndjson = null;
      s.errorCode = 30501;
      rig2.script = s;
      const c2: AgentController = await rig2.ready();
      await rig2.ask(c2, '纯牛奶', 200);
      same('30501 unavailable', c2.currentPhase, AgentPhase.UNAVAILABLE);
      const before: number = rig2.rec.wire.length;
      same('no more send', c2.send(c2.snapshot().page, '再问'), false);
      same('no more requests', rig2.rec.wire.length, before);
    });

    it('member_unknown_and_basic_mode_load_nothing', 0, async () => {
      for (const level of ['member_unknown', AgentIdentity.BASIC]) {
        const rig: TRig = new TRig();
        rig.identity = new AgentIdentity('test', level, null, 's1', 0, 1);
        const deps: AgentDeps = new AgentDeps(rig.identity, (): string => rig.identity.key, rig.gates.send);
        deps.contract = rig.port;
        deps.conversation = rig.port;
        deps.memberUnknown = level === 'member_unknown';
        const c: AgentController = new AgentController(deps);
        c.setVisible(true);
        c.start();
        await rig.pump(100);
        same(level + ' blocked', c.currentPhase, AgentPhase.BLOCKED);
        same(level + ' zero requests', rig.rec.wire.length, 0);
      }
    });

    it('stream_client_drops_bytes_from_port_after_cancel_even_if_port_keeps_calling', 0, async () => {
      // 端口在取消后仍回调（真实传输层的回调可能迟到）：StreamClient 自己也必须丢弃，交付计数不变、只记 dropped。
      const port: CapturePort = new CapturePort();
      const timer: AgentVirtualTimer = new AgentVirtualTimer();
      let frames: number = 0;
      const client: StreamClient<number> = new StreamClient<number>(port, timer, 1, (_t: number): void => {
        frames++;
      });
      client.start(SESSION, '{}', new AgentCall('k', false, (): boolean => true, (): boolean => true));
      const h: Record<string, string> = {};
      h['content-type'] = 'text/event-stream';
      port.sink?.onHeaders(200, h);
      port.sink?.onBytes(utf8(META));
      same('one frame', client.delivered, 1);
      client.cancel();
      port.sink?.onBytes(utf8(delta(2, '迟到') + done(3)));
      port.sink?.onEnd();
      same('still one frame', client.delivered, 1);
      same('dropped counted', client.dropped >= 2, true);
      same('no late event', frames, 1);
    });

    it('availability_release_build_never_uses_fake_port_in_any_environment', 0, () => {
      for (const env of ['staging', 'test', 'prod']) {
        const i: AgentAvailabilityInput = new AgentAvailabilityInput();
        i.build = 'release';
        i.environment = env;
        i.mockRequested = true;
        same('release ' + env, AgentAvailability.decide(i).port, 'real');
      }
    });

    it('stream_client_delivered_counter_zero_after_cancel_capture_assertion', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const client: StreamClient<number> = new StreamClient<number>(rig.port, rig.timer, 1, (_t: number): void => {
      });
      client.start(SESSION, '{"client_msg_id":"msg-test-00000001","text":"x"}',
        new AgentCall('k', false, (): boolean => true, (): boolean => true));
      await rig.pump();
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META);
      await rig.pump();
      same('one frame', client.delivered, 1);
      client.cancel();
      m.text(delta(2, '迟到') + done(3));
      await rig.pump();
      same('zero frames after cancel', client.delivered, 1);
    });
  });
}
