// 剪贴板本机记录加盐（FU-CLIP §2.2；K08～K11）：自写记录与 24 小时提示记录只存「本机随机盐的 HMAC-SHA256 指纹 + 时间」与 saltId，
// 不存原文、不存未加盐的 hash。盐存安全存储（生产 SecureStore / Asset），盐读写失败不回落到未加盐 hash。
// 三端同名：ClipboardFingerprint、ClipboardSaltStore、MemoryClipboardSaltStore、ClipboardRecords（向量 specs/clipboard-candidates-vectors.json）。
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Sha256 } from '../clientcore/Sha256';
import { RequestSigner } from '../network/RequestSigner';
import { SecureStore } from '../storage/SecureStore';
import { ClipboardClassifier, ClipboardHashStore } from './Clipboard';

/**
 * 指纹 = HMAC-SHA256(key = 本机盐 32 字节, msg = 原文 UTF-8)，小写十六进制（RFC 2104，用纯 Sha256 实现：本机单测里 CryptoArchitectureKit
 * 是空实现）。原文不做规范化（G08）。saltId = SHA-256(盐) 前 8 字节的小写十六进制，只用来识别记录属于哪个盐，不可逆推盐。
 */
export class ClipboardFingerprint {
  static readonly SALT_BYTES: number = 32;
  private static readonly BLOCK: number = 64;

  private readonly inner: Uint8Array;
  private readonly outer: Uint8Array;
  readonly saltId: string;

  constructor(salt: Uint8Array) {
    let key: Uint8Array = salt;
    if (key.length > ClipboardFingerprint.BLOCK) {
      key = Sha256.digest(key);
    }
    this.inner = new Uint8Array(ClipboardFingerprint.BLOCK);
    this.outer = new Uint8Array(ClipboardFingerprint.BLOCK);
    for (let i: number = 0; i < ClipboardFingerprint.BLOCK; i++) {
      const k: number = i < key.length ? key[i] : 0;
      this.inner[i] = k ^ 0x36;
      this.outer[i] = k ^ 0x5c;
    }
    this.saltId = RequestSigner.hex(Sha256.digest(salt).slice(0, 8));
  }

  hash(text: string): string {
    const message: Uint8Array = RequestSigner.utf8(text);
    const first: Uint8Array = new Uint8Array(ClipboardFingerprint.BLOCK + message.length);
    first.set(this.inner, 0);
    first.set(message, ClipboardFingerprint.BLOCK);
    const innerHash: Uint8Array = Sha256.digest(first);
    const second: Uint8Array = new Uint8Array(ClipboardFingerprint.BLOCK + innerHash.length);
    second.set(this.outer, 0);
    second.set(innerHash, ClipboardFingerprint.BLOCK);
    return RequestSigner.hex(Sha256.digest(second));
  }

  /**
   * 执行层默认的随机盐（ClipboardDeps 的缺省值，entry 生产接线另显式注入 secureRandomSalt）：先用系统 CSPRNG；运行环境没有可用的
   * CSPRNG（本机 Local Test 的 cryptoFramework 是空实现，返回 0 字节）时退回 Math.random 拼 32 字节——只为测试环境能跑通加盐记录；
   * 生产 entry 不用它（规则空白 HS03）。
   */
  static defaultRandomSalt(): Uint8Array {
    const secure: Uint8Array = ClipboardFingerprint.secureRandomSalt();
    if (secure.length === ClipboardFingerprint.SALT_BYTES) {
      return secure;
    }
    const bytes: Uint8Array = new Uint8Array(ClipboardFingerprint.SALT_BYTES);
    for (let i: number = 0; i < bytes.length; i++) {
      bytes[i] = Math.floor(Math.random() * 256) & 0xff;
    }
    return bytes;
  }

  /** 生产的随机盐：系统 CSPRNG（cryptoFramework Random）；拿不到 32 字节返回空数组（调用方按盐不可用处理，不回落）。 */
  static secureRandomSalt(): Uint8Array {
    try {
      const data: cryptoFramework.DataBlob = cryptoFramework.createRandom()
        .generateRandomSync(ClipboardFingerprint.SALT_BYTES);
      const bytes: Uint8Array | undefined = data === undefined || data === null ? undefined : data.data;
      return bytes !== undefined && bytes !== null && bytes.length === ClipboardFingerprint.SALT_BYTES ? bytes
        : new Uint8Array(0);
    } catch (e) {
      return new Uint8Array(0);
    }
  }
}

