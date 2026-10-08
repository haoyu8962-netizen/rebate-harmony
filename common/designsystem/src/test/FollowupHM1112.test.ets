// FU-HM-1112：APP-06a 共性第 13、14、21、22、25、27、30 条在 DesignSystem 一侧的回归测试。只新增，不改已有向量与测试。
import { describe, it, expect } from '@ohos/hypium';
import {
  BuyButtonState, PriceTerms, ProductCardA11y, ProductCardData, ProductCardMapper, ProductCardTexts, SearchDisclaimers
} from '../../Index';

/** 草稿表的替身：只认契约里的 platform_coming_soon 与平台名，其余键原样加尖括号。 */
class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    if (key === 'platform_coming_soon') {
      return '{platform_name}返利即将开放';
    }
    if (key === 'platform.jd') {
      return '京东';
    }
    return '<' + key + '>';
  }
}

function card(overrides: string): Record<string, Object> {
  const base: Record<string, Object> = JSON.parse(BASE_JSON) as Record<string, Object>;
  return merge(base, overrides);
}

const BASE_JSON: string = '{"product_key":"tb:x","item_ref":"r","platform":"taobao",'
  + '"title":"t","image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
  + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
  + '"link_id":"l","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00","stale":false,'
  + '"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis","rebate_estimate"],"availability":"ok"}';

function merge(base: Record<string, Object>, overrides: string): Record<string, Object> {
  const extra: Record<string, Object> = JSON.parse('{' + overrides + '}') as Record<string, Object>;
  Object.keys(extra).forEach((k: string) => {
    base[k] = extra[k];
  });
  return base;
}

const COMPARE: string = '"rebate_basis":"price_compare_risk","rebate_min_fen":56,"rebate_max_fen":112,'
  + '"disclaimer_keys":["price_basis","rebate_compare"]';

