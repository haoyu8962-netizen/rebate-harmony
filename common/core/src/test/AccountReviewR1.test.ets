// APP-13a 鸿蒙 harmony-review-r1 的 10 条修复（R1-01 S0、R1-02–R1-10 S1）：真实 ApiClient + 本地假服务 + Core 执行器（页面按钮回调调用的
// 同一套方法）。每条至少一个用例；回退对应修复（见 NATIVE/APP-13a/harmony-mutation-fix-r1.txt）时该用例失败。
// 号码只用测试值；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  AccountMessages, BindOutcome, BindPhoneAction, BindPhoneIdentity, BindPhoneService, DeleteAccountController,
  DeletionPresentation, DeletionSource, PhoneBindingState, PhoneChangeController, PhoneChangeStep, SmsSendDeadlines,
  StepUpController, TransportRequest, AccountMessage
} from '../../Index';
import { envelope, header, tokenPair } from './NetworkTestRig';
import {
  AccountFixture, cooling, fillStep2, gateway, Host, NEW_PHONE, openDeletion, PHONE, settle, stateOf, summary, toStep2
} from './AccountIntegration.test';

function cancelledUser(): string {
  return '{"status":"cancelled","apply_at":"2026-10-14T10:00:00+08:00","cooling_until":"2026-10-21T10:00:00+08:00",'
    + '"can_cancel":false,"cancelled_at":"2026-10-14T10:05:00+08:00","cancel_reason":"user","processed_at":null}';
}