/** 读盐的结果：ok=false 为读失败（安全存储不可用）；ok=true 且 salt=null 为还没有盐。 */
export class ClipboardSaltRead {
  readonly ok: boolean;
  readonly salt: Uint8Array | null;

  constructor(ok: boolean, salt: Uint8Array | null) {
    this.ok = ok;
    this.salt = salt;
  }
}

/** 本机盐的存储端口（生产 SecureClipboardSaltStore，测试 MemoryClipboardSaltStore）。写与删确认成功返回 true。 */
export interface ClipboardSaltStore {
  load(): ClipboardSaltRead;

  save(salt: Uint8Array): boolean;

  remove(): boolean;
}

/** 内存实现（测试与组合之前）：初始无盐；failReads / failWrites 模拟安全存储失败；hasSalt 无副作用。 */
export class MemoryClipboardSaltStore implements ClipboardSaltStore {
  private salt: Uint8Array | null = null;
  failReads: boolean = false;
  failWrites: boolean = false;
  /** 测试核对：save / remove 的调用次数。 */
  saves: number = 0;
  removes: number = 0;

  get hasSalt(): boolean {
    return this.salt !== null;
  }

  /** 测试：直接换盐（不经 ClipboardRecords）。 */
  setSalt(salt: Uint8Array): void {
    this.salt = salt.slice();
  }

  load(): ClipboardSaltRead {
    if (this.failReads) {
      return new ClipboardSaltRead(false, null);
    }
    return new ClipboardSaltRead(true, this.salt === null ? null : this.salt.slice());
  }

  save(salt: Uint8Array): boolean {
    this.saves++;
    if (this.failWrites) {
      return false;
    }
    this.salt = salt.slice();
    return true;
  }

  remove(): boolean {
    this.removes++;
    if (this.failWrites) {
      return false;
    }
    this.salt = null;
    return true;
  }
}

/**
 * 安全存储里的盐（生产：AssetSecureStore('couli_clipboard')，首次解锁后可读、不同步、不随卸载保留）。值为 64 位小写十六进制；
 * 格式不对按没有盐（下次需要时重新生成并覆盖）；存储抛错按读写失败。
 */
export class SecureClipboardSaltStore implements ClipboardSaltStore {
  static readonly ALIAS: string = 'salt';
  private static readonly HEX: RegExp = /^[0-9a-f]{64}$/;
  private readonly store: SecureStore;

  constructor(store: SecureStore) {
    this.store = store;
  }

  load(): ClipboardSaltRead {
    let value: string | null = null;
    try {
      value = this.store.get(SecureClipboardSaltStore.ALIAS);
    } catch (e) {
      return new ClipboardSaltRead(false, null);
    }
    if (value === null || !SecureClipboardSaltStore.HEX.test(value)) {
      return new ClipboardSaltRead(true, null);
    }
    const bytes: Uint8Array = new Uint8Array(ClipboardFingerprint.SALT_BYTES);
    for (let i: number = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(value.substring(i * 2, i * 2 + 2), 16);
    }
    return new ClipboardSaltRead(true, bytes);
  }

  save(salt: Uint8Array): boolean {
    try {
      this.store.set(SecureClipboardSaltStore.ALIAS, RequestSigner.hex(salt));
      return true;
    } catch (e) {
      return false;
    }
  }

  remove(): boolean {
    try {
      this.store.remove(SecureClipboardSaltStore.ALIAS);
      return true;
    } catch (e) {
      return false;
    }
  }
}

/** 当前可用的指纹器：available=false 为盐不可用（读写失败）；available=true 且 fingerprint=null 为还没有盐（且这次不生成）。 */
class SaltState {
  readonly available: boolean;
  readonly fingerprint: ClipboardFingerprint | null;

  constructor(available: boolean, fingerprint: ClipboardFingerprint | null) {
    this.available = available;
    this.fingerprint = fingerprint;
  }
}

