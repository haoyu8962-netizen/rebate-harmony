// FU-HM-THEME-BASE-harmony 测试作者 v1（新鲜独立 Claude，D10-823）。
// 依据：NATIVE/FU-HM-THEME-BASE/brief-harmony.md §1.2（51 个角色分组）、§2.1（preset 语义）、§3.1（用例 1–4）；裁定 D10-1153。
// 被测接口（CouliThemeMapping.ets，本文件 import 的四个名字都要 export）：
//   enum SystemNeutralPreset { TOKEN = 'token', SYSTEM = 'system' }
//   buildSystemColors(tokens: Map<string, ResourceColor>, preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN): CustomColors
//   BRAND_ROLES / NEUTRAL_ROLES：string[]（或只读数组），元素是角色名字面量，22 / 29 个。
// 下面两张「角色 → 令牌键」表抄自 eb9db90 的 buildSystemColors，是「TOKEN 模式零变化」的独立判据：实现不得让测试反过来读实现的表。
import { describe, it, expect } from '@ohos/hypium';
import { CustomColors } from '@kit.ArkUI';
import {
  BRAND_ROLES, NEUTRAL_ROLES, SystemNeutralPreset, buildSystemColors
} from '../main/ets/theme/CouliThemeMapping';
import { EXPECTED_COLORS } from './Ds02Expected';

class RoleBinding {
  role: string;
  token: string;

  constructor(role: string, token: string) {
    this.role = role;
    this.token = token;
  }
}

class RoleValue {
  role: string;
  value: ResourceColor | undefined;

  constructor(role: string, value: ResourceColor | undefined) {
    this.role = role;
    this.value = value;
  }
}

// 甲组：品牌与状态（22），两套都取令牌。
const BRAND_BINDINGS: RoleBinding[] = [
  new RoleBinding('brand', 'brand.primary'),
  new RoleBinding('iconEmphasize', 'brand.primary'),
  new RoleBinding('backgroundEmphasize', 'brand.primary'),
  new RoleBinding('fontEmphasize', 'text.link'),
  new RoleBinding('iconSubEmphasize', 'brand.emphasis'),
  new RoleBinding('compBackgroundEmphasize', 'control.checked'),
  new RoleBinding('compEmphasizeSecondary', 'brand.subtle'),
  new RoleBinding('interactiveSelect', 'brand.subtle'),
  new RoleBinding('compEmphasizeTertiary', 'rebate.background'),
  new RoleBinding('interactiveActive', 'button.primary.pressed.background'),
  new RoleBinding('interactiveFocus', 'focus.ring'),
  new RoleBinding('warning', 'status.warning.text'),
  new RoleBinding('alert', 'status.error.text'),
  new RoleBinding('confirm', 'status.success.text'),
  new RoleBinding('fontOnPrimary', 'text.inverse'),
  new RoleBinding('fontOnSecondary', 'button.primary.default.text'),
  new RoleBinding('fontOnTertiary', 'rebate.solid.text'),
  new RoleBinding('fontOnFourth', 'button.primary.pressed.text'),
  new RoleBinding('iconOnPrimary', 'text.inverse'),
  new RoleBinding('iconOnSecondary', 'button.primary.default.text'),
  new RoleBinding('iconOnTertiary', 'rebate.solid.text'),
  new RoleBinding('iconOnFourth', 'button.primary.pressed.text')
];

