// Debug / Staging 专用：搜索与商品详情的本机假数据（APP-06a 冒烟与设计稿截图）。只在 product=staging 编译，Release 没有本文件
// （tools/ci/release-scan.sh 查 COULI_FAKE_SEARCH_SERVER_APP06A_4f8e27）。由 DebugFakeServer 在启动参数打开时调用，不发任何网络请求。
// 商品数据照设计稿 Search / SearchEmpty / Product 的样例（sample-data.md），金额是整数分。
import { BundledConfig } from 'generated';
import { DebugFakeTrade } from './DebugFakeTrade';

/** 固定标记（release-scan 的内容标记）。 */
export const DEBUG_FAKE_SEARCH_MARKER: string = 'COULI_FAKE_SEARCH_SERVER_APP06A_4f8e27';

/** 一次假回答：业务码、data（JSON 文本）、延迟毫秒。 */
export class FakeAnswer {
  readonly code: number;
  readonly data: string;
  readonly delayMillis: number;
  /** 42901 的 Retry-After 秒数（响应头）；没有为 null。 */
  readonly retryAfter: string | null;

  constructor(code: number, data: string, delayMillis: number = 400, retryAfter: string | null = null) {
    this.code = code;
    this.data = data;
    this.delayMillis = delayMillis;
    this.retryAfter = retryAfter;
  }
}

class Sample {
  key: string = '';
  title: string = '';
  shop: string = '';
  priceFen: number = 0;
  couponFen: number = 0;
  finalFen: number = 0;
  estNetFen: number | null = null;
  minFen: number | null = null;
  maxFen: number | null = null;
  basis: string = 'normal';
  presale: boolean = false;
  tags: string[] = [];
  cta: string = 'btn.buy';
  disclaimers: string[] = [];
  availability: string = 'ok';
  stale: boolean = false;
  /** amount_unknown（拼多多直链）：product_key、价格、返利都为 null（BR-PRICE-08）。 */
  unknownAmount: boolean = false;
  /** 价格不可用（BR-PRICE-01）：价格三字段与返利为 null，availability=price_unavailable，不下发 link_id。 */
  noPrice: boolean = false;
  /** 下发的 age_sec（缓存降级样例用 2160，BR-PRICE-11 例）。 */
  ageSec: number = 300;
  /** 商品图（契约 image）：null 显示占位；FU-HM-1112 共性第 22 条的截图用本机图片（data URI，不连网络）。 */
  image: string | null = null;
}

/** 本机示例商品图（16×16 渐变 PNG 的 data URI；FU-HM-1112 共性第 22 条：有图时显示图、加载失败与空字段显示占位）。 */
const SAMPLE_IMAGE: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAACGUlEQVR42g3LocrGIBQA0P+dv2JxYQwGYpjlFg0iCGLQcouGYTKZTCaTaWmP8O/08/fe5E3bi8cb2euv18Kr1SvNC+4V4eX4nvndy0vrS9r763/PTZ60PXg8kT3+eiw8Wj3SPOAeER6Oz5mfvTy0PqQ9X1g3WWlbeKzIlr+WhaXVkmaBWyIsjuvMay+L1kXa+sK8yUzbxGNGNv01LUytpjQT3BRhcpxnnnuZtE7S5hfGTUbaBh4jsuGvYWFoNaQZ4IYIg+M489jLoHWQNr7Qb9LT1vHokXV/dQtdqy5NB9dF6Bz7mfteOq2dtP6FdpOWtoZHi6z5q1loWjVpGrgmQuPYztz20mhtpLUv1JvUtFU8amTVX9VC1apKU8FVESrHeua6l0prJa1+odykpK3gUSIr/ioWilZFmgKuiFA4ljOXvRRaC2nlC/kmOW0ZjxxZ9le2kLXK0mRwWYTMMZ857yXTmknLX8CbYNoQD4wM/YUWUCuUBsGhCMgRz4x7QVqRNPxCuElIW8AjRBb8FSwErYI0AVwQIXAMZw57CbQG0sIX3E1c2hweLjLnL2fBaeWkceCcCI6jO7Pbi6PVkea+YG5i0mbwMJEZfxkLRisjjQFnRDAczZnNXgythjTzBXUTlTaFh4pM+UtZUFopaRQ4JYLiqM6s9qJoVaSpL8BNIG2AB0QG/gILoBVIA+BABOAIZ4a9AK1AGvz6Pzw3AJ9zJnSGAAAAAElFTkSuQmCC';
/** 一定加载失败的图片地址（.invalid 保留域名，不会解析；演示失败后回到占位）。 */
const BROKEN_IMAGE: string = 'https://img.example.invalid/broken.png';

