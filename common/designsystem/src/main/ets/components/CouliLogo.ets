/**
 * 品牌 Logo（BRAND-01）：只是取用入口，不决定页面摆放（登录等页面的位置以定稿画板为准）。
 *
 * 资源是规划仓库 design/logo/source 的 SVG 原文件（保留矢量）：resources/base/media 放原色版，resources/dark/media 放同名反白版，
 * 系统按应用颜色模式取图——应用目前强制浅色（EntryAbility 里 setColorMode(COLOR_MODE_LIGHT)，TECH-22），深色接入后自动换反白。
 * 等比缩放、不拉伸；四周留白由调用方按 Logo 规范排版。
 */
export enum CouliLogoVariant {
  /** 主图形（256 × 256 画布），建议最小显示 24vp。 */
  Mark = 'mark',
  /** 横向组合：图形 + 中文字标（580 × 256 画布），建议最小宽 112vp；更窄的地方用 Mark。 */
  Horizontal = 'horizontal'
}

const LOGO_CANVAS_HEIGHT: number = 256;
const HORIZONTAL_CANVAS_WIDTH: number = 580;
/** Logo 规范的建议最小尺寸（design/logo/README.md「使用规则」）：图形 24vp 见方，横版宽 112vp。 */
const MARK_MIN_SIZE: number = 24;
const HORIZONTAL_MIN_WIDTH: number = 112;

export class CouliLogoSpec {
  /** 原始画布宽高比（宽 / 高），与 SVG 源文件的 viewBox 一致。 */
  static aspectRatio(variant: CouliLogoVariant): number {
    return variant === CouliLogoVariant.Horizontal ? HORIZONTAL_CANVAS_WIDTH / LOGO_CANVAS_HEIGHT : 1;
  }

  /** 不指定高度时用的默认高度：取建议最小尺寸（横版按最小宽 112vp 折算高度）。 */
  static defaultHeight(variant: CouliLogoVariant): number {
    return variant === CouliLogoVariant.Horizontal ? HORIZONTAL_MIN_WIDTH / CouliLogoSpec.aspectRatio(variant) : MARK_MIN_SIZE;
  }

  /** 对应的媒体资源（浅 / 深由系统按 base / dark 目录自动选）。 */
  static resource(variant: CouliLogoVariant): Resource {
    return variant === CouliLogoVariant.Horizontal ? $r('app.media.couli_logo_horizontal') : $r('app.media.couli_logo_mark');
  }
}

@ComponentV2
export struct CouliLogo {
  @Param variant: CouliLogoVariant = CouliLogoVariant.Mark;
  /** 显示高度（vp），宽度按画布宽高比算；不给（0）时用该版式的建议最小尺寸。 */
  @Param logoHeight: number = 0;
  /** 读屏文本（由调用方经文案字典取）；空串表示装饰图，读屏跳过。 */
  @Param accessibilityLabel: string = '';

  private resolvedHeight(): number {
    return this.logoHeight > 0 ? this.logoHeight : CouliLogoSpec.defaultHeight(this.variant);
  }

  build() {
    Image(CouliLogoSpec.resource(this.variant))
      .height(this.resolvedHeight())
      .width(this.resolvedHeight() * CouliLogoSpec.aspectRatio(this.variant))
      .objectFit(ImageFit.Contain)
      .draggable(false)
      .accessibilityText(this.accessibilityLabel)
      .accessibilityLevel(this.accessibilityLabel.length > 0 ? 'yes' : 'no')
  }
}
