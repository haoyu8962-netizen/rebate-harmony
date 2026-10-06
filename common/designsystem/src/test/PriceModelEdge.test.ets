// DS-01 补充单测：编排者裁定的异常数据处理（TODO(N-13)）与组件层规则的纯函数部分。向量之外，不改 Codex 的向量与测试。
import { describe, it, expect } from '@ohos/hypium';
import {
  BuyButtonModel, CardAmountMask, CouliFormat, EstNetModel, PriceTagContent, PriceTagModel, PriceTerms, RebateTagContent, RebateTagModel
} from '../../Index';

function kind(c: RebateTagContent): string {
  return c.kindRaw + ':' + c.text;
}

export default function priceModelEdgeTest() {
  describe('PriceModelEdge', () => {
    it('anomalies_are_no_rebate', 0, () => {
      const none: string = 'none:' + PriceTerms.noRebate;
      expect(kind(RebateTagModel.make('normal', null, 269, false))).assertEqual(none);
      expect(kind(RebateTagModel.make('price_compare_risk', 135, null, false))).assertEqual(none);
      expect(kind(RebateTagModel.make('normal', -1, 269, false))).assertEqual(none);
      expect(kind(RebateTagModel.make('price_compare_risk', 300, 200, false))).assertEqual(none);
      expect(kind(RebateTagModel.make('normal', 0, 0, false))).assertEqual(none);
      expect(kind(RebateTagModel.make('mystery', 100, 200, false))).assertEqual(none);
      expect(kind(RebateTagModel.make('no_rebate', 100, 100, false))).assertEqual(none);
    });

    it('login_first_and_unknown_only_for_amount_unknown', 0, () => {
      expect(RebateTagModel.make('normal', 269, 269, true).kindRaw).assertEqual('login');
      expect(RebateTagModel.make('amount_unknown', 100, 100, false).kindRaw).assertEqual('unknown');
    });

    it('unknown_context_and_hidden_no_suffix', 0, () => {
      const r: RebateTagContent = RebateTagModel.make('normal', 269, 269, false);
      expect(BuyButtonModel.text('B', r, false, 'poster')).assertEqual('B');
      expect(BuyButtonModel.text('B', r, true, 'list')).assertEqual('B');
      expect(BuyButtonModel.spoken('B', r, false, 'list')).assertEqual('B' + PriceTerms.comma + PriceTerms.rebate + ' 2.69 '
        + PriceTerms.yuan);
      const range: RebateTagContent = RebateTagModel.make('price_compare_risk', 123, 234, false);
      expect(BuyButtonModel.spoken('B', range, false, 'detail')).assertEqual('B' + PriceTerms.comma + PriceTerms.rebate
        + ' 1.23 ' + PriceTerms.yuan + PriceTerms.to + '2.34 ' + PriceTerms.yuan);
      expect(BuyButtonModel.spoken('B', r, true, 'detail')).assertEqual('B');
    });

    it('coupon_le_zero_is_no_coupon_and_only_pdd_prefixed', 0, () => {
      const neg: PriceTagContent = PriceTagModel.make('taobao', 1000, -5, 1000, false);
      expect(neg.noCoupon).assertTrue();
      expect(neg.mainLabel).assertEqual(PriceTerms.salePrice);
      expect(PriceTagModel.make('jd', 1000, 100, 900, false).mainLabel).assertEqual(PriceTerms.afterCoupon);
      expect(PriceTagModel.make('taobao', 1000, 0, 1000, true).presaleLabel).assertEqual(PriceTerms.presale);
    });

    it('est_net_null_and_invalid_date', 0, () => {
      expect(EstNetModel.make('normal', 100, null) === null).assertTrue();
      expect(CouliFormat.dateOnly('2026-13-xx', 1790647200000)).assertEqual('2026-13-xx');
    });

    it('range_breaks_only_at_dash', 0, () => {
      const r: RebateTagContent = RebateTagModel.make('price_compare_risk', 8888888, 9999999, false);
      expect(r.amountParts.length).assertEqual(2);
      expect(r.amountParts[0]).assertEqual('¥88888.88');
      expect(r.amountParts[1]).assertEqual(PriceTerms.rangeDash + '¥99999.99');
    });

    it('date_only_rejects_nonexistent_dates', 0, () => {
      const now: number = 1790647200000; // 2026 年（上海）
      expect(CouliFormat.dateOnly('2026-02-29', now)).assertEqual('2026-02-29');
      expect(CouliFormat.dateOnly('2026-13-01', now)).assertEqual('2026-13-01');
      expect(CouliFormat.dateOnly('2026-00-00', now)).assertEqual('2026-00-00');
      expect(CouliFormat.dateOnly('2026-04-31', now)).assertEqual('2026-04-31');
      expect(CouliFormat.dateOnly('2026-06-00', now)).assertEqual('2026-06-00');
      expect(CouliFormat.dateOnly('2026-12-31', now)).assertEqual('12-31');
      expect(CouliFormat.dateOnly('2026-02-28', now)).assertEqual('02-28');
      expect(CouliFormat.dateOnly('2024-02-29', now)).assertEqual('2024-02-29');
      expect(CouliFormat.dateOnly('2000-02-29', now)).assertEqual('2000-02-29');
      // 2100 不是闰年：非法日期原样返回（与合法跨年日期的输出相同形态，另用同年验证）。
      const now2100: number = Date.UTC(2100, 5, 1);
      expect(CouliFormat.dateOnly('2100-02-29', now2100)).assertEqual('2100-02-29');
      expect(CouliFormat.dateOnly('2100-02-28', now2100)).assertEqual('02-28');
      const now2028: number = Date.UTC(2028, 5, 1);
      expect(CouliFormat.dateOnly('2028-02-29', now2028)).assertEqual('02-29');
    });

    it('card_amount_hidden_exposes_no_amount', 0, () => {
      const single: RebateTagContent = RebateTagModel.make('normal', 269, 269, false);
      const range: RebateTagContent = RebateTagModel.make('price_compare_risk', 135, 269, false);
      for (const r of [single, range]) {
        const m: RebateTagContent = CardAmountMask.rebate(r, true);
        expect(m.kindRaw).assertEqual(r.kindRaw);
        expect(m.text).assertEqual(PriceTerms.rebate + ' ' + PriceTerms.amountMask);
        expect(m.amountParts.join('')).assertEqual(PriceTerms.amountMask);
        expect(m.spokenText).assertEqual(PriceTerms.rebate + PriceTerms.comma + PriceTerms.amountHiddenSpoken);
        expect(m.text.indexOf('2.69') < 0 && m.spokenText.indexOf('2.69') < 0).assertTrue();
        expect(m.text.indexOf('1.35') < 0 && m.spokenText.indexOf('1.35') < 0).assertTrue();
        for (const ctx of ['list', 'agent', 'detail']) {
          expect(BuyButtonModel.text('B', r, true, ctx)).assertEqual('B');
          expect(BuyButtonModel.spoken('B', r, true, ctx)).assertEqual('B');
        }
        expect(CardAmountMask.rebate(r, false) === r).assertTrue();
      }
      expect(CardAmountMask.estNet('E', true) === null).assertTrue();
      expect(CardAmountMask.estNet('E', false)).assertEqual('E');
      for (const r of [RebateTagModel.make('no_rebate', 0, 0, false), RebateTagModel.make('amount_unknown', 0, 0, false),
        RebateTagModel.make('normal', 269, 269, true)]) {
        expect(CardAmountMask.rebate(r, true) === r).assertTrue();
      }
    });

    it('retry_later_text', 0, () => {
      expect(BuyButtonModel.retryText('')).assertEqual(PriceTerms.retryLater);
      expect(BuyButtonModel.retryText('X')).assertEqual('X');
    });

    it('spoken_money', 0, () => {
      expect(CouliFormat.moneySpoken(-150)).assertEqual(PriceTerms.minus + '1.5 ' + PriceTerms.yuan);
      expect(CouliFormat.rebateRangeSpoken(0, 0) === null).assertTrue();
    });
  });
}
