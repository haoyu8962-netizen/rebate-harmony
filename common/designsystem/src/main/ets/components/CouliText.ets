import { CouliTextStyle } from '../CouliTypography';

/**
 * 文字样式修饰器：字号与行高用 fp（随系统字体大小缩放，03 §10.4），颜色与字重由调用处给。
 * 用法：Text(x).attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textPrimary))
 * 金额加 tabular：等宽数字（GUIDE §2「金额加 tabular-nums」）。
 */
export class CouliTextModifier implements AttributeModifier<TextAttribute> {
  private readonly style: CouliTextStyle;
  private readonly color: ResourceColor;
  private readonly weight: number;
  private readonly tabular: boolean;

  constructor(style: CouliTextStyle, color: ResourceColor, weight?: number, tabular?: boolean) {
    this.style = style;
    this.color = color;
    this.weight = weight ?? style.fontWeight;
    this.tabular = tabular ?? false;
  }

  applyNormalAttribute(instance: TextAttribute): void {
    instance.fontSize(this.style.fontSize);
    instance.lineHeight(this.style.lineHeight);
    instance.fontColor(this.color);
    instance.fontWeight(this.weight);
    if (this.tabular) {
      instance.fontFeature(TABULAR_FEATURE);
    }
  }
}

/** OpenType 等宽数字特性。 */
export const TABULAR_FEATURE: string = '"tnum" on';
