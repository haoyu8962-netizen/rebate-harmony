// APP-03b 鸿蒙第 2 轮评审（harmony-review-r2.md R2-01…R2-03）与三端共性问题（cross-platform-lessons.md 12–19）的回归测试。
// 每条都按评审里的失败场景复现：撤掉对应修复，这些断言会失败。本地假服务，不连任何真实地址。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiRequest, ApiResult, ClientEvents, ConfigReply, ConfigStore, DeviceIdentityCleaner, DeviceRegistry,
  EnvironmentSwitchGate, HttpTransport, LocalDataCleanerRegistry, LocalRejectReason, MemoryDeviceCredentialStore,
  MemoryPrivacyStore, NetworkComposition, NetworkHeaders, PrivacyGate, PrivacyStateRaw, PrivacyWithdrawalCleaners,
  RepeatingTimer,
  SecureSessionTokens, SessionTokenSet, TrackerFlushScheduler, TrackerQueue, TransportFailure, TransportRequest,
  TransportResponse, UploadTicket
} from '../../Index';
import {
  CapturingScheduler, FlakySecureStore, OdidStub, RegistryRig, SIGN_SECRET, TextBox, VALID_ODID, registered, tokensJson
} from './ClientCoreIntegration.test';
import { Deferred, Rig, envelope, flush, header, openLinkRequest, tokenPair } from './NetworkTestRig';

const REJECT_HASH: string = '{"fields":["device_hash"]}';

/** 手动触发的周期定时器。 */
class ManualTimer implements RepeatingTimer {
  action: (() => void) | null = null;

  start(_intervalMillis: number, action: () => void): number {
    this.action = action;
    return 1;
  }

  stop(_handle: number): void {
    this.action = null;
  }

  fire(): void {
    const action: (() => void) | null = this.action;
    if (action !== null) {
      action();
    }
  }
}

/** 手动控制的配置拉取器。 */
class ManualFetcher {
  pending: ((reply: ConfigReply) => void)[] = [];
  calls: number = 0;

  fetch(_etag: string | null, done: (reply: ConfigReply) => void): void {
    this.calls++;
    this.pending.push(done);
  }

  reply(body: string): void {
    const done: ((reply: ConfigReply) => void) | undefined = this.pending.shift();
    if (done !== undefined) {
      done(new ConfigReply(ConfigReply.OK, body, null));
    }
  }
}

/**
 * 模拟 RCP：请求交给传输层后先「等连接 / TLS」（hold），之后才核对 TransportRequest.admit 并真正发出。
 * admit 不通过的不发出（refused），按 cancelled 返回。
 */
class HoldingTransport implements HttpTransport {
  readonly sent: TransportRequest[] = [];
  readonly cancelled: TransportRequest[] = [];
  refused: number = 0;
  private release: () => void = () => {
  };
  private readonly hold: Promise<void>;

  constructor() {
    this.hold = new Promise<void>((resolve: () => void) => {
      this.release = resolve;
    });
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    return this.hold.then((): TransportResponse => {
      if (!request.admit()) {
        this.refused++;
        return TransportResponse.failed(TransportFailure.CANCELLED);
      }
      this.sent.push(request);
      return registered('dev-late');
    });
  }

  cancel(request: TransportRequest): void {
    this.cancelled.push(request);
  }

  connect(): void {
    this.release();
  }
}

/** 埋点队列文件（内存）。 */
class QueueBox {
  value: string | null = null;

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    this.value = value;
  }
}

function makeQueue(file: QueueBox, sink: (events: string[]) => boolean, privacy: string): TrackerQueue {
  return new TrackerQueue((): string | null => file.read(), (value: string | null): void => file.write(value), sink,
    privacy, (): string | null => null, 'dev-1', 'harmony', '1.2.0', 'session-1', (): number => 0,
    (): boolean => true);
}

function loginRequest(): ApiRequest {
  return new ApiRequest('loginByWechat', {}, '', '{"code":"wx-auth-code"}');
}

