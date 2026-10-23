// APP-10 鸿蒙 Agent 页的本地假服务集成测试（brief §2.15）：Core 执行器 AgentController（页面按钮回调调用的同一套方法与票据）+ StreamClient
// + Debug / Staging 的本机假服务 AgentFakeService（core staging，fixture 逐行转成 SSE 文本、经 DebugMockGate 的同一道环境闸门）+ 真实 Router /
// StackNavigator / EntryGuard（卡片点击经 Router 打开，断言导航栈、参数与入口来源）。数据只用锁定契约的 15 个 fixture 与合成数据；不连任何地址。
import { describe, it, expect } from '@ohos/hypium';
import {
  AgentBuyTap, AgentCardView, AgentChipTap, AgentConsentTicket, AgentController, AgentDeps, AgentHttpResult, AgentIdentity,
  AgentJson, AgentJsonObject, AgentPageTicket, AgentPhase, AgentProductRef, AgentRetryTap, AgentRunTicket,
  AgentSnapshot, AgentStreamState, AgentTap, AgentTapKind, AgentTimer, AgentTurnView, AgentAmount, AppEnvironment,
  EarningsCardView, EarningsView, GuardState, LaunchReadiness, MemoryPendingBackend, PendingActionStore, PrivacyState,
  RetryAfterGate, RouteDestination, RouteRequest, RouteSource, Router, RouteTable, StackNavigator, StreamReducer,
  UpdateCheckStatus, UpdateState, AgentCardOrigin, AgentCardDecoder, AgentCard, AgentErrorView, EarningsButton,
  AgentTextBlock, AgentTextSpan, AgentDraftTexts, AgentProductView, AgentCall, AgentConsentGate, AgentContextHandoff,
  AgentContextSource, AgentContextTicket, AgentContractPort, AgentStreamHandle, AgentStreamSink, AgentWithdrawFlow,
  AgentWithdrawOutcome, MePageLife
} from '../../Index';
import { AgentFakeScript, AgentFakeService, AgentDebugSources } from '../staging/ets/agent/AgentFakeService';
import { ClientEvent, RouteSpec } from 'generated';
import { CouliFormat } from 'designsystem/src/main/ets/format/CouliFormat';
import { CouliModalInstance, CouliModalPresenter, CouliModalSlot } from 'designsystem/src/main/ets/components/ModalInstance';
import { ProductGridLayout } from 'designsystem/Logic';
import { AGENT_STREAM_FIXTURES } from './AgentStreamFixturesData';
import { AGENT_VECTORS_JSON } from './AgentVectorsData';
import { ParamStack, TAB_ROOTS } from './OrderIntegration.test';

type JSONObject = Record<string, Object | null>;

const T0: number = Date.parse('2026-10-06T10:00:00+08:00');
const EMPTY: JSONObject = {};
const TWO_EMPTY: JSONObject[] = [EMPTY, EMPTY];

/** 手动推进的计时器（SSE 分帧间隔、30 秒断线）。 */
class AgentManualTimer implements AgentTimer {
  now: number = T0;
  private serial: number = 0;
  private tasks: Map<number, [number, () => void]> = new Map<number, [number, () => void]>();

  schedule(ms: number, run: () => void): number {
    this.serial++;
    this.tasks.set(this.serial, [this.now + ms, run]);
    return this.serial;
  }

  cancel(id: number): void {
    this.tasks.delete(id);
  }

  get pending(): number {
    return this.tasks.size;
  }

  /** 按到期顺序逐个执行（执行中新排的任务在到期时也会执行）。 */
  advance(ms: number): void {
    const end: number = this.now + ms;
    for (let guard: number = 0; guard < 10000; guard++) {
      let nextId: number = -1;
      let nextAt: number = Number.MAX_SAFE_INTEGER;
      this.tasks.forEach((v: [number, () => void], k: number) => {
        if (v[0] <= end && (v[0] < nextAt || (v[0] === nextAt && k < nextId))) {
          nextAt = v[0];
          nextId = k;
        }
      });
      if (nextId < 0) {
        break;
      }
      const t: [number, () => void] | undefined = this.tasks.get(nextId);
      this.tasks.delete(nextId);
      this.now = Math.max(this.now, nextAt);
      if (t !== undefined) {
        t[1]();
      }
    }
    this.now = end;
  }
}

async function settle(): Promise<void> {
  for (let i: number = 0; i < 40; i++) {
    await Promise.resolve();
  }
}

class OpenRecord {
  readonly route: string;
  readonly params: Record<string, Object>;
  readonly source: RouteSource;

  constructor(route: string, params: Record<string, Object>, source: RouteSource) {
    this.route = route;
    this.params = params;
    this.source = source;
  }
}

/**
 * 测试替身端口（R1-12）：包住本机假服务，正文只在这里记（假服务本身不保存请求正文）；可替换建会话 / 停止的结果（R1-06）。
 */
class RecordingPort implements AgentContractPort {
  private readonly inner: AgentFakeService;
  bodies: string[] = [];
  createResult: AgentHttpResult | null = null;
  cancelResult: AgentHttpResult | null = null;
  /** 端口拿到的每一个 AgentCall（R2-01、R2-02：之后核对它们的 sendAllowed 是否永久失效）。 */
  calls: AgentCall[] = [];
  /** 建会话 / 停止挂起（R2-02、R2-03、R2-04）：为 true 时请求按「已发出」计数，结果等 releaseCreate / releaseCancel。 */
  holdCreate: boolean = false;
  holdCancel: boolean = false;
  private createWaiters: ((r: AgentHttpResult) => void)[] = [];
  private cancelWaiters: ((r: AgentHttpResult) => void)[] = [];

  constructor(inner: AgentFakeService) {
    this.inner = inner;
  }

  createSession(call: AgentCall): Promise<AgentHttpResult> {
    this.calls.push(call);
    if (this.holdCreate && this.inner.allowed(call)) {
      this.inner.sent++;
      return new Promise<AgentHttpResult>((resolve: (r: AgentHttpResult) => void): void => {
        this.createWaiters.push(resolve);
      });
    }
    if (this.createResult !== null && this.inner.allowed(call)) {
      this.inner.sent++;
      return Promise.resolve(this.createResult as AgentHttpResult);
    }
    return this.inner.createSession(call);
  }

  currentSession(call: AgentCall): Promise<AgentHttpResult> {
    this.calls.push(call);
    return this.inner.currentSession(call);
  }

  sendMessage(sessionId: string, body: string, call: AgentCall, sink: AgentStreamSink): AgentStreamHandle {
    this.calls.push(call);
    if (this.inner.allowed(call)) {
      this.bodies.push(body);
    }
    return this.inner.sendMessage(sessionId, body, call, sink);
  }

  cancelRun(runId: string, call: AgentCall): Promise<AgentHttpResult> {
    this.calls.push(call);
    if (this.holdCancel && this.inner.allowed(call)) {
      this.inner.sent++;
      this.inner.cancels++;
      return new Promise<AgentHttpResult>((resolve: (r: AgentHttpResult) => void): void => {
        this.cancelWaiters.push(resolve);
      });
    }
    if (this.cancelResult !== null && this.inner.allowed(call)) {
      this.inner.sent++;
      this.inner.cancels++;
      return Promise.resolve(this.cancelResult as AgentHttpResult);
    }
    return this.inner.cancelRun(runId, call);
  }

  cancelOwned(identityKey: string): void {
    this.inner.cancelOwned(identityKey);
  }

  releaseCreate(r: AgentHttpResult): void {
    const all: ((r: AgentHttpResult) => void)[] = this.createWaiters;
    this.createWaiters = [];
    for (const w of all) {
      w(r);
    }
  }

  releaseCancel(r: AgentHttpResult): void {
    const all: ((r: AgentHttpResult) => void)[] = this.cancelWaiters;
    this.cancelWaiters = [];
    for (const w of all) {
      w(r);
    }
  }

  /** 此刻还有哪个已拿到的 AgentCall 准许发包（都应为 0）。 */
  get openCalls(): number {
    return this.calls.filter((c: AgentCall): boolean => c.sendAllowed()).length;
  }
}

function failure(code: number, data: string = '{}', retryAfter: string | null = null,
  trace: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b'): AgentHttpResult {
  return new AgentHttpResult(false, code === 42901 ? 429 : 422, code, 'err',
    AgentJson.objectOf(JSON.parse(data) as Object) ?? {}, trace, retryAfter);
}

