// FU-HM-0722 鸿蒙跟进合集十：Android APP-13a 评审教训（APP-13a 共性 29–48）回灌 + F-X-13（APP-05b 共性 34）+ F-AND-35 对应用例。
// 真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer）+ Core 执行器（页面按钮回调调用的同一套方法）。每条改动 / 抽查条目一个用例；
// 回退对应修复（见 NATIVE/FU-HM-0722/mutations.txt）时该用例失败。号码只用测试值；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  AccountMessage, AccountSettle, ApiClientWalletPort, ApiRequest, BindOutcome, BindPendingGuide, BindPhoneAction, BindPhoneFields,
  BindPhoneForm, BindPhoneFormBinding, BindPhonePagePermit, BindPhoneService, BindPhoneTicker, BindPhoneTickScheduler, DeleteAccountController,
  DeletionPresentation, DeletionSource, ForceUpdateDeletionEntry, LegalVersions, LoginHost, LoginOutcome, LoginSendState, LoginService,
  PendingKeyRecord, PhoneBindingState, PhoneChangeController, PhoneChangeStep, SendCodeOutcome, SmsSendDeadlines,
  StepUpController, TransportRequest, TransportResponse
} from '../../Index';
import { envelope, header, tokenPair } from './NetworkTestRig';
import {
  AccountFixture, cooling, fillStep2, gateway, Host, NEW_PHONE, openDeletion, pendingDeletion, settle, stateOf, toStep2
} from './AccountIntegration.test';

const LATE_TOKEN: string = 'late-step-token-2';
const EQUIVALENT: string = '139 0000 1234';

class TestFields implements BindPhoneFields {
  phoneText: string = '';
  codeText: string = '';
  phoneError: string = '';
  codeError: string = '';
}

class FakeTicks implements BindPhoneTickScheduler {
  started: number = 0;
  stopped: number = 0;
  private next: number = 1;

  start(_millis: number, _fn: () => void): number {
    this.started++;
    return this.next++;
  }

  stop(_id: number): void {
    this.stopped++;
  }
}

class QuietHost implements LoginHost {
  updateState(): string {
    return 'supported';
  }

  hasPendingAction(): boolean {
    return false;
  }

  closeLogin(): void {
  }

  resumePending(): void {
  }

  discardPending(): void {
  }

  enterForceUpdate(): void {
  }

  sessionChanged(): void {
  }

  sessionSynced(): void {
  }

  sessionEnded(): void {
  }
}

function cancelledUser(): string {
  return '{"status":"cancelled","apply_at":"2026-10-14T10:00:00+08:00","cooling_until":"2026-10-21T10:00:00+08:00",'
    + '"can_cancel":false,"cancelled_at":"2026-10-14T11:00:00+08:00","cancel_reason":"user","processed_at":null}';
}

function stepUpOk(token: string): TransportResponse {
  return envelope(0, '{"step_up_token":"' + token + '","expire_at":"2026-10-14T10:05:00+08:00"}');
}

/** 恢复夹具默认的 step-up 回复（123456 成功）。 */
function defaultStepUp(f: AccountFixture): void {
  f.reply('POST /v1/auth/step-up', (r: TransportRequest) => (r.body ?? '').indexOf('"123456"') >= 0
    ? stepUpOk('fixture-step-token') : envelope(20002, '{}'));
}

/** 受限会话（deletion_only）的夹具：冷启动屏障的刷新仍给 deletion_only。 */
function restrictedFixture(): AccountFixture {
  const f: AccountFixture = new AccountFixture();
  f.reply('POST /v1/auth/refresh', (_r: TransportRequest) =>
  envelope(0, tokenPair('access-r1', 'refresh-r1', 'deletion_only')));
  f.switchAccount('user-1', 'deletion_only');
  return f;
}

/**
 * 同一登录会话里只换作用域（APP-13a 共性 48 的场景）：一次读取得到 10002 → 网络层单飞刷新 → 服务端给目标作用域的令牌。登录序号、
 * 会话世代、账号不变（ownerScope 不变），作用域变了（scope 变了）。不调 session.sync（由用例自己在同步区里调）。
 */
async function refreshTo(f: AccountFixture, scope: string): Promise<void> {
  let first: boolean = true;
  f.reply('POST /v1/auth/refresh', (_r: TransportRequest) =>
  envelope(0, tokenPair('access-' + scope + '-2', 'refresh-' + scope + '-2', scope)));
  f.reply('GET /v1/me/deletion', (_r: TransportRequest) => {
    if (first) {
      first = false;
      return envelope(10002, '{}');
    }
    return envelope(0, 'null');
  });
  await f.rig.client.request(new ApiRequest('getDeletion'));
  await settle();
}

