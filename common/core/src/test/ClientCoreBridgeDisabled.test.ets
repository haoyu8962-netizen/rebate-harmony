// F-X-24：配置解析属于 ClientCore / ConfigStore 模块，A1–A11 原样覆盖共用 vectors.md。
import { describe, it, expect } from '@ohos/hypium';
import { ConfigReply, ConfigSourceRaw } from '../main/ets/clientcore/ConfigStore';
import { DISABLED_KEY, Fx24ConfigRig } from './Fx24ConfigRig';

class ConfigCase {
  readonly name: string;
  readonly raw: string | null;
  readonly expected: string[];
  readonly warn: boolean;

  constructor(name: string, raw: string | null, expected: string[], warn: boolean = false) {
    this.name = name;
    this.raw = raw;
    this.expected = expected;
    this.warn = warn;
  }
}

export default function clientCoreBridgeDisabledTest() {
  describe('ClientCoreBridgeDisabled_FX24', () => {
    const cases: ConfigCase[] = [
      new ConfigCase('A1_missing', null, []),
      new ConfigCase('A2_empty', '[]', []),
      new ConfigCase('A3_one', '["clipboard.read"]', ['clipboard.read']),
      new ConfigCase('A4_two', '["clipboard.read","net.signedRequest"]', ['clipboard.read', 'net.signedRequest']),
      new ConfigCase('A5_unknown_is_valid', '["unknown.method"]', ['unknown.method']),
      new ConfigCase('A6_not_array', '"clipboard.read"', [], true),
      new ConfigCase('A7_non_string_item', '["clipboard.read",1]', [], true),
      new ConfigCase('A8_pattern_invalidates_whole_key', '["clipboard.read","Bad.Name"]', [], true),
      new ConfigCase('A9_duplicate_invalidates_whole_key', '["clipboard.read","clipboard.read"]', [], true),
      new ConfigCase('A10_explicit_null', 'null', [], true),
      new ConfigCase('A11_missing_dot', '["clipboardread"]', [], true)
    ];
    for (const vector of cases) {
      it(vector.name, 0, () => {
        const rig: Fx24ConfigRig = new Fx24ConfigRig();
        rig.apply(vector.raw);
        expect(rig.store.sourceRaw).assertEqual(ConfigSourceRaw.CURRENT);
        const actual: string[] = rig.methods();
        expect(actual.length).assertEqual(vector.expected.length);
        expect(JSON.stringify(actual.slice().sort())).assertEqual(JSON.stringify(vector.expected.slice().sort()));
        // 一次解析只允许一条 warn，且内容严格只有键名，不泄露原值或其中任一元素。
        expect(JSON.stringify(rig.warnings)).assertEqual(JSON.stringify(vector.warn ? [DISABLED_KEY] : []));
      });
    }

    it('L1_bundled_then_current_then_restarted_lkg_use_the_same_accessor', 0, () => {
      const rig: Fx24ConfigRig = new Fx24ConfigRig('["app.getEnv"]');
      expect(rig.store.sourceRaw).assertEqual(ConfigSourceRaw.BUNDLED);
      expect(JSON.stringify(rig.methods())).assertEqual('["app.getEnv"]');
      rig.apply('["clipboard.read"]');
      expect(JSON.stringify(rig.methods())).assertEqual('["clipboard.read"]');
      const restarted: Fx24ConfigRig = new Fx24ConfigRig('["app.getEnv"]', rig.file);
      expect(restarted.store.sourceRaw).assertEqual(ConfigSourceRaw.LKG);
      expect(JSON.stringify(restarted.methods())).assertEqual('["clipboard.read"]');
      restarted.reply(new ConfigReply(ConfigReply.FAILURE, null, null));
      expect(JSON.stringify(restarted.methods())).assertEqual('["clipboard.read"]');
    });

    it('L2_explicit_empty_overrides_lkg_and_304_or_failure_keeps_current', 0, () => {
      const rig: Fx24ConfigRig = new Fx24ConfigRig('["app.getEnv"]');
      rig.apply('["clipboard.read"]', 'v1');
      rig.apply('[]', 'v2');
      expect(JSON.stringify(rig.methods())).assertEqual('[]');
      expect(rig.store.value('dict_version')).assertEqual('"v2"');
      rig.reply(new ConfigReply(ConfigReply.NOT_MODIFIED, null, null));
      expect(JSON.stringify(rig.methods())).assertEqual('[]');
      rig.reply(new ConfigReply(ConfigReply.FAILURE, null, null));
      expect(JSON.stringify(rig.methods())).assertEqual('[]');
      expect(rig.store.value('dict_version')).assertEqual('"v2"');
      expect(rig.warnings.length).assertEqual(0);
    });

    it('L3_present_invalid_value_defaults_instead_of_reviving_an_older_list', 0, () => {
      for (const raw of ['null', '["clipboard.read","Bad.Name"]']) {
        const rig: Fx24ConfigRig = new Fx24ConfigRig('["app.getEnv"]');
        rig.apply('["clipboard.read"]', 'v1');
        rig.apply(raw, 'v2');
        expect(JSON.stringify(rig.methods())).assertEqual('[]');
        expect(JSON.stringify(rig.warnings)).assertEqual('["bridge_disabled_methods"]');
        expect(rig.store.value('dict_version')).assertEqual('"v2"');
      }
    });

    it('L4_missing_current_key_uses_existing_top_level_lkg_fallback', 0, () => {
      const rig: Fx24ConfigRig = new Fx24ConfigRig();
      rig.apply('["clipboard.read"]', 'v1');
      rig.apply(null, 'v2');
      // 和已有 ConfigStore.value 同口径：旧响应缺新增键时沿用 LKG；所有层都缺才是 A1 的 []。
      expect(rig.store.value(DISABLED_KEY)).assertEqual('["clipboard.read"]');
      expect(JSON.stringify(rig.methods())).assertEqual(rig.store.value(DISABLED_KEY));
      expect(rig.warnings.length).assertEqual(0);
    });
  });
}
