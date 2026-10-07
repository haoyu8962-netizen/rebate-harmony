// APP-06a 鸿蒙第 1 轮评审（harmony-review-r1.md）在 DesignSystem 一侧的复现测试：
// R1-01 价格缺失不补 0（ProductCardMapper / ProductCardData）；R1-03 取价处的降级提示；R1-05 口径说明弹层（DisclaimerNote）。
// 只新增，不改 DS-01 已有的向量与测试。
import { describe, it, expect } from '@ohos/hypium';
import {
  BuyButtonState, CouliDialogOptions, DisclaimerNote, PriceTerms, ProductCardData, ProductCardKeys, ProductCardMapper,
  ProductCardTexts
} from '../../Index';

/** 草稿表的替身：键原样加前缀返回，便于断言用了哪个键。 */
class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    return '<' + key + '>';
  }
}

function card(overrides: string): Record<string, Object> {
  const base: Record<string, Object> = JSON.parse('{"product_key":"tb:x","item_ref":"r","platform":"taobao",'
    + '"title":"t","image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"l","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00","stale":false,'
    + '"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis","rebate_estimate"],"availability":"ok"}'
  ) as Record<string, Object>;
  const extra: Record<string, Object> = JSON.parse(overrides) as Record<string, Object>;
  Object.keys(extra).forEach((k: string) => {
    base[k] = extra[k];
  });
  return base;
}

/** 卡上一切会显示的金额文字（价格、副行、预估返后、取价行、按钮基础文字）。 */
function shownMoney(d: ProductCardData): string {
  return [d.price.mainAmount, d.price.subLine ?? '', d.price.spokenMain, d.estNet ?? '', d.quoteTime].join('|');
}

const NOW: number = Date.parse('2026-10-02T10:00:00+08:00');