function bindService(f: AccountFixture): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
    new Host(), (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

function keysOf(f: AccountFixture, route: string): string[] {
  return f.requests(route).map((r: TransportRequest): string => header(r, 'Idempotency-Key') ?? '');
}

export default function accountReviewR1Test() {
  describe('AccountReviewR1', () => {
    it('R1_01_bind_page_identity_fixed_old_callbacks_after_relogin_send_nothing', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const svc: BindPhoneService = bindService(f);
      let resets: number = 0;
      svc.subscribeSession((): void => {
        resets++;
      });
      const pageA: BindPhoneIdentity = svc.capturePage();
      const out: BindOutcome = await svc.bind(NEW_PHONE, '123456', pageA);
      expect(out.actionRaw).assertEqual(BindOutcome.PENDING);
      const key: string = svc.pendingView(pageA)?.key ?? '';
      expect(key.length > 0).assertTrue();
      // A 会话失效 → 登录 B：同步通知页面作废旧实例；旧身份看不到 A 的待确认。
      f.switchAccount('user-2');
      expect(svc.syncSession()).assertTrue();
      expect(resets).assertEqual(1);
      expect(svc.pendingView(pageA) === null).assertTrue();
      // B 下用旧回调（A 的身份）提交：零请求。
      expect((await svc.bind(NEW_PHONE, '123456', pageA)).actionRaw).assertEqual(BindOutcome.STALE);
      // A 重新登录（同账号、登录世代已变）：旧的确认 / 放弃回调仍零请求。
      f.switchAccount('user-1');
      expect(svc.syncSession()).assertTrue();
      expect(resets).assertEqual(2);
      expect((await svc.confirmPending(key, pageA)).actionRaw).assertEqual(BindOutcome.STALE);
      expect((await svc.abandonPending(key, pageA)).actionRaw).assertEqual(BindOutcome.STALE);
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      expect(f.count('POST /v1/idempotency-keys/abandon')).assertEqual(0);
      // 新实例（按新身份重建）恢复 A 的待确认。
      const pageA2: BindPhoneIdentity = svc.capturePage();
      expect(svc.pendingView(pageA2)?.key).assertEqual(key);
    });

    it('R1_02_non_terminal_10007_5xxxx_keep_key_in_store_and_next_click_reuses_it', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(50001, '{}'));
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      expect(c.apply(c.snapshot.version)).assertTrue();
      await settle();
      // 存储层保留原键（不进待确认，页面回到可申请）。
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
      expect(c.snapshot.pending === null).assertTrue();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(10007, '{"stage":"cooling"}'));
      c.setChecked(c.snapshot.version, true);
      expect(c.apply(c.snapshot.version)).assertTrue();
      await settle();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      c.setChecked(c.snapshot.version, true);
      expect(c.apply(c.snapshot.version)).assertTrue();
      await settle();
      const keys: string[] = keysOf(f, 'POST /v1/me/deletion');
      expect(keys.length).assertEqual(3);
      expect(keys[0].length > 0).assertTrue();
      expect(keys[1]).assertEqual(keys[0]);
      expect(keys[2]).assertEqual(keys[0]);
      // 成功结束键。
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
    });

    it('R1_02_bind_phone_50401_keeps_key_and_resubmit_uses_same_key_and_body', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      p.setCode(p.snapshot.version, '654321');
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      const posts: TransportRequest[] = f.requests('POST /v1/me/phone');
      expect(posts.length).assertEqual(2);
      expect(header(posts[1], 'Idempotency-Key')).assertEqual(header(posts[0], 'Idempotency-Key'));
      expect(posts[1].body).assertEqual(posts[0].body);
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
    });

    it('R1_03_bind_page_confirm_42901_shared_phone_gate_blocks_confirm_and_abandon', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const svc: BindPhoneService = bindService(f);
      const page: BindPhoneIdentity = svc.capturePage();
      await svc.bind(NEW_PHONE, '123456', page);
      const key: string = svc.pendingView(page)?.key ?? '';
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '9' }));
      const first: BindOutcome = await svc.confirmPending(key, page);
      expect(first.actionRaw).assertEqual(BindOutcome.PENDING);
      expect(f.session.phoneGate.active).assertTrue();
      expect(svc.phoneGateActive).assertTrue();
      // 限流期内再点确认 / 放弃：不发包。
      expect((await svc.confirmPending(key, page)).actionRaw).assertEqual(BindPhoneAction.RETRY_AFTER);
      expect((await svc.abandonPending(key, page)).actionRaw).assertEqual(BindPhoneAction.RETRY_AFTER);
      expect(f.count('POST /v1/me/phone')).assertEqual(2);
      expect(f.count('POST /v1/idempotency-keys/abandon')).assertEqual(0);
      // 换号页共用同一闸门。
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      expect(p.confirm(p.snapshot.pendingVersion, key)).assertFalse();
      // 到期后可以再确认。
      f.rig.nowMillis += 10000;
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      expect((await svc.confirmPending(key, page)).actionRaw).assertEqual(BindPhoneAction.DONE);
      expect(f.count('POST /v1/me/phone')).assertEqual(3);
    });

    it('R1_04_bind_page_confirm_success_and_completed_clear_all_step_up_tokens', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const svc: BindPhoneService = bindService(f);
      const page: BindPhoneIdentity = svc.capturePage();
      await svc.bind(NEW_PHONE, '123456', page);
      f.session.tokens.put('withdraw', 'user-1', 'fixture-wallet-token', f.rig.nowMillis + 60000);
      f.session.tokens.put('phone_change', 'user-1', 'fixture-phone-token', f.rig.nowMillis + 60000);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      const done: BindOutcome = await svc.confirmPending(svc.pendingView(page)?.key ?? '', page);
      expect(done.actionRaw).assertEqual(BindPhoneAction.DONE);
      expect(f.session.tokens.size).assertEqual(0);
      // 放弃得知 completed / code=0：同一结算。
      const g: AccountFixture = new AccountFixture();
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const svc2: BindPhoneService = bindService(g);
      const page2: BindPhoneIdentity = svc2.capturePage();
      await svc2.bind(NEW_PHONE, '123456', page2);
      g.session.tokens.put('withdraw', 'user-1', 'fixture-wallet-token', g.rig.nowMillis + 60000);
      g.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) =>
      envelope(0, '{"outcome":"completed","original":{"code":0,"msg":"","data":{}}}'));
      const out: BindOutcome = await svc2.abandonPending(svc2.pendingView(page2)?.key ?? '', page2);
      expect(out.actionRaw).assertEqual(BindPhoneAction.DONE);
      expect(g.session.tokens.size).assertEqual(0);
    });

    it('R1_05_apply_30416_message_uses_this_amount_not_refetched_wallet_negative', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await openDeletion(f);
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(30416, '{"amount_fen":567}'));
      f.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(0, summary(200)));
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.NEGATIVE);
      expect(c.snapshot.negativeText).assertContain('5.67');
      expect(c.snapshot.negativeText.indexOf('2.00') < 0).assertTrue();
      // 缺金额：走 fallback，不借钱包金额。
      const g: AccountFixture = new AccountFixture();
      const d: DeleteAccountController = await openDeletion(g);
      g.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(30416, '{}'));
      g.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(0, summary(200)));
      d.setChecked(d.snapshot.version, true);
      d.apply(d.snapshot.version);
      await settle();
      const fallback: AccountMessage = AccountMessages.of('error.30416', new Map<string, string>(), '', true, true);
      expect(d.snapshot.negativeText).assertEqual(fallback.text);
    });

    it('R1_06_late_44001_while_hidden_is_deferred_until_shown_and_dropped_on_leave', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      p.onHidden();
      f.held[f.held.length - 1].resolve(envelope(44001, '{}'));
      await settle();
      expect(p.snapshot.blocked === null).assertTrue();
      p.onShown();
      expect(p.snapshot.blocked !== null).assertTrue();
      // 出栈：延后的弹窗作废。
      const g: AccountFixture = new AccountFixture();
      const q: PhoneChangeController = await toStep2(g);
      await fillStep2(g, q);
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      q.submit(q.snapshot.version);
      await settle();
      q.onHidden();
      g.held[g.held.length - 1].resolve(envelope(44001, '{}'));
      await settle();
      q.leave();
      q.onShown();
      expect(q.snapshot.blocked === null).assertTrue();
    });

    it('R1_07_scope_only_10405_refresh_only_does_not_force_update_from_page', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.switchAccount('user-1', 'deletion_only');
      f.reply('POST /v1/auth/refresh', (_r: TransportRequest) =>
      envelope(0, tokenPair('access-r2', 'refresh-r2', 'deletion_only')));
      // 本机 1.2.0 ≥ min 1.1.0、会话 deletion_only：网络层 REFRESH_ONLY。
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(10405, '{"min_supported_version":"1.1.0"}'));
      f.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) =>
      envelope(10405, '{"min_supported_version":"1.1.0"}'));
      const c: DeleteAccountController = await openDeletion(f, DeletionSource.FORCE_UPDATE);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
      expect(f.rig.update.calls.length).assertEqual(0);
      expect(f.forced).assertEqual(0);
      // 发码路径同样只看网络层 Effect。
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(10405, '{"min_supported_version":"1.1.0"}'));
      const s: StepUpController = new StepUpController(f.deps(), 'account_deletion', 'user-1');
      s.send();
      await settle();
      expect(f.forced).assertEqual(0);
      expect(f.rig.update.calls.length).assertEqual(0);
    });

    it('R1_08_success_getme_42901_settles_shared_me_gate_both_ways', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.reply('GET /v1/me', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '90' }));
      const before: number = f.count('GET /v1/me');
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
      expect(f.count('GET /v1/me')).assertEqual(before + 1);
      expect(f.meReadGate.active).assertTrue();
      // 随即进注销页：getMe 在发包前被共享闸门拦下。
      await openDeletion(f);
      expect(f.count('GET /v1/me')).assertEqual(before + 1);
    });

    it('R1_09_cancel_unknown_then_refetch_cancelled_settles_as_cancel_success', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      const c: DeleteAccountController = await openDeletion(f, DeletionSource.SETTINGS);
      const exits: AccountMessage[] = [];
      c.exitToSettings = (toast: AccountMessage): void => {
        exits.push(toast);
      };
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      f.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => {
        f.reply('GET /v1/me/deletion', (_q: TransportRequest) => envelope(0, cancelledUser()));
        return gateway();
      });
      expect(c.cancel(c.snapshot.version)).assertTrue();
      await settle();
      expect(exits.length).assertEqual(1);
      expect(exits[0].textKey).assertEqual('deletion.cancelled_toast');
      expect(f.count('POST /v1/me/deletion/cancel')).assertEqual(1);
      // 仍在冷静期：只留人工重试，不自动重发。
      const g: AccountFixture = new AccountFixture();
      g.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      const d: DeleteAccountController = await openDeletion(g, DeletionSource.SETTINGS);
      let gExits: number = 0;
      d.exitToSettings = (_t: AccountMessage): void => {
        gExits++;
      };
      g.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => gateway());
      d.cancel(d.snapshot.version);
      await settle();
      expect(gExits).assertEqual(0);
      expect(stateOf(d)).assertEqual(DeletionPresentation.COOLING);
      expect(d.canCancel).assertTrue();
      expect(g.count('POST /v1/me/deletion/cancel')).assertEqual(1);
    });

    it('R1_10_step_up_sms_42901_keyed_by_account_phone_action', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.session.sync();
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      const a: StepUpController = new StepUpController(f.deps(), 'phone_change', 'user-1');
      expect(a.send()).assertTrue();
      await settle();
      expect(a.snapshot.sendBlocked).assertTrue();
      // 同账号另一个 action：不受影响。
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      const b: StepUpController = new StepUpController(f.deps(), 'account_deletion', 'user-1');
      expect(b.snapshot.sendBlocked).assertFalse();
      expect(b.send()).assertTrue();
      await settle();
      expect(f.count('POST /v1/auth/sms-codes')).assertEqual(2);
      // 同键的新面板（面板关闭后重开）仍受限。
      a.close();
      const c: StepUpController = new StepUpController(f.deps(), 'phone_change', 'user-1');
      expect(c.snapshot.sendBlocked).assertTrue();
      expect(c.send()).assertFalse();
      expect(f.count('POST /v1/auth/sms-codes')).assertEqual(2);
      expect(PHONE.length).assertEqual(11);
    });
  });
}
