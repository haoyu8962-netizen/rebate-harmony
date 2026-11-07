// FU-X-CTA-KEY-DRIFT-harmony 测试作者 v1（D10-856 / D10-857 / D10-861 / D10-907）：商品卡 cta.text_key 的渲染与未知键兜底。
// 规则与向量在 specs/cta-key-vectors.json（三端逐字节照抄 iOS，sha256 d93b2905…，95 行；gen.py 守字节）。本机单测读不了文件，
// gen.py 把全文生成为同目录 CtaKeyVectorsData.ets 的 CTA_KEY_VECTORS_JSON（同 FormatVectorsData / FormatVector.test.ets 的读法）。
//
// 被测接口（实现者按此提供；本文件不提供假实现）：
// - ProductCardMapper.fromCard(card, texts, buyEnabled, nowMillis, purchaseStatus, onCtaFallback)：末位新参数
//   onCtaFallback: (key: string) => void，缺省写 hilog；每次映射遇到渲染不出的 cta 键调一次，只给 text_key 原值。
// - ProductCardMapper.fromCardWithStatus(card, texts, buyEnabled, statusOf, nowMillis, onCtaFallback)：同上，原样交给 fromCard。
// - ProductCardKeys.BUY_FALLBACK：兜底文案键 'btn.buy'。
// - 按钮整行文字 / 读屏仍由 BuyButtonModel.text / spoken(base, rebate, amountHidden, context) 组成（BuyButton.label() / spoken() 同一调用）。
//
// 鸿蒙差异在测试里映射、不改向量（D10-907 ①；先例 H-P14 / H-R14）：见 harmonyState()。
// 不依赖时区（verify 在默认 / UTC / America/Los_Angeles 各跑一遍）：nowMillis 固定 1794022200000（与 iOS 同一时刻），
// 断言不涉及取价时间；DefaultTexts 是升锁到 a89c1ec3a 后的包内契约字典（A10 钉住几条原文）。
// 接入：List.test.ets 导入并调用 ctaKeyVectorTest()；gen.py 生成 CtaKeyVectorsData.ets（--check 查漂移）。
import { describe, it, expect } from '@ohos/hypium';
import { DefaultTexts } from 'generated';
import { CTA_KEY_VECTORS_JSON } from './CtaKeyVectorsData';
import {
  BuyButtonModel, BuyButtonState, BuyContext, CouliFormat, ProductCardData, ProductCardKeys, ProductCardMapper,
  ProductCardTexts
} from '../../Index';

/** 2026-11-07 11:30:00 +08:00（与 iOS CtaKeyVectorTests 同一时刻）。 */
const NOW: number = 1794022200000;
/** D10-857：三端统一锁到 rebate-platform a89c1ec3a（CT-26t #2450）。 */
const LOCK_COMMIT: string = 'a89c1ec3a7f4de0b069742af909eba6545358ea3';
const BUY: string = '购买';
/** 鸿蒙下架卡的按钮字（ProductCardKeys.OFF_SHELF 的契约键；这里写键名本身，不借产品常量）。 */
const OFF_SHELF_TEXT: string = 'error.30141';
const MODES: string[] = ['contract', 'echo', 'none'];
/** 显示返利金额的三个页面（BR-TEXT-14 表 C）：向量 title 与读屏只判这三个。 */
const AMOUNT_PAGES: string[] = [BuyContext.LIST, BuyContext.DETAIL, BuyContext.AGENT];
const ALL_PAGES: string[] = [BuyContext.LIST, BuyContext.DETAIL, BuyContext.AGENT, BuyContext.LINK_LANDING,
  BuyContext.SHARE];
/**
 * 锁内没有的示例新键（A3，至少 8 个）。写法避开 gitleaks generic-api-key 的误报（向量同样把 cta.v4.buy_now 换成了 cta.next.buy）。
 * 覆盖：btn.buy 前缀、多级、别的前缀、单字符、已有键加后缀、大写、键里带花括号、中文。
 */
