// APP-10b 鸿蒙第 2 轮评审修复（NATIVE/APP-10b/harmony-review-r2.md R2-01..R2-06）的回归用例：沿用 AgentTransportIntegration 的接线
// （真实 ApiClient + 真实端口 ApiAgentContractPort + AgentController + Router + 抓包传输替身 Recorder / 手工喂字节 ManualSink）。
// R2-02 的应用级接线（AppAgent）在 entry 层没有单测源码集：这里按 AppAgent 的同一接线组装 Core 的 AgentConsentLapse + AgentOwnershipStop。
// 数据只用构造值与锁定 fixture 的形状，不连任何地址。
import { describe, it } from '@ohos/hypium';
import {
  AgentConsentGate, AgentConsentLapse, AgentConsentTicket, AgentController, AgentErrorView, AgentFeedbackView, AgentIdentity,
  AgentOwnershipEvent, AgentOwnershipHandlers, AgentOwnershipStop, AgentPhase, AgentRetryMode, AgentRetryTap, AgentRunTicket,
  AgentSnapshot, TransportRequest, TransportResponse
} from '../../Index';
import { AgentFakeHistoryScenario } from '../staging/ets/agent/AgentFakeTransport';
import { flush } from './NetworkTestRig';
import { delta, done, ManualSink, META, OpenRecord, same, SESSION, TRig, Wire } from './AgentTransportIntegration.test';

const TRACE: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';
const AI: string = '{"consent_type":"ai_third_party"}';

