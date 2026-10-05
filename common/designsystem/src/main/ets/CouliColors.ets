import { DesignTokens } from 'generated';

/**
 * 颜色令牌的语义名（三端一致：令牌路径 `brand.primary` → `brandPrimary`，连字符同样转驼峰）。
 * 取值来自生成的 DesignTokens.colors（#RRGGBB 字符串，可直接作 ArkUI ResourceColor）。
 * 只有浅色主题：应用强制浅色（EntryAbility 里 setColorMode(COLOR_MODE_LIGHT)，TECH-22）。
 */
export class CouliColors {
  static readonly brandPrimary: string = CouliColors.token('brand.primary');
  static readonly brandEmphasis: string = CouliColors.token('brand.emphasis');
  static readonly brandSecondary: string = CouliColors.token('brand.secondary');
  static readonly brandSubtle: string = CouliColors.token('brand.subtle');
  static readonly backgroundCanvas: string = CouliColors.token('background.canvas');
  static readonly backgroundAdminCanvas: string = CouliColors.token('background.admin-canvas');
  static readonly backgroundSurface: string = CouliColors.token('background.surface');
  static readonly backgroundMuted: string = CouliColors.token('background.muted');
  static readonly backgroundPlaceholder: string = CouliColors.token('background.placeholder');
  static readonly textPrimary: string = CouliColors.token('text.primary');
  static readonly textSecondary: string = CouliColors.token('text.secondary');
  static readonly textInverse: string = CouliColors.token('text.inverse');
  static readonly textLink: string = CouliColors.token('text.link');
  static readonly priceText: string = CouliColors.token('price.text');
  static readonly rebateText: string = CouliColors.token('rebate.text');
  static readonly rebateBackground: string = CouliColors.token('rebate.background');
  static readonly rebateSolidBackground: string = CouliColors.token('rebate.solid.background');
  static readonly rebateSolidText: string = CouliColors.token('rebate.solid.text');
  static readonly statusPendingText: string = CouliColors.token('status.pending.text');
  static readonly statusPendingBackground: string = CouliColors.token('status.pending.background');
  static readonly statusSuccessText: string = CouliColors.token('status.success.text');
  static readonly statusSuccessBackground: string = CouliColors.token('status.success.background');
  static readonly statusWarningText: string = CouliColors.token('status.warning.text');
  static readonly statusWarningBackground: string = CouliColors.token('status.warning.background');
  static readonly statusErrorText: string = CouliColors.token('status.error.text');
  static readonly statusErrorBackground: string = CouliColors.token('status.error.background');
  static readonly borderSubtle: string = CouliColors.token('border.subtle');
  static readonly borderControl: string = CouliColors.token('border.control');
  static readonly focusRing: string = CouliColors.token('focus.ring');
  static readonly sourceText: string = CouliColors.token('source.text');
  static readonly sourceBackground: string = CouliColors.token('source.background');
  static readonly sourceBorder: string = CouliColors.token('source.border');
  static readonly buttonPrimaryDefaultBackground: string = CouliColors.token('button.primary.default.background');
  static readonly buttonPrimaryDefaultText: string = CouliColors.token('button.primary.default.text');
  static readonly buttonPrimaryPressedBackground: string = CouliColors.token('button.primary.pressed.background');
  static readonly buttonPrimaryPressedText: string = CouliColors.token('button.primary.pressed.text');
  static readonly buttonPrimaryDisabledBackground: string = CouliColors.token('button.primary.disabled.background');
  static readonly buttonPrimaryDisabledText: string = CouliColors.token('button.primary.disabled.text');

  /** 令牌路径 → 语义名，便于核对映射完整（单测用）。 */
  static readonly semanticNames: Map<string, string> = CouliColors.buildNames();

  static token(path: string): string {
    const value: string | undefined = DesignTokens.colors.get(path);
    if (value === undefined) {
      throw new Error('missing color token: ' + path);
    }
    return value;
  }

  private static buildNames(): Map<string, string> {
    const names: Map<string, string> = new Map<string, string>();
    names.set('brand.primary', 'brandPrimary');
    names.set('brand.emphasis', 'brandEmphasis');
    names.set('brand.secondary', 'brandSecondary');
    names.set('brand.subtle', 'brandSubtle');
    names.set('background.canvas', 'backgroundCanvas');
    names.set('background.admin-canvas', 'backgroundAdminCanvas');
    names.set('background.surface', 'backgroundSurface');
    names.set('background.muted', 'backgroundMuted');
    names.set('background.placeholder', 'backgroundPlaceholder');
    names.set('text.primary', 'textPrimary');
    names.set('text.secondary', 'textSecondary');
    names.set('text.inverse', 'textInverse');
    names.set('text.link', 'textLink');
    names.set('price.text', 'priceText');
    names.set('rebate.text', 'rebateText');
    names.set('rebate.background', 'rebateBackground');
    names.set('rebate.solid.background', 'rebateSolidBackground');
    names.set('rebate.solid.text', 'rebateSolidText');
    names.set('status.pending.text', 'statusPendingText');
    names.set('status.pending.background', 'statusPendingBackground');
    names.set('status.success.text', 'statusSuccessText');
    names.set('status.success.background', 'statusSuccessBackground');
    names.set('status.warning.text', 'statusWarningText');
    names.set('status.warning.background', 'statusWarningBackground');
    names.set('status.error.text', 'statusErrorText');
    names.set('status.error.background', 'statusErrorBackground');
    names.set('border.subtle', 'borderSubtle');
    names.set('border.control', 'borderControl');
    names.set('focus.ring', 'focusRing');
    names.set('source.text', 'sourceText');
    names.set('source.background', 'sourceBackground');
    names.set('source.border', 'sourceBorder');
    names.set('button.primary.default.background', 'buttonPrimaryDefaultBackground');
    names.set('button.primary.default.text', 'buttonPrimaryDefaultText');
    names.set('button.primary.pressed.background', 'buttonPrimaryPressedBackground');
    names.set('button.primary.pressed.text', 'buttonPrimaryPressedText');
    names.set('button.primary.disabled.background', 'buttonPrimaryDisabledBackground');
    names.set('button.primary.disabled.text', 'buttonPrimaryDisabledText');
    return names;
  }
}
