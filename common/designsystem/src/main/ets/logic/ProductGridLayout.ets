import { DesignTokens } from 'generated';
import { LARGE_TEXT_SCALE } from './TextScale';

/** 网格最窄列宽：窄于此（或字号放大）时改单列，保证金额段不拆、不裁切。 */
export const GRID_MIN_COLUMN: number = 160;

/** 网格列间距 space.3（直接取生成的令牌表；不经 CouliMetrics，避免把 ArkUI / 颜色资源带进纯逻辑入口）。 */
function gridGap(): number {
  const value: number | undefined = DesignTokens.spacing.get('3');
  if (value === undefined) {
    throw new Error('missing token space.3');
  }
  return value;
}

/** 两列所需的最小可用宽度（vp）：两列最窄列宽 + 列间距。ProductCardGrid 与 ProductGridLayout 共用。 */
export function productGridTwoColumnMinWidth(): number {
  return 2 * GRID_MIN_COLUMN + gridGap();
}

/**
 * 商品网格的列数（纯函数，便于单测）：只有 1 件、可用宽度放不下两列（每列至少 160vp + 列间距）或字号放大超过阈值时单列，否则两列。
 * 宽度未知（0，还没量到）按两列先排，量到后再定。
 */
export class ProductGridLayout {
  static readonly MIN_COLUMN: number = GRID_MIN_COLUMN;

  static columns(count: number, widthVp: number, fontScale: number): number {
    if (count <= 1 || fontScale > LARGE_TEXT_SCALE) {
      return 1;
    }
    if (widthVp > 0 && widthVp < productGridTwoColumnMinWidth()) {
      return 1;
    }
    return 2;
  }
}