function sample(key: string, title: string, price: number, coupon: number, min: number | null, max: number | null,
  basis: string, presale: boolean): Sample {
  const s: Sample = new Sample();
  s.key = key;
  s.title = title;
  s.priceFen = price;
  s.couponFen = coupon;
  s.finalFen = price - coupon;
  s.minFen = min;
  s.maxFen = max;
  s.basis = basis;
  s.presale = presale;
  s.estNetFen = min !== null && min > 0 && basis !== 'no_rebate' ? s.finalFen - min : null;
  const tags: string[] = [];
  if (coupon > 0) {
    tags.push('有券');
  }
  if (presale) {
    tags.push('预售');
  }
  s.tags = tags;
  s.cta = basis === 'no_rebate' ? 'btn.buy.no_rebate' : (coupon > 0 ? 'btn.buy.coupon' : 'btn.buy');
  const disclaimers: string[] = [coupon > 0 ? 'price_basis' : 'price_basis.general'];
  if (basis === 'normal') {
    disclaimers.push('rebate_estimate');
  } else if (basis === 'price_compare_risk') {
    disclaimers.push('rebate_compare');
  }
  s.disclaimers = disclaimers;
  return s;
}

function pairs(keys: string[], values: string[]): Map<string, string> {
  const m: Map<string, string> = new Map<string, string>();
  for (let i: number = 0; i < keys.length; i++) {
    m.set(keys[i], values[i]);
  }
  return m;
}

const SOURCES: Map<string, string> = pairs(['taobao', 'jd', 'pdd'], ['taobao_union', 'jd_union', 'pdd_union']);
const PREFIX: Map<string, string> = pairs(['taobao', 'jd', 'pdd'], ['tb', 'jd', 'pdd']);

function str(value: string | null): string {
  return value === null ? 'null' : JSON.stringify(value);
}

function num(value: number | null): string {
  return value === null ? 'null' : String(value);
}

function cardJson(s: Sample, platform: string, withShop: boolean): string {
  const prefix: string = PREFIX.get(platform) ?? platform;
  const key: string | null = s.unknownAmount ? null : prefix + ':' + s.key;
  const noPrice: boolean = s.unknownAmount || s.noPrice;
  const quoted: string = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  const parts: string[] = [
    '"product_key":' + str(key),
    '"item_ref":' + str(s.unknownAmount ? null : 'v1.' + prefix + '.' + s.key + '.sig'),
    '"platform":' + str(platform),
    '"title":' + str(s.unknownAmount ? null : s.title),
    '"image":' + str(s.image),
    '"price_fen":' + num(noPrice ? null : s.priceFen),
    '"coupon_fen":' + num(noPrice ? null : s.couponFen),
    '"final_price_fen":' + num(noPrice ? null : s.finalFen),
    '"est_net_price_fen":' + num(noPrice ? null : s.estNetFen),
    '"rebate_min_fen":' + num(noPrice ? null : s.minFen),
    '"rebate_max_fen":' + num(noPrice ? null : s.maxFen),
    '"rebate_basis":' + str(s.basis),
    '"benefit_tags":' + JSON.stringify(s.tags),
    '"is_presale":' + s.presale,
    '"link_id":' + (s.noPrice ? 'null' : '"0199a3b4-5c6d-7e8f-9a0b-' + ('000000000000' + Math.abs(hash(s.key))).slice(-12)
      + '"'),
    '"cta":{"text_key":' + str(s.cta) + '}',
    '"quoted_at":' + str(s.unknownAmount ? null : quoted),
    '"stale":' + s.stale,
    '"age_sec":' + (s.unknownAmount ? 'null' : String(s.ageSec)),
    '"source":' + str(SOURCES.get(platform) ?? 'taobao_union'),
    '"disclaimer_keys":' + JSON.stringify(s.unknownAmount ? [] : s.disclaimers),
    '"availability":' + str(s.availability)
  ];
  if (withShop) {
    parts.push('"shop_name":' + str(s.shop.length > 0 ? s.shop : null));
    parts.push('"shop_type":null', '"spec_text":null', '"ad_label":null');
  }
  return '{' + parts.join(',') + '}';
}

