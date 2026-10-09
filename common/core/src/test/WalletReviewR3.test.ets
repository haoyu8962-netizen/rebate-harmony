// APP-09 鸿蒙第 3 轮评审（harmony-review-r3.md R3-01…R3-05）与共性第 34–38 条的回归测试：真实 ApiClient + 本地假服务
// （WalletIntegration 的 WalletFixture），不连任何地址、不做真实提现。每个用例的注释写明「按旧逻辑为何失败」。
// R3-03 的界面部分（收款方式组内的错误文字、选项上的无障碍说明）在 PayoutAccountView，这里测执行层与焦点目标算式。
import { describe, it, expect } from '@ohos/hypium';
import {
  PayoutAccountController, PayoutAccountForm, PayoutPhase, TransportRequest, TransportResponse, WalletController, WalletDraftTexts,
  WalletMessage, WalletPhase, WithdrawController, WithdrawPhase, WithdrawRecordsController
} from '../../Index';
import { envelope } from './NetworkTestRig';
import {
  NOW, openWithdraw, passStepUp, queryOfReq, settle, summaryJson, WalletFixture, withdrawal
} from './WalletIntegration.test';

function advance(f: WalletFixture, ms: number): void {
  f.nowMs += ms;
  f.rig.nowMillis = f.nowMs;
}

const CREATED: string = '2026-10-12T10:30:00+08:00';

