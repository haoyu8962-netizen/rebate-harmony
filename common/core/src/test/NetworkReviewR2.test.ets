// APP-03a 鸿蒙第 2 轮评审（harmony-review-r2.md）R2-01..R2-09、跨端清单 22–29，以及「所有自动续发路径同一套调用归属核对」
// 的回归测试：每条复现评审或清单里的失败场景。全部对本地假服务（可注入的传输接口 / RCP 发送层 / 存储），不连任何真实地址。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOperation, ApiOperations, ApiOutcome, ApiRequest, ApiResult, EffectKind, ErrorActionInput, ErrorActionMapper,
  ErrorActionState, ErrorEffect, HttpTransport, LocalRejectReason, MemoryPendingKeyBackend, MemorySecureStore,
  NetworkHeaders, PendingKeyRecord, PendingKeyStore, PendingResolution, PendingResponseKind, RcpRawResponse,
  RcpRequestSpec, RcpTransport, ReauthorizeIn, SecureEntry, SecurePendingKeyBackend, SessionTokenSet, TransportFailure,
  TransportRequest, TransportResponse
} from '../../Index';
import {
  Deferred, FakeRcpSender, Rig, envelope, flush, header, openLinkRequest, refreshScenario, tokenPair
} from './NetworkTestRig';

const WITHDRAW_BODY: string = '{"amount_cent":1000}';

function loginResponse(userId: string, access: string, scope: string = 'full'): TransportResponse {
  return envelope(0, '{"user_id":"' + userId + '","is_new_user":false,"tokens":' + tokenPair(access, access + '-r',
    scope) + '}');
}

function loginRequest(): ApiRequest {
  return new ApiRequest('loginBySms', {}, '', '{"phone":"13800000000","code":"123456"}');
}

function withdrawRequest(): ApiRequest {
  return new ApiRequest('createWithdrawal', {}, '', WITHDRAW_BODY);
}

function withdrawals(rig: Rig): TransportRequest[] {
  return rig.server.received.filter((r: TransportRequest) => r.url.indexOf('/v1/withdrawals') >= 0);
}

function withToken(rig: Rig, token: string): TransportRequest[] {
  return rig.server.received.filter((r: TransportRequest) =>
  header(r, NetworkHeaders.AUTHORIZATION) === 'Bearer ' + token);
}

function op(id: string): ApiOperation {
  return ApiOperations.byId(id) as ApiOperation;
}

function mapCode(code: number, operationId: string, data: Record<string, Object> = {},
  fromProductCard: boolean = true): ErrorEffect {
  return ErrorActionMapper.map(new ErrorActionInput(code, data, op(operationId), {}, false,
    new ErrorActionState('supported', 'full', '1.2.0'), fromProductCard));
}

/** 写入时可注入失败的未决记录存储（模拟 Asset 写失败，R2-05）。 */
class FlakyPendingBackend extends MemoryPendingKeyBackend {
  failWrites: boolean = false;

  write(record: PendingKeyRecord): void {
    if (this.failWrites) {
      throw new Error('asset add failed');
    }
    super.write(record);
  }
}

/** 记录每次从存储里读出的秘密值（R2-07：别的账号的请求体不得读出）。 */
class SpySecureStore extends MemorySecureStore {
  readonly returnedValues: string[] = [];
  wholeNamespaceReads: number = 0;

  entries(): SecureEntry[] {
    this.wholeNamespaceReads++;
    const out: SecureEntry[] = super.entries();
    for (const entry of out) {
      this.returnedValues.push(entry.value);
    }
    return out;
  }

  entriesInGroup(group: string): SecureEntry[] {
    const out: SecureEntry[] = super.entriesInGroup(group);
    for (const entry of out) {
      this.returnedValues.push(entry.value);
    }
    return out;
  }

  get(alias: string): string | null {
    const value: string | null = super.get(alias);
    if (value !== null) {
      this.returnedValues.push(value);
    }
    return value;
  }
}

/** 模拟「已交给传输层、还在等连接」：连上（open）之后才真正发出，发出前核对 admit（lessons 22）。 */
class ConnectingTransport implements HttpTransport {
  readonly sent: TransportRequest[] = [];
  accepted: number = 0;
  open: () => void = () => {
  };
  private readonly connected: Promise<void>;

