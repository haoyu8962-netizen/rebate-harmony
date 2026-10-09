// FU-HM-0607：APP-06b 共性第 45、47 条——返利归零弹窗不得在新价不同时写「价格没有变化」，价格口径未知时一律中性写法（三端同名键）。
import { describe, it, expect } from '@ohos/hypium';
import { PriceConfirmLine, PriceConfirmText, PriceTerms } from '../../Index';

function prices(price: string, coupon: string, final: string): Record<string, Object> {
  return JSON.parse('{"price_fen":' + price + ',"coupon_fen":' + coupon + ',"final_price_fen":' + final + '}') as
  Record<string, Object>;
}

function money(fen: number): string {
  return '¥' + (fen / 100).toFixed(1);
}

/** 文案字典的替身：键 + 变量原样拼出，便于断言。 */
function render(l: PriceConfirmLine): string {
  let out: string = '<' + l.key;
  l.vars.forEach((v: string, k: string) => {
    out += ' ' + k + '=' + v;
  });
  return out + '>';
}

function body(oldFen: number | null, newFen: number | null, before: Record<string, Object> | null,
  latest: Record<string, Object> | null): string {
  return render(PriceConfirmText.rebateGoneBody('taobao', oldFen, newFen, before, latest, money, render));
}

export default function followupHM0607Test() {
  describe('FollowupHM0607Design', () => {
    it('l45_new_price_different_below_threshold_uses_body_changed', 0, () => {
      // 原价 29.90、新价 30.80（涨幅未达阈值，price_changed=false），返利归零
      const known: string = body(2990, 3080, prices('3990', '1000', '2990'), prices('4080', '1000', '3080'));
      expect(known).assertEqual('<trade.rebate_gone.body_changed price=¥30.8 price_now=<trade.price_changed.now price_label='
        + PriceTerms.afterCoupon + '>>');
      expect(known.indexOf('trade.rebate_gone.body ') < 0).assertTrue();
      // 新价口径未补齐：「现在」不带口径词
      expect(body(2990, 3080, prices('3990', '1000', '2990'), prices('null', 'null', '3080')))
        .assertEqual('<trade.rebate_gone.body_changed price=¥30.8 price_now=<trade.price_changed.now_plain>>');
      // 新价未知：只写「继续购买不会获得返利」
      expect(body(2990, null, prices('3990', '1000', '2990'), null)).assertEqual('<trade.rebate_gone.note>');
    });

    it('l45_same_price_keeps_unchanged_body_with_known_basis', 0, () => {
      expect(body(2990, 2990, prices('3990', '1000', '2990'), null))
        .assertEqual('<trade.rebate_gone.body price=¥29.9 price_label=' + PriceTerms.afterCoupon + '>');
      // 原卡口径未知但补齐后的新卡已知（同一金额）：按新卡
      expect(body(2990, 2990, prices('null', 'null', '2990'), prices('2990', '0', '2990')))
        .assertEqual('<trade.rebate_gone.body price=¥29.9 price_label=' + PriceTerms.salePrice + '>');
    });

    it('l47_unknown_basis_never_defaults_to_after_coupon', 0, () => {
      // 同价归零、口径都未知（补齐失败后再次购买）：不写「券后」
      const plain: string = body(3290, 3290, prices('null', 'null', '3290'), prices('null', 'null', '3290'));
      expect(plain).assertEqual('<trade.rebate_gone.body_plain price=¥32.9>');
      expect(plain.indexOf(PriceTerms.afterCoupon) < 0).assertTrue();
      // 改价确认框「之前」一行：原卡口径未知用 before_plain，已知才带口径词
      expect(render(PriceConfirmText.before('taobao', prices('null', 'null', '3290'))))
        .assertEqual('<trade.price_changed.before_plain>');
      expect(render(PriceConfirmText.before('taobao', prices('3990', '1000', '2990'))))
        .assertEqual('<trade.price_changed.before price_label=' + PriceTerms.afterCoupon + '>');
      expect(render(PriceConfirmText.now('taobao', prices('null', 'null', '3290'), 3290)))
        .assertEqual('<trade.price_changed.now_plain>');
    });
  });
}
