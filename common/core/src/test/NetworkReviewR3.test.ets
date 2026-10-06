// APP-03a 鸿蒙第 3 轮评审（harmony-review-r3.md）R3-01..R3-04 与跨端清单 35–40 的回归测试：每条复现评审或清单里的
// 失败场景。全部对本地假服务（可注入的传输接口 / 存储 / 强更检查器），不连任何真实地址。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiOutcome, ApiRequest, ApiResult, CleanReport, EffectKind, ErrorEffect, LocalDataCleaner, LocalDataCleanerRegistry,
  LocalRejectReason, MemoryPendingKeyBackend, MemorySecureStore, MemorySessionTokens, MemoryUpdateStore,
  NetworkComposition, NetworkHeaders, PendingKeyRecord, PendingKeyStore, PendingStoreError, PrivacyState, PrivacyWithdrawalCleaners, ReplayKind,
  SecurePendingKeyBackend, SecureSessionTokens, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse,
  UpdateCheckCoordinator, UpdateCheckOutcome, UpdateChecker, UpdateCheckResult, UpdateGate, UpdateNetworkPort,
  UpdateStoreListing
} from '../../Index';
import { Deferred, Rig, envelope, flush, header, tokenPair } from './NetworkTestRig';

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

/** 读、删可注入失败的未决记录存储（模拟 Asset 查询 / 删除失败，R3-01、R3-03）。 */
class FlakyPendingBackend extends MemoryPendingKeyBackend {
  failLists: boolean = false;
  failRemoves: boolean = false;
  listCalls: number = 0;

  list(account: string): PendingKeyRecord[] {
    this.listCalls++;
    if (this.failLists) {
      throw new Error('asset query failed');
    }
    return super.list(account);
  }

  remove(account: string, key: string): void {
    if (this.failRemoves) {
      throw new Error('asset remove failed');
    }
    super.remove(account, key);
  }
}

/** 删除可注入失败的安全存储（清会话时删除失败，lessons 38）。 */
class FlakySecureStore extends MemorySecureStore {
  failRemoves: boolean = false;

  remove(alias: string): void {
    if (this.failRemoves) {
      throw new Error('asset remove failed');
    }
    super.remove(alias);
  }
}

/** 保存可注入失败的令牌存储（登录令牌写不进安全存储，lessons 40）。 */
class FailingSaveTokens extends MemorySessionTokens {
  failSaves: boolean = false;

  save(tokens: SessionTokenSet): void {
    if (this.failSaves) {
      throw new Error('asset add failed');
    }
    super.save(tokens);
  }
}

/** 手动应答的强更检查器。 */
class ManualChecker implements UpdateChecker {
  private resolvers: ((o: UpdateCheckOutcome) => void)[] = [];

  check(): Promise<UpdateCheckOutcome> {
    return new Promise<UpdateCheckOutcome>((resolve: (o: UpdateCheckOutcome) => void) => {
      this.resolvers.push(resolve);
    });
  }

  async respond(result: UpdateCheckResult): Promise<void> {
    const resolve: ((o: UpdateCheckOutcome) => void) | undefined = this.resolvers.shift();
    if (resolve !== undefined) {
      resolve(UpdateCheckOutcome.success(result));
    }
    await flush();
  }
}

/** 记录执行时刻状态的清理器（lessons 35：invalidate 必须先于它执行）。 */
class ObservingCleaner implements LocalDataCleaner {
  readonly name: string;
  private readonly observe: () => void;

  constructor(name: string, observe: () => void) {
    this.name = name;
    this.observe = observe;
  }

