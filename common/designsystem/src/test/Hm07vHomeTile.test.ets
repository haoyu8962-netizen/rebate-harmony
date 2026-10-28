// HM-07v-a：首页私有横滑卡的读屏名（brief §2.2「横滑卡不显示标题与来源标签；读屏名仍含平台 + 标题 + 价格 + 返利」，§5；H9）与
// 网格单列判定口径（H11：首页改用组件库 ProductGridLayout，不再自写 150 / 1.5 阈值）。测试作者先写、先红。
// 产品接口（签名见 tests-a-harmony-handback.md §3）：
//   ProductCardA11y.scrollTileLabel(data: ProductCardData, adLabel: string | null): string
//   拼法：[推广标识（服务端原文去首尾空白，空则不读）]，平台名，标题，价格读法（PriceTagModel.spoken(price, true, INLINE)），返利读法
//   （CardAmountMask 之后的 spokenText；平台 not_launched 不读返利；价格不可用时只读 priceUnavailableText），以 PriceTerms.comma 连接。
//   iOS 评审 a-r1 S2-5 教训：合并读屏不得丢掉「推广」；也不得把装饰（图片、钟表、i 图标）拼进去。
import { describe, it, expect } from '@ohos/hypium';
import {
  ContentColumn, PriceTagModel, ProductCardA11y, ProductCardData, ProductCardMapper, ProductCardTexts, ProductGridLayout,
  RebateTagModel
} from '../../Index';

function data(platform: string, label: string, title: string, price: number, coupon: number, presale: boolean,
  basis: string, rebateMin: number, rebateMax: number): ProductCardData {
  const d: ProductCardData = new ProductCardData();
  d.platformCode = platform;
  d.platformLabel = label;
  d.title = title;
  d.price = PriceTagModel.make(platform, price, coupon, price - coupon, presale);
  d.rebate = RebateTagModel.make(basis, rebateMin, rebateMax, false);
  d.imageLabel = '商品图';
  d.disclaimerButtonLabel = '价格说明';
  return d;
}

/** 测试 v3：映射用文案（平台名取画板写法，其余键原样）。 */
class PlatformTexts implements ProductCardTexts {
  text(key: string): string {
    if (key === 'platform.pdd') {
      return '拼多多';
    }
    return key;
  }
}

/** Main-v3 今日精选第 1 件（main_v3 sectionItems.scroll[0]）。 */
function nuts(): ProductCardData {
  return data('taobao', '淘宝', '林间果 每日坚果 30袋', 2290, 300, false, 'normal', 110, 110);
}