const NEW_CTA: string[] = ['btn.buy.future_x', 'btn.buy.rebate.v2', 'cta.next.buy', 'x', 'btn.buy.rebate_suffix.new',
  'BTN.BUY', 'btn.buy.{amount}', '购买按钮', 'btn.buy.rebate_unknown.v2'];
const UNKNOWN: string = 'btn.buy.future_x';

const NO_REBATE: string = '{"rebate_basis":"no_rebate","rebate_min_fen":0,"rebate_max_fen":0,"est_net_price_fen":null}';
const AMOUNT_UNKNOWN: string = '{"rebate_basis":"amount_unknown","rebate_min_fen":null,"rebate_max_fen":null,'
  + '"est_net_price_fen":null}';
const LOGIN_REQUIRED: string = '{"rebate_basis":"login_required","rebate_min_fen":null,"rebate_max_fen":null,'
  + '"est_net_price_fen":null}';

interface CtaExpect {
  buyBase: string;
  state: string;
  diagnostic: string | null;
  title?: Record<string, string>;
}

interface CtaCase {
  id: string;
  texts: string;
  card: Record<string, Object | null>;
  buyEnabled: boolean;
  expect: CtaExpect;
  note: string;
}

interface CtaVectors {
  version: number;
  source: string;
  contractCommit: string;
  rules: string[];
  textsModes: Record<string, string>;
  harness: string;
  baseCard: Record<string, Object | null>;
  cases: CtaCase[];
}

/** 字段路径进入失败信息（同 FormatVector.test.ets 的 assertScalar 写法）。 */
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

/** 向量的三种 texts 写法（textsModes）：contract = 字典或空串；echo = 字典或键名本身；none = 一律空串。 */
class ModeTexts implements ProductCardTexts {
  private readonly mode: string;

  constructor(mode: string) {
    if (MODES.indexOf(mode) < 0) {
      throw new Error('未知 texts 模式：' + mode);
    }
    this.mode = mode;
  }

  text(key: string): string {
    if (this.mode === 'none') {
      return '';
    }
    const contract: string | undefined = DefaultTexts.text(key);
    if (this.mode === 'echo') {
      return contract ?? key;
    }
    return contract ?? '';
  }
}

/** 测试自定的 texts：表里有的给表里的字，其余交给 rest。 */
class TableTexts implements ProductCardTexts {
  private readonly table: Map<string, string>;
  private readonly rest: (key: string) => string;

  constructor(table: Map<string, string>, rest: (key: string) => string) {
    this.table = table;
    this.rest = rest;
  }

  text(key: string): string {
    return this.table.get(key) ?? this.rest(key);
  }
}

const CONTRACT_REST: (key: string) => string = (key: string): string => DefaultTexts.text(key) ?? '';
const ECHO_ALL_REST: (key: string) => string = (key: string): string => key;
const NONE_REST: (key: string) => string = (_key: string): string => '';

function table1(key: string, text: string): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  m.set(key, text);
  return m;
}

/** 一次映射的结果与这次映射收到的全部诊断（注入的 onCtaFallback 不去重）。 */
class Mapped {
  readonly data: ProductCardData;
  readonly diagnostics: string[];

  constructor(data: ProductCardData, diagnostics: string[]) {
    this.data = data;
    this.diagnostics = diagnostics;
  }
}

/** 搜索卡 / 详情大卡的入口（SearchView.toCards、ProductDetailView）。 */
function mapCard(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean,
  status: string = ProductCardMapper.PURCHASE_ON): Mapped {
  const got: string[] = [];
  const data: ProductCardData = ProductCardMapper.fromCard(card, texts, buyEnabled, NOW, status,
    (key: string): void => {
      got.push(key);
    });
  return new Mapped(data, got);
}

