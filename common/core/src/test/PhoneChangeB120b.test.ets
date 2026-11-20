// FU-HM-PHONECHANGE-B120B（鸿蒙换手机号对齐 B1-20b；任务书 NATIVE/PHONECHANGE-B120B/brief-harmony.md §1、§2）：
// 30414（换号开关关闭）一律「弹窗 + 回设置页」、新号等于当前号的 20001 文案、首次绑定 / 提现 / 收款零变化。
// 真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer）+ Core 执行器（页面按钮回调调用的同一套方法，按钮回调只带渲染时的版本）。
// 号码只用测试值；测试里没有像密钥的字面量。
//
// 实现须提供的接口（写手替实现方定，详见 tests-handback-harmony.md「实现须提供的接口」）：
// - PhoneChangeSnapshot.disabledDialog: AccountMessage | null —— 「换号已关闭」弹窗；正文键 textKey = 'error.30414'；没有弹窗为 null。
//   页面不可见时不置位，回到可见（onShown）再置位（照 44001 延后弹窗）。HEAD 上没有这个字段：经 Reflect.get 读，读到 undefined 视为没弹。
// - 弹窗【知道了】= 既有 finish(renderVersion)：弹窗在时也放行，调 onFinished（与结果页【完成】同一出口）。
// - 弹窗【联系客服】= 既有 contactCs()：弹窗在时先走客服出口（d.customerService），再调 onFinished。
// 每条用例上方写「先红」：先红 = 当前 HEAD（1e56883，未实现）上这条怎样；标「防改错」的是现状已对、钉住不许改坏的。
import { describe, it, expect } from '@ohos/hypium';
import {
  BindOutcome, BindPhoneAction, BindPhoneFields, BindPhoneForm, BindPhonePagePermit, BindPhoneService, PhoneBindingState,
  PhoneChangeController, PhoneChangeStep, SmsSendDeadlines, StepUpController, TransportRequest
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { AccountFixture, fillStep2, gateway, Host, NEW_PHONE, settle, toStep2 } from './AccountIntegration.test';

/** 快照上的新字段名（实现须提供，见文件头）。 */
const DIALOG: string = 'disabledDialog';
const EDITED: string = '13700007777';

class TestFields implements BindPhoneFields {
  phoneText: string = '';
  codeText: string = '';
  phoneError: string = '';
  codeError: string = '';
}

/** onFinished 的调用次数，以及调用时客服出口已被调过几次（核对「先客服、后关子页」）。 */
class Finished {
  n: number = 0;
  csAtFinish: number = -1;
}

function watchFinish(f: AccountFixture, p: PhoneChangeController): Finished {
  const c: Finished = new Finished();
  p.onFinished = (): void => {
    c.n++;
    c.csAtFinish = f.cs;
  };
  return c;
}

/** 「换号已关闭」弹窗：没弹为 'none'，弹了为 'dialog:' + 正文键。 */
function dialogKey(p: PhoneChangeController): string {
  const d: Object | null | undefined = Reflect.get(p.snapshot, DIALOG) as Object | null | undefined;
  if (d === undefined || d === null) {
    return 'none';
  }
  const k: Object | undefined = Reflect.get(d, 'textKey') as Object | undefined;
  return 'dialog:' + String(k);
}

function sentCount(f: AccountFixture): number {
  return f.rig.server.received.length;
}

/** 第 1 步与第 2 步的旧按钮回调（渲染时的旧版本与当前版本各来一遍）：弹窗出现后都不许再发请求。 */
function pokeAll(p: PhoneChangeController, old: number): void {
  const vs: number[] = [old, p.snapshot.version];
  for (const v of vs) {
    p.sendStep1(v);
    p.setStep1Code(v, '123456');
    p.next(v);
    p.setNewPhone(v, EDITED);
    p.sendBind(v);
    p.setCode(v, '654321');
    p.submit(v);
  }
}

/** 换号页留下一条结果未知的未决记录（提交得到网关错误页），停在待确认（同 FollowupHM0722 的 pendingPhoneChange）。 */
async function pendingPhoneChange(f: AccountFixture): Promise<PhoneChangeController> {
  const a: PhoneChangeController = await toStep2(f);
  await fillStep2(f, a);
  f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
  a.submit(a.snapshot.version);
  await settle();
  return a;
}

function bindService(f: AccountFixture): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
    new Host(), (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

export default function phoneChangeB120bTest() {
  describe('PhoneChangeB120b', () => {
    // ================================================================ 30414：第 1 步

    // 依据：brief §1-1（第 1 步发码）、§1-2（不改 StepUpController，看面板快照 error 键识别）；后端 sms-code-requests.ts:92-96。
    // 先红：HEAD 只把 error.30414 写进第 1 步红字、停在第 1 步可再发（快照没有 disabledDialog → 'none'）。
    it('pcb_1_step1_send_30414_dialog_ok_finishes_once_old_callbacks_send_nothing', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(30414, '{}'));
      f.session.sync();
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      const done: Finished = watchFinish(f, p);
      p.onShown();
      const v0: number = p.snapshot.version;
      expect(p.sendStep1(v0)).assertTrue();
      await settle();
      expect(f.count('POST /v1/auth/sms-codes')).assertEqual(1);
      expect(dialogKey(p)).assertEqual('dialog:error.30414');
      // 弹窗不自己关子页，等用户点按钮。
      expect('auto-finish:' + done.n).assertEqual('auto-finish:0');
      // 弹窗在时：旧回调（发码、输入、下一步、第 2 步各按钮）零请求。
      const before: number = sentCount(f);
      pokeAll(p, v0);
      await settle();
      expect('during:' + (sentCount(f) - before)).assertEqual('during:0');
      // 【知道了】→ 与结果页【完成】同一出口，回设置页 1 次。
      expect(p.finish(p.snapshot.version)).assertTrue();
      expect('finished:' + done.n).assertEqual('finished:1');
      expect(f.cs).assertEqual(0);
      pokeAll(p, v0);
      await settle();
      expect('after:' + (sentCount(f) - before)).assertEqual('after:0');
      p.leave();
    });

    // 依据：brief §1-1（第 1 步二次验证 stepUp phone_change）；后端 step-up.ts:405-410。【联系客服】沿用 contactCs() 统一出口。
    // 先红：HEAD 只在第 1 步显示 error.30414 红字，验证码不清，【下一步】可再点再发。
    it('pcb_2_step1_verify_30414_dialog_contact_cs_then_finishes_once', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('POST /v1/auth/step-up', (_r: TransportRequest) => envelope(30414, '{}'));
      f.session.sync();
      const p: PhoneChangeController = new PhoneChangeController(f.deps());
      const done: Finished = watchFinish(f, p);
      p.onShown();
      const v0: number = p.snapshot.version;
      p.sendStep1(v0);
      await settle();
      p.setStep1Code(p.snapshot.version, '123456');
      expect(p.next(p.snapshot.version)).assertTrue();
      await settle();
      expect(f.count('POST /v1/auth/step-up')).assertEqual(1);
      expect(dialogKey(p)).assertEqual('dialog:error.30414');
      expect(p.snapshot.step === PhoneChangeStep.STEP2).assertFalse();
      expect(f.session.tokens.has('phone_change')).assertFalse();
      expect('auto-finish:' + done.n).assertEqual('auto-finish:0');
      const before: number = sentCount(f);
      pokeAll(p, v0);
      await settle();
      expect('during:' + (sentCount(f) - before)).assertEqual('during:0');
      // 【联系客服】：客服出口 1 次，之后关子页回设置 1 次（关子页时客服已打开）。
      expect(p.contactCs()).assertTrue();
      expect(f.cs).assertEqual(1);
      expect('finished:' + done.n).assertEqual('finished:1');
      expect('cs-before-finish:' + done.csAtFinish).assertEqual('cs-before-finish:1');
      p.leave();
    });

    // ================================================================ 30414：第 2 步提交

    // 依据：brief §1-1（第 2 步提交 bindPhone）、弹窗前后表单与 phone_change 令牌作废；后端 bind-phone.ts:266-275。
    // 先红：HEAD 停在第 2 步、横幅 + 【联系客服】，新号 / 码 / 令牌保留，可再提交（AccountFlows :83 的现状）。
    it('pcb_3_step2_submit_30414_dialog_token_dropped_cannot_resubmit_ok_finishes', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      const done: Finished = watchFinish(f, p);
      await fillStep2(f, p);
      expect(f.session.tokens.has('phone_change')).assertTrue();
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      const v0: number = p.snapshot.version;
      expect(p.submit(v0)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      expect(dialogKey(p)).assertEqual('dialog:error.30414');
      expect('token:' + f.session.tokens.has('phone_change')).assertEqual('token:false');
      expect('canSubmit:' + p.canSubmit).assertEqual('canSubmit:false');
      expect('auto-finish:' + done.n).assertEqual('auto-finish:0');
      const before: number = sentCount(f);
      pokeAll(p, v0);
      await settle();
      expect('during:' + (sentCount(f) - before)).assertEqual('during:0');
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      expect(p.finish(p.snapshot.version)).assertTrue();
      expect('finished:' + done.n).assertEqual('finished:1');
      p.leave();
    });

    // 依据：brief §1-1「30414 不再算号码类反馈」（PhoneChangeController.fieldFeedback 把 30414 除外）：held 原键原体重发的是旧号码、
    // 用户之后改了新号，回 30414 也照样弹窗 + 回设置（开关关闭与号码无关）。
    // 先红：HEAD 把 30414 当号码类反馈过滤，什么都不显示、停在第 2 步（FollowupHM0722 :787 的现状）。
    it('pcb_3b_held_resend_30414_after_editing_new_phone_still_dialog', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      const done: Finished = watchFinish(f, p);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
      p.setNewPhone(p.snapshot.version, EDITED);
      p.setCode(p.snapshot.version, '222222');
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      expect((f.last('POST /v1/me/phone').body ?? '').indexOf(NEW_PHONE) >= 0).assertTrue();
      expect('held:' + dialogKey(p)).assertEqual('held:dialog:error.30414');
      expect('held-canSubmit:' + p.canSubmit).assertEqual('held-canSubmit:false');
      expect(p.finish(p.snapshot.version)).assertTrue();
      expect('finished:' + done.n).assertEqual('finished:1');
      p.leave();
    });

    // ================================================================ 30414：10003 面板

    // 依据：brief §1-1（提交拿 10003 后打开的二次验证面板里的发码 / 验证）、§1-2（关面板、落弹窗；不改 StepUpController）。
    // 面板与第 1 步共用发码键（账号 + 号码 + phone_change），先把时钟拨过第 1 步的 60 秒倒计时，面板才真正发码。
    // 先红：HEAD 面板只显示 error.30414 红字，stepUpAction 仍为 phone_change（面板不关）。
    it('pcb_4_step_up_panel_send_or_verify_30414_closes_panel_dialog_finishes', 0, async () => {
      const segments: string[] = ['send', 'verify'];
      for (const seg of segments) {
        const f: AccountFixture = new AccountFixture();
        let n: number = 0;
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => {
          n++;
          return n === 1 ? envelope(10003, '{}') : envelope(0, '{}');
        });
        const p: PhoneChangeController = await toStep2(f);
        const done: Finished = watchFinish(f, p);
        await fillStep2(f, p);
        p.submit(p.snapshot.version);
        await settle();
        expect(p.snapshot.stepUpAction).assertEqual('phone_change');
        const s: StepUpController | null = p.createStepUp();
        expect(s !== null).assertTrue();
        const panel: StepUpController = s as StepUpController;
        if (seg === 'send') {
          f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(30414, '{}'));
          f.rig.nowMillis += 61000;
          expect(panel.send()).assertTrue();
        } else {
          f.reply('POST /v1/auth/step-up', (_r: TransportRequest) => envelope(30414, '{}'));
          panel.setCode('123456');
          expect(panel.verify()).assertTrue();
        }
        await settle();
        expect(seg + '-panel:' + String(p.snapshot.stepUpAction)).assertEqual(seg + '-panel:null');
        expect(seg + ':' + dialogKey(p)).assertEqual(seg + ':dialog:error.30414');
        expect(seg + '-auto-finish:' + done.n).assertEqual(seg + '-auto-finish:0');
        // 面板与本页的旧回调零请求；原键不再重放。
        const before: number = sentCount(f);
        panel.send();
        panel.setCode('123456');
        panel.verify();
        pokeAll(p, p.snapshot.version);
        await settle();
        expect(seg + '-during:' + (sentCount(f) - before)).assertEqual(seg + '-during:0');
        expect(f.count('POST /v1/me/phone')).assertEqual(1);
        expect(p.finish(p.snapshot.version)).assertTrue();
        expect(seg + '-finished:' + done.n).assertEqual(seg + '-finished:1');
        p.leave();
      }
    });

    // ================================================================ 30414：待确认

    // 依据：brief §1-1（待确认【确认】得 30414）。
    // 先红：HEAD 回第 2 步、横幅 + 客服、新号 / 码 / 令牌保留、canSubmit 为真（FollowupHM0722 :319 的现状）。
    it('pcb_5a_pending_confirm_30414_same_page_dialog_and_finishes', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const a: PhoneChangeController = await pendingPhoneChange(f);
      const done: Finished = watchFinish(f, a);
      expect(a.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      const key: string = a.snapshot.pending?.key ?? '';
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      expect(a.confirm(a.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(f.rig.client.pendingFor('bindPhone') === null).assertTrue();
      expect(dialogKey(a)).assertEqual('dialog:error.30414');
      expect('token:' + f.session.tokens.has('phone_change')).assertEqual('token:false');
      expect('canSubmit:' + a.canSubmit).assertEqual('canSubmit:false');
      const posts: number = f.count('POST /v1/me/phone');
      a.submit(a.snapshot.version);
      await settle();
      expect(f.count('POST /v1/me/phone')).assertEqual(posts);
      expect(a.finish(a.snapshot.version)).assertTrue();
      expect('finished:' + done.n).assertEqual('finished:1');
      a.leave();
    });

    // 依据：brief §1-1（别处——另一个换号实例或 BindPhone 页——结算同一键得 30414）。
    // 先红：HEAD 上 B 回第 2 步、横幅 + 客服、可填好后提交（FollowupHM0722 :342、:389-410 的现状）。
    it('pcb_5b_pending_settled_30414_elsewhere_by_other_instance_or_bind_page_dialog_on_b', 0, async () => {
      // 另一个换号实例：A 点【确认】、回包挂住后离页；B 进来显示同键待确认；回包 30414。
      let f: AccountFixture = new AccountFixture();
      const a: PhoneChangeController = await pendingPhoneChange(f);
      const key: string = a.snapshot.pending?.key ?? '';
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      expect(a.confirm(a.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      a.leave();
      let b: PhoneChangeController = new PhoneChangeController(f.deps());
      let done: Finished = watchFinish(f, b);
      b.onShown();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      f.held[f.held.length - 1].resolve(envelope(30414, '{}'));
      await settle();
      expect('instance:' + dialogKey(b)).assertEqual('instance:dialog:error.30414');
      expect('instance-canSubmit:' + b.canSubmit).assertEqual('instance-canSubmit:false');
      expect(b.finish(b.snapshot.version)).assertTrue();
      expect('instance-finished:' + done.n).assertEqual('instance-finished:1');
      b.leave();
      // BindPhone 页（首次绑定）确认同一键得 30414：换号页 B 同样弹窗 + 回设置。
      f = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      form.setPhone(form.binding(), NEW_PHONE);
      form.setCode(form.binding(), '123456');
      const first: BindOutcome | null = await form.submit(form.binding());
      expect(first?.actionRaw).assertEqual(BindOutcome.PENDING);
      const bindKey: string = svc.pendingView(form.pageIdentity)?.key ?? '';
      f.session.sync();
      b = new PhoneChangeController(f.deps());
      done = watchFinish(f, b);
      b.onShown();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      const permit: BindPhonePagePermit = form.permit();
      const own: BindOutcome | null = await form.confirmPending(bindKey, permit);
      await settle();
      // BindPhone 页自己照旧（首次绑定零变化）：错误 + 客服入口。
      expect(own?.ended).assertTrue();
      expect(own?.customerService).assertTrue();
      expect('bind-page:' + dialogKey(b)).assertEqual('bind-page:dialog:error.30414');
      expect(b.contactCs()).assertTrue();
      expect('bind-page-finished:' + done.n).assertEqual('bind-page-finished:1');
      b.leave();
      form.leave();
    });

    // 依据：brief §1-1（【放弃】得 completed 原结果 30414 → 弹窗 + 回设置；不再出 already_done 轻提示）。
    // 先红：HEAD 回第 2 步、横幅 error.30414 + 轻提示 pending_confirm.already_done（FollowupHM0722 :371-387 的现状）。
    it('pcb_5c_abandon_completed_original_30414_same_page_and_elsewhere_dialog_without_already_done', 0, async () => {
      const completed: string = '{"outcome":"completed","original":{"code":30414,"msg":""}}';
      // 同页放弃。
      let f: AccountFixture = new AccountFixture();
      const a: PhoneChangeController = await pendingPhoneChange(f);
      let done: Finished = watchFinish(f, a);
      let key: string = a.snapshot.pending?.key ?? '';
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) => envelope(0, completed));
      expect(a.abandon(a.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect('same-page:' + dialogKey(a)).assertEqual('same-page:dialog:error.30414');
      expect('same-page-notice:' + (a.snapshot.notice?.textKey ?? 'none')).assertEqual('same-page-notice:none');
      expect(a.finish(a.snapshot.version)).assertTrue();
      expect('same-page-finished:' + done.n).assertEqual('same-page-finished:1');
      a.leave();
      // 别处放弃：A 放弃、回包挂住后离页；B 显示同键待确认，收到 completed 原 30414。
      f = new AccountFixture();
      const c: PhoneChangeController = await pendingPhoneChange(f);
      key = c.snapshot.pending?.key ?? '';
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) => null);
      expect(c.abandon(c.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      c.leave();
      const b: PhoneChangeController = new PhoneChangeController(f.deps());
      done = watchFinish(f, b);
      b.onShown();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      f.held[f.held.length - 1].resolve(envelope(0, completed));
      await settle();
      expect('elsewhere:' + dialogKey(b)).assertEqual('elsewhere:dialog:error.30414');
      expect('elsewhere-notice:' + (b.snapshot.notice?.textKey ?? 'none')).assertEqual('elsewhere-notice:none');
      expect(b.finish(b.snapshot.version)).assertTrue();
      expect('elsewhere-finished:' + done.n).assertEqual('elsewhere-finished:1');
      b.leave();
    });

    // ================================================================ 30414：页面不可见

    // 依据：brief §1-1（页面不可见时照 44001 延后弹窗，回到可见再弹）；弹窗出现前表单已作废。
    // 先红：HEAD 不可见时落第 2 步横幅、canSubmit 仍为真；回到可见也没有弹窗。
    it('pcb_6_submit_30414_while_hidden_dialog_only_after_shown', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      const done: Finished = watchFinish(f, p);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      p.onHidden();
      f.held[f.held.length - 1].resolve(envelope(30414, '{}'));
      await settle();
      expect('hidden:' + dialogKey(p)).assertEqual('hidden:none');
      expect('hidden-finish:' + done.n).assertEqual('hidden-finish:0');
      expect('hidden-canSubmit:' + p.canSubmit).assertEqual('hidden-canSubmit:false');
      p.onShown();
      expect('shown:' + dialogKey(p)).assertEqual('shown:dialog:error.30414');
      expect('shown-token:' + f.session.tokens.has('phone_change')).assertEqual('shown-token:false');
      expect(p.finish(p.snapshot.version)).assertTrue();
      expect('finished:' + done.n).assertEqual('finished:1');
      p.leave();
    });

    // ================================================================ 新号等于当前号（20001 fields=[phone]，不带 reason）

    // 依据：brief §1-3；后端 bind-phone.ts:283（新号 = 当前号：20001 data.fields=["phone"]，不带 reason）。
    // 先红：HEAD 文案落 error.20001（「填写内容有误，请检查」）。对照三段（带 reason、fields=[code]、待确认的确认）在 HEAD 上是绿的（防改错）。
    it('pcb_7_same_number_20001_fields_phone_without_reason_shows_phone_invalid_controls_unchanged', 0, async () => {
      // 1 新号等于当前号。
      let f: AccountFixture = new AccountFixture();
      let p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(20001, '{"fields":["phone"]}'));
      p.submit(p.snapshot.version);
      await settle();
      expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect('same-number:' + (p.snapshot.phoneError?.textKey ?? 'none'))
        .assertEqual('same-number:error.20001.phone_invalid');
      expect(p.snapshot.codeError === null).assertTrue();
      expect(p.snapshot.banner === null).assertTrue();
      expect(p.snapshot.newPhone).assertEqual(NEW_PHONE);
      expect(f.session.tokens.has('phone_change')).assertTrue();
      expect(dialogKey(p)).assertEqual('none');
      p.leave();
      // 2 对照（防改错）：带 reason=phone_invalid 的号码非法照旧。
      f = new AccountFixture();
      p = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) =>
      envelope(20001, '{"fields":["phone"],"reason":"phone_invalid"}'));
      p.submit(p.snapshot.version);
      await settle();
      expect('reason:' + (p.snapshot.phoneError?.textKey ?? 'none')).assertEqual('reason:error.20001.phone_invalid');
      expect(p.snapshot.newPhone).assertEqual(NEW_PHONE);
      expect(f.session.tokens.has('phone_change')).assertTrue();
      p.leave();
      // 3 对照（防改错）：fields=[code] 仍标验证码框，号码框不标红。
      f = new AccountFixture();
      p = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(20001, '{"fields":["code"]}'));
      p.submit(p.snapshot.version);
      await settle();
      expect('code-field:' + (p.snapshot.codeError?.textKey ?? 'none')).assertEqual('code-field:error.20001');
      expect(p.snapshot.phoneError === null).assertTrue();
      p.leave();
      // 4 对照（防改错）：待确认【确认】得 20001 fields=[phone] 仍是 cannot_confirm（不在字段旁标红）。
      f = new AccountFixture();
      const a: PhoneChangeController = await pendingPhoneChange(f);
      const key: string = a.snapshot.pending?.key ?? '';
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(20001, '{"fields":["phone"]}'));
      expect(a.confirm(a.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(a.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      expect('confirm:' + (a.snapshot.banner?.textKey ?? 'none')).assertEqual('confirm:pending_confirm.cannot_confirm');
      expect(a.snapshot.phoneError === null).assertTrue();
      a.leave();
    });

    // ================================================================ 防改错：首次绑定、提现 / 收款面板

    // 依据：brief §1-7（首次绑定 BindPhone 页行为零变化）、§1-2（提现 / 收款也用 StepUpController，属资金路径，一行不改）。
    // 同时开着一个停在第 1 步的换号页：别的页面遇 30414 不许让换号页弹窗、关子页。
    // 先红：无（防改错，HEAD 上绿）。防的错法：在会话 / 共享服务层统一拦 30414；改 StepUpController 让面板遇 30414 自己关；
    // 把首次绑定的 30414 也改成弹窗。
    it('pcb_8_bind_page_and_withdraw_payout_panels_30414_unchanged_no_phone_change_dialog', 0, async () => {
      // 1 首次绑定页直接提交得 30414：照旧是号码类错误（error.30414）、不带待确认结束的客服入口（customerService 只在 ended 结果上），
      //   页面不关。
      let f: AccountFixture = new AccountFixture();
      f.session.sync();
      let p: PhoneChangeController = new PhoneChangeController(f.deps());
      let done: Finished = watchFinish(f, p);
      p.onShown();
      const svc: BindPhoneService = bindService(f);
      const fields: TestFields = new TestFields();
      const form: BindPhoneForm = new BindPhoneForm(svc, fields);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      form.setPhone(form.binding(), NEW_PHONE);
      form.setCode(form.binding(), '123456');
      const out: BindOutcome | null = await form.submit(form.binding());
      await settle();
      expect(out !== null).assertTrue();
      expect(out?.actionRaw).assertEqual(BindPhoneAction.ERROR);
      expect((out?.textKey ?? '').startsWith('error.30414')).assertTrue();
      expect('fresh-cs:' + String(out?.customerService)).assertEqual('fresh-cs:false');
      expect('fresh-ended:' + String(out?.ended)).assertEqual('fresh-ended:false');
      expect(BindOutcome.phoneClass(out as BindOutcome)).assertTrue();
      expect(dialogKey(p)).assertEqual('none');
      expect(done.n).assertEqual(0);
      form.leave();
      p.leave();
      // 2 提现、改收款的二次验证面板：发码 30414、验证 30414 都只显示错误，面板不关；同时开着的换号页不弹窗。
      const actions: string[] = ['withdraw', 'payout_account'];
      for (const action of actions) {
        f = new AccountFixture();
        f.session.sync();
        p = new PhoneChangeController(f.deps());
        done = watchFinish(f, p);
        p.onShown();
        f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(30414, '{}'));
        f.reply('POST /v1/auth/step-up', (_r: TransportRequest) => envelope(30414, '{}'));
        const s: StepUpController = new StepUpController(f.deps(), action, 'user-1');
        expect(s.send()).assertTrue();
        await settle();
        expect(action + '-send:' + (s.snapshot.error?.textKey ?? 'none')).assertEqual(action + '-send:error.30414');
        expect(s.open).assertTrue();
        s.setCode('123456');
        expect(s.verify()).assertTrue();
        await settle();
        expect(action + '-verify:' + (s.snapshot.error?.textKey ?? 'none')).assertEqual(action + '-verify:error.30414');
        expect(s.open).assertTrue();
        expect(s.snapshot.code).assertEqual('123456');
        expect(action + ':' + dialogKey(p)).assertEqual(action + ':none');
        expect(done.n).assertEqual(0);
        s.close();
        p.leave();
      }
    });
  });
}
