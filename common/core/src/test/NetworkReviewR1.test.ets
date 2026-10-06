// APP-03a 鸿蒙第 1 轮评审（harmony-review-r1.md）R1-01..R1-08 与 RCP 传输层的回归测试：每条复现评审里的失败场景。
// 全部对本地假服务（可注入的传输接口 / 可注入的 RCP 发送层），不连任何真实地址。
import { describe, it, expect } from '@ohos/hypium';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  ApiOperation, ApiOperations, ApiOutcome, ApiRequest, ApiResult, EffectKind,
  ErrorActionInput, ErrorActionMapper, ErrorActionState, ErrorEffect, LocalRejectReason, MemorySessionTokens,
  NetworkHeaders, RcpRawResponse, RcpRequestSpec, RcpTransport, RefreshCompletion, RefreshCoordinator,
  RefreshRequest, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse
} from '../../Index';
import {
  Deferred, FakeRcpSender, Rig, envelope, flush, header, openLinkRequest, refreshScenario, tokenPair
} from './NetworkTestRig';

const WITHDRAW_BODY: string = '{"amount_cent":1000}';

function loginResponse(userId: string, access: string): TransportResponse {
  return envelope(0, '{"user_id":"' + userId + '","is_new_user":false,"tokens":' + tokenPair(access, access + '-r',
    'full') + '}');
}

function withdrawals(rig: Rig): TransportRequest[] {
  return rig.server.received.filter((r: TransportRequest) => r.url.indexOf('/v1/withdrawals') >= 0);
}

/** 清令牌时抛异常的令牌存储（模拟 Asset 存储删除失败，R1-04）。 */
class ThrowingClearTokens extends MemorySessionTokens {
  clear(): void {
    throw new Error('asset remove failed');
  }
}

function op(id: string): ApiOperation {
  return ApiOperations.byId(id) as ApiOperation;
}

function mapCode(code: number, operationId: string, data: Record<string, Object> = {},
  fromProductCard: boolean = true): ErrorEffect {
  return ErrorActionMapper.map(new ErrorActionInput(code, data, op(operationId), {}, false,
    new ErrorActionState('supported', 'full', '1.2.0'), fromProductCard));
}

