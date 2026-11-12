// HM-L2-PRODUCT-CELL-harmony 测试作者 v1（新鲜独立 Claude，先红）：商品卡信息区整块读屏名与 U1 一行购买句式的纯逻辑。
// 依据：NATIVE/HM-L2-BATCH1/brief-PRODUCT-CELL.md §2.3 / §3「逻辑」1–4；README 末节编排裁定 D10-1177（⑥ openable、② D10-871 回落）；
// couli docs/changes/20261105-商品详情v3定稿.md 第 3、10 条（U1：列表卡、AI 卡购买按钮一行「购买预估返 ¥x」同句式；预估返后列表卡、AI 卡都不展示）。
// 用例名前缀 c1–c4 对应书 §3「逻辑」第 1–4 条；c5 / c6 是 U1 一行句式与 D10-871 的钉子（BUTTON 已落，只补断言，现树应绿）；c7 口径一致。
//
// 被测接口（实现者按此提供；本文件不给假实现）：
// - ProductCardA11y.cellLabel(data: ProductCardData): string —— 新增。列表 / AI / 网格卡「信息区」的整块读屏名「平台，标题，价格，返利」，
//   与首页横滑卡 scrollTileLabel 同口径（不带推广标识）：价格按 PriceTagModel 读法（含副行、预售），价格不可用只读提示句，amount_unknown 不读价格、
//   只读「可返利，金额以订单为准」，平台 not_launched 不读返利，金额隐藏按 CardAmountMask；不拼图片占位、口径 i、购买按钮、预估返后。
//   ProductCard 信息区 .accessibilityText 用它（宿主 tools/ci/l2cell P4-info 钉接线）。
//
// 期望值是字面量（与 Hm07vHomeTile 同一套读法写法），不在测试里拼产品同款函数；c7 才拿 scrollTileLabel 比「口径一致」。
// FU-HM-A11Y-AGENT（#24，编排裁定 D10-1248 ⑦ / PRODUCT-CELL 评审 S3-1）：c8 读看得见的——信息区里显示的优惠标签照读（在标题后、价格前，预售只读一次），
// 列表 / 网格隐藏的「暂无返利」不读；横滑卡 scrollTileLabel 同改（不显示标签就不读标签、暂无返利不读，Hm07vHomeTile 同步），三类卡读法一致。
// 不依赖时区：断言不涉及取价时间。
import { describe, it, expect } from '@ohos/hypium';
import { DefaultTexts } from 'generated';
import {
  BuyButtonModel, BuyButtonState, BuyContext, CardAmountMask, EstNetModel, PriceTagModel, RebateTagContent, RebateTagModel
} from '../main/ets/format/PriceModels';
import { ProductCardMapper, ProductCardTexts } from '../main/ets/format/ProductCardMapper';
import { ProductCardA11y, ProductCardData, ProductTag } from '../main/ets/components/ProductCard';

const NOW: number = 1794022200000;
/** 契约字典 btn.buy（D10-1177 ②：金额隐藏且动词含本卡金额时回落到它）。 */
const BUY: string = '购买';
/** U1 一行句式：btn.buy.rebate「购买预估返 {amount}」填好本卡单一金额。 */
const ONE_LINE: string = '购买预估返 ¥2.69';
/** btn.buy.rebate_unknown（拿不到金额）。 */
const ONE_LINE_UNKNOWN: string = '购买可返利';
const UNKNOWN_LABEL: string = '可返利，金额以订单为准';
const HIDDEN_REBATE: string = '预估返，金额已隐藏';
const UNAVAILABLE: string = '暂时查不到该商品价格';
/** 列表卡不读、不显示的装饰与卡外文字。 */
const IMAGE_LABEL: string = '商品图';
const INFO_LABEL: string = '价格说明';
const EST_NET_WORD: string = '预估返后';

function data(platform: string, label: string, title: string, price: number, coupon: number, presale: boolean,
  basis: string, rebateMin: number | null, rebateMax: number | null): ProductCardData {
  const d: ProductCardData = new ProductCardData();
  d.platformCode = platform;
  d.platformLabel = label;
  d.title = title;
  d.price = PriceTagModel.make(platform, price, coupon, price - coupon, presale);
  d.rebate = RebateTagModel.make(basis, rebateMin, rebateMax, false);
  d.imageLabel = IMAGE_LABEL;
  d.disclaimerButtonLabel = INFO_LABEL;
  d.buyBase = '领券购买';
  return d;
}

/** Main-v3 今日精选第 1 件（Hm07vHomeTile 同一件，读法已在那边钉过）。 */
function nuts(): ProductCardData {
  return data('taobao', '淘宝', '林间果 每日坚果 30袋', 2290, 300, false, 'normal', 110, 110);
}