/**
 * 自写记录（最近 10 条，K11）与 24 小时提示记录（G08，严格小于 24 小时），只存加盐指纹、时间与 saltId（FU-CLIP §2.2）。
 * - 盐：第一次要写记录时生成（randomSalt 注入，生产为系统 CSPRNG）；读记录不生成。调用方只在已同意当前版本后调用写入（基本模式不生成）。
 * - 换盐（saltId 与记录里的不一致）：整份记录作废，下一次写时两份一起清掉。
 * - 盐不可用：recordSelfWritten / recordPrompted 返回 false（自写记不上 → 调用方不写系统剪贴板）；promptedWithin24h 返回 null（这一次不
 *   自动提示）；都不回落到未加盐 hash。
 * - withdraw：先删盐、再删两份记录与 saltId；任一步没确认成功返回 false（调用方保留待清理标记并重试）。
 * - removeLegacy：删掉旧版未加盐的记录键（K09，升级后第一次运行，不论是否同意）。
 * 存储键（ClipboardHashStore 的 key；生产在 couli_app 里再加前缀 clipboard.hash.）：salted.salt_id、salted.self_written、salted.prompted。
 */
export class ClipboardRecords {
  static readonly CAPACITY: number = 10;
  static readonly KEY_SALT_ID: string = 'salted.salt_id';
  static readonly KEY_WRITTEN: string = 'salted.self_written';
  static readonly KEY_PROMPTED: string = 'salted.prompted';
  /** 旧版（APP-07）未加盐记录的键：ClipboardWriteLedger 的 self_written、PromptHistory 的 prompted。 */
  static readonly LEGACY_KEYS: string[] = ['self_written', 'prompted'];
  private static readonly SEPARATOR: string = ',';
  private static readonly FIELD: string = '@';

  private readonly store: ClipboardHashStore;
  private readonly saltStore: ClipboardSaltStore;
  private readonly clock: () => number;
  private readonly randomSalt: () => Uint8Array;

  constructor(store: ClipboardHashStore, saltStore: ClipboardSaltStore, clock: () => number,
    randomSalt: () => Uint8Array) {
    this.store = store;
    this.saltStore = saltStore;
    this.clock = clock;
    this.randomSalt = randomSalt;
  }

  private salt(generate: boolean): SaltState {
    const read: ClipboardSaltRead = this.saltStore.load();
    if (!read.ok) {
      return new SaltState(false, null);
    }
    if (read.salt !== null && read.salt.length === ClipboardFingerprint.SALT_BYTES) {
      return new SaltState(true, new ClipboardFingerprint(read.salt));
    }
    if (!generate) {
      return new SaltState(true, null);
    }
    let fresh: Uint8Array;
    try {
      fresh = this.randomSalt();
    } catch (e) {
      return new SaltState(false, null);
    }
    if (fresh.length !== ClipboardFingerprint.SALT_BYTES || !this.saltStore.save(fresh)) {
      return new SaltState(false, null);
    }
    return new SaltState(true, new ClipboardFingerprint(fresh));
  }

  /** 当前盐的指纹（读记录用，不生成盐）；没有盐或不可用为 null。 */
  fingerprintOf(text: string): string | null {
    const state: SaltState = this.salt(false);
    return state.fingerprint === null ? null : state.fingerprint.hash(text);
  }

  /** 记录属于当前盐。 */
  private current(saltId: string): boolean {
    return this.store.read(ClipboardRecords.KEY_SALT_ID) === saltId;
  }

  /** 写之前：记录属于别的盐（换盐、盐丢失后新建）→ 两份一起清掉，再记下当前 saltId。 */
  private adopt(saltId: string): boolean {
    if (this.current(saltId)) {
      return true;
    }
    return this.store.write(ClipboardRecords.KEY_WRITTEN, null)
      && this.store.write(ClipboardRecords.KEY_PROMPTED, null)
      && this.store.write(ClipboardRecords.KEY_SALT_ID, saltId);
  }

  private written(): string[] {
    const raw: string | null = this.store.read(ClipboardRecords.KEY_WRITTEN);
    if (raw === null) {
      return [];
    }
    const all: string[] = raw.split(ClipboardRecords.SEPARATOR).filter((h: string): boolean => h.length > 0);
    return all.slice(Math.max(0, all.length - ClipboardRecords.CAPACITY));
  }

