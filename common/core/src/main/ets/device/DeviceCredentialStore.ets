import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SecureStore } from '../storage/SecureStore';

/** 读设备原始标识（鸿蒙：ODID）。只在已同意隐私政策之后调用（BR-ID-11：同意前禁止读取）。 */
export interface DeviceIdReader {
  read(): string | null;
}

/** 鸿蒙的 ODID（@kit.BasicServicesKit deviceInfo.ODID，API 12，不需要权限）。取不到为 null。 */
export class OdidReader implements DeviceIdReader {
  read(): string | null {
    try {
      const odid: string = deviceInfo.ODID;
      return typeof odid === 'string' ? odid : null;
    } catch (e) {
      return null;
    }
  }
}

/** 一次设备凭据读取的结论。 */
export class StoredDeviceKind {
  /** 没有（从未注册，或已清除）。 */
  static readonly NONE: string = 'none';
  static readonly PRESENT: string = 'present';
  /** 读取失败：不能当成没有（否则会重复注册出新设备），下次再读。 */
  static readonly UNREADABLE: string = 'unreadable';
}

export class StoredDevice {
  readonly kind: string;
  readonly deviceId: string;
  readonly installSecret: string;

  constructor(kind: string, deviceId: string = '', installSecret: string = '') {
    this.kind = kind;
    this.deviceId = deviceId;
    this.installSecret = installSecret;
  }
}

/** device_id 与 install_secret 的存储（install_secret 只进安全存储，CSB-05）。 */
export interface DeviceCredentialStore {
  read(): StoredDevice;

  /** 两项一起写；写不进抛错。 */
  save(deviceId: string, installSecret: string): void;

  /** 两项一起删；删不掉抛错。 */
  clear(): void;
}

/** 内存实现（单测；可模拟读、写、删失败）。 */
export class MemoryDeviceCredentialStore implements DeviceCredentialStore {
  deviceId: string | null = null;
  installSecret: string | null = null;
  failReads: boolean = false;
  failSaves: boolean = false;
  failClears: boolean = false;
  saveCount: number = 0;
  clearCount: number = 0;

  read(): StoredDevice {
    if (this.failReads) {
      return new StoredDevice(StoredDeviceKind.UNREADABLE);
    }
    if (this.deviceId !== null && this.installSecret !== null) {
      return new StoredDevice(StoredDeviceKind.PRESENT, this.deviceId, this.installSecret);
    }
    return new StoredDevice(StoredDeviceKind.NONE);
  }

  save(deviceId: string, installSecret: string): void {
    if (this.failSaves) {
      throw new Error('device credential save failed');
    }
    this.saveCount++;
    this.deviceId = deviceId;
    this.installSecret = installSecret;
  }

  clear(): void {
    if (this.failClears) {
      throw new Error('device credential clear failed');
    }
    this.clearCount++;
    this.deviceId = null;
    this.installSecret = null;
  }
}

/** 一个非敏感的字符串键值（device_id 用；03 §3.3 存储表：非敏感 KV 走 Preferences）。读取失败抛出。 */
export interface KeyValueSlot {
  get(): string | null;

  set(value: string): void;

  remove(): void;
}

/**
 * Preferences 里的一个键（同步接口：getPreferencesSync / getSync / putSync / deleteSync API 11，flushSync API 14，均不高于 API 20）。
 * 每次操作现取实例（系统有缓存）：命名空间被别的清理删除后不会拿着失效的实例。
 */
export class PreferencesSlot implements KeyValueSlot {
  private readonly context: common.Context;
  private readonly namespace: string;
  private readonly key: string;

  constructor(context: common.Context, namespace: string, key: string) {
    this.context = context;
    this.namespace = namespace;
    this.key = key;
  }

  get(): string | null {
    const value: preferences.ValueType = this.prefs().getSync(this.key, '');
    return typeof value === 'string' && value.length > 0 ? value : null;
  }

  set(value: string): void {
    const prefs: preferences.Preferences = this.prefs();
    prefs.putSync(this.key, value);
    prefs.flushSync();
  }

  remove(): void {
    const prefs: preferences.Preferences = this.prefs();
    prefs.deleteSync(this.key);
    prefs.flushSync();
  }

  private prefs(): preferences.Preferences {
    return preferences.getPreferencesSync(this.context, { name: this.namespace });
  }
}

/**
 * 生产实现（03 §3.3 存储表）：device_id 不敏感，放 Preferences（DEVICE_NAMESPACE）；install_secret 只放安全存储（Asset Store Kit，
 * CSB-05；条目仅本设备可用、不随备份迁移，CSB-06，见 AssetSecureStore）。
 * - 写：先写 install_secret，再写 device_id（device_id 是「已注册」的标志，最后落盘）。
 * - 读：任一项读取失败 → UNREADABLE；两项都在 → PRESENT；都不在 → NONE；只剩一项（写到一半被打断、内容损坏）→ 尽力删除后按 NONE
 *   （重新注册）。
 * - 删：两项都删，任一失败抛出（清理器据此报告失败、下次重试）。
 */
export class SecureDeviceCredentialStore implements DeviceCredentialStore {
  /** device_id 所在的 Preferences 命名空间（不在 CouliPreferences.ALL_NAMESPACES：由 device_identity 清理项负责删）。 */
  static readonly DEVICE_NAMESPACE: string = 'couli_device';
  static readonly DEVICE_ID_KEY: string = 'device.device_id';
  static readonly INSTALL_SECRET_ALIAS: string = 'install_secret';

  private readonly idSlot: KeyValueSlot;
  private readonly secrets: SecureStore;

  constructor(idSlot: KeyValueSlot, secrets: SecureStore) {
    this.idSlot = idSlot;
    this.secrets = secrets;
  }

  read(): StoredDevice {
    let id: string | null = null;
    let secret: string | null = null;
    try {
      id = this.idSlot.get();
      secret = this.secrets.get(SecureDeviceCredentialStore.INSTALL_SECRET_ALIAS);
    } catch (e) {
      return new StoredDevice(StoredDeviceKind.UNREADABLE);
    }
    if (id !== null && id.length > 0 && secret !== null && secret.length > 0) {
      return new StoredDevice(StoredDeviceKind.PRESENT, id, secret);
    }
    if (id !== null || secret !== null) {
      try {
        this.clear();
      } catch (e) {
        // 删不掉：仍按没有处理（重新注册成功后整组覆盖）。
      }
    }
    return new StoredDevice(StoredDeviceKind.NONE);
  }

  save(deviceId: string, installSecret: string): void {
    this.secrets.set(SecureDeviceCredentialStore.INSTALL_SECRET_ALIAS, installSecret);
    this.idSlot.set(deviceId);
  }

  clear(): void {
    let failure: Error | null = null;
    try {
      this.idSlot.remove();
    } catch (e) {
      failure = e as Error;
    }
    try {
      this.secrets.remove(SecureDeviceCredentialStore.INSTALL_SECRET_ALIAS);
    } catch (e) {
      failure = failure ?? e as Error;
    }
    if (failure !== null) {
      throw failure;
    }
  }
}