/** 剪贴板弹层 / 首页 / AI 卡的入口（AppClipboard.rowsOf、AppHome / AppAgent.productCard）。 */
function mapWithStatus(card: Record<string, Object>, texts: ProductCardTexts, buyEnabled: boolean,
  status: string): Mapped {
  const got: string[] = [];
  const data: ProductCardData = ProductCardMapper.fromCardWithStatus(card, texts, buyEnabled,
    (_platform: string): string => status, NOW, (key: string): void => {
      got.push(key);
    });
  return new Mapped(data, got);
}

/** BuyButtonState → 向量的状态写法（normal / loading / disabled / retry_later）。 */
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

/**
 * D10-907 ①（先例 H-P14 / H-R14：鸿蒙差异在测试里映射，不改向量文件）：鸿蒙的下架卡由映射直接给「稍后再试」态，按钮字是
 * error.30141「商品已下架」（ProductCardMapper 下架分支，APP-06b 共性第 28 条；冻结用例 App06bReviewR1.test.ets:50-53）。
 * 所以向量里 availability=off_shelf 的 disabled 在鸿蒙判为 retry_later，且 retryText = 同一 texts 给的 error.30141 文案
 * （见 a2 的下架分支）；buyBase 与诊断照向量判。其余状态与向量逐字相同。
 */
function harmonyState(card: Record<string, Object>, vectorState: string): string {
  return card['availability'] === 'off_shelf' && vectorState === 'disabled' ? 'retry_later' : vectorState;
}

/** baseCard 逐字段被 over 覆盖；值为 null 表示不带这个字段（向量 harness；ArkTS 不用 delete，直接不放）。 */
function overlay(base: Record<string, Object | null>, over: Record<string, Object | null>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const replaced: string[] = Object.keys(over);
  Object.keys(base).forEach((k: string) => {
    const v: Object | null | undefined = base[k];
    if (replaced.indexOf(k) < 0 && v !== null && v !== undefined) {
      out[k] = v;
    }
  });
  replaced.forEach((k: string) => {
    const v: Object | null | undefined = over[k];
    if (v !== null && v !== undefined) {
      out[k] = v;
    }
  });
  return out;
}

function parseOver(json: string): Record<string, Object | null> {
  return JSON.parse(json) as Record<string, Object | null>;
}

function ctaOf(key: string): Record<string, Object> {
  const cta: Record<string, Object> = {};
  cta['text_key'] = key;
  return cta;
}

/** baseCard + overJson，cta 换成 {text_key: key}。 */
function cardWith(base: Record<string, Object | null>, key: string, overJson: string = '{}'): Record<string, Object> {
  const over: Record<string, Object | null> = parseOver(overJson);
  over['cta'] = ctaOf(key);
  return overlay(base, over);
}

function ctaKeyOf(card: Record<string, Object>): string {
  const cta: Object | undefined = card['cta'];
  if (cta === undefined || cta === null || typeof cta !== 'object') {
    return '';
  }
  const key: Object | undefined = (cta as Record<string, Object>)['text_key'];
  return typeof key === 'string' ? key as string : '';
}

/** 按钮上会出现的字：buyBase，以及三个显示金额页面的整行文字与读屏——都不带花括号、不带键名。 */
function assertNoBraceNoKey(label: string, d: ProductCardData, key: string): void {
  const shown: string[] = [d.buyBase];
  for (const page of AMOUNT_PAGES) {
    shown.push(BuyButtonModel.text(d.buyBase, d.rebate, false, page));
    shown.push(BuyButtonModel.spoken(d.buyBase, d.rebate, false, page));
  }
  for (const s of shown) {
    truthy(label + ' 无花括号「' + s + '」', s.indexOf('{') < 0 && s.indexOf('}') < 0);
    if (key.length > 0) {
      truthy(label + ' 无键名 ' + key + '「' + s + '」', s.indexOf(key) < 0);
    }
  }
}

