// APP-03b 集成测试（任务书 §5 第 2 条；本地假服务，不连任何真实地址）：
// ① 同意之后注册设备，签名改用服务端签发的真实凭据，X-Sign 与 request-sign 向量一致；② 10402 只重新注册 1 次（单飞），然后重放；
// ③ 无效标识不发注册请求；④ 配置拉取失败用 LKG（含 ETag / 304）；⑤ 撤回同意后埋点队列清空且不再上报。
// 另含：20001 reread_device_hash、session_unreadable、清会话隔离（F-AND-10）、PrivacyGate 的异步设备注册退避、清理项接线。
import { describe, it, expect } from '@ohos/hypium';
import { BundledConfig, EventRouteEntryBlockedEntry } from 'generated';
import {
  ApiClient, ApiConfigFetcher, ApiOutcome, ApiRequest, ApiResult, CleanReport, ClientEvents, ConfigSnapshot, ConfigStore,
  DeviceIdentityCleaner, DeviceIdPolicy, DeviceIdReader, DeviceRegistry, EffectKind, ErrorEffect, LocalDataCleanerRegistry,
  LocalRejectReason, MemoryDeviceCredentialStore, MemoryPrivacyStore, MemorySessionTokens, NetworkHeaders, PrivacyGate,
  PrivacyStateRaw, PrivacyWithdrawalCleaners, RetryScheduler, SecureEntry, SecureSessionTokens, SecureStore,
  SessionReadStatus, SessionTokenSet, TrackerQueue, TransportFailure, TransportRequest, TransportResponse
} from '../../Index';
import { Deferred, Rig, envelope, flush, header, openLinkRequest } from './NetworkTestRig';

export const VALID_ODID: string = '3F2504E0-4F89-11D3-9A0C-0305E82C3301';
/** device-hash.vectors.json 里这个 ODID 的 device_hash。 */
export const VALID_ODID_HASH: string = 'd1bfaf4aff653cb27984b7d978e51a7d406d1572df95d205c254beb18dc134d3';
export const OTHER_ODID: string = '6a2f1c9e-0b7d-4e55-8c3a-2f9d1e0b4c77';
/** request-sign.vectors.json valid_cases[0]：POST /v1/links/abc/open?src=agent。 */
export const SIGN_SECRET: string = 'test-only.install.device-a';
const SIGN_TIMESTAMP_SECONDS: number = 1790661600;
const SIGN_NONCE: string = 'b5a8f07b9dda63c3f78ed24c341d25b3';
const SIGN_EXPECTED: string = '5715b672cfc2e52a082392ba4d6997110ae6f9583dc076c6ce8b8df0bc9eeb66';

/** 可控的 ODID 读取：按顺序给出 values（最后一个一直重复），记录读取次数。 */
export class OdidStub implements DeviceIdReader {
  values: (string | null)[];
  reads: number = 0;

  constructor(values: (string | null)[]) {
    this.values = values;
  }

  read(): string | null {
    this.reads++;
    return this.values.length > 1 ? this.values.shift() as (string | null) : this.values[0];
  }
}

/** 真实 DeviceRegistry + 假服务。 */
export class RegistryRig {
  readonly store: MemoryDeviceCredentialStore = new MemoryDeviceCredentialStore();
  readonly reader: OdidStub;
  readonly registry: DeviceRegistry;
  readonly rig: Rig;
  privacyRaw: string = PrivacyStateRaw.CONSENTED;
  lost: number = 0;

  constructor(odids: (string | null)[] = [VALID_ODID]) {
    let client: ApiClient | null = null;
    this.reader = new OdidStub(odids);
    this.registry = new DeviceRegistry('harmony', this.reader, this.store, (): string => this.privacyRaw,
      (): ApiClient | null => client);
    this.registry.onRestartNeeded = (immediate: boolean): void => {
      if (!immediate) {
        this.lost++;
      }
    };
    this.rig = new Rig(new SessionTokenSet('old-access', 'old-refresh', 'full', 'user-1'), null, null, null, null,
      this.registry, this.registry);
    client = this.rig.client;
  }

  devicesSent(): TransportRequest[] {
    return this.rig.server.received.filter((r: TransportRequest) => r.url.indexOf('/v1/devices') >= 0);
  }
}

export function registered(deviceId: string, secret: string = SIGN_SECRET): TransportResponse {
  return envelope(0, '{"device_id":"' + deviceId + '","install_secret":"' + secret + '"}');
}

