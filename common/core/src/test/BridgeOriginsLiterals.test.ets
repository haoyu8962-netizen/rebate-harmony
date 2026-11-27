// FU-HM-BRIDGE-ORIGINS-VERIFY D10-3512 (c)：payload `v` 只认字面量 `1`；`version` 只认非负十进制整数字面量且 ≤ 9007199254740991
// （Number.MAX_SAFE_INTEGER；ArkTS JSON.parse 对 2^53 与 2^53+1 得同一值，所以 2^53 本身也拒）。实现要对 payload 原文做最小词法取
// 顶层 `v` / `version` 字面量，这里按原文写法造 payload（参照安卓 BridgeOriginsN22R1Test.kt:68-78）。端口是桩、一律放行。
import { describe, it } from '@ohos/hypium';
import {
  APP_ID, assertAccepted, assertRejected, GOOD_ORIGIN, headerJson, jwsOf, payloadJson, RecordingEs256, verifyUnit
} from './BridgeOriginsTestSupport';

const ORIGINS: string = '["' + GOOD_ORIGIN + '"]';

function withVersion(raw: string): string {
  return jwsOf(headerJson(), payloadJson(raw));
}

function withV(raw: string): string {
  return jwsOf(headerJson(), payloadJson('1', ORIGINS, raw));
}

export default function bridgeOriginsLiteralsTest() {
  describe('BridgeOriginsLiterals', () => {
    it('literal_01_v_must_be_exactly_the_integer_literal_1', 0, () => {
      assertAccepted('对照 v 为 1', verifyUnit(withV('1')), 1, [GOOD_ORIGIN]);
      for (const raw of ['1.0', '1e0', '1E0', '1.00', '10e-1', '1e+0', '0.1e1', '"1"', 'true']) {
        assertRejected('v 为 ' + raw, verifyUnit(withV(raw)));
      }
    });

    it('literal_02_version_must_be_a_non_negative_decimal_integer_literal', 0, () => {
      assertAccepted('对照 version 3', verifyUnit(withVersion('3')), 3, [GOOD_ORIGIN]);
      assertAccepted('对照 version 0', verifyUnit(withVersion('0')), 0, [GOOD_ORIGIN]);
      for (const raw of ['1.0', '3.0', '3e0', '3E0', '3e+0', '0.3e1', '0.0', '-0.0', '-1', '-3', '"1"', '"3"']) {
        assertRejected('version 为 ' + raw, verifyUnit(withVersion(raw)));
      }
    });

    it('literal_03_version_boundary_is_max_safe_integer', 0, () => {
      assertAccepted('9007199254740991（MAX_SAFE_INTEGER）通过', verifyUnit(withVersion('9007199254740991')),
        9007199254740991, [GOOD_ORIGIN]);
      assertAccepted('9007199254740991 = 上次可用（相等通过）',
        verifyUnit(withVersion('9007199254740991'), new RecordingEs256(), 9007199254740991), 9007199254740991, [GOOD_ORIGIN]);
      assertAccepted('9007199254740990 通过', verifyUnit(withVersion('9007199254740990')), 9007199254740990, [GOOD_ORIGIN]);
      for (const raw of ['9007199254740992', '9007199254740993', '18014398509481984', '9223372036854775807',
        '9223372036854775808', '99999999999999999999']) {
        assertRejected('version 为 ' + raw, verifyUnit(withVersion(raw)));
      }
      assertRejected('9007199254740990 < 上次可用 9007199254740991',
        verifyUnit(withVersion('9007199254740990'), new RecordingEs256(), 9007199254740991));
    });

    it('literal_04_lexing_takes_the_top_level_literals_whatever_the_layout', 0, () => {
      // 键序、冒号两侧空白、换行都不影响；只看顶层的 v / version，不看嵌套对象或字符串里的同名片段。
      const spaced: string = '{\n  "origins" : ["' + GOOD_ORIGIN + '"] ,\n  "version" :\t42 ,\n  "env":"test", "app_id":"' +
        APP_ID + '",\n  "v"  :  1\n}';
      assertAccepted('换序与空白', verifyUnit(jwsOf(headerJson(), spaced)), 42, [GOOD_ORIGIN]);
      const nested: string = '{"meta":{"v":1.0,"version":1.5},"note":"\\"version\\":1.0","v":1,"app_id":"' + APP_ID +
        '","env":"test","version":8,"origins":' + ORIGINS + '}';
      assertAccepted('嵌套对象与字符串里的同名片段不算', verifyUnit(jwsOf(headerJson(), nested)), 8, [GOOD_ORIGIN]);
      const nestedBadTop: string = '{"meta":{"v":1,"version":8},"v":1.0,"app_id":"' + APP_ID + '","env":"test","version":8,' +
        '"origins":' + ORIGINS + '}';
      assertRejected('顶层 v 为 1.0、嵌套里是 1', verifyUnit(jwsOf(headerJson(), nestedBadTop)));
      const nestedBadVersion: string = '{"meta":{"version":8},"v":1,"app_id":"' + APP_ID + '","env":"test",' +
        '"version":8.0,"origins":' + ORIGINS + '}';
      assertRejected('顶层 version 为 8.0、嵌套里是 8', verifyUnit(jwsOf(headerJson(), nestedBadVersion)));
    });
  });
}
