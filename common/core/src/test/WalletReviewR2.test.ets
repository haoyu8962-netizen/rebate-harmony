// APP-09 鸿蒙第 2 轮评审（harmony-review-r2.md R2-01…R2-09）与共性第 26–33 条的回归测试：真实 ApiClient + 本地假服务
// （WalletIntegration 的 WalletFixture），不连任何地址、不做真实提现。每个用例的注释写明「按旧逻辑为何失败」。R2-09 的界面验收
// （真实短窗口 + 200% + 键盘）见 compare-harmony.md 的截图，这里只测布局算式。
import { describe, it, expect } from '@ohos/hypium';
import {
  PayoutAccountController, PayoutPhase, StepUpController, StepUpSheetFit, TransportRequest, TransportResponse,
  TransportFailure, WalletController, WalletMessage, WalletPhase, WithdrawController, WithdrawPhase,
  WithdrawRecordsController
} from '../../Index';
import { Deferred, envelope } from './NetworkTestRig';
import {
  ALIPAY, NOW, openWithdraw, pathOf, queryOfReq, rulesJson, settle, summaryJson, WalletFixture, withdrawal
} from './WalletIntegration.test';

const SMS_KEY: string = 'user-1|13800005678|withdraw';

/** 提现页提交到需要二次验证（STEP_UP）。 */
async function toStepUp(f: WalletFixture): Promise<WithdrawController> {
  const c: WithdrawController = await openWithdraw(f);
  c.fillQuick(1000, c.snapshot.version);
  await settle();
  c.submit();
  await settle();
  return c;
}

function advance(f: WalletFixture, ms: number): void {
  f.nowMs += ms;
  f.rig.nowMillis = f.nowMs;
}