export class TextBox {
  value: string | null = null;
  reads: number = 0;

  read(): string | null {
    this.reads++;
    return this.value;
  }

  write(value: string | null): void {
    this.value = value;
  }
}

export class CapturingScheduler implements RetryScheduler {
  delays: number[] = [];
  actions: (() => void)[] = [];

  schedule(delayMillis: number, action: () => void): void {
    this.delays.push(delayMillis);
    this.actions.push(action);
  }

  runNext(): void {
    const action: (() => void) | undefined = this.actions.shift();
    if (action !== undefined) {
      action();
    }
  }
}

/** 可注入失败的安全存储（F-AND-10、session_unreadable）。 */
export class FlakySecureStore implements SecureStore {
  readonly values: Map<string, string> = new Map<string, string>();
  failGet: boolean = false;
  failSet: boolean = false;
  failRemove: boolean = false;
  removeCalls: number = 0;

  get(alias: string): string | null {
    if (this.failGet) {
      throw new Error('secure store unavailable');
    }
    return this.values.get(alias) ?? null;
  }

  set(alias: string, value: string): void {
    if (this.failSet) {
      throw new Error('secure store write failed');
    }
    this.values.set(alias, value);
  }

  setGrouped(_group: string, alias: string, value: string): void {
    this.set(alias, value);
  }

  remove(alias: string): void {
    this.removeCalls++;
    if (this.failRemove) {
      throw new Error('secure store remove failed');
    }
    this.values.delete(alias);
  }

  entries(): SecureEntry[] {
    return [];
  }

  entriesInGroup(_group: string): SecureEntry[] {
    return [];
  }

  clear(): void {
    this.values.clear();
  }
}

export function tokensJson(access: string): string {
  return '{"access_token":"' + access + '","refresh_token":"r-' + access + '","session_scope":"full","account":"user-1"}';
}

function configStoreOn(rig: Rig, file: TextBox): ConfigStore {
  return new ConfigStore((): string | null => file.read(), (value: string | null): void => file.write(value),
    ApiConfigFetcher.create((): ApiClient | null => rig.client), (): number => rig.nowMillis, BundledConfig.DATA_JSON);
}

function dictVersion(store: ConfigStore): string {
  const data: Record<string, Object> = JSON.parse(store.snapshotJson) as Record<string, Object>;
  return data['dict_version'] as string;
}

