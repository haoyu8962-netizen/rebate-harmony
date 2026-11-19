// LOCK-harmony 段 3 测试写手（二次验证与提现：发码去 phone + step_up 必须有会话 + phone_bound 判据 + 改收款摘要 + 令牌缓存摘要 + 提现补用例）。
// 口径：seg3-brief「段 3 要做的」1–5；裁定 D10-1635 ①②、D10-1658 ①、D10-1659 S2-4/S2-5、D10-1665 / 1667、D10-1682 ②、D10-1703 末句、
// 03 §4.2 第四条、D10-2108 Q5。假服务（entry/src/staging DebugFake*）的规则用例不在本文件，见 entry/src/ohosTest/ets/test/LockHarmonySeg3Fake.test.ets。
// 全部走真实 ApiClient + 本地假服务（NetworkTestRig），从生产调用点驱动：StepUpController、WithdrawController / PayoutAccountController（经
// SensitiveFlow）、PhoneChangeController、DeleteAccountController、StepUpTokenCache。
// 新接口不假设类型，只假设名字（实现若取别名，报编排一并改本文件的常量）：
// - StepUpDeps / WalletDeps / AccountDeps 的 phoneBound: () => boolean | null（同 AgentDeps / MePages 的同名回调；本文件用 Reflect.set 写入，
//   HEAD 上写了也没人读）；
// - StepUpTokenCache.put(action, account, token, expireAtMs, binding = '', summary: string | null = null) 与
//   take(action, account, nowMs, binding: string | null = null, summary: string | null = null)：summary 是调用方算好的业务摘要键，
//   null = 不带摘要；严格相等才复用（null 与非 null 也算不同）。只有缓存直测用这个签名（经 SummaryTokenCache 接口转型调用）。
// 每条用例上方写「先红」：先红 = 当前 HEAD（60575f3，未实现）上这条怎样；标「防改错」的是现状已对、钉住不许改坏的。
import { describe, it, expect } from '@ohos/hypium';
import {
  AccountDeps, ApiClient, ApiOutcome, ApiRequest, ApiResult, DeleteAccountController, LocalRejectReason, NetworkHeaders, PayoutAccountController,
  PayoutPhase, PhoneChangeController, RoutePolicy, SessionTokenSet, StepUpController, StepUpTokenCache, TransportFailure,
  TransportRequest, TransportResponse, WalletDeps, WalletMessage, WithdrawController, WithdrawPhase
} from '../../Index';
import { envelope, header, Rig } from './NetworkTestRig';
import { NOW, openWithdraw, passStepUp, settle, TEST_PHONE, WalletFixture } from './WalletIntegration.test';
import {
  AccountFixture, applyWithStepUp, openDeletion, PHONE as ACCOUNT_PHONE, settle as accountSettle, toStep2
} from './AccountIntegration.test';

/** StepUpDeps 新增的「本账号是否绑定手机号」回调名（见文件头）。 */
const PHONE_BOUND: string = 'phoneBound';
const SMS: string = 'POST /v1/auth/sms-codes';
const VERIFY: string = 'POST /v1/auth/step-up';
const PAYOUT_ACTION: string = 'payout_account_change';
const PAYOUT_LOGON: string = 'zhangsan@example.com';
const PAYOUT_LOGON_B: string = 'lisi@example.com';
const PAYOUT_CARD: string = '6222 0000-0000 0009';
const STEP_TOKEN: string = 'fixture-step-token';

/** 缓存直测用的签名（见文件头；HEAD 上多出的参数被忽略）。 */
interface SummaryTokenCache {
  put(action: string, account: string, token: string, expireAtMs: number, binding: string, summary: string | null): void;

  take(action: string, account: string, nowMs: number, binding: string | null, summary: string | null): string | null;
}

function summaryCache(): SummaryTokenCache {
  return new StepUpTokenCache() as Object as SummaryTokenCache;
}

function bodyOf(r: TransportRequest): Record<string, Object> {
  return JSON.parse(r.body ?? '{}') as Record<string, Object>;
}

/** 请求体的键（排序后逗号连接）。 */
function keysOf(o: Record<string, Object>): string {
  return Object.keys(o).sort().join(',');
}

function sentTo(rig: TransportRequest[], key: string): TransportRequest[] {
  const parts: string[] = key.split(' ');
  return rig.filter((r: TransportRequest): boolean => r.method === parts[0]
    && r.url.split('?')[0].endsWith(parts[1]));
}

function walletSent(f: WalletFixture, key: string): TransportRequest[] {
  return sentTo(f.rig.server.received, key);
}

function accountSent(f: AccountFixture, key: string): TransportRequest[] {
  return sentTo(f.rig.server.received, key);
}

function withPhoneBound(d: Object, bound: boolean | null): void {
  Reflect.set(d, PHONE_BOUND, (): boolean | null => bound);
}

/** 钱包装配 + 指定的 phone_bound 回调。 */
function walletDeps(f: WalletFixture, bound: boolean | null = true): WalletDeps {
  const d: WalletDeps = f.deps();
  withPhoneBound(d, bound);
  return d;
}