  constructor() {
    this.connected = new Promise<void>((resolve: () => void) => {
      this.open = resolve;
    });
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    this.accepted++;
    return this.connected.then((): TransportResponse => {
      if (!request.admit()) {
        return TransportResponse.failed(TransportFailure.CANCELLED);
      }
      this.sent.push(request);
      return envelope(0, '{}');
    });
  }

  cancel(_request: TransportRequest): void {
  }
}

/** 一笔结果未知的提现（超时）。返回幂等键。 */
async function unknownWithdrawal(rig: Rig): Promise<string> {
  const previous = rig.server.handler;
  rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
  Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
  const first: ApiResult = await rig.client.request(withdrawRequest());
  rig.server.handler = previous;
  return first.idempotencyKey as string;
}

export default function networkReviewR2Test() {
  describe('NetworkReviewR2', () => {
    // ---------------------------------------------------------------- R2-01 / lessons 30（屏障后继续）
    it('r2_01_barrier_waiter_is_bound_before_waiting_and_never_sends_for_new_account', 0, async () => {
      const rig: Rig = new Rig();
      const loginHold: Deferred = new Deferred();
      const refreshHold: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return loginHold.promise;
        }
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return refreshHold.promise;
        }
        if (header(request, NetworkHeaders.AUTHORIZATION) === 'Bearer old-access') {
          return Promise.resolve(envelope(10002, '{}'));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const login: Promise<ApiResult> = rig.client.request(loginRequest());
      await flush();
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      // A 发起提现：带会话，在等 A 的刷新屏障。
      const withdraw: Promise<ApiResult> = rig.client.request(withdrawRequest());
      await flush();
      expect(withdrawals(rig).length).assertEqual(0);
      // 已在途的 B 登录成功。
      loginHold.resolve(loginResponse('user-2', 'b-access'));
      expect((await login).ok).assertTrue();
      expect(rig.tokens.account()).assertEqual('user-2');
      // B 的新请求不等 A 的旧刷新（旧刷新已与新会话脱钩）。
      const orders: ApiResult = await rig.client.request(new ApiRequest('listOrders'));
      expect(orders.ok).assertTrue();
      expect(header(rig.server.last('/v1/orders'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer b-access');
      // A 的刷新结束（判为 session_changed）：等待的提现结束，不改绑到 B。
      refreshHold.resolve(envelope(0, tokenPair('a-new', 'a-new-r', 'full')));
      const result: ApiResult = await withdraw;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(withdrawals(rig).length).assertEqual(0);
      expect(((await me).localRejectReason)).assertEqual(LocalRejectReason.SESSION_CHANGED);
      // A 的刷新结果没有写进 B 的会话。
      expect(rig.tokens.accessToken()).assertEqual('b-access');
    });

    // ---------------------------------------------------------------- R2-02 / lessons 31
    it('r2_02_restricted_login_while_unknown_refreshes_after_recovery_on_next_request', 0, async () => {
      const rig: Rig = new Rig(null);
      rig.update.stateRaw = 'unknown';
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return Promise.resolve(loginResponse('user-1', 'restricted', 'deletion_only'));
        }
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(0, tokenPair('fresh-access', 'fresh-refresh', 'full')));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      expect((await rig.client.request(loginRequest())).ok).assertTrue();
      expect(rig.update.calls.length).assertEqual(1);
      expect(rig.client.refreshCalls).assertEqual(0);
      // 强更期间没有任何网络调用；复查恢复为 supported。
      rig.update.stateRaw = 'supported';
      const orders: ApiResult = await rig.client.request(new ApiRequest('listOrders'));
      expect(orders.ok).assertTrue();
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(header(rig.server.last('/v1/orders'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer fresh-access');
    });

    it('r2_02_update_state_notification_starts_restricted_refresh', 0, async () => {
      const rig: Rig = new Rig(null);
      rig.update.stateRaw = 'unknown';
      const refresh: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return Promise.resolve(loginResponse('user-1', 'restricted', 'deletion_only'));
        }
        return request.url.indexOf('/v1/auth/refresh') >= 0 ? refresh.promise : Promise.resolve(envelope(0, '{}'));
      };
      await rig.client.request(loginRequest());
      rig.update.stateRaw = 'below';
      rig.client.onUpdateStateChanged();
      expect(rig.client.refreshCalls).assertEqual(0);
      rig.update.stateRaw = 'supported';
      rig.client.onUpdateStateChanged();
      // 状态变更通知本身就发起刷新屏障，不等下一个请求。
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      const orders: Promise<ApiResult> = rig.client.request(new ApiRequest('listOrders'));
      await flush();
      expect(rig.server.count('/v1/orders')).assertEqual(0);
      refresh.resolve(envelope(0, tokenPair('fresh-access', 'fresh-refresh', 'full')));
      expect((await orders).ok).assertTrue();
      expect(withToken(rig, 'restricted').length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R2-03 / lessons 31
    it('r2_03_restricted_refresh_timeout_ends_waiting_call_without_old_token', 0, async () => {
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'deletion_only', 'user-1'));
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ? TransportResponse.failed(TransportFailure.TIMEOUT) :
      envelope(0, '{}'));
      const me: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(me.outcome).assertEqual(ApiOutcome.NETWORK_ERROR);
      expect(me.failure).assertEqual('refresh_unavailable');
      expect((me.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.NETWORK_ERROR);
      expect(rig.server.count('/v1/me')).assertEqual(0);
      expect(withToken(rig, 'old-access').length).assertEqual(0);
      // 没有服务端结论：会话保留；下一个请求再做一次屏障。
      expect(rig.tokens.accessToken()).assertEqual('old-access');
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ?
      envelope(0, tokenPair('fresh-access', 'fresh-refresh', 'full')) : envelope(0, '{}'));
      expect((await rig.client.request(new ApiRequest('getMe'))).ok).assertTrue();
      expect(withToken(rig, 'old-access').length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R2-04 / lessons 27
    it('r2_04_abandon_completed_original_is_unwrapped_and_mapped', 0, async () => {
      const rig: Rig = new Rig();
      const key: string = await unknownWithdrawal(rig);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"outcome":"completed","original":{"code":30304,"msg":"需要实名"}}'));
      const result: ApiResult = await rig.client.abandonPending(key);
      expect(result.outcome).assertEqual(ApiOutcome.BUSINESS_ERROR);
      expect(result.code).assertEqual(30304);
      expect(result.ok).assertFalse();
      expect(result.pendingResolution).assertEqual(PendingResolution.COMPLETED);
      const effect: ErrorEffect = result.effect as ErrorEffect;
      expect(effect.effectKindRaw).assertEqual(EffectKind.GUIDE_ONLY);
      expect(effect.route).assertEqual('RealName');
      expect(effect.textKey).assertEqual('error.30304');
      // 3xxxx 原结果结束这个键。
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
    });

    it('r2_04_abandon_completed_success_and_abandoned_outcomes', 0, async () => {
      const rig: Rig = new Rig();
      const key: string = await unknownWithdrawal(rig);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"outcome":"completed","original":{"code":0,"msg":"","data":{"withdrawal_id":"w1"}}}'));
      const done: ApiResult = await rig.client.abandonPending(key);
      expect(done.ok).assertTrue();
      expect(done.effect === null).assertTrue();
      expect(done.data['withdrawal_id']).assertEqual('w1');
      expect(done.pendingResolution).assertEqual(PendingResolution.COMPLETED);
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
      const other: string = await unknownWithdrawal(rig);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"outcome":"abandoned","original":null}'));
      const abandoned: ApiResult = await rig.client.abandonPending(other);
      expect(abandoned.ok).assertTrue();
      expect(abandoned.pendingResolution).assertEqual(PendingResolution.ABANDONED);
      expect(rig.pending.state(other).stateRaw).assertEqual('done');
    });

    // ---------------------------------------------------------------- R2-05 / lessons 32
    it('r2_05_confirm_or_abandon_persist_failure_keeps_unknown_and_reports', 0, async () => {
      const backend: FlakyPendingBackend = new FlakyPendingBackend();
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'), null, null, backend);
      const key: string = await unknownWithdrawal(rig);
      const sentBefore: number = rig.server.received.length;
      backend.failWrites = true;
      const confirm: ApiResult = await rig.client.confirmPending(key);
      expect(confirm.localRejectReason).assertEqual(LocalRejectReason.PENDING_STORE_FAILED);
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      const abandon: ApiResult = await rig.client.abandonPending(key);
      expect(abandon.localRejectReason).assertEqual(LocalRejectReason.PENDING_STORE_FAILED);
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      expect(rig.server.received.length).assertEqual(sentBefore);
      // 存储恢复后可以照常确认（不会卡在在途、不会 pending_key_unresolved）。
      backend.failWrites = false;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0, '{}'));
      const again: ApiResult = await rig.client.confirmPending(key);
      expect(again.ok).assertTrue();
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
    });

    // ---------------------------------------------------------------- R2-06 / lessons 29
    it('r2_06_20001_outputs_field_hint_and_20004_reauthorize', 0, async () => {
      const fields: Record<string, Object> = {};
      fields['fields'] = ['amount_fen'];
      const field: ErrorEffect = mapCode(20001, 'createWithdrawal', fields);
      expect(field.effectKindRaw).assertEqual(EffectKind.FIELD_ERROR);
      expect(field.fields.length).assertEqual(1);
      expect(field.fields[0]).assertEqual('amount_fen');
      expect(field.textKey).assertEqual('error.20001');
      expect(field.replayRaw).assertEqual('none');
      const phone: Record<string, Object> = {};
      phone['fields'] = ['phone'];
      phone['reason'] = 'phone_invalid';
      expect(mapCode(20001, 'loginBySms', phone).textKey).assertEqual('error.20001.phone_invalid');
      const device: Record<string, Object> = {};
      device['fields'] = ['device_hash'];
      expect(mapCode(20001, 'loginBySms', device).textKey === null).assertTrue();
      const stepUp: ErrorEffect = mapCode(20004, 'stepUp');
      expect(stepUp.effectKindRaw).assertEqual(EffectKind.REAUTHORIZE);
      expect(stepUp.reauthorizeIn).assertEqual(ReauthorizeIn.STEP_UP);
      expect(stepUp.route === null).assertTrue();
      expect(stepUp.replayRaw).assertEqual('none');
      expect(stepUp.registerPending).assertFalse();
      const mismatch: Record<string, Object> = {};
      mismatch['reason'] = 'identity_mismatch';
      expect(mapCode(20004, 'stepUp', mismatch).textKey).assertEqual('error.20004.identity_mismatch');
      const wechat: ErrorEffect = mapCode(20004, 'loginByWechat');
      expect(wechat.effectKindRaw).assertEqual(EffectKind.REAUTHORIZE);
      expect(wechat.reauthorizeIn).assertEqual(ReauthorizeIn.LOGIN);
      expect(wechat.route).assertEqual('Login');
      // 管线：提现返回 20001 → 页面拿到字段提示动作。
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(20001, '{"fields":["amount_fen"]}'));
      const result: ApiResult = await rig.client.request(withdrawRequest());
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.FIELD_ERROR);
      expect((result.effect as ErrorEffect).fields[0]).assertEqual('amount_fen');
      expect(withdrawals(rig).length).assertEqual(1);
    });

    // ---------------------------------------------------------------- R2-07 / lessons 33
    it('r2_07_restore_reads_only_current_account_records_from_secure_store', 0, () => {
      const spy: SpySecureStore = new SpySecureStore();
      const backend: SecurePendingKeyBackend = new SecurePendingKeyBackend(spy);
      backend.write(new PendingKeyRecord('key-a', 'createWithdrawal', '{"payee":"A-SECRET-ACCOUNT"}', 'A', 'user-a', 1,
        'unknown', true));
      backend.write(new PendingKeyRecord('key-b', 'createWithdrawal', '{"payee":"B-ACCOUNT"}', 'B', 'user-b', 2,
        'unknown', true));
      const store: PendingKeyStore = new PendingKeyStore(backend, (): number => 0);
      store.restore('user-b');
      expect(store.pendingFor('createWithdrawal')?.key).assertEqual('key-b');
      expect(spy.wholeNamespaceReads).assertEqual(0);
      expect(spy.returnedValues.length > 0).assertTrue();
      for (const value of spy.returnedValues) {
        expect(value.indexOf('A-SECRET-ACCOUNT') < 0).assertTrue();
      }
      // A 重新登录后仍能取回自己的记录。
      store.restore('user-a');
      expect(store.pendingFor('createWithdrawal')?.key).assertEqual('key-a');
    });

    // ---------------------------------------------------------------- R2-08 / lessons 34
    it('r2_08_late_10404_of_old_account_does_not_clear_new_session', 0, async () => {
      const rig: Rig = new Rig();
      const hold: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return Promise.resolve(loginResponse('user-2', 'b-access'));
        }
        return request.url.indexOf('/v1/me') >= 0 ? hold.promise : Promise.resolve(envelope(0, '{}'));
      };
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect((await rig.client.request(loginRequest())).ok).assertTrue();
      hold.resolve(envelope(10404, '{}'));
      const result: ApiResult = await me;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(result.effect === null).assertTrue();
      expect(rig.tokens.accessToken()).assertEqual('b-access');
      expect(rig.tokens.clearCount).assertEqual(0);
      expect(rig.sessionEffects.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R2-09 / lessons 34
    it('r2_09_link_landing_30144_uses_link_landing_invalid_text', 0, () => {
      expect(mapCode(30144, 'getLink').textKey).assertEqual('link_landing.invalid');
      expect(mapCode(30144, 'getSharePage').textKey).assertEqual('link_landing.invalid');
      expect(mapCode(30144, 'openLink', {}, false).textKey).assertEqual('link_landing.invalid');
      const card: ErrorEffect = mapCode(30144, 'openLink');
      expect(card.effectKindRaw).assertEqual(EffectKind.REFETCH_PRODUCT);
      expect(card.textKey).assertEqual('error.30144');
    });

    // ---------------------------------------------------------------- 改名（编排者裁定）
    it('pending_key_unresolved_is_the_local_reject_reason', 0, async () => {
      expect(LocalRejectReason.PENDING_KEY_UNRESOLVED).assertEqual('pending_key_unresolved');
      const rig: Rig = new Rig();
      await unknownWithdrawal(rig);
      const another: ApiResult = await rig.client.request(withdrawRequest());
      expect(another.localRejectReason).assertEqual('pending_key_unresolved');
    });

    // ---------------------------------------------------------------- lessons 22
    it('l22_invalidate_cancels_request_waiting_in_rcp', 0, async () => {
      const sender: FakeRcpSender = new FakeRcpSender();
      sender.reply = (_s: RcpRequestSpec): Promise<RcpRawResponse> => new Promise<RcpRawResponse>(() => {
      });
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'),
        new RcpTransport(sender));
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect(sender.specs.length).assertEqual(1);
      rig.client.invalidate();
      const result: ApiResult = await call;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(sender.cancelled.length).assertEqual(1);
      expect(sender.cancelled[0]).assertEqual(sender.specs[0]);
      // 不重试。
      expect(sender.specs.length).assertEqual(1);
    });

    it('l22_transport_rechecks_ownership_right_before_sending', 0, async () => {
      const transport: ConnectingTransport = new ConnectingTransport();
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'), transport);
      const call: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect(transport.accepted).assertEqual(1);
      // 已交给传输层、还在等连接时撤回同意（清理器还没跑到 invalidate）。
      rig.context.readable = false;
      transport.open();
      const result: ApiResult = await call;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(transport.sent.length).assertEqual(0);
      // RCP 层：admit 不通过不交给 RCP。
      const sender: FakeRcpSender = new FakeRcpSender();
      const direct: TransportResponse = await new RcpTransport(sender).send(new TransportRequest('GET',
        'https://api.test.invalid/v1/me', {}, null, 10000, (): boolean => false));
      expect(direct.failure).assertEqual(TransportFailure.CANCELLED);
      expect(sender.specs.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- lessons 23
    it('l23_login_response_after_withdrawal_or_logout_is_dropped', 0, async () => {
      const rig: Rig = new Rig(null);
      const hold: Deferred = new Deferred();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => hold.promise;
      const login: Promise<ApiResult> = rig.client.request(loginRequest());
      await flush();
      rig.context.readable = false;
      hold.resolve(loginResponse('user-2', 'b-access'));
      expect((await login).localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(rig.tokens.accessToken() === null).assertTrue();
      // 登录在途时退出 / 换会话：迟到的登录响应同样丢弃。
      const rig2: Rig = new Rig();
      const hold2: Deferred = new Deferred();
      rig2.server.handler = (_r: TransportRequest): Promise<TransportResponse> => hold2.promise;
      const login2: Promise<ApiResult> = rig2.client.request(loginRequest());
      await flush();
      rig2.tokens.clear();
      rig2.client.onSessionChanged();
      hold2.resolve(loginResponse('user-2', 'b-access'));
      expect((await login2).localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig2.tokens.accessToken() === null).assertTrue();
      // 环境切换（invalidate）后到达的登录响应也丢弃。
      const rig3: Rig = new Rig(null);
      const hold3: Deferred = new Deferred();
      rig3.server.handler = (_r: TransportRequest): Promise<TransportResponse> => hold3.promise;
      const login3: Promise<ApiResult> = rig3.client.request(loginRequest());
      await flush();
      rig3.client.invalidate();
      hold3.resolve(loginResponse('user-2', 'b-access'));
      expect((await login3).localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(rig3.tokens.accessToken() === null).assertTrue();
    });

    // ---------------------------------------------------------------- lessons 24
    it('l24_refresh_uses_snapshot_fixed_at_enqueue', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect(rig.server.last('/v1/auth/refresh').body).assertEqual('{"refresh_token":"old-refresh"}');
      // 刷新执行期间，登录流程以外换成了另一个账号：结算按入队快照判为过期，不写进别的账号。
      rig.tokens.save(new SessionTokenSet('c-access', 'c-refresh', 'full', 'user-3'));
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      const result: ApiResult = await me;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig.tokens.accessToken()).assertEqual('c-access');
      expect(rig.tokens.account()).assertEqual('user-3');
      expect(rig.server.count('/v1/me')).assertEqual(1);
    });

    // ---------------------------------------------------------------- lessons 25（GET 重试）
    it('path_get_retry_after_account_switch_is_not_sent', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      rig.timer.onBackoff = (): void => {
        rig.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
        rig.client.onSessionChanged();
      };
      const result: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig.server.count('/v1/me')).assertEqual(1);
      expect(withToken(rig, 'b-access').length).assertEqual(0);
      // 登录流程以外换账号（没有通知）同样不重试。
      const rig2: Rig = new Rig();
      rig2.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.TIMEOUT));
      rig2.timer.onBackoff = (): void => {
        rig2.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
      };
      const result2: ApiResult = await rig2.client.request(new ApiRequest('getMe'));
      expect(result2.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig2.server.count('/v1/me')).assertEqual(1);
    });

    // ---------------------------------------------------------------- 10002 重放
    it('path_10002_replay_after_withdrawal_is_not_sent', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      // 刷新期间撤回同意（清理器还没调 invalidate）。
      rig.context.readable = false;
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      const result: ApiResult = await me;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      expect(rig.server.count('/v1/me')).assertEqual(1);
      expect(withToken(rig, 'new-access').length).assertEqual(0);
      // 刷新结果晚于撤回：丢弃，不把会话写回。
      expect(rig.tokens.accessToken()).assertEqual('old-access');
    });

    // ---------------------------------------------------------------- 10402 重放
    it('path_10402_replay_after_account_switch_is_not_sent', 0, async () => {
      const rig: Rig = new Rig();
      let register: (ok: boolean) => void = (_ok: boolean) => {
      };
      rig.registrar.result = () => new Promise<boolean>((resolve: (ok: boolean) => void) => {
        register = resolve;
      });
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(10402, '{}'));
      const call: Promise<ApiResult> = rig.client.request(withdrawRequest());
      await flush();
      expect(rig.registrar.calls).assertEqual(1);
      const key: string = withdrawals(rig)[0].headers[NetworkHeaders.IDEMPOTENCY_KEY];
      // 重新注册期间仍占用这个键（内部续发，lessons 26）。
      expect(rig.pending.state(key).stateRaw).assertEqual('in_flight');
      rig.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
      rig.client.onSessionChanged();
      register(true);
      const result: ApiResult = await call;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(withdrawals(rig).length).assertEqual(1);
      // A 的记录按 A 结算（从未结果未知 → 删除）。
      expect(rig.pendingBackend.read('user-1', key) === null).assertTrue();
    });

    // ---------------------------------------------------------------- 10401 校时重签
    it('path_10401_resign_after_account_switch_is_not_sent', 0, async () => {
      const rig: Rig = new Rig();
      const serverDate: string = new Date(rig.nowMillis + 3600 * 1000).toUTCString();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        // 响应回来之前换了账号。
        rig.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
        rig.client.onSessionChanged();
        const headers: Record<string, string> = {};
        headers['date'] = serverDate;
        return Promise.resolve(envelope(10401, '{}', headers));
      };
      const result: ApiResult = await rig.client.request(openLinkRequest());
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig.server.received.length).assertEqual(1);
    });

    // ---------------------------------------------------------------- 确认未决 + 屏障
    it('path_confirm_waiting_barrier_is_dropped_after_account_switch', 0, async () => {
      const rig: Rig = new Rig();
      const key: string = await unknownWithdrawal(rig);
      const refresh: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return Promise.resolve(loginResponse('user-2', 'b-access'));
        }
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        if (request.url.indexOf('/v1/me') >= 0 && header(request, NetworkHeaders.AUTHORIZATION) === 'Bearer old-access') {
          return Promise.resolve(envelope(10002, '{}'));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      const confirm: Promise<ApiResult> = rig.client.confirmPending(key);
      await flush();
      expect(rig.pending.state(key).stateRaw).assertEqual('in_flight');
      expect((await rig.client.request(loginRequest())).ok).assertTrue();
      refresh.resolve(envelope(0, tokenPair('a-new', 'a-new-r', 'full')));
      const result: ApiResult = await confirm;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      await me;
      // 只有最初那次提现；确认没有替 B 发出。A 的记录回到结果未知。
      expect(withdrawals(rig).length).assertEqual(1);
      const record = rig.pendingBackend.read('user-1', key);
      expect(record !== null && record.stateRaw === 'unknown').assertTrue();
    });

    // ---------------------------------------------------------------- lessons 26
    it('l26_pending_hold_is_bound_to_call_id', 0, () => {
      const store: PendingKeyStore = new PendingKeyStore(new MemoryPendingKeyBackend(), (): number => 0);
      store.coldStart('u');
      expect(store.beforeSend('createWithdrawal', 'k1', WITHDRAW_BODY, 'u', '', 1)).assertTrue();
      store.onResponse('k1', PendingResponseKind.NO_ENVELOPE, 'u', 1);
      expect(store.state('k1').stateRaw).assertEqual('unknown');
      expect(store.confirm('k1', 2)).assertTrue();
      expect(store.holderOf('k1')).assertEqual(2);
      // 旧调用（1）的收尾与迟到结局不得释放新调用（2）持有的占用。
      store.settleIfInFlight('k1', 'u', 1);
      store.onResponse('k1', PendingResponseKind.NO_ENVELOPE, 'u', 1);
      expect(store.state('k1').stateRaw).assertEqual('in_flight');
      expect(store.holderOf('k1')).assertEqual(2);
      // 别的调用不能借用在途的同一个键。
      expect(store.beforeSend('createWithdrawal', 'k1', WITHDRAW_BODY, 'u', '', 3)).assertFalse();
      store.settleIfInFlight('k1', 'u', 2);
      expect(store.state('k1').stateRaw).assertEqual('unknown');
      expect(store.holderOf('k1') === null).assertTrue();
    });

    it('l26_pending_key_stays_held_during_internal_refresh_replay', 0, async () => {
      const rig: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig, refresh);
      const first: Promise<ApiResult> = rig.client.request(withdrawRequest());
      await flush();
      const key: string = withdrawals(rig)[0].headers[NetworkHeaders.IDEMPOTENCY_KEY];
      expect(rig.pending.state(key).stateRaw).assertEqual('in_flight');
      expect(rig.pending.holderOf(key) !== null).assertTrue();
      // 刷新期间同账号再提交一笔（新键）：上一笔仍在途，本地拒绝。
      const second: Promise<ApiResult> = rig.client.request(withdrawRequest());
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      expect((await first).ok).assertTrue();
      expect((await second).localRejectReason).assertEqual(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      expect(withdrawals(rig).length).assertEqual(2);
      for (const sent of withdrawals(rig)) {
        expect(sent.headers[NetworkHeaders.IDEMPOTENCY_KEY]).assertEqual(key);
      }
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
    });

    // ---------------------------------------------------------------- lessons 28
    it('l28_login_and_refresh_read_latest_force_update_state', 0, async () => {
      const rig: Rig = new Rig(null);
      const hold: Deferred = new Deferred();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => hold.promise;
      const login: Promise<ApiResult> = rig.client.request(loginRequest());
      await flush();
      // 发出登录时是 supported，处理响应时强更检查变成未知。
      rig.update.stateRaw = 'unknown';
      hold.resolve(loginResponse('user-1', 'restricted', 'deletion_only'));
      expect((await login).ok).assertTrue();
      expect(rig.update.calls.length).assertEqual(1);
      // 普通刷新同样按处理响应那一刻的状态。
      const rig2: Rig = new Rig();
      const refresh: Deferred = new Deferred();
      refreshScenario(rig2, refresh);
      const me: Promise<ApiResult> = rig2.client.request(new ApiRequest('getMe'));
      await flush();
      rig2.update.stateRaw = 'unknown';
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'deletion_only')));
      await me;
      expect(rig2.update.calls.length).assertEqual(1);
    });
  });
}
