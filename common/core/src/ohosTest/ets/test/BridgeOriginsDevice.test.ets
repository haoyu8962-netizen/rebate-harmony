// FU-HM-BRIDGE-ORIGINS-VERIFY core 设备用例（D10-3512 (a)：33 条真签名向量只在这里跑；鸿蒙模拟器 / 真机，真 cryptoFramework）。
// 端口用生产的 CryptoKitEs256；公钥表装 staging 钥（env staging）与向量测试钥（env test，只在测试里注入）。判定只看 expect.accept 与
// expect.origins（完全相等，含顺序与写法），拒绝时 reason 须是约定的 12 个之一（expect.reason 只供定位）。lastGoodVersion 取向量
// client.last_good_version。数据在 N22VectorsData.ets（全仓唯一含 JWS 字面量的文件）。
// 由 verify.sh:1109 `run_device_tests core common/core core_test` 跑（不带必跑名单，只看 DEVICE_TEST_PASS），不改 entry 设备名单。
import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeOriginsLastGood, BridgeOriginsVerdict, BridgeOriginsVerifier, ConfigSignKeyEntry, ConfigSignKeys, CryptoKitEs256,
  Sha256
} from '../../../../Index';
import { CONFIG_SIGN_KEYS_BUNDLED as STAGING_BUNDLED_KEYS } from '../../../staging/ets/config/ConfigSignKeysBundled';
import {
  N22_STAGING_ENV, N22_STAGING_KID, N22_STAGING_SHA16, N22_STAGING_SPKI_HEX, N22_TEST_ENV, N22_TEST_KID, N22_TEST_SHA16,
  N22_TEST_SPKI_HEX, N22_VECTORS_JSON, P384_SPKI_HEX, STG_LIVE_OK_JWS
} from './N22VectorsData';

const APP_ID: string = 'couli';
const STG_ORIGIN: string = 'https://h5-stg.couliapp.cn';
const ACCEPTED_NAMES: string[] = ['stg_live_ok', 'stg_live_ok_last_good_equal', 't_ok', 't_ok_two_origins_port'];

function same(label: string, actual: Object | null | undefined, expected: Object | null | undefined): void {
  const a: string = JSON.stringify(actual);
  const e: string = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(label + ': actual=' + a + ' expect=' + e);
  }
  expect(a).assertEqual(e);
}

function check(label: string, ok: boolean): void {
  if (!ok) {
    throw new Error(label);
  }
  expect(ok).assertTrue();
}