// 乙组：中性与材质（29），方案 A 取令牌，方案 B（SYSTEM）不给、走系统默认。
const NEUTRAL_BINDINGS: RoleBinding[] = [
  new RoleBinding('fontPrimary', 'text.primary'),
  new RoleBinding('iconPrimary', 'text.primary'),
  new RoleBinding('fontSecondary', 'text.secondary'),
  new RoleBinding('iconSecondary', 'text.secondary'),
  new RoleBinding('fontTertiary', 'source.text'),
  new RoleBinding('fontFourth', 'border.control'),
  new RoleBinding('iconTertiary', 'border.control'),
  new RoleBinding('iconFourth', 'border.subtle'),
  new RoleBinding('backgroundPrimary', 'background.canvas'),
  new RoleBinding('backgroundSecondary', 'background.surface'),
  new RoleBinding('compBackgroundPrimary', 'background.surface'),
  new RoleBinding('compBackgroundFocus', 'background.surface'),
  new RoleBinding('backgroundTertiary', 'background.muted'),
  new RoleBinding('compBackgroundGray', 'background.muted'),
  new RoleBinding('backgroundFourth', 'background.placeholder'),
  new RoleBinding('compBackgroundTertiary', 'background.placeholder'),
  new RoleBinding('compBackgroundSecondary', 'status.pending.background'),
  new RoleBinding('compForegroundPrimary', 'text.primary'),
  new RoleBinding('compBackgroundNeutral', 'text.primary'),
  new RoleBinding('compFocusedPrimary', 'text.primary'),
  new RoleBinding('compBackgroundPrimaryTran', 'source.background'),
  new RoleBinding('compBackgroundPrimaryContrary', 'border.active'),
  new RoleBinding('compDivider', 'border.subtle'),
  new RoleBinding('compFocusedTertiary', 'source.border'),
  new RoleBinding('compCommonContrary', 'text.inverse'),
  new RoleBinding('compFocusedSecondary', 'text.secondary'),
  new RoleBinding('interactiveHover', 'background.muted'),
  new RoleBinding('interactivePressed', 'button.primary.disabled.background'),
  new RoleBinding('interactiveClick', 'background.placeholder')
];

// SDK Colors 的 51 个角色逐个显式读，防止「只遍历实现返回的键」假绿（同 Ds02Theme.systemValues）。
function roleValues(colors: CustomColors): RoleValue[] {
  return [
    new RoleValue('brand', colors.brand),
    new RoleValue('warning', colors.warning),
    new RoleValue('alert', colors.alert),
    new RoleValue('confirm', colors.confirm),
    new RoleValue('fontPrimary', colors.fontPrimary),
    new RoleValue('fontSecondary', colors.fontSecondary),
    new RoleValue('fontTertiary', colors.fontTertiary),
    new RoleValue('fontFourth', colors.fontFourth),
    new RoleValue('fontEmphasize', colors.fontEmphasize),
    new RoleValue('fontOnPrimary', colors.fontOnPrimary),
    new RoleValue('fontOnSecondary', colors.fontOnSecondary),
    new RoleValue('fontOnTertiary', colors.fontOnTertiary),
    new RoleValue('fontOnFourth', colors.fontOnFourth),
    new RoleValue('iconPrimary', colors.iconPrimary),
    new RoleValue('iconSecondary', colors.iconSecondary),
    new RoleValue('iconTertiary', colors.iconTertiary),
    new RoleValue('iconFourth', colors.iconFourth),
    new RoleValue('iconEmphasize', colors.iconEmphasize),
    new RoleValue('iconSubEmphasize', colors.iconSubEmphasize),
    new RoleValue('iconOnPrimary', colors.iconOnPrimary),
    new RoleValue('iconOnSecondary', colors.iconOnSecondary),
    new RoleValue('iconOnTertiary', colors.iconOnTertiary),
    new RoleValue('iconOnFourth', colors.iconOnFourth),
    new RoleValue('backgroundPrimary', colors.backgroundPrimary),
    new RoleValue('backgroundSecondary', colors.backgroundSecondary),
    new RoleValue('backgroundTertiary', colors.backgroundTertiary),
    new RoleValue('backgroundFourth', colors.backgroundFourth),
    new RoleValue('backgroundEmphasize', colors.backgroundEmphasize),
    new RoleValue('compForegroundPrimary', colors.compForegroundPrimary),
    new RoleValue('compBackgroundPrimary', colors.compBackgroundPrimary),
    new RoleValue('compBackgroundPrimaryTran', colors.compBackgroundPrimaryTran),
    new RoleValue('compBackgroundPrimaryContrary', colors.compBackgroundPrimaryContrary),
    new RoleValue('compBackgroundGray', colors.compBackgroundGray),
    new RoleValue('compBackgroundSecondary', colors.compBackgroundSecondary),
    new RoleValue('compBackgroundTertiary', colors.compBackgroundTertiary),
    new RoleValue('compBackgroundEmphasize', colors.compBackgroundEmphasize),
    new RoleValue('compBackgroundNeutral', colors.compBackgroundNeutral),
    new RoleValue('compEmphasizeSecondary', colors.compEmphasizeSecondary),
    new RoleValue('compEmphasizeTertiary', colors.compEmphasizeTertiary),
    new RoleValue('compDivider', colors.compDivider),
    new RoleValue('compCommonContrary', colors.compCommonContrary),
    new RoleValue('compBackgroundFocus', colors.compBackgroundFocus),
    new RoleValue('compFocusedPrimary', colors.compFocusedPrimary),
    new RoleValue('compFocusedSecondary', colors.compFocusedSecondary),
    new RoleValue('compFocusedTertiary', colors.compFocusedTertiary),
    new RoleValue('interactiveHover', colors.interactiveHover),
    new RoleValue('interactivePressed', colors.interactivePressed),
    new RoleValue('interactiveFocus', colors.interactiveFocus),
    new RoleValue('interactiveActive', colors.interactiveActive),
    new RoleValue('interactiveSelect', colors.interactiveSelect),
    new RoleValue('interactiveClick', colors.interactiveClick)
  ];
}