function bindService(f: AccountFixture, host: Host = new Host()): BindPhoneService {
  const svc: BindPhoneService = new BindPhoneService(f.rig.client, new SmsSendDeadlines(), new PhoneBindingState(),
    host, (): number => f.rig.nowMillis);
  svc.accountPort = f.session;
  svc.syncSession();
  return svc;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

/** 换号页留下一条结果未知的未决记录（提交得到网关错误页），停在待确认。 */
async function pendingPhoneChange(f: AccountFixture): Promise<PhoneChangeController> {
  const a: PhoneChangeController = await toStep2(f);
  await fillStep2(f, a);
  f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
  a.submit(a.snapshot.version);
  await settle();
  return a;
}

/** BindPhone 页留下一条结果未知的未决记录（提交得到网关错误页），返回原键。 */
async function pendingBind(f: AccountFixture, form: BindPhoneForm, svc: BindPhoneService): Promise<string> {
  f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
  form.setPhone(form.binding(), NEW_PHONE);
  form.setCode(form.binding(), '123456');
  const first: BindOutcome | null = await form.submit(form.binding());
  expect(first?.actionRaw).assertEqual(BindOutcome.PENDING);
  f.session.sync();
  return svc.pendingView(form.pageIdentity)?.key ?? '';
}

/** 绑手机页的接收实例（按 BindPhoneView 同一接线：subscribePending → refreshPending，再按结局交给 pendingSettled）。 */
class BindReceiver {
  readonly form: BindPhoneForm;
  readonly svc: BindPhoneService;
  shownKey: string | null = null;
  readonly ended: BindOutcome[] = [];
  private readonly unsubscribe: () => void;

  constructor(svc: BindPhoneService) {
    this.svc = svc;
    this.form = new BindPhoneForm(svc, new TestFields());
    this.refresh();
    this.unsubscribe = this.form.subscribePending((): void => this.refresh(), (o: BindOutcome): void => {
      this.ended.push(o);
    }, (): string | null => this.shownKey);
  }

  refresh(): void {
    const key: string | undefined = this.svc.pendingView(this.form.pageIdentity)?.key;
    this.shownKey = key ?? null;
  }

  dispose(): void {
    this.form.leave();
    this.unsubscribe();
  }
}

/**
 * 绑手机页的补办入口替身（FU-HM-0722 R2-01，按 BindPhoneView 同一接线）：guideChanged → refreshGuide；subscribePending → refreshPending
 * （卡片 + 入口）；onShown → pageShown 后 refreshPending；确认 / 放弃开始时清入口文案、结果为 null 直接返回（不导航、不提交）。
 */
class GuidePage {
  readonly form: BindPhoneForm;
  readonly svc: BindPhoneService;
  pendingKey: string | null = null;
  guideText: string = '';
  guideCalls: number = 0;
  private readonly unsubscribe: () => void;

  constructor(svc: BindPhoneService) {
    this.svc = svc;
    this.form = new BindPhoneForm(svc, new TestFields());
    this.form.guideChanged = (): void => {
      this.guideCalls++;
      this.refreshGuide();
    };
    this.unsubscribe = this.form.subscribePending((): void => this.refreshPending(), (_o: BindOutcome): void => {
    }, (): string | null => this.pendingKey);
  }

  refreshPending(): void {
    this.pendingKey = this.svc.pendingView(this.form.pageIdentity)?.key ?? null;
    this.refreshGuide();
  }

  refreshGuide(): void {
    const g: BindPendingGuide | null = this.form.pendingGuide(this.pendingKey);
    this.guideText = g === null ? '' : g.textKey;
  }

  hidden(): void {
    this.form.pageHidden();
  }

  shown(): void {
    if (!this.form.pageShown()) {
      this.refreshPending();
    }
  }

  async run(abandon: boolean): Promise<BindOutcome | null> {
    const key: string = this.pendingKey ?? '';
    const permit: BindPhonePagePermit = this.form.permit();
    this.guideText = '';
    return abandon ? this.form.abandonPending(key, permit) : this.form.confirmPending(key, permit);
  }

  dispose(): void {
    this.form.leave();
    this.unsubscribe();
  }
}

export default function followupHM0722Test() {
  describe('FollowupHM0722', () => {
    // ---------------------------------------------------------------- 共性 43（Android R3-01）：token 失效世代
    it('fhm0722_43_late_step1_verify_after_phone_change_success_elsewhere_is_not_kept', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      // 实例 A 提交换号在途（已到服务端）→ 用户返回设置、进入实例 B。
      const a: PhoneChangeController = await toStep2(f);
      await fillStep2(f, a);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      expect(a.submit(a.snapshot.version)).assertTrue();
      await settle();
      const submitHeld: number = f.held.length - 1;
      a.leave();
      const b: PhoneChangeController = new PhoneChangeController(f.deps());
      b.onShown();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
      // A 第 1 步发的码还在共享倒计时里（同账号、同号码、同 action）：B 不重发，直接用收到的码验证。
      expect(b.snapshot.step1.sent).assertTrue();
      // B 第 1 步验证：服务端已签发 T2，但回包延迟。
      f.reply('POST /v1/auth/step-up', (_r: TransportRequest) => null);
      expect(b.setStep1Code(b.snapshot.version, '123456')).assertTrue();
      expect(b.next(b.snapshot.version)).assertTrue();
      await settle();
      const verifyHeld: number = f.held.length - 1;
      // A 成功：共享结算统一作废全部 token。
      f.held[submitHeld].resolve(envelope(0, '{}'));
      await settle();
      // B 收到 T2：不写共享缓存、不进第 2 步，留在第 1 步、清空验证码并提示重新验证。
      f.held[verifyHeld].resolve(stepUpOk(LATE_TOKEN));
      await settle();
      expect(f.session.tokens.has('phone_change')).assertFalse();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.STEP1);
      expect(b.snapshot.step1.code).assertEqual('');
      expect(b.snapshot.step1.error?.textKey).assertEqual('error.10003');
      // B 重新验证后提交：带的是新 token，不是 T2。
      defaultStepUp(f);
      f.reply('POST /v1/me/phone', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
        ? envelope(10003, '{}') : envelope(0, '{}'));
      expect(b.setStep1Code(b.snapshot.version, '123456')).assertTrue();
      expect(b.next(b.snapshot.version)).assertTrue();
      await settle();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      await fillStep2(f, b);
      expect(b.submit(b.snapshot.version)).assertTrue();
      await settle();
      const sent: string | undefined = header(f.last('POST /v1/me/phone'), 'X-Step-Up-Token');
      expect(sent === undefined || sent !== LATE_TOKEN).assertTrue();
      expect(sent).assertEqual('fixture-step-token');
      b.leave();
    });

    it('fhm0722_43_sheet_verify_success_arriving_after_tokens_invalidated_is_discarded', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      expect(c.apply(c.snapshot.version)).assertTrue();
      await settle();
      expect(c.snapshot.stepUpAction).assertEqual('account_deletion');
      const sheet: StepUpController | null = c.createStepUp();
      expect(sheet !== null).assertTrue();
      const s: StepUpController = sheet as StepUpController;
      expect(s.send()).assertTrue();
      await settle();
      const applies: number = f.count('POST /v1/me/deletion');
      f.reply('POST /v1/auth/step-up', (_r: TransportRequest) => null);
      s.setCode('123456');
      expect(s.verify()).assertTrue();
      await settle();
      // 反向时序：先清 token（别处换号 / 绑手机成功的共享结算），后收到旧验证成功。
      expect(AccountSettle.bindPhoneSucceeded(f.session.tokens, true)).assertTrue();
      f.held[f.held.length - 1].resolve(stepUpOk(LATE_TOKEN));
      await settle();
      expect(f.session.tokens.has('account_deletion')).assertFalse();
      expect(f.count('POST /v1/me/deletion')).assertEqual(applies);
      // 面板保留、可重新输入。
      expect(s.open).assertTrue();
      expect(s.snapshot.verifying).assertFalse();
      expect(s.snapshot.code).assertEqual('');
      expect(s.snapshot.error?.textKey).assertEqual('error.10003');
      s.close();
      c.leave();
    });

    // ---------------------------------------------------------------- 共性 44（Android R3-02）：同页待确认终结业务错误回第 2 步
    it('fhm0722_44_same_page_confirm_30411_30414_restores_step2_with_phone_code_and_token', 0, async () => {
      const codes: number[] = [30411, 30414];
      for (const code of codes) {
        const f: AccountFixture = new AccountFixture();
        const a: PhoneChangeController = await pendingPhoneChange(f);
        expect(a.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
        const key: string = a.snapshot.pending?.key ?? '';
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(code, '{}'));
        expect(a.confirm(a.snapshot.pendingVersion, key)).assertTrue();
        await settle();
        expect(f.rig.client.pendingFor('bindPhone') === null).assertTrue();
        expect(a.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
        expect(a.snapshot.newPhone).assertEqual(NEW_PHONE);
        expect(a.snapshot.code).assertEqual('654321');
        expect(f.session.tokens.has('phone_change')).assertTrue();
        expect(a.snapshot.banner?.textKey).assertEqual('error.' + code);
        expect(a.snapshot.showCustomerService).assertEqual(code === 30414);
        expect(a.canSubmit).assertTrue();
        a.leave();
      }
    });

    // ---------------------------------------------------------------- 共性 47（Android RC-01）：跨实例同键终结业务错误
    it('fhm0722_47_confirm_30411_30414_elsewhere_restores_step2_on_instance_showing_same_key', 0, async () => {
      const codes: number[] = [30411, 30414];
      for (const code of codes) {
        const f: AccountFixture = new AccountFixture();
        const a: PhoneChangeController = await pendingPhoneChange(f);
        const key: string = a.snapshot.pending?.key ?? '';
        // A 点【确认】，请求已到服务端、回包挂住 → 返回设置进入 B，B 恢复同键待确认。
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        expect(a.confirm(a.snapshot.pendingVersion, key)).assertTrue();
        await settle();
        a.leave();
        const b: PhoneChangeController = new PhoneChangeController(f.deps());
        b.onShown();
        expect(b.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
        f.held[f.held.length - 1].resolve(envelope(code, '{}'));
        await settle();
        expect(f.rig.client.pendingFor('bindPhone') === null).assertTrue();
        expect(b.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
        expect(b.snapshot.pending === null).assertTrue();
        expect(b.snapshot.banner?.textKey).assertEqual('error.' + code);
        expect(b.snapshot.showCustomerService).assertEqual(code === 30414);
        // 第 2 步提交入口恢复：填好新号与验证码后【提交】可用。
        expect(b.setNewPhone(b.snapshot.version, NEW_PHONE)).assertTrue();
        expect(b.setCode(b.snapshot.version, '654321')).assertTrue();
        expect(b.canSubmit).assertTrue();
        b.leave();
      }
    });

    it('fhm0722_47_abandon_completed_original_3xxxx_and_bind_page_confirm_elsewhere_restore_step2', 0, async () => {
      // 放弃得到 completed（原结果 30414）。
      let f: AccountFixture = new AccountFixture();
      const a: PhoneChangeController = await pendingPhoneChange(f);
      const key: string = a.snapshot.pending?.key ?? '';
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) => null);
      expect(a.abandon(a.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      a.leave();
      let b: PhoneChangeController = new PhoneChangeController(f.deps());
      b.onShown();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      f.held[f.held.length - 1].resolve(envelope(0, '{"outcome":"completed","original":{"code":30414,"msg":""}}'));
      await settle();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect(b.snapshot.banner?.textKey).assertEqual('error.30414');
      expect(b.snapshot.notice?.textKey).assertEqual('pending_confirm.already_done');
      b.leave();
      // BindPhone 页（首次绑定）确认同一键得到 30414：换号页 B 同样恢复第 2 步与错误提示（BindPhone 通知也带完整结局）。
      f = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      const bind: BindPhoneFormBinding = form.binding();
      form.setPhone(bind, NEW_PHONE);
      form.setCode(form.binding(), '123456');
      const first: BindOutcome | null = await form.submit(form.binding());
      expect(first?.actionRaw).assertEqual(BindOutcome.PENDING);
      const bindKey: string = svc.pendingView(form.pageIdentity)?.key ?? '';
      f.session.sync();
      b = new PhoneChangeController(f.deps());
      b.onShown();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.PENDING);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      const permit: BindPhonePagePermit = form.permit();
      await form.confirmPending(bindKey, permit);
      await settle();
      expect(b.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
      expect(b.snapshot.banner?.textKey).assertEqual('error.30414');
      expect(b.snapshot.showCustomerService).assertTrue();
      b.leave();
    });

    // ---------------------------------------------------------------- 共性 45（Android R3-03）：等刷新的写请求按完整身份不发
    it('fhm0722_45_deletion_only_confirm_waiting_for_refresh_not_sent_after_same_epoch_full', 0, async () => {
      const f: AccountFixture = restrictedFixture();
      const c: DeleteAccountController = await pendingDeletion(f);
      const key: string = c.snapshot.pending?.key ?? '';
      expect(key.length > 0).assertTrue();
      const sent: number = f.count('POST /v1/me/deletion');
      // 受限屏障的刷新挂住 → 点【确认】，请求等刷新 → 刷新得到同账号、同登录会话的 full。
      f.reply('POST /v1/auth/refresh', (_r: TransportRequest) => null);
      const refreshing: Promise<boolean> = f.rig.client.refreshRestrictedSession();
      await settle();
      expect(c.confirm(c.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(sent);
      const owner: string = f.walletScope();
      f.held[f.held.length - 1].resolve(envelope(0, tokenPair('access-full', 'refresh-full', 'full')));
      await refreshing;
      await settle();
      expect(f.rig.client.sessionScope()).assertEqual('full');
      expect(f.walletScope()).assertEqual(owner);
      f.session.sync();
      await settle();
      // 旧请求不发；未决记录保留原键、仍是结果未知，等新实例里的用户操作。
      expect(f.count('POST /v1/me/deletion')).assertEqual(sent);
      const record: PendingKeyRecord | null = f.rig.client.pendingFor('requestDeletion');
      expect(record?.key).assertEqual(key);
      expect(record?.everUnknown).assertTrue();
      const again: DeleteAccountController = await openDeletion(f);
      expect(again.snapshot.pending?.key).assertEqual(key);
      again.leave();
    });

    // ---------------------------------------------------------------- 共性 48 / F-AND-35（Android RC-02）：已到服务端的照常结算
    it('fhm0722_48_deletion_only_confirm_at_server_settles_after_same_epoch_full_refresh', 0, async () => {
      const f: AccountFixture = restrictedFixture();
      const c: DeleteAccountController = await pendingDeletion(f);
      const key: string = c.snapshot.pending?.key ?? '';
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => null);
      const sent: number = f.count('POST /v1/me/deletion');
      expect(c.confirm(c.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(sent + 1);
      const confirmHeld: number = f.held.length - 1;
      const owner: string = f.walletScope();
      await refreshTo(f, 'full');
      expect(f.rig.client.sessionScope()).assertEqual('full');
      expect(f.walletScope()).assertEqual(owner);
      f.session.sync();
      expect(c.alive).assertFalse();
      const c2: DeleteAccountController = await openDeletion(f);
      expect(c2.snapshot.pending?.key).assertEqual(key);
      const changes: number = f.deletionChanges;
      const gen: number = f.session.deletionGeneration;
      // 等过多轮再放行（旧写请求不因作用域换代被取消）。
      await settle();
      await settle();
      f.held[confirmHeld].resolve(envelope(0, cooling()));
      await settle();
      // 原键结束（没落成结果未知）、只发了 1 次；共享结算照常；新实例随共享通知落到冷静期。
      expect(f.rig.client.pendingFor('requestDeletion') === null).assertTrue();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
      expect(f.count('POST /v1/me/deletion')).assertEqual(sent + 1);
      expect(f.deletionChanges).assertEqual(changes + 1);
      expect(f.session.deletionGeneration > gen).assertTrue();
      expect(c2.snapshot.pending === null).assertTrue();
      expect(stateOf(c2)).assertEqual(DeletionPresentation.COOLING);
      expect(c2.snapshot.banner === null).assertTrue();
      c2.leave();
    });

    it('fhm0722_48_deletion_only_apply_at_server_settles_after_same_epoch_full_refresh', 0, async () => {
      const f: AccountFixture = restrictedFixture();
      const c: DeleteAccountController = await openDeletion(f);
      f.session.tokens.put('account_deletion', 'user-1', 'restricted-step-token', f.rig.nowMillis + 60000, f.scope());
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => null);
      c.setChecked(c.snapshot.version, true);
      expect(c.apply(c.snapshot.version)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
      expect(header(f.last('POST /v1/me/deletion'), 'X-Step-Up-Token')).assertEqual('restricted-step-token');
      const applyHeld: number = f.held.length - 1;
      await refreshTo(f, 'full');
      f.session.sync();
      expect(c.alive).assertFalse();
      const changes: number = f.deletionChanges;
      f.held[applyHeld].resolve(envelope(0, cooling()));
      await settle();
      expect(f.rig.client.pendingFor('requestDeletion') === null).assertTrue();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
      expect(f.deletionChanges).assertEqual(changes + 1);
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
    });

    it('fhm0722_48_deletion_only_cancel_at_server_settles_after_same_epoch_full_refresh', 0, async () => {
      const f: AccountFixture = restrictedFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      const c: DeleteAccountController = await openDeletion(f);
      expect(stateOf(c)).assertEqual(DeletionPresentation.COOLING);
      f.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => null);
      expect(c.cancel(c.snapshot.version)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/deletion/cancel')).assertEqual(1);
      const cancelHeld: number = f.held.length - 1;
      await refreshTo(f, 'full');
      f.session.sync();
      expect(c.alive).assertFalse();
      const changes: number = f.deletionChanges;
      const gen: number = f.session.deletionGeneration;
      f.held[cancelHeld].resolve(envelope(0, cancelledUser()));
      await settle();
      expect(f.deletionChanges).assertEqual(changes + 1);
      expect(f.session.deletionGeneration > gen).assertTrue();
      expect(f.count('POST /v1/me/deletion/cancel')).assertEqual(1);
    });

    it('fhm0722_48_phone_change_submit_at_server_settles_after_same_epoch_scope_change', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      await fillStep2(f, p);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      expect(p.submit(p.snapshot.version)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      const submitHeld: number = f.held.length - 1;
      const owner: string = f.walletScope();
      // 同一登录会话里作用域换代（full → deletion_only，令牌刷新）。
      await refreshTo(f, 'deletion_only');
      expect(f.rig.client.sessionScope()).assertEqual('deletion_only');
      expect(f.walletScope()).assertEqual(owner);
      f.session.sync();
      expect(p.alive).assertFalse();
      // 换代之后新作用域里拿到的 token（注销验证）。
      f.session.tokens.put('account_deletion', 'user-1', 'restricted-step-token', f.rig.nowMillis + 60000, f.scope());
      f.held[submitHeld].resolve(envelope(0, '{}'));
      await settle();
      // 已到服务端的换号成功照常共享结算：原键结束、全部 action 的 token 作废。
      expect(f.rig.client.pendingFor('bindPhone') === null).assertTrue();
      expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
      expect(f.session.tokens.has('account_deletion')).assertFalse();
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
    });

    // ---------------------------------------------------------------- 共性 46（Android R3-04）：待确认卡独立于读取
    it('fhm0722_46_existing_unknown_record_shows_usable_pending_card_while_get_deletion_loading', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const first: DeleteAccountController = await pendingDeletion(f);
      const key: string = first.snapshot.pending?.key ?? '';
      first.leave();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => null);
      const c: DeleteAccountController = new DeleteAccountController(f.deps(), DeletionSource.SETTINGS);
      c.onShown();
      await settle();
      expect(stateOf(c)).assertEqual(DeletionPresentation.PENDING);
      expect(c.snapshot.pending?.key).assertEqual(key);
      expect(c.snapshot.pending?.inFlight).assertFalse();
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      const sent: number = f.count('POST /v1/me/deletion');
      expect(c.confirm(c.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(sent + 1);
      expect(f.rig.client.pendingFor('requestDeletion') === null).assertTrue();
      c.leave();
    });

    // ---------------------------------------------------------------- 共性 32（Android R1-12）：强更标签与注销页共用 deletionRead
    it('fhm0722_32_force_update_label_and_delete_page_share_deletion_read_gate_both_ways', 0, async () => {
      let f: AccountFixture = new AccountFixture();
      f.session.sync();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '60' }));
      const entry: ForceUpdateDeletionEntry = new ForceUpdateDeletionEntry(new ApiClientWalletPort(f.rig.client),
        f.session.deletionReadGate, (): string => f.scope());
      entry.refresh(true);
      await settle();
      expect(f.session.deletionReadGate.active).assertTrue();
      // 限流期间用兜底标签（不因读取失败隐藏链接）。
      expect(entry.labelKey('member', true) !== null).assertTrue();
      const reads: number = f.count('GET /v1/me/deletion');
      const c: DeleteAccountController = await openDeletion(f);
      expect(f.count('GET /v1/me/deletion')).assertEqual(reads);
      expect(c.snapshot.readBlocked).assertTrue();
      c.leave();
      entry.leave();
      // 反向：注销页读到 42901，强更标签的读取在发包前被同一闸门拦下。
      f = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '60' }));
      const d: DeleteAccountController = await openDeletion(f);
      expect(f.session.deletionReadGate.active).assertTrue();
      const before: number = f.count('GET /v1/me/deletion');
      const label: ForceUpdateDeletionEntry = new ForceUpdateDeletionEntry(new ApiClientWalletPort(f.rig.client),
        f.session.deletionReadGate, (): string => f.scope());
      label.refresh(true);
      await settle();
      expect(f.count('GET /v1/me/deletion')).assertEqual(before);
      d.leave();
      label.leave();
    });

    // ---------------------------------------------------------------- 共性 41（Android R2-08）：待确认提示独立附加 trace6
    it('fhm0722_41_bind_page_pending_5xxxx_text_appends_trace6_once', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => gateway());
      form.setPhone(form.binding(), NEW_PHONE);
      form.setCode(form.binding(), '123456');
      await form.submit(form.binding());
      const key: string = svc.pendingView(form.pageIdentity)?.key ?? '';
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50001, '{}'));
      const out: BindOutcome | null = await form.confirmPending(key, form.permit());
      expect(out?.actionRaw).assertEqual(BindOutcome.PENDING);
      const o: BindOutcome = out as BindOutcome;
      expect(o.trace6.length).assertEqual(6);
      // 文案本身没有 {trace6} 占位：独立附加一次；已带上的不重复。
      const plain: string = '暂时无法确认，请稍后再试';
      const text: string = BindOutcome.pendingText(plain, o);
      expect(text.indexOf(o.trace6) > 0).assertTrue();
      expect(BindOutcome.pendingText(text, o)).assertEqual(text);
    });

    // ---------------------------------------------------------------- F-X-13 / APP-05b 共性 34 + APP-13a 共性 30：换号第 2 步
    it('fhm0722_x13_phone_change_step2_edit_while_sending_keeps_timer_by_normalized_phone', 0, async () => {
      // A → 空 → A：旧结果的已发码提示丢弃，倒计时按当前号码照常启动、到期自动恢复。
      let f: AccountFixture = new AccountFixture();
      let p: PhoneChangeController = await toStep2(f);
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      expect(p.setNewPhone(p.snapshot.version, NEW_PHONE)).assertTrue();
      expect(p.sendBind(p.snapshot.version)).assertTrue();
      await settle();
      expect(p.setNewPhone(p.snapshot.version, '')).assertTrue();
      expect(p.setNewPhone(p.snapshot.version, NEW_PHONE)).assertTrue();
      f.held[f.held.length - 1].resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      await settle();
      expect(p.snapshot.codeSent).assertFalse();
      expect(p.snapshot.notice === null || p.snapshot.notice.textKey !== 'phone_change.code_sent').assertTrue();
      expect(p.snapshot.countdown > 0).assertTrue();
      expect(p.snapshot.sending).assertFalse();
      expect(p.canSendBind).assertFalse();
      // 等价写法：同一个规范化号码，倒计时同样生效（不能绕过）。
      expect(p.setNewPhone(p.snapshot.version, EQUIVALENT)).assertTrue();
      expect(p.snapshot.countdown > 0).assertTrue();
      expect(p.canSendBind).assertFalse();
      expect(p.sendBind(p.snapshot.version)).assertFalse();
      // 计时器已按共享截止时间启动：到期后自动恢复【获取验证码】（不需要用户操作）。
      f.rig.nowMillis += 61000;
      await sleep(1300);
      expect(p.snapshot.countdown).assertEqual(0);
      expect(p.canSendBind).assertTrue();
      p.leave();
      // 在途时改成等价写法：旧结果丢弃，倒计时按规范化号码立即显示。
      f = new AccountFixture();
      p = await toStep2(f);
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      p.setNewPhone(p.snapshot.version, NEW_PHONE);
      expect(p.sendBind(p.snapshot.version)).assertTrue();
      await settle();
      p.setNewPhone(p.snapshot.version, EQUIVALENT);
      f.held[f.held.length - 1].resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      await settle();
      expect(p.snapshot.codeSent).assertFalse();
      expect(p.snapshot.countdown > 0).assertTrue();
      expect(p.canSendBind).assertFalse();
      // 请求体仍按原始输入提交（G33）。
      expect((f.last('POST /v1/auth/sms-codes').body ?? '').indexOf('"' + NEW_PHONE + '"') >= 0).assertTrue();
      p.leave();
      // 42901：A → 空 → A，限流按当前号码生效、不弹横幅，到期自动恢复。
      f = new AccountFixture();
      p = await toStep2(f);
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      p.setNewPhone(p.snapshot.version, NEW_PHONE);
      expect(p.sendBind(p.snapshot.version)).assertTrue();
      await settle();
      p.setNewPhone(p.snapshot.version, '');
      p.setNewPhone(p.snapshot.version, NEW_PHONE);
      f.held[f.held.length - 1].resolve(envelope(42901, '{}', { 'Retry-After': '2' }));
      await settle();
      expect(p.snapshot.sendRateLimited).assertTrue();
      expect(p.snapshot.banner === null).assertTrue();
      expect(p.canSendBind).assertFalse();
      f.rig.nowMillis += 3000;
      await sleep(1300);
      expect(p.snapshot.sendRateLimited).assertFalse();
      expect(p.canSendBind).assertTrue();
      p.leave();
    });

    // ---------------------------------------------------------------- F-X-13 / APP-05b 共性 34：BindPhone 页
    it('fhm0722_x13_bind_page_edit_while_sending_refreshes_timer_by_normalized_phone', 0, async () => {
      const replies: TransportResponse[] = [envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'),
        envelope(42901, '{}', { 'Retry-After': '30' })];
      for (const reply of replies) {
        const rate: boolean = reply === replies[1];
        // A → 空 → A 与等价写法两种编辑。
        const edits: string[] = [NEW_PHONE, EQUIVALENT];
        for (const back of edits) {
          const f: AccountFixture = new AccountFixture();
          const svc: BindPhoneService = bindService(f);
          const fields: TestFields = new TestFields();
          const form: BindPhoneForm = new BindPhoneForm(svc, fields);
          const ticks: FakeTicks = new FakeTicks();
          const ticker: BindPhoneTicker = new BindPhoneTicker((): void => {
          }, (): boolean => {
            const st: LoginSendState = svc.sendState(fields.phoneText);
            return st.countdownSec > 0 || st.rateLimitedSec > 0;
          }, ticks);
          let changed: number = 0;
          form.deadlinesChanged = (): void => {
            changed++;
            ticker.refresh();
          };
          form.setPhone(form.binding(), NEW_PHONE);
          f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
          const running: Promise<SendCodeOutcome | null> = form.sendCode(form.binding());
          await settle();
          form.setPhone(form.binding(), '');
          ticker.refresh();
          form.setPhone(form.binding(), back);
          ticker.refresh();
          expect(ticker.running).assertFalse();
          f.held[f.held.length - 1].resolve(reply);
          const out: SendCodeOutcome | null = await running;
          await settle();
          // 旧结果的提示 / 播报丢弃（页面拿到 null），计时器按当前号码的共享截止时间启动。
          expect(out === null).assertTrue();
          expect(changed).assertEqual(1);
          expect(ticker.running).assertTrue();
          if (rate) {
            expect(svc.sendState(fields.phoneText).rateLimitedSec > 0).assertTrue();
            // 42901 到期：下一次每秒刷新时停掉计时器，【获取验证码】恢复。
            f.rig.nowMillis += 31000;
            ticker.refresh();
            expect(svc.sendState(fields.phoneText).rateLimitedSec).assertEqual(0);
            expect(ticker.running).assertFalse();
          } else {
            expect(svc.sendState(fields.phoneText).countdownSec > 0).assertTrue();
          }
          form.leave();
        }
      }
    });

    // ---------------------------------------------------------------- F-X-13 / APP-05b 共性 34：短信登录页（Core 口径）
    it('fhm0722_x13_sms_login_edit_while_sending_drops_old_result_and_state_follows_normalized_phone', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const service: LoginService = new LoginService(f.rig.client, f.rig.tokens, new QuietHost(), LegalVersions.bundled(),
        (): number => f.rig.nowMillis);
      // 在途时 A → 空 → A：换号即作废这次尝试（APP-05a 共性 1，传输同步取消）；旧结果按 stale 交回，页面不提示、只重算计时。
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => null);
      const running: Promise<SendCodeOutcome> = service.sendCode(NEW_PHONE);
      await settle();
      service.invalidateAttempt();
      service.invalidateAttempt();
      if (f.held.length > 0) {
        f.held[f.held.length - 1].resolve(envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      }
      const out: SendCodeOutcome = await running;
      expect(out.stateRaw).assertEqual(LoginOutcome.STALE);
      // 当前号码（含等价写法）的发码状态只按共享截止时间；没有被旧请求锁死。
      const now: LoginSendState = service.sendState(NEW_PHONE);
      const eq: LoginSendState = service.sendState(EQUIVALENT);
      expect(eq.countdownSec).assertEqual(now.countdownSec);
      expect(eq.rateLimitedSec).assertEqual(now.rateLimitedSec);
      // 42901 按规范化号码记下，等价写法同样受限；到期后不再需要计时器（页面计时器据此停、按钮恢复）。
      f.reply('POST /v1/auth/sms-codes', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      f.rig.nowMillis += 61000;
      await service.sendCode(EQUIVALENT);
      expect(service.sendState(NEW_PHONE).rateLimitedSec > 0).assertTrue();
      expect(service.sendState(NEW_PHONE).needsTimer(false)).assertTrue();
      f.rig.nowMillis += 31000;
      expect(service.sendState(NEW_PHONE).rateLimitedSec).assertEqual(0);
      expect(service.sendState(NEW_PHONE).needsTimer(false)).assertFalse();
    });

    // ---------------------------------------------------------------- F-X-15：held 原体重发的号码类反馈按原提交核对
    it('fhm0722_x15_phone_change_held_resend_phone_errors_not_landed_on_edited_new_phone', 0, async () => {
      const edited: string = '13700007777';
      const replies: TransportResponse[] = [envelope(20001, '{"reason":"phone_invalid"}'), envelope(30411, '{}'),
        envelope(30414, '{}')];
      for (const reply of replies) {
        const f: AccountFixture = new AccountFixture();
        const p: PhoneChangeController = await toStep2(f);
        await fillStep2(f, p);
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
        expect(p.submit(p.snapshot.version)).assertTrue();
        await settle();
        expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
        // held 期间改成另一个号码再提交：网络层按 held 原键原体重发旧号码，服务端回旧号码的错误。
        p.setNewPhone(p.snapshot.version, edited);
        p.setCode(p.snapshot.version, '222222');
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => reply);
        expect(p.submit(p.snapshot.version)).assertTrue();
        await settle();
        expect((f.last('POST /v1/me/phone').body ?? '').indexOf(NEW_PHONE) >= 0).assertTrue();
        // 旧号码的反馈不落到新号上，新号与验证码保留。
        expect(p.snapshot.phoneError === null).assertTrue();
        expect(p.snapshot.banner === null).assertTrue();
        expect(p.snapshot.showCustomerService).assertFalse();
        expect(p.snapshot.newPhone).assertEqual(edited);
        expect(p.snapshot.code).assertEqual('222222');
        expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
        p.leave();
      }
      // 对照：没改号码时同一错误照常显示在号码上。
      const g: AccountFixture = new AccountFixture();
      const q: PhoneChangeController = await toStep2(g);
      await fillStep2(g, q);
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      q.submit(q.snapshot.version);
      await settle();
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(20001, '{"reason":"phone_invalid"}'));
      q.submit(q.snapshot.version);
      await settle();
      expect(q.snapshot.phoneError !== null).assertTrue();
      q.leave();
    });

    it('fhm0722_x15_bind_page_held_resend_phone_errors_not_landed_on_edited_phone', 0, async () => {
      const edited: string = '13700007777';
      const replies: TransportResponse[] = [envelope(20001, '{"reason":"phone_invalid"}'),
        envelope(30411, '{"reason":"mergeable","merge_ticket":"x"}'), envelope(30414, '{}')];
      for (const reply of replies) {
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f);
        const fields: TestFields = new TestFields();
        const form: BindPhoneForm = new BindPhoneForm(svc, fields);
        form.setPhone(form.binding(), NEW_PHONE);
        form.setCode(form.binding(), '123456');
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
        await form.submit(form.binding());
        expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
        form.setPhone(form.binding(), edited);
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => reply);
        const out: BindOutcome | null = await form.submit(form.binding());
        await settle();
        expect((f.last('POST /v1/me/phone').body ?? '').indexOf(NEW_PHONE) >= 0).assertTrue();
        expect(out === null).assertTrue();
        expect(svc.mergePending).assertFalse();
        expect(fields.phoneText).assertEqual(edited);
        form.leave();
      }
      // 对照：没改号码时号码错误照常交给页面。
      const g: AccountFixture = new AccountFixture();
      const svc2: BindPhoneService = bindService(g);
      const form2: BindPhoneForm = new BindPhoneForm(svc2, new TestFields());
      form2.setPhone(form2.binding(), NEW_PHONE);
      form2.setCode(form2.binding(), '123456');
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      await form2.submit(form2.binding());
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      const kept: BindOutcome | null = await form2.submit(form2.binding());
      expect(kept !== null && BindOutcome.phoneClass(kept)).assertTrue();
      expect(kept?.reusedHeld).assertTrue();
      form2.leave();
    });
    // ---------------------------------------------------------------- 第 1 轮修复（review-r1）
    // R1-01（共性 47）：BindPhone 页作为接收实例——A 确认 / 放弃同键、回包前离页，B 重进恢复同键待确认；A 的终结结局交给 B。
    it('fhm0722_r1_01_bind_page_reentered_instance_receives_30411_30414_completed_3xxxx_and_abandoned', 0, async () => {
      const cases: string[] = ['confirm:30411', 'confirm:30414', 'abandon:completed_30414', 'abandon:abandoned'];
      for (const c of cases) {
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f);
        const a: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
        const key: string = await pendingBind(f, a, svc);
        expect(key.length > 0).assertTrue();
        const abandon: boolean = c.startsWith('abandon');
        f.reply(abandon ? 'POST /v1/idempotency-keys/abandon' : 'POST /v1/me/phone', (_r: TransportRequest) => null);
        const permit: BindPhonePagePermit = a.permit();
        const own: Promise<BindOutcome | null> = abandon ? a.abandonPending(key, permit) : a.confirmPending(key, permit);
        await settle();
        // A 回包前离页；B 重进，恢复同键待确认。
        a.leave();
        const b: BindReceiver = new BindReceiver(svc);
        expect(b.shownKey).assertEqual(key);
        let reply: TransportResponse = envelope(30411, '{}');
        if (c === 'confirm:30414') {
          reply = envelope(30414, '{}');
        } else if (c === 'abandon:completed_30414') {
          reply = envelope(0, '{"outcome":"completed","original":{"code":30414,"msg":""}}');
        } else if (c === 'abandon:abandoned') {
          reply = envelope(0, '{"outcome":"abandoned"}');
        }
        f.held[f.held.length - 1].resolve(reply);
        const mine: BindOutcome | null = await own;
        await settle();
        // A 已离页：自己拿到 null；B 卡片消失，并收到完整结局（只一次）。
        expect(mine === null).assertTrue();
        expect(b.shownKey === null).assertTrue();
        expect(b.ended.length).assertEqual(1);
        const o: BindOutcome = b.ended[0];
        if (c === 'abandon:abandoned') {
          expect(o.actionRaw).assertEqual(BindOutcome.ABANDONED);
          expect(o.textKey).assertEqual('pending_confirm.abandoned');
          expect(o.clearsCode).assertTrue();
        } else {
          expect(o.actionRaw).assertEqual(BindPhoneAction.ERROR);
          expect(o.ended).assertTrue();
          expect((o.textKey ?? '').startsWith(c === 'confirm:30411' ? 'error.30411' : 'error.30414')).assertTrue();
          expect(o.customerService).assertEqual(c === 'confirm:30414');
          expect(o.noticeKey === 'pending_confirm.already_done').assertEqual(c === 'abandon:completed_30414');
          // 字段保留策略：手机号保留（B 的表单恢复可用、可重填后提交）。
          expect(o.keepsPhone).assertTrue();
          expect(o.trace6).assertEqual('123456');
        }
        b.dispose();
      }
      // 对照：别的键 / 本实例自己在途的那一次不按通知重复落地（自己的结果经 gated 交回，30414 同样带客服入口）。
      const g: AccountFixture = new AccountFixture();
      const svc2: BindPhoneService = bindService(g);
      const self: BindReceiver = new BindReceiver(svc2);
      const key2: string = await pendingBind(g, self.form, svc2);
      self.refresh();
      expect(self.shownKey).assertEqual(key2);
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(30414, '{}'));
      const direct: BindOutcome | null = await self.form.confirmPending(key2, self.form.permit());
      await settle();
      expect(self.ended.length).assertEqual(0);
      expect(direct?.ended).assertTrue();
      expect(direct?.customerService).assertTrue();
      self.dispose();
    });

    // R1-02（共性 48）：放弃查明已受理（completed、original.code=0、没有 original.data）在作用域换代后迟到，共享结算照常。
    it('fhm0722_r1_02_deletion_abandon_completed_without_data_settles_after_same_epoch_full_refresh', 0, async () => {
      const f: AccountFixture = restrictedFixture();
      const c: DeleteAccountController = await pendingDeletion(f);
      const key: string = c.snapshot.pending?.key ?? '';
      expect(key.length > 0).assertTrue();
      f.reply('POST /v1/idempotency-keys/abandon', (_r: TransportRequest) => null);
      expect(c.abandon(c.snapshot.pendingVersion, key)).assertTrue();
      await settle();
      expect(f.count('POST /v1/idempotency-keys/abandon')).assertEqual(1);
      const abandonHeld: number = f.held.length - 1;
      const owner: string = f.walletScope();
      await refreshTo(f, 'full');
      expect(f.walletScope()).assertEqual(owner);
      f.session.sync();
      expect(c.alive).assertFalse();
      const changes: number = f.deletionChanges;
      const gen: number = f.session.deletionGeneration;
      f.held[abandonHeld].resolve(envelope(0, '{"outcome":"completed","original":{"code":0,"msg":""}}'));
      await settle();
      expect(f.rig.client.pendingFor('requestDeletion') === null).assertTrue();
      expect(f.deletionChanges).assertEqual(changes + 1);
      expect(f.session.deletionGeneration > gen).assertTrue();
      expect(f.count('POST /v1/idempotency-keys/abandon')).assertEqual(1);
    });

    // R1-03（共性 33）：撤回结果未知 → 自动核对读取失败（5xxxx）→ 用户【重试】查明已撤回 → 撤回成功结算一次。
    it('fhm0722_r1_03_cancel_unknown_verify_read_fails_then_retry_finds_cancelled_settles_once', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      const c: DeleteAccountController = await openDeletion(f, DeletionSource.SETTINGS);
      const exits: AccountMessage[] = [];
      c.exitToSettings = (toast: AccountMessage): void => {
        exits.push(toast);
      };
      f.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => {
        f.reply('GET /v1/me/deletion', (_q: TransportRequest) => envelope(50001, '{}'));
        return gateway();
      });
      expect(c.cancel(c.snapshot.version)).assertTrue();
      await settle();
      expect(exits.length).assertEqual(0);
      expect(stateOf(c)).assertEqual(DeletionPresentation.LOAD_FAILED);
      const changes: number = f.deletionChanges;
      const gen: number = f.session.deletionGeneration;
      f.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cancelledUser()));
      expect(c.retry(c.snapshot.version)).assertTrue();
      await settle();
      expect(exits.length).assertEqual(1);
      expect(exits[0].textKey).assertEqual('deletion.cancelled_toast');
      expect(f.deletionChanges).assertEqual(changes + 1);
      expect(f.session.deletionGeneration > gen).assertTrue();
      expect(f.count('POST /v1/me/deletion/cancel')).assertEqual(1);
      // 只结算一次：之后的读取不再按撤回成功处理。
      expect(c.retry(c.snapshot.version)).assertTrue();
      await settle();
      expect(exits.length).assertEqual(1);
      expect(f.deletionChanges).assertEqual(changes + 1);
      c.leave();
      // 对照：核对失败后先读到仍在冷静期（核对结束），之后再读到已撤回只落地读取结果，不按撤回成功出栈。
      const g: AccountFixture = new AccountFixture();
      g.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      const d: DeleteAccountController = await openDeletion(g, DeletionSource.SETTINGS);
      let gExits: number = 0;
      d.exitToSettings = (_t: AccountMessage): void => {
        gExits++;
      };
      g.reply('POST /v1/me/deletion/cancel', (_r: TransportRequest) => {
        g.reply('GET /v1/me/deletion', (_q: TransportRequest) => envelope(50001, '{}'));
        return gateway();
      });
      d.cancel(d.snapshot.version);
      await settle();
      g.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cooling()));
      d.retry(d.snapshot.version);
      await settle();
      expect(stateOf(d)).assertEqual(DeletionPresentation.COOLING);
      g.reply('GET /v1/me/deletion', (_r: TransportRequest) => envelope(0, cancelledUser()));
      d.retry(d.snapshot.version);
      await settle();
      expect(gExits).assertEqual(0);
      d.leave();
    });

    // R1-04（共性 41）：确认在途时页面被盖住，回包 10004 labor_agreement → 保存补办目标，回到可见给手动入口；补办后仍待确认、不自动提交。
    it('fhm0722_r1_04_bind_page_covered_confirm_10004_keeps_manual_guide_entry_until_leave_or_reset', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const a: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      const key: string = await pendingBind(f, a, svc);
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const permit: BindPhonePagePermit = a.permit();
      const own: Promise<BindOutcome | null> = a.confirmPending(key, permit);
      await settle();
      a.pageHidden();
      f.held[f.held.length - 1].resolve(envelope(10004, '{"consent_type":"labor_agreement"}'));
      expect((await own) === null).assertTrue();
      await settle();
      // 被盖住时不给入口（不可点），回到可见后有。
      expect(a.takeGuide(key) === null).assertTrue();
      expect(a.pageShown()).assertFalse();
      const guide: BindPendingGuide | null = a.pendingGuide(key);
      expect(guide?.route).assertEqual('LaborAgreement');
      expect(guide?.textKey).assertEqual('error.10004');
      expect(a.pendingGuide('other-key') === null).assertTrue();
      // 上一行作废了入口（键变了）；重新得到入口后点手动入口。
      const sent: number = f.count('POST /v1/me/phone');
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const again: Promise<BindOutcome | null> = a.confirmPending(key, a.permit());
      await settle();
      a.pageHidden();
      f.held[f.held.length - 1].resolve(envelope(10004, '{"consent_type":"labor_agreement"}'));
      await again;
      await settle();
      a.pageShown();
      expect(a.takeGuide(key)).assertEqual('LaborAgreement');
      expect(a.takeGuide(key) === null).assertTrue();
      // 补办回来：记录仍待确认，不自动提交。
      await settle();
      expect(svc.pendingView(a.pageIdentity)?.key).assertEqual(key);
      expect(f.count('POST /v1/me/phone')).assertEqual(sent + 1);
      // 离页 / 会话换代清除。
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const third: Promise<BindOutcome | null> = a.confirmPending(key, a.permit());
      await settle();
      a.pageHidden();
      f.held[f.held.length - 1].resolve(envelope(10004, '{"consent_type":"labor_agreement"}'));
      await third;
      a.pageShown();
      expect(a.pendingGuide(key) !== null).assertTrue();
      a.reset(new TestFields());
      expect(a.pendingGuide(key) === null).assertTrue();
      const b: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const fourth: Promise<BindOutcome | null> = b.confirmPending(key, b.permit());
      await settle();
      b.pageHidden();
      b.leave();
      f.held[f.held.length - 1].resolve(envelope(10004, '{"consent_type":"labor_agreement"}'));
      await fourth;
      b.pageShown();
      expect(b.pendingGuide(key) === null).assertTrue();
    });

    // R1-05（APP-05b 共性 36）：held 改号后重发得到 50001 / 50401——不是字段反馈，横幅、错误与 trace6 照常显示。
    it('fhm0722_r1_05_held_resend_after_phone_edit_5xxxx_banner_and_trace6_still_shown', 0, async () => {
      const edited: string = '13700007777';
      const codes: number[] = [50001, 50401];
      for (const code of codes) {
        const f: AccountFixture = new AccountFixture();
        const p: PhoneChangeController = await toStep2(f);
        await fillStep2(f, p);
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
        expect(p.submit(p.snapshot.version)).assertTrue();
        await settle();
        p.setNewPhone(p.snapshot.version, edited);
        f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(code, '{}'));
        expect(p.submit(p.snapshot.version)).assertTrue();
        await settle();
        expect((f.last('POST /v1/me/phone').body ?? '').indexOf(NEW_PHONE) >= 0).assertTrue();
        expect(p.snapshot.banner !== null).assertTrue();
        expect((p.snapshot.banner?.textKey ?? '').startsWith('error.50')).assertTrue();
        expect((p.snapshot.banner?.text ?? '').indexOf('123456') >= 0).assertTrue();
        expect(p.snapshot.newPhone).assertEqual(edited);
        expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
        p.leave();
        // BindPhone 同查：held 改号后重发得到 5xxxx，结果照常交给页面（带 trace6）。
        const g: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(g);
        const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
        form.setPhone(form.binding(), NEW_PHONE);
        form.setCode(form.binding(), '123456');
        g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
        await form.submit(form.binding());
        form.setPhone(form.binding(), edited);
        g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(code, '{}'));
        const out: BindOutcome | null = await form.submit(form.binding());
        expect(out?.reusedHeld).assertTrue();
        expect(out?.actionRaw).assertEqual(BindPhoneAction.ERROR);
        expect(out?.trace6).assertEqual('123456');
        form.leave();
      }
    });
    // ---------------------------------------------------------------- 第 2 轮修复（review-r2）
    // R2-01（R1-04 另一种顺序）：确认 / 放弃在途 → 被盖住 → 回包 10004 labor_agreement；「回包先到」与「页面先恢复」两种顺序都给手动入口。
    it('fhm0722_r2_01_bind_page_guide_entry_shown_for_confirm_abandon_reply_first_and_shown_first', 0, async () => {
      const cases: string[] = ['confirm:reply_first', 'confirm:shown_first', 'abandon:reply_first', 'abandon:shown_first'];
      for (const c of cases) {
        const abandon: boolean = c.startsWith('abandon');
        const shownFirst: boolean = c.endsWith('shown_first');
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f);
        const page: GuidePage = new GuidePage(svc);
        const key: string = await pendingBind(f, page.form, svc);
        page.refreshPending();
        expect(page.pendingKey).assertEqual(key);
        const endpoint: string = abandon ? 'POST /v1/idempotency-keys/abandon' : 'POST /v1/me/phone';
        f.reply(endpoint, (_r: TransportRequest) => null);
        const running: Promise<BindOutcome | null> = page.run(abandon);
        await settle();
        page.hidden();
        if (shownFirst) {
          // 页面先回到可见：此刻入口还没保存。
          page.shown();
          expect(page.guideText).assertEqual('');
        }
        const sent: number = f.count(endpoint);
        f.held[f.held.length - 1].resolve(envelope(10004, '{"consent_type":"labor_agreement"}'));
        const out: BindOutcome | null = await running;
        await settle();
        // 发起时的可见许可已失效：页面拿到 null（不导航、不弹窗）。
        expect(out === null).assertTrue();
        if (!shownFirst) {
          // 被盖住期间不显示，回到可见后显示。
          expect(page.guideText).assertEqual('');
          expect(page.guideCalls).assertEqual(0);
          page.shown();
        } else {
          expect(page.guideCalls).assertEqual(1);
        }
        expect(page.guideText).assertEqual('error.10004');
        expect(page.pendingKey).assertEqual(key);
        // 只给入口：不自动提交、不自动导航（入口仍在，点一次才取出补办目标）。
        await settle();
        expect(f.count(endpoint)).assertEqual(sent);
        expect(page.form.takeGuide(key)).assertEqual('LaborAgreement');
        expect(svc.pendingView(page.form.pageIdentity)?.key).assertEqual(key);
        page.dispose();
      }
      // 对照：先恢复后又被盖住 / 已离页时回包到达，不通知页面（回到可见由 onShown 兜；离页不给入口）。
      const ends: string[] = ['hidden_again', 'left'];
      for (const e of ends) {
        const g: AccountFixture = new AccountFixture();
        const svc2: BindPhoneService = bindService(g);
        const q: GuidePage = new GuidePage(svc2);
        const key2: string = await pendingBind(g, q.form, svc2);
        q.refreshPending();
        g.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
        const r: Promise<BindOutcome | null> = q.run(false);
        await settle();
        q.hidden();
        q.shown();
        if (e === 'left') {
          q.form.leave();
        } else {
          q.hidden();
        }
        g.held[g.held.length - 1].resolve(envelope(10004, '{"consent_type":"labor_agreement"}'));
        expect((await r) === null).assertTrue();
        await settle();
        expect(q.guideCalls).assertEqual(0);
        expect(q.guideText).assertEqual('');
        q.shown();
        expect(q.guideText).assertEqual(e === 'left' ? '' : 'error.10004');
        expect(q.pendingKey).assertEqual(key2);
        q.dispose();
      }
    });

    // R2-02（F-X-15）：号码 A + 验证码 123456 → 50401 held → 改成号码 B、验证码不变 → 重发 A 原体得到 20002 / 20003，不落到 B 的验证码上。
    it('fhm0722_r2_02_bind_page_held_resend_after_phone_edit_same_code_20002_20003_not_landed', 0, async () => {
      const edited: string = '13700007777';
      const replies: number[] = [20002, 20003];
      // 改号（丢弃）/ 等价写法 / 没改号（都照常交给页面）。
      const edits: string[] = [edited, EQUIVALENT, NEW_PHONE];
      for (const code of replies) {
        for (const phone of edits) {
          const f: AccountFixture = new AccountFixture();
          const svc: BindPhoneService = bindService(f);
          const fields: TestFields = new TestFields();
          const form: BindPhoneForm = new BindPhoneForm(svc, fields);
          form.setPhone(form.binding(), NEW_PHONE);
          form.setCode(form.binding(), '123456');
          f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
          await form.submit(form.binding());
          expect(f.rig.pendingBackend.list('user-1').length).assertEqual(1);
          form.setPhone(form.binding(), phone);
          f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(code, '{}'));
          const out: BindOutcome | null = await form.submit(form.binding());
          await settle();
          const body: string = f.last('POST /v1/me/phone').body ?? '';
          expect(body.indexOf(NEW_PHONE) >= 0 && body.indexOf('123456') >= 0).assertTrue();
          expect(fields.phoneText).assertEqual(phone);
          expect(fields.codeText).assertEqual('123456');
          if (phone === edited) {
            expect(out === null).assertTrue();
            // R3-03：旧键已按结局结束；再提交一次用新键，请求体是当前号码与验证码。
            const oldKey: string | undefined = header(f.last('POST /v1/me/phone'), 'Idempotency-Key');
            expect(oldKey !== undefined && (oldKey as string).length > 0).assertTrue();
            expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
            expect(f.rig.client.pendingFor('bindPhone') === null).assertTrue();
            const posts: number = f.count('POST /v1/me/phone');
            f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50001, '{}'));
            const next: BindOutcome | null = await form.submit(form.binding());
            await settle();
            expect(f.count('POST /v1/me/phone')).assertEqual(posts + 1);
            const nextBody: string = f.last('POST /v1/me/phone').body ?? '';
            expect(nextBody.indexOf(edited) >= 0 && nextBody.indexOf('123456') >= 0).assertTrue();
            expect(nextBody.indexOf(NEW_PHONE) < 0).assertTrue();
            const newKey: string | undefined = header(f.last('POST /v1/me/phone'), 'Idempotency-Key');
            expect(newKey !== undefined && newKey !== oldKey).assertTrue();
            expect(next?.reusedHeld).assertFalse();
          } else {
            expect(out !== null && BindOutcome.codeError(out)).assertTrue();
            expect(out?.reusedHeld).assertTrue();
          }
          form.leave();
        }
      }
      // 对照：改号后重发得到 5xxxx，结果照常交给页面（带 trace6）。
      const g: AccountFixture = new AccountFixture();
      const svc2: BindPhoneService = bindService(g);
      const form2: BindPhoneForm = new BindPhoneForm(svc2, new TestFields());
      form2.setPhone(form2.binding(), NEW_PHONE);
      form2.setCode(form2.binding(), '123456');
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      await form2.submit(form2.binding());
      form2.setPhone(form2.binding(), edited);
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50001, '{}'));
      const five: BindOutcome | null = await form2.submit(form2.binding());
      expect(five?.actionRaw).assertEqual(BindPhoneAction.ERROR);
      expect(five?.trace6).assertEqual('123456');
      form2.leave();
    });

    // R2-02 换号页同查：held 改号、验证码不变，20002 / 20003 不落到新号的验证码上；等价写法 / 没改号照常显示在验证码上。
    it('fhm0722_r2_02_phone_change_held_resend_after_phone_edit_same_code_20002_20003_not_landed', 0, async () => {
      const edited: string = '13700007777';
      const replies: number[] = [20002, 20003];
      const edits: string[] = [edited, EQUIVALENT, NEW_PHONE];
      for (const code of replies) {
        for (const phone of edits) {
          const f: AccountFixture = new AccountFixture();
          const p: PhoneChangeController = await toStep2(f);
          await fillStep2(f, p);
          f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
          expect(p.submit(p.snapshot.version)).assertTrue();
          await settle();
          p.setNewPhone(p.snapshot.version, phone);
          const typed: string = p.snapshot.code;
          f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(code, '{}'));
          p.submit(p.snapshot.version);
          await settle();
          expect((f.last('POST /v1/me/phone').body ?? '').indexOf(NEW_PHONE) >= 0).assertTrue();
          expect(p.snapshot.newPhone).assertEqual(phone);
          expect(p.snapshot.step).assertEqual(PhoneChangeStep.STEP2);
          if (phone === edited) {
            expect(p.snapshot.codeError === null).assertTrue();
            expect(p.snapshot.banner === null).assertTrue();
            expect(p.snapshot.code).assertEqual(typed);
            // R3-03：旧键已按结局结束；再提交一次用新键，请求体是当前号码与验证码。
            const oldKey: string | undefined = header(f.last('POST /v1/me/phone'), 'Idempotency-Key');
            expect(oldKey !== undefined && (oldKey as string).length > 0).assertTrue();
            expect(f.rig.pendingBackend.list('user-1').length).assertEqual(0);
            expect(f.rig.client.pendingFor('bindPhone') === null).assertTrue();
            const posts: number = f.count('POST /v1/me/phone');
            f.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50001, '{}'));
            expect(p.submit(p.snapshot.version)).assertTrue();
            await settle();
            expect(f.count('POST /v1/me/phone')).assertEqual(posts + 1);
            const nextBody: string = f.last('POST /v1/me/phone').body ?? '';
            expect(nextBody.indexOf(edited) >= 0 && nextBody.indexOf(typed) >= 0).assertTrue();
            expect(nextBody.indexOf(NEW_PHONE) < 0).assertTrue();
            const newKey: string | undefined = header(f.last('POST /v1/me/phone'), 'Idempotency-Key');
            expect(newKey !== undefined && newKey !== oldKey).assertTrue();
          } else {
            expect(p.snapshot.codeError !== null || p.snapshot.banner !== null).assertTrue();
          }
          p.leave();
        }
      }
      // 对照：改号后 5xxxx 横幅照常。
      const g: AccountFixture = new AccountFixture();
      const q: PhoneChangeController = await toStep2(g);
      await fillStep2(g, q);
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50401, '{}'));
      q.submit(q.snapshot.version);
      await settle();
      q.setNewPhone(q.snapshot.version, edited);
      g.reply('POST /v1/me/phone', (_r: TransportRequest) => envelope(50001, '{}'));
      q.submit(q.snapshot.version);
      await settle();
      expect(q.snapshot.banner !== null).assertTrue();
      q.leave();
    });

    // ---------------------------------------------------------------- 第 3 轮窄修
    // R3-01（共性 47）：确认 / 放弃已到服务端 → 同账号同登录世代作用域刷新 → 页面 reset、新身份恢复同键待确认 → 旧请求的完整结局按通知
    // 交给新身份的表单（旧身份的 ownPending 不再吞掉）；旧请求自己经 gated 拿 null。
    it('fhm0722_r3_01_bind_page_reset_after_scope_refresh_receives_confirm_abandon_ending_for_same_key', 0, async () => {
      const cases: string[] = ['confirm:30414', 'abandon:completed_30414', 'abandon:abandoned'];
      for (const c of cases) {
        const f: AccountFixture = new AccountFixture();
        const svc: BindPhoneService = bindService(f);
        const page: BindReceiver = new BindReceiver(svc);
        const key: string = await pendingBind(f, page.form, svc);
        page.refresh();
        expect(page.shownKey).assertEqual(key);
        const abandon: boolean = c.startsWith('abandon');
        f.reply(abandon ? 'POST /v1/idempotency-keys/abandon' : 'POST /v1/me/phone', (_r: TransportRequest) => null);
        const permit: BindPhonePagePermit = page.form.permit();
        const own: Promise<BindOutcome | null> = abandon ? page.form.abandonPending(key, permit)
          : page.form.confirmPending(key, permit);
        await settle();
        const held: number = f.held.length - 1;
        const oldPage: number = page.form.pageIdentity.page;
        // 同账号同登录世代：full → deletion_only；App 同步区里 syncSession 通知页面 reset，按新身份恢复同键待确认。
        await refreshTo(f, 'deletion_only');
        expect(f.rig.client.sessionScope()).assertEqual('deletion_only');
        expect(svc.syncSession()).assertTrue();
        f.session.sync();
        page.form.reset(new TestFields());
        expect(page.form.pageIdentity.page !== oldPage).assertTrue();
        page.refresh();
        expect(page.shownKey).assertEqual(key);
        let reply: TransportResponse = envelope(30414, '{}');
        if (c === 'abandon:completed_30414') {
          reply = envelope(0, '{"outcome":"completed","original":{"code":30414,"msg":""}}');
        } else if (c === 'abandon:abandoned') {
          reply = envelope(0, '{"outcome":"abandoned"}');
        }
        f.held[held].resolve(reply);
        const mine: BindOutcome | null = await own;
        await settle();
        expect(mine === null).assertTrue();
        expect(page.shownKey === null).assertTrue();
        expect(page.ended.length).assertEqual(1);
        const o: BindOutcome = page.ended[0];
        if (c === 'abandon:abandoned') {
          expect(o.actionRaw).assertEqual(BindOutcome.ABANDONED);
          expect(o.textKey).assertEqual('pending_confirm.abandoned');
          expect(o.clearsCode).assertTrue();
        } else {
          expect(o.actionRaw).assertEqual(BindPhoneAction.ERROR);
          expect(o.ended).assertTrue();
          expect((o.textKey ?? '').startsWith('error.30414')).assertTrue();
          // 与 R1-01 同口径：确认得到 30414 给客服入口；放弃 completed 原 30414 给「已处理完」提示。
          expect(o.customerService).assertEqual(c === 'confirm:30414');
          expect(o.noticeKey === 'pending_confirm.already_done').assertEqual(c === 'abandon:completed_30414');
          expect(o.keepsPhone).assertTrue();
          expect(o.trace6).assertEqual('123456');
        }
        page.dispose();
      }
    });

    // R3-02：作用域换代（deletion_only → full，同账号同登录世代）后迟到的旧作用域 42901 不写进新作用域的闸门；已发请求照常网络结算。
    it('fhm0722_r3_02_deletion_apply_late_42901_after_scope_refresh_not_written_to_new_gate', 0, async () => {
      const f: AccountFixture = restrictedFixture();
      const c: DeleteAccountController = await openDeletion(f);
      f.session.tokens.put('account_deletion', 'user-1', 'restricted-step-token', f.rig.nowMillis + 60000, f.scope());
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => null);
      c.setChecked(c.snapshot.version, true);
      expect(c.apply(c.snapshot.version)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
      const applyHeld: number = f.held.length - 1;
      await refreshTo(f, 'full');
      f.session.sync();
      expect(c.alive).assertFalse();
      expect(f.session.deletionGate.active).assertFalse();
      f.held[applyHeld].resolve(envelope(42901, '{}', { 'Retry-After': '30' }));
      await settle();
      expect(f.session.deletionGate.active).assertFalse();
      expect(f.session.deletionGate.remainingMs).assertEqual(0);
      expect(f.count('POST /v1/me/deletion')).assertEqual(1);
      // 对照：新 full 页自己的 42901 照常写闸门。
      const c2: DeleteAccountController = await openDeletion(f);
      f.reply('POST /v1/me/deletion', (_r: TransportRequest) => envelope(42901, '{}', { 'Retry-After': '30' }));
      f.session.tokens.put('account_deletion', 'user-1', 'full-step-token', f.rig.nowMillis + 60000, f.scope());
      c2.setChecked(c2.snapshot.version, true);
      expect(c2.apply(c2.snapshot.version)).assertTrue();
      await settle();
      expect(f.count('POST /v1/me/deletion')).assertEqual(2);
      expect(f.session.deletionGate.active).assertTrue();
      c2.leave();
    });

    it('fhm0722_r3_02_deletion_confirm_abandon_late_42901_after_scope_refresh_not_written_to_new_gate', 0, async () => {
      const ops: string[] = ['confirm', 'abandon'];
      for (const op of ops) {
        const f: AccountFixture = restrictedFixture();
        const c: DeleteAccountController = await pendingDeletion(f);
        const key: string = c.snapshot.pending?.key ?? '';
        expect(key.length > 0).assertTrue();
        const path: string = op === 'confirm' ? 'POST /v1/me/deletion' : 'POST /v1/idempotency-keys/abandon';
        f.reply(path, (_r: TransportRequest) => null);
        const sent: number = f.count(path);
        expect(op === 'confirm' ? c.confirm(c.snapshot.pendingVersion, key)
          : c.abandon(c.snapshot.pendingVersion, key)).assertTrue();
        await settle();
        expect(f.count(path)).assertEqual(sent + 1);
        const held: number = f.held.length - 1;
        await refreshTo(f, 'full');
        f.session.sync();
        expect(c.alive).assertFalse();
        expect(f.session.deletionGate.active).assertFalse();
        f.held[held].resolve(envelope(42901, '{}', { 'Retry-After': '30' }));
        await settle();
        expect(f.session.deletionGate.active).assertFalse();
        expect(f.session.deletionGate.remainingMs).assertEqual(0);
        expect(f.count(path)).assertEqual(sent + 1);
        // 未决记录保留原键（42901 不结束键），新实例仍可操作。
        const again: DeleteAccountController = await openDeletion(f);
        expect(again.snapshot.pending?.key).assertEqual(key);
        again.leave();
      }
    });

    it('fhm0722_r3_02_bind_page_late_42901_after_scope_refresh_not_written_to_new_phone_gate', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      const svc: BindPhoneService = bindService(f);
      const form: BindPhoneForm = new BindPhoneForm(svc, new TestFields());
      form.setPhone(form.binding(), NEW_PHONE);
      form.setCode(form.binding(), '123456');
      f.reply('POST /v1/me/phone', (_r: TransportRequest) => null);
      const own: Promise<BindOutcome | null> = form.submit(form.binding());
      await settle();
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      const held: number = f.held.length - 1;
      await refreshTo(f, 'deletion_only');
      expect(svc.syncSession()).assertTrue();
      f.session.sync();
      form.reset(new TestFields());
      expect(f.session.phoneGate.active).assertFalse();
      f.held[held].resolve(envelope(42901, '{}', { 'Retry-After': '30' }));
      const mine: BindOutcome | null = await own;
      await settle();
      expect(mine === null || mine.actionRaw !== BindPhoneAction.DONE).assertTrue();
      expect(f.session.phoneGate.active).assertFalse();
      expect(svc.phoneGateActive).assertFalse();
      expect(f.count('POST /v1/me/phone')).assertEqual(1);
      form.leave();
    });
  });
}
