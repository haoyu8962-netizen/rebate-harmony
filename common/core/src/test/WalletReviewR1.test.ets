// APP-09 鸿蒙第 1 轮评审（harmony-review-r1.md R1-01…R1-10）的回归测试：真实 ApiClient + 本地假服务（WalletIntegration 的 WalletFixture），
// 不连任何地址、不做真实提现。每个用例的注释写明「按旧逻辑为何失败」。R1-11（二次验证半屏的键盘布局）是界面问题，见 compare-harmony.md 的截图。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiResult, FileOps, FileSlot, FundPageLayout, MemoryOrderCacheStore, OrderPendingMark,
  PayoutAccountController, PayoutPhase, PendingClick, PendingView, RealNameController, RecordsPhase, RouteRequest,
  RouteSource, SensitiveStep, StepUpController, StepUpSheetFit, TransportFailure, TransportRequest, TransportResponse,
  WalletContractPort, WalletController, WalletMessage, WalletPhase, WalletRecord, WalletStaleCache, WalletSummaryView,
  WithdrawController, WithdrawPhase, WithdrawRecordsController
} from '../../Index';
import { Deferred, envelope } from './NetworkTestRig';
import {
  ALIPAY, NOW, openWithdraw, passStepUp, pathOf, queryOfReq, rulesJson, settle, sleep, summaryJson, WalletFixture,
  withdrawal
} from './WalletIntegration.test';

/** 内存文件操作（FileSlot 注入点）：可模拟改名失败、删除失败（标记的临时文件已落盘但改名失败）。 */
class MarkOps implements FileOps {
  readonly files: Map<string, string> = new Map<string, string>();
  failRename: boolean = false;
  failRemove: boolean = false;

  exists(path: string): boolean {
    return this.files.has(path);
  }

  readText(path: string): string {
    return this.files.get(path) ?? '';
  }

  writeDurable(path: string, value: string): void {
    this.files.set(path, value);
  }

  rename(from: string, to: string): void {
    if (this.failRename) {
      throw new Error('rename failed');
    }
    const v: string = this.files.get(from) ?? '';
    this.files.delete(from);
    this.files.set(to, v);
  }

  remove(path: string): void {
    if (this.failRemove) {
      throw new Error('remove failed');
    }
    this.files.delete(path);
  }
}

/** 实名待定接口的替身（只回成功）。 */
class OkContract implements WalletContractPort {
  private ok(): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', {}, 'trace-wallet-abc123', 200, TransportFailure.NONE,
      null, null, null));
  }

  submitRealname(_name: string, _idNo: string): Promise<ApiResult> {
    return this.ok();
  }

  getLaborAgreement(): Promise<ApiResult> {
    return this.ok();
  }

  signLaborAgreement(_v: string, _s: string): Promise<ApiResult> {
    return this.ok();
  }
}

const MARK_PATH: string = '/data/files/couli_wallet_cache.pending';

/** 提现页提交得到结果未知（断连），返回提现页。 */
async function pendingWithdraw(f: WalletFixture): Promise<WithdrawController> {
  f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
  f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
  const c: WithdrawController = await openWithdraw(f);
  c.fillQuick(1000, c.snapshot.version);
  await settle();
  c.submit();
  await settle();
  return c;
}

