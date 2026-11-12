/*
 * FU-HM-A11Y-AGENT-harmony 逻辑层（测试作者 v2，新鲜独立 Claude，先红）：商品卡信息区读屏名（ProductCardA11y.cellLabel）在「不展示价格」时
 * 读看得见的「预售」标签（Codex 评审 r1 S3：预售 + amount_unknown / 价格不可用时，标签行显示「预售」，读屏名漏读）。
 * 依据：README 末节 D10-1248 ⑦（读看得见的权益、不读视觉隐藏文字，三类卡读法一致）；B3-lane/notices.md D10-1328 ①（新口径：平台、标题、看得见的
 * 优惠标签、价格、返利；预售只读一次；「暂无返利」不读）；AGENT/review-codex-r1.md 结论段第 2 条；测试 v1 交回 §7 第 1 条（优惠标签按标签行顺序读）。
 *
 * 卡面事实（ProductCard.ets，abd347c 起未变）：
 *   - 标签行 tagRow = ProductCardTags.compose(tags, price)：price.presaleLabel 非空时在占位处（无占位则最后）放一个「预售」，调用方误写的「预售」
 *     文字标签去重；列表 / AI / 网格卡的标签行与价格是否展示无关（价格不可用、amount_unknown 时照样显示「预售」）。
 *   - 不展示价格（noPrice = amount_unknown 或价格不可用）时 PriceTag 与副行都不放，所以价格读法里的「预售」与预售说明「定金与尾款以下单页为准」
 *     都看不见。
 * 由此本文件钉（只收紧，不改 v1 已认可的口径）：
 *   1. 预售 + amount_unknown：读屏名恰读一次「预售」，位置按标签行顺序，不读预售说明、不读任何价格；
 *   2. 预售 + 价格不可用：同上，返利照旧不读，只读提示句；
 *   3. 预售 + amount_unknown + 平台 not_launched：连「可返利」也不读，「预售」照读；
 *   4. 回归：有价格的预售仍只读一次（价格读法里那一次）；不是预售时调用方误写的「预售」文字标签不显示也不读。
 * 现树（实现 v1）预期：1、2、3 红（「预售」0 次），4 绿。
 * 登记：common/designsystem/src/test/List.test.ets 调 a11yAgentCellLabelTest()（冻结件，走 #24，见 tests-harmony-v2-handback.md）；未登记时由
 * tools/ci/a11yagent/run-logic.cjs 用 node 直接执行本文件（不冒充 hvigor）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { DefaultTexts } from 'generated';
import { PriceTagModel, RebateTagModel } from '../main/ets/format/PriceModels';
import { ProductCardMapper, ProductCardTexts } from '../main/ets/format/ProductCardMapper';
import { ProductCardA11y, ProductCardData, ProductTag } from '../main/ets/components/ProductCard';

const NOW: number = 1794022200000;
const PRESALE: string = '预售';
const PRESALE_NOTE: string = '定金与尾款以下单页为准';
const UNKNOWN_LABEL: string = '可返利，金额以订单为准';
const UNAVAILABLE: string = '暂时查不到该商品价格';
const TITLE: string = '东北长粒香大米 10kg 新米';

/** 不展示价格的卡（映射里 PriceTagModel.unpriced(presale) 的同一形状）。 */
function unpriced(basis: string, presale: boolean): ProductCardData {
  const d: ProductCardData = new ProductCardData();
  d.platformCode = 'taobao';
  d.platformLabel = '淘宝';
  d.title = TITLE;
  d.price = PriceTagModel.unpriced(presale);
  d.rebate = RebateTagModel.make(basis, basis === 'amount_unknown' ? null : 321, basis === 'amount_unknown' ? null : 321, false);
  d.imageLabel = '商品图';
  d.disclaimerButtonLabel = '价格说明';
  d.buyBase = '领券购买';
  return d;
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

const BASE_CARD: string = '{"platform":"taobao","product_key":"tb:presale","item_ref":"ref-presale",'
  + '"link_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5c24","title":"' + TITLE + '","price_fen":8800,"coupon_fen":0,'
  + '"final_price_fen":8800,"est_net_price_fen":8479,"rebate_min_fen":321,"rebate_max_fen":321,"rebate_basis":"normal",'
  + '"benefit_tags":["包邮"],"is_presale":true,"cta":{"text_key":"btn.buy.rebate"},"quoted_at":"2026-11-07T09:30:00+08:00",'
  + '"stale":false,"age_sec":12,"disclaimer_keys":["price_basis"],"availability":"ok"';

/** BASE_CARD 加若干字段（extra 以逗号开头，后写的键覆盖前面的同名键）。 */
function mapped(extra: string): ProductCardData {
  const card: Record<string, Object> = JSON.parse(BASE_CARD + extra + '}') as Record<string, Object>;
  return ProductCardMapper.fromCard(card, new ContractTexts(), true, NOW, ProductCardMapper.PURCHASE_ON, (_key: string): void => {
  });
}

export default function a11yAgentCellLabelTest() {
  describe('A11yAgentCellLabel', () => {
    // 1. 预售 + amount_unknown（Codex r1 S3 内存探针原样：标签行 [预售]，读屏名只有「淘宝，测试商品，可返利，金额以订单为准」）。
    it('a11yagent_cell_presale_amount_unknown_reads_presale_once', 0, () => {
      const bare: ProductCardData = unpriced('amount_unknown', true);
      same('无其他标签', ProductCardA11y.cellLabel(bare), '淘宝，' + TITLE + '，预售，' + UNKNOWN_LABEL);
      const tagged: ProductCardData = unpriced('amount_unknown', true);
      tagged.tags = [new ProductTag('包邮'), ProductTag.presaleSlot(), new ProductTag('退货包运费'), new ProductTag(PRESALE)];
      const t: string = ProductCardA11y.cellLabel(tagged);
      same('按标签行顺序（占位处读「预售」，误写的「预售」不重读）', t, '淘宝，' + TITLE + '，包邮，预售，退货包运费，' + UNKNOWN_LABEL);
      same('「预售」恰一次', occurrences(t, PRESALE), 1);
      lacks('不读看不见的预售说明', t, PRESALE_NOTE);
      // 经真实映射：价格三字段齐全也不展示价格（BR-PRICE-08），标签行仍显示「预售」。
      const m: ProductCardData = mapped(',"rebate_basis":"amount_unknown","rebate_min_fen":null,"rebate_max_fen":null');
      const mt: string = ProductCardA11y.cellLabel(m);
      same('映射：读法', mt, '淘宝，' + TITLE + '，包邮，预售，' + UNKNOWN_LABEL);
      lacks('映射：不读价格', mt, '88');
    });

    // 2. 预售 + 价格不可用（Codex r1 S3「价格不可用也存在相同分支问题」）。
    it('a11yagent_cell_presale_price_unavailable_reads_presale_once', 0, () => {
      const gone: ProductCardData = unpriced('normal', true);
      gone.priceUnavailable = true;
      gone.priceUnavailableText = UNAVAILABLE;
      gone.tags = [new ProductTag('包邮')];
      const g: string = ProductCardA11y.cellLabel(gone);
      same('读法', g, '淘宝，' + TITLE + '，包邮，预售，' + UNAVAILABLE);
      same('「预售」恰一次', occurrences(g, PRESALE), 1);
      lacks('不读看不见的预售说明', g, PRESALE_NOTE);
      lacks('不读返利金额', g, '预估返');
      // 经真实映射：availability=price_unavailable。
      const m: ProductCardData = mapped(',"availability":"price_unavailable","price_fen":null,"coupon_fen":null,"final_price_fen":null');
      const mt: string = ProductCardA11y.cellLabel(m);
      same('映射：「预售」恰一次', occurrences(mt, PRESALE), 1);
      same('映射：按标签行顺序读在标题后', mt.indexOf(TITLE + '，包邮，预售') === mt.indexOf(TITLE) && mt.indexOf(TITLE) > 0, true);
      lacks('映射：不读看不见的预售说明', mt, PRESALE_NOTE);
    });

    // 3. 预售 + amount_unknown + 平台 not_launched：返利句不读，「预售」仍看得见、照读。
    it('a11yagent_cell_presale_amount_unknown_not_launched_still_reads_presale', 0, () => {
      const off: ProductCardData = unpriced('amount_unknown', true);
      off.rebateHidden = true;
      same('读法', ProductCardA11y.cellLabel(off), '淘宝，' + TITLE + '，预售');
    });

    // 4. 回归：有价格时「预售」仍只读一次；不是预售时误写的「预售」不显示也不读。
    it('a11yagent_cell_presale_regression_priced_once_and_not_presale_none', 0, () => {
      const priced: ProductCardData = mapped('');
      const p: string = ProductCardA11y.cellLabel(priced);
      same('有价格的预售「预售」恰一次', occurrences(p, PRESALE), 1);
      same('有价格的预售读出包邮', p.indexOf('包邮') > p.indexOf(TITLE), true);
      const plain: ProductCardData = unpriced('amount_unknown', false);
      plain.tags = [new ProductTag(PRESALE), new ProductTag('包邮')];
      same('不是预售：误写的「预售」不读', ProductCardA11y.cellLabel(plain), '淘宝，' + TITLE + '，包邮，' + UNKNOWN_LABEL);
    });
  });
}
