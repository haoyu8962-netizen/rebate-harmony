import { common } from '@kit.AbilityKit';
import {
  ApiClient, ApiConfigFetcher, AppConfig, ClientEvent, ClientPlatformRaw, ConfigFetcher, ConfigStore, DeviceRegistry,
  EnvironmentSwitchGate, EventSink, FileSlot, LocalDataCleaner, PermissionRequester, PermissionResult, PrivacyState,
  PrivacyStateRaw, SystemRepeatingTimer, TrackerFlushScheduler, TrackerQueue, TrackerQueueCleaner
} from 'core';
import { BundledConfig } from 'generated';
import { AppNetwork } from '../network/AppNetwork';
import { HarmonyPermissionSystem } from '../permission/HarmonyPermissionSystem';
import { PermissionPromptModel } from '../permission/PermissionPromptModel';
import { AppUpdate } from '../update/AppUpdate';
import { HARMONY_CHANNEL } from '../update/HarmonyStoreAccess';

/** 沙盒里的文件名（不放 CSB-05 的内容）。 */
const CONFIG_LKG_FILE: string = 'couli_config_lkg.json';
const TRACKER_QUEUE_FILE: string = 'couli_tracker_queue.json';
const PERMISSION_THROTTLE_FILE: string = 'couli_permission_throttle.json';

/**
 * 埋点上报 sink：openapi 还没有 /v1/events（needs.md N-20）。TODO(N-20)：契约补上后改为经 ApiClient 上报；在那之前不上报，
 * 返回 false（未确认），事件留在本地队列里（上限 500 条，离线缓存规则同 03 §4.7），接上后再发。
 */
const PENDING_EVENTS_SINK: EventSink = (_events: string[]): boolean => false;

/** 环境切换清 LKG（03 §3.6）。「清除缓存」不清它（03 §4.3）。 */
class ConfigLkgCleaner implements LocalDataCleaner {
  readonly name: string = 'config_lkg';
  private readonly store: ConfigStore;

  constructor(store: ConfigStore) {
    this.store = store;
  }

  clean(): Promise<void> {
    try {
      this.store.clearForEnvironmentSwitch();
      return Promise.resolve();
    } catch (e) {
      return Promise.reject(e);
    }
  }
}

/**
 * App 组合处的客户端核心（APP-03b；Android 在 AppModule 里做同样的事）：ConfigStore（LKG）、TrackerQueue、PermissionRequester。
 * EntryAbility.onCreate 调 compose 一次（在 AppNetwork.compose 之后）。
 * - ConfigStore：环境闸门 SETTLED 后（AppPrivacy.environmentSettled）冷启动——同步读 LKG 文件，再后台经 ApiClient 拉
 *   getConfig（基本模式、首启未同意时也在匿名白名单里）；回前台带 If-None-Match 再拉。LKG 登记进环境切换清理（config_lkg）。
 *   运行中切换环境完成（EnvironmentSwitchGate 重新打开，新环境已提交）后重新拉取（R1-02、lessons 5）。
 * - TrackerQueue：隐私结论第一次读出时按该结论创建（未同意、撤回清理未完成时不读旧队列并删残留文件）；之后隐私变化与撤回清理
 *   完成经 privacyChanged 通知（撤回同意立即清空队列、不再上报）。队列登记在撤回清理名单与切换环境清理里（tracker_queue，
 *   R1-06）。每 10 秒由 TrackerFlushScheduler 定时 flush（lessons 8）；是否上报由队列里同一套检查决定：已同意且撤回清理完成、
 *   强更检查有结果、环境 SETTLED 且闸门打开；每批绑定隐私、环境、队列世代（lessons 16）。冷启动（lessons 15）：compose 里
 *   启动定时器，AppPrivacy.start 读出隐私结论时显式创建队列（已同意则加载旧队列），之后每 10 秒按同一套检查提交。user_id 取 ApiClient.sessionAccount（经过会话隔离判断，lessons 9）。生产 sink 待 N-20。
 * - PermissionRequester：原生入口与以后的桥方法 perm.request 都只走 AppClientCore.requestPermission；系统调用经
 *   HarmonyPermissionSystem，用途说明与去设置引导经 PermissionPromptModel（RootPage 盖在最上层显示）。节流记录在沙盒文件里，
 *   「清除缓存」与切换环境都不清。
 */
