// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// 设计令牌原始值：design/tokens/design-tokens.json。颜色键为去掉 tokens.color. 的点分路径。
// spacing / radius / fontSize 是任务书 §5.6 的约定接口；lineHeight、fontWeight、touchTarget 供 DesignSystem 映射用。

export class DesignTokens {
  static readonly version: string = '0.3.0';
  static readonly colors: Map<string, string> = DesignTokens.buildColors();
  static readonly spacing: Map<string, number> = DesignTokens.buildSpacing();
  static readonly radius: Map<string, number> = DesignTokens.buildRadius();
  static readonly fontSize: Map<string, number> = DesignTokens.buildFontSize();
  static readonly lineHeight: Map<string, number> = DesignTokens.buildLineHeight();
  static readonly fontWeight: Map<string, number> = DesignTokens.buildFontWeight();
  static readonly touchTarget: Map<string, number> = DesignTokens.buildTouchTarget();

  private static buildColors(): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    map.set('brand.primary', '#C44820');
    map.set('brand.emphasis', '#A83B1F');
    map.set('brand.secondary', '#26735B');
    map.set('brand.subtle', '#FBEFE8');
    map.set('background.canvas', '#F2EEE6');
    map.set('background.admin-canvas', '#F6F3ED');
    map.set('background.surface', '#FFFFFF');
    map.set('background.muted', '#EFEAE2');
    map.set('background.placeholder', '#E9E2D9');
    map.set('text.primary', '#28251F');
    map.set('text.secondary', '#655E57');
    map.set('text.inverse', '#FFFFFF');
    map.set('text.link', '#A83B1F');
    map.set('price.text', '#28251F');
    map.set('rebate.text', '#A83B1F');
    map.set('rebate.background', '#FBEFE8');
    map.set('rebate.solid.background', '#C44820');
    map.set('rebate.solid.text', '#FFFFFF');
    map.set('status.pending.text', '#655E57');
    map.set('status.pending.background', '#EFEAE2');
    map.set('status.success.text', '#26735B');
    map.set('status.success.background', '#EAF4EE');
    map.set('status.warning.text', '#846020');
    map.set('status.warning.background', '#FBF2DC');
    map.set('status.error.text', '#B42345');
    map.set('status.error.background', '#FDECF0');
    map.set('border.subtle', '#E4DED5');
    map.set('border.control', '#8A8177');
    map.set('focus.ring', '#26735B');
    map.set('source.text', '#655E57');
    map.set('source.background', '#FFFFFF');
    map.set('source.border', '#E4DED5');
    map.set('button.primary.default.background', '#C44820');
    map.set('button.primary.default.text', '#FFFFFF');
    map.set('button.primary.pressed.background', '#A83B1F');
    map.set('button.primary.pressed.text', '#FFFFFF');
    map.set('button.primary.disabled.background', '#E9E2D9');
    map.set('button.primary.disabled.text', '#655E57');
    return map;
  }

  private static buildSpacing(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    map.set('0', 0);
    map.set('1', 4);
    map.set('2', 8);
    map.set('3', 12);
    map.set('4', 16);
    map.set('5', 20);
    map.set('6', 24);
    map.set('8', 32);
    map.set('10', 40);
    map.set('12', 48);
    map.set('16', 64);
    return map;
  }

  private static buildRadius(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    map.set('small', 8);
    map.set('button', 12);
    map.set('card', 16);
    map.set('panel', 24);
    map.set('pill', 999);
    return map;
  }

  private static buildFontSize(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    map.set('caption', 12);
    map.set('footnote', 14);
    map.set('body', 17);
    map.set('title', 22);
    map.set('heading', 28);
    map.set('display', 34);
    return map;
  }

  private static buildLineHeight(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    map.set('caption', 1.5);
    map.set('footnote', 1.5);
    map.set('body', 1.5);
    map.set('title', 1.3);
    map.set('heading', 1.25);
    map.set('display', 1.2);
    return map;
  }

  private static buildFontWeight(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    map.set('regular', 400);
    map.set('medium', 500);
    map.set('semibold', 600);
    map.set('bold', 700);
    return map;
  }

  private static buildTouchTarget(): Map<string, number> {
    const map: Map<string, number> = new Map<string, number>();
    map.set('minimum', 44);
    map.set('ios', 44);
    map.set('android', 48);
    map.set('harmony', 48);
    return map;
  }
}
