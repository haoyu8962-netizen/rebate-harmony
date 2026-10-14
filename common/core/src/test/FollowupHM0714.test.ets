// FU-HM-0714 鸿蒙跟进合集三：F-HM-31（BindPhone 老用户 phone_bound 补查只退出原导航实例）、F-HM-32（换号第 2 步返回第 1 步后，
// 旧发码的迟到结果不写进换代后的表单）。真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer）+ Core 执行器（页面回调与返回处理
// 调用的同一套方法）。回退对应修复（见 NATIVE/FU-HM-0714/mutations.txt）时对应用例失败。号码只用测试值；没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  BindPhoneFields, BindPhoneForm, BindPhoneRecheck, BindPhoneService, KeyedDeadlines, OwnPageExit, PhoneBindingState,
  PhoneChangeController, PhoneChangeStep, SmsSendDeadlines, TransportRequest
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { AccountFixture, Host, NEW_PHONE, settle, toStep2 } from './AccountIntegration.test';

class TestFields implements BindPhoneFields {
  phoneText: string = '';
  codeText: string = '';
  phoneError: string = '';
  codeError: string = '';
}

function bindService(f: AccountFixture): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
    new Host(), (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

/** 导航栈里的一个 BindPhone 实例（navDestinationId + 页面表单）。 */
class NavEntry {
  readonly id: string;
  readonly form: BindPhoneForm;

  constructor(id: string, form: BindPhoneForm) {
    this.id = id;
    this.form = form;
  }
}

/** AppBindPhonePage.exitOwnInstance 的同一判定：栈顶是本实例就 pop，否则只按 navDestinationId 移除本实例。 */
function exitOwn(stack: NavEntry[], ownId: string): void {
  const top: NavEntry | undefined = stack.length > 0 ? stack[stack.length - 1] : undefined;
  const plan: string = OwnPageExit.plan(ownId, top !== undefined ? top.id : null);
  if (plan === OwnPageExit.POP) {
    stack.pop();
  } else if (plan === OwnPageExit.REMOVE) {
    const at: number = stack.findIndex((e: NavEntry): boolean => e.id === ownId);
    if (at >= 0) {
      stack.splice(at, 1);
    }
  }
}

/** 补查的「查 getMe」：由测试决定何时、以什么结果返回。 */
class HeldCheck {
  private done: ((bound: boolean) => void) | null = null;

  readonly check: () => Promise<boolean> = (): Promise<boolean> =>
    new Promise<boolean>((resolve: (bound: boolean) => void): void => {
      this.done = resolve;
    });

  resolve(bound: boolean): void {
    const done: ((bound: boolean) => void) | null = this.done;
    if (done !== null) {
      done(bound);
    }
  }
}

/** SettingsView.phoneBack 的同一处理（页面返回 PhoneChangeView.onBack 与系统返回 systemBack 都走这里）。 */
function phoneBack(c: PhoneChangeController, closeSub: () => void): void {
  if (c.back()) {
    return;
  }
  closeSub();
}

const OLD_PHONE: string = '123';

export default function followupHM0714Test() {
  describe('FollowupHM0714', () => {
    it('fuhm0714_hm31_recheck_bound_exits_only_original_instance_reopened_page_stays', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const stack: NavEntry[] = [];
      // 原页面 A 打开，补查在途；随后经允许的入口又打开了一个 BindPhone（B，盖在 A 上面）。
      const a: NavEntry = new NavEntry('nav-a', new BindPhoneForm(svc, new TestFields()));
      stack.push(a);
      const held: HeldCheck = new HeldCheck();
      const running: Promise<string> = a.form.recheckBound(held.check);
      const b: NavEntry = new NavEntry('nav-b', new BindPhoneForm(svc, new TestFields()));
      stack.push(b);
      // A 的补查查清已绑：A 的页面许可仍有效 → 只退出 A 这一个导航实例（AppLogin → config.onRecheckBound）。
      held.resolve(true);
      const result: string = await running;
      expect(result).assertEqual(BindPhoneRecheck.BOUND_HERE);
      let shared: number = 0;
      if (result !== BindPhoneRecheck.UNBOUND) {
        shared++;
      }
      if (result === BindPhoneRecheck.BOUND_HERE) {
        exitOwn(stack, a.id);
      }
      // 新页仍在、旧实例退出（按路由名移除会把 B 也删掉）。
      expect(stack.length).assertEqual(1);
      expect(stack[0] === b).assertTrue();
      expect(b.form.live(b.form.binding())).assertTrue();
      expect(shared).assertEqual(1);
    });

    it('fuhm0714_hm31_recheck_after_original_left_and_reopen_keeps_new_page', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const stack: NavEntry[] = [];
      const a: NavEntry = new NavEntry('nav-a', new BindPhoneForm(svc, new TestFields()));
      stack.push(a);
      const held: HeldCheck = new HeldCheck();
      const running: Promise<string> = a.form.recheckBound(held.check);
      // 补查在途 → 返回（A 同步离页出口、出栈）→ 重新打开 BindPhone（B）。
      a.form.leave();
      svc.invalidate();
      stack.splice(stack.indexOf(a), 1);
      const b: NavEntry = new NavEntry('nav-b', new BindPhoneForm(svc, new TestFields()));
      stack.push(b);
      held.resolve(true);
      const result: string = await running;
      // A 的许可已失效：只做共享结算（守卫重算），不出栈、不恢复待办。
      expect(result).assertEqual(BindPhoneRecheck.BOUND_LEFT);
      let exits: number = 0;
      if (result === BindPhoneRecheck.BOUND_HERE) {
        exits++;
        exitOwn(stack, a.id);
      }
      expect(exits).assertEqual(0);
      expect(stack.length).assertEqual(1);
      expect(stack[0] === b).assertTrue();
      expect(b.form.live(b.form.binding())).assertTrue();
      // 没查清 / 未绑：什么都不做。
      const held2: HeldCheck = new HeldCheck();
      const second: Promise<string> = b.form.recheckBound(held2.check);
      held2.resolve(false);
      expect(await second).assertEqual(BindPhoneRecheck.UNBOUND);
      expect(stack.length).assertEqual(1);
    });

    it('fuhm0714_hm32_page_back_in_flight_send_20001_not_shown_under_new_phone', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      // 第 2 步输入 123 并发码，请求在途。
      expect(p.setNewPhone(p.snapshot.version, OLD_PHONE)).assertTrue();
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      expect(p.sendBind(p.snapshot.version)).assertTrue();
      await settle();
      const sends: number = f.count('POST /v1/auth/sms-codes');
      // 页面返回（PhoneChangeView.onBack → phoneBack）：回第 1 步，控制器保留。
      let closed: number = 0;
      phoneBack(p, (): void => {
        closed++;
      });
      expect(closed).assertEqual(0);
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
      // 重新验证进入第 2 步，填有效新号。
      p.setStep1Code(p.snapshot.version, '123456');
      expect(p.next(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect(p.setNewPhone(p.snapshot.version, NEW_PHONE)).assertTrue();
      // 旧发码返回 20001。
      f.held[f.held.length - 1].resolve(envelope(20001, '{}'));
      await settle();
      // 新号码下不显示旧结果；表单不被改写。
      expect(p.snapshot.phoneError === null).assertTrue();
      expect(p.snapshot.banner === null).assertTrue();
      expect(p.snapshot.codeSent).assertFalse();
      expect(p.snapshot.newPhone).assertEqual(NEW_PHONE);
      // 共享部分照常结算：旧号的发码不再在途，新号可以发码。
      const oldKey: string = KeyedDeadlines.key('user-1', OLD_PHONE, 'bind');
      expect(f.session.bindSms.sending(oldKey)).assertFalse();
      expect(p.snapshot.sending).assertFalse();
      expect(p.canSendBind).assertTrue();
      expect(f.count('POST /v1/auth/sms-codes')).assertEqual(sends);
      p.leave();
    });

    it('fuhm0714_hm32_system_back_in_flight_send_late_result_settles_shared_limits_only', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      expect(p.setNewPhone(p.snapshot.version, OLD_PHONE)).assertTrue();
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      expect(p.sendBind(p.snapshot.version)).assertTrue();
      await settle();
      // 系统返回（SettingsView.systemBack → phoneBack）：回第 1 步，控制器保留。
      let closed: number = 0;
      phoneBack(p, (): void => {
        closed++;
      });
      expect(closed).assertEqual(0);
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
      // 旧发码在第 1 步时返回 20001：不写进任何表单。
      f.held[f.held.length - 1].resolve(envelope(20001, '{}'));
      await settle();
      expect(p.snapshot.phoneError === null).assertTrue();
      expect(p.snapshot.banner === null).assertTrue();
      // 重新验证进入第 2 步，填有效新号：仍不显示旧错误。
      p.setStep1Code(p.snapshot.version, '123456');
      expect(p.next(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect(p.setNewPhone(p.snapshot.version, NEW_PHONE)).assertTrue();
      await settle();
      expect(p.snapshot.phoneError === null).assertTrue();
      expect(p.snapshot.banner === null).assertTrue();
      expect(p.snapshot.codeSent).assertFalse();
      // 迟到的 42901：限流按共享截止时间结算（同号重填时照样限流），但不弹横幅、不写错误。
      p.setNewPhone(p.snapshot.version, OLD_PHONE);
      expect(p.sendBind(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.back()).assertTrue();
      p.setStep1Code(p.snapshot.version, '123456');
      expect(p.next(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.setNewPhone(p.snapshot.version, OLD_PHONE)).assertTrue();
      f.held[f.held.length - 1].resolve(envelope(42901, '{}', { 'Retry-After': '60' }));
      await settle();
      const oldKey: string = KeyedDeadlines.key('user-1', OLD_PHONE, 'bind');
      expect(f.session.bindSms.rateLimited(oldKey, f.rig.nowMillis)).assertTrue();
      expect(p.snapshot.sendRateLimited).assertTrue();
      expect(p.canSendBind).assertFalse();
      expect(p.snapshot.banner === null).assertTrue();
      expect(p.snapshot.phoneError === null).assertTrue();
      p.leave();
    });
  });
}
