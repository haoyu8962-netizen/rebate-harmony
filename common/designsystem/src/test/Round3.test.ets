// DS-01 第 3 轮评审补测：R2-01（数字格金额项必须带不可拆段、320vp + 130% 纵排）与 R2-02（PriceTag 预售标签与说明）。
import { describe, it, expect } from '@ohos/hypium';
import {
  AmountGridItem, AmountGridLayout, AmountTone, CouliChipTone, CouliFormat, PresaleDisplay, PriceTagContent,
  PriceTagModel, PriceTerms, ProductCardTags, ProductTag
} from '../../Index';

/** 320vp 屏宽 − 页面左右各 16 − 卡片左右各 16（GUIDE §7.2 钱包页）。 */
const GRID_320: number = 320 - 2 * 16 - 2 * 16;

function labels(tags: ProductTag[]): string {
  return tags.map((t: ProductTag) => t.label).join('|');
}

export default function round3Test() {
  describe('Round3AmountGrid', () => {
    it('money_and_range_items_carry_segments', 0, () => {
      const m: AmountGridItem = AmountGridItem.money('a', 9999999);
      expect(m.value).assertEqual(CouliFormat.money(9999999));
      expect(m.segments.join('|')).assertEqual(CouliFormat.money(9999999));
      expect(m.maskable).assertTrue();
      const r: AmountGridItem = AmountGridItem.range('b', 123, 234, AmountTone.REBATE);
      expect(r.segments.join('|')).assertEqual(CouliFormat.money(123) + '|' + PriceTerms.rangeDash
        + CouliFormat.money(234));
      expect(r.spoken).assertEqual(CouliFormat.rebateRangeSpoken(123, 234));
      // 0 元返利格不用返利橙。
      expect(AmountGridItem.money('c', 0, AmountTone.REBATE).tone).assertEqual(AmountTone.NORMAL);
    });

    it('text_items_are_not_amounts', 0, () => {
      const t: AmountGridItem = AmountGridItem.text('a', 'x y');
      expect(t.maskable).assertFalse();
      expect(t.segments.length).assertEqual(0);
      // 文字里万一带金额，含「¥」的词仍参与测量。
      expect(AmountGridItem.text('a', 'x ¥99999.99').segments.join('|')).assertEqual('¥99999.99');
      // 小字里的金额也参与测量。
      expect(AmountGridItem.money('a', 5678, AmountTone.REBATE, '', 'n ' + CouliFormat.money(3456))
        .noteSegments.join('|')).assertEqual(CouliFormat.money(3456));
      // 区间异常按「暂无返利」文字格。
      const none: AmountGridItem = AmountGridItem.range('b', 0, 0);
      expect(none.value).assertEqual(PriceTerms.noRebate);
      expect(none.maskable).assertFalse();
    });

    it('stacks_at_320vp_130pct_99999_99', 0, () => {
      const items: AmountGridItem[] = [AmountGridItem.money('a', 9999999), AmountGridItem.money('b', 9999999)];
      // 不给测量函数（本机单测无 UI 上下文）：按等宽字宽估算下限判断。
      expect(AmountGridLayout.shouldStack(items, GRID_320, 1.3, true, false, false)).assertTrue();
      // 测量函数返回 0 或抛错（measureText 失败）也不能当成放得下。
      expect(AmountGridLayout.shouldStack(items, GRID_320, 1.3, true, false, false,
        (_t: string, _s: number, _w: number): number => 0)).assertTrue();
      expect(AmountGridLayout.shouldStack(items, GRID_320, 1.3, true, false, false,
        (_t: string, _s: number, _w: number): number => {
          throw new Error('no measure');
        })).assertTrue();
      // 区间格同样。
      const mixed: AmountGridItem[] = [AmountGridItem.money('a', 9999999),
        AmountGridItem.range('b', 8888888, 9999999, AmountTone.REBATE)];
      expect(AmountGridLayout.shouldStack(mixed, GRID_320, 1.3, true, false, false)).assertTrue();
    });

    it('short_amounts_stay_side_by_side_below_200pct', 0, () => {
      const items: AmountGridItem[] = [AmountGridItem.money('a', 5678), AmountGridItem.text('b', 'x')];
      expect(AmountGridLayout.shouldStack(items, GRID_320, 1, true, false, false)).assertFalse();
      expect(AmountGridLayout.shouldStack(items, GRID_320, 1.3, true, false, false)).assertFalse();
      // 200% 一律纵排。
      expect(AmountGridLayout.shouldStack(items, GRID_320, 2, true, false, false)).assertTrue();
      // 宽度未知时先横排（onAreaChange 后重算）。
      expect(AmountGridLayout.shouldStack([AmountGridItem.money('a', 9999999), AmountGridItem.money('b', 9999999)],
        0, 1.3, true, false, false)).assertFalse();
      // 金额隐藏：只量「****」。
      expect(AmountGridLayout.shouldStack([AmountGridItem.money('a', 9999999), AmountGridItem.money('b', 9999999)],
        GRID_320, 1.3, true, false, true)).assertFalse();
    });

    it('wallet_hero_items_use_factories', 0, () => {
      // 钱包主卡（onBrand、小号数值）现有调用路径：冻结 ¥0、已提现 ¥5。
      const hero: AmountGridItem[] = [AmountGridItem.money('a', 0, AmountTone.NORMAL, 'h'),
        AmountGridItem.money('b', 500)];
      expect(hero[0].segments.length + hero[1].segments.length).assertEqual(2);
      expect(AmountGridLayout.shouldStack(hero, GRID_320, 1, false, true, false)).assertFalse();
      expect(AmountGridLayout.shouldStack(hero, GRID_320, 2, false, true, false)).assertTrue();
      // 钱包主卡里 7 位金额在 130% 也要按测量纵排（小号数值也算）。
      const big: AmountGridItem[] = [AmountGridItem.money('a', 9999999), AmountGridItem.money('b', 9999999)];
      expect(AmountGridLayout.shouldStack(big, 160, 1.3, false, true, false)).assertTrue();
    });
  });

  describe('Round3PriceTagPresale', () => {
    it('presale_content', 0, () => {
      const p: PriceTagContent = PriceTagModel.make('taobao', 10099999, 100000, 9999999, true);
      expect(p.presaleLabel).assertEqual(PriceTerms.presale);
      expect(p.presaleNote).assertEqual(PriceTerms.presaleNote);
      const n: PriceTagContent = PriceTagModel.make('taobao', 3990, 1000, 2990, false);
      expect(n.presaleLabel).assertNull();
      expect(n.presaleNote).assertNull();
      expect(PriceTagModel.make('pdd', 1990, 0, 1990, true).presaleNote).assertEqual(PriceTerms.presaleNote);
    });

    it('inline_spoken_contains_label_and_note', 0, () => {
      const p: PriceTagContent = PriceTagModel.make('taobao', 3990, 1000, 2990, true);
      const c: string = PriceTerms.comma;
      expect(PriceTagModel.spoken(p, true, PresaleDisplay.INLINE)).assertEqual(PriceTerms.presale + c + p.spokenMain
        + c + p.spokenSub + c + PriceTerms.presaleNote);
      expect(PriceTagModel.spoken(p, false, PresaleDisplay.INLINE)).assertEqual(PriceTerms.presale + c
        + p.spokenMain + c + PriceTerms.presaleNote);
      // 卡片组合（EXTERNAL）：标签行与说明行各自朗读，PriceTag 不重复。
      expect(PriceTagModel.spoken(p, true, PresaleDisplay.EXTERNAL)).assertEqual(p.spokenMain + c + p.spokenSub);
      // 非预售不变。
      const n: PriceTagContent = PriceTagModel.make('taobao', 3990, 0, 3990, false);
      expect(PriceTagModel.spoken(n, true, PresaleDisplay.INLINE)).assertEqual(n.spokenMain + c + PriceTerms.noCoupon);
    });

    it('card_composition_no_duplicates', 0, () => {
      const p: PriceTagContent = PriceTagModel.make('taobao', 3990, 1000, 2990, true);
      const n: PriceTagContent = PriceTagModel.make('taobao', 3990, 1000, 2990, false);
      const muted: ProductTag = new ProductTag('m', CouliChipTone.MUTED, 'info');
      const spec: ProductTag = new ProductTag('s');
      // 占位决定位置。
      expect(labels(ProductCardTags.compose([muted, ProductTag.presaleSlot(), spec], p)))
        .assertEqual('m|' + PriceTerms.presale + '|s');
      // 无占位：排最后。
      expect(labels(ProductCardTags.compose([muted, spec], p))).assertEqual('m|s|' + PriceTerms.presale);
      // 调用方误写「预售」文字标签 + 占位：只留一个。
      expect(labels(ProductCardTags.compose([new ProductTag(PriceTerms.presale), ProductTag.presaleSlot(), spec], p)))
        .assertEqual(PriceTerms.presale + '|s');
      // 非预售：占位与误写都去掉。
      expect(labels(ProductCardTags.compose([ProductTag.presaleSlot(), new ProductTag(PriceTerms.presale), spec], n)))
        .assertEqual('s');
      expect(ProductCardTags.notes('spec', p).join('|')).assertEqual('spec|' + PriceTerms.presaleNote);
      expect(ProductCardTags.notes(null, n).length).assertEqual(0);
    });
  });
}
