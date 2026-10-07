import { DeviceHashSeeds } from 'generated';
import { RequestSigner } from '../network/RequestSigner';
import { Sha256 } from './Sha256';

/** 客户端端别（client_platform 的端侧取值；三端测试接线名，与 Android 同名）。 */
export class ClientPlatformRaw {
  static readonly IOS: string = 'ios';
  static readonly ANDROID: string = 'android';
  static readonly HARMONY: string = 'harmony';
}

/** 隐私状态（与 client-core-vectors 的 privacy、router PrivacyState 的取值一致）。 */
export class PrivacyStateRaw {
  static readonly NOT_DECIDED: string = 'not_decided';
  static readonly CONSENTED: string = 'consented';
  static readonly BASIC_MODE: string = 'basic_mode';
}

/** 设备标识的判定结果。 */
export class DeviceIdDecision {
  /** 可以注册设备（求哈希并上报）。 */
  readonly register: boolean;
  /** 不注册的原因（DeviceIdPolicy.REASON_*；没有稳定枚举，测试不锁死）；可以注册时为 null。 */
  readonly reasonRaw: string | null;
  /** 请求体的 id_source；不注册时为 null。 */
  readonly idSource: string | null;
  /** device_hash；不注册时为 null（无效值不求哈希上报）。 */
  readonly deviceHash: string | null;

  constructor(register: boolean, reasonRaw: string | null, idSource: string | null, deviceHash: string | null) {
    this.register = register;
    this.reasonRaw = reasonRaw;
    this.idSource = idSource;
    this.deviceHash = deviceHash;
  }

  static reject(reason: string): DeviceIdDecision {
    return new DeviceIdDecision(false, reason, null, null);
  }
}

/**
 * 设备标识的有效性与 device_hash（BR-ID-09 细则「设备标识的无效值」；契约快照 specs/device-hash.vectors.json）。纯函数，
 * 三端同一规则（与 Android DeviceIdPolicy 同序）。
 *
 * 判定顺序：隐私不是已同意 → 不注册（BR-ID-11：同意前连读取都不允许，调用方先判隐私再读标识）→ 端别不认识 → 取不到 /
 * 去首尾 ASCII 空白后为空 → 去掉 `0` 与 `-` 后为空（全零）→ 哈希命中无效设备哈希清单的种子（DeviceHashSeeds，含已知公共
 * 固定值）→ 有效。
 * TODO(N-21)：各标识的长度、字符集规则 BR-ID-09 没有给出，向量也明确不覆盖；不自造格式校验（rule-gaps 第 1 条，保守：
 * 只按已明确的无效值拦截，格式不符的值由服务端 20001 拒收后按 reread_device_hash 重读，不带原值重试）。
 *
 * 鸿蒙用 ODID（id_source = odid）；iOS 用 IDFV（idfv）；Android 只用 ANDROID_ID（android_id，MVP 不取 OAID）。
 */
export class DeviceIdPolicy {
  static readonly REASON_PRIVACY: string = 'privacy_not_consented';
  static readonly REASON_PLATFORM: string = 'unknown_platform';
  static readonly REASON_UNAVAILABLE: string = 'unavailable';
  static readonly REASON_EMPTY: string = 'empty';
  static readonly REASON_ALL_ZERO: string = 'all_zero';
  static readonly REASON_KNOWN_INVALID: string = 'known_invalid_hash';

  /** 本端的 id_source；不认识的端别为 null。 */
  static idSource(platform: string): string | null {
    if (platform === ClientPlatformRaw.HARMONY) {
      return 'odid';
    }
    if (platform === ClientPlatformRaw.IOS) {
      return 'idfv';
    }
    if (platform === ClientPlatformRaw.ANDROID) {
      return 'android_id';
    }
    return null;
  }

  /** 哈希输入：去首尾 ASCII 空白（device-hash.vectors.json：向量只用 ASCII 空白）并转小写。 */
  static normalize(rawId: string): string {
    let start: number = 0;
    let end: number = rawId.length;
    while (start < end && DeviceIdPolicy.isAsciiSpace(rawId.charCodeAt(start))) {
      start++;
    }
    while (end > start && DeviceIdPolicy.isAsciiSpace(rawId.charCodeAt(end - 1))) {
      end--;
    }
    // toLowerCase 与区域设置无关（Android 用 lowercase(Locale.ROOT)，同一结果）。
    return rawId.substring(start, end).toLowerCase();
  }

  /** device_hash = lowercase_hex(SHA-256(normalize(rawId) 的 UTF-8 字节))。只对有效值调用（无效值不求哈希上报）。 */
  static hash(rawId: string): string {
    return RequestSigner.hex(Sha256.digest(RequestSigner.utf8(DeviceIdPolicy.normalize(rawId))));
  }

  /** 标识本身是否有效（不看隐私）：不为空、不是全零、哈希不在种子清单里。 */
  static isValid(rawId: string | null): boolean {
    return DeviceIdPolicy.invalidReason(rawId) === null;
  }

  /** 能否注册设备（client-core-vectors 的 device 组）。 */
  static evaluate(platform: string, rawId: string | null, privacy: string): DeviceIdDecision {
    if (privacy !== PrivacyStateRaw.CONSENTED) {
      return DeviceIdDecision.reject(DeviceIdPolicy.REASON_PRIVACY);
    }
    const source: string | null = DeviceIdPolicy.idSource(platform);
    if (source === null) {
      return DeviceIdDecision.reject(DeviceIdPolicy.REASON_PLATFORM);
    }
    const reason: string | null = DeviceIdPolicy.invalidReason(rawId);
    if (reason !== null || rawId === null) {
      return DeviceIdDecision.reject(reason ?? DeviceIdPolicy.REASON_UNAVAILABLE);
    }
    return new DeviceIdDecision(true, null, source, DeviceIdPolicy.hash(rawId));
  }

  private static invalidReason(rawId: string | null): string | null {
    if (rawId === null) {
      return DeviceIdPolicy.REASON_UNAVAILABLE;
    }
    const normalized: string = DeviceIdPolicy.normalize(rawId);
    if (normalized.length === 0) {
      return DeviceIdPolicy.REASON_EMPTY;
    }
    let allZero: boolean = true;
    for (let i: number = 0; i < normalized.length; i++) {
      const ch: string = normalized.charAt(i);
      if (ch !== '0' && ch !== '-') {
        allZero = false;
        break;
      }
    }
    if (allZero) {
      return DeviceIdPolicy.REASON_ALL_ZERO;
    }
    if (DeviceHashSeeds.has(DeviceIdPolicy.hash(rawId))) {
      return DeviceIdPolicy.REASON_KNOWN_INVALID;
    }
    return null;
  }

  /** 空格、\t、\n、\v、\f、\r。 */
  private static isAsciiSpace(code: number): boolean {
    return code === 0x20 || (code >= 0x09 && code <= 0x0d);
  }
}
