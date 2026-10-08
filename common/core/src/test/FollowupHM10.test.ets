// F-HM-10（随 APP-05b）：APP-05a 共性 22（已写出的发码被取消后仍可继续输入，未写出的不记）、23（登出在与登录保存同一同步区里
// 核对登录世代再删会话，新登录不被误删）、24（登录尝试作废与会话保存在同一同步区）、25（原会话已被别处清除时，登出收尾只清原会话
// 的待办）、26（会话失效 Effect 带网络层确定清理时的被清世代，旧世代没清就不发）；APP-04 共性 66、67、68（桥 auth.login 等这次
// 登录完成或离开再结算；是否打开登录页按本次导航的实际结果；结算允许本次登录造成的会话变化——走完整 BridgeHost 链路）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiRequest, ApiResult, BridgeCaller, BridgeHandlers, BridgeHost, BridgeLoginWait, LoginOutcome, MemorySessionTokens,
  PhoneEntry, RouteRequest, RouteSource, Router, SendCodeOutcome, SessionTokenSet, TransportRequest, TransportResponse
} from '../../Index';
import { Deferred, envelope, flush, Rig, tokenPair } from './NetworkTestRig';
import { OAuthFixture } from './App05bFixture';
import { FakeState, ManualClock, ORIGIN, req, wire } from './BridgeHost.test';

const CONSENT_AT: number = 1790661600000;

function smsLoginData(userId: string | null): string {
  const user: string = userId === null ? '' : '"user_id":"' + userId + '",';
  return '{' + user + '"is_new_user":false,"tokens":' + tokenPair('new-access', 'new-refresh', 'full') + '}';
}

/** 桥宿主状态：绑定串按真实会话世代与账号现算（登录会改变它）。 */
class LiveBridgeState extends FakeState {
  private readonly rig: Rig;

  constructor(rig: Rig) {
    super();
    this.rig = rig;
  }

  loggedIn(): boolean {
    return this.rig.client.sessionAccount() !== null;
  }

  binding(): string {
    return this.privacyRaw + '|0|1|' + this.rig.client.sessionGenerationId() + '|'
      + (this.rig.client.sessionAccount() ?? '');
  }
}

function fastSleep(_ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 2);
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

function bridgeHost(f: OAuthFixture, state: LiveBridgeState): BridgeHost {
  const host: BridgeHost = new BridgeHost(state, new ManualClock());
  host.register('auth.login', BridgeHandlers.login((hostValid: () => boolean): Promise<boolean> =>
  new BridgeLoginWait(f.navigator, () => f.service, (): number => f.rig.client.sessionGenerationId(),
    (): boolean => f.rig.client.sessionAccount() !== null, (): void => {
      f.router.open(RouteRequest.of('Login', RouteSource.IN_APP));
    }, fastSleep).run(hostValid)));
  return host;
}

class Settled {
  reply: string | null = null;
  done: boolean = false;
}

function track(p: Promise<string | null>): Settled {
  const s: Settled = new Settled();
  p.then((r: string | null): void => {
    s.reply = r;
    s.done = true;
  });
  return s;
}

const CALLER: BridgeCaller = new BridgeCaller(ORIGIN, true, true);

