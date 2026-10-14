// APP-13a 鸿蒙 harmony-review-r3 的 5 条窄修（R3-01–R3-05，均 S1）：真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer）+
// Core 执行器（页面按钮回调与返回处理调用的同一套方法）。每条一个用例；回退对应修复（见 NATIVE/APP-13a/harmony-mutation-fix-r3.txt）时该用例失败。
// 号码只用测试值；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  BindOutcome, BindPhoneAction, BindPhoneFields, BindPhoneForm, BindPhoneFormBinding, BindPhonePagePermit, BindPhoneService,
  PhoneBindingState, PhoneChangeController, PhoneChangeStep, PhoneChangeStep1Buttons, SmsSendDeadlines, StepUpSnapshot,
  TransportRequest, TransportResponse
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { AccountFixture, fillStep2, gateway, Host, NEW_PHONE, settle, toStep2 } from './AccountIntegration.test';

class TestFields implements BindPhoneFields {
  phoneText: string = '';
  codeText: string = '';
  phoneError: string = '';
  codeError: string = '';
}

function bindService(f: AccountFixture, host: Host = new Host()): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
    host, (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

/** BindPhone 页填好号码与验证码后的渲染时绑定。 */
function filled(form: BindPhoneForm): BindPhoneFormBinding {
  const b: BindPhoneFormBinding = form.binding();
  form.setPhone(b, NEW_PHONE);
  form.setCode(b, '123456');
  return form.binding();
}

/** 换号页留下一条结果未知的未决记录（提交得到网关错误页），返回停在待确认的页面。 */
async function pendingPhoneChange(f: AccountFixture): Promise<PhoneChangeController> {
  const a: PhoneChangeController = await toStep2(f);
  await fillStep2(f, a);
  f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
  a.submit(a.snapshot.version);
  await settle();
  return a;
}

export default function accountReviewR3Test() {
  describe('AccountReviewR3', () => {
    it('R3_01_bind_page_confirm_in_flight_then_leave_then_10001_navigates_zero_times', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const first: BindOutcome | null = await form.submit(filled(form));
      expect(first?.actionRaw).assertEqual(BindOutcome.PENDING);
      const key: string = svc.pendingView(form.pageIdentity)?.key ?? '';
      expect(key.length > 0).assertTrue();
      // 点【确认上一次提交】（点击时取页面许可），请求在途 → 返回离页（同步离页出口）→ 原请求返回 10001。
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const permit: BindPhonePagePermit = form.permit();
      const running: Promise<BindOutcome | null> = form.confirmPending(key, permit);
      await settle();
      form.leave();
      svc.invalidate();
      expect(form.permitted(permit)).assertFalse();
      f.held[f.held.length - 1].resolve(envelope(10001, '{}'));
      const out: BindOutcome | null = await running;
      await settle();
      // 页面的结果处理（BindPhoneView.pendingSettled）只在拿到结果时导航：离页后 0 次。
      let navigations: number = 0;
      if (out !== null && out.route !== null) {
        navigations++;
      }
      expect(navigations).assertEqual(0);
      expect(out === null).assertTrue();
      // 共享结算照常：请求确实发出并回来，10001 不结束键，未决记录仍在、不在途。
      expect(f.count('POST /v1/me/phone')).assertEqual(2);
      expect(f.rig.client.pendingFor(BindPhoneService.BIND_OPERATION)?.key).assertEqual(key);
    });

    it('R3_02_phone_change_abandon_in_flight_reenter_abandoned_lands_on_step1_without_token', 0, async () => {
      const replies: TransportResponse[] = [envelope(0, '{"outcome":"abandoned","original":null}'), envelope(20903, '{}')];
      for (const reply of replies) {
        const f: AccountFixture = new AccountFixture();
        const a: PhoneChangeController = await pendingPhoneChange(f);
        expect(a.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
        const key: string = a.snapshot.pending?.key ?? '';
        expect(key.length > 0).assertTrue();
        // 点【放弃上一次提交】，请求在途 → 返回设置 → 重新进入换号：新页面显示在途的待确认。
        f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) => null);
        expect(a.abandon(a.snapshot.pendingVersion, key)).assertTrue();
        await settle();
        a.leave();
        const stepUps: number = f.count('POST /v1/auth/step-up');
        const b: PhoneChangeController = new PhoneChangeController(f.deps());
        b.onShown();
        expect(b.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
        // 原放弃返回 abandoned / 20903：新页面回第 1 步、清空、重新验证（flow-map 11.2.8），不能直接进第 2 步。
        f.held[f.held.length - 1].resolve(reply);
        await settle();
        expect(b.snapshot.pending === null).assertTrue();
        expect(b.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
        expect(b.snapshot.notice?.textKey).assertEqual('pending_confirm.abandoned');
        expect(b.snapshot.newPhone).assertEqual('');
        expect(b.snapshot.code).assertEqual('');
        expect(f.session.tokens.has('phone_change')).assertFalse();
        expect(f.count('POST /v1/auth/step-up')).assertEqual(stepUps);
        // 不能发新号码的验证码、不能提交。
        b.setNewPhone(b.snapshot.version, NEW_PHONE);
        expect(b.canSendBind).assertFalse();
        expect(b.sendBind(b.snapshot.version)).assertFalse();
        expect(b.canSubmit).assertFalse();
        b.leave();
      }
    });

    it('R3_03_late_first_bind_success_after_reopen_keeps_new_bind_page', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const host: Host = new Host();
      const svc: BindPhoneService = bindService(f, host);
      // 导航栈里的 BindPhone 实例（页面按 navDestinationId 只退出自己）。
      const stack: BindPhoneForm[] = [];
      let resumed: number = 0;
      const formA: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      stack.push(formA);
      // 首次绑定在途 → 返回（A 出栈）→ 重新打开 BindPhone（B）。
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const running: Promise<BindOutcome | null> = formA.submit(filled(formA));
      await settle();
      formA.leave();
      svc.invalidate();
      stack.splice(stack.indexOf(formA), 1);
      const formB: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      stack.push(formB);
      // 旧请求成功。
      f.held[f.held.length - 1].resolve(envelope(0, '{}'));
      const out: BindOutcome | null = await running;
      await settle();
      // A 页面的结果处理（BindPhoneView.bind → onBound：退出自己的导航实例 + 恢复待办）只在原页面许可有效时执行。
      if (out !== null && out.actionRaw === BindPhoneAction.DONE) {
        const own: number = stack.indexOf(formA);
        stack.splice(own >= 0 ? own : stack.length - 1, 1);
        resumed++;
      }
      expect(out === null).assertTrue();
      expect(resumed).assertEqual(0);
      // 新页仍在、仍可用。
      expect(stack.length).assertEqual(1);
      expect(stack[0] === formB).assertTrue();
      expect(formB.live(formB.binding())).assertTrue();
      // 共享结算照常：绑手机（host 共享出口 1 次）、getMe、未决记录删除。
      expect(host.bound).assertEqual(1);
      expect(f.count('GET /v1/me') > 0).assertTrue();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
    });

    it('R3_04_step1_send_42901_does_not_disable_next_with_valid_code', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.session.sync();
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      p.onShown();
      expect(p.sendStep1(p.snapshot.version)).assertTrue();
      await settle();
      // 倒计时结束后重新获取，返回 42901。
      f.rig.nowMillis += 61000;
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '60' }));
      expect(p.sendStep1(p.snapshot.version)).assertTrue();
      await settle();
      // 输入仍有效的原验证码。
      expect(p.setStep1Code(p.snapshot.version, '123456')).assertTrue();
      const s1: StepUpSnapshot = p.snapshot.step1;
      expect(s1.sendBlocked).assertTrue();
      expect(s1.verifyBlocked).assertFalse();
      // 【获取验证码】只看发码限制，【下一步】只看验证限制。
      expect(PhoneChangeStep1Buttons.sendBlocked(s1)).assertTrue();
      expect(PhoneChangeStep1Buttons.nextBlocked(s1)).assertFalse();
      expect(PhoneChangeStep1Buttons.nextEnabled(s1, p.snapshot.phoneKnown)).assertTrue();
      expect(p.canNext).assertTrue();
      expect(p.next(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      p.leave();
      // 反向：验证限流不禁用发码。
      const q: PhoneChangeController = new PhoneChangeController(f.deps());
      f.session.verifyGate.start(60000);
      q.setStep1Code(q.snapshot.version, '123456');
      const t1: StepUpSnapshot = q.snapshot.step1;
      expect(PhoneChangeStep1Buttons.nextEnabled(t1, q.snapshot.phoneKnown)).assertFalse();
      expect(PhoneChangeStep1Buttons.sendBlocked(t1)).assertEqual(t1.sendBlocked);
      q.leave();
    });

    it('R3_05_back_on_step2_returns_to_step1_without_submit_and_keeps_controller', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect(f.session.tokens.has('phone_change')).assertTrue();
      const posts: number = f.count('POST /v1/me/phone');
      // 系统返回 / 页面返回（SettingsView.phoneBack → controller.back）：处理掉、不关子页。
      expect(p.back()).assertTrue();
      expect(p.alive).assertTrue();
      expect(p.snapshot.dead).assertFalse();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
      expect(p.snapshot.newPhone).assertEqual('');
      expect(p.snapshot.code).assertEqual('');
      expect(f.session.tokens.has('phone_change')).assertFalse();
      expect(f.count('POST /v1/me/phone')).assertEqual(posts);
      // 第 1 步再返回：交给设置页退出。
      expect(p.back()).assertFalse();
      // 重新验证后照常进第 2 步。
      p.setStep1Code(p.snapshot.version, '123456');
      expect(p.next(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      p.leave();
    });
  });
}