  private stamps(): string[][] {
    const raw: string | null = this.store.read(ClipboardRecords.KEY_PROMPTED);
    const out: string[][] = [];
    if (raw === null) {
      return out;
    }
    for (const entry of raw.split(ClipboardRecords.SEPARATOR)) {
      const at: number = entry.indexOf(ClipboardRecords.FIELD);
      if (at <= 0 || !Number.isSafeInteger(Number(entry.substring(at + 1)))) {
        continue;
      }
      out.push([entry.substring(0, at), entry.substring(at + 1)]);
    }
    return out;
  }

  /** 记下一条自写内容；确认落盘成功返回 true（共性第 23、25 条：失败时调用方不得写系统剪贴板）。 */
  recordSelfWritten(text: string): boolean {
    const state: SaltState = this.salt(true);
    if (state.fingerprint === null) {
      return false;
    }
    const fp: ClipboardFingerprint = state.fingerprint;
    if (!this.adopt(fp.saltId)) {
      return false;
    }
    const value: string = fp.hash(text);
    const next: string[] = this.written().filter((h: string): boolean => h !== value);
    next.push(value);
    return this.store.write(ClipboardRecords.KEY_WRITTEN,
      next.slice(Math.max(0, next.length - ClipboardRecords.CAPACITY)).join(ClipboardRecords.SEPARATOR));
  }

  /** 是 App 自写的内容（当前盐下的最近 10 条）；没有盐、盐不可用、记录属于别的盐都为 false。 */
  isSelfWritten(text: string): boolean {
    const state: SaltState = this.salt(false);
    if (state.fingerprint === null || !this.current(state.fingerprint.saltId)) {
      return false;
    }
    return this.written().indexOf(state.fingerprint.hash(text)) >= 0;
  }

  /** 出过提示条：记录指纹与时间（只按 24 小时到期清理，共性第 7 条）；确认落盘返回 true。 */
  recordPrompted(text: string): boolean {
    const state: SaltState = this.salt(true);
    if (state.fingerprint === null) {
      return false;
    }
    const fp: ClipboardFingerprint = state.fingerprint;
    if (!this.adopt(fp.saltId)) {
      return false;
    }
    const value: string = fp.hash(text);
    const now: number = this.clock();
    const kept: string[] = [];
    for (const stamp of this.stamps()) {
      const age: number = now - Number(stamp[1]);
      if (stamp[0] !== value && age >= 0 && age < ClipboardClassifier.PROMPT_WINDOW_MS) {
        kept.push(stamp[0] + ClipboardRecords.FIELD + stamp[1]);
      }
    }
    kept.push(value + ClipboardRecords.FIELD + now);
    return this.store.write(ClipboardRecords.KEY_PROMPTED, kept.join(ClipboardRecords.SEPARATOR));
  }

  /** 24 小时内（严格小于）提示过；盐不可用为 null（调用方这一次不自动提示，手动粘贴照常）。 */
  promptedWithin24h(text: string): boolean | null {
    const state: SaltState = this.salt(false);
    if (!state.available) {
      return null;
    }
    if (state.fingerprint === null || !this.current(state.fingerprint.saltId)) {
      return false;
    }
    const value: string = state.fingerprint.hash(text);
    const now: number = this.clock();
    return this.stamps().some((stamp: string[]): boolean => {
      const age: number = now - Number(stamp[1]);
      return stamp[0] === value && age >= 0 && age < ClipboardClassifier.PROMPT_WINDOW_MS;
    });
  }

  /** 撤回同意（与鸿蒙切换环境）：同一步里先删盐、再删两份记录与 saltId；全部确认成功返回 true。 */
  withdraw(): boolean {
    const saltOk: boolean = this.saltStore.remove();
    const writtenOk: boolean = this.store.write(ClipboardRecords.KEY_WRITTEN, null);
    const promptedOk: boolean = this.store.write(ClipboardRecords.KEY_PROMPTED, null);
    const idOk: boolean = this.store.write(ClipboardRecords.KEY_SALT_ID, null);
    return saltOk && writtenOk && promptedOk && idOk;
  }

  /** 删除旧版未加盐的记录（K09）；全部确认成功返回 true。 */
  removeLegacy(): boolean {
    let ok: boolean = true;
    for (const key of ClipboardRecords.LEGACY_KEYS) {
      if (!this.store.write(key, null)) {
        ok = false;
      }
    }
    return ok;
  }
}