function same(label: string, actual: string | number | boolean | null, wanted: string | number | boolean | null): void {
  expect(label + ' = ' + JSON.stringify(actual)).assertEqual(label + ' = ' + JSON.stringify(wanted));
}

function lacks(label: string, text: string, word: string): void {
  expect(label + ' 不含「' + word + '」：' + (text.indexOf(word) < 0 ? 'ok' : text)).assertEqual(label + ' 不含「' + word + '」：ok');
}

function occurrences(text: string, part: string): number {
  return text.split(part).length - 1;
}

/** texts = 包内契约字典（缺键空串）；平台名键给画板写法（Hm07vHomeTile PlatformTexts 同法），读屏名才有「平台」一段。 */
class ContractTexts implements ProductCardTexts {
  text(key: string): string {
    if (key === 'platform.taobao') {
      return '淘宝';
    }
    if (key === 'platform.pdd') {
      return '拼多多';
    }
    return DefaultTexts.text(key) ?? '';
  }
}

const BASE_CARD: string = '{"platform":"taobao","product_key":"tb:cell","item_ref":"ref-cell",'
  + '"link_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5c10","title":"洗衣液 3kg","price_fen":3990,"coupon_fen":1000,'
  + '"final_price_fen":2990,"est_net_price_fen":2721,"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal",'
  + '"benefit_tags":[],"is_presale":false,"cta":{"text_key":"btn.buy.rebate"},"quoted_at":"2026-11-07T09:30:00+08:00",'
  + '"stale":false,"age_sec":12,"disclaimer_keys":["price_basis"],"availability":"ok"';

/** BASE_CARD 加若干字段（extra 以逗号开头，JSON 后写的键覆盖前面的同名键）。 */
function mapped(extra: string): ProductCardData {
  const card: Record<string, Object> = JSON.parse(BASE_CARD + extra + '}') as Record<string, Object>;
  return ProductCardMapper.fromCard(card, new ContractTexts(), true, NOW, ProductCardMapper.PURCHASE_ON, (_key: string): void => {
  });
}

