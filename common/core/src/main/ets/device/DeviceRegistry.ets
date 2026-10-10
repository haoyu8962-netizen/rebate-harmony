import { EnvironmentSwitchGate } from '../config/EnvironmentSwitchGate';
import { LocalDataCleaner, LocalDataCleanerRegistry } from '../config/LocalDataCleaner';
import { DeviceIdDecision, DeviceIdPolicy, PrivacyStateRaw } from '../clientcore/DeviceIdPolicy';
import { ApiClient, ApiRequest, ApiResult, CredentialSource, DeviceRegistrar } from '../network/ApiClient';
import { EffectKind } from '../network/ErrorActionMapper';
import { PrivacyWithdrawalCleaners } from '../privacy/PrivacyWithdrawal';
import { DeviceCredentialStore, DeviceIdReader, StoredDevice, StoredDeviceKind } from './DeviceCredentialStore';

/** 一个判定为有效、可以上报的设备哈希。 */
class HashedId {
  readonly hash: string;
  readonly source: string;

  constructor(hash: string, source: string) {
    this.hash = hash;
    this.source = source;
  }
}

/** registerDevice 的请求体（openapi RegisterDeviceRequest）。 */
class RegisterBody {
  device_hash: string;
  id_source: string;

  constructor(deviceHash: string, idSource: string) {
    this.device_hash = deviceHash;
    this.id_source = idSource;
  }
}

/** 一次注册请求的结局。 */
enum SendOutcome {
  SAVED,
  FAILED,
  REREAD_HASH
}

/**
 * 一次注册任务开始时绑定的归属 ticket（cross-platform-lessons 2、10、12、13）：三种世代——
 * - 隐私世代（privacyEpoch：撤回同意加 1，App 接 PrivacyGate 的同意周期）；
 * - 环境世代（EnvironmentSwitchGate.token：切换开始同步加 1，切换中为 null，不开始）；
 * - 清理世代（clear 加 1）。
 * 读标识、发送（ApiRequest.owner，ApiClient 每次实际发送前核对）、处理结果（成功、失败、20001）、保存凭据，每一步都先与
 * 当前值核对，再加上隐私仍是已同意；任何一项变了，这个任务就此结束，什么都不改。
 */
class RegistrationTicket {
  readonly privacy: number;
  readonly environment: number;
  readonly generation: number;

  constructor(privacy: number, environment: number, generation: number) {
    this.privacy = privacy;
    this.environment = environment;
    this.generation = generation;
  }

  same(other: RegistrationTicket): boolean {
    return this.privacy === other.privacy && this.environment === other.environment
      && this.generation === other.generation;
  }
}

/**
 * 一个注册窗口（一次单飞注册）的调用方（harmony-review-r3 R3-03，APP-04 共性 58）：10402 重新注册把发起它的调用方的有效性
 * （ApiRequest.owner，桥调用为 call.valid——到截止时间即失效，剩余预算由它体现；共享刷新为这一轮的「还有有效调用方」）登记
 * 进来；null 是独立的原生调用方（启动 / 退避注册、没有归属守卫的原生请求），一直有效。没有任何调用方的窗口（启动注册）也一直
 * 有效。注册在等待结束、读取标识前、实际发送前检查 live()；注册请求的归属守卫是 owner（同一个函数对象），没有有效调用方时
 * DeviceRegistry.callersChanged 按它取消底层请求。
 */
class RegistrationWindow {
  readonly callers: ((() => boolean) | null)[] = [];
  /** 这个窗口注册请求的归属守卫（send 设置；cancelOwned 按它取消）。 */
  owner: (() => boolean) | null = null;
  /** 已因没有有效调用方取消过（不重复取消）。 */
  cancelled: boolean = false;

  constructor(caller: (() => boolean) | null = null, independent: boolean = false) {
    if (caller !== null || independent) {
      this.callers.push(caller);
    }
  }

  live(): boolean {
    if (this.callers.length === 0) {
      return true;
    }
    for (const caller of this.callers) {
      if (RegistrationWindow.alive(caller)) {
        return true;
      }
    }
    return false;
  }

