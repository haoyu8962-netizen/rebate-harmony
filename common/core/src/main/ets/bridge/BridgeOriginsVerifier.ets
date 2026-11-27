// N-22 bridge_origins 的 ES256 JWS 验签（FU-HM-BRIDGE-ORIGINS-VERIFY；D10-3507 / D10-3512 / D10-3606；scope.md P1–P3）。
// 与安卓 core/bridge/BridgeOriginsVerifier.kt 同口径；三端共用向量 NATIVE/N22-VECTORS/n22-bridge-origins-vectors.json。
// 本机单测（Local Test 里 cryptoFramework 是空实现）注入 Es256Port 替身，只测验签之后的规则；真签名向量在 core 设备用例里跑。
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { CONFIG_SIGN_KEYS_BUNDLED } from 'core/ets/config/ConfigSignKeysBundled';
import { Sha256 } from '../clientcore/Sha256';
import { StreamUtf8Decoder } from '../network/StreamUtf8Decoder';

/** JSON 对象（JSON.parse 的结果按对象取字段）。 */
type JsonObject = Record<string, Object>;

/** P-256 公钥 SPKI DER 的固定前缀（SEQUENCE / id-ecPublicKey / prime256v1 / BIT STRING 头），其后是 04 与 64 字节坐标。 */
const P256_SPKI_PREFIX: number[] = [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
  0x03, 0x01, 0x07, 0x03, 0x42, 0x00
];
/** P-256 SPKI DER 的总长：前缀 26 + 未压缩点标记 1 + 坐标 64。 */
const P256_SPKI_BYTES: number = 91;
const UNCOMPRESSED_POINT: number = 0x04;

/**
 * 验签通过的可信 H5 源白名单：version = payload.version（非负安全整数），origins = payload.origins 原样（每项本身就是规范化
 * https origin，顺序不变）。同时是 ConfigStore 的「上次可用白名单」（随 LKG 落盘为 bridge_origins_last_good）。
 */
export class BridgeOriginsLastGood {
  readonly version: number;
  readonly origins: string[];

  constructor(version: number, origins: string[]) {
    this.version = version;
    this.origins = origins;
  }
}

/**
 * ConfigStore 注入的验签闭包（scope.md P4 ①）：入参为 /v1/config 的 data（JSON 文本）与上次可用白名单的 version（没有为 null）；
 * 通过返回白名单，不通过返回 null。
 */
export type BridgeOriginsCheck = (dataJson: string, lastGoodVersion: number | null) => BridgeOriginsLastGood | null;

/** 公钥表里一把钥的可见信息（不含公钥本身）。spkiSha256Prefix16 = SPKI DER 的 sha256 小写十六进制前 16 位。 */
export class ConfigSignKeyEntry {
  readonly env: string;
  readonly kid: string;
  readonly spkiSha256Prefix16: string;

  constructor(env: string, kid: string, spkiSha256Prefix16: string) {
    this.env = env;
    this.kid = kid;
    this.spkiSha256Prefix16 = spkiSha256Prefix16;
  }
}

/** 表里的一把钥：可见信息 + SPKI DER（只在表内持有，对外给副本）。 */
class LoadedSignKey {
  readonly entry: ConfigSignKeyEntry;
  readonly spkiDer: Uint8Array;

  constructor(entry: ConfigSignKeyEntry, spkiDer: Uint8Array) {
    this.entry = entry;
    this.spkiDer = spkiDer;
  }
}

/** 字节 → 小写十六进制。 */
function hexOfBytes(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  }
  return out;
}

/** P-256 SPKI 的结构判定（见 ConfigSignKeys 注释）。CryptoKitEs256 导入前也用它，保证非 P-256 公钥不交给系统接口。 */
function isP256Spki(der: Uint8Array): boolean {
  if (der.length !== P256_SPKI_BYTES) {
    return false;
  }
  for (let i: number = 0; i < P256_SPKI_PREFIX.length; i++) {
    if (der[i] !== P256_SPKI_PREFIX[i]) {
      return false;
    }
  }
  return der[P256_SPKI_PREFIX.length] === UNCOMPRESSED_POINT;
}

/**
 * 随包的配置签名公钥表（scope.md P1；安卓 ConfigSignKeys）：按 (运行环境 id, kid) 取 P-256 公钥的 SPKI DER。
 * - parse：空白或逗号分隔的若干项 `env:kid:<SPKI DER 十六进制>`（十六进制大小写都认）；段数不是 3、env 或 kid 为空、十六进制不成立
 *   （非十六进制字符、奇数位、空）、不是 P-256 SPKI 的项跳过，不抛。同一 (env, kid) 多次出现时后者覆盖前者。
 * - 「是 P-256 SPKI」只做结构判定（本机单测里 cryptoFramework 是空实现）：正好 91 字节、前 26 字节为
 *   3059301306072a8648ce3d020106082a8648ce3d030107034200、第 27 字节为 04（未压缩点）。点是否在曲线上由端口导入时判（设备步）；
 *   这与安卓在构造时用 KeyFactory 核曲线不同（test-handback §4 注 2）。
 * - sha256 用纯 ArkTS 的 clientcore/Sha256（不用 cryptoFramework，本机单测可测）。
 * - entries 按 env、kid 排序。
 */