export default function walletReviewR3Test() {
  describe('APP09_HarmonyReviewR3', () => {
    it('R3_01_list_commit_keeps_detail_accepted_in_same_round', 0, async () => {
      // 旧逻辑：刷新的列表响应延迟，期间展开 W1、详情先回来（PAID_API + 流水号）；延迟的列表（PENDING_REVIEW）直接覆盖 items，
      // 随后重取详情失败 → 卡片显示「审核中」同时显示已到账的交易流水号（第一组断言 status 为 PENDING_REVIEW）。
      const f: WalletFixture = new WalletFixture();
      const listPending: string = '{"items":[' + withdrawal('W1', 'PENDING_REVIEW', 1000, CREATED)
        + '],"next_cursor":null}';
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, listPending));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open(null);
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('PENDING_REVIEW');
      // 下拉刷新：列表响应挂起
      f.reply('/v1/withdrawals', (_r: TransportRequest) => null);
      expect(c.refresh()).assertTrue();
      await settle();
      const listHeld: number = f.held.length - 1;
      // 列表在途时展开，详情先返回已到账
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W1', 'PAID_API', 1000, CREATED,
        ',"channel_order_id":"20261012000000000001"')));
      expect(c.toggle('W1', c.snapshot.version)).assertTrue();
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('PAID_API');
      // 之后的自动重取详情失败；延迟的列表返回旧状态
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(50001, '{}'));
      f.held[listHeld].resolve(envelope(0, listPending));
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('PAID_API');
      const row: Record<string, Object | null> = c.tradeNo('W1');
      expect(row['show'] === true).assertTrue();
      expect(row['copyText'] as string).assertEqual('20261012000000000001');
      // 下一轮列表成功、详情也成功：本轮数据整体替换（不是永远沿用旧轮次的详情）
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":['
        + withdrawal('W1', 'FAILED', 1000, CREATED) + '],"next_cursor":null}'));
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W1', 'FAILED', 1000, CREATED)));
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('FAILED');
      expect(c.tradeNo('W1')['show'] === true).assertFalse();
    });

    it('R3_02_repeated_retry_while_refreshing_keeps_cursor', 0, async () => {
      // 旧逻辑：刷新失败后连点两次重试：第一次 run 把 cursor 清空，第二次把这个 null 备份成 keptCursor；第二次也失败后旧列表保留、
      // hasMore=true，但 loadMore() 一直 false（第一组断言失败）；且在途时重试会另发一轮（请求计数断言失败）。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals', (r: TransportRequest) => queryOfReq(r).indexOf('cursor=') >= 0
        ? envelope(0, '{"items":[' + withdrawal('W9', 'PAID_API', 300, '2026-08-01T10:00:00+08:00')
          + '],"next_cursor":null}')
        : envelope(0, '{"items":[' + withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00')
          + '],"next_cursor":"c2"}'));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open(null);
      await settle();
      expect(c.snapshot.hasMore).assertTrue();
      // 第一次刷新失败：出现重试条
      const pagedOk: (r: TransportRequest) => TransportResponse | null = (r: TransportRequest) => queryOfReq(r).indexOf('cursor=') >= 0
        ? envelope(0, '{"items":[' + withdrawal('W9', 'PAID_API', 300, '2026-08-01T10:00:00+08:00')
          + '],"next_cursor":null}')
        : envelope(50001, '{}');
      f.reply('/v1/withdrawals', pagedOk);
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.refreshError !== null).assertTrue();
      // 连点两次重试：第一次发出（挂起），第二次合并到在途这一轮，不另发
      const before: number = f.count('GET /v1/withdrawals');
      f.reply('/v1/withdrawals', (_r: TransportRequest) => null);
      expect(c.refresh()).assertTrue();
      expect(c.snapshot.refreshing).assertTrue();
      expect(c.inFlight()).assertTrue();
      expect(c.refresh()).assertTrue();
      expect(c.retry()).assertFalse();
      await settle();
      expect(f.count('GET /v1/withdrawals')).assertEqual(before + 1);
      f.reply('/v1/withdrawals', pagedOk);
      f.held[f.held.length - 1].resolve(envelope(50001, '{}'));
      await settle();
      expect(c.snapshot.items.length).assertEqual(1);
      expect(c.snapshot.hasMore).assertTrue();
      expect(c.inFlight()).assertFalse();
      // 恢复的是「已成功列表」配套的游标：可继续翻页（请求带 cursor=c2）
      expect(c.loadMore()).assertTrue();
      await settle();
      expect(queryOfReq(f.last('/v1/withdrawals'))).assertContain('cursor=c2');
      expect(c.snapshot.items.length).assertEqual(2);
    });

    it('R3_03_payout_method_field_error_visible_with_real_focus_target', 0, async () => {
      // 旧逻辑：20001 fields=[payout_method] 只登记字段错误、不设 banner；页面收款方式组不显示错误，焦点目标 payout_payout_method
      // 不存在。现在焦点落到当前选中的选项（payout_method_bank_card），组内显示错误；字段错误全不在可见字段上时改用错误条。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(20001, '{"fields":["payout_method"]}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      p.setMethod('bank_card');
      p.setField('card_no', '6222 0000 0000 0009');
      p.setField('bank_name', '示例银行');
      p.setField('payee_name', '测试三');
      const seq: number = p.snapshot.fieldErrorSeq;
      expect(p.save()).assertTrue();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      expect(p.snapshot.fieldErrors.has('payout_method')).assertTrue();
      expect(p.snapshot.fieldErrorSeq).assertEqual(seq + 1);
      // 已填内容保留
      expect(p.snapshot.form.cardNo).assertEqual('6222 0000 0000 0009');
      expect(p.snapshot.form.bankName).assertEqual('示例银行');
      // 焦点目标是页面上实际存在的选项控件；收款方式组排在错误顺序最前
      expect(PayoutAccountForm.FIELD_ORDER[0]).assertEqual('payout_method');
      expect(PayoutAccountForm.errorFocusId('payout_method', 'bank_card')).assertEqual('payout_method_bank_card');
      expect(PayoutAccountForm.errorFocusId('payout_method', 'alipay')).assertEqual('payout_method_alipay');
      expect(PayoutAccountForm.errorFocusId('card_no', 'bank_card')).assertEqual('payout_card_no');
      expect(PayoutAccountForm.visibleFields('bank_card').indexOf('payout_method') >= 0).assertTrue();
      // 字段错误不落在当前方式可见的字段上（银行卡方式下报 alipay_logon_id）：没有可见位置 → 错误条说明原因
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(20001, '{"fields":["alipay_logon_id"]}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      expect(p.save()).assertTrue();
      await settle();
      expect(p.snapshot.banner !== null).assertTrue();
      expect(p.snapshot.form.cardNo).assertEqual('6222 0000 0000 0009');
    });

    it('R3_04_withdraw_covered_page_defers_step_up_and_risk_dialog', 0, async () => {
      // 旧逻辑：提交在途时点收款账号行进入 PayoutAccount（onHidden），原请求返回 10003 / 44001 → 隐藏页仍发布 stepUpAction /
      // riskDialog，页面立即开面板或弹窗（第一组断言 stepUpAction 非空）。
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      c.openPayout();
      c.onHidden();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('PayoutAccount');
      f.held[f.held.length - 1].resolve(envelope(10003, '{}'));
      await settle();
      // 状态已结算到 STEP_UP（原键保留），但不打开面板
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      expect(c.snapshot.stepUpAction).assertNull();
      expect(c.createStepUp()).assertNull();
      // 回到本页：面板打开，验证后沿用原键重放
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(0, withdrawal('W1', 'PENDING_REVIEW', 1000,
        CREATED, ',"channel_order_id":null')));
      c.onShown();
      expect(c.snapshot.stepUpAction as string).assertEqual(WithdrawController.STEP_UP_ACTION);
      await passStepUp(c);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.DONE);

      // 44001：本页刚发起导航（导航世代已变，onHidden 还没到）就到达 → 不弹窗；回到本页再弹
      const g: WalletFixture = new WalletFixture();
      g.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      g.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c2: WithdrawController = await openWithdraw(g);
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      c2.openRecords();
      g.held[g.held.length - 1].resolve(envelope(44001, '{}'));
      await settle();
      expect(c2.snapshot.riskDialog).assertNull();
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      expect(c2.snapshot.inputText).assertEqual('10');
      c2.onHidden();
      c2.onShown();
      expect((c2.snapshot.riskDialog as WalletMessage).textKey).assertEqual('error.44001');

      // 前置引导（30304 → RealName）：本页刚发起导航时到达，不自动打开前置页（引导条仍在）
      const h: WalletFixture = new WalletFixture();
      h.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      h.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c3: WithdrawController = await openWithdraw(h);
      c3.fillQuick(1000, c3.snapshot.version);
      await settle();
      expect(c3.submit()).assertTrue();
      await settle();
      c3.openPayout();
      h.held[h.held.length - 1].resolve(envelope(30304, '{}'));
      await settle();
      expect(h.stack.names.indexOf('RealName')).assertEqual(-1);
      expect(c3.snapshot.banner !== null).assertTrue();

      // 页面一直可见：照常立即打开（不误伤）
      const k: WalletFixture = new WalletFixture();
      const c4: WithdrawController = await openWithdraw(k);
      c4.fillQuick(1000, c4.snapshot.version);
      await settle();
      c4.submit();
      await settle();
      expect(c4.snapshot.stepUpAction as string).assertEqual(WithdrawController.STEP_UP_ACTION);
    });

    it('R3_04_payout_covered_page_defers_step_up_and_risk_dialog', 0, async () => {
      // 旧逻辑：收款账号页保存在途时被覆盖，迟到的 10003 / 44001 仍发布 stepUpAction / riskDialog（第一组断言 stepUpAction 非空）。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => null);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', '13800135678');
      p.setField('payee_name', '测试三');
      expect(p.save()).assertTrue();
      await settle();
      p.onHidden();
      f.held[f.held.length - 1].resolve(envelope(10003, '{}'));
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.STEP_UP);
      expect(p.snapshot.stepUpAction).assertNull();
      expect(p.createStepUp()).assertNull();
      p.onShown();
      expect(p.snapshot.stepUpAction as string).assertEqual(PayoutAccountController.STEP_UP_ACTION);
      p.stepUpClosed();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      // 44001：本页发起了导航（打开实名页）后到达 → 不弹窗；回到本页再弹，已填内容保留
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => null);
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      expect(p.save()).assertTrue();
      await settle();
      p.openRealName();
      f.held[f.held.length - 1].resolve(envelope(44001, '{}'));
      await settle();
      expect(p.snapshot.riskDialog).assertNull();
      expect(p.snapshot.form.alipayLogonId).assertEqual('13800135678');
      p.onShown();
      expect((p.snapshot.riskDialog as WalletMessage).textKey).assertEqual('error.44001');
    });

    it('R3_05_kept_summary_marks_updated_time_on_every_non_network_failure', 0, async () => {
      // 旧逻辑：5xxxx / 42901 / 坏数据刷新失败只设错误条，keptFetchedAt 不存在、stale=false → 页面不标最后成功时间。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect(w.snapshot.keptFetchedAt).assertEqual(0);
      // 5xxxx
      advance(f, 5 * 60000);
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(50001, '{}'));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(w.snapshot.summary !== null).assertTrue();
      expect(w.snapshot.stale).assertFalse();
      expect(w.snapshot.keptFetchedAt).assertEqual(NOW);
      // 坏数据
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, '{}'));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(w.snapshot.keptFetchedAt).assertEqual(NOW);
      // 42901
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(w.snapshot.keptFetchedAt).assertEqual(NOW);
      // 限流中回到本页（提交成功标记要刷新）：没发也保留并标时间
      f.session.walletNeedsRefresh = true;
      w.onShown();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect(w.snapshot.keptFetchedAt).assertEqual(NOW);
      // 中性文案（草稿 TODO(N-32)）：「更新于 {time}」，不说成网络不可用
      const text: string = WalletDraftTexts.DRAFTS.get('wallet.updated_at') ?? '';
      expect(text).assertEqual('更新于 {time}');
      expect(text.indexOf('网络')).assertEqual(-1);
      // 成功后清除
      advance(f, 31000);
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson()));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(w.snapshot.keptFetchedAt).assertEqual(0);
      expect(w.snapshot.refreshError).assertNull();
    });
  });
}