  static alive(caller: (() => boolean) | null): boolean {
    if (caller === null) {
      return true;
    }
    try {
      return caller();
    } catch (e) {
      return false;
    }
  }
}

/**
 * 一次 10402 重新注册的完整结果，按「被拒的凭据世代」（被拒请求带的 device_id）与 ticket 保存（lessons 4、18；
 * harmony-review-r2 R2-02）：每个被拒凭据各一条，不只留最近一次——晚到的 10402 复用它所属凭据的那次结果（成功或失败），
 * 不覆盖别的凭据的记录，也不另发注册。
 */
class ReregisterRecord {
  readonly ticket: RegistrationTicket;
  /** 结果所依赖的注册窗口（harmony-review-r4 R4-01）：记录进行中时，复用它的晚到 10402 把调用方登记到这个窗口。 */
  readonly window: RegistrationWindow | null;
  /** 等这条记录结果的调用方（并入在途窗口的记录按它们判定还要不要为这个被拒凭据重放）。 */
  readonly callers: ((() => boolean) | null)[] = [];
  /** 结果已兑现（已完成的记录直接复用结果，不再登记调用方）。 */
  settled: boolean = false;
  private outcome: Promise<boolean> = Promise.resolve(false);

  constructor(ticket: RegistrationTicket, window: RegistrationWindow | null = null,
    caller: (() => boolean) | null = null) {
    this.ticket = ticket;
    this.window = window;
    this.callers.push(caller);
  }

  get result(): Promise<boolean> {
    return this.outcome;
  }

  /** 绑定结果并在兑现时标记为已完成。 */
  bind(result: Promise<boolean>): ReregisterRecord {
    this.outcome = result;
    result.then((): void => {
      this.settled = true;
    });
    return this;
  }

  /** 进行中的记录又来一个调用方（R4-01）：同时登记到记录与它的注册窗口，窗口只在全部调用方失效时才取消。 */
  join(caller: (() => boolean) | null): void {
    this.callers.push(caller);
    this.window?.callers.push(caller);
  }

  live(): boolean {
    for (const caller of this.callers) {
      if (RegistrationWindow.alive(caller)) {
        return true;
      }
    }
    return false;
  }
}