export default function walletReviewR1Test() {
  describe('APP09_HarmonyReviewR1', () => {
    it('R1_01_late_result_of_left_page_resyncs_reentered_withdraw', 0, async () => {
      // 旧逻辑：新页面只在 onShown / 自己的结果之后 syncPending；旧页面的请求超时后（未决记录变成结果未知）新页面不知道，
      // 仍是 inFlightElsewhere=true、pending=null，没有确认与放弃入口 → 第 2 组断言失败。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      c.leave();
      const c2: WithdrawController = await openWithdraw(f);
      expect(c2.snapshot.inFlightElsewhere).assertTrue();
      expect(c2.canSubmit).assertFalse();
      expect(c2.snapshot.pending).assertNull();
      // 原请求超时：未决记录结算为结果未知 → 当前页面重新同步出待确认卡（旧页面不改新页面，只通知）
      f.held[f.held.length - 1].resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.SUBMITTING);
      expect(c2.snapshot.pending !== null).assertTrue();
      expect(c2.snapshot.inFlightElsewhere).assertFalse();
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      expect(c2.layout().pendingCard).assertTrue();
      // 新页面可以确认：原键原体
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(0, withdrawal('W9', 'PENDING_REVIEW', 1000,
        '2026-10-12T10:30:00+08:00', ',"channel_order_id":null')));
      const p: PendingView = c2.snapshot.pending as PendingView;
      expect(c2.confirm(c2.snapshot.pendingVersion, p.key)).assertTrue();
      await settle();
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.DONE);
    });

    it('R1_01_payout_late_result_resyncs_reentered_page', 0, async () => {
      // 旧逻辑：收款账号页同样没有订阅，重新进入的页面停在「别处在途」，待确认卡不出现。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => null);
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', 'zhangsan@example.com');
      p.setField('payee_name', '测试三');
      expect(p.save()).assertTrue();
      await settle();
      p.leave();
      const p2: PayoutAccountController = new PayoutAccountController(f.deps());
      p2.onShown();
      await settle();
      expect(p2.snapshot.inFlightElsewhere).assertTrue();
      expect(p2.canSave).assertFalse();
      f.held[f.held.length - 1].resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      await settle();
      expect(p2.snapshot.pending !== null).assertTrue();
      expect(p2.snapshot.phase).assertEqual(PayoutPhase.PENDING);
      expect(p2.layout().pendingCard).assertTrue();
    });

    it('R1_02_pending_card_independent_of_rules_and_payout_read_failure', 0, async () => {
      // 旧逻辑：页面在 view=null（rules 读取失败）时只渲染错误态与【重试】，PayoutAccountView 的 ERROR 分支同样隐藏待确认卡；
      // 分区由页面自己判断，没有可核对的出口。现在页面按 layout() 渲染：错误态与待确认卡同时出现，确认 / 放弃可用。
      const f: WalletFixture = new WalletFixture();
      await pendingWithdraw(f);
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(50001, '{}'));
      const c2: WithdrawController = await openWithdraw(f);
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.ERROR);
      expect(c2.view()).assertNull();
      const layout: FundPageLayout = c2.layout();
      expect(layout.body).assertEqual(FundPageLayout.ERROR);
      expect(layout.pendingCard).assertTrue();
      // 确认得到 20901（键不结束）：仍是错误态 + 待确认卡，不变成没有 rules 的编辑态
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(20901, '{}'));
      const key: string = (c2.snapshot.pending as PendingView).key;
      expect(c2.confirm(c2.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(c2.layout().pendingCard).assertTrue();
      expect(c2.layout().body).assertEqual(FundPageLayout.ERROR);
      // 放弃：同样可用（按自己的闸门与在途状态）
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) => envelope(0, '{"outcome":"abandoned","original":null}'));
      expect(c2.abandon(c2.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(c2.snapshot.pending).assertNull();
      expect(c2.layout().body).assertEqual(FundPageLayout.ERROR);

      // 收款账号页：账号读取 5xxxx → 错误态，待确认卡仍显示
      const g: WalletFixture = new WalletFixture();
      g.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      g.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      g.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      g.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(g.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', 'zhangsan@example.com');
      p.setField('payee_name', '测试三');
      p.save();
      await settle();
      expect(p.snapshot.pending !== null).assertTrue();
      g.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(50001, '{}'));
      const p2: PayoutAccountController = new PayoutAccountController(g.deps());
      p2.onShown();
      await settle();
      expect(p2.snapshot.phase).assertEqual(PayoutPhase.ERROR);
      expect(p2.layout().body).assertEqual(FundPageLayout.ERROR);
      expect(p2.layout().pendingCard).assertTrue();
      expect(p2.confirm(p2.snapshot.pendingVersion, (p2.snapshot.pending as PendingView).key)).assertTrue();
    });

    it('R1_03_records_focus_detail_42901_starts_shared_gate_and_keeps_retry', 0, async () => {
      // 旧逻辑：定位详情失败因 focus=true 跳过 failure()，42901 不启动共享读闸门，刷新照样发送；也没有失败提示与重试入口。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open('W3');
      await settle();
      expect(f.session.readGate.active).assertTrue();
      expect(c.snapshot.focusError !== null).assertTrue();
      const lists: number = f.count('/v1/withdrawals');
      expect(c.refresh()).assertFalse();
      expect(f.count('/v1/withdrawals')).assertEqual(lists);
      expect(c.retryFocus()).assertFalse();
      // 闸门过期后可重试，成功定位
      f.nowMs += 31000;
      f.rig.nowMillis = f.nowMs;
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W3', 'FAILED', 800,
        '2026-10-08T11:30:00+08:00', ',"channel_order_id":null')));
      expect(c.retryFocus()).assertTrue();
      await settle();
      expect(c.snapshot.focusError).assertNull();
      expect(c.isExpanded('W3')).assertTrue();
      // 展开项详情 5xxxx：带 trace6 的失败提示与重试入口
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(50001, '{}'));
      expect(c.toggle('W2', c.snapshot.version)).assertTrue();
      await settle();
      expect((c.detailError('W2') as WalletMessage).text).assertContain('123456');
      expect(c.retryDetail('W2', c.snapshot.version)).assertTrue();
    });

    it('R1_03_withdraw_payout_read_and_getme_failures_handled', 0, async () => {
      // 旧逻辑：提现页 getPayoutAccount 失败直接 return（5xxxx 没有 trace6、42901 不进共享闸门）；钱包页 getMe 失败同样忽略。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(50001, '{}'));
      const c: WithdrawController = await openWithdraw(f);
      expect(c.snapshot.payoutLine).assertNull();
      expect((c.snapshot.payoutError as WalletMessage).text).assertContain('123456');
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '20' }));
      expect(c.retryPayout()).assertTrue();
      await settle();
      expect(f.session.readGate.active).assertTrue();
      expect(c.retryPayout()).assertFalse();
      // 30304（未实名）：rules 会引导，收款账号行静默
      const g: WalletFixture = new WalletFixture();
      g.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(30304, '{}'));
      const c3: WithdrawController = await openWithdraw(g);
      expect(c3.snapshot.payoutError).assertNull();
      // 钱包页 getMe 42901：共享读闸门生效（刷新不再发）
      const h: WalletFixture = new WalletFixture();
      h.reply('/v1/me', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      h.session.sync();
      const w: WalletController = new WalletController(h.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect(h.session.readGate.active).assertTrue();
      expect(w.refresh()).assertFalse();
      // getMe 5xxxx：摘要照常，轻提示带 trace6
      const k: WalletFixture = new WalletFixture();
      k.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      k.session.sync();
      const w2: WalletController = new WalletController(k.deps());
      w2.load();
      await settle();
      expect(w2.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect((w2.snapshot.notice as WalletMessage).text).assertContain('123456');
    });

    it('R1_04_render_bound_values_rejected_when_stale', 0, async () => {
      // 旧逻辑：页面回调在点击时读 model.version（最新），且控制器只核对版本，不核对构建时显示的金额 / 未决键 / 路由 / 流水号；
      // 新 rules 已到、画面未重绘时旧【全部提现】按新版本填入新金额。现在按钮把构建时的版本与对应数据一起交给控制器核对。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      const v1: number = c.snapshot.version;
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(0, rulesJson(null, '{"max_withdrawable_fen":500}')));
      c.onShown();
      await settle();
      const v2: number = c.snapshot.version;
      expect(v2 > v1).assertTrue();
      expect(c.fillAll(v1, 1200)).assertFalse();
      expect(c.fillAll(v2, 1200)).assertFalse();
      expect(c.snapshot.inputText).assertEqual('');
      expect(c.fillAll(v2, 500)).assertTrue();
      expect(c.snapshot.inputText).assertEqual('5');
      // 待确认：构建时的未决键不符不发
      const g: WalletFixture = new WalletFixture();
      const p: WithdrawController = await pendingWithdraw(g);
      const sent: number = g.count('POST /v1/withdrawals');
      expect(p.confirm(p.snapshot.pendingVersion, 'stale-key')).assertFalse();
      expect(p.abandon(p.snapshot.pendingVersion, 'stale-key')).assertFalse();
      expect(g.count('POST /v1/withdrawals')).assertEqual(sent);
      // 引导按钮：构建时的目标路由不符不打开
      const h: WalletFixture = new WalletFixture();
      h.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(0,
        rulesJson(null, '{"can_withdraw":false,"block_code":30305}')));
      const gw: WithdrawController = await openWithdraw(h);
      expect(gw.openGuide(gw.snapshot.version, 'RealName')).assertFalse();
      expect(gw.openGuide(gw.snapshot.version, 'PayoutAccount')).assertTrue();
      // 提现记录【复制】：构建时显示的流水号与当前不符不写剪贴板
      const k: WalletFixture = new WalletFixture();
      k.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W2', 'PAID_API', 500,
        '2026-09-27T15:20:00+08:00', ',"channel_order_id":"20260928200040011100"')));
      k.session.sync();
      const r: WithdrawRecordsController = new WithdrawRecordsController(k.deps());
      r.open('W2');
      await settle();
      expect(await r.copy('W2', r.snapshot.version, '20260928200040011199')).assertEqual('not_copyable');
      expect(k.board.writes).assertEqual(0);
      expect(await r.copy('W2', r.snapshot.version, '20260928200040011100')).assertEqual('done');
    });

    it('R1_05_wallet_cache_mark_tmp_file_blocks_after_restart_and_settles_before_read', 0, () => {
      // 回归保护（R1-05 按 APP-08 订单缓存的做法收口，代码与 OrderStaleCache 同口径）：标记经真实 FileSlot 写入，临时文件已落盘但
      // 改名失败、同时删除失败 → 重启后的新实例按待清理阻断读取；故障解除后读之前先补删。标记与删除「都」写不进的多重故障残余
      // 不在这里追求，登记 rule-gaps 鸿蒙段 H19，归 F-AND-25（持久化登录世代）。
      const ops: MarkOps = new MarkOps();
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      store.mark = new OrderPendingMark(new FileSlot(MARK_PATH, ops));
      let account: string | null = 'user-1';
      const summary: WalletRecord = JSON.parse(summaryJson()) as WalletRecord;
      const first: WalletStaleCache = new WalletStaleCache(store, (): string | null => account, (): number => NOW);
      first.save(summary);
      expect(first.load() !== null).assertTrue();
      account = null;
      ops.failRename = true;
      store.failClear = true;
      expect(first.clear()).assertFalse();
      expect(ops.files.has(FileSlot.tempOf(MARK_PATH))).assertTrue();
      account = 'user-1';
      const restarted: WalletStaleCache = new WalletStaleCache(store, (): string | null => account, (): number => NOW);
      expect(restarted.blocked).assertTrue();
      expect(restarted.load()).assertNull();
      ops.failRename = false;
      store.failClear = false;
      const healed: WalletStaleCache = new WalletStaleCache(store, (): string | null => account, (): number => NOW);
      expect(healed.load()).assertNull();
      expect(store.files.size).assertEqual(0);
      expect(ops.files.has(MARK_PATH)).assertFalse();
      expect(ops.files.has(FileSlot.tempOf(MARK_PATH))).assertFalse();
      expect(healed.blocked).assertFalse();
    });

    it('R1_06_sms_resend_deadline_shared_across_reopened_panels', 0, async () => {
      // 旧逻辑：倒计时只在面板实例里；关闭重开后新面板倒计时为 0、打开即再发一次码（同一时刻两次）。发送在途时关闭重开同样会重发。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      const s1: StepUpController = c.createStepUp() as StepUpController;
      expect(s1.send()).assertTrue();
      await settle();
      expect(s1.snapshot.countdown).assertEqual(60);
      s1.close();
      const s2: StepUpController = c.createStepUp() as StepUpController;
      expect(s2.snapshot.sent).assertTrue();
      expect(s2.snapshot.countdown > 0).assertTrue();
      expect(s2.send()).assertFalse();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(1);
      s2.close();
      // 截止时间过后可以再发
      f.nowMs += 61000;
      f.rig.nowMillis = f.nowMs;
      // 发送在途时关闭重开：不发第二次；在途结果回来后（面板已关）仍记下截止时间
      f.reply('/v1/auth/sms-codes', (_r: TransportRequest) => null);
      const s3: StepUpController = c.createStepUp() as StepUpController;
      expect(s3.send()).assertTrue();
      s3.close();
      const s4: StepUpController = c.createStepUp() as StepUpController;
      expect(s4.send()).assertFalse();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(2);
      const d: Deferred = f.held[f.held.length - 1];
      d.resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      await settle();
      s4.close();
      const s5: StepUpController = c.createStepUp() as StepUpController;
      expect(s5.snapshot.countdown > 0).assertTrue();
      expect(s5.send()).assertFalse();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(2);
      // 不同 action（收款账号）不受影响
      expect(f.session.sms.remainingMs('user-1|13800005678|payout_account_change', f.nowMs)).assertEqual(0);
    });

    it('R1_07_refresh_refetches_focus_and_expanded_details', 0, async () => {
      // 旧逻辑：placeFocus 优先用缓存详情（首次的 PENDING_REVIEW），刷新不重取定位单与展开项的详情 → 状态与流水号一直是旧的。
      const f: WalletFixture = new WalletFixture();
      let paid: boolean = false;
      f.reply('/v1/withdrawals', (_r: TransportRequest) => envelope(0, '{"items":[' + [
        withdrawal('W1', paid ? 'PAID_API' : 'PENDING_REVIEW', 1000, '2026-10-12T10:30:00+08:00'),
        withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00')
      ].join(',') + '],"next_cursor":null}'));
      f.reply('/v1/withdrawals/:id', (r: TransportRequest) => pathOf(r).endsWith('/W1')
        ? envelope(0, withdrawal('W1', paid ? 'PAID_API' : 'PENDING_REVIEW', 1000, '2026-10-12T10:30:00+08:00',
          paid ? ',"channel_order_id":"20261012000000000001"' : ',"channel_order_id":null'))
        : envelope(0, withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00',
          paid ? ',"channel_order_id":"20260928000000000002"' : ',"channel_order_id":null')));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open('W1');
      await settle();
      expect(c.snapshot.items[0]['status'] as string).assertEqual('PENDING_REVIEW');
      expect(c.toggle('W2', c.snapshot.version)).assertTrue();
      await settle();
      expect(c.tradeNo('W2')['show'] === true).assertFalse();
      paid = true;
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.items[0]['withdrawal_id'] as string).assertEqual('W1');
      expect(c.snapshot.items[0]['status'] as string).assertEqual('PAID_API');
      expect(c.tradeNo('W1')['copyText'] as string).assertEqual('20261012000000000001');
      expect(c.tradeNo('W2')['copyText'] as string).assertEqual('20260928000000000002');
    });

    it('R1_08_refresh_during_load_more_resets_paging', 0, async () => {
      // 旧逻辑：翻页在途时下拉刷新开启新轮次，旧翻页响应按序号丢弃，但 loadingMore 一直为 true，loadMore 永远返回 false。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals', (r: TransportRequest) => r.url.indexOf('cursor=') >= 0 ? null
        : envelope(0, '{"items":[' + withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00')
          + '],"next_cursor":"c2"}'));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open(null);
      await settle();
      expect(c.snapshot.hasMore).assertTrue();
      expect(c.loadMore()).assertTrue();
      expect(c.snapshot.loadingMore).assertTrue();
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.phase).assertEqual(RecordsPhase.CONTENT);
      expect(c.snapshot.loadingMore).assertFalse();
      expect(c.snapshot.hasMore).assertTrue();
      expect(c.loadMore()).assertTrue();
    });

    it('R1_09_stale_getme_cannot_overwrite_newer_realname', 0, async () => {
      // 旧逻辑：getMe 只按账号与 scope 核对，不绑页面与请求世代；旧响应（none）晚到，在钱包出栈后把共享实名状态改回 none。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me', (_r: TransportRequest) => null);
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      const stale: Deferred = f.held[f.held.length - 1];
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, '{"realname_status":"verified"}'));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(f.session.realname.verified('user-1')).assertTrue();
      w.leave();
      stale.resolve(envelope(0, '{"realname_status":"none"}'));
      await settle();
      expect(f.session.realname.verified('user-1')).assertTrue();
      // 实名提交成功之后，之前在途的旧查询（none）也不能改回去
      const g: WalletFixture = new WalletFixture();
      g.reply('/v1/me', (_r: TransportRequest) => null);
      g.contract = new OkContract();
      g.session.sync();
      const w2: WalletController = new WalletController(g.deps());
      w2.load();
      await settle();
      const old: Deferred = g.held[g.held.length - 1];
      const rn: RealNameController = new RealNameController(g.deps());
      rn.setName('测试三');
      rn.setIdNo('00000000000000000x');
      expect(rn.requestSubmit()).assertTrue();
      rn.setConsentChecked(true);
      expect(rn.agreeAndSubmit()).assertTrue();
      await settle();
      expect(g.session.realname.verified('user-1')).assertTrue();
      old.resolve(envelope(0, '{"realname_status":"none"}'));
      await settle();
      expect(g.session.realname.verified('user-1')).assertTrue();
    });

    it('R1_10_30306_blocks_submit_until_newer_rules_allow', 0, async () => {
      // 旧逻辑：30306 后恢复 EDITING 并重取 rules；重取失败时保留旧 rules（can_withdraw=true），canSubmit 又变成 true。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(30306, '{}'));
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(50001, '{}'));
      expect(c.submit()).assertTrue();
      await settle();
      expect(c.snapshot.serverBlocked).assertTrue();
      expect(c.canSubmit).assertFalse();
      expect((c.guide() as WalletRecord)['textKey'] as string).assertEqual('error.30306');
      // 输入变化触发的估算失败：仍阻断
      c.setInput('5');
      await settle();
      expect(c.canSubmit).assertFalse();
      // 之后成功取到、明确允许的 rules：解除
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(0, rulesJson(500)));
      c.onShown();
      await settle();
      expect(c.snapshot.serverBlocked).assertFalse();
      expect(c.canSubmit).assertTrue();
    });

    it('R1_11_step_up_sheet_fits_above_keyboard_for_any_height', 0, () => {
      // 旧做法：bindSheet FIT_CONTENT + TRANSLATE_AND_RESIZE，半屏只上移到验证码格露出，倒计时与【验证并提交】在键盘下面（截图
      // WithdrawStepUp）。现在面板最大高按键盘后的可用高度算、下方垫键盘占位：面板 + 占位 + 顶部留白不超过视口，任何键盘高度下
      // 底部操作区都在键盘上沿之上；极端短视口保底 MIN_PANEL（只压缩中段）。
      const viewport: number = 873;
      const top: number = 38;
      const bottom: number = 28;
      for (const kb of [0, 260, 296, 340, 420]) {
        const panel: number = StepUpSheetFit.maxPanel(viewport, top, bottom, kb);
        expect(panel + StepUpSheetFit.spacer(kb) + top + StepUpSheetFit.TOP_GAP + bottom <= viewport).assertTrue();
        expect(panel >= StepUpSheetFit.MIN_PANEL).assertTrue();
      }
      expect(StepUpSheetFit.maxPanel(873, 38, 28, 296) > StepUpSheetFit.maxPanel(873, 38, 28, 420)).assertTrue();
      expect(StepUpSheetFit.maxPanel(480, 38, 28, 296)).assertEqual(StepUpSheetFit.MIN_PANEL);
      expect(StepUpSheetFit.maxPanel(0, 0, 0, 296)).assertEqual(StepUpSheetFit.FALLBACK_PANEL);
      // 中段：放得下取自然高；放不下压缩到可用高；极端短视口不低于一行验证码格（不超过自然高）
      expect(StepUpSheetFit.middle(404, 30, 100, 72, 76, 58)).assertEqual(76);
      expect(StepUpSheetFit.middle(404, 190, 125, 72, 98, 58)).assertEqual(58);
      expect(StepUpSheetFit.middle(160, 30, 100, 72, 76, 58)).assertEqual(58);
      expect(StepUpSheetFit.middle(160, 30, 100, 72, 40, 58)).assertEqual(40);
      expect(StepUpSheetFit.spacer(0)).assertEqual(0);
      expect(StepUpSheetFit.spacer(295.4)).assertEqual(296);
    });
  });

  describe('APP09_HarmonyLessons13to25', () => {
    it('lesson14_confirm_abandon_carry_click_account_epoch_and_key', 0, async () => {
      // 旧逻辑：确认 / 放弃不带点击时的身份，执行时只按当前会话与键走；会话换代后用旧点击发出。现在占用记录前与每次发包前核对。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await pendingWithdraw(f);
      const key: string = (c.snapshot.pending as PendingView).key;
      const click: PendingClick = new PendingClick('user-1', f.session.epoch, key);
      const sent: number = f.count('POST /v1/withdrawals');
      f.switchAccount('user-2');
      const step: SensitiveStep = await c.flow.confirm(key, null, click);
      expect(step.textKey as string).assertEqual('pending_confirm.retry_later');
      const abandon: SensitiveStep = await c.flow.abandon(key, click);
      expect(abandon.textKey as string).assertEqual('pending_confirm.retry_later');
      expect(f.count('POST /v1/withdrawals')).assertEqual(sent);
      expect(f.count('/v1/idempotency-keys/abandon')).assertEqual(0);
      // 键与点击不符同样不发
      f.switchAccount('user-1');
      const c2: WithdrawController = await openWithdraw(f);
      const wrong: SensitiveStep = await c2.flow.confirm(key, null, new PendingClick('user-1', f.session.epoch, 'other-key'));
      expect(wrong.textKey as string).assertEqual('pending_confirm.retry_later');
      expect(f.count('POST /v1/withdrawals')).assertEqual(sent);
    });

    it('lesson16_step_up_replay_budget_per_user_confirm', 0, async () => {
      // 旧逻辑：replayedKey 只在键结束时清；同一键二次验证后又得 10003，之后用户每次点确认都不再弹面板（预算永久用尽）。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await pendingWithdraw(f);
      f.session.tokens.onSuccess('withdraw');
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(10003, '{}'));
      expect(c.confirm(c.snapshot.pendingVersion)).assertTrue();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      const before: number = f.count('POST /v1/withdrawals');
      await passStepUp(c);
      // 二次验证后原键续发一次，又得 10003：不再弹面板，保持待确认
      expect(f.count('POST /v1/withdrawals')).assertEqual(before + 1);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      expect(c.snapshot.stepUpAction).assertNull();
      // 用户再点确认：新的一次预算，10003 重新打开二次验证
      expect(c.confirm(c.snapshot.pendingVersion)).assertTrue();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
    });

    it('lesson18_abandon_10004_guides_and_keeps_key', 0, async () => {
      // 放弃分支得到 10004（劳务协议）：打开对应页，未决键保留，回来等用户再点。
      const f: WalletFixture = new WalletFixture();
      f.router.open(RouteRequest.of('Withdraw', RouteSource.IN_APP));
      const c: WithdrawController = await pendingWithdraw(f);
      const key: string = (c.snapshot.pending as PendingView).key;
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) =>
        envelope(10004, '{"consent_type":"labor_agreement"}'));
      expect(c.abandon(c.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('LaborAgreement');
      expect((c.snapshot.pending as PendingView).key).assertEqual(key);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
    });

    it('lesson19_payout_line_old_response_not_overwrite', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      const old: Deferred = f.held[f.held.length - 1];
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{"payout_method":"bank_card",'
        + '"masked_account":"尾号 0009","bank_name":"示例银行","masked_payee_name":"**三","change_remaining_this_month":1}'));
      c.onShown();
      await settle();
      const fresh: string = c.snapshot.payoutLine as string;
      expect(fresh.indexOf('0009') >= 0).assertTrue();
      old.resolve(envelope(0, ALIPAY));
      await settle();
      expect(c.snapshot.payoutLine as string).assertEqual(fresh);
    });

    it('lesson20_no_paging_before_first_page_and_latest_detail_only', 0, async () => {
      // 旧逻辑：刷新在途时还能用旧游标翻页；同一单的两次详情谁晚到用谁。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals', (r: TransportRequest) => envelope(0, '{"items":['
        + withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00') + '],"next_cursor":"c2"}'));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open(null);
      await settle();
      f.reply('/v1/withdrawals', (_r: TransportRequest) => null);
      expect(c.refresh()).assertTrue();
      expect(c.loadMore()).assertFalse();
      await settle();
      expect(c.loadMore()).assertFalse();
      f.held[f.held.length - 1].resolve(envelope(0, '{"items":['
        + withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00') + '],"next_cursor":"c3"}'));
      await settle();
      // 同一单详情：第一次挂起，收起再展开发第二次；第一次晚到不覆盖
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => null);
      expect(c.toggle('W2', c.snapshot.version)).assertTrue();
      await settle();
      const first: Deferred = f.held[f.held.length - 1];
      expect(c.toggle('W2', c.snapshot.version)).assertTrue();
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W2', 'PAID_API', 500,
        '2026-09-27T15:20:00+08:00', ',"channel_order_id":"NEW000000000000000002"')));
      expect(c.toggle('W2', c.snapshot.version)).assertTrue();
      await settle();
      first.resolve(envelope(0, withdrawal('W2', 'PAID_API', 500, '2026-09-27T15:20:00+08:00',
        ',"channel_order_id":"OLD000000000000000001"')));
      await settle();
      expect(c.tradeNo('W2')['copyText'] as string).assertEqual('NEW000000000000000002');
    });

    it('lesson21_unknown_realname_queries_before_withdraw_and_failure_does_not_navigate', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      let opened: number = 0;
      expect(w.requestWithdraw((): void => {
        opened++;
      })).assertTrue();
      await settle();
      expect(opened).assertEqual(0);
      expect((w.snapshot.notice as WalletMessage).text).assertContain('123456');
      f.reply('/v1/me', (_r: TransportRequest) => envelope(0, '{"realname_status":"verified"}'));
      w.requestWithdraw((): void => {
        opened++;
      });
      await settle();
      expect(opened).assertEqual(1);
      expect(f.session.realname.verified('user-1')).assertTrue();
      // 出栈后迟到的查询不导航
      const g: WalletFixture = new WalletFixture();
      g.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      g.session.sync();
      const w2: WalletController = new WalletController(g.deps());
      w2.load();
      await settle();
      g.reply('/v1/me', (_r: TransportRequest) => null);
      let opened2: number = 0;
      w2.requestWithdraw((): void => {
        opened2++;
      });
      w2.leave();
      if (g.held.length > 0) {
        g.held[g.held.length - 1].resolve(envelope(0, '{"realname_status":"verified"}'));
      }
      await settle();
      expect(opened2).assertEqual(0);
    });

    it('lesson22_risk_frozen_keeps_withdraw_enabled', 0, async () => {
      // G11 更正：风控冻结不置灰；负余额与 withdraw_enabled=false 仍置灰。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson('{"risk_paused_reason":"fixture_reason"}')));
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.withdrawAllowed).assertTrue();
      const v: WalletRecord = WalletSummaryView.of(w.snapshot.summary as WalletRecord, false, NOW);
      expect(((v['withdrawButton'] as WalletRecord)['enabled'] as boolean)).assertTrue();
      expect(((v['riskBanner'] as WalletRecord)['show'] as boolean)).assertTrue();
    });

    it('lesson23_blocked_rules_still_refetch_with_amount', 0, async () => {
      // rules 是否重取只看金额与输入是否允许，不被旧 can_withdraw=false 挡住（30305 时金额框可输入，G29）。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals/rules', (r: TransportRequest) => envelope(0, queryOfReq(r).indexOf('amount_fen=500') >= 0
        ? rulesJson(500) : rulesJson(null, '{"can_withdraw":false,"block_code":30305}')));
      const c: WithdrawController = await openWithdraw(f);
      expect(c.snapshot.rules?.['can_withdraw'] as boolean).assertFalse();
      expect(c.setInput('5')).assertTrue();
      await sleep(650);
      await settle();
      expect(f.rig.server.received.filter((r: TransportRequest): boolean => pathOf(r) === '/v1/withdrawals/rules'
        && queryOfReq(r).indexOf('amount_fen=500') >= 0).length).assertEqual(1);
      expect(c.snapshot.rules?.['can_withdraw'] as boolean).assertTrue();
    });
  });
}