function hash(text: string): number {
  let h: number = 7;
  for (let i: number = 0; i < text.length; i++) {
    h = (h * 31 + text.charCodeAt(i)) % 1000000007;
  }
  return h;
}

function withImage(s: Sample, image: string): Sample {
  s.image = image;
  return s;
}

/** 第一页（设计稿 Search 的三张卡）。 */
function firstPage(): Sample[] {
  return [
    withImage(sample('milk', '全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶 送礼礼盒款 生产日期新鲜', 2345, 1000, 56, 112,
      'price_compare_risk', false), SAMPLE_IMAGE),
    withImage(sample('milk12', '纯牛奶 200ml × 12 盒 多规格可选', 1234, 0, 0, 99, 'price_compare_risk', false),
      BROKEN_IMAGE),
    sample('organic', '有机纯牛奶 250ml × 24 盒 预售 下月发货', 9999, 0, 250, 500, 'price_compare_risk', true)
  ];
}

/** 第二页（SearchEmpty 推荐里的两张卡）。 */
function secondPage(): Sample[] {
  return [
    sample('tissue', '抽纸 3 层 120 抽 × 24 包 家用整箱装', 1734, 500, 56, 56, 'normal', false),
    sample('rice', '东北长粒香大米 10kg 新米 预售款', 8800, 0, 321, 321, 'normal', true)
  ];
}

/** 详情状态样例（关键词「状态」或 states）：无返利、比价区间、金额未知、已下架、信息失效、缓存降级。 */
function statePage(platform: string): Sample[] {
  const noRebate: Sample = sample('norebate', '无返利样例 保温杯 500ml', 4560, 1000, 0, 0, 'no_rebate', false);
  const gone: Sample = sample('gone', '已下架样例 洗衣凝珠 52 颗', 3990, 0, 120, 120, 'normal', false);
  const expired: Sample = sample('expired', '信息失效样例 卷纸 4 层 27 卷', 2990, 500, 80, 80, 'normal', false);
  const stale: Sample = sample('stale', '缓存降级样例 猫粮 2kg', 6800, 1000, 200, 300, 'normal', false);
  stale.stale = true;
  stale.ageSec = 2160;
  const noPrice: Sample = sample('noprice', '价格不可用样例 洗发水 500ml', 0, 0, null, null, 'normal', false);
  noPrice.noPrice = true;
  noPrice.availability = 'price_unavailable';
  const out: Sample[] = [noRebate, gone, expired, stale, noPrice];
  if (platform === 'pdd') {
    const unknown: Sample = sample('unknown', '', 0, 0, null, null, 'amount_unknown', false);
    unknown.unknownAmount = true;
    unknown.cta = 'btn.buy';
    out.push(unknown);
  }
  return out;
}

function detailSample(key: string): Sample | null {
  if (key === 'milk') {
    // 设计稿 Product：券后 ¥46.78、券前 ¥56.78 · 券 ¥10、预估返 ¥1.23–¥2.34、预估返后 ¥45.55、乳品生活旗舰店。
    const s: Sample = sample('milk', '全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶', 5678, 1000, 123, 234,
      'price_compare_risk', false);
    s.shop = '乳品生活旗舰店';
    s.estNetFen = 4555;
    s.image = SAMPLE_IMAGE;
    return s;
  }
  const all: Sample[] = firstPage().concat(secondPage()).concat(statePage('taobao'));
  for (const s of all) {
    if (s.key === key) {
      s.shop = '示例旗舰店';
      return s;
    }
  }
  return null;
}

