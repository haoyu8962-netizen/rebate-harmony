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
 * 一次 10402 重新注册的完整结果，按「被拒的凭据世代」（被拒请求带的 device_id）与 ticket 保存（lessons 4、18；
 * harmony-review-r2 R2-02）：每个被拒凭据各一条，不只留最近一次——晚到的 10402 复用它所属凭据的那次结果（成功或失败），
 * 不覆盖别的凭据的记录，也不另发注册。
 */
class ReregisterRecord {
  readonly ticket: RegistrationTicket;
  readonly result: Promise<boolean>;

  constructor(ticket: RegistrationTicket, result: Promise<boolean>) {
    this.ticket = ticket;
    this.result = result;
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

  deviceId(): string | null {
    const current: StoredDevice | null = this.current();
    return current === null ? null : current.deviceId;
  }

  installSecret(): string | null {
    const current: StoredDevice | null = this.current();
    return current === null ? null : current.installSecret;
  }

  /** 是否已有可用的凭据（读不出按没有）。 */
  get registered(): boolean {
    return this.current() !== null;
  }

  /** 本世代被 20001 拒收过的哈希个数（测试与诊断用）。 */
  get rejectedHashCount(): number {
    return this.rejectedHashes.length;
  }

  /** PrivacyGate 的设备注册步骤：确保已注册（已有凭据直接 true）。不抛出。 */
  register(): Promise<boolean> {
    const running: Promise<boolean> | null = this.running;
    if (running !== null) {
      return running;
    }
    return this.track(this.ensureRegistered());
  }

  /** 10402：重新注册 1 次（单飞；同一被拒凭据与世代复用结果）。不抛出。 */
  reregister(usedDeviceId: string | null): Promise<boolean> {
    const scope: RegistrationTicket | null = this.scope();
    if (scope === null) {
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
      // （lessons 4、18，R2-02）。
      return record.result;
    }
    const running: Promise<boolean> | null = this.running;
    if (running !== null) {
      this.remember(key, new ReregisterRecord(scope, running));
      return running;
    }
    // 被拒的 device_id 先在内存里作废（这次注册请求也不带它），再删旧凭据：删不掉不注册（旧凭据还在存储里）。
    if (usedDeviceId !== null) {
      this.revokedDeviceId = usedDeviceId;
    }
    let result: Promise<boolean>;
    try {
      this.store.clear();
      this.cached = null;
      this.loaded = true;
      result = this.track(this.ensureRegistered().then((ok: boolean): boolean => {
        if (!ok && this.valid(scope)) {
          // 失败（且结果仍属于本世代）：交给退避流程；失效的结果不触发。
          this.restart(false);
        }
        return ok;
      }));
    } catch (e) {
      this.restart(false);
      result = Promise.resolve(false);
    }
    this.remember(key, new ReregisterRecord(scope, result));
    return result;
  }

  /** 环境闸门关闭（切换开始，同步）：放弃在途的注册任务与重新注册记录；它们的 ticket 已失效，结果一律不处理。 */
  abandonInFlight(): void {
    this.running = null;
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
    this.reregisters.clear();
    this.store.clear();
  }

  private track(work: Promise<boolean>): Promise<boolean> {
    const run: Promise<boolean> = work.catch((): boolean => false);
    this.running = run;
    run.then((): void => {
      if (this.running === run) {
        this.running = null;
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

  private async ensureRegistered(): Promise<boolean> {
    const scope: RegistrationTicket | null = this.scope();
    if (scope === null) {
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
      const hashed: HashedId | null = this.readHash(scope);
      if (hashed === null) {
        return false;
      }
      const outcome: SendOutcome = await this.send(hashed, scope);
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
  private readHash(scope: RegistrationTicket): HashedId | null {
    if (!this.valid(scope)) {
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
  private async send(hashed: HashedId, scope: RegistrationTicket): Promise<SendOutcome> {
    const client: ApiClient | null = this.client();
    if (client === null || !this.valid(scope)) {
      return SendOutcome.FAILED;
    }
    this.registerRequests++;
    const body: string = JSON.stringify(new RegisterBody(hashed.hash, hashed.source));
    const request: ApiRequest = new ApiRequest(ApiClient.REGISTER_DEVICE_OPERATION, {}, '', body);
    // lessons 13：请求带上原始 ticket，ApiClient 在实际发送前（含传输层 admit）与每次等待之后都核对，不会改绑到当前环境。
    request.owner = (): boolean => this.valid(scope);
    const result: ApiResult = await client.request(request);
    if (!this.valid(scope)) {
      // 注册期间撤回同意、切换环境或清理过：结果属于旧世代，一个分支都不处理。
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