export class ConfigSignKeys {
  private static readonly SEPARATORS: RegExp = new RegExp('[\\s,]+');
  private static readonly HEX: RegExp = new RegExp('^(?:[0-9a-fA-F]{2})+$');
  private static readonly ITEM_SEGMENTS: number = 3;
  private static readonly SHA_PREFIX_CHARS: number = 16;

  /** 空表：任何 jws 都验不过（no_key_for_kid_env）。 */
  static readonly EMPTY: ConfigSignKeys = new ConfigSignKeys([]);

  /** env → kid → 钥。 */
  private readonly byEnvKid: Map<string, Map<string, LoadedSignKey>> = new Map<string, Map<string, LoadedSignKey>>();

  private constructor(keys: LoadedSignKey[]) {
    for (const key of keys) {
      let byKid: Map<string, LoadedSignKey> | undefined = this.byEnvKid.get(key.entry.env);
      if (byKid === undefined) {
        byKid = new Map<string, LoadedSignKey>();
        this.byEnvKid.set(key.entry.env, byKid);
      }
      byKid.set(key.entry.kid, key);
    }
  }

  /** 解析构建配置串（见类注释）。 */
  static parse(spec: string): ConfigSignKeys {
    const keys: LoadedSignKey[] = [];
    for (const item of spec.split(ConfigSignKeys.SEPARATORS)) {
      if (item.length === 0) {
        continue;
      }
      const key: LoadedSignKey | null = ConfigSignKeys.parseItem(item);
      if (key !== null) {
        keys.push(key);
      }
    }
    return keys.length === 0 ? ConfigSignKeys.EMPTY : new ConfigSignKeys(keys);
  }

  /** 本构建随包的表（'core/ets/config/ConfigSignKeysBundled' 按 target 二选一）。 */
  static bundled(): ConfigSignKeys {
    return ConfigSignKeys.parse(CONFIG_SIGN_KEYS_BUNDLED);
  }

  /** 全部可用的钥，按 env、kid 排序（同一 env + kid 只一项）。 */
  get entries(): ConfigSignKeyEntry[] {
    const out: ConfigSignKeyEntry[] = [];
    this.byEnvKid.forEach((byKid: Map<string, LoadedSignKey>): void => {
      byKid.forEach((key: LoadedSignKey): void => {
        out.push(key.entry);
      });
    });
    out.sort((a: ConfigSignKeyEntry, b: ConfigSignKeyEntry): number => {
      if (a.env !== b.env) {
        return a.env < b.env ? -1 : 1;
      }
      return a.kid < b.kid ? -1 : (a.kid > b.kid ? 1 : 0);
    });
    return out;
  }

  /** 是否有 (env, kid) 这一把。 */
  hasKey(env: string, kid: string): boolean {
    return this.find(env, kid) !== null;
  }

  /** (env, kid) 的 SPKI DER（副本）；没有为 null。 */
  publicKey(env: string, kid: string): Uint8Array | null {
    const key: LoadedSignKey | null = this.find(env, kid);
    return key === null ? null : new Uint8Array(key.spkiDer);
  }

  private find(env: string, kid: string): LoadedSignKey | null {
    const byKid: Map<string, LoadedSignKey> | undefined = this.byEnvKid.get(env);
    if (byKid === undefined) {
      return null;
    }
    const key: LoadedSignKey | undefined = byKid.get(kid);
    return key === undefined ? null : key;
  }

