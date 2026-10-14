// APP-10b 鸿蒙第 1 轮评审修复（NATIVE/APP-10b/harmony-review-r1.md R1-01..R1-13）的回归用例：沿用 AgentTransportIntegration 的接线
// （真实 ApiClient + 真实端口 ApiAgentContractPort + AgentController + Router + 抓包传输替身 Recorder / 手工喂字节 ManualSink）。
// 「抓包」只在测试替身里留存；数据只用构造值与锁定 fixture 的形状，不连任何地址。R1-04 的制品层证据在 release-scan（见 harmony-mutation-fix-r1.txt）。
import { describe, it } from '@ohos/hypium';
import {
  AgentCall, AgentConsentGate, AgentConsentTicket, AgentController, AgentErrorView, AgentFeedbackView, AgentHttpResult,
  AgentIdentityChange, AgentOwnershipEvent, AgentOwnershipHandlers, AgentOwnershipStop, AgentPhase, AgentRetryTap,
  AgentJsonObject, AgentRunTicket, AgentSse, AgentSyncAction, AgentTurnView, AgentSyncPolicy, AgentTimeoutPolicy, ApiRequest, TransportRequest, TransportResponse
} from '../../Index';
import { AgentFakeHistoryScenario } from '../staging/ets/agent/AgentFakeTransport';
import { AgentFakeScript } from '../staging/ets/agent/AgentFakeService';
import { flush } from './NetworkTestRig';
import { delta, done, ManualSink, META, OpenRecord, same, SESSION, TRig, utf8, Wire } from './AgentTransportIntegration.test';

const TRACE: string = '0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b';

function envelope(code: number, data: string): Promise<TransportResponse> {
  const h: Record<string, string> = {};
  h['content-type'] = 'application/json';
  return Promise.resolve(TransportResponse.ok(code === 0 ? 200 : 400, h, '{"code":' + String(code) + ',"msg":"","data":' + data
    + ',"trace_id":"' + TRACE + '"}'));
}

function errorFrame(id: number, code: number): string {
  return 'event: error\nid: ' + id + '\ndata: {"code":' + code + ',"msg":"x","retryable":false,"fallback":null}\n\n';
}

function bytesOf(list: number[]): ArrayBuffer {
  return new Uint8Array(list).buffer as ArrayBuffer;
}

function concat(a: ArrayBuffer, b: ArrayBuffer): ArrayBuffer {
  const out: Uint8Array = new Uint8Array(a.byteLength + b.byteLength);
  out.set(new Uint8Array(a), 0);
  out.set(new Uint8Array(b), a.byteLength);
  return out.buffer as ArrayBuffer;
}

/** 当前会话 + 一条进行中的新回复（已收到 meta 与第一段文字）。 */
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

/** 断线（meta 之前 EOF）后的一轮：返回它的【重试】票据。 */
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

