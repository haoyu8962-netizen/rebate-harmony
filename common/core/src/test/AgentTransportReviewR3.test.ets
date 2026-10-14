// APP-10b 鸿蒙第 3 轮评审窄修（NATIVE/APP-10b/harmony-review-r3.md R3-01..R3-03）的回归用例：沿用 AgentTransportIntegration 的接线
// （真实 ApiClient + 真实端口 ApiAgentContractPort + AgentController + 抓包传输替身 Recorder / 手工喂字节 ManualSink）。
// AppAgent 的应用级接线（entry 层没有单测源码集）按同一写法组装 Core 的 AgentConsentLapse、AgentGates.retain、AgentOwnershipStop。
// 数据只用构造值与锁定 fixture 的形状，不连任何地址。
import { describe, it } from '@ohos/hypium';
import {
  AgentConsentGate, AgentConsentLapse, AgentController, AgentErrorView, AgentGates, AgentHttpResult, AgentIdentity,
  AgentOwnershipHandlers, AgentOwnershipStop, AgentPhase, AgentRetryTap, AgentRunTicket, TransportRequest, TransportResponse
} from '../../Index';
import { delta, done, ManualSink, META, same, SESSION, TRig, Wire } from './AgentTransportIntegration.test';

const TRACE: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';
const AI: string = '{"consent_type":"ai_third_party"}';
const REPLY2: string = '019a0000-0000-7000-8000-000000000222';

