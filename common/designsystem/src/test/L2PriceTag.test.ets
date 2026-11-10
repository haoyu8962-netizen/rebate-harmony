// HM-L2-PRICE-TAG-harmony 测试作者 v1（新鲜独立 Claude，先红）：价格 / 返利标签「逻辑不改、保持绿」的显式钉子 + 减弱动态的数字过渡策略。
// 依据：NATIVE/HM-L2-BATCH1/brief-PRICE-TAG.md §2.2、§2.3、§3「逻辑」1–3；README 末节编排裁定 D10-1177 ④（不做金额隐藏变体，
// CardAmountMask 原样留作防御）、⑤（金额拆独立 Text 挂系统 NumericTextTransition；探针不过就直接替换）；D10-638（返利按接口实际单值，
// 服务端 min=max）；D10-1163 ①（减弱动态直接替换）；BR-TEXT-10（App 金额写法：「¥」+ 元，最多两位小数，去末尾 0，无千分位）。
// 用例名前缀 p1–p3 对应书 §3「逻辑」第 1–3 条；p4 是 D10-1177 ④ 的防御钉子（与 FormatVector / PriceModelEdge 同口径，那两份不动）。
//
// 被测接口（实现者按此提供；本文件不给假实现）：
// - MotionPolicy.numericTransition(reduced: boolean): boolean —— 新增（书 §3 逻辑 3：「抽布尔纯函数，放 logic/MotionPolicy.ets」），
//   金额 Text 要不要挂系统数字过渡：未减弱 true、减弱 false（D10-1163 ① 减弱动态直接替换）。纯函数，不引用 ArkUI 全局
//   NumericTextTransition、无 @kit 依赖（进 Logic.ets 的文件）。README ⑤ 探针不过、退化为直接替换时这条策略照样保留（批 2 AMOUNT-GRID /
//   WALLET-HERO 复用），组件不挂过渡由宿主守卫 check_l2_price.py --numeric replace 钉。
// - 其余全是现有接口（PriceTagModel / RebateTagModel / CardAmountMask / CouliFormat），本单不改逻辑，这里只钉行为。
//
// 期望值是抄自任务书 / BR / 目录样例的字面量，不读实现里的常量；设备套件 Ds02L2Ui 的 l2price_ 段读的是同一组字面量。
import { describe, it, expect } from '@ohos/hypium';
import { CardAmountMask, PriceTagContent, PriceTagModel, RebateKind, RebateTagContent, RebateTagModel } from '../main/ets/format/PriceModels';
import { CouliFormat } from '../main/ets/format/CouliFormat';
import { MotionKind, MotionPolicy, MotionSpec } from '../main/ets/logic/MotionPolicy';

/** BR-TEXT-10 的分 → 文字（逐条抄书：去末尾 0、去多余小数点、无千分位）。 */
const MONEY_CASES: string[][] = [
  ['1', '¥0.01'], ['5', '¥0.05'], ['10', '¥0.1'], ['100', '¥1'], ['269', '¥2.69'], ['1345', '¥13.45'], ['1990', '¥19.9'],
  ['3990', '¥39.9'], ['100000', '¥1000'], ['123456', '¥1234.56'], ['9999999', '¥99999.99'], ['10099999', '¥100999.99'],
  ['123456789', '¥1234567.89'], ['100000000', '¥1000000']
];

/**
 * 目录 PriceTag 样例（CatalogSampleViews.BusinessSample.price()）的主价：[平台, 券前分, 券分, 券后分, 预售, 口径词, 主价文字]。
 * normal / long-price 两态；设备用例 l2price_01 / 03 按这些文字找金额节点。
 */
const CATALOG_PRICES: (string | number | boolean)[][] = [
  ['taobao', 2345, 1000, 1345, false, '券后', '¥13.45'],
  ['taobao', 10099999, 1000, 9999999, false, '券后', '¥99999.99'],
  ['taobao', 3990, 0, 3990, false, '售价', '¥39.9'],
  ['taobao', 10099999, 0, 10099999, false, '售价', '¥100999.99'],
  ['pdd', 1990, 300, 1690, false, '拼单券后', '¥16.9'],
  ['pdd', 10099999, 300, 10099699, false, '拼单券后', '¥100996.99'],
  ['taobao', 5678, 1000, 4678, true, '券后', '¥46.78'],
  ['taobao', 10099999, 1000, 9999999, true, '券后', '¥99999.99'],
  // 目录「切换金额」（catalog-amount-toggle）后的主价：券后价 −100 分（Ds02L2Ui l2price_03）。
  ['taobao', 2345, 1100, 1245, false, '券后', '¥12.45'],
  ['taobao', 3890, 0, 3890, false, '售价', '¥38.9'],
  ['pdd', 1990, 400, 1590, false, '拼单券后', '¥15.9']
];

