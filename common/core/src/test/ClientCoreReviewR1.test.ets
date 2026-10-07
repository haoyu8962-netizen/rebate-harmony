// APP-03b 鸿蒙第 1 轮评审（harmony-review-r1.md R1-01…R1-06）与三端共性问题（cross-platform-lessons.md 1–11）的回归测试。
// 每条都按评审里的失败场景复现：修复前这些断言会失败。本地假服务，不连任何真实地址。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClient, ApiResult, CleanReport, ClientEvents, ConfigReply, ConfigStore, DeviceIdentityCleaner, DeviceIdPolicy,
  EnvironmentSwitchGate, FileOps, FileSlot, LocalDataCleaner, LocalDataCleanerRegistry, MemoryPrivacyStore, NetworkHeaders, PrivacyGate,
  PrivacyStateRaw, PrivacyWithdrawalCleaners, RepeatingTimer, SecureSessionTokens, TrackerFlushScheduler, TrackerQueue,
  TrackerQueueCleaner, TransportRequest, TransportResponse
} from '../../Index';
import {
  CapturingScheduler, FlakySecureStore, OTHER_ODID, RegistryRig, SIGN_SECRET, TextBox, VALID_ODID, registered, tokensJson
} from './ClientCoreIntegration.test';
import { Deferred, Rig, envelope, flush, header, openLinkRequest, tokenPair } from './NetworkTestRig';

const REJECT_HASH: string = '{"fields":["device_hash"]}';

/**
 * 模拟运行中切换环境（EnvironmentSwitcher 在 src/staging，本机单测按 Release 源码编译）：同样的顺序与闸门调用——
 * 同步关闭闸门 → 清理 → （写环境记录）→ 提交后重新打开。midway 在清理后、提交前执行（环境记录仍在异步写入的窗口）。
 */
async function switchEnvironment(gate: EnvironmentSwitchGate, cleaners: LocalDataCleanerRegistry,
  midway: () => Promise<void>): Promise<CleanReport> {
  gate.close();
  const report: CleanReport = await cleaners.cleanAll();
  await midway();
  gate.reopen(report.ok);
  return report;
}

/** 用函数实现的清理项。 */
class FnCleaner implements LocalDataCleaner {
  readonly name: string;
  private readonly action: () => void;

  constructor(name: string, action: () => void) {
    this.name = name;
    this.action = action;
  }

  clean(): Promise<void> {
    try {
      this.action();
      return Promise.resolve();
    } catch (e) {
      return Promise.reject(e);
    }
  }
}

/** 可注入失败的内存文件系统（lessons 1：残留 .tmp、删除失败）。 */
class MemoryFileOps implements FileOps {
  readonly files: Map<string, string> = new Map<string, string>();
  failRemove: string[] = [];

  exists(path: string): boolean {
    return this.files.has(path);
  }

  readText(path: string): string {
    const value: string | undefined = this.files.get(path);
    if (value === undefined) {
      throw new Error('no such file');
    }
    return value;
  }

  writeDurable(path: string, value: string): void {
    this.files.set(path, value);
  }

  rename(from: string, to: string): void {
    const value: string | undefined = this.files.get(from);
    if (value === undefined) {
      throw new Error('no such file');
    }
    this.files.delete(from);
    this.files.set(to, value);
  }

  remove(path: string): void {
    if (this.failRemove.indexOf(path) >= 0) {
      throw new Error('unlink failed');
    }
    this.files.delete(path);
  }
}

/** 埋点队列文件：可模拟删除失败。 */
class QueueFile {
  value: string | null = null;
  failDelete: boolean = false;

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    if (value === null && this.failDelete) {
      throw new Error('delete failed');
    }
    this.value = value;
  }
}

/** 手动触发的周期定时器。 */
class ManualTimer implements RepeatingTimer {
  starts: number = 0;
  stops: number = 0;
  action: (() => void) | null = null;
  interval: number = 0;

  start(intervalMillis: number, action: () => void): number {
    this.starts++;
    this.interval = intervalMillis;
    this.action = action;
    return this.starts;
  }

