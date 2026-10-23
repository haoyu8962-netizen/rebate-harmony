import { CouliLogo, CouliLogoVariant } from './CouliLogo';

/**
 * 品牌标识（清单 §3.7 BrandMark）：正式 Logo 主图形（BRAND-01 SVG，浅 / 深由资源目录自动选）缩到 56；读屏跳过（装饰）。
 * 与 CouliLogo 一样只从 designsystem/Brand 导出（CouliLogo 用字面量 $r 引媒体资源，F-HM-57）。
 */
@ComponentV2
export struct BrandMark {
  @Param markSize: number = 56;

  build() {
    CouliLogo({ variant: CouliLogoVariant.Mark, logoHeight: this.markSize, accessibilityLabel: '' })
  }
}
