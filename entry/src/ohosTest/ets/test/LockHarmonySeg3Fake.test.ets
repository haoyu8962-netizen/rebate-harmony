// LOCK-harmony 段 3 测试写手：staging 本机假服务（DebugFakeServer / DebugFakeWallet / DebugFakeMe / DebugFakeAccount）的二次验证规则，
// 以及 Release BuildVariant 的发码槽位占位（seg3-brief「段 3 要做的」1、6；D10-1635、D10-1658 ①、D10-1667、D10-2108 Q5）。
// 不驱动界面：直接经 DebugFakeServer.fakeSend（传输入口闸门放行后的本机回答一侧，生产里由 DebugMockTransport 调用）送 TransportRequest，
// 断言统一外壳里的 code / data，不假设假服务内部方法的签名（Authorization 怎么接给钱包假服务由实现定）。
// 假服务的状态是静态的：每条用例先按缺省场景 reset。
// 放在这里的原因：假服务只在 entry 的 staging 源码里，core 的单测引用不到；entry 没有本机单测目录，现有的假服务用例都在本目录（设备套件）。
// 本文件不驱动 UI，也能用临时 node 跑法在本机跑（见 NATIVE/LOCK-harmony/seg3-tests-handback.md「跑法」）。
// 每条用例上方写「先红」：先红 = 当前 HEAD（60575f3，未实现）上这条怎样；标「防改错」的是现状已对、钉住不许改坏的。
import { describe, it, expect } from '@ohos/hypium';
import { AppConfig, AppEnvironment, EnvironmentRecord, NetworkHeaders, TransportRequest, TransportResponse } from 'core';
import { DebugFakeServer } from '../../../staging/ets/variant/DebugFakeServer';
import { DebugFakeWallet } from '../../../staging/ets/variant/DebugFakeWallet';
import { DebugFakeMe } from '../../../staging/ets/variant/DebugFakeMe';
import { DebugFakeAccount } from '../../../staging/ets/variant/DebugFakeAccount';
import { BuildVariant as ReleaseVariant } from '../../../release/ets/variant/BuildVariant';
import { BuildVariant as StagingVariant } from '../../../staging/ets/variant/BuildVariant';
import { DEBUG_STEP_UP_PHONE } from '../../../staging/ets/variant/DebugFakeWallet';
import { common, Want } from '@kit.AbilityKit';
import { RouteAvailability } from 'core';
import { RouteSpec } from 'generated';

const BASE: string = 'https://api.fake.invalid';
const BEARER: string = 'Bearer stub-access-1';
const SMS_PATH: string = '/v1/auth/sms-codes';
const STEP_UP_PATH: string = '/v1/auth/step-up';
const PAYOUT_PATH: string = '/v1/me/payout-account';

class Reply {
  readonly code: number;
  readonly data: Record<string, Object>;

  constructor(code: number, data: Record<string, Object>) {
    this.code = code;
    this.data = data;
  }

  get fields(): string {
    const f: Object | undefined = this.data['fields'];
    return Array.isArray(f) ? (f as string[]).join(',') : '';
  }
}

/** 只在内存里的环境记录（s3f_15 启动 staging 环境用；不落盘）。 */
class MemoryEnvironmentRecord implements EnvironmentRecord {
  private readonly values: Map<string, string> = new Map<string, string>();

  async get(key: string): Promise<string | undefined> {
    return this.values.get(key);
  }

  async put(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }

  async remove(key: string): Promise<void> {
    this.values.delete(key);
  }
}

function resetFakes(): void {
  DebugFakeWallet.reset('');
  DebugFakeMe.reset('');
  DebugFakeAccount.reset('');
}

async function call(server: DebugFakeServer, method: string, path: string, body: string | null,
  auth: string | null = BEARER, stepUpToken: string | null = null, idempotencyKey: string | null = null): Promise<Reply> {
  const headers: Record<string, string> = {};
  if (idempotencyKey !== null) {
    headers[NetworkHeaders.IDEMPOTENCY_KEY] = idempotencyKey;
  }
  if (auth !== null) {
    headers[NetworkHeaders.AUTHORIZATION] = auth;
  }
  if (stepUpToken !== null) {
    headers[NetworkHeaders.STEP_UP_TOKEN] = stepUpToken;
  }
  const res: TransportResponse = await server.fakeSend(new TransportRequest(method, BASE + path, headers, body, 10000));
  const env: Record<string, Object> = JSON.parse(res.body) as Record<string, Object>;
  const data: Object | undefined = env['data'];
  return new Reply(env['code'] as number, data !== undefined && data !== null && typeof data === 'object'
    ? data as Record<string, Object> : {});
}

