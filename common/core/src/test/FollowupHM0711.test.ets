// FU-HM-0711 鸿蒙回头补课：APP-09 共性第 59–62 条（Android 定向复核 RC-01..RC-04 的鸿蒙对照）。
// 真实 ApiClient + 本地假服务，不连任何地址、不做真实提现。每个用例的注释写明「按旧逻辑为何失败」或「作为证据」。
import { describe, it, expect } from '@ohos/hypium';
import {
  PayoutAccountController, PayoutPhase, RealNameController, SessionTokenSet, SmsResendClock, StepUpController,
  TransportFailure, TransportRequest, TransportResponse, WalletController, WalletDeps, WalletMessage, WalletPhase,
  WithdrawController, WithdrawPhase
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { NOW, settle, TEST_PHONE, WalletFixture, withdrawal, openWithdraw } from './WalletIntegration.test';

const CREATED: string = '2026-10-12T10:30:00+08:00';

/** 提现页金额持久化回调的一次调用（共性第 59 条）。 */
class Persisted {
  readonly text: string;
  readonly account: string | null;
  readonly scope: string;

  constructor(text: string, account: string | null, scope: string) {
    this.text = text;
    this.account = account;
    this.scope = scope;
  }
}

/** 新令牌已保存（登录世代已变），钱包会话的清空通知（session.sync）还没执行。 */
function relogin(f: WalletFixture, account: string): void {
  f.rig.tokens.save(new SessionTokenSet('access-' + account + '-b', 'refresh-' + account + '-b', 'full', account));
  f.rig.client.onSessionChanged();
}

export default function followupHM0711Test() {
  describe('FollowupHM0711', () => {
    it('lesson59_input_callbacks_bound_to_form_identity_not_written_after_session_change', 0, async () => {
      // 共性第 59 条（S0，Android RC-01）：旧逻辑金额、收款账号字段、姓名 / 身份证号的输入回调只看 left——新令牌已保存、清空通知还没到
      // 时，旧回调照常把内容写进快照，金额还经 onInputChanged 交给 App 按「执行时的当前账号」保存（断言 setInput 返回 false、
      // 持久化次数不变、各字段保持原值都会失败）。现在输入回调写入前核对表单构建时的归属键、账号与钱包会话世代，持久化回调带表单固定的
      // 账号与归属键。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      const c: WithdrawController = await openWithdraw(f);
      const saved: Persisted[] = [];
      c.onInputChanged = (text: string, account: string | null, scope: string): void => {
        saved.push(new Persisted(text, account, scope));
      };
      const pageScope: string = f.scope();
      expect(c.setInput('10')).assertTrue();
      expect(saved.length).assertEqual(1);
      expect(saved[0].text).assertEqual('10');
      expect(saved[0].account as string).assertEqual('user-1');
      expect(saved[0].scope).assertEqual(pageScope);
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      expect(p.setField('alipay_logon_id', '13800135678')).assertTrue();
      expect(p.setField('payee_name', '测试三')).assertTrue();
      const r: RealNameController = new RealNameController(f.deps());
      r.setName('测试三');
      expect(r.setIdNo('000000000000000000')).assertTrue();

      // 换成另一个账号：令牌已保存，清空通知未到
      relogin(f, 'user-2');
      expect(f.rig.client.sessionAccount() as string).assertEqual('user-2');
      // 旧表单的输入 / 自动填充回调迟到
      expect(c.setInput('20')).assertFalse();
      expect(c.fillQuick(1000, c.snapshot.version)).assertFalse();
      expect(c.snapshot.inputText).assertEqual('10');
      expect(saved.length).assertEqual(1);
      expect(saved.some((x: Persisted): boolean => x.account === 'user-2')).assertFalse();
      expect(p.setField('alipay_logon_id', '13900000000')).assertFalse();
      expect(p.setField('payee_name', '李四')).assertFalse();
      p.setMethod('bank_card');
      expect(p.snapshot.form.alipayLogonId).assertEqual('13800135678');
      expect(p.snapshot.form.payeeName).assertEqual('测试三');
      expect(p.snapshot.form.method).assertEqual('alipay');
      r.setName('李四');
      expect(r.setIdNo('11010519491231002X')).assertFalse();
      expect(r.snapshot.name).assertEqual('测试三');
      expect(r.snapshot.idNo).assertEqual('000000000000000000');

      // 清空通知执行后旧回调才到：换代后的表单保持空白，持久化只有清除
      f.session.sync();
      expect(c.snapshot.inputText).assertEqual('');
      const afterReset: number = saved.length;
      expect(saved[afterReset - 1].text).assertEqual('');
      expect(c.setInput('30')).assertFalse();
      expect(c.snapshot.inputText).assertEqual('');
      expect(saved.length).assertEqual(afterReset);
      expect(p.setField('alipay_logon_id', '13800135678')).assertFalse();
      expect(p.snapshot.form.alipayLogonId).assertEqual('');
      r.setName('测试三');
      expect(r.snapshot.name).assertEqual('');

      // 不误伤：新会话的新页面照常输入、按新账号保存
      const c2: WithdrawController = await openWithdraw(f);
      const saved2: Persisted[] = [];
      c2.onInputChanged = (text: string, account: string | null, scope: string): void => {
        saved2.push(new Persisted(text, account, scope));
      };
      expect(c2.setInput('10')).assertTrue();
      expect(saved2.length).assertEqual(1);
      expect(saved2[0].account as string).assertEqual('user-2');
      expect(saved2[0].scope).assertEqual(f.scope());
    });

    it('lesson60_step_up_panel_keeps_opening_identity_and_checks_before_phone_slot_and_send', 0, async () => {
      // 共性第 60 条（Android RC-02）：旧逻辑面板的 send() 只看 closed——会话已换（清空通知未到）时照样读手机号、占用发码槽位再交给
      // 网络层（断言读号次数不变、槽位不在途会失败）；canVerify 也不看会话，旧面板的【验证并提交】照样构造请求（断言 verify() 为
      // false 会失败）。现在面板沿用发起页传入的账号、归属键与钱包会话世代，读号、占槽位、发包前都先核对。
      const f: WalletFixture = new WalletFixture();
      const d: WalletDeps = f.deps();
      let phoneReads: number = 0;
      d.stepUpPhone = (_a: string): string | null => {
        phoneReads++;
        return TEST_PHONE;
      };
      f.session.sync();
      const c: WithdrawController = new WithdrawController(d);
      c.onShown();
      await settle();
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      const s: StepUpController = c.createStepUp() as StepUpController;
      expect(s.send()).assertTrue();
      await settle();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(1);
      // 倒计时已过：可以重新获取
      f.nowMs += 61000;
      const key: string = SmsResendClock.key('user-1', TEST_PHONE, WithdrawController.STEP_UP_ACTION);
      // 同账号重新登录：令牌与登录世代已变，清空通知未到
      relogin(f, 'user-1');
      const reads: number = phoneReads;
      expect(s.send()).assertFalse();
      expect(phoneReads).assertEqual(reads);
      expect(f.session.sms.sending(key)).assertFalse();
      await settle();
      expect(f.count('/v1/auth/sms-codes')).assertEqual(1);
      s.setCode('123456');
      expect(s.snapshot.code).assertEqual('');
      expect(s.canVerify).assertFalse();
      expect(s.verify()).assertFalse();
      await settle();
      expect(f.count('/v1/auth/step-up')).assertEqual(0);
      // 发起页本身也不再给出新面板
      expect(c.createStepUp()).assertNull();
      // 不误伤：同一会话里打开的面板照常重新获取与验证
      const g: WalletFixture = new WalletFixture();
      g.session.sync();
      const c2: WithdrawController = new WithdrawController(g.deps());
      c2.onShown();
      await settle();
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      const s2: StepUpController = c2.createStepUp() as StepUpController;
      expect(s2.send()).assertTrue();
      await settle();
      s2.setCode('123456');
      expect(s2.verify()).assertTrue();
      await settle();
      expect(g.count('/v1/auth/step-up')).assertEqual(1);
    });

    it('lesson61_wallet_dirty_notice_carries_fixed_scope_without_rereading_session', 0, async () => {
      // 共性第 61 条（Android RC-03 对照）：鸿蒙提现成功的通知出口传的是页面构建时固定的 boundScope（WithdrawController.finish /
      // apply 离页分支），订阅端 WalletController.walletDirty 再核对「通知归属 = 本实例归属 = 当前归属」。ArkTS 单线程，令牌保存与
      // 结果处理不会在核对与通知之间交错。作为证据用例：通知带发起页的归属；登录世代变了之后到达的旧成功不通知、不让钱包刷新。
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', 'fixture-step-token', NOW + 300000);
      f.session.sync();
      const scopes: string[] = [];
      const unsubscribe: () => void = f.session.subscribeWalletDirty((scope: string): void => {
        scopes.push(scope);
      });
      const pageScope: string = f.scope();
      const c: WithdrawController = new WithdrawController(f.deps());
      c.onShown();
      await settle();
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      expect(scopes.length).assertEqual(1);
      expect(scopes[0]).assertEqual(pageScope);
      // 第二笔：提交挂起，同账号重新登录（清空通知未到），旧成功迟到
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => null);
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      const c2: WithdrawController = new WithdrawController(f.deps());
      c2.onShown();
      await settle();
      c2.fillQuick(1000, c2.snapshot.version);
      await settle();
      expect(c2.submit()).assertTrue();
      await settle();
      const post: number = f.held.length - 1;
      const version: number = f.session.walletDirtyVersion;
      const summaries: number = f.count('/v1/wallet/summary');
      relogin(f, 'user-1');
      f.held[post].resolve(envelope(0, withdrawal('W8', 'PENDING_REVIEW', 1000, CREATED, ',"channel_order_id":null')));
      await settle();
      expect(scopes.length).assertEqual(1);
      expect(f.session.walletDirtyVersion).assertEqual(version);
      expect(f.count('/v1/wallet/summary')).assertEqual(summaries);
      unsubscribe();
    });

    it('lesson62_admit_rejection_reason_kept_when_deadline_passes_before_delivery', 0, async () => {
      // 共性第 62 条（Android RC-04）：传输层最终核对（admit）被共享读闸门拒绝、返回 cancelled；旧逻辑 ApiClient 在结果交回时再查
      // 闸门（!sendPermitted）反推原因——禁用期恰在拒绝之后、交回之前到期，就按普通取消处理：GET 退避重试真的发出第二次（计数 2），
      // 或页面拿到网络错误而不是 42901。现在拒绝当场记下原因，按 SEND_BLOCKED 结算：结束加载、给 42901；可否重试按当前截止时间
      // （已到期 → 可重试）。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const base: (r: TransportRequest) => Promise<TransportResponse> = f.rig.server.handler;
      let payoutCalls: number = 0;
      let admitted: number = 0;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/me/payout-account') < 0) {
          return base(r);
        }
        payoutCalls++;
        if (payoutCalls > 1) {
          admitted++;
          return Promise.resolve(envelope(0, '{}'));
        }
        // 连接建立期间别的请求触发了 42901（30 秒），随后传输层的最终核对被闸门拒绝；结果交回之前禁用期已到期
        f.session.readGate.start(30000);
        const ok: boolean = r.admit();
        f.nowMs += 31000;
        if (ok) {
          admitted++;
          return Promise.resolve(envelope(0, '{}'));
        }
        return Promise.resolve(TransportResponse.failed(TransportFailure.CANCELLED));
      };
      const p: PayoutAccountController = new PayoutAccountController(f.deps());
      p.onShown();
      await settle();
      expect(admitted).assertEqual(0);
      expect(payoutCalls).assertEqual(1);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.ERROR);
      expect((p.snapshot.error as WalletMessage).textKey).assertEqual('error.42901');
      // 可否重试按当前截止时间：已到期 → 【重试】可用并真正发出
      expect(f.session.readGate.active).assertFalse();
      expect(p.retry()).assertTrue();
      await settle();
      expect(payoutCalls).assertEqual(2);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
    });
  });
}