export class AppClientCore {
  private static instance: AppClientCore | null = null;

  static get shared(): AppClientCore {
    if (AppClientCore.instance === null) {
      AppClientCore.instance = new AppClientCore();
    }
    return AppClientCore.instance;
  }

  private context: common.UIAbilityContext | null = null;
  private system: HarmonyPermissionSystem | null = null;
  private configStore: ConfigStore | null = null;
  private configStarted: boolean = false;
  private tracker: TrackerQueue | null = null;
  private trackerSlot: FileSlot | null = null;
  private permissions: PermissionRequester | null = null;
  private readonly sessionId: string = TrackerQueue.uuid();
  private flushScheduler: TrackerFlushScheduler | null = null;
  /** 隐私世代（撤回同意加 1）：AppPrivacy.start 接到 PrivacyGate.consentCycle；埋点批次的 ticket 用（lessons 16）。 */
  consentCycle: () => number = () => 0;

  /** 已组合的 ConfigStore（compose 之前为 null）。 */
  get config(): ConfigStore | null {
    return this.configStore;
  }

  /** EntryAbility.onCreate 调；同一进程里 Ability 重建时只换上新的 Ability 上下文（系统权限框绑定它）。 */
  compose(context: common.UIAbilityContext): void {
    if (this.context !== null) {
      this.context = context;
      if (this.system !== null) {
        this.system.attach(context);
      }
      return;
    }
    this.context = context;
    const files: string = context.filesDir;
    const lkg: FileSlot = FileSlot.at(files, CONFIG_LKG_FILE);
    const fetcher: ConfigFetcher = ApiConfigFetcher.create((): ApiClient | null => AppNetwork.client);
    const store: ConfigStore = new ConfigStore((): string | null => lkg.read(), (value: string | null): void => lkg.write(value),
      fetcher, (): number => Date.now(), BundledConfig.DATA_JSON);
    this.configStore = store;
    AppConfig.cleaners.register(new ConfigLkgCleaner(store));
    // 运行中切换环境完成（新环境已提交、闸门重新打开）：重新拉取配置（旧环境的 LKG 已在清理阶段删除）。
    store.attachEnvironment(EnvironmentSwitchGate.shared);

    this.trackerSlot = FileSlot.at(files, TRACKER_QUEUE_FILE);
    // 同名替换撤回清理名单里的占位（R1-06）：撤回同意（cleanOnly）与切换环境（cleanAll）都清空队列，删不掉报告失败。
    AppConfig.cleaners.register(new TrackerQueueCleaner((): void => this.clearTrackerQueue()));

    const throttle: FileSlot = FileSlot.at(files, PERMISSION_THROTTLE_FILE);
    const system: HarmonyPermissionSystem = new HarmonyPermissionSystem(context);
    this.system = system;
    const prompt: PermissionPromptModel = PermissionPromptModel.shared;
    this.permissions = new PermissionRequester((): string | null => throttle.read(),
      (value: string | null): void => throttle.write(value), (): number => Date.now(), ClientPlatformRaw.HARMONY,
      (permission: string): string => system.status(permission),
      (purposeKey: string, continueKey: string | null): Promise<void> => prompt.showRationale(purposeKey, continueKey),
      (permission: string): Promise<string> => system.request(permission),
      (messageKey: string | null, buttonKey: string): void => prompt.showSettingsGuide(messageKey, buttonKey));
    prompt.openSettings = (): void => system.openSettings(prompt.currentPermission);

    const scheduler: TrackerFlushScheduler = new TrackerFlushScheduler(new SystemRepeatingTimer(),
      (): void => this.flushEvents(), TrackerQueue.FLUSH_INTERVAL_MILLIS);
    this.flushScheduler = scheduler;
    scheduler.start();
  }

  /** 环境闸门 SETTLED：配置冷启动（读 LKG → 后台拉取）。同一进程只做一次。 */
  environmentSettled(): void {
    const store: ConfigStore | null = this.configStore;
    if (store === null || this.configStarted) {
      return;
    }
    this.configStarted = true;
    store.onColdStart();
  }

  /** 回前台：带 ETag 拉配置；埋点尝试上报一次。 */
  onForeground(): void {
    const store: ConfigStore | null = this.configStore;
    if (store !== null && this.configStarted) {
      store.onForeground();
    }
    this.flushEvents();
  }

