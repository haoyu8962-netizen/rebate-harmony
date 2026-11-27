// FU-HM-BRIDGE-ORIGINS-VERIFY（D10-3512 (a)）：本机只测验签之后的规则——Es256 端口是 RecordingEs256 桩（可设通过 / 不通过 / 抛错，
// 记下收到的 SPKI、签名输入、签名字节）；33 条真签名向量在 core 设备用例 BridgeOriginsDevice.test 里跑。
// 规则顺序与 reason 照向量 rules_order 与安卓 BridgeOriginsVerifier.kt:182-218；拒绝只断言「拒且 reason 是约定的 12 个之一」，
// 不钉具体码（向量说明 reason 不必逐字复现）；malformed 能区分（rules_02 断言为 malformed）。
// 每组先跑应通过的对照（同一写法只换被测字段），证明拒绝来自被测规则。JWS 全部运行时拼（D10-3512 (b)）。
import { describe, it } from '@ohos/hypium';
import { BridgeOriginsVerdict, BridgeOriginsVerifier, ConfigSignKeys } from '../../Index';
import { BundledConfig } from 'generated';
import {
  APP_ID, assertAccepted, assertRejected, b64url, b64urlText, check, dataWithJws, fakeSignature, GOOD_ORIGIN, headerJson,
  jwsOf, originsJson, payloadJson, RecordingEs256, same, synthSpkiHex, UNIT_ENV, UNIT_KID, unitKeys, verifyUnit
} from './BridgeOriginsTestSupport';

/** 坏 origin 两种形式各验一次：单项、好项 + 坏项；端口都放行。 */
function assertOriginRejected(origin: string): void {
  for (const items of [[origin], [GOOD_ORIGIN, origin]]) {
    const label: string = 'origins ' + JSON.stringify(items);
    assertRejected(label, verifyUnit(jwsOf(headerJson(), payloadJson('1', originsJson(items)))));
  }
}

/** 补 'A' 到长度 % 4 == 1（base64 长度不成立，任何解码器都解不出）。 */
function lengthMod4Is1(segment: string): string {
  let out: string = segment + 'A';
  while (out.length % 4 !== 1) {
    out += 'A';
  }
  return out;
}

function verifyConfigUnit(dataJson: string, port: RecordingEs256 = new RecordingEs256()): BridgeOriginsVerdict {
  return BridgeOriginsVerifier.verifyConfig(dataJson, APP_ID, UNIT_ENV, null, unitKeys(), port);
}

