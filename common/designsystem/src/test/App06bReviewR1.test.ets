// APP-06b 鸿蒙评审第 1 轮（harmony-review-r1.md）：R1-05 券失效确认框的价格口径、R1-07 下架卡按钮置灰、R1-09 弹层大屏限宽。
import { describe, it, expect } from '@ohos/hypium';
import {
  BuyButtonState, CouliLayout, CouliSpacing, PriceConfirmLabel, PriceTerms, ProductCardData, ProductCardMapper,
  ProductCardTexts
} from '../../Index';

class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    return '<' + key + '>';
  }
}

function card(json: string): Record<string, Object> {
  return JSON.parse('{"product_key":"tb:x","platform":"taobao","title":"t","price_fen":3990,"coupon_fen":1000,'
    + '"final_price_fen":2990,"est_net_price_fen":2721,"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal",'
    + '"benefit_tags":[],"is_presale":false,"link_id":"l","cta":{"text_key":"btn.buy.coupon"},"disclaimer_keys":["price_basis"]'
    + json + '}') as Record<string, Object>;
}

function latest(price: string, coupon: string, final: string): Record<string, Object> {
  return JSON.parse('{"price_fen":' + price + ',"coupon_fen":' + coupon + ',"final_price_fen":' + final + '}') as
  Record<string, Object>;
}

export default function app06bReviewR1Test() {
  describe('App06bReviewR1', () => {
    // R1-05：coupon_gone 不等于无券
    it('r1_05_coupon_gone_unknown_coupon_has_no_sale_price_label', 0, () => {
      const label: string | null = PriceConfirmLabel.now('taobao', latest('null', 'null', '2990'), 2990);
      expect(label === null).assertTrue();
      expect(label === PriceTerms.salePrice).assertFalse();
    });

    it('r1_05_coupon_gone_with_new_coupon_is_after_coupon_and_without_coupon_is_sale_price', 0, () => {
      expect(PriceConfirmLabel.now('taobao', latest('3490', '500', '2990'), 2990))
        .assertEqual(PriceTerms.afterCoupon);
      expect(PriceConfirmLabel.now('taobao', latest('2990', '0', '2990'), 2990))
        .assertEqual(PriceTerms.salePrice);
      expect(PriceConfirmLabel.now('pdd', latest('2990', '0', '2990'), 2990))
        .assertEqual(PriceTerms.pddPrice);
      // 最新卡的券后价与弹窗新价不一致（不是同一次结果）：不用它定口径
      expect(PriceConfirmLabel.now('taobao', latest('2990', '0', '2990'), 3190) === null)
        .assertTrue();
      // 普通改价且券额未知：第 2 轮 R2-08 起同样不带口径词（见 App06bReviewR2.test）
      expect(PriceConfirmLabel.now('taobao', latest('null', 'null', '3190'), 3190) === null).assertTrue();
    });

    // R1-07：下架卡置灰、其它卡照常
    it('r1_07_off_shelf_card_buy_button_disabled_with_off_shelf_text', 0, () => {
      const off: ProductCardData = ProductCardMapper.fromCard(card(',"availability":"off_shelf"'), new KeyTexts(), true);
      expect(off.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      expect(off.retryText).assertEqual('<error.30141>');
      const ok: ProductCardData = ProductCardMapper.fromCard(card(',"availability":"ok"'), new KeyTexts(), true);
      expect(ok.buyState).assertEqual(BuyButtonState.NORMAL);
      // 平台 not_launched 时下架仍优先显示「商品已下架」
      const both: ProductCardData = ProductCardMapper.fromCard(card(',"availability":"off_shelf"'), new KeyTexts(), true,
        Date.now(), 'not_launched');
      expect(both.retryText).assertEqual('<error.30141>');
    });

    // R1-09：弹层内容在大屏限宽
    it('r1_09_dialog_content_width_capped_on_large_screens', 0, () => {
      expect(CouliLayout.dialogContentWidth(360, CouliSpacing.space6)).assertEqual(360 - 2 * CouliSpacing.space6);
      expect(CouliLayout.dialogContentWidth(840, 0)).assertEqual(CouliLayout.maxContentWidth);
      expect(CouliLayout.dialogContentWidth(1280, CouliSpacing.space6)).assertEqual(CouliLayout.maxContentWidth);
      expect(CouliLayout.dialogContentWidth(0, CouliSpacing.space6)).assertEqual(0);
    });
  });
}