  /**
   * 隐私结论（router PrivacyState 取值）或撤回清理状态变化：第一次按它创建埋点队列，之后通知队列（非同意立即清空）。
   * withdrawalCleanupDone 为 false（撤回痕迹还在）时按未同意（TrackerQueue.effectivePrivacy，R1-06）。
   */
  privacyChanged(state: PrivacyState, withdrawalCleanupDone: boolean): void {
    const decided: string = state === PrivacyState.CONSENTED ? PrivacyStateRaw.CONSENTED :
      state === PrivacyState.BASIC_MODE ? PrivacyStateRaw.BASIC_MODE : PrivacyStateRaw.NOT_DECIDED;
    const raw: string = TrackerQueue.effectivePrivacy(decided, withdrawalCleanupDone);
    const existing: TrackerQueue | null = this.tracker;
    if (existing !== null) {
      existing.onPrivacyChanged(raw);
      return;
    }
    const slot: FileSlot | null = this.trackerSlot;
    if (slot === null) {
      return;
    }
    const queue: TrackerQueue = new TrackerQueue((): string | null => slot.read(),
      (value: string | null): void => slot.write(value), PENDING_EVENTS_SINK, raw,
      (): string | null => AppClientCore.userId(), '', ClientPlatformRaw.HARMONY, AppNetwork.appVersion, this.sessionId,
      (): number => Date.now(), (): boolean => AppClientCore.uploadAllowed());
    queue.deviceIdSource = (): string | null => {
      const devices: DeviceRegistry | null = AppNetwork.devices;
      return devices === null ? null : devices.deviceId();
    };
    queue.channelSource = (): string | null => HARMONY_CHANNEL;
    // 批次归属（lessons 16、17）：每批绑定隐私、环境、队列三种世代，交给 sink 前与改写队列前核对；环境闸门关闭（切换开始，
    // 同步）时取消在途上报。
    queue.privacyEpoch = (): number => this.consentCycle();
    queue.attachEnvironment(EnvironmentSwitchGate.shared);
    this.tracker = queue;
  }

  /** 采集一个事件（只能来自 ClientEvents 的生成函数）。还没创建队列时丢弃。 */
  track(event: ClientEvent): boolean {
    const queue: TrackerQueue | null = this.tracker;
    return queue === null ? false : queue.track(event);
  }

  /** 原生入口申请系统权限（以后的 perm.request 同一入口）。compose 之前为 unavailable。 */
  requestPermission(permission: string, fromSettings: boolean = false): Promise<PermissionResult> {
    const requester: PermissionRequester | null = this.permissions;
    if (requester === null) {
      return Promise.resolve(new PermissionResult('unavailable'));
    }
    PermissionPromptModel.shared.currentPermission = permission;
    return requester.request(permission, fromSettings);
  }

  /** 切换环境的清理项调用：清空队列（内存与文件）；还没创建队列时直接删文件。删不掉抛错。 */
  clearTrackerQueue(): void {
    const queue: TrackerQueue | null = this.tracker;
    if (queue !== null) {
      queue.clear();
      return;
    }
    const slot: FileSlot | null = this.trackerSlot;
    if (slot !== null) {
      slot.write(null);
    }
  }

  private flushEvents(): void {
    const queue: TrackerQueue | null = this.tracker;
    if (queue !== null) {
      queue.flush();
    }
  }

  /** 埋点 user_id：经过会话隔离判断的有效账号（游客、隔离中、读不出、撤回清理未完成为 null；lessons 9）。 */
  private static userId(): string | null {
    const client: ApiClient | null = AppNetwork.client;
    return client === null ? null : client.sessionAccount();
  }

  /**
   * 上报前提（与隐私检查一起在 TrackerQueue.flush 里判断）：环境已 SETTLED（AppConfig.endpoints 有值；冷启动对账完成之前、
   * 阻断时都没有）、不在切换环境中、强更检查有确定结论（AppUpdate.uploadReady
   * 读 routerStatus：检查中、未知（含复查失败）只入队，R3-01；lessons 15：冷启动加载的旧队列在这些都就绪后由定时上报按时提交）。
   */
  private static uploadAllowed(): boolean {
    return AppConfig.endpoints() !== undefined && EnvironmentSwitchGate.shared.open
      && AppUpdate.shared.uploadReady();
  }
}