export default function agentTransportReviewR1Test(): void {
  describe('AgentTransportReviewR1', () => {
    // ---------------------------------------------------------------- R1-01（S0）HTTP AI 10004 与 SSE 共用同步作废入口
    it('r1_01_feedback_ai_10004_during_new_stream_halts_stream_zero_late_frames_no_quota', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const c: AgentController = await streaming(rig, '前');
      same('streaming', c.snapshot().sending, true);
      const fb: AgentFeedbackView = rig.turn(c, 0).feedback as AgentFeedbackView;
      rig.fake.feedbackCode = 10004;
      c.feedback(fb.ticket, 'up');
      await rig.pump(100);
      same('gate locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('no dialog for feedback', c.snapshot().consent, null);
      same('stream halted', c.snapshot().sending, false);
      const delivered: number = rig.state(c).lastSeq;
      // 旧流之后到达的 delta / done：0 帧交付、额度不更新。
      rig.rec.lastManual.text(delta(3, '后') + done(4, 7));
      await rig.pump();
      same('no late delta', rig.state(c).text, '前');
      same('no late seq', rig.state(c).lastSeq, delivered);
      same('quota untouched', c.snapshot().quotaLeft, null);
      same('no stop ticket', c.snapshot().stop, null);
    });

    // ---------------------------------------------------------------- R1-02（S0）cancel 单次发送
    it('r1_02_identity_cancel_10002_single_shot_no_refresh_no_second_cancel_before_own_request', 0, async () => {
      for (const event of [AgentOwnershipEvent.LOGOUT, AgentOwnershipEvent.AI_CONSENT_WITHDRAWN,
        AgentOwnershipEvent.PRIVACY_WITHDRAWN]) {
        const rig: TRig = new TRig();
        const c: AgentController = await streaming(rig, '甲');
        rig.fake.cancelCode = 10002;
        rig.fake.delayMs = 50;
        const coordinator: AgentOwnershipStop = new AgentOwnershipStop(rig.ledger, new AgentOwnershipHandlers());
        coordinator.dispatch(coordinator.before(event, c), rig.port);
        // 流程自己的请求（logout / recordConsent(false)）在 cancel 之后发出，且自身响应较慢。
        const own: ApiRequest = event === AgentOwnershipEvent.LOGOUT ? new ApiRequest('logout')
          : new ApiRequest('recordConsent', {}, '', '{"type":"ai_third_party","version":1,"accepted":false}');
        rig.client.request(own);
        await rig.pump(3000, 50);
        same(event + ' exactly one cancel', rig.rec.count('/cancel'), 1);
        same(event + ' no refresh', rig.rec.count('/v1/auth/refresh'), 0);
        const order: string[] = rig.rec.wire.map((w: Wire): string => w.path);
        const cancelAt: number = order.findIndex((p: string): boolean => p.indexOf('/cancel') >= 0);
        const ownAt: number = order.findIndex((p: string): boolean => p.indexOf('/logout') >= 0 || p.indexOf('consent') >= 0);
        same(event + ' cancel before own request', cancelAt >= 0 && ownAt > cancelAt, true);
        same(event + ' original token', (rig.rec.last('/cancel') as Wire).headers['Authorization'], 'Bearer old-access');
      }
    });

    // ---------------------------------------------------------------- R1-03（S0）身份变更在途：不重建、不准入
    it('r1_03_identity_change_in_flight_no_rebuild_no_admission_until_done', 0, async () => {
      const change: AgentIdentityChange = new AgentIdentityChange();
      same('idle', change.active, false);
      change.begin(AgentOwnershipEvent.AI_CONSENT_WITHDRAWN);
      // 返回 Agent Tab（控制器已被协调器作废，current 为空）：不重建。
      same('return to tab no rebuild', AgentSyncPolicy.decide(null, false, 'k', true, change.active, true, true),
        AgentSyncAction.INVALIDATE);
      same('same key still invalidate', AgentSyncPolicy.decide('k', true, 'k', true, change.active, true, true),
        AgentSyncAction.INVALIDATE);
      // 应用级许可经端口出口与控制器准入：current / 历史 / 发消息都不发。
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      rig.port.gate = (): boolean => !change.active;
      rig.allowed = (): boolean => !change.active;
      const c: AgentController = rig.controller();
      c.start();
      await rig.pump(200);
      same('no current while in flight', rig.rec.wire.length, 0);
      same('send refused', c.send(c.snapshot().page, '纯牛奶'), false);
      // 端口出口：即使调用方的许可放行，也不发；cancel 不受它限制（它是流程捕获的那一次）。
      const open: AgentCall = new AgentCall(rig.identity.key, false, (): boolean => true, (): boolean => true);
      const r: AgentHttpResult = await rig.port.listMessages(SESSION, null, 20, open, true);
      same('history not sent', [r.notSent, rig.rec.count('/messages')], [true, 0]);
      rig.port.cancelRun('019a0000-0000-7000-8000-000000000121', open);
      await rig.pump(100);
      same('cancel exempt', rig.rec.count('/cancel'), 1);
      // 流程结束：解锁后按结果重建。
      change.end(AgentOwnershipEvent.AI_CONSENT_WITHDRAWN);
      same('done', change.active, false);
      same('rebuild after done', AgentSyncPolicy.decide(null, false, 'k2', true, change.active, true, true),
        AgentSyncAction.REBUILD);
      const c2: AgentController = rig.controller();
      c2.start();
      await rig.pump(200);
      same('requests after done', rig.rec.count('/v1/agent/sessions/current'), 1);
      // 同一事件可重叠：两次 begin 需要两次 end。
      change.begin(AgentOwnershipEvent.LOGOUT);
      change.begin(AgentOwnershipEvent.LOGOUT);
      change.end(AgentOwnershipEvent.LOGOUT);
      same('overlap still active', change.active, true);
      change.end(AgentOwnershipEvent.LOGOUT);
      same('overlap ended', change.active, false);
    });

    // ---------------------------------------------------------------- R1-04（S0）向量探针只在测试源码集
    it('r1_04_vector_wiring_installed_from_test_source_set', 0, () => {
      // 生产入口只剩注入点；这里由 List.test.ets 的 installAgentVectorWiring() 注入（制品层零命中由 release-scan 核对）。
      same('timeout wiring injected', AgentTimeoutPolicy.wiring !== null, true);
      same('ownership wiring injected', AgentOwnershipStop.wiring !== null, true);
    });

    // ---------------------------------------------------------------- R1-05 隐藏期的发送结果不导航、不提示、不留弹框
    it('r1_05_hidden_send_results_no_navigation_no_toast_no_dialog_and_replay_10004_only_locks', 0, async () => {
      for (const code of [10001, 42901, 30506]) {
        const rig: TRig = new TRig();
        rig.fake.currentSessionId = SESSION;
        const c: AgentController = await rig.ready();
        const s: AgentFakeScript = new AgentFakeScript();
        s.ndjson = null;
        s.errorCode = code;
        s.errorStatus = code === 42901 ? 429 : 400;
        rig.script = s;
        c.send(c.snapshot().page, '纯牛奶');
        c.setVisible(false);
        await rig.pump(500);
        same(code + ' no navigation', rig.opens.length, 0);
        same(code + ' no toast', rig.toasts.length, 0);
        if (code === 42901) {
          same('gate still written', rig.gates.send.active, true);
        }
      }
      // 同意后的重放再遇 AI 10004 时页面已隐藏：只锁闸门，不留自动弹框票据；回来显示【重新同意】。
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      rig.fake.consentGranted = false;
      await rig.ask(c, '纯牛奶', 300);
      const t: AgentConsentTicket = c.snapshot().consent as AgentConsentTicket;
      same('first dialog', t !== null && t.pendingRun !== null, true);
      const agreed: Promise<boolean> = c.consentAgree(t);
      rig.fake.consentGranted = false;
      await agreed;
      c.setVisible(false);
      await rig.pump(500);
      same('replayed once', rig.rec.streams.length, 2);
      same('locked', c.snapshot().consentGate, AgentConsentGate.REFUSED);
      same('no dialog ticket while hidden', c.snapshot().consent, null);
      c.setVisible(true);
      same('no auto dialog on return', c.snapshot().consent, null);
      same('re-consent entry', c.currentPhase, AgentPhase.CONSENT_DECLINED);
    });

    // ---------------------------------------------------------------- R1-06 30501 集中处理（七 operation + SSE）
    it('r1_06_feedback_30501_and_stream_30501_lock_unavailable_no_more_requests', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const c: AgentController = await rig.ready();
      rig.fake.feedbackCode = 30501;
      c.feedback((rig.turn(c, 0).feedback as AgentFeedbackView).ticket, 'up');
      await rig.pump(100);
      same('feedback 30501 unavailable', c.currentPhase, AgentPhase.UNAVAILABLE);
      const before: number = rig.rec.wire.length;
      same('send refused', c.send(c.snapshot().page, '再问'), false);
      c.loadEarlier(c.snapshot().page);
      await rig.pump(200);
      same('zero requests after 30501', rig.rec.wire.length, before);
      // 流内 error 30501：同样锁住本次进入。
      const rig2: TRig = new TRig();
      const c2: AgentController = await streaming(rig2, '甲');
      rig2.rec.lastManual.text(errorFrame(3, 30501));
      await rig2.pump();
      same('stream 30501 unavailable', c2.currentPhase, AgentPhase.UNAVAILABLE);
      const streams: number = rig2.rec.streams.length;
      same('stream send refused', c2.send(c2.snapshot().page, '再问'), false);
      await rig2.pump(200);
      same('no new stream', rig2.rec.streams.length, streams);
      same('no quota', c2.snapshot().quotaLeft, null);
    });

    // ---------------------------------------------------------------- R1-07 配置关闭：立即作废重建，准入处复核
    it('r1_07_config_off_rebuilds_same_identity_and_admission_rechecks_config', 0, async () => {
      same('same key availability changed', AgentSyncPolicy.decide('k', true, 'k', false, false, true, true),
        AgentSyncAction.REBUILD);
      same('same key same availability', AgentSyncPolicy.decide('k', true, 'k', true, false, true, true), AgentSyncAction.KEEP);
      same('no page', AgentSyncPolicy.decide('k', true, 'k', false, false, false, true), AgentSyncAction.INVALIDATE);
      // 控制器与端口出口：配置关闭后，已在途的流不再写出后续请求，新的一律不准入。
      let configOn: boolean = true;
      const rig: TRig = new TRig();
      rig.port.gate = (): boolean => configOn;
      rig.allowed = (): boolean => configOn;
      const c: AgentController = await streaming(rig, '甲');
      configOn = false;
      // 作废（AppAgent.sync → REBUILD 的第一步）：关流、取消所属请求。
      c.dispose();
      rig.rec.lastManual.text(delta(3, '后') + done(4, 7));
      await rig.pump();
      same('no late frame', c.streamStates.length === 0 || rig.state(c).text === '甲', true);
      const c2: AgentController = rig.controller();
      c2.start();
      await rig.pump(200);
      same('rebuilt sends nothing', rig.rec.count('/v1/agent/sessions/current'), 1);
      same('send refused', c2.send(c2.snapshot().page, '纯牛奶'), false);
    });

    // ---------------------------------------------------------------- R1-08 后台暂停整个重载流程（含请求在途）
    it('r1_08_background_while_history_in_flight_cancels_and_never_resends', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      const retry: AgentRetryTap = await disconnectedBeforeMeta(rig, c, '纯牛奶');
      rig.fake.delayMs = 800;
      const reads: number = rig.fake.historyRequests;
      c.retry(retry);
      await rig.pump(100);
      same('history in flight', rig.fake.historyRequests - reads, 1);
      const cancels: number = rig.rec.cancels;
      rig.foreground = false;
      c.setForeground(false);
      // 进后台的同步出口：在途的那次历史请求被取消，本条只留【重试】。
      same('cancelled at transition', rig.rec.cancels - cancels >= 1, true);
      same('retry only', (rig.turn(c).error as AgentErrorView).retry !== null, true);
      await rig.pump(3000, 100);
      same('no resend in background', rig.rec.streams.length, 1);
      rig.foreground = true;
      c.setForeground(true);
      await rig.pump(20000, 500);
      same('not resumed', rig.rec.streams.length, 1);
      same('no more history', rig.fake.historyRequests - reads, 1);
    });

    // ---------------------------------------------------------------- R1-09 重载对不上：保留本地、按消息 id 去重追加
    it('r1_09_reload_unmatched_keeps_local_and_appends_history_turns_dedup_by_id', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      const retry: AgentRetryTap = await disconnectedBeforeMeta(rig, c, '纯牛奶');
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      c.retry(retry);
      await rig.pump(200);
      same('local kept first', rig.turn(c, 0).userText, '纯牛奶');
      same('appended two history turns', c.snapshot().turns.map((t: AgentTurnView): string => t.userText),
        ['纯牛奶', '提现记录在哪看', '我现在有多少收益']);
      same('resent same id', rig.rec.streams.length, 2);
      // 再断一次、再重试：同一批历史不重复追加。
      rig.rec.lastManual.headers();
      rig.rec.lastManual.end();
      await rig.pump();
      c.retry((rig.turn(c, 0).error as AgentErrorView).retry as AgentRetryTap);
      await rig.pump(200);
      same('dedup by message id', c.snapshot().turns.length, 3);
    });

    // ---------------------------------------------------------------- R1-10 翻页与重载的 expired 统一只读
    it('r1_10_expired_on_paging_and_reload_locks_input_and_resend_shows_30504', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.PAGED;
      rig.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('cursor=') >= 0
        ? envelope(0, '{"items":[],"next_cursor":null,"expired":true}') : null;
      const c: AgentController = await rig.ready();
      same('fresh', c.snapshot().readOnly, false);
      c.loadEarlier(c.snapshot().page);
      await rig.pump(200);
      same('paging expired read only', c.snapshot().readOnly, true);
      same('cannot send', c.canSend, false);
      same('notice', c.snapshot().sessionNotice, AgentController.errorText(30504, ''));
      // 断线重载拿到 expired=true 且对不上：不向过期会话重发，显示 error.30504 +【新对话】。
      const rig2: TRig = new TRig();
      rig2.rec.manual = true;
      rig2.fake.currentSessionId = SESSION;
      const c2: AgentController = await rig2.ready();
      const retry: AgentRetryTap = await disconnectedBeforeMeta(rig2, c2, '纯牛奶');
      rig2.rec.respond = (r: TransportRequest): Promise<TransportResponse> | null => r.url.indexOf('/messages') >= 0
        && r.method === 'GET' ? envelope(0, '{"items":[],"next_cursor":null,"expired":true}') : null;
      c2.retry(retry);
      await rig2.pump(200);
      same('no resend to expired', rig2.rec.streams.length, 1);
      const e: AgentErrorView = rig2.turn(c2).error as AgentErrorView;
      same('30504 text', e.text, AgentController.errorText(30504, ''));
      same('no retry', e.retry, null);
      same('new chat entry', e.newChat !== null, true);
      same('reload read only', c2.snapshot().readOnly, true);
    });

    // ---------------------------------------------------------------- R1-11 新对话 / 停止同步 cancelOwned
    it('r1_11_new_chat_and_stop_cancel_owned_requests_synchronously', 0, async () => {
      const rig: TRig = new TRig();
      rig.fake.currentSessionId = SESSION;
      rig.fake.historyScenario = AgentFakeHistoryScenario.ACTIVE;
      const c: AgentController = await rig.ready();
      rig.fake.delayMs = 1000;
      c.feedback((rig.turn(c, 0).feedback as AgentFeedbackView).ticket, 'up');
      await flush();
      await flush();
      same('feedback registered', rig.port.ownedCount(rig.identity.key), 1);
      const cancels: number = rig.rec.cancels;
      c.newChat(c.snapshot().page);
      same('cancelled synchronously', rig.rec.cancels - cancels >= 1, true);
      same('only the new create left', rig.port.ownedCount(rig.identity.key), 1);
      await rig.pump(3000, 100);
      same('no late toast', rig.toasts.length, 0);
      // 【停止】：消息还没发出（建会话在途）→ 同步取消这一轮的建会话。
      const rig2: TRig = new TRig();
      const c2: AgentController = await rig2.ready();
      rig2.fake.delayMs = 1000;
      c2.send(c2.snapshot().page, '纯牛奶');
      await flush();
      await flush();
      same('create registered', rig2.port.ownedCount(rig2.identity.key), 1);
      const cancels2: number = rig2.rec.cancels;
      c2.stop(c2.snapshot().stop as AgentRunTicket);
      same('stop cancelled create', rig2.rec.cancels - cancels2 >= 1, true);
      same('nothing owned', rig2.port.ownedCount(rig2.identity.key), 0);
      await rig2.pump(3000, 100);
      same('no stream', rig2.rec.streams.length, 0);
    });

    // ---------------------------------------------------------------- R1-12 流首 BOM 在字节层跳过后再计 data 字节
    it('r1_12_bom_then_65537_byte_data_limited_across_chunks_and_multiline', 0, async () => {
      const bom: ArrayBuffer = bytesOf([0xEF, 0xBB, 0xBF]);
      const big: string = 'data: ' + 'x'.repeat(65537) + '\n';
      // 一块里 BOM + 首行 data。
      const a: AgentSse = new AgentSse();
      same('bom first line', a.feedBytes(concat(bom, utf8(big))).map((o: AgentJsonObject): string => String(o['kindRaw'])), ['too_large']);
      // BOM 跨块（EF | BB | BF + data）。
      const b: AgentSse = new AgentSse();
      b.feedBytes(bytesOf([0xEF]));
      b.feedBytes(bytesOf([0xBB]));
      same('bom split', b.feedBytes(concat(bytesOf([0xBF]), utf8(big))).map((o: AgentJsonObject): string => String(o['kindRaw'])),
        ['too_large']);
      // 多行 data 合计超限。
      const m: AgentSse = new AgentSse();
      const half: string = 'data: ' + 'y'.repeat(32768) + '\n';
      same('multiline', m.feedBytes(concat(bom, utf8(half + half + 'data: z\n'))).map((o: AgentJsonObject): string => String(o['kindRaw'])),
        ['too_large']);
      // 恰好 64 KiB 不超限、BOM 之后的字段照常识别。
      const ok: AgentSse = new AgentSse();
      const items: AgentJsonObject[] = ok.feedBytes(concat(bom, utf8('data: ' + 'x'.repeat(65536) + '\nevent: meta\nid: 1\n\n')));
      same('exact limit frame', items.map((o: AgentJsonObject): string => String(o['kindRaw'])), ['frame']);
      same('event parsed after bom', items[0]['event'], 'meta');
      // 真实管线：BOM + 65537 字节的 meta data → limited，后续正文不显示、额度不更新。
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      const c: AgentController = await rig.ready();
      c.send(c.snapshot().page, '纯牛奶');
      await rig.pump(50);
      const sink: ManualSink = rig.rec.lastManual;
      sink.headers();
      sink.bytes(bom);
      sink.text(big + 'event: meta\nid: 1\n\n' + delta(2, '不该显示') + done(3, 7), [4096]);
      await rig.pump();
      same('limited', rig.state(c).status, 'limited');
      same('no text', rig.state(c).text, '');
      same('no quota', c.snapshot().quotaLeft, null);
    });

    // ---------------------------------------------------------------- R1-13 重载错误保留完整结果
    it('r1_13_reload_10001_routes_login_once_and_5xxxx_keeps_trace6', 0, async () => {
      const rig: TRig = new TRig();
      rig.rec.manual = true;
      rig.fake.currentSessionId = SESSION;
      const c: AgentController = await rig.ready();
      const retry: AgentRetryTap = await disconnectedBeforeMeta(rig, c, '纯牛奶');
      rig.fake.historyCode = 10001;
      const reads: number = rig.fake.historyRequests;
      c.retry(retry);
      await rig.pump(20000, 500);
      same('one request no backoff', rig.fake.historyRequests - reads, 1);
      same('login opened once', rig.opens.map((o: OpenRecord): string => o.route), ['Login']);
      same('unified text', (rig.turn(c).error as AgentErrorView).text, AgentController.errorText(10001, ''));
      // 隐藏期间开始的重载：同样不退避，但不导航。
      const hidden: TRig = new TRig();
      hidden.rec.manual = true;
      hidden.fake.currentSessionId = SESSION;
      const ch: AgentController = await hidden.ready();
      const retryH: AgentRetryTap = await disconnectedBeforeMeta(hidden, ch, '纯牛奶');
      hidden.fake.historyCode = 10001;
      hidden.fake.delayMs = 300;
      ch.retry(retryH);
      ch.setVisible(false);
      await hidden.pump(2000, 100);
      same('hidden no navigation', hidden.opens.length, 0);
      // 5xxxx：退避用尽后显示统一文案 + trace6，不压成「连接中断」。
      const rig2: TRig = new TRig();
      rig2.rec.manual = true;
      rig2.fake.currentSessionId = SESSION;
      const c2: AgentController = await rig2.ready();
      const retry2: AgentRetryTap = await disconnectedBeforeMeta(rig2, c2, '纯牛奶');
      rig2.fake.historyCode = 50001;
      const reads2: number = rig2.fake.historyRequests;
      c2.retry(retry2);
      for (let i: number = 0; i < 40; i++) {
        await rig2.pump(1000, 100);
      }
      same('five attempts', rig2.fake.historyRequests - reads2, 5);
      const e: AgentErrorView = rig2.turn(c2).error as AgentErrorView;
      same('trace6 kept', e.text, AgentController.errorText(50001, TRACE));
      same('trace6 present', e.text.indexOf('4f5a6b') >= 0, true);
      same('retry still offered', e.retry !== null, true);
    });
  });
}
