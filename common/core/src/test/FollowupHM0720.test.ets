// FU-HM-0720：Android APP-10b 共性 36–46 / iOS APP-05b 共性 19–24 回灌到鸿蒙的回归用例。
// Agent 部分沿用 AgentTransportIntegration 的接线（真实 ApiClient + 真实端口 ApiAgentContractPort + AgentController + 抓包传输替身
// Recorder / 手工喂字节 ManualSink）；AppAgent 的应用级「AI 同意失效」接线按 AgentTransportReviewR3 同一写法组装 Core 的 AgentConsentLapse。
// 数据只用构造值与锁定 fixture / 向量的形状，不连任何地址。
import { describe, it } from '@ohos/hypium';
import {
  AgentCall, AgentConsentGate, AgentConsentLapse, AgentContractPort, AgentController, AgentConversationPort, AgentDeps,
  AgentErrorView, AgentFeedbackView, AgentGates, AgentHttpResult, AgentIdentity, AgentReportEntryView, AgentRetryMode,
  AccountPendingView, AgentRetryTap, AgentRunTicket, AgentSnapshot, AgentStreamHandle, AgentStreamSink, AgentTurnView, AuthAnnouncement,
  LoginSendState, RouteRequest, RouteSource, TransportFailure, TransportRequest, TransportResponse, AppEnvironment,
  BindOutcome, BindPhoneAction, BindPhoneAnnouncer, BindPhoneFields, BindPhoneForm, BindPhoneFormBinding, BindPhoneIdentity,
  BindPhoneService,
  BindPhoneTicker, BindPhoneTickScheduler, CacheClear, CacheFs, MeSession, OAuthLoginOutcome, OAuthProvider,
  PhoneBindingState, SendCodeOutcome, SessionTokenSet, SmsSendDeadlines, ThirdPartyAuthAdapter, ThirdPartyAuthKind,
  ThirdPartyAuthResult
} from '../../Index';
import { delta, done, guideCard, ManualSink, META, OpenRecord, same, SESSION, TRig, Wire } from './AgentTransportIntegration.test';
import { AGENT_TRANSPORT_VECTORS_JSON } from './AgentTransportVectorsData';
import { ClientEvent } from 'generated';
import { DebugSubstitutes, GatedAuthAdapter } from '../staging/ets/network/DebugSubstitutes';
import { envelope as netEnvelope, flush } from './NetworkTestRig';
import { AccountFixture, gateway, Host, NEW_PHONE, settle } from './AccountIntegration.test';
import { FakeAuthAdapter, OAuthFixture } from './App05bFixture';
import { Fixture } from './OpenPurchaseIntegration.test';

const TRACE: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';
const AI: string = '{"consent_type":"ai_third_party"}';
/** META 帧里的回复 id（AgentTransportIntegration.META）。 */
const REPLY: string = '019a0000-0000-7000-8000-000000000222';
const USER_ID: string = '019a0000-0000-7000-8000-000000000221';

function json(code: number, data: string): TransportResponse {
  const h: Record<string, string> = {};
  h['content-type'] = 'application/json';
  if (code === 42901) {
    h['retry-after'] = '12';
  }
  return TransportResponse.ok(code === 0 ? 200 : code === 42901 ? 429 : 400, h,
    '{"code":' + String(code) + ',"msg":"","data":' + data + ',"trace_id":"' + TRACE + '"}');
}

function envelope(code: number, data: string): string {
  return '{"code":' + String(code) + ',"msg":"","data":' + data + ',"trace_id":"' + TRACE + '"}';
}

function item(id: string, role: string, at: string, text: string, finish: string | null): string {
  return '{"message_id":"' + id + '","role":"' + role + '","created_at":"' + at + '","text":' + JSON.stringify(text)
    + ',"cards":[],"finish_reason":' + (finish === null ? 'null' : '"' + finish + '"') + '}';
}

/** 一页历史：目标轮（用户 + 回复 REPLY，finish 给定）；finish 为 undefined 时空页（历史里没有目标）。 */
function pageWith(userText: string, replyText: string, finish: string | null, present: boolean): string {
  if (!present) {
    return '{"items":[],"next_cursor":null,"expired":false}';
  }
  return '{"items":[' + item(USER_ID, 'user', '2026-10-14T10:00:00+08:00', userText, null) + ','
    + item(REPLY, 'assistant', '2026-10-14T10:00:02+08:00', replyText, finish) + '],"next_cursor":null,"expired":false}';
}

/** 可控的一次回答（先挂起，release 时交出）。 */
class Held {
  private resolve: ((r: TransportResponse) => void) | null = null;
  readonly promise: Promise<TransportResponse>;

  constructor() {
    this.promise = new Promise<TransportResponse>((res: (r: TransportResponse) => void): void => {
      this.resolve = res;
    });
  }

  release(r: TransportResponse): void {
    const f: ((r: TransportResponse) => void) | null = this.resolve;
    if (f !== null) {
      f(r);
    }
  }
}

/** AppAgent 的应用级「AI 同意失效」接线（按此刻归属键核对），并数上报次数。 */
class Lapse {
  readonly lapse: AgentConsentLapse = new AgentConsentLapse();
  current: AgentController | null = null;
  reports: number = 0;
  private readonly rig: TRig;

  constructor(rig: TRig) {
    this.rig = rig;
    rig.allowed = (): boolean => this.allowed();
    rig.port.gate = (): boolean => this.allowed();
    rig.consentLapsed = (): boolean => this.lapse.blocks(rig.identity.ownerKey);
    rig.aiConsentLost = (ownerKey: string): void => {
      this.reports++;
      this.lapse.lapse(ownerKey, rig.identity.ownerKey, this.current);
    };
  }

  allowed(): boolean {
    return !this.lapse.blocks(this.rig.identity.ownerKey);
  }

  get lapsed(): boolean {
    return this.lapse.blocks(this.rig.identity.ownerKey);
  }
}

function page(rig: TRig, n: number, user: string = 'user-1', session: string = 's1'): void {
  rig.identity = new AgentIdentity('test', AgentIdentity.MEMBER, user, session, 0, n);
}

/** 应用级三组闸门按归属键（不含页面实例）判定（AppAgent 的接线，R3-03）。 */
function ownerGates(rig: TRig): void {
  rig.gates = AgentGates.create((): number => rig.timer.now, (): string => rig.identity.ownerKey, false);
  rig.gates.retain(rig.identity.ownerKey);
}

async function newStream(rig: TRig, c: AgentController, text: string, first: string): Promise<ManualSink> {
  c.send(c.snapshot().page, text);
  await rig.pump(50);
  const m: ManualSink = rig.rec.lastManual;
  m.headers();
  m.text(META + delta(2, first));
  await rig.pump();
  return m;
}

/** 当前会话 + 一条进行中的回复（已收到 meta 与第一段文字）。 */
async function streaming(rig: TRig, text: string, first: string): Promise<AgentController> {
  rig.rec.manual = true;
  rig.fake.currentSessionId = SESSION;
  const c: AgentController = await rig.ready();
  await newStream(rig, c, text, first);
  return c;
}

function errorOf(rig: TRig, c: AgentController, i: number = -1): AgentErrorView | null {
  return rig.turn(c, i).error;
}

/**
 * 把真实端口的结果在交给控制器之前扣住（模拟「回包已处理完、等待调度回到控制器」的窗口，Android R3-01 的时间线）：
 * hold 打开时，下一次匹配 op 的结果先交给 held，release() 时再交付。请求本身照常经真实 ApiClient 发出。
 */
class HoldPort implements AgentContractPort, AgentConversationPort {
  private readonly inner: AgentContractPort;
  private readonly conv: AgentConversationPort;
  holdOp: string = '';
  private releaser: (() => void) | null = null;
  private arrived: boolean = false;

  constructor(inner: AgentContractPort, conv: AgentConversationPort) {
    this.inner = inner;
    this.conv = conv;
  }

  get resultArrived(): boolean {
    return this.arrived;
  }

  release(): void {
    const f: (() => void) | null = this.releaser;
    this.releaser = null;
    if (f !== null) {
      f();
    }
  }

  private wrap(op: string, p: Promise<AgentHttpResult>): Promise<AgentHttpResult> {
    if (op !== this.holdOp) {
      return p;
    }
    this.holdOp = '';
    return p.then((r: AgentHttpResult): Promise<AgentHttpResult> => {
      this.arrived = true;
      return new Promise<AgentHttpResult>((res: (v: AgentHttpResult) => void): void => {
        this.releaser = (): void => res(r);
      });
    });
  }

  createSession(call: AgentCall): Promise<AgentHttpResult> {
    return this.wrap('create', this.inner.createSession(call));
  }

  currentSession(call: AgentCall): Promise<AgentHttpResult> {
    return this.wrap('current', this.inner.currentSession(call));
  }

  sendMessage(sessionId: string, body: string, call: AgentCall, sink: AgentStreamSink): AgentStreamHandle {
    return this.inner.sendMessage(sessionId, body, call, sink);
  }

