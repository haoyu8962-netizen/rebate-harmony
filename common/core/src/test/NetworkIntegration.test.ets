// APP-03a 网络管线集成测试（任务书 §5 第 2 条与 cross-platform-r1-lessons 自查）：ApiClient 对本地假服务（可注入的传输接口），
// 不连任何真实地址。摘要原语用参考实现（Local Test 里 CryptoArchitectureKit 是空实现，见 TestDigest.ets）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiResult, ApiOutcome, ApiRequest, EffectKind, ErrorEffect, LocalRejectReason, NetworkHeaders, SessionTokenSet,
  SessionTokensCleaner, LocalDataCleanerRegistry, TransportFailure, TransportRequest, TransportResponse
} from '../../Index';
import {
  Deferred, Rig, envelope, flush, header, openLinkRequest, refreshScenario, tokenPair
} from './NetworkTestRig';

export default function networkIntegrationTest() {
  describe('NetworkIntegration', () => {
    it('five_concurrent_10002_share_one_refresh_and_all_replay', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const calls: Promise<ApiResult>[] = [
        rig.client.request(new ApiRequest('getMe')),
        rig.client.request(new ApiRequest('getWalletSummary')),
        rig.client.request(new ApiRequest('listOrders')),
        rig.client.request(openLinkRequest()),
        rig.client.request(openLinkRequest())
      ];
      await flush();
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      expect(rig.server.received.length).assertEqual(6);
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      const results: ApiResult[] = await Promise.all(calls);
      for (const result of results) {
        expect(result.ok).assertTrue();
      }
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(rig.server.received.length).assertEqual(11);
      expect(rig.tokens.refreshToken()).assertEqual('new-refresh');
      // 刷新请求签名、不带 Authorization；请求体是旧 refresh_token。
      const refreshRequest: TransportRequest = rig.server.last('/v1/auth/refresh');
      expect(header(refreshRequest, NetworkHeaders.AUTHORIZATION) === undefined).assertTrue();
      expect((header(refreshRequest, NetworkHeaders.SIGN) ?? '').length).assertEqual(64);
      expect(refreshRequest.body).assertEqual('{"refresh_token":"old-refresh"}');
      // 写请求重放沿用原键、原请求体，重新组头、重新签名（新 nonce，lessons R1-01）。
      const opens: TransportRequest[] = rig.server.received.filter((r: TransportRequest) => r.url.indexOf('/open') >= 0);
      expect(opens.length).assertEqual(4);
      const keys: string[] = opens.map((r: TransportRequest) => header(r, NetworkHeaders.IDEMPOTENCY_KEY) ?? '');
      const firstKeys: string[] = [keys[0], keys[1]].sort();
      const replayKeys: string[] = [keys[2], keys[3]].sort();
      expect(JSON.stringify(replayKeys)).assertEqual(JSON.stringify(firstKeys));
      expect(header(opens[2], NetworkHeaders.NONCE) !== header(opens[0], NetworkHeaders.NONCE)).assertTrue();
      expect(header(opens[2], NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer new-access');
    });

    it('late_10002_with_old_token_reuses_finished_refresh', 0, async () => {
      const rig: Rig = new Rig();
      const late: Deferred = new Deferred();
      let first: boolean = true;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
        }
        if (header(request, NetworkHeaders.AUTHORIZATION) === 'Bearer new-access') {
          return Promise.resolve(envelope(0, '{}'));
        }
        if (first) {
          // 第一个（慢）请求带旧令牌，响应晚到。
          first = false;
          return late.promise;
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      const slow: Promise<ApiResult> = rig.client.request(new ApiRequest('listOrders'));
      await flush();
      const fast: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(fast.ok).assertTrue();
      expect(rig.client.refreshCalls).assertEqual(1);
      late.resolve(envelope(10002, '{}'));
      expect((await slow).ok).assertTrue();
      expect(rig.client.refreshCalls).assertEqual(1);
    });

    it('refresh_failure_clears_session_once_and_routes_login', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const calls: Promise<ApiResult>[] = [rig.client.request(new ApiRequest('getMe')),
        rig.client.request(new ApiRequest('listOrders')), rig.client.request(new ApiRequest('getWalletSummary'))];
      await flush();
      refresh.resolve(envelope(10404, '{}'));
      const results: ApiResult[] = await Promise.all(calls);
      for (const result of results) {
        expect(result.ok).assertFalse();
        expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      }
      expect(rig.tokens.clearCount).assertEqual(1);
      expect(rig.sessionEffects.length).assertEqual(1);
      expect(rig.client.refreshCalls).assertEqual(1);
    });

    it('refresh_failure_in_force_update_stays', 0, async () => {
      const rig: Rig = new Rig();
      rig.update.stateRaw = 'below';
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      refresh.resolve(envelope(10404, '{}'));
      const result: ApiResult = await call;
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_STAY_FORCE_UPDATE);
      expect(rig.tokens.accessToken() === null).assertTrue();
    });

    it('late_refresh_after_withdrawal_is_discarded', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      SessionTokensCleaner.register(registry, rig.tokens, (): void => rig.client.invalidate());
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      await registry.cleanOnly(['session_tokens']);
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      const result: ApiResult = await call;
      expect(result.ok).assertFalse();
      expect(rig.tokens.accessToken() === null).assertTrue();
      expect(rig.server.count('/v1/me')).assertEqual(1);
    });

    it('get_timeout_retries_once_after_500ms_write_does_not', 0, async () => {
      const rig: Rig = new Rig();
      let getCalls: number = 0;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.method === 'GET') {
          getCalls++;
          return Promise.resolve(getCalls === 1 ? TransportResponse.failed(TransportFailure.TIMEOUT) : envelope(0, '{}'));
        }
        return Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      };
      const read: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(read.ok).assertTrue();
      expect(rig.server.count('/v1/me')).assertEqual(2);
      expect(rig.timer.delays.indexOf(500) >= 0).assertTrue();
      expect(rig.server.received[0].timeoutMillis).assertEqual(10000);
      const params: Record<string, string> = {};
      params['link_id'] = 'link-1';
      const write: ApiResult = await rig.client.request(new ApiRequest('dismissPendingTrack', params, '', '{}'));
      expect(write.outcome).assertEqual(ApiOutcome.NETWORK_ERROR);
      expect(write.failure).assertEqual(TransportFailure.TIMEOUT);
      expect(rig.server.count('/dismiss')).assertEqual(1);
    });

    it('get_disconnect_retries_once_then_fails', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      const read: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(read.failure).assertEqual(TransportFailure.DISCONNECT);
      expect(rig.server.count('/v1/me')).assertEqual(2);
    });

    it('retry_revalidates_privacy_before_resend', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      rig.timer.onBackoff = (): void => {
        rig.context.privacyRaw = 'basic';
      };
      const read: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(read.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
      // 隐私状态变了：调用归属失效，重试作废（harmony-review-r2 统一归属核对；lessons 1、25）。
      expect(read.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(rig.server.received.length).assertEqual(1);
    });

    it('retry_after_withdrawal_drops_credentials', 0, async () => {
      const rig: Rig = new Rig();
      let calls: number = 0;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        calls++;
        return Promise.resolve(calls === 1 ? TransportResponse.failed(TransportFailure.TIMEOUT) : envelope(0, '{}'));
      };
      rig.timer.onBackoff = (): void => {
        rig.context.readable = false;
      };
      const read: ApiResult = await rig.client.request(new ApiRequest('getConfig'));
      // 撤回同意（清理未完成）：作废在途请求和它的重试（lessons 1），重试不发出，更不会带凭据。
      expect(read.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(header(rig.server.received[0], NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer old-access');
      expect(rig.server.received.length).assertEqual(1);
      // 新发起的白名单请求照常匿名发出，不带任何凭据。
      const fresh: ApiResult = await rig.client.request(new ApiRequest('getConfig'));
      expect(fresh.ok).assertTrue();
      expect(header(rig.server.received[1], NetworkHeaders.AUTHORIZATION) === undefined).assertTrue();
      expect(header(rig.server.received[1], NetworkHeaders.DEVICE_ID) === undefined).assertTrue();
    });

    it('open_link_ends_after_8_seconds_without_retry', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => new Deferred().promise;
      const call: Promise<ApiResult> = rig.client.request(openLinkRequest());
      await flush();
      expect(rig.timer.delays.indexOf(8000) >= 0).assertTrue();
      expect(rig.server.received[0].timeoutMillis).assertEqual(8000);
      rig.timer.fire();
      const result: ApiResult = await call;
      expect(result.failure).assertEqual(TransportFailure.TIMEOUT);
      expect(rig.server.received.length).assertEqual(1);
    });

    it('basic_mode_sends_no_credentials_and_rejects_locally', 0, async () => {
      const rig: Rig = new Rig();
      rig.context.privacyRaw = 'basic';
      const search: ApiResult = await rig.client.request(new ApiRequest('searchProducts', {}, 'q=paper'));
      expect(search.ok).assertTrue();
      const sent: TransportRequest = rig.server.received[0];
      for (const name of [NetworkHeaders.AUTHORIZATION, NetworkHeaders.DEVICE_ID, NetworkHeaders.SIGN,
        NetworkHeaders.NONCE, NetworkHeaders.TIMESTAMP, NetworkHeaders.IDEMPOTENCY_KEY]) {
        expect(header(sent, name) === undefined).assertTrue();
      }
      expect(header(sent, NetworkHeaders.APP_ID)).assertEqual('couli');
      expect(sent.url).assertEqual('https://api.test.invalid/v1/products/search?q=paper');
      const open: ApiResult = await rig.client.request(openLinkRequest());
      expect(open.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
      expect(open.localRejectReason).assertEqual(LocalRejectReason.BASIC_MODE_DENIED);
      const version: ApiResult = await rig.client.request(new ApiRequest('checkAppVersion'));
      expect(version.localRejectReason).assertEqual(LocalRejectReason.BASIC_MODE_DENIED);
      expect(rig.server.received.length).assertEqual(1);
    });

    it('credentials_unreadable_uses_anonymous_allowlist', 0, async () => {
      const rig: Rig = new Rig();
      rig.context.readable = false;
      const register: ApiResult = await rig.client.request(new ApiRequest('registerDevice', {}, '', '{}'));
      expect(register.localRejectReason).assertEqual(LocalRejectReason.CREDENTIALS_UNREADABLE);
      const config: ApiResult = await rig.client.request(new ApiRequest('getConfig'));
      expect(config.ok).assertTrue();
      expect(header(rig.server.received[0], NetworkHeaders.AUTHORIZATION) === undefined).assertTrue();
      expect(rig.server.received.length).assertEqual(1);
    });

    it('environment_unsettled_sends_nothing', 0, async () => {
      const rig: Rig = new Rig();
      rig.context.settled = false;
      const result: ApiResult = await rig.client.request(new ApiRequest('getConfig'));
      expect(result.localRejectReason).assertEqual(LocalRejectReason.ENVIRONMENT_UNSETTLED);
      expect(rig.server.received.length).assertEqual(0);
    });

    it('signed_request_x_sign_matches_shared_vector', 0, async () => {
      // specs/request-sign.vectors.json valid_cases[0]：同一时间、nonce、install_secret、路径与请求体。
      const rig: Rig = new Rig();
      rig.random.nonces = ['b5a8f07b9dda63c3f78ed24c341d25b3'];
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect(result.ok).assertTrue();
      const sent: TransportRequest = rig.server.received[0];
      expect(sent.url).assertEqual('https://api.test.invalid/v1/links/abc/open?src=agent');
      expect(header(sent, NetworkHeaders.TIMESTAMP)).assertEqual('1790661600');
      expect(header(sent, NetworkHeaders.NONCE)).assertEqual('b5a8f07b9dda63c3f78ed24c341d25b3');
      expect(header(sent, NetworkHeaders.SIGN)).assertEqual('5715b672cfc2e52a082392ba4d6997110ae6f9583dc076c6ce8b8df0bc9eeb66');
      expect(header(sent, NetworkHeaders.DEVICE_ID)).assertEqual('device-fixture');
      expect((header(sent, NetworkHeaders.IDEMPOTENCY_KEY) ?? '').length > 0).assertTrue();
    });

    it('signed_request_without_device_is_rejected_locally', 0, async () => {
      const rig: Rig = new Rig();
      rig.credentials.device = null;
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect(result.localRejectReason).assertEqual(LocalRejectReason.DEVICE_NOT_READY);
      expect(rig.server.received.length).assertEqual(0);
    });

    it('10401_with_date_skew_resigns_once_with_new_nonce', 0, async () => {
      const rig: Rig = new Rig();
      const serverDate: string = new Date(rig.nowMillis + 3600 * 1000).toUTCString();
      let calls: number = 0;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        calls++;
        const headers: Record<string, string> = {};
        headers['date'] = serverDate;
        return Promise.resolve(calls === 1 ? envelope(10401, '{}', headers) : envelope(0, '{}'));
      };
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect(result.ok).assertTrue();
      expect(rig.server.received.length).assertEqual(2);
      const a: TransportRequest = rig.server.received[0];
      const b: TransportRequest = rig.server.received[1];
      expect(header(a, NetworkHeaders.NONCE) !== header(b, NetworkHeaders.NONCE)).assertTrue();
      expect(header(b, NetworkHeaders.TIMESTAMP)).assertEqual(String(1790661600 + 3600));
      expect(header(a, NetworkHeaders.IDEMPOTENCY_KEY)).assertEqual(header(b, NetworkHeaders.IDEMPOTENCY_KEY));
    });

    it('10401_without_date_does_not_resend', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10401, '{}'));
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.TOAST);
      expect(rig.server.received.length).assertEqual(1);
    });

    it('login_tokens_under_data_tokens_and_deletion_only_while_update_unknown', 0, async () => {
      const rig: Rig = new Rig(null);
      rig.update.stateRaw = 'unknown';
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0,
        '{"user_id":"0199a3b4-user","is_new_user":false,"tokens":' + tokenPair('login-access', 'login-refresh',
          'deletion_only') + '}'));
      const result: ApiResult = await rig.client.request(new ApiRequest('loginBySms', {}, '',
        '{"phone":"13800000000","code":"123456"}'));
      expect(result.ok).assertTrue();
      expect(rig.tokens.accessToken()).assertEqual('login-access');
      expect(rig.tokens.scope()).assertEqual('deletion_only');
      expect(rig.tokens.account()).assertEqual('0199a3b4-user');
      expect(rig.update.calls.length).assertEqual(1);
      expect(rig.update.calls[0] === null).assertTrue();
    });

    it('login_full_scope_while_supported_does_not_force_update', 0, async () => {
      const rig: Rig = new Rig(null);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0,
        '{"user_id":"u2","is_new_user":true,"tokens":' + tokenPair('a2', 'r2', 'full') + '}'));
      await rig.client.request(new ApiRequest('loginByHuawei', {}, '', '{}'));
      expect(rig.tokens.scope()).assertEqual('full');
      expect(rig.update.calls.length).assertEqual(0);
    });

    it('restricted_session_rejects_outside_table_and_body_conditions', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      // 冷启动的受限会话屏障（R1-06）先刷新一次；服务端仍给 deletion_only（账号在注销流程里）。
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ?
      envelope(0, tokenPair('still-restricted', 'still-restricted-r', 'deletion_only')) : envelope(0, '{}'));
      const orders: ApiResult = await rig.client.request(new ApiRequest('listOrders'));
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      expect(rig.tokens.scope()).assertEqual('deletion_only');
      expect(orders.localRejectReason).assertEqual(LocalRejectReason.SESSION_SCOPE_DENIED);
      const bind: ApiResult = await rig.client.request(new ApiRequest('sendSmsCode', {}, '',
        '{"phone":"13800000000","purpose":"bind"}'));
      expect(bind.localRejectReason).assertEqual(LocalRejectReason.SESSION_SCOPE_BODY_DENIED);
      const stepUpOther: ApiResult = await rig.client.request(new ApiRequest('sendSmsCode', {}, '',
        '{"phone":"13800000000","purpose":"step_up","action":"withdraw"}'));
      expect(stepUpOther.localRejectReason).assertEqual(LocalRejectReason.SESSION_SCOPE_BODY_DENIED);
      expect(rig.server.received.length).assertEqual(1);
      expect(rig.client.refreshCalls).assertEqual(1);
      const deletion: ApiResult = await rig.client.request(new ApiRequest('sendSmsCode', {}, '',
        '{"phone":"13800000000","purpose":"step_up","action":"account_deletion"}'));
      expect(deletion.ok).assertTrue();
      const consent: ApiResult = await rig.client.request(new ApiRequest('recordConsent', {}, '',
        '{"type":"personalization","version":1,"accepted":true,"channel":"privacy_center","client_at":"x"}'));
      expect(consent.localRejectReason).assertEqual(LocalRejectReason.SESSION_SCOPE_BODY_DENIED);
      const withdraw: ApiResult = await rig.client.request(new ApiRequest('recordConsent', {}, '',
        '{"type":"personalization","version":1,"accepted":false,"channel":"privacy_center","client_at":"x"}'));
      expect(withdraw.ok).assertTrue();
    });

    it('restricted_session_refresh_is_a_barrier_for_all_requests', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      const refresh: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      request.url.indexOf('/v1/auth/refresh') >= 0 ? refresh.promise : Promise.resolve(envelope(0, '{}'));
      const barrier: Promise<boolean> = rig.client.refreshRestrictedSession();
      const config: Promise<ApiResult> = rig.client.request(new ApiRequest('getConfig'));
      const orders: Promise<ApiResult> = rig.client.request(new ApiRequest('listOrders'));
      await flush();
      expect(rig.server.received.length).assertEqual(1);
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      expect(await barrier).assertTrue();
      expect((await config).ok).assertTrue();
      const listed: ApiResult = await orders;
      expect(listed.ok).assertTrue();
      expect(header(rig.server.last('/v1/orders'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer new-access');
    });

    it('10405_legacy_restricted_token_refresh_only_failure_routes_login', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      // 冷启动屏障的刷新仍给 deletion_only；之后 10405 的「只刷新」被拒绝。
      let refreshes: number = 0;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          refreshes++;
          return Promise.resolve(refreshes === 1 ?
          envelope(0, tokenPair('legacy-access', 'legacy-refresh', 'deletion_only')) : envelope(10404, '{}'));
        }
        return Promise.resolve(envelope(10405, '{"min_supported_version":"1.1.0"}'));
      };
      const result: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(header(rig.server.last('/v1/me'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer legacy-access');
      expect(refreshes).assertEqual(2);
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      expect(rig.update.calls.length).assertEqual(0);
      expect(rig.tokens.accessToken() === null).assertTrue();
    });

    it('10405_below_enters_force_update', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(10405, '{"min_supported_version":"1.3.0"}'));
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.FORCE_UPDATE);
      expect(rig.update.calls[0]).assertEqual('1.3.0');
    });

    it('step_up_operation_without_trusted_account_is_rejected', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', null));
      const result: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', '{"amount_cent":1000}'));
      expect(result.localRejectReason).assertEqual(LocalRejectReason.ACCOUNT_UNKNOWN);
      expect(rig.server.received.length).assertEqual(0);
    });

    it('unknown_then_10003_confirm_with_step_up_token_same_key_and_body', 0, async () => {
      const rig: Rig = new Rig();
      let calls: number = 0;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        calls++;
        if (calls === 1) {
          return Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
        }
        return Promise.resolve(calls === 2 ? envelope(10003, '{}') : envelope(0, '{}'));
      };
      const body: string = '{"amount_cent":1000}';
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', body));
      const key: string = first.idempotencyKey as string;
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      // 结果未知期间不能用新键提交。
      const another: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', body));
      expect(another.localRejectReason).assertEqual(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      const confirm: ApiResult = await rig.client.confirmPending(key);
      expect((confirm.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.STEP_UP);
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      const again: ApiResult = await rig.client.confirmPending(key, 'step-up-token');
      expect(again.ok).assertTrue();
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
      const last: TransportRequest = rig.server.received[2];
      expect(header(last, NetworkHeaders.STEP_UP_TOKEN)).assertEqual('step-up-token');
      expect(header(last, NetworkHeaders.IDEMPOTENCY_KEY)).assertEqual(key);
      expect(last.body).assertEqual(body);
    });

    it('confirm_rejected_locally_returns_to_unknown', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', '{}'));
      const key: string = first.idempotencyKey as string;
      rig.context.settled = false;
      const confirm: ApiResult = await rig.client.confirmPending(key);
      expect(confirm.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      expect(rig.server.received.length).assertEqual(1);
    });

    it('abandon_blocked_by_login_only_guides_and_stays_pending', 0, async () => {
      const rig: Rig = new Rig();
      let calls: number = 0;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        calls++;
        return Promise.resolve(calls === 1 ? TransportResponse.failed(TransportFailure.TIMEOUT) : envelope(10001, '{}'));
      };
      const first: ApiResult = await rig.client.request(new ApiRequest('requestDeletion', {}, '', '{}'));
      const key: string = first.idempotencyKey as string;
      const abandon: ApiResult = await rig.client.abandonPending(key);
      const effect: ErrorEffect = abandon.effect as ErrorEffect;
      expect(effect.effectKindRaw).assertEqual(EffectKind.GUIDE_ONLY);
      expect(effect.registerPending).assertFalse();
      expect(effect.replayRaw).assertEqual('none');
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      const abandonRequest: TransportRequest = rig.server.last('/v1/idempotency-keys/abandon');
      expect(header(abandonRequest, NetworkHeaders.IDEMPOTENCY_KEY) === undefined).assertTrue();
      expect(abandonRequest.body).assertEqual('{"action":"account_deletion","idempotency_key":"' + key + '"}');
    });

    it('abandon_outcomes_finish_or_keep_pending', 0, async () => {
      const rig: Rig = new Rig();
      let calls: number = 0;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        calls++;
        if (calls === 1) {
          return Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
        }
        if (calls === 2) {
          return Promise.resolve(envelope(40901, '{}'));
        }
        return Promise.resolve(envelope(0, '{"outcome":"completed","original":{"code":30303,"msg":"","data":{}}}'));
      };
      const first: ApiResult = await rig.client.request(new ApiRequest('createWithdrawal', {}, '', '{}'));
      const key: string = first.idempotencyKey as string;
      await rig.client.abandonPending(key);
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      await rig.client.abandonPending(key);
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
      expect(rig.pendingBackend.read('user-1', key) === null).assertTrue();
    });

    it('foreground_restore_keeps_in_flight_of_this_process', 0, async () => {
      const rig: Rig = new Rig();
      const hold: Deferred = new Deferred();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => hold.promise;
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('createWithdrawal', {}, '', '{}'));
      await flush();
      const record: string = rig.server.received[0].headers[NetworkHeaders.IDEMPOTENCY_KEY];
      rig.pending.restore('user-1');
      expect(rig.pending.state(record).stateRaw).assertEqual('in_flight');
      hold.resolve(envelope(0, '{}'));
      expect((await call).ok).assertTrue();
      expect(rig.pending.state(record).stateRaw).assertEqual('done');
    });

    it('withdrawal_invalidates_in_flight_request', 0, async () => {
      const rig: Rig = new Rig();
      const hold: Deferred = new Deferred();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => hold.promise;
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      rig.client.invalidate();
      hold.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      const result: ApiResult = await call;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(rig.server.received.length).assertEqual(1);
    });

    it('10402_reregisters_and_replays_once_then_falls_back', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10402, '{}'));
      const result: ApiResult = await rig.client.request(openLinkRequest());
      // APP-03b 之前没有设备注册：不重放，按兜底。
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.GENERIC_ERROR);
      expect(rig.server.received.length).assertEqual(1);
    });

    it('429_disables_button_by_retry_after', 0, async () => {
      const rig: Rig = new Rig();
      const headers: Record<string, string> = {};
      headers['retry-after'] = '7';
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(42901, '{}', headers));
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect((result.effect as ErrorEffect).disableMillis).assertEqual(7000);
      expect(result.trace6).assertEqual('123456');
    });
  });
}