  clean(): Promise<void> {
    this.observe();
    return Promise.resolve();
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

function supportedResult(): UpdateCheckResult {
  return new UpdateCheckResult('1.0.0', null, '1.2.0', 'huawei', [new UpdateStoreListing('huawei', '1.2.0')], 1800);
}

function belowResult(): UpdateCheckResult {
  return new UpdateCheckResult('1.3.0', null, '1.3.0', 'huawei', [new UpdateStoreListing('huawei', '1.3.0')], 1800);
}

export default function networkReviewR3Test() {
  describe('NetworkReviewR3', () => {
    // ---------------------------------------------------------------- R3-01 / lessons 38
    it('r3_01_restore_read_failure_blocks_new_key_until_records_are_read', 0, async () => {
      const backend: FlakyPendingBackend = new FlakyPendingBackend();
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'), null, null, backend);
      const key: string = await unknownWithdrawal(rig);
      // 退出，再以同一账号登录；登录那一刻恢复未决记录的查询失败。
      rig.tokens.clear();
      rig.client.onSessionChanged();
      backend.failLists = true;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/login') >= 0 ? loginResponse('user-1', 'a2') : envelope(0, '{}'));
      expect((await rig.client.request(loginRequest())).ok).assertTrue();
      expect(rig.pending.recoveryPending).assertTrue();
      expect(rig.client.pendingStoreUnavailable()).assertTrue();
      const sentBefore: number = withdrawals(rig).length;
      const listsBefore: number = backend.listCalls;
      // 读取失败不是「没有记录」：新键提交、确认、放弃都本地拒绝，且每次调用都重试读取。
      const second: ApiResult = await rig.client.request(withdrawRequest());
      expect(second.localRejectReason).assertEqual(LocalRejectReason.PENDING_STORE_FAILED);
      expect(backend.listCalls > listsBefore).assertTrue();
      expect((await rig.client.confirmPending(key)).localRejectReason).assertEqual(LocalRejectReason.PENDING_STORE_FAILED);
      expect((await rig.client.abandonPending(key)).localRejectReason).assertEqual(LocalRejectReason.PENDING_STORE_FAILED);
      expect(withdrawals(rig).length).assertEqual(sentBefore);
      // 存储恢复：下一次调用读出旧的未知键，新键照样被拦，只能确认原键。
      backend.failLists = false;
      const third: ApiResult = await rig.client.request(withdrawRequest());
      expect(third.localRejectReason).assertEqual(LocalRejectReason.PENDING_KEY_UNRESOLVED);
      expect(rig.pending.recoveryPending).assertFalse();
      expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      expect(withdrawals(rig).length).assertEqual(sentBefore);
      const confirm: ApiResult = await rig.client.confirmPending(key);
      expect(confirm.ok).assertTrue();
      const keys: string[] = withdrawals(rig).map((r: TransportRequest) => header(r, NetworkHeaders.IDEMPOTENCY_KEY) ?? '');
      expect(keys.every((k: string) => k === key)).assertTrue();
    });

    it('l38_corrupt_pending_record_is_not_treated_as_no_record', 0, () => {
      const secure: MemorySecureStore = new MemorySecureStore();
      secure.setGrouped(SecurePendingKeyBackend.group('user-1'), 'pending_key:user-1:broken', '{not json');
      const backend: SecurePendingKeyBackend = new SecurePendingKeyBackend(secure);
      const store: PendingKeyStore = new PendingKeyStore(backend, (): number => 0);
      let restoreFailed: boolean = false;
      try {
        store.coldStart('user-1');
      } catch (e) {
        restoreFailed = e instanceof PendingStoreError;
      }
      expect(restoreFailed).assertTrue();
      expect(store.recoveryPending).assertTrue();
      // 损坏的记录无法确认未决状态：新提交在写记录之前就失败（管线里返回 pending_store_failed，见 r3_01）。
      let blocked: boolean = false;
      try {
        store.beforeSend('createWithdrawal', 'new-key', WITHDRAW_BODY, 'user-1');
      } catch (e) {
        blocked = e instanceof PendingStoreError;
      }
      expect(blocked).assertTrue();
      expect(secure.entriesInGroup(SecurePendingKeyBackend.group('user-1')).length).assertEqual(1);
      let readFailed: boolean = false;
      try {
        backend.read('user-1', 'broken');
      } catch (e) {
        readFailed = e instanceof PendingStoreError;
      }
      expect(readFailed).assertTrue();
    });

    // ---------------------------------------------------------------- R3-02
    it('r3_02_refresh_failure_does_not_clear_session_switched_before_settling', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          // 刷新结论（10404）定下之后、完成流程清会话之前，B 登录成功并保存了令牌。
          rig.onClock = (): void => {
            rig.tokens.save(new SessionTokenSet('b-access', 'b-refresh', 'full', 'user-2'));
            rig.client.onSessionChanged();
          };
          return Promise.resolve(envelope(10404, '{}'));
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      const result: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig.tokens.accessToken()).assertEqual('b-access');
      expect(rig.tokens.account()).assertEqual('user-2');
      expect(rig.tokens.clearCount).assertEqual(0);
      expect(rig.sessionEffects.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R3-03
    it('r3_03_terminal_remove_failure_leaves_no_ownerless_in_flight_and_retries', 0, async () => {
      const backend: FlakyPendingBackend = new FlakyPendingBackend();
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'), null, null, backend);
      const key: string = await unknownWithdrawal(rig);
      backend.failRemoves = true;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"withdrawal_id":"w1"}'));
      const confirm: ApiResult = await rig.client.confirmPending(key);
      expect(confirm.ok).assertTrue();
      // 内存里已终结，没有留下没有持有者的在途；持久删除记为清理待重试。
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
      expect(rig.pending.holderOf(key) === null).assertTrue();
      expect(rig.pending.cleanupPendingFor('user-1')).assertTrue();
      expect(backend.read('user-1', key) !== null).assertTrue();
      // 删除仍失败：该账号的敏感操作本地拒绝（pending_store_failed），不发送。
      const sentBefore: number = withdrawals(rig).length;
      const blocked: ApiResult = await rig.client.request(withdrawRequest());
      expect(blocked.localRejectReason).assertEqual(LocalRejectReason.PENDING_STORE_FAILED);
      expect(withdrawals(rig).length).assertEqual(sentBefore);
      // 存储恢复：下一次调用先重试删除，然后照常用新键提交（不再是 pending_key_unresolved）。
      backend.failRemoves = false;
      const next: ApiResult = await rig.client.request(withdrawRequest());
      expect(next.ok).assertTrue();
      expect(next.idempotencyKey !== key).assertTrue();
      expect(backend.read('user-1', key) === null).assertTrue();
      expect(rig.pending.cleanupPendingFor('user-1')).assertFalse();
    });

    // ---------------------------------------------------------------- R3-04 / lessons 35
    it('r3_04_real_update_notification_chain_starts_restricted_refresh', 0, async () => {
      const now: number = 1790661600 * 1000;
      const gate: UpdateGate = new UpdateGate(new MemoryUpdateStore(), (): number => now, '1.2.0', 'harmony', 'agc', null);
      const checker: ManualChecker = new ManualChecker();
      const coordinator: UpdateCheckCoordinator = new UpdateCheckCoordinator(gate, checker, (): number => now);
      coordinator.environmentSettled = (): boolean => true;
      coordinator.privacy = (): PrivacyState => PrivacyState.CONSENTED;
      // 生产接线：UpdatePort 读强更结论、确需强更调 on10405；返回的处理函数就是 AppUpdate.onChanged。
      const port: UpdateNetworkPort = new UpdateNetworkPort(() => coordinator.inAppUpdate(),
        (minSupported: string | null): void => gate.on10405(minSupported, now));
      const rig: Rig = new Rig(null, null, null, null, port);
      let routed: number = 0;
      const onChanged: () => void = NetworkComposition.install(rig.client, new LocalDataCleanerRegistry(),
        (): void => {
          routed++;
        });
      // AppUpdate.refresh(notify)：检查开始 / 结束（notify）时回调 onChanged。
      coordinator.changed = (notify: boolean): void => {
        if (notify) {
          onChanged();
        }
      };
      const refresh: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return Promise.resolve(loginResponse('user-1', 'restricted', 'deletion_only'));
        }
        return request.url.indexOf('/v1/auth/refresh') >= 0 ? refresh.promise : Promise.resolve(envelope(0, '{}'));
      };
      coordinator.syncPrivacy(true);
      await checker.respond(supportedResult());
      expect(port.state()).assertEqual('supported');
      expect((await rig.client.request(loginRequest())).ok).assertTrue();
      // 之后的检查经历 below 再恢复 supported，期间没有任何业务请求。
      coordinator.recheck(false);
      await checker.respond(belowResult());
      expect(port.state()).assertEqual('below');
      expect(rig.client.refreshCalls).assertEqual(0);
      coordinator.recheck(false);
      await checker.respond(supportedResult());
      expect(port.state()).assertEqual('supported');
      expect(routed > 0).assertTrue();
      // 真实通知链本身就发起了受限会话刷新屏障（测试没有调用 onUpdateStateChanged）。
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(rig.server.count('/v1/auth/refresh')).assertEqual(1);
      const orders: Promise<ApiResult> = rig.client.request(new ApiRequest('listOrders'));
      await flush();
      expect(rig.server.count('/v1/orders')).assertEqual(0);
      refresh.resolve(envelope(0, tokenPair('fresh-access', 'fresh-refresh', 'full')));
      const result: ApiResult = await orders;
      expect(result.ok).assertTrue();
      expect(header(rig.server.last('/v1/orders'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer fresh-access');
    });

    it('r3_04_force_update_from_network_reaches_update_module', 0, async () => {
      const now: number = 1790661600 * 1000;
      const gate: UpdateGate = new UpdateGate(new MemoryUpdateStore(), (): number => now, '1.2.0', 'harmony', 'agc', null);
      const coordinator: UpdateCheckCoordinator = new UpdateCheckCoordinator(gate, new ManualChecker(), (): number => now);
      const port: UpdateNetworkPort = new UpdateNetworkPort(() => coordinator.inAppUpdate(),
        (minSupported: string | null): void => gate.on10405(minSupported, now));
      const rig: Rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'), null, null, null, port);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(10405, '{"min_supported_version":"1.5.0"}'));
      const result: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.FORCE_UPDATE);
      expect(port.state()).assertEqual('below');
      expect(gate.state(now).statusRaw).assertEqual('below_min');
    });

    it('l35_invalidate_runs_first_in_withdrawal_and_environment_cleanup', 0, async () => {
      for (const withdrawal of [true, false]) {
        const rig: Rig = new Rig();
        const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
        let cancelledWhenTokensCleared: number = -1;
        // 令牌清理项先于网络接线登记，invalidate 仍然最先执行。
        registry.register(new ObservingCleaner(PrivacyWithdrawalCleaners.SESSION_TOKENS, () => {
          cancelledWhenTokensCleared = rig.server.cancelled.length;
          rig.tokens.clear();
        }));
        PrivacyWithdrawalCleaners.registerPlaceholders(registry);
        NetworkComposition.install(rig.client, registry, (): void => {
        });
        const hold: Deferred = new Deferred();
        rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => hold.promise;
        const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
        await flush();
        expect(rig.server.count('/v1/me')).assertEqual(1);
        const report: CleanReport = withdrawal ? await PrivacyWithdrawalCleaners.run(registry) : await registry.cleanAll();
        expect(report.cleaned[0]).assertEqual(NetworkComposition.INVALIDATE_STEP);
        expect(cancelledWhenTokensCleared).assertEqual(1);
        const result: ApiResult = await me;
        expect(result.outcome).assertEqual(ApiOutcome.LOCAL_REJECT);
        expect(result.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      }
    });

    // ---------------------------------------------------------------- lessons 37
    it('l37_late_10002_after_refresh_failure_reuses_failure_as_session_cleared', 0, async () => {
      const rig: Rig = new Rig();
      const meHold: Deferred = new Deferred();
      const refresh: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        if (request.url.indexOf('/v1/me') >= 0) {
          return meHold.promise;
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      const orders: Promise<ApiResult> = rig.client.request(new ApiRequest('listOrders'));
      await flush();
      refresh.resolve(envelope(10404, '{}'));
      const ordersResult: ApiResult = await orders;
      expect((ordersResult.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      expect(rig.tokens.clearCount).assertEqual(1);
      // 同一旧令牌的 10002 晚到：复用那次失败的结论，返回 session_cleared，不再刷新、不再清会话。
      meHold.resolve(envelope(10002, '{}'));
      const late: ApiResult = await me;
      expect(late.localRejectReason).assertEqual(LocalRejectReason.SESSION_CLEARED);
      expect((late.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.CLEAR_SESSION_LOGIN);
      expect(rig.client.refreshCalls).assertEqual(1);
      expect(rig.tokens.clearCount).assertEqual(1);
      expect(rig.sessionEffects.length).assertEqual(1);
    });

    it('l37_user_switch_is_session_changed_not_session_cleared', 0, async () => {
      const rig: Rig = new Rig();
      const meHold: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return Promise.resolve(loginResponse('user-2', 'b-access'));
        }
        return request.url.indexOf('/v1/me') >= 0 ? meHold.promise : Promise.resolve(envelope(0, '{}'));
      };
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect((await rig.client.request(loginRequest())).ok).assertTrue();
      meHold.resolve(envelope(10002, '{}'));
      expect((await me).localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(rig.client.refreshCalls).assertEqual(0);
    });

    // ---------------------------------------------------------------- lessons 38（清会话删除失败）
    it('l38_session_clear_remove_failure_keeps_old_token_blocked_and_retries', 0, () => {
      const store: FlakySecureStore = new FlakySecureStore();
      const tokens: SecureSessionTokens = new SecureSessionTokens(store);
      tokens.save(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'));
      store.failRemoves = true;
      let threw: boolean = false;
      try {
        tokens.clear();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(tokens.accessToken() === null).assertTrue();
      expect(tokens.refreshToken() === null).assertTrue();
      expect(tokens.removalRetryPending).assertTrue();
      expect(store.get('session_tokens') !== null).assertTrue();
      store.failRemoves = false;
      expect(tokens.accessToken() === null).assertTrue();
      expect(tokens.removalRetryPending).assertFalse();
      expect(store.get('session_tokens') === null).assertTrue();
      // 进程重启后也读不回旧令牌。
      expect(new SecureSessionTokens(store).accessToken() === null).assertTrue();
    });

    // ---------------------------------------------------------------- lessons 39
    it('l39_unknown_key_non_terminal_2xxxx_maps_to_cannot_confirm', 0, async () => {
      for (const code of [20901, 20001, 20902]) {
        const rig: Rig = new Rig();
        const key: string = await unknownWithdrawal(rig);
        rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
        Promise.resolve(envelope(code, '{"fields":["amount_cent"]}'));
        const result: ApiResult = await rig.client.confirmPending(key);
        const effect: ErrorEffect = result.effect as ErrorEffect;
        expect(effect.effectKindRaw).assertEqual(EffectKind.PAGE_ACTION);
        expect(effect.textKey).assertEqual('pending_confirm.cannot_confirm');
        expect(effect.replayRaw).assertEqual(ReplayKind.NONE);
        // 键不能换：记录仍待确认，可以再确认或放弃。
        expect(rig.pending.state(key).stateRaw).assertEqual('unknown');
      }
      // 20903 结束这个键，不覆盖。
      const rig: Rig = new Rig();
      const key: string = await unknownWithdrawal(rig);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(20903, '{}'));
      const voided: ApiResult = await rig.client.confirmPending(key);
      expect((voided.effect as ErrorEffect).textKey !== 'pending_confirm.cannot_confirm').assertTrue();
      expect(rig.pending.state(key).stateRaw).assertEqual('done');
    });

    // ---------------------------------------------------------------- lessons 40
    it('l40_old_generation_10001_does_not_route_to_login', 0, async () => {
      const rig: Rig = new Rig();
      const meHold: Deferred = new Deferred();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/auth/login') >= 0) {
          return Promise.resolve(loginResponse('user-2', 'b-access'));
        }
        return request.url.indexOf('/v1/me') >= 0 ? meHold.promise : Promise.resolve(envelope(0, '{}'));
      };
      const me: Promise<ApiResult> = rig.client.request(new ApiRequest('getMe'));
      await flush();
      expect((await rig.client.request(loginRequest())).ok).assertTrue();
      meHold.resolve(envelope(10001, '{}'));
      const result: ApiResult = await me;
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_CHANGED);
      expect(result.effect === null).assertTrue();
      expect(rig.tokens.accessToken()).assertEqual('b-access');
      expect(rig.sessionEffects.length).assertEqual(0);
    });

    it('l40_login_token_save_failure_is_not_login_success', 0, async () => {
      const tokens: FailingSaveTokens = new FailingSaveTokens(null);
      const rig: Rig = new Rig(null, null, tokens);
      tokens.failSaves = true;
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(loginResponse('user-1', 'a-access'));
      const result: ApiResult = await rig.client.request(loginRequest());
      expect(result.ok).assertFalse();
      expect(result.localRejectReason).assertEqual(LocalRejectReason.SESSION_STORE_FAILED);
      expect(tokens.accessToken() === null).assertTrue();
    });
  });
}