export default function clientCoreIntegrationTest() {
  describe('ClientCoreIntegration', () => {
    // ---------------------------------------------------------------- ① 注册后签名用真实凭据，X-Sign 与向量一致
    it('consented_registration_issues_credentials_and_signs_with_them', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/devices') >= 0 ? registered('dev-issued-1') : envelope(0, '{}'));
      // 注册之前：签名接口没有凭据，本地拒绝，不发出。
      const before: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(before.localRejectReason).assertEqual(LocalRejectReason.DEVICE_NOT_READY);
      expect(rr.rig.server.received.length).assertEqual(0);

      expect(await rr.registry.register()).assertTrue();
      const sent: TransportRequest[] = rr.devicesSent();
      expect(sent.length).assertEqual(1);
      expect(sent[0].body).assertEqual('{"device_hash":"' + VALID_ODID_HASH + '","id_source":"odid"}');
      // 注册请求本身：不带 X-Device-Id、不签名。
      expect(header(sent[0], NetworkHeaders.DEVICE_ID) === undefined).assertTrue();
      expect(header(sent[0], NetworkHeaders.SIGN) === undefined).assertTrue();
      expect(rr.store.deviceId).assertEqual('dev-issued-1');
      expect(rr.store.installSecret).assertEqual(SIGN_SECRET);
      expect(rr.registry.deviceId()).assertEqual('dev-issued-1');

      // 签名接口：X-Device-Id 是签发的 device_id，X-Sign 用签发的 install_secret，与 request-sign 向量逐字节一致。
      rr.rig.nowMillis = SIGN_TIMESTAMP_SECONDS * 1000;
      rr.rig.random.nonces = [SIGN_NONCE];
      const result: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(result.ok).assertTrue();
      const open: TransportRequest = rr.rig.server.last('/open');
      expect(header(open, NetworkHeaders.DEVICE_ID)).assertEqual('dev-issued-1');
      expect(header(open, NetworkHeaders.TIMESTAMP)).assertEqual(String(SIGN_TIMESTAMP_SECONDS));
      expect(header(open, NetworkHeaders.NONCE)).assertEqual(SIGN_NONCE);
      expect(header(open, NetworkHeaders.SIGN)).assertEqual(SIGN_EXPECTED);

      // 已有凭据：再注册直接成功，不再发请求。
      expect(await rr.registry.register()).assertTrue();
      expect(rr.devicesSent().length).assertEqual(1);
    });

    it('registration_survives_restart_from_store', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-stored';
      rr.store.installSecret = SIGN_SECRET;
      expect(rr.registry.deviceId()).assertEqual('dev-stored');
      expect(await rr.registry.register()).assertTrue();
      expect(rr.devicesSent().length).assertEqual(0);
      expect(rr.reader.reads).assertEqual(0);
    });

    // ---------------------------------------------------------------- ② 10402：单飞重新注册 1 次，然后重放
    it('concurrent_10402_share_one_reregistration_then_replay_once', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      const registration: Deferred = new Deferred();
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/devices') >= 0) {
          return registration.promise;
        }
        return Promise.resolve(header(request, NetworkHeaders.DEVICE_ID) === 'dev-old' ? envelope(10402, '{}') :
        envelope(0, '{}'));
      };
      const first: Promise<ApiResult> = rr.rig.client.request(openLinkRequest());
      const second: Promise<ApiResult> = rr.rig.client.request(openLinkRequest());
      await flush();
      // 两个 10402 共用一次注册；被拒的 device_id 已在内存里作废。
      expect(rr.devicesSent().length).assertEqual(1);
      expect(rr.registry.deviceId() === null).assertTrue();
      expect(header(rr.devicesSent()[0], NetworkHeaders.DEVICE_ID) === undefined).assertTrue();
      registration.resolve(registered('dev-new'));
      expect((await first).ok).assertTrue();
      expect((await second).ok).assertTrue();
      expect(rr.devicesSent().length).assertEqual(1);
      const opens: TransportRequest[] = rr.rig.server.received.filter((r: TransportRequest) => r.url.indexOf('/open') >= 0);
      // 每个请求恰好发 2 次：首发（旧 device_id）+ 重放 1 次（新 device_id、重新签名）。
      expect(opens.length).assertEqual(4);
      expect(header(opens[2], NetworkHeaders.DEVICE_ID)).assertEqual('dev-new');
      expect(header(opens[3], NetworkHeaders.DEVICE_ID)).assertEqual('dev-new');
      expect(header(opens[2], NetworkHeaders.IDEMPOTENCY_KEY) === header(opens[0], NetworkHeaders.IDEMPOTENCY_KEY) ||
        header(opens[2], NetworkHeaders.IDEMPOTENCY_KEY) === header(opens[1], NetworkHeaders.IDEMPOTENCY_KEY)).assertTrue();
      expect(rr.store.deviceId).assertEqual('dev-new');
      expect(rr.lost).assertEqual(0);
    });

    it('replay_still_10402_is_not_reregistered_again', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/devices') >= 0 ? registered('dev-new') : envelope(10402, '{}'));
      const result: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(result.ok).assertFalse();
      expect(result.code).assertEqual(10402);
      expect(rr.devicesSent().length).assertEqual(1);
      expect(rr.rig.server.count('/open')).assertEqual(2);
      expect((result.effect as ErrorEffect).effectKindRaw).assertEqual(EffectKind.GENERIC_ERROR);
    });

    it('failed_reregistration_reports_credentials_lost', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/devices') >= 0 ? envelope(50001, '{}') : envelope(10402, '{}'));
      const result: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(result.ok).assertFalse();
      expect(rr.rig.server.count('/open')).assertEqual(1);
      expect(rr.lost).assertEqual(1);
      expect(rr.store.deviceId === null).assertTrue();
    });

    it('register_device_own_10402_does_not_recurse', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(10402, '{}'));
      expect(await rr.registry.register()).assertFalse();
      expect(rr.devicesSent().length).assertEqual(1);
    });

    // ---------------------------------------------------------------- ③ 无效标识不发注册请求
    it('invalid_identifiers_never_send_registration', 0, async () => {
      const odids: (string | null)[] = [null, '', '   ', '0', '00000000-0000-0000-0000-000000000000', '----'];
      for (const odid of odids) {
        const rr: RegistryRig = new RegistryRig([odid]);
        expect(await rr.registry.register()).assertFalse();
        expect(rr.devicesSent().length).assertEqual(0);
        expect(rr.rig.server.received.length).assertEqual(0);
      }
    });

    it('not_consented_does_not_even_read_identifier', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.privacyRaw = PrivacyStateRaw.BASIC_MODE;
      expect(await rr.registry.register()).assertFalse();
      expect(rr.reader.reads).assertEqual(0);
      expect(rr.rig.server.received.length).assertEqual(0);
    });

    it('unreadable_credentials_do_not_register_a_second_device', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.failReads = true;
      expect(await rr.registry.register()).assertFalse();
      expect(rr.devicesSent().length).assertEqual(0);
      rr.store.failReads = false;
      rr.store.deviceId = 'dev-stored';
      rr.store.installSecret = SIGN_SECRET;
      expect(await rr.registry.register()).assertTrue();
      expect(rr.devicesSent().length).assertEqual(0);
    });

    it('privacy_gate_retries_registration_with_backoff_until_valid', 0, async () => {
      const rr: RegistryRig = new RegistryRig(['00000000-0000-0000-0000-000000000000', '0', VALID_ODID]);
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(registered('dev-1'));
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      const scheduler: CapturingScheduler = new CapturingScheduler();
      gate.retryScheduler = scheduler;
      gate.registerDeviceRegistration((): Promise<boolean> => rr.registry.register());
      gate.agree(0);
      gate.onConsented(0);
      await flush();
      expect(rr.devicesSent().length).assertEqual(0);
      expect(JSON.stringify(scheduler.delays)).assertEqual('[1000]');
      scheduler.runNext();
      await flush();
      expect(JSON.stringify(scheduler.delays)).assertEqual('[1000,2000]');
      scheduler.runNext();
      await flush();
      // 第三次读到有效 ODID：注册成功，循环结束（不再排队）。
      expect(rr.devicesSent().length).assertEqual(1);
      expect(scheduler.actions.length).assertEqual(0);
      expect(rr.registry.deviceId()).assertEqual('dev-1');
      // 凭据丢失后交给退避流程（循环已结束时才另起）：从第一个退避间隔之后开始，不紧接着再发。
      rr.store.deviceId = null;
      rr.store.installSecret = null;
      rr.registry.clear();
      gate.restartDeviceRegistration(false);
      await flush();
      expect(rr.devicesSent().length).assertEqual(1);
      expect(JSON.stringify(scheduler.delays)).assertEqual('[1000,2000,1000]');
      scheduler.runNext();
      await flush();
      expect(rr.devicesSent().length).assertEqual(2);
    });

    it('withdrawal_stops_registration_backoff', 0, async () => {
      const rr: RegistryRig = new RegistryRig([null]);
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      const scheduler: CapturingScheduler = new CapturingScheduler();
      gate.retryScheduler = scheduler;
      gate.registerDeviceRegistration((): Promise<boolean> => rr.registry.register());
      gate.agree(0);
      gate.onConsented(0);
      await flush();
      expect(scheduler.actions.length).assertEqual(1);
      gate.withdraw(0);
      const readsBefore: number = rr.reader.reads;
      scheduler.runNext();
      await flush();
      expect(rr.reader.reads).assertEqual(readsBefore);
      expect(scheduler.actions.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 20001 reread_device_hash
    it('reread_device_hash_rereads_once_and_never_resends_rejected_value', 0, async () => {
      const same: RegistryRig = new RegistryRig([VALID_ODID]);
      same.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(20001, '{"fields":["device_hash"]}'));
      expect(await same.registry.register()).assertFalse();
      // 重读到的还是被拒的值：不带原值重试。
      expect(same.devicesSent().length).assertEqual(1);
      expect(same.reader.reads).assertEqual(2);
      expect(await same.registry.register()).assertFalse();
      expect(same.devicesSent().length).assertEqual(1);

      const changed: RegistryRig = new RegistryRig([VALID_ODID, OTHER_ODID]);
      let calls: number = 0;
      changed.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => {
        calls++;
        return Promise.resolve(calls === 1 ? envelope(20001, '{"fields":["device_hash"]}') : registered('dev-2'));
      };
      expect(await changed.registry.register()).assertTrue();
      const sent: TransportRequest[] = changed.devicesSent();
      expect(sent.length).assertEqual(2);
      expect(sent[1].body).assertEqual('{"device_hash":"' + DeviceIdPolicy.hash(OTHER_ODID) + '","id_source":"odid"}');
    });

    it('mapper_outputs_reread_device_hash_without_user_text', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(20001, '{"fields":["device_hash"]}'));
      const result: ApiResult = await rr.rig.client.request(new ApiRequest('registerDevice', {}, '',
        '{"device_hash":"' + VALID_ODID_HASH + '","id_source":"odid"}'));
      const effect: ErrorEffect = result.effect as ErrorEffect;
      expect(effect.effectKindRaw).assertEqual(EffectKind.REREAD_DEVICE_HASH);
      expect(effect.textKey === null).assertTrue();
      expect(effect.fields[0]).assertEqual('device_hash');
    });

    it('withdrawal_cleanup_clears_device_identity_and_discards_late_registration', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      const late: Deferred = new Deferred();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => late.promise;
      const registering: Promise<boolean> = rr.registry.register();
      await flush();
      const cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      PrivacyWithdrawalCleaners.registerPlaceholders(cleaners);
      DeviceIdentityCleaner.register(cleaners, rr.registry);
      expect(JSON.stringify(cleaners.names())).assertEqual(JSON.stringify(PrivacyWithdrawalCleaners.NAMES));
      rr.privacyRaw = PrivacyStateRaw.BASIC_MODE;
      const report: CleanReport = await PrivacyWithdrawalCleaners.run(cleaners);
      expect(report.ok).assertTrue();
      expect(rr.store.clearCount).assertEqual(1);
      late.resolve(registered('dev-late'));
      expect(await registering).assertFalse();
      expect(rr.store.deviceId === null).assertTrue();
      expect(rr.registry.deviceId() === null).assertTrue();
      // 删除失败：清理项报告失败（撤回清理保持待完成、下次重试），内存里已经没有。
      rr.store.deviceId = 'dev-x';
      rr.store.installSecret = SIGN_SECRET;
      rr.store.failClears = true;
      const failed: CleanReport = await PrivacyWithdrawalCleaners.run(cleaners);
      expect(failed.ok).assertFalse();
      expect(failed.failed.indexOf(PrivacyWithdrawalCleaners.DEVICE_IDENTITY) >= 0).assertTrue();
      expect(rr.registry.deviceId() === null).assertTrue();
    });

    // ---------------------------------------------------------------- ④ 配置拉取失败用 LKG；ETag / 304
    it('config_fetch_failure_falls_back_to_lkg_and_304_keeps_current', 0, async () => {
      const rig: Rig = new Rig();
      const file: TextBox = new TextBox();
      let etagSent: string | undefined = undefined;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        etagSent = header(request, NetworkHeaders.IF_NONE_MATCH);
        if (etagSent === 'W/"cfg-1"') {
          return Promise.resolve(TransportResponse.ok(304, {}, ''));
        }
        return Promise.resolve(envelope(0, '{"dict_version":"net-1","link_patterns":{"version":"p-1","rules":[]}}',
          { 'ETag': 'W/"cfg-1"' }));
      };
      const first: ConfigStore = configStoreOn(rig, file);
      first.onColdStart();
      expect(first.sourceRaw).assertEqual('bundled');
      expect(dictVersion(first)).assertEqual('2026100201');
      await flush();
      expect(first.sourceRaw).assertEqual('current');
      expect(dictVersion(first)).assertEqual('net-1');
      expect(file.value !== null).assertTrue();
      expect(etagSent === undefined).assertTrue();
      // 回前台：原样带 If-None-Match（弱 ETag 不拆），304 内容不变。
      first.onForeground();
      await flush();
      expect(etagSent).assertEqual('W/"cfg-1"');
      expect(first.sourceRaw).assertEqual('current');
      expect(dictVersion(first)).assertEqual('net-1');
      const patterns: Record<string, Object> = JSON.parse(first.linkPatterns() ?? '{}') as Record<string, Object>;
      expect(patterns['version']).assertEqual('p-1');

      // 重启后拉取失败（断连，GET 自动重试 1 次后仍失败）：继续用 LKG。
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
      const restarted: ConfigStore = configStoreOn(rig, file);
      restarted.onColdStart();
      expect(restarted.sourceRaw).assertEqual('lkg');
      await flush();
      expect(restarted.sourceRaw).assertEqual('lkg');
      expect(dictVersion(restarted)).assertEqual('net-1');
      // 业务错误同样不覆盖 LKG。
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(50001, '{}'));
      restarted.onForeground();
      await flush();
      expect(restarted.sourceRaw).assertEqual('lkg');
      // 切换环境清 LKG，回到包内配置。
      restarted.clearForEnvironmentSwitch();
      expect(file.value === null).assertTrue();
      expect(restarted.sourceRaw).assertEqual('bundled');
    });

    it('config_is_fetchable_in_basic_mode_without_credentials', 0, async () => {
      const rig: Rig = new Rig();
      rig.context.privacyRaw = 'basic';
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"dict_version":"basic-ok"}'));
      const store: ConfigStore = configStoreOn(rig, new TextBox());
      store.onColdStart();
      await flush();
      expect(dictVersion(store)).assertEqual('basic-ok');
      const sent: TransportRequest = rig.server.last('/v1/config');
      expect(header(sent, NetworkHeaders.AUTHORIZATION) === undefined).assertTrue();
      expect(header(sent, NetworkHeaders.DEVICE_ID) === undefined).assertTrue();
    });

    it('config_subscribers_observe_changes', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"dict_version":"seen"}'));
      const store: ConfigStore = configStoreOn(rig, new TextBox());
      const sources: string[] = [];
      const cancel: () => void = store.subscribe((snapshot: ConfigSnapshot): void => {
        sources.push(snapshot.sourceRaw);
      });
      store.onColdStart();
      await flush();
      cancel();
      store.clearForEnvironmentSwitch();
      expect(JSON.stringify(sources)).assertEqual('["bundled","bundled","current"]');
    });

    // ---------------------------------------------------------------- ⑤ 撤回同意后埋点队列清空、不再上报
    it('withdrawal_clears_tracker_queue_and_stops_reporting', 0, async () => {
      const file: TextBox = new TextBox();
      const uploaded: string[] = [];
      let allowUpload: boolean = false;
      let privacy: string = PrivacyStateRaw.CONSENTED;
      const makeQueue: () => TrackerQueue = (): TrackerQueue => new TrackerQueue((): string | null => file.read(),
        (value: string | null): void => file.write(value), (events: string[]): boolean => {
          for (const event of events) {
            uploaded.push(event);
          }
          return true;
        }, privacy, (): string | null => null, 'dev-1', 'harmony', '1.2.0', 'session-1', (): number => 0,
        (): boolean => allowUpload);
      const queue: TrackerQueue = makeQueue();
      for (let i: number = 0; i < 3; i++) {
        expect(queue.track(ClientEvents.appLaunch('Home'))).assertTrue();
      }
      expect(queue.queueSize).assertEqual(3);
      expect(file.value !== null).assertTrue();

      // App 的撤回路径：PrivacyGate.withdraw → 结论变为基本模式 → AppPrivacy.publish → TrackerQueue.onPrivacyChanged。
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      gate.agree(0);
      gate.withdraw(0);
      privacy = gate.state(0).decisionRaw;
      expect(privacy).assertEqual(PrivacyStateRaw.BASIC_MODE);
      queue.onPrivacyChanged(privacy);
      expect(queue.queueSize).assertEqual(0);
      expect(file.value === null).assertTrue();
      allowUpload = true;
      expect(queue.track(ClientEvents.appLaunch('Home'))).assertFalse();
      queue.flush();
      expect(uploaded.length).assertEqual(0);
      // 重建队列（冷启动）后再同意：撤回前的事件不会复活。
      const restarted: TrackerQueue = makeQueue();
      restarted.onPrivacyChanged(PrivacyStateRaw.CONSENTED);
      restarted.flush();
      expect(uploaded.length).assertEqual(0);
      expect(restarted.track(ClientEvents.appLaunch('Home'))).assertTrue();
      restarted.flush();
      expect(uploaded.length).assertEqual(1);
    });

    it('tracker_needs_registered_device_and_sends_common_fields', 0, () => {
      const uploaded: string[] = [];
      const queue: TrackerQueue = new TrackerQueue((): string | null => null, (_v: string | null): void => {
      }, (events: string[]): boolean => {
        for (const event of events) {
          uploaded.push(event);
        }
        return true;
      }, PrivacyStateRaw.CONSENTED, (): string | null => 'user-9', '', 'harmony', '1.2.0', 'session-1', (): number => 0,
        (): boolean => true);
      // 还没有 device_id（设备未注册）：不采集。
      expect(queue.track(ClientEvents.appLaunch('Home'))).assertFalse();
      queue.deviceIdSource = (): string | null => 'dev-1';
      queue.channelSource = (): string | null => 'agc';
      expect(queue.track(ClientEvents.routeEntryBlocked('Home', 'Withdraw', ClientEventsEntry.push(), 'home.banner.1')))
        .assertTrue();
      queue.flush();
      const packet: Record<string, Object> = JSON.parse(uploaded[0]) as Record<string, Object>;
      expect(packet['name']).assertEqual('route_entry_blocked');
      expect(packet['user_id']).assertEqual('user-9');
      expect(packet['device_id']).assertEqual('dev-1');
      expect(packet['channel']).assertEqual('agc');
      expect(packet['spm']).assertEqual('home.banner.1');
      expect(packet['route']).assertEqual('Withdraw');
      expect(packet['entry']).assertEqual('push');
      expect(packet['client_at']).assertEqual('1970-01-01T00:00:00.000Z');
    });

    // ---------------------------------------------------------------- session_unreadable
    it('unreadable_session_rejects_auth_operations_locally', 0, async () => {
      const tokens: MemorySessionTokens = new MemorySessionTokens(new SessionTokenSet('a', 'r', 'full', 'user-1'));
      const rig: Rig = new Rig(null, null, tokens);
      tokens.unreadable = true;
      const me: ApiResult = await rig.client.request(new ApiRequest('getMe'));
      expect(me.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      const config: ApiResult = await rig.client.request(new ApiRequest('getConfig'));
      expect(config.localRejectReason).assertEqual(LocalRejectReason.SESSION_UNREADABLE);
      expect(rig.server.received.length).assertEqual(0);
      // x-auth = none 的接口照常（不带令牌）。
      const device: ApiResult = await rig.client.request(new ApiRequest('registerDevice', {}, '',
        '{"device_hash":"' + VALID_ODID_HASH + '","id_source":"odid"}'));
      expect(device.ok).assertTrue();
      // 恢复后照常带令牌。
      tokens.unreadable = false;
      expect((await rig.client.request(new ApiRequest('getMe'))).ok).assertTrue();
      expect(header(rig.server.last('/v1/me'), NetworkHeaders.AUTHORIZATION)).assertEqual('Bearer a');
    });

    it('secure_tokens_distinguish_absent_unreadable_and_corrupt', 0, () => {
      const store: FlakySecureStore = new FlakySecureStore();
      const tokens: SecureSessionTokens = new SecureSessionTokens(store);
      // 读取失败：unreadable，不缓存、不删除。
      store.values.set('session_tokens', tokensJson('a1'));
      store.failGet = true;
      expect(tokens.readStatus()).assertEqual(SessionReadStatus.UNREADABLE);
      expect(tokens.accessToken() === null).assertTrue();
      expect(store.removeCalls).assertEqual(0);
      store.failGet = false;
      expect(tokens.readStatus()).assertEqual(SessionReadStatus.PRESENT);
      expect(tokens.accessToken()).assertEqual('a1');
      // 不存在：absent。
      const empty: SecureSessionTokens = new SecureSessionTokens(new FlakySecureStore());
      expect(empty.readStatus()).assertEqual(SessionReadStatus.ABSENT);
      // 内容损坏：按没有会话，并删除。
      const corruptStore: FlakySecureStore = new FlakySecureStore();
      corruptStore.values.set('session_tokens', '{not json');
      const corrupt: SecureSessionTokens = new SecureSessionTokens(corruptStore);
      expect(corrupt.readStatus()).assertEqual(SessionReadStatus.ABSENT);
      expect(corruptStore.values.has('session_tokens')).assertFalse();
    });

    // ---------------------------------------------------------------- F-AND-10：隔离只在确认删除或新会话成功写入后解除
    it('f_and_10_isolation_survives_failed_clear_and_failed_login_save', 0, () => {
      const store: FlakySecureStore = new FlakySecureStore();
      store.values.set('session_tokens', tokensJson('old'));
      const tokens: SecureSessionTokens = new SecureSessionTokens(store);
      expect(tokens.accessToken()).assertEqual('old');
      // 清会话删除失败：隔离，旧令牌不再给出。
      store.failRemove = true;
      let threw: boolean = false;
      try {
        tokens.clear();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(tokens.removalRetryPending).assertTrue();
      expect(tokens.accessToken() === null).assertTrue();
      // 并发登录的令牌保存失败：隔离不解除，旧令牌继续被阻断。
      store.failSet = true;
      threw = false;
      try {
        tokens.save(new SessionTokenSet('new', 'r-new', 'full', 'user-2'));
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(tokens.removalRetryPending).assertTrue();
      expect(tokens.accessToken() === null).assertTrue();
      expect(store.values.get('session_tokens')).assertEqual(tokensJson('old'));
      // 存储恢复：下次读取重试删除成功，隔离解除，没有会话。
      store.failRemove = false;
      store.failSet = false;
      expect(tokens.accessToken() === null).assertTrue();
      expect(tokens.removalRetryPending).assertFalse();
      expect(store.values.has('session_tokens')).assertFalse();
    });

    it('f_and_10_successful_new_session_lifts_isolation_without_being_deleted', 0, () => {
      const store: FlakySecureStore = new FlakySecureStore();
      store.values.set('session_tokens', tokensJson('old'));
      const tokens: SecureSessionTokens = new SecureSessionTokens(store);
      store.failRemove = true;
      try {
        tokens.clear();
      } catch (e) {
        // 预期：删除失败。
      }
      expect(tokens.removalRetryPending).assertTrue();
      tokens.save(new SessionTokenSet('new', 'r-new', 'full', 'user-2'));
      expect(tokens.removalRetryPending).assertFalse();
      store.failRemove = false;
      const removesBefore: number = store.removeCalls;
      expect(tokens.accessToken()).assertEqual('new');
      expect(store.removeCalls).assertEqual(removesBefore);
      expect(store.values.has('session_tokens')).assertTrue();
    });

    it('f_and_10_login_save_failure_is_rejected_and_old_token_stays_blocked', 0, async () => {
      const store: FlakySecureStore = new FlakySecureStore();
      store.values.set('session_tokens', tokensJson('old'));
      const secure: SecureSessionTokens = new SecureSessionTokens(store);
      store.failRemove = true;
      try {
        secure.clear();
      } catch (e) {
        // 预期：删除失败。
      }
      store.failSet = true;
      // 用真实的安全存储令牌实现替代内存令牌：经 ApiClient 登录，保存失败返回 session_save_failed。
      const rigWithSecure: SecureRig = new SecureRig(secure);
      rigWithSecure.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/login') >= 0 ?
        envelope(0, '{"user_id":"user-2","tokens":{"access_token":"new","refresh_token":"r-new","session_scope":"full"}}') :
        envelope(0, '{}'));
      const login: ApiResult = await rigWithSecure.rig.client.request(new ApiRequest('loginBySms', {}, '',
        '{"phone":"13800000000","code":"123456"}'));
      expect(login.ok).assertFalse();
      expect(login.localRejectReason).assertEqual(LocalRejectReason.SESSION_SAVE_FAILED);
      expect(secure.removalRetryPending).assertTrue();
      // 之后的请求不带旧令牌。
      await rigWithSecure.rig.client.request(new ApiRequest('getMe'));
      expect(header(rigWithSecure.rig.server.last('/v1/me'), NetworkHeaders.AUTHORIZATION) === undefined).assertTrue();
    });

    // ---------------------------------------------------------------- ApiClient 条件请求
    it('if_none_match_is_sent_verbatim_and_304_is_not_modified', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(TransportResponse.ok(304, { 'etag': '"v2"' }, ''));
      const request: ApiRequest = new ApiRequest('getConfig');
      request.ifNoneMatch = '"v2"';
      const result: ApiResult = await rig.client.request(request);
      expect(result.outcome).assertEqual(ApiOutcome.NOT_MODIFIED);
      expect(result.etag).assertEqual('"v2"');
      expect(header(rig.server.last('/v1/config'), NetworkHeaders.IF_NONE_MATCH)).assertEqual('"v2"');
      // 304 不是网络错误：GET 不自动重试。
      expect(rig.server.count('/v1/config')).assertEqual(1);
    });
  });
}

/** route_entry_blocked 的 entry 枚举取值（生成的 EventRouteEntryBlockedEntry）。 */
class ClientEventsEntry {
  static push(): EventRouteEntryBlockedEntry {
    return EventRouteEntryBlockedEntry.PUSH;
  }
}

/** 用真实 SecureSessionTokens 的 Rig（F-AND-10 经 ApiClient 的登录路径）。 */
class SecureRig {
  readonly rig: Rig;

  constructor(tokens: SecureSessionTokens) {
    this.rig = new Rig(null, null, null, null, null, null, null, tokens);
  }
}