function inRange(s: Sample, min: number | null, max: number | null, coupon: boolean): boolean {
  if (coupon && s.couponFen <= 0) {
    return false;
  }
  if (min !== null && s.finalFen < min) {
    return false;
  }
  return max === null || s.finalFen <= max;
}

function intParam(params: Map<string, string>, name: string): number | null {
  const v: string | undefined = params.get(name);
  return v === undefined ? null : Number.parseInt(v, 10);
}

function parseQuery(url: string): Map<string, string> {
  const out: Map<string, string> = new Map<string, string>();
  const q: number = url.indexOf('?');
  if (q < 0) {
    return out;
  }
  for (const pair of url.substring(q + 1).split('&')) {
    const eq: number = pair.indexOf('=');
    if (eq > 0) {
      out.set(pair.substring(0, eq), decodeURIComponent(pair.substring(eq + 1)));
    }
  }
  return out;
}

/**
 * 场景（按关键词选，一次启动走遍各画板）：
 * - 任意关键词：第一页 3 张卡（Search），has_more=true；翻页第二页 2 张，到底。
 * - 「空」「没有」或 none：无结果 + 该平台推荐 2 张（SearchEmpty）。
 * - 「慢」或 slow：3 秒后才回答（演示换 Tab / 换关键词 / 离开后迟到响应被丢弃、请求被取消）。
 * - 「失败」或 fail：50401（trace_id 末 6 位 0a1b2c）；「关闭」或 disabled：京东 Tab 回 50304 search_disabled，其余平台正常。
 * - 「翻页出错」或 p2error：第一页正常，第二页 50401（底部错误文案带 trace6，再给重试；APP-06a R2-03）。
 * - 「翻页关闭」或 p2off：第一页正常，京东第二页 50304 search_disabled（与首屏同一处理：隐藏京东、回落；R2-01）。
 * - 「频繁」或 busy：42901（Retry-After 10 秒）。
 * - 「状态」或 states：详情各状态样例（无返利、已下架 30141、信息失效 30143、缓存降级 stale + age 2160、价格不可用；
 *   拼多多 Tab 另有金额未知卡）。
 * 筛选与排序在本页内执行（BR-PRICE-15：价格按券后价、含边界；券后价升序与返利降序只排当页）。
 */
export class DebugFakeSearch {
  static readonly marker: string = DEBUG_FAKE_SEARCH_MARKER;

  static search(url: string): FakeAnswer {
    const params: Map<string, string> = parseQuery(url);
    const q: string = params.get('q') ?? '';
    const platform: string = params.get('platform') ?? 'taobao';
    const cursor: string | undefined = params.get('cursor');
    const slow: boolean = q.indexOf('慢') >= 0 || q.indexOf('slow') >= 0;
    const delay: number = slow ? 3000 : 500;
    if (cursor === 'p2' && (q.indexOf('翻页出错') >= 0 || q.indexOf('p2error') >= 0)) {
      return new FakeAnswer(50401, '{}', delay);
    }
    if (cursor === 'p2' && platform === 'jd' && (q.indexOf('翻页关闭') >= 0 || q.indexOf('p2off') >= 0)) {
      return new FakeAnswer(50304, '{"platform":"' + platform + '","reason":"search_disabled"}', delay);
    }
    const pagedScenario: boolean = q.indexOf('翻页') >= 0 || q.indexOf('p2error') >= 0 || q.indexOf('p2off') >= 0;
    if (!pagedScenario && (q.indexOf('失败') >= 0 || q.indexOf('fail') >= 0)) {
      return new FakeAnswer(50401, '{}', delay);
    }
    if (!pagedScenario && (q.indexOf('关闭') >= 0 || q.indexOf('disabled') >= 0) && platform === 'jd') {
      // 只有京东关闭：页面移除京东 Tab、回落到其他平台重搜，并提示「京东暂不提供搜索…」（不给重试）。
      return new FakeAnswer(50304, '{"platform":"' + platform + '","reason":"search_disabled"}', delay);
    }
    if (q.indexOf('频繁') >= 0 || q.indexOf('busy') >= 0) {
      return new FakeAnswer(42901, '{}', delay, '10');
    }
    if (q.indexOf('空') >= 0 || q.indexOf('没有') >= 0 || q.indexOf('none') >= 0) {
      const fallback: string[] = secondPage().map((s: Sample) => cardJson(s, platform, false));
      return new FakeAnswer(0, '{"items":[],"next_cursor":null,"has_more":false,"fallback_items":[' + fallback.join(',')
        + ']}', delay);
    }
    const states: boolean = q.indexOf('状态') >= 0 || q.indexOf('states') >= 0;
    const second: boolean = cursor === 'p2';
    let items: Sample[] = states ? statePage(platform) : (second ? secondPage() : firstPage());
    const min: number | null = intParam(params, 'price_min_fen');
    const max: number | null = intParam(params, 'price_max_fen');
    const coupon: boolean = params.get('has_coupon') === 'true';
    items = items.filter((s: Sample) => s.unknownAmount || inRange(s, min, max, coupon));
    const sort: string = params.get('sort') ?? 'relevance';
    if (sort === 'final_price_asc') {
      items.sort((a: Sample, b: Sample) => a.finalFen - b.finalFen);
    } else if (sort === 'rebate_desc') {
      items.sort((a: Sample, b: Sample) => (b.minFen ?? 0) - (a.minFen ?? 0));
    }
    const more: boolean = !states && !second;
    const cards: string[] = items.map((s: Sample) => cardJson(s, platform, false));
    const fallback: string = items.length === 0 && !second ?
      secondPage().map((s: Sample) => cardJson(s, platform, false)).join(',') : '';
    return new FakeAnswer(0, '{"items":[' + cards.join(',') + '],"next_cursor":' + (more ? '"p2"' : 'null')
      + ',"has_more":' + more + ',"fallback_items":[' + fallback + ']}', delay);
  }

