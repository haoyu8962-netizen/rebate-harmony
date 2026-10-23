// 生成物，禁止手改；来源 specs/design-tokens.v0.4.0.json（tools/codegen/gen_theme.py 生成）
// 浅色 = value、深色 = dark；颜色键为去掉 color. 的点分路径，取值是鸿蒙 #RRGGBB / #AARRGGBB。
// 纯数据：不引用资源、不依赖 Context，主题映射与本机单测都从这里读（F-HM-57）。

/** 一层阴影令牌（shadow.*：x / y / blur / spread 为逻辑单位，color 为 #RRGGBB，opacity 0–1）。 */
export class ThemeShadowLayer {
  readonly x: number;
  readonly y: number;
  readonly blur: number;
  readonly spread: number;
  readonly color: string;
  readonly opacity: number;

  constructor(x: number, y: number, blur: number, spread: number, color: string, opacity: number) {
    this.x = x;
    this.y = y;
    this.blur = blur;
    this.spread = spread;
    this.color = color;
    this.opacity = opacity;
  }
}

/** 一个颜色令牌的两套取值。 */
export class ThemeColorToken {
  readonly key: string;
  readonly light: string;
  readonly dark: string;

  constructor(key: string, light: string, dark: string) {
    this.key = key;
    this.light = light;
    this.dark = dark;
  }
}

/** 一个阴影令牌的两套取值（none 为空数组）。 */
export class ThemeShadowToken {
  readonly key: string;
  readonly light: ThemeShadowLayer[];
  readonly dark: ThemeShadowLayer[];

  constructor(key: string, light: ThemeShadowLayer[], dark: ThemeShadowLayer[]) {
    this.key = key;
    this.light = light;
    this.dark = dark;
  }
}

export class CouliThemeTokens {
  static readonly version: string = "0.4.0";
  static readonly colors: ThemeColorToken[] = [
    new ThemeColorToken("brand.primary", "#C44820", "#C44820"),
    new ThemeColorToken("brand.emphasis", "#A83B1F", "#F0956B"),
    new ThemeColorToken("brand.secondary", "#26735B", "#6CC49F"),
    new ThemeColorToken("brand.subtle", "#FBEFE8", "#3A2219"),
    new ThemeColorToken("background.canvas", "#F2EEE6", "#171513"),
    new ThemeColorToken("background.admin-canvas", "#F6F3ED", "#171513"),
    new ThemeColorToken("background.surface", "#FFFFFF", "#24211E"),
    new ThemeColorToken("background.muted", "#EFEAE2", "#2F2B27"),
    new ThemeColorToken("background.placeholder", "#E9E2D9", "#36312C"),
    new ThemeColorToken("text.primary", "#28251F", "#F2EEE6"),
    new ThemeColorToken("text.secondary", "#655E57", "#B5ACA2"),
    new ThemeColorToken("text.inverse", "#FFFFFF", "#FFFFFF"),
    new ThemeColorToken("text.link", "#A83B1F", "#F0956B"),
    new ThemeColorToken("price.text", "#28251F", "#F2EEE6"),
    new ThemeColorToken("rebate.text", "#A83B1F", "#F29A6E"),
    new ThemeColorToken("rebate.background", "#FBEFE8", "#3A2219"),
    new ThemeColorToken("rebate.solid.background", "#C44820", "#C44820"),
    new ThemeColorToken("rebate.solid.text", "#FFFFFF", "#FFFFFF"),
    new ThemeColorToken("status.pending.text", "#655E57", "#B5ACA2"),
    new ThemeColorToken("status.pending.background", "#EFEAE2", "#2F2B27"),
    new ThemeColorToken("status.success.text", "#26735B", "#6CC49F"),
    new ThemeColorToken("status.success.background", "#EAF4EE", "#16302A"),
    new ThemeColorToken("status.warning.text", "#846020", "#E3B65C"),
    new ThemeColorToken("status.warning.background", "#FBF2DC", "#33290F"),
    new ThemeColorToken("status.error.text", "#B42345", "#F28DA4"),
    new ThemeColorToken("status.error.background", "#FDECF0", "#3B1A22"),
    new ThemeColorToken("border.subtle", "#E4DED5", "#3A3530"),
    new ThemeColorToken("border.control", "#8A8177", "#8C8278"),
    new ThemeColorToken("border.active", "#28251F", "#F2EEE6"),
    new ThemeColorToken("focus.ring", "#26735B", "#5DBB97"),
    new ThemeColorToken("source.text", "#655E57", "#B5ACA2"),
    new ThemeColorToken("source.background", "#FFFFFF", "#24211E"),
    new ThemeColorToken("source.border", "#E4DED5", "#3A3530"),
    new ThemeColorToken("button.primary.default.background", "#C44820", "#C44820"),
    new ThemeColorToken("button.primary.default.text", "#FFFFFF", "#FFFFFF"),
    new ThemeColorToken("button.primary.pressed.background", "#A83B1F", "#A83B1F"),
    new ThemeColorToken("button.primary.pressed.text", "#FFFFFF", "#FFFFFF"),
    new ThemeColorToken("button.primary.disabled.background", "#E9E2D9", "#36312C"),
    new ThemeColorToken("button.primary.disabled.text", "#655E57", "#A39A90"),
    new ThemeColorToken("button.inverse.background", "#FFFFFF", "#FFFFFF"),
    new ThemeColorToken("button.inverse.text", "#A83B1F", "#A83B1F"),
    new ThemeColorToken("overlay.scrim", "#6628251F", "#8C000000"),
    new ThemeColorToken("control.checked", "#C44820", "#C44820"),
    new ThemeColorToken("badge.background", "#C44820", "#C44820"),
  ];
  static readonly shadows: ThemeShadowToken[] = [
    new ThemeShadowToken("none", [], []),
    new ThemeShadowToken("card", [new ThemeShadowLayer(0, 2, 8, 0, "#28251F", 0.06)], [new ThemeShadowLayer(0, 2, 8, 0, "#000000", 0.3)]),
    new ThemeShadowToken("floating", [new ThemeShadowLayer(0, 8, 24, 0, "#28251F", 0.12)], [new ThemeShadowLayer(0, 8, 24, 0, "#000000", 0.45)]),
  ];
  /** component.*：键为去掉 component. 的点分路径（如 'checkbox.size'），dimension 按 vp、number 原样。 */
  static readonly component: Map<string, number> = CouliThemeTokens.buildComponent();

  private static buildComponent(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    map.set("button.min-height", 48);
    map.set("button.padding-inline", 20);
    map.set("button.padding-block", 12);
    map.set("button.gap", 8);
    map.set("control.min-height", 44);
    map.set("control.border-width", 1);
    map.set("icon.default", 24);
    map.set("icon.small", 14);
    map.set("icon.inline", 16);
    map.set("icon.medium", 20);
    map.set("field.min-height", 52);
    map.set("code-cell.height", 56);
    map.set("checkbox.size", 18);
    map.set("checkbox.max-scale", 1.5);
    map.set("chip.height", 32);
    map.set("tab-indicator.height", 2);
    map.set("tag.min-height", 22);
    map.set("platform-badge.min-height", 20);
    map.set("count-badge.size", 18);
    map.set("image.list", 96);
    map.set("grid-cell.min-height", 72);
    map.set("oauth.size", 48);
    map.set("oauth.gap", 32);
    return map;
  }
}