/** 一套接线：假服务、Router、计时器、身份（可改，模拟换号、撤回、切环境）。 */
class AgentRig {
  readonly timer: AgentManualTimer = new AgentManualTimer();
  env: AppEnvironment = AppEnvironment.TEST;
  fakeOn: boolean = true;
  fixture: string = 'normal';
  /** 非空时按它回答（构造流 / JSON 错误）。 */
  script: AgentFakeScript | null = null;
  readonly fake: AgentFakeService;
  readonly port: RecordingPort;
  identity: AgentIdentity = new AgentIdentity('test', AgentIdentity.MEMBER, 'A', 's1', 0, 1);
  readonly gate: RetryAfterGate;
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  guard: GuardState = new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false);
  opens: OpenRecord[] = [];
  events: ClientEvent[] = [];
  toasts: string[] = [];
  logs: string[] = [];
  consents: boolean[] = [];
  consentResult: number = 0;
  buys: AgentJsonObject[] = [];
  refs: AgentProductRef[] = [];
  forced: number = 0;
  masked: boolean = false;
  /** recordConsent 挂起（R1-01）：为 true 时返回的 Promise 不结算，直到 releaseConsent。 */
  consentHang: boolean = false;
  private consentResolvers: ((r: AgentHttpResult) => void)[] = [];
  phoneBound: boolean | null = null;
  purchaseCancels: number = 0;
  maskListeners: ((hidden: boolean) => void)[] = [];
  snapshots: AgentSnapshot[] = [];
  withContract: boolean = true;
  context: AgentJsonObject | null = null;

  constructor() {
    this.fake = new AgentFakeService((): boolean => this.fakeOn, (): AppEnvironment | undefined => this.env, this.timer,
      (_body: string): AgentFakeScript => this.scriptNow());
    this.port = new RecordingPort(this.fake);
    this.gate = new RetryAfterGate((): number => this.timer.now, (): string => this.identity.key);
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null && TAB_ROOTS.indexOf(d.route) >= 0;
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.timer.now),
      (): GuardState => this.guard, this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED,
        UpdateCheckStatus.finished(this.guard.updateState)));
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
    if (this.fixture === 'disconnected') {
      s.hangAfterLine = (raw ?? '').split('\n').filter((l: string): boolean => l.length > 0).length;
    }
    return s;
  }

  setMask(hidden: boolean): void {
    this.masked = hidden;
    for (const l of this.maskListeners.slice()) {
      l(hidden);
    }
  }

  controller(identity: AgentIdentity = this.identity): AgentController {
    const deps: AgentDeps = new AgentDeps(identity, (): string => this.identity.key, this.gate);
    deps.contract = this.withContract ? AgentDebugSources.contract(this.fakeOn, this.env, this.port) : null;
    deps.timer = this.timer;
    deps.clock = (): number => this.timer.now;
    deps.masked = (): boolean => this.masked;
    deps.subscribeMask = (l: (hidden: boolean) => void): () => void => {
      this.maskListeners.push(l);
      return (): void => {
        this.maskListeners = this.maskListeners.filter((x: (hidden: boolean) => void): boolean => x !== l);
      };
    };
    deps.money = (fen: number): string => CouliFormat.money(fen);
    deps.open = (route: string, params: Record<string, Object>, source: RouteSource): void => {
      this.opens.push(new OpenRecord(route, params, source));
      this.router.open(RouteRequest.of(route, source, params));
    };
    deps.buy = (product: AgentJsonObject, ref: AgentProductRef): void => {
      this.buys.push(product);
      this.refs.push(ref);
    };
    deps.recordConsent = (accepted: boolean): Promise<AgentHttpResult> => {
      this.consents.push(accepted);
      if (this.consentHang) {
        return new Promise<AgentHttpResult>((resolve: (r: AgentHttpResult) => void): void => {
          this.consentResolvers.push(resolve);
        });
      }
      if (this.consentResult === 0) {
        this.fake.consentGranted = accepted;
        return Promise.resolve(new AgentHttpResult(true, 200, 0, 'ok', {}, 'trace-consent-000001', null));
      }
      return Promise.resolve(new AgentHttpResult(false, 500, this.consentResult, 'err', {}, 'trace-consent-0a1b2c', null));
    };
    deps.track = (e: ClientEvent): void => {
      this.events.push(e);
    };
    deps.toast = (text: string): void => {
      this.toasts.push(text);
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
    deps.examples = (): string[] => ['24 盒装纯牛奶，50 以内'];
    deps.filingText = (): string => '使用模型：通义千问（阿里云百炼）';
    deps.context = this.context;
    const c: AgentController = new AgentController(deps);
    c.onChange = (s: AgentSnapshot): void => {
      this.snapshots.push(s);
    };
    // entry 在构造后立即同步写入可见性（R1-02）；测试默认在 Agent 页上。
    c.setVisible(true);
    return c;
  }

  /** 挂起的 recordConsent 结算（ok=false 时按 consentResult 或 50001 失败）。 */
  releaseConsent(ok: boolean): void {
    const all: ((r: AgentHttpResult) => void)[] = this.consentResolvers;
    this.consentResolvers = [];
    for (const r of all) {
      if (ok) {
        this.fake.consentGranted = true;
        r(new AgentHttpResult(true, 200, 0, 'ok', {}, 'trace-consent-000001', null));
      } else {
        r(new AgentHttpResult(false, 500, this.consentResult === 0 ? 50001 : this.consentResult, 'err', {},
          'trace-consent-0a1b2c', null));
      }
    }
  }

  get lastBody(): string {
    return this.port.bodies.length === 0 ? '' : this.port.bodies[this.port.bodies.length - 1];
  }

  /** 新建控制器、进入页面（取当前会话）。 */
  async ready(): Promise<AgentController> {
    const c: AgentController = this.controller();
    c.start();
    await settle();
    return c;
  }

  /** 发一条消息并让假服务把 fixture 全部下发（ms 足够长）。 */
  async ask(c: AgentController, text: string = '纯牛奶 24盒', ms: number = 5000): Promise<void> {
    c.send(c.snapshot().page, text);
    await settle();
    this.timer.advance(ms);
    await settle();
  }

  last(c: AgentController): AgentSnapshot {
    return c.snapshot();
  }

  turn(c: AgentController, i: number = -1): AgentTurnView {
    const turns: AgentTurnView[] = c.snapshot().turns;
    return turns[i < 0 ? turns.length + i : i];
  }

  card(c: AgentController, type: string): AgentCardView {
    for (const t of c.snapshot().turns) {
      for (const v of t.cards) {
        if (v.card.type === type) {
          return v;
        }
      }
    }
    throw new Error('no card ' + type);
  }

  bodyClientMsgId(): string {
    return AgentFakeService.clientMsgId(this.lastBody) ?? '';
  }

  /** 身份变化（换号、会话失效、撤回隐私、撤回 AI 同意、切环境）。 */
  change(kind: string): void {
    const i: AgentIdentity = this.identity;
    switch (kind) {
      case 'account_switch':
        this.identity = new AgentIdentity(i.env, AgentIdentity.MEMBER, 'B', 's2', i.aiConsent, i.page);
        break;
      case 'session_invalid':
      case 'logout':
        this.identity = new AgentIdentity(i.env, AgentIdentity.GUEST, null, 's3', i.aiConsent, i.page);
        break;
      case 'privacy_withdrawn':
        this.identity = new AgentIdentity(i.env, AgentIdentity.BASIC, null, 's4', i.aiConsent, i.page);
        break;
      case 'ai_consent_withdrawn':
        this.identity = new AgentIdentity(i.env, i.level, i.userId, i.session, i.aiConsent + 1, i.page);
        break;
      case 'env_switch':
        this.identity = new AgentIdentity('staging', i.level, i.userId, 's5', i.aiConsent, i.page);
        break;
      case 'page_destroyed':
        this.identity = new AgentIdentity(i.env, i.level, i.userId, i.session, i.aiConsent, i.page + 1);
        break;
      default:
        break;
    }
  }
}

function vectorStream(name: string): JSONObject {
  const v: JSONObject = JSON.parse(AGENT_VECTORS_JSON) as JSONObject;
  const rows: JSONObject[] = v['streams'] as JSONObject[];
  for (const r of rows) {
    if (r['name'] === name) {
      return r['expect'] as JSONObject;
    }
  }
  throw new Error('no vector ' + name);
}

function same(path: string, actual: Object | null | undefined, expected: Object | null | undefined): void {
  const a: string = JSON.stringify(actual === undefined ? null : actual);
  const e: string = JSON.stringify(expected === undefined ? null : expected);
  if (a !== e) {
    throw new Error(path + ': actual=' + a + ' expect=' + e);
  }
  expect(a).assertEqual(e);
}

/** 规范化快照的逐字段比较（键排序后比较 JSON 文本）。 */
function canon(v: Object | null): Object | null {
  if (v === null || typeof v !== 'object') {
    return v;
  }
  if (Array.isArray(v)) {
    return (v as Object[]).map((x: Object): Object | null => canon(x));
  }
  const o: JSONObject = v as JSONObject;
  const out: JSONObject = {};
  for (const k of Object.keys(o).sort()) {
    out[k] = canon(o[k] ?? null);
  }
  return out;
}

const STREAM_FIXTURES: string[][] = [
  ['normal', 'G04_G08_G32_normal'],
  ['tool-failed', 'G04_G08_G32_tool-failed'],
  ['cancelled', 'G04_G08_G32_cancelled'],
  ['unknown-card', 'G04_G08_G32_unknown-card'],
  ['error', 'G04_G08_G32_error'],
  ['fallback', 'G04_G08_G32_fallback'],
  ['normal-page-guide', 'G04_G08_G32_normal-page-guide'],
  ['normal-earnings', 'G04_G08_G32_normal-earnings'],
  ['unknown-card-page-guide', 'G04_G08_G32_unknown-card-page-guide'],
  ['error-search-fallback', 'G04_G08_G32_error-search-fallback'],
  ['duplicate-ended-done', 'G04_G08_G32_G26_duplicate-ended-done'],
  ['duplicate-ended-error', 'G04_G08_G32_G26_duplicate-ended-error'],
  ['duplicate-in-progress', 'G04_G08_G32_G26_duplicate-in-progress']
];

function lineScript(lines: string[]): AgentFakeScript {
  const s: AgentFakeScript = new AgentFakeScript();
  s.ndjson = lines.join('\n') + '\n';
  s.intervalMs = 50;
  return s;
}

function jsonScript(code: number, status: number, retryAfter: string | null = null,
  data: AgentJsonObject = {}): AgentFakeScript {
  const s: AgentFakeScript = new AgentFakeScript();
  s.ndjson = null;
  s.errorCode = code;
  s.errorStatus = status;
  s.retryAfter = retryAfter;
  s.errorData = data;
  return s;
}

const META: string = '{"event":"meta","id":1,"data":{"session_id":"019a0000-0000-7000-8000-000000000001","run_id":'
  + '"019a0000-0000-7000-8000-000000000101","message_id":"019a0000-0000-7000-8000-000000000201","prompt_version":"demo-prompt-v1",'
  + '"model_label":"演示模型","ai_label":"内容由 AI 生成，仅供参考"}}';
const DONE3: string = '{"event":"done","id":3,"data":{"finish_reason":"stop","quota_left":29}}';

function guideCard(data: string): string {
  return '{"event":"card","id":2,"data":{"seq":2,"card_id":"c1","type":"page_guide","schema_version":1,"data":' + data
    + ',"fallback_text":"这个我没法直接帮你打开。"}}';
}

/** 系统模态替身（R2-05）：打开是异步的；打开完成前 close 不生效（SDK 返回 103303），打开随后照样成功。 */
class FakeModal implements CouliModalPresenter {
  state: string = 'idle';
  closeCalls: number = 0;
  private finish: (() => void) | null = null;

  open(): Promise<void> {
    this.state = 'opening';
    return new Promise<void>((resolve: () => void): void => {
      this.finish = (): void => {
        if (this.state === 'opening') {
          this.state = 'shown';
        }
        resolve();
      };
    });
  }

  close(): void {
    this.closeCalls++;
    if (this.state === 'shown') {
      this.state = 'closed';
    }
  }

  completeOpen(): void {
    const f: (() => void) | null = this.finish;
    this.finish = null;
    if (f !== null) {
      f();
    }
  }
}

const AI_10004: string = '{"consent_type":"ai_third_party"}';
/** BR-AI-13：同账号在另一端撤回 AI 同意后，当前 run 收到的合法 SSE error 帧（流契约没有 consent_type，R3-01）。 */
const ERR_10004: string = '{"event":"error","id":2,"data":{"code":10004,"msg":"需要同意","retryable":false,"fallback":null}}';
const DUP_META: string = META.split('"ai_label":"内容由 AI 生成，仅供参考"}}').join('"ai_label":"内容由 AI 生成，仅供参考","duplicate":true}}');