/**
 * 设备注册（BR-ID-09；03 §4.1、§4.2、§3.6；三端同一行为，与 Android DeviceRegistry 一致）：实现 ApiClient 的 CredentialSource
 * （签名用的 device_id、install_secret）与 DeviceRegistrar（10402 的重新注册）。
 *
 * - register：PrivacyGate.onConsented 的设备注册步骤（退避重试由 PrivacyGate 负责：兑现 false 即失败）。先判隐私（只在已同意且
 *   凭据可读时，BR-ID-11：同意前连标识都不读）与环境闸门（切换环境期间不开始），已有凭据直接成功；凭据读不出不注册（避免重复
 *   注册出新设备）。然后读 ODID，按 DeviceIdPolicy 判定：无效值（取不到、空、全零、无效哈希清单里的值）不注册、不发请求、
 *   不求哈希上报，按退避再读。有效值求 device_hash，调 POST /v1/devices（id_source = odid），成功后先写存储（install_secret
 *   进安全存储）、再改内存。
 * - 归属（lessons 2、10、12、13；R1-01）：每次尝试开始时绑定 RegistrationTicket（隐私、环境、清理三种世代）。
 *   读标识：最后一次核对与 reader.read() 在同一个同步区里（中间没有 await；ArkTS 单线程，clear 与撤回同意也只能在两次
 *   await 之间执行），撤回同意完成之后旧任务不会再开始读 ODID。发送：请求带 ApiRequest.owner = 这个 ticket，ApiClient
 *   在每次实际发送前（含传输层的 admit）核对，失效就按 cancelled 结束，不会被改绑到当前环境。结果：收到任何结果（成功、
 *   失败、20001）都先核对，已失效的结果什么都不改：不保存凭据、不记被拒哈希、不重读标识、不再发送、不触发凭据丢失回调。
 *   环境闸门关闭（切换开始，同步）时放弃在途任务与重新注册记录（R2-01）。
 * - 20001 且 data.fields 含 device_hash（Effect reread_device_hash）：不提示用户。每次被拒（含重读后的那次）都把这次发送的哈希
 *   记进本世代的被拒集合（R1-04、lessons 3）；重读一次设备标识，读到被拒集合里的值就不再发（不带原值重试），之后的退避重试
 *   同样排除。被拒集合只记在本进程、随 clear 清空（TODO(N-21)：是否跨进程记住未定）。
 * - reregister（10402，ApiClient 的 DeviceRegistrar；普通请求与刷新请求共用这一个入口，R1-03、lessons 6）：单飞——注册在途时
 *   一律等同一次；被拒的 device_id 已换成别的直接成功。结果按「被拒的 device_id（凭据世代）+ ticket」逐条保存（lessons 4、18，
 *   R2-02）：晚到的 10402 复用它所属凭据的那次结果，失败也复用，不再另发注册、不覆盖别的凭据的记录；之后的尝试统一交给
 *   退避（onRestartNeeded(false)）。clear 与环境闸门关闭时全部作废。
 *   被拒的 device_id 立即在内存里作废（之后的请求不再带它），先删旧凭据再注册。
 * - 环境切换（R1-02、lessons 5）：attachEnvironment 后，闸门在新环境提交完成、重新打开时调 onRestartNeeded(true)
 *   （App 接到 PrivacyGate 立即重新开始注册）；不在仍属于旧环境的清理阶段触发。
 * - clear：撤回同意、切换环境的清理项（先清内存、作废在途注册，再删存储；删不掉抛错，由清理入口重试）。
 * TODO(APP-12)：注册成功后上报本地同意记录（consent_records，client_at = 同意的点击时间，BR-ID-12）与推送 token。
 * 单线程（UI 线程）使用。
 */
export class DeviceRegistry implements CredentialSource, DeviceRegistrar {
  /** RegisterDeviceData.install_secret：16–128 个字符（openapi）。 */
  static readonly SECRET_MIN: number = 16;
  static readonly SECRET_MAX: number = 128;

  /**
   * 需要重新开始注册：immediate = false 是 10402 后重新注册失败（凭据已丢，交给退避流程，从第一个退避间隔开始）；
   * true 是环境切换完成、闸门重新打开（立即开始）。App 接到 PrivacyGate.restartDeviceRegistration。
   */
  onRestartNeeded: (immediate: boolean) => void = (_immediate: boolean) => {
  };
  /** 环境世代（EnvironmentSwitchGate.token：切换中为 null）。缺省一直是 0（没有运行中切换，如 Release 与单测）。 */
  environmentToken: () => number | null = () => 0;
  /** 隐私世代（撤回同意加 1；App 接 PrivacyGate.consentCycle）。缺省一直是 0。 */
  privacyEpoch: () => number = () => 0;

  private readonly platform: string;
  private readonly reader: DeviceIdReader;
  private readonly store: DeviceCredentialStore;
  /** PrivacyStateRaw：已同意且撤回清理已完成时为 consented。 */
  private readonly privacy: () => string;
  /** 网络核心（与 ApiClient 相互依赖，延迟取）。 */
  private readonly client: () => ApiClient | null;
  private cached: StoredDevice | null = null;
  private loaded: boolean = false;
  /** 被服务端拒绝（10402）的 device_id：内存里作废，不再带出。 */
  private revokedDeviceId: string | null = null;
  /** clear 加 1：之前开始的注册结果一律作废。 */
  private generation: number = 0;
  /** 本世代里被 20001 拒收过的 device_hash（不带原值重试）。 */
  private rejectedHashes: string[] = [];
  /** 在途的注册（单飞）。 */
  private running: Promise<boolean> | null = null;
  /** 在途注册的窗口（调用方有效性，R3-03）；与 running 同生同灭。 */
  private window: RegistrationWindow | null = null;
  /** 10402 重新注册的结果，按被拒的 device_id（凭据世代）逐条保存（R2-02）。键：device_id；被拒请求没带时为空串。 */
  private reregisters: Map<string, ReregisterRecord> = new Map<string, ReregisterRecord>();
  /** 实际发出的注册请求数（测试与诊断用）。 */
  registerRequests: number = 0;

