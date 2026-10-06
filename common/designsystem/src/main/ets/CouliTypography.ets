import { DesignTokens } from 'generated';

/**
 * 一级文字样式。字号与行高单位是 fp：随系统字体大小缩放（03 §10.4，鸿蒙文字用 fp）。
 * 用法：Text(x).fontSize(style.fontSize).lineHeight(style.lineHeight).fontWeight(style.fontWeight)
 */
export class CouliTextStyle {
  readonly level: string;
  /** 令牌字号（逻辑像素，按 fp 使用）。 */
  readonly size: number;
  /** 行高倍数。 */
  readonly lineHeightRatio: number;
  readonly weight: number;

  constructor(level: string, size: number, lineHeightRatio: number, weight: number) {
    this.level = level;
    this.size = size;
    this.lineHeightRatio = lineHeightRatio;
    this.weight = weight;
  }

  /** ArkUI fontSize 参数，如 '17fp'。 */
  get fontSize(): string {
    return this.size + 'fp';
  }

  /** ArkUI lineHeight 参数（字号 × 行高倍数，fp）。 */
  get lineHeight(): string {
    return Math.round(this.size * this.lineHeightRatio * 100) / 100 + 'fp';
  }

  get fontWeight(): number {
    return this.weight;
  }
}

/**
 * 6 级文字样式（caption … display），与 iOS / Android 同名。
 * 字重：令牌只给了档位，没规定各级用哪档；先按「正文常规、标题半粗、展示加粗」取（与 Android 一致），组件任务按设计稿再核。
 */
export class CouliTypography {
  static readonly caption: CouliTextStyle = CouliTypography.style('caption', 'regular');
  static readonly footnote: CouliTextStyle = CouliTypography.style('footnote', 'regular');
  static readonly body: CouliTextStyle = CouliTypography.style('body', 'regular');
  static readonly title: CouliTextStyle = CouliTypography.style('title', 'semibold');
  static readonly heading: CouliTextStyle = CouliTypography.style('heading', 'semibold');
  static readonly display: CouliTextStyle = CouliTypography.style('display', 'bold');

  static readonly all: CouliTextStyle[] = [
    CouliTypography.caption, CouliTypography.footnote, CouliTypography.body,
    CouliTypography.title, CouliTypography.heading, CouliTypography.display
  ];

  private static style(level: string, weight: string): CouliTextStyle {
    return new CouliTextStyle(level, CouliTypography.number(DesignTokens.fontSize, level),
      CouliTypography.number(DesignTokens.lineHeight, level), CouliTypography.number(DesignTokens.fontWeight, weight));
  }

  private static number(table: Map<string, number>, key: string): number {
    const value: number | undefined = table.get(key);
    if (value === undefined) {
      throw new Error('missing font token: ' + key);
    }
    return value;
  }
}

/** 字重令牌 font.weight.*（DS-01；700 只给少量核心数值，GUIDE §2）。 */
export class CouliFontWeight {
  static readonly regular: number = CouliFontWeight.of('regular');
  static readonly medium: number = CouliFontWeight.of('medium');
  static readonly semibold: number = CouliFontWeight.of('semibold');
  static readonly bold: number = CouliFontWeight.of('bold');

  private static of(key: string): number {
    const value: number | undefined = DesignTokens.fontWeight.get(key);
    if (value === undefined) {
      throw new Error('missing font weight token: ' + key);
    }
    return value;
  }
}