export default function followupHM10Test() {
  describe('FollowupHM10', () => {
    it('item22_written_send_cancelled_by_phone_change_keeps_continue_entry', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const deferred: Deferred = new Deferred();
      let smsCalls: number = 0;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/sms-codes') >= 0) {
          smsCalls++;
          if (smsCalls === 1) {
            // 传输层发出前的最后核对通过 = 已写出；服务端受理了，但响应还没回来。
            r.admit();
            return deferred.promise;
          }
          const headers: Record<string, string> = {};
          headers['Retry-After'] = '120';
          return Promise.resolve(envelope(42901, '{}', headers));
        }
        return f.answer(r);
      };
      const running: Promise<SendCodeOutcome> = f.service.sendCode('13800138000');
      await flush();
      // 换号：旧请求作废并取消。
      f.service.invalidateAttempt();
      const outcome: SendCodeOutcome = await running;
      // 旧请求不改页面。
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      // 换回号码 A：已写出、结果未知的发码保留「继续输入验证码」的期限。
      expect(f.service.continueEntry('13800138000').kind).assertEqual(PhoneEntry.CONTINUE);
      // 再发码遇到 42901：仍能继续输入已收到的码。
      const limited: SendCodeOutcome = await f.service.sendCode('13800138000');
      expect(limited.stateRaw).assertEqual('rate_limited');
      expect(f.service.phoneEntry('13800138000', true).kind).assertEqual(PhoneEntry.CONTINUE);
    });

    it('item22_unwritten_send_is_not_recorded', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const pending: TransportRequest[] = [];
      const deferred: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        pending.push(r);
        return deferred.promise;
      };
      const running: Promise<SendCodeOutcome> = f.service.sendCode('13800138000');
      await flush();
      f.service.invalidateAttempt();
      // 还在等连接：真正发出前的核对不通过，没有写出。
      expect(pending.length).assertEqual(1);
      expect(pending[0].admit()).assertFalse();
      const outcome: SendCodeOutcome = await running;
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      expect(f.service.continueEntry('13800138000').kind).assertEqual(PhoneEntry.SEND);
      expect(f.service.issuedCodeRemainingSec('13800138000')).assertEqual(0);
    });

    it('item23_logout_does_not_delete_login_saved_while_waiting', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const logoutReply: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/logout') >= 0) {
          return logoutReply.promise;
        }
        if (r.url.indexOf('/v1/auth/login/sms') >= 0) {
          // 新登录的响应没有 user_id（账号未知）：旧实现按「世代变了且有账号」判断，会把它当成原会话已清而删掉。
          return Promise.resolve(envelope(0, smsLoginData(null)));
        }
        return Promise.resolve(envelope(10404, '{}'));
      };
      const loggingOut: Promise<boolean> = f.service.logout();
      await flush();
      // 等待期间原会话先被网络层清掉（10404），随后用户在登录页完成新登录。
      await f.rig.client.request(new ApiRequest('getMe'));
      expect(f.rig.tokens.accessToken()).assertNull();
      const login: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(login.stateRaw).assertEqual(LoginOutcome.LOGGED_IN);
      f.host.calls.splice(0, f.host.calls.length);
      logoutReply.resolve(envelope(0, '{}'));
      const done: boolean = await loggingOut;
      expect(done).assertFalse();
      expect(f.rig.tokens.accessToken()).assertEqual('new-access');
      expect(f.host.calls.indexOf('sessionEnded')).assertEqual(-1);
    });

    it('item23_logout_without_new_login_clears_in_same_sync_region', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const epoch: number = f.rig.client.loginEpoch();
      expect(await f.service.logout()).assertTrue();
      expect(f.rig.tokens.accessToken()).assertNull();
      expect(f.rig.client.loginEpoch()).assertEqual(epoch + 1);
      // 用过期的登录世代再清：不动当前会话。
      f.rig.tokens.save(new SessionTokenSet('later-access', 'later-refresh', 'full', 'user-2'));
      expect(f.rig.client.clearSessionIfEpoch(epoch)).assertFalse();
      expect(f.rig.tokens.accessToken()).assertEqual('later-access');
    });

    it('item24_invalidation_before_response_processing_wins_over_save', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const reply: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
      r.url.indexOf('/v1/auth/login/sms') >= 0 ? reply.promise : f.answer(r);
      const running: Promise<LoginOutcome> = f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      await flush();
      // 响应已到传输层、处理它的续延还没跑：同一轮里先作废。核对有效与写令牌在同一同步区，作废只能落在它之前或之后。
      reply.resolve(envelope(0, smsLoginData('user-9')));
      f.service.invalidateAttempt();
      const outcome: LoginOutcome = await running;
      expect(outcome.stateRaw).assertEqual(LoginOutcome.STALE);
      expect(f.rig.tokens.accessToken()).assertNull();
    });

    it('item25_logout_after_network_cleared_session_keeps_new_guest_pending', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      const logoutReply: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/logout') >= 0) {
          return logoutReply.promise;
        }
        return Promise.resolve(envelope(10404, '{}'));
      };
      const loggingOut: Promise<boolean> = f.service.logout();
      await flush();
      // 等待期间网络层清掉原会话（业务请求 10404）。
      await f.rig.client.request(new ApiRequest('getMe'));
      expect(f.rig.tokens.accessToken()).assertNull();
      // 之后用户（游客）点了需登录的入口：新建的 pending_action 属于游客。
      f.openInApp('OrderList');
      expect(f.router.hasPendingAction).assertTrue();
      logoutReply.resolve(envelope(10404, '{}'));
      expect(await loggingOut).assertTrue();
      expect(f.router.hasPendingAction).assertTrue();
    });

    it('item25_pending_of_original_session_is_still_cleared', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(OAuthFixture.session('user-1'));
      // 原会话的待办（冷启动读到 / 上次前置没走完）。
      const values: Record<string, Object> = {};
      values['route'] = 'OrderList';
      f.store.save(Router.OPEN_ROUTE_ACTION, values, f.rig.nowMillis, RouteSource.IN_APP);
      expect(f.router.hasPendingAction).assertTrue();
      const logoutReply: Deferred = new Deferred();
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
      r.url.indexOf('/v1/auth/logout') >= 0 ? logoutReply.promise : Promise.resolve(envelope(10404, '{}'));
      const loggingOut: Promise<boolean> = f.service.logout();
      await flush();
      await f.rig.client.request(new ApiRequest('getMe'));
      logoutReply.resolve(envelope(0, '{}'));
      expect(await loggingOut).assertTrue();
      expect(f.router.hasPendingAction).assertFalse();
      expect(f.host.calls.indexOf('sessionEnded') >= 0).assertTrue();
    });

    it('item26_session_effect_carries_cleared_generation_and_stale_clear_is_not_sent', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10404, '{}'));
      const generation: number = rig.client.sessionGenerationId();
      const result: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(result.code).assertEqual(10404);
      expect(rig.sessionEffects.length).assertEqual(1);
      expect(rig.clearedGenerations[0]).assertEqual(generation);
      // 旧世代的 10404 在新会话之后到达：不清新会话、不发通知。
      const second: Rig = new Rig();
      const reply: Deferred = new Deferred();
      second.server.handler = (_r: TransportRequest): Promise<TransportResponse> => reply.promise;
      const running: Promise<ApiResult> = second.client.request(new ApiRequest('getMe'));
      await flush();
      second.client.onSessionChanged();
      second.tokens.save(new SessionTokenSet('fresh-access', 'fresh-refresh', 'full', 'user-2'));
      reply.resolve(envelope(10404, '{}'));
      await running;
      expect(second.sessionEffects.length).assertEqual(0);
      expect(second.tokens.accessToken()).assertEqual('fresh-access');
    });

    it('item66_67_same_host_cancel_then_login_waits_and_settles_true_through_bridge_host', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const host: BridgeHost = bridgeHost(f, new LiveBridgeState(f.rig));
      // 第一次：打开登录页，用户关掉 → false。
      const first: Settled = track(host.handle(req('L1', 'auth.login'), CALLER));
      await flush();
      expect(f.stack.names.indexOf('Login') >= 0).assertTrue();
      expect(first.done).assertFalse();
      f.navigator.remove('Login');
      await sleep(20);
      expect(first.done).assertTrue();
      expect(JSON.stringify(wire(first.reply).data)).assertEqual('{"logged_in":false}');
      // 同一宿主再次调用：照样打开并等待（不因上一次的路由结果提前返回）。
      const second: Settled = track(host.handle(req('L2', 'auth.login'), CALLER));
      await sleep(20);
      expect(f.stack.names.indexOf('Login') >= 0).assertTrue();
      expect(second.done).assertFalse();
      // 在登录页完成短信登录（会话保存、会话世代与账号变化）→ true（共性 68：允许本次登录造成的会话变化）。
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
      r.url.indexOf('/v1/auth/login/sms') >= 0 ? Promise.resolve(envelope(0, smsLoginData('user-9'))) : f.answer(r);
      const login: LoginOutcome = await f.service.login('13800138000', '123456', CONSENT_AT, '', false);
      expect(login.stateRaw).assertEqual(LoginOutcome.LOGGED_IN);
      await sleep(20);
      expect(second.done).assertTrue();
      expect(wire(second.reply).code).assertEqual(0);
      expect(JSON.stringify(wire(second.reply).data)).assertEqual('{"logged_in":true}');
    });

    it('item66_privacy_change_while_waiting_ends_the_wait', 0, async () => {
      const f: OAuthFixture = new OAuthFixture();
      const state: LiveBridgeState = new LiveBridgeState(f.rig);
      const host: BridgeHost = bridgeHost(f, state);
      const call: Settled = track(host.handle(req('P1', 'auth.login'), CALLER));
      await sleep(10);
      expect(call.done).assertFalse();
      state.privacyRaw = 'basic_mode';
      await sleep(30);
      expect(call.done).assertTrue();
      // 登录页仍在，但这次调用的隐私归属已失效：不再等。
      expect(JSON.stringify(wire(call.reply).data)).assertEqual('{"logged_in":false}');
    });

    it('item67_no_login_page_opened_settles_immediately_with_current_state', 0, async () => {
      const f: OAuthFixture = new OAuthFixture(new MemorySessionTokens(new SessionTokenSet('a', 'r', 'full', 'user-1')));
      let opened: number = 0;
      const wait: BridgeLoginWait = new BridgeLoginWait(f.navigator, () => f.service,
        (): number => f.rig.client.sessionGenerationId(), (): boolean => f.rig.client.sessionAccount() !== null,
        (): void => {
          opened++;
        }, fastSleep);
      // 本次导航没有压入登录页：按当前登录状态立即结算。
      expect(await wait.run((): boolean => true)).assertTrue();
      expect(opened).assertEqual(1);
    });
  });
}