  /** 一项 `env:kid:<hex>`；段数不对、env / kid 为空、十六进制不成立、不是 P-256 SPKI 为 null。 */
  private static parseItem(item: string): LoadedSignKey | null {
    const parts: string[] = item.split(':');
    if (parts.length !== ConfigSignKeys.ITEM_SEGMENTS || parts[0].length === 0 || parts[1].length === 0 ||
      !ConfigSignKeys.HEX.test(parts[2])) {
      return null;
    }
    const hex: string = parts[2];
    const der: Uint8Array = new Uint8Array(hex.length / 2);
    for (let i: number = 0; i < der.length; i++) {
      der[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    }
    if (!isP256Spki(der)) {
      return null;
    }
    const sha16: string = hexOfBytes(Sha256.digest(der)).substring(0, ConfigSignKeys.SHA_PREFIX_CHARS);
    return new LoadedSignKey(new ConfigSignKeyEntry(parts[0], parts[1], sha16), der);
  }

}

/**
 * ES256 验签端口（scope.md P2；照 RequestSigner 的 DigestPort / CryptoKitDigest 先例做成可注入）：Local Test 里 cryptoFramework 是
 * 空实现，本机单测注入假端口，真验签只在 core 设备用例里跑。
 */
export interface Es256Port {
  /**
   * spkiDer：P-256 公钥的 SPKI DER；signingInput：ASCII 的 `header.payload`；p1363：64 字节 R‖S。
   * 验过返回 true；验不过、公钥导入失败（含非 P-256、坏 SPKI）、签名转换或系统接口出错一律 false，不抛。
   */
  verify(spkiDer: Uint8Array, signingInput: Uint8Array, p1363: Uint8Array): boolean;
}

/**
 * 生产端口：@kit.CryptoArchitectureKit（docs/harmony-ref/crypto-architecture-kit.md 第一节，只用同步接口）——
 * createAsyKeyGenerator('ECC256').convertKeySync({ data: spkiDer }, null).pubKey → createVerify('ECC256|SHA256') → initSync →
 * verifySync({ data: signingInput }, { data: Es256.p1363ToDer(p1363) })。
 * 不是 P-256 SPKI 结构（含 P-384、截断、空）的公钥不交给系统接口，直接 false；导入失败、验签抛错一律按 false，不往外抛。
 */
export class CryptoKitEs256 implements Es256Port {
  verify(spkiDer: Uint8Array, signingInput: Uint8Array, p1363: Uint8Array): boolean {
    const der: Uint8Array | null = Es256.p1363ToDer(p1363);
    if (der === null || !isP256Spki(spkiDer)) {
      return false;
    }
    try {
      const generator: cryptoFramework.AsyKeyGenerator = cryptoFramework.createAsyKeyGenerator('ECC256');
      const keyPair: cryptoFramework.KeyPair = generator.convertKeySync({ data: spkiDer }, null);
      const verifier: cryptoFramework.Verify = cryptoFramework.createVerify('ECC256|SHA256');
      verifier.initSync(keyPair.pubKey);
      return verifier.verifySync({ data: signingInput }, { data: der }) === true;
    } catch (e) {
      return false;
    }
  }
}

/** ES256 签名格式工具（scope.md §2 路线 A；安卓 Es256.toDer）。 */
export class Es256 {
  static readonly SIGNATURE_BYTES: number = 64;
  private static readonly SIGN_BIT: number = 0x80;
  private static readonly DER_INTEGER: number = 0x02;
  private static readonly DER_SEQUENCE: number = 0x30;

  /**
   * 64 字节 R‖S（IEEE P1363）→ DER `SEQUENCE { INTEGER r, INTEGER s }`：各半去掉前导 0x00；全 0 时为单字节 0x00；最高位为 1 时
   * 前补 0x00；长度都在单字节内。输入不是 64 字节为 null。
   */
  static p1363ToDer(p1363: Uint8Array): Uint8Array | null {
    if (p1363.length !== Es256.SIGNATURE_BYTES) {
      return null;
    }
    const half: number = Es256.SIGNATURE_BYTES / 2;
    const r: number[] = Es256.derInteger(p1363, 0, half);
    const s: number[] = Es256.derInteger(p1363, half, Es256.SIGNATURE_BYTES);
    const out: number[] = [Es256.DER_SEQUENCE, r.length + s.length];
    for (const b of r) {
      out.push(b);
    }
    for (const b of s) {
      out.push(b);
    }
    return new Uint8Array(out);
  }

  /** bytes[from, to) 作为无符号大端整数 → DER INTEGER（标签、长度、值）。 */
  private static derInteger(bytes: Uint8Array, from: number, to: number): number[] {
    let start: number = from;
    while (start < to && bytes[start] === 0) {
      start++;
    }
    const value: number[] = [];
    if (start === to) {
      value.push(0);
    } else {
      if ((bytes[start] & Es256.SIGN_BIT) !== 0) {
        value.push(0);
      }
      for (let i: number = start; i < to; i++) {
        value.push(bytes[i]);
      }
    }
    const out: number[] = [Es256.DER_INTEGER, value.length];
    for (const b of value) {
      out.push(b);
    }
    return out;
  }
}

/** base64url 解码（scope.md P3；纯 ArkTS）。 */
export class Base64Url {
  /**
   * 字符集只认 `[A-Za-z0-9_-]`、无填充；长度 % 4 == 1 不成立 → null；'' → 空字节。末组多出的位不核对（同 java Base64 URL 解码器）。
   */
  static decode(segment: string): Uint8Array | null {
    if (segment.length % 4 === 1) {
      return null;
    }
    const out: Uint8Array = new Uint8Array(Math.floor(segment.length * 3 / 4));
    let buffer: number = 0;
    let bits: number = 0;
    let index: number = 0;
    for (let i: number = 0; i < segment.length; i++) {
      const value: number = Base64Url.sextet(segment.charCodeAt(i));
      if (value < 0) {
        return null;
      }
      buffer = ((buffer << 6) | value) & 0xFFFF;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[index] = (buffer >> bits) & 0xFF;
        index++;
      }
    }
    return out;
  }

