import { CustomColors } from '@kit.ArkUI';
import { CouliThemeTokens, ThemeColorToken, ThemeShadowLayer, ThemeShadowToken } from './CouliThemeTokens';

export { ThemeShadowLayer } from './CouliThemeTokens';

/**
 * DS-02 主题映射（纯逻辑：不引用资源、不依赖 Context，本机单测直接导入本文件，F-HM-57）。
 * 取值全部来自 CouliThemeTokens（令牌 v0.4.0 生成物）；页面不直接用这里的字符串，而用 CouliColors（资源限定词 base / dark）。
 */

/** 颜色令牌：键去掉 `color.`，值为鸿蒙 #RRGGBB / #AARRGGBB（八位已换位）。dark=true 取深色。 */
export function resolveColorTokens(dark: boolean = false): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  CouliThemeTokens.colors.forEach((token: ThemeColorToken) => {
    map.set(token.key, dark ? token.dark : token.light);
  });
  return map;
}

/** 阴影令牌：每层 x / y / blur / spread / color / opacity；none 为空数组。dark=true 取深色。 */
export function resolveShadowTokens(dark: boolean = false): Map<string, ThemeShadowLayer[]> {
  const map: Map<string, ThemeShadowLayer[]> = new Map<string, ThemeShadowLayer[]>();
  CouliThemeTokens.shadows.forEach((token: ThemeShadowToken) => {
    map.set(token.key, dark ? token.dark : token.light);
  });
  return map;
}

function pick(tokens: Map<string, ResourceColor>, key: string): ResourceColor {
  const value: ResourceColor | undefined = tokens.get(key);
  if (value === undefined) {
    throw new Error('missing color token for system theme: ' + key);
  }
  return value;
}

/**
 * 系统组件主题（ThemeControl.setDefaultTheme）：SDK Colors 的 51 个角色全部显式按令牌映射，不留鸿蒙默认色。
 * 传入资源（CouliColors.tokenResources()）时系统按 base / dark 限定词自动换深色；单测传探针值检验数据流。
 * 角色语义按 @ohos.arkui.theme 的说明对到最近的令牌：文字四级 → 主 / 次 / 控件边界 / 弱分隔；底色四级 → 页面 / 卡片 / 分组 / 占位；
 * 强调 → 狸橙；聚焦 → focus.ring；分隔 → border.subtle；在强调色上的文字 / 图标 → text.inverse。
 */
export function buildSystemColors(tokens: Map<string, ResourceColor>): CustomColors {
  const colors: CustomColors = {
    brand: pick(tokens, 'brand.primary'),
    warning: pick(tokens, 'status.warning.text'),
    alert: pick(tokens, 'status.error.text'),
    confirm: pick(tokens, 'status.success.text'),
    fontPrimary: pick(tokens, 'text.primary'),
    fontSecondary: pick(tokens, 'text.secondary'),
    fontTertiary: pick(tokens, 'source.text'),
    fontFourth: pick(tokens, 'border.control'),
    fontEmphasize: pick(tokens, 'text.link'),
    fontOnPrimary: pick(tokens, 'text.inverse'),
    fontOnSecondary: pick(tokens, 'button.primary.default.text'),
    fontOnTertiary: pick(tokens, 'rebate.solid.text'),
    fontOnFourth: pick(tokens, 'button.primary.pressed.text'),
    iconPrimary: pick(tokens, 'text.primary'),
    iconSecondary: pick(tokens, 'text.secondary'),
    iconTertiary: pick(tokens, 'border.control'),
    iconFourth: pick(tokens, 'border.subtle'),
    iconEmphasize: pick(tokens, 'brand.primary'),
    iconSubEmphasize: pick(tokens, 'brand.emphasis'),
    iconOnPrimary: pick(tokens, 'text.inverse'),
    iconOnSecondary: pick(tokens, 'button.primary.default.text'),
    iconOnTertiary: pick(tokens, 'rebate.solid.text'),
    iconOnFourth: pick(tokens, 'button.primary.pressed.text'),
    backgroundPrimary: pick(tokens, 'background.canvas'),
    backgroundSecondary: pick(tokens, 'background.surface'),
    backgroundTertiary: pick(tokens, 'background.muted'),
    backgroundFourth: pick(tokens, 'background.placeholder'),
    backgroundEmphasize: pick(tokens, 'brand.primary'),
    compForegroundPrimary: pick(tokens, 'text.primary'),
    compBackgroundPrimary: pick(tokens, 'background.surface'),
    compBackgroundPrimaryTran: pick(tokens, 'source.background'),
    compBackgroundPrimaryContrary: pick(tokens, 'border.active'),
    compBackgroundGray: pick(tokens, 'background.muted'),
    compBackgroundSecondary: pick(tokens, 'status.pending.background'),
    compBackgroundTertiary: pick(tokens, 'background.placeholder'),
    compBackgroundEmphasize: pick(tokens, 'control.checked'),
    compBackgroundNeutral: pick(tokens, 'text.primary'),
    compEmphasizeSecondary: pick(tokens, 'brand.subtle'),
    compEmphasizeTertiary: pick(tokens, 'rebate.background'),
    compDivider: pick(tokens, 'border.subtle'),
    compCommonContrary: pick(tokens, 'text.inverse'),
    compBackgroundFocus: pick(tokens, 'background.surface'),
    compFocusedPrimary: pick(tokens, 'text.primary'),
    compFocusedSecondary: pick(tokens, 'text.secondary'),
    compFocusedTertiary: pick(tokens, 'source.border'),
    interactiveHover: pick(tokens, 'background.muted'),
    interactivePressed: pick(tokens, 'button.primary.disabled.background'),
    interactiveFocus: pick(tokens, 'focus.ring'),
    interactiveActive: pick(tokens, 'button.primary.pressed.background'),
    interactiveSelect: pick(tokens, 'brand.subtle'),
    interactiveClick: pick(tokens, 'background.placeholder')
  };
  return colors;
}