export default function productCardMapperR1Test() {
  describe('ProductCardMapperR1', () => {
    it('r1_01_null_final_price_is_unknown_not_zero', 0, () => {
      // 评审场景：final_price_fen=null，availability 不是 price_unavailable，rebate_basis 不是 amount_unknown。
      const d: ProductCardData = ProductCardMapper.fromCard(card('{"final_price_fen":null}'), new KeyTexts(), true, NOW);
      expect(d.priceUnavailable).assertTrue();
      expect(shownMoney(d).indexOf('¥0') < 0).assertTrue();
      expect(d.price.mainAmount).assertEqual('');
      expect(d.price.mainLabel).assertEqual('');
      expect(d.estNet).assertNull();
      expect(d.quoteTime).assertEqual('');
      expect(d.priceUnavailableText).assertEqual('<' + ProductCardKeys.PRICE_UNAVAILABLE + '>');
      // 价格不可用：按钮「稍后再试」（禁用），即使调用方给了可点。
      expect(d.buyState).assertEqual(BuyButtonState.RETRY_LATER);
    });

    it('r1_01_availability_price_unavailable_hides_all_amounts', 0, () => {
      const d: ProductCardData = ProductCardMapper.fromCard(card('{"availability":"price_unavailable","price_fen":null,'
        + '"coupon_fen":null,"final_price_fen":null,"est_net_price_fen":null,"rebate_min_fen":null,'
        + '"rebate_max_fen":null,"link_id":null}'), new KeyTexts(), false, NOW);
      expect(d.priceUnavailable).assertTrue();
      expect(shownMoney(d).indexOf('¥') < 0).assertTrue();
      expect(d.buyState).assertEqual(BuyButtonState.RETRY_LATER);
      // 字段齐全但服务端标了 price_unavailable：同样不显示金额。
      const marked: ProductCardData = ProductCardMapper.fromCard(card('{"availability":"price_unavailable"}'),
        new KeyTexts(), true, NOW);
      expect(marked.priceUnavailable).assertTrue();
      expect(shownMoney(marked).indexOf('¥') < 0).assertTrue();
    });

    it('r1_01_missing_coupon_or_price_is_unknown', 0, () => {
      expect(ProductCardMapper.fromCard(card('{"coupon_fen":null}'), new KeyTexts(), true, NOW).priceUnavailable)
        .assertTrue();
      expect(ProductCardMapper.fromCard(card('{"price_fen":null}'), new KeyTexts(), true, NOW).priceUnavailable)
        .assertTrue();
      const ok: ProductCardData = ProductCardMapper.fromCard(card('{}'), new KeyTexts(), true, NOW);
      expect(ok.priceUnavailable).assertFalse();
      expect(ok.price.mainAmount).assertEqual('¥29.9');
      expect(ok.buyState).assertEqual(BuyButtonState.NORMAL);
    });

    it('r1_01_amount_unknown_keeps_its_own_state_without_zero_price', 0, () => {
      const d: ProductCardData = ProductCardMapper.fromCard(card('{"rebate_basis":"amount_unknown","price_fen":null,'
        + '"coupon_fen":null,"final_price_fen":null,"est_net_price_fen":null,"rebate_min_fen":null,'
        + '"rebate_max_fen":null,"cta":{"text_key":"btn.buy"},"availability":"unknown"}'), new KeyTexts(), true, NOW);
      expect(d.priceUnavailable).assertFalse();
      expect(d.rebate.kindRaw).assertEqual('unknown');
      expect(d.price.mainAmount).assertEqual('');
      expect(d.buyState).assertEqual(BuyButtonState.NORMAL);
    });

    it('r1_03_stale_quote_gets_price_change_note', 0, () => {
      const stale: ProductCardData = ProductCardMapper.fromCard(card('{"stale":true,"age_sec":2160,'
        + '"quoted_at":"2026-10-02T09:30:00+08:00"}'), new KeyTexts(), true, NOW);
      expect(stale.priceStale).assertTrue();
      expect(stale.quoteTime.indexOf(PriceTerms.quoted) === 0).assertTrue();
      expect(stale.quoteTime.endsWith(PriceTerms.separator + '<' + ProductCardKeys.PRICE_STALE + '>')).assertTrue();
      // age > 300 即使 stale=false 也提示；正好 300 不提示（BR-PRICE-11 边界）。
      expect(ProductCardMapper.fromCard(card('{"age_sec":301}'), new KeyTexts(), true, NOW).priceStale).assertTrue();
      const fresh: ProductCardData = ProductCardMapper.fromCard(card('{"age_sec":300}'), new KeyTexts(), true, NOW);
      expect(fresh.priceStale).assertFalse();
      expect(fresh.quoteTime.indexOf(ProductCardKeys.PRICE_STALE) < 0).assertTrue();
    });

    it('r1_05_card_info_opens_full_text_note', 0, () => {
      const d: ProductCardData = ProductCardMapper.fromCard(card('{"rebate_basis":"price_compare_risk",'
        + '"rebate_min_fen":0,"disclaimer_keys":["price_basis","rebate_compare"]}'), new KeyTexts(), true, NOW);
      expect(d.disclaimerTitle).assertEqual('<' + ProductCardKeys.DISCLAIMER_TITLE + '>');
      expect(d.disclaimerCloseText).assertEqual('<' + ProductCardKeys.DISCLAIMER_CLOSE + '>');
      // 卡片 i 点开的是说明弹层（不是不换行的气泡）：正文是全部说明行，长句完整保留（含「以下单页为准」结尾）。
      expect(DisclaimerNote.available(d.disclaimerTitle, d.disclaimerLines, d.disclaimerCloseText)).assertTrue();
      const o: CouliDialogOptions = DisclaimerNote.options(d.disclaimerTitle, d.disclaimerLines, d.disclaimerCloseText,
        'couli-disclaimer-info-7');
      expect(o.message).assertEqual(PriceTerms.priceBasis + '\n' + PriceTerms.rebateCompare);
      expect(o.message.endsWith('以下单页为准\n' + PriceTerms.rebateCompare)).assertTrue();
      expect(o.title).assertEqual(d.disclaimerTitle);
      expect(o.primaryText).assertEqual(d.disclaimerCloseText);
      expect(o.returnFocusId).assertEqual('couli-disclaimer-info-7');
      expect(o.dismissOnMask).assertTrue();
      // 缺标题或关闭文字时退回 DS-01 原气泡（目录页等未给弹层文案的调用方行为不变）。
      expect(DisclaimerNote.available('', d.disclaimerLines, 'x')).assertFalse();
      expect(DisclaimerNote.available('x', [], 'x')).assertFalse();
    });
  });
}
