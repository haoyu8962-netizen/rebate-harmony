// FU-HM-BRIDGE-ORIGINS-VERIFY（D10-3507 / D10-3512）：随包公钥表 ConfigSignKeys 的解析与 release / staging 两份随包表。
// 照安卓 BridgeOriginsVerifierSupplementTest 的公钥表用例与 N22BridgeOriginsBuildKeysTest；鸿蒙的 P-256 判定只做 SPKI 结构判定
// （cryptoFramework 在 Local Test 是空实现），sha16 用纯 ArkTS 的 Sha256，所以本机可测；真 staging 钥的 sha16 另在 core 设备用例。
// keys_06 = D10-3512 (e)「release 公钥表不含非 prod kid」：本机单测按 default target 编译，随包表按相对路径分别引入两份。
import { describe, it } from '@ohos/hypium';
import { ConfigSignKeyEntry, ConfigSignKeys } from '../../Index';
import { CONFIG_SIGN_KEYS_BUNDLED as RELEASE_KEYS } from '../release/ets/config/ConfigSignKeysBundled';
import { CONFIG_SIGN_KEYS_BUNDLED as STAGING_KEYS } from '../staging/ets/config/ConfigSignKeysBundled';
import {
  bytesOfHex, check, hexOf, P384_SPKI_PREFIX_HEX, repeatHex, same, synthSpkiHex, SYNTH_11_SHA16, SYNTH_22_SHA16,
  SYNTH_33_SHA16
} from './BridgeOriginsTestSupport';

const STAGING_ENV: string = 'staging';
const STAGING_KID: string = 'config-staging-2026-11b';
const STAGING_SHA16: string = '07ba14efc5908e5c';

function entriesText(keys: ConfigSignKeys): string[] {
  return keys.entries.map((e: ConfigSignKeyEntry): string => e.env + '|' + e.kid + '|' + e.spkiSha256Prefix16);
}

