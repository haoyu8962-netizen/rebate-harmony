// APP-13a 鸿蒙 harmony-review-r2 的 7 条修复（R2-01 S0、R2-02–R2-07 S1）：真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer）+
// Core 执行器（页面按钮回调调用的同一套方法）。每条至少一个用例；回退对应修复（见 NATIVE/APP-13a/harmony-mutation-fix-r2.txt）时该用例失败。
// 号码只用测试值；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  BindOutcome, BindPhoneAction, BindPhoneFields, BindPhoneForm, BindPhoneFormBinding, BindPhoneIdentity, BindPhoneService,
  DeleteAccountController, DeletionSource, PhoneBindingState, PhoneChangeController, PhoneChangeStep, SendCodeOutcome, SmsSendDeadlines,
  StepUpController, TransportRequest
} from '../../Index';
import { envelope, header, waitUntil } from './NetworkTestRig';
import { AccountFixture, fillStep2, gateway, Host, NEW_PHONE, settle, toStep2 } from './AccountIntegration.test';

const EDITED_PHONE: string = '13700009999';

class TestFields implements BindPhoneFields {
  phoneText: string = '';
  codeText: string = '';
  phoneError: string = '';
  codeError: string = '';
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, ms);
  });
}

function bindService(f: AccountFixture, host: Host = new Host()): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
    host, (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

export default function accountReviewR2Test() {
  describe('AccountReviewR2', () => {
    it('R2_01_bind_form_old_input_send_submit_callbacks_after_session_switch_write_and_send_nothing', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const fieldsA: TestFields = new TestFields();
      const form: BindPhoneForm = new BindPhoneForm(svc, fieldsA);
      let fieldsB: TestFields = new TestFields();
      // 页面的换代处理（BindPhoneView.resetForSession）：换上新模型与新身份。
      svc.subscribeSession((): void => {
        fieldsB = new TestFields();
        form.reset(fieldsB);
      });
      // A 页面渲染出的回调（手机号、验证码输入、清空、发码、提交都捕获这一份绑定）。
      const bA: BindPhoneFormBinding = form.binding();
      expect(form.setPhone(bA, NEW_PHONE)).assertTrue();
      expect(form.setCode(bA, '123456')).assertTrue();
      expect(fieldsA.phoneText).assertEqual(NEW_PHONE);
      // A 会话失效 → 登录 B：同步换代。
      f.switchAccount('user-2');
      expect(svc.syncSession()).assertTrue();
      const pageB: BindPhoneIdentity = form.pageIdentity;
      expect(pageB === bA.identity).assertFalse();
      // 执行保留下来的 A 的旧回调：零写入（新旧模型都不动）、零请求。
      expect(form.setPhone(bA, EDITED_PHONE)).assertFalse();
      expect(form.setCode(bA, '111111')).assertFalse();
      expect(form.clearPhone(bA)).assertFalse();
      const sent: SendCodeOutcome | null = await form.sendCode(bA);
      const bound: BindOutcome | null = await form.submit(bA);
      await settle();
      expect(sent === null).assertTrue();
      expect(bound === null).assertTrue();
      expect(fieldsB.phoneText).assertEqual('');
      expect(fieldsB.codeText).assertEqual('');
      expect(fieldsA.phoneText).assertEqual(NEW_PHONE);
      expect(fieldsA.codeText).assertEqual('123456');
      expect(f.count('POST /v1/auth/sms-codes')).assertEqual(0);
      expect(f.count('POST /v1/me/phone')).assertEqual(0);
      expect(f.rig.pendingBackend.list('user-2').length).assertEqual(0);
      // 别的页面实例的绑定也不认。
      const other: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      expect(form.setPhone(other.binding(), NEW_PHONE)).assertFalse();
      // B 的新绑定照常可用。
      const bB: BindPhoneFormBinding = form.binding();
      expect(form.setPhone(bB, NEW_PHONE)).assertTrue();
      expect(fieldsB.phoneText).assertEqual(NEW_PHONE);
    });

    it('R2_02_held_then_10003_replay_uses_fixed_original_key_and_body_not_edited_form', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
      // held 期间改成另一个号码与验证码再提交：第二次得 10003，二次验证后重放。
      let n: number = 0;
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => {
        n++;
        return n === 1 ? envelope(10003, '{}') : envelope(0, '{}');
      });
      p.setNewPhone(p.snapshot.version, EDITED_PHONE);
      p.setCode(p.snapshot.version, '111111');
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.snapshot.stepUpAction).assertEqual('phone_change');
      const s: StepUpController | null = p.createStepUp();
      expect(s === null).assertFalse();
      (s as StepUpController).setCode('123456');
      expect((s as StepUpController).verify()).assertTrue();
      await settle();
      const posts: TransportRequest[] = f.requests('POST /v1/me/phone');
      expect(posts.length).assertEqual(3);
      const key: string = header(posts[0], 'Idempotency-Key') ?? '';
      expect(key.length > 0).assertTrue();
      expect(header(posts[1], 'Idempotency-Key')).assertEqual(key);
      expect(header(posts[2], 'Idempotency-Key')).assertEqual(key);
      expect(posts[1].body).assertEqual(posts[0].body);
      expect(posts[2].body).assertEqual(posts[0].body);
      expect((posts[2].body ?? '').indexOf(EDITED_PHONE) < 0).assertTrue();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
    });

    it('R2_03_done_page_shows_fixed_summary_of_actually_sent_request_not_edited_form', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      p.setNewPhone(p.snapshot.version, EDITED_PHONE);
      p.setCode(p.snapshot.version, '111111');
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      const posts: TransportRequest[] = f.requests('POST /v1/me/phone');
      expect(posts.length).assertEqual(2);
      expect(posts[1].body).assertEqual(posts[0].body);
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
      // 实际提交成功的是 139****1234，不是表单里后来改的 137****9999。
      expect(p.snapshot.doneMasked).assertEqual('139****1234');
    });

    it('R2_04_bind_page_confirm_settles_and_notifies_phone_change_page_in_flight_cleared', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const svc: BindPhoneService = bindService(f);
      let notified: number = 0;
      svc.subscribePending((): void => {
        notified++;
      });
      const page: BindPhoneIdentity = svc.capturePage();
      expect((await svc.bind(NEW_PHONE, '123456', page)).actionRaw).assertEqual(BindOutcome.PENDING);
      expect(notified).assertEqual(1);
      const key: string = svc.pendingView(page)?.key ?? '';
      expect(key.length > 0).assertTrue();
      // 点确认，请求在途 → 离开 BindPhone → 打开同账号换号页：恢复记录且在途。
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const running: Promise<BindOutcome> = svc.confirmPending(key, page);
      await settle();
      svc.invalidate();
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      expect(p.snapshot.pending?.inFlight).assertTrue();
      expect(p.confirm(p.snapshot.pendingVersion, key)).assertFalse();
      // 原确认返回 20003：存储回到结果未知，并通知两个页面从存储重新同步。
      f.held[0].resolve(envelope(20003, '{}'));
      await running;
      await settle();
      expect(notified).assertEqual(2);
      expect(p.snapshot.pending?.key).assertEqual(key);
      expect(p.snapshot.pending?.inFlight).assertFalse();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(0, '{}'));
      expect(p.confirm(p.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.DONE);
    });

    it('R2_05_delete_page_refreshes_when_wallet_read_gate_expires', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/wallet/summary', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '1' }));
      f.session.sync();
      const c: DeleteAccountController = new DeleteAccountController(f.deps(), DeletionSource.SETTINGS);
      let changes: number = 0;
      c.onChange = (): void => {
        changes++;
      };
      c.onShown();
      await settle();
      expect(c.snapshot.readBlocked).assertTrue();
      expect(c.retry(c.snapshot.version)).assertFalse();
      const before: number = changes;
      // 到期：钱包读取闸门通知 → 注销页刷新快照，【重试】恢复。
      f.rig.nowMillis += 1500;
      // FU-HM-0719 第 3 项：等到期通知交回结论（注销页已刷新且【重试】恢复），不再固定睡 1.3 秒。
      expect(await waitUntil((): boolean => changes > before && !c.snapshot.readBlocked)).assertTrue();
      expect(changes > before).assertTrue();
      expect(c.snapshot.readBlocked).assertFalse();
      c.leave();
    });

    it('R2_06_reopened_step1_panel_schedules_expiry_refresh_for_restored_keyed_rate_limit', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.session.sync();
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '1' }));
      const a: StepUpController = new StepUpController(f.deps(), 'phone_change', 'user-1');
      expect(a.send()).assertTrue();
      await settle();
      expect(a.snapshot.sendBlocked).assertTrue();
      a.close();
      // 别的 action 的长限流把全局 smsGate 延到 90 秒（它的到期通知不会在 1 秒时到）。
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '90' }));
      const w: StepUpController = new StepUpController(f.deps(), 'withdraw', 'user-1');
      expect(w.send()).assertTrue();
      await settle();
      w.close();
      // 在前一个期限内重进换号第 1 步：恢复本键限流，并按本键截止时间到期刷新。
      const b: StepUpController = new StepUpController(f.deps(), 'phone_change', 'user-1');
      let changes: number = 0;
      b.onChange = (): void => {
        changes++;
      };
      expect(b.snapshot.sendBlocked).assertTrue();
      f.rig.nowMillis += 1500;
      await sleep(1300);
      expect(changes > 0).assertTrue();
      expect(b.snapshot.sendBlocked).assertFalse();
      b.close();
    });

    it('R2_07_bind_write_and_bind_sms_not_cancelled_on_leave_and_settle_shared_state', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const host: Host = new Host();
      const svc: BindPhoneService = bindService(f, host);
      const page: BindPhoneIdentity = svc.capturePage();
      // 发码在途 → 离页：传输不取消，截止时间照记。
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      const sending: Promise<SendCodeOutcome> = svc.sendCode(NEW_PHONE, page);
      await settle();
      svc.invalidate();
      f.held[0].resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      const sent: SendCodeOutcome = await sending;
      expect(sent.stateRaw).assertEqual(BindOutcome.STALE);
      expect(svc.sendState(NEW_PHONE).countdownSec > 0).assertTrue();
      // 绑定在途 → 离页：写请求不取消；成功照常结算（绑手机、getMe、未决记录删除），页面结果只作废。
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const binding: Promise<BindOutcome> = svc.bind(NEW_PHONE, '123456', page);
      await settle();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
      svc.invalidate();
      expect(f.rig.server.cancelled.length).assertEqual(0);
      f.held[1].resolve(envelope(0, '{}'));
      const out: BindOutcome = await binding;
      await settle();
      expect(out.actionRaw).assertEqual(BindOutcome.STALE);
      expect(f.rig.server.cancelled.length).assertEqual(0);
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
      expect(host.bound).assertEqual(1);
      expect(f.count('GET /v1/me') > 0).assertTrue();
      expect(BindPhoneAction.DONE.length > 0).assertTrue();
    });
  });
}
