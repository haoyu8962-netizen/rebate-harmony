import { CouliLogo, CouliLogoVariant } from './CouliLogo';
import { BrandMarkSpec, BrandMarkVariant } from '../logic/BrandMarkSpec';

/**
 * 品牌标识（清单 §3.7 BrandMark）：正式 Logo 主图形（BRAND-01 SVG，浅 / 深由资源目录自动选）缩到 56；读屏跳过（装饰）。
 * 与 CouliLogo 一样只从 designsystem/Brand 导出（CouliLogo 用字面量 $r 引媒体资源，F-HM-57）。
 * D10-2762：variant = AppIcon 时是应用图标式方块（规划仓库 design/app-icon/icon-default.svg 原件，圆角 = 边长 × 12 / 56），
 * 登录页首屏用；默认 Mark 与现版完全一样。两种版式都按 vp 定死边长（不随字号放大）、读屏跳过。
 */
@ComponentV2
export struct BrandMark {
  @Param markSize: number = 56;
  @Param variant: BrandMarkVariant = BrandMarkVariant.Mark;

  build() {
    if (this.variant === BrandMarkVariant.AppIcon) {
      Image($r('app.media.couli_app_icon'))
        .width(this.markSize)
        .height(this.markSize)
        .objectFit(ImageFit.Contain)
        .borderRadius(BrandMarkSpec.cornerRadius(this.variant, this.markSize))
        .clip(true)
        .draggable(false)
        .accessibilityText('')
        .accessibilityLevel('no')
    } else {
      CouliLogo({ variant: CouliLogoVariant.Mark, logoHeight: this.markSize, accessibilityLabel: '' })
    }
  }
}