export default function l2ProductCellTest() {
  describe('L2ProductCell', () => {
    // 书 §3 逻辑 1：信息区合成读屏「平台，标题，价格，返利」，scrollTileLabel 口径（不带推广标识），无占位文字。
    it('l2cell_c1_cell_label_reads_platform_title_price_rebate', 0, () => {
      same('有券单值', ProductCardA11y.cellLabel(nuts()), '淘宝，林间果 每日坚果 30袋，券后 19.9 元，券前 22.9 元，券 3 元，预估返 1.1 元');
      const jd: ProductCardData = data('jd', '京东', '洁澄 洗衣液 3kg 薰衣草香', 2680, 0, false, 'normal', 90, 90);
      same('无券', ProductCardA11y.cellLabel(jd), '京东，洁澄 洗衣液 3kg 薰衣草香，售价 26.8 元，无券，预估返 0.9 元');
      const range: ProductCardData = data('pdd', '拼多多', '厨房纸巾 4 卷', 1290, 300, false, 'normal', 135, 269);
      same('拼多多区间', ProductCardA11y.cellLabel(range), '拼多多，厨房纸巾 4 卷，拼单券后 9.9 元，拼单券前 12.9 元，券 3 元，预估返 1.35 元到2.69 元');
      const presale: ProductCardData = data('taobao', '淘宝', '东北长粒香大米 10kg 新米 预售款', 8800, 0, true, 'normal', 321, 321);
      same('预售', ProductCardA11y.cellLabel(presale), '淘宝，东北长粒香大米 10kg 新米 预售款，预售，售价 88 元，无券，定金与尾款以下单页为准，预估返 3.21 元');
      // 平台在最前、只读一次；标题只读一次（标题组「平台，标题」不另读）。
      const label: string = ProductCardA11y.cellLabel(nuts());
      same('平台在最前', label.indexOf('淘宝'), 0);
      same('平台读一次', occurrences(label, '淘宝'), 1);
      same('标题读一次', occurrences(label, '林间果 每日坚果 30袋'), 1);
    });

    // 书 §3 逻辑 2：读屏名不含预估返后（U1：列表卡、AI 卡不展示预估返后；字段照常下发、客户端不读）；也不含装饰与卡外按钮文字。
    it('l2cell_c2_cell_label_excludes_est_net_and_decorations', 0, () => {
      const d: ProductCardData = nuts();
      d.estNet = EstNetModel.make('normal', 110, 1780);
      same('前提：样例确有预估返后文字', d.estNet !== null && (d.estNet as string).indexOf(EST_NET_WORD) === 0, true);
      const label: string = ProductCardA11y.cellLabel(d);
      for (const word of [EST_NET_WORD, '17.8', IMAGE_LABEL, INFO_LABEL, '领券购买', '¥', 'null', 'undefined', '推广']) {
        lacks('读屏名', label, word);
      }
      same('有预估返后字段时读屏名不变', label, ProductCardA11y.cellLabel(nuts()));
      // 映射来的真实卡（est_net_price_fen 照常下发）同样不读。
      const m: ProductCardData = mapped('');
      same('前提：映射填了 estNet', m.estNet !== null, true);
      lacks('映射卡读屏名', ProductCardA11y.cellLabel(m), EST_NET_WORD);
      lacks('映射卡读屏名', ProductCardA11y.cellLabel(m), '27.21');
      lacks('映射卡读屏名（按钮文字不并入）', ProductCardA11y.cellLabel(m), ONE_LINE);
    });

    // 书 §3 逻辑 3：not_launched、amount_unknown、price_unavailable 沿 ProductCardA11y 规则。
    it('l2cell_c3_not_launched_amount_unknown_price_unavailable', 0, () => {
      const off: ProductCardData = nuts();
      off.rebateHidden = true;
      same('平台 not_launched：不读返利，价格照读', ProductCardA11y.cellLabel(off), '淘宝，林间果 每日坚果 30袋，券后 19.9 元，券前 22.9 元，券 3 元');
      const unknown: ProductCardData = data('pdd', '拼多多', '厨房纸巾 4 卷', 1290, 300, false, 'amount_unknown', null, null);
      same('amount_unknown：不读价格', ProductCardA11y.cellLabel(unknown), '拼多多，厨房纸巾 4 卷，' + UNKNOWN_LABEL);
      for (const word of ['¥', '元', '券后', '券前', '9.9', '12.9']) {
        lacks('amount_unknown 读屏名', ProductCardA11y.cellLabel(unknown), word);
      }
      const unknownOff: ProductCardData = data('pdd', '拼多多', '厨房纸巾 4 卷', 1290, 300, false, 'amount_unknown', null, null);
      unknownOff.rebateHidden = true;
      same('amount_unknown + not_launched：连「可返利」也不读', ProductCardA11y.cellLabel(unknownOff), '拼多多，厨房纸巾 4 卷');
      const gone: ProductCardData = nuts();
      gone.priceUnavailable = true;
      gone.priceUnavailableText = UNAVAILABLE;
      same('价格不可用：只读提示句', ProductCardA11y.cellLabel(gone), '淘宝，林间果 每日坚果 30袋，' + UNAVAILABLE);
      // 经真实映射：拼多多直链 amount_unknown，价格三字段齐全也不读价格（BR-PRICE-08）。
      const full: ProductCardData = mapped(',"platform":"pdd","rebate_basis":"amount_unknown","rebate_min_fen":null,"rebate_max_fen":null,'
        + '"cta":{"text_key":"btn.buy.rebate_unknown"}');
      lacks('映射 amount_unknown 读屏名', ProductCardA11y.cellLabel(full), '¥');
      lacks('映射 amount_unknown 读屏名', ProductCardA11y.cellLabel(full), '29.9');
      same('映射 amount_unknown 读屏名以「可返利，金额以订单为准」结尾', ProductCardA11y.cellLabel(full).endsWith(UNKNOWN_LABEL), true);
    });

    // 书 §3 逻辑 4：D10-871 的防御——amountHidden=true 的读屏不读金额（与 CardAmountMask 一致）。
    it('l2cell_c4_amount_hidden_reads_no_amount', 0, () => {
      const hidden: ProductCardData = nuts();
      hidden.amountHidden = true;
      same('单值隐藏', ProductCardA11y.cellLabel(hidden), '淘宝，林间果 每日坚果 30袋，券后 19.9 元，券前 22.9 元，券 3 元，' + HIDDEN_REBATE);
      lacks('单值隐藏', ProductCardA11y.cellLabel(hidden), '1.1 元');
      const range: ProductCardData = data('pdd', '拼多多', '厨房纸巾 4 卷', 1290, 300, false, 'normal', 135, 269);
      range.amountHidden = true;
      const label: string = ProductCardA11y.cellLabel(range);
      same('区间隐藏', label, '拼多多，厨房纸巾 4 卷，拼单券后 9.9 元，拼单券前 12.9 元，券 3 元，' + HIDDEN_REBATE);
      lacks('区间隐藏', label, '1.35');
      lacks('区间隐藏', label, '2.69');
      // 与 CardAmountMask 同口径：返利段就是遮罩后的 spokenText。
      same('与 CardAmountMask 一致', label.endsWith(CardAmountMask.rebate(range.rebate, true).spokenText), true);
      // 映射卡：est_net 照常下发，隐藏时也不读。
      const m: ProductCardData = mapped('');
      m.amountHidden = true;
      for (const word of ['2.69', '27.21', EST_NET_WORD]) {
        lacks('映射卡隐藏', ProductCardA11y.cellLabel(m), word);
      }
    });

    // U1（DETAIL-V3 第 3 条）：列表卡、AI 卡的购买按钮与详情同一句式，一行「购买预估返 ¥x」，有券无券同一句；拿不到金额「购买可返利」。
    // BUTTON 已落（ProductCardMapper + BuyButtonModel），本单只补断言（书 §1 表「按钮一行」）：现树应绿。
    it('l2cell_c5_buy_one_line_sentence_same_on_list_ai_detail', 0, () => {
      const d: ProductCardData = mapped('');
      same('映射填好的动词', d.buyBase, ONE_LINE);
      for (const ctx of [BuyContext.LIST, BuyContext.AGENT, BuyContext.DETAIL]) {
        const text: string = BuyButtonModel.text(d.buyBase, d.rebate, false, ctx);
        same(ctx + ' 一行句式', text, ONE_LINE);
        same(ctx + ' 状态文字（NORMAL）', BuyButtonModel.stateLabel(BuyButtonState.NORMAL, d.buyBase, d.retryText, d.rebate, false, ctx),
          ONE_LINE);
        same(ctx + ' 不换行', text.indexOf('\n') < 0, true);
        same(ctx + ' 不拼旧后缀「·」', text.indexOf('·') < 0, true);
        same(ctx + ' 金额只出现一次', occurrences(text, '¥2.69'), 1);
        lacks(ctx + ' 按钮', text, EST_NET_WORD);
      }
      const noCoupon: ProductCardData = mapped(',"coupon_fen":0,"final_price_fen":3990');
      same('无券同一句', BuyButtonModel.text(noCoupon.buyBase, noCoupon.rebate, false, BuyContext.LIST), ONE_LINE);
      const unknown: ProductCardData = mapped(',"rebate_basis":"amount_unknown","rebate_min_fen":null,"rebate_max_fen":null,'
        + '"cta":{"text_key":"btn.buy.rebate_unknown"}');
      same('拿不到金额', BuyButtonModel.text(unknown.buyBase, unknown.rebate, false, BuyContext.LIST), ONE_LINE_UNKNOWN);
    });

    // D10-871 按 D10-1177 ② 读：金额隐藏时，动词含本卡金额就回落 btn.buy「购买」——前提是传给按钮的是**未遮罩**的本卡返利
    // （BUTTON 评审 r1 S3-1：卡内 this.rebate() 是遮罩后的，误传就比不中；接线由宿主 P7-hidden / l2button B5-hidden 钉）。
    it('l2cell_c6_amount_hidden_buy_falls_back_with_unmasked_rebate', 0, () => {
      const d: ProductCardData = mapped('');
      for (const ctx of [BuyContext.LIST, BuyContext.AGENT]) {
        same(ctx + ' 隐藏可见文字', BuyButtonModel.text(d.buyBase, d.rebate, true, ctx), BUY);
        same(ctx + ' 隐藏读屏', BuyButtonModel.spoken(d.buyBase, d.rebate, true, ctx), BUY);
        same(ctx + ' 隐藏状态文字', BuyButtonModel.stateLabel(BuyButtonState.NORMAL, d.buyBase, d.retryText, d.rebate, true, ctx), BUY);
      }
      // 遮罩后的返利不再带本卡金额文字（这正是不能把它传给按钮的原因）。
      const masked: RebateTagContent = CardAmountMask.rebate(d.rebate, true);
      same('遮罩后金额文字不同于本卡金额', masked.amountText === d.rebate.amountText, false);
      same('前提：本卡金额文字', d.rebate.amountText, '¥2.69');
    });

    // 口径一致（书 §2.3「复用 scrollTileLabel 口径」）：各状态的映射卡，cellLabel 与 scrollTileLabel(无推广标识) 逐字相同。
    it('l2cell_c7_cell_label_matches_scroll_tile_label_without_ad', 0, () => {
      const cases: ProductCardData[] = [
        mapped(''),
        mapped(',"rebate_basis":"price_compare_risk","rebate_min_fen":135,"rebate_max_fen":269'),
        mapped(',"rebate_basis":"no_rebate","rebate_min_fen":0,"rebate_max_fen":0,"cta":{"text_key":"btn.buy.no_rebate"}'),
        mapped(',"rebate_basis":"amount_unknown","rebate_min_fen":null,"rebate_max_fen":null,"cta":{"text_key":"btn.buy.rebate_unknown"}'),
        mapped(',"is_presale":true'),
        mapped(',"coupon_fen":0,"final_price_fen":3990'),
      ];
      const hidden: ProductCardData = mapped('');
      hidden.amountHidden = true;
      cases.push(hidden);
      const off: ProductCardData = mapped('');
      off.rebateHidden = true;
      cases.push(off);
      const gone: ProductCardData = mapped('');
      gone.priceUnavailable = true;
      gone.priceUnavailableText = UNAVAILABLE;
      cases.push(gone);
      cases.forEach((c: ProductCardData, i: number) => {
        same('case ' + i, ProductCardA11y.cellLabel(c), ProductCardA11y.scrollTileLabel(c, null));
        same('case ' + i + ' 非空且以平台开头', ProductCardA11y.cellLabel(c).indexOf(c.platformLabel) === 0 && c.platformLabel.length > 0, true);
      });
    });

    // FU-HM-A11Y-AGENT（#24；D10-1248 ⑦，PRODUCT-CELL 评审 S3-1）：读看得见的权益、不读视觉隐藏文字。
    it('l2cell_c8_cell_label_reads_visible_tags_not_hidden_no_rebate', 0, () => {
      // 信息区标签行显示的优惠标签（benefit_tags）照读，顺序同视觉：标题后、价格前；横滑卡不显示标签，scrollTileLabel 不读。
      const tagged: ProductCardData = nuts();
      tagged.tags = [new ProductTag('包邮'), new ProductTag('退货包运费')];
      same('带标签', ProductCardA11y.cellLabel(tagged), '淘宝，林间果 每日坚果 30袋，包邮，退货包运费，券后 19.9 元，券前 22.9 元，券 3 元，预估返 1.1 元');
      same('横滑卡不显示标签也不读', ProductCardA11y.scrollTileLabel(tagged, null), ProductCardA11y.cellLabel(nuts()));
      // 预售：标签行里的「预售」与价格读法里的「预售」是同一个，只读一次；调用方误写的「预售」文字标签同样不重读。
      const presale: ProductCardData = data('taobao', '淘宝', '东北长粒香大米 10kg 新米 预售款', 8800, 0, true, 'normal', 321, 321);
      presale.tags = [new ProductTag('包邮'), ProductTag.presaleSlot(), new ProductTag('预售')];
      const p: string = ProductCardA11y.cellLabel(presale);
      same('预售只读一次（标题里的「预售款」不算）', occurrences(p, '预售') - occurrences(p, '预售款'), 1);
      same('预售卡读出包邮', p.indexOf('包邮') > p.indexOf('预售款'), true);
      // 映射来的真实卡（benefit_tags 原样进标签行）。
      const m: ProductCardData = mapped(',"benefit_tags":["有券","包邮"]');
      same('映射卡读标签', ProductCardA11y.cellLabel(m).indexOf('洗衣液 3kg，有券，包邮，') > 0, true);
      // 列表 / 网格 / AI 卡隐藏「暂无返利」（BR-TEXT-10），读屏也不读；横滑卡（返利块不显示）同样不读。
      const none: ProductCardData = data('taobao', '淘宝', '加厚双层', 980, 100, false, 'no_rebate', 0, 0);
      same('暂无返利不读', ProductCardA11y.cellLabel(none), '淘宝，加厚双层，券后 8.8 元，券前 9.8 元，券 1 元');
      same('横滑卡暂无返利不读', ProductCardA11y.scrollTileLabel(none, null), '淘宝，加厚双层，券后 8.8 元，券前 9.8 元，券 1 元');
      const noneMapped: ProductCardData = mapped(',"rebate_basis":"no_rebate","rebate_min_fen":0,"rebate_max_fen":0,"cta":{"text_key":"btn.buy.no_rebate"}');
      lacks('映射 no_rebate 读屏名', ProductCardA11y.cellLabel(noneMapped), '暂无返利');
      // 金额隐藏、amount_unknown 照旧（可见的「预估返 ****」「可返利，金额以订单为准」照读）。
      const hidden: ProductCardData = nuts();
      hidden.tags = [new ProductTag('包邮')];
      hidden.amountHidden = true;
      same('带标签 + 金额隐藏', ProductCardA11y.cellLabel(hidden), '淘宝，林间果 每日坚果 30袋，包邮，券后 19.9 元，券前 22.9 元，券 3 元，' + HIDDEN_REBATE);
    });
  });
}
