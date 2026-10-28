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

/**
 * 两列所需的最小可用宽度（vp）：两列最窄列宽 + 列间距。ProductCardGrid 与 ProductGridLayout 共用。
 * minColumn：每列最窄宽度，缺省 GRID_MIN_COLUMN（160，既有调用不变）；HM-07v（编排 D10-405）首页超市百货段按卡内内容实际所需宽度传入。
 */
export function productGridTwoColumnMinWidth(minColumn: number = GRID_MIN_COLUMN): number {
  return 2 * minColumn + gridGap();
}

/**
 * 商品网格的列数（纯函数，便于单测）：只有 1 件、可用宽度放不下两列（每列至少 minColumn + 列间距）或字号放大超过阈值时单列，否则两列。
 * 宽度未知（0，还没量到）按两列先排，量到后再定。minColumn 缺省 160（GRID_MIN_COLUMN）：不传时与原口径完全相同；
 * 传入非正数或非数字时也按 160（防止误传把门槛降成 0）。
 */
export class ProductGridLayout {
  static readonly MIN_COLUMN: number = GRID_MIN_COLUMN;

  static columns(count: number, widthVp: number, fontScale: number, minColumn: number = GRID_MIN_COLUMN): number {
    if (count <= 1 || fontScale > LARGE_TEXT_SCALE) {
      return 1;
    }
    const min: number = Number.isFinite(minColumn) && minColumn > 0 ? minColumn : GRID_MIN_COLUMN;
    if (widthVp > 0 && widthVp < productGridTwoColumnMinWidth(min)) {
      return 1;
    }
    return 2;
  }
}
