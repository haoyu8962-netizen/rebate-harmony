// F-X-05a：商品卡数据必须带平台编码（徽标按编码取图，不按显示名猜）。走生产 ProductCardMapper.fromCard。
import { describe, it, expect } from '@ohos/hypium';
import { ProductCardData, ProductCardMapper, ProductCardTexts } from '../../Index';

/** 平台名按真实中文给：编码与显示名分开，测试才能分辨「按编码取图」。 */
class NameTexts implements ProductCardTexts {
  text(key: string): string {
    const names: Map<string, string> = new Map<string, string>([
      ['platform.taobao', '淘宝'], ['platform.jd', '京东'], ['platform.pdd', '拼多多'], ['platform.tmall', '天猫']
    ]);
    return names.get(key) ?? '';
  }
}

function card(platform: string): Record<string, Object> {
  return JSON.parse('{"product_key":"x:1","item_ref":"r","platform":"' + platform + '",'
    + '"title":"t","image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"l","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00","stale":false,'
    + '"age_sec":12,"source":"union","disclaimer_keys":["price_basis"],"availability":"ok"}') as Record<string, Object>;
}

const NOW: number = Date.parse('2026-10-02T10:00:00+08:00');

export default function fx05aWiringTest() {
  describe('Fx05aWiring', () => {
    it('fx05a_card_data_default_platform_code_is_empty', 0, () => {
      expect(new ProductCardData().platformCode).assertEqual('');
    });

    it('fx05a_mapper_keeps_raw_platform_code_next_to_label', 0, () => {
      const rows: string[][] = [['taobao', '淘宝'], ['jd', '京东'], ['pdd', '拼多多'], ['tmall', '天猫'], ['xyz', '']];
      for (const row of rows) {
        const d: ProductCardData = ProductCardMapper.fromCard(card(row[0]), new NameTexts(), true, NOW);
        // 编码原样保留（pdd 不改写成 pinduoduo；未知编码不清空、不猜），图由 PlatformIconSource 再查。
        expect(d.platformCode).assertEqual(row[0]);
        expect(d.platformLabel).assertEqual(row[1]);
      }
    });
  });
}