  constructor(platform: string, reader: DeviceIdReader, store: DeviceCredentialStore, privacy: () => string,
    client: () => ApiClient | null) {
    this.platform = platform;
    this.reader = reader;
    this.store = store;
    this.privacy = privacy;
    this.client = client;
  }

  /**
   * 接上环境闸门：注册绑定它的世代（切换中不开始、跨切换的结果作废），闸门重新打开（新环境已提交）时 onRestartNeeded(true)。
   * 返回取消登记的函数。
   */
  attachEnvironment(gate: EnvironmentSwitchGate): () => void {
    this.environmentToken = (): number | null => gate.token();
    const closed: () => void = gate.onClosed((): void => {
      this.abandonInFlight();
    });
    const reopened: () => void = gate.onReopened((_switched: boolean): void => {
      this.restart(true);
    });
    return (): void => {
      closed();
      reopened();
    };
  }

  /**
   * 设备凭据的统一读取判定（FU-HM-0711b R2-01，与 ApiClient 读令牌同一判定）：已同意且撤回清理已完成（privacy 为 consented）、
   * 不在切换环境（环境世代不为 null）、网络核心的凭据判定成立（ApiClient.credentialReadAllowed：环境已就绪、隐私 full、
   * 撤回清理已完成）。所有读取入口（deviceId、installSecret、registered，以及注册内部的 current）都在访问缓存或存储之前
   * 先过这里；不成立就一次都不读，按没有凭据返回 null。网络核心还没组合（client 为 null）按不成立。本身不读凭据。
   */
  credentialsReadable(): boolean {
    if (!this.consented() || this.environment() === null) {
      return false;
    }
    let client: ApiClient | null = null;
    try {
      client = this.client();
    } catch (e) {
      return false;
    }
    return client !== null && client.credentialReadAllowed();
  }

  /** 签名与埋点用的 device_id；凭据不可读（切环境、撤回清理未完成、未同意、环境未定）时为 null，缓存与存储都不读。 */
  deviceId(): string | null {
    const current: StoredDevice | null = this.current();
    return current === null ? null : current.deviceId;
  }

  /** 签名用的 install_secret；不可读时同 deviceId。 */
  installSecret(): string | null {
    const current: StoredDevice | null = this.current();
    return current === null ? null : current.installSecret;
  }

  /** 是否已有可用的凭据（读不出、不可读都按没有）。 */
  get registered(): boolean {
    return this.current() !== null;
  }

  /** 本世代被 20001 拒收过的哈希个数（测试与诊断用）。 */
  get rejectedHashCount(): number {
    return this.rejectedHashes.length;
  }

  /**
   * PrivacyGate 的设备注册步骤：确保已注册（已有凭据直接 true）。不抛出。
   * APP-03b 共性 27（I-R3-01）：退避注册与 10402 窗口共享被拒凭据的恢复状态。有被隔离的凭据时，这次退避注册就是它的恢复：
   * 结果登记到该凭据的重新注册记录上（换掉之前失败的那条），还没醒来、晚到的同一凭据 10402 复用它——成功后直接重放，不再
   * 注册一次；失败仍由退避流程自己重试（这里不另发退避通知）。
   */
  register(): Promise<boolean> {
    const running: Promise<boolean> | null = this.running;
    if (running !== null) {
      // 独立的原生调用方并入：这个窗口不再因桥调用方全部失效而停下（R3-03）。
      this.window?.callers.push(null);
      return running;
    }
    // 独立的启动 / 退避注册：带一个独立调用方，一直有效（不因桥调用方失效而停下）。
    const window: RegistrationWindow = new RegistrationWindow(null, true);
    const flight: Promise<boolean> = this.track(this.ensureRegistered(window), window);
    const revoked: string | null = this.revokedDeviceId;
    const scope: RegistrationTicket | null = this.scope();
    if (revoked !== null && scope !== null) {
      const recovery: Promise<boolean> = flight.then((ok: boolean): boolean => {
        const now: string | null = this.deviceId();
        return ok && now !== null && now !== revoked;
      });
      this.remember(DeviceRegistry.credentialKey(revoked), new ReregisterRecord(scope, window).bind(recovery));
    }
    return flight;
  }