export default function walletReviewR2Test() {
  describe('APP09_HarmonyReviewR2', () => {
    it('R2_01_reopened_panel_settles_when_inflight_send_finishes', 0, async () => {
      // 旧逻辑：新面板构造时复制 sending=true；旧请求结束只改共享时钟，不通知新面板 → 成功后新面板一直 sending=true、countdown=0，
      // 推进 61 秒后 send() 仍返回 false（第 1 组断言失败）。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await toStepUp(f);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => null);
      const s1: StepUpController = c.createStepUp() as StepUpController;
      expect(s1.send()).assertTrue();
      s1.close();
      expect(f.session.sms.listenerCount(SMS_KEY)).assertEqual(0);
      const s2: StepUpController = c.createStepUp() as StepUpController;
      expect(s2.snapshot.sending).assertTrue();
      expect(s2.send()).assertFalse();
      f.held[f.held.length - 1].resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      await settle();
      expect(s2.snapshot.sending).assertFalse();
      expect(s2.snapshot.sent).assertTrue();
      expect(s2.snapshot.countdown).assertEqual(60);
      advance(f, 61000);
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      expect(s2.send()).assertTrue();
      await settle();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(2);
      s2.close();
      // 失败分支：在途请求 5xxxx → 重开的面板解除 sending、显示带 trace6 的提示，并回到可重试
      advance(f, 61000);
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => null);
      const s3: StepUpController = c.createStepUp() as StepUpController;
      expect(s3.send()).assertTrue();
      s3.close();
      const s4: StepUpController = c.createStepUp() as StepUpController;
      expect(s4.snapshot.sending).assertTrue();
      f.held[f.held.length - 1].resolve(envelope(50001, '{}'));
      await settle();
      expect(s4.snapshot.sending).assertFalse();
      expect(s4.snapshot.countdown).assertEqual(0);
      expect((s4.snapshot.error as WalletMessage).text).assertContain('123456');
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      expect(s4.send()).assertTrue();
      await settle();
      expect(s4.snapshot.countdown).assertEqual(60);
      s4.close();
      expect(f.session.sms.listenerCount(SMS_KEY)).assertEqual(0);
    });

    it('R2_02_42901_after_panel_closed_still_starts_shared_gates', 0, async () => {
      // 旧逻辑：发码结果回来时面板已关（valid()=false）提前 return，跳过 failure() 里的 smsGate.start → 重开面板立即发出第二次请求。
      // 验证同理：owner 绑面板，关闭后 42901 被当成取消丢掉，verifyGate 不启动。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await toStepUp(f);
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => null);
      const s1: StepUpController = c.createStepUp() as StepUpController;
      expect(s1.send()).assertTrue();
      s1.close();
      f.held[f.held.length - 1].resolve(envelope(42901, '{}', { 'Retry-After': '60' }));
      await settle();
      expect(f.session.smsGate.active).assertTrue();
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      const s2: StepUpController = c.createStepUp() as StepUpController;
      expect(s2.snapshot.sendBlocked).assertTrue();
      expect(s2.send()).assertFalse();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(1);
      // 截止时间过后可以发
      advance(f, 61000);
      expect(s2.send()).assertTrue();
      await settle();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(2);
      // 验证：面板关闭后到达的 42901 同样写入共享验证限流
      f.reply('/v1/auth/step-up', (_r: TransportRequest) => null);
      s2.setCode('123456');
      expect(s2.verify()).assertTrue();
      await settle();
      s2.close();
      f.held[f.held.length - 1].resolve(envelope(42901, '{}', { 'Retry-After': '30' }));
      await settle();
      expect(f.session.verifyGate.active).assertTrue();
      const s3: StepUpController = c.createStepUp() as StepUpController;
      s3.setCode('123456');
      expect(s3.canVerify).assertFalse();
      expect(s3.verify()).assertFalse();
      s3.close();
      // 会话换代后到达的 42901 不写进新会话
      const g: WalletFixture = new WalletFixture();
      const cg: WithdrawController = await toStepUp(g);
      g.reply('/v1/auth/sms-codes', (_r: TransportRequest) => null);
      const sg: StepUpController = cg.createStepUp() as StepUpController;
      expect(sg.send()).assertTrue();
      sg.close();
      g.switchAccount('user-2');
      g.held[g.held.length - 1].resolve(envelope(42901, '{}', { 'Retry-After': '60' }));
      await settle();
      expect(g.session.smsGate.active).assertFalse();
    });

    it('R2_03_expanded_item_adopts_latest_detail_for_status_and_trade_no', 0, async () => {
      // 旧逻辑：普通展开项只存 details，列表项仍是旧的 PENDING_REVIEW；卡片显示「审核中」，同时出现已到账详情的交易流水号。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":['
        + withdrawal('W1', 'PENDING_REVIEW', 1000, '2026-10-12T10:30:00+08:00') + '],"next_cursor":null}'));
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W1', 'PAID_API', 1000,
        '2026-10-12T10:30:00+08:00', ',"channel_order_id":"20261012000000000001"')));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open(null);
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('PENDING_REVIEW');
      const v: number = c.snapshot.version;
      expect(c.toggle('W1', v)).assertTrue();
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('PAID_API');
      expect(c.tradeNo('W1')['copyText'] as string).assertEqual('20261012000000000001');
      expect(c.snapshot.version > v + 1).assertTrue();
      // 刷新：列表变为 FAILED，本轮详情读取失败 → 不再显示上一轮的流水号（与本轮状态矛盾），展开项显示错误与【重试】
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":['
        + withdrawal('W1', 'FAILED', 1000, '2026-10-12T10:30:00+08:00') + '],"next_cursor":null}'));
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(50001, '{}'));
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('FAILED');
      expect(c.tradeNo('W1')['show'] === true).assertFalse();
      expect((c.detailError('W1') as WalletMessage).text).assertContain('123456');
      expect(await c.copy('W1', c.snapshot.version, '20261012000000000001')).assertEqual('not_copyable');
    });

    it('R2_04_refresh_failure_keeps_list_with_its_cursor_and_retry', 0, async () => {
      // 旧逻辑：刷新开始把 cursor 清成 null；第一页 50001 → 保留 items、hasMore=true，却不恢复游标 → loadMore() 一直 false。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals', (r: TransportRequest) => queryOfReq(r).indexOf('cursor=') >= 0
        ? envelope(0, '{"items":[' + withdrawal('W9', 'PAID_API', 300, '2026-08-01T10:00:00+08:00')
          + '],"next_cursor":null}')
        : envelope(0, '{"items":[' + withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00')
          + '],"next_cursor":"c2"}'));
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W2', 'PAID_API', 500,
        '2026-09-27T15:20:00+08:00', ',"channel_order_id":"20260928000000000002"')));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open(null);
      await settle();
      expect(c.toggle('W2', c.snapshot.version)).assertTrue();
      await settle();
      expect(c.tradeNo('W2')['show'] === true).assertTrue();
      const listOk: (r: TransportRequest) => TransportResponse | null = (r: TransportRequest) =>
        queryOfReq(r).indexOf('cursor=') >= 0
          ? envelope(0, '{"items":[' + withdrawal('W9', 'PAID_API', 300, '2026-08-01T10:00:00+08:00')
            + '],"next_cursor":null}')
          : envelope(50001, '{}');
      f.reply('/v1/withdrawals', listOk);
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.items.length).assertEqual(1);
      expect(c.snapshot.hasMore).assertTrue();
      expect((c.snapshot.refreshError as WalletMessage).text).assertContain('123456');
      // 旧列表配套的详情仍显示（不因轮次变化把流水号藏掉）
      expect(c.tradeNo('W2')['show'] === true).assertTrue();
      // 恢复的游标可继续翻页（请求带 cursor=c2）
      expect(c.loadMore()).assertTrue();
      await settle();
      const last: TransportRequest = f.last('/v1/withdrawals');
      expect(queryOfReq(last)).assertContain('cursor=c2');
      expect(c.snapshot.items.length).assertEqual(2);
      // 【重试】成功后常驻错误清除
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":['
        + withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00') + '],"next_cursor":"c3"}'));
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.refreshError).assertNull();
      // 限流中（共享读闸门）回到前台：不发、旧列表与游标原样保留
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      await openWithdraw(f);
      expect(f.session.readGate.active).assertTrue();
      c.onShown();
      await settle();
      expect(c.snapshot.items.length).assertEqual(1);
      advance(f, 31000);
      expect(c.loadMore()).assertTrue();
    });

    it('R2_05_getme_failure_before_summary_is_kept_and_shown_with_retry', 0, async () => {
      // 旧逻辑：getMe 先返回 50001 时页面仍是 LOADING，错误直接丢弃 → 摘要随后成功，notice 与错误都为 null。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => null);
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.LOADING);
      f.held[f.held.length - 1].resolve(envelope(0, summaryJson()));
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect((w.snapshot.notice as WalletMessage).text).assertContain('123456');
      expect((w.snapshot.realnameError as WalletMessage).text).assertContain('123456');
      // 【重试】：成功后清除并落地实名状态
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, '{"realname_status":"verified"}'));
      expect(w.retryRealname()).assertTrue();
      await settle();
      expect(w.snapshot.realnameError).assertNull();
      expect(f.session.realname.verified('user-1')).assertTrue();
      expect(w.retryRealname()).assertFalse();
    });

    it('R2_06_payout_reread_failure_shows_error_and_drops_old_line', 0, async () => {
      // 旧逻辑：提现页已显示账号 A，回来重读 50001 → 保留旧 payoutLine 并设 payoutError；视图先判 payoutLine，错误与重试显示不出来。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      expect(c.snapshot.payoutLine).assertEqual('支付宝 138****5678');
      // 重读在途：旧账号不再标作当前收款账号
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => null);
      c.onShown();
      await settle();
      expect(c.snapshot.payoutLine).assertNull();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(50001, '{}'));
      c.onShown();
      await settle();
      expect(c.snapshot.payoutLine).assertNull();
      expect((c.snapshot.payoutError as WalletMessage).text).assertContain('123456');
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, ALIPAY));
      expect(c.retryPayout()).assertTrue();
      await settle();
      expect(c.snapshot.payoutError).assertNull();
      expect(c.snapshot.payoutLine).assertEqual('支付宝 138****5678');
      // 收款账号页同类：显示账号（VIEW）时重读失败 → 错误态（trace6 +【重试】），不把旧账号当当前账号
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, ALIPAY));
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.VIEW);
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(50001, '{}'));
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.ERROR);
      expect((p.snapshot.error as WalletMessage).text).assertContain('123456');
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, ALIPAY));
      expect(p.retry()).assertTrue();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.VIEW);
    });

    it('lesson30_withdraw_rules_reread_failure_shows_error_and_retry', 0, async () => {
      // 旧逻辑：已有 rules 时回到本页重取 50001 → rulesFailed 只在 rules 为 null 时设错误，旧 rules 静默沿用，没有提示与重试。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      expect(c.snapshot.rules !== null).assertTrue();
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(50001, '{}'));
      c.onShown();
      await settle();
      expect((c.snapshot.rulesError as WalletMessage).text).assertContain('123456');
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(0, rulesJson(null)));
      expect(c.retryRules()).assertTrue();
      await settle();
      expect(c.snapshot.rulesError).assertNull();
      expect(c.retryRules()).assertFalse();
    });

    it('R2_07_withdraw_navigation_voided_when_page_covered_or_other_navigation', 0, async () => {
      // 旧逻辑：等待 getMe 时用户点【提现记录】进入记录页，钱包只触发 onHidden，未作废 navSeq → 旧 getMe 返回 verified 后照样 open()。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me', (_r: TransportRequest) => null);
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.withdrawAllowed).assertTrue();
      let opened: number = 0;
      expect(w.requestWithdraw((): void => {
        opened++;
      })).assertTrue();
      await settle();
      w.onHidden();
      f.held[f.held.length - 1].resolve(envelope(0, '{"realname_status":"verified"}'));
      await settle();
      expect(opened).assertEqual(0);
      // 读取结果照样落进共享实名状态；回到钱包再点直接打开
      expect(f.session.realname.verified('user-1')).assertTrue();
      w.onShown();
      expect(w.requestWithdraw((): void => {
        opened++;
      })).assertTrue();
      expect(opened).assertEqual(1);
      // 本页发起了别的导航（noteNavigation）：同样作废
      const g: WalletFixture = new WalletFixture();
      g.reply('/v1/me', (_r: TransportRequest) => null);
      g.session.sync();
      const w2: WalletController = new WalletController(g.deps());
      w2.load();
      await settle();
      let opened2: number = 0;
      w2.requestWithdraw((): void => {
        opened2++;
      });
      await settle();
      w2.noteNavigation();
      g.held[g.held.length - 1].resolve(envelope(0, '{"realname_status":"verified"}'));
      await settle();
      expect(opened2).assertEqual(0);
      // 实名查询世代被新查询取代：旧响应不导航
      const h: WalletFixture = new WalletFixture();
      h.reply('/v1/me', (_r: TransportRequest) => null);
      h.session.sync();
      const w3: WalletController = new WalletController(h.deps());
      w3.load();
      await settle();
      let opened3: number = 0;
      w3.requestWithdraw((): void => {
        opened3++;
      });
      await settle();
      const old: Deferred = h.held[h.held.length - 1];
      h.session.realname.begin();
      old.resolve(envelope(0, '{"realname_status":"verified"}'));
      await settle();
      expect(opened3).assertEqual(0);
    });

    it('R2_07_post_await_navigation_waits_for_visible_withdraw_page', 0, async () => {
      // 共性第 31 条同类：提交在途时本页被覆盖，成功后不把 WithdrawRecords 压到覆盖页上，回到本页时再替换。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      c.onHidden();
      f.held[f.held.length - 1].resolve(envelope(0, withdrawal('W1', 'PENDING_REVIEW', 1000,
        '2026-10-12T10:30:00+08:00', ',"channel_order_id":null')));
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.DONE);
      expect(f.stack.names.indexOf('WithdrawRecords')).assertEqual(-1);
      c.onShown();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('WithdrawRecords');
      expect(f.stack.topParams()['withdrawal_id'] as string).assertEqual('W1');
    });

    it('R2_08_offline_refresh_marks_memory_summary_stale_when_cache_write_failed', 0, async () => {
      // 旧逻辑：缓存写入失败、cache.load()=null → 进入保留内容的 fail 分支：旧金额继续显示，stale=false、【提现】仍可点。
      const f: WalletFixture = new WalletFixture();
      f.store.failWrite = true;
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect(f.store.files.size).assertEqual(0);
      advance(f, 5 * 60000);
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(w.snapshot.summary !== null).assertTrue();
      expect(w.snapshot.stale).assertTrue();
      expect(w.snapshot.staleFetchedAt).assertEqual(NOW);
      expect(w.withdrawAllowed).assertFalse();
      // 磁盘里有更旧的缓存时也用更新的内存摘要的时刻
      const g: WalletFixture = new WalletFixture();
      g.session.sync();
      const w2: WalletController = new WalletController(g.deps());
      w2.load();
      await settle();
      expect(g.store.files.size).assertEqual(1);
      advance(g, 60000);
      g.store.failWrite = true;
      w2.refresh();
      await settle();
      advance(g, 60000);
      g.reply('/v1/wallet/summary', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      w2.refresh();
      await settle();
      expect(w2.snapshot.stale).assertTrue();
      expect(w2.snapshot.staleFetchedAt).assertEqual(NOW + 60000);
      // 5xxxx 刷新失败：保留内容 + 常驻错误条（trace6 +【重试】）
      const h: WalletFixture = new WalletFixture();
      h.session.sync();
      const w3: WalletController = new WalletController(h.deps());
      w3.load();
      await settle();
      h.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(50001, '{}'));
      w3.refresh();
      await settle();
      expect(w3.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect((w3.snapshot.refreshError as WalletMessage).text).assertContain('123456');
      h.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson()));
      w3.refresh();
      await settle();
      expect(w3.snapshot.refreshError).assertNull();
      expect(pathOf(h.last('/v1/wallet/summary'))).assertEqual('/v1/wallet/summary');
    });

    it('R2_09_step_up_degrades_to_whole_scroll_when_three_parts_do_not_fit', 0, () => {
      // 旧做法：middle() 强制保留一行验证码格的下限，面板按 MIN_PANEL 抬高；真实约 560vp、200% 字号、键盘约 300vp 时三段之和超过
      // 可用高，标题与关闭溢出到窗口上方。现在三段最小高放不下真实可用高就整块滚动，外层高度等于真实可用高（不超出窗口）。
      const viewport: number = 560;
      const top: number = 38;
      const bottom: number = 28;
      const kb: number = 300;
      const avail: number = StepUpSheetFit.available(viewport, top, bottom, kb);
      expect(avail).assertEqual(560 - 38 - 24 - 300 - 28);
      // 200%：标题两行约 68，底部（倒计时命中区 48 + 间距 8 + 按钮 64）约 120，chrome 72，一行验证码格约 82
      const header: number = 68;
      const footer: number = 120;
      const chrome: number = 72;
      const minMiddle: number = 82;
      expect(StepUpSheetFit.degraded(avail, header, footer, chrome, minMiddle)).assertTrue();
      const panelMax: number = StepUpSheetFit.maxPanel(viewport, top, bottom, kb);
      const outer: number = StepUpSheetFit.outer(avail, panelMax, header, footer, chrome, 150, true);
      expect(outer).assertEqual(avail);
      expect(outer + StepUpSheetFit.spacer(kb) + top + StepUpSheetFit.TOP_GAP + bottom <= viewport).assertTrue();
      // 键盘收起或普通字号：三段放得下，不降级，外层高度等于三段之和（中段压缩后），不超过面板最大高
      const availNoKb: number = StepUpSheetFit.available(viewport, top, bottom, 0);
      expect(StepUpSheetFit.degraded(availNoKb, header, footer, chrome, minMiddle)).assertFalse();
      const availStd: number = StepUpSheetFit.available(873, top, bottom, 296);
      expect(StepUpSheetFit.degraded(availStd, 30, 100, chrome, 58)).assertFalse();
      const pm: number = StepUpSheetFit.maxPanel(873, top, bottom, 296);
      const mid: number = StepUpSheetFit.middle(pm, 30, 100, chrome, 76, 58);
      expect(StepUpSheetFit.outer(availStd, pm, 30, 100, chrome, mid, false)).assertEqual(30 + 100 + chrome + mid);
      // 还没量到标题 / 底部：不降级，先给有限高
      expect(StepUpSheetFit.degraded(avail, 0, 0, chrome, minMiddle)).assertFalse();
      expect(StepUpSheetFit.outer(avail, panelMax, 0, 0, chrome, 0, false) <= StepUpSheetFit.FALLBACK_PANEL).assertTrue();
      // 极端：可用高为负也给一行控件的滚动区
      expect(StepUpSheetFit.available(300, top, bottom, 300)).assertEqual(StepUpSheetFit.MIN_SCROLL);
    });
  });
}