  stop(_handle: number): void {
    this.stops++;
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

function makeConfigStore(file: TextBox, fetcher: ManualFetcher, bundled: string): ConfigStore {
  return new ConfigStore((): string | null => file.read(), (value: string | null): void => file.write(value),
    (etag: string | null, done: (reply: ConfigReply) => void): void => fetcher.fetch(etag, done), (): number => 0,
    bundled);
}

function hashOf(odid: string): string {
  return DeviceIdPolicy.hash(odid);
}

function bodyOf(odid: string): string {
  return '{"device_hash":"' + hashOf(odid) + '","id_source":"odid"}';
}

export default function clientCoreReviewR1Test() {
  describe('ClientCoreReviewR1', () => {
    // ---------------------------------------------------------------- R1-01 / lessons 10、2
    it('r1_01_switch_gate_blocks_registration_and_discards_cross_switch_success', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      const envGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      rr.registry.attachEnvironment(envGate);
      const restarts: boolean[] = [];
      rr.registry.onRestartNeeded = (immediate: boolean): void => {
        restarts.push(immediate);
      };
      const cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      DeviceIdentityCleaner.register(cleaners, rr.registry);
      // 环境 A 的注册在途（退避任务），这时开始切换到 B。网络层的地址故意仍指向 A（最坏情况），只靠注册自己的世代核对。
      const inFlight: Deferred = new Deferred();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => inFlight.promise;
      const crossing: Promise<boolean> = rr.registry.register();
      await flush();
      expect(rr.devicesSent().length).assertEqual(1);
      envGate.close();
      // 清理之前：退避任务再次注册，只会共用在途的那一次，不另发。
      const beforeClean: Promise<boolean> = rr.registry.register();
      await cleaners.cleanAll();
      // 清理完成、新环境还没提交：退避任务再次注册，不得发出（哪怕地址仍指向 A）。
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(registered('dev-A-late'));
      const duringSwitch: boolean = await rr.registry.register();
      // A 的在途注册在清理之后、提交之前成功返回：旧凭据不得写入。
      inFlight.resolve(registered('dev-A'));
      await flush();
      expect(rr.store.deviceId === null).assertTrue();
      expect(JSON.stringify(restarts)).assertEqual('[]');
      envGate.reopen(true);
      expect(await beforeClean).assertFalse();
      expect(duringSwitch).assertFalse();
      expect(await crossing).assertFalse();
      expect(rr.devicesSent().length).assertEqual(1);
      expect(rr.store.deviceId === null).assertTrue();
      expect(rr.registry.deviceId() === null).assertTrue();
      // 新环境提交后才通知立即重新注册；注册到的是 B 的凭据。
      expect(JSON.stringify(restarts)).assertEqual('[true]');
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(registered('dev-B'));
      expect(await rr.registry.register()).assertTrue();
      expect(rr.registry.deviceId()).assertEqual('dev-B');
    });

    it('r1_01_lesson2_stale_failure_and_20001_do_not_touch_new_generation', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      const envGate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      rr.registry.attachEnvironment(envGate);
      const cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      DeviceIdentityCleaner.register(cleaners, rr.registry);
      // 旧注册收到 20001 device_hash，但结果分支在切换（清理）之后才执行。
      const inFlight: Deferred = new Deferred();
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => inFlight.promise;
      const crossing: Promise<boolean> = rr.registry.register();
      await flush();
      const readsBefore: number = rr.reader.reads;
      envGate.close();
      await cleaners.cleanAll();
      inFlight.resolve(envelope(20001, REJECT_HASH));
      expect(await crossing).assertFalse();
      // 失效的结果：不记被拒哈希、不重读标识、不再发送。
      expect(rr.registry.rejectedHashCount).assertEqual(0);
      expect(rr.reader.reads).assertEqual(readsBefore);
      expect(rr.devicesSent().length).assertEqual(1);
      envGate.reopen(true);
      // 新环境读到同一个有效 ODID：照常注册（没被旧世代的拒绝拦住）。
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(registered('dev-B'));
      expect(await rr.registry.register()).assertTrue();
      expect(rr.devicesSent()[1].body).assertEqual(bodyOf(VALID_ODID));
    });

    it('r1_01_gate_token_and_listeners', 0, () => {
      const gate: EnvironmentSwitchGate = new EnvironmentSwitchGate();
      const seen: boolean[] = [];
      gate.onReopened((_s: boolean): void => {
        throw new Error('listener failed');
      });
      gate.onReopened((switched: boolean): void => {
        seen.push(switched);
      });
      expect(gate.token()).assertEqual(0);
      gate.close();
      expect(gate.open).assertFalse();
      expect(gate.token() === null).assertTrue();
      gate.reopen(false);
      expect(gate.token()).assertEqual(1);
      gate.reopen(true);
      expect(JSON.stringify(seen)).assertEqual('[false]');
    });

    // ---------------------------------------------------------------- R1-02 / lessons 5
    it('r1_02_switch_commit_restarts_registration_and_config_fetch', 0, async () => {
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
      const config: ConfigStore = makeConfigStore(lkg, fetcher, '{}');
      config.attachEnvironment(envGate);
      config.onColdStart();
      fetcher.reply('{"dict_version":"env-a"}');
      const cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      DeviceIdentityCleaner.register(cleaners, rr.registry);
      cleaners.register(new FnCleaner('config_lkg', (): void => config.clearForEnvironmentSwitch()));
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(registered('dev-A'));
      gate.agree(0);
      gate.onConsented(0);
      await flush();
      expect(rr.registry.deviceId()).assertEqual('dev-A');
      expect(scheduler.actions.length).assertEqual(0);
      expect(fetcher.calls).assertEqual(1);

      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> => Promise.resolve(registered('dev-B'));
      let sentDuringSwitch: number = -1;
      let fetchesDuringSwitch: number = -1;
      const report: CleanReport = await switchEnvironment(envGate, cleaners, async (): Promise<void> => {
        await flush();
        sentDuringSwitch = rr.devicesSent().length;
        fetchesDuringSwitch = fetcher.calls;
      });
      expect(report.ok).assertTrue();
      // 清理与提交期间不注册、不拉配置；提交之后立即重新注册（同一同意周期，onConsented 不会再跑），并重新拉配置。
      expect(sentDuringSwitch).assertEqual(1);
      expect(fetchesDuringSwitch).assertEqual(1);
      await flush();
      expect(rr.devicesSent().length).assertEqual(2);
      expect(rr.registry.deviceId()).assertEqual('dev-B');
      expect(fetcher.calls).assertEqual(2);
      expect(config.sourceRaw).assertEqual('bundled');
      fetcher.reply('{"dict_version":"env-b"}');
      expect(config.value('dict_version')).assertEqual('"env-b"');
    });

    // ---------------------------------------------------------------- R1-03 / lessons 6
    it('r1_03_refresh_10402_reregisters_once_and_replays_refresh', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      const registration: Deferred = new Deferred();
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/devices') >= 0) {
          return registration.promise;
        }
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(header(request, NetworkHeaders.DEVICE_ID) === 'dev-old' ? envelope(10402, '{}') :
          envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
        }
        return Promise.resolve(header(request, NetworkHeaders.AUTHORIZATION) === 'Bearer new-access' ?
        envelope(0, '{}') : envelope(10002, '{}'));
      };
      // 业务请求 10002 → 内部刷新 → 刷新收到 10402。
      const pending: Promise<ApiResult> = rr.rig.client.request(openLinkRequest());
      await flush();
      // 刷新走设备注册入口（与普通请求的 10402 同一个单飞入口），只发 1 次注册。
      expect(rr.devicesSent().length).assertEqual(1);
      expect(rr.registry.deviceId() === null).assertTrue();
      registration.resolve(registered('dev-new', 'test-only.install.device-b'));
      const result: ApiResult = await pending;
      expect(result.ok).assertTrue();
      expect(rr.devicesSent().length).assertEqual(1);
      const refreshes: TransportRequest[] = rr.rig.server.received.filter((r: TransportRequest) =>
      r.url.indexOf('/v1/auth/refresh') >= 0);
      // 刷新：首发（旧凭据，10402）+ 重新组头、用新凭据重新签名后重放 1 次。
      expect(refreshes.length).assertEqual(2);
      expect(header(refreshes[0], NetworkHeaders.DEVICE_ID)).assertEqual('dev-old');
      expect(header(refreshes[1], NetworkHeaders.DEVICE_ID)).assertEqual('dev-new');
      expect(header(refreshes[1], NetworkHeaders.SIGN) !== undefined).assertTrue();
      expect(header(refreshes[1], NetworkHeaders.SIGN) !== header(refreshes[0], NetworkHeaders.SIGN)).assertTrue();
      // 没有清会话；业务请求用新令牌、新凭据重放成功。
      expect(rr.rig.sessionEffects.length).assertEqual(0);
      expect(rr.rig.tokens.clearCount).assertEqual(0);
      expect(rr.rig.tokens.accessToken()).assertEqual('new-access');
      expect(header(rr.rig.server.last('/open'), NetworkHeaders.DEVICE_ID)).assertEqual('dev-new');
    });

    it('r1_03_refresh_uses_the_same_registrar_entry_as_business_requests', 0, async () => {
      const rig: Rig = new Rig();
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ? envelope(10402, '{}') : envelope(10002, '{}'));
      rig.registrar.result = (): Promise<boolean> => Promise.resolve(false);
      await rig.client.request(openLinkRequest());
      // 刷新的 10402 交给同一个 DeviceRegistrar.reregister，带被拒的 device_id。
      expect(rig.registrar.calls).assertEqual(1);
      expect(JSON.stringify(rig.registrar.usedDeviceIds)).assertEqual('["device-fixture"]');
      expect(rig.sessionEffects.length).assertEqual(0);
    });

    it('r1_03_refresh_10402_failed_reregistration_keeps_session', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/devices') >= 0) {
          return Promise.resolve(envelope(50001, '{}'));
        }
        if (request.url.indexOf('/v1/auth/refresh') >= 0) {
          return Promise.resolve(envelope(10402, '{}'));
        }
        return Promise.resolve(envelope(10002, '{}'));
      };
      const result: ApiResult = await rr.rig.client.request(openLinkRequest());
      expect(result.ok).assertFalse();
      expect(rr.devicesSent().length).assertEqual(1);
      expect(rr.rig.server.count('/v1/auth/refresh')).assertEqual(1);
      // 设备注册失败不是刷新被拒：不清会话、不发会话级 Effect；交给退避流程。
      expect(rr.rig.sessionEffects.length).assertEqual(0);
      expect(rr.rig.tokens.clearCount).assertEqual(0);
      expect(rr.rig.tokens.accessToken()).assertEqual('old-access');
      expect(rr.lost).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-04 / lessons 3
    it('r1_04_rejected_hash_after_reread_is_never_resent', 0, async () => {
      const rr: RegistryRig = new RegistryRig([VALID_ODID, OTHER_ODID]);
      rr.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(20001, REJECT_HASH));
      expect(await rr.registry.register()).assertFalse();
      // 读 A 被拒 → 重读得到 B，B 也被拒：两次都记下。
      expect(rr.devicesSent().length).assertEqual(2);
      expect(rr.devicesSent()[0].body).assertEqual(bodyOf(VALID_ODID));
      expect(rr.devicesSent()[1].body).assertEqual(bodyOf(OTHER_ODID));
      expect(rr.registry.rejectedHashCount).assertEqual(2);
      // 下一次退避仍读到 B：不再发送（原来会发出 A、B、B）。
      expect(await rr.registry.register()).assertFalse();
      expect(await rr.registry.register()).assertFalse();
      expect(rr.devicesSent().length).assertEqual(2);
    });

    // ---------------------------------------------------------------- lessons 4
    it('lesson4_late_10402_reuses_failed_reregistration', 0, async () => {
      const rr: RegistryRig = new RegistryRig();
      rr.store.deviceId = 'dev-old';
      rr.store.installSecret = SIGN_SECRET;
      const opens: Deferred[] = [new Deferred(), new Deferred()];
      let openIndex: number = 0;
      rr.rig.server.handler = (request: TransportRequest): Promise<TransportResponse> => {
        if (request.url.indexOf('/v1/devices') >= 0) {
          return Promise.resolve(envelope(50001, '{}'));
        }
        const deferred: Deferred = opens[openIndex];
        openIndex++;
        return deferred.promise;
      };
      // 两个请求都带旧 device_id 发出。
      const first: Promise<ApiResult> = rr.rig.client.request(openLinkRequest());
      const second: Promise<ApiResult> = rr.rig.client.request(openLinkRequest());
      await flush();
      expect(openIndex).assertEqual(2);
      opens[0].resolve(envelope(10402, '{}'));
      expect((await first).ok).assertFalse();
      expect(rr.devicesSent().length).assertEqual(1);
      expect(rr.lost).assertEqual(1);
      // 同一批旧凭据的第二个 10402 晚到：复用失败结果，不再注册、不再触发恢复。
      opens[1].resolve(envelope(10402, '{}'));
      expect((await second).ok).assertFalse();
      expect(rr.devicesSent().length).assertEqual(1);
      expect(rr.lost).assertEqual(1);
    });

    // ---------------------------------------------------------------- R1-05 / lessons 7
    it('r1_05_search_status_falls_back_to_latest_success_across_refreshes_and_restart', 0, () => {
      const file: TextBox = new TextBox();
      const fetcher: ManualFetcher = new ManualFetcher();
      const bundled: string = '{"features":{"search_status":{"taobao":"on","jd":"off"}}}';
      const store: ConfigStore = makeConfigStore(file, fetcher, bundled);
      store.onColdStart();
      fetcher.reply('{"dict_version":"a","features":{"search_status":{"taobao":"off"}}}');
      expect(store.searchStatus('taobao')).assertEqual('off');
      store.onForeground();
      fetcher.reply('{"features":{"search_status":{"jd":"on"}}}');
      // 缺 taobao：用最近一次成功的 off，而不是包内的 on。
      expect(store.searchStatus('taobao')).assertEqual('off');
      expect(store.searchStatus('jd')).assertEqual('on');
      // 顶层键同样回落到上一份成功配置。
      expect(store.value('dict_version')).assertEqual('"a"');
      store.onForeground();
      fetcher.reply('{"features":{}}');
      expect(store.searchStatus('taobao')).assertEqual('off');
      expect(store.searchStatus('jd')).assertEqual('on');
      // 重启：拉取完成前读 LKG，结果与重启前一致。
      const restarted: ConfigStore = makeConfigStore(file, new ManualFetcher(), bundled);
      restarted.onColdStart();
      expect(restarted.sourceRaw).assertEqual('lkg');
      expect(restarted.searchStatus('taobao')).assertEqual('off');
      expect(restarted.searchStatus('jd')).assertEqual('on');
      // 切换环境清掉回落数据。
      restarted.clearForEnvironmentSwitch();
      expect(restarted.searchStatus('taobao')).assertEqual('on');
    });

    // ---------------------------------------------------------------- R1-06 / lessons 11
    it('r1_06_failed_queue_delete_keeps_withdrawal_pending_and_blocks_reload', 0, async () => {
      const file: QueueFile = new QueueFile();
      const uploaded: string[] = [];
      const store: MemoryPrivacyStore = new MemoryPrivacyStore();
      const makeQueue: (privacy: string) => TrackerQueue = (privacy: string): TrackerQueue => new TrackerQueue((): string | null => file.read(),
        (value: string | null): void => file.write(value), (events: string[]): boolean => {
          for (const event of events) {
            uploaded.push(event);
          }
          return true;
        }, privacy, (): string | null => null, 'dev-1', 'harmony', '1.2.0', 'session-1', (): number => 0,
        (): boolean => true);
      const makeGate: (queueRef: () => TrackerQueue) => PrivacyGate = (queueRef: () => TrackerQueue): PrivacyGate => {
        const cleaners: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
        PrivacyWithdrawalCleaners.registerPlaceholders(cleaners);
        cleaners.register(new TrackerQueueCleaner((): void => queueRef().clear()));
        const created: PrivacyGate = new PrivacyGate(store, (): number => 0, '1');
        created.withdrawalCleanup = (): void => {
          PrivacyWithdrawalCleaners.run(cleaners).then((report: CleanReport) => {
            if (report.ok) {
              created.withdrawalCleanupDone();
            }
          });
        };
        return created;
      };
      expect(PrivacyWithdrawalCleaners.NAMES.indexOf(PrivacyWithdrawalCleaners.TRACKER_QUEUE) >= 0).assertTrue();

      let queue: TrackerQueue = makeQueue(PrivacyStateRaw.CONSENTED);
      const gate: PrivacyGate = makeGate((): TrackerQueue => queue);
      gate.agree(0);
      expect(queue.track(ClientEvents.appLaunch('Home'))).assertTrue();
      expect(queue.track(ClientEvents.appLaunch('Home'))).assertTrue();
      // 撤回同意：删除队列文件失败 → 撤回清理不算完成。
      file.failDelete = true;
      gate.withdraw(0);
      await flush();
      queue.onPrivacyChanged(TrackerQueue.effectivePrivacy(gate.state(0).decisionRaw, gate.credentialsReadable()));
      expect(queue.queueSize).assertEqual(0);
      expect(queue.pendingPurge).assertTrue();
      expect(gate.credentialsReadable()).assertFalse();
      expect(file.value !== null).assertTrue();
      // 本进程重新同意：撤回清理没完成，按未同意（不采集、不上报）。
      gate.agree(0);
      queue.onPrivacyChanged(TrackerQueue.effectivePrivacy(gate.state(0).decisionRaw, gate.credentialsReadable()));
      expect(queue.track(ClientEvents.appLaunch('Home'))).assertFalse();

      // 没产生新事件就重启：撤回痕迹还在 → 不加载旧队列。
      const restartedGate: PrivacyGate = makeGate((): TrackerQueue => queue);
      restartedGate.coldStart(0);
      queue = makeQueue(TrackerQueue.effectivePrivacy(restartedGate.state(0).decisionRaw,
        restartedGate.credentialsReadable()));
      expect(queue.queueSize).assertEqual(0);
      expect(queue.pendingPurge).assertTrue();
      restartedGate.agree(0);
      queue.onPrivacyChanged(TrackerQueue.effectivePrivacy(restartedGate.state(0).decisionRaw,
        restartedGate.credentialsReadable()));
      queue.flush();
      expect(uploaded.length).assertEqual(0);
      // 存储恢复：重试撤回清理成功 → 文件删掉、痕迹清除，之后才恢复采集。
      file.failDelete = false;
      expect(restartedGate.retryPendingWithdrawalCleanup()).assertTrue();
      await flush();
      expect(file.value === null).assertTrue();
      expect(restartedGate.credentialsReadable()).assertTrue();
      queue.onPrivacyChanged(TrackerQueue.effectivePrivacy(restartedGate.state(0).decisionRaw,
        restartedGate.credentialsReadable()));
      expect(queue.pendingPurge).assertFalse();
      queue.flush();
      expect(uploaded.length).assertEqual(0);
      expect(queue.track(ClientEvents.appLaunch('Home'))).assertTrue();
      queue.flush();
      expect(uploaded.length).assertEqual(1);
    });

    // ---------------------------------------------------------------- lessons 1
    it('lesson1_delete_removes_leftover_temp_file_and_reports_failure', 0, () => {
      const ops: MemoryFileOps = new MemoryFileOps();
      const slot: FileSlot = new FileSlot('/sandbox/couli_tracker_queue.json', ops);
      slot.write('{"events":["new"]}');
      expect(ops.files.has(FileSlot.tempOf(slot.path))).assertFalse();
      // 上次写到一半（改名前被回收）：临时文件里还有旧数据。
      ops.files.set(FileSlot.tempOf(slot.path), '{"events":["interrupted"]}');
      slot.write(null);
      expect(ops.files.size).assertEqual(0);
      // 临时文件删不掉：正式文件照删，但报告失败（调用方保留待清理）。
      slot.write('{"events":["x"]}');
      ops.files.set(FileSlot.tempOf(slot.path), 'stale');
      ops.failRemove = [FileSlot.tempOf(slot.path)];
      let threw: boolean = false;
      try {
        slot.write(null);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(ops.files.has(slot.path)).assertFalse();
      expect(ops.files.has(FileSlot.tempOf(slot.path))).assertTrue();
      // 经埋点队列：清空失败记为待清理，恢复后重试删除。
      const queue: TrackerQueue = new TrackerQueue((): string | null => slot.read(),
        (value: string | null): void => slot.write(value), (_e: string[]): boolean => true, PrivacyStateRaw.NOT_DECIDED,
        (): string | null => null, 'dev-1', 'harmony', '1.2.0', 'session-1', (): number => 0, (): boolean => true);
      expect(queue.pendingPurge).assertTrue();
      ops.failRemove = [];
      queue.flush();
      expect(queue.pendingPurge).assertFalse();
      expect(ops.files.size).assertEqual(0);
    });

    // ---------------------------------------------------------------- lessons 8
    it('lesson8_flush_scheduler_ticks_every_interval_under_same_state_checks', 0, () => {
      const uploaded: string[] = [];
      let envOpen: boolean = true;
      const queue: TrackerQueue = new TrackerQueue((): string | null => null, (_v: string | null): void => {
      }, (events: string[]): boolean => {
        for (const event of events) {
          uploaded.push(event);
        }
        return true;
      }, PrivacyStateRaw.CONSENTED, (): string | null => null, 'dev-1', 'harmony', '1.2.0', 'session-1',
        (): number => 0, (): boolean => envOpen);
      const timer: ManualTimer = new ManualTimer();
      const scheduler: TrackerFlushScheduler = new TrackerFlushScheduler(timer, (): void => queue.flush(),
        TrackerQueue.FLUSH_INTERVAL_MILLIS);
      scheduler.start();
      scheduler.start();
      expect(timer.starts).assertEqual(1);
      expect(timer.interval).assertEqual(10000);
      // 1～9 条、没有新事件：到点也要上报。
      for (let i: number = 0; i < 3; i++) {
        queue.track(ClientEvents.appLaunch('Home'));
      }
      expect(uploaded.length).assertEqual(0);
      timer.fire();
      expect(uploaded.length).assertEqual(3);
      // 切换环境中（闸门关闭）：到点不上报。
      queue.track(ClientEvents.appLaunch('Home'));
      envOpen = false;
      timer.fire();
      expect(uploaded.length).assertEqual(3);
      // 撤回同意：队列清空，到点不上报。
      envOpen = true;
      queue.onPrivacyChanged(PrivacyStateRaw.BASIC_MODE);
      timer.fire();
      expect(uploaded.length).assertEqual(3);
      scheduler.stop();
      expect(timer.stops).assertEqual(1);
      expect(scheduler.running).assertFalse();
    });

    // ---------------------------------------------------------------- lessons 9
    it('lesson9_tracker_user_id_follows_session_isolation', 0, async () => {
      const secureStore: FlakySecureStore = new FlakySecureStore();
      secureStore.values.set('session_tokens', tokensJson('old-access'));
      const tokens: SecureSessionTokens = new SecureSessionTokens(secureStore);
      const rig: Rig = new Rig(null, null, null, null, null, null, null, tokens);
      const client: ApiClient = rig.client;
      expect(client.sessionAccount()).assertEqual('user-1');
      // 撤回清理未完成（凭据不可读）：没有 user_id。
      rig.context.readable = false;
      expect(client.sessionAccount() === null).assertTrue();
      rig.context.readable = true;
      // 刷新明确失败、删除令牌落盘失败（隔离中）：没有 user_id。
      secureStore.failRemove = true;
      rig.server.handler = (request: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(request.url.indexOf('/v1/auth/refresh') >= 0 ? envelope(10404, '{}') : envelope(10002, '{}'));
      await client.request(openLinkRequest());
      expect(tokens.removalRetryPending).assertTrue();
      expect(client.sessionAccount() === null).assertTrue();
      const uploaded: string[] = [];
      const queue: TrackerQueue = new TrackerQueue((): string | null => null, (_v: string | null): void => {
      }, (events: string[]): boolean => {
        for (const event of events) {
          uploaded.push(event);
        }
        return true;
      }, PrivacyStateRaw.CONSENTED, (): string | null => client.sessionAccount(), 'dev-1', 'harmony', '1.2.0',
        'session-1', (): number => 0, (): boolean => true);
      queue.track(ClientEvents.appLaunch('Home'));
      queue.flush();
      const packet: Record<string, Object> = JSON.parse(uploaded[0]) as Record<string, Object>;
      expect(packet['user_id'] === undefined).assertTrue();
      expect(packet['device_id']).assertEqual('dev-1');
    });
  });
}