  /** 一个字符的 6 位值；不在 URL 字母表里为 -1。 */
  private static sextet(c: number): number {
    if (c >= 0x41 && c <= 0x5A) {
      return c - 0x41;
    }
    if (c >= 0x61 && c <= 0x7A) {
      return c - 0x61 + 26;
    }
    if (c >= 0x30 && c <= 0x39) {
      return c - 0x30 + 52;
    }
    if (c === 0x2D) {
      return 62;
    }
    return c === 0x5F ? 63 : -1;
  }
}

/** 一次验签的判定：通过时 allowlist 非 null、reason 为 ''；拒绝时 allowlist 为 null、reason 为约定字符串之一（只供日志定位）。 */
export class BridgeOriginsVerdict {
  readonly allowlist: BridgeOriginsLastGood | null;
  readonly reason: string;

  private constructor(allowlist: BridgeOriginsLastGood | null, reason: string) {
    this.allowlist = allowlist;
    this.reason = reason;
  }

  static accepted(allowlist: BridgeOriginsLastGood): BridgeOriginsVerdict {
    return new BridgeOriginsVerdict(allowlist, '');
  }

  static rejected(reason: string): BridgeOriginsVerdict {
    return new BridgeOriginsVerdict(null, reason);
  }

  get isAccepted(): boolean {
    return this.allowlist !== null;
  }
}

/**
 * bridge_origins 的 ES256 JWS 验签（契约 ConfigBridgeOrigins 的 description；规则顺序同向量 rules_order 与安卓 :182-218）：
 * 1. 三段、每段非空且只含 `[A-Za-z0-9_-]`（无填充）、三段都能解码、header 是 JSON 对象 → 否则 malformed
 * 2. header.alg === 'ES256' → bad_alg
 * 3. header.kid（字符串）+ 运行环境 id 在公钥表里 → no_key_for_kid_env（1–3 不调端口）
 * 4. 签名段解码后正好 64 字节 → bad_signature_format（不调端口）；端口验 ASCII `header.payload` → false / 抛错为 bad_signature
 * 5. header.typ === 'couli-bridge-origins+jws'（缺失也拒）→ bad_typ
 * 6. payload 是 JSON 对象（否则 bad_payload）；payload 顶层 `v` 的原文字面量正好是 `1` → bad_v；app_id、env 为字符串且相等 →
 *    app_id_mismatch / env_mismatch
 * 7. payload 顶层 `version` 的原文字面量是非负十进制整数（`0|[1-9][0-9]*`）且 ≤ 9007199254740991 → bad_payload；
 *    有上次可用时 ≥ 它（相等通过）→ version_rollback
 * 8. origins 是非空数组 → bad_payload；每项是字符串且本身就是规范化 https origin（小写 LDH 主机、可选端口：无前导 0、1..65535、
 *    不是 443；无路径 / 查询 / 片段 / 凭据 / 通配 / 结尾点 / 空白）→ bad_origin。不先规范化再接受。
 * (c)：`v` / `version` 按 payload 原文做最小词法取顶层字面量（见 topLevelLiterals）——JSON.parse 会把 1.0 / 1e0 当成 1。
 */
export class BridgeOriginsVerifier {
  static readonly REASON_MALFORMED: string = 'malformed';
  static readonly REASON_BAD_ALG: string = 'bad_alg';
  static readonly REASON_NO_KEY: string = 'no_key_for_kid_env';
  static readonly REASON_BAD_SIGNATURE_FORMAT: string = 'bad_signature_format';
  static readonly REASON_BAD_SIGNATURE: string = 'bad_signature';
  static readonly REASON_BAD_TYP: string = 'bad_typ';
  static readonly REASON_BAD_V: string = 'bad_v';
  static readonly REASON_APP_ID_MISMATCH: string = 'app_id_mismatch';
  static readonly REASON_ENV_MISMATCH: string = 'env_mismatch';
  static readonly REASON_BAD_PAYLOAD: string = 'bad_payload';
  static readonly REASON_VERSION_ROLLBACK: string = 'version_rollback';
  static readonly REASON_BAD_ORIGIN: string = 'bad_origin';
  /** 约定的 12 个 reason（拒绝时必为其一）。 */
  static readonly REASONS: string[] = ['malformed', 'bad_alg', 'no_key_for_kid_env', 'bad_signature_format',
    'bad_signature', 'bad_typ', 'bad_v', 'app_id_mismatch', 'env_mismatch', 'bad_payload', 'version_rollback',
    'bad_origin'];

