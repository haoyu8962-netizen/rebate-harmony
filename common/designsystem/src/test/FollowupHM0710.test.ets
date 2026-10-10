// FU-HM-0710（APP-07 共性第 32 条）：剪贴板多卡弹层 / 单卡的商品卡复用搜索卡的同一映射，按卡片自己的平台取购买状态。
// 旧逻辑：剪贴板行直接 fromCard(card, texts)（购买状态缺省 on）——not_launched 仍显示返利与预估返后、维护时购买按钮可点。
import { describe, it, expect } from '@ohos/hypium';
import { BuyButtonState, ProductCardData, ProductCardMapper, ProductCardTexts } from '../../Index';

class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    return '<' + key + '>';
  }
}

function card(platform: string): Record<string, Object> {
  return JSON.parse('{"product_key":"x:1","item_ref":"r","platform":"' + platform + '","title":"t","image":null,'
    + '"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,"rebate_min_fen":269,'
    + '"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,"link_id":"l",'
    + '"cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00","availability":"ok",'
    + '"disclaimer_keys":["price_basis","rebate_estimate"]}') as Record<string, Object>;
}

export default function followupHM0710Test() {
  describe('FollowupHM0710_ClipboardPurchaseStatus', () => {
    it('APP07_32_card_rows_apply_platform_purchase_status', 0, () => {
      const statuses: Map<string, string> = new Map<string, string>();
      statuses.set('taobao', 'not_launched');
      statuses.set('jd', 'maintenance');
      const statusOf: (p: string) => string = (p: string): string => statuses.get(p) ?? ProductCardMapper.PURCHASE_ON;
      const now: number = Date.parse('2026-10-02T10:00:00+08:00');
      // not_launched：隐藏返利、预估返后（含读屏金额），按钮禁用
      const tb: ProductCardData = ProductCardMapper.fromCardWithStatus(card('taobao'), new KeyTexts(), true, statusOf, now);
      expect(tb.rebateHidden).assertTrue();
      expect(tb.estNet).assertNull();
      expect(tb.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      // maintenance：返利照常，购买禁用（「稍后再试」）
      const jd: ProductCardData = ProductCardMapper.fromCardWithStatus(card('jd'), new KeyTexts(), true, statusOf, now);
      expect(jd.rebateHidden).assertFalse();
      expect(jd.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      // on：与搜索卡相同
      const pdd: ProductCardData = ProductCardMapper.fromCardWithStatus(card('pdd'), new KeyTexts(), true, statusOf, now);
      expect(pdd.buyState).assertEqual(BuyButtonState.NORMAL);
      expect(pdd.estNet !== null).assertTrue();
      // 配置变化后重新映射即同步（调用方订阅变化后重建行）
      statuses.set('taobao', ProductCardMapper.PURCHASE_ON);
      const tb2: ProductCardData = ProductCardMapper.fromCardWithStatus(card('taobao'), new KeyTexts(), true, statusOf, now);
      expect(tb2.rebateHidden).assertFalse();
      expect(tb2.buyState).assertEqual(BuyButtonState.NORMAL);
    });
  });
}