  cancelRun(runId: string, call: AgentCall): Promise<AgentHttpResult> {
    return this.inner.cancelRun(runId, call);
  }

  cancelOwned(identityKey: string): void {
    this.inner.cancelOwned(identityKey);
  }

  listMessages(sessionId: string, cursor: string | null, limit: number, call: AgentCall, autoRetry: boolean):
    Promise<AgentHttpResult> {
    return this.wrap('history', this.conv.listMessages(sessionId, cursor, limit, call, autoRetry));
  }

  setFeedback(messageId: string, value: string, call: AgentCall): Promise<AgentHttpResult> {
    return this.wrap('feedback', this.conv.setFeedback(messageId, value, call));
  }

  report(messageId: string, reason: string, call: AgentCall): Promise<AgentHttpResult> {
    return this.wrap('report', this.conv.report(messageId, reason, call));
  }
}

/** 与 TRig.controller 同一套接线，只是端口换成 HoldPort。 */
function heldController(rig: TRig, port: HoldPort): AgentController {
  const deps: AgentDeps = new AgentDeps(rig.identity, (): string => rig.identity.key, rig.gates.send);
  deps.contract = port;
  deps.conversation = port;
  deps.readGate = rig.gates.read;
  deps.actionGate = rig.gates.action;
  deps.timer = rig.timer;
  deps.clock = (): number => rig.timer.now;
  deps.random = (): number => rig.random;
  deps.foreground = (): boolean => rig.foreground;
  deps.cancelLedger = rig.ledger;
  deps.allowed = (): boolean => rig.allowed();
  deps.consentLapsed = (): boolean => rig.consentLapsed();
  deps.aiConsentLost = (ownerKey: string): void => rig.aiConsentLost(ownerKey);
  deps.currentOwnerKey = (): string => rig.identity.ownerKey;
  deps.open = (route: string, params: Record<string, Object>, source: RouteSource): void => {
    rig.opens.push(new OpenRecord(route, params, source));
    rig.router.open(RouteRequest.of(route, source, params));
  };
  deps.recordConsent = (accepted: boolean): Promise<AgentHttpResult> => {
    rig.fake.consentGranted = accepted;
    return Promise.resolve(new AgentHttpResult(true, 200, 0, 'ok', {}, 'trace-consent-000001', null));
  };
  deps.track = (e: ClientEvent): void => {
    rig.events.push(e);
  };
  deps.toast = (t: string): void => {
    rig.toasts.push(t);
  };
  deps.forceUpdate = (): void => {
    rig.forced++;
  };
  deps.cancelPurchase = (): void => {
    rig.purchaseCancels++;
  };
  deps.log = (m: string): void => {
    rig.logs.push(m);
  };
  const c: AgentController = new AgentController(deps);
  c.onChange = (s: AgentSnapshot): void => {
    rig.snapshots.push(s);
  };
  c.setVisible(true);
  return c;
}

/** 重建页同归属的新流在 AI 10004 之后：停下、锁同意、不弹框不导航、不能再发、之后 0 帧交付。 */
async function assertRebuiltHalted(tag: string, rig: TRig, w: Lapse, rebuilt: AgentController, m: ManualSink,
  opens: number, toasts: number): Promise<void> {
  same(tag + ' lapse reported once', w.reports, 1);
  same(tag + ' lapsed', w.lapsed, true);
  same(tag + ' new stream halted', rebuilt.snapshot().sending, false);
  same(tag + ' consent refused', rebuilt.snapshot().consentGate, AgentConsentGate.REFUSED);
  same(tag + ' no dialog', rebuilt.snapshot().consent, null);
  same(tag + ' no navigation', rig.opens.length, opens);
  same(tag + ' no toast', rig.toasts.length, toasts);
  same(tag + ' cannot send', rebuilt.canSend, false);
  m.text(delta(3, '后') + done(4, 7));
  await rig.pump();
  same(tag + ' no late delta', rig.state(rebuilt).text, '新');
  const wire: number = rig.rec.wire.length;
  same(tag + ' send refused', rebuilt.send(rebuilt.snapshot().page, '再问'), false);
  await rig.pump(200);
  same(tag + ' no request', rig.rec.wire.length, wire);
}

// ---------------------------------------------------------------- APP-05b / APP-12 用的小替身

class TestFields implements BindPhoneFields {
  phoneText: string = '';
  codeText: string = '';
  phoneError: string = '';
  codeError: string = '';
}