function smsBody(action: string): string {
  return '{"purpose":"step_up","action":"' + action + '"}';
}

function verifyBody(action: string, summary: string | null): string {
  return '{"action":"' + action + '","code":"123456"' + (summary === null ? '' : ',"summary":' + summary) + '}';
}

const ALIPAY_A: string = '{"payout_method":"alipay","alipay_logon_id":"zhangsan@example.com"}';
const PUT_A: string = '{"payout_method":"alipay","alipay_logon_id":"zhangsan@example.com","payee_name":"测试三"}';
const PUT_B: string = '{"payout_method":"alipay","alipay_logon_id":"lisi@example.com","payee_name":"测试三"}';
const CARD_SUMMARY: string = '{"payout_method":"bank_card","card_no":"6222 0000-0000 0009"}';
const PUT_CARD: string = '{"payout_method":"bank_card","card_no":"6222 0000-0000 0009","bank_name":"示例银行","payee_name":"测试三"}';

/** 验证成功，交出令牌。 */
async function tokenFor(server: DebugFakeServer, action: string, summary: string | null): Promise<string> {
  const r: Reply = await call(server, 'POST', STEP_UP_PATH, verifyBody(action, summary));
  expect(action + ':' + r.code).assertEqual(action + ':0');
  return r.data['step_up_token'] as string;
}