  static product(url: string): FakeAnswer {
    const path: string = url.indexOf('?') >= 0 ? url.substring(0, url.indexOf('?')) : url;
    const encoded: string = path.substring(path.lastIndexOf('/') + 1);
    const productKey: string = decodeURIComponent(encoded);
    const colon: number = productKey.indexOf(':');
    const prefix: string = colon > 0 ? productKey.substring(0, colon) : 'tb';
    const key: string = colon > 0 ? productKey.substring(colon + 1) : productKey;
    const platform: string = prefix === 'jd' ? 'jd' : (prefix === 'pdd' ? 'pdd' : 'taobao');
    if (key === 'gone') {
      return new FakeAnswer(30141, '{}');
    }
    if (key === 'expired') {
      return new FakeAnswer(30143, '{}');
    }
    const s: Sample | null = detailSample(key);
    if (s === null) {
      return new FakeAnswer(30143, '{}');
    }
    // APP-06b：改价类购买之后的权威重取按新报价回答（DebugFakeTrade.milkQuote）
    const quote: number[] | null = key === 'milk' ? DebugFakeTrade.milkQuote() : null;
    if (quote !== null) {
      s.priceFen = quote[0];
      s.couponFen = quote[1];
      s.finalFen = quote[2];
      s.estNetFen = s.finalFen - 123;
    }
    return new FakeAnswer(0, cardJson(s, platform, true), key.indexOf('slow') >= 0 ? 3000 : 500);
  }

  /**
   * /v1/config：包内配置原样，只把三个平台的搜索开关都打开（Search 截图要三个 Tab）。
   * FU-HM-1112（共性第 27 条截图）：platform_status 淘宝 on、京东 maintenance、拼多多 not_launched。
   */
  static config(): FakeAnswer {
    const data: Record<string, Object> = JSON.parse(BundledConfig.DATA_JSON) as Record<string, Object>;
    const features: Record<string, Object> = (data['features'] ?? {}) as Record<string, Object>;
    const status: Record<string, Object> = {};
    status['taobao'] = 'on';
    status['jd'] = 'on';
    status['pdd'] = 'on';
    features['search_status'] = status;
    const purchase: Record<string, Object> = {};
    purchase['taobao'] = 'on';
    purchase['jd'] = 'maintenance';
    purchase['pdd'] = 'not_launched';
    features['platform_status'] = purchase;
    data['features'] = features;
    return new FakeAnswer(0, JSON.stringify(data), 200);
  }
}