export default function bridgeOriginsKeysTest() {
  describe('BridgeOriginsKeys', () => {
    it('keys_01_parse_good_items_gives_sorted_entries_with_sha16', 0, () => {
      const keys: ConfigSignKeys = ConfigSignKeys.parse('test:unit-b:' + synthSpkiHex('22') + ' staging:unit-a:' +
        synthSpkiHex('11') + ',test:unit-a:' + synthSpkiHex('33').toUpperCase());
      same('按 env、kid 排序，sha16 为 SPKI DER sha256 前 16 位（十六进制大小写都认）', entriesText(keys),
        ['staging|unit-a|' + SYNTH_11_SHA16, 'test|unit-a|' + SYNTH_33_SHA16, 'test|unit-b|' + SYNTH_22_SHA16]);
      check('hasKey staging/unit-a', keys.hasKey('staging', 'unit-a'));
      check('hasKey test/unit-b', keys.hasKey('test', 'unit-b'));
      check('kid 只在它的 env 下有效', !keys.hasKey('prod', 'unit-a') && !keys.hasKey('staging', 'unit-b'));
      same('publicKey 给回 SPKI DER', hexOf(keys.publicKey('test', 'unit-b') ?? new Uint8Array(0)), synthSpkiHex('22'));
      check('没有的 (env, kid) 为 null', keys.publicKey('prod', 'unit-a') === null);
    });

    it('keys_02_parse_skips_bad_items_and_keeps_good_ones', 0, () => {
      const good: string = synthSpkiHex('11');
      const bad: string[] = [
        'test:only-two-segments',
        'test:four:segments:' + good,
        'test:not-hex:zz' + good.substring(2),
        'test:odd-hex:' + good.substring(1),
        'test:truncated:' + good.substring(0, good.length - 8),
        'test:too-long:' + good + '00',
        'test:p384:' + P384_SPKI_PREFIX_HEX + repeatHex('44', 96),
        'test:compressed:' + good.substring(0, 52) + '02' + good.substring(54),
        'test:empty-hex:',
        ':empty-env:' + good,
        'test::' + good
      ];
      const spec: string = ' , ' + bad.join(' ,\n\t') + ' ,\n test:good:' + good + ' , ';
      const keys: ConfigSignKeys = ConfigSignKeys.parse(spec);
      same('只留好项', entriesText(keys), ['test|good|' + SYNTH_11_SHA16]);
      for (const kid of ['only-two-segments', 'four', 'not-hex', 'odd-hex', 'truncated', 'too-long', 'p384', 'compressed',
        'empty-hex', '']) {
        check('坏项不进表：' + kid, !keys.hasKey('test', kid));
      }
      check('env 为空的坏项不进表', !keys.hasKey('', 'empty-env'));
      same('空串', entriesText(ConfigSignKeys.parse('')), []);
      same('只有分隔符', entriesText(ConfigSignKeys.parse(' ,\n, \t')), []);
    });

    it('keys_03_same_env_kid_later_item_overrides_earlier', 0, () => {
      const keys: ConfigSignKeys = ConfigSignKeys.parse('test:rotating:' + synthSpkiHex('11') + ' test:other:' +
        synthSpkiHex('33') + ' test:rotating:' + synthSpkiHex('22'));
      same('同一 (env, kid) 只一项、取后者', entriesText(keys),
        ['test|other|' + SYNTH_33_SHA16, 'test|rotating|' + SYNTH_22_SHA16]);
      same('publicKey 也是后者', hexOf(keys.publicKey('test', 'rotating') ?? new Uint8Array(0)), synthSpkiHex('22'));
    });

    it('keys_04_empty_table_has_no_key', 0, () => {
      same('EMPTY 没有任何一把', entriesText(ConfigSignKeys.EMPTY), []);
      check('EMPTY.hasKey', !ConfigSignKeys.EMPTY.hasKey(STAGING_ENV, STAGING_KID));
      check('EMPTY.publicKey', ConfigSignKeys.EMPTY.publicKey(STAGING_ENV, STAGING_KID) === null);
    });

    it('keys_05_public_key_is_a_copy', 0, () => {
      const keys: ConfigSignKeys = ConfigSignKeys.parse('test:copy:' + synthSpkiHex('11'));
      const first: Uint8Array = keys.publicKey('test', 'copy') ?? new Uint8Array(0);
      same('先拿到原值', hexOf(first), synthSpkiHex('11'));
      first.fill(0);
      same('改调用方手里的字节不影响表', hexOf(keys.publicKey('test', 'copy') ?? new Uint8Array(0)), synthSpkiHex('11'));
      same('改后 sha16 不变', entriesText(keys), ['test|copy|' + SYNTH_11_SHA16]);
      same('bytesOfHex 自检', hexOf(bytesOfHex('00ff10')), '00ff10');
    });

    it('keys_06_release_bundled_table_has_no_non_prod_kid', 0, () => {
      // D10-3512 (e)：release 表（common/core/src/release/ets/config/ConfigSignKeysBundled.ets）不含 staging / test / local 项，
      // 不含 staging 钥与向量测试钥的 kid。逐字查导出的表串，再按解析结果查 env。
      for (const marker of ['staging:', 'test:', 'local:', 'config-staging', 'n22-vector-test-key']) {
        check('release 表不得出现 ' + marker, RELEASE_KEYS.indexOf(marker) < 0);
      }
      for (const entry of ConfigSignKeys.parse(RELEASE_KEYS).entries) {
        check('release 表只许 prod 项：' + entry.env + ':' + entry.kid, entry.env === 'prod');
      }
    });

    it('keys_07_staging_bundled_table_has_the_staging_key_and_no_test_key', 0, () => {
      // scope.md P6：staging 表 = staging 钥（kid config-staging-2026-11b，sha16 07ba14efc5908e5c）+ prod 钥（现为空）；
      // 向量测试钥只在测试里注入。
      const keys: ConfigSignKeys = ConfigSignKeys.parse(STAGING_KEYS);
      check('staging 表有 staging 钥', keys.hasKey(STAGING_ENV, STAGING_KID));
      same('staging 表的项', entriesText(keys).filter((t: string): boolean => !t.startsWith('prod|')),
        [STAGING_ENV + '|' + STAGING_KID + '|' + STAGING_SHA16]);
      check('staging 表不含向量测试钥', STAGING_KEYS.indexOf('n22-vector-test-key') < 0 && !keys.hasKey('test',
        'n22-vector-test-key-1'));
      for (const entry of keys.entries) {
        check('staging 表只有 staging / prod 项：' + entry.env, entry.env === 'staging' || entry.env === 'prod');
      }
    });
  });
}