function json(code: number, data: string): TransportResponse {
  const h: Record<string, string> = {};
  h['content-type'] = 'application/json';
  if (code === 42901) {
    h['retry-after'] = '12';
  }
  return TransportResponse.ok(code === 0 ? 200 : code === 42901 ? 429 : 400, h,
    '{"code":' + String(code) + ',"msg":"","data":' + data + ',"trace_id":"' + TRACE + '"}');
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

/** AppAgent 的应用级「AI 同意失效」接线：准入（端口出口 + 控制器）、重建初始状态、所有来源 AI 10004 的入口都按此刻归属键（不含页面实例）。 */
class LapseWiring {
  readonly lapse: AgentConsentLapse = new AgentConsentLapse();
  current: AgentController | null = null;
  private readonly rig: TRig;

  constructor(rig: TRig) {
    this.rig = rig;
    rig.allowed = (): boolean => this.allowed();
    rig.port.gate = (): boolean => this.allowed();
    rig.consentLapsed = (): boolean => this.lapse.blocks(rig.identity.ownerKey);
    rig.aiConsentLost = (ownerKey: string): void => {
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

/** 当前会话 + 一条进行中的回复（已收到 meta 与第一段文字）。 */
async function streaming(rig: TRig, first: string): Promise<AgentController> {
  rig.rec.manual = true;
  rig.fake.currentSessionId = SESSION;
  const c: AgentController = await rig.ready();
  c.send(c.snapshot().page, '纯牛奶');
  await rig.pump(50);
  rig.rec.lastManual.headers();
  rig.rec.lastManual.text(META + delta(2, first));
  await rig.pump();
  return c;
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

async function disconnectedBeforeMeta(rig: TRig, c: AgentController, text: string): Promise<AgentRetryTap> {
  c.send(c.snapshot().page, text);
  await rig.pump(50);
  const m: ManualSink = rig.rec.lastManual;
  m.headers();
  m.text(': ping\n\n');
  m.end();
  await rig.pump();
  return (rig.turn(c).error as AgentErrorView).retry as AgentRetryTap;
}

function item(id: string, role: string, at: string, text: string, finish: string | null): string {
  return '{"message_id":"' + id + '","role":"' + role + '","created_at":"' + at + '","text":' + JSON.stringify(text)
    + ',"cards":[],"finish_reason":' + (finish === null ? 'null' : '"' + finish + '"') + '}';
}

export default function agentTransportReviewR3Test(): void {
  describe('AgentTransportReviewR3', () => {
    // ---------------------------------------------------------------- R3-01（S0）所有来源的 AI 10004 汇入应用级失效
    it('r3_01a_stop_cancel_ai_10004_after_same_owner_page_rebuild_halts_new_stream_and_lapses', 0, async () => {
      const rig: TRig = new TRig();
      const w: LapseWiring = new LapseWiring(rig);
      const c: AgentController = await streaming(rig, '旧');
      w.current = c;
      const held: Held = new Held();
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('/cancel') >= 0
        ? held.promise : null;
      c.stop(c.snapshot().stop as AgentRunTicket);
      await rig.pump(50);
      same('one cancel', rig.rec.count('/cancel'), 1);
      // 同身份销毁并重建页面（AppAgent.pageDisappear → invalidate；pageAppear → 新页面实例），开始新流。
      c.dispose();
      w.current = null;
      page(rig, 2);
      const rebuilt: AgentController = await rig.ready();
      w.current = rebuilt;
      const m: ManualSink = await newStream(rig, rebuilt, '新问题', '新');
      same('new stream', rebuilt.snapshot().sending, true);
      const toasts: number = rig.toasts.length;
      held.release(json(10004, AI));
      await rig.pump(50);
      same('consentLapse', w.lapsed, true);
      same('requestsAllowed', w.allowed(), false);
      same('new stream halted', rebuilt.snapshot().sending, false);
      same('consent locked', rebuilt.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('no dialog', rebuilt.snapshot().consent, null);
      same('no navigation', rig.opens.length, 0);
      same('no toast', rig.toasts.length, toasts);
      m.text(delta(3, '后') + done(4, 7));
      await rig.pump();
      same('no late delta', rig.state(rebuilt).text, '新');
      same('quota untouched', rebuilt.snapshot().quotaLeft, null);
      const wire: number = rig.rec.wire.length;
      same('send refused', rebuilt.send(rebuilt.snapshot().page, '再问'), false);
      await rig.pump(200);
      same('no request', rig.rec.wire.length, wire);
    });

    it('r3_01b_send_ai_10004_then_rebuild_without_reconsent_zero_current_history_and_cannot_send', 0, async () => {
      const rig: TRig = new TRig();
      const w: LapseWiring = new LapseWiring(rig);
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      w.current = c;
      rig.fake.consentGranted = false;
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(300);
      same('consentLapse', w.lapsed, true);
      same('requestsAllowed', w.allowed(), false);
      // 未重新同意即销毁重建页面。
      c.dispose();
      w.current = null;
      page(rig, 2);
      const wire: number = rig.rec.wire.length;
      const current: number = rig.rec.count('/sessions/current');
      const history: number = rig.rec.wire.filter((x: Wire): boolean => x.method === 'GET' && x.path.indexOf('/messages') >= 0)
        .length;
      const again: AgentController = rig.controller();
      w.current = again;
      again.start();
      await rig.pump(300);
      same('0 current', rig.rec.count('/sessions/current'), current);
      same('0 history', rig.rec.wire.filter((x: Wire): boolean => x.method === 'GET' && x.path.indexOf('/messages') >= 0)
        .length, history);
      same('no request at all', rig.rec.wire.length, wire);
      same('re-consent entry', again.currentPhase, AgentPhase.CONSENT_DECLINED);
      same('cannot send', again.send(again.snapshot().page, '再问'), false);
      await rig.pump(300);
      same('still no request', rig.rec.wire.length, wire);
    });

    it('r3_01c_other_owner_late_stop_cancel_ai_10004_dropped_entirely', 0, async () => {
      const rig: TRig = new TRig();
      const w: LapseWiring = new LapseWiring(rig);
      const a: AgentController = await streaming(rig, '甲');
      w.current = a;
      const held: Held = new Held();
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('/cancel') >= 0
        ? held.promise : null;
      a.stop(a.snapshot().stop as AgentRunTicket);
      await rig.pump(50);
      a.dispose();
      page(rig, 2, 'user-2', 's2');
      const b: AgentController = await rig.ready();
      w.current = b;
      const m: ManualSink = await newStream(rig, b, '乙的问题', '乙');
      held.release(json(10004, AI));
      await rig.pump(50);
      same('nothing recorded', w.lapsed, false);
      same('old owner not recorded', w.lapse.blocks(new AgentIdentity('test', AgentIdentity.MEMBER, 'user-1', 's1', 0, 1)
        .ownerKey), false);
      same('allowed', w.allowed(), true);
      same('other stream kept', b.snapshot().sending, true);
      same('other consent clear', b.snapshot().consentGate, AgentConsentGate.CLEAR);
      m.text(delta(3, '续') + done(4, 9));
      await rig.pump();
      same('other continues', rig.state(b).text, '乙续');
    });

    // ---------------------------------------------------------------- R3-02 历史匹配排除已属于其他本地轮次的回复
    it('r3_02_retry_old_turn_does_not_take_newer_same_text_turn_reply', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      const retry: AgentRetryTap = await disconnectedBeforeMeta(rig, c, '相同问题');
      // 第二轮同文本成功并持有回复 id。
      c.send(c.snapshot().page, '相同问题');
      await rig.pump(50);
      const m: ManualSink = rig.rec.lastManual;
      m.headers();
      m.text(META + delta(2, '第二轮回复') + done(3, 20));
      await rig.pump();
      same('second owns reply id', rig.state(c, 1).messageId, REPLY2);
      const firstId: string | null = rig.rec.streams[0].clientMsgId;
      // 历史页只有第二轮的合法 user / assistant。
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('/messages') >= 0
        && r.method === 'GET' ? Promise.resolve(json(0, '{"items":[' + item('019a0000-0000-7000-8000-000000000331', 'user',
        '2026-10-14T10:00:01+08:00', '相同问题', null) + ',' + item(REPLY2, 'assistant', '2026-10-14T10:00:03+08:00',
        '第二轮回复', 'stop') + '],"next_cursor":null,"expired":false}')) : null;
      const streams: number = rig.rec.streams.length;
      c.retry(retry);
      await rig.pump(300);
      same('turns kept', c.snapshot().turns.length, 2);
      same('first not given second reply id', rig.state(c, 0).messageId === REPLY2, false);
      same('first not given second text', rig.state(c, 0).text === '第二轮回复', false);
      same('second unchanged', rig.state(c, 1).messageId, REPLY2);
      same('unmatched resends', rig.rec.streams.length, streams + 1);
      same('same client_msg_id', rig.rec.streams[rig.rec.streams.length - 1].clientMsgId, firstId);
    });

    // ---------------------------------------------------------------- R3-03 Retry-After 闸门按不含页面实例的归属保存
    it('r3_03_retry_after_survives_same_owner_page_rebuild_cleared_on_owner_change', 0, async () => {
      const rig: TRig = new TRig();
      // AppAgent 的接线：闸门按归属键（不含页面实例）判定，invalidate 时 retain。
      rig.gates = AgentGates.create((): number => rig.timer.now, (): string => rig.identity.ownerKey, false);
      rig.gates.retain(rig.identity.ownerKey);
      rig.fake.currentSessionId = SESSION;
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null =>
        r.url.indexOf('/sessions/current') >= 0 ? Promise.resolve(json(42901, '{}')) : null;
      const c: AgentController = await rig.ready();
      same('one current', rig.rec.count('/sessions/current'), 1);
      const first: number = rig.gates.read.remainingMs;
      same('remaining ~12000', first > 11000 && first <= 12000, true);
      // 同 ownerKey 销毁重建。
      c.dispose();
      same('kept on same owner', rig.gates.retain(rig.identity.ownerKey), false);
      page(rig, 2);
      const again: AgentController = await rig.ready();
      const left: number = rig.gates.read.remainingMs;
      same('remaining kept', left > 11000 && left <= first, true);
      same('second current not sent', rig.rec.count('/sessions/current'), 1);
      again.dispose();
      // 归属真正改变：清理（换回原归属也不复活）。
      page(rig, 3, 'user-2', 's2');
      same('cleared on owner change', rig.gates.retain(rig.identity.ownerKey), true);
      same('new owner free', rig.gates.read.remainingMs, 0);
      page(rig, 4);
      rig.gates.retain(rig.identity.ownerKey);
      same('no revival', rig.gates.read.remainingMs, 0);
      // 迟到 42901（应用级 cancel）交原归属键，App 先核对再写。
      const g: AgentGates = rig.gates;
      const owners: string[] = [];
      const handlers: AgentOwnershipHandlers = new AgentOwnershipHandlers();
      handlers.rateLimited = (ownerKey: string, ms: number): void => {
        owners.push(ownerKey);
        if (ownerKey === rig.identity.ownerKey) {
          g.action.start(ms);
        }
      };
      const coordinator: AgentOwnershipStop = new AgentOwnershipStop(rig.ledger, handlers);
      const r42901: AgentHttpResult = new AgentHttpResult(false, 429, 42901, '', {}, TRACE, '12');
      const old: AgentIdentity = new AgentIdentity('test', AgentIdentity.MEMBER, 'user-2', 's2', 0, 3);
      page(rig, 5);
      coordinator.settle(r42901, old.key, old.ownerKey);
      same('handler gets owner key', owners[0], old.ownerKey);
      same('other owner not written', g.action.active, false);
      const now: AgentIdentity = rig.identity;
      page(rig, 6);
      coordinator.settle(r42901, now.key, now.ownerKey);
      same('same owner written across page instances', g.action.active, true);
    });
  });
}
