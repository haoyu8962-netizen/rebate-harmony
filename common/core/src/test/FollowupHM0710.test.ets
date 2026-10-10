// FU-HM-0710 鸿蒙回头补课：APP-09 残余 F-HM-19/20/21、APP-09 共性第 39–48 条、APP-08 共性第 30–35 条（订单）、
// APP-07 共性第 32 条（剪贴板购买状态的映射见 designsystem FollowupHM0710）。真实 ApiClient + 本地假服务，不连任何地址、不做真实提现。
// 每个用例的注释写明「按旧逻辑为何失败」。
import { describe, it, expect } from '@ohos/hypium';
import {
  OpenPurchaseController, OrderAnchorKeeper, OrderDetailController, OrderDetailSnapshot, OrderListConditions,
  OrderListController, OrderPhase, OrderRecord, OrderScrollAnchor, PayoutAccountController, PayoutAccountForm, PayoutPhase,
  PendingClick, SmsResendClock, SmsSendOutcome, TransportFailure, TransportRequest, TransportResponse, WalletController,
  WithdrawController, WithdrawPhase, WithdrawRecordsController, OwnPageExit, OrderPageRestorer, OrderPageState,
  OrderStaleCache, OrderCacheCleaner, LocalDataCleanerRegistry, PrivacyWithdrawalCleaners, CleanReport,
  PendingTrackController, PendingTrackJumpWatcher, PendingView, OrderPageStateKv, OrderPageStateStore,
  RealNameController, LaborAgreementController, SessionTokenSet, RouteRequest, RouteSource, RouteDestination,
  WalletPhase, RecordsPhase, WalletContractPort, WalletRecord, ApiResult, ApiOutcome, WalletMessage
} from '../../Index';
import { envelope, flush } from './NetworkTestRig';
import {
  NOW, openWithdraw, queryOfReq, rulesJson, settle, summaryJson, WalletFixture, withdrawal
} from './WalletIntegration.test';
import { detail, OrderFixture, order, page, pending, rec } from './OrderIntegration.test';
import { card, FAR_FUTURE, Fixture, openOk, settle as settlePurchase } from './OpenPurchaseIntegration.test';

const CREATED: string = '2026-10-12T10:30:00+08:00';

function count(names: string[], name: string): number {
  return names.filter((n: string): boolean => n === name).length;
}

/** 页面恢复记录的内存键值存储（R2-01）：可注入读取 / 删除失败。 */
class MemPageKv implements OrderPageStateKv {
  readonly map: Map<string, string> = new Map<string, string>();
  failGet: boolean = false;
  failRemove: boolean = false;

  get(key: string): string | null {
    if (this.failGet) {
      throw new Error('get failed');
    }
    return this.map.get(key) ?? null;
  }

  put(key: string, value: string): void {
    this.map.set(key, value);
  }

  remove(key: string): void {
    if (this.failRemove) {
      throw new Error('remove failed');
    }
    this.map.delete(key);
  }
}

/** 实名与劳务协议待定接口的计数替身（共性第 52 条）。 */
class CountingContract implements WalletContractPort {
  realnameCalls: number = 0;
  signCalls: number = 0;

  private ok(data: Record<string, Object>): Promise<ApiResult> {
    return Promise.resolve(new ApiResult(ApiOutcome.SUCCESS, 0, '', data, 'trace-wallet-abc123', 200,
      TransportFailure.NONE, null, null, null));
  }

  submitRealname(_name: string, _idNo: string): Promise<ApiResult> {
    this.realnameCalls++;
    return this.ok({});
  }

  getLaborAgreement(): Promise<ApiResult> {
    const d: Record<string, Object> = {};
    d['version'] = 'v1';
    d['text'] = 'fixture agreement text';
    d['text_sha256'] = 'fixture-sha';
    d['need_sign'] = true;
    return this.ok(d);
  }

  signLaborAgreement(_version: string, _sha: string): Promise<ApiResult> {
    this.signCalls++;
    return this.ok({});
  }
}

function itemOf(items: WalletRecord[], id: string): WalletRecord | undefined {
  return items.find((i: WalletRecord): boolean => i['withdrawal_id'] === id);
}