  /**
   * 10402：重新注册 1 次（单飞；同一被拒凭据与世代复用结果）。不抛出。
   * caller（R3-03，共性 58）：发起这次重新注册的调用方有效性（普通请求的 ApiRequest.owner、共享刷新这一轮的「还有有效
   * 调用方」；null = 独立的原生调用方）。登记进注册窗口：等待结束、读取标识前、实际发送前都检查，没有有效调用方就停下，
   * 并取消底层注册请求（callersChanged）。入口时调用方已失效：不注册，但被拒凭据照样隔离并交给唯一的退避链一次。
   */
  reregister(usedDeviceId: string | null, caller: (() => boolean) | null = null): Promise<boolean> {
    const scope: RegistrationTicket | null = this.scope();
    if (scope === null || !this.credentialsReadable()) {
      // R2-01：凭据不可读（环境未就绪、撤回清理未完成）时不读当前凭据，也不删、不注册。
      return Promise.resolve(false);
    }
    const now: string | null = this.deviceId();
    if (now !== null && now !== usedDeviceId) {
      // 已经换成新的 device_id（别的 10402 或退避先完成了注册）：直接重放。
      return Promise.resolve(true);
    }
    const key: string = DeviceRegistry.credentialKey(usedDeviceId);
    const record: ReregisterRecord | undefined = this.reregisters.get(key);
    if (record !== undefined && record.ticket.same(scope)) {
      // 这个被拒凭据的晚到 10402（哪怕之后别的凭据又被拒过）：复用它那次的完整结果（成功或失败），不另发注册
      // （lessons 4、18，R2-02）。记录还在进行中时把这个调用方登记进它的注册窗口（R4-01）：先到的调用方失效不会再
      // 取消仍有调用方在等的注册；已完成的记录直接复用结果。
      if (!record.settled) {
        record.join(caller);
      }
      return record.result;
    }
    if (!RegistrationWindow.alive(caller)) {
      // 调用方已失效（桥调用到期、页面离开）：不为它注册；被拒凭据仍隔离、恢复交给唯一的退避链（与 iOS、Android 一致）。
      this.isolate(usedDeviceId);
      return Promise.resolve(false);
    }
    // 被拒的 device_id 立刻从可读凭据里隔离（F-ALL-08 / APP-03b 共性 21，I-R1-01）：不论是新开一轮注册还是并入在途的
    // 注册，之后的请求（含这次注册请求）都不再带它。
    if (usedDeviceId !== null) {
      this.revokedDeviceId = usedDeviceId;
    }
    const running: Promise<boolean> | null = this.running;
    if (running !== null) {
      const joinedRecord: ReregisterRecord = new ReregisterRecord(scope, this.window, caller);
      this.window?.callers.push(caller);
      // 并入在途的注册窗口：窗口结束后只有拿到了不是被拒那份的凭据才算成功。在途的是开始时还读得到旧凭据的普通注册
      // （它不会换凭据）时，这个被拒凭据的结果是失败，并且交给退避流程一次；窗口本身失败时由窗口自己通知退避，这里不重复。
      // 结果按被拒凭据保存，晚到的同一凭据 10402 复用它，不再另挂（退避通知只发一次）。
      const joined: Promise<boolean> = running.then((ok: boolean): boolean => {
        if (!joinedRecord.live()) {
          // 等待结束时这个被拒凭据的调用方都已失效：不再为它重放（退避由窗口自己的结局负责）。
          return false;
        }
        if (ok && this.deviceId() !== null) {
          return true;
        }
        if (ok && this.valid(scope)) {
          this.restart(false);
        }
        return false;
      });
      this.remember(key, joinedRecord.bind(joined));
      return joined;
    }
    // 再删旧凭据：删不掉不注册（旧凭据还在存储里）。
    let result: Promise<boolean>;
    let started: RegistrationWindow | null = null;
    try {
      this.store.clear();
      this.cached = null;
      this.loaded = true;
      const window: RegistrationWindow = new RegistrationWindow(caller, true);
      started = window;
      result = this.track(this.ensureRegistered(window).then((ok: boolean): boolean => {
        if (!ok && this.valid(scope)) {
          // 失败（含调用方全部失效而停下，被拒凭据已隔离；结果仍属于本世代）：交给唯一的退避链一次；失效的结果不触发。
          this.restart(false);
        }
        return ok;
      }), window);
    } catch (e) {
      this.restart(false);
      result = Promise.resolve(false);
    }
    this.remember(key, new ReregisterRecord(scope, started, caller).bind(result));
    return result;
  }