function json(code: number, data: string): TransportResponse {
  const h: Record<string, string> = {};
  h['content-type'] = 'application/json';
  if (code === 42901) {
    h['retry-after'] = '12';
  }
  return TransportResponse.ok(code === 0 ? 200 : code === 42901 ? 429 : code >= 50000 ? 503 : 400, h,
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

/** 再发一条新消息并让它进入流式（meta + 第一段）。 */
async function newStream(rig: TRig, c: AgentController, text: string, first: string): Promise<ManualSink> {
  c.send(c.snapshot().page, text);
  await rig.pump(50);
  const m: ManualSink = rig.rec.lastManual;
  m.headers();
  m.text(META + delta(2, first));
  await rig.pump();
  return m;
}

function creates(rig: TRig): number {
  return rig.rec.wire.filter((w: Wire): boolean => w.method === 'POST' && w.path === '/v1/agent/sessions').length;
}

export default function agentTransportReviewR2Test(): void {
  describe('AgentTransportReviewR2', () => {
    // ---------------------------------------------------------------- R2-01（S0，G60 裁定）停止的 cancel 迟到返回 AI 10004
    it('r2_01_stop_cancel_ai_10004_same_identity_halts_new_stream_other_identity_dropped', 0, async () => {
      const rig: TRig = new TRig();
      const c: AgentController = await streaming(rig, '旧');
      const held: Held = new Held();
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('/cancel') >= 0
        ? held.promise : null;
      c.stop(c.snapshot().stop as AgentRunTicket);
      await rig.pump(50);
      same('one cancel', rig.rec.count('/cancel'), 1);
      const m: ManualSink = await newStream(rig, c, '新问题', '新');
      same('new run streaming', c.snapshot().sending, true);
      const toasts: number = rig.toasts.length;
      held.release(json(10004, AI));
      await rig.pump(50);
      // 同一身份：统一同步作废——新回复立即停下；不弹框、不导航、不提示。
      same('new stream halted', c.snapshot().sending, false);
      same('consent locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('no dialog', c.snapshot().consent, null);
      same('no navigation', rig.opens.length, 0);
      same('no toast', rig.toasts.length, toasts);
      // 旧连接上之后到达的 delta / done：0 帧交付、额度不更新。
      m.text(delta(3, '后') + done(4, 7));
      await rig.pump();
      same('no late delta', rig.state(c).text, '新');
      same('quota untouched', c.snapshot().quotaLeft, null);
      same('send refused', c.send(c.snapshot().page, '再问'), false);

      // 不同身份：cancel 结果整体丢弃（不锁新身份的同意、不写新身份的动作闸门、不碰新身份的流）。
      for (const code of [10004, 42901]) {
        const r2: TRig = new TRig();
        const a: AgentController = await streaming(r2, '甲');
        const h2: Held = new Held();
        r2.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('/cancel') >= 0
          ? h2.promise : null;
        a.stop(a.snapshot().stop as AgentRunTicket);
        await r2.pump(50);
        r2.identity = new AgentIdentity('test', AgentIdentity.MEMBER, 'user-2', 's2', 0, 1);
        const b: AgentController = await r2.ready();
        const mb: ManualSink = await newStream(r2, b, '乙的问题', '乙');
        h2.release(json(code, code === 10004 ? AI : '{}'));
        await r2.pump(50);
        same(code + ' other identity stream kept', b.snapshot().sending, true);
        same(code + ' other identity consent clear', b.snapshot().consentGate, AgentConsentGate.CLEAR);
        same(code + ' other identity action gate untouched', r2.gates.action.active, false);
        mb.text(delta(3, '续') + done(4, 9));
        await r2.pump();
        same(code + ' other identity continues', r2.state(b).text, '乙续');
      }
    });

    // ---------------------------------------------------------------- R2-02（S0）应用级 cancel 的 AI 10004 → 应用级「AI 同意失效」
    it('r2_02_app_cancel_ai_10004_lapses_owner_halts_rebuilt_controller_blocks_until_reconsent', 0, async () => {
      const rig: TRig = new TRig();
      const lapse: AgentConsentLapse = new AgentConsentLapse();
      // AppAgent 的同一接线：准入（端口出口 + 控制器）与重建时的初始状态都看此刻归属有没有失效。
      rig.allowed = (): boolean => !lapse.blocks(rig.identity.ownerKey);
      rig.port.gate = (): boolean => !lapse.blocks(rig.identity.ownerKey);
      rig.consentLapsed = (): boolean => lapse.blocks(rig.identity.ownerKey);
      let current: AgentController | null = null;
      const handlers: AgentOwnershipHandlers = new AgentOwnershipHandlers();
      handlers.aiConsentLost = (ownerKey: string): void => {
        lapse.lapse(ownerKey, rig.identity.ownerKey, current);
      };
      const coordinator: AgentOwnershipStop = new AgentOwnershipStop(rig.ledger, handlers);
      const c: AgentController = await streaming(rig, '甲');
      const held: Held = new Held();
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('/cancel') >= 0
        ? held.promise : null;
      // 确认撤回 AI 同意：同步停流并以原身份发 cancel；recordConsent(false) 50001 → 流程解锁（身份没变）→ 回到 Agent 页重建。
      coordinator.dispatch(coordinator.before(AgentOwnershipEvent.AI_CONSENT_WITHDRAWN, c), rig.port);
      await rig.pump(50);
      same('cancel sent', rig.rec.count('/cancel'), 1);
      const rebuilt: AgentController = await rig.ready();
      current = rebuilt;
      const m: ManualSink = await newStream(rig, rebuilt, '新问题', '新');
      same('rebuilt streaming', rebuilt.snapshot().sending, true);
      held.release(json(10004, AI));
      await rig.pump(50);
      same('lapse recorded', lapse.blocks(rig.identity.ownerKey), true);
      same('rebuilt halted', rebuilt.snapshot().sending, false);
      same('rebuilt locked', rebuilt.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('no dialog', rebuilt.snapshot().consent, null);
      same('no navigation', rig.opens.length, 0);
      m.text(delta(3, '后') + done(4, 7));
      await rig.pump();
      same('no late delta', rig.state(rebuilt).text, '新');
      same('quota untouched', rebuilt.snapshot().quotaLeft, null);
      const wire: number = rig.rec.wire.length;
      same('send refused', rebuilt.send(rebuilt.snapshot().page, '再问'), false);
      // 再次重建（页面实例新建，归属不变）：一开始就是「需要重新同意」，不取会话、不拉历史。
      rig.identity = new AgentIdentity('test', AgentIdentity.MEMBER, 'user-1', 's1', 0, 2);
      const again: AgentController = rig.controller();
      current = again;
      again.start();
      await rig.pump(200);
      same('no requests after rebuild', rig.rec.wire.length, wire);
      same('re-consent entry', again.currentPhase, AgentPhase.CONSENT_DECLINED);
      same('rebuild locked', again.snapshot().consentGate, AgentConsentGate.REFUSED);
      // 重新同意记录成功（AppAgent.recordConsent 成功时 agreed）才解除。
      again.consentReopen(again.snapshot().page);
      const t: AgentConsentTicket = again.snapshot().consent as AgentConsentTicket;
      same('still blocked before agree', lapse.blocks(rig.identity.ownerKey), true);
      await again.consentAgree(t);
      lapse.agreed(rig.identity.ownerKey);
      same('unlocked', again.snapshot().consentGate, AgentConsentGate.CLEAR);
      const streams: number = rig.rec.streams.length;
      rig.rec.manual = false;
      again.send(again.snapshot().page, '同意后再问');
      await rig.pump(3000, 25);
      same('sends after re-consent', rig.rec.streams.length, streams + 1);
      // 不同身份的结果整体丢弃：不记、不碰。
      const other: AgentConsentLapse = new AgentConsentLapse();
      same('other identity dropped', other.lapse('old-owner', rig.identity.ownerKey, again), false);
      same('nothing recorded', other.blocks(rig.identity.ownerKey) || other.blocks('old-owner'), false);
      same('controller untouched', again.snapshot().consentGate, AgentConsentGate.CLEAR);
    });

    // ---------------------------------------------------------------- R2-03 【停止】同步取消并作废所属工作
    it('r2_03_stop_cancels_owned_feedback_and_late_10001_does_not_navigate_stream_kept_until_meta', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const c: AgentController = await streaming(rig, '前');
      const fb: AgentFeedbackView = rig.turn(c, 0).feedback as AgentFeedbackView;
      rig.fake.feedbackCode = 10001;
      rig.fake.delayMs = 1000;
      c.feedback(fb.ticket, 'up');
      await flush();
      await flush();
      same('feedback in flight', (rig.turn(c, 0).feedback as AgentFeedbackView).enabled, false);
      const cancels: number = rig.rec.cancels;
      c.stop(c.snapshot().stop as AgentRunTicket);
      same('stop cancelled feedback synchronously', rig.rec.cancels - cancels >= 1, true);
      same('nothing owned', rig.port.ownedCount(rig.identity.key), 0);
      same('feedback rolled back', (rig.turn(c, 0).feedback as AgentFeedbackView).selected, null);
      same('feedback enabled', (rig.turn(c, 0).feedback as AgentFeedbackView).enabled, true);
      await rig.pump(3000, 100);
      same('late 10001 no login', rig.opens.length, 0);
      same('late result no toast', rig.toasts.length, 0);
      same('one cancel', rig.rec.count('/cancel'), 1);
      // meta 之前停止：反馈同样被取消，但这一轮的流保留到 meta（≤30 秒）再关并发 1 次 cancel（G26 例外）。
      const rig2: TRig = new TRig();
      rig2.rec.manual = true;
      rig2.fake.currentSessionId = SESSION;
      rig2.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const c2: AgentController = await rig2.ready();
      c2.send(c2.snapshot().page, '纯牛奶');
      await rig2.pump(50);
      const m: ManualSink = rig2.rec.lastManual;
      m.headers();
      await rig2.pump();
      rig2.fake.delayMs = 1000;
      c2.feedback((rig2.turn(c2, 0).feedback as AgentFeedbackView).ticket, 'down');
      await flush();
      await flush();
      const cancels2: number = rig2.rec.cancels;
      c2.stop(c2.snapshot().stop as AgentRunTicket);
      same('stopping', c2.snapshot().sending, true);
      same('feedback cancelled before meta', rig2.rec.cancels - cancels2 >= 1, true);
      m.text(META);
      await rig2.pump(50);
      same('stream kept until meta then one cancel', rig2.rec.count('/cancel'), 1);
      same('stopped', c2.snapshot().sending, false);
    });

    // ---------------------------------------------------------------- R2-04 翻页 30504：会话失效处理
    it('r2_04_paging_30504_clears_session_paging_and_turns_next_send_creates_session', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.PAGED;
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('cursor=') >= 0
        ? Promise.resolve(json(30504, '{}')) : null;
      const c: AgentController = await rig.ready();
      same('two rounds', c.snapshot().turns.length, 2);
      same('more', c.snapshot().earlier, 'more');
      c.loadEarlier(c.snapshot().page);
      await rig.pump(200);
      same('turns cleared', c.snapshot().turns.length, 0);
      same('paging cleared', c.snapshot().earlier, 'hidden');
      same('notice', c.snapshot().sessionNotice, AgentController.errorText(30504, ''));
      same('ready', c.currentPhase, AgentPhase.READY);
      same('not read only', c.snapshot().readOnly, false);
      rig.rec.respond = null;
      const before: number = creates(rig);
      c.send(c.snapshot().page, '再问');
      await rig.pump(3000, 25);
      same('new session created', creates(rig), before + 1);
      const last: Wire = rig.rec.streams[rig.rec.streams.length - 1];
      same('not old session', last.path.indexOf(SESSION) < 0, true);
    });

    // ---------------------------------------------------------------- R2-05 翻页 5xxxx：统一文案 + trace6；隐藏期间无界面副作用
    it('r2_05_paging_5xxxx_keeps_trace6_and_hidden_result_has_no_ui_side_effects', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.PAGED;
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('cursor=') >= 0
        ? Promise.resolve(json(50001, '{}')) : null;
      const c: AgentController = await rig.ready();
      c.loadEarlier(c.snapshot().page);
      await rig.pump(500);
      same('failed', c.snapshot().earlier, 'failed');
      same('unified text with trace6', c.snapshot().loadErrorText, AgentController.errorText(50001, TRACE));
      same('trace6 present', c.snapshot().loadErrorText.indexOf('4f5a6b') >= 0, true);
      same('turns kept', c.snapshot().turns.length, 2);
      // 隐藏期间到达的翻页结果（10001）：不导航、不交界面；回来一次性应用统一文案。
      const rig2: TRig = new TRig();
      rig2.fake.currentSessionId = SESSION;
      rig2.fake.historyScenario = AgentFakeHistoryScenario.PAGED;
      const held: Held = new Held();
      rig2.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('cursor=') >= 0
        ? held.promise : null;
      const c2: AgentController = await rig2.ready();
      c2.loadEarlier(c2.snapshot().page);
      await rig2.pump(50);
      c2.setVisible(false);
      const published: number = rig2.snapshots.length;
      held.release(json(10001, '{}'));
      await rig2.pump(200);
      same('hidden no navigation', rig2.opens.length, 0);
      same('hidden no toast', rig2.toasts.length, 0);
      same('hidden no ui publish', rig2.snapshots.length, published);
      c2.setVisible(true);
      same('applied once on return', rig2.snapshots.length, published + 1);
      same('text on return', rig2.snapshots[rig2.snapshots.length - 1].loadErrorText, AgentController.errorText(10001, ''));
      same('still no navigation', rig2.opens.map((o: OpenRecord): string => o.route).length, 0);
    });

    // ---------------------------------------------------------------- R2-06 三组闸门的页面接线（读取 / 发送 / 动作）
    it('r2_06_page_gates_read_for_load_reload_refresh_paging_send_for_send_action_for_feedback', 0, async () => {
      // 取当前会话 42901：读取闸门；整页【重试】禁用，发送不受影响。
      const rig: TRig = new TRig();
      rig.fake.currentCode = 42901;
      const c: AgentController = await rig.ready();
      const s: AgentSnapshot = c.snapshot();
      same('load failed', s.phase, AgentPhase.LOAD_FAILED);
      same('read limited', [s.readLimited, s.limited], [true, false]);
      same('load retry disabled', s.loadRetryDisabled, true);
      same('send not blocked', s.sendBlocked, false);
      // 有会话的断线一轮：重连查询 /【刷新】看读取闸门，同键重发 / 新消息看发送闸门；翻页看读取闸门；反馈举报看动作闸门。
      const rig2: TRig = new TRig();
      rig2.rec.manual = true;
      rig2.fake.currentSessionId = SESSION;
      rig2.fake.historyScenario = AgentFakeHistoryScenario.PAGED;
      const c2: AgentController = await rig2.ready();
      c2.send(c2.snapshot().page, '纯牛奶');
      await rig2.pump(50);
      rig2.rec.lastManual.headers();
      rig2.rec.lastManual.end();
      await rig2.pump();
      const retry: AgentRetryTap = (rig2.turn(c2).error as AgentErrorView).retry as AgentRetryTap;
      same('reconnect mode', retry.mode, AgentRetryMode.RECONNECT);
      rig2.gates.read.start(12000);
      const r: AgentSnapshot = c2.snapshot();
      same('reconnect disabled by read gate', r.retryDisabled(AgentRetryMode.RECONNECT), true);
      same('refresh disabled by read gate', r.retryDisabled(AgentRetryMode.REFRESH), true);
      same('paging disabled by read gate', r.earlierDisabled, true);
      same('same-id resend not read gated', r.retryDisabled(AgentRetryMode.SAME), false);
      same('send not read gated', r.sendBlocked, false);
      same('feedback not read gated', r.actionDisabled, false);
      rig2.gates.read.reset();
      rig2.gates.send.start(12000);
      const w: AgentSnapshot = c2.snapshot();
      same('reconnect not send gated', w.retryDisabled(AgentRetryMode.RECONNECT), false);
      same('paging not send gated', w.earlierDisabled, false);
      same('resend send gated', w.retryDisabled(AgentRetryMode.SAME), true);
      same('new message send gated', w.retryDisabled(AgentRetryMode.NEW), true);
      same('send blocked', w.sendBlocked, true);
      rig2.gates.send.reset();
      rig2.gates.action.start(12000);
      const a: AgentSnapshot = c2.snapshot();
      same('feedback action gated', a.actionDisabled, true);
      same('send not action gated', a.sendBlocked, false);
      same('reload not action gated', a.retryDisabled(AgentRetryMode.RECONNECT), false);
    });
  });
}