/** 收款账号页：还没绑（GET 回空对象）→ 表单；PUT 不带令牌回 10003，带令牌按 withToken 回。 */
function payoutFixture(withToken: (r: TransportRequest) => TransportResponse): WalletFixture {
  const f: WalletFixture = new WalletFixture();
  f.reply('GET /v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
  f.reply('PUT /v1/me/payout-account', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
    ? envelope(10003, '{}') : withToken(r));
  return f;
}

function payoutSaved(_r: TransportRequest): TransportResponse {
  return envelope(0, '{"payout_method":"alipay","masked_account":"zh***@example.com","masked_payee_name":"**三",'
    + '"change_remaining_this_month":1}');
}

async function openPayout(f: WalletFixture, bound: boolean | null = true): Promise<PayoutAccountController> {
  f.session.sync();
  const p: PayoutAccountController = new PayoutAccountController(walletDeps(f, bound));
  p.onShown();
  await settle();
  return p;
}

/** 支付宝表单填好（登录号与姓名两侧带空白：请求体只去首尾空白）。 */
function fillAlipay(p: PayoutAccountController, logon: string): void {
  p.setMethod('alipay');
  p.setField('alipay_logon_id', '  ' + logon + ' ');
  p.setField('payee_name', ' 测试三 ');
}

/** 改收款的 step-up 体里的 summary（没有为 null）。 */
function summaryOf(r: TransportRequest): Record<string, Object> | null {
  const v: Object | undefined = bodyOf(r)['summary'];
  return v === undefined || v === null || typeof v !== 'object' ? null : v as Record<string, Object>;
}

/** 二次验证面板已打开、发码请求已结算（不输码）。 */
async function sendOnly(s: StepUpController): Promise<boolean> {
  const issued: boolean = s.send();
  await settle();
  return issued;
}

export default function lockHarmonySeg3Test() {
  describe('LockHarmonySeg3', () => {
    // ================================================================ 1. step_up 发码（D10-1635 ①、D10-1658 ①、03 §4.2 第四条）

    // 依据：D10-1635 ①、D10-1658 ①：step_up 发码请求体不带 phone；号码只作 SmsResendClock 的键。四个 action 同一执行器。
    // 先红：HEAD 请求体是 {phone, purpose, action}（StepUpController.ets:193），keys 断言红。
    it('s3_1_1_step_up_sms_body_has_no_phone_for_all_four_actions_and_carries_bearer', 0, async () => {
      const actions: string[] = ['withdraw', PAYOUT_ACTION, 'phone_change', 'account_deletion'];
      for (const action of actions) {
        const f: WalletFixture = new WalletFixture();
        f.session.sync();
        const s: StepUpController = new StepUpController(walletDeps(f), action, 'user-1');
        expect(await sendOnly(s)).assertTrue();
        const sent: TransportRequest[] = walletSent(f, SMS);
        expect(sent.length).assertEqual(1);
        const body: Record<string, Object> = bodyOf(sent[0]);
        expect(action + ':' + keysOf(body)).assertEqual(action + ':action,purpose');
        expect(body['purpose'] as string).assertEqual('step_up');
        expect(body['action'] as string).assertEqual(action);
        expect((sent[0].body ?? '').indexOf(TEST_PHONE)).assertEqual(-1);
        // 防改错：发码仍带会员令牌（不因去掉 phone 改成匿名发）
        expect(header(sent[0], NetworkHeaders.AUTHORIZATION) as string).assertEqual('Bearer old-access');
        expect(s.snapshot.sent).assertTrue();
        s.close();
      }
    });

    // 依据：同上，经生产调用点：提现 10003 → 面板发码；换号第 1 步；注销申请 10003 → 面板发码。
    // 先红：三处发码体都带 phone（keys 断言红）。
    it('s3_1_2_production_call_points_send_step_up_sms_without_phone', 0, async () => {
      const w: WalletFixture = new WalletFixture();
      w.session.sync();
      const c: WithdrawController = new WithdrawController(walletDeps(w));
      c.onShown();
      await settle();
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      await passStepUp(c);
      expect('withdraw:' + keysOf(bodyOf(w.last('/v1/auth/sms-codes')))).assertEqual('withdraw:action,purpose');

      const a: AccountFixture = new AccountFixture();
      await toStep2(a);
      const phoneSms: TransportRequest[] = accountSent(a, SMS);
      expect(phoneSms.length).assertEqual(1);
      expect('phone_change:' + keysOf(bodyOf(phoneSms[0]))).assertEqual('phone_change:action,purpose');
      expect((phoneSms[0].body ?? '').indexOf(ACCOUNT_PHONE)).assertEqual(-1);

      const b: AccountFixture = new AccountFixture();
      const d: DeleteAccountController = await openDeletion(b);
      await applyWithStepUp(d);
      const delSms: TransportRequest[] = accountSent(b, SMS);
      expect(delSms.length).assertEqual(1);
      expect('account_deletion:' + keysOf(bodyOf(delSms[0]))).assertEqual('account_deletion:action,purpose');
    });

    // 依据：D10-1658 ①：Release 有账号时给不含数字的槽位占位（安卓 "bound"），号码只作 SmsResendClock 的键、不上送。
    // 这里用占位 "bound" 当 stepUpPhone：照常发码、请求体不出现占位；同键重开面板恢复倒计时（键仍按账号 + 占位 + action）。
    // 先红：HEAD 把 "bound" 当号码写进请求体（phone=bound）。
    it('s3_1_3_digitless_slot_placeholder_sends_and_keys_the_resend_clock_but_is_not_uploaded', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.phone = 'bound';
      f.session.sync();
      const s: StepUpController = new StepUpController(walletDeps(f), 'withdraw', 'user-1');
      expect(await sendOnly(s)).assertTrue();
      expect(s.snapshot.noPhone).assertFalse();
      const sent: TransportRequest[] = walletSent(f, SMS);
      expect(sent.length).assertEqual(1);
      expect((sent[0].body ?? '').indexOf('bound')).assertEqual(-1);
      expect(keysOf(bodyOf(sent[0]))).assertEqual('action,purpose');
      s.close();
      // 同账号、同占位、同 action 重开：恢复倒计时，不再发
      const again: StepUpController = new StepUpController(walletDeps(f), 'withdraw', 'user-1');
      expect(again.snapshot.sent).assertTrue();
      expect(again.snapshot.countdown > 0).assertTrue();
      expect(again.send()).assertFalse();
      await settle();
      expect(walletSent(f, SMS).length).assertEqual(1);
      again.close();
    });

    // 依据：03 §4.2 第四条、D10-1703 末句、iOS 段 2 S2-1、安卓 requiresSession：step_up 发码必须有会话；ApiClient 已是确认游客（没有
    // 会话）时本地拒、零写出，不匿名发。面板的发起身份（account / scope）用钉住的旧值模拟「页面还以为有会话」——只靠面板的归属回调挡
    // 不住时，网络层或调用点也必须拒。
    // 先红：HEAD 的 sendSmsCode 是 optional，确认游客照发 1 次、不带 Authorization。
    it('s3_1_4_step_up_sms_confirmed_guest_rejected_locally_zero_writes', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      f.rig.tokens.clear();
      f.rig.client.onSessionChanged();
      const d: WalletDeps = walletDeps(f);
      d.account = (): string | null => 'user-1';
      d.scope = (): string => 'pinned-scope';
      const s: StepUpController = new StepUpController(d, 'withdraw', 'user-1', 'pinned-scope');
      s.send();
      await settle();
      expect(walletSent(f, SMS).length).assertEqual(0);
      expect(s.snapshot.sent).assertFalse();
      expect(s.snapshot.sending).assertFalse();
      s.close();
    });

    // 依据：同上，「身份未知照段 2 口径拒」（D10-1931，03 §4.2 第二条）：会话此刻读不出时 step_up 发码零写出。
    // 先红：绿（防改错）。段 2 的身份未知一档已拒 optional；防段 3 给 step_up 发码加声明或开关时越过这一档。
    it('s3_1_5_step_up_sms_identity_unknown_rejected_zero_writes', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      f.rig.tokens.unreadable = true;
      const d: WalletDeps = walletDeps(f);
      d.account = (): string | null => 'user-1';
      d.scope = (): string => 'pinned-scope';
      const s: StepUpController = new StepUpController(d, 'account_deletion', 'user-1', 'pinned-scope');
      s.send();
      await settle();
      expect(walletSent(f, SMS).length).assertEqual(0);
      expect(s.snapshot.sent).assertFalse();
      s.close();
    });

    // ================================================================ 2. noPhone 判据改看 phone_bound（D10-1682 ②、D10-1659 S2-4/S2-5、D10-1667）

    // 依据：phone_bound=false 时改收款不发码，走「先绑定手机」（面板 noPhone，或干脆不开面板）；本机号码槽位有值也一样。
    // 先红：HEAD 只看 stepUpPhone（有值），照发 1 次。
    it('s3_2_1_phone_bound_false_payout_change_sends_no_code', 0, async () => {
      const f: WalletFixture = payoutFixture(payoutSaved);
      const p: PayoutAccountController = await openPayout(f, false);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      fillAlipay(p, PAYOUT_LOGON);
      p.save();
      await settle();
      // 评审 S3-6：面板必须开出来再查（不许 createStepUp 返回 null 时整段空过）；不发码、走「先绑定手机」引导（noPhone）。
      const s: StepUpController | null = p.createStepUp();
      expect(s !== null).assertTrue();
      const panel: StepUpController = s as StepUpController;
      panel.send();
      await settle();
      expect(panel.snapshot.noPhone).assertTrue();
      expect(panel.snapshot.sent).assertFalse();
      panel.close();
      expect(walletSent(f, SMS).length).assertEqual(0);
      expect(walletSent(f, VERIFY).length).assertEqual(0);
    });

    // 依据：同上，换号：phone_bound=false 时第 1 步不发码（phoneKnown 置 false，页面走「先绑定手机」）。
    // 先红：HEAD phoneKnown 看 stepUpPhone（有值）→ true，【获取验证码】照发 1 次。
    it('s3_2_2_phone_bound_false_phone_change_step1_sends_no_code', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.session.sync();
      const d: AccountDeps = f.deps();
      withPhoneBound(d, false);
      const p: PhoneChangeController = new PhoneChangeController(d);
      p.onShown();
      expect(p.snapshot.phoneKnown).assertFalse();
      p.sendStep1(p.snapshot.version);
      await accountSettle();
      expect(accountSent(f, SMS).length).assertEqual(0);
    });

    // 依据：同上，注销：getMe 的 phone_bound=false → 只提示、不发申请、不发码（DeleteAccountController 现有口径，G10）。
    // 先红：绿（防改错）。防把注销的判据换成 stepUpPhone / 槽位占位后放行。
    it('s3_2_3_phone_bound_false_deletion_no_apply_no_code', 0, async () => {
      const f: AccountFixture = new AccountFixture();
      f.reply('GET /v1/me', (_r: TransportRequest) => envelope(0, '{"user_id":"user-1","phone_bound":false}'));
      const c: DeleteAccountController = await openDeletion(f);
      c.setChecked(c.snapshot.version, true);
      c.apply(c.snapshot.version);
      await accountSettle();
      expect(c.snapshot.unsupportedShown).assertTrue();
      expect(accountSent(f, 'POST /v1/me/deletion').length).assertEqual(0);
      expect(accountSent(f, SMS).length).assertEqual(0);
    });

    // 依据：D10-1667：phone_bound 判据「只拦改收款 / 换号 / 注销，不碰提现」。phone_bound=false 时提现 10003 仍弹面板、照常发码、验证、
    // 沿用原键重放。
    // 先红：绿（防改错）。防实现把 phone_bound 判据加在四个 action 共用的入口上。
    it('s3_2_4_phone_bound_false_does_not_block_withdraw_step_up', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const c: WithdrawController = new WithdrawController(walletDeps(f, false));
      c.onShown();
      await settle();
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      const s: StepUpController = await passStepUp(c);
      expect(s.snapshot.noPhone).assertFalse();
      expect(walletSent(f, SMS).length).assertEqual(1);
      expect(walletSent(f, VERIFY).length).assertEqual(1);
      expect(walletSent(f, 'POST /v1/withdrawals').length).assertEqual(2);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.DONE);
    });

    // 依据：phone_bound=true 时改收款 / 换号照常发码（本机号码槽位有值）。
    // 先红：绿（防改错）。防「一律不发」。
    it('s3_2_5_phone_bound_true_payout_and_phone_change_still_send', 0, async () => {
      const f: WalletFixture = payoutFixture(payoutSaved);
      const p: PayoutAccountController = await openPayout(f, true);
      fillAlipay(p, PAYOUT_LOGON);
      p.save();
      await settle();
      const s: StepUpController = p.createStepUp() as StepUpController;
      expect(await sendOnly(s)).assertTrue();
      expect(walletSent(f, SMS).length).assertEqual(1);
      s.close();

      const a: AccountFixture = new AccountFixture();
      a.session.sync();
      const d: AccountDeps = a.deps();
      withPhoneBound(d, true);
      const pc: PhoneChangeController = new PhoneChangeController(d);
      pc.onShown();
      expect(pc.snapshot.phoneKnown).assertTrue();
      pc.sendStep1(pc.snapshot.version);
      await accountSettle();
      expect(accountSent(a, SMS).length).assertEqual(1);
    });

    // ================================================================ 3. 改收款 step-up 带 summary（D10-1635 ②、D10-1667 第 3 条）

    // 依据：首次保存（支付宝）：POST /v1/auth/step-up 体 = {action, code, summary}；summary = {payout_method: alipay, alipay_logon_id}，
    // 账号是 PayoutAccountForm.body(form) 将要 PUT 的原样（去首尾空白后），不带收款人姓名，不是脱敏展示摘要（zh***@example.com）。
    // 先红：HEAD 验证体只有 {action, code}（keys 断言红）。
    it('s3_3_1_payout_first_save_alipay_step_up_carries_raw_body_summary_without_payee', 0, async () => {
      const f: WalletFixture = payoutFixture(payoutSaved);
      const p: PayoutAccountController = await openPayout(f);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      fillAlipay(p, PAYOUT_LOGON);
      expect(p.save()).assertTrue();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.STEP_UP);
      await passStepUp(p);
      const v: TransportRequest = f.last(VERIFY);
      const body: Record<string, Object> = bodyOf(v);
      expect(keysOf(body)).assertEqual('action,code,summary');
      expect(body['action'] as string).assertEqual(PAYOUT_ACTION);
      const sum: Record<string, Object> | null = summaryOf(v);
      expect(sum !== null).assertTrue();
      expect(keysOf(sum as Record<string, Object>)).assertEqual('alipay_logon_id,payout_method');
      expect((sum as Record<string, Object>)['payout_method'] as string).assertEqual('alipay');
      expect((sum as Record<string, Object>)['alipay_logon_id'] as string).assertEqual(PAYOUT_LOGON);
      const raw: string = v.body ?? '';
      expect(raw.indexOf('测试三')).assertEqual(-1);
      expect(raw.indexOf('**三')).assertEqual(-1);
      expect(raw.indexOf('zh***')).assertEqual(-1);
      // 摘要里的账号与随后 PUT 的原体一致；发码体不带摘要
      const put: TransportRequest = f.last('PUT /v1/me/payout-account');
      expect(bodyOf(put)['alipay_logon_id'] as string).assertEqual(PAYOUT_LOGON);
      expect(header(put, 'X-Step-Up-Token') as string).assertEqual(STEP_TOKEN);
      expect(keysOf(bodyOf(f.last('/v1/auth/sms-codes'))).indexOf('summary')).assertEqual(-1);
    });

    // 依据：同上，银行卡：summary = {payout_method: bank_card, card_no}，card_no 按将要 PUT 的原样（含空格、连字符，只去首尾空白；客户端不
    // 规范化、不算指纹），不带开户行与收款人姓名，不是「尾号 0009」这类展示文案。
    // 先红：HEAD 无 summary。
    it('s3_3_2_payout_first_save_bank_card_summary_is_card_no_as_put_without_bank_or_payee', 0, async () => {
      const f: WalletFixture = payoutFixture((_r: TransportRequest) => envelope(0, '{"payout_method":"bank_card",'
        + '"masked_account":"尾号 0009","bank_name":"示例银行","masked_payee_name":"**三","change_remaining_this_month":1}'));
      const p: PayoutAccountController = await openPayout(f);
      p.setMethod('bank_card');
      p.setField('card_no', ' ' + PAYOUT_CARD + ' ');
      p.setField('bank_name', ' 示例银行 ');
      p.setField('payee_name', ' 测试三 ');
      expect(p.save()).assertTrue();
      await settle();
      await passStepUp(p);
      const v: TransportRequest = f.last(VERIFY);
      const sum: Record<string, Object> | null = summaryOf(v);
      expect(sum !== null).assertTrue();
      expect(keysOf(sum as Record<string, Object>)).assertEqual('card_no,payout_method');
      expect((sum as Record<string, Object>)['payout_method'] as string).assertEqual('bank_card');
      expect((sum as Record<string, Object>)['card_no'] as string).assertEqual(PAYOUT_CARD);
      expect((v.body ?? '').indexOf('示例银行')).assertEqual(-1);
      expect((v.body ?? '').indexOf('测试三')).assertEqual(-1);
      expect((sum as Record<string, Object>)['card_no'] as string)
        .assertEqual(bodyOf(f.last('PUT /v1/me/payout-account'))['card_no'] as string);
    });

    // 依据：同上，确认上一笔：摘要来自未决记录原体（不是本页表单，也不是脱敏的待确认摘要）。先保存得到结果未知 → 换一个新页面实例（表单为空）
    // 进待确认 →【确认上一笔】得到 10003 → 面板验证体 summary = 原体的支付宝账号；拿到令牌后原键原体续发。
    // 先红：HEAD 无 summary。
    it('s3_3_3_payout_confirm_previous_step_up_summary_from_pending_original_body', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('GET /v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
      f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
      const p: PayoutAccountController = await openPayout(f);
      fillAlipay(p, PAYOUT_LOGON);
      p.save();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.PENDING);
      const firstKey: string | undefined = header(f.last('PUT /v1/me/payout-account'), 'Idempotency-Key');
      f.reply('PUT /v1/me/payout-account', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
        ? envelope(10003, '{}') : payoutSaved(r));
      const p2: PayoutAccountController = new PayoutAccountController(walletDeps(f));
      p2.onShown();
      await settle();
      expect(p2.snapshot.phase).assertEqual(PayoutPhase.PENDING);
      expect(p2.snapshot.form.alipayLogonId).assertEqual('');
      expect(p2.confirm(p2.snapshot.pendingVersion)).assertTrue();
      await settle();
      expect(p2.snapshot.stepUpAction as string).assertEqual(PAYOUT_ACTION);
      await passStepUp(p2);
      const sum: Record<string, Object> | null = summaryOf(f.last(VERIFY));
      expect(sum !== null).assertTrue();
      expect(keysOf(sum as Record<string, Object>)).assertEqual('alipay_logon_id,payout_method');
      expect((sum as Record<string, Object>)['alipay_logon_id'] as string).assertEqual(PAYOUT_LOGON);
      const replay: TransportRequest = f.last('PUT /v1/me/payout-account');
      expect(header(replay, 'Idempotency-Key') as string).assertEqual(firstKey as string);
      expect(header(replay, 'X-Step-Up-Token') as string).assertEqual(STEP_TOKEN);
      expect(bodyOf(replay)['alipay_logon_id'] as string).assertEqual(PAYOUT_LOGON);
    });

    // 依据：D10-1635 ②、D10-1667：withdraw / phone_change / account_deletion 的 step-up 体只有 {action, code}，不带 summary。
    // 先红：绿（防改错）。防实现给四个 action 一律加摘要（假服务对它们带摘要回 20001）。
    it('s3_3_4_withdraw_phone_change_deletion_step_up_body_has_no_summary', 0, async () => {
      const w: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(w);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      await passStepUp(c);
      const wb: Record<string, Object> = bodyOf(w.last(VERIFY));
      expect('withdraw:' + keysOf(wb)).assertEqual('withdraw:action,code');
      expect(wb['action'] as string).assertEqual('withdraw');

      const a: AccountFixture = new AccountFixture();
      await toStep2(a);
      const pv: TransportRequest[] = accountSent(a, VERIFY);
      expect(pv.length).assertEqual(1);
      expect('phone_change:' + keysOf(bodyOf(pv[0]))).assertEqual('phone_change:action,code');

      const b: AccountFixture = new AccountFixture();
      const d: DeleteAccountController = await openDeletion(b);
      await applyWithStepUp(d);
      const dv: TransportRequest[] = accountSent(b, VERIFY);
      expect(dv.length).assertEqual(1);
      expect('account_deletion:' + keysOf(bodyOf(dv[0]))).assertEqual('account_deletion:action,code');
    });

    // ================================================================ 4. 令牌缓存按摘要区分（seg3-brief 4；scope §4 ④）

    // 依据：put / take 带 summary，摘要不同不复用（含 null 对非 null）；同摘要复用。直测 StepUpTokenCache（签名见文件头）。
    // 先红：HEAD 不认 summary，摘要不同照样交出令牌（第一条断言红）。
    it('s3_4_1_token_cache_summary_mismatch_not_reused_same_summary_reused', 0, () => {
      const c: SummaryTokenCache = summaryCache();
      const a: string = '{"alipay_logon_id":"a@example.com","payout_method":"alipay"}';
      const b: string = '{"alipay_logon_id":"b@example.com","payout_method":"alipay"}';
      c.put(PAYOUT_ACTION, 'user-1', 'tok-a', NOW + 60000, 'scope-1', a);
      expect(c.take(PAYOUT_ACTION, 'user-1', NOW, null, b)).assertNull();
      expect(c.take(PAYOUT_ACTION, 'user-1', NOW, null, null)).assertNull();
      expect(c.take(PAYOUT_ACTION, 'user-1', NOW, null, a) as string).assertEqual('tok-a');
      expect(c.take(PAYOUT_ACTION, 'user-1', NOW, 'scope-1', a) as string).assertEqual('tok-a');
      // 不带摘要放入的，带摘要取也不复用
      c.put(PAYOUT_ACTION, 'user-1', 'tok-null', NOW + 60000, 'scope-1', null);
      expect(c.take(PAYOUT_ACTION, 'user-1', NOW, null, a)).assertNull();
    });

    // 依据：withdraw、phone_change、account_deletion 传 null，行为照旧：按账号、action、有效期、binding 复用；on10003 / onSuccess /
    // onSessionChanged 照旧清。
    // 先红：绿（防改错）。
    it('s3_4_2_token_cache_null_summary_behaves_as_before', 0, () => {
      const c: SummaryTokenCache = summaryCache();
      c.put('withdraw', 'user-1', 'tok-w', NOW + 60000, '', null);
      c.put('phone_change', 'user-1', 'tok-p', NOW + 60000, 'scope-1', null);
      c.put('account_deletion', 'user-1', 'tok-d', NOW + 60000, 'scope-1', null);
      expect(c.take('withdraw', 'user-1', NOW, null, null) as string).assertEqual('tok-w');
      expect(c.take('withdraw', 'user-2', NOW, null, null)).assertNull();
      expect(c.take('withdraw', 'user-1', NOW + 60000, null, null)).assertNull();
      expect(c.take('phone_change', 'user-1', NOW, 'scope-1', null) as string).assertEqual('tok-p');
      expect(c.take('phone_change', 'user-1', NOW, 'scope-2', null)).assertNull();
      const real: StepUpTokenCache = c as Object as StepUpTokenCache;
      // 旧调用（不传摘要）照旧
      expect(real.take('account_deletion', 'user-1', NOW, 'scope-1') as string).assertEqual('tok-d');
      real.on10003('withdraw');
      expect(c.take('withdraw', 'user-1', NOW, null, null)).assertNull();
      real.onSuccess('phone_change');
      expect(c.take('phone_change', 'user-1', NOW, 'scope-1', null)).assertNull();
      const gen: number = real.generation;
      real.onSessionChanged();
      expect(real.generation).assertEqual(gen + 1);
      expect(real.size).assertEqual(0);
    });

    // 依据：同上，经生产调用点：改收款首次保存 A → 10003 → 面板（摘要 A）→ 带令牌重放得到 30303（令牌未核销，留在缓存）→ 再保存同一
    // 账号 A：新键、带上缓存的令牌（同摘要复用）→ 改成账号 B 再保存：新键、不带令牌（摘要不同不复用）。
    // 先红：HEAD 的缓存不认摘要，B 的保存带上了 A 的令牌（最后一段断言红）。
    it('s3_4_3_payout_cached_token_reused_only_for_same_summary', 0, async () => {
      const f: WalletFixture = payoutFixture((_r: TransportRequest) =>
      envelope(30303, '{"reason":"payout_account_change_limit"}'));
      const p: PayoutAccountController = await openPayout(f);
      fillAlipay(p, PAYOUT_LOGON);
      p.save();
      await settle();
      await passStepUp(p);
      const puts: TransportRequest[] = walletSent(f, 'PUT /v1/me/payout-account');
      expect(puts.length).assertEqual(2);
      expect(header(puts[1], 'X-Step-Up-Token') as string).assertEqual(STEP_TOKEN);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      // 同一账号再保存：新键，带缓存令牌
      fillAlipay(p, PAYOUT_LOGON);
      expect(p.save()).assertTrue();
      await settle();
      const same: TransportRequest = f.last('PUT /v1/me/payout-account');
      expect(walletSent(f, 'PUT /v1/me/payout-account').length).assertEqual(3);
      expect(header(same, 'Idempotency-Key') !== header(puts[0], 'Idempotency-Key')).assertTrue();
      expect(header(same, 'X-Step-Up-Token') as string).assertEqual(STEP_TOKEN);
      expect(p.snapshot.phase).assertEqual(PayoutPhase.FORM);
      // 换成账号 B：不复用 A 的令牌
      fillAlipay(p, PAYOUT_LOGON_B);
      expect(p.save()).assertTrue();
      await settle();
      const other: TransportRequest = f.last('PUT /v1/me/payout-account');
      expect(walletSent(f, 'PUT /v1/me/payout-account').length).assertEqual(4);
      expect(bodyOf(other)['alipay_logon_id'] as string).assertEqual(PAYOUT_LOGON_B);
      expect(header(other, 'X-Step-Up-Token') === undefined).assertTrue();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.STEP_UP);
    });

    // 依据：评审 S3-2（变异 M7 存活）：【确认上一笔】取缓存令牌也按未决原体的摘要比对——缓存里是同摘要（账号 A）的令牌就带上，
    // 是别的摘要（账号 B）的令牌就不带（得到 10003 再弹面板）。摘要键按实现的 StepUpBusinessSummary.key 格式（键名字典序的 JSON 文本）。
    // 先红：HEAD 不认摘要，两种都带（第二段断言红）；确认路径取令牌时摘要恒传 null（M7）则第一段红。
    it('s3_4_4_payout_confirm_previous_reuses_cached_token_only_for_pending_body_summary', 0, async () => {
      const keyA: string = '{"alipay_logon_id":"' + PAYOUT_LOGON + '","payout_method":"alipay"}';
      const keyB: string = '{"alipay_logon_id":"' + PAYOUT_LOGON_B + '","payout_method":"alipay"}';
      const keys: string[] = [keyA, keyB];
      for (const key of keys) {
        const f: WalletFixture = new WalletFixture();
        f.reply('GET /v1/me/payout-account', (_r: TransportRequest) => envelope(0, '{}'));
        f.reply('PUT /v1/me/payout-account', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
        const p: PayoutAccountController = await openPayout(f);
        fillAlipay(p, PAYOUT_LOGON);
        p.save();
        await settle();
        expect(p.snapshot.phase).assertEqual(PayoutPhase.PENDING);
        const firstKey: string | undefined = header(f.last('PUT /v1/me/payout-account'), 'Idempotency-Key');
        f.reply('PUT /v1/me/payout-account', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
          ? envelope(10003, '{}') : payoutSaved(r));
        const cache: SummaryTokenCache = f.session.tokens as Object as SummaryTokenCache;
        cache.put(PAYOUT_ACTION, 'user-1', STEP_TOKEN, NOW + 300000, '', key);
        expect(p.confirm(p.snapshot.pendingVersion)).assertTrue();
        await settle();
        const puts: TransportRequest[] = walletSent(f, 'PUT /v1/me/payout-account');
        expect(puts.length).assertEqual(2);
        const confirmPut: TransportRequest = puts[1];
        expect(header(confirmPut, 'Idempotency-Key') as string).assertEqual(firstKey as string);
        if (key === keyA) {
          expect('same:' + String(header(confirmPut, 'X-Step-Up-Token'))).assertEqual('same:' + STEP_TOKEN);
          expect(walletSent(f, SMS).length).assertEqual(0);
        } else {
          expect('other:' + String(header(confirmPut, 'X-Step-Up-Token'))).assertEqual('other:undefined');
          expect(p.snapshot.stepUpAction as string).assertEqual(PAYOUT_ACTION);
        }
      }
    });

    // ================================================================ 5. 提现（FU-HM-WITHDRAW-NO-STEPUP-ALIGN，D10-1665 / 1667，Q5）

    // 依据：提现不主动弹二次验证（首包前零发码、零验证）；收到 10003 仍弹面板；拿到令牌沿用原幂等键、原体重放；验证体不带摘要（见 s3_3_4）。
    // 先红：绿（防改错）。
    it('s3_5_1_withdraw_not_proactive_10003_opens_panel_replays_original_key', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      const first: TransportRequest[] = walletSent(f, 'POST /v1/withdrawals');
      expect(first.length).assertEqual(1);
      expect(walletSent(f, SMS).length).assertEqual(0);
      expect(walletSent(f, VERIFY).length).assertEqual(0);
      expect(header(first[0], 'X-Step-Up-Token') === undefined).assertTrue();
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.STEP_UP);
      await passStepUp(c);
      const all: TransportRequest[] = walletSent(f, 'POST /v1/withdrawals');
      expect(all.length).assertEqual(2);
      expect(header(all[1], 'Idempotency-Key') as string).assertEqual(header(all[0], 'Idempotency-Key') as string);
      expect(header(all[1], 'X-Step-Up-Token') as string).assertEqual(STEP_TOKEN);
      expect(all[1].body as string).assertEqual(all[0].body as string);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.DONE);
    });

    // 依据：withdraw 令牌按同 action 复用（不带摘要）：二次验证后重放得到 30303（令牌未核销）→ 用户再次提交（新键）带上同一令牌，不再弹面板。
    // 先红：绿（防改错）。防实现给 withdraw 也算摘要，或缓存改成「带摘要才复用」。
    it('s3_5_2_withdraw_token_reused_for_same_action_with_new_key', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.reply('POST /v1/withdrawals', (r: TransportRequest) => header(r, 'X-Step-Up-Token') === undefined
        ? envelope(10003, '{}') : envelope(30303, '{"reason":"daily_count"}'));
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      await passStepUp(c);
      expect(walletSent(f, 'POST /v1/withdrawals').length).assertEqual(2);
      expect(c.snapshot.phase).assertEqual(WithdrawPhase.EDITING);
      c.fillQuick(500, c.snapshot.version);
      await settle();
      expect(c.submit()).assertTrue();
      await settle();
      const all: TransportRequest[] = walletSent(f, 'POST /v1/withdrawals');
      expect(all.length).assertEqual(3);
      expect(header(all[2], 'Idempotency-Key') !== header(all[0], 'Idempotency-Key')).assertTrue();
      expect(header(all[2], 'X-Step-Up-Token') as string).assertEqual(STEP_TOKEN);
      expect(walletSent(f, SMS).length).assertEqual(1);
      expect(walletSent(f, VERIFY).length).assertEqual(1);
    });

    // 依据：换账号后 withdraw 令牌不复用（按账号隔离照旧），新账号提交不带旧令牌。
    // 先红：绿（防改错）。
    it('s3_5_3_withdraw_token_not_reused_across_accounts', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.tokens.put('withdraw', 'user-1', STEP_TOKEN, NOW + 300000);
      f.rig.tokens.save(new SessionTokenSet('access-user-2', 'refresh-user-2', 'full', 'user-2'));
      f.rig.client.onSessionChanged();
      const c: WithdrawController = await openWithdraw(f);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      const all: TransportRequest[] = walletSent(f, 'POST /v1/withdrawals');
      expect(all.length).assertEqual(1);
      expect(header(all[0], 'X-Step-Up-Token') === undefined).assertTrue();
    });

    // ================================================================ r2：评审 r2 新 S3-a / S3-b / S3-c（只补测试，产品不改）

    // 依据：D10-2141 ⑥、评审 r2 S3-a 第一道防线：改收款没有摘要（服务端本应 20001 拒签）时验证成功也不写缓存，不留 null 键的改收款令牌；
    // 本次令牌仍交给发起方（onToken）。经 StepUpController 驱动（summary 参数缺省为 null）。对照：withdraw 照旧以 null 键写入。
    // 变异「去掉不写缓存的条件」：has(payout_account_change) 为 true，本条红。
    it('s3_r2_1_payout_step_up_without_summary_does_not_write_cache', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const s: StepUpController = new StepUpController(walletDeps(f), PAYOUT_ACTION, 'user-1');
      let handed: string = '';
      s.onToken = (t: string): void => {
        handed = t;
      };
      expect(await sendOnly(s)).assertTrue();
      s.setCode('123456');
      expect(s.verify()).assertTrue();
      await settle();
      expect(handed).assertEqual(STEP_TOKEN);
      expect(keysOf(bodyOf(f.last(VERIFY)))).assertEqual('action,code');
      expect('payout-cached:' + f.session.tokens.has(PAYOUT_ACTION)).assertEqual('payout-cached:false');
      // 对照：withdraw 不带摘要，照旧写入、照旧可取
      const w: StepUpController = new StepUpController(walletDeps(f), 'withdraw', 'user-1');
      expect(await sendOnly(w)).assertTrue();
      w.setCode('123456');
      w.verify();
      await settle();
      expect(f.session.tokens.take('withdraw', 'user-1', NOW) as string).assertEqual(STEP_TOKEN);
    });

    // 依据：同上，第二道防线：改收款取缓存令牌时摘要键为 null（原体解析不出摘要）一律不取，不让 null 键匹配到缓存里的 null 键改收款令牌。
    // 经生产 SensitiveFlow（收款页的 flow.submit）驱动：缓存预置 null 键的改收款令牌，提交一份解析不出摘要的原体 → PUT 不带令牌。
    // 对照：同一份 null 键预置下，提现提交照旧带上 withdraw 令牌。
    // 变异「去掉 cachedToken 里 null 键不取的条件」：PUT 带上 fixture-step-token，本条红。
    it('s3_r2_2_payout_take_with_null_summary_key_never_reuses_null_key_token', 0, async () => {
      const f: WalletFixture = payoutFixture(payoutSaved);
      const p: PayoutAccountController = await openPayout(f);
      f.session.tokens.put(PAYOUT_ACTION, 'user-1', STEP_TOKEN, NOW + 300000);
      await p.flow.submit('{"payout_method":"wechat","payee_name":"测试三"}', '{}');
      const puts: TransportRequest[] = walletSent(f, 'PUT /v1/me/payout-account');
      expect(puts.length).assertEqual(1);
      expect('payout-null-key:' + String(header(puts[0], 'X-Step-Up-Token'))).assertEqual('payout-null-key:undefined');

      const g: WalletFixture = new WalletFixture();
      g.session.tokens.put('withdraw', 'user-1', STEP_TOKEN, NOW + 300000);
      const c: WithdrawController = await openWithdraw(g);
      c.fillQuick(1000, c.snapshot.version);
      await settle();
      c.submit();
      await settle();
      const posts: TransportRequest[] = walletSent(g, 'POST /v1/withdrawals');
      expect(posts.length).assertEqual(1);
      expect(header(posts[0], 'X-Step-Up-Token') as string).assertEqual(STEP_TOKEN);
    });

    // 依据：评审 S3-3 / r2 S3-b：10402 重新注册后的重放沿用调用点的「身份未知也照发」声明（03 §4.2、D10-1931 ②）。身份未知时声明的登录发码
    // 首发得到 10402 → 重新注册成功 → 不带 Authorization 重放 1 次、成功。
    // 变异「sameKey 不复制 sendsWhenIdentityUnknown」：重放被本地拒（session_unreadable），只写出 1 次，本条红。
    it('s3_r2_3_10402_replay_keeps_identity_unknown_declaration', 0, async () => {
      const rig: Rig = new Rig();
      rig.tokens.unreadable = true;
      rig.registrar.result = (): Promise<boolean> => Promise.resolve(true);
      let n: number = 0;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        n++;
        return Promise.resolve(n === 1 ? envelope(10402, '{}') : envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      };
      const request: ApiRequest = new ApiRequest('sendSmsCode', {}, '', '{"phone":"13800138000","purpose":"login"}');
      request.sendsWhenIdentityUnknown = true;
      const result: ApiResult = await rig.client.request(request);
      expect(rig.registrar.calls).assertEqual(1);
      expect('writes:' + rig.server.received.length).assertEqual('writes:2');
      expect(result.outcome).assertEqual(ApiOutcome.SUCCESS);
      for (const r of rig.server.received) {
        expect(header(r, NetworkHeaders.AUTHORIZATION) === undefined).assertTrue();
      }
    });

    // 依据：同上，sameKey（刷新 10001、重新注册 10402 两条重放都经它）必须把 requiresSession 与 sendsWhenIdentityUnknown 原样复制到重放请求。
    // requiresSession 在重放路径上没有可观察的外部差异（首发要求有 access；重放前 ownershipLost 先拦会话变化），所以这条直接调私有静态方法
    // 钉住复制本身（白盒）。变异「不复制 requiresSession」或「不复制 sendsWhenIdentityUnknown」：对应断言红。
    // r4（ArkTS arkts-no-classes-as-obj）：不把类名当对象用——经一个真实 ApiClient 实例的 constructor 取到同一个类，再取私有静态方法。
    it('s3_r2_4_same_key_copy_keeps_session_switches', 0, () => {
      const client: ApiClient = new Rig().client;
      const owner: Object = Reflect.get(client, 'constructor') as Object;
      const sameKey: (request: ApiRequest, key: string | null) => ApiRequest =
        Reflect.get(owner, 'sameKey') as (request: ApiRequest, key: string | null) => ApiRequest;
      expect(typeof sameKey).assertEqual('function');
      const a: ApiRequest = new ApiRequest('sendSmsCode', {}, '', '{"purpose":"step_up","action":"withdraw"}');
      a.requiresSession = true;
      const ca: ApiRequest = sameKey(a, 'k-1');
      expect('requiresSession:' + ca.requiresSession).assertEqual('requiresSession:true');
      expect('declared:' + ca.sendsWhenIdentityUnknown).assertEqual('declared:false');
      expect(ca.idempotencyKey as string).assertEqual('k-1');
      const b: ApiRequest = new ApiRequest('sendSmsCode', {}, '', '{"phone":"13800138000","purpose":"login"}');
      b.sendsWhenIdentityUnknown = true;
      const cb: ApiRequest = sameKey(b, null);
      expect('declared:' + cb.sendsWhenIdentityUnknown).assertEqual('declared:true');
      expect('requiresSession:' + cb.requiresSession).assertEqual('requiresSession:false');
    });

    // 依据：D10-1659 S2-4、D10-2141、评审 r2 S3-c：phone_bound=false 时改收款保存得到 10003 → 进 STEP_UP，页面给 BR-ID-08 原句
    // （step_up.no_available_method）的 banner 和现有「去绑定手机号」手动引导（guideRoute = BindPhone，withdraw.guide.bind_phone）；
    // 面板不发码（phoneUnbound）。不自动跳转（Router 栈不变）。换号页同一口径：phoneUnbound + guideRoute = BindPhone、guideCode 10005。
    // 变异「去掉 PayoutAccountController 的 phone_bound=false 引导段」：banner / guideRoute 断言红。
    it('s3_r2_5_phone_bound_false_payout_and_phone_change_show_bind_phone_guide', 0, async () => {
      const f: WalletFixture = payoutFixture(payoutSaved);
      const p: PayoutAccountController = await openPayout(f, false);
      fillAlipay(p, PAYOUT_LOGON);
      const stackBefore: string = JSON.stringify(f.stack.names);
      p.save();
      await settle();
      expect(p.snapshot.phase).assertEqual(PayoutPhase.STEP_UP);
      expect('banner:' + (p.snapshot.banner === null ? 'null' : (p.snapshot.banner as WalletMessage).textKey))
        .assertEqual('banner:step_up.no_available_method');
      expect('guide:' + String(p.snapshot.guideRoute)).assertEqual('guide:' + RoutePolicy.BIND_PHONE);
      expect(String(p.snapshot.guideTextKey)).assertEqual('withdraw.guide.bind_phone');
      const s: StepUpController | null = p.createStepUp();
      expect(s !== null).assertTrue();
      const panel: StepUpController = s as StepUpController;
      panel.send();
      await settle();
      expect(panel.snapshot.phoneUnbound).assertTrue();
      expect((panel.snapshot.error as WalletMessage).textKey).assertEqual('step_up.no_available_method');
      expect(walletSent(f, SMS).length).assertEqual(0);
      expect(JSON.stringify(f.stack.names)).assertEqual(stackBefore);
      panel.close();

      const a: AccountFixture = new AccountFixture();
      a.session.sync();
      const d: AccountDeps = a.deps();
      withPhoneBound(d, false);
      const pc: PhoneChangeController = new PhoneChangeController(d);
      pc.onShown();
      expect(pc.snapshot.phoneUnbound).assertTrue();
      expect('guide:' + String(pc.snapshot.guideRoute)).assertEqual('guide:' + RoutePolicy.BIND_PHONE);
      expect(pc.snapshot.guideCode as number).assertEqual(10005);
      expect(a.opened.length).assertEqual(0);
    });

    // 依据：编排 D10-2143（接受 sameKey 复制开关的附带变化，同时钉反面）、03 §4.2、D10-1931 ②、D10-1940（三档每次发送前重新判定）：
    // **没有声明**的 optional 请求（这里用落在五类请求体条件里的登录发码，但不打开 sendsWhenIdentityUnknown）——确认游客时匿名首发得到
    // 10402 → 重新注册期间会话变成「身份未知」（读不出）→ 重放前 ownershipLost 不拦（首发和此刻账号都为空）→ 重放仍按身份未知本地拒
    // （session_unreadable）、零写出。对照 s3_r2_3：打开声明的同一请求照发。
    // 变异「sameKey 把 sendsWhenIdentityUnknown 强置 true」或「prepare 跳过身份未知一档」：重放写出第 2 次，本条红。
    it('s3_r3_1_undeclared_optional_10402_replay_under_identity_unknown_rejected_zero_writes', 0, async () => {
      const rig: Rig = new Rig(null);
      rig.registrar.result = (): Promise<boolean> => {
        rig.tokens.unreadable = true;
        return Promise.resolve(true);
      };
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(rig.server.received.length === 1
        ? envelope(10402, '{}') : envelope(0, '{"resend_after_sec":60,"expires_in_sec":300}'));
      const request: ApiRequest = new ApiRequest('sendSmsCode', {}, '', '{"phone":"13800138000","purpose":"login"}');
      expect(request.sendsWhenIdentityUnknown).assertFalse();
      const result: ApiResult = await rig.client.request(request);
      expect(rig.registrar.calls).assertEqual(1);
      expect('writes:' + rig.server.received.length).assertEqual('writes:1');
      expect(header(rig.server.received[0], NetworkHeaders.AUTHORIZATION) === undefined).assertTrue();
      expect(result.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
      expect(String(result.localRejectReason)).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
    });
  });
}
