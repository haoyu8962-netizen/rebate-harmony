import { CouliInteraction } from '../CouliMetrics';

/**
 * 可点图标的「不带子组件」写法（FU-HM-ROOTSHOWN-CHAIN ②，编排 D10-1668；探针 2 probe2-run-20261114-193310）：带子组件的
 * `Button(){CouliIcon}` 在设备上框架判为不可获焦（focusable=false，requestFocus / 先 Tab / tabStop(true) 都落空），键盘走焦与
 * CouliFocusReturn 回焦都到不了；SymbolGlyph 本身是叶子节点，可获焦（同一页面实测 isFocused=true）。
 * 本修饰器给 SymbolGlyph 设图标字号与颜色、图标边长的布局框、48vp 居中命中区（responseRegion）与按压反馈；margin 在「把图标放回原 48vp
 * 按钮中心」的基础上再叠加调用处原来给按钮的外边距，版面与原写法一致。读屏名、角色、id、focusable、focusBox、onClick 仍写在调用处。
 */
export class CouliGlyphTap implements AttributeModifier<SymbolGlyphAttribute> {
  private readonly iconSize: number;
  private readonly color: ResourceColor;
  private readonly top: number;
  private readonly right: number;
  private readonly bottom: number;
  private readonly left: number;

  constructor(iconSize: number, color: ResourceColor, top: number = 0, right: number = 0, bottom: number = 0,
    left: number = 0) {
    this.iconSize = iconSize;
    this.color = color;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
    this.left = left;
  }

  applyNormalAttribute(instance: SymbolGlyphAttribute): void {
    const inset: number = (CouliInteraction.minTouchTarget - this.iconSize) / 2;
    instance.fontSize(this.iconSize + 'vp');
    instance.fontColor([this.color]);
    instance.width(this.iconSize);
    instance.height(this.iconSize);
    instance.margin({ top: inset + this.top, right: inset + this.right, bottom: inset + this.bottom, left: inset + this.left });
    instance.responseRegion({ x: -inset, y: -inset, width: CouliInteraction.minTouchTarget,
      height: CouliInteraction.minTouchTarget });
    instance.clickEffect({ level: ClickEffectLevel.LIGHT });
  }
}