export default function bridgeOriginsRulesTest() {
  describe('BridgeOriginsRules', () => {
    it('rules_01_good_jws_is_accepted_and_the_port_gets_spki_input_and_signature', 0, () => {
      const port: RecordingEs256 = new RecordingEs256('true');
      const header: string = headerJson();
      const payload: string = payloadJson('7', originsJson([GOOD_ORIGIN, 'https://a.example:8443']));
      const signature: Uint8Array = fakeSignature(64, 0x3c);
      const jws: string = jwsOf(header, payload, signature);
      assertAccepted('对照', verifyUnit(jws, port), 7, [GOOD_ORIGIN, 'https://a.example:8443']);
      same('端口只调一次', port.calls.length, 1);
      same('端口收到的 SPKI = 表里 (test, unit-key-1) 的 DER', port.calls[0].spkiHex, synthSpkiHex('11'));
      same('签名输入 = ASCII 的原样 header.payload 两段', port.calls[0].input, b64urlText(header) + '.' + b64urlText(payload));
      same('签名字节 = 签名段解码后的 64 字节', port.calls[0].signatureHex, '3c'.repeat(64));
    });

    it('rules_02_malformed_shapes_are_rejected_as_malformed_without_calling_the_port', 0, () => {
      const good: string = jwsOf();
      const parts: string[] = good.split('.');
      const cases: string[] = [
        '',
        parts[0] + '.' + parts[1],
        good + '.' + parts[2],
        parts[0] + '..' + parts[2],
        '.' + parts[1] + '.' + parts[2],
        parts[0] + '.' + parts[1] + '.',
        good + '=',
        parts[0] + '=.' + parts[1] + '.' + parts[2],
        parts[0] + '.' + parts[1] + '+.' + parts[2],
        parts[0] + '.' + parts[1] + '.' + parts[2].substring(0, 10) + '/' + parts[2].substring(11),
        parts[0] + ' .' + parts[1] + '.' + parts[2],
        parts[0] + '.' + parts[1] + '.' + lengthMod4Is1(parts[2]),
        lengthMod4Is1(parts[0]) + '.' + parts[1] + '.' + parts[2],
        parts[0] + '.' + lengthMod4Is1(parts[1]) + '.' + parts[2],
        b64urlText('not json') + '.' + parts[1] + '.' + parts[2],
        b64urlText('["ES256"]') + '.' + parts[1] + '.' + parts[2],
        b64urlText('"ES256"') + '.' + parts[1] + '.' + parts[2]
      ];
      for (let i: number = 0; i < cases.length; i++) {
        const port: RecordingEs256 = new RecordingEs256('true');
        const verdict: BridgeOriginsVerdict = verifyUnit(cases[i], port);
        assertRejected('malformed 第 ' + i + ' 条', verdict);
        same('malformed 第 ' + i + ' 条的 reason', verdict.reason, BridgeOriginsVerifier.REASON_MALFORMED);
        same('malformed 第 ' + i + ' 条不调端口', port.calls.length, 0);
      }
    });

    it('rules_03_alg_other_than_es256_is_rejected_without_calling_the_port', 0, () => {
      assertAccepted('对照 ES256', verifyUnit(jwsOf()), 1, [GOOD_ORIGIN]);
      const headers: string[] = [headerJson('none'), headerJson('HS256'), headerJson('ES384'), headerJson('es256'),
        headerJson('RS256'), '{"kid":"' + UNIT_KID + '","typ":"couli-bridge-origins+jws"}',
        '{"alg":1,"kid":"' + UNIT_KID + '"}'];
      for (const header of headers) {
        const port: RecordingEs256 = new RecordingEs256('true');
        assertRejected('header ' + header, verifyUnit(jwsOf(header), port));
        same('header ' + header + ' 不调端口', port.calls.length, 0);
      }
    });

    it('rules_04_kid_missing_unknown_or_in_another_env_is_rejected_without_calling_the_port', 0, () => {
      const stagingOnly: ConfigSignKeys = ConfigSignKeys.parse('staging:' + UNIT_KID + ':' + synthSpkiHex('11'));
      const headers: string[] = [headerJson('ES256', 'other-kid'), headerJson('ES256', ''),
        '{"alg":"ES256","typ":"couli-bridge-origins+jws"}', '{"alg":"ES256","kid":7,"typ":"couli-bridge-origins+jws"}'];
      for (const header of headers) {
        const port: RecordingEs256 = new RecordingEs256('true');
        assertRejected('header ' + header, verifyUnit(jwsOf(header), port));
        same('header ' + header + ' 不调端口', port.calls.length, 0);
      }
      const port: RecordingEs256 = new RecordingEs256('true');
      assertRejected('kid 只在 staging 下有钥、运行环境 test',
        BridgeOriginsVerifier.verify(jwsOf(), APP_ID, UNIT_ENV, null, stagingOnly, port));
      assertRejected('空表', BridgeOriginsVerifier.verify(jwsOf(), APP_ID, UNIT_ENV, null, ConfigSignKeys.EMPTY, port));
      same('都不调端口', port.calls.length, 0);
      assertAccepted('对照：同一张表在 staging 下验 staging 的 payload',
        BridgeOriginsVerifier.verify(jwsOf(headerJson(), payloadJson('1', '["' + GOOD_ORIGIN + '"]', '1', '"' + APP_ID +
          '"', '"staging"')), APP_ID, 'staging', null, stagingOnly, port), 1, [GOOD_ORIGIN]);
    });

    it('rules_05_signature_not_64_bytes_is_rejected_without_calling_the_port', 0, () => {
      for (const length of [1, 32, 63, 65, 70, 72, 96]) {
        const port: RecordingEs256 = new RecordingEs256('true');
        assertRejected('签名 ' + length + ' 字节', verifyUnit(jwsOf(headerJson(), payloadJson(), fakeSignature(length)), port));
        same('签名 ' + length + ' 字节不调端口', port.calls.length, 0);
      }
    });

    it('rules_06_port_false_or_throwing_is_rejected', 0, () => {
      const no: RecordingEs256 = new RecordingEs256('false');
      assertRejected('端口验不过', verifyUnit(jwsOf(), no));
      same('验不过时端口调过一次', no.calls.length, 1);
      const boom: RecordingEs256 = new RecordingEs256('throw');
      assertRejected('端口抛错（不抛到调用方）', verifyUnit(jwsOf(), boom));
      same('抛错时端口调过一次', boom.calls.length, 1);
    });

    it('rules_07_typ_wrong_or_missing_is_rejected', 0, () => {
      for (const header of [headerJson('ES256', UNIT_KID, 'JWT'), headerJson('ES256', UNIT_KID, ''),
        headerJson('ES256', UNIT_KID, 'COULI-BRIDGE-ORIGINS+JWS'), '{"alg":"ES256","kid":"' + UNIT_KID + '"}']) {
        assertRejected('header ' + header, verifyUnit(jwsOf(header)));
      }
    });

    it('rules_08_v_app_id_and_env_must_match', 0, () => {
      const origins: string = '["' + GOOD_ORIGIN + '"]';
      for (const v of ['2', '0', 'true', '"1"', 'null', '[1]']) {
        assertRejected('v 为 ' + v, verifyUnit(jwsOf(headerJson(), payloadJson('1', origins, v))));
      }
      assertRejected('缺 v', verifyUnit(jwsOf(headerJson(), '{"app_id":"couli","env":"test","version":1,"origins":' + origins +
        '}')));
      for (const appId of ['"couli-other"', '"COULI"', '1', 'null']) {
        assertRejected('app_id 为 ' + appId, verifyUnit(jwsOf(headerJson(), payloadJson('1', origins, '1', appId))));
      }
      for (const env of ['"staging"', '"prod"', '"TEST"', '1']) {
        assertRejected('env 为 ' + env, verifyUnit(jwsOf(headerJson(), payloadJson('1', origins, '1', '"couli"', env))));
      }
      for (const payload of ['not json', '["' + GOOD_ORIGIN + '"]', '1', '']) {
        assertRejected('payload ' + payload, verifyUnit(jwsOf(headerJson(), payload)));
      }
    });

    it('rules_09_version_type_and_last_good_comparison', 0, () => {
      const jws: (version: string) => string = (version: string): string => jwsOf(headerJson(), payloadJson(version));
      assertAccepted('version 0、无上次可用', verifyUnit(jws('0')), 0, [GOOD_ORIGIN]);
      assertAccepted('version 5、无上次可用不比', verifyUnit(jws('5')), 5, [GOOD_ORIGIN]);
      assertAccepted('version 5 = 上次可用 5（相等通过）', verifyUnit(jws('5'), new RecordingEs256(), 5), 5, [GOOD_ORIGIN]);
      assertAccepted('version 6 > 上次可用 5', verifyUnit(jws('6'), new RecordingEs256(), 5), 6, [GOOD_ORIGIN]);
      assertRejected('version 4 < 上次可用 5（回退）', verifyUnit(jws('4'), new RecordingEs256(), 5));
      assertRejected('version 0 < 上次可用 1', verifyUnit(jws('0'), new RecordingEs256(), 1));
      for (const raw of ['-1', '"3"', 'true', 'null', '1.5', '{}', '[]']) {
        assertRejected('version 为 ' + raw, verifyUnit(jws(raw)));
      }
      assertRejected('缺 version', verifyUnit(jwsOf(headerJson(), '{"v":1,"app_id":"couli","env":"test","origins":["' +
        GOOD_ORIGIN + '"]}')));
    });

    it('rules_10_origins_must_be_a_non_empty_array_of_strings', 0, () => {
      for (const origins of ['[]', '"' + GOOD_ORIGIN + '"', 'null', '{}', '[1]', '["' + GOOD_ORIGIN + '",1]',
        '["' + GOOD_ORIGIN + '",null]', '[["' + GOOD_ORIGIN + '"]]']) {
        assertRejected('origins 为 ' + origins, verifyUnit(jwsOf(headerJson(), payloadJson('1', origins))));
      }
      assertRejected('缺 origins', verifyUnit(jwsOf(headerJson(), '{"v":1,"app_id":"couli","env":"test","version":1}')));
    });

    it('rules_11_non_canonical_origins_are_rejected', 0, () => {
      for (const origin of [
        'http://h5.example.test', 'HTTPS://h5.example.test', 'https://H5.example.test', 'https://h5.EXAMPLE.test',
        GOOD_ORIGIN + '/', GOOD_ORIGIN + '/path', GOOD_ORIGIN + '?', GOOD_ORIGIN + '?a=1', GOOD_ORIGIN + '#', GOOD_ORIGIN + '#f',
        'https://u:p@h5.example.test', 'https://u@h5.example.test', 'https://*.example.test', 'https://*',
        GOOD_ORIGIN + ':443', GOOD_ORIGIN + ':0', GOOD_ORIGIN + ':08443', GOOD_ORIGIN + ':65536', GOOD_ORIGIN + ':',
        'https://h5.example.test.', 'https://a..example', 'https://-a.example', 'https://a-.example', 'https://a_b.example',
        GOOD_ORIGIN + ' ', ' ' + GOOD_ORIGIN, GOOD_ORIGIN + '\n', 'https://[::1]', 'https://例子.测试', 'https://h5。example.test',
        '', 'https://', 'h5.example.test', '//h5.example.test', 'wss://h5.example.test'
      ]) {
        assertOriginRejected(origin);
      }
    });

    it('rules_12_canonical_origins_are_accepted_as_is_in_order', 0, () => {
      const list: string[] = [GOOD_ORIGIN, 'https://a.example:8443', 'https://xn--fsqu00a.xn--0zwm56d', 'https://0.example',
        'https://a-b.example:1', 'https://a--b.c0.example:65535', 'https://localhost'];
      for (const origin of list) {
        assertAccepted('单项 ' + origin, verifyUnit(jwsOf(headerJson(), payloadJson('1', originsJson([origin])))), 1, [origin]);
      }
      assertAccepted('多项原样、顺序不变', verifyUnit(jwsOf(headerJson(), payloadJson('1', originsJson(list)))), 1, list);
    });

    it('rules_13_rule_order_earlier_failures_never_reach_the_port', 0, () => {
      // alg 错 + kid 不在表：alg 先判；kid 不在表 + 签名长度错：不调端口；签名验不过 + typ 错 / v 错：端口调了一次、仍拒。
      const p1: RecordingEs256 = new RecordingEs256('true');
      assertRejected('alg 错 + kid 不在表', verifyUnit(jwsOf(headerJson('HS256', 'other')), p1));
      const p2: RecordingEs256 = new RecordingEs256('true');
      assertRejected('kid 不在表 + 签名 63 字节', verifyUnit(jwsOf(headerJson('ES256', 'other'), payloadJson(),
        fakeSignature(63)), p2));
      same('前两条都不调端口', p1.calls.length + p2.calls.length, 0);
      const p3: RecordingEs256 = new RecordingEs256('false');
      assertRejected('签名验不过 + typ 错 + v 错', verifyUnit(jwsOf(headerJson('ES256', UNIT_KID, 'JWT'),
        payloadJson('1', '["' + GOOD_ORIGIN + '"]', '2')), p3));
      same('验签在 typ / payload 之前', p3.calls.length, 1);
      const p4: RecordingEs256 = new RecordingEs256('true');
      assertRejected('签名通过 + typ 错（payload 全对）', verifyUnit(jwsOf(headerJson('ES256', UNIT_KID, 'JWT')), p4));
      same('typ 在验签之后判', p4.calls.length, 1);
    });

    it('rules_14_config_shapes_other_than_a_jws_string_are_malformed', 0, () => {
      const jws: string = jwsOf();
      assertAccepted('对照：data 里 bridge_origins.jws', verifyConfigUnit(dataWithJws(jws)), 1, [GOOD_ORIGIN]);
      const quoted: string = JSON.stringify(jws);
      const shapes: string[] = [
        '{"bridge_origins":["' + GOOD_ORIGIN + '"]}',
        '{"h5_base_url":"' + GOOD_ORIGIN + '/"}',
        '{"bridge_origins":{}}',
        '{"bridge_origins":{"h5":"' + GOOD_ORIGIN + '"}}',
        '{"bridge_origins":{"jws":123}}',
        '{"bridge_origins":{"jws":null}}',
        '{"bridge_origins":{"jws":true}}',
        '{"bridge_origins":{"jws":[' + quoted + ']}}',
        '{"bridge_origins":{"jws":{"v":' + quoted + '}}}',
        '{"bridge_origins":' + quoted + '}',
        '{"bridge_origins":null}',
        'not json',
        '[]',
        ''
      ];
      for (const data of shapes) {
        const port: RecordingEs256 = new RecordingEs256('true');
        const verdict: BridgeOriginsVerdict = verifyConfigUnit(data, port);
        assertRejected('data ' + data, verdict);
        same('data ' + data + ' 的 reason', verdict.reason, BridgeOriginsVerifier.REASON_MALFORMED);
        same('data ' + data + ' 不调端口', port.calls.length, 0);
      }
    });

    it('rules_15_bundled_placeholder_jws_is_rejected_in_every_env', 0, () => {
      // default_config.json:64-66 的包内占位（生成物 BundledConfig.DATA_JSON，不动）：必然验不过 → 没有服务端配置时白名单为空。
      const bundled: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
      const bridge: Record<string, Object> = bundled['bridge_origins'] as Record<string, Object>;
      check('包内带 bridge_origins.jws 占位串', typeof bridge['jws'] === 'string');
      const keys: ConfigSignKeys = ConfigSignKeys.parse('staging:' + UNIT_KID + ':' + synthSpkiHex('11') + ' test:' +
        UNIT_KID + ':' + synthSpkiHex('22') + ' prod:' + UNIT_KID + ':' + synthSpkiHex('33'));
      for (const env of ['staging', 'test', 'prod', 'local']) {
        assertRejected('包内占位 @ ' + env, BridgeOriginsVerifier.verifyConfig(BundledConfig.DATA_JSON, APP_ID, env, null, keys,
          new RecordingEs256('true')));
      }
    });

    it('rules_16_header_kid_in_is_only_for_logging', 0, () => {
      same('取 header.kid', BridgeOriginsVerifier.headerKidIn(dataWithJws(jwsOf(headerJson('ES256', 'kid-for-log')))),
        'kid-for-log');
      same('未验签也取（签名坏、kid 不在表）', BridgeOriginsVerifier.headerKidIn(dataWithJws(jwsOf(headerJson('ES256', 'x'),
        payloadJson(), fakeSignature(3)))), 'x');
      check('旧数组形状为 null', BridgeOriginsVerifier.headerKidIn('{"bridge_origins":["' + GOOD_ORIGIN + '"]}') === null);
      check('header 段坏为 null', BridgeOriginsVerifier.headerKidIn(dataWithJws('%%%.' + b64url(fakeSignature(3)) + '.x')) ===
        null);
      check('header 没有 kid 为 null', BridgeOriginsVerifier.headerKidIn(dataWithJws(jwsOf('{"alg":"ES256"}'))) === null);
    });
  });
}