export default function followupHM0710Test() {
  describe('FollowupHM0710', () => {
    it('F_HM_19_load_more_inserts_detail_accepted_in_same_round', 0, async () => {
      // 旧逻辑：刷新后列表只含第一页、重取 W2 详情；翻页在途时详情先回来（PAID_API + 流水号），翻页随后返回 PENDING_REVIEW 摘要并直接
      // push → 同一卡片「审核中」却显示到账流水号（status 断言为 PENDING_REVIEW）。
      const f: WalletFixture = new WalletFixture();
      const first: string = '{"items":[' + withdrawal('W1', 'PAID_API', 500, CREATED) + '],"next_cursor":"c2"}';
      const second: string = '{"items":[' + withdrawal('W2', 'PENDING_REVIEW', 800, '2026-10-01T10:00:00+08:00')
        + '],"next_cursor":null}';
      f.reply('/v1/withdrawals', (r: TransportRequest) => envelope(0, queryOfReq(r).indexOf('cursor=') >= 0 ? second : first));
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W2', 'PENDING_REVIEW', 800,
        '2026-10-01T10:00:00+08:00')));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open(null);
      await settle();
      expect(c.loadMore()).assertTrue();
      await settle();
      expect(c.toggle('W2', c.snapshot.version)).assertTrue();
      await settle();
      expect(c.snapshot.items.length).assertEqual(2);
      // 下拉刷新：列表成功（只有第一页），W2 详情重取挂起
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => null);
      expect(c.refresh()).assertTrue();
      await settle();
      expect(c.snapshot.items.length).assertEqual(1);
      const detailHeld: number = f.held.length - 1;
      // 翻页挂起
      f.reply('/v1/withdrawals', (_r: TransportRequest) => null);
      expect(c.loadMore()).assertTrue();
      await settle();
      const pageHeld: number = f.held.length - 1;
      // 详情先回来：已到账 + 流水号
      f.held[detailHeld].resolve(envelope(0, withdrawal('W2', 'PAID_API', 800, '2026-10-01T10:00:00+08:00',
        ',"channel_order_id":"20261001000000000002"')));
      await settle();
      // 翻页随后返回旧摘要
      f.held[pageHeld].resolve(envelope(0, second));
      await settle();
      const w2: Record<string, Object | null> | undefined = c.snapshot.items.find((i: Record<string, Object | null>):
      boolean => i['withdrawal_id'] === 'W2');
      expect(w2 !== undefined).assertTrue();
      expect((w2 as Record<string, Object | null>)['status'] as string).assertEqual('PAID_API');
      expect(c.tradeNo('W2')['copyText'] as string).assertEqual('20261001000000000002');
    });

    it('F_HM_20_focus_only_on_visible_error_field_else_banner', 0, async () => {
      // 旧逻辑：页面按全部字段顺序取第一个出错字段，fields=[alipay_logon_id, card_no] 在银行卡方式下选中隐藏的 alipay_logon_id，
      // 焦点请求 payout_alipay_logon_id（不存在）。现在只从可见字段选；没有可见出错字段时为 null（焦点落到错误条 payout_banner）。
      expect(PayoutAccountForm.firstVisibleErrorField(['alipay_logon_id', 'card_no'], 'bank_card')).assertEqual('card_no');
      expect(PayoutAccountForm.firstVisibleErrorField(['alipay_logon_id'], 'bank_card')).assertNull();
      expect(PayoutAccountForm.firstVisibleErrorField(['card_no', 'payout_method'], 'alipay')).assertEqual('payout_method');
      expect(PayoutAccountForm.BANNER_ID).assertEqual('payout_banner');
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(20001,
        '{"fields":["alipay_logon_id","card_no"]}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setMethod('bank_card');
      p.setField('card_no', '6222 0000 0000 0009');
      p.setField('bank_name', '示例银行');
      p.setField('payee_name', '测试三');
      expect(p.save()).assertTrue();
      await settle();
      // 卡号可见：焦点落卡号，不出错误条（不重复播报）
      expect(p.snapshot.banner).assertNull();
      expect(PayoutAccountForm.firstVisibleErrorField(Array.from(p.snapshot.fieldErrors.keys()), p.snapshot.form.method))
        .assertEqual('card_no');
      expect(PayoutAccountForm.errorFocusId('card_no', 'bank_card')).assertEqual('payout_card_no');
      // 只有隐藏字段：错误条出现，可见出错字段为 null → 焦点目标是错误条
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(20001, '{"fields":["alipay_logon_id"]}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      expect(p.save()).assertTrue();
      await settle();
      expect(p.snapshot.banner !== null).assertTrue();
      expect(PayoutAccountForm.firstVisibleErrorField(Array.from(p.snapshot.fieldErrors.keys()), p.snapshot.form.method))
        .assertNull();
    });

    it('F_HM_21_withdraw_late_guide_after_leave_and_return_does_not_navigate', 0, async () => {
      // 旧逻辑：提交挂起 → 进收款账号页 → 返回（onShown 把 visible 恢复为 true）→ 原请求才返回 30304 → 立即打开 RealName。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      c.openPayout();
      c.onHidden();
      c.onShown();
      await settle();
      f.held[held].resolve(envelope(30304, '{}'));
      await settle();
      expect(f.stack.names.indexOf('RealName')).assertEqual(-1);
      // 状态已结算：引导条仍在（手动入口）
      expect(c.snapshot.banner !== null).assertTrue();
      expect(c.snapshot.phase === WithdrawPhase.SUBMITTING).assertFalse();
      // 页面一直可见、没发生导航：照常自动打开（不误伤）
      const g: WalletFixture = new WalletFixture();
      g.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      g.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(30304, '{}'));
      const c2: WithdrawController = await openWithdraw(g);
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      expect(g.stack.names.indexOf('RealName') >= 0).assertTrue();
    });

    it('F_HM_21_payout_late_guide_after_leave_and_return_does_not_navigate', 0, async () => {
      // 旧逻辑：保存挂起 → 打开实名页 → 返回 → 迟到的 30304 再次自动导航到 RealName（同一页面出现两次）。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => null);
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', '13800135678');
      p.setField('payee_name', '测试三');
      expect(p.save()).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      p.openRealName();
      p.onHidden();
      p.onShown();
      await settle();
      expect(count(f.stack.names, 'RealName')).assertEqual(1);
      f.held[held].resolve(envelope(30304, '{}'));
      await settle();
      expect(count(f.stack.names, 'RealName')).assertEqual(1);
      expect(p.snapshot.banner !== null).assertTrue();
      expect(p.snapshot.form.alipayLogonId).assertEqual('13800135678');
    });

    it('lesson41_deferred_results_consumed_when_back_before_arrival', 0, async () => {
      // 共性第 41 条：先回到本页、后收到结果——已登记的延后结果（二次验证面板、成功替换）按原键 / 页面 / 会话复核后立即消费，
      // 不挂到下一次 onShown。
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      c.openRecords();
      c.onHidden();
      c.onShown();
      await settle();
      f.held[f.held.length - 1].resolve(envelope(10003, '{}'));
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      expect(c.snapshot.stepUpAction as string).assertEqual(WithdrawController.STEP_UP_ACTION);
      // 成功：发起页已回到可见 → 立即以 WithdrawRecords 替换；替换前【提交】不可用（phase=DONE）
      const g: WalletFixture = new WalletFixture();
      g.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      g.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c2: WithdrawController = await openWithdraw(g);
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      const held: number = g.held.length - 1;
      c2.openPayout();
      c2.onHidden();
      c2.onShown();
      await settle();
      g.held[held].resolve(envelope(0, withdrawal('W7', 'PENDING_REVIEW', 1000, CREATED, ',"channel_order_id":null')));
      await settle();
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.DONE);
      expect(c2.canSubmit).assertFalse();
      expect(g.stack.names[g.stack.names.length - 1]).assertEqual('WithdrawRecords');
    });

    it('lesson39_submit_carries_click_identity_session_change_blocks_unsent', 0, async () => {
      // 共性第 39 条（S0）：旧逻辑首次提交不带点击身份，会话换代后仍按当前会话（B）读取凭据、登记未决并发送 A 的请求体
      // （POST 计数断言为 1）。现在点击时固定账号与会话世代，换代后本地拒绝、不登记、不发送。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      const click: PendingClick = new PendingClick('user-1', f.session.epoch, '');
      f.switchAccount('user-2');
      const sent: number = f.count('POST /v1/withdrawals');
      await c.flow.submit('{"amount_fen":1000}', '{"amount_fen":1000}', null, null, click);
      await settle();
      expect(f.count('POST /v1/withdrawals')).assertEqual(sent);
      expect(c.flow.pending()).assertNull();
      expect(c.flow.inFlightElsewhere()).assertFalse();
      // 二次验证后的原键重放同样核对（不改取当前会话）
      await c.flow.submit('{"amount_fen":1000}', '{"amount_fen":1000}', 'replay-key-1', 'fixture-step-token', click);
      await settle();
      expect(f.count('POST /v1/withdrawals')).assertEqual(sent);
      // 同一会话：照常发出（不误伤）
      const g: WalletFixture = new WalletFixture();
      g.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c2: WithdrawController = await openWithdraw(g);
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      expect(g.count('POST /v1/withdrawals')).assertEqual(1);
    });

    it('lesson40_sms_slot_release_bound_to_request_ticket', 0, () => {
      // 共性第 40 条：旧逻辑 finish(key) 无条件释放在途槽位——会话清空后同账号又发了新请求，旧请求迟到的结算把新请求的 sending
      // 解除并向新面板发布失败（sending 断言为 false）。
      const clock: SmsResendClock = new SmsResendClock();
      const key: string = SmsResendClock.key('user-1', '13800005678', 'withdraw');
      const t1: number = clock.begin(key, NOW);
      expect(t1 > 0).assertTrue();
      clock.clear();
      const t2: number = clock.begin(key, NOW);
      expect(t2 > 0 && t2 !== t1).assertTrue();
      let published: number = 0;
      const off: () => void = clock.subscribe(key, (_o: SmsSendOutcome): void => {
        published++;
      });
      clock.finish(key, null, new SmsSendOutcome(false, null), t1);
      expect(clock.sending(key)).assertTrue();
      expect(published).assertEqual(0);
      clock.finish(key, NOW + 60000, new SmsSendOutcome(true, null), t2);
      expect(clock.sending(key)).assertFalse();
      expect(published).assertEqual(1);
      expect(clock.remainingMs(key, NOW)).assertEqual(60000);
      off();
    });

    it('lesson43_payout_save_success_voids_earlier_read', 0, async () => {
      // 共性第 43 条：旧逻辑保存成功不推进读取世代，保存前发起、迟到的读取（旧账号 X）通过 seq 检查，把刚保存的新账号覆盖回去。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.VIEW);
      expect(p.startChange(p.snapshot.version)).assertTrue();
      // 一次读取挂起（服务端取到旧账号 X 后迟迟不回）
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => null);
      expect(p.retry()).assertTrue();
      await settle();
      const readHeld: number = f.held.length - 1;
      // 保存新账号 Y 成功
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{"payout_method":"alipay",'
        + '"masked_account":"139****0001","masked_payee_name":"**四","change_remaining_this_month":1}'));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      p.setField('alipay_logon_id', '13900000001');
      p.setField('payee_name', '测试四');
      expect(p.save()).assertTrue();
      await settle();
      expect((p.snapshot.account as Record<string, Object | null>)['masked_account'] as string).assertEqual('139****0001');
      // 旧读取迟到：不覆盖
      f.held[readHeld].resolve(envelope(0, '{"payout_method":"alipay","masked_account":"138****5678",'
        + '"masked_payee_name":"**三","change_remaining_this_month":2}'));
      await settle();
      expect((p.snapshot.account as Record<string, Object | null>)['masked_account'] as string).assertEqual('139****0001');
    });

    it('lesson45_estimate_blocked_by_gate_settles_with_retry', 0, async () => {
      // 共性第 45 条：估算被本地限流拦下时旧逻辑只隐藏估算、不给提示与重试（rulesError 断言为 null）。
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      expect(c.snapshot.rules !== null).assertTrue();
      f.session.readGate.start(30000);
      expect(c.fillQuick(500, c.snapshot.version)).assertTrue();
      await settle();
      expect(c.snapshot.estimate === 'calculating').assertFalse();
      expect(c.snapshot.estimate as string).assertEqual('hidden');
      expect(c.snapshot.rulesError !== null).assertTrue();
      // 禁用期过后重试：rules 成功，提示清除，估算恢复
      f.nowMs += 31000;
      f.rig.nowMillis = f.nowMs;
      expect(c.retryRules()).assertTrue();
      await settle();
      expect(c.snapshot.rulesError).assertNull();
      expect(c.snapshot.estimate === 'calculating').assertFalse();
    });

    it('lesson46_return_refresh_short_circuited_by_gate_marks_stale', 0, async () => {
      // 共性第 46 条：旧逻辑限流短路时只标更新时间，不给限流提示与重试、【提现】仍可点（withdrawAllowed 断言为 true）。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.withdrawAllowed).assertTrue();
      f.session.readGate.start(30000);
      f.session.walletNeedsRefresh = true;
      w.onShown();
      expect(w.snapshot.keptFetchedAt).assertEqual(NOW);
      expect(w.snapshot.refreshError !== null).assertTrue();
      expect(w.withdrawAllowed).assertFalse();
      // 禁用期过后成功：恢复
      f.nowMs += 31000;
      f.rig.nowMillis = f.nowMs;
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson()));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(w.snapshot.refreshError).assertNull();
      expect(w.withdrawAllowed).assertTrue();
    });

    it('APP08_30_leave_ends_refreshing_synchronously', 0, async () => {
      // 共性第 30 条：旧逻辑 leave() 只取消请求，refreshing 停在 true（迟到响应被丢弃，没有任何出口把它结束）。
      const f: OrderFixture = new OrderFixture();
      f.cache.saveDetail('O1', rec(detail('O1', '"order_no":"111"')));
      f.detailReply = (_id: string): TransportResponse => TransportResponse.failed(TransportFailure.TIMEOUT);
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      expect(d.snapshot.stale).assertTrue();
      f.detailReply = (_id: string): TransportResponse | null => null;
      expect(d.refreshStale()).assertTrue();
      await flush();
      expect(d.snapshot.refreshing).assertTrue();
      let notified: number = 0;
      d.onChange = (_s: OrderDetailSnapshot): void => {
        notified++;
      };
      d.leave();
      expect(d.snapshot.refreshing).assertFalse();
      expect(notified).assertEqual(1);
      // 列表同样
      const g: OrderFixture = new OrderFixture();
      g.list = (_q: string) => envelope(0, page([order('O1', '1', 'PAID')], null));
      const c: OrderListController = g.listController();
      c.ensureLoaded();
      await flush();
      expect(c.snapshot.phase).assertEqual(OrderPhase.CONTENT);
      g.list = (_q: string) => null;
      expect(c.refresh()).assertTrue();
      expect(c.snapshot.refreshing).assertTrue();
      c.leave();
      expect(c.snapshot.refreshing).assertFalse();
    });

    it('APP08_33_not_installed_copy_counts_as_jump_out', 0, async () => {
      // 共性第 33 条（BR-ATTR-21）：旧逻辑未安装但口令复制成功（FINAL_NOT_INSTALLED）只提示安装，不调 onJumped，回前台不拉待跟单卡。
      const f: Fixture = new Fixture();
      f.ports.installedRaw = 'false';
      const jumped: string[] = [];
      f.controller.onJumped = (platform: string): void => {
        jumped.push(platform);
      };
      f.controller.buy(card(), null);
      f.opens()[0].ok(openOk('{"primary":{"type":"copy_tpwd","value":"fixture-tpwd-001"},"fallbacks":[],'
        + '"expire_at":"' + FAR_FUTURE + '"}'));
      await settlePurchase(f);
      expect(f.ports.copied.length).assertEqual(1);
      expect(f.controller.state.notInstalled).assertTrue();
      expect(f.controller.state.toast?.key).assertEqual(OpenPurchaseController.COPIED_KEY);
      expect(jumped.length).assertEqual(1);
      expect(jumped[0]).assertEqual('taobao');
    });

    it('APP08_34_server_calibrated_clock_from_response_date', 0, async () => {
      // 共性第 34 条（BR-TEXT-11）：旧逻辑没有对外的校准时钟，订单页用本机 Date.now()。手机快一天时「今天 09:00」显示成「昨天」。
      const f: WalletFixture = new WalletFixture();
      const serverMs: number = NOW - 24 * 3600 * 1000;
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson(), {
        'Date': new Date(serverMs).toUTCString()
      }));
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      expect(f.rig.client.serverNow()).assertEqual(NOW);
      w.load();
      await settle();
      expect(f.rig.client.serverNow()).assertEqual(serverMs);
      // 偏差不超过 5 分钟：不校准
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => envelope(0, summaryJson(), {
        'Date': new Date(NOW + 120000).toUTCString()
      }));
      expect(w.refresh()).assertTrue();
      await settle();
      expect(f.rig.client.serverNow()).assertEqual(NOW);
    });

    it('APP08_35_user_scroll_during_restore_cancels_it', 0, () => {
      // 共性第 35 条（APP-06a 第 41 条）：旧逻辑恢复冻结期间的滚动只被忽略，补页到目标后仍把用户拉回旧锚点（resolve 返回下标）。
      const conditions: string = new OrderListConditions().encode();
      const keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
      keeper.begin('O40', conditions);
      const firstPage: OrderRecord[] = [rec(order('O1', '1', 'PAID')), rec(order('O2', '2', 'PAID'))];
      expect(keeper.resolve(firstPage, conditions, OrderPhase.CONTENT, 1)).assertEqual(OrderScrollAnchor.WAIT);
      // 列表首次可交互：建立位置基准，不改锚点
      expect(keeper.visible('')).assertFalse();
      expect(keeper.frozen).assertTrue();
      expect(keeper.anchor).assertEqual('O40');
      // 用户在补页期间滚动：取消恢复，按用户的新位置记录
      expect(keeper.visible('O2')).assertTrue();
      expect(keeper.frozen).assertFalse();
      expect(keeper.anchor).assertEqual('O2');
      const ticket: number = keeper.ticket;
      const withTarget: OrderRecord[] = firstPage.concat([rec(order('O40', '40', 'PAID'))]);
      expect(keeper.resolve(withTarget, conditions, OrderPhase.CONTENT, 1)).assertEqual(OrderScrollAnchor.DROPPED);
      expect(keeper.commitAlign(ticket, 1, conditions)).assertFalse();
      // 没有人动列表：照常恢复（不误伤）
      const k2: OrderAnchorKeeper = new OrderAnchorKeeper();
      k2.begin('O40', conditions);
      expect(k2.resolve(firstPage, conditions, OrderPhase.CONTENT, 1)).assertEqual(OrderScrollAnchor.WAIT);
      expect(k2.visible('')).assertFalse();
      expect(k2.visible('')).assertFalse();
      expect(k2.resolve(withTarget, conditions, OrderPhase.CONTENT, 1)).assertEqual(2);
    });
    // ---------------------------------------------------------------- 第 1 轮评审修复（R1-01..04）与 APP-08 共性第 36–38 条

    it('R1_01_withdraw_deferred_confirm_step_up_dropped_when_key_settled_elsewhere', 0, async () => {
      // 旧逻辑：页面 A 确认结果未知的键 K，隐藏期间收到 10003（登记延后验证）；页面 B 放弃 K 成功（未决记录已删）。A 的 phase 与
      // stepUpKey 仍是旧值，回到 A 时 surfaceDeferred 只比对页面保存的键，重新打开验证面板（stepUpAction 断言非空）。
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const a: WithdrawController = await openWithdraw(f);
      a.fillQuick(1000, a.snapshot.version);
      await settle();
      expect(a.submit()).assertTrue();
      await settle();
      const key: string = (a.snapshot.pending as PendingView).key;
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      expect(a.confirm(a.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      a.openRecords();
      a.onHidden();
      f.held[held].resolve(envelope(10003, '{}'));
      await settle();
      expect(a.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      expect(a.snapshot.stepUpAction).assertNull();
      // 页面 B 放弃 K 成功
      const b: WithdrawController = await openWithdraw(f);
      expect((b.snapshot.pending as PendingView).key).assertEqual(key);
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) =>
        envelope(0, '{"outcome":"abandoned","original":null}'));
      expect(b.abandon(b.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(b.snapshot.pending).assertNull();
      // A 同步清除旧验证状态，回到正常页面状态
      expect(a.snapshot.phase === WithdrawPhase.STEP_UP).assertFalse();
      expect(a.snapshot.pending).assertNull();
      const sms: number = f.count('/v1/auth/sms-codes');
      a.onShown();
      await settle();
      expect(a.snapshot.stepUpAction).assertNull();
      expect(a.createStepUp()).assertNull();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(sms);
      expect(a.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      // 不误伤：K 没被别处结算时，回来照常打开面板
      const g: WalletFixture = new WalletFixture();
      g.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      g.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c: WithdrawController = await openWithdraw(g);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      g.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      expect(c.confirm(c.snapshot.pendingVersion, (c.snapshot.pending as PendingView).key)).assertTrue();
      await settle();
      c.openRecords();
      c.onHidden();
      g.held[g.held.length - 1].resolve(envelope(10003, '{}'));
      await settle();
      c.onShown();
      expect(c.snapshot.stepUpAction as string).assertEqual(WithdrawController.STEP_UP_ACTION);
    });

    it('R1_01_payout_deferred_confirm_step_up_dropped_when_key_settled_elsewhere', 0, async () => {
      // 旧逻辑：同上（收款账号）。回到 P1 时延后的验证面板按旧 stepUpKey 重新打开（stepUpAction 断言非空）。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', '13800135678');
      p.setField('payee_name', '测试三');
      expect(p.save()).assertTrue();
      await settle();
      const key: string = (p.snapshot.pending as PendingView).key;
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => null);
      expect(p.confirm(p.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      p.openRealName();
      p.onHidden();
      f.held[held].resolve(envelope(10003, '{}'));
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.STEP_UP);
      expect(p.snapshot.stepUpAction).assertNull();
      const p2: PayoutAccountController = new PayoutAccountController(f.deps());
      p2.onShown();
      await settle();
      expect((p2.snapshot.pending as PendingView).key).assertEqual(key);
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) =>
        envelope(0, '{"outcome":"abandoned","original":null}'));
      expect(p2.abandon(p2.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(p2.snapshot.pending).assertNull();
      expect(p.snapshot.phase === PayoutPhase.STEP_UP).assertFalse();
      const sms: number = f.count('/v1/auth/sms-codes');
      p.onShown();
      await settle();
      expect(p.snapshot.stepUpAction).assertNull();
      expect(p.createStepUp()).assertNull();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(sms);
      expect(p.snapshot.pending).assertNull();
    });

    it('R1_02_own_page_exit_targets_instance_not_route_name', 0, () => {
      // 旧逻辑（popOrRemove）：只看栈顶路由名——P1 保存在途时推入同名页 P2，P1 成功后栈顶名仍是 PayoutAccount，于是 pop 掉 P2；
      // 被别的页面盖住时 removeByName 删掉全部同名实例。现在按 onReady 记下的实例 id：栈顶是本实例才 pop，否则只移除本实例。
      expect(OwnPageExit.plan('nav-p1', 'nav-p2')).assertEqual(OwnPageExit.REMOVE);
      expect(OwnPageExit.plan('nav-p1', 'nav-help')).assertEqual(OwnPageExit.REMOVE);
      expect(OwnPageExit.plan('nav-p1', 'nav-p1')).assertEqual(OwnPageExit.POP);
      expect(OwnPageExit.plan('nav-p1', null)).assertEqual(OwnPageExit.REMOVE);
      // 不知道自己的实例 id：不猜（不按名字出栈）
      expect(OwnPageExit.plan(null, 'nav-p1')).assertEqual(OwnPageExit.NONE);
      expect(OwnPageExit.plan('', '')).assertEqual(OwnPageExit.NONE);
    });

    it('R1_03_payout_blocked_guide_keeps_manual_entry', 0, async () => {
      // 旧逻辑：保存在途时离页再返回，迟到的 30304 被正确拦下不自动导航，但只设 banner、phase=FORM、error=null——表单里没有可点的实名
      // 入口（guideRoute 断言为 undefined / openGuide 不存在）。现在保留引导目标并给手动入口，输入保留、不重提保存。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => null);
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', '13800135678');
      p.setField('payee_name', '测试三');
      expect(p.save()).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      p.onHidden();
      p.onShown();
      await settle();
      f.held[held].resolve(envelope(30304, '{}'));
      await settle();
      expect(count(f.stack.names, 'RealName')).assertEqual(0);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      expect(p.snapshot.guideRoute as string).assertEqual('RealName');
      expect(p.snapshot.guideTextKey as string).assertEqual('withdraw.guide.realname');
      const puts: number = f.count('PUT /v1/me/payout-account');
      // 渲染版本或目标不符：不执行
      expect(p.openGuide(p.snapshot.version - 1, 'RealName')).assertFalse();
      expect(p.openGuide(p.snapshot.version, 'LaborAgreement')).assertFalse();
      expect(p.openGuide(p.snapshot.version, 'RealName')).assertTrue();
      expect(count(f.stack.names, 'RealName')).assertEqual(1);
      expect(f.count('PUT /v1/me/payout-account')).assertEqual(puts);
      expect(p.snapshot.form.alipayLogonId).assertEqual('13800135678');
      // 会话换代：入口失效
      p.onHidden();
      p.onShown();
      f.switchAccount('user-2');
      expect(p.openGuide(p.snapshot.version, 'RealName')).assertFalse();
      // 一直可见：照常自动打开，不留手动入口（不误伤）
      const g: WalletFixture = new WalletFixture();
      g.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      g.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => envelope(30304, '{}'));
      g.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      g.session.sync();
      const q: PayoutAccountController = new PayoutAccountController(g.deps());
      q.onShown();
      await settle();
      q.setField('alipay_logon_id', '13800135678');
      q.setField('payee_name', '测试三');
      expect(q.save()).assertTrue();
      await settle();
      expect(count(g.stack.names, 'RealName')).assertEqual(1);
      expect(q.snapshot.guideRoute).assertNull();
    });

    it('R1_04_small_scroll_within_same_card_cancels_restore', 0, () => {
      // 旧逻辑：只比较顶部订单编号——恢复等待期间用户在同一张卡片内小幅滚动，顶部条目不变，恢复任务保留，目标就绪后 commitAlign 仍放行，
      // 把用户拉回旧目标（resolve 返回下标 / commitAlign 为 true）。现在按实际滚动偏移判定，并在延迟对齐前再复核。
      const conditions: string = new OrderListConditions().encode();
      const firstPage: OrderRecord[] = [rec(order('O1', '1', 'PAID')), rec(order('O2', '2', 'PAID'))];
      const withTarget: OrderRecord[] = firstPage.concat([rec(order('O40', '40', 'PAID'))]);
      const keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
      keeper.begin('O40', conditions);
      expect(keeper.resolve(firstPage, conditions, OrderPhase.CONTENT, 1)).assertEqual(OrderScrollAnchor.WAIT);
      expect(keeper.observe('O1', 0)).assertFalse();
      // 同一张卡片（顶部仍是 O1）内滚动 12 像素：取消恢复
      expect(keeper.observe('O1', 12)).assertTrue();
      expect(keeper.frozen).assertFalse();
      expect(keeper.anchor).assertEqual('O1');
      expect(keeper.resolve(withTarget, conditions, OrderPhase.CONTENT, 1)).assertEqual(OrderScrollAnchor.DROPPED);
      // 延迟对齐执行前再复核：排入回调后用户滚动（滚动回调还没到）→ commitAlign 取消
      const k2: OrderAnchorKeeper = new OrderAnchorKeeper();
      k2.begin('O40', conditions);
      expect(k2.resolve(firstPage, conditions, OrderPhase.CONTENT, 1)).assertEqual(OrderScrollAnchor.WAIT);
      expect(k2.observe('O1', 0)).assertFalse();
      expect(k2.resolve(withTarget, conditions, OrderPhase.CONTENT, 1)).assertEqual(2);
      const ticket: number = k2.ticket;
      expect(k2.commitAlign(ticket, 1, conditions, 'O1', 30)).assertFalse();
      expect(k2.frozen).assertFalse();
      expect(k2.anchor).assertEqual('O1');
      // 没有人动列表：照常对齐（不误伤；浮点误差内不算滚动）
      const k3: OrderAnchorKeeper = new OrderAnchorKeeper();
      k3.begin('O40', conditions);
      expect(k3.resolve(firstPage, conditions, OrderPhase.CONTENT, 1)).assertEqual(OrderScrollAnchor.WAIT);
      expect(k3.observe('O1', 0)).assertFalse();
      expect(k3.observe('O1', 0.2)).assertFalse();
      expect(k3.resolve(withTarget, conditions, OrderPhase.CONTENT, 1)).assertEqual(2);
      expect(k3.commitAlign(k3.ticket, 1, conditions, 'O1', 0)).assertTrue();
    });

    it('APP08_36_page_state_wiped_by_withdrawal_and_env_cleaners', 0, async () => {
      // 共性第 36 条：旧逻辑订单页面恢复记录（含完整订单号搜索词 q）不在撤回同意的清理里——清理器只删订单缓存，记录仍在，下次冷启动按它
      // 恢复出完整订单号（restore 后 conditions().q 断言为订单号）。
      const f: OrderFixture = new OrderFixture();
      const tag: string = OrderStaleCache.accountTag('user-1');
      const cond: OrderListConditions = new OrderListConditions();
      cond.q = '2026101288886666';
      let stored: string | null = new OrderPageState(tag, cond.encode(), 'O40', '2026101288886666').encode();
      let failDelete: boolean = true;
      const keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
      const restorer: OrderPageRestorer = new OrderPageRestorer((): string | null => stored,
        (value: string | null): void => {
          if (value === null && failDelete) {
            throw new Error('delete failed');
          }
          stored = value;
        }, (): string | null => 'user-1', keeper);
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      OrderCacheCleaner.install(registry, f.cache, (): void => {
        f.hub.reset();
      }, (): boolean => restorer.wipe());
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      // 删除失败：撤回清理不算完成；本进程内不再按旧记录恢复（也不恢复出搜索词）
      const failed: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(failed.ok).assertFalse();
      expect(stored !== null).assertTrue();
      const list: OrderListController = f.listController();
      restorer.restore(list, null);
      expect(list.conditions().q).assertNull();
      expect(restorer.input).assertEqual('');
      expect(keeper.frozen).assertFalse();
      // 删除成功：记录确认已删、内存锚点与输入作废
      failDelete = false;
      stored = new OrderPageState(tag, cond.encode(), 'O40', '2026101288886666').encode();
      const ok: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(ok.ok).assertTrue();
      expect(stored).assertNull();
      expect(keeper.anchor).assertEqual('');
      // 切换环境（cleanAll）同样清
      stored = new OrderPageState(tag, cond.encode(), 'O40', '').encode();
      const all: CleanReport = await registry.cleanAll();
      expect(all.ok).assertTrue();
      expect(stored).assertNull();
    });

    it('APP08_38_pending_cards_cleared_and_jump_watcher_voided_on_cleanup', 0, async () => {
      // 共性第 38 条：撤回同意 / 切换环境的清理前第一步（hub.reset）清空商品详情、搜索页上已显示的待跟单卡并作废其执行器。旧逻辑外跳
      // 回前台的拉取不看会话：旧会话点购买、清理后回来仍触发拉取（returned 断言为 1）。
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      const detailSlot: PendingTrackController = f.pendingController();
      const searchSlot: PendingTrackController = f.pendingController();
      detailSlot.fetch(null);
      searchSlot.fetch(null);
      await flush();
      expect(detailSlot.snapshot.cards.length).assertEqual(1);
      expect(searchSlot.snapshot.cards.length).assertEqual(1);
      let returned: number = 0;
      const watcher: PendingTrackJumpWatcher = new PendingTrackJumpWatcher();
      watcher.session = (): number => searchSlot.sessionSerial;
      watcher.onReturn = (_p: string): void => {
        returned++;
      };
      watcher.buyStarted('taobao');
      watcher.onBackground();
      watcher.jumpedOut('taobao');
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      OrderCacheCleaner.install(registry, f.cache, (): void => {
        f.hub.reset();
      });
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      const report: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(report.ok).assertTrue();
      expect(detailSlot.snapshot.cards.length).assertEqual(0);
      expect(searchSlot.snapshot.cards.length).assertEqual(0);
      const fetches: number = f.rig.server.count('/v1/orders/pending-tracks');
      watcher.onForeground();
      await flush();
      expect(returned).assertEqual(0);
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(fetches);
      // 同一会话：照常拉（不误伤）
      watcher.buyStarted('taobao');
      watcher.onBackground();
      watcher.jumpedOut('taobao');
      watcher.onForeground();
      expect(returned).assertEqual(1);
    });

    it('R2_01_page_state_wipe_reports_failure_when_storage_unavailable_or_read_fails', 0, async () => {
      // 旧逻辑：AppOrders 的偏好适配在存储打不开时写入静默返回、读取返回 null——wipe 读回 null 判定删除成功、清除 wipePending，
      // 撤回清理报告成功（failed.ok 断言为 true），磁盘记录（含完整订单号）实际仍在。现在「打不开 / 读失败」抛错，与「没有记录」区分。
      const key: string = 'orders.page_state';
      const kv: MemPageKv = new MemPageKv();
      const tag: string = OrderStaleCache.accountTag('user-1');
      const cond: OrderListConditions = new OrderListConditions();
      cond.q = '2026101288886666';
      kv.map.set(key, new OrderPageState(tag, cond.encode(), 'O40', '2026101288886666').encode());
      let available: boolean = false;
      const store: OrderPageStateStore = new OrderPageStateStore((): OrderPageStateKv | null => available ? kv : null,
        key);
      const keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
      const restorer: OrderPageRestorer = new OrderPageRestorer((): string | null => store.read(),
        (value: string | null): void => store.write(value), (): string | null => 'user-1', keeper);
      const f: OrderFixture = new OrderFixture();
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      OrderCacheCleaner.install(registry, f.cache, (): void => {
        f.hub.reset();
      }, (): boolean => restorer.wipe());
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      // 存储打不开：清理报失败，记录仍在；本进程内禁止恢复
      const failed: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(failed.ok).assertFalse();
      expect(kv.map.has(key)).assertTrue();
      const list: OrderListController = f.listController();
      restorer.restore(list, null);
      expect(list.conditions().q).assertNull();
      expect(restorer.input).assertEqual('');
      // 打得开但读取失败（删除没报错也不算删掉）：同样报失败
      available = true;
      kv.failGet = true;
      const readFailed: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(readFailed.ok).assertFalse();
      // 删除失败：报失败，记录仍在
      kv.failGet = false;
      kv.failRemove = true;
      kv.map.set(key, new OrderPageState(tag, cond.encode(), 'O40', '2026101288886666').encode());
      const removeFailed: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(removeFailed.ok).assertFalse();
      expect(kv.map.has(key)).assertTrue();
      // 确认删除落盘、读回没有：才算完成（不误伤）
      kv.failRemove = false;
      const ok: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(ok.ok).assertTrue();
      expect(kv.map.has(key)).assertFalse();
      // 记录本来就不存在：读取为 null（不是错误），清理成功
      const empty: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(empty.ok).assertTrue();
    });

    it('R2_02_withdraw_blocked_guide_keeps_manual_entry_when_rules_refetch_fails', 0, async () => {
      // 旧逻辑：提交挂起 → 离页再返回 → 迟到的 30304 被正确拦下，但随后重取 rules 返回 50001，页面保留旧的允许提现 rules，guide() 为
      // null，只有实名提示条、没有实名按钮（manualGuide / openKeptGuide 断言失败）。现在独立保存结果要求的目标并给手动入口。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      const text: string = c.snapshot.inputText;
      expect(c.submit()).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      c.openPayout();
      c.onHidden();
      c.onShown();
      await settle();
      f.reply('/v1/withdrawals/rules', (_r: TransportRequest) => envelope(50001, '{}'));
      f.held[held].resolve(envelope(30304, '{}'));
      await settle();
      expect(count(f.stack.names, 'RealName')).assertEqual(0);
      expect(c.guide()).assertNull();
      expect(c.snapshot.rulesError !== null).assertTrue();
      expect(c.manualGuide() as string).assertEqual('RealName');
      expect(c.snapshot.guideTextKey as string).assertEqual('withdraw.guide.realname');
      const posts: number = f.count('POST /v1/withdrawals');
      // 绑定渲染版本与目标：不符不执行
      expect(c.openKeptGuide(c.snapshot.version - 1, 'RealName')).assertFalse();
      expect(c.openKeptGuide(c.snapshot.version, 'LaborAgreement')).assertFalse();
      expect(c.openKeptGuide(c.snapshot.version, 'RealName')).assertTrue();
      expect(count(f.stack.names, 'RealName')).assertEqual(1);
      expect(f.count('POST /v1/withdrawals')).assertEqual(posts);
      expect(c.snapshot.inputText).assertEqual(text);
      // 已导航走（页面不可见）：同一渲染的重复点击不再执行
      expect(c.openKeptGuide(c.snapshot.version, 'RealName')).assertFalse();
      // 回来后 rules 成功且明确允许：收起手动入口
      f.reply('/v1/withdrawals/rules', (r: TransportRequest) => {
        const q: string = queryOfReq(r);
        return envelope(0, q.indexOf('amount_fen=') >= 0 ? rulesJson(1000) : rulesJson(null));
      });
      c.onHidden();
      c.onShown();
      await settle();
      expect(c.manualGuide()).assertNull();
    });

    it('R2_03_payout_guide_button_bound_to_render_version_and_visibility', 0, async () => {
      // 旧逻辑：按钮回调执行时读 this.model 的最新版本与目标——旧按钮（版本 v1、RealName）晚到时用新快照（v2、LaborAgreement）通过
      // 校验，换目标打开。现在按钮捕获不可变的版本与目标（RenderBound），执行层还核对页面此刻可见（导航走后旧回调失效）。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => null);
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', '13800135678');
      p.setField('payee_name', '测试三');
      expect(p.save()).assertTrue();
      await settle();
      p.onHidden();
      p.onShown();
      await settle();
      f.held[f.held.length - 1].resolve(envelope(30304, '{}'));
      await settle();
      const v1: number = p.snapshot.version;
      expect(p.snapshot.guideRoute as string).assertEqual('RealName');
      // 再保存一次，迟到的 10004（劳务协议）→ 目标换成 LaborAgreement、版本前进
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      expect(p.save()).assertTrue();
      await settle();
      p.onHidden();
      p.onShown();
      await settle();
      f.held[f.held.length - 1].resolve(envelope(10004, '{"consent_type":"labor_agreement"}'));
      await settle();
      expect(p.snapshot.guideRoute as string).assertEqual('LaborAgreement');
      expect(p.snapshot.version > v1).assertTrue();
      // 旧按钮的捕获值（v1、RealName）：拒绝，不换目标执行
      expect(p.openGuide(v1, 'RealName')).assertFalse();
      expect(count(f.stack.names, 'LaborAgreement')).assertEqual(0);
      expect(count(f.stack.names, 'RealName')).assertEqual(0);
      // 页面被覆盖时：当前按钮也不执行
      p.onHidden();
      expect(p.openGuide(p.snapshot.version, 'LaborAgreement')).assertFalse();
      p.onShown();
      await settle();
      expect(p.openGuide(p.snapshot.version, 'LaborAgreement')).assertTrue();
      expect(count(f.stack.names, 'LaborAgreement')).assertEqual(1);
    });

    it('R2_04_deferred_withdraw_success_replaces_only_own_instance', 0, async () => {
      // 旧逻辑：延后的成功出口调 replaceTop → navigator.remove('Withdraw')，把 W1、W2 两个提现页都移除（栈里 Withdraw 个数断言为 0）。
      // 现在提现页接上自己的实例出口 replaceOwn，只替换发起页这个实例。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      f.stack.pushPathByName('Withdraw', new RouteDestination('Withdraw'));
      f.stack.pushPathByName('Withdraw', new RouteDestination('Withdraw'));
      const c2: WithdrawController = await openWithdraw(f);
      let replaced: number = 0;
      c2.replaceOwn = (route: string, params: Record<string, Object>): void => {
        replaced++;
        f.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
        // 只移除本实例（W2，下标 1）
        f.stack.names.splice(1, 1);
        f.stack.params.splice(1, 1);
      };
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      c2.onHidden();
      f.held[held].resolve(envelope(0, withdrawal('W9', 'PENDING_REVIEW', 1000, CREATED, ',"channel_order_id":null')));
      await settle();
      expect(c2.snapshot.phase).assertEqual(WithdrawPhase.DONE);
      expect(f.stack.names.indexOf('WithdrawRecords')).assertEqual(-1);
      c2.onShown();
      await settle();
      expect(replaced).assertEqual(1);
      expect(count(f.stack.names, 'Withdraw')).assertEqual(1);
      expect(f.stack.names[f.stack.names.length - 1]).assertEqual('WithdrawRecords');
    });

    it('lesson52_form_bound_to_login_generation_before_session_clear_notice', 0, async () => {
      // 共性第 52 条（S0）：同账号重新登录，新令牌已保存（登录序号、会话世代已变），钱包会话的清空通知（session.sync）还没执行。旧逻辑
      // 只核对账号与钱包 epoch（都没变）：旧页面的提现提交照常读凭据、登记未决并发出（POST 计数 +1），收款账号保存、实名提交、
      // 劳务签署同样照常执行。现在表单绑定页面构建时的会话归属（含登录世代），生成键、读取凭据前核对。
      const f: WalletFixture = new WalletFixture();
      const contract: CountingContract = new CountingContract();
      f.contract = contract;
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.tokens.put('payout_account_change', 'user-1', 'fixture-step-token', NOW + 300000);
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.canSubmit).assertTrue();
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      p.setField('alipay_logon_id', '13800135678');
      p.setField('payee_name', '测试三');
      expect(p.canSave).assertTrue();
      const r: RealNameController = new RealNameController(f.deps());
      r.setName('测试三');
      r.setIdNo('000000000000000000');
      expect(r.requestSubmit()).assertTrue();
      r.setConsentChecked(true);
      const l: LaborAgreementController = new LaborAgreementController(f.deps());
      l.load();
      await settle();
      l.setChecked(true);
      expect(l.canSign).assertTrue();
      const pageScope: string = f.scope();
      const epoch: number = f.session.epoch;
      // 同账号重新登录：只换了令牌与登录世代，清空通知未到
      f.rig.tokens.save(new SessionTokenSet('access-user-1b', 'refresh-user-1b', 'full', 'user-1'));
      f.rig.client.onSessionChanged();
      expect(f.session.epoch).assertEqual(epoch);
      expect(f.rig.client.sessionAccount() as string).assertEqual('user-1');
      const posts: number = f.count('POST /v1/withdrawals');
      const puts: number = f.count('PUT /v1/me/payout-account');
      expect(c.submit()).assertFalse();
      expect(p.save()).assertFalse();
      expect(r.agreeAndSubmit()).assertFalse();
      expect(l.sign()).assertFalse();
      // 执行层：带本页归属键的点击身份——不读凭据、不登记、不发包
      await c.flow.submit('{"amount_fen":1000}', '{"amount_fen":1000}', null, null,
        new PendingClick('user-1', epoch, '', pageScope));
      await settle();
      expect(f.count('POST /v1/withdrawals')).assertEqual(posts);
      expect(f.count('PUT /v1/me/payout-account')).assertEqual(puts);
      expect(c.flow.pending()).assertNull();
      expect(c.flow.inFlightElsewhere()).assertFalse();
      expect(contract.realnameCalls).assertEqual(0);
      expect(contract.signCalls).assertEqual(0);
      // 清空通知到了之后，新页面照常提交（不误伤）
      f.session.sync();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      const c2: WithdrawController = await openWithdraw(f);
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      expect(f.count('POST /v1/withdrawals')).assertEqual(posts + 1);
    });

    it('lesson53_withdraw_success_refreshes_visible_wallet_and_voids_old_summary', 0, async () => {
      // 共性第 53 条：旧逻辑提现成功只置 walletNeedsRefresh——用户在提交挂起时返回钱包，钱包的回流 / 下拉刷新在提现落库前发出，
      // 成功后没有任何刷新，旧摘要（available 1000）继续当正常数据显示。现在成功通知同一会话仍存在的钱包页：作废旧摘要请求并重取。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      w.onHidden();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = new WithdrawController(f.deps());
      c.onShown();
      await settle();
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      const post: number = f.held.length - 1;
      c.leave();
      // 回到钱包：下拉刷新的摘要请求在成功前发出、挂起
      let hold: boolean = true;
      f.reply('/v1/wallet/summary', (_r: TransportRequest) => hold ? null
        : envelope(0, summaryJson('{"available_fen":0,"withdrawable_fen":0,"withdrawn_fen":1000}')));
      w.onShown();
      expect(w.refresh()).assertTrue();
      await settle();
      const oldSummary: number = f.held.length - 1;
      hold = false;
      f.held[post].resolve(envelope(0, withdrawal('W9', 'PENDING_REVIEW', 1000, CREATED, ',"channel_order_id":null')));
      await settle();
      // 旧摘要迟到：不覆盖成功后的新摘要
      f.held[oldSummary].resolve(envelope(0, summaryJson()));
      await settle();
      expect((w.snapshot.summary as WalletRecord)['available_fen'] as number).assertEqual(0);
      expect(f.session.walletNeedsRefresh).assertFalse();
      // 换了会话的旧结果不刷新新会话的钱包：只认同一归属
      const runs: number = f.count('/v1/wallet/summary');
      f.session.markWalletDirty('other-scope');
      await settle();
      expect(f.count('/v1/wallet/summary')).assertEqual(runs);
    });

    it('lesson54_focus_detail_shares_per_item_sequence_with_normal_detail', 0, async () => {
      // 共性第 54 条（Android R3-03 对照）：定位详情 F1（审核中）延迟返回，用户展开同一单的普通详情 F2（已到账、流水号）先回来——F1 迟到
      // 不得覆盖。鸿蒙定位与普通详情本就共用每单请求序号（detailReq），列表合并只用本轮已接受的详情：作为证据用例。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      let calls: number = 0;
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => {
        calls++;
        if (calls === 1) {
          return envelope(50001, '{}');
        }
        if (calls === 2) {
          return null;
        }
        return envelope(0, withdrawal('W3', 'PAID_API', 800, '2026-10-08T11:30:00+08:00',
          ',"channel_order_id":"CH20261008001"'));
      });
      const r: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      r.open('W3');
      await settle();
      expect(r.snapshot.focusError !== null).assertTrue();
      expect(r.refresh()).assertTrue();
      await settle();
      const f1: number = f.held.length - 1;
      expect(r.toggle('W3', r.snapshot.version)).assertTrue();
      await settle();
      expect((itemOf(r.snapshot.items, 'W3') as WalletRecord)['status'] as string).assertEqual('PAID_API');
      f.held[f1].resolve(envelope(0, withdrawal('W3', 'PENDING_REVIEW', 800, '2026-10-08T11:30:00+08:00',
        ',"channel_order_id":null')));
      await settle();
      expect((itemOf(r.snapshot.items, 'W3') as WalletRecord)['status'] as string).assertEqual('PAID_API');
      expect(r.tradeNo('W3')['show'] as boolean).assertTrue();
    });

    it('lesson55_return_entries_enter_rate_limited_error_state', 0, async () => {
      // 共性第 55 条：旧逻辑记录页回流（onShown）被共享限流短路时只恢复旧列表，没有错误条与重试说明（refreshError 断言为 null）；
      // 下拉刷新被挡下也只返回 false。钱包回到前台的入口旧逻辑调 refresh()，被闸门短路成什么都不做。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const r: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      r.open(null);
      await settle();
      expect(r.snapshot.phase).assertEqual(RecordsPhase.CONTENT);
      const items: number = r.snapshot.items.length;
      f.session.readGate.start(30000);
      r.onShown();
      expect(r.snapshot.phase).assertEqual(RecordsPhase.CONTENT);
      expect(r.snapshot.items.length).assertEqual(items);
      expect((r.snapshot.refreshError as WalletMessage).textKey).assertEqual('error.42901');
      expect(r.snapshot.blocked).assertTrue();
      expect(r.retry()).assertFalse();
      // 下拉刷新被挡下：同样给限流错误状态
      const g: WalletFixture = new WalletFixture();
      g.session.sync();
      const r2: WithdrawRecordsController = new WithdrawRecordsController(g.deps());
      r2.open(null);
      await settle();
      g.session.readGate.start(30000);
      expect(r2.refresh()).assertFalse();
      expect((r2.snapshot.refreshError as WalletMessage).textKey).assertEqual('error.42901');
      // 钱包回到前台的入口：保留旧摘要、限流错误条、【提现】置灰
      const h: WalletFixture = new WalletFixture();
      h.session.sync();
      const w: WalletController = new WalletController(h.deps());
      w.load();
      await settle();
      h.session.readGate.start(30000);
      w.onForeground();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect(w.snapshot.refreshError !== null).assertTrue();
      expect(w.withdrawAllowed).assertFalse();
    });

    it('lesson56_read_blocked_before_send_ends_loading_with_42901', 0, async () => {
      // 共性第 56 条（Android R3-05、R3-06 对照）：请求已排队、发送前被共享限流闸门拦下（SEND_BLOCKED）——鸿蒙按 42901 结算：收款账号
      // 读取结束加载、给 42901 与（禁用中的）重试；钱包【提现】的实名前置查询给 42901 提示与重试。作为证据用例。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      f.rig.timer.holdBackoff = true;
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.LOADING);
      f.session.readGate.start(30000);
      f.rig.timer.releaseBackoffs();
      await settle();
      expect(f.count('/v1/me/payout-account')).assertEqual(1);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.ERROR);
      expect((p.snapshot.error as WalletMessage).textKey).assertEqual('error.42901');
      expect(p.retry()).assertFalse();
      // 实名前置查询：摘要已显示、实名状态未知，点【提现】的 getMe 发送前被拦下
      const g: WalletFixture = new WalletFixture();
      g.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      g.session.sync();
      const w: WalletController = new WalletController(g.deps());
      w.load();
      await settle();
      expect(w.withdrawAllowed).assertTrue();
      g.rig.timer.holdBackoff = true;
      g.reply('/v1/me', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      let opened: number = 0;
      expect(w.requestWithdraw((): void => {
        opened++;
      })).assertTrue();
      await settle();
      g.session.readGate.start(30000);
      g.rig.timer.releaseBackoffs();
      await settle();
      expect(opened).assertEqual(0);
      expect((w.snapshot.realnameError as WalletMessage).textKey).assertEqual('error.42901');
      expect((w.snapshot.notice as WalletMessage).textKey).assertEqual('error.42901');
    });

    it('lesson57_realname_query_navigation_bound_to_visible_generation', 0, async () => {
      // 共性第 57 条：点【提现】等 getMe 时 App 切后台（AppWallet.onAppBackground → 可见页 onHidden，可见世代换代），再回前台（onShown）——
      // 迟到的 verified 不导航（旧许可不随回到前台恢复）。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me', (_r: TransportRequest) => envelope(50001, '{}'));
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      f.reply('/v1/me', (_r: TransportRequest) => null);
      let opened: number = 0;
      expect(w.requestWithdraw((): void => {
        opened++;
      })).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      w.onHidden();
      w.onShown();
      f.held[held].resolve(envelope(0, '{"realname_status":"verified"}'));
      await settle();
      expect(opened).assertEqual(0);
      // 一直在前台：照常导航（不误伤）
      expect(w.requestWithdraw((): void => {
        opened++;
      })).assertTrue();
      expect(opened).assertEqual(1);
    });

    it('R3_01_abandon_in_flight_after_leave_returns_original_success_refreshes_wallet', 0, async () => {
      // 旧逻辑：已离页分支只认 DONE。提现结果未知 → 点放弃上一笔（请求挂起）→ 退出提现页回到钱包 → 放弃返回 completed、original.code=0
      // （映射为 ALREADY_DONE），直接返回不通知钱包：未决记录已删，钱包没有新的摘要请求，仍显示 1000 分且允许提现。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      w.onHidden();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      const key: string = (c.snapshot.pending as PendingView).key;
      f.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) => null);
      expect(c.abandon(c.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      const held: number = f.held.length - 1;
      c.leave();
      w.onShown();
      await settle();
      const runs: number = f.count('/v1/wallet/summary');
      f.reply('/v1/wallet/summary', (_r: TransportRequest) =>
        envelope(0, summaryJson('{"available_fen":0,"withdrawable_fen":0,"withdrawn_fen":1000}')));
      f.held[held].resolve(envelope(0,
        '{"outcome":"completed","original":{"code":0,"msg":"","data":{"withdrawal_id":"W7"}}}'));
      await settle();
      expect(f.rig.client.pendingFor('createWithdrawal')).assertNull();
      expect(f.count('/v1/wallet/summary')).assertEqual(runs + 1);
      expect((w.snapshot.summary as WalletRecord)['available_fen'] as number).assertEqual(0);
      // 不误伤：放弃得到原结果失败（original.code≠0）时不通知钱包
      const g: WalletFixture = new WalletFixture();
      g.session.sync();
      const w2: WalletController = new WalletController(g.deps());
      w2.load();
      await settle();
      w2.onHidden();
      g.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      const c2: WithdrawController = await openWithdraw(g);
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      g.reply('/v1/idempotency-keys/abandon', (_r: TransportRequest) => null);
      expect(c2.abandon(c2.snapshot.pendingVersion, (c2.snapshot.pending as PendingView).key)).assertTrue();
      await settle();
      const held2: number = g.held.length - 1;
      c2.leave();
      w2.onShown();
      await settle();
      const runs2: number = g.count('/v1/wallet/summary');
      g.held[held2].resolve(envelope(0, '{"outcome":"completed","original":{"code":50001,"msg":"","data":{}}}'));
      await settle();
      expect(g.count('/v1/wallet/summary')).assertEqual(runs2);
    });

    it('R3_02_upper_wallet_refresh_does_not_consume_lower_wallet_need', 0, async () => {
      // 旧逻辑：两个钱包实例共用 session.walletNeedsRefresh。W1 打开提现页提交（响应挂起），再打开 W2；提现成功时 W2 可见、刷新并把
      // 共享标记清掉，W1 不可见没有自己的待刷新——逐层返回 W1 时 onShown 不再取摘要，W1 仍显示 1000 分且允许提现。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const w1: WalletController = new WalletController(f.deps());
      w1.load();
      await settle();
      expect(w1.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      w1.onHidden();
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const c: WithdrawController = new WithdrawController(f.deps());
      c.onShown();
      await settle();
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      const post: number = f.held.length - 1;
      c.onHidden();
      const w2: WalletController = new WalletController(f.deps());
      w2.load();
      await settle();
      expect(w2.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      f.reply('/v1/wallet/summary', (_r: TransportRequest) =>
        envelope(0, summaryJson('{"available_fen":0,"withdrawable_fen":0,"withdrawn_fen":1000}')));
      f.held[post].resolve(envelope(0, withdrawal('W8', 'PENDING_REVIEW', 1000, CREATED, ',"channel_order_id":null')));
      await settle();
      expect((w2.snapshot.summary as WalletRecord)['available_fen'] as number).assertEqual(0);
      expect((w1.snapshot.summary as WalletRecord)['available_fen'] as number).assertEqual(1000);
      // 逐层返回：W2 出栈、提现页出栈，回到 W1 —— W1 自己的待刷新仍在，重取摘要
      w2.leave();
      c.leave();
      const runs: number = f.count('/v1/wallet/summary');
      w1.onShown();
      await settle();
      expect(f.count('/v1/wallet/summary')).assertEqual(runs + 1);
      expect((w1.snapshot.summary as WalletRecord)['available_fen'] as number).assertEqual(0);
      // 已消费：再次回到 W1 不重复取
      w1.onHidden();
      w1.onShown();
      await settle();
      expect(f.count('/v1/wallet/summary')).assertEqual(runs + 1);
    });
  });
}
