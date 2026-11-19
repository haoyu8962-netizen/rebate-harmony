// LOCK-harmony 段 2 测试写手（网络层：身份未知三档、五类声明、两次读交错、固定账号核对；D10-2108 Q1 / Q2 / Q3 / Q7）。
// 规则原文：couli origin/main 规划/03_前端架构.md §4.2「可选登录接口的发送口径」；编排裁定 D10-1658 ④、D10-1703、D10-1709、D10-1710、
// D10-1711、D10-1713、D10-1715、D10-1716、D10-1931、D10-1939、D10-1940、D10-2108。
// 全部走真实 ApiClient + 本地假服务（NetworkTestRig）；「会话读不出」用 MemorySessionTokens.unreadable 或真实 SecureSessionTokens
// 读令牌项抛错（FollowupHM0724Rig.FlakyTokenStore）；「读得出但没有 access_token」用真实 SecureSessionTokens 读一份缺 access 的存储项。
// 五类声明尽量经生产调用点（LoginService、BindPhoneService、OAuthLoginService、OneTapLoginService、ApiConfigFetcher、
// PrivacyCenterController）驱动，不假设开关名；只有没有生产调用方的 ingestEvents 与「声明了也不得越过请求体条件」的几条在网络层直接构造，
// 用 Reflect.set 打开开关（名字 DECLARE，取 iOS ApiCall.sendsWhenIdentityUnknown 的同名；实现若取别名，报编排一并改本文件的常量）。
// 每条用例上方写「依据」与「先红」：先红 = 当前 HEAD（505c77d，未实现）上这条怎样；标「防改错」的是现状已对、钉住不许改坏的。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientWalletPort, ApiConfigFetcher, ApiOutcome, ApiRequest, ApiResult, LegalVersions, LocalRejectReason, LoginHost,
  LoginService, MemorySessionTokens, MeLocalStore, MemoryMeClearMark, MemoryMeLocalBackend, NetworkHeaders, OAuthLoginOutcome,
  OAuthProvider, PhoneChangeController, PrivacyCenterController, RealNameRemote, SecureSessionTokens, SendCodeOutcome,
  SessionIdentity, SessionReadStatus, SessionTokens, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse
} from '../../Index';
import { OneTapAttempt, OneTapLoginService } from '../main/ets/login/OneTapLoginService';
import { Deferred, envelope, flush, header, Rig, tokenPair } from './NetworkTestRig';
import { FlakyTokenStore, TOKENS_ALIAS } from './FollowupHM0724Rig';
import { OAuthFixture } from './App05bFixture';
import { MeFixture, Ports, settle } from './MeIntegration.test';
import { AccountFixture, fillStep2, toStep2 } from './AccountIntegration.test';

/** 「身份未知也照发」开关名（只给网络层直接构造的用例用；见文件头）。 */
const DECLARE: string = 'sendsWhenIdentityUnknown';
const PHONE: string = '13800138000';
const CONSENT_AT: number = 1790661600000;
const SMS: string = '/v1/auth/sms-codes';
const OAUTH: string = '/v1/auth/oauth-attempts';
const CONFIG: string = '/v1/config';
const EVENTS: string = '/v1/events';
const CONSENTS: string = '/v1/consents';
const SEARCH: string = '/v1/products/search';
const LINKS: string = '/v1/links/';

/** 读得出、有合法 refresh、但没有 access_token 的会话项（Q1：只有「缺失或为 null」算身份未知）。 */
const NO_ACCESS_SHAPES: string[] = [
  '{"refresh_token":"ref-n","session_scope":"full","account":"user-1"}',
  '{"access_token":null,"refresh_token":"ref-n","session_scope":"full","account":"user-1"}',
  '{"refresh_token":"ref-n","session_scope":"full","account":null}'
];
/** Q1：仍按损坏（空串、类型错；refresh 不合法时缺 access 也不算身份未知）。 */
const CORRUPT_SHAPES: string[] = [
  '{"access_token":"","refresh_token":"ref-n","session_scope":"full","account":"user-1"}',
  '{"access_token":5,"refresh_token":"ref-n","session_scope":"full","account":"user-1"}',
  '{"refresh_token":"","session_scope":"full","account":"user-1"}',
  '{"access_token":null,"session_scope":"full","account":"user-1"}',
  '{"refresh_token":7,"session_scope":"full","account":"user-1"}'
];

function declared(request: ApiRequest): ApiRequest {
  Reflect.set(request, DECLARE, true);
  return request;
}

function auth(r: TransportRequest): string | undefined {
  return header(r, NetworkHeaders.AUTHORIZATION);
}

function sentTo(rig: Rig, part: string): TransportRequest[] {
  return rig.server.received.filter((r: TransportRequest): boolean => r.url.indexOf(part) >= 0);
}

function search(): ApiRequest {
  return new ApiRequest('searchProducts', {}, 'keyword=phone');
}

function openLink(): ApiRequest {
  const params: Record<string, string> = {};
  params['link_id'] = 'lk-1';
  return new ApiRequest('openLink', params, '', '{}');
}

function getLink(): ApiRequest {
  const params: Record<string, string> = {};
  params['link_id'] = 'lk-1';
  return new ApiRequest('getLink', params);
}

function parseInput(): ApiRequest {
  return new ApiRequest('parseInput', {}, '', '{"text":"https://item.example.invalid/1"}');
}

function sms(purpose: string): ApiRequest {
  return new ApiRequest('sendSmsCode', {}, '', '{"phone":"' + PHONE + '","purpose":"' + purpose + '"}');
}