  private static readonly ALG: string = 'ES256';
  private static readonly TYP: string = 'couli-bridge-origins+jws';
  private static readonly JWS_SEGMENTS: number = 3;
  private static readonly KEY_BRIDGE_ORIGINS: string = 'bridge_origins';
  private static readonly KEY_JWS: string = 'jws';
  private static readonly KEY_V: string = 'v';
  private static readonly KEY_VERSION: string = 'version';
  private static readonly HTTPS_DEFAULT_PORT: number = 443;
  private static readonly MAX_PORT: number = 65535;
  private static readonly B64URL: RegExp = new RegExp('^[A-Za-z0-9_-]+$');
  /** 非负十进制整数字面量（无符号、无前导 0、无小数点与指数）。 */
  private static readonly NON_NEGATIVE_INTEGER: RegExp = new RegExp('^(?:0|[1-9][0-9]*)$');
  /**
   * version 上限 = Number.MAX_SAFE_INTEGER（D10-3606）。2^53 及以上一律拒：ArkTS 的 JSON.parse 把 9007199254740992 与
   * 9007199254740993 解析成同一个数，number 分不开它们，「≥ 上次可用」的比较就不可靠；所以按原文字面量判，超过这个值不接受。
   */
  private static readonly MAX_VERSION_LITERAL: string = '9007199254740991';
  /**
   * 规范化 https origin 的**原样**写法（与参考校验器 check-vectors.py、安卓 :170-171 同一正则）：小写 LDH 主机标签、可选端口；
   * 不做任何规范化。端口另外要求 1..65535、不是 443（无前导 0 由正则保证）。
   */
  private static readonly ORIGIN: RegExp = new RegExp(
    '^https://[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?::([1-9][0-9]{0,4}))?$');

