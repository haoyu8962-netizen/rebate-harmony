import { describe, it, expect } from '@ohos/hypium';
import { CustomColors } from '@kit.ArkUI';
import { resolveColorTokens, resolveShadowTokens, buildSystemColors } from '../main/ets/theme/CouliThemeMapping';
import { EXPECTED_COLORS, EXPECTED_SHADOWS, ExpectedColor } from './Ds02Expected';

// SDK Colors API 12 的完整角色表，显式访问防止“只遍历实现返回的键”假绿。
function systemValues(colors: CustomColors): (ResourceColor | undefined)[] {
  return [
    colors.brand,
    colors.warning,
    colors.alert,
    colors.confirm,
    colors.fontPrimary,
    colors.fontSecondary,
    colors.fontTertiary,
    colors.fontFourth,
    colors.fontEmphasize,
    colors.fontOnPrimary,
    colors.fontOnSecondary,
    colors.fontOnTertiary,
    colors.fontOnFourth,
    colors.iconPrimary,
    colors.iconSecondary,
    colors.iconTertiary,
    colors.iconFourth,
    colors.iconEmphasize,
    colors.iconSubEmphasize,
    colors.iconOnPrimary,
    colors.iconOnSecondary,
    colors.iconOnTertiary,
    colors.iconOnFourth,
    colors.backgroundPrimary,
    colors.backgroundSecondary,
    colors.backgroundTertiary,
    colors.backgroundFourth,
    colors.backgroundEmphasize,
    colors.compForegroundPrimary,
    colors.compBackgroundPrimary,
    colors.compBackgroundPrimaryTran,
    colors.compBackgroundPrimaryContrary,
    colors.compBackgroundGray,
    colors.compBackgroundSecondary,
    colors.compBackgroundTertiary,
    colors.compBackgroundEmphasize,
    colors.compBackgroundNeutral,
    colors.compEmphasizeSecondary,
    colors.compEmphasizeTertiary,
    colors.compDivider,
    colors.compCommonContrary,
    colors.compBackgroundFocus,
    colors.compFocusedPrimary,
    colors.compFocusedSecondary,
    colors.compFocusedTertiary,
    colors.interactiveHover,
    colors.interactivePressed,
    colors.interactiveFocus,
    colors.interactiveActive,
    colors.interactiveSelect,
    colors.interactiveClick
  ];
}

export default function ds02ThemeTest() {
  describe('Ds02Theme', () => {
    for (const dark of [false, true]) {
      it('complete_palette_matches_unique_source_' + dark, 0, () => {
        const actual: Map<string, string> = resolveColorTokens(dark);
        expect(actual.size).assertEqual(EXPECTED_COLORS.length);
        for (const row of EXPECTED_COLORS) {
          expect(actual.has(row.key)).assertTrue();
          expect(actual.get(row.key)).assertEqual(dark ? row.dark : row.light);
        }
      });
    }
    it('all_shadow_layers_follow_mode_none_falls_back', 0, () => {
      for (const dark of [false, true]) {
        const actual = resolveShadowTokens(dark);
        expect(actual.size).assertEqual(EXPECTED_SHADOWS.length);
        for (const row of EXPECTED_SHADOWS) {
          const layers = actual.get(row.key);
          expect(layers !== undefined).assertTrue();
          if (layers === undefined) { throw new Error('Missing shadow: ' + row.key); }
          const expected = dark ? row.dark : row.light;
          expect(layers.length).assertEqual(expected.length);
          for (let index: number = 0; index < expected.length; index++) {
            expect(layers[index].x).assertEqual(expected[index].x);
            expect(layers[index].y).assertEqual(expected[index].y);
            expect(layers[index].blur).assertEqual(expected[index].blur);
            expect(layers[index].spread).assertEqual(expected[index].spread);
            expect(layers[index].color).assertEqual(expected[index].color);
            expect(layers[index].opacity).assertEqual(expected[index].opacity);
          }
        }
      }
    });
    it('every_system_role_consumes_tokens_two_probes', 0, () => {
      // 探针只验证数据流，不是新的产品色值。两轮防止默认值偶合。
      for (const probe of [0xFF123456, 0xFF654321]) {
        const tokens: Map<string, ResourceColor> = new Map<string, ResourceColor>();
        for (const row of EXPECTED_COLORS) { tokens.set(row.key, probe); }
        const values: (ResourceColor | undefined)[] = systemValues(buildSystemColors(tokens));
        expect(values.length).assertEqual(51);
        for (const value of values) { expect(value).assertEqual(probe); }
      }
    });
    it('representative_system_roles_keep_semantic_keys', 0, () => {
      const tokens: Map<string, ResourceColor> = new Map<string, ResourceColor>();
      let index: number = 1;
      for (const row of EXPECTED_COLORS) { tokens.set(row.key, index++); }
      const colors: CustomColors = buildSystemColors(tokens);
      expect(colors.brand).assertEqual(tokens.get('brand.primary'));
      expect(colors.fontPrimary).assertEqual(tokens.get('text.primary'));
      expect(colors.fontSecondary).assertEqual(tokens.get('text.secondary'));
      expect(colors.backgroundPrimary).assertEqual(tokens.get('background.canvas'));
      expect(colors.compDivider).assertEqual(tokens.get('border.subtle'));
      expect(colors.interactiveFocus).assertEqual(tokens.get('focus.ring'));
    });
  });
}