export default function followupHM1112Test() {
  describe('FollowupHM1112DesignSystem', () => {
    // ---------------------------------------------------------------- 第 13、25 条：页底说明的选句
    it('item13_normal_card_keeps_rebate_estimate_even_when_mixed_with_compare_cards', 0, () => {
      const items: Record<string, Object>[] = [card(COMPARE), card('"product_key":"tb:y"')];
      const keys: string[] = SearchDisclaimers.keys(items);
      expect(JSON.stringify(keys)).assertEqual('["price_basis","rebate_compare","rebate_estimate"]');
      const lines: string[] = SearchDisclaimers.lines(items, new KeyTexts());
      expect(lines.indexOf(PriceTerms.rebateEstimate) >= 0).assertTrue();
    });

    it('item13_normal_card_without_server_key_gets_rebate_estimate_fallback', 0, () => {
      const items: Record<string, Object>[] = [card('"disclaimer_keys":["price_basis"]')];
      expect(JSON.stringify(SearchDisclaimers.keys(items))).assertEqual('["price_basis","rebate_estimate"]');
    });

    it('item25_pure_compare_range_cards_use_only_rebate_compare', 0, () => {
      const items: Record<string, Object>[] = [card(COMPARE), card(COMPARE + ',"product_key":"tb:z"')];
      const keys: string[] = SearchDisclaimers.keys(items);
      expect(JSON.stringify(keys)).assertEqual('["price_basis","rebate_compare"]');
      expect(SearchDisclaimers.lines(items, new KeyTexts()).indexOf(PriceTerms.rebateEstimate)).assertEqual(-1);
    });

    it('item13_mixed_coupon_and_no_coupon_merges_price_sentence_but_keeps_rebate_sentence', 0, () => {
      const items: Record<string, Object>[] = [card(''),
        card('"coupon_fen":0,"final_price_fen":3990,"disclaimer_keys":["price_basis.general","rebate_estimate"]')];
      const keys: string[] = SearchDisclaimers.keys(items);
      expect(JSON.stringify(keys)).assertEqual('["rebate_estimate","price_basis.general"]');
    });

    // ---------------------------------------------------------------- 第 14、21 条：按可见卡片选句，没有可见卡片时保留
    it('item14_visible_rows_pick_cards_and_empty_view_keeps_previous_lines', 0, () => {
      const a: Record<string, Object> = card(COMPARE);
      const b: Record<string, Object> = card('"product_key":"tb:y"');
      const rows: (Record<string, Object> | null)[] = [null, a, b, null];
      const first: Record<string, Object>[] | null = SearchDisclaimers.visible(rows, 0, 1);
      expect(first !== null && first.length === 1 && first[0] === a).assertTrue();
      const both: Record<string, Object>[] | null = SearchDisclaimers.visible(rows, 1, 3);
      expect(both !== null && both.length === 2).assertTrue();
      // 只看到页尾（或被详情盖住）：null = 保留上一次的句子。
      expect(SearchDisclaimers.visible(rows, 3, 3)).assertNull();
      expect(SearchDisclaimers.visible([], 0, 5)).assertNull();
      // 预留高度按全部已加载结果：可见集合的句子一定是它的子集（高度不随可见卡片来回变化）。
      const reserve: string[] = SearchDisclaimers.lines([a, b], new KeyTexts());
      for (const line of SearchDisclaimers.lines([a], new KeyTexts())) {
        expect(reserve.indexOf(line) >= 0).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 第 22 条：商品图接 image 字段
    it('item22_image_field_is_used_and_placeholder_only_when_empty_loading_or_failed', 0, () => {
      const withImage: ProductCardData = ProductCardMapper.fromCard(card('"image":"https://img.example.invalid/a.png"'),
        new KeyTexts());
      expect(withImage.imageUrl).assertEqual('https://img.example.invalid/a.png');
      expect(ProductCardMapper.fromCard(card(''), new KeyTexts()).imageUrl).assertEqual('');
      expect(ProductCardMapper.fromCard(card('"image":"  "'), new KeyTexts()).imageUrl).assertEqual('');
      expect(ProductCardA11y.showsPlaceholder('', false, false)).assertTrue();
      expect(ProductCardA11y.showsPlaceholder('u', false, false)).assertTrue();
      expect(ProductCardA11y.showsPlaceholder('u', true, false)).assertFalse();
      expect(ProductCardA11y.showsPlaceholder('u', true, true)).assertTrue();
    });

    // ---------------------------------------------------------------- 第 27 条：按 platform_status 展示购买按钮
    it('item27_card_buy_button_follows_platform_purchase_status', 0, () => {
      const on: ProductCardData = ProductCardMapper.fromCard(card('"platform":"jd"'), new KeyTexts(), true, Date.now(), 'on');
      expect(on.buyState).assertEqual(BuyButtonState.NORMAL);
      const maintenance: ProductCardData = ProductCardMapper.fromCard(card('"platform":"jd"'), new KeyTexts(), true,
        Date.now(), 'maintenance');
      expect(maintenance.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      expect(maintenance.retryText).assertEqual('');
      const soon: ProductCardData = ProductCardMapper.fromCard(card('"platform":"jd"'), new KeyTexts(), true, Date.now(),
        'not_launched');
      expect(soon.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      expect(soon.retryText).assertEqual('京东返利即将开放');
      // 价格不可用优先（BR-PRICE-01 的「稍后再试」）。
      const noPrice: ProductCardData = ProductCardMapper.fromCard(card('"platform":"jd","final_price_fen":null'),
        new KeyTexts(), true, Date.now(), 'not_launched');
      expect(noPrice.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      expect(noPrice.retryText).assertEqual('');
    });

    // ---------------------------------------------------------------- 第 31 条：not_launched 隐藏返利与预估返后
    it('item31_not_launched_hides_rebate_amounts_and_keeps_price', 0, () => {
      const d: ProductCardData = ProductCardMapper.fromCard(card(COMPARE + ',"platform":"jd"'), new KeyTexts(), true,
        Date.now(), 'not_launched');
      expect(d.rebateHidden).assertTrue();
      expect(d.rebate.hasAmount).assertFalse();
      expect(d.estNet).assertNull();
      expect(d.disclaimerPrefix).assertEqual('');
      expect(d.disclaimerLines.indexOf(PriceTerms.rebateCompare)).assertEqual(-1);
      expect(d.disclaimerLines.indexOf(PriceTerms.priceBasis) >= 0).assertTrue();
      // 商品价格照留，按钮禁用。
      expect(d.price.mainAmount.length > 0).assertTrue();
      expect(d.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      // 维护中只禁用按钮，返利照常显示。
      const m: ProductCardData = ProductCardMapper.fromCard(card(COMPARE), new KeyTexts(), true, Date.now(), 'maintenance');
      expect(m.rebateHidden).assertFalse();
      expect(m.rebate.hasAmount).assertTrue();
      // 页底说明：这张卡只贡献价格句。
      const items: Record<string, Object>[] = [card('"platform":"jd"')];
      expect(JSON.stringify(SearchDisclaimers.keys(items, (_i: Record<string, Object>): boolean => true)))
        .assertEqual('["price_basis"]');
    });

    // ---------------------------------------------------------------- 第 30 条：详情标题的读屏角色
    it('item30_detail_title_is_heading_and_list_title_is_not', 0, () => {
      expect(ProductCardA11y.titleIsHeading(true)).assertTrue();
      expect(ProductCardA11y.titleIsHeading(false)).assertFalse();
    });
  });
}
