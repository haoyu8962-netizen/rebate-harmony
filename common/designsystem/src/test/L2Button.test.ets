// HM-L2-BUTTON-harmony 测试作者 v1（新鲜独立 Claude）：BuyButtonModel 的 D10-871 回落、FU-HM-OFFSHELF-STATE、F-HM-94 两条并入。
// 依据：NATIVE/HM-L2-BATCH1/brief-BUTTON.md §2.3 / §2.4 / §3「逻辑」1–8；README 末节编排裁定 D10-1177 ②（amountHidden 下字面 {amount}
// 或含本卡金额都回落 btn.buy「购买」，走契约字典，spoken 不读金额）、③（不改 specs/cta-key-vectors.json，本套件钉行为）、
// ⑪（F-HM-94：补两个存活变异用例、spoken 对 {amount} 新键读「¥」的修正）；D10-907（下架 = 禁用态 + 下架文案）。
// 用例名前缀 l1–l8 对应书 §3「逻辑」第 1–8 条；l6b 是书外推论（D10-1177 ② 字面「文案」不分状态），交回里单列。
//
// 被测接口（实现者按此提供；本文件不给假实现）：
// - BuyButtonModel.text / spoken(base, rebate, amountHidden, context)：入口先做 D10-871 回落（书 §2.3）。
// - BuyButtonModel.stateLabel(state, base, retryText, rebate, amountHidden, context): string —— 新增，BuyButton.label() 的纯逻辑
//   （书 §2.3 末条）：NORMAL → text(...)；DISABLED 且 retryText 非空 → retryText，否则动词；RETRY_LATER → retryText(...)。
// - ProductCardMapper.fromCard(...)：availability=off_shelf → BuyButtonState.DISABLED + retryText = texts(error.30141)（书 §2.4）。
//
// 期望值是抄自任务书 / 契约字典的字面量，不读实现里的常量：BUY =「购买」（btn.buy，锁 a89c1ec3a），OFF_SHELF =「商品已下架」（error.30141）。
// 不依赖时区：断言不涉及取价时间。
import { describe, it, expect } from '@ohos/hypium';
import { DefaultTexts } from 'generated';
import { BuyButtonModel, BuyContext, RebateTagContent, RebateTagModel } from '../main/ets/format/PriceModels';
import { PriceTerms } from '../main/ets/format/PriceTerms';
import { ProductCardMapper, ProductCardTexts } from '../main/ets/format/ProductCardMapper';
import { ProductCardData } from '../main/ets/components/ProductCard';
import { BuyButtonState } from '../main/ets/components/Price';

const NOW: number = 1794022200000;
/** 契约字典 btn.buy（a89c1ec3a 起「购买」；PriceTerms.buy 是「去购买」，me12 冻结，回落不得用它）。 */
const BUY: string = '购买';
/** 契约字典 error.30141。 */
const OFF_SHELF: string = '商品已下架';
/** 「稍后再试」（BR-TEXT-14；DISABLED 不得显示它）。 */
const RETRY_LATER_TEXT: string = '稍后再试';
/** 同卡单一返利 ¥2.69 的可见与读屏写法（BR-TEXT-10；读屏「2.69 元」见 adaptation-a11y-spec §9）。 */
const AMOUNT_TEXT: string = '¥2.69';
const AMOUNT_SPOKEN: string = '2.69 元';
/** 映射已填好金额的 btn.buy.rebate（「购买预估返 {amount}」）。 */
const FILLED_REBATE: string = '购买预估返 ¥2.69';
/** 将来某个带 {amount} 的新键填好后的样子（F-HM-94 S3-3：动词里有金额、却不含整段「预估返 ¥x」）。 */
const FILLED_NEW_KEY: string = '立省 ¥2.69';
const AMOUNT_PAGES: string[] = [BuyContext.LIST, BuyContext.DETAIL, BuyContext.AGENT];
const ALL_PAGES: string[] = [BuyContext.LIST, BuyContext.DETAIL, BuyContext.AGENT, BuyContext.LINK_LANDING,
  BuyContext.SHARE];