  /**
   * 不走重新注册的 10402（重放里再收到、注册请求自己收到）：这次请求所用的凭据还是当前凭据时立刻隔离，并把恢复交给
   * 唯一一条退避链（PrivacyGate.restartDeviceRegistration(false) 本身只保留一条链）。ticket 无效（未同意、切换中）时不动。
   */
  isolate(usedDeviceId: string | null): void {
    if (usedDeviceId === null || this.scope() === null || !this.credentialsReadable()) {
      return;
    }
    if (this.deviceId() !== usedDeviceId) {
      return;
    }
    this.revokedDeviceId = usedDeviceId;
    this.restart(false);
  }

  /**
   * 调用方有效性变了（ApiClient.cancelOwned：桥调用到期、页面离开时）：在途注册窗口已没有有效调用方时，取消它已交给传输层的
   * 注册请求（R3-03，共性 58）；启动注册等独立窗口不受影响。
   */
  callersChanged(): void {
    const window: RegistrationWindow | null = this.window;
    if (window === null || window.cancelled || window.live()) {
      return;
    }
    window.cancelled = true;
    const owner: (() => boolean) | null = window.owner;
    const client: ApiClient | null = this.client();
    if (owner !== null && client !== null) {
      client.cancelOwned(owner);
    }
  }

  /** 环境闸门关闭（切换开始，同步）：放弃在途的注册任务与重新注册记录；它们的 ticket 已失效，结果一律不处理。 */
  abandonInFlight(): void {
    this.running = null;
    this.window = null;
    this.reregisters.clear();
  }

  private static credentialKey(usedDeviceId: string | null): string {
    return usedDeviceId === null ? '' : usedDeviceId;
  }

  /** 记下一个被拒凭据的结果；顺手丢掉 ticket 已失效（属于旧世代）的记录。 */
  private remember(key: string, record: ReregisterRecord): void {
    const stale: string[] = [];
    this.reregisters.forEach((value: ReregisterRecord, k: string) => {
      if (!value.ticket.same(record.ticket)) {
        stale.push(k);
      }
    });
    for (const k of stale) {
      this.reregisters.delete(k);
    }
    this.reregisters.set(key, record);
  }

  /** 撤回同意、切换环境：先清内存并作废在途注册，再删存储（删不掉抛错，内存里已经没有）。 */
  clear(): void {
    this.generation++;
    this.cached = null;
    this.loaded = true;
    this.revokedDeviceId = null;
    this.rejectedHashes = [];
    this.running = null;
    this.window = null;
    this.reregisters.clear();
    this.store.clear();
  }

  private track(work: Promise<boolean>, window: RegistrationWindow): Promise<boolean> {
    const run: Promise<boolean> = work.catch((): boolean => false);
    this.running = run;
    this.window = window;
    run.then((): void => {
      if (this.running === run) {
        this.running = null;
        this.window = null;
      }
    });
    return run;
  }

  private restart(immediate: boolean): void {
    try {
      this.onRestartNeeded(immediate);
    } catch (e) {
      // App 的回调出错不影响结果。
    }
  }

  private consented(): boolean {
    try {
      return this.privacy() === PrivacyStateRaw.CONSENTED;
    } catch (e) {
      return false;
    }
  }

