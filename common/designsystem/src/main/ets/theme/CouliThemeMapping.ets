import { CustomColors } from '@kit.ArkUI';
import { CouliThemeTokens, ThemeColorToken, ThemeShadowLayer, ThemeShadowToken } from './CouliThemeTokens';

export { ThemeShadowLayer } from './CouliThemeTokens';

/**
 * DS-02 主题映射（纯逻辑：不引用资源、不依赖 Context，本机单测直接导入本文件，F-HM-57）。
 * 取值全部来自 CouliThemeTokens（锁定快照的生成物，与 generated/DesignTokens 同源）；页面不直接用这里的字符串，而用 CouliColors（资源限定词 base / dark）。
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
 * FU-HM-THEME-BASE：29 个中性与材质角色的两种取值（D10-909 ④，负责人定稿前录两套）。
 * TOKEN：取令牌暖灰（默认，与上线行为相同）；SYSTEM：不给这些角色，走系统默认。枚举串值同时是 staging 启动参数的取值。
 */
export enum SystemNeutralPreset { TOKEN = 'token', SYSTEM = 'system' }

/** 品牌与状态（22）：两种方案都取令牌。 */
export const BRAND_ROLES: string[] = [
  'brand', 'warning', 'alert', 'confirm',
  'fontEmphasize', 'fontOnPrimary', 'fontOnSecondary', 'fontOnTertiary', 'fontOnFourth',
  'iconEmphasize', 'iconSubEmphasize', 'iconOnPrimary', 'iconOnSecondary', 'iconOnTertiary', 'iconOnFourth',
  'backgroundEmphasize', 'compBackgroundEmphasize', 'compEmphasizeSecondary', 'compEmphasizeTertiary',
  'interactiveFocus', 'interactiveActive', 'interactiveSelect'
];

/** 中性与材质（29）：只有 TOKEN 方案取令牌，SYSTEM 方案不给。 */
export const NEUTRAL_ROLES: string[] = [
  'fontPrimary', 'fontSecondary', 'fontTertiary', 'fontFourth',
  'iconPrimary', 'iconSecondary', 'iconTertiary', 'iconFourth',
  'backgroundPrimary', 'backgroundSecondary', 'backgroundTertiary', 'backgroundFourth',
  'compForegroundPrimary', 'compBackgroundPrimary', 'compBackgroundPrimaryTran', 'compBackgroundPrimaryContrary',
  'compBackgroundGray', 'compBackgroundSecondary', 'compBackgroundTertiary', 'compBackgroundNeutral',
  'compDivider', 'compCommonContrary', 'compBackgroundFocus', 'compFocusedPrimary', 'compFocusedSecondary', 'compFocusedTertiary',
  'interactiveHover', 'interactivePressed', 'interactiveClick'
];

/**
 * 系统组件主题（ThemeControl.setDefaultTheme）：默认（TOKEN）SDK Colors 的 51 个角色全部显式按令牌映射，不留鸿蒙默认色；
 * SYSTEM 只给 22 个品牌角色，29 个中性角色的键不存在（SDK 的 CustomColors 没传的角色走系统默认）；未知取值按 TOKEN。
 * 传入资源（CouliColors.tokenResources()）时系统按 base / dark 限定词自动换深色；单测传探针值检验数据流。
 * 角色语义按 @ohos.arkui.theme 的说明对到最近的令牌：文字四级 → 主 / 次 / 控件边界 / 弱分隔；底色四级 → 页面 / 卡片 / 分组 / 占位；
 * 强调 → 狸橙；聚焦 → focus.ring；分隔 → border.subtle；在强调色上的文字 / 图标 → text.inverse。
 */
export function buildSystemColors(tokens: Map<string, ResourceColor>,
  preset: SystemNeutralPreset = SystemNeutralPreset.TOKEN): CustomColors {
  const colors: CustomColors = {
    brand: pick(tokens, 'brand.primary'),
    warning: pick(tokens, 'status.warning.text'),
    alert: pick(tokens, 'status.error.text'),
    confirm: pick(tokens, 'status.success.text'),
    fontEmphasize: pick(tokens, 'text.link'),
    fontOnPrimary: pick(tokens, 'text.inverse'),
    fontOnSecondary: pick(tokens, 'button.primary.default.text'),
    fontOnTertiary: pick(tokens, 'rebate.solid.text'),
    fontOnFourth: pick(tokens, 'button.primary.pressed.text'),
    iconEmphasize: pick(tokens, 'brand.primary'),
    iconSubEmphasize: pick(tokens, 'brand.emphasis'),
    iconOnPrimary: pick(tokens, 'text.inverse'),
    iconOnSecondary: pick(tokens, 'button.primary.default.text'),
    iconOnTertiary: pick(tokens, 'rebate.solid.text'),
    iconOnFourth: pick(tokens, 'button.primary.pressed.text'),
    backgroundEmphasize: pick(tokens, 'brand.primary'),
    compBackgroundEmphasize: pick(tokens, 'control.checked'),
    compEmphasizeSecondary: pick(tokens, 'brand.subtle'),
    compEmphasizeTertiary: pick(tokens, 'rebate.background'),
    interactiveFocus: pick(tokens, 'focus.ring'),
    interactiveActive: pick(tokens, 'button.primary.pressed.background'),
    interactiveSelect: pick(tokens, 'brand.subtle')
  };
  if (preset !== SystemNeutralPreset.SYSTEM) {
    colors.fontPrimary = pick(tokens, 'text.primary');
    colors.fontSecondary = pick(tokens, 'text.secondary');
    colors.fontTertiary = pick(tokens, 'source.text');
    colors.fontFourth = pick(tokens, 'border.control');
    colors.iconPrimary = pick(tokens, 'text.primary');
    colors.iconSecondary = pick(tokens, 'text.secondary');
    colors.iconTertiary = pick(tokens, 'border.control');
    colors.iconFourth = pick(tokens, 'border.subtle');
    colors.backgroundPrimary = pick(tokens, 'background.canvas');
    colors.backgroundSecondary = pick(tokens, 'background.surface');
    colors.backgroundTertiary = pick(tokens, 'background.muted');
    colors.backgroundFourth = pick(tokens, 'background.placeholder');
    colors.compForegroundPrimary = pick(tokens, 'text.primary');
    colors.compBackgroundPrimary = pick(tokens, 'background.surface');
    colors.compBackgroundPrimaryTran = pick(tokens, 'source.background');
    colors.compBackgroundPrimaryContrary = pick(tokens, 'border.active');
    colors.compBackgroundGray = pick(tokens, 'background.muted');
    colors.compBackgroundSecondary = pick(tokens, 'status.pending.background');
    colors.compBackgroundTertiary = pick(tokens, 'background.placeholder');
    colors.compBackgroundNeutral = pick(tokens, 'text.primary');
    colors.compDivider = pick(tokens, 'border.subtle');
    colors.compCommonContrary = pick(tokens, 'text.inverse');
    colors.compBackgroundFocus = pick(tokens, 'background.surface');
    colors.compFocusedPrimary = pick(tokens, 'text.primary');
    colors.compFocusedSecondary = pick(tokens, 'text.secondary');
    colors.compFocusedTertiary = pick(tokens, 'source.border');
    colors.interactiveHover = pick(tokens, 'background.muted');
    colors.interactivePressed = pick(tokens, 'button.primary.disabled.background');
    colors.interactiveClick = pick(tokens, 'background.placeholder');
  }
  return colors;
}