function bytesOfHex(hex: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(hex.length / 2);
  for (let i: number = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function hexOf(bytes: Uint8Array): string {
  let out: string = '';
  for (let i: number = 0; i < bytes.length; i++) {
    out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
  }
  return out;
}

function asciiBytes(text: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(text.length);
  for (let i: number = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0x7f;
  }
  return out;
}

/** 测试自己的 base64url 解码（只用于取向量签名字节；与被测的 Base64Url 无关）。 */
function b64urlDecode(segment: string): Uint8Array {
  const alphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  const out: number[] = [];
  let buffer: number = 0;
  let bits: number = 0;
  for (let i: number = 0; i < segment.length; i++) {
    buffer = (buffer << 6) | alphabet.indexOf(segment.charAt(i));
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}

function sha16(hex: string): string {
  return hexOf(Sha256.digest(bytesOfHex(hex))).substring(0, 16);
}

function vectorKeys(): ConfigSignKeys {
  return ConfigSignKeys.parse(N22_STAGING_ENV + ':' + N22_STAGING_KID + ':' + N22_STAGING_SPKI_HEX + '\n' + N22_TEST_ENV + ':' +
    N22_TEST_KID + ':' + N22_TEST_SPKI_HEX);
}

function vectorCases(): Record<string, Object>[] {
  const root: Record<string, Object> = JSON.parse(N22_VECTORS_JSON) as Record<string, Object>;
  return root['cases'] as Record<string, Object>[];
}

function describeVerdict(verdict: BridgeOriginsVerdict): string {
  const allow: BridgeOriginsLastGood | null = verdict.allowlist;
  return allow === null ? 'Rejected(' + verdict.reason + ')' :
    'Accepted(version=' + allow.version + ', origins=' + JSON.stringify(allow.origins) + ')';
}

/** 向量 stg_live_ok 的签名输入与 64 字节签名。 */
function liveParts(): string[] {
  return STG_LIVE_OK_JWS.split('.');
}

function stagingData(jws: string): string {
  const bridge: Record<string, Object> = {};
  bridge['jws'] = jws;
  const data: Record<string, Object> = {};
  data['h5_base_url'] = STG_ORIGIN;
  data['bridge_origins'] = bridge;
  return JSON.stringify(data);
}

export default function bridgeOriginsDeviceTest() {
  describe('BridgeOriginsDevice', () => {
    it('device_01_vector_file_is_complete_and_its_keys_match_the_embedded_spki', 0, () => {
      const cases: Record<string, Object>[] = vectorCases();
      same('向量总数', cases.length, 33);
      const names: string[] = cases.map((c: Record<string, Object>): string => c['name'] as string);
      same('向量名不重复', names.filter((n: string, i: number): boolean => names.indexOf(n) === i).length, 33);
      const accepted: string[] = cases.filter((c: Record<string, Object>): boolean =>
      (c['expect'] as Record<string, Object>)['accept'] === true)
        .map((c: Record<string, Object>): string => c['name'] as string);
      same('应通过的 4 条', accepted, ACCEPTED_NAMES);
      same('staging SPKI 自洽（纯 ArkTS sha256）', sha16(N22_STAGING_SPKI_HEX), N22_STAGING_SHA16);
      same('测试钥 SPKI 自洽', sha16(N22_TEST_SPKI_HEX), N22_TEST_SHA16);
      const keys: Record<string, Object>[] =
        (JSON.parse(N22_VECTORS_JSON) as Record<string, Object>)['keys'] as Record<string, Object>[];
      same('向量 keys 与内嵌的两把一致', keys.map((k: Record<string, Object>): string =>
      (k['env'] as string) + '|' + (k['kid'] as string) + '|' + (k['spki_der_sha256_16'] as string)),
        [N22_STAGING_ENV + '|' + N22_STAGING_KID + '|' + N22_STAGING_SHA16, N22_TEST_ENV + '|' + N22_TEST_KID + '|' +
          N22_TEST_SHA16]);
      same('stg_live_ok 的 jws 与内嵌的实测 jws 一致',
        cases.filter((c: Record<string, Object>): boolean => c['name'] === 'stg_live_ok')
          .map((c: Record<string, Object>): string => c['jws'] as string), [STG_LIVE_OK_JWS]);
    });

    it('device_02_all_33_vectors_match_with_the_real_crypto_framework', 0, () => {
      const keys: ConfigSignKeys = vectorKeys();
      const es256: CryptoKitEs256 = new CryptoKitEs256();
      const failures: string[] = [];
      for (const c of vectorCases()) {
        const name: string = c['name'] as string;
        const client: Record<string, Object> = c['client'] as Record<string, Object>;
        const want: Record<string, Object> = c['expect'] as Record<string, Object>;
        const lastGood: Object | null | undefined = client['last_good_version'];
        let verdict: BridgeOriginsVerdict;
        try {
          verdict = BridgeOriginsVerifier.verify(c['jws'] as string, client['app_id'] as string, client['env'] as string,
            typeof lastGood === 'number' ? lastGood as number : null, keys, es256);
        } catch (e) {
          failures.push(name + ': threw ' + String(e));
          continue;
        }
        const got: string = describeVerdict(verdict);
        if (want['accept'] === true) {
          const origins: string = JSON.stringify(want['origins']);
          if (!verdict.isAccepted || JSON.stringify((verdict.allowlist as BridgeOriginsLastGood).origins) !== origins) {
            failures.push(name + ': want Accepted ' + origins + ', got ' + got);
          }
        } else if (verdict.isAccepted || BridgeOriginsVerifier.REASONS.indexOf(verdict.reason) < 0) {
          failures.push(name + ': want Rejected (vector reason ' + String(want['reason']) + '), got ' + got);
        }
      }
      same('33 条向量全部与 expect 一致', failures, []);
    });

    it('device_03_config_sign_keys_entries_use_the_real_sha256_prefix', 0, () => {
      const entries: string[] = vectorKeys().entries.map((e: ConfigSignKeyEntry): string =>
      e.env + '|' + e.kid + '|' + e.spkiSha256Prefix16);
      same('entries（按 env、kid 排序）', entries, [N22_STAGING_ENV + '|' + N22_STAGING_KID + '|07ba14efc5908e5c',
        N22_TEST_ENV + '|' + N22_TEST_KID + '|f3494fc5043fc593']);
    });

    it('device_04_non_p256_and_broken_spki_are_rejected_without_throwing', 0, () => {
      const es256: CryptoKitEs256 = new CryptoKitEs256();
      const parts: string[] = liveParts();
      const input: Uint8Array = asciiBytes(parts[0] + '.' + parts[1]);
      const signature: Uint8Array = b64urlDecode(parts[2]);
      same('前提：实测签名 64 字节', signature.length, 64);
      const verifyOrThrown: (spkiHex: string, data: Uint8Array) => string = (spkiHex: string, data: Uint8Array): string => {
        try {
          return String(es256.verify(bytesOfHex(spkiHex), data, signature));
        } catch (e) {
          return 'threw ' + String(e);
        }
      };
      same('对照：staging 钥验实测 jws', verifyOrThrown(N22_STAGING_SPKI_HEX, input), 'true');
      same('对照：篡改签名输入', verifyOrThrown(N22_STAGING_SPKI_HEX, asciiBytes(parts[0] + '.' + parts[1] + 'A')), 'false');
      same('对照：别的 P-256 钥（向量测试钥）', verifyOrThrown(N22_TEST_SPKI_HEX, input), 'false');
      same('P-384 公钥：导入被拒、不抛', verifyOrThrown(P384_SPKI_HEX, input), 'false');
      same('坏 SPKI（3 字节）', verifyOrThrown('010203', input), 'false');
      same('空 SPKI', verifyOrThrown('', input), 'false');
      same('截断的 P-256 SPKI', verifyOrThrown(N22_STAGING_SPKI_HEX.substring(0, 120), input), 'false');
      same('点不在曲线上的 P-256 结构', verifyOrThrown(N22_STAGING_SPKI_HEX.substring(0, 54) + '11'.repeat(64), input), 'false');
      check('P-384 SPKI 不进公钥表', !ConfigSignKeys.parse('staging:p384:' + P384_SPKI_HEX).hasKey('staging', 'p384'));
    });

    it('device_05_staging_live_jws_through_the_production_staging_key_table', 0, () => {
      // src/staging 的随包表（Debug / Staging 才编译；ohosTest 按 src/release 编译，这里按相对路径引入）。
      const keys: ConfigSignKeys = ConfigSignKeys.parse(STAGING_BUNDLED_KEYS);
      const verdict: BridgeOriginsVerdict = BridgeOriginsVerifier.verifyConfig(stagingData(STG_LIVE_OK_JWS), APP_ID,
        N22_STAGING_ENV, null, keys, new CryptoKitEs256());
      same('staging 实测 → [h5-stg]', describeVerdict(verdict), 'Accepted(version=0, origins=["' + STG_ORIGIN + '"])');
      const prod: BridgeOriginsVerdict = BridgeOriginsVerifier.verifyConfig(stagingData(STG_LIVE_OK_JWS), APP_ID, 'prod', null,
        keys, new CryptoKitEs256());
      check('同一文档在 prod 下不认：' + describeVerdict(prod), !prod.isAccepted);
      const release: BridgeOriginsVerdict = BridgeOriginsVerifier.verifyConfig(stagingData(STG_LIVE_OK_JWS), APP_ID,
        N22_STAGING_ENV, null, ConfigSignKeys.bundled(), new CryptoKitEs256());
      check('Release 随包表（ohosTest 编译的那份）不认 staging 文档：' + describeVerdict(release), !release.isAccepted);
    });
  });
}