export default function hm07vHomeTileTest() {
  describe('Hm07vHomeTile', () => {
    it('hm07v_scroll_label_coupon_reads_ad_platform_title_price_and_rebate', 0, () => {
      expect(ProductCardA11y.scrollTileLabel(nuts(), '推广'))
        .assertEqual('推广，淘宝，林间果 每日坚果 30袋，券后 19.9 元，券前 22.9 元，券 3 元，预估返 1.1 元');
    });

    it('hm07v_scroll_label_no_coupon_and_no_ad_label', 0, () => {
      const d: ProductCardData = data('jd', '京东', '洁澄 洗衣液 3kg 薰衣草香', 2680, 0, false, 'normal', 90, 90);
      expect(ProductCardA11y.scrollTileLabel(d, null)).assertEqual('京东，洁澄 洗衣液 3kg 薰衣草香，售价 26.8 元，无券，预估返 0.9 元');
      // 空白标识当没有（BR-TEXT-17 原样显示；空串不读出一个空单元）。
      expect(ProductCardA11y.scrollTileLabel(d, '  ')).assertEqual('京东，洁澄 洗衣液 3kg 薰衣草香，售价 26.8 元，无券，预估返 0.9 元');
      // 非默认标识原样读一次（不改写成「推广」）。
      expect(ProductCardA11y.scrollTileLabel(d, ' 商家赞助·限时合作 '))
        .assertEqual('商家赞助·限时合作，京东，洁澄 洗衣液 3kg 薰衣草香，售价 26.8 元，无券，预估返 0.9 元');
    });

    it('hm07v_scroll_label_presale_reads_presale_and_note', 0, () => {
      const d: ProductCardData = data('taobao', '淘宝', '东北长粒香大米 10kg 新米 预售款', 8800, 0, true, 'normal', 321, 321);
      expect(ProductCardA11y.scrollTileLabel(d, null))
        .assertEqual('淘宝，东北长粒香大米 10kg 新米 预售款，预售，售价 88 元，无券，定金与尾款以下单页为准，预估返 3.21 元');
    });

    it('hm07v_scroll_label_no_rebate_range_and_pdd_terms', 0, () => {
      const none: ProductCardData = data('taobao', '淘宝', '加厚双层', 980, 100, false, 'no_rebate', 0, 0);
      expect(ProductCardA11y.scrollTileLabel(none, '推广'))
        .assertEqual('推广，淘宝，加厚双层，券后 8.8 元，券前 9.8 元，券 1 元，暂无返利');
      const range: ProductCardData = data('pdd', '拼多多', '厨房纸巾 4 卷', 1290, 300, false, 'normal', 135, 269);
      expect(ProductCardA11y.scrollTileLabel(range, null))
        .assertEqual('拼多多，厨房纸巾 4 卷，拼单券后 9.9 元，拼单券前 12.9 元，券 3 元，预估返 1.35 元到2.69 元');
    });

    it('hm07v_scroll_label_amount_hidden_not_launched_and_price_unavailable', 0, () => {
      const hidden: ProductCardData = nuts();
      hidden.amountHidden = true;
      // 金额隐藏开关（CardAmountMask）：返利读「预估返，金额已隐藏」，不读出 1.1。
      expect(ProductCardA11y.scrollTileLabel(hidden, '推广'))
        .assertEqual('推广，淘宝，林间果 每日坚果 30袋，券后 19.9 元，券前 22.9 元，券 3 元，预估返，金额已隐藏');
      const off: ProductCardData = nuts();
      off.rebateHidden = true;
      // 平台 not_launched：不读返利（共性 31），价格照读。
      expect(ProductCardA11y.scrollTileLabel(off, null)).assertEqual('淘宝，林间果 每日坚果 30袋，券后 19.9 元，券前 22.9 元，券 3 元');
      const gone: ProductCardData = nuts();
      gone.priceUnavailable = true;
      gone.priceUnavailableText = '暂时查不到该商品价格';
      // 价格不可用（BR-PRICE-01）：不读任何金额。
      expect(ProductCardA11y.scrollTileLabel(gone, null)).assertEqual('淘宝，林间果 每日坚果 30袋，暂时查不到该商品价格');
    });

    // 测试 v3（评审 r1 R1-01，S1）：BR-PRICE-08 拼多多直链 rebate_basis=amount_unknown「不显示任何价格与返利金额，显示『可返利，
    // 金额以订单为准』（BR-TEXT-14 rebate_amount_unknown）」。横滑卡读屏名同样不得读出任何价格：价格三字段齐全（映射后 price 带金额，
    // ProductCardMapper.priceUnavailable 对 amount_unknown 恒为 false）时也一样；价格字段为空时也不得落成「价格不可用」或只剩标题。
    // 期望值是字面量（规则原文 + 平台名 + 标题），不在测试里拼产品同款函数。r1 产品（照常读价格）上第 1、3 组必红。
    it('hm07v_scroll_label_amount_unknown_reads_no_price', 0, () => {
      const unknownLabel: string = '可返利，金额以订单为准';
      const priced: ProductCardData = data('pdd', '拼多多', '厨房纸巾 4 卷', 1290, 300, false, 'amount_unknown', 0, 0);
      expect(ProductCardA11y.scrollTileLabel(priced, '推广')).assertEqual('推广，拼多多，厨房纸巾 4 卷，' + unknownLabel);
      // 金额隐藏开关对它无影响（本来就没有金额）。
      priced.amountHidden = true;
      expect(ProductCardA11y.scrollTileLabel(priced, null)).assertEqual('拼多多，厨房纸巾 4 卷，' + unknownLabel);
      // 经真实映射：契约卡（拼多多直链）。① 价格字段为空（BR-PRICE-08 原文：报价快照价格字段为空）；② 三字段齐全。
      const texts: PlatformTexts = new PlatformTexts();
      const bare: Record<string, Object> = JSON.parse('{"platform":"pdd","title":"厨房纸巾 4 卷","rebate_basis":"amount_unknown",'
        + '"price_fen":null,"coupon_fen":null,"final_price_fen":null,"rebate_min_fen":null,"rebate_max_fen":null,'
        + '"disclaimer_keys":["price_basis"],"cta":{"text_key":"btn.buy"},"availability":"ok"}') as Record<string, Object>;
      const bareData: ProductCardData = ProductCardMapper.fromCard(bare, texts);
      expect(ProductCardA11y.scrollTileLabel(bareData, '推广')).assertEqual('推广，拼多多，厨房纸巾 4 卷，' + unknownLabel);
      const full: Record<string, Object> = JSON.parse('{"platform":"pdd","title":"厨房纸巾 4 卷","rebate_basis":"amount_unknown",'
        + '"price_fen":1290,"coupon_fen":300,"final_price_fen":990,"rebate_min_fen":null,"rebate_max_fen":null,'
        + '"disclaimer_keys":["price_basis"],"cta":{"text_key":"btn.buy"},"availability":"ok"}') as Record<string, Object>;
      const fullData: ProductCardData = ProductCardMapper.fromCard(full, texts);
      expect(ProductCardA11y.scrollTileLabel(fullData, '推广')).assertEqual('推广，拼多多，厨房纸巾 4 卷，' + unknownLabel);
      // 任何形态都不读金额、货币符号与价格口径词。
      for (const d of [priced, bareData, fullData]) {
        const label: string = ProductCardA11y.scrollTileLabel(d, '推广');
        for (const word of ['¥', '元', '券后', '券前', '售价', '无券', '9.9', '12.9', '暂时查不到']) {
          expect(label.indexOf(word) < 0 ? word : 'HM07V_PRICE_IN_UNKNOWN_LABEL ' + word + ' ' + label).assertEqual(word);
        }
      }
    });

    it('hm07v_scroll_label_excludes_decorations', 0, () => {
      const label: string = ProductCardA11y.scrollTileLabel(nuts(), '推广');
      for (const word of ['商品图', '价格说明', '图片', '图标', '¥', 'null', 'undefined']) {
        expect(label.indexOf(word) < 0 ? word : 'HM07V_DECORATION_IN_LABEL ' + word + ' ' + label).assertEqual(word);
      }
      expect(label.split('推广').length - 1).assertEqual(1);
      expect(label.split('淘宝').length - 1).assertEqual(1);
    });

    // H11：首页网格 / 信息流列数必须等于组件库口径。下面三组是「首页自写 150vp / 1.5 倍阈值」与组件库（160vp / 1.3 倍）给出不同结果的
    // 边界：鸿蒙模拟器 376vp 宽、页面边距 16 + 段卡内边距 16 时，超市百货网格可用宽正好 312vp（自写 → 2 列，组件库 → 1 列）。
    // 设备用例 hm07va_grid_columns_follow_component_library_rule 用同一函数在真实页面上核对接线。
    it('hm07v_grid_rule_boundaries_that_home_must_inherit', 0, () => {
      expect(ProductGridLayout.columns(2, 312, 1)).assertEqual(1);
      expect(ProductGridLayout.columns(2, 331, 1)).assertEqual(1);
      expect(ProductGridLayout.columns(2, 332, 1)).assertEqual(2);
      expect(ProductGridLayout.columns(4, 344, 1.4)).assertEqual(1);
      expect(ProductGridLayout.columns(4, 344, 1.3)).assertEqual(2);
      expect(ProductGridLayout.columns(1, 600, 1)).assertEqual(1);
    });

    // 测试 v2（编排 D10-405 D2 + 15:10 补充）：组件库全局口径不变（缺省每列最窄 160），网格加带默认值的可选参数 minColumn；首页超市百货段
    // 按卡内内容实际所需宽度传入，常规字号在 376 / 390 宽（段卡内可用宽 312 / 326vp，列间距 space.3 = 12）出两列；字号 > 1.3 倍时
    // 不论 minColumn 都单列（无障碍）。设备用例 hm07va_grid_… 用同一函数 + 首页同一量宽在真实页面上核对，并在 376 常规字号下要求两列。
    it('hm07v_grid_min_column_param_default_160_unchanged_and_home_value_decides_columns', 0, () => {
      // 缺省 = 显式传 160 = 原口径（既有调用、快照不变）。
      for (const w of [0, 300, 312, 331, 332, 344, 600]) {
        for (const k of [1, 1.3, 1.31, 2]) {
          expect(ProductGridLayout.columns(2, w, k)).assertEqual(ProductGridLayout.columns(2, w, k, 160));
        }
      }
      expect(ProductGridLayout.MIN_COLUMN).assertEqual(160);
      // 两列门槛 = 2 × minColumn + 12：376 宽（312vp）minColumn ≤ 150 两列；390 宽（326vp）≤ 157 两列。
      expect(ProductGridLayout.columns(2, 312, 1, 150)).assertEqual(2);
      expect(ProductGridLayout.columns(2, 312, 1, 151)).assertEqual(1);
      expect(ProductGridLayout.columns(2, 326, 1, 157)).assertEqual(2);
      expect(ProductGridLayout.columns(2, 326, 1, 158)).assertEqual(1);
      // 字号：≤ 1.3 倍按宽度判定；> 1.3 倍（含 200%）不论 minColumn 多小都单列。
      expect(ProductGridLayout.columns(2, 312, 1.3, 120)).assertEqual(2);
      expect(ProductGridLayout.columns(2, 312, 1.31, 120)).assertEqual(1);
      expect(ProductGridLayout.columns(2, 600, 2, 1)).assertEqual(1);
      // 只有 1 件恒单列；宽度未知（0）先按两列排。
      expect(ProductGridLayout.columns(1, 600, 1, 100)).assertEqual(1);
      expect(ProductGridLayout.columns(2, 0, 1, 300)).assertEqual(2);
      // 误传（0 / 负数 / 非数字）按缺省 160，不能把门槛降成 0。
      for (const bad of [0, -1, NaN, Infinity]) {
        expect(ProductGridLayout.columns(2, 312, 1, bad)).assertEqual(1);
        expect(ProductGridLayout.columns(2, 332, 1, bad)).assertEqual(2);
      }
    });

    // 测试 v2（编排 D10-405 D3）：本机没有 ≥ 600vp 模拟器，w > 600 的限宽居中分支在这里按窗口宽参数化覆盖；首页搜索行 / 原生区 / 列表 /
    // 基本模式顶栏都按 ContentColumn 定宽（宿主检查 W5 守接线）。设备截图 Guest-w600-light 为「376 宽代替」，真机 / 大屏核对登记 QA。
    it('hm07v_content_column_limits_600_and_centers_for_window_599_600_601_840_1200', 0, () => {
      // [窗口宽, 内容列宽, 左边距, 是否限宽]
      const rows: number[][] = [
        [320, 320, 0, 0], [376, 376, 0, 0], [390, 390, 0, 0], [599, 599, 0, 0], [600, 600, 0, 0],
        [601, 600, 0.5, 1], [840, 600, 120, 1], [1200, 600, 300, 1]
      ];
      for (const r of rows) {
        const what: string = 'w=' + r[0];
        expect(what + ':' + ContentColumn.width(r[0])).assertEqual(what + ':' + r[1]);
        expect(what + ':' + ContentColumn.inset(r[0])).assertEqual(what + ':' + r[2]);
        expect(what + ':' + ContentColumn.limited(r[0])).assertEqual(what + ':' + (r[3] === 1));
        // 居中：左边距 + 内容列 + 右边距 = 窗口宽，左右相等；内容列从不超过 600。
        const right: number = r[0] - ContentColumn.inset(r[0]) - ContentColumn.width(r[0]);
        expect(what + ':' + right).assertEqual(what + ':' + ContentColumn.inset(r[0]));
        expect(ContentColumn.width(r[0]) <= 600).assertTrue();
      }
      expect(ContentColumn.MAX_WIDTH).assertEqual(600);
      // 窗口宽未知（还没量到 / 非法）：0，调用方按铺满处理，不得算出负边距。
      for (const bad of [0, -1, NaN]) {
        expect(ContentColumn.width(bad)).assertEqual(0);
        expect(ContentColumn.inset(bad)).assertEqual(0);
        expect(ContentColumn.limited(bad)).assertFalse();
      }
    });
  });
}