function oauthAttempt(purpose: string): ApiRequest {
  return new ApiRequest('createOauthAttempt', {}, '', '{"provider":"wechat","purpose":"' + purpose + '"}');
}

function consent(type: string, accepted: boolean): ApiRequest {
  return new ApiRequest('recordConsent', {}, '', '{"type":"' + type + '","version":3,"accepted":' + accepted
    + ',"channel":"privacy_center","client_at":"2026-10-01T10:00:00+08:00"}');
}

function events(): ApiRequest {
  return new ApiRequest('ingestEvents', {}, '', '{"events":[]}');
}

const LINK_CALLS: (() => ApiRequest)[] = [openLink, getLink];
const LINK_CALLS_WITH_PARSE: (() => ApiRequest)[] = [parseInput, openLink, getLink];

/** 已登录会员（old-access / user-1），会话此刻读不出（存着会话但读不出：身份未知）。 */
function unknownRig(): Rig {
  const rig: Rig = new Rig();
  rig.tokens.unreadable = true;
  return rig;
}

/** 本地拒绝且原因在允许集合里（D10-1940：错误码各端沿用现有的，用例钉零发送）。 */
function rejectedWith(result: ApiResult, reasons: string[]): boolean {
  return result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason !== null
    && reasons.indexOf(result.localRejectReason as string) >= 0;
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

/** 真实 SecureSessionTokens（读令牌项可按次数抛错）接真实 ApiClient；自己丢弃会话时照 NetworkComposition 通知网络层。 */
class SecureWorld {
  readonly store: FlakyTokenStore = new FlakyTokenStore();
  readonly tokens: SecureSessionTokens;
  readonly rig: Rig;
  discards: number = 0;

  constructor(stored: string | null) {
    if (stored !== null) {
      this.store.values.set(TOKENS_ALIAS, stored);
    }
    this.tokens = new SecureSessionTokens(this.store);
    this.rig = new Rig(null, null, null, null, null, null, null, this.tokens);
    this.tokens.onSelfDiscarded((): void => {
      this.discards++;
      this.rig.client.onSessionTokensCleared(true);
    });
  }
}

/** D10-2123：会话读取方法按开关抛错的令牌存储（生产实现不会抛；钉「抛错按读不出、不向上抛」）。 */
class ThrowingReadTokens implements SessionTokens {
  failing: boolean = false;
  private readonly inner: MemorySessionTokens;

  constructor(initial: SessionTokenSet | null) {
    this.inner = new MemorySessionTokens(initial);
  }

  private check(): void {
    if (this.failing) {
      throw new Error('session read failed');
    }
  }

  accessToken(): string | null {
    this.check();
    return this.inner.accessToken();
  }

  refreshToken(): string | null {
    this.check();
    return this.inner.refreshToken();
  }

  scope(): string {
    this.check();
    return this.inner.scope();
  }

  account(): string | null {
    this.check();
    return this.inner.account();
  }

  readStatus(): string {
    this.check();
    return this.inner.readStatus();
  }

  save(tokens: SessionTokenSet): void {
    this.inner.save(tokens);
  }

  clear(): void {
    this.inner.clear();
  }
}

function meStore(): MeLocalStore {
  const s: MeLocalStore = new MeLocalStore();
  s.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
  return s;
}

export default function lockHarmonySeg2Test() {
  describe('LockHarmonySeg2', () => {
    // ================================================================ D10-1931 ④ 四条（followups.md:1164-1166）

    // 依据：D10-1931 ④ 第 1 条、03 §4.2 第二条「搜索……都不声明，身份未知时不发」、D10-1940 (三)。
    // 先红：防改错（现状 prepare 对 auth!=='none' 且读不出时一律 session_unreadable），钉住放开名单时不得把搜索带进去。
    it('s2_1931_1_unreadable_session_search_products_zero_writes', 0, async () => {
      const rig: Rig = unknownRig();
      const result: ApiResult = await rig.client.request(search());
      expect(result.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      expect(rig.server.received.length).assertEqual(0);
    });

    // 依据：D10-1931 ①④ 第 2 条（屏障 / 作废之前开始、未固定账号的 optional 调用写出前比作废世代，零写出、不匿名）；对照：解除后同一操作
    // 按真实身份带 Bearer。另一半：会员开始的搜索在退避期间会话变成读不出，重试不得降成匿名（03 §4.2「每次重试重新核」）。
    // 先红：防改错（现状 epoch / 归属核对已能拦）。
    it('s2_1931_2_call_started_before_invalidation_or_unreadable_is_not_written_anonymously', 0, async () => {
      // (a) 游客开始的搜索：首发断连、退避挂起；期间作废（撤回同意 / 切环境）→ 重试零写出，以 cancelled 收口。
      const guest: Rig = new Rig(null);
      guest.timer.holdBackoff = true;
      guest.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      const firstResults: ApiResult[] = [];
      guest.client.request(search()).then((r: ApiResult): void => {
        firstResults.push(r);
      });
      await flush();
      expect(sentTo(guest, SEARCH).length).assertEqual(1);
      expect(guest.timer.heldBackoffs).assertEqual(1);
      guest.client.invalidate();
      guest.timer.releaseBackoffs();
      await flush();
      expect(sentTo(guest, SEARCH).length).assertEqual(1);
      expect(firstResults.length).assertEqual(1);
      expect(firstResults[0].outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
      // 对照：解除后（新会员会话）同一操作带真实身份的 Bearer 发出。
      guest.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0, '{}'));
      guest.tokens.save(new SessionTokenSet('member-access', 'member-refresh', 'full', 'user-1'));
      const after: ApiResult = await guest.client.request(search());
      expect(after.ok).assertTrue();
      expect(auth(guest.server.last(SEARCH))).assertEqual('Bearer member-access');

      // (b) 会员开始的搜索：首发带 Bearer 断连，退避期间会话变成读不出 → 重试零写出、本地拒，不降成匿名。
      const member: Rig = new Rig();
      member.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      member.timer.onBackoff = (): void => {
        member.tokens.unreadable = true;
      };
      const retried: ApiResult = await member.client.request(search());
      expect(sentTo(member, SEARCH).length).assertEqual(1);
      expect(auth(member.server.last(SEARCH))).assertEqual('Bearer old-access');
      expect(retried.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
    });

    // 依据：D10-1931 ③④ 第 3 条（令牌与读取状态取自同一次读取的同一份快照；前一次读失败、后一次成功，且会话 account 为 null → 不得写出
    // 不带令牌的请求）。前 k 次读令牌项抛错（k = 0..8，覆盖调用入口、归属核对、组请求各处），之后读得出；会话项的 account 为 null，
    // 所以写出前的账号核对拦不住，只能靠单次快照。断言：任何 k 下都不出现匿名写出；本地拒时零写出；写出则必须带这份会话的令牌。
    // 先红：现状在 k = 4 时匿名写出 1 次（入口与核对处几次读令牌都失败，prepare 的 accessToken() 仍失败、紧接着的 readStatus() 读成功 →
    // 既不拒也不带 Authorization；临时 node 跑法实测）。
    it('s2_1931_3_interleaved_reads_fail_then_succeed_with_null_account_never_write_anonymously', 0, async () => {
      const anonymousAt: number[] = [];
      for (let k: number = 0; k <= 8; k++) {
        const w: SecureWorld = new SecureWorld(
          '{"access_token":"acc-n","refresh_token":"ref-n","session_scope":"full","account":null}');
        w.store.failNextReads(k);
        const result: ApiResult = await w.rig.client.request(search());
        const writes: TransportRequest[] = sentTo(w.rig, SEARCH);
        for (const r of writes) {
          if (auth(r) !== 'Bearer acc-n') {
            anonymousAt.push(k);
          }
        }
        if (!result.ok) {
          expect(result.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
          expect(writes.length).assertEqual(0);
        }
      }
      expect(anonymousAt.join(',')).assertEqual('');
    });

    // 依据：D10-1931 ②④ 第 4 条、03 §4.2 第一条（读得出却没有 access_token = 身份未知，默认不发）、D10-2108 Q1（只有 access 缺失或为 null、
    // refresh 合法时算身份未知；这不是「会话条目损坏」，不得隔离删除、不得通知换代后当游客照发，D10-1931 ②）。
    // 先红：现状 decode 把三种形状都当损坏 → 删除并通知 → readStatus ABSENT → 搜索 / 取链接匿名写出。
    it('s2_1931_4a_present_session_without_access_undeclared_optional_zero_writes_and_not_corrupt', 0, async () => {
      for (const shape of NO_ACCESS_SHAPES) {
        const w: SecureWorld = new SecureWorld(shape);
        const found: ApiResult = await w.rig.client.request(search());
        const link: ApiResult = await w.rig.client.request(getLink());
        const parsed: ApiResult = await w.rig.client.request(parseInput());
        expect(found.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(found.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
        expect(link.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(parsed.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(w.rig.server.received.length).assertEqual(0);
        // 不按损坏处理：会话项还在、没有「自己丢弃」通知、读取结果不是「没有会话」。
        expect(w.store.values.has(TOKENS_ALIAS)).assertTrue();
        expect(w.discards).assertEqual(0);
        expect(w.tokens.readStatus() === SessionReadStatus.ABSENT).assertFalse();
      }
    });

    // 依据：同上第 4 条后半（五类声明的照发、不带令牌）；D10-1940 (一)（签名类带设备标识与签名）。
    // 先红：防改错（现状把这三种形状当游客，所以照发、不带令牌；钉住实现不能改成「无 access 一律拒」）。
    it('s2_1931_4b_present_session_without_access_declared_requests_send_without_token', 0, async () => {
      for (const shape of NO_ACCESS_SHAPES) {
        const w: SecureWorld = new SecureWorld(shape);
        await ApiConfigFetcher.fetch(w.rig.client, null);
        const login: LoginService = new LoginService(w.rig.client, w.tokens, new QuietHost());
        await login.sendCode(PHONE);
        expect(sentTo(w.rig, CONFIG).length).assertEqual(1);
        expect(auth(w.rig.server.last(CONFIG)) === undefined).assertTrue();
        expect(sentTo(w.rig, SMS).length).assertEqual(1);
        const sent: TransportRequest = w.rig.server.last(SMS);
        expect(auth(sent) === undefined).assertTrue();
        expect(header(sent, NetworkHeaders.DEVICE_ID)).assertEqual('device-fixture');
        expect(header(sent, NetworkHeaders.SIGN) !== undefined).assertTrue();
      }
    });

    // 依据：D10-2108 Q1（''（空串）和类型错仍按损坏；refresh 不合法的也不是「身份未知」）、03 §4.2 第六条与 D10-1715 / D10-1716（损坏 →
    // 世代加一、通知一次、之后按确认游客匿名发）。
    // 先红：防改错（现状已如此；钉住实现不能把空串 / 类型错 / refresh 不合法一并当成身份未知）。
    it('s2_q1_empty_or_mistyped_access_or_invalid_refresh_stays_corrupt_then_confirmed_guest', 0, async () => {
      for (const shape of CORRUPT_SHAPES) {
        const w: SecureWorld = new SecureWorld(shape);
        const generation: number = w.rig.client.sessionGenerationId();
        expect(w.tokens.readStatus()).assertEqual(SessionReadStatus.ABSENT);
        expect(w.discards).assertEqual(1);
        expect(w.rig.client.sessionGenerationId() > generation).assertTrue();
        expect(w.store.values.has(TOKENS_ALIAS)).assertFalse();
        const found: ApiResult = await w.rig.client.request(search());
        expect(found.ok).assertTrue();
        expect(sentTo(w.rig, SEARCH).length).assertEqual(1);
        expect(auth(w.rig.server.last(SEARCH)) === undefined).assertTrue();
        // 只通知一次（D10-1716 ②）。
        expect(w.discards).assertEqual(1);
      }
    });

    // ================================================================ D10-1703 ② 固定账号核对（Q3：拒绝码沿用 session_changed，钉零发送）

    // 依据：D10-1703 ①② 第 1 条、03 §4.2 第五条（固定账号的请求发送前核对实际带了这个账号的令牌，对不上本地拒，不降成匿名）。鸿蒙在调用入口
    // （api.request 的 bind）固定账号；入口之后、写出之前会话变成读不出（用调用方归属守卫第一次被核对时翻转模拟）。getLink 另走 GET 自动重试：
    // 首发带 Bearer 断连，退避期间读不出 → 重试零写出。
    // 先红：防改错（现状 ownershipLost 账号不同 → session_changed）。
    it('s2_1703_1_member_pinned_then_session_unreadable_open_link_get_link_zero_writes', 0, async () => {
      const reasons: string[] = [LocalRejectReason.SESSION_CHANGED, LocalRejectReason.SESSION_UNREADABLE];
      for (const make of LINK_CALLS) {
        const rig: Rig = new Rig();
        const request: ApiRequest = make();
        request.owner = (): boolean => {
          rig.tokens.unreadable = true;
          return true;
        };
        const result: ApiResult = await rig.client.request(request);
        expect(rejectedWith(result, reasons)).assertTrue();
        expect(sentTo(rig, LINKS).length).assertEqual(0);
      }
      const retry: Rig = new Rig();
      retry.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      retry.timer.onBackoff = (): void => {
        retry.tokens.unreadable = true;
      };
      const again: ApiResult = await retry.client.request(getLink());
      expect(rejectedWith(again, reasons)).assertTrue();
      expect(sentTo(retry, LINKS).length).assertEqual(1);
      expect(auth(retry.server.last(LINKS))).assertEqual('Bearer old-access');
    });

    // 依据：D10-1703 ② 第 2 条（固定账号后令牌换成另一账号 → 本地拒）；每次重试重新核。
    // 先红：防改错。
    it('s2_1703_2_member_pinned_then_token_of_another_account_open_link_get_link_zero_writes', 0, async () => {
      const reasons: string[] = [LocalRejectReason.SESSION_CHANGED, LocalRejectReason.ACCOUNT_MISMATCH];
      for (const make of LINK_CALLS) {
        const rig: Rig = new Rig();
        const request: ApiRequest = make();
        request.owner = (): boolean => {
          rig.tokens.save(new SessionTokenSet('access-B', 'refresh-B', 'full', 'user-2'));
          return true;
        };
        const result: ApiResult = await rig.client.request(request);
        expect(rejectedWith(result, reasons)).assertTrue();
        expect(sentTo(rig, LINKS).length).assertEqual(0);
      }
      const retry: Rig = new Rig();
      retry.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      retry.timer.onBackoff = (): void => {
        retry.tokens.save(new SessionTokenSet('access-B', 'refresh-B', 'full', 'user-2'));
      };
      const again: ApiResult = await retry.client.request(getLink());
      expect(rejectedWith(again, reasons)).assertTrue();
      expect(sentTo(retry, LINKS).length).assertEqual(1);
      expect(auth(retry.server.last(LINKS))).assertEqual('Bearer old-access');
    });

    // 依据：D10-1703 ② 第 3 条、D10-1709 ②（确认游客 → 匿名照发）。
    // 先红：防改错（钉住实现不能改成「无令牌一律拒」）。
    it('s2_1703_3_confirmed_guest_open_link_and_get_link_send_anonymously', 0, async () => {
      const rig: Rig = new Rig(null);
      const opened: ApiResult = await rig.client.request(openLink());
      const got: ApiResult = await rig.client.request(getLink());
      expect(opened.ok).assertTrue();
      expect(got.ok).assertTrue();
      expect(sentTo(rig, LINKS).length).assertEqual(2);
      for (const r of sentTo(rig, LINKS)) {
        expect(auth(r) === undefined).assertTrue();
      }
      expect(header(rig.server.received[0], NetworkHeaders.SIGN) !== undefined).assertTrue();
    });

    // ================================================================ D10-1709 / 1710 / 1711 / 1713：身份未知（会话读不出）

    // 依据：D10-1709 ③④ 用例「身份未知 + parseInput / openLink → session_unreadable、零发送」；03 §4.2 第二条（转链、报价不声明）。
    // 先红：防改错。
    it('s2_1709_1_identity_unknown_parse_input_open_link_get_link_rejected_zero_writes', 0, async () => {
      const rig: Rig = unknownRig();
      for (const make of LINK_CALLS_WITH_PARSE) {
        const result: ApiResult = await rig.client.request(make());
        expect(result.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      }
      expect(rig.server.received.length).assertEqual(0);
    });

    // 依据：D10-1709 ③（登录发码 purpose=login 声明照发）、D10-1658 ④、D10-1940 (一)（签名类带设备标识与签名、不带令牌）；调用点 LoginService。
    // 先红：现状 prepare 对读不出的 optional 一律 session_unreadable → 发码零写出。
    it('s2_1709_2_identity_unknown_login_sms_via_login_service_sends_signed_without_token', 0, async () => {
      const rig: Rig = unknownRig();
      const login: LoginService = new LoginService(rig.client, rig.tokens, new QuietHost());
      await login.sendCode(PHONE);
      expect(sentTo(rig, SMS).length).assertEqual(1);
      const sent: TransportRequest = rig.server.last(SMS);
      expect(auth(sent) === undefined).assertTrue();
      expect(header(sent, NetworkHeaders.DEVICE_ID)).assertEqual('device-fixture');
      expect(header(sent, NetworkHeaders.SIGN) !== undefined).assertTrue();
      expect((sent.body ?? '').indexOf('"purpose":"login"') >= 0).assertTrue();
    });

    // 依据：D10-1709 ③（绑手机发码 purpose=bind 声明照发）；调用点 BindPhoneService（第三方登录后的绑手机页）。
    // 先红：现状 session_unreadable → 零写出。
    it('s2_1709_3_identity_unknown_bind_sms_via_bind_phone_service_sends_without_token', 0, async () => {
      const tokens: MemorySessionTokens = OAuthFixture.session('user-1');
      tokens.unreadable = true;
      const f: OAuthFixture = new OAuthFixture(tokens);
      await f.bind.sendCode(PHONE);
      expect(sentTo(f.rig, SMS).length).assertEqual(1);
      const sent: TransportRequest = f.rig.server.last(SMS);
      expect(auth(sent) === undefined).assertTrue();
      expect(header(sent, NetworkHeaders.SIGN) !== undefined).assertTrue();
      expect((sent.body ?? '').indexOf('"purpose":"bind"') >= 0).assertTrue();
    });

    // 依据：D10-1709 ③（getConfig 声明照发）、D10-1931 ②（鸿蒙「读不出时一律拒」偏严，要对齐）、Q7（调用点开开关：裸 getConfig 没有声明，
    // 照旧 session_unreadable——不按 operation 在网络层一律放行；ClientCoreIntegration:585 那条因此不变）。
    // 先红：现状经 ApiConfigFetcher 的 getConfig 也被拒 → /v1/config 零写出。
    it('s2_1709_4_identity_unknown_get_config_via_fetcher_sends_once_without_token_bare_call_still_rejected', 0, async () => {
      const rig: Rig = unknownRig();
      const bare: ApiResult = await rig.client.request(new ApiRequest('getConfig'));
      expect(bare.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      expect(sentTo(rig, CONFIG).length).assertEqual(0);
      await ApiConfigFetcher.fetch(rig.client, null);
      expect(sentTo(rig, CONFIG).length).assertEqual(1);
      expect(auth(rig.server.last(CONFIG)) === undefined).assertTrue();
    });

    // 依据：D10-1709 ③（ingestEvents 声明照发；鸿蒙没有生产调用方，按 scope-draft §3.1 只在网络层支持，这里直接构造）；未声明的同一请求照旧拒。
    // 先红：声明开关不存在 → Reflect.set 只加了一个无人读的属性 → 照旧 session_unreadable、零写出。
    it('s2_1709_5_identity_unknown_ingest_events_declared_sends_undeclared_rejected', 0, async () => {
      const rig: Rig = unknownRig();
      const plain: ApiResult = await rig.client.request(events());
      expect(plain.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      expect(sentTo(rig, EVENTS).length).assertEqual(0);
      const sent: ApiResult = await rig.client.request(declared(events()));
      expect(sent.ok).assertTrue();
      expect(sentTo(rig, EVENTS).length).assertEqual(1);
      expect(auth(rig.server.last(EVENTS)) === undefined).assertTrue();
    });

    // 依据：Q7 的接口约定——开关在 ApiRequest 上、缺省关（D10-1709「缺省 false」）。
    // 先红：ApiRequest 上没有这个字段。
    it('s2_q7_declaration_switch_exists_and_defaults_off', 0, () => {
      const request: ApiRequest = new ApiRequest('getConfig');
      expect(Reflect.has(request, DECLARE)).assertTrue();
      expect(Reflect.get(request, DECLARE) === false).assertTrue();
    });

    // 依据：D10-1710（createOauthAttempt 只在 purpose=login 时声明）；调用点 OAuthLoginService（微信等第三方登录）。
    // 先红：现状 session_unreadable → 授权尝试零写出。
    it('s2_1710_1_identity_unknown_oauth_login_attempt_sends_signed_without_token', 0, async () => {
      const tokens: MemorySessionTokens = OAuthFixture.session('user-1');
      tokens.unreadable = true;
      const f: OAuthFixture = new OAuthFixture(tokens);
      const running: Promise<OAuthLoginOutcome> = f.oauth.loginWith(OAuthProvider.WECHAT, CONSENT_AT);
      await flush();
      expect(sentTo(f.rig, OAUTH).length).assertEqual(1);
      const sent: TransportRequest = f.rig.server.last(OAUTH);
      expect(auth(sent) === undefined).assertTrue();
      expect(header(sent, NetworkHeaders.SIGN) !== undefined).assertTrue();
      expect(running !== null).assertTrue();
    });

    // 依据：D10-1710（同上）；scope-draft §3.1：华为一键登录 OneTapLoginService.createAttempt 同为 createOauthAttempt purpose=login。
    // 先红：现状 session_unreadable → 零写出。
    it('s2_1710_2_identity_unknown_one_tap_attempt_sends_without_token', 0, async () => {
      const tokens: MemorySessionTokens = OAuthFixture.session('user-1');
      tokens.unreadable = true;
      const f: OAuthFixture = new OAuthFixture(tokens);
      const oneTap: OneTapLoginService = new OneTapLoginService(f.rig.client, f.service, new LegalVersions(3, 2));
      const attempt: OneTapAttempt | null = await oneTap.createAttempt();
      expect(sentTo(f.rig, OAUTH).length).assertEqual(1);
      expect(auth(f.rig.server.last(OAUTH)) === undefined).assertTrue();
      expect(attempt !== null).assertTrue();
    });

    // 依据：D10-1710（purpose=step_up / payout_bind / reverify 不声明，身份未知照拒）。
    // 先红：防改错（钉住实现不能在网络层按 operation 放行 createOauthAttempt）。
    it('s2_1710_3_identity_unknown_undeclared_oauth_attempt_non_login_rejected', 0, async () => {
      const rig: Rig = unknownRig();
      for (const purpose of ['step_up', 'payout_bind', 'reverify', 'login']) {
        const result: ApiResult = await rig.client.request(oauthAttempt(purpose));
        expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      }
      expect(rig.server.received.length).assertEqual(0);
    });

    // 依据：D10-1711 ①③、D10-1713、03 §4.2 第二、三条（隐私中心撤回隐私同意 type=privacy 且 accepted=false 声明照发、不带令牌、带
    // X-Device-Id）；调用点 PrivacyCenterController.withdraw。页面打开与确认时会话就已读不出（确认时固定的归属里账号本就为空），所以这里不碰
    // 「确认后才读不出」那种只固定世代的情形（Q6：另登 FU-HM，不在本单）。
    // 先红：现状 session_unreadable → /v1/consents 零写出（本地撤回照常）。
    it('s2_1711_1_identity_unknown_privacy_withdraw_sends_with_device_id_without_token', 0, async () => {
      const f: MeFixture = new MeFixture();
      f.tokens.unreadable = true;
      const ports: Ports = new Ports();
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), ports, meStore());
      p.shown();
      await p.withdraw(p.identity, p.withdrawPermit());
      await settle();
      expect(f.count('POST ' + CONSENTS)).assertEqual(1);
      const sent: TransportRequest = f.last(CONSENTS);
      expect(auth(sent) === undefined).assertTrue();
      expect(header(sent, NetworkHeaders.DEVICE_ID)).assertEqual('device-fixture');
      expect((sent.body ?? '').indexOf('"accepted":false') >= 0).assertTrue();
      expect(ports.withdrawn).assertEqual(1);
    });

    // 依据：D10-1711 ②③（AI / 个性化 / 实名等其余同意类型身份未知时本地拒 session_unreadable、零发送，界面不当成功）；隐私同意 accepted=true
    // 也不是撤回。实名同意走生产调用点 RealNameRemote.recordConsent（结果不 ok）。
    // 先红：防改错。
    it('s2_1711_2_identity_unknown_other_consents_rejected_zero_writes_not_success', 0, async () => {
      const rig: Rig = unknownRig();
      const bodies: ApiRequest[] = [consent('ai_third_party', true), consent('ai_third_party', false),
        consent('personalization', false), consent('personalization', true), consent('privacy', true)];
      for (const request of bodies) {
        const result: ApiResult = await rig.client.request(request);
        expect(result.ok).assertFalse();
        expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      }
      const remote: RealNameRemote = new RealNameRemote(new ApiClientWalletPort(rig.client), (): number | null => 3,
        (): number | null => 3, (): number => CONSENT_AT);
      const realname: ApiResult = await remote.recordConsent((): boolean => true, (): boolean => true);
      expect(realname.ok).assertFalse();
      expect(realname.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      expect(sentTo(rig, CONSENTS).length).assertEqual(0);
    });

    // 依据：D10-1709 ②、D10-1711 ③（确认游客 + parseInput / AI 同意 → 匿名照发，设备级照旧）。
    // 先红：防改错。
    it('s2_1711_3_confirmed_guest_parse_input_and_ai_consent_send_anonymously', 0, async () => {
      const rig: Rig = new Rig(null);
      const parsed: ApiResult = await rig.client.request(parseInput());
      const ai: ApiResult = await rig.client.request(consent('ai_third_party', true));
      expect(parsed.ok).assertTrue();
      expect(ai.ok).assertTrue();
      expect(rig.server.received.length).assertEqual(2);
      for (const r of rig.server.received) {
        expect(auth(r) === undefined).assertTrue();
      }
    });

    // 依据：D10-1709 用例「会话恢复后同一请求带令牌发出」、03 §4.2 第一条「有令牌——带上发」。声明了的 getConfig 在读得出时也必须带令牌
    // （声明只管身份未知那一档，不是「一律匿名」）。
    // 先红：防改错。
    it('s2_1709_6_session_recovers_same_requests_carry_bearer', 0, async () => {
      const rig: Rig = unknownRig();
      expect((await rig.client.request(search())).localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      rig.tokens.unreadable = false;
      const found: ApiResult = await rig.client.request(search());
      expect(found.ok).assertTrue();
      expect(auth(rig.server.last(SEARCH))).assertEqual('Bearer old-access');
      await ApiConfigFetcher.fetch(rig.client, null);
      expect(auth(rig.server.last(CONFIG))).assertEqual('Bearer old-access');
      const sentEvents: ApiResult = await rig.client.request(declared(events()));
      expect(sentEvents.ok).assertTrue();
      expect(auth(rig.server.last(EVENTS))).assertEqual('Bearer old-access');
    });

    // 依据：D10-1860（会员改绑手机：新号发码 purpose=bind 在身份未知时就该被拒）、Q7（不能在网络层只按 purpose=bind 放行）。网络层：没有声明的
    // purpose=bind 发码照拒；调用点：PhoneChangeController 第 2 步的新号发码在会话读不出后零写出。
    // 先红：防改错（钉住「按请求体 purpose=bind 在网络层放行」这种错法）。
    it('s2_1860_phone_change_new_number_bind_sms_rejected_when_identity_unknown', 0, async () => {
      const rig: Rig = unknownRig();
      for (const purpose of ['bind', 'login', 'step_up']) {
        const result: ApiResult = await rig.client.request(sms(purpose));
        expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      }
      expect(rig.server.received.length).assertEqual(0);
      const f: AccountFixture = new AccountFixture();
      const p: PhoneChangeController = await toStep2(f);
      const before: number = f.count('POST ' + SMS);
      f.rig.tokens.unreadable = true;
      await fillStep2(f, p);
      await settle();
      expect(f.count('POST ' + SMS)).assertEqual(before);
    });

    // ================================================================ Q2 / D10-1658 ④：刷新屏障

    // 依据：D10-2108 Q2（只有五类声明请求不等刷新屏障）、D10-1658 ④（会话正在刷新时，登录发码照常立即发出）。会员 getMe 得 10002 触发单飞刷新，
    // 刷新挂起期间经 LoginService 发登录码：刷新结束之前就要写出。
    // 先红：现状有令牌的 optional 算 bound → awaitBarrier → 刷新结束前零写出。
    it('s2_q2_declared_login_sms_does_not_wait_for_refresh_barrier', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      let meCalls: number = 0;
      rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        if (r.url.indexOf('/v1/me') >= 0) {
          meCalls++;
          return Promise.resolve(meCalls === 1 ? envelope(10002, '{}') : envelope(0, '{}'));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      const login: LoginService = new LoginService(rig.client, rig.tokens, new QuietHost());
      const sending: Promise<SendCodeOutcome> = login.sendCode(PHONE);
      await flush();
      const writtenDuringRefresh: number = sentTo(rig, SMS).length;
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      await me;
      await sending;
      expect(writtenDuringRefresh).assertEqual(1);
    });

    // 依据：D10-2108 Q2 后半（其余 optional 照现状：有令牌时等刷新屏障，刷新后带新令牌发）。
    // 先红：防改错（钉住实现不能把屏障豁免扩大到未声明的 optional）。
    it('s2_q2_undeclared_optional_still_waits_for_refresh_then_uses_new_token', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      let meCalls: number = 0;
      rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        if (r.url.indexOf('/v1/me') >= 0) {
          meCalls++;
          return Promise.resolve(meCalls === 1 ? envelope(10002, '{}') : envelope(0, '{}'));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      const found: Promise<ApiResult> = rig.client.request(search());
      await flush();
      expect(sentTo(rig, SEARCH).length).assertEqual(0);
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      await me;
      expect((await found).ok).assertTrue();
      expect(sentTo(rig, SEARCH).length).assertEqual(1);
      expect(auth(rig.server.last(SEARCH))).assertEqual('Bearer new-access');
    });

    // ================================================================ D10-1939 / D10-1940 (二)：设备凭据读不出的窗口

    // 依据：D10-1940 (二)（设备凭据读不出：签名三类零发送；POST /v1/events 零发送；POST /v1/consents 含隐私撤回零发送；只有 GET /v1/config
    // 匿名照发）、D10-1939（声明照发不越过设备凭据屏障与签名要求）。会话身份可读与读不出两种都跑；声明经调用点或网络层开关打开。
    // 先红：防改错（现状撤回清理窗口白名单外一律 credentials_unreadable；钉住声明不得越过这道屏障）。
    it('s2_1940_credentials_unreadable_window_declared_requests_zero_writes_except_config_once', 0, async () => {
      for (const sessionUnreadable of [false, true]) {
        const rig: Rig = new Rig();
        rig.tokens.unreadable = sessionUnreadable;
        rig.context.readable = false;
        const login: LoginService = new LoginService(rig.client, rig.tokens, new QuietHost());
        await login.sendCode(PHONE);
        const signed: ApiRequest[] = [declared(sms('login')), declared(sms('bind')), declared(oauthAttempt('login'))];
        for (const request of signed) {
          expect((await rig.client.request(request)).outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        }
        expect((await rig.client.request(declared(events()))).outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect((await rig.client.request(declared(consent('privacy', false)))).outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(rig.server.received.length).assertEqual(0);
        await ApiConfigFetcher.fetch(rig.client, null);
        expect(rig.server.received.length).assertEqual(1);
        expect(sentTo(rig, CONFIG).length).assertEqual(1);
        expect(auth(rig.server.last(CONFIG)) === undefined).assertTrue();
        expect(header(rig.server.last(CONFIG), NetworkHeaders.DEVICE_ID) === undefined).assertTrue();
      }
    });

    // ================================================================ Q7：声明开关之外还按请求体条件（网络层双重核对；口径见交回「待定」1）

    // 依据：03 §4.2 第二条「按请求体的条件精确打开，不按调用点一律打开」、D10-2108 Q7「调用点打开开关，再按请求体条件放行」、D10-1710（step_up
    // 等不声明）、D10-1711（只有 type=privacy 且 accepted=false）、03 §4.2 第四条（step_up 发码必须带本人令牌）。即使调用方打开了开关，
    // 请求体不在五类条件内的照旧拒。
    // 先红：防改错（现状没有开关，全部拒）；钉住「只看开关不看请求体」这种错法。
    it('s2_q7_declared_switch_does_not_open_bodies_outside_the_five_conditions', 0, async () => {
      const rig: Rig = unknownRig();
      const outside: ApiRequest[] = [declared(sms('step_up')), declared(oauthAttempt('step_up')),
        declared(oauthAttempt('payout_bind')), declared(consent('privacy', true)), declared(consent('ai_third_party', false)),
        declared(consent('personalization', false)), declared(search()), declared(parseInput()), declared(openLink())];
      for (const request of outside) {
        const result: ApiResult = await rig.client.request(request);
        expect(result.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      }
      expect(rig.server.received.length).assertEqual(0);
    });

    // ================================================================ D10-2123 补用例（钉实现者自定、编排认可的两处口径）

    // 依据：D10-2123（认可实现交回待定 1）、03 §4.2 第六条末句「界面显示的登录状态与网络层用的是同一个结果」、D10-1931 ②、D10-2108 Q1。
    // 界面对账入口 ApiClient.sessionIdentity：「有会话、access 缺失或为 null、refresh 合法」与读不出同一档，返回 known=false（账号、世代、
    // 作用域都为空），不推断为确认游客；对照：合法会员 known=true 带账号，空串 access（损坏 → 已丢弃）known=true、账号为空（确认游客）。
    // 防的错法：网络层按身份未知拒发，界面却按「已知、没有账号」当游客（两边不同源）；或者把损坏也一并当成未知（损坏要转游客，D10-1716）。
    // 先红：把 sessionIdentity 里「PRESENT 且 access 为 null → known=false」那一段改回 HEAD 写法 → 返回 known=true、账号为空。
    it('s2_d2123_1_session_identity_without_access_is_unknown_not_confirmed_guest', 0, () => {
      for (const shape of NO_ACCESS_SHAPES) {
        const w: SecureWorld = new SecureWorld(shape);
        const id: SessionIdentity = w.rig.client.sessionIdentity(null);
        expect(id.known).assertFalse();
        expect(id.account === null && id.loginEpoch === null).assertTrue();
        expect(id.scope).assertEqual('');
      }
      const member: SecureWorld = new SecureWorld(
        '{"access_token":"acc-n","refresh_token":"ref-n","session_scope":"full","account":"user-1"}');
      const known: SessionIdentity = member.rig.client.sessionIdentity(null);
      expect(known.known).assertTrue();
      expect(known.account).assertEqual('user-1');
      const corrupt: SecureWorld = new SecureWorld(CORRUPT_SHAPES[0]);
      const guest: SessionIdentity = corrupt.rig.client.sessionIdentity(null);
      expect(guest.known).assertTrue();
      expect(guest.account === null).assertTrue();
    });

    // 依据：D10-2123（认可实现交回待定 3）、03 §4.2 第一条（存着会话、这一刻读不出 = 身份未知）、D10-1709 ③、D10-1940 (一)。会话读取方法
    // 抛错时 ApiClient 不得向上抛：request() 照常交回结果；未声明的 optional 本地拒 session_unreadable、零写出；五类声明照发、不带令牌；
    // 不再抛错后同一请求带令牌。
    // 防的错法：抛错从 request() 同步抛出（调用方没有结果、流程卡住）；或把抛错当「没有会话」按游客匿名发出。
    // 先红：把 readSession 的 catch 去掉（读取方法抛错原样抛出，HEAD 写法）→ request() 抛错。
    it('s2_d2123_2_session_read_throwing_counts_as_unreadable_and_never_propagates', 0, async () => {
      const tokens: ThrowingReadTokens = new ThrowingReadTokens(new SessionTokenSet('old-access', 'old-refresh', 'full',
        'user-1'));
      const rig: Rig = new Rig(null, null, null, null, null, null, null, tokens);
      tokens.failing = true;
      const threw: string[] = [];
      const results: ApiResult[] = [];
      const calls: ApiRequest[] = [search(), getLink(), parseInput(), declared(events()), declared(sms('login'))];
      for (const request of calls) {
        try {
          results.push(await rig.client.request(request));
        } catch (e) {
          threw.push(request.operationId);
        }
      }
      try {
        await ApiConfigFetcher.fetch(rig.client, null);
      } catch (e) {
        threw.push('getConfig');
      }
      expect(threw.join(',')).assertEqual('');
      expect(results.length).assertEqual(5);
      for (let i: number = 0; i < 3; i++) {
        expect(results[i].outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(results[i].localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      }
      expect(sentTo(rig, SEARCH).length + sentTo(rig, LINKS).length + sentTo(rig, '/v1/inputs/parse').length)
        .assertEqual(0);
      expect(results[3].ok).assertTrue();
      expect(results[4].ok).assertTrue();
      for (const part of [EVENTS, SMS, CONFIG]) {
        expect(sentTo(rig, part).length).assertEqual(1);
        expect(auth(rig.server.last(part)) === undefined).assertTrue();
      }
      expect(header(rig.server.last(SMS), NetworkHeaders.SIGN) !== undefined).assertTrue();
      tokens.failing = false;
      const recovered: ApiResult = await rig.client.request(search());
      expect(recovered.ok).assertTrue();
      expect(auth(rig.server.last(SEARCH))).assertEqual('Bearer old-access');
    });
  });
}