const BASE_CARD: string = '{"platform":"taobao","product_key":"tb:l2","item_ref":"ref-l2",'
  + '"link_id":"0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5c09","title":"洗衣液 3kg","price_fen":3990,"coupon_fen":1000,'
  + '"final_price_fen":2990,"est_net_price_fen":2721,"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal",'
  + '"benefit_tags":[],"is_presale":false,"cta":{"text_key":"btn.buy.rebate"},"quoted_at":"2026-11-07T09:30:00+08:00",'
  + '"stale":false,"age_sec":12,"disclaimer_keys":["price_basis"],"availability":"ok"';

/** BASE_CARD 加若干字段（extra 以逗号开头，JSON 后写的键覆盖前面的同名键）。 */
function card(extra: string): Record<string, Object> {
  return JSON.parse(BASE_CARD + extra + '}') as Record<string, Object>;
}

function same(label: string, actual: string | number | boolean | null, wanted: string | number | boolean | null): void {
  expect(label + ' = ' + JSON.stringify(actual)).assertEqual(label + ' = ' + JSON.stringify(wanted));
}

function sameList(label: string, actual: string[], wanted: string[]): void {
  expect(label + ' = ' + JSON.stringify(actual)).assertEqual(label + ' = ' + JSON.stringify(wanted));
}

function truthy(label: string, condition: boolean): void {
  expect(label + ' = ' + condition).assertEqual(label + ' = true');
}

function occurrences(text: string, part: string): number {
  return text.split(part).length - 1;
}

/** texts = 包内契约字典（缺键空串）。 */
class ContractTexts implements ProductCardTexts {
  text(key: string): string {
    return DefaultTexts.text(key) ?? '';
  }
}

/** texts = 「<键名>」（App06bReviewR1 的写法，看清楚取的是哪个键）。 */
class KeyTexts implements ProductCardTexts {
  text(key: string): string {
    return '<' + key + '>';
  }
}

/** 表里有的给表里的字，其余走契约字典。 */
class TableTexts implements ProductCardTexts {
  private readonly table: Map<string, string>;

  constructor(table: Map<string, string>) {
    this.table = table;
  }

  text(key: string): string {
    return this.table.get(key) ?? (DefaultTexts.text(key) ?? '');
  }
}

function table1(key: string, text: string): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set(key, text);
  return m;
}

class Mapped {
  readonly data: ProductCardData;
  readonly diagnostics: string[];

  constructor(data: ProductCardData, diagnostics: string[]) {
    this.data = data;
    this.diagnostics = diagnostics;
  }
}

function mapCard(c: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean,
  status: string = ProductCardMapper.PURCHASE_ON): Mapped {
  const got: string[] = [];
  const data: ProductCardData = ProductCardMapper.fromCard(c, texts, buyEnabled, NOW, status, (key: string): void => {
    got.push(key);
  });
  return new Mapped(data, got);
}

function amount269(): RebateTagContent {
  return RebateTagModel.make('normal', 269, 269, false);
}

/** 本卡全部几种返利（单值、区间、无返利、金额未知、登录查看）。 */
function allRebates(): RebateTagContent[] {
  return [amount269(), RebateTagModel.make('price_compare_risk', 135, 269, false), RebateTagModel.make('no_rebate', 0, 0, false),
    RebateTagModel.make('amount_unknown', null, null, false), RebateTagModel.make('login_required', null, null, true)];
}

function stateRaw(state: BuyButtonState): string {
  switch (state) {
    case BuyButtonState.NORMAL:
      return 'normal';
    case BuyButtonState.LOADING:
      return 'loading';
    case BuyButtonState.DISABLED:
      return 'disabled';
    case BuyButtonState.RETRY_LATER:
      return 'retry_later';
    default:
      return 'unknown';
  }
}

