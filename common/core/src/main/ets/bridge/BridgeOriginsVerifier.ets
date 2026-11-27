// N-22 bridge_origins 的 ES256 JWS 验签（FU-HM-BRIDGE-ORIGINS-VERIFY；D10-3507 / D10-3512；scope.md P1–P3）。
// 与安卓 core/bridge/BridgeOriginsVerifier.kt 同口径；三端共用向量 NATIVE/N22-VECTORS/n22-bridge-origins-vectors.json。
//
// 【写测步的桩】判定一律拒（reason 为 STUB_REASON，不在约定的 12 个 reason 里）、白名单一律空、解析 / 解码一律 null、
// 端口生产实现抛「未实现」。公开类型名与签名即实现步的接口，实现步按各处注释填，签名不改。
import { CONFIG_SIGN_KEYS_BUNDLED } from 'core/ets/config/ConfigSignKeysBundled';

/** 写测步桩的拒绝原因（实现后不再出现）。 */
const STUB_REASON: string = 'not_implemented';

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

/**
 * 随包的配置签名公钥表（scope.md P1；安卓 ConfigSignKeys）：按 (运行环境 id, kid) 取 P-256 公钥的 SPKI DER。
 * 实现步口径：
 * - parse：空白或逗号分隔的若干项 `env:kid:<SPKI DER 十六进制>`（十六进制大小写都认）；段数不是 3、env 或 kid 为空、十六进制不成立
 *   （非十六进制字符、奇数位、空）、不是 P-256 SPKI 的项跳过，不抛。同一 (env, kid) 多次出现时后者覆盖前者。
 * - 「是 P-256 SPKI」只做结构判定（本机单测里 cryptoFramework 是空实现）：正好 91 字节、前 26 字节为
 *   3059301306072a8648ce3d020106082a8648ce3d030107034200、第 27 字节为 04（未压缩点）。点是否在曲线上由端口导入时判（设备步）。
 * - sha256 用纯 ArkTS 的 clientcore/Sha256（不用 cryptoFramework，本机单测可测）。
 * - entries 按 env、kid 排序。
 */
export class ConfigSignKeys {
  /** 空表：任何 jws 都验不过（no_key_for_kid_env）。 */
  static readonly EMPTY: ConfigSignKeys = new ConfigSignKeys();

  private constructor() {
  }

  /** 解析构建配置串（见类注释）。桩：恒空表。 */
  static parse(_spec: string): ConfigSignKeys {
    return ConfigSignKeys.EMPTY;
  }

  /** 本构建随包的表（'core/ets/config/ConfigSignKeysBundled' 按 target 二选一）。 */
  static bundled(): ConfigSignKeys {
    return ConfigSignKeys.parse(CONFIG_SIGN_KEYS_BUNDLED);
  }

  /** 全部可用的钥，按 env、kid 排序（同一 env + kid 只一项）。桩：[]。 */
  get entries(): ConfigSignKeyEntry[] {
    return [];
  }

  /** 是否有 (env, kid) 这一把。桩：false。 */
  hasKey(_env: string, _kid: string): boolean {
    return false;
  }