  private environment(): number | null {
    try {
      return this.environmentToken();
    } catch (e) {
      return null;
    }
  }

  private privacyGeneration(): number {
    try {
      return this.privacyEpoch();
    } catch (e) {
      return -1;
    }
  }

  /** 现在可以开始一次注册时绑定的 ticket；未同意或正在切换环境为 null。 */
  private scope(): RegistrationTicket | null {
    if (!this.consented()) {
      return null;
    }
    const env: number | null = this.environment();
    return env === null ? null : new RegistrationTicket(this.privacyGeneration(), env, this.generation);
  }

  /** ticket 仍然有效：隐私、环境、清理三种世代都没变，且仍是已同意（读标识、发送、处理结果、保存之前都调用）。 */
  private valid(scope: RegistrationTicket): boolean {
    return scope.generation === this.generation && this.environment() === scope.environment
      && this.privacyGeneration() === scope.privacy && this.consented();
  }

  private current(): StoredDevice | null {
    // R2-01：判定在访问缓存与存储之前；不成立零读取。
    if (!this.credentialsReadable()) {
      return null;
    }
    if (!this.loaded) {
      const stored: StoredDevice = this.store.read();
      if (stored.kind === StoredDeviceKind.PRESENT) {
        this.cached = stored;
        this.loaded = true;
      } else if (stored.kind === StoredDeviceKind.NONE) {
        this.loaded = true;
      }
      // UNREADABLE：下次再读，不当成没有。
    }
    const cached: StoredDevice | null = this.cached;
    return cached !== null && cached.deviceId !== this.revokedDeviceId ? cached : null;
  }

  private async ensureRegistered(window: RegistrationWindow): Promise<boolean> {
    const scope: RegistrationTicket | null = this.scope();
    if (scope === null) {
      return false;
    }
    if (!this.credentialsReadable()) {
      // R2-01：凭据不可读时不读缓存与存储，也不注册（不知道是否已有凭据，注册可能多出一个设备）；交给退避再试。
      return false;
    }
    if (this.current() !== null) {
      return true;
    }
    if (!this.loaded) {
      // 凭据读不出：不注册（可能已有凭据，重新注册会多出一个设备），等退避再读。
      return false;
    }
    // 第一次读；20001 device_hash 被拒后按 BR-ID-09 重读一次（共两次），被拒过的值一律不再发。
    for (let reads: number = 0; reads < 2; reads++) {
      const hashed: HashedId | null = this.readHash(scope, window);
      if (hashed === null) {
        return false;
      }
      const outcome: SendOutcome = await this.send(hashed, scope, window);
      if (outcome !== SendOutcome.REREAD_HASH) {
        return outcome === SendOutcome.SAVED;
      }
    }
    return false;
  }

  /**
   * 读一次标识并判定；ticket 失效、无效、本世代被拒过的值为 null（不求哈希上报、不发请求）。
   * lessons 12（A-R2-01，S0）：最后一次隐私与世代核对和 reader.read() 在同一个同步区里，中间不得有 await。ArkTS 单线程，
   * clear（撤回同意 / 切换环境的清理项）与撤回同意本身只能在两次 await 之间执行，所以撤回完成之后旧任务不会再开始读 ODID。
   * 本方法必须保持同步。
   */
  private readHash(scope: RegistrationTicket, window: RegistrationWindow): HashedId | null {
    // R3-03：读取标识前检查调用方（没有有效调用方不读）。
    if (!this.valid(scope) || !window.live()) {
      return null;
    }
    let raw: string | null = null;
    try {
      raw = this.reader.read();
    } catch (e) {
      raw = null;
    }
    if (!this.valid(scope)) {
      // 读取本身同步（不会让出线程），这里只防读取回调里改了状态：失效就不求哈希、不发送。
      return null;
    }
    const decision: DeviceIdDecision = DeviceIdPolicy.evaluate(this.platform, raw, this.privacy());
    if (!decision.register || decision.deviceHash === null || decision.idSource === null) {
      return null;
    }
    if (this.rejectedHashes.indexOf(decision.deviceHash) >= 0) {
      return null;
    }
    return new HashedId(decision.deviceHash, decision.idSource);
  }