export default function lockHarmonySeg3FakeTest() {
  describe('LockHarmonySeg3Fake', () => {
    // ================================================================ 发码（seg3-brief 6 第 1 条）

    // 依据：D10-1635 ①、D10-1658 ①：step_up 发码体带 phone → 20001 fields=[phone]。
    // 先红：HEAD 对任何 step_up 发码回成功（DebugFakeWallet.ets:119-121）。
    it('s3f_1_step_up_sms_with_phone_20001_fields_phone', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const r: Reply = await call(server, 'POST', SMS_PATH,
        '{"phone":"13800005678","purpose":"step_up","action":"withdraw"}');
      expect(r.code).assertEqual(20001);
      expect(r.fields).assertEqual('phone');
    });

    // 依据：step_up 发码必须有会话（03 §4.2 第四条、D10-1703 末句）：不带 Authorization → 10001；DebugFakeServer 要把 Authorization 接给钱包
    // 假服务。
    // 先红：HEAD 回 0。
    it('s3f_2_step_up_sms_without_authorization_10001', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const r: Reply = await call(server, 'POST', SMS_PATH, smsBody('payout_account_change'), null);
      expect(r.code).assertEqual(10001);
    });

    // 依据：phone_bound=false（账号假服务 unbound 场景，getMe 给 phone_bound=false）→ 发码 20001 fields=[code]。
    // 先红：HEAD 回 0。
    it('s3f_3_step_up_sms_phone_unbound_20001_fields_code', 0, async () => {
      resetFakes();
      DebugFakeAccount.reset('unbound');
      const server: DebugFakeServer = new DebugFakeServer();
      const r: Reply = await call(server, 'POST', SMS_PATH, smsBody('phone_change'));
      expect(r.code).assertEqual(20001);
      expect(r.fields).assertEqual('code');
    });

    // 依据：有会话、已绑手机、不带 phone 的 step_up 发码照常成功（resend_after_sec 60）；四个 action 都一样。
    // 先红：绿（防改错）。防新规则把正常发码也拦掉。
    it('s3f_4_step_up_sms_member_bound_without_phone_succeeds', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const actions: string[] = ['withdraw', 'payout_account_change', 'phone_change', 'account_deletion'];
      for (const a of actions) {
        const r: Reply = await call(server, 'POST', SMS_PATH, smsBody(a));
        expect(a + ':' + r.code).assertEqual(a + ':0');
        expect(r.data['resend_after_sec'] as number).assertEqual(60);
      }
    });

    // ================================================================ 验证（seg3-brief 6 第 2 条）

    // 依据：D10-1635 ②：payout_account_change 缺摘要或形状不对 → 20001 fields=[summary]（形状：Alipay {payout_method: alipay,
    // alipay_logon_id}、BankCard {payout_method: bank_card, card_no}，都是封闭对象；不带收款人姓名）。
    // 先红：HEAD 只看验证码，回 0。
    it('s3f_5_verify_payout_missing_or_malformed_summary_20001_fields_summary', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const bad: (string | null)[] = [
        null,
        '{}',
        '{"payout_method":"alipay"}',
        '{"payout_method":"alipay","card_no":"6222000000000009"}',
        '{"payout_method":"bank_card","alipay_logon_id":"zhangsan@example.com"}',
        '{"payout_method":"alipay","alipay_logon_id":"zhangsan@example.com","payee_name":"测试三"}',
        '{"payout_method":"wechat","alipay_logon_id":"zhangsan@example.com"}',
        '"zhangsan@example.com"'
      ];
      for (const s of bad) {
        const r: Reply = await call(server, 'POST', STEP_UP_PATH, verifyBody('payout_account_change', s));
        expect(String(s) + ':' + r.code + ':' + r.fields).assertEqual(String(s) + ':20001:summary');
      }
    });

    // 依据：同上，合法摘要（支付宝、银行卡）验证成功、签发令牌。
    // 先红：绿（防改错）。
    it('s3f_6_verify_payout_with_valid_summary_issues_token', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      expect((await tokenFor(server, 'payout_account_change', ALIPAY_A)).length > 0).assertTrue();
      expect((await tokenFor(server, 'payout_account_change', CARD_SUMMARY)).length > 0).assertTrue();
    });

    // 依据：D10-1667：withdraw / phone_change / account_deletion 带摘要 → 20001；不带照常成功。
    // 先红：带摘要那半红（HEAD 回 0）；不带的半段是防改错。
    it('s3f_7_verify_other_actions_with_summary_20001_without_ok', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const actions: string[] = ['withdraw', 'phone_change', 'account_deletion'];
      for (const a of actions) {
        const r: Reply = await call(server, 'POST', STEP_UP_PATH, verifyBody(a, ALIPAY_A));
        expect(a + ':' + r.code).assertEqual(a + ':20001');
        expect((await tokenFor(server, a, null)).length > 0).assertTrue();
      }
    });

    // ================================================================ 保存收款（seg3-brief 6 第 3 条）

    // 依据：签发令牌记下 claim；保存时请求体与 claim 比对，不符 → 10003、不核销（同一令牌换回相符的请求体仍能用）。
    // 先红：HEAD 不比对，B 的保存带 A 的令牌回 0（第一段断言红）。
    it('s3f_8_save_payout_body_must_match_claim_mismatch_10003_not_consumed', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const tok: string = await tokenFor(server, 'payout_account_change', ALIPAY_A);
      const mismatch: Reply = await call(server, 'PUT', PAYOUT_PATH, PUT_B, BEARER, tok);
      expect(mismatch.code).assertEqual(10003);
      const ok: Reply = await call(server, 'PUT', PAYOUT_PATH, PUT_A, BEARER, tok);
      expect(ok.code).assertEqual(0);
    });

    // 依据：同上，银行卡按将要 PUT 的原样比对通过；别的 action 的令牌（withdraw）不能用来保存收款（claim 不符）。
    // 先红：后半段红（HEAD 不看令牌归属，回 0）。
    it('s3f_9_save_payout_bank_card_matches_and_withdraw_token_rejected', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const card: string = await tokenFor(server, 'payout_account_change', CARD_SUMMARY);
      expect((await call(server, 'PUT', PAYOUT_PATH, PUT_CARD, BEARER, card)).code).assertEqual(0);
      const w: string = await tokenFor(server, 'withdraw', null);
      expect((await call(server, 'PUT', PAYOUT_PATH, PUT_A, BEARER, w)).code).assertEqual(10003);
    });

    // 依据：保存不带令牌照旧 10003（DebugFakeWallet.ets:300-302）。
    // 先红：绿（防改错）。
    it('s3f_10_save_payout_without_token_10003', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      expect((await call(server, 'PUT', PAYOUT_PATH, PUT_A)).code).assertEqual(10003);
    });

    // ================================================================ 提现（seg3-brief 6 第 4 条，D10-2108 Q5）

    // 依据：Q5 / D10-1667 过渡期：提现不带令牌 → 10003；带 withdraw 令牌（不带摘要签发）→ 成功。
    // 先红：绿（防改错）。防假服务把提现改成「不要令牌」或要求摘要。
    it('s3f_11_withdraw_without_token_10003_with_withdraw_token_ok', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      expect((await call(server, 'POST', '/v1/withdrawals', '{"amount_fen":1000}')).code).assertEqual(10003);
      const tok: string = await tokenFor(server, 'withdraw', null);
      expect((await call(server, 'POST', '/v1/withdrawals', '{"amount_fen":1000}', BEARER, tok)).code).assertEqual(0);
    });

    // ================================================================ Me（seg3-brief 6 第 5 条）

    // 依据：getMe 带 masked_phone：已绑 138****5678；未绑（账号假服务 unbound）为 null。
    // 先红：HEAD 两处都没有 masked_phone 字段（undefined）。
    it('s3f_12_get_me_masked_phone_bound_and_unbound', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const bound: Reply = await call(server, 'GET', '/v1/me', null);
      expect(bound.data['phone_bound'] as boolean).assertTrue();
      expect(bound.data['masked_phone'] as string).assertEqual('138****5678');
      DebugFakeAccount.reset('unbound');
      const unbound: Reply = await call(server, 'GET', '/v1/me', null);
      expect(unbound.data['phone_bound'] as boolean).assertFalse();
      expect(Object.keys(unbound.data).indexOf('masked_phone') >= 0).assertTrue();
      expect(unbound.data['masked_phone'] === null).assertTrue();
    });

    // 依据：评审 S3-2（变异 F3 存活）、brief 6-3：保存成功即核销令牌——同一令牌换一个新幂等键再保存同一原体 → 10003。
    // 先红：HEAD 不看令牌，第二次照样回 0。
    it('s3f_14_save_payout_success_consumes_token_new_key_same_token_10003', 0, async () => {
      resetFakes();
      const server: DebugFakeServer = new DebugFakeServer();
      const tok: string = await tokenFor(server, 'payout_account_change', ALIPAY_A);
      const first: Reply = await call(server, 'PUT', PAYOUT_PATH, PUT_A, BEARER, tok, 'idem-s3f14-1');
      expect(first.code).assertEqual(0);
      const again: Reply = await call(server, 'PUT', PAYOUT_PATH, PUT_A, BEARER, tok, 'idem-s3f14-2');
      expect(again.code).assertEqual(10003);
    });

    // ================================================================ Release 槽位占位（seg3-brief 1 第 3 条，D10-1658 ①）

    // 依据：Release 有账号时 stepUpPhone 给不含数字的槽位占位（安卓 "bound"），不再恒为 null（否则 Release 发不出码）。
    // 先红：HEAD 恒为 null（release BuildVariant.ets:97-100）。
    it('s3f_13_release_step_up_slot_is_digitless_placeholder_when_account_present', 0, () => {
      const slot: string | null = ReleaseVariant.stepUpPhone('user-1');
      expect(slot !== null && slot.length > 0).assertTrue();
      expect(/[0-9]/.test(slot as string)).assertFalse();
    });

    // ================================================================ staging 槽位（D10-2141 ⑤，评审 S2-1）

    // 依据：评审 S2-1、D10-1658 ①：staging 直连真后端（假服务没开）时，有账号给不含数字的槽位占位（同 Release 'bound'），无账号为 null；
    // 假服务打开（且当前环境允许调试假数据）时给假服务的测试号。没有环境时本条先启动一个 staging 环境（内存记录，不落盘）。
    // 先红：HEAD 假服务没开时恒为 null（staging BuildVariant.ets:244-247）。
    it('s3f_15_staging_step_up_slot_bound_when_fake_off_test_phone_when_fake_on', 0, async () => {
      // 评审 r2 S3-d：记下进入前的假服务开关，finally 里恢复（开关私有，只能经 setEnabled 的返回值得知：由关变开返回 true）。
      const wasOn: boolean = !DebugFakeServer.setEnabled(true);
      DebugFakeServer.setEnabled(false);
      try {
        const off: string | null = StagingVariant.stepUpPhone('user-1');
        expect('off:' + String(off)).assertEqual('off:bound');
        expect(StagingVariant.stepUpPhone('')).assertNull();
        if (AppConfig.environment() === undefined) {
          await AppConfig.start(AppEnvironment.STAGING, new MemoryEnvironmentRecord());
        }
        DebugFakeServer.setEnabled(true);
        expect(DebugFakeServer.mockGate()).assertTrue();
        expect(StagingVariant.stepUpPhone('user-1') as string).assertEqual(DEBUG_STEP_UP_PHONE);
      } finally {
        DebugFakeServer.setEnabled(wasOn);
      }
    });

    // ================================================================ 路由「强制不可用」覆盖（C3 修，D10-2181 方案 A 第 1、2 条）

    // 依据：D10-2181 ①：staging 加启动参数 couli_debug_route_unavailable（逗号分隔、去空白、空串清空），与 couli_debug_route_available
    // 同一道闸（DebugMockGate.allowedNow）；② 同一路由两边都给了以「不可用」为准；① release 变体没有这个入口，给了参数也照路由表。
    // 驱动：staging 经实现新加的 BuildVariant.applyRouteUnavailable(value: Object | undefined)（applyLaunchOptions 把
    // want.parameters?.['couli_debug_route_unavailable'] 交给它）；「强制可用」名单是既有私有静态 availableOverride，经类对象 Reflect 写入
    // （arkts-no-classes-as-obj：经实例的 constructor 取类，同 LockHarmonySeg3 s3_r2_4），finally 里还原。可用性一律用 RouteAvailability.available 判。
    // 第 3 步（只给强制可用 → since 0.0.0）同时证明 Reflect 写进了闸门读的那个字段、空串清掉了不可用名单，第 4 步的「不可用为准」才有意义。
    // 先红：c3fix 基 dfc8f98 上 staging 没有 applyRouteUnavailable → TypeError（release 半段与第 1 步是防改错，现状已对）。
    it('s3f_16_route_unavailable_override_wins_over_available_in_staging_release_ignores_it', 0, async () => {
      // release：给了参数也照路由表（DeleteAccount since 1.0.0 → 可用），也没有 applyRouteUnavailable 这个入口。
      const want: Want = { parameters: { 'couli_debug_route_unavailable': 'DeleteAccount' } as Record<string, Object> };
      ReleaseVariant.applyLaunchOptions(new Object() as common.ApplicationContext, want);
      expect('release:' + RouteAvailability.available(ReleaseVariant.routeSpec('DeleteAccount'), '1.0.0'))
        .assertEqual('release:true');
      const releaseOwner: Object = Reflect.get(new ReleaseVariant(), 'constructor') as Object;
      expect('release-entry:' + Reflect.has(releaseOwner, 'applyRouteUnavailable')).assertEqual('release-entry:false');
      // staging：先有环境（闸门要求当前环境允许调试假数据）。
      if (AppConfig.environment() === undefined) {
        await AppConfig.start(AppEnvironment.STAGING, new MemoryEnvironmentRecord());
      }
      const owner: Object = Reflect.get(new StagingVariant(), 'constructor') as Object;
      const savedAvailable: Object | undefined = Reflect.get(owner, 'availableOverride') as Object | undefined;
      try {
        // 1 两边都没有 → 按路由表。
        Reflect.set(owner, 'availableOverride', new Array<string>());
        StagingVariant.applyRouteUnavailable('');
        expect('none:' + RouteAvailability.available(StagingVariant.routeSpec('DeleteAccount'), '1.0.0')).assertEqual('none:true');
        // 2 只在强制不可用里（逗号分隔、带空白）→ 不可用。
        StagingVariant.applyRouteUnavailable(' Wallet , DeleteAccount ');
        expect('unavailable:' + RouteAvailability.available(StagingVariant.routeSpec('DeleteAccount'), '1.0.0'))
          .assertEqual('unavailable:false');
        // 3 空串清掉不可用名单，只在强制可用里 → since 换成 0.0.0（既有行为）。
        StagingVariant.applyRouteUnavailable('');
        Reflect.set(owner, 'availableOverride', ['DeleteAccount']);
        const forced: RouteSpec | undefined = StagingVariant.routeSpec('DeleteAccount');
        expect('available:' + (forced === undefined ? 'undefined' : String(forced.sinceHarmony))).assertEqual('available:0.0.0');
        // 4 两边都有 → 以不可用为准。
        StagingVariant.applyRouteUnavailable('DeleteAccount');
        expect('both:' + RouteAvailability.available(StagingVariant.routeSpec('DeleteAccount'), '1.0.0')).assertEqual('both:false');
      } finally {
        Reflect.set(owner, 'availableOverride', savedAvailable);
        if (typeof Reflect.get(owner, 'applyRouteUnavailable') === 'function') {
          StagingVariant.applyRouteUnavailable('');
        }
      }
    });

    // ================================================================ 换手机号入口（FU-HM-PHONECHANGE-B120B，brief-harmony §1-5，D10-2203 ⑤）

    // 依据：brief §1-5：两个 BuildVariant 各加 phoneChangeAvailable(): boolean。Release 恒 false、不认两份覆盖名单；staging = 假服务闸门放行
    // 或 couli_debug_route_available 含 PhoneChange 时 true，couli_debug_route_unavailable 含 PhoneChange 时以不可用为准，staging 直连真服务
    // 又没给覆盖时 false。复用 s3f_16 的两份名单（availableOverride 经类对象 Reflect 写入，unavailable 经既有 applyRouteUnavailable），
    // 新方法也经类对象 Reflect 取（arkts-no-classes-as-obj，同 s3f_16），HEAD 能编译。新方法须是不依赖 this 的静态方法（这里取出后直接调）。
    // finally 里还原两份名单与假服务开关。
    // 先红：HEAD 两个变体都没有 phoneChangeAvailable → 'release-fn:undefined'。
    it('pcb_9_phone_change_available_release_false_staging_fake_gate_or_override_unavailable_wins', 0, async () => {
      const releaseOwner: Object = Reflect.get(new ReleaseVariant(), 'constructor') as Object;
      const releaseAvailable: () => boolean = Reflect.get(releaseOwner, 'phoneChangeAvailable') as () => boolean;
      expect('release-fn:' + typeof releaseAvailable).assertEqual('release-fn:function');
      // Release 给了覆盖参数也不认。
      const want: Want = { parameters: { 'couli_debug_route_available': 'PhoneChange' } as Record<string, Object> };
      ReleaseVariant.applyLaunchOptions(new Object() as common.ApplicationContext, want);
      expect('release:' + releaseAvailable()).assertEqual('release:false');
      if (AppConfig.environment() === undefined) {
        await AppConfig.start(AppEnvironment.STAGING, new MemoryEnvironmentRecord());
      }
      const owner: Object = Reflect.get(new StagingVariant(), 'constructor') as Object;
      const available: () => boolean = Reflect.get(owner, 'phoneChangeAvailable') as () => boolean;
      expect('staging-fn:' + typeof available).assertEqual('staging-fn:function');
      const savedAvailable: Object | undefined = Reflect.get(owner, 'availableOverride') as Object | undefined;
      const savedUnavailable: Object | undefined = Reflect.get(owner, 'unavailableOverride') as Object | undefined;
      const wasOn: boolean = !DebugFakeServer.setEnabled(true);
      DebugFakeServer.setEnabled(false);
      try {
        // 1 直连真服务、两份名单都空 → 不可用。
        Reflect.set(owner, 'availableOverride', new Array<string>());
        StagingVariant.applyRouteUnavailable('');
        expect('none:' + available()).assertEqual('none:false');
        // 2 假服务闸门放行 → 可用。
        DebugFakeServer.setEnabled(true);
        expect(DebugFakeServer.mockGate()).assertTrue();
        expect('fake:' + available()).assertEqual('fake:true');
        // 3 假服务放行但强制不可用含 PhoneChange（逗号分隔、带空白）→ 不可用。
        StagingVariant.applyRouteUnavailable(' Wallet , PhoneChange ');
        expect('fake+unavailable:' + available()).assertEqual('fake+unavailable:false');
        // 4 假服务关、只在强制可用名单里 → 可用。
        StagingVariant.applyRouteUnavailable('');
        DebugFakeServer.setEnabled(false);
        Reflect.set(owner, 'availableOverride', ['PhoneChange']);
        expect('available:' + available()).assertEqual('available:true');
        // 5 两份名单都有 → 以不可用为准。
        StagingVariant.applyRouteUnavailable('PhoneChange');
        expect('both:' + available()).assertEqual('both:false');
      } finally {
        Reflect.set(owner, 'availableOverride', savedAvailable);
        Reflect.set(owner, 'unavailableOverride', savedUnavailable);
        DebugFakeServer.setEnabled(wasOn);
      }
    });
  });
}