  /** 验一段 JWS compact（见类注释）。lastGoodVersion 为上次可用白名单的 version，没有为 null。不抛。 */
  static verify(jws: string, appId: string, env: string, lastGoodVersion: number | null, keys: ConfigSignKeys,
    es256: Es256Port): BridgeOriginsVerdict {
    // 1. 三段 base64url（无填充、每段非空），三段都能解码；header 是 JSON 对象
    const parts: string[] = jws.split('.');
    if (parts.length !== BridgeOriginsVerifier.JWS_SEGMENTS) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_MALFORMED);
    }
    const decoded: Uint8Array[] = [];
    for (const part of parts) {
      const bytes: Uint8Array | null = BridgeOriginsVerifier.B64URL.test(part) ? Base64Url.decode(part) : null;
      if (bytes === null) {
        return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_MALFORMED);
      }
      decoded.push(bytes);
    }
    const header: JsonObject | null = BridgeOriginsVerifier.parseObject(BridgeOriginsVerifier.utf8Text(decoded[0]));
    if (header === null) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_MALFORMED);
    }
    // 2. alg
    if (BridgeOriginsVerifier.stringField(header, 'alg') !== BridgeOriginsVerifier.ALG) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_ALG);
    }
    // 3. 按 kid + 当前运行环境 id 取随包公钥
    const kid: string | null = BridgeOriginsVerifier.stringField(header, 'kid');
    const spki: Uint8Array | null = kid === null ? null : keys.publicKey(env, kid);
    if (spki === null) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_NO_KEY);
    }
    // 4. 签名：正好 64 字节 R‖S（P1363）；签名输入是 ASCII 的原样两段
    const signature: Uint8Array = decoded[2];
    if (signature.length !== Es256.SIGNATURE_BYTES) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_SIGNATURE_FORMAT);
    }
    if (!BridgeOriginsVerifier.portVerifies(es256, spki, BridgeOriginsVerifier.asciiBytes(parts[0] + '.' + parts[1]),
      signature)) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_SIGNATURE);
    }
    // 5. typ（缺失也拒）
    if (BridgeOriginsVerifier.stringField(header, 'typ') !== BridgeOriginsVerifier.TYP) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_TYP);
    }
    return BridgeOriginsVerifier.checkPayload(BridgeOriginsVerifier.utf8Text(decoded[1]), appId, env, lastGoodVersion);
  }

  /**
   * 从 /v1/config 的 data（JSON 文本）取 `bridge_origins.jws` 再验。data 不是 JSON 对象、缺 bridge_origins、bridge_origins 不是对象
   * （含旧的字符串数组形状、null、字符串）、缺 jws 或 jws 不是字符串 → malformed。
   */
  static verifyConfig(dataJson: string, appId: string, env: string, lastGoodVersion: number | null,
    keys: ConfigSignKeys, es256: Es256Port): BridgeOriginsVerdict {
    const jws: string | null = BridgeOriginsVerifier.jwsIn(dataJson);
    if (jws === null) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_MALFORMED);
    }
    return BridgeOriginsVerifier.verify(jws, appId, env, lastGoodVersion, keys, es256);
  }

  /** 只供日志定位：data 里 bridge_origins.jws 的 header.kid（未验签原值，调用方自行过滤 / 截断）；取不到为 null。 */
  static headerKidIn(dataJson: string): string | null {
    const jws: string | null = BridgeOriginsVerifier.jwsIn(dataJson);
    if (jws === null) {
      return null;
    }
    const parts: string[] = jws.split('.');
    if (parts.length !== BridgeOriginsVerifier.JWS_SEGMENTS || !BridgeOriginsVerifier.B64URL.test(parts[0])) {
      return null;
    }
    const bytes: Uint8Array | null = Base64Url.decode(parts[0]);
    const header: JsonObject | null = bytes === null ? null :
      BridgeOriginsVerifier.parseObject(BridgeOriginsVerifier.utf8Text(bytes));
    return header === null ? null : BridgeOriginsVerifier.stringField(header, 'kid');
  }

  /** 规则 6–8（验签通过之后）。 */
  private static checkPayload(text: string, appId: string, env: string, lastGoodVersion: number | null):
    BridgeOriginsVerdict {
    const payload: JsonObject | null = BridgeOriginsVerifier.parseObject(text);
    const literals: Map<string, string> | null = payload === null ? null : BridgeOriginsVerifier.topLevelLiterals(text);
    if (payload === null || literals === null) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_PAYLOAD);
    }
    // 6. v 的原文字面量正好是 1（1.0、1e0、"1"、true 都不算）；app_id、env
    if (literals.get(BridgeOriginsVerifier.KEY_V) !== '1') {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_V);
    }
    if (BridgeOriginsVerifier.stringField(payload, 'app_id') !== appId) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_APP_ID_MISMATCH);
    }
    if (BridgeOriginsVerifier.stringField(payload, 'env') !== env) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_ENV_MISMATCH);
    }
    // 7. version：非负十进制整数字面量、≤ MAX_SAFE_INTEGER；有上次可用时 ≥ 它（相等算通过）
    const version: number | null = BridgeOriginsVerifier.versionOf(literals.get(BridgeOriginsVerifier.KEY_VERSION));
    if (version === null) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_PAYLOAD);
    }
    if (lastGoodVersion !== null && version < lastGoodVersion) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_VERSION_ROLLBACK);
    }
    // 8. origins：非空数组，每项是字符串且本身就是规范化 https origin
    const origins: Object | undefined = payload['origins'];
    if (origins === undefined || origins === null || !Array.isArray(origins) || (origins as Object[]).length === 0) {
      return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_PAYLOAD);
    }
    const values: string[] = [];
    for (const item of origins as Object[]) {
      if (typeof item !== 'string' || !BridgeOriginsVerifier.isCanonicalHttpsOrigin(item as string)) {
        return BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_BAD_ORIGIN);
      }
      values.push(item as string);
    }
    return BridgeOriginsVerdict.accepted(new BridgeOriginsLastGood(version, values));
  }

  /** 端口验签；false、非布尔、抛错都按验不过。 */
  private static portVerifies(es256: Es256Port, spki: Uint8Array, input: Uint8Array, signature: Uint8Array): boolean {
    try {
      return es256.verify(spki, input, signature) === true;
    } catch (e) {
      return false;
    }
  }

  /** data 里的 bridge_origins.jws（字符串）；形状不对为 null。 */
  private static jwsIn(dataJson: string): string | null {
    const data: JsonObject | null = BridgeOriginsVerifier.parseObject(dataJson);
    const bridge: JsonObject | null = data === null ? null :
      BridgeOriginsVerifier.objectOf(data[BridgeOriginsVerifier.KEY_BRIDGE_ORIGINS]);
    return bridge === null ? null : BridgeOriginsVerifier.stringField(bridge, BridgeOriginsVerifier.KEY_JWS);
  }

  /** version 字面量 → 数值；不是非负十进制整数字面量、或大于 9007199254740991 为 null（理由见 MAX_VERSION_LITERAL）。 */
  private static versionOf(literal: string | undefined): number | null {
    if (literal === undefined || !BridgeOriginsVerifier.NON_NEGATIVE_INTEGER.test(literal)) {
      return null;
    }
    const max: string = BridgeOriginsVerifier.MAX_VERSION_LITERAL;
    if (literal.length > max.length || (literal.length === max.length && literal > max)) {
      return null;
    }
    return parseInt(literal, 10);
  }

  private static isCanonicalHttpsOrigin(text: string): boolean {
    const match: RegExpMatchArray | null = text.match(BridgeOriginsVerifier.ORIGIN);
    if (match === null) {
      return false;
    }
    const port: string | undefined = match[1];
    if (port === undefined || port.length === 0) {
      return true;
    }
    const number: number = parseInt(port, 10);
    return number >= 1 && number <= BridgeOriginsVerifier.MAX_PORT && number !== BridgeOriginsVerifier.HTTPS_DEFAULT_PORT;
  }

  /**
   * payload 原文顶层各键的值字面量（原样子串）。只在 JSON.parse 已确认是对象之后调用，所以只需最小词法：跳过字符串（含转义）、
   * 按括号深度跳过嵌套对象 / 数组，其余字面量取到下一个 `,` `}` `]` 或空白为止。键名按 JSON 解码后比较（`"v"` 也是 v）；
   * 同名键取最后一个（与 JSON.parse 一致）。词法不成立时为 null（按 bad_payload）。
   */
  private static topLevelLiterals(text: string): Map<string, string> | null {
    const out: Map<string, string> = new Map<string, string>();
    let i: number = BridgeOriginsVerifier.skipSpace(text, 0);
    if (text.charAt(i) !== '{') {
      return null;
    }
    i = BridgeOriginsVerifier.skipSpace(text, i + 1);
    if (text.charAt(i) === '}') {
      return out;
    }
    while (i < text.length) {
      if (text.charAt(i) !== '"') {
        return null;
      }
      const keyEnd: number = BridgeOriginsVerifier.stringEnd(text, i);
      if (keyEnd < 0) {
        return null;
      }
      let key: Object;
      try {
        key = JSON.parse(text.substring(i, keyEnd)) as Object;
      } catch (e) {
        return null;
      }
      i = BridgeOriginsVerifier.skipSpace(text, keyEnd);
      if (text.charAt(i) !== ':') {
        return null;
      }
      const start: number = BridgeOriginsVerifier.skipSpace(text, i + 1);
      const end: number = BridgeOriginsVerifier.valueEnd(text, start);
      if (end <= start || typeof key !== 'string') {
        return null;
      }
      out.set(key as string, text.substring(start, end));
      i = BridgeOriginsVerifier.skipSpace(text, end);
      if (text.charAt(i) === '}') {
        return out;
      }
      if (text.charAt(i) !== ',') {
        return null;
      }
      i = BridgeOriginsVerifier.skipSpace(text, i + 1);
    }
    return null;
  }

  /** JSON 的四种空白。 */
  private static skipSpace(text: string, from: number): number {
    let i: number = from;
    while (i < text.length) {
      const c: string = text.charAt(i);
      if (c !== ' ' && c !== '\t' && c !== '\n' && c !== '\r') {
        break;
      }
      i++;
    }
    return i;
  }

  /** from 处是 `"`：返回收尾引号之后的位置；没收尾为 -1。 */
  private static stringEnd(text: string, from: number): number {
    let i: number = from + 1;
    while (i < text.length) {
      const c: string = text.charAt(i);
      if (c === '\\') {
        i += 2;
      } else if (c === '"') {
        return i + 1;
      } else {
        i++;
      }
    }
    return -1;
  }

  /** from 处一个值的结束位置（不含）；不成立为 -1。 */
  private static valueEnd(text: string, from: number): number {
    const first: string = text.charAt(from);
    if (first === '"') {
      return BridgeOriginsVerifier.stringEnd(text, from);
    }
    if (first === '{' || first === '[') {
      let depth: number = 0;
      let i: number = from;
      while (i < text.length) {
        const c: string = text.charAt(i);
        if (c === '"') {
          i = BridgeOriginsVerifier.stringEnd(text, i);
          if (i < 0) {
            return -1;
          }
          continue;
        }
        if (c === '{' || c === '[') {
          depth++;
        } else if (c === '}' || c === ']') {
          depth--;
          if (depth === 0) {
            return i + 1;
          }
        }
        i++;
      }
      return -1;
    }
    let i: number = from;
    while (i < text.length) {
      const c: string = text.charAt(i);
      if (c === ',' || c === '}' || c === ']' || c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        break;
      }
      i++;
    }
    return i;
  }

  private static parseObject(text: string): JsonObject | null {
    try {
      return BridgeOriginsVerifier.objectOf(JSON.parse(text) as Object | null);
    } catch (e) {
      return null;
    }
  }

  private static objectOf(value: Object | null | undefined): JsonObject | null {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as JsonObject;
  }

  private static stringField(record: JsonObject, key: string): string | null {
    const value: Object | undefined = record[key];
    return typeof value === 'string' ? value as string : null;
  }

  /** UTF-8 字节 → 字符串（非法序列替换为 U+FFFD，不去 BOM：带 BOM 的 JSON 解析不成立）。 */
  private static utf8Text(bytes: Uint8Array): string {
    return StreamUtf8Decoder.decodeAll(bytes, false);
  }

  /** 签名输入（三段已确认只含 ASCII 的 base64url 字符）。 */
  private static asciiBytes(text: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(text.length);
    for (let i: number = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i);
    }
    return out;
  }
}