  /**
   * 发一次注册并处理结果。发出前、收到结果后都核对快照：失效时返回 FAILED 且不改任何状态（不保存、不记被拒哈希）。
   */
  private async send(hashed: HashedId, scope: RegistrationTicket, window: RegistrationWindow): Promise<SendOutcome> {
    const client: ApiClient | null = this.client();
    // R3-03：实际发送前检查调用方。
    if (client === null || !this.valid(scope) || !window.live()) {
      return SendOutcome.FAILED;
    }
    this.registerRequests++;
    const body: string = JSON.stringify(new RegisterBody(hashed.hash, hashed.source));
    const request: ApiRequest = new ApiRequest(ApiClient.REGISTER_DEVICE_OPERATION, {}, '', body);
    // lessons 13：请求带上原始 ticket，ApiClient 在实际发送前（含传输层 admit）与每次等待之后都核对，不会改绑到当前环境。
    // R3-03：守卫也要求窗口还有有效调用方（ApiClient 每次实际发送前核对）；同一个函数对象记在窗口上，调用方全部失效时
    // callersChanged 按它取消底层请求。
    const owner: () => boolean = (): boolean => this.valid(scope) && window.live();
    window.owner = owner;
    request.owner = owner;
    const result: ApiResult = await client.request(request);
    if (!this.valid(scope) || !window.live()) {
      // 注册期间撤回同意、切换环境或清理过，或调用方全部失效（等待结束）：结果一个分支都不处理（不记被拒哈希、不重读、
      // 不再发送）。
      return SendOutcome.FAILED;
    }
    if (result.ok) {
      const deviceId: Object | undefined = result.data['device_id'];
      const secret: Object | undefined = result.data['install_secret'];
      if (typeof deviceId !== 'string' || (deviceId as string).length === 0 || typeof secret !== 'string'
        || (secret as string).length < DeviceRegistry.SECRET_MIN || (secret as string).length > DeviceRegistry.SECRET_MAX) {
        return SendOutcome.FAILED;
      }
      return this.save(deviceId as string, secret as string, scope) ? SendOutcome.SAVED : SendOutcome.FAILED;
    }
    const effect: string | null = result.effect === null ? null : result.effect.effectKindRaw;
    if (effect === EffectKind.REREAD_DEVICE_HASH) {
      // 每次被拒都记下这次发送的哈希（含重读后的那次，R1-04）。
      if (this.rejectedHashes.indexOf(hashed.hash) < 0) {
        this.rejectedHashes.push(hashed.hash);
      }
      return SendOutcome.REREAD_HASH;
    }
    return SendOutcome.FAILED;
  }

  /** 先写存储、再改内存；快照失效（撤回同意、切换环境或清理过）的结果丢弃。 */
  private save(deviceId: string, secret: string, scope: RegistrationTicket): boolean {
    if (!this.valid(scope)) {
      return false;
    }
    try {
      this.store.save(deviceId, secret);
    } catch (e) {
      return false;
    }
    this.cached = new StoredDevice(StoredDeviceKind.PRESENT, deviceId, secret);
    this.loaded = true;
    this.revokedDeviceId = null;
    return true;
  }
}

/** device_id 与 install_secret 的清理项（同名替换 APP-02b 的占位：撤回同意 cleanOnly 与切换环境 cleanAll 都会跑到）。 */
export class DeviceIdentityCleaner implements LocalDataCleaner {
  readonly name: string = PrivacyWithdrawalCleaners.DEVICE_IDENTITY;
  private readonly registry: DeviceRegistry;

  constructor(registry: DeviceRegistry) {
    this.registry = registry;
  }

  clean(): Promise<void> {
    try {
      this.registry.clear();
      return Promise.resolve();
    } catch (e) {
      return Promise.reject(e);
    }
  }

  static register(cleaners: LocalDataCleanerRegistry, registry: DeviceRegistry): void {
    cleaners.register(new DeviceIdentityCleaner(registry));
  }
}