/** R3-01：流内撤回终止后，所有发送入口都不发（输入框、示例、查订单、【重试】、加载重试、新对话），已拿到的许可全部失效。 */
async function assertZeroSendsAfterStreamConsentLost(tag: string, rig: AgentRig, c: AgentController): Promise<void> {
  same(tag + ' gate locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
  same(tag + ' no dialog (no consent_type)', c.snapshot().consent, null);
  same(tag + ' conversation cleared', c.snapshot().turns.length, 0);
  same(tag + ' declined page', c.currentPhase, AgentPhase.CONSENT_DECLINED);
  same(tag + ' not sending', c.snapshot().sending, false);
  same(tag + ' canSend', c.canSend, false);
  same(tag + ' every taken permit revoked', rig.port.openCalls, 0);
  const sent: number = rig.fake.sent;
  const bodies: number = rig.port.bodies.length;
  same(tag + ' send', c.send(c.snapshot().page, '再来一条'), false);
  for (const chip of c.snapshot().examples) {
    c.chip(chip);
  }
  if (c.snapshot().ordersChip !== null) {
    c.chip(c.snapshot().ordersChip as AgentChipTap);
  }
  for (const turn of c.snapshot().turns) {
    if (turn.error !== null && turn.error.retry !== null) {
      c.retry(turn.error.retry as AgentRetryTap);
    }
  }
  c.retryLoad(c.snapshot().page);
  c.newChat(c.snapshot().page);
  same(tag + ' send after new chat', c.send(c.snapshot().page, '新对话里再发'), false);
  rig.timer.advance(5000);
  await settle();
  same(tag + ' zero sends', rig.fake.sent, sent);
  same(tag + ' zero bodies', rig.port.bodies.length, bodies);
  same(tag + ' permits still revoked', rig.port.openCalls, 0);
  same(tag + ' still locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
}

export default function agentIntegrationTest(): void {
  describe('AgentIntegration', () => {
    // ---------------------------------------------------------------- 7 类（+ duplicate）流：经假服务以 SSE 下发 → 逻辑快照与向量一致
    for (const row of STREAM_FIXTURES) {
      const fixture: string = row[0];
      const vector: string = row[1];
      it('fixture_via_sse_' + fixture, 0, async () => {
        const rig: AgentRig = new AgentRig();
        rig.fixture = fixture;
        const c: AgentController = await rig.ready();
        same('phase', c.currentPhase, AgentPhase.READY);
        await rig.ask(c);
        const states: AgentStreamState[] = c.streamStates;
        same('turns', states.length, 1);
        same(fixture, canon(StreamReducer.normalize(states[0])), canon(vectorStream(vector)));
        same('sending', c.snapshot().sending, false);
      });
    }

    it('fixture_disconnected_hangs_30s_then_disconnected_and_retry_reuses_client_msg_id', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'disconnected';
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶 24盒', 1000);
      same('still streaming', c.snapshot().sending, true);
      rig.timer.advance(29000);
      same('29s still streaming', c.snapshot().sending, true);
      rig.timer.advance(1500);
      await settle();
      same('normalized', canon(StreamReducer.normalize(c.streamStates[0])),
        canon(vectorStream('G04_G08_G33_disconnected_timeout')));
      const turn: AgentTurnView = rig.turn(c);
      expect(turn.error !== null && turn.error.retry !== null).assertTrue();
      const first: string = rig.bodyClientMsgId();
      rig.fixture = 'duplicate-ended-done';
      c.retry((turn.error as AgentErrorView).retry as AgentRetryTap);
      await settle();
      rig.timer.advance(2000);
      await settle();
      same('same client_msg_id', rig.bodyClientMsgId(), first);
      // duplicate 两帧不并入：已收到的部分内容保留，消息结束（G26），不更新额度。
      same('text kept', c.streamStates[0].text, '为你找到以下商品，');
      same('status', rig.turn(c).status, 'done');
      same('quota', c.snapshot().quotaLeft, null);
    });

    it('history_card_earnings_only_history_text_and_buttons_no_amount', 0, () => {
      const raw: string = (AGENT_STREAM_FIXTURES.get('normal-earnings-history.ndjson') as string).trim();
      const card: AgentJsonObject = (JSON.parse(raw) as JSONObject)['data'] as AgentJsonObject;
      const state: AgentStreamState = StreamReducer.historyCard(StreamReducer.initial(), card);
      const view: EarningsView = EarningsCardView.view(state.cards[0], false, T0);
      same('shape', view.shape, 'history');
      same('text', view.historyTextKey, 'agent.earnings.history');
      same('withdrawable', view.withdrawable, null);
      same('buttons', view.buttons.map((b: EarningsButton): string => b.route), ['Wallet', 'WithdrawRecords']);
      // 历史来源即便误带金额也不显示、不保留（G13）。
      const live: string = (AGENT_STREAM_FIXTURES.get('normal-earnings.ndjson') as string).split('\n')[3];
      const liveCard: AgentJsonObject = (JSON.parse(live) as JSONObject)['data'] as AgentJsonObject;
      const parsed: AgentCard = AgentCardDecoder.parse(liveCard, AgentCardOrigin.HISTORY, new Map<string, RouteSpec>());
      same('history keeps no amount', JSON.stringify(parsed.data).indexOf('1000') < 0, true);
    });

    // ---------------------------------------------------------------- page_guide（D31，AC-S1-142 ②、144 ④、145、154）
    it('page_guide_tap_opens_withdraw_records_empty_params_agent_card_only_on_tap', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal-page-guide';
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      // 卡片出现、流结束后 10 秒不点：不跳转（AC-S1-142 ②）。
      rig.timer.advance(10000);
      await settle();
      same('no auto open', rig.stack.names.length, 0);
      same('no opens', rig.opens.length, 0);
      const v: AgentCardView = rig.card(c, 'page_guide');
      expect(v.guide !== null).assertTrue();
      same('spoken', (v.guide as AgentTap).label, '去看看，提现记录');
      c.tap(v.guide as AgentTap);
      same('route', rig.opens[0].route, 'WithdrawRecords');
      same('params', rig.opens[0].params, EMPTY);
      same('source', rig.opens[0].source, RouteSource.AGENT_CARD);
      same('stack', rig.stack.names, ['WithdrawRecords']);
      same('stack params', rig.stack.topParams(), EMPTY);
    });

    it('unknown_card_page_guide_settings_no_button_one_route_entry_blocked', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'unknown-card-page-guide';
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      const v: AgentCardView = rig.card(c, 'page_guide');
      same('kind', v.card.kind, 'fallback');
      same('guide', v.guide, null);
      same('text', v.card.fallbackText, '设置相关的选项都在设置页。');
      const blocked: ClientEvent[] = rig.events.filter((e: ClientEvent): boolean => e.name === 'route_entry_blocked');
      same('events', blocked.length, 1);
      same('route', blocked[0].fields.get('route'), 'Settings');
      same('entry', blocked[0].fields.get('entry'), 'in_app');
      c.refresh();
      c.refresh();
      same('no repeat', rig.events.filter((e: ClientEvent): boolean => e.name === 'route_entry_blocked').length, 1);
    });

    it('page_guide_wallet_with_params_and_payout_account_no_button', 0, async () => {
      for (const data of ['{"route":"Wallet","text_key":"agent.guide.Wallet","params":{}}',
        '{"route":"PayoutAccount","text_key":"agent.guide.PayoutAccount"}',
        '{"route":"https://example.com/pay","text_key":"agent.guide.Wallet"}']) {
        const rig: AgentRig = new AgentRig();
        rig.script = lineScript([META, guideCard(data), DONE3]);
        const c: AgentController = await rig.ready();
        await rig.ask(c);
        const v: AgentCardView = rig.card(c, 'page_guide');
        same('no button ' + data, v.guide, null);
        same('fallback ' + data, v.card.kind, 'fallback');
        const n: number = rig.events.filter((e: ClientEvent): boolean => e.name === 'route_entry_blocked').length;
        // URL 形 route 不上报（G10）。
        same('events ' + data, n, data.indexOf('https') >= 0 ? 0 : 1);
      }
    });

    it('page_guide_guest_wallet_goes_login_registers_agent_card_pending_then_opens_once', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.guard = new GuardState('consented', 'ok', 'guest', true, '1.0.0', false);
      rig.script = lineScript([META, guideCard('{"route":"Wallet","text_key":"agent.guide.Wallet"}'), DONE3]);
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      c.tap(rig.card(c, 'page_guide').guide as AgentTap);
      same('login', rig.stack.names, ['Login']);
      const pending: Record<string, Object> | null = rig.router.pendingAction('open_route');
      expect(pending !== null).assertTrue();
      rig.guard = new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false);
      rig.stack.clear();
      rig.router.prerequisiteCompleted();
      same('wallet once', rig.stack.names, ['Wallet']);
      same('params', rig.stack.topParams(), EMPTY);
      rig.router.prerequisiteCompleted();
      same('not twice', rig.stack.names, ['Wallet']);
    });

    it('page_guide_basic_mode_privacy_and_update_unknown_do_not_open', 0, async () => {
      for (const g of [new GuardState('basic', 'ok', 'phone_bound', true, '1.0.0', false),
        new GuardState('not_decided', 'ok', 'phone_bound', true, '1.0.0', false),
        new GuardState('consented', 'unknown', 'phone_bound', true, '1.0.0', false),
        new GuardState('consented', 'below_min', 'phone_bound', true, '1.0.0', false)]) {
        const rig: AgentRig = new AgentRig();
        rig.script = lineScript([META, guideCard('{"route":"AuthManage","text_key":"agent.guide.AuthManage"}'), DONE3]);
        const c: AgentController = await rig.ready();
        await rig.ask(c);
        rig.guard = g;
        c.tap(rig.card(c, 'page_guide').guide as AgentTap);
        same('not opened ' + g.privacy + g.update + JSON.stringify(rig.stack.names), rig.stack.names.indexOf('AuthManage') < 0, true);
        // 隐私阻断：agent_card 的 pending 不登记 / 删除，同意后不补执行。
        same('no pending ' + g.privacy, rig.router.pendingAction('open_route') === null
          || g.privacy === 'consented', true);
      }
    });

    // ---------------------------------------------------------------- 收益卡（D32，AC-S1-148 ②③④）
    it('earnings_live_amounts_mask_and_buttons', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal-earnings';
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      let v: EarningsView = rig.card(c, 'earnings_summary').earnings as EarningsView;
      same('withdrawable', v.withdrawable, '¥10');
      same('estimated', v.estimatedTotal, '¥56.78');
      same('applied', v.appliedAmount, '¥20');
      same('month', v.creditPeriod, '11 月');
      same('title', v.latestTitle, '审核中');
      same('updated', v.updatedAt, '10:00');
      const before: number = rig.snapshots.length;
      rig.setMask(true);
      expect(rig.snapshots.length > before).assertTrue();
      v = rig.card(c, 'earnings_summary').earnings as EarningsView;
      same('masked w', v.withdrawable, '****');
      same('masked e', v.estimatedTotal, '****');
      same('masked a', v.appliedAmount, '****');
      same('month kept', v.creditPeriod, '11 月');
      const taps: AgentTap[] = rig.card(c, 'earnings_summary').earningsTaps;
      c.tap(taps[0]);
      c.tap(taps[1]);
      same('routes', rig.opens.map((o: OpenRecord): string => o.route), ['Wallet', 'WithdrawRecords']);
      same('params', rig.opens.map((o: OpenRecord): Record<string, Object> => o.params), TWO_EMPTY);
      same('source', rig.opens.map((o: OpenRecord): string => o.source), ['agent_card', 'agent_card']);
      // 金额不进日志、埋点、提示（G15）。
      const leak: string = JSON.stringify(rig.logs) + JSON.stringify(rig.toasts)
        + JSON.stringify(rig.events.map((e: ClientEvent): string => JSON.stringify(Array.from(e.fields.values()))));
      same('no 1000', leak.indexOf('1000') < 0 && leak.indexOf('5678') < 0 && leak.indexOf('2000') < 0
        && leak.indexOf('¥') < 0, true);
      // 作废后金额不再可达（只在内存，随控制器清空）。
      c.dispose();
      same('cleared', c.streamStates.length, 0);
      same('unsubscribed', rig.maskListeners.length, 0);
    });

    // ---------------------------------------------------------------- 迟到与作废（brief §0 第 3 条）
    for (const kind of ['account_switch', 'session_invalid', 'logout', 'privacy_withdrawn', 'ai_consent_withdrawn',
      'env_switch', 'page_destroyed']) {
      it('late_frames_after_' + kind + '_do_not_touch_new_identity', 0, async () => {
        const rig: AgentRig = new AgentRig();
        rig.fixture = 'normal';
        const a: AgentController = await rig.ready();
        a.send(a.snapshot().page, '纯牛奶');
        await settle();
        rig.timer.advance(320);
        await settle();
        // 已收到 card 帧（normal 第 6 行）。
        same('card received', a.streamStates[0].cards.length, 1);
        const oldGuide: AgentPageTicket = a.snapshot().page;
        const oldBuy: AgentBuyTap = rig.card(a, 'product_list').products[0].buy as AgentBuyTap;
        const sentBefore: number = rig.fake.sent;
        // 归属变化：同步出口作废旧控制器（不发 cancel），按新身份重建。
        rig.change(kind);
        same('old dead', a.alive(), false);
        a.dispose();
        const b: AgentController = await rig.ready();
        const bSnap: string = JSON.stringify(b.snapshot().turns.length) + b.snapshot().phase;
        // A 的连接迟到的 text.delta / card / done。
        rig.timer.advance(5000);
        await settle();
        same('b untouched', JSON.stringify(b.snapshot().turns.length) + b.snapshot().phase, bSnap);
        same('b quota', b.snapshot().quotaLeft, null);
        same('a cleared', a.streamStates.length, 0);
        same('no cancel sent', rig.fake.cancels, 0);
        expect(rig.fake.sent >= sentBefore).assertTrue();
        // 旧回调交给新控制器：一律拒绝（不转交）。
        b.send(oldGuide, 'x');
        b.buy(oldBuy);
        same('no buy', rig.buys.length, 0);
        same('no b turns', b.snapshot().turns.length, 0);
        same('no events', rig.events.length, 0);
      });
    }

    it('identity_change_without_dispose_still_drops_late_frames', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const a: AgentController = await rig.ready();
      a.send(a.snapshot().page, '纯牛奶');
      await settle();
      rig.timer.advance(160);
      const before: string = JSON.stringify(StreamReducer.normalize(a.streamStates[0]));
      rig.change('account_switch');
      rig.timer.advance(5000);
      await settle();
      same('frozen', JSON.stringify(StreamReducer.normalize(a.streamStates[0])), before);
      same('no publish', a.snapshot().turns.length, 0);
    });

    it('new_chat_drops_old_stream_card_and_done_and_old_card_taps', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal-page-guide';
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '提现记录');
      await settle();
      rig.timer.advance(60);
      const page: AgentPageTicket = c.snapshot().page;
      c.newChat(page);
      await settle();
      rig.timer.advance(5000);
      await settle();
      same('cleared', c.snapshot().turns.length, 0);
      same('conversation', c.snapshot().conversation, page.conversation + 1);
      same('quota', c.snapshot().quotaLeft, null);
      same('no cancel', rig.fake.cancels, 0);
      // 新对话里正常发送。
      rig.fixture = 'normal-page-guide';
      await rig.ask(c);
      const tap: AgentTap = rig.card(c, 'page_guide').guide as AgentTap;
      c.newChat(c.snapshot().page);
      await settle();
      c.tap(tap);
      same('old tap rejected', rig.opens.length, 0);
      // 旧对话的追问胶囊也拒绝。
      c.chip(new AgentChipTap(tap.controller, tap.conversation, 'x', 'x'));
      same('old chip rejected', c.snapshot().turns.length, 0);
    });

    it('stop_cancels_locally_sends_cancel_and_late_done_ignored', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal';
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await settle();
      rig.timer.advance(260);
      const stop: AgentRunTicket = c.snapshot().stop as AgentRunTicket;
      c.stop(stop);
      await settle();
      same('cancelled', rig.turn(c).status, 'cancelled');
      same('cancel sent', rig.fake.cancels, 1);
      rig.timer.advance(5000);
      await settle();
      same('late ignored', c.streamStates[0].status, 'cancelled');
      same('no quota', c.snapshot().quotaLeft, null);
      // 停止后再点同一个停止票据：不再发。
      c.stop(stop);
      same('cancel once', rig.fake.cancels, 1);
    });

    it('duplicate_streams_do_not_update_quota', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal';
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      same('quota', c.snapshot().quotaLeft, 29);
      for (const f of ['duplicate-ended-done', 'duplicate-ended-error', 'duplicate-in-progress']) {
        rig.fixture = f;
        await rig.ask(c, '再来一次 ' + f);
        same('quota kept ' + f, c.snapshot().quotaLeft, 29);
      }
      const last: AgentTurnView = rig.turn(c);
      // duplicate 30506：给同键【重试】（G26）。
      same('30506 retry same', last.error !== null && last.error.retry !== null && last.error.retry.mode === 'same', true);
    });

    // ---------------------------------------------------------------- JSON 错误（G24）
    it('json_errors_map_to_page_actions', 0, async () => {
      let rig: AgentRig = new AgentRig();
      let c: AgentController = await rig.ready();
      rig.script = jsonScript(30501, 422);
      await rig.ask(c);
      same('30501 unavailable', c.currentPhase, AgentPhase.UNAVAILABLE);

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(30502, 422);
      await rig.ask(c);
      same('30502 quota', c.snapshot().quotaExhausted, true);
      const q: AgentTurnView = rig.turn(c);
      same('search', q.error !== null && q.error.search !== null, true);
      same('bind phone', q.error !== null && q.error.login !== null && q.error.login.route === 'BindPhone', true);
      same('send blocked', c.send(c.snapshot().page, 'x'), false);

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(30504, 422, null, AgentJson.objectOf(JSON.parse('{"reason":"round_limit"}') as Object) ?? {});
      await rig.ask(c);
      same('30504 new chat', rig.turn(c).error !== null && rig.turn(c).error?.newChat !== null, true);

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(30506, 409);
      await rig.ask(c, 'x', 100);
      same('30506 gate', rig.gate.active, true);
      same('30506 removed', c.snapshot().turns.length, 0);

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(42901, 429, '12');
      await rig.ask(c, 'x', 100);
      same('42901 gate', rig.gate.active, true);
      same('42901 remaining', rig.gate.remainingMs > 11000 && rig.gate.remainingMs <= 12000, true);
      same('42901 blocked', c.send(c.snapshot().page, 'y'), false);
      same('42901 toast', rig.toasts[rig.toasts.length - 1], '操作太频繁，请稍后再试');
      const sent: number = rig.fake.sent;
      rig.timer.advance(12001);
      same('42901 expired', c.send(c.snapshot().page, 'z'), true);
      expect(rig.fake.sent >= sent).assertTrue();

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(50401, 504);
      await rig.ask(c);
      const id50401: string = rig.bodyClientMsgId();
      const t5: AgentTurnView = rig.turn(c);
      same('50401 text trace6', (t5.error?.text ?? '').indexOf('4f5a6b') >= 0, true);
      rig.script = null;
      rig.fixture = 'normal';
      c.retry(t5.error?.retry as AgentRetryTap);
      await settle();
      rig.timer.advance(5000);
      await settle();
      same('50401 same id', rig.bodyClientMsgId(), id50401);
      same('50401 done', rig.turn(c).status, 'done');

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(50001, 500);
      await rig.ask(c);
      same('50001 new chat', rig.turn(c).error?.newChat !== null, true);
      same('50001 trace6', (rig.turn(c).error?.text ?? '').indexOf('4f5a6b') >= 0, true);

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(10405, 403);
      await rig.ask(c);
      same('10405 forced', rig.forced, 1);

      rig = new AgentRig();
      c = await rig.ready();
      rig.script = jsonScript(20001, 400, null, AgentJson.objectOf(JSON.parse('{"fields":["text"]}') as Object) ?? {});
      await rig.ask(c);
      same('20001 toast', rig.toasts[rig.toasts.length - 1], '最多输入 500 字');
    });

    it('stream_error_search_fallback_opens_search_with_q', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'error-search-fallback';
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      const t: AgentTurnView = rig.turn(c);
      same('search label', t.error?.searchLabel, '去搜索「纯牛奶 24盒」');
      c.tap(t.error?.search as AgentTap);
      same('route', rig.stack.names, ['Search']);
      same('q', rig.stack.topParams(), JSON.parse('{"q":"纯牛奶 24盒"}') as Record<string, Object>);
      // error.ndjson：没有 fallback_q → 不预填。
      const rig2: AgentRig = new AgentRig();
      rig2.fixture = 'error';
      const c2: AgentController = await rig2.ready();
      await rig2.ask(c2);
      c2.tap(rig2.turn(c2).error?.search as AgentTap);
      same('no q', rig2.stack.topParams(), EMPTY);
    });

    // ---------------------------------------------------------------- AgentConsent（BR-ID-14、BR-AI-13，G16、G17）
    it('consent_10004_sheet_unchecked_agree_replays_same_client_msg_id_once', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fake.consentGranted = false;
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      const first: string = rig.bodyClientMsgId();
      const sentAfterFirst: number = rig.fake.sent;
      const t: AgentConsentTicket = c.snapshot().consent as AgentConsentTicket;
      expect(t !== null).assertTrue();
      same('awaiting', rig.turn(c).phase, 'awaiting_consent');
      // 同意前不把用户输入发出第二次。
      rig.timer.advance(5000);
      same('not resent before consent', rig.fake.sent, sentAfterFirst);
      await c.consentAgree(t);
      await settle();
      rig.timer.advance(5000);
      await settle();
      same('recorded', rig.consents, [true]);
      same('replayed same id', rig.bodyClientMsgId(), first);
      same('sent once more', rig.fake.sent, sentAfterFirst + 1);
      same('done', rig.turn(c).status, 'done');
      // 旧弹窗票据再点：不再记录、不再重放。
      await c.consentAgree(t);
      same('once', rig.consents.length, 1);
    });

    it('consent_decline_records_false_stays_with_reagree', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fake.consentGranted = false;
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      const t: AgentConsentTicket = c.snapshot().consent as AgentConsentTicket;
      c.consentDecline(t);
      await settle();
      same('recorded false', rig.consents, [false]);
      same('declined', c.currentPhase, AgentPhase.CONSENT_DECLINED);
      same('pending dropped', c.snapshot().turns.length, 0);
      same('no opens', rig.stack.names.length, 0);
      c.consentReopen(c.snapshot().page);
      const t2: AgentConsentTicket = c.snapshot().consent as AgentConsentTicket;
      expect(t2.serial > t.serial).assertTrue();
      // 关闭（系统返回）只处理自己的票据。
      c.consentDismissed(t);
      same('old ticket ignored', c.snapshot().consent !== null, true);
    });

    it('consent_not_shown_for_privacy_type_or_30501', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const c: AgentController = await rig.ready();
      rig.script = jsonScript(10004, 403, null, AgentJson.objectOf(JSON.parse('{"consent_type":"privacy"}') as Object) ?? {});
      await rig.ask(c);
      same('no sheet', c.snapshot().consent, null);
      // 非 AI 的 10004（privacy）：统一分流——没有可调用的重新同意入口，只提示 error.10004，不打开任何页面（R1-05）。
      same('unified toast', rig.toasts[rig.toasts.length - 1], AgentController.errorText(10004, ''));
      same('no open', rig.opens.length, 0);
      same('gate clear', c.snapshot().consentGate, AgentConsentGate.CLEAR);
    });

    // ---------------------------------------------------------------- 购买（BR-PRICE-13、14，G25）
    it('buy_passes_render_time_snapshot_and_updates_only_that_card', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal';
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      const v: AgentCardView = rig.card(c, 'product_list');
      const buy: AgentBuyTap = v.products[0].buy as AgentBuyTap;
      c.buy(buy);
      same('buys', rig.buys.length, 1);
      same('link', rig.buys[0]['link_id'], buy.linkId);
      // 30141：置灰 +「换一批」；只改这一张。
      c.updateProduct(rig.refs[0], (card: Record<string, Object>): Record<string, Object> => {
        const n: Record<string, Object> = {};
        for (const k of Object.keys(card)) {
          n[k] = card[k];
        }
        n['availability'] = 'off_shelf';
        return n;
      });
      const after: AgentCardView = rig.card(c, 'product_list');
      same('refresh chip', after.products[0].refresh !== null, true);
      same('quote untouched', rig.card(c, 'rebate_quote').products[0].refresh, null);
      c.chip(after.products[0].refresh as AgentChipTap);
      await settle();
      same('sent refresh', rig.turn(c).userText, '换一批');
      // coupon_gone：卡片上加「这个券已领完」。
      c.updateProduct(rig.refs[0], (card: Record<string, Object>): Record<string, Object> => {
        const n: Record<string, Object> = {};
        for (const k of Object.keys(card)) {
          n[k] = card[k];
        }
        n['availability'] = 'coupon_gone';
        return n;
      });
      same('coupon gone', rig.card(c, 'product_list').products[0].couponGone, true);
      // 离开 Agent 页（控制器作废）后到达的 open 响应：不改任何东西。
      c.dispose();
      c.updateProduct(rig.refs[0], (card: Record<string, Object>): Record<string, Object> => card);
      same('disposed', c.streamStates.length, 0);
    });

    // ---------------------------------------------------------------- Release、环境闸门、基本模式
    it('release_no_contract_unavailable_and_no_requests', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.withContract = false;
      const c: AgentController = await rig.ready();
      same('phase', c.currentPhase, AgentPhase.UNAVAILABLE);
      same('send', c.send(c.snapshot().page, '纯牛奶'), false);
      same('sent', rig.fake.sent, 0);
      same('no consent', c.snapshot().consent, null);
    });

    it('prod_environment_gate_blocks_fake_at_transport_entry', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.env = AppEnvironment.PROD;
      const c: AgentController = await rig.ready();
      same('prod unavailable', c.currentPhase, AgentPhase.UNAVAILABLE);
      // 已拿到端口后才切到 prod：每次实际发包再核对，不注入假流。
      const rig2: AgentRig = new AgentRig();
      const c2: AgentController = await rig2.ready();
      rig2.env = AppEnvironment.PROD;
      await rig2.ask(c2);
      same('not sent', rig2.fake.sent, 1);
      same('no stream', c2.streamStates.length === 0 || c2.streamStates[0].metaSeen === false, true);
      rig2.env = AppEnvironment.TEST;
      rig2.fakeOn = false;
      const c3: AgentController = rig2.controller();
      same('fake off unavailable', c3.currentPhase, AgentPhase.UNAVAILABLE);
    });

    it('basic_mode_blocks_requests', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.identity = new AgentIdentity('test', AgentIdentity.BASIC, null, 's0', 0, 1);
      const c: AgentController = await rig.ready();
      same('blocked', c.currentPhase, AgentPhase.BLOCKED);
      same('sent', rig.fake.sent, 0);
    });

    // ---------------------------------------------------------------- 页面骨架、文本、金额格式
    it('input_limit_500_code_points_and_context_first_message_only', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.context = AgentJson.objectOf(JSON.parse('{"product_key":"jd:demo-0004"}') as Object);
      const c: AgentController = await rig.ready();
      same('context label', c.snapshot().contextLabelKey, 'agent.draft.context.product');
      let long: string = '';
      for (let i: number = 0; i < 501; i++) {
        long += '好';
      }
      same('501 rejected', c.send(c.snapshot().page, long), false);
      same('toast', rig.toasts[0], '最多输入 500 字');
      same('nothing sent', rig.fake.sent, 1);
      await rig.ask(c, long.substring(0, 500));
      const body1: JSONObject = JSON.parse(rig.lastBody) as JSONObject;
      same('context attached', body1['context'], JSON.parse('{"product_key":"jd:demo-0004"}') as Object);
      expect(/^[A-Za-z0-9_-]{8,64}$/.test(body1['client_msg_id'] as string)).assertTrue();
      await rig.ask(c, '第二条');
      const body2: JSONObject = JSON.parse(rig.lastBody) as JSONObject;
      same('context once', body2['context'], null);
      same('label cleared', c.snapshot().contextLabelKey, null);
      // 页面已在时再从订单详情【问问 AI】带 {order_id}：不清空当前对话，附在接下来第一条上。
      const turnsBefore: number = c.snapshot().turns.length;
      c.attachContext(AgentJson.objectOf(JSON.parse('{"order_id":"019a0000-0000-7000-8000-000000000501"}') as Object));
      same('order label', c.snapshot().contextLabelKey, 'agent.draft.context.order');
      same('kept turns', c.snapshot().turns.length, turnsBefore);
      await rig.ask(c, '为什么没返利');
      const body3: JSONObject = JSON.parse(rig.lastBody) as JSONObject;
      same('order context', body3['context'],
        JSON.parse('{"order_id":"019a0000-0000-7000-8000-000000000501"}') as Object);
      // 不合三选一形状的 context 丢弃。
      c.attachContext(AgentJson.objectOf(JSON.parse('{"order_id":"x","text":"y"}') as Object));
      same('bad context dropped', c.snapshot().contextLabelKey, null);
    });

    it('model_text_is_sanitized_before_render', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.script = lineScript([META,
        '{"event":"text.delta","id":2,"data":{"seq":2,"delta":"看 https://x.example.com/a 和 ￥AbCdEfGh12￥ **加粗**"}}',
        DONE3]);
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      const plain: string = rig.turn(c).blocks.map((b: AgentTextBlock): string => b.plain).join('');
      same('no url', plain.indexOf('example') < 0 && plain.indexOf('AbCdEfGh12') < 0, true);
      same('bold', rig.turn(c).blocks[0].spans.some((x: AgentTextSpan): boolean => x.bold && x.text === '加粗'), true);
      same('ai label', rig.turn(c).aiLabel, '内容由 AI 生成，仅供参考');
    });

    it('core_amount_copy_matches_designsystem_format', 0, () => {
      for (const fen of [0, 1, 9, 10, 99, 100, 990, 1000, 1990, 2000, 5678, 123456789, -5, -150, -1990]) {
        same('fen ' + fen, AgentAmount.yuan(fen), CouliFormat.money(fen));
      }
    });

    // ================================================================ harmony-review-r1 修复回归
    // ---------------------------------------------------------------- R1-01（S0）AI 同意状态机
    it('r1_01_consent_pending_blocks_every_send_entry_zero_sends', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fake.consentGranted = false;
      rig.consentHang = true;
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      const t: AgentConsentTicket = c.snapshot().consent as AgentConsentTicket;
      same('awaiting gate', c.snapshot().consentGate, AgentConsentGate.AWAITING);
      const sentAwaiting: number = rig.fake.sent;
      // 待同意：输入框、示例、查订单胶囊都不发。
      same('awaiting send', c.send(c.snapshot().page, '第二条'), false);
      c.chip(c.snapshot().examples[0]);
      c.chip(c.snapshot().ordersChip as AgentChipTap);
      same('awaiting zero', rig.fake.sent, sentAwaiting);
      // 点【同意并使用】：弹窗立即关闭，recordConsent 挂起。
      const pending: Promise<boolean> = c.consentAgree(t);
      await settle();
      same('submitting gate', c.snapshot().consentGate, AgentConsentGate.SUBMITTING);
      same('dialog closed', c.snapshot().consent, null);
      same('can send', c.canSend, false);
      same('submitting send', c.send(c.snapshot().page, '再发一条'), false);
      c.chip(c.snapshot().examples[0]);
      c.chip(c.snapshot().ordersChip as AgentChipTap);
      // 旧弹窗票据重复点同意：不再记录。
      await c.consentAgree(t);
      rig.timer.advance(5000);
      await settle();
      same('zero sends while submitting', rig.fake.sent, sentAwaiting);
      same('one record', rig.consents, [true]);
      same('turns', c.snapshot().turns.length, 1);
      rig.releaseConsent(true);
      same('agreed', await pending, true);
    });

    it('r1_01_consent_record_failure_keeps_sending_blocked', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fake.consentGranted = false;
      rig.consentResult = 50001;
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      const sent: number = rig.fake.sent;
      const ok: boolean = await c.consentAgree(c.snapshot().consent as AgentConsentTicket);
      await settle();
      same('not agreed', ok, false);
      same('refused gate', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('failed flag', c.snapshot().consentFailed, true);
      same('phase', c.currentPhase, AgentPhase.CONSENT_DECLINED);
      same('pending dropped', c.snapshot().turns.length, 0);
      same('send blocked', c.send(c.snapshot().page, '再来'), false);
      c.chip(c.snapshot().examples[0]);
      rig.timer.advance(5000);
      await settle();
      same('zero sends after failure', rig.fake.sent, sent);
      same('toast', rig.toasts[rig.toasts.length - 1].indexOf('0a1b2c') >= 0, true);
      // 【重新同意】→ 成功后才解除；没有待重放消息（不补发）。
      rig.consentResult = 0;
      c.consentReopen(c.snapshot().page);
      same('reopened', c.snapshot().consentGate, AgentConsentGate.AWAITING);
      await c.consentAgree(c.snapshot().consent as AgentConsentTicket);
      await settle();
      same('clear', c.snapshot().consentGate, AgentConsentGate.CLEAR);
      same('ready', c.currentPhase, AgentPhase.READY);
      same('no replay', rig.fake.sent, sent);
      same('send ok', c.send(c.snapshot().page, '现在可以'), true);
    });

    it('r1_01_consent_success_replays_exactly_once_same_client_msg_id', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fake.consentGranted = false;
      rig.consentHang = true;
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      const first: string = rig.bodyClientMsgId();
      const sent: number = rig.fake.sent;
      const t: AgentConsentTicket = c.snapshot().consent as AgentConsentTicket;
      const p: Promise<boolean> = c.consentAgree(t);
      await settle();
      rig.releaseConsent(true);
      await p;
      await settle();
      rig.timer.advance(5000);
      await settle();
      same('one replay', rig.fake.sent, sent + 1);
      same('same id', rig.bodyClientMsgId(), first);
      same('bodies', rig.port.bodies.length, 2);
      // 再结算一次、再点旧票据：都不再重放。
      rig.releaseConsent(true);
      await c.consentAgree(t);
      await settle();
      rig.timer.advance(5000);
      await settle();
      same('still one', rig.fake.sent, sent + 1);
      same('done', rig.turn(c).status, 'done');
    });

    // ---------------------------------------------------------------- R1-02 离开页面（APP-10b G02 更正：切 Tab / 被覆盖时流保活）
    // 编排者补充第 2 条（规划 03 §7.2 2026-10-14）：切 Tab 不断流、不重拉历史，只撤销导航与弹层许可；隐藏期间不更新界面、回来一次性应用。
    // 原 R1-02 的「离页即关连接」断言随之改为保活断言（APP-10 共性第 2 条同步更正）。
    it('r1_02_hide_keeps_stream_alive_and_applies_once_on_return', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal';
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await settle();
      rig.timer.advance(320);
      await settle();
      same('card received', c.streamStates[0].cards.length, 1);
      c.setVisible(false);
      same('sending kept', c.snapshot().sending, true);
      const published: number = rig.snapshots.length;
      rig.timer.advance(5000);
      await settle();
      same('stream continued to done', c.streamStates[0].status, 'done');
      same('quota applied in memory', c.snapshot().quotaLeft, 29);
      same('no ui update while hidden', rig.snapshots.length, published);
      same('hidden send', c.send(c.snapshot().page, 'x'), false);
      same('no navigation while hidden', rig.opens.length, 0);
      c.setVisible(true);
      same('applied once on return', rig.snapshots.length, published + 1);
    });

    it('r1_02_hide_during_create_session_and_load_keeps_requests', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const c: AgentController = rig.controller();
      c.start();
      // 取当前会话在途时切走：请求保留、结果照常落到内存（不重取）。
      c.setVisible(false);
      await settle();
      same('ready while hidden', c.currentPhase, AgentPhase.READY);
      c.setVisible(true);
      c.start();
      await settle();
      same('no second load', rig.fake.sent, 1);
      // 建会话在途时切走：消息照常发出（流保活）。
      const sent: number = rig.fake.sent;
      c.send(c.snapshot().page, '纯牛奶');
      c.setVisible(false);
      await settle();
      rig.timer.advance(5000);
      await settle();
      same('create and stream', rig.fake.sent, sent + 2);
      same('body sent', rig.port.bodies.length, 1);
      same('done', rig.turn(c).status, 'done');
    });

    it('r1_03_stop_revokes_rendered_card_and_buy_callbacks', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'normal';
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await settle();
      rig.timer.advance(320);
      await settle();
      const card: AgentCardView = rig.card(c, 'product_list');
      const detail: AgentTap = card.products[0].detail as AgentTap;
      const buy: AgentBuyTap = card.products[0].buy as AgentBuyTap;
      c.buy(buy);
      same('bought before stop', rig.buys.length, 1);
      const ref: AgentProductRef = rig.refs[0];
      c.stop(c.snapshot().stop as AgentRunTicket);
      same('purchase cancelled', rig.purchaseCancels, 1);
      c.tap(detail);
      c.buy(buy);
      same('old detail rejected', rig.opens.length, 0);
      same('old buy rejected', rig.buys.length, 1);
      c.updateProduct(ref, (x: Record<string, Object>): Record<string, Object> => {
        const n: Record<string, Object> = {};
        for (const k of Object.keys(x)) {
          n[k] = x[k];
        }
        n['availability'] = 'off_shelf';
        return n;
      });
      const after: AgentCardView = rig.card(c, 'product_list');
      same('purchase result ignored', after.products[0].refresh, null);
      same('kept visible', after.products.length > 0, true);
      same('no buy ticket', after.products[0].buy, null);
      same('no detail ticket', after.products[0].detail, null);
    });

    it('r1_03_stop_revokes_page_guide_tap', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const s: AgentFakeScript = lineScript([META, guideCard('{"route":"Wallet","text_key":"agent.guide.Wallet"}')]);
      s.hangAfterLine = 2;
      rig.script = s;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '钱包');
      await settle();
      rig.timer.advance(200);
      await settle();
      const tap: AgentTap = rig.card(c, 'page_guide').guide as AgentTap;
      c.stop(c.snapshot().stop as AgentRunTicket);
      c.tap(tap);
      same('no open', rig.opens.length, 0);
      same('stack', rig.stack.names.length, 0);
      same('no guide after stop', rig.card(c, 'page_guide').guide, null);
    });

    // ---------------------------------------------------------------- R1-04 情境交接固定来源身份
    it('r1_04_context_ticket_fixed_at_source_rejects_after_account_switch', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const handoff: AgentContextHandoff = new AgentContextHandoff();
      let pageAlive: boolean = true;
      const a: AgentController = await rig.ready();
      // A 的订单详情构造时固定来源票据。
      const source: AgentContextSource = new AgentContextSource(rig.identity.ownerKey, (): boolean => pageAlive);
      const ctx: AgentJsonObject = AgentJson.objectOf(JSON.parse('{"order_id":"019a0000-0000-7000-8000-000000000501"}') as Object)
        ?? {};
      // 换登 B。
      rig.change('account_switch');
      a.dispose();
      const b: AgentController = await rig.ready();
      same('rejected', handoff.offer(new AgentContextTicket(source, ctx), rig.identity.ownerKey, b), false);
      same('b no context', b.snapshot().contextLabelKey, null);
      same('nothing pending', handoff.take(rig.identity.ownerKey), null);
      await rig.ask(b, '为什么没返利');
      same('b body no context', (JSON.parse(rig.lastBody) as JSONObject)['context'], null);
      // 同一身份、来源页还在：附上；来源页离开后的旧回调拒绝。
      const fresh: AgentContextSource = new AgentContextSource(rig.identity.ownerKey, (): boolean => pageAlive);
      same('accepted', handoff.offer(new AgentContextTicket(fresh, ctx), rig.identity.ownerKey, b), true);
      same('attached', b.snapshot().contextLabelKey, 'agent.draft.context.order');
      pageAlive = false;
      same('page gone', handoff.offer(new AgentContextTicket(fresh, ctx), rig.identity.ownerKey, null), false);
      // 还没有控制器时记下，只交给同一归属键的控制器。
      pageAlive = true;
      same('pending', handoff.offer(new AgentContextTicket(fresh, ctx), rig.identity.ownerKey, null), true);
      same('other owner', handoff.take('other'), null);
      same('cleared', handoff.hasPending, false);
    });

    // ---------------------------------------------------------------- R1-05 统一分流
    it('r1_05_unified_errors_open_prerequisite_or_toast', 0, async () => {
      const cases: string[][] = [['10001', '{}', 'Login'], ['10005', '{}', 'BindPhone'],
        ['10004', '{"consent_type":"labor_agreement"}', 'LaborAgreement'], ['10004', '{"consent_type":"privacy"}', '']];
      for (const row of cases) {
        const rig: AgentRig = new AgentRig();
        const c: AgentController = await rig.ready();
        rig.script = jsonScript(Number.parseInt(row[0], 10), 403, null,
          AgentJson.objectOf(JSON.parse(row[1]) as Object) ?? {});
        await rig.ask(c);
        if (row[2].length > 0) {
          same('open ' + row[0], rig.opens.map((o: OpenRecord): string => o.route), [row[2]]);
          same('in_app ' + row[0], rig.opens[0].source, RouteSource.IN_APP);
          same('empty params ' + row[0], rig.opens[0].params, EMPTY);
        } else {
          same('toast only', rig.opens.length, 0);
          same('toast', rig.toasts[rig.toasts.length - 1], AgentController.errorText(10004, ''));
        }
      }
      // 取当前会话回 10001：同一入口。
      const rig2: AgentRig = new AgentRig();
      rig2.fake.consentOnLoad = false;
      const c2: AgentController = rig2.controller();
      rig2.port.createResult = failure(10001);
      c2.start();
      await settle();
      await rig2.ask(c2);
      same('create session 10001', rig2.opens.map((o: OpenRecord): string => o.route), ['Login']);
    });

    // ---------------------------------------------------------------- R1-06 新对话、停止共用错误规则
    it('r1_06_new_chat_and_stop_share_error_rules', 0, async () => {
      let rig: AgentRig = new AgentRig();
      let c: AgentController = await rig.ready();
      rig.port.createResult = failure(10405);
      c.newChat(c.snapshot().page);
      await settle();
      same('new chat 10405', rig.forced, 1);

      rig = new AgentRig();
      c = await rig.ready();
      rig.port.createResult = failure(10004, '{"consent_type":"ai_third_party"}');
      c.newChat(c.snapshot().page);
      await settle();
      same('new chat consent', c.snapshot().consent !== null, true);
      same('gate', c.snapshot().consentGate, AgentConsentGate.AWAITING);

      rig = new AgentRig();
      c = await rig.ready();
      rig.port.createResult = failure(42901, '{}', '7');
      c.newChat(c.snapshot().page);
      await settle();
      same('new chat 42901 gate', rig.gate.active, true);

      rig = new AgentRig();
      c = await rig.ready();
      rig.port.createResult = failure(50001);
      c.newChat(c.snapshot().page);
      await settle();
      same('new chat other toast', rig.toasts[rig.toasts.length - 1].indexOf('4f5a6b') >= 0, true);

      // 停止：42901 → 共享闸门；30505 静默；10405 → 强更。
      for (const code of [42901, 30505, 10405, 10001]) {
        rig = new AgentRig();
        rig.fixture = 'normal';
        c = await rig.ready();
        c.send(c.snapshot().page, '纯牛奶');
        await settle();
        rig.timer.advance(260);
        await settle();
        rig.port.cancelResult = failure(code, '{}', code === 42901 ? '9' : null);
        const toasts: number = rig.toasts.length;
        c.stop(c.snapshot().stop as AgentRunTicket);
        await settle();
        if (code === 42901) {
          same('stop 42901 gate', rig.gate.active, true);
        } else if (code === 30505) {
          same('stop 30505 silent', rig.toasts.length, toasts);
          same('stop 30505 no open', rig.opens.length, 0);
        } else if (code === 10405) {
          same('stop 10405', rig.forced, 1);
        } else {
          // APP-10b brief §0 第 2 条：cancel 的结果一律不导航、不弹框（应用级持有），10001 只记本机日志。
          same('stop 10001 no navigation', rig.opens.length, 0);
        }
      }
    });

    // ---------------------------------------------------------------- R1-07 流内 error 用响应头 trace6
    it('r1_07_stream_error_appends_header_trace6', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const s: AgentFakeScript = new AgentFakeScript();
      s.ndjson = AGENT_STREAM_FIXTURES.get('error.ndjson') as string;
      s.intervalMs = 50;
      s.headerTraceId = 'trace-abcdef';
      rig.script = s;
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      const text: string = (rig.turn(c).error as AgentErrorView).text;
      same('trace6', text.indexOf('abcdef') >= 0, true);
    });

    // ---------------------------------------------------------------- R1-08 以 error 结束也有 AiLabel
    it('r1_08_error_terminated_reply_has_ai_label', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fixture = 'error';
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      same('status', rig.turn(c).status, 'error');
      same('ai label', rig.turn(c).aiLabel, '内容由 AI 生成，仅供参考');
    });

    // ---------------------------------------------------------------- R1-09 响应头不重置 30 秒
    it('r1_09_headers_do_not_extend_first_line_timeout', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const s: AgentFakeScript = lineScript([META, DONE3]);
      s.headersDelayMs = 29000;
      s.intervalMs = 60000;
      rig.script = s;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await settle();
      rig.timer.advance(29500);
      await settle();
      same('headers only, still waiting', c.snapshot().sending, true);
      rig.timer.advance(1000);
      await settle();
      same('timed out at 30s', c.snapshot().sending, false);
      same('disconnected', rig.turn(c).status, 'disconnected');
    });

    // ---------------------------------------------------------------- R1-10 同意弹窗的可见性
    it('r1_10_consent_showable_only_visible_unblocked_valid', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fake.consentGranted = false;
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      const t: AgentConsentTicket = c.snapshot().consent as AgentConsentTicket;
      same('showable', c.consentShowable(t, false), true);
      same('blocked', c.consentShowable(t, true), false);
      c.setVisible(false);
      same('hidden', c.consentShowable(t, false), false);
      same('ticket kept while hidden', c.snapshot().consent !== null, true);
      c.setVisible(true);
      same('shown again', c.consentShowable(t, false), true);
      c.consentDismissed(t);
      same('dismissed', c.consentShowable(t, false), false);
      c.dispose();
      same('disposed', c.consentShowable(t, false), false);
    });

    // ---------------------------------------------------------------- R1-12 假服务不留正文
    it('r1_12_fake_service_keeps_no_request_body', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const c: AgentController = await rig.ready();
      await rig.ask(c, 'SECRET-TEXT-7f3a');
      same('sent', rig.port.bodies.length, 1);
      // 假服务的全部可序列化字段里都找不到这次的正文（撤回、换号后也就读不到）。
      same('no body kept', JSON.stringify(rig.fake).indexOf('SECRET-TEXT') < 0, true);
      c.dispose();
    });

    // ---------------------------------------------------------------- R1-13 grid 布局与购买票据
    it('r1_13_grid_columns_and_buy_tickets', 0, async () => {
      same('one item single', ProductGridLayout.columns(1, 400, 1), 1);
      same('two cols', ProductGridLayout.columns(3, 400, 1), 2);
      same('narrow single', ProductGridLayout.columns(3, 300, 1), 1);
      same('large font single', ProductGridLayout.columns(3, 400, 2), 1);
      same('unknown width two', ProductGridLayout.columns(2, 0, 1), 2);
      const rig: AgentRig = new AgentRig();
      const normal: string = AGENT_STREAM_FIXTURES.get('normal.ndjson') as string;
      rig.script = lineScript(normal.split('\n').filter((l: string): boolean => l.trim().length > 0).map((l: string): string =>
      l.indexOf('"product_list"') >= 0 ? l.split('"layout":"list"').join('"layout":"grid"') : l));
      const c: AgentController = await rig.ready();
      await rig.ask(c);
      const v: AgentCardView = rig.card(c, 'product_list');
      same('layout', v.layout, 'grid');
      same('every grid item has buy', v.products.every((p: AgentProductView): boolean => p.buy !== null), true);
      c.buy(v.products[0].buy as AgentBuyTap);
      same('grid buy', rig.buys.length, 1);
    });

    // ---------------------------------------------------------------- R1-14、R1-15 订单卡与收益卡文案
    it('r1_14_r1_15_order_card_plain_label_and_earnings_earliest', 0, async () => {
      const order: string = '{"event":"card","id":2,"data":{"seq":2,"card_id":"c1","type":"order_status","schema_version":1,'
        + '"data":{"order_id":"019a0000-0000-7000-8000-000000000501","platform":"jd","title":"演示纯牛奶","is_other_product":false,'
        + '"display_status":"STATUS","reason":null,"est_rebate_fen":200,"expected_credit_period":"2026-11"},'
        + '"fallback_text":"当前版本暂不支持显示这张卡片，请升级后查看。"}}';
      for (const status of ['CREDITED_PART_CLAWED', 'WAITING', 'SOMETHING_NEW']) {
        const rig: AgentRig = new AgentRig();
        rig.script = lineScript([META, order.split('STATUS').join(status), DONE3]);
        const c: AgentController = await rig.ready();
        await rig.ask(c);
        const lines: string[] = rig.card(c, 'order_status').lines;
        const joined: string = lines.join('|');
        same('no placeholder ' + status, joined.indexOf('{') < 0, true);
        same('no raw status ' + status, joined.indexOf(status) < 0, true);
        if (status === 'CREDITED_PART_CLAWED') {
          same('plain', lines[1], '已结算（部分扣回）');
        }
        if (status === 'WAITING') {
          same('order month', lines.indexOf('预计 11 月结算') >= 0, true);
          same('not earliest', joined.indexOf('最早') < 0, true);
        }
      }
      same('earnings earliest', AgentDraftTexts.earningsCredit('11 月', false), '最早预计 11 月结算');
      same('earnings overdue', AgentDraftTexts.earningsCredit(null, true), '入账核对中');
    });

    // ---------------------------------------------------------------- H10 已绑手机的会员额度用完不引导绑定
    it('h10_quota_member_phone_bound_no_bind_prompt', 0, async () => {
      for (const bound of [true, false]) {
        const rig: AgentRig = new AgentRig();
        rig.phoneBound = bound;
        const c: AgentController = await rig.ready();
        rig.script = jsonScript(30502, 422);
        await rig.ask(c);
        const e: AgentErrorView = rig.turn(c).error as AgentErrorView;
        same('search ' + bound, e.search !== null, true);
        if (bound) {
          same('no bind', e.login, null);
          same('member hint', e.quotaHint, AgentDraftTexts.text('agent.draft.quota.member_hint'));
        } else {
          same('bind', (e.login as AgentTap).route, 'BindPhone');
        }
      }
      const guest: AgentRig = new AgentRig();
      guest.identity = new AgentIdentity('test', AgentIdentity.GUEST, null, 's1', 0, 1);
      const g: AgentController = await guest.ready();
      guest.script = jsonScript(30502, 422);
      await guest.ask(g);
      same('guest login', ((guest.turn(g).error as AgentErrorView).login as AgentTap).route, 'Login');
    });
    // ================================================================ harmony-review-r2 修复回归
    // ---------------------------------------------------------------- R2-01（S0）每次 AI 10004 都锁闸门（含同意后的重放）
    it('r2_01_replay_10004_relocks_gate_every_send_entry_zero_sends', 0, async () => {
      const rig: AgentRig = new AgentRig();
      rig.fake.consentGranted = false;
      rig.consentHang = true;
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      const p: Promise<boolean> = c.consentAgree(c.snapshot().consent as AgentConsentTicket);
      await settle();
      // 同意记录成功，但服务端仍按未同意处理：重放再次返回 10004。
      rig.releaseConsent(true);
      rig.fake.consentGranted = false;
      same('agreed', await p, true);
      await settle();
      rig.timer.advance(5000);
      await settle();
      same('replayed once', rig.port.bodies.length, 2);
      same('gate relocked', c.snapshot().consentGate, AgentConsentGate.AWAITING);
      const again: AgentConsentTicket | null = c.snapshot().consent;
      same('dialog again without replay', again !== null && again.pendingRun === null, true);
      same('turn shows 10004', (rig.turn(c).error as AgentErrorView).retry, null);
      same('can send', c.canSend, false);
      same('every taken permit revoked', rig.port.openCalls, 0);
      const sent: number = rig.fake.sent;
      // 所有发送入口：输入框、示例、查订单、【重试】、加载重试、新对话（建会话）都不发。
      same('send', c.send(c.snapshot().page, '再来一条'), false);
      c.chip(c.snapshot().examples[0]);
      c.chip(c.snapshot().ordersChip as AgentChipTap);
      for (const turn of c.snapshot().turns) {
        if (turn.error !== null && turn.error.retry !== null) {
          c.retry(turn.error.retry as AgentRetryTap);
        }
      }
      c.retryLoad(c.snapshot().page);
      rig.timer.advance(5000);
      await settle();
      same('zero sends while awaiting', rig.fake.sent, sent);
      // 关闭弹窗（暂不使用）仍禁发；新对话也不解除。
      c.consentDismissed(again as AgentConsentTicket);
      same('refused', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('send refused', c.send(c.snapshot().page, '再来'), false);
      c.newChat(c.snapshot().page);
      c.chip(c.snapshot().examples[0]);
      rig.timer.advance(5000);
      await settle();
      same('zero sends after dismiss', rig.fake.sent, sent);
      same('bodies unchanged', rig.port.bodies.length, 2);
      same('permits still revoked', rig.port.openCalls, 0);
      // 再次同意成功才解除；没有待重放消息。
      rig.consentHang = false;
      c.consentReopen(c.snapshot().page);
      await c.consentAgree(c.snapshot().consent as AgentConsentTicket);
      await settle();
      same('clear after agree', c.snapshot().consentGate, AgentConsentGate.CLEAR);
      same('no auto replay', rig.fake.sent, sent);
      same('send ok', c.send(c.snapshot().page, '现在可以'), true);
    });

    it('r2_01_late_10004_from_every_operation_locks_gate_without_dialog', 0, async () => {
      // 取会话（离页后到达）、建会话（新对话，离页后到达）、停止（旧对话）各收到一次 AI 10004：闸门都锁住、不弹框。
      let rig: AgentRig = new AgentRig();
      rig.fake.consentOnLoad = true;
      rig.fake.consentGranted = false;
      let c: AgentController = rig.controller();
      c.start();
      c.setVisible(false);
      await settle();
      same('load late locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('load late no dialog', c.snapshot().consent, null);
      c.setVisible(true);
      c.start();
      await settle();
      same('declined page', c.currentPhase, AgentPhase.CONSENT_DECLINED);
      same('load late send', c.send(c.snapshot().page, 'x'), false);

      rig = new AgentRig();
      c = await rig.ready();
      rig.port.holdCreate = true;
      c.newChat(c.snapshot().page);
      await settle();
      c.setVisible(false);
      rig.port.releaseCreate(failure(10004, AI_10004));
      await settle();
      same('new chat late locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('new chat late no dialog', c.snapshot().consent, null);
      c.setVisible(true);
      same('new chat late send', c.send(c.snapshot().page, 'x'), false);
    });

    // ---------------------------------------------------------------- R2-02 发送许可创建时固定，失效即永久失效
    it('r2_02_send_permit_fixed_at_creation_never_revives', 0, async () => {
      const rig: AgentRig = new AgentRig();
      // 取会话的许可：离页再回来不恢复。
      const c: AgentController = rig.controller();
      rig.port.holdCreate = true;
      c.start();
      const load: AgentCall = rig.port.calls[rig.port.calls.length - 1];
      same('load permit', load.sendAllowed(), true);
      // APP-10b G02：切 Tab 不撤销发送许可（只撤销导航与弹层许可）。
      c.setVisible(false);
      c.setVisible(true);
      same('load permit kept across tab switch', load.sendAllowed(), true);
      c.start();
      await settle();
      same('ready', c.currentPhase, AgentPhase.READY);
      // 首条消息建会话的许可：离页 → 回来，仍失效。
      c.send(c.snapshot().page, '纯牛奶');
      await settle();
      const create: AgentCall = rig.port.calls[rig.port.calls.length - 1];
      same('create permit', create.sendAllowed(), true);
      c.setVisible(false);
      same('hidden keeps permit', create.sendAllowed(), true);
      c.setVisible(true);
      same('create permit kept', create.sendAllowed(), true);
      // 新对话的建会话许可：再点一次新对话后永久失效。
      c.newChat(c.snapshot().page);
      await settle();
      const fresh: AgentCall = rig.port.calls[rig.port.calls.length - 1];
      same('new chat permit', fresh.sendAllowed(), true);
      c.newChat(c.snapshot().page);
      same('new chat permit revoked', fresh.sendAllowed(), false);
      rig.port.holdCreate = false;
      rig.port.releaseCreate(failure(50001));
      await settle();
      // 流的许可：停止后永久失效（之后的新消息不复活它）。
      rig.fixture = 'disconnected';
      c.send(c.snapshot().page, '纯牛奶');
      await settle();
      rig.timer.advance(400);
      await settle();
      const stream: AgentCall = rig.port.calls[rig.port.calls.length - 1];
      same('stream permit', stream.sendAllowed(), true);
      c.stop(c.snapshot().stop as AgentRunTicket);
      same('stream permit revoked by stop', stream.sendAllowed(), false);
      rig.fixture = 'normal';
      await rig.ask(c, '下一条');
      same('still revoked', stream.sendAllowed(), false);
      same('load still revoked', load.sendAllowed(), false);
      same('create still revoked', create.sendAllowed(), false);
    });

    // ---------------------------------------------------------------- R2-03 首条消息建会话的迟到结果先结算共享事实
    it('r2_03_first_message_create_session_late_result_settles_shared', 0, async () => {
      for (const code of [42901, 10405, 10004]) {
        for (const how of ['hidden', 'stopped']) {
          const rig: AgentRig = new AgentRig();
          const c: AgentController = await rig.ready();
          rig.port.holdCreate = true;
          c.send(c.snapshot().page, '纯牛奶');
          await settle();
          if (how === 'hidden') {
            c.setVisible(false);
          } else {
            c.stop(c.snapshot().stop as AgentRunTicket);
          }
          rig.port.releaseCreate(failure(code, code === 10004 ? AI_10004 : '{}', code === 42901 ? '7' : null));
          await settle();
          c.setVisible(true);
          const tag: string = how + ' ' + code;
          same(tag + ' no open', rig.opens.length, 0);
          same(tag + ' no dialog', c.snapshot().consent, null);
          if (code === 42901) {
            same(tag + ' gate', rig.gate.active, true);
            same(tag + ' send blocked', c.send(c.snapshot().page, 'x'), false);
            rig.timer.advance(7001);
            same(tag + ' gate over', rig.gate.active, false);
          } else if (code === 10405) {
            same(tag + ' force update', rig.forced, 1);
          } else {
            same(tag + ' consent locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
            same(tag + ' send blocked', c.send(c.snapshot().page, 'x'), false);
          }
        }
      }
    });

    // ---------------------------------------------------------------- R2-04 停止的迟到结果不影响新对话 / 新消息
    it('r2_04_stale_cancel_result_does_not_touch_new_conversation', 0, async () => {
      for (const code of [10004, 10001, 42901, 10405]) {
        for (const how of ['new_chat', 'same_chat']) {
          const rig: AgentRig = new AgentRig();
          rig.fixture = 'disconnected';
          const c: AgentController = await rig.ready();
          c.send(c.snapshot().page, '纯牛奶');
          await settle();
          rig.timer.advance(260);
          await settle();
          rig.port.holdCancel = true;
          c.stop(c.snapshot().stop as AgentRunTicket);
          await settle();
          same('cancel sent', rig.fake.cancels, 1);
          if (how === 'new_chat') {
            c.newChat(c.snapshot().page);
            await settle();
          }
          c.send(c.snapshot().page, '新问题');
          await settle();
          rig.timer.advance(260);
          await settle();
          const tag: string = how + ' ' + code;
          same(tag + ' new run sending', c.snapshot().sending, true);
          const toasts: number = rig.toasts.length;
          rig.port.releaseCancel(failure(code, code === 10004 ? AI_10004 : '{}', code === 42901 ? '9' : null));
          await settle();
          same(tag + ' no dialog', c.snapshot().consent, null);
          same(tag + ' no open', rig.opens.length, 0);
          same(tag + ' no toast', rig.toasts.length, toasts);
          // G60 裁定（APP-10b harmony-review-r2 R2-01）：同身份 cancel 的 AI 10004 走同步作废——新回复立即停下；其余码仍不碰新消息。
          same(tag + ' new run untouched', c.snapshot().sending, code !== 10004);
          if (code === 42901) {
            same(tag + ' shared gate', rig.gate.active, true);
          } else if (code === 10405) {
            same(tag + ' force update', rig.forced, 1);
          } else if (code === 10004) {
            same(tag + ' consent locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
          } else {
            same(tag + ' gate clear', c.snapshot().consentGate, AgentConsentGate.CLEAR);
          }
        }
      }
    });

    // ---------------------------------------------------------------- R2-05 异步打开的模态：每个实例独立取消
    it('r2_05_modal_closed_before_async_open_completes_is_closed_after', 0, async () => {
      const slot: CouliModalSlot = new CouliModalSlot();
      const a: FakeModal = new FakeModal();
      const ia: CouliModalInstance = slot.show(1, a, (): boolean => true);
      same('opening', slot.openKey, 1);
      // 离页：打开还没完成就关闭（103303，不生效）。
      slot.close();
      same('key cleared', slot.openKey, 0);
      same('still opening', a.state, 'opening');
      a.completeOpen();
      await settle();
      same('closed after open', a.state, 'closed');
      same('instance dead', ia.live, false);

      // 被替换：A 打开中，B 替代；B 先完成并显示，A 迟到完成只关自己。
      const s2: CouliModalSlot = new CouliModalSlot();
      const m1: FakeModal = new FakeModal();
      const m2: FakeModal = new FakeModal();
      s2.show(1, m1, (): boolean => true);
      s2.show(2, m2, (): boolean => true);
      m2.completeOpen();
      await settle();
      m1.completeOpen();
      await settle();
      same('old closed', m1.state, 'closed');
      same('new shown', m2.state, 'shown');
      same('new key', s2.openKey, 2);

      // 打开完成时已失效（票据、可见性、阻挡层）：关闭这次捕获的实例。
      const s3: CouliModalSlot = new CouliModalSlot();
      const m3: FakeModal = new FakeModal();
      let valid: boolean = true;
      s3.show(3, m3, (): boolean => valid);
      valid = false;
      m3.completeOpen();
      await settle();
      same('invalid closed', m3.state, 'closed');
      same('invalid key', s3.openKey, 0);

      // 独立实例（CouliDialog）：调用方关闭早于打开完成。
      const m4: FakeModal = new FakeModal();
      const i4: CouliModalInstance = new CouliModalInstance(0, m4);
      i4.start((): boolean => true);
      i4.cancel();
      m4.completeOpen();
      await settle();
      same('standalone closed', m4.state, 'closed');
    });

    // ---------------------------------------------------------------- R2-06 撤回 AI 同意：保留完整错误，统一分流
    it('r2_06_withdraw_failure_keeps_code_trace_and_unified_routing', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const gate: RetryAfterGate = new RetryAfterGate((): number => rig.timer.now, (): string => 'owner');
      let next: AgentHttpResult = failure(50001, '{}', null, 'trace-abcdef');
      let records: number = 0;
      let withdrawn: number = 0;
      const routes: string[] = [];
      const flow: AgentWithdrawFlow = new AgentWithdrawFlow(gate, (): Promise<AgentHttpResult> => {
        records++;
        return Promise.resolve(next);
      }, (): void => {
        withdrawn++;
      }, (route: string): void => {
        routes.push(route);
      }, (): boolean => true);
      let o: AgentWithdrawOutcome = await flow.run();
      same('50001 not withdrawn', o.ok, false);
      same('trace6', o.text.indexOf('abcdef') >= 0, true);
      same('no placeholder', o.text.indexOf('{trace6}') < 0, true);
      same('code kept', o.result.code, 50001);
      // 42901：提示 error.42901，本入口按 Retry-After 禁用，禁用期内不发请求。
      next = failure(42901, '{}', '7');
      o = await flow.run();
      same('42901 text', o.text, AgentController.errorText(42901, ''));
      same('42901 gate', gate.active, true);
      o = await flow.run();
      same('42901 no send while disabled', records, 2);
      rig.timer.advance(7001);
      // 10001 → 统一前置路由（不提示 50001）。
      next = failure(10001);
      o = await flow.run();
      same('login route', routes, ['Login']);
      same('login no text', o.text, '');
      // 没有外壳 → 统一文案（error.50001 无 trace6 占位）。
      next = AgentHttpResult.network();
      o = await flow.run();
      same('network text', o.text, AgentController.errorText(50001, ''));
      same('never withdrawn on failure', withdrawn, 0);
      // 成功才算撤回。
      next = new AgentHttpResult(true, 200, 0, 'ok', {}, 'trace-ok', null);
      o = await flow.run();
      same('ok', o.ok, true);
      same('withdrawn once', withdrawn, 1);
      same('done text', o.text, AgentDraftTexts.text('agent.draft.withdraw.done'));
    });

    // ================================================================ harmony-review-r3 修复回归
    // ---------------------------------------------------------------- R3-01（S0）流内 error 10004 同步禁发（普通流）
    it('r3_01_stream_10004_locks_gate_every_send_entry_zero_sends', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const c: AgentController = await rig.ready();
      await rig.ask(c, '纯牛奶');
      same('first ok', c.snapshot().consentGate, AgentConsentGate.CLEAR);
      const cancels: number = rig.purchaseCancels;
      rig.script = lineScript([META, ERR_10004]);
      await rig.ask(c, '再来一条');
      same('sent once each', rig.port.bodies.length, 2);
      same('card callbacks revoked', rig.purchaseCancels > cancels, true);
      await assertZeroSendsAfterStreamConsentLost('normal', rig, c);
      // 再次同意成功才解除。
      rig.script = null;
      c.consentReopen(c.snapshot().page);
      await c.consentAgree(c.snapshot().consent as AgentConsentTicket);
      await settle();
      same('clear after agree', c.snapshot().consentGate, AgentConsentGate.CLEAR);
      same('send ok', c.send(c.snapshot().page, '现在可以'), true);
    });

    // ---------------------------------------------------------------- R3-01 duplicate 流（直接下发与【重试】后的重发收尾）同样禁发
    it('r3_01_duplicate_stream_10004_locks_gate_every_send_entry_zero_sends', 0, async () => {
      // ① meta.duplicate=true 直接下发后 error 10004（finishTurn）。
      let rig: AgentRig = new AgentRig();
      let c: AgentController = await rig.ready();
      rig.script = lineScript([DUP_META, ERR_10004]);
      await rig.ask(c, '纯牛奶');
      same('dup sent once', rig.port.bodies.length, 1);
      await assertZeroSendsAfterStreamConsentLost('duplicate', rig, c);

      // ② 断线后【重试】（同一 client_msg_id），回来的 duplicate 两帧是 error 10004（endDuplicate）。
      rig = new AgentRig();
      rig.fixture = 'disconnected';
      c = await rig.ready();
      await rig.ask(c, '纯牛奶 24盒', 1000);
      rig.timer.advance(30500);
      await settle();
      const turn: AgentTurnView = rig.turn(c);
      same('disconnected retry', turn.error !== null && turn.error.retry !== null, true);
      rig.script = lineScript([DUP_META, ERR_10004]);
      c.retry((turn.error as AgentErrorView).retry as AgentRetryTap);
      await settle();
      rig.timer.advance(2000);
      await settle();
      same('resent once', rig.port.bodies.length, 2);
      await assertZeroSendsAfterStreamConsentLost('duplicate resend', rig, c);
    });

    // ---------------------------------------------------------------- R3-02 撤回挂起时离页，迟到的 10005 不导航、限流照常结算
    it('r3_02_withdraw_late_prereq_does_not_navigate_after_leaving_page', 0, async () => {
      const rig: AgentRig = new AgentRig();
      const gate: RetryAfterGate = new RetryAfterGate((): number => rig.timer.now, (): string => 'owner');
      const waiters: ((r: AgentHttpResult) => void)[] = [];
      let records: number = 0;
      let withdrawn: number = 0;
      const routes: string[] = [];
      let identity: string = 'owner';
      const fixedIdentity: string = identity;
      // 设置页实例：可见时确认撤回，本次操作的导航许可当场固定。
      let life: MePageLife = new MePageLife();
      life.shown();
      let permit: () => boolean = life.permit();
      const flowOf = (p: () => boolean): AgentWithdrawFlow => new AgentWithdrawFlow(gate, (): Promise<AgentHttpResult> => {
        records++;
        return new Promise<AgentHttpResult>((resolve: (r: AgentHttpResult) => void): void => {
          waiters.push(resolve);
        });
      }, (): void => {
        withdrawn++;
      }, (route: string): void => {
        routes.push(route);
      }, (): boolean => identity === fixedIdentity && p());
      const release = (r: AgentHttpResult): void => {
        const all: ((r: AgentHttpResult) => void)[] = waiters.splice(0, waiters.length);
        for (const w of all) {
          w(r);
        }
      };
      // ① 挂起期间返回「我的」（设置页出栈），再打开其他页面；身份未变。迟到的 10005 不导航。
      let pending: Promise<AgentWithdrawOutcome> = flowOf(permit).run();
      life.hidden();
      life.leave();
      release(failure(10005));
      let o: AgentWithdrawOutcome = await pending;
      same('route decided', o.route, 'BindPhone');
      same('left page: no navigation', routes.length, 0);
      same('not withdrawn', withdrawn, 0);
      // ② 挂起期间被其他页面盖住（没出栈）后回来：导航世代已变，也不导航。
      life = new MePageLife();
      life.shown();
      permit = life.permit();
      pending = flowOf(permit).run();
      life.hidden();
      life.shown();
      release(failure(10005));
      await pending;
      same('covered then back: no navigation', routes.length, 0);
      // ③ 离页后迟到的 42901：限流照常结算（本入口禁用），禁用期内不再发请求。
      life = new MePageLife();
      life.shown();
      permit = life.permit();
      pending = flowOf(permit).run();
      life.leave();
      release(failure(42901, '{}', '7'));
      o = await pending;
      same('late 42901 settles gate', gate.active, true);
      same('late 42901 disable', o.disableMs, 7000);
      const before: number = records;
      await flowOf((): boolean => true).run();
      same('disabled: no request', records, before);
      rig.timer.advance(7001);
      // ④ 离页后迟到的成功：应用级作废照常完成。
      life = new MePageLife();
      life.shown();
      permit = life.permit();
      pending = flowOf(permit).run();
      life.leave();
      release(new AgentHttpResult(true, 200, 0, 'ok', {}, 'trace-ok', null));
      o = await pending;
      same('late ok withdrawn', withdrawn, 1);
      // ⑤ 身份已变（页面仍可见）：不导航。
      life = new MePageLife();
      life.shown();
      permit = life.permit();
      pending = flowOf(permit).run();
      identity = 'other';
      release(failure(10005));
      await pending;
      same('identity changed: no navigation', routes.length, 0);
      identity = fixedIdentity;
      // ⑥ 对照：发起页一直可见、身份不变 → 照常打开前置页。
      pending = flowOf(permit).run();
      release(failure(10005));
      await pending;
      same('still visible: navigates', routes, ['BindPhone']);
    });

    // ---------------------------------------------------------------- F-HM-27 撤回挂起时进入设置页内子页，迟到的 10005 不导航
    // 设置页的修改昵称、通知设置、协议半屏是页内子页：切换不触发 onHidden，由 SettingsView 在切换时调 MePageLife.subPageEntered()
    // （AppSettingsPage 把 SettingsPageConfig.subPageEntered 接到本页 life）。这里用同一个 MePageLife 与真实 AgentWithdrawFlow，
    // 前置路由的打开条件与 AppAgent.withdrawConsent 相同（固定身份 + 确认时固定的许可）。
    it('fu_hm_27_withdraw_late_prereq_after_entering_settings_sub_page_does_not_navigate', 0, async () => {
      const timer: AgentManualTimer = new AgentManualTimer();
      const gate: RetryAfterGate = new RetryAfterGate((): number => timer.now, (): string => 'owner');
      const waiters: ((r: AgentHttpResult) => void)[] = [];
      let records: number = 0;
      let withdrawn: number = 0;
      const routes: string[] = [];
      const identity: string = 'owner';
      const flowOf = (p: () => boolean): AgentWithdrawFlow => new AgentWithdrawFlow(gate, (): Promise<AgentHttpResult> => {
        records++;
        return new Promise<AgentHttpResult>((resolve: (r: AgentHttpResult) => void): void => {
          waiters.push(resolve);
        });
      }, (): void => {
        withdrawn++;
      }, (route: string): void => {
        // 与 AppAgent.withdrawConsent 一样：打开前再核对一次固定身份与许可。
        if (identity === 'owner' && p()) {
          routes.push(route);
        }
      }, (): boolean => identity === 'owner' && p());
      const release = (r: AgentHttpResult): void => {
        const all: ((r: AgentHttpResult) => void)[] = waiters.splice(0, waiters.length);
        for (const w of all) {
          w(r);
        }
      };
      // ① 挂起期间进入「通知设置」子页（设置页本身一直可见，没有 onHidden）：迟到的 10005 不导航。
      const life: MePageLife = new MePageLife();
      life.shown();
      let pending: Promise<AgentWithdrawOutcome> = flowOf(life.permit()).run();
      life.subPageEntered();
      release(failure(10005));
      let o: AgentWithdrawOutcome = await pending;
      same('sub: route decided', o.route, 'BindPhone');
      same('sub: no navigation', routes.length, 0);
      same('sub: not withdrawn', withdrawn, 0);
      // ② 进入「修改昵称」后又返回设置主页：旧许可不恢复，迟到的 10005 仍不导航。
      pending = flowOf(life.permit()).run();
      life.subPageEntered();
      // 返回主页只是视图切回（SettingsView.closeSub），不调用 life 的任何方法；页面仍可见。
      same('back on main: page visible', life.visible, true);
      release(failure(10005));
      await pending;
      same('sub then back: no navigation', routes.length, 0);
      // ③ 进入子页后迟到的 42901：限流照常结算（本入口禁用），禁用期内不再发请求。
      pending = flowOf(life.permit()).run();
      life.subPageEntered();
      release(failure(42901, '{}', '7'));
      o = await pending;
      same('sub: late 42901 settles gate', gate.active, true);
      same('sub: late 42901 disable', o.disableMs, 7000);
      const before: number = records;
      await flowOf((): boolean => true).run();
      same('sub: disabled no request', records, before);
      timer.advance(7001);
      // ④ 进入子页后迟到的成功：应用级作废（清理）照常完成。
      pending = flowOf(life.permit()).run();
      life.subPageEntered();
      release(new AgentHttpResult(true, 200, 0, 'ok', {}, 'trace-ok', null));
      await pending;
      same('sub: late ok withdrawn', withdrawn, 1);
      // ⑤ 对照：返回主页后重新确认（新许可在最后一次切换之后固定）、一直留在主页 → 照常打开前置页。
      pending = flowOf(life.permit()).run();
      release(failure(10005));
      await pending;
      same('fresh permit on main: navigates', routes, ['BindPhone']);
    });
  });
}