export default function networkReviewR1Test() {
  describe('NetworkReviewR1', () => {
    // ---------------------------------------------------------------- R1-01
    it('r1_01_login_switch_does_not_replay_old_request_with_new_account', 0, async () => {
      const rig: Rig = new Rig();
      const hold: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/withdrawals') >= 0) {
          return hold.promise;
        }
        if (request.url.indexOf('/v1/auth/login/sms') >= 0) {
          return Promise.resolve(loginResponse('user-2', 'b-access'));
        }
        return Promise.resolve(envelope(0, tokenPair('refreshed', 'refreshed-r', 'full')));
      };
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY));
      await flush();
      const key: string = withdrawals(rig)[0].headers[NetworkHeaders.IDEMPOTENCY_KEY];
      const login: ApiResult = await rig.client.request(new ApiRequest('loginBySms', {}, '',
        '{"phone":"13800000000","code":"123456"}'));
      expect(login.ok).assertTrue();
      expect(rig.tokens.account()).assertEqual('user-2');
      hold.resolve(envelope(10002, '{}'));
      const result: ApiResult = await call;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      // 原提现请求体与幂等键没有带着 B 的令牌再发出，也没有为 A 去刷新 B 的会话。
      expect(withdrawals(rig).length).assertEqual(1);
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(0);
      expect(rig.server.received.filter((r: TransportRequest) =>
      header(r, NetworkHeaders.AUTHORIZATION) === 'Bearer b-access').length).assertEqual(0);
      // A 的未决记录按 A 结算（从未结果未知、拿到 10002 后不重放 → 删除），B 看不到。
      expect(rig.pendingBackend.read('user-1', key) === null).assertTrue();
      expect(rig.client.pendingFor('createWithdrawal') === null).assertTrue();
    });

    it('r1_01_token_of_another_account_saved_outside_client_is_not_reused', 0, async () => {
      const rig: Rig = new Rig();
      const hold: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      request.url.indexOf('/v1/me') >= 0 && header(request, NetworkHeaders.AUTHORIZATION) === 'Bearer old-access' ?
      hold.promise : Promise.resolve(envelope(0, '{}'));
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      // 登录流程以外换了账号（没有调用 onSessionChanged）：当前令牌不是本请求令牌刷新得来的。
      rig.tokens.save(new SessionTokenSet('c-access', 'c-refresh', 'full', 'user-3'));
      hold.resolve(envelope(10002, '{}'));
      const result: ApiResult = await call;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig.server.count('/v1/me')).assertEqual(1);
      expect(rig.client.refreshCalls).assertEqual(0);
    });

    // ---------------------------------------------------------------- R1-02
    it('r1_02_confirm_and_abandon_refuse_record_of_other_account', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login/sms') >= 0) {
          return Promise.resolve(loginResponse('user-2', 'b-access'));
        }
        if (request.url.indexOf('/v1/withdrawals') >= 0) {
          return Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
        }
        return Promise.resolve(envelope(0, '{"outcome":"abandoned"}'));
      };
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY));
      const key: string = first.idempotencyKey as string;
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      await rig.client.request(new ApiRequest('loginBySms', {}, '', '{"phone":"13800000000","code":"123456"}'));
      const sentBefore: number = rig.server.received.length;
      const confirm: ApiResult = await rig.client.confirmPending(key);
      expect(confirm.localRejectReason).assertEqual(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      const abandon: ApiResult = await rig.client.abandonPending(key);
      expect(abandon.localRejectReason).assertEqual(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      expect(rig.server.received.length).assertEqual(sentBefore);
      expect(rig.client.pendingState(key).stateRaw).assertEqual('none');
      // A 的记录原样保留（结果未知），等 A 重新登录。
      const kept = rig.pendingBackend.read('user-1', key);
      expect(kept !== null && kept.stateRaw === 'unknown').assertTrue();
    });

    it('r1_02_store_still_on_old_account_reports_account_mismatch', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY));
      const key: string = first.idempotencyKey as string;
      // 登录流程以外换成 B，PendingKeyStore 仍指向 A（评审复现的情形）。
      rig.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
      expect(rig.pending.currentAccount).assertEqual('user-1');
      const confirm: ApiResult = await rig.client.confirmPending(key);
      expect(confirm.localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_MISMATCH);
      const abandon: ApiResult = await rig.client.abandonPending(key);
      expect(abandon.localRejectReason === LocalRejectReason.ACCOUNT_MISMATCH
        || abandon.localRejectReason === LocalRejectReason.PENDING_KEY_UNRESOLVED).assertTrue();
      expect(rig.server.received.length).assertEqual(1);
      const kept = rig.pendingBackend.read('user-1', key);
      expect(kept !== null && kept.stateRaw === 'unknown').assertTrue();
      expect(rig.client.pendingState(key).stateRaw).assertEqual('none');
    });

    it('r1_02_confirm_in_flight_when_account_switches_settles_for_original_account', 0, async () => {
      const rig: Rig = new Rig();
      const hold: Deferred = new Deferred();
      let withdrawCalls: number = 0;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/withdrawals') >= 0) {
          withdrawCalls++;
          if (withdrawCalls === 1) {
            return Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
          }
          return withdrawCalls === 2 ? hold.promise : Promise.resolve(envelope(0, '{}'));
        }
        return Promise.resolve(envelope(0, tokenPair('refreshed', 'refreshed-r', 'full')));
      };
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY));
      const key: string = first.idempotencyKey as string;
      const confirm: Promise<ApiResult> = rig.client.confirmPending(key);
      await flush();
      expect(rig.pending.state(key).stateRaw).assertEqual('in_flight');
      // 确认在途时切到账号 B。
      rig.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
      rig.client.onSessionChanged();
      hold.resolve(envelope(10002, '{}'));
      const result: ApiResult = await confirm;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(withdrawCalls).assertEqual(2);
      // 结算绑定 A：A 的记录回到结果未知，不停在在途。
      const record = rig.pendingBackend.read('user-1', key);
      expect(record !== null && record.stateRaw === 'unknown').assertTrue();
      // 切回 A 后可以再确认。
      rig.tokens.save(new SessionTokenSet('a2-access', 'a2-refresh', 'full', 'user-1'));
      rig.client.onSessionChanged();
      expect(rig.client.pendingState(key).stateRaw).assertEqual('unknown');
      const again: ApiResult = await rig.client.confirmPending(key);
      expect(again.ok).assertTrue();
      expect(header(withdrawals(rig)[2], NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer a2-access');
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
    });

    // ---------------------------------------------------------------- R1-03
    it('r1_03_waiter_never_sends_old_token_after_refresh_failure', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      const orders: Promise<ApiResult> = rig.client.request(new ApiRequest('listOrders'));
      await flush();
      refresh.resolve(envelope(10404, '{}'));
      const waited: ApiResult = await orders;
      expect(waited.localRejectReason).assertEqual(LocalRejectReason.SESSION_CLEARED);
      expect((waited.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      expect(((await me).effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      // 订单请求一次都没发出；带旧令牌的只有最初的 getMe。
      expect(rig.server.count('/v1/orders')).assertEqual(0);
      expect(rig.server.received.filter((r: TransportRequest) =>
      header(r, NetworkHeaders.AUTHORIZATION) === 'Bearer old-access').length).assertEqual(1);
      expect(rig.tokens.clearCount).assertEqual(1);
      expect(rig.sessionEffects.length).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-04
    it('r1_04_cleanup_and_effect_exceptions_still_settle_every_waiter', 0, async () => {
      const store: ThrowingClearTokens =
        new ThrowingClearTokens(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      const rig: Rig = new Rig(null, null, store);
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      let settled: number = 0;
      const calls: Promise<ApiResult>[] = [rig.client.request(new ApiRequest('getMe')),
        rig.client.request(new ApiRequest('getWalletSummary'))];
      await flush();
      const waiter: Promise<ApiResult> = rig.client.request(new ApiRequest('listOrders'));
      await flush();
      refresh.resolve(envelope(10404, '{}'));
      const results: ApiResult[] = await Promise.all(calls);
      for (const result of results) {
        expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
        expect(result.failure).assertEqual('session_cleanup_failed');
        settled++;
      }
      const waited: ApiResult = await waiter;
      expect(waited.localRejectReason).assertEqual(LocalRejectReason.SESSION_CLEARED);
      expect(settled).assertEqual(2);
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(rig.server.count('/v1/orders')).assertEqual(0);
    });

    it('r1_04_throwing_session_effect_callback_does_not_lose_waiters', 0, async () => {
      const rig: Rig = new Rig();
      rig.throwOnSessionEffect = true;
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const calls: Promise<ApiResult>[] = [rig.client.request(new ApiRequest('getMe')),
        rig.client.request(new ApiRequest('listOrders'))];
      await flush();
      refresh.resolve(envelope(10404, '{}'));
      const results: ApiResult[] = await Promise.all(calls);
      expect(results.length).assertEqual(2);
      for (const result of results) {
        expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      }
      expect(rig.tokens.accessToken() === null).assertTrue();
      expect(rig.sessionEffects.length).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-05
    it('r1_05_confirm_ending_on_second_10002_returns_record_to_unknown', 0, async () => {
      const rig: Rig = new Rig();
      let withdrawCalls: number = 0;
      let refreshes: number = 0;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          refreshes++;
          return Promise.resolve(envelope(0, tokenPair('access-' + refreshes, 'refresh-' + refreshes, 'full')));
        }
        withdrawCalls++;
        if (withdrawCalls === 1) {
          return Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
        }
        return Promise.resolve(withdrawCalls <= 3 ? envelope(10002, '{}') : envelope(0, '{}'));
      };
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY));
      const key: string = first.idempotencyKey as string;
      const confirm: ApiResult = await rig.client.confirmPending(key);
      // 10002 → 刷新 → 同键重放 → 又 10002：调用结束（不再重放）。
      expect(withdrawCalls).assertEqual(3);
      expect((confirm.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.GENERIC_ERROR);
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      expect(rig.pendingBackend.read('user-1', key)?.stateRaw).assertEqual('unknown');
      // 回前台恢复后仍可确认，不会 pending_key_unresolved。
      rig.pending.restore('user-1');
      const again: ApiResult = await rig.client.confirmPending(key);
      expect(again.ok).assertTrue();
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
    });

    it('r1_05_10402_without_reregistration_returns_record_to_unknown', 0, async () => {
      const rig: Rig = new Rig();
      let withdrawCalls: number = 0;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        withdrawCalls++;
        return Promise.resolve(withdrawCalls === 1 ? TransportResponse.failed(TransportFailure.DISCONNECT) :
        envelope(10402, '{}'));
      };
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY));
      const key: string = first.idempotencyKey as string;
      await rig.client.confirmPending(key);
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      expect(rig.pending.confirm(key)).assertTrue();
    });

    // ---------------------------------------------------------------- R1-06
    it('r1_06_cold_start_restricted_session_refreshes_before_first_request', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ?
      envelope(0, tokenPair('fresh-access', 'fresh-refresh', 'full')) : envelope(0, '{}'));
      // 没有手动调用 refreshRestrictedSession：直接发请求。
      const me: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(me.ok).assertTrue();
      expect(rig.server.received[0].url.indexOf('/v1/auth/refresh') >= 0).assertTrue();
      expect(header(rig.server.received[1], NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer fresh-access');
      const orders: ApiResult = await rig.client.request(new ApiRequest('listOrders'));
      expect(orders.ok).assertTrue();
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(rig.server.received.filter((r: TransportRequest) =>
      header(r, NetworkHeaders.AUTHORIZATION) === 'Bearer old-access').length).assertEqual(0);
    });

    it('r1_06_restricted_barrier_failure_ends_call_without_old_token', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ? envelope(10404, '{}') : envelope(0, '{}'));
      const me: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(me.localRejectReason).assertEqual(LocalRejectReason.SESSION_CLEARED);
      expect((me.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      expect(rig.server.count('/v1/me')).assertEqual(0);
      expect(rig.tokens.accessToken() === null).assertTrue();
    });

    it('r1_06_force_update_recovery_triggers_restricted_refresh', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      rig.update.stateRaw = 'below';
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ?
      envelope(0, tokenPair('fresh-access', 'fresh-refresh', 'full')) : envelope(0, '{}'));
      // 强更状态「低于」：停在强更页，用受限令牌（注销入口），不刷新。
      await rig.client.request(new ApiRequest('getMe'));
      expect(rig.client.refreshCalls).assertEqual(0);
      expect(header(rig.server.last('/v1/me'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer old-access');
      // 升级 / 最低版本调低后复查为「不低于」：下一次请求前先刷新。
      rig.update.stateRaw = 'supported';
      const orders: ApiResult = await rig.client.request(new ApiRequest('listOrders'));
      expect(orders.ok).assertTrue();
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(header(rig.server.last('/v1/orders'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer fresh-access');
    });

    // ---------------------------------------------------------------- R1-07
    it('r1_07_refresh_failure_uses_force_update_state_at_settle', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      // 刷新期间版本检查进入强更。
      rig.update.stateRaw = 'below';
      refresh.resolve(envelope(10404, '{}'));
      const result: ApiResult = await call;
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE);
      expect((result.effect as ErrorEffect).route === null).assertTrue();
      expect(rig.sessionEffects[0].effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE);
    });

    it('r1_07_coordinator_reads_force_update_at_completion', 0, () => {
      let forceUpdate: boolean = false;
      let finish: RefreshCompletion = (_t: string | null) => {
      };
      const coordinator: RefreshCoordinator = new RefreshCoordinator(
        (completion: RefreshCompletion): void => {
          finish = completion;
        },
        (_r: RefreshRequest, _t: string): void => {
        },
        (): void => {
        },
        (): number => 0,
        (): boolean => forceUpdate);
      coordinator.run([new RefreshRequest('a', op('getMe'), '', '')], false);
      forceUpdate = true;
      finish(null);
      expect(coordinator.effectRaw).assertEqual(EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE);
    });

    // ---------------------------------------------------------------- R1-08
    it('r1_08_30144_refetches_product_and_link_landing_is_page_action', 0, async () => {
      const card: ErrorEffect = mapCode(30144, 'openLink');
      expect(card.effectKindRaw).assertEqual(EffectKind.REFETCH_PRODUCT);
      expect(card.replayRaw).assertEqual('none');
      expect(card.registerPending).assertFalse();
      expect(mapCode(30144, 'openLink', {}, false).effectKindRaw).assertEqual(EffectKind.PAGE_ACTION);
      expect(mapCode(30144, 'getLink').effectKindRaw).assertEqual(EffectKind.PAGE_ACTION);
      expect(mapCode(30144, 'getSharePage').effectKindRaw).assertEqual(EffectKind.PAGE_ACTION);
      // 管线：商品卡片的 openLink 收到 30144 → refetch_product，不自动重试、不自动外跳；LinkLanding 来的 → page_action。
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(30144, '{}'));
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.REFETCH_PRODUCT);
      const landing: ApiRequest = openLinkRequest();
      landing.fromProductCard = false;
      const fromLanding: ApiResult = await rig.client.request(landing);
      expect((fromLanding.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.PAGE_ACTION);
      expect(rig.server.received.length).assertEqual(2);
    });

    it('r1_08_30306_disables_withdraw_button', 0, () => {
      const effect: ErrorEffect = mapCode(30306, 'createWithdrawal');
      expect(effect.effectKindRaw).assertEqual(EffectKind.DISABLE_BUTTON);
      expect(effect.disableMillis).assertEqual(0);
      expect(effect.textKey).assertEqual('error.30306');
      expect(mapCode(30206, 'getMe').effectKindRaw).assertEqual(EffectKind.DISABLE_BUTTON);
    });

    it('r1_08_other_non_toast_actions_from_error_codes', 0, () => {
      const pageActions: number[] = [20902, 30103, 30104, 30121, 30132, 30141, 30151, 30153, 30302, 30309, 30408, 30411,
        30413, 30416, 30501, 30504, 30505, 30506, 30602, 30701, 30802, 30803, 30804, 44001, 44003, 50303, 50304, 50305];
      for (const code of pageActions) {
        const effect: ErrorEffect = mapCode(code, 'getMe');
        expect(code + ':' + effect.effectKindRaw).assertEqual(code + ':' + EffectKind.PAGE_ACTION);
        expect(effect.replayRaw).assertEqual('none');
      }
      // 带 reason 的同样按界面动作（不被「带 reason 只提示」吞掉）。
      const disabled: Record<string, Object> = {};
      disabled['reason'] = 'search_disabled';
      expect(mapCode(50304, 'searchProducts', disabled).effectKindRaw).assertEqual(EffectKind.PAGE_ACTION);
      const merge: Record<string, Object> = {};
      merge['reason'] = 'mergeable';
      expect(mapCode(30411, 'bindPhone', merge).effectKindRaw).assertEqual(EffectKind.PAGE_ACTION);
      expect(mapCode(40901, 'createWithdrawal').effectKindRaw).assertEqual(EffectKind.KEEP_LOADING);
      const cooling: Record<string, Object> = {};
      cooling['stage'] = 'cooling';
      const processing: Record<string, Object> = {};
      processing['stage'] = 'processing';
      expect(mapCode(10007, 'getMe', cooling).route).assertEqual('DeleteAccount');
      expect(mapCode(10007, 'getMe', processing).effectKindRaw).assertEqual(EffectKind.TOAST);
      // 原有判定不变：30101 auth_unavailable 只提示；30303 带 reason 仍是 Toast。
      const unavailable: Record<string, Object> = {};
      unavailable['reason'] = 'auth_unavailable';
      expect(mapCode(30101, 'openLink', unavailable).effectKindRaw).assertEqual(EffectKind.TOAST);
      expect(mapCode(30303, 'createWithdrawal').effectKindRaw).assertEqual(EffectKind.TOAST);
    });

    // ---------------------------------------------------------------- RCP 传输层（rule-gaps 编排者裁定）
    it('rcp_transport_does_not_follow_redirect', 0, async () => {
      const sender: FakeRcpSender = new FakeRcpSender();
      const location: Record<string, string> = {};
      location['location'] = 'https://elsewhere.test.invalid/steal';
      sender.reply = (_s: RcpRequestSpec): Promise<RcpRawResponse> =>
      Promise.resolve(new RcpRawResponse(302, location, ''));
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'),
        new RcpTransport(sender));
      const result: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      // 3xx 原样交回：没有统一外壳 → 网络错误；只发了一次，没有去 Location。
      expect(result.outcome).assertEqual(ApiOutcome.NETWORK_ERROR);
      expect(result.httpStatus).assertEqual(302);
      expect(sender.specs.length).assertEqual(1);
      expect(sender.specs[0].url).assertEqual('https://api.test.invalid/v1/me');
      const transfer = sender.specs[0].configuration.transfer;
      expect(transfer !== undefined && transfer.autoRedirect === false).assertTrue();
      expect(transfer?.timeout?.connectMs).assertEqual(10000);
      expect(transfer?.timeout?.transferMs).assertEqual(10000);
    });

    it('rcp_transport_keeps_timeouts_and_no_status_code_resend', 0, async () => {
      const sender: FakeRcpSender = new FakeRcpSender();
      const retryAfter: Record<string, string> = {};
      retryAfter['retry-after'] = '1';
      sender.reply = (_s: RcpRequestSpec): Promise<RcpRawResponse> =>
      Promise.resolve(new RcpRawResponse(503, retryAfter, '<html>busy</html>'));
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'),
        new RcpTransport(sender));
      const open: ApiResult = await rig.client.request(openLinkRequest());
      expect(open.outcome).assertEqual(ApiOutcome.NETWORK_ERROR);
      // 写请求 503 + Retry-After：传输层与管线都不重发。
      expect(sender.specs.length).assertEqual(1);
      expect(sender.specs[0].configuration.transfer?.timeout?.connectMs).assertEqual(8000);
      expect(sender.specs[0].configuration.transfer?.timeout?.transferMs).assertEqual(8000);
      expect(sender.specs[0].configuration.transfer?.autoRedirect).assertEqual(false);
      // RCP 超时错误码 → timeout；GET 只由管线重试 1 次。
      const timeoutError: BusinessError = { name: 'BusinessError', message: 'Timeout was reached', code: 1007900028 };
      sender.reply = (_s: RcpRequestSpec): Promise<RcpRawResponse> => Promise.reject(timeoutError);
      const me: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(me.failure).assertEqual(TransportFailure.TIMEOUT);
      expect(sender.specs.length).assertEqual(3);
      const direct: TransportResponse = await new RcpTransport(sender).send(new TransportRequest('GET',
        'https://api.test.invalid/v1/me', {}, null, 10000));
      expect(direct.failure).assertEqual(TransportFailure.TIMEOUT);
    });
  });
}
