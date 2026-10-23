import { common } from '@kit.AbilityKit';
import { ThemeControl } from '@kit.ArkUI';
import { DesignTokens } from 'generated';
import { CouliColorMode } from './components/ColorMode';
import { buildSystemColors } from './theme/CouliThemeMapping';
import { CouliThemeTokens, ThemeColorToken } from './theme/CouliThemeTokens';

/**
 * 按资源名取本模块颜色资源（resources/base 与 resources/dark 的 element/color.json，由 tools/codegen/gen_theme.py 生成）。
 * 资源名用变量拼出（编译成按名称运行时查找）：$r 写成字面量会在编译期按「当前编译单元」的资源表校验，core 的本机单测把
 * designsystem 当 devDependency 引入时只带 core 自己的资源，会报 Unknown resource type（F-HM-57）。HAP 构建会合并本模块资源，
 * 运行时按名称找到；系统切深色时自动取 dark 目录的同名值。
 */
export function couliColorResource(name: string): Resource {
  return $r('app.color.' + name);
}

/** 令牌路径（去掉 color.）→ 资源名：color_ + 路径，点与连字符换下划线。 */
export function couliColorResourceName(path: string): string {
  return 'color_' + path.replace(new RegExp('[.-]', 'g'), '_');
}

function res(path: string): Resource {
  return couliColorResource(couliColorResourceName(path));
}

/**
 * 颜色令牌的语义名（三端一致：令牌路径 `brand.primary` → `brandPrimary`，连字符同样转驼峰）。
 * DS-02 起取值是资源（ResourceColor）：浅色取 resources/base、深色取 resources/dark，页面与组件跟随系统 / 应用颜色模式自动换值，
 * 不在视图里判断深浅。两套数值的唯一源是令牌 v0.4.0（color.* 的 value / dark）。
 */
export class CouliColors {
  static readonly brandPrimary: Resource = res('brand.primary');
  static readonly brandEmphasis: Resource = res('brand.emphasis');
  static readonly brandSecondary: Resource = res('brand.secondary');
  static readonly brandSubtle: Resource = res('brand.subtle');
  static readonly backgroundCanvas: Resource = res('background.canvas');
  static readonly backgroundAdminCanvas: Resource = res('background.admin-canvas');
  static readonly backgroundSurface: Resource = res('background.surface');
  static readonly backgroundMuted: Resource = res('background.muted');
  static readonly backgroundPlaceholder: Resource = res('background.placeholder');
  static readonly textPrimary: Resource = res('text.primary');
  static readonly textSecondary: Resource = res('text.secondary');
  static readonly textInverse: Resource = res('text.inverse');
  static readonly textLink: Resource = res('text.link');
  static readonly priceText: Resource = res('price.text');
  static readonly rebateText: Resource = res('rebate.text');
  static readonly rebateBackground: Resource = res('rebate.background');
  static readonly rebateSolidBackground: Resource = res('rebate.solid.background');
  static readonly rebateSolidText: Resource = res('rebate.solid.text');
  static readonly statusPendingText: Resource = res('status.pending.text');
  static readonly statusPendingBackground: Resource = res('status.pending.background');
  static readonly statusSuccessText: Resource = res('status.success.text');
  static readonly statusSuccessBackground: Resource = res('status.success.background');
  static readonly statusWarningText: Resource = res('status.warning.text');
  static readonly statusWarningBackground: Resource = res('status.warning.background');
  static readonly statusErrorText: Resource = res('status.error.text');
  static readonly statusErrorBackground: Resource = res('status.error.background');
  static readonly borderSubtle: Resource = res('border.subtle');
  static readonly borderControl: Resource = res('border.control');
  static readonly borderActive: Resource = res('border.active');
  static readonly focusRing: Resource = res('focus.ring');
  static readonly sourceText: Resource = res('source.text');
  static readonly sourceBackground: Resource = res('source.background');
  static readonly sourceBorder: Resource = res('source.border');
  static readonly buttonPrimaryDefaultBackground: Resource = res('button.primary.default.background');
  static readonly buttonPrimaryDefaultText: Resource = res('button.primary.default.text');
  static readonly buttonPrimaryPressedBackground: Resource = res('button.primary.pressed.background');
  static readonly buttonPrimaryPressedText: Resource = res('button.primary.pressed.text');
  static readonly buttonPrimaryDisabledBackground: Resource = res('button.primary.disabled.background');
  static readonly buttonPrimaryDisabledText: Resource = res('button.primary.disabled.text');
  static readonly buttonInverseBackground: Resource = res('button.inverse.background');
  static readonly buttonInverseText: Resource = res('button.inverse.text');
  static readonly overlayScrim: Resource = res('overlay.scrim');
  static readonly controlChecked: Resource = res('control.checked');
  static readonly badgeBackground: Resource = res('badge.background');

  /**
   * 契约快照令牌路径 → 语义名（DesignTokens.colors，contract.lock 锁定的 v0.3.0 键；DS-02 新增的 T1–T5 颜色在 CouliThemeTokens）。
   */
  static readonly semanticNames: Map<string, string> = CouliColors.buildNames();

  /** 契约快照里的浅色原值（#RRGGBB 字符串；只给需要字符串的旧调用与核对用，界面取色一律用上面的资源）。 */
  static token(path: string): string {
    const value: string | undefined = DesignTokens.colors.get(path);
    if (value === undefined) {
      throw new Error('missing color token: ' + path);
    }
    return value;
  }

  /** 全部颜色令牌（v0.4.0，键去掉 color.）→ 资源；系统组件主题（CouliTheme.install）用它，深色随资源限定词。 */
  static tokenResources(): Map<string, ResourceColor> {
    const map: Map<string, ResourceColor> = new Map<string, ResourceColor>();
    CouliThemeTokens.colors.forEach((token: ThemeColorToken) => {
      map.set(token.key, res(token.key));
    });
    return map;
  }

  /** 令牌路径 → 驼峰语义名。 */
  static semanticName(path: string): string {
    const parts: string[] = path.split(new RegExp('[.-]'));
    let out: string = parts[0];
    for (let i: number = 1; i < parts.length; i++) {
      out += parts[i].substring(0, 1).toUpperCase() + parts[i].substring(1);
    }
    return out;
  }

  private static buildNames(): Map<string, string> {
    const names: Map<string, string> = new Map<string, string>();
    DesignTokens.colors.forEach((_value: string, path: string) => {
      names.set(path, CouliColors.semanticName(path));
    });
    return names;
  }
}

/**
 * 系统组件主题：ThemeControl.setDefaultTheme 用令牌资源显式填满 SDK Colors 的 51 个角色（映射见 CouliThemeMapping.buildSystemColors），
 * 没显式设色的系统组件（Toggle、Radio、SegmentButton、系统对话框、半屏把手等）也用狸橙与暖灰；资源随深色自动换值。
 * 在 EntryAbility 加载首页前调用一次。传入应用上下文时同时接上运行中深浅跟踪（CouliColorMode：焦点框、分段文字等
 * 只收解析好颜色的地方据此重新取色，评审 r1 R1-03）。
 */
export class CouliTheme {
  static install(context?: common.Context): void {
    ThemeControl.setDefaultTheme({ colors: buildSystemColors(CouliColors.tokenResources()) });
    if (context !== undefined) {
      CouliColorMode.attach(context);
    }
  }
}