export default function clientCoreReviewR2Test() {
  describe('ClientCoreReviewR2', () => {
    // ---------------------------------------------------------------- R2-01 / lessons 17
    it('r2_01_gate_close_cancels_in_flight_requests_before_any_await', 0, async () => {
      const rig: Rig = new Rig();
      const gate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      NetworkComposition.install(rig.client, new LocalDataCleanerRegistry(), (): void => {
      }, gate);
      // 请求已交给传输层，还在等连接 / TLS。
      const waiting: Deferred = new Deferred();
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => waiting.promise;
      const call: Promise<ApiResult> = rig.client.request(openLinkRequest());
      await flush();
      expect(rig.server.received.length).assertEqual(1);
      expect(rig.server.cancelled.length).assertEqual(0);
      // 切换开始：闸门同步关闭。还没有任何 await（环境记录的 get / put 都还没开始），在途请求就已经取消。
      gate.close();
      expect(rig.server.cancelled.length).assertEqual(1);
      const result: ApiResult = await call;
      expect(result.ok).assertFalse();
      expect(result.localRejectReason).assertEqual(LocalRejectReason.CANCELLED);
      // 旧连接晚到的响应不再被处理。
      waiting.resolve(envelope(0, '{"ok":true}'));
      await flush();
      expect(rig.server.received.length).assertEqual(1);
    });

    it('r2_01_gate_close_abandons_registration_task_and_tracker_upload', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      const gate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      rr.registry.attachEnvironment(gate);
      NetworkComposition.install(rr.rig.client, new LocalDataCleanerRegistry(), (): void => {
      }, gate);
      const inFlight: Deferred = new Deferred();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => inFlight.promise;
      const task: Promise<boolean> = rr.registry.register();
      await flush();
      expect(rr.devicesSent().length).assertEqual(1);
      gate.close();
      // 注册请求在关闭的同步区里被取消，任务以失败结束；切换期间退避任务再来也不发。
      expect(rr.rig.server.cancelled.length).assertEqual(1);
      expect(await task).assertFalse();
      expect(await rr.registry.register()).assertFalse();
      expect(rr.devicesSent().length).assertEqual(1);
      inFlight.resolve(registered('dev-old-env'));
      await flush();
      expect(rr.registry.deviceId() === null).assertTrue();
      expect(rr.store.deviceId === null).assertTrue();
    });

    // ---------------------------------------------------------------- R2-02 / lessons 4、18
    it('r2_02_late_10402_of_older_credential_reuses_its_own_result_across_rounds', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-0';
      rr.store.installSecret = SIGN_SECRET;
      let registrations: number = 0;
      const oldOpens: Deferred[] = [new Deferred(), new Deferred()];
      let oldIndex: number = 0;
      let dev1Calls: number = 0;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/devices') >= 0) {
          registrations++;
          return Promise.resolve(registrations === 1 ? registered('dev-1') : envelope(50001, '{}'));
        }
        const device: string | undefined = header(request, NetworkHeaders.DEVICE_ID);
        if (device === 'dev-0') {
          const deferred: Deferred = oldOpens[oldIndex];
          oldIndex++;
          return deferred.promise;
        }
        dev1Calls++;
        return Promise.resolve(dev1Calls === 1 ? envelope(0, '{"ok":true}') : envelope(10402, '{}'));
      };
      // 两个请求都带 D0 发出。
      const first: Promise<ApiResult> = rr.rig.client.request(openLinkRequest());
      const second: Promise<ApiResult> = rr.rig.client.request(openLinkRequest());
      await flush();
      expect(oldIndex).assertEqual(2);
      // 第一个收到 10402：重新注册成功取得 D1，用 D1 重放成功。
      oldOpens[0].resolve(envelope(10402, '{}'));
      expect((await first).ok).assertTrue();
      expect(registrations).assertEqual(1);
      expect(rr.registry.deviceId()).assertEqual('dev-1');
      // 新请求带 D1 收到 10402，这一轮注册失败（交给退避）。
      expect((await rr.rig.client.request(openLinkRequest())).ok).assertFalse();
      expect(registrations).assertEqual(2);
      expect(rr.lost).assertEqual(1);
      // 第二个 D0 请求的 10402 这时才到：复用 D0 那次的结果，不再注册、不再触发恢复（原来会第 3 次注册）。
      oldOpens[1].resolve(envelope(10402, '{}'));
      const late: ApiResult = await second;
      expect(late.ok).assertFalse();
      expect(registrations).assertEqual(2);
      expect(rr.lost).assertEqual(1);
      // 清理之后记录作废：新世代的 10402 照常注册。
      rr.registry.clear();
      expect(rr.registry.registered).assertFalse();
    });

    // ---------------------------------------------------------------- R2-03 / lessons 19
    it('r2_03_login_without_tokens_is_invalid_session_tokens_and_keeps_session', 0, async () => {
      const inputs: string[] = [
        '{"user_id":"user-B"}',
        '{"user_id":"user-B","tokens":{"access_token":"access-B","session_scope":"full"}}',
        '{"user_id":"user-B","tokens":{"refresh_token":"refresh-B","session_scope":"full"}}',
        '{"user_id":"user-B","tokens":"broken"}'
      ];
      for (const data of inputs) {
        const rig: Rig = new Rig(new SessionTokenSet('access-A', 'refresh-A', 'full', 'user-A'));
        rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(envelope(0, data));
        const result: ApiResult = await rig.client.request(loginRequest());
        expect(result.ok).assertFalse();
        expect(result.localRejectReason).assertEqual(LocalRejectReason.INVALID_SESSION_TOKENS);
        // 账号 A 的会话原样保留。
        expect(rig.tokens.accessToken()).assertEqual('access-A');
        expect(rig.tokens.account()).assertEqual('user-A');
      }
      // 令牌齐全但写不进安全存储：session_save_failed（与缺令牌分开）。
      const secure: FlakySecureStore = new FlakySecureStore();
      secure.values.set('session_tokens', tokensJson('access-A'));
      const tokens: SecureSessionTokens = new SecureSessionTokens(secure);
      const saveRig: Rig = new Rig(null, null, null, null, null, null, null, tokens);
      secure.failSet = true;
      saveRig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"user_id":"user-B","tokens":' + tokenPair('access-B', 'refresh-B', 'full') + '}'));
      const failed: ApiResult = await saveRig.client.request(loginRequest());
      expect(failed.ok).assertFalse();
      expect(failed.localRejectReason).assertEqual(LocalRejectReason.SESSION_SAVE_FAILED);
      // 正常登录仍然成功。
      const ok: Rig = new Rig(new SessionTokenSet('access-A', 'refresh-A', 'full', 'user-A'));
      ok.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, '{"user_id":"user-B","tokens":' + tokenPair('access-B', 'refresh-B', 'full') + '}'));
      expect((await ok.client.request(loginRequest())).ok).assertTrue();
      expect(ok.tokens.accessToken()).assertEqual('access-B');
    });

    // ---------------------------------------------------------------- lessons 12（A-R2-01，S0）
    it('lesson12_after_withdrawal_old_task_never_reads_device_identifier', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      let cycle: number = 0;
      rr.registry.privacyEpoch = (): number => cycle;
      const cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      DeviceIdentityCleaner.register(cleaners, rr.registry);
      // ① 注册在途时撤回同意并完成清理，之后 20001 才到：不再读 ODID（不重读）、不再发送。
      const inFlight: Deferred = new Deferred();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => inFlight.promise;
      const task: Promise<boolean> = rr.registry.register();
      await flush();
      expect(rr.reader.reads).assertEqual(1);
      rr.privacyRaw = PrivacyStateRaw.BASIC_MODE;
      cycle++;
      await cleaners.cleanOnly([PrivacyWithdrawalCleaners.DEVICE_IDENTITY]);
      inFlight.resolve(envelope(20001, REJECT_HASH));
      expect(await task).assertFalse();
      expect(rr.reader.reads).assertEqual(1);
      expect(rr.devicesSent().length).assertEqual(1);
      // ② 撤回完成之后，旧的退避任务到点：开始前的检查与读取在同一个同步区，读都不读。
      expect(await rr.registry.register()).assertFalse();
      expect(rr.reader.reads).assertEqual(1);

      // ③ 撤回后很快又同意（隐私世代变了，清理世代、环境世代都没变）：旧任务的 20001 晚到也不得重读标识。
      const rr2: RegistryRig = new RegistryRig();
      let cycle2: number = 0;
      rr2.registry.privacyEpoch = (): number => cycle2;
      const second: Deferred = new Deferred();
      rr2.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => second.promise;
      const task2: Promise<boolean> = rr2.registry.register();
      await flush();
      cycle2++;
      second.resolve(envelope(20001, REJECT_HASH));
      expect(await task2).assertFalse();
      expect(rr2.reader.reads).assertEqual(1);
      expect(rr2.registry.rejectedHashCount).assertEqual(0);
      expect(rr2.devicesSent().length).assertEqual(1);
    });

    // ---------------------------------------------------------------- lessons 13（A-R2-02）
    it('lesson13_register_request_carries_ticket_and_is_refused_at_send_guard', 0, async () => {
      const transport: HoldingTransport = new HoldingTransport();
      let client: ApiClient | null = null;
      let env: number = 0;
      const store: MemoryDeviceCredentialStore = new MemoryDeviceCredentialStore();
      const registry: DeviceRegistry = new DeviceRegistry('harmony', new OdidStub([VALID_ODID]), store,
        (): string => PrivacyStateRaw.CONSENTED, (): ApiClient | null => client);
      registry.environmentToken = (): number | null => env;
      const rig: Rig = new Rig(null, transport, null, null, null, registry, registry);
      client = rig.client;
      // 旧任务读完标识、请求交给传输层，还在等连接；这时环境世代变了（网络层的地址未变，最坏情况：ApiClient 自己的
      // 调用归属仍然成立）。传输层发出前的 admit 用注册任务的原始 ticket 核对，不发出。
      const task: Promise<boolean> = registry.register();
      await flush();
      env = 1;
      transport.connect();
      expect(await task).assertFalse();
      expect(transport.refused).assertEqual(1);
      expect(transport.sent.length).assertEqual(0);
      expect(store.deviceId === null).assertTrue();
    });

    // ---------------------------------------------------------------- lessons 14（A-R2-03）
    it('lesson14_failed_switch_after_device_cleared_restarts_registration_and_config', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      const envGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      rr.registry.attachEnvironment(envGate);
      const gate: PrivacyGate = new PrivacyGate(new MemoryPrivacyStore(), (): number => 0, '1');
      const scheduler: CapturingScheduler = new CapturingScheduler();
      gate.retryScheduler = scheduler;
      gate.registerDeviceRegistration((): Promise<boolean> => rr.registry.register());
      rr.registry.onRestartNeeded = (immediate: boolean): void => gate.restartDeviceRegistration(immediate);
      const fetcher: ManualFetcher = new ManualFetcher();
      const lkg: TextBox = new TextBox();
      const config: ConfigStore = new ConfigStore((): string | null => lkg.read(),
        (value: string | null): void => lkg.write(value),
        (etag: string | null, done: (reply: ConfigReply) => void): void => fetcher.fetch(etag, done), (): number => 0, '{}');
      config.attachEnvironment(envGate);
      config.onColdStart();
      fetcher.reply('{"dict_version":"env-a"}');
      const cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      DeviceIdentityCleaner.register(cleaners, rr.registry);
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(registered('dev-A'));
      gate.agree(0);
      gate.onConsented(0);
      await flush();
      expect(rr.registry.deviceId()).assertEqual('dev-A');
      expect(fetcher.calls).assertEqual(1);
      // 切换：设备凭据已清掉，之后环境记录写入失败，继续用原环境（reopen(false)）。
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(registered('dev-A2'));
      envGate.close();
      await cleaners.cleanAll();
      expect(rr.registry.deviceId() === null).assertTrue();
      envGate.reopen(false);
      await flush();
      // 恢复：立即重新注册（不靠 10402），并重新拉配置。
      expect(rr.registry.deviceId()).assertEqual('dev-A2');
      expect(rr.devicesSent().length).assertEqual(2);
      expect(fetcher.calls).assertEqual(2);
    });

    // ---------------------------------------------------------------- lessons 15（A-R2-04）
    it('lesson15_cold_start_old_queue_is_submitted_by_scheduler_without_new_events', 0, () => {
      const file: QueueBox = new QueueBox();
      // 上一个进程：3 条事件没上报出去（sink 失败）。
      const previous: TrackerQueue = makeQueue(file, (_e: string[]): boolean => false, PrivacyStateRaw.CONSENTED);
      for (let i: number = 0; i < 3; i++) {
        expect(previous.track(ClientEvents.appLaunch('Home'))).assertTrue();
      }
      previous.flush();
      expect(file.value !== null).assertTrue();
      // 冷启动：按已同意显式创建队列并启动定时上报；不清理、不产生新事件。
      const uploaded: string[] = [];
      const queue: TrackerQueue = makeQueue(file, (events: string[]): boolean => {
        for (const event of events) {
          uploaded.push(event);
        }
        return true;
      }, PrivacyStateRaw.CONSENTED);
      expect(queue.queueSize).assertEqual(3);
      const timer: ManualTimer = new ManualTimer();
      const scheduler: TrackerFlushScheduler = new TrackerFlushScheduler(timer, (): void => queue.flush(),
        TrackerQueue.FLUSH_INTERVAL_MILLIS);
      scheduler.start();
      timer.fire();
      expect(uploaded.length).assertEqual(3);
      expect(queue.queueSize).assertEqual(0);
      expect(file.value === null).assertTrue();
    });

    // ---------------------------------------------------------------- lessons 16（A-R2-05）
    it('lesson16_batch_taken_before_withdrawal_is_never_submitted', 0, async () => {
      const file: QueueBox = new QueueBox();
      const queue: TrackerQueue = makeQueue(file, (_e: string[]): boolean => true, PrivacyStateRaw.CONSENTED);
      const submitted: string[] = [];
      const handed: string[][] = [];
      let release: () => void = () => {
      };
      const connected: Promise<void> = new Promise<void>((resolve: () => void) => {
        release = resolve;
      });
      // 异步 sink：拿到批次后等连接，真正提交前自查 ticket（N-20 时这一步是 ApiRequest.owner）。
      queue.asyncSink = (events: string[], ticket: UploadTicket): Promise<boolean> => {
        handed.push(events);
        return connected.then((): boolean => {
          if (!ticket.valid) {
            return true;
          }
          for (const event of events) {
            submitted.push(event);
          }
          return true;
        });
      };
      queue.track(ClientEvents.appLaunch('Home'));
      queue.track(ClientEvents.appLaunch('Home'));
      queue.flush();
      expect(handed.length).assertEqual(1);
      // 已取出的批次在途时撤回同意：清空并作废这一批。
      queue.onPrivacyChanged(PrivacyStateRaw.BASIC_MODE);
      release();
      await flush();
      expect(submitted.length).assertEqual(0);
      expect(queue.queueSize).assertEqual(0);
      // 重新同意后也不会复活撤回前的事件。
      queue.onPrivacyChanged(PrivacyStateRaw.CONSENTED);
      queue.flush();
      expect(handed.length).assertEqual(1);
    });

    it('lesson16_environment_switch_cancels_in_flight_batch_and_keeps_queue', 0, async () => {
      const file: QueueBox = new QueueBox();
      const queue: TrackerQueue = makeQueue(file, (_e: string[]): boolean => true, PrivacyStateRaw.CONSENTED);
      const gate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      queue.attachEnvironment(gate);
      const handed: string[][] = [];
      const pending: ((ok: boolean) => void)[] = [];
      const valid: UploadTicket[] = [];
      queue.asyncSink = (events: string[], ticket: UploadTicket): Promise<boolean> => {
        handed.push(events);
        valid.push(ticket);
        return new Promise<boolean>((resolve: (ok: boolean) => void) => {
          pending.push(resolve);
        });
      };
      queue.track(ClientEvents.appLaunch('Home'));
      queue.flush();
      expect(handed.length).assertEqual(1);
      expect(valid[0].valid).assertTrue();
      // 切换开始（同步关闭闸门）：在途批次作废；切换期间不上报。
      gate.close();
      expect(valid[0].valid).assertFalse();
      queue.flush();
      expect(handed.length).assertEqual(1);
      gate.reopen(false);
      // 旧批次晚到的「成功」不改队列。
      pending[0](true);
      await flush();
      expect(queue.queueSize).assertEqual(1);
      // 新环境世代里重新上报。
      queue.flush();
      expect(handed.length).assertEqual(2);
      expect(valid[1].valid).assertTrue();
      pending[1](true);
      await flush();
      expect(queue.queueSize).assertEqual(0);
    });
  });
}