function bindService(f: AccountFixture, host: Host, binding: PhoneBindingState = new PhoneBindingState()): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), binding,
    host, (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

/** 换上新令牌（另一账号或同账号重新登录：登录世代都变），并按 App 状态同步的同一出口通知绑手机服务。 */
function relogin(f: AccountFixture, svc: BindPhoneService, account: string, tag: string): void {
  f.rig.tokens.save(new SessionTokenSet('access-' + account + '-' + tag, 'refresh-' + account + '-' + tag, 'full', account));
  f.rig.client.onSessionChanged();
  svc.syncSession();
}

function filled(form: BindPhoneForm): BindPhoneFormBinding {
  const b: BindPhoneFormBinding = form.binding();
  form.setPhone(b, NEW_PHONE);
  form.setCode(b, '123456');
  return form.binding();
}

/** 手动触发的每秒刷新调度器（FU-HM-0720 R2-01）。 */
class ManualTicks implements BindPhoneTickScheduler {
  private readonly fns: Map<number, () => void> = new Map<number, () => void>();
  private next: number = 1;

  start(_millis: number, fn: () => void): number {
    const id: number = this.next++;
    this.fns.set(id, fn);
    return id;
  }

  stop(id: number): void {
    this.fns.delete(id);
  }

  get active(): number {
    return this.fns.size;
  }

  fire(): void {
    for (const fn of Array.from(this.fns.values())) {
      fn();
    }
  }
}

/**
 * 绑手机页计时部分的替身（按 BindPhoneView 同一接线：Core BindPhoneTicker + BindPhoneForm.deadlinesChanged + onShown 的 refresh +
 * 发码结果交付后的 refresh）。delivered / announced 记录页面拿到的发码结果与读屏播报（toast、风控框、字段错误都只在 delivered 非空时出现）。
 */
class TimerPage {
  readonly svc: BindPhoneService;
  readonly fields: TestFields = new TestFields();
  readonly form: BindPhoneForm;
  readonly ticker: BindPhoneTicker;
  readonly announcer: BindPhoneAnnouncer = new BindPhoneAnnouncer();
  readonly delivered: SendCodeOutcome[] = [];
  readonly announced: string[] = [];
  hooks: number = 0;

  constructor(svc: BindPhoneService, ticks: ManualTicks) {
    this.svc = svc;
    this.form = new BindPhoneForm(svc, this.fields);
    this.ticker = new BindPhoneTicker((): void => {
      const st: LoginSendState = svc.sendState(this.form.binding().fields.phoneText);
      const a: AuthAnnouncement | null = this.announcer.tick(this.form.binding().fields.phoneText,
        st.countdownSec + st.rateLimitedSec);
      if (a !== null) {
        this.announced.push(a.textKey);
      }
    }, (): boolean => !this.sendEnabled(), ticks);
    this.form.deadlinesChanged = (): void => {
      this.hooks++;
      this.ticker.refresh();
    };
  }

  /** 【获取验证码】可点（不算 sending）：这个号码此刻没有倒计时、没有限流。 */
  sendEnabled(): boolean {
    const st: LoginSendState = this.svc.sendState(this.form.binding().fields.phoneText);
    return st.countdownSec === 0 && st.rateLimitedSec === 0;
  }

  /** NavDestination.onShown 的正常分支。 */
  shown(): void {
    this.form.pageShown();
    this.ticker.refresh();
  }

  async send(): Promise<void> {
    const b: BindPhoneFormBinding = this.form.binding();
    const o: SendCodeOutcome | null = await this.form.sendCode(b);
    if (o === null || !this.form.live(b)) {
      return;
    }
    this.delivered.push(o);
    const a: AuthAnnouncement | null = this.announcer.sendResult(o, b.fields.phoneText);
    if (a !== null) {
      this.announced.push(a.textKey);
    }
    this.ticker.refresh();
  }
}

/**
 * 绑手机页待确认部分的替身（FU-HM-0720 R3-01；按 BindPhoneView 同一接线：form.subscribePending → refreshPending；onShown 正常分支
 * refreshPending；subscribeSession → resetForSession，被盖住时不读待确认）。pending / announced 是页面的待确认卡与读屏播报。
 */
class PendingPage {
  readonly svc: BindPhoneService;
  readonly form: BindPhoneForm;
  identity: BindPhoneIdentity;
  pending: AccountPendingView | null = null;
  readonly announced: string[] = [];
  refreshes: number = 0;
  private readonly unsubscribers: (() => void)[] = [];

  constructor(svc: BindPhoneService) {
    this.svc = svc;
    this.form = new BindPhoneForm(svc, new TestFields());
    this.identity = this.form.pageIdentity;
    this.refresh();
    this.unsubscribers.push(svc.subscribeSession((): void => this.resetForSession()));
    this.unsubscribers.push(this.form.subscribePending((): void => this.refresh()));
  }

  /** BindPhoneView.refreshPending：按共享记录更新待确认卡，新出现时播报一次。 */
  refresh(): void {
    this.refreshes++;
    const p: AccountPendingView | null = this.svc.pendingView(this.identity);
    const was: AccountPendingView | null = this.pending;
    this.pending = p;
    if (p !== null && (was === null || was.key !== p.key)) {
      this.announced.push(p.key);
    }
  }

  private resetForSession(): void {
    this.pending = null;
    this.identity = this.form.reset(new TestFields());
    if (this.form.presentable()) {
      this.refresh();
    }
  }

  /** NavDestination.onShown 的正常分支。 */
  shown(): void {
    if (this.form.pageShown()) {
      return;
    }
    if (!this.svc.identityValid(this.identity)) {
      this.resetForSession();
      return;
    }
    this.refresh();
  }

  /** aboutToDisappear 的退订（离页窗口：onWillDisappear 先 leave，之后才退订）。 */
  dispose(): void {
    for (const u of this.unsubscribers) {
      u();
    }
  }
}

/** 总是可用的假第三方授权器（只在测试里）。 */
class AlwaysAuth implements ThirdPartyAuthAdapter {
  readonly provider: string = OAuthProvider.WECHAT;

  adapterAvailable(): boolean {
    return true;
  }

  installed(): boolean | null {
    return true;
  }

  authorize(nonce: string): Promise<ThirdPartyAuthResult> {
    return Promise.resolve(new ThirdPartyAuthResult(ThirdPartyAuthKind.CREDENTIAL, 'debug-stub-code', nonce));
  }
}

/** 内存文件系统（清缓存口径用）：可设删除后「立刻重建」的文件、删除失败、列目录失败。 */
class MemFs implements CacheFs {
  readonly files: Set<string> = new Set<string>();
  dirExists: boolean = true;
  recreate: string = '';
  failRemove: string = '';
  failList: boolean = false;
  vanish: string = '';

  exists(path: string): boolean {
    return path === 'cache' ? this.dirExists : this.files.has(path);
  }

  list(_dir: string): string[] {
    if (this.failList) {
      throw new Error('list failed');
    }
    const out: string[] = [];
    this.files.forEach((p: string): void => {
      out.push(p.substring('cache/'.length));
    });
    return out;
  }

  isDirectory(_path: string): boolean {
    return false;
  }

  removeDirectory(path: string): void {
    this.removeFile(path);
  }

  removeFile(path: string): void {
    if (path === this.vanish) {
      this.files.delete(path);
      throw new Error('ENOENT');
    }
    if (path === this.failRemove) {
      throw new Error('EACCES');
    }
    this.files.delete(path);
    if (this.recreate.length > 0 && !this.files.has(this.recreate)) {
      // WebView / 图片加载在途：删完立刻又写出缓存文件。
      this.files.add(this.recreate);
    }
  }
}

export default function followupHM0720Test(): void {
  describe('FollowupHM0720', () => {
    // ---------------------------------------------------------------- 共性 36（Android R1-01 S0）
    it('fhm0720_36_stop_before_meta_then_http_json_ai_10004_locks_gate_lapses_once_no_dialog_no_nav', 0, async () => {
      const rig: TRig = new TRig();
      const w: Lapse = new Lapse(rig);
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      w.current = c;
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      // 请求已发出、还没有任何响应（meta 之前）：点【停止】进入「正在停止」。
      c.stop(c.snapshot().stop as AgentRunTicket);
      await rig.pump();
      same('stopping', rig.turn(c).statusText, '正在停止');
      const opens: number = rig.opens.length;
      // 服务端随后回 HTTP JSON：AI 10004。
      m.headers('application/json', 400);
      m.text(envelope(10004, AI));
      m.end();
      await rig.pump(100);
      same('consent refused', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('lapse reported once', w.reports, 1);
      same('lapsed', w.lapsed, true);
      same('no dialog', c.snapshot().consent, null);
      same('no navigation', rig.opens.length, opens);
      same('no cancel (no run id)', rig.rec.count('/cancel'), 0);
      same('cannot send', c.canSend, false);
      const wire: number = rig.rec.wire.length;
      same('send refused', c.send(c.snapshot().page, '再问'), false);
      await rig.pump(200);
      same('no request after', rig.rec.wire.length, wire);
    });

    it('fhm0720_36_stop_before_meta_then_http_json_42901_writes_send_gate', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      c.stop(c.snapshot().stop as AgentRunTicket);
      await rig.pump();
      const extra: Record<string, string> = {};
      extra['retry-after'] = '9';
      m.headers('application/json', 429, extra);
      m.text(envelope(42901, '{}'));
      m.end();
      await rig.pump(100);
      same('send gate written', rig.gates.send.active, true);
      same('cancelled locally', rig.state(c).status, 'cancelled');
      same('consent clear', c.snapshot().consentGate, AgentConsentGate.CLEAR);
    });

    // ---------------------------------------------------------------- 共性 37（Android R1-02）
    it('fhm0720_37_no_envelope_success_json_and_transport_failure_show_disconnected_reload_history_then_same_id', 0,
      async () => {
        for (const kind of ['html', 'code0', 'failure', 'notsent']) {
          const rig: TRig = new TRig();
          rig.rec.manual = true;
          rig.fake.currentSessionId = SESSION;
          const c: AgentController = await rig.ready();
          if (kind === 'notsent') {
            // 未发出（实际写出前准入不通过）：静默，不留这一轮。
            c.send(c.snapshot().page, '纯牛奶');
            rig.allowed = (): boolean => false;
            await rig.pump(100);
            rig.allowed = (): boolean => true;
            same('notsent silent no turn', c.snapshot().turns.length, 0);
            same('notsent no toast', rig.toasts.length, 0);
            continue;
          }
          c.send(c.snapshot().page, '纯牛奶');
          await rig.pump(50);
          const m: ManualSink = rig.rec.lastManual;
          const firstId: string | null = rig.rec.streams[0].clientMsgId;
          if (kind === 'html') {
            m.headers('text/html', 502);
            m.text('<html>bad gateway</html>');
            m.end();
          } else if (kind === 'code0') {
            m.headers('application/json', 200);
            m.text(envelope(0, '{}'));
            m.end();
          } else {
            m.sink?.onFailure(TransportFailure.DISCONNECT);
          }
          await rig.pump(100);
          const err: AgentErrorView | null = errorOf(rig, c);
          same(kind + ' turn kept', c.snapshot().turns.length, 1);
          same(kind + ' disconnected text', err === null ? null : (err as AgentErrorView).text, '连接中断');
          same(kind + ' reload retry', err === null || err.retry === null ? null : (err.retry as AgentRetryTap).mode,
            AgentRetryMode.RECONNECT);
          same(kind + ' not new chat', err === null ? null : err.newChat, null);
          // 【重试】先查历史（对不上）再用原 client_msg_id 重发。
          rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.method === 'GET'
            && r.url.indexOf('/messages') >= 0 ? Promise.resolve(json(0, pageWith('', '', null, false))) : null;
          const history: number = rig.rec.wire.filter((x: Wire): boolean => x.method === 'GET' && x.path.indexOf('/messages') >= 0)
            .length;
          c.retry((err as AgentErrorView).retry as AgentRetryTap);
          await rig.pump(300);
          same(kind + ' history first', rig.rec.wire.filter((x: Wire): boolean => x.method === 'GET'
            && x.path.indexOf('/messages') >= 0).length, history + 1);
          same(kind + ' resent', rig.rec.streams.length, 2);
          same(kind + ' same client_msg_id', rig.rec.streams[1].clientMsgId, firstId);
        }
      });

    // ---------------------------------------------------------------- 共性 38（Android R1-03）
    it('fhm0720_38_retry_history_unmatched_after_tab_switch_keeps_turn_and_resends_while_hidden', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + delta(2, '部分'));
      m.end();
      await rig.pump(100);
      const firstId: string | null = rig.rec.streams[0].clientMsgId;
      const err: AgentErrorView = errorOf(rig, c) as AgentErrorView;
      const held: Held = new Held();
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.method === 'GET'
        && r.url.indexOf('/messages') >= 0 ? held.promise : null;
      c.retry(err.retry as AgentRetryTap);
      await rig.pump(50);
      // 历史在途时切到别的 Tab（App 仍在前台）。
      c.setVisible(false);
      const published: number = rig.snapshots.length;
      held.release(json(0, pageWith('', '', null, false)));
      await rig.pump(100);
      same('turn kept while hidden', c.streamStates.length, 1);
      same('partial kept', rig.state(c).text, '部分');
      same('resent while hidden', rig.rec.streams.length, 2);
      same('same client_msg_id', rig.rec.streams[1].clientMsgId, firstId);
      same('no ui publish while hidden', rig.snapshots.length, published);
      c.setVisible(true);
      await rig.pump();
      same('applied once on return', rig.snapshots.length > published, true);
      same('still one turn', c.snapshot().turns.length, 1);
    });

    // ---------------------------------------------------------------- 共性 40（Android R2-01 S0）
    it('fhm0720_40_feedback_and_report_ai_10004_after_cancel_30505_history_replace_halt_new_stream_and_lock', 0,
      async () => {
        for (const action of ['feedback', 'report']) {
          const rig: TRig = new TRig();
          const w: Lapse = new Lapse(rig);
          const c: AgentController = await streaming(rig, '提现记录在哪看', '正文');
          w.current = c;
          const cancelHeld: Held = new Held();
          const actionHeld: Held = new Held();
          let historyArmed: boolean = false;
          rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => {
            if (r.url.indexOf('/cancel') >= 0) {
              return cancelHeld.promise;
            }
            if (r.url.indexOf('/' + action) >= 0) {
              return actionHeld.promise;
            }
            if (historyArmed && r.method === 'GET' && r.url.indexOf('/messages') >= 0) {
              return Promise.resolve(json(0, pageWith('提现记录在哪看', '服务端正文', 'stop', true)));
            }
            return null;
          };
          // 收到正文后停止，cancel 暂不返回。
          c.stop(c.snapshot().stop as AgentRunTicket);
          await rig.pump(50);
          same(action + ' one cancel', rig.rec.count('/cancel'), 1);
          // 对该回复发起反馈 / 举报（在途）。
          if (action === 'feedback') {
            const fb: AgentFeedbackView = rig.turn(c, 0).feedback as AgentFeedbackView;
            c.feedback(fb.ticket, 'up');
          } else {
            const entry: AgentReportEntryView = rig.turn(c, 0).report as AgentReportEntryView;
            c.reportOpen(entry.ticket);
            c.reportEdit(entry.ticket, '其他问题', '');
            c.reportSubmit(entry.ticket);
          }
          await rig.pump(50);
          same(action + ' action sent', rig.rec.count('/' + action), 1);
          // cancel 返回 30505 → 历史重载用相同回复 id 替换本轮（动作状态被重置）。
          historyArmed = true;
          cancelHeld.release(json(30505, '{}'));
          await rig.pump(200);
          same(action + ' replaced from history', rig.state(c, 0).text, '服务端正文');
          historyArmed = false;
          // 随后开始新一轮。
          const m: ManualSink = await newStream(rig, c, '新问题', '新');
          same(action + ' new stream', c.snapshot().sending, true);
          const opens: number = rig.opens.length;
          const toasts: number = rig.toasts.length;
          // 旧动作请求返回 AI 10004。
          actionHeld.release(json(10004, AI));
          await rig.pump(50);
          await assertRebuiltHalted(action, rig, w, c, m, opens, toasts);
          same(action + ' reset state untouched', action === 'feedback'
            ? (rig.turn(c, 0).feedback === null ? 'none' : (rig.turn(c, 0).feedback as AgentFeedbackView).selected)
            : 'n/a', action === 'feedback' ? null : 'n/a');
        }
      });

    it('fhm0720_40_late_42901_of_reset_feedback_writes_action_gate_but_keeps_reset_state', 0, async () => {
      const rig: TRig = new TRig();
      const c: AgentController = await streaming(rig, '提现记录在哪看', '正文');
      const cancelHeld: Held = new Held();
      const actionHeld: Held = new Held();
      let historyArmed: boolean = false;
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => {
        if (r.url.indexOf('/cancel') >= 0) {
          return cancelHeld.promise;
        }
        if (r.url.indexOf('/feedback') >= 0) {
          return actionHeld.promise;
        }
        if (historyArmed && r.method === 'GET' && r.url.indexOf('/messages') >= 0) {
          return Promise.resolve(json(0, pageWith('提现记录在哪看', '服务端正文', 'stop', true)));
        }
        return null;
      };
      c.stop(c.snapshot().stop as AgentRunTicket);
      await rig.pump(50);
      c.feedback((rig.turn(c, 0).feedback as AgentFeedbackView).ticket, 'up');
      await rig.pump(50);
      historyArmed = true;
      cancelHeld.release(json(30505, '{}'));
      await rig.pump(200);
      same('reset shows unselected', (rig.turn(c, 0).feedback as AgentFeedbackView).selected, null);
      const toasts: number = rig.toasts.length;
      actionHeld.release(json(42901, '{}'));
      await rig.pump(50);
      same('action gate written', rig.gates.action.active, true);
      same('reset state kept', (rig.turn(c, 0).feedback as AgentFeedbackView).selected, null);
      same('no toast', rig.toasts.length, toasts);
    });

    // ---------------------------------------------------------------- 共性 42（Android R2-04）
    it('fhm0720_42_resume_create_session_returning_in_background_sends_no_stream_keeps_turn_retryable', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      // 首次建会话断网。
      rig.fake.createCode = -1;
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(200);
      const err: AgentErrorView = errorOf(rig, c) as AgentErrorView;
      same('disconnected retry', err.retry === null ? null : (err.retry as AgentRetryTap).mode, AgentRetryMode.SAME);
      const firstId: string = (err.retry as AgentRetryTap).clientMsgId;
      // 用户点【重试】，第二次建会话挂起；此时 App 进入后台，再返回建会话成功。
      rig.fake.createCode = 0;
      const held: Held = new Held();
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.method === 'POST'
        && r.url.endsWith('/v1/agent/sessions') ? held.promise : null;
      c.retry(err.retry as AgentRetryTap);
      await rig.pump(50);
      rig.foreground = false;
      c.setForeground(false);
      held.release(json(0, '{"session_id":"' + SESSION + '"}'));
      await rig.pump(200);
      same('no stream in background', rig.rec.streams.length, 0);
      same('turn kept', c.snapshot().turns.length, 1);
      const after: AgentErrorView | null = errorOf(rig, c);
      same('retry kept', after === null ? null : after.retry === null ? null : (after.retry as AgentRetryTap).clientMsgId,
        firstId);
      same('not sending', c.snapshot().sending, false);
      // 回前台不自动续发。
      rig.foreground = true;
      c.setForeground(true);
      await rig.pump(500);
      same('no auto resend', rig.rec.streams.length, 0);
      // 用户再点【重试】：会话已在 → 先查历史（对不上）再同键重发。
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.method === 'GET'
        && r.url.indexOf('/messages') >= 0 ? Promise.resolve(json(0, pageWith('', '', null, false))) : null;
      c.retry((errorOf(rig, c) as AgentErrorView).retry as AgentRetryTap);
      await rig.pump(300);
      same('resent once', rig.rec.streams.length, 1);
      same('same client_msg_id', rig.rec.streams[0].clientMsgId, firstId);
    });

    it('fhm0720_42_resumed_resend_blocked_at_admission_keeps_turn_with_retry', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      rig.rec.lastManual.headers();
      rig.rec.lastManual.text(META + delta(2, '部分'));
      rig.rec.lastManual.end();
      await rig.pump(100);
      const firstId: string | null = rig.rec.streams[0].clientMsgId;
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.method === 'GET'
        && r.url.indexOf('/messages') >= 0 ? Promise.resolve(json(0, pageWith('', '', null, false))) : null;
      // 同键重发已受理（resend 发布了「连接中」快照）、实际写出之前进入后台：本地没发出，但不删原轮次。
      let flip: boolean = true;
      c.onChange = (snap: AgentSnapshot): void => {
        rig.snapshots.push(snap);
        if (flip && snap.sending) {
          flip = false;
          rig.foreground = false;
        }
      };
      c.retry((errorOf(rig, c) as AgentErrorView).retry as AgentRetryTap);
      await rig.pump(300);
      same('flipped during resend', flip, false);
      same('turn kept', c.snapshot().turns.length, 1);
      same('partial kept', rig.state(c).text, '部分');
      same('not written', rig.rec.streams.length, 1);
      const err: AgentErrorView | null = errorOf(rig, c);
      same('retry kept', err === null || err.retry === null ? null : (err.retry as AgentRetryTap).clientMsgId, firstId);
    });

    it('fhm0720_42_resume_create_session_admission_in_background_not_sent_keeps_turn_retryable', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      rig.fake.createCode = -1;
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(200);
      const err: AgentErrorView = errorOf(rig, c) as AgentErrorView;
      const firstId: string = (err.retry as AgentRetryTap).clientMsgId;
      rig.fake.createCode = 0;
      const creates: number = rig.rec.wire.filter((x: Wire): boolean => x.method === 'POST'
        && x.path === '/v1/agent/sessions').length;
      // 【重试】已受理、建会话实际写出之前进入后台：建会话不写出，原轮次保留为可手动重试。
      let flip: boolean = true;
      c.onChange = (snap: AgentSnapshot): void => {
        rig.snapshots.push(snap);
        if (flip && snap.sending) {
          flip = false;
          rig.foreground = false;
        }
      };
      c.retry(err.retry as AgentRetryTap);
      await rig.pump(300);
      same('flipped during resend', flip, false);
      same('create not written', rig.rec.wire.filter((x: Wire): boolean => x.method === 'POST'
        && x.path === '/v1/agent/sessions').length, creates);
      same('no stream', rig.rec.streams.length, 0);
      same('turn kept', c.snapshot().turns.length, 1);
      const after: AgentErrorView | null = errorOf(rig, c);
      same('retry kept', after === null || after.retry === null ? null : (after.retry as AgentRetryTap).clientMsgId, firstId);
    });

    // ---------------------------------------------------------------- 共性 43（Android R2-05）
    it('fhm0720_43_new_turn_while_old_turn_reloads_keeps_old_turn_disconnected_with_retry_no_auto_resend', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '旧问题');
      await rig.pump(50);
      rig.rec.lastManual.headers();
      rig.rec.lastManual.text(': ping\n\n');
      rig.rec.lastManual.end();
      await rig.pump(100);
      const held: Held = new Held();
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.method === 'GET'
        && r.url.indexOf('/messages') >= 0 ? held.promise : null;
      c.retry((errorOf(rig, c, 0) as AgentErrorView).retry as AgentRetryTap);
      await rig.pump(50);
      // 旧轮查历史期间发送新轮 B。
      const m: ManualSink = await newStream(rig, c, '新问题', '新');
      held.release(json(0, pageWith('', '', null, false)));
      await rig.pump(100);
      const a: AgentTurnView = rig.turn(c, 0);
      same('old turn disconnected', a.status, 'disconnected');
      same('old turn not streaming', a.streaming, false);
      same('old turn retry', a.error === null ? null : a.error.retry === null ? null : 'retry', 'retry');
      same('B still streaming', c.snapshot().sending, true);
      m.text(done(3, 9));
      await rig.pump(200);
      same('no auto resend after B', rig.rec.streams.length, 2);
      same('old turn still retryable', rig.turn(c, 0).error === null ? null : 'retry', 'retry');
    });

    // ---------------------------------------------------------------- 共性 44（Android R2-06）
    it('fhm0720_44_card_only_reply_has_report_entry_and_feedback', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '提现进度');
      await rig.pump(50);
      rig.rec.lastManual.headers();
      rig.rec.lastManual.text(META + guideCard(2, 'c1') + done(3, 9));
      await rig.pump(100);
      const v: AgentTurnView = rig.turn(c);
      same('no text', v.blocks.length, 0);
      same('one card', v.cards.length, 1);
      same('report entry', v.report === null ? null : (v.report as AgentReportEntryView).reported, false);
      same('feedback', v.feedback === null ? null : 'shown', 'shown');
      c.reportOpen((v.report as AgentReportEntryView).ticket);
      same('sheet opens', c.snapshot().reportSheet === null, false);
    });

    // ---------------------------------------------------------------- 共性 45（Android R3-01 S0）
    it('fhm0720_45_same_owner_rebuild_old_results_settle_ai_10004_lapse_once_halt_new_stream', 0, async () => {
      for (const op of ['current', 'history', 'create', 'feedback', 'report']) {
        const rig: TRig = new TRig();
        ownerGates(rig);
        const w: Lapse = new Lapse(rig);
        rig.rec.manual = true;
        rig.fake.currentSessionId = SESSION;
        const port: HoldPort = new HoldPort(rig.port, rig.port);
        let armed: boolean = true;
        const path: string = op === 'current' ? '/sessions/current' : op === 'history' ? '/messages'
          : op === 'create' ? '/v1/agent/sessions' : '/' + op;
        rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => {
          const hit: boolean = op === 'create' ? r.method === 'POST' && r.url.endsWith(path)
            : op === 'history' ? r.method === 'GET' && r.url.indexOf(path) >= 0 : r.url.indexOf(path) >= 0;
          if (armed && hit) {
            armed = false;
            return Promise.resolve(json(10004, AI));
          }
          return null;
        };
        if (op === 'create') {
          rig.fake.currentSessionId = null;
        }
        let c: AgentController;
        if (op === 'current' || op === 'history') {
          port.holdOp = op;
          c = heldController(rig, port);
          w.current = c;
          c.start();
          await rig.pump(100);
        } else {
          armed = false;
          c = heldController(rig, port);
          w.current = c;
          c.start();
          await rig.pump(100);
          if (op === 'create') {
            armed = true;
            port.holdOp = 'create';
            c.send(c.snapshot().page, '纯牛奶');
            await rig.pump(100);
          } else {
            // 已有一条带可信回复 id 的回复。
            c.send(c.snapshot().page, '纯牛奶');
            await rig.pump(50);
            rig.rec.lastManual.headers();
            rig.rec.lastManual.text(META + delta(2, '正文') + done(3, 9));
            await rig.pump(100);
            armed = true;
            port.holdOp = op;
            if (op === 'feedback') {
              c.feedback((rig.turn(c, 0).feedback as AgentFeedbackView).ticket, 'up');
            } else {
              const entry: AgentReportEntryView = rig.turn(c, 0).report as AgentReportEntryView;
              c.reportOpen(entry.ticket);
              c.reportEdit(entry.ticket, '其他问题', '');
              c.reportSubmit(entry.ticket);
            }
            await rig.pump(100);
          }
        }
        same(op + ' old result arrived and held', port.resultArrived, true);
        same(op + ' not yet lapsed', w.reports, 0);
        // 旧页面以相同 ownerKey 销毁重建，重建页开新流。
        c.dispose();
        w.current = null;
        page(rig, 2);
        rig.fake.currentSessionId = SESSION;
        const rebuilt: AgentController = await rig.ready();
        w.current = rebuilt;
        const m: ManualSink = await newStream(rig, rebuilt, '新问题', '新');
        same(op + ' rebuilt streaming', rebuilt.snapshot().sending, true);
        const opens: number = rig.opens.length;
        const toasts: number = rig.toasts.length;
        port.release();
        await rig.pump(50);
        await assertRebuiltHalted(op, rig, w, rebuilt, m, opens, toasts);
      }
    });

    it('fhm0720_45_same_owner_rebuild_old_42901_opens_app_gate_other_owner_dropped', 0, async () => {
      for (const sameOwner of [true, false]) {
        const rig: TRig = new TRig();
        ownerGates(rig);
        const w: Lapse = new Lapse(rig);
        rig.rec.manual = true;
        rig.fake.currentSessionId = SESSION;
        const port: HoldPort = new HoldPort(rig.port, rig.port);
        let armed: boolean = true;
        rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => {
          if (armed && r.url.indexOf('/sessions/current') >= 0) {
            armed = false;
            return Promise.resolve(json(42901, '{}'));
          }
          return null;
        };
        port.holdOp = 'current';
        const c: AgentController = heldController(rig, port);
        w.current = c;
        c.start();
        await rig.pump(100);
        c.dispose();
        if (sameOwner) {
          page(rig, 2);
        } else {
          page(rig, 2, 'user-2', 's2');
          rig.gates.retain(rig.identity.ownerKey);
        }
        const rebuilt: AgentController = await rig.ready();
        w.current = rebuilt;
        const m: ManualSink = await newStream(rig, rebuilt, '新问题', '新');
        port.release();
        await rig.pump(50);
        same(String(sameOwner) + ' read gate', rig.gates.read.active, sameOwner);
        same(String(sameOwner) + ' new stream kept', rebuilt.snapshot().sending, true);
        same(String(sameOwner) + ' no lapse', w.reports, 0);
        same(String(sameOwner) + ' no toast', rig.toasts.length, 0);
        m.text(delta(3, '续') + done(4, 9));
        await rig.pump();
        same(String(sameOwner) + ' continues', rig.state(rebuilt).text, '新续');
      }
    });

    it('fhm0720_45_other_owner_old_ai_10004_after_rebuild_dropped_entirely', 0, async () => {
      const rig: TRig = new TRig();
      const w: Lapse = new Lapse(rig);
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const port: HoldPort = new HoldPort(rig.port, rig.port);
      let armed: boolean = true;
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => {
        if (armed && r.url.indexOf('/sessions/current') >= 0) {
          armed = false;
          return Promise.resolve(json(10004, AI));
        }
        return null;
      };
      port.holdOp = 'current';
      const c: AgentController = heldController(rig, port);
      w.current = c;
      c.start();
      await rig.pump(100);
      c.dispose();
      page(rig, 2, 'user-2', 's2');
      const b: AgentController = await rig.ready();
      w.current = b;
      const m: ManualSink = await newStream(rig, b, '乙的问题', '乙');
      port.release();
      await rig.pump(50);
      same('nothing reported', w.reports, 0);
      same('other stream kept', b.snapshot().sending, true);
      same('other consent clear', b.snapshot().consentGate, AgentConsentGate.CLEAR);
      m.text(delta(3, '续') + done(4, 9));
      await rig.pump();
      same('other continues', rig.state(b).text, '乙续');
    });

    // ---------------------------------------------------------------- 共性 46（Android R3-02；G25 向量接真实控制器）
    it('fhm0720_46_g25_cancel_30505_history_replaces_only_non_cancelled_on_real_controller_path', 0, async () => {
      const root: Record<string, Object> = JSON.parse(AGENT_TRANSPORT_VECTORS_JSON) as Record<string, Object>;
      let found: Record<string, Object> | null = null;
      // 只读 Codex 向量 cancel 组的这一条（向量文件与向量测试不改）。
      for (const v of ((root['cancel'] ?? []) as Object[])) {
        if ((v as Record<string, Object>)['name'] === 'G25_构造_30505历史只替换非cancelled的原轮') {
          found = v as Record<string, Object>;
        }
      }
      same('vector found', found === null, false);
      const axes: Object[] = ((found as Record<string, Object>)['axes'] as Object[])[0] as Object[];
      same('four axes', axes.length, 4);
      for (const a of axes) {
        const axis: Record<string, Object> = a as Record<string, Object>;
        const name: string = axis['name'] as string;
        const input: Record<string, Object> = axis['input'] as Record<string, Object>;
        const expect: Record<string, Object> = axis['expect'] as Record<string, Object>;
        const rig: TRig = new TRig();
        const c: AgentController = await streaming(rig, '提现记录在哪看', '本地正文');
        rig.rec.lastManual.text(guideCard(3, 'c1'));
        await rig.pump();
        const cancelHeld: Held = new Held();
        const rawFinish: Object | undefined = input['historyFinishReasonRaw'];
        const finish: string | null = typeof rawFinish === 'string' ? rawFinish as string : null;
        rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => {
          if (r.url.indexOf('/cancel') >= 0) {
            return cancelHeld.promise;
          }
          if (r.method === 'GET' && r.url.indexOf('/messages') >= 0) {
            return Promise.resolve(json(0, pageWith('提现记录在哪看', finish === 'cancelled' ? '' : '服务端正文', finish,
              input['historyMatched'] === true)));
          }
          return null;
        };
        c.stop(c.snapshot().stop as AgentRunTicket);
        await rig.pump(50);
        c.feedback((rig.turn(c, 0).feedback as AgentFeedbackView).ticket, 'up');
        await rig.pump(100);
        if (input['ticketMatches'] === false) {
          c.newChat(c.snapshot().page);
          await rig.pump(50);
        }
        const turnsBefore: number = c.snapshot().turns.length;
        cancelHeld.release(json(30505, '{}'));
        await rig.pump(300);
        if (input['ticketMatches'] === false) {
          same(name + ' conversation untouched', c.snapshot().turns.length, turnsBefore);
          same(name + ' expect no mutation', expect['conversationMutations'], 0);
          continue;
        }
        const replaced: boolean = rig.state(c, 0).text === '服务端正文';
        same(name + ' replaced', replaced, expect['replaced']);
        same(name + ' local status', rig.state(c, 0).status, expect['localStatusRaw']);
        if (expect['replaced'] === false) {
          same(name + ' local text kept', rig.state(c, 0).text, '本地正文');
          same(name + ' cards kept', rig.turn(c, 0).cards.length, 1);
          same(name + ' feedback kept', (rig.turn(c, 0).feedback as AgentFeedbackView).selected, 'up');
        }
      }
    });
    // ---------------------------------------------------------------- APP-05b 共性 19（iOS R1-01）
    it('fhm0720_19_purchase_pending_held_after_third_party_login_not_replayed_until_released', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.env.logged = false;
      f.controller.buy(f.env.card, null);
      f.opens()[0].fail(10001);
      await flush();
      same('pending registered', f.pending.peek() === null, false);
      // 第三方新号登录成功、待办暂缓（引导未结束）：购买页回到可见触发的自动恢复不读、不删、不重放。
      f.env.logged = true;
      f.pending.heldFlag = true;
      f.controller.resumeAfterLogin();
      await flush();
      same('no replay while held', f.opens().length, 1);
      same('pending kept while held', f.pending.peek() === null, false);
      f.controller.onBackground();
      f.controller.onForeground();
      await flush();
      same('no deferred replay while held', f.opens().length, 1);
      // 释放后 App 显式通知原页（AppTrade.loginHoldReleased → resumeAfterLogin）：同键重放一次。
      f.pending.heldFlag = false;
      f.controller.resumeAfterLogin();
      await flush();
      same('replayed once after release', f.opens().length, 2);
      same('same key', f.opens()[1].request.idempotencyKey, f.opens()[0].request.idempotencyKey);
      same('pending consumed', f.pending.peek(), null);
    });

    it('fhm0720_19_hold_release_notifies_listeners_once_only_when_held', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      f.newUser = true;
      f.openInApp('OrderList');
      let released: number = 0;
      f.service.onHoldReleased((): void => {
        released++;
      });
      const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, 1790661600000);
      await flush();
      const nonce: string = f.adapter.nonces[f.adapter.nonces.length - 1];
      f.adapter.resolve(FakeAuthAdapter.credential('code-new', nonce));
      await running;
      same('held after new-user login', f.service.pendingHeld(), true);
      same('not released yet', released, 0);
      f.service.resumeHeldPending();
      same('released once', released, 1);
      same('hold cleared', f.service.pendingHeld(), false);
      // 没有暂缓时的 endHold（如普通绑定完成）不再通知。
      f.service.endHold();
      same('no extra notify', released, 1);
    });

    // ---------------------------------------------------------------- APP-05b 共性 20（iOS R1-02）
    it('fhm0720_20_bind_success_get_me_advances_read_generation_and_feeds_me_snapshot', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const host: Host = new Host();
      const svc: BindPhoneService = bindService(f, host);
      const me: MeSession = new MeSession((): number => f.rig.nowMillis, (): string => 'scope-1');
      // 「我的」此前有一笔 getMe 在途（绑定前发出，世代 g0）。
      const g0: number = me.meGeneration;
      let loaded: number = 0;
      svc.meReadAdvance = (): number => me.advanceRead();
      svc.meLoaded = (account: string, data: Record<string, Object>, generation: number): void => {
        loaded++;
        me.offerMe(account, data, generation);
      };
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => netEnvelope(0, '{}'));
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      const out: BindOutcome | null = await form.submit(filled(form));
      await settle();
      same('done', out === null ? null : out.actionRaw, BindPhoneAction.DONE);
      same('fresh get me fed once', loaded, 1);
      const snap: Record<string, Object | null> | null = me.snapshotFor('user-1');
      same('shared snapshot phone_bound', snap === null ? null : snap['phone_bound'], true);
      // 绑定前在途的旧 getMe 迟到（phone_bound=false）：读取世代已推进，不再覆盖。
      const stale: Record<string, Object | null> = {};
      stale['user_id'] = 'user-1';
      stale['phone_bound'] = false;
      same('stale read rejected', me.offerMe('user-1', stale, g0), false);
      const after: Record<string, Object | null> | null = me.snapshotFor('user-1');
      same('still bound', after === null ? null : after['phone_bound'], true);
    });

    // ---------------------------------------------------------------- APP-05b 共性 22（iOS R1-04）
    it('fhm0720_22_bind_results_while_page_covered_drop_dialog_and_merge_ticket_done_deferred_until_shown', 0, async () => {
      for (const kind of ['merge', 'error', 'done']) {
        const f: AccountFixture = new AccountFixture();
        const host: Host = new Host();
        const svc: BindPhoneService = bindService(f, host);
        const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        const running: Promise<BindOutcome | null> = form.submit(filled(form));
        await settle();
        // 提交后打开协议页 / 客服（本页被盖住）。
        form.pageHidden();
        const reply: TransportResponse = kind === 'merge' ? netEnvelope(30411, '{"reason":"mergeable","merge_ticket":"mt-1"}')
          : kind === 'error' ? netEnvelope(20003, '{}') : netEnvelope(0, '{}');
        f.held[f.held.length - 1].resolve(reply);
        const out: BindOutcome | null = await running;
        await settle();
        same(kind + ' no page outcome while covered', out, null);
        if (kind === 'merge') {
          same('merge ticket not kept for later', svc.mergePending, false);
          same('no deferred done', form.pageShown(), false);
        } else if (kind === 'error') {
          same('error not deferred', form.pageShown(), false);
        } else {
          same('shared settlement done', host.bound, 1);
          same('done deferred to shown', form.pageShown(), true);
          same('only once', form.pageShown(), false);
        }
        // 回到可见后新发起的请求照常拿到结果。
        same(kind + ' permit valid again', form.permitted(form.permit()), true);
      }
    });

    // ---------------------------------------------------------------- 第 1 轮评审 R1-01（APP-05b 共性 25）
    it('fhm0720_r1_01_bind_done_after_page_shown_again_exits_once_now_not_waiting_for_next_shown', 0, async () => {
      // 页面先恢复、后收到绑定成功：旧做法 gated 因旧可见世代返回 null 并置延后标记，页面已可见、不会再有 onShown，停在表单。
      const f: AccountFixture = new AccountFixture();
      const host: Host = new Host();
      const svc: BindPhoneService = bindService(f, host);
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const running: Promise<BindOutcome | null> = form.submit(filled(form));
      await settle();
      form.pageHidden();
      same('nothing deferred yet', form.pageShown(), false);
      f.held[f.held.length - 1].resolve(netEnvelope(0, '{}'));
      const out: BindOutcome | null = await running;
      await settle();
      same('shared settlement done', host.bound, 1);
      same('page exits now (visible, own instance, same identity, bound)', out === null ? null : out.actionRaw,
        BindPhoneAction.DONE);
      form.pageHidden();
      same('no second exit on later shown', form.pageShown(), false);
    });

    it('fhm0720_r1_01_bind_done_both_orders_exit_once_and_left_never_exits', 0, async () => {
      // 成功先到（仍被盖住）→ 回到可见出栈一次；页面先恢复 → 立即出栈一次；离页后先恢复的顺序也不出栈。
      for (const order of ['done_first', 'shown_first', 'shown_then_left']) {
        const f: AccountFixture = new AccountFixture();
        const host: Host = new Host();
        const svc: BindPhoneService = bindService(f, host);
        const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        const running: Promise<BindOutcome | null> = form.submit(filled(form));
        await settle();
        form.pageHidden();
        if (order !== 'done_first') {
          form.pageShown();
        }
        if (order === 'shown_then_left') {
          form.leave();
        }
        f.held[f.held.length - 1].resolve(netEnvelope(0, '{}'));
        const out: BindOutcome | null = await running;
        await settle();
        same(order + ' shared settlement', host.bound, 1);
        const now: number = out !== null && out.actionRaw === BindPhoneAction.DONE ? 1 : 0;
        let later: number = form.pageShown() ? 1 : 0;
        later += form.pageShown() ? 1 : 0;
        // 成功先到：只在回到可见时出栈；页面先恢复：结果到达当时出栈（不留到下一次 onShown）；离页：都不出栈。
        same(order + ' exits at result', now, order === 'shown_first' ? 1 : 0);
        same(order + ' exits on shown', later, order === 'done_first' ? 1 : 0);
      }
    });

    // ---------------------------------------------------------------- 第 1 轮评审 R1-02（APP-05b 共性 26）
    it('fhm0720_r1_02_done_while_hidden_then_switch_account_not_consumed_by_new_identity', 0, async () => {
      for (const reset of [true, false]) {
        const f: AccountFixture = new AccountFixture();
        const host: Host = new Host();
        const binding: PhoneBindingState = new PhoneBindingState();
        // B 在共享状态里也是已绑：旧做法 reset 后「当前身份有效」即消费 A 的延后成功。
        binding.set('user-2', true);
        const svc: BindPhoneService = bindService(f, host, binding);
        const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        const running: Promise<BindOutcome | null> = form.submit(filled(form));
        await settle();
        form.pageHidden();
        f.held[f.held.length - 1].resolve(netEnvelope(0, '{}'));
        same('covered no outcome', await running, null);
        await settle();
        same('A settled', host.bound, 1);
        // 隐藏期间换成账号 B（B 已绑手机，共享状态里已绑也不能借 A 的成功出栈）。
        relogin(f, svc, 'user-2', 'b');
        if (reset) {
          form.reset(new TestFields());
          same('B identity bound in shared state', svc.boundShared(form.pageIdentity), true);
        }
        same('reset=' + String(reset) + ' B page not exited by A success', form.pageShown(), false);
      }
    });

    it('fhm0720_r1_02_done_while_hidden_then_same_account_relogin_or_leave_cleared', 0, async () => {
      for (const how of ['relogin_reset', 'relogin_no_reset', 'leave']) {
        const f: AccountFixture = new AccountFixture();
        const host: Host = new Host();
        const svc: BindPhoneService = bindService(f, host);
        const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        const running: Promise<BindOutcome | null> = form.submit(filled(form));
        await settle();
        form.pageHidden();
        f.held[f.held.length - 1].resolve(netEnvelope(0, '{}'));
        same(how + ' covered no outcome', await running, null);
        await settle();
        if (how === 'leave') {
          form.leave();
        } else {
          // 同账号重新登录：账号不变、登录世代变了，原固定身份失效。
          relogin(f, svc, 'user-1', 'again');
          if (how === 'relogin_reset') {
            form.reset(new TestFields());
          }
        }
        same(how + ' deferred done not consumed', form.pageShown(), false);
      }
    });

    // ---------------------------------------------------------------- 第 1 轮评审 R1-03（APP-05b 共性 27）
    it('fhm0720_r1_03_send_code_results_while_covered_not_delivered_but_deadlines_recorded', 0, async () => {
      for (const kind of ['risk', 'rate', 'sent']) {
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f, new Host());
        const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
        f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
        const b: BindPhoneFormBinding = form.binding();
        form.setPhone(b, NEW_PHONE);
        const running: Promise<SendCodeOutcome | null> = form.sendCode(form.binding());
        await settle();
        form.pageHidden();
        const h: Record<string, string> = {};
        h['Retry-After'] = '60';
        const reply: TransportResponse = kind === 'risk' ? netEnvelope(44001, '{}')
          : kind === 'rate' ? netEnvelope(42901, '{}', h) : netEnvelope(0, '{"resend_after_sec":60,"expires_in_sec":300}');
        f.held[f.held.length - 1].resolve(reply);
        same(kind + ' not delivered while covered', await running, null);
        await settle();
        if (kind === 'rate') {
          same('rate limit recorded', svc.sendState(NEW_PHONE).rateLimitedSec > 0, true);
        } else if (kind === 'sent') {
          same('countdown recorded', svc.sendState(NEW_PHONE).countdownSec > 0, true);
        }
        same(kind + ' fields untouched', form.binding().fields.phoneError, '');
      }
    });

    it('fhm0720_r1_03_send_code_late_after_return_dropped_fresh_send_delivered', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f, new Host());
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      form.setPhone(form.binding(), NEW_PHONE);
      const late: Promise<SendCodeOutcome | null> = form.sendCode(form.binding());
      await settle();
      // 盖住后又回来，旧发码才返回 44001：发起时的许可已失效，不弹风控框。
      form.pageHidden();
      form.pageShown();
      f.held[f.held.length - 1].resolve(netEnvelope(44001, '{}'));
      same('late result after return dropped', await late, null);
      await settle();
      // 对照：回到可见后新发起的发码照常交给页面。
      const fresh: Promise<SendCodeOutcome | null> = form.sendCode(form.binding());
      await settle();
      f.held[f.held.length - 1].resolve(netEnvelope(44001, '{}'));
      const out: SendCodeOutcome | null = await fresh;
      same('fresh result delivered', out !== null && out.stateRaw !== 'stale', true);
    });

    // ---------------------------------------------------------------- 第 2 轮评审 R2-01（先回可见、后成功 / 42901）
    it('fhm0720_r2_01_send_result_after_shown_again_starts_ticker_and_expiry_reenables_without_prompts', 0, async () => {
      for (const kind of ['sent', 'rate']) {
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f, new Host());
        const ticks: ManualTicks = new ManualTicks();
        const page: TimerPage = new TimerPage(svc, ticks);
        f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
        page.form.setPhone(page.form.binding(), NEW_PHONE);
        const running: Promise<void> = page.send();
        await settle();
        page.form.pageHidden();
        page.shown();
        same(kind + ' no ticker before result', page.ticker.running, false);
        const h: Record<string, string> = {};
        h['Retry-After'] = '60';
        f.held[f.held.length - 1].resolve(kind === 'rate' ? netEnvelope(42901, '{}', h)
          : netEnvelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
        await running;
        await settle();
        same(kind + ' result not delivered', page.delivered.length, 0);
        same(kind + ' recomputed once', page.hooks, 1);
        same(kind + ' ticker running', page.ticker.running, true);
        same(kind + ' one interval', ticks.active, 1);
        same(kind + ' send disabled while waiting', page.sendEnabled(), false);
        same(kind + ' no prompt on recompute', page.announced.length, 0);
        for (let i = 0; i < 61; i++) {
          f.rig.nowMillis += 1000;
          ticks.fire();
        }
        same(kind + ' ticker stopped at expiry', page.ticker.running, false);
        same(kind + ' interval cleared', ticks.active, 0);
        same(kind + ' send re-enabled', page.sendEnabled(), true);
        // 到期只有「可以重新获取验证码」照常播报一次（G14）；不补「已发送至」、不补 toast / 风控框 / 字段错误。
        same(kind + ' only resend-ready announced', page.announced.join(','), BindPhoneAnnouncer.RESEND_READY_KEY);
        same(kind + ' still nothing delivered', page.delivered.length, 0);
        same(kind + ' fields untouched', page.fields.phoneError + page.fields.codeError, '');
      }
    });

    it('fhm0720_r2_01_late_send_result_hidden_again_left_or_identity_changed_starts_no_ticker', 0, async () => {
      for (const how of ['hidden', 'left', 'switch', 'relogin']) {
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f, new Host());
        const ticks: ManualTicks = new ManualTicks();
        const page: TimerPage = new TimerPage(svc, ticks);
        f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
        page.form.setPhone(page.form.binding(), NEW_PHONE);
        const running: Promise<void> = page.send();
        await settle();
        page.form.pageHidden();
        page.shown();
        if (how === 'hidden') {
          page.form.pageHidden();
        } else if (how === 'left') {
          page.form.leave();
        } else {
          // 换账号 / 同账号重新登录：页面经 subscribeSession 按新身份重建表单（reset）。
          relogin(f, svc, how === 'switch' ? 'user-2' : 'user-1', how);
          page.form.reset(new TestFields());
        }
        f.held[f.held.length - 1].resolve(netEnvelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
        await running;
        await settle();
        same(how + ' not delivered', page.delivered.length, 0);
        same(how + ' no recompute', page.hooks, 0);
        same(how + ' no ticker', page.ticker.running, false);
        same(how + ' no interval', ticks.active, 0);
        same(how + ' no prompt', page.announced.length, 0);
        if (how === 'hidden') {
          // 对照：被盖住时到达的由回到可见那次 refresh 接上（R1-03 原口径）。
          page.shown();
          same('hidden then shown ticker running', page.ticker.running, true);
          same('hidden then shown no prompt', page.announced.length, 0);
        }
      }
    });

    // ---------------------------------------------------------------- 第 3 轮评审 R3-01（APP-05b 共性 22：待确认订阅也核页面许可）
    it('fhm0720_r3_01_bind_unknown_while_hidden_or_left_pending_subscription_no_update_no_announce_until_shown', 0, async () => {
      for (const how of ['visible', 'hidden', 'left', 'hidden_relogin']) {
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f, new Host());
        const page: PendingPage = new PendingPage(svc);
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        const running: Promise<BindOutcome | null> = page.form.submit(filled(page.form));
        await settle();
        const before: number = page.refreshes;
        if (how === 'hidden' || how === 'hidden_relogin') {
          page.form.pageHidden();
        } else if (how === 'left') {
          // onWillDisappear 已 leave、aboutToDisappear 还没退订。
          page.form.leave();
        }
        // 无统一外壳的网关超时：结果未知，服务在结果经 gated 之前就 notifyPending。
        f.held[f.held.length - 1].resolve(gateway());
        const out: BindOutcome | null = await running;
        await settle();
        same(how + ' shared pending recorded', svc.pendingView(svc.capturePage()) !== null, true);
        if (how === 'visible') {
          // 对照：可见时订阅照常刷新、播报一次；请求结果本身也交给页面（PENDING）。
          same('visible outcome pending', out === null ? null : out.actionRaw, BindOutcome.PENDING);
          same('visible card shown', page.pending !== null, true);
          same('visible announced once', page.announced.length, 1);
          continue;
        }
        same(how + ' no page outcome', out, null);
        same(how + ' subscription did not refresh page', page.refreshes, before);
        same(how + ' card not updated', page.pending, null);
        same(how + ' no announce', page.announced.length, 0);
        if (how === 'left') {
          page.dispose();
          continue;
        }
        if (how === 'hidden_relogin') {
          // 被盖住期间同账号重新登录：页面经 subscribeSession 换代，仍不读、不播报；回到可见按新身份读一次。
          relogin(f, svc, 'user-1', 'again');
          same('relogin while hidden no announce', page.announced.length, 0);
          same('relogin while hidden card empty', page.pending, null);
        }
        page.shown();
        same(how + ' card shown after back visible', page.pending !== null, true);
        same(how + ' announced once after shown', page.announced.length, 1);
        // 之后再来一次结算通知：同一条记录，不重复播报。
        page.form.pageHidden();
        page.shown();
        same(how + ' no duplicate announce', page.announced.length, 1);
      }
    });

    // ---------------------------------------------------------------- 合并前复核 RC-01（APP-05b 共性 31：成功收尾核完整归属）
    it('fhm0720_rc_01_get_me_held_scope_turns_deletion_only_same_generation_late_success_no_phone_bound', 0, async () => {
      for (const path of ['bind', 'confirm']) {
        for (const change of [true, false]) {
          const tag: string = path + (change ? ' scope changed' : ' control');
          const f: AccountFixture = new AccountFixture();
          const host: Host = new Host();
          const binding: PhoneBindingState = new PhoneBindingState();
          const svc: BindPhoneService = bindService(f, host, binding);
          const identity: BindPhoneIdentity = svc.capturePage();
          let running: Promise<BindOutcome>;
          if (path === 'bind') {
            f.reply('POST /v1/me/phone', (_r: TransportRequest) => netEnvelope(0, '{}'));
            f.reply('GET /v1/me', (_r: TransportRequest) => null);
            running = svc.bind(NEW_PHONE, '123456', identity);
          } else {
            f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
            same(tag + ' first unknown', (await svc.bind(NEW_PHONE, '123456', identity)).actionRaw, BindOutcome.PENDING);
            const p: AccountPendingView | null = svc.pendingView(identity);
            f.reply('POST /v1/me/phone', (_r: TransportRequest) => netEnvelope(0, '{}'));
            f.reply('GET /v1/me', (_r: TransportRequest) => null);
            running = svc.confirmPending(p === null ? '' : p.key, identity);
          }
          await settle();
          same(tag + ' get me in flight', f.held.length, 1);
          const generation: number = f.rig.client.sessionGenerationId();
          if (change) {
            // 同账号刷新：作用域 full → deletion_only，登录世代不变（不走 onSessionChanged）。
            f.rig.tokens.save(new SessionTokenSet('access-user-1-restricted', 'refresh-user-1', 'deletion_only', 'user-1'));
            same(tag + ' same generation', f.rig.client.sessionGenerationId(), generation);
            same(tag + ' identity lapsed', svc.identityValid(identity), false);
          }
          f.held[0].resolve(netEnvelope(0, '{"user_id":"user-1","phone_bound":true}'));
          const out: BindOutcome = await running;
          await settle();
          // 共享结算照常：这个账号已记为绑了手机。
          same(tag + ' shared bound recorded', binding.get('user-1'), true);
          same(tag + ' phoneBound calls', host.bound, change ? 0 : 1);
          same(tag + ' outcome', out.actionRaw, change ? BindOutcome.STALE : BindPhoneAction.DONE);
        }
      }
    });

    // ---------------------------------------------------------------- APP-05b 共性 24（iOS R1-06）
    it('fhm0720_24_staging_wechat_gate_follows_environment_not_fake_server_switch', 0, () => {
      let env: AppEnvironment | undefined = AppEnvironment.TEST;
      const auth: GatedAuthAdapter = new GatedAuthAdapter(new AlwaysAuth(),
        DebugSubstitutes.environmentGate((): AppEnvironment | undefined => env));
      same('shown in test without fake server', auth.adapterAvailable(), true);
      // 对照：原闸门在假服务没开时不放行（按钮不显示）。
      same('old gate hidden', DebugSubstitutes.gate((): boolean => false, (): AppEnvironment | undefined => env)(), false);
      env = AppEnvironment.PROD;
      same('prod hidden', auth.adapterAvailable(), false);
      env = undefined;
      same('unsettled hidden', auth.adapterAvailable(), false);
    });

    // ---------------------------------------------------------------- APP-12 共性 39（iOS APP-12 R3）
    it('fhm0720_39_clear_cache_success_is_no_io_error_not_empty_directory', 0, () => {
      const fs: MemFs = new MemFs();
      fs.files.add('cache/web1');
      fs.files.add('cache/img1');
      fs.recreate = 'cache/web2';
      same('rebuilt file after delete still success', CacheClear.run(fs, 'cache'), true);
      same('rebuilt file left', fs.files.has('cache/web2'), true);
      const gone: MemFs = new MemFs();
      gone.files.add('cache/a');
      gone.vanish = 'cache/a';
      same('vanished item counts as cleared', CacheClear.run(gone, 'cache'), true);
      const locked: MemFs = new MemFs();
      locked.files.add('cache/a');
      locked.failRemove = 'cache/a';
      same('remove failure is failure', CacheClear.run(locked, 'cache'), false);
      const unlisted: MemFs = new MemFs();
      unlisted.failList = true;
      same('list failure is failure', CacheClear.run(unlisted, 'cache'), false);
      const none: MemFs = new MemFs();
      none.dirExists = false;
      same('no dir counts as cleared', CacheClear.run(none, 'cache'), true);
    });
  });
}