// 每个令牌一个不同的探针值：错连到别的令牌也能被发现（Ds02Theme 的同值探针发现不了）。
function probeTokens(base: number): Map<string, ResourceColor> {
  const tokens: Map<string, ResourceColor> = new Map<string, ResourceColor>();
  let index: number = 0;
  for (const row of EXPECTED_COLORS) {
    tokens.set(row.key, base + index);
    index++;
  }
  return tokens;
}

// 断言文字里带角色名，红的时候一眼知道是哪个角色。
function shown(role: string, value: ResourceColor | undefined): string {
  return role + '=' + String(value);
}

function bindingFor(role: string): RoleBinding | undefined {
  for (const row of BRAND_BINDINGS) {
    if (row.role === role) {
      return row;
    }
  }
  for (const row of NEUTRAL_BINDINGS) {
    if (row.role === role) {
      return row;
    }
  }
  return undefined;
}

function assertFullTokenMapping(colors: CustomColors, tokens: Map<string, ResourceColor>): void {
  const rows: RoleValue[] = roleValues(colors);
  expect(rows.length).assertEqual(51);
  for (const row of rows) {
    const binding: RoleBinding | undefined = bindingFor(row.role);
    expect(binding !== undefined).assertTrue();
    if (binding !== undefined) {
      expect(shown(row.role, row.value)).assertEqual(shown(row.role, tokens.get(binding.token)));
    }
  }
  expect(Object.keys(colors).length).assertEqual(51);
}

function sortedRoles(rows: RoleBinding[]): string[] {
  return rows.map((row: RoleBinding): string => row.role).sort();
}

function sortedCopy(names: ReadonlyArray<string>): string[] {
  const copy: string[] = [];
  for (const name of names) {
    copy.push(name);
  }
  return copy.sort();
}