/** text 与 spoken 都回落成字典「购买」。 */
function expectFallback(label: string, base: string, rebate: RebateTagContent, context: string): void {
  same(label + ' text', BuyButtonModel.text(base, rebate, true, context), BUY);
  same(label + ' spoken', BuyButtonModel.spoken(base, rebate, true, context), BUY);
}

export default function l2ButtonTest() {
  describe('L2Button', () => {
    // ---------------------------------------------------------------- 前提：字典原文（不借产品常量）
    it('l0_contract_dictionary_texts_pinned', 0, () => {
      same('btn.buy', DefaultTexts.text('btn.buy') ?? null, BUY);
      same('btn.buy.rebate', DefaultTexts.text('btn.buy.rebate') ?? null, '购买预估返 {amount}');
      same('error.30141', DefaultTexts.text('error.30141') ?? null, OFF_SHELF);
      // 回落不能是 PriceTerms.buy（「去购买」）：两者不同，下面的 BUY 断言才分得开。
      truthy('PriceTerms.buy 与 btn.buy 不同', PriceTerms.buy !== BUY);
      same('PriceTerms.retryLater', PriceTerms.retryLater, RETRY_LATER_TEXT);
    });

    // ---------------------------------------------------------------- 1. 金额隐藏 + 字面 {amount} → 字典「购买」
    // 现状红因：text 在 amountHidden 时直接返回 base（含「{amount}」），spoken 也只读 base（PriceModels.ets:247-249、:260-267）。
    it('l1_hidden_literal_amount_placeholder_falls_back_to_btn_buy', 0, () => {
      const bases: string[] = ['购买预估返 {amount}', '{amount}', '立省{amount}购买'];
      for (const base of bases) {
        const rebates: RebateTagContent[] = allRebates();
        for (let i: number = 0; i < rebates.length; i++) {
          for (const context of ALL_PAGES) {
            expectFallback(base + ' / rebate#' + i + ' / ' + context, base, rebates[i], context);
          }
        }
      }
    });

    // ---------------------------------------------------------------- 2. 金额隐藏 + 映射已填的本卡金额 → 「购买」，读屏不含金额
    // 现状红因：同上；spoken 会读出「购买预估返 ¥2.69」（D10-1177 ② 定稿：回落、读屏不读金额）。
    it('l2_hidden_filled_amount_of_this_card_falls_back_and_spoken_has_no_amount', 0, () => {
      for (const context of ALL_PAGES) {
        expectFallback('filled btn.buy.rebate / ' + context, FILLED_REBATE, amount269(), context);
        expectFallback('filled new key / ' + context, FILLED_NEW_KEY, amount269(), context);
        const spoken: string = BuyButtonModel.spoken(FILLED_REBATE, amount269(), true, context);
        truthy(context + ' spoken 不含 ¥', spoken.indexOf('¥') < 0);
        truthy(context + ' spoken 不含金额数字', spoken.indexOf('2.69') < 0);
      }
      // 区间卡：动词里含本卡区间金额（¥1.35–¥2.69）同样回落。
      const range: RebateTagContent = RebateTagModel.make('price_compare_risk', 135, 269, false);
      expectFallback('filled range', '购买预估返 ' + (range.amountText ?? ''), range, BuyContext.LIST);
    });

    // 2 的端到端：映射真实填出的 buyBase（contract 字典）再交给按钮模型。
    it('l2_end_to_end_mapper_filled_base_falls_back_when_hidden', 0, () => {
      const m: Mapped = mapCard(card(''), new ContractTexts(), true);
      same('buyBase（映射已填金额）', m.data.buyBase, FILLED_REBATE);
      for (const context of AMOUNT_PAGES) {
        same(context + ' hidden text', BuyButtonModel.text(m.data.buyBase, m.data.rebate, true, context), BUY);
        same(context + ' hidden spoken', BuyButtonModel.spoken(m.data.buyBase, m.data.rebate, true, context), BUY);
      }
    });

    // ---------------------------------------------------------------- 3. amountHidden=false：与 FU-X-CTA 行为逐字相同（回归）
    // 现状应绿；防回落误伤正常路径（书 §8：D10-871 是防御，不能动到 amountHidden=false）。
    it('l3_not_hidden_keeps_fu_x_cta_behavior', 0, () => {
      for (const context of AMOUNT_PAGES) {
        same(context + ' text 已含金额不再拼后缀', BuyButtonModel.text(FILLED_REBATE, amount269(), false, context), FILLED_REBATE);
        same(context + ' spoken 金额只读一次', BuyButtonModel.spoken(FILLED_REBATE, amount269(), false, context),
          '购买预估返 ' + AMOUNT_SPOKEN);
        same(context + ' 动词拼后缀', BuyButtonModel.text('领券购买', amount269(), false, context),
          '领券购买 ' + PriceTerms.buySuffix.replace('{amount}', AMOUNT_TEXT));
        same(context + ' 动词读屏补金额', BuyButtonModel.spoken('领券购买', amount269(), false, context),
          '领券购买' + PriceTerms.comma + '预估返 ' + AMOUNT_SPOKEN);
      }
      // 端到端：未隐藏时映射出的整行文字照旧带金额。
      const m: Mapped = mapCard(card(''), new ContractTexts(), true);
      same('list title', BuyButtonModel.text(m.data.buyBase, m.data.rebate, false, BuyContext.LIST), FILLED_REBATE);
      // 不显示金额的页面（link_landing / share）不拼后缀。
      for (const context of [BuyContext.LINK_LANDING, BuyContext.SHARE]) {
        same(context + ' 不拼后缀', BuyButtonModel.text('领券购买', amount269(), false, context), '领券购买');
      }
    });

    // ---------------------------------------------------------------- 4. 金额隐藏 + 不带金额的动词 → 原样（FormatVector buyButton[6] 同口径）
    // 现状应绿；防「隐藏就一律回落」的过度实现。
    it('l4_hidden_verb_without_amount_unchanged', 0, () => {
      const verbs: string[] = ['去淘宝购买', '领券购买', '去购买（无返利）', '购买可返利', '登录查看返利', BUY, '去购买'];
      const rebates: RebateTagContent[] = allRebates();
      for (const verb of verbs) {
        for (let i: number = 0; i < rebates.length; i++) {
          for (const context of ALL_PAGES) {
            same(verb + ' / rebate#' + i + ' / ' + context + ' text', BuyButtonModel.text(verb, rebates[i], true, context), verb);
            same(verb + ' / rebate#' + i + ' / ' + context + ' spoken', BuyButtonModel.spoken(verb, rebates[i], true, context),
              verb);
          }
        }
      }
    });

    // ---------------------------------------------------------------- 5. 下架映射：DISABLED + error.30141；平台未上线时下架文案仍优先
    // 现状红因：ProductCardMapper.ets:159-164 给 RETRY_LATER（D10-907：应为禁用态 + 下架文案）。
    it('l5_off_shelf_maps_to_disabled_with_off_shelf_text', 0, () => {
      const off: Mapped = mapCard(card(',"availability":"off_shelf"'), new KeyTexts(), true);
      same('off_shelf state', stateRaw(off.data.buyState), 'disabled');
      same('off_shelf retryText', off.data.retryText, '<error.30141>');
      same('off_shelf buyBase 照旧', off.data.buyBase, '<btn.buy.rebate>');
      const contract: Mapped = mapCard(card(',"availability":"off_shelf"'), new ContractTexts(), true);
      same('off_shelf retryText（字典）', contract.data.retryText, OFF_SHELF);
      same('off_shelf buyBase（字典）', contract.data.buyBase, FILLED_REBATE);
      sameList('off_shelf 不记诊断', contract.diagnostics, []);
      for (const status of [ProductCardMapper.PURCHASE_NOT_LAUNCHED, 'maintenance']) {
        const both: Mapped = mapCard(card(',"availability":"off_shelf"'), new KeyTexts(), true, status);
        same(status + ' + off_shelf state', stateRaw(both.data.buyState), 'disabled');
        same(status + ' + off_shelf retryText（下架优先）', both.data.retryText, '<error.30141>');
      }
      // 调用方禁用（限流那份映射）也一样。
      const limited: Mapped = mapCard(card(',"availability":"off_shelf"'), new KeyTexts(), false);
      same('buyEnabled=false + off_shelf state', stateRaw(limited.data.buyState), 'disabled');
      same('buyEnabled=false + off_shelf retryText', limited.data.retryText, '<error.30141>');
      // 价格不可用仍优先于下架（ProductCardMapper.ets:159 的 !priceUnavailable 不动）。
      const noPrice: Mapped = mapCard(card(',"availability":"off_shelf","price_fen":null'), new KeyTexts(), true);
      same('price_unavailable + off_shelf state', stateRaw(noPrice.data.buyState), 'retry_later');
      same('price_unavailable + off_shelf retryText', noPrice.data.retryText, '');
      // 平台状态（非下架）不受本单影响。
      const soon: Mapped = mapCard(card(''), new KeyTexts(), true, ProductCardMapper.PURCHASE_NOT_LAUNCHED);
      same('not_launched state 照旧', stateRaw(soon.data.buyState), 'retry_later');
      const ok: Mapped = mapCard(card(''), new KeyTexts(), true);
      same('ok state', stateRaw(ok.data.buyState), 'normal');
      same('ok retryText', ok.data.retryText, '');
    });

    // ---------------------------------------------------------------- 6. stateLabel：BuyButton.label() 的纯逻辑
    // 现状红因：BuyButtonModel.stateLabel 不存在（书 §2.3 新增）；BuyButton.label() 的 DISABLED 走 default 分支、忽略 retryText。
    it('l6_state_label_disabled_retry_later_normal', 0, () => {
      const r: RebateTagContent = amount269();
      for (const verb of ['领券购买', '去购买（无返利）', BUY]) {
        same(verb + ' DISABLED + 空 retryText → 动词',
          BuyButtonModel.stateLabel(BuyButtonState.DISABLED, verb, '', r, false, BuyContext.LIST), verb);
        same(verb + ' LOADING → 动词（不拼后缀）',
          BuyButtonModel.stateLabel(BuyButtonState.LOADING, verb, '', r, false, BuyContext.LIST), verb);
      }
      truthy('DISABLED 不出现「稍后再试」',
        BuyButtonModel.stateLabel(BuyButtonState.DISABLED, '领券购买', '', r, false, BuyContext.LIST).indexOf(RETRY_LATER_TEXT) < 0);
      same('DISABLED + 下架文案', BuyButtonModel.stateLabel(BuyButtonState.DISABLED, '领券购买', OFF_SHELF, r, false,
        BuyContext.LIST), OFF_SHELF);
      same('RETRY_LATER 空串 → PriceTerms.retryLater',
        BuyButtonModel.stateLabel(BuyButtonState.RETRY_LATER, '领券购买', '', r, false, BuyContext.LIST), PriceTerms.retryLater);
      same('RETRY_LATER 给了文案', BuyButtonModel.stateLabel(BuyButtonState.RETRY_LATER, '领券购买', '淘宝返利即将开放', r, false,
        BuyContext.LIST), '淘宝返利即将开放');
      // NORMAL 与 text 同一结果（含拼后缀、D10-871 回落）。
      for (const context of ALL_PAGES) {
        for (const hidden of [false, true]) {
          for (const base of ['领券购买', FILLED_REBATE, '购买预估返 {amount}']) {
            same(base + ' / ' + context + ' / hidden=' + hidden + ' NORMAL = text',
              BuyButtonModel.stateLabel(BuyButtonState.NORMAL, base, '', r, hidden, context),
              BuyButtonModel.text(base, r, hidden, context));
          }
        }
      }
      same('NORMAL 拼后缀', BuyButtonModel.stateLabel(BuyButtonState.NORMAL, '领券购买', '', r, false, BuyContext.LIST),
        '领券购买 ' + PriceTerms.buySuffix.replace('{amount}', AMOUNT_TEXT));
      same('NORMAL 隐藏回落', BuyButtonModel.stateLabel(BuyButtonState.NORMAL, FILLED_REBATE, '', r, true, BuyContext.DETAIL), BUY);
    });

    // 6b（书外推论，交回单列）：D10-1177 ② 说「amountHidden 下文案含金额都回落」，不分状态；
    // 加载中 / 禁用（无下架文案）显示的是动词本身，动词里有本卡金额时同样不得露金额。
    it('l6b_hidden_amount_never_shown_in_loading_or_disabled', 0, () => {
      const r: RebateTagContent = amount269();
      for (const state of [BuyButtonState.LOADING, BuyButtonState.DISABLED]) {
        same(stateRaw(state) + ' hidden 已填金额', BuyButtonModel.stateLabel(state, FILLED_REBATE, '', r, true, BuyContext.LIST), BUY);
        same(stateRaw(state) + ' hidden 字面 {amount}',
          BuyButtonModel.stateLabel(state, '购买预估返 {amount}', '', r, true, BuyContext.DETAIL), BUY);
        same(stateRaw(state) + ' 未隐藏照旧', BuyButtonModel.stateLabel(state, FILLED_REBATE, '', r, false, BuyContext.LIST),
          FILLED_REBATE);
      }
      same('DISABLED hidden 有下架文案仍显示下架文案',
        BuyButtonModel.stateLabel(BuyButtonState.DISABLED, FILLED_REBATE, OFF_SHELF, r, true, BuyContext.LIST), OFF_SHELF);
    });

    // ---------------------------------------------------------------- 7. 下架卡端到端：DISABLED、按钮字「商品已下架」
    // 现状红因：映射给 RETRY_LATER；stateLabel 不存在。点击 0 次回调由设备套件 Ds02L2Ui 断言。
    it('l7_off_shelf_card_is_disabled_and_labelled_off_shelf', 0, () => {
      const m: Mapped = mapCard(card(',"availability":"off_shelf"'), new ContractTexts(), true);
      same('state', stateRaw(m.data.buyState), 'disabled');
      for (const context of AMOUNT_PAGES) {
        for (const hidden of [false, true]) {
          same(context + ' hidden=' + hidden + ' label', BuyButtonModel.stateLabel(m.data.buyState, m.data.buyBase,
            m.data.retryText, m.data.rebate, hidden, context), OFF_SHELF);
        }
      }
      // 调用方禁用但不是下架：动词，不是「稍后再试」（ProductCard.ets:369 不得再把空串换成「稍后再试」，宿主 B5 守）。
      const limited: Mapped = mapCard(card(''), new ContractTexts(), false);
      same('limited state', stateRaw(limited.data.buyState), 'disabled');
      same('limited retryText', limited.data.retryText, '');
      same('limited label', BuyButtonModel.stateLabel(limited.data.buyState, limited.data.buyBase, limited.data.retryText,
        limited.data.rebate, false, BuyContext.LIST), FILLED_REBATE);
    });

    // ---------------------------------------------------------------- 8. F-HM-94（D10-1177 ⑪）
    // S3-1：文案只含「}」也算渲染不出（renderCta 的「}」判断，FU-X-CTA 评审 M1 存活）。现状应绿，钉住防回退。
    it('l8_s3_1_closing_brace_only_text_is_unrenderable', 0, () => {
      const own: Mapped = mapCard(card(''), new TableTexts(table1('btn.buy.rebate', '购买}')), true);
      same('btn.buy.rebate → 「购买}」buyBase', own.data.buyBase, BUY);
      sameList('btn.buy.rebate → 「购买}」诊断', own.diagnostics, ['btn.buy.rebate']);
      same('btn.buy.rebate → 「购买}」state', stateRaw(own.data.buyState), 'normal');
      const fallbackBroken: Mapped = mapCard(card(',"cta":{"text_key":"cta.next.buy"}'),
        new TableTexts(table1('btn.buy', '购}买')), true);
      same('btn.buy 也只含「}」→ 包内字典', fallbackBroken.data.buyBase, BUY);
      sameList('只记原键一次', fallbackBroken.diagnostics, ['cta.next.buy']);
      const filled: Mapped = mapCard(card(''), new TableTexts(table1('btn.buy.rebate', '购买预估返 {amount}}')), true);
      same('填完仍剩「}」', filled.data.buyBase, BUY);
      sameList('填完仍剩「}」诊断', filled.diagnostics, ['btn.buy.rebate']);
    });

    // S3-2：非字符串 text_key（数字等）= 空键：''、禁用、不记诊断（与详情一致，FU-X-CTA 评审 M2c 存活）。现状应绿，钉住防回退。
    it('l8_s3_2_non_string_text_key_is_empty_key', 0, () => {
      for (const over of [',"cta":{"text_key":5}', ',"cta":{"text_key":0}', ',"cta":{"text_key":true}',
        ',"cta":{"text_key":{"k":"btn.buy"}}', ',"cta":{"text_key":["btn.buy"]}']) {
        const m: Mapped = mapCard(card(over), new ContractTexts(), true);
        same(over + ' buyBase', m.data.buyBase, '');
        same(over + ' state', stateRaw(m.data.buyState), 'disabled');
        sameList(over + ' 诊断', m.diagnostics, []);
      }
    });

    // S3-3（spoken 修正）：动词里有本卡金额、却不含整段「预估返 ¥x」时，读屏不读「¥」，金额按读屏写法只读一次，可见文字在开头。
    // 现状红因：spoken 原样返回 base（PriceModels.ets:263），读出「立省 ¥2.69」。
    it('l8_s3_3_spoken_new_amount_key_does_not_read_yuan_sign', 0, () => {
      for (const context of AMOUNT_PAGES) {
        const spoken: string = BuyButtonModel.spoken(FILLED_NEW_KEY, amount269(), false, context);
        truthy(context + ' 不含 ¥：' + spoken, spoken.indexOf('¥') < 0);
        same(context + ' 金额读屏写法恰好一次：' + spoken, occurrences(spoken, AMOUNT_SPOKEN), 1);
        truthy(context + ' 可见动词在开头：' + spoken, spoken.indexOf('立省') === 0);
        // 可见文字不变（只改读屏）。
        same(context + ' text 照旧', BuyButtonModel.text(FILLED_NEW_KEY, amount269(), false, context), FILLED_NEW_KEY);
      }
      // 端到端：将来某个新键「立省 {amount}」经映射填好（调用方 texts 给出），读屏同样不读「¥」。
      const m: Mapped = mapCard(card(',"cta":{"text_key":"btn.buy.save"}'),
        new TableTexts(table1('btn.buy.save', '立省 {amount}')), true);
      same('新键 buyBase', m.data.buyBase, FILLED_NEW_KEY);
      sameList('新键可渲染不记诊断', m.diagnostics, []);
      const spoken: string = BuyButtonModel.spoken(m.data.buyBase, m.data.rebate, false, BuyContext.DETAIL);
      truthy('端到端不含 ¥：' + spoken, spoken.indexOf('¥') < 0);
      same('端到端金额一次：' + spoken, occurrences(spoken, AMOUNT_SPOKEN), 1);
      // 已有的 btn.buy.rebate 读法不变（A8）。
      same('btn.buy.rebate 读法', BuyButtonModel.spoken(FILLED_REBATE, amount269(), false, BuyContext.LIST),
        '购买预估返 ' + AMOUNT_SPOKEN);
    });
  });
}