/** 拒绝日志的去重状态（同一闭包内，上一次记过的 (env, reason, bridge_origins 原值)）。 */
class BridgeOriginsWarnState {
  lastKey: string | null = null;
}

/**
 * 生产接线用的验签闭包（scope.md E1；安卓 AppConfig.bridgeOriginsVerifier）。放在 core 是为了本机可测；entry 的 AppClientCore 以
 * `BridgeOriginsWiring.check(() => 当前环境 id, APP_ID, ConfigSignKeys.bundled(), new CryptoKitEs256(), hilog 出口)` 传给 ConfigStore。
 * - 每次调用现取 environmentId()（切环境后用新环境）；undefined（环境闸门非 SETTLED）或取值抛错 → 拒（no_key_for_kid_env），不调端口。
 * - 用 verifyConfig 判定；通过返回 allowlist，拒绝返回 null 并调 warn 一行
 *   `bridge_origins rejected: reason=<reason> kid=<kid> env=<env>`：kid 取 headerKidIn，只留 `[A-Za-z0-9._-]`、截断到 64 字符，取不到为 `-`；
 *   env 同样过滤，未定为 `-`；不写 jws 与 origins。同一 (env, reason, bridge_origins 原值) 与上一次相同时不再记。warn 抛错不影响判定。
 */