export default function themeBaseTest() {
  describe('ThemeBase', () => {
    it('preset_values_are_the_launch_parameter_values', 0, () => {
      // staging 启动参数 couli_debug_theme_neutral 的取值就是这两个串（§2.2）。
      expect(SystemNeutralPreset.TOKEN as string).assertEqual('token');
      expect(SystemNeutralPreset.SYSTEM as string).assertEqual('system');
    });

    it('token_mode_and_default_match_current_mapping_two_probes', 0, () => {
      expect(BRAND_BINDINGS.length).assertEqual(22);
      expect(NEUTRAL_BINDINGS.length).assertEqual(29);
      for (const base of [0xFF100000, 0xFF200000]) {
        const tokens: Map<string, ResourceColor> = probeTokens(base);
        assertFullTokenMapping(buildSystemColors(tokens), tokens);
        assertFullTokenMapping(buildSystemColors(tokens, SystemNeutralPreset.TOKEN), tokens);
      }
    });

    it('system_mode_keeps_brand_tokens_and_leaves_neutral_undefined_two_probes', 0, () => {
      for (const base of [0xFF300000, 0xFF400000]) {
        const tokens: Map<string, ResourceColor> = probeTokens(base);
        const colors: CustomColors = buildSystemColors(tokens, SystemNeutralPreset.SYSTEM);
        const brand: string[] = sortedRoles(BRAND_BINDINGS);
        const values: RoleValue[] = roleValues(colors);
        expect(values.length).assertEqual(51);
        for (const row of values) {
          const binding: RoleBinding | undefined = bindingFor(row.role);
          expect(binding !== undefined).assertTrue();
          if (binding === undefined) {
            continue;
          }
          // 中性角色必须是 undefined：不许落成默认色 0、空串或别的令牌，否则系统默认接不上。
          const expected: ResourceColor | undefined = brand.includes(row.role) ? tokens.get(binding.token) : undefined;
          expect(shown(row.role, row.value)).assertEqual(shown(row.role, expected));
          if (!brand.includes(row.role)) {
            expect(row.value).assertUndefined();
          }
        }
      }
    });

    it('system_mode_omits_neutral_keys_entirely', 0, () => {
      // 「不给」= 键不存在。显式写 undefined 的键仍在对象上，能否接上系统默认取决于 ArkUI 的合并方式，SDK 里看不到实现，不赌这一点。
      const colors: CustomColors = buildSystemColors(probeTokens(0xFF500000), SystemNeutralPreset.SYSTEM);
      expect(Object.keys(colors).sort().join(',')).assertEqual(sortedRoles(BRAND_BINDINGS).join(','));
    });

    it('role_tables_partition_the_51_system_roles', 0, () => {
      expect(BRAND_ROLES.length).assertEqual(22);
      expect(NEUTRAL_ROLES.length).assertEqual(29);
      const brand: string[] = sortedCopy(BRAND_ROLES);
      const neutral: string[] = sortedCopy(NEUTRAL_ROLES);
      // 与本文件的分组逐项相同（品牌角色误入中性表、或反过来，都在这里红）。
      expect(brand.join(',')).assertEqual(sortedRoles(BRAND_BINDINGS).join(','));
      expect(neutral.join(',')).assertEqual(sortedRoles(NEUTRAL_BINDINGS).join(','));
      // 不相交、并集恰好 51 个（宿主检查 C4 再对 tools/ci/ds02/fixtures/system-color-roles.json）。
      const union: Set<string> = new Set<string>();
      for (const name of brand) {
        union.add(name);
      }
      for (const name of neutral) {
        expect(union.has(name)).assertFalse();
        union.add(name);
      }
      expect(union.size).assertEqual(51);
      const declared: string[] = roleValues({}).map((row: RoleValue): string => row.role).sort();
      expect(Array.from(union).sort().join(',')).assertEqual(declared.join(','));
    });

    it('role_tables_agree_with_what_each_preset_returns', 0, () => {
      // 防止表只是摆设：SYSTEM 实际返回的键集合 = BRAND_ROLES，TOKEN 比 SYSTEM 多出来的 = NEUTRAL_ROLES。
      const tokens: Map<string, ResourceColor> = probeTokens(0xFF600000);
      const system: string[] = Object.keys(buildSystemColors(tokens, SystemNeutralPreset.SYSTEM)).sort();
      const full: string[] = Object.keys(buildSystemColors(tokens, SystemNeutralPreset.TOKEN)).sort();
      expect(system.join(',')).assertEqual(sortedCopy(BRAND_ROLES).join(','));
      expect(full.filter((name: string): boolean => !system.includes(name)).join(','))
        .assertEqual(sortedCopy(NEUTRAL_ROLES).join(','));
    });

    it('unknown_preset_falls_back_to_token_without_throwing', 0, () => {
      const tokens: Map<string, ResourceColor> = probeTokens(0xFF700000);
      for (const raw of ['bogus', '', 'SYSTEM', 'TOKEN', ' system', 'system ']) {
        assertFullTokenMapping(buildSystemColors(tokens, raw as SystemNeutralPreset), tokens);
      }
      assertFullTokenMapping(buildSystemColors(tokens, undefined), tokens);
    });

    it('missing_brand_token_still_throws_in_both_presets', 0, () => {
      // 现行 pick() 的语义：缺令牌立即抛错。SYSTEM 只是不给中性角色，品牌角色缺令牌不能悄悄变成系统默认。品牌组用到的令牌逐个删。
      const brandTokens: Set<string> = new Set<string>();
      for (const row of BRAND_BINDINGS) {
        brandTokens.add(row.token);
      }
      for (const preset of [SystemNeutralPreset.TOKEN, SystemNeutralPreset.SYSTEM]) {
        brandTokens.forEach((token: string) => {
          const tokens: Map<string, ResourceColor> = probeTokens(0xFF800000);
          tokens.delete(token);
          let message: string = '';
          try {
            buildSystemColors(tokens, preset);
          } catch (e) {
            message = (e as Error).message;
          }
          expect(message).assertEqual('missing color token for system theme: ' + token);
        });
      }
    });
  });
}
