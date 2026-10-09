// APP-06b 鸿蒙评审第 2 轮（harmony-review-r2.md）：R2-04 补齐前已知新价照常显示并可买、R2-07 搜索卡限流期间的按钮映射、
// R2-08 普通改价补齐前不带口径词。卡片字段按 Core CardPatch 写入的样子构造（client_price_pending 与 Core 同名，Core 测试另核对）。
import { describe, it, expect } from '@ohos/hypium';
import {
  BuyButtonState, PriceConfirmLabel, PriceTerms, ProductCardData, ProductCardMapper, ProductCardTexts
} from '../../Index';

class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    return '<' + key + '>';
  }
}

/** open 改价写入后的卡：新券后价 31.90 已知，券前价、券额待补齐。 */
function pending(extra: string): Record<string, Object> {
  return JSON.parse('{"product_key":"tb:x","platform":"taobao","title":"t","price_fen":null,"coupon_fen":null,'
    + '"final_price_fen":3190,"est_net_price_fen":null,"rebate_min_fen":287,"rebate_max_fen":287,"rebate_basis":"normal",'
    + '"benefit_tags":[],"is_presale":false,"link_id":"l","cta":{"text_key":"btn.buy"},"availability":"ok",'
    + '"disclaimer_keys":["price_basis"]' + extra + '}') as Record<string, Object>;
}

function latest(price: string, coupon: string, final: string): Record<string, Object> {
  return JSON.parse('{"price_fen":' + price + ',"coupon_fen":' + coupon + ',"final_price_fen":' + final + '}') as
  Record<string, Object>;
}

export default function app06bReviewR2Test() {
  describe('App06bReviewR2', () => {
    // R2-04：补齐前不是「价格不可用」
    it('r2_04_pending_fill_card_shows_known_price_and_buy_enabled', 0, () => {
      expect(ProductCardMapper.PRICE_PENDING).assertEqual('client_price_pending');
      const d: ProductCardData = ProductCardMapper.fromCard(pending(',"client_price_pending":true'), new KeyTexts(), true);
      expect(d.priceUnavailable).assertFalse();
      expect(d.priceUnavailableText).assertEqual('');
      expect(d.buyState).assertEqual(BuyButtonState.NORMAL);
      // 只显示已知新价，不带口径词（不反推券后 / 售价），不给副行、不标无券
      expect(d.price.mainAmount.length > 0).assertTrue();
      expect(d.price.mainAmount.indexOf('31.9') >= 0).assertTrue();
      expect(d.price.mainLabel).assertEqual('');
      expect(d.price.subLine === null).assertTrue();
      expect(d.price.noCoupon).assertFalse();
      expect(d.buyBase).assertEqual(PriceTerms.buy);
      // 服务端明确价格不可用、或没有补齐标记的缺价卡：仍按价格不可用（BR-PRICE-01）
      const u: ProductCardData = ProductCardMapper.fromCard(
        pending(',"client_price_pending":true,"availability":"price_unavailable"'), new KeyTexts(), true);
      expect(u.priceUnavailable).assertTrue();
      expect(u.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      const plain: ProductCardData = ProductCardMapper.fromCard(pending(''), new KeyTexts(), true);
      expect(plain.priceUnavailable).assertTrue();
      // 补齐后（标记 false、三字段齐全）按券额给口径
      const filled: Record<string, Object> = pending(',"client_price_pending":false');
      filled['price_fen'] = 4190;
      filled['coupon_fen'] = 1000;
      const done: ProductCardData = ProductCardMapper.fromCard(filled, new KeyTexts(), true);
      expect(done.price.mainLabel).assertEqual(PriceTerms.afterCoupon);
    });

    // R2-07：搜索页限流期间用 buyEnabled=false 映射的同一张卡
    it('r2_07_limited_card_mapping_disables_buy_and_keeps_other_states', 0, () => {
      const ok: Record<string, Object> = pending(',"client_price_pending":false');
      ok['price_fen'] = 4190;
      ok['coupon_fen'] = 1000;
      expect(ProductCardMapper.fromCard(ok, new KeyTexts(), true).buyState).assertEqual(BuyButtonState.NORMAL);
      expect(ProductCardMapper.fromCard(ok, new KeyTexts(), false).buyState).assertEqual(BuyButtonState.DISABLED);
      // 下架仍显示「商品已下架」
      ok['availability'] = 'off_shelf';
      expect(ProductCardMapper.fromCard(ok, new KeyTexts(), false).retryText).assertEqual('<error.30141>');
    });

    // R2-08：普通改价（非 coupon_gone）补齐前不沿用旧口径
    it('r2_08_plain_price_change_unknown_coupon_has_no_label_until_filled', 0, () => {
      // 原卡无券（售价 39.90），复核新增 10 元券、新价 29.90：补齐前券额未知
      const label: string | null = PriceConfirmLabel.now('taobao', latest('null', 'null', '2990'), 2990);
      expect(label === null).assertTrue();
      expect(label === PriceTerms.salePrice).assertFalse();
      // 补齐后按新券给「券后」
      expect(PriceConfirmLabel.now('taobao', latest('3990', '1000', '2990'), 2990)).assertEqual(PriceTerms.afterCoupon);
      expect(PriceConfirmLabel.now('pdd', latest('3990', '1000', '2990'), 2990)).assertEqual(PriceTerms.pddAfterCoupon);
      // 没有最新卡也不给口径词
      expect(PriceConfirmLabel.now('taobao', null, 2990) === null).assertTrue();
    });
  });
}
