import { CouliInteraction, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CardAmountMask, RebateTagContent } from '../format/PriceModels';
import { PriceTerms } from '../format/PriceTerms';
import { ProductCardData } from './ProductCard';

/** 首页横滑卡宽（Main-v3 实测 144vp）。 */
export const SCROLL_TILE_MIN_WIDTH: number = 144;
/** 返利块首行钟表图标视觉宽（RebateTag / GridRebateBlock 同值）。 */
const CLOCK_ICON: number = 14;
/** 返利块首行口径 i 实际占的宽：命中区 48，左外边距 −14（DisclaimerFooter CARD）、右外边距 −8（GridRebateBlock）。 */
const INFO_FOOTPRINT: number = 48 - 14 - CouliSpacing.space2;

/**
 * 商品卡内容的量宽（HM-07v；编排 D10-405「按内容实际所需宽度定列数」、APP-11v Android 评审 r1 S1-2「200% 不截断」）。
 * 文字一律按 100% 字号用 vp 字号量（不受字号倍数影响），再乘调用方给的字号倍数；内边距、图标等固定尺寸不乘。
 * 只量「一段不能拆的金额段」：主价行（口径词 + 主价）、副行、返利金额与返利块首行；amount_unknown 量专用标签最长的一段（逗号处可折行）；
 * 标题可折行，不参与。
 * 需要 UIContext（MeasureUtils），量不到时按「字数 × 字号」保守估计（只会偏宽）。
 */
export class ProductCardMeasure {
  /** 首页横滑卡宽：不小于 144，金额放不下时加宽。 */
  static scrollTileWidth(ui: UIContext, items: ProductCardData[], scale: number): number {
    return Math.max(SCROLL_TILE_MIN_WIDTH, ProductCardMeasure.contentWidth(ui, items, scale));
  }

  /**
   * 首页段卡内网格卡（ProductCard GRID inset：无内边距）每列至少要的宽（vp），传给 ProductGridLayout.columns 的 minColumn。
   * 没有可量的内容时返回 0（调用方按组件库缺省 160 处理）。
   */
  static gridMinColumn(ui: UIContext, items: ProductCardData[], scale: number): number {
    return ProductCardMeasure.contentWidth(ui, items, scale);
  }

  /** 一组卡里「不能拆的内容」的最大宽度（vp，向上取整 + 2 的余量）。 */
  static contentWidth(ui: UIContext, items: ProductCardData[], scale: number): number {
    const k: number = Number.isFinite(scale) && scale > 0 ? scale : 1;
    let need: number = 0;
    for (const d of items) {
      if (d.priceUnavailable) {
        continue;
      }
      const unknown: boolean = d.rebate.kindRaw === 'unknown';
      if (!unknown) {
        // amount_unknown 不画价格行与副行（BR-PRICE-08），不量。
        const label: number = ProductCardMeasure.text(ui, d.price.mainLabel + ' ', CouliTypography.caption.size,
          CouliFontWeight.regular);
        const amount: number = ProductCardMeasure.text(ui, d.price.mainAmount, CouliTypography.body.size,
          CouliFontWeight.bold);
        const sub: number = ProductCardMeasure.text(ui, d.price.noCoupon ? PriceTerms.noCoupon : (d.price.subLine ?? ''),
          CouliTypography.caption.size, CouliFontWeight.regular);
        need = Math.max(need, (label + amount) * k, sub * k);
      }
      if (unknown && !d.rebateHidden) {
        // 「可返利，金额以订单为准」：只在逗号后可折行，量最长的一段（钟表 + 间距 + 左右内边距；不放口径 i）。
        const segs: string[] = d.rebate.text.split(PriceTerms.comma);
        let longest: number = 0;
        segs.forEach((s: string, i: number) => {
          const piece: string = i < segs.length - 1 ? s + PriceTerms.comma : s;
          longest = Math.max(longest, ProductCardMeasure.text(ui, piece, CouliTypography.caption.size,
            CouliFontWeight.regular));
        });
        need = Math.max(need, longest * k + 2 * CouliSpacing.space2 + CLOCK_ICON + CouliSpacing.space1);
      } else if (!d.rebateHidden && d.rebate.kindRaw !== 'none') {
        const rebate: RebateTagContent = CardAmountMask.rebate(d.rebate, d.amountHidden);
        const pad: number = 2 * CouliSpacing.space2;
        const amountText: string = rebate.hasAmount ? rebate.amountParts.join('') : '';
        const rebateAmount: number = ProductCardMeasure.text(ui, amountText, CouliTypography.footnote.size,
          CouliFontWeight.bold) * k + pad;
        const head: number = ProductCardMeasure.text(ui, rebate.hasAmount ? PriceTerms.rebate : rebate.text,
          CouliTypography.caption.size, CouliFontWeight.regular) * k + pad + CLOCK_ICON + CouliSpacing.space1
          + (d.disclaimerLines.length > 0 ? INFO_FOOTPRINT : 0);
        need = Math.max(need, rebateAmount, head);
      } else if (!unknown && d.disclaimerLines.length > 0) {
        need = Math.max(need, CouliSpacing.space3 + CouliInteraction.minTouchTarget);
      }
    }
    return need <= 0 ? 0 : Math.ceil(need) + 2;
  }

  /** 100% 字号下的文字宽（vp）。 */
  static text(ui: UIContext, text: string, size: number, weight: number): number {
    if (text.length === 0) {
      return 0;
    }
    try {
      const px: number = ui.getMeasureUtils().measureText({
        textContent: text, fontSize: size + 'vp', fontWeight: weight
      }) as number;
      return ui.px2vp(px);
    } catch (e) {
      return text.length * size;
    }
  }
}