  /** (env, kid) 的 SPKI DER（副本）；没有为 null。桩：null。 */
  publicKey(_env: string, _kid: string): Uint8Array | null {
    return null;
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
 * 生产端口：@kit.CryptoArchitectureKit（docs/harmony-ref/crypto-architecture-kit.md 一节）——
 * createAsyKeyGenerator('ECC256').convertKeySync({ data: spkiDer }, null).pubKey → createVerify('ECC256|SHA256') → initSync →
 * verifySync({ data: signingInput }, { data: Es256.p1363ToDer(p1363) })。任何异常按 false。桩：抛「未实现」。
 */
export class CryptoKitEs256 implements Es256Port {
  verify(_spkiDer: Uint8Array, _signingInput: Uint8Array, _p1363: Uint8Array): boolean {
    throw new Error('CryptoKitEs256 not implemented (FU-HM-BRIDGE-ORIGINS-VERIFY stub)');
  }
}

/** ES256 签名格式工具（scope.md §2 路线 A；安卓 Es256.toDer）。 */
export class Es256 {
  static readonly SIGNATURE_BYTES: number = 64;

  /**
   * 64 字节 R‖S（IEEE P1363）→ DER `SEQUENCE { INTEGER r, INTEGER s }`：各半去掉前导 0x00；全 0 时为单字节 0x00；最高位为 1 时
   * 前补 0x00；长度都在单字节内。输入不是 64 字节为 null。桩：恒 null。
   */
  static p1363ToDer(_p1363: Uint8Array): Uint8Array | null {
    return null;
  }
}

/** base64url 解码（scope.md P3）。 */
export class Base64Url {
  /**
   * 字符集只认 `[A-Za-z0-9_-]`、无填充；长度 % 4 == 1 不成立 → null；'' → 空字节。桩：恒 null。
   */
  static decode(_segment: string): Uint8Array | null {
    return null;
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
 *    不是 443；无路径 / 查询 / 片段 / 凭据 / 通配 / 结尾点 / 空白）→ bad_origin
 * (c)：`v` / `version` 按 payload 原文做最小词法取顶层字面量（JSON.parse 会把 1.0 / 1e0 当 1，2^53 与 2^53+1 不可区分）。
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

  /** 验一段 JWS compact（见类注释）。桩：一律拒。 */
  static verify(_jws: string, _appId: string, _env: string, _lastGoodVersion: number | null, _keys: ConfigSignKeys,
    _es256: Es256Port): BridgeOriginsVerdict {
    return BridgeOriginsVerdict.rejected(STUB_REASON);
  }

  /**
   * 从 /v1/config 的 data（JSON 文本）取 `bridge_origins.jws` 再验。data 不是 JSON 对象、缺 bridge_origins、bridge_origins 不是对象
   * （含旧的字符串数组形状、null、字符串）、缺 jws 或 jws 不是字符串 → malformed。桩：一律拒。
   */
  static verifyConfig(_dataJson: string, _appId: string, _env: string, _lastGoodVersion: number | null,
    _keys: ConfigSignKeys, _es256: Es256Port): BridgeOriginsVerdict {
    return BridgeOriginsVerdict.rejected(STUB_REASON);
  }

  /** 只供日志定位：data 里 bridge_origins.jws 的 header.kid（未验签原值）；取不到为 null。桩：null。 */
  static headerKidIn(_dataJson: string): string | null {
    return null;
  }
}

/**
 * 生产接线用的验签闭包（scope.md E1；安卓 AppConfig.bridgeOriginsVerifier）。放在 core 是为了本机可测；entry 的 AppClientCore 以
 * `BridgeOriginsWiring.check(() => AppConfig.environment()?.current, APP_ID, ConfigSignKeys.bundled(), new CryptoKitEs256(), hilog 出口)`
 * 传给 ConfigStore。实现步口径：
 * - 每次调用现取 environmentId()（切环境后用新环境）；undefined（环境闸门非 SETTLED）→ 拒，不调端口。
 * - 用 verifyConfig 判定；通过返回 allowlist，拒绝返回 null 并调 warn 一行
 *   `bridge_origins rejected: reason=<reason> kid=<kid> env=<env>`：kid 取 headerKidIn，只留 `[A-Za-z0-9._-]`、截断到 64 字符，取不到为 `-`；
 *   env 未定为 `-`；不写 jws 与 origins。同一 (env, reason, bridge_origins 原值) 与上一次相同时不再记。warn 抛错不影响判定。
 * 桩：恒 null，不调 warn。
 */
export class BridgeOriginsWiring {
  static check(_environmentId: () => string | undefined, _appId: string, _keys: ConfigSignKeys, _es256: Es256Port,
    _warn: (line: string) => void = (_line: string): void => {
    }): BridgeOriginsCheck {
    return (_dataJson: string, _lastGoodVersion: number | null): BridgeOriginsLastGood | null => null;
  }
}