export default function ctaKeyVectorTest() {
  describe('CtaKeyVector', () => {
    const v: CtaVectors = JSON.parse(CTA_KEY_VECTORS_JSON) as CtaVectors;
    const base: Record<string, Object | null> = v.baseCard;

    // ---------------------------------------------------------------- A1 向量文件本身
    it('a1_vector_file_shape', 0, () => {
      same('version', v.version, 1);
      same('contractCommit', v.contractCommit, LOCK_COMMIT);
      same('source 非空', v.source.length > 0, true);
      same('harness 非空', v.harness.length > 0, true);
      same('cases.length', v.cases.length, 23);
      const ids: string[] = [];
      for (const row of v.cases) {
        truthy('id 非空', row.id.length > 0);
        truthy(row.id + ' id 不重复', ids.indexOf(row.id) < 0);
        ids.push(row.id);
        truthy(row.id + ' note 非空', row.note.length > 0);
        truthy(row.id + ' texts 模式「' + row.texts + '」已登记', MODES.indexOf(row.texts) >= 0);
        truthy(row.id + ' state 取值', ['normal', 'disabled', 'retry_later'].indexOf(row.expect.state) >= 0);
      }
      sameList('textsModes', Object.keys(v.textsModes).sort(), ['contract', 'echo', 'none']);
      for (const mode of MODES) {
        truthy('texts 模式 ' + mode + ' 有用例', v.cases.some((r: CtaCase): boolean => r.texts === mode));
      }
      same('rules.length', v.rules.length, 4);
      for (let i: number = 0; i < 4; i++) {
        const rule: string = 'R' + (i + 1);
        truthy('rules[' + i + '] 以 ' + rule + ' 开头', v.rules[i].startsWith(rule + ' '));
        truthy(rule + ' 有用例', v.cases.some((r: CtaCase): boolean => r.note.indexOf(rule) >= 0));
      }
      same('baseCard.cta.text_key', ctaKeyOf(overlay(base, parseOver('{}'))), 'btn.buy.rebate');
    });

    // ---------------------------------------------------------------- A2 23 条逐条跑（各按自己的 textsMode）
    it('a2_vectors_present', 0, () => {
      same('cases.length', v.cases.length, 23);
    });
    for (const row of v.cases) {
      it('a2_vector_' + row.id, 0, () => {
        const label: string = row.id + '（' + row.note + '）';
        const card: Record<string, Object> = overlay(base, row.card);
        const key: string = ctaKeyOf(card);
        const texts: ProductCardTexts = new ModeTexts(row.texts);
        const e: CtaExpect = row.expect;
        const m: Mapped = mapCard(card, texts, row.buyEnabled);
        same(label + ' buyBase', m.data.buyBase, e.buyBase);
        const wantState: string = harmonyState(card, e.state);
        same(label + ' state', stateRaw(m.data.buyState), wantState);
        if (wantState !== e.state) {
          // 下架映射（D10-907 ①）：按钮字是同一 texts 给的 error.30141 文案，不是空串。
          const offShelf: string = texts.text(OFF_SHELF_TEXT);
          truthy(label + ' error.30141 文案非空', offShelf.length > 0);
          same(label + ' retryText（error.30141）', m.data.retryText, offShelf);
        }
        const wantDiagnostics: string[] = [];
        if (e.diagnostic !== null) {
          wantDiagnostics.push(e.diagnostic);
        }
        sameList(label + ' 诊断（恰好一条只带 text_key，或者没有）', m.diagnostics, wantDiagnostics);
        assertNoBraceNoKey(label, m.data, key);
        const titles: Record<string, string> | undefined = e.title;
        if (titles !== undefined) {
          Object.keys(titles).forEach((page: string) => {
            truthy(label + ' title 页面名 ' + page, ALL_PAGES.indexOf(page) >= 0);
            same(label + ' title.' + page, BuyButtonModel.text(m.data.buyBase, m.data.rebate, false, page), titles[page]);
          });
        }
        // 剪贴板弹层 / 首页 / AI 卡走 fromCardWithStatus：同一张卡、平台 on，结果与 fromCard 相同，诊断原样转过去。
        const w: Mapped = mapWithStatus(card, texts, row.buyEnabled, ProductCardMapper.PURCHASE_ON);
        same(label + ' fromCardWithStatus buyBase', w.data.buyBase, e.buyBase);
        same(label + ' fromCardWithStatus state', stateRaw(w.data.buyState), wantState);
        sameList(label + ' fromCardWithStatus 诊断', w.diagnostics, wantDiagnostics);
      });
    }

    // ---------------------------------------------------------------- A3 任意锁外键都能点
    it('a3_any_unknown_key_is_tappable_with_buy_text', 0, () => {
      truthy('示例新键 ≥ 8 个', NEW_CTA.length >= 8);
      for (const key of NEW_CTA) {
        truthy(key + ' 不在锁内字典', DefaultTexts.text(key) === undefined);
        for (const mode of MODES) {
          const label: string = key + ' / ' + mode;
          const card: Record<string, Object> = cardWith(base, key);
          const m: Mapped = mapCard(card, new ModeTexts(mode), true);
          same(label + ' buyBase', m.data.buyBase, BUY);
          same(label + ' state（缺键本身不置灰）', stateRaw(m.data.buyState), 'normal');
          sameList(label + ' 诊断', m.diagnostics, [key]);
          assertNoBraceNoKey(label, m.data, key);
          for (const page of AMOUNT_PAGES) {
            truthy(label + ' ' + page + ' 整行以「购买」开头',
              BuyButtonModel.text(m.data.buyBase, m.data.rebate, false, page).startsWith(BUY));
          }
          const w: Mapped = mapWithStatus(card, new ModeTexts(mode), true, ProductCardMapper.PURCHASE_ON);
          same(label + ' fromCardWithStatus buyBase', w.data.buyBase, BUY);
          same(label + ' fromCardWithStatus state', stateRaw(w.data.buyState), 'normal');
          sameList(label + ' fromCardWithStatus 诊断', w.diagnostics, [key]);
        }
      }
    });

    // ---------------------------------------------------------------- A4 兜底先经调用方 texts，再取包内契约字典
    it('a4_fallback_goes_through_caller_texts_first', 0, () => {
      same('BUY_FALLBACK', ProductCardKeys.BUY_FALLBACK, 'btn.buy');
      const card: Record<string, Object> = cardWith(base, UNKNOWN);
      // ① texts 给 btn.buy 一个自己的字（草稿 / 下发文案可覆盖）：用它。
      const own: Mapped = mapCard(card, new TableTexts(table1('btn.buy', '立即购买'), NONE_REST), true);
      same('① texts 自己的 btn.buy', own.data.buyBase, '立即购买');
      same('① state', stateRaw(own.data.buyState), 'normal');
      sameList('① 诊断', own.diagnostics, [UNKNOWN]);
      // ② texts 对 btn.buy 也回键名本身：渲染不出，改用包内契约字典。
      const echo: Mapped = mapCard(card, new TableTexts(new Map<string, string>(), ECHO_ALL_REST), true);
      same('② btn.buy 回键名 → 包内字典', echo.data.buyBase, BUY);
      sameList('② 诊断只记原键一次', echo.diagnostics, [UNKNOWN]);
      // ③ texts 的 btn.buy 带客户端不认识的变量：渲染不出，改用包内契约字典。
      const brace: Mapped = mapCard(card, new TableTexts(table1('btn.buy', '购买{x}'), NONE_REST), true);
      same('③ btn.buy 带 {x} → 包内字典', brace.data.buyBase, BUY);
      sameList('③ 诊断', brace.diagnostics, [UNKNOWN]);
      // ④ texts 一律空串：包内契约字典（同向量 unknown.none）。
      const none: Mapped = mapCard(card, new TableTexts(new Map<string, string>(), NONE_REST), true);
      same('④ texts 全空 → 包内字典', none.data.buyBase, BUY);
      sameList('④ 诊断', none.diagnostics, [UNKNOWN]);
      // 兜底不换键：同一张卡的 cta 原样（映射不改卡片）。
      same('卡片 cta 原样', ctaKeyOf(card), UNKNOWN);
    });

    // 已知键也经调用方 texts（R1：不再写死 PriceTerms「去购买 / 领券购买 / 去购买（无返利）」）。
    it('a4b_known_keys_read_caller_texts_not_price_terms', 0, () => {
      const table: Map<string, string> = new Map<string, string>();
      table.set('btn.buy', '买它');
      table.set('btn.buy.coupon', '领券买它');
      table.set('btn.buy.no_rebate', '买它（无返利）');
      const texts: TableTexts = new TableTexts(table, NONE_REST);
      const rows: string[][] = [['btn.buy', '{}'], ['btn.buy.coupon', '{}'], ['btn.buy.no_rebate', NO_REBATE]];
      for (const r of rows) {
        const m: Mapped = mapCard(cardWith(base, r[0], r[1]), texts, true);
        same(r[0] + ' 取调用方 texts', m.data.buyBase, table.get(r[0]) ?? '');
        same(r[0] + ' state', stateRaw(m.data.buyState), 'normal');
        sameList(r[0] + ' 不记诊断', m.diagnostics, []);
      }
    });

    // ---------------------------------------------------------------- A5 诊断只带键
    it('a5_diagnostic_carries_only_the_key', 0, () => {
      const over: Record<string, Object | null> = {};
      over['title'] = '张三 13800001111 的收货地址';
      over['shop_name'] = '某某旗舰店';
      over['cta'] = ctaOf(UNKNOWN);
      const card: Record<string, Object> = overlay(base, over);
      const m: Mapped = mapCard(card, new ModeTexts('contract'), true);
      sameList('诊断恰好一条、等于 text_key', m.diagnostics, [UNKNOWN]);
      const joined: string = m.diagnostics.join('|');
      const forbidden: string[] = ['张三', '13800001111', '收货地址', '洗衣液', 'tb:cta', 'ref-cta', '0199a3b4',
        '某某旗舰店', '2990', '29.9', '2721', '3990', '2.69', 'taobao'];
      for (const field of ['title', 'product_key', 'item_ref', 'link_id', 'shop_name', 'platform']) {
        const value: Object | undefined = card[field];
        if (typeof value === 'string') {
          forbidden.push(value as string);
        }
      }
      for (const word of forbidden) {
        truthy('诊断不含「' + word + '」', joined.indexOf(word) < 0);
      }
    });

    // ---------------------------------------------------------------- A6 已知键不记诊断
    it('a6_known_keys_log_nothing', 0, () => {
      const rows: string[][] = [['btn.buy', '{}'], ['btn.buy.coupon', '{}'], ['btn.buy.no_rebate', NO_REBATE],
        ['btn.buy.rebate', '{}'], ['btn.buy.rebate_unknown', AMOUNT_UNKNOWN], ['rebate_login_to_view', LOGIN_REQUIRED]];
      for (const mode of ['contract', 'echo']) {
        for (const r of rows) {
          const label: string = r[0] + ' / ' + mode;
          const m: Mapped = mapCard(cardWith(base, r[0], r[1]), new ModeTexts(mode), true);
          sameList(label + ' 不记诊断', m.diagnostics, []);
          same(label + ' state', stateRaw(m.data.buyState), 'normal');
          truthy(label + ' 按钮有字', m.data.buyBase.length > 0);
          truthy(label + ' 不显示键名', m.data.buyBase.indexOf(r[0]) < 0);
        }
      }
    });

    // ---------------------------------------------------------------- A7 返利键的金额与返利标签同源
    it('a7_rebate_key_uses_same_amount_as_tag', 0, () => {
      for (const fen of [1, 269, 500, 123456]) {
        const label: string = 'btn.buy.rebate ' + fen + ' 分';
        const card: Record<string, Object> = cardWith(base, 'btn.buy.rebate',
          '{"rebate_min_fen":' + fen + ',"rebate_max_fen":' + fen + '}');
        const m: Mapped = mapCard(card, new ModeTexts('contract'), true);
        const amount: string | null = m.data.rebate.amountText;
        same(label + ' 返利标签种类', m.data.rebate.kindRaw, 'amount');
        same(label + ' 标签金额 = CouliFormat.money', amount, CouliFormat.money(fen));
        same(label + ' buyBase', m.data.buyBase, '购买预估返 ' + (amount ?? '<标签没有金额>'));
        truthy(label + ' 返利标签以同一金额结尾', amount !== null && m.data.rebate.text.endsWith(amount));
        sameList(label + ' 不记诊断', m.diagnostics, []);
      }
    });

    // ---------------------------------------------------------------- A8 读屏金额只读一次（句式转开发验收，D10-861 ⑤）
    it('a8_rebate_key_spoken_reads_amount_once', 0, () => {
      const m: Mapped = mapCard(cardWith(base, 'btn.buy.rebate'), new ModeTexts('contract'), true);
      for (const page of AMOUNT_PAGES) {
        const s: string = BuyButtonModel.spoken(m.data.buyBase, m.data.rebate, false, page);
        const label: string = page + ' 读屏「' + s + '」';
        truthy(label + ' 以「购买」开头', s.startsWith(BUY));
        truthy(label + ' 无花括号', s.indexOf('{') < 0 && s.indexOf('}') < 0);
        truthy(label + ' 不读「¥」', s.indexOf('¥') < 0);
        same(label + ' 「预估返」次数', occurrences(s, '预估返'), 1);
        same(label + ' 金额 2.69 次数', occurrences(s, '2.69'), 1);
      }
    });

    // ---------------------------------------------------------------- A9 购买状态压过兜底
    it('a9_purchase_status_still_wins_over_fallback', 0, () => {
      const texts: TableTexts = new TableTexts(table1('platform.taobao', '淘宝'), CONTRACT_REST);
      const card: Record<string, Object> = cardWith(base, UNKNOWN);
      // 维护中：「稍后再试」（retryText 照旧为空串，组件显示 PriceTerms.retryLater）。
      const maintenance: Mapped = mapCard(card, texts, true, 'maintenance');
      same('maintenance state', stateRaw(maintenance.data.buyState), 'retry_later');
      same('maintenance retryText 照旧', maintenance.data.retryText, '');
      same('maintenance buyBase', maintenance.data.buyBase, BUY);
      sameList('maintenance 诊断', maintenance.diagnostics, [UNKNOWN]);
      // 未开放：「{平台}返利即将开放」，返利照旧隐藏。
      const soon: Mapped = mapCard(card, texts, true, ProductCardMapper.PURCHASE_NOT_LAUNCHED);
      same('not_launched state', stateRaw(soon.data.buyState), 'retry_later');
      same('not_launched retryText 照旧', soon.data.retryText, '淘宝返利即将开放');
      same('not_launched 返利隐藏', soon.data.rebateHidden, true);
      same('not_launched buyBase', soon.data.buyBase, BUY);
      sameList('not_launched 诊断', soon.diagnostics, [UNKNOWN]);
      // 剪贴板 / 首页 / AI 卡的入口按卡片平台取状态，同样压过兜底。
      const viaStatus: Mapped = mapWithStatus(card, texts, true, 'maintenance');
      same('fromCardWithStatus maintenance state', stateRaw(viaStatus.data.buyState), 'retry_later');
      same('fromCardWithStatus maintenance buyBase', viaStatus.data.buyBase, BUY);
      sameList('fromCardWithStatus maintenance 诊断', viaStatus.diagnostics, [UNKNOWN]);
      const soonViaStatus: Mapped = mapWithStatus(card, texts, true, ProductCardMapper.PURCHASE_NOT_LAUNCHED);
      same('fromCardWithStatus not_launched retryText', soonViaStatus.data.retryText, '淘宝返利即将开放');
      // 价格不可用：照旧「稍后再试」。
      const noPrice: Mapped = mapCard(cardWith(base, UNKNOWN, '{"price_fen":null,"availability":"price_unavailable"}'),
        texts, true);
      same('price_unavailable state', stateRaw(noPrice.data.buyState), 'retry_later');
      same('price_unavailable buyBase', noPrice.data.buyBase, BUY);
      sameList('price_unavailable 诊断', noPrice.diagnostics, [UNKNOWN]);
      // 调用方禁用（搜索页限流的那份映射，buyEnabled=false）：照旧禁用，但按钮有字。
      const limited: Mapped = mapCard(card, texts, false);
      same('buyEnabled=false state', stateRaw(limited.data.buyState), 'disabled');
      same('buyEnabled=false buyBase', limited.data.buyBase, BUY);
      sameList('buyEnabled=false 诊断', limited.diagnostics, [UNKNOWN]);
      // 下架（D10-907 ① 的鸿蒙映射）：「商品已下架」，按钮有字。
      const gone: Mapped = mapCard(cardWith(base, UNKNOWN, '{"availability":"off_shelf"}'), texts, false);
      same('off_shelf state', stateRaw(gone.data.buyState), 'retry_later');
      same('off_shelf retryText', gone.data.retryText, DefaultTexts.text(OFF_SHELF_TEXT) ?? '<字典缺 error.30141>');
      same('off_shelf buyBase', gone.data.buyBase, BUY);
      sameList('off_shelf 诊断', gone.diagnostics, [UNKNOWN]);
    });

    // ---------------------------------------------------------------- A10 锁内字典（属于提交 1：未升锁的工作树上红）
    it('a10_locked_dictionary_has_buy_keys', 0, () => {
      same('btn.buy', DefaultTexts.text('btn.buy') ?? null, '购买');
      same('btn.buy.rebate', DefaultTexts.text('btn.buy.rebate') ?? null, '购买预估返 {amount}');
      same('btn.buy.rebate_unknown', DefaultTexts.text('btn.buy.rebate_unknown') ?? null, '购买可返利');
      same('rebate_login_to_view', DefaultTexts.text('rebate_login_to_view') ?? null, '登录查看返利');
      // 向量还依赖的几条原文（这次升锁没改值）。
      same('btn.buy.coupon', DefaultTexts.text('btn.buy.coupon') ?? null, '领券购买');
      same('btn.buy.no_rebate', DefaultTexts.text('btn.buy.no_rebate') ?? null, '去购买（无返利）');
      same('error.30141', DefaultTexts.text(OFF_SHELF_TEXT) ?? null, '商品已下架');
      same('platform_coming_soon', DefaultTexts.text('platform_coming_soon') ?? null, '{platform_name}返利即将开放');
      // 向量的锁外键确实不在锁内。
      same('btn.buy.future_x 不在锁内', DefaultTexts.text(UNKNOWN) === undefined, true);
      same('cta.next.buy 不在锁内', DefaultTexts.text('cta.next.buy') === undefined, true);
    });

    // ---------------------------------------------------------------- R4 守卫：没有 cta / 空键仍禁用、不兜底（D10-861 ①）
    it('a11_missing_cta_or_empty_key_still_disabled_without_fallback', 0, () => {
      const overs: string[] = ['{"cta":null}', '{"cta":{}}', '{"cta":{"text_key":""}}', '{"cta":{"text_key":null}}'];
      for (const overJson of overs) {
        for (const mode of MODES) {
          const label: string = overJson + ' / ' + mode;
          const card: Record<string, Object> = overlay(base, parseOver(overJson));
          const m: Mapped = mapCard(card, new ModeTexts(mode), true);
          same(label + ' buyBase', m.data.buyBase, '');
          same(label + ' state', stateRaw(m.data.buyState), 'disabled');
          sameList(label + ' 不记诊断', m.diagnostics, []);
          const w: Mapped = mapWithStatus(card, new ModeTexts(mode), true, ProductCardMapper.PURCHASE_ON);
          same(label + ' fromCardWithStatus state', stateRaw(w.data.buyState), 'disabled');
          sameList(label + ' fromCardWithStatus 不记诊断', w.diagnostics, []);
        }
      }
    });
  });
}
