// APP-06b 共性第 16 条（Android R2-01）：返利从无到有、口径未知时卡片按服务端区间显示，不落入「暂无返利」。
// 卡片由 core CardPatch.apply 写成 rebate_basis=null + client_provisional_rebate=true（这里直接构造同样的 JSON）。
import { describe, it, expect } from '@ohos/hypium';
import { ProductCardData, ProductCardMapper, ProductCardTexts, RebateKind } from '../../Index';

class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    return '<' + key + '>';
  }
}

function card(json: string): Record<string, Object> {
  return JSON.parse('{"product_key":"tb:x","platform":"taobao","title":"t","price_fen":3990,"coupon_fen":1000,'
    + '"final_price_fen":2990,"est_net_price_fen":null,"rebate_min_fen":123,"rebate_max_fen":234,"benefit_tags":[],'
    + '"is_presale":false,"link_id":"l","cta":{"text_key":"btn.buy"},"availability":"ok","disclaimer_keys":["price_basis"]'
    + json + '}') as Record<string, Object>;
}

export default function app06bProvisionalTest() {
  describe('App06bProvisionalRebate', () => {
    it('provisional_rebate_shows_server_range_not_no_rebate', 0, () => {
      const d: ProductCardData = ProductCardMapper.fromCard(card(',"rebate_basis":null,"client_provisional_rebate":true'),
        new KeyTexts());
      expect(d.rebate.kind).assertEqual(RebateKind.RANGE);
      expect(d.estNet === null).assertTrue();
    });

    it('unknown_basis_without_provisional_flag_stays_no_rebate', 0, () => {
      const d: ProductCardData = ProductCardMapper.fromCard(card(',"rebate_basis":null'), new KeyTexts());
      expect(d.rebate.kind).assertEqual(RebateKind.NONE);
    });

    it('provisional_flag_ignored_once_basis_known', 0, () => {
      const d: ProductCardData = ProductCardMapper.fromCard(
        card(',"rebate_basis":"no_rebate","client_provisional_rebate":false'), new KeyTexts());
      expect(d.rebate.kind).assertEqual(RebateKind.NONE);
    });
  });
}