function same(label: string, actual: string | number | boolean | null, wanted: string | number | boolean | null): void {
  expect(label + ' = ' + JSON.stringify(actual)).assertEqual(label + ' = ' + JSON.stringify(wanted));
}

function sameList(label: string, actual: string[], wanted: string[]): void {
  expect(label + ' = ' + JSON.stringify(actual)).assertEqual(label + ' = ' + JSON.stringify(wanted));
}

function truthy(label: string, condition: boolean): void {
  expect(label + ' ' + condition).assertEqual(label + ' true');
}

/** 千分位 / 空格 / 全角逗号都不许出现在金额里（BR-TEXT-10「无千分位」）。 */
function noGrouping(label: string, text: string): void {
  truthy(label + ' 无千分位 ' + JSON.stringify(text), text.indexOf(',') < 0 && text.indexOf('，') < 0 && text.indexOf(' ') < 0
    && text.indexOf('\u00a0') < 0 && text.indexOf('\'') < 0);
}

export default function l2PriceTagTest() {
  describe('L2PriceTag', () => {
    // 书 §3 逻辑 1：单一金额格式化、无千分位（BR-TEXT-10）。
    it('p1_money_single_amount_no_thousands_separator', 0, () => {
      for (const c of MONEY_CASES) {
        const got: string = CouliFormat.money(Number(c[0]));
        same('money(' + c[0] + ')', got, c[1]);
        noGrouping('money(' + c[0] + ')', got);
      }
      // 读屏数字与显示同一套整数运算，也不分组。
      same('moneySpoken(123456789)', CouliFormat.moneySpoken(123456789), '1234567.89 元');
      same('rebateRange 单值', CouliFormat.rebateRange(269, 269), '¥2.69');
    });

    // 书 §3 逻辑 1：PriceTag 主价 = 券后价 / 售价的单一金额（目录 normal / long-price / 切换后的值），口径词照 BR-PRICE-04。
    it('p1_price_tag_main_amount_is_single_final_price', 0, () => {
      for (const row of CATALOG_PRICES) {
        const c: PriceTagContent = PriceTagModel.make(row[0] as string, row[1] as number, row[2] as number, row[3] as number,
          row[4] as boolean);
        const tag: string = row[0] + '/' + row[3] + (row[4] ? '/presale' : '');
        same(tag + ' mainAmount', c.mainAmount, row[6] as string);
        same(tag + ' mainLabel', c.mainLabel, row[5] as string);
        same(tag + ' mainAmount = CouliFormat.money(final)', c.mainAmount, CouliFormat.money(row[3] as number));
        noGrouping(tag + ' mainAmount', c.mainAmount);
        truthy(tag + ' 主价只有一个 ¥', c.mainAmount.split('¥').length === 2);
        // 主价文字里只有金额：口径词在 mainLabel（拆 Text 后口径词与金额是两个节点，金额节点只装 mainAmount）。
        truthy(tag + ' mainAmount 不含口径词', c.mainAmount.indexOf(row[5] as string) < 0);
      }
      // 改价后中性内容（APP-06b H-R2-04）同口径：只给金额。
      const n: PriceTagContent = PriceTagModel.neutral(9999999, false);
      same('neutral mainAmount', n.mainAmount, '¥99999.99');
      same('neutral mainLabel', n.mainLabel, '');
    });

    // 书 §3 逻辑 1 + 2（D10-638）：返利单值 min=max → AMOUNT，金额只有一段、无千分位；目录 single / large / block 与切换后的值。
    it('p2_d10_638_min_equals_max_is_single_rebate_amount', 0, () => {
      const cases: (string | number)[][] = [
        ['normal', 269, '¥2.69', '2.69 元'], ['price_compare_risk', 269, '¥2.69', '2.69 元'], ['normal', 369, '¥3.69', '3.69 元'],
        ['normal', 5, '¥0.05', '0.05 元'], ['normal', 100, '¥1', '1 元'], ['normal', 1234567, '¥12345.67', '12345.67 元'],
        ['price_compare_risk', 9999999, '¥99999.99', '99999.99 元']
      ];
      for (const c of cases) {
        const fen: number = c[1] as number;
        const r: RebateTagContent = RebateTagModel.make(c[0] as string, fen, fen, false);
        const tag: string = c[0] + '/' + fen;
        same(tag + ' kind', r.kindRaw, 'amount');
        truthy(tag + ' hasAmount', r.hasAmount);
        same(tag + ' amountText', r.amountText, c[2] as string);
        sameList(tag + ' amountParts（单值一段）', r.amountParts, [c[2] as string]);
        same(tag + ' text', r.text, '预估返 ' + (c[2] as string));
        same(tag + ' spoken', r.spokenText, '预估返 ' + (c[3] as string));
        noGrouping(tag + ' amountText', r.amountText ?? '');
        truthy(tag + ' 不含区间连接符', (r.amountText ?? '').indexOf('–') < 0);
      }
    });

    // 书 §3 逻辑 2：RANGE 分支只作兼容保留（DETAIL-V3 brief-common.md:150）——仍在、行为不变；不新增种类（新入口由宿主守卫 P6 钉）。
    it('p2_range_branch_kept_for_compat_only', 0, () => {
      const r: RebateTagContent = RebateTagModel.make('price_compare_risk', 56, 112, false);
      same('range kind', r.kindRaw, 'range');
      same('range amountText', r.amountText, '¥0.56–¥1.12');
      sameList('range amountParts', r.amountParts, ['¥0.56', '–¥1.12']);
      same('range spoken', r.spokenText, '预估返 0.56 元到1.12 元');
      const zeroMin: RebateTagContent = RebateTagModel.make('normal', 0, 5, false);
      same('min=0 仍是 range', zeroMin.kindRaw, 'range');
      const kinds: string[] = [RebateKind.AMOUNT, RebateKind.RANGE, RebateKind.NONE, RebateKind.UNKNOWN, RebateKind.LOGIN];
      sameList('RebateKind 只有这 5 种取值', kinds, ['amount', 'range', 'none', 'unknown', 'login']);
      // 其余三种不带金额（目录 amount_unknown / login_required / no_rebate），文字取契约字典 / 术语表。
      same('amount_unknown', RebateTagModel.make('amount_unknown', null, null, false).text, '可返利，金额以订单为准');
      same('login_required', RebateTagModel.make('login_required', null, null, true).text, '登录查看返利');
      same('no_rebate', RebateTagModel.make('no_rebate', 0, 0, false).text, '暂无返利');
      truthy('不带金额的 amountText 为 null', RebateTagModel.make('amount_unknown', null, null, false).amountText === null
        && RebateTagModel.make('login_required', null, null, true).amountText === null);
    });

    // 书 §3 逻辑 3（D10-1163 ①）：减弱动态 → 不挂数字过渡（直接替换）；未减弱 → 挂。纯函数，重复调用结果稳定，不受其它策略调用影响。
    it('p3_reduced_motion_numeric_transition_policy', 0, () => {
      same('numericTransition(reduced=true)', MotionPolicy.numericTransition(true), false);
      same('numericTransition(reduced=false)', MotionPolicy.numericTransition(false), true);
      const spec: MotionSpec = MotionPolicy.resolve(true, MotionKind.ENTER);
      same('resolve 不受影响（减弱 durationMs）', spec.durationMs, 0);
      for (let i: number = 0; i < 3; i++) {
        same('第 ' + i + ' 次 reduced=true', MotionPolicy.numericTransition(true), false);
        same('第 ' + i + ' 次 reduced=false', MotionPolicy.numericTransition(false), true);
      }
    });

    // D10-1177 ④：不做金额隐藏变体；CardAmountMask 原样留作防御（与 PriceModelEdge:80-103 同口径，那份不动）。
    it('p4_amount_hidden_defense_unchanged', 0, () => {
      const single: RebateTagContent = RebateTagModel.make('normal', 269, 269, false);
      const masked: RebateTagContent = CardAmountMask.rebate(single, true);
      same('masked kind', masked.kindRaw, 'amount');
      same('masked text', masked.text, '预估返 ****');
      same('masked amountText', masked.amountText, '****');
      sameList('masked amountParts', masked.amountParts, ['****']);
      same('masked spoken', masked.spokenText, '预估返，金额已隐藏');
      truthy('不隐藏时原样返回', CardAmountMask.rebate(single, false) === single);
      const unknown: RebateTagContent = RebateTagModel.make('amount_unknown', null, null, false);
      truthy('不带金额的原样返回', CardAmountMask.rebate(unknown, true) === unknown);
      same('estNet 隐藏', CardAmountMask.estNet('预估返后 ¥27.21', true), null);
      same('estNet 不隐藏', CardAmountMask.estNet('预估返后 ¥27.21', false), '预估返后 ¥27.21');
      // 价格不在隐藏范围（D10-871）：PriceTagModel 没有隐藏入参，主价照常是金额。
      same('价格照常', PriceTagModel.make('taobao', 2345, 1000, 1345, false).mainAmount, '¥13.45');
    });
  });
}