export class BridgeOriginsWiring {
  private static readonly LOG_MAX: number = 64;
  private static readonly LOG_UNSAFE: RegExp = new RegExp('[^A-Za-z0-9._-]', 'g');

  static check(environmentId: () => string | undefined, appId: string, keys: ConfigSignKeys, es256: Es256Port,
    warn: (line: string) => void = (_line: string): void => {
    }): BridgeOriginsCheck {
    const state: BridgeOriginsWarnState = new BridgeOriginsWarnState();
    return (dataJson: string, lastGoodVersion: number | null): BridgeOriginsLastGood | null => {
      let env: string | undefined = undefined;
      try {
        env = environmentId();
      } catch (e) {
        env = undefined;
      }
      const verdict: BridgeOriginsVerdict = env === undefined ?
        BridgeOriginsVerdict.rejected(BridgeOriginsVerifier.REASON_NO_KEY) :
        BridgeOriginsVerifier.verifyConfig(dataJson, appId, env, lastGoodVersion, keys, es256);
      const allowlist: BridgeOriginsLastGood | null = verdict.allowlist;
      if (allowlist !== null) {
        return new BridgeOriginsLastGood(allowlist.version, allowlist.origins.slice());
      }
      BridgeOriginsWiring.warnRejected(state, warn, dataJson, verdict.reason, env);
      return null;
    };
  }

  private static warnRejected(state: BridgeOriginsWarnState, warn: (line: string) => void, dataJson: string,
    reason: string, env: string | undefined): void {
    const envText: string = env === undefined ? '-' : BridgeOriginsWiring.safe(env);
    const key: string = envText + '\n' + reason + '\n' + BridgeOriginsWiring.bridgeOriginsRaw(dataJson);
    if (state.lastKey === key) {
      return;
    }
    state.lastKey = key;
    const kidRaw: string | null = BridgeOriginsVerifier.headerKidIn(dataJson);
    const kid: string = kidRaw === null ? '-' : BridgeOriginsWiring.safe(kidRaw);
    try {
      warn('bridge_origins rejected: reason=' + reason + ' kid=' + kid + ' env=' + envText);
    } catch (e) {
      // 日志出口出错不影响判定。
    }
  }

  /** 只留 [A-Za-z0-9._-]、截断到 64；过滤后为空为 `-`。 */
  private static safe(text: string): string {
    const kept: string = text.replace(BridgeOriginsWiring.LOG_UNSAFE, '').substring(0, BridgeOriginsWiring.LOG_MAX);
    return kept.length === 0 ? '-' : kept;
  }

  /** 去重用：data 里 bridge_origins 的原值（JSON 文本）；data 不是对象为整段 data。 */
  private static bridgeOriginsRaw(dataJson: string): string {
    try {
      const data: Object | null = JSON.parse(dataJson) as Object | null;
      if (data !== null && typeof data === 'object' && !Array.isArray(data)) {
        const value: Object | undefined = (data as JsonObject)['bridge_origins'];
        return value === undefined ? 'undefined' : JSON.stringify(value);
      }
    } catch (e) {
      // 解析不了：按整段原文去重。
    }
    return dataJson;
  }
}
