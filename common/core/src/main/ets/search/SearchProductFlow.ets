import { parsePlatform, parseSort, Platform, RebateBasis, Sort } from 'generated';
import { ErrorActionMapper } from '../network/ErrorActionMapper';

/**
 * 搜索与商品详情的纯逻辑（APP-06a；向量 specs/search-product-vectors.json，三端同名）。
 * 不发请求、不碰界面；执行器（SearchController / ProductDetailController）与页面在别处。
 *
 * 规则依据：BR-PROD-07（关键词）、BR-PROD-08（游标）、BR-PROD-10 细则「按平台的搜索开关」、BR-PRICE-08 / 15 / 21 / 22、
 * BR-TEXT-12 / 14、拍板第二批 TRADE-08 / 10 / 20 / 21、03 §4.2 / §4.3。
 * 规则空白（rule-gaps N-27）一律保守处理：判定不了的状态不显示，不用 false / null 以外的值补造。
 */

/** 关键词长度上限（openapi searchProducts.q maxLength）。 */
const KEYWORD_MAX: number = 100;
/** 价格筛选边界（BR-PRICE-15：0 < 值 ≤ 10,000,000 分，两端含，min ≤ max）。 */
const PRICE_MIN_FEN: number = 1;
const PRICE_MAX_FEN: number = 10000000;

const KEY_Q: string = 'q';
const KEY_PLATFORM: string = 'platform';
const KEY_SORT: string = 'sort';
const KEY_HAS_COUPON: string = 'has_coupon';
const KEY_PRICE_MIN: string = 'price_min_fen';
const KEY_PRICE_MAX: string = 'price_max_fen';
const KEY_CURSOR: string = 'cursor';

/** 契约 query 参数的发送顺序（签名与发送一致；顺序固定，便于比对）。 */
const QUERY_ORDER: string[] = [KEY_Q, KEY_PLATFORM, KEY_SORT, KEY_HAS_COUPON, KEY_PRICE_MIN, KEY_PRICE_MAX, KEY_CURSOR];

/** JSON 对象取值（不是对象为 null）。 */
function objectOf(value: Object | null | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

function arrayOf(value: Object | null | undefined): Record<string, Object>[] {
  if (value === undefined || value === null || !Array.isArray(value)) {
    return [];
  }
  const out: Record<string, Object>[] = [];
  for (const item of value as Object[]) {
    const record: Record<string, Object> | null = objectOf(item);
    if (record !== null) {
      out.push(record);
    }
  }
  return out;
}

/** Unicode 码点个数（代理对算一个）。 */
function codePointLength(text: string): number {
  let count: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const unit: number = text.charCodeAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
      const next: number = text.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        i++;
      }
    }
    count++;
  }
  return count;
}

/** SearchQuery.build 的结果。valid=false 时 query 为空对象（占位，rule-gaps：无效输入不虚构 reason）。 */
export class SearchQueryResult {
  readonly valid: boolean;
  /** 平铺的契约 query 参数（q、platform、sort、has_coupon、price_min_fen、price_max_fen、cursor）。 */
  readonly query: Record<string, Object>;
  /** TODO(N-27)：无效原因的词表未规定，一律 null。 */
  readonly reasonRaw: string | null;

  constructor(valid: boolean, query: Record<string, Object>) {
    this.valid = valid;
    this.query = query;
    this.reasonRaw = null;
  }

  static invalid(): SearchQueryResult {
    return new SearchQueryResult(false, {});
  }

  /** 拼成 ApiRequest.query（不含 '?'；值做 URL 编码）。无效时为空串。 */
  toQueryString(): string {
    if (!this.valid) {
      return '';
    }
    const parts: string[] = [];
    for (const key of QUERY_ORDER) {
      const value: Object | undefined = this.query[key];
      if (value === undefined || value === null) {
        continue;
      }
      parts.push(key + '=' + encodeURIComponent(String(value)));
    }
    return parts.join('&');
  }
}

/** 搜索请求的构造（searchProducts 参数，openapi 9cd1e6f）。 */
export class SearchQuery {
  /**
   * 关键词规范化（客户端）：去掉首尾空白、连续空白合并为一个空格。
   * TODO(N-27)：BR-PROD-07 的 NFKC 与转小写是服务端 norm(q)（缓存键）的步骤，客户端是否复用未规定；客户端不改写大小写与兼容字符，
   * 原样交给服务端规范化。
   */
  static normalizeKeyword(raw: string): string {
    return raw.replace(/\s+/g, ' ').trim();
  }

  /**
   * input：keyword（必填）、platform（契约 PlatformCode）、sort（契约 SortCode，省略按 relevance）、
   * filters { has_coupon?: boolean, price_min_fen?: 整数分, price_max_fen?: 整数分 }、cursor（不透明字符串，原样透传）。
   * 关键词规范化后 1～100 个字符（码点计数；TODO(N-27) 长度在规范化前还是后、按什么计数未规定，这里按规范化后的码点）。
   * 价格筛选按 BR-PRICE-15 的业务边界（比契约 minimum:0 更严，rule-gaps 已登记差异）。
   */
  static build(input: Record<string, Object>): SearchQueryResult {
    const keywordRaw: Object | undefined = input['keyword'];
    if (typeof keywordRaw !== 'string') {
      return SearchQueryResult.invalid();
    }
    const keyword: string = SearchQuery.normalizeKeyword(keywordRaw as string);
    const length: number = codePointLength(keyword);
    if (length < 1 || length > KEYWORD_MAX) {
      return SearchQueryResult.invalid();
    }
    const platformRaw: Object | undefined = input['platform'];
    if (typeof platformRaw !== 'string' || parsePlatform(platformRaw as string) === undefined) {
      return SearchQueryResult.invalid();
    }
    let sort: string = Sort.RELEVANCE;
    const sortRaw: Object | undefined = input['sort'];
    if (sortRaw !== undefined && sortRaw !== null) {
      if (typeof sortRaw !== 'string' || parseSort(sortRaw as string) === undefined) {
        return SearchQueryResult.invalid();
      }
      sort = sortRaw as string;
    }
    const query: Record<string, Object> = {};
    query[KEY_Q] = keyword;
    query[KEY_PLATFORM] = platformRaw as string;
    query[KEY_SORT] = sort;

    const filtersRaw: Object | undefined = input['filters'];
    if (filtersRaw !== undefined && filtersRaw !== null) {
      const filters: Record<string, Object> | null = objectOf(filtersRaw);
      if (filters === null) {
        return SearchQueryResult.invalid();
      }
      const hasCoupon: Object | undefined = filters[KEY_HAS_COUPON];
      if (hasCoupon !== undefined && hasCoupon !== null) {
        if (typeof hasCoupon !== 'boolean') {
          return SearchQueryResult.invalid();
        }
        query[KEY_HAS_COUPON] = hasCoupon as boolean;
      }
      const min: number | null | undefined = SearchQuery.priceBound(filters[KEY_PRICE_MIN]);
      const max: number | null | undefined = SearchQuery.priceBound(filters[KEY_PRICE_MAX]);
      if (min === undefined || max === undefined) {
        return SearchQueryResult.invalid();
      }
      if (min !== null && max !== null && min > max) {
        return SearchQueryResult.invalid();
      }
      if (min !== null) {
        query[KEY_PRICE_MIN] = min;
      }
      if (max !== null) {
        query[KEY_PRICE_MAX] = max;
      }
    }

    const cursor: Object | undefined = input['cursor'];
    if (cursor !== undefined && cursor !== null) {
      if (typeof cursor !== 'string' || (cursor as string).length === 0) {
        return SearchQueryResult.invalid();
      }
      query[KEY_CURSOR] = cursor as string;
    }
    return new SearchQueryResult(true, query);
  }

  /** 价格边界：缺省 null；合法整数分返回数值；其余（负数、0、小数、超上限、非数值）undefined = 无效。 */
  static priceBound(value: Object | undefined): number | null | undefined {
    if (value === undefined || value === null) {
      return null;
    }
    if (typeof value !== 'number') {
      return undefined;
    }
    const fen: number = value as number;
    if (!Number.isInteger(fen) || fen < PRICE_MIN_FEN || fen > PRICE_MAX_FEN) {
      return undefined;
    }
    return fen;
  }
}

/** 搜索平台 Tab（BR-PROD-10 细则「按平台的搜索开关」）。 */
export class SearchTabs {
  /** 候选平台与显示顺序：契约 PlatformCode 的顺序。 */
  static readonly CANDIDATES: string[] = [Platform.TAOBAO, Platform.JD, Platform.PDD, Platform.MEITUAN, Platform.VIP,
    Platform.DOUYIN, Platform.ELEME, Platform.KUAISHOU, Platform.SUNING];

  /**
   * searchStatus：{ current?, lkg?, bundled? }，每层是 平台 → 取值 的对象（ConfigStore.searchStatusLayers）。
   * 逐个平台按 current → lkg → bundled 取第一个带该平台取值的层：on 显示；off 与不认识的取值都按 off，且不再回落
   * （「未知状态按 off」）；三层都没有该平台按 off。TODO(N-27)：取值为 JSON null 时按缺失回落（未规定）。
   */
  static resolve(searchStatus: Record<string, Object>): string[] {
    const layers: Record<string, Object>[] = [];
    for (const name of ['current', 'lkg', 'bundled']) {
      const layer: Record<string, Object> | null = objectOf(searchStatus[name]);
      if (layer !== null) {
        layers.push(layer);
      }
    }
    const out: string[] = [];
    for (const platform of SearchTabs.CANDIDATES) {
      if (SearchTabs.statusOf(layers, platform) === 'on') {
        out.push(platform);
      }
    }
    return out;
  }

  private static statusOf(layers: Record<string, Object>[], platform: string): string {
    for (const layer of layers) {
      const value: Object | undefined = layer[platform];
      if (value === undefined || value === null) {
        continue;
      }
      return value === 'on' ? 'on' : 'off';
    }
    return 'off';
  }

  /** 选中的 Tab：想要的平台在可用 Tab 里就用它，否则第一个；没有可用 Tab 为 null。 */
  static select(tabs: string[], wanted: string | null): string | null {
    if (wanted !== null && tabs.indexOf(wanted) >= 0) {
      return wanted;
    }
    return tabs.length > 0 ? tabs[0] : null;
  }
}

/** 结果态。 */
export class SearchStateRaw {
  static readonly CONTENT: string = 'content';
  static readonly EMPTY: string = 'empty';
  static readonly ERROR: string = 'error';
}

/**
 * 分页累积（BR-PROD-08：游标不透明、服务端去重；BR-PRICE-08：has_more 按联盟口径，与过滤后页大小无关）。
 * items 只含搜索命中，按服务端顺序追加；fallback_items（无结果推荐）另放，不混入。
 * 到底：has_more=false。TODO(N-27)：has_more=true 却没有 next_cursor 时无法继续翻页，按到底处理（矛盾的处理未规定）。
 */
export class SearchPager {
  items: Record<string, Object>[] = [];
  fallbackItems: Record<string, Object>[] = [];
  endReached: boolean = false;
  nextCursor: string | null = null;
  pages: number = 0;

  get stateRaw(): string {
    return this.items.length > 0 ? SearchStateRaw.CONTENT : SearchStateRaw.EMPTY;
  }

  /** 追加一页（完整成功 envelope）。 */
  append(envelope: Record<string, Object>): void {
    const data: Record<string, Object> = objectOf(envelope['data']) ?? {};
    const items: Record<string, Object>[] = arrayOf(data['items']);
    for (const item of items) {
      this.items.push(item);
    }
    if (this.pages === 0) {
      // fallback_items 只在首页 items 为空时出现（openapi SearchProductsData）。
      this.fallbackItems = arrayOf(data['fallback_items']);
    }
    this.pages++;
    const cursor: Object | undefined = data['next_cursor'];
    this.nextCursor = typeof cursor === 'string' && (cursor as string).length > 0 ? cursor as string : null;
    this.endReached = data['has_more'] !== true || this.nextCursor === null;
  }
}

/** SearchResultState.map 的结果。 */
export class SearchResultView {
  readonly stateRaw: string;
  /** error 时的文案键（error.<code>[.<reason>]，Core 错误映射）；字典里没有为 null（页面用通用失败兜底）。 */
  readonly textKey: string | null;
  readonly code: number;
  /** 50304 等错误带的 data.platform（文案 {platform_name} 用）。 */
  readonly platform: string | null;
  readonly traceId: string;

  constructor(stateRaw: string, textKey: string | null, code: number, platform: string | null, traceId: string) {
    this.stateRaw = stateRaw;
    this.textKey = textKey;
    this.code = code;
    this.platform = platform;
    this.traceId = traceId;
  }
}

/** 搜索响应 → 结果态（03 §3.2 content / empty / error；错误文案 BR-TEXT-14，复用 ErrorActionMapper.textKey）。 */
export class SearchResultState {
  static map(envelope: Record<string, Object>): SearchResultView {
    const codeRaw: Object | undefined = envelope['code'];
    const code: number = typeof codeRaw === 'number' ? codeRaw as number : -1;
    const data: Record<string, Object> = objectOf(envelope['data']) ?? {};
    const traceRaw: Object | undefined = envelope['trace_id'];
    const traceId: string = typeof traceRaw === 'string' ? traceRaw as string : '';
    if (code === 0) {
      const items: Record<string, Object>[] = arrayOf(data['items']);
      return new SearchResultView(items.length > 0 ? SearchStateRaw.CONTENT : SearchStateRaw.EMPTY, null, 0, null,
        traceId);
    }
    const reasonRaw: Object | undefined = data['reason'];
    const reason: string | null = typeof reasonRaw === 'string' ? reasonRaw as string : null;
    const platformRaw: Object | undefined = data['platform'];
    const platform: string | null = typeof platformRaw === 'string' ? platformRaw as string : null;
    return new SearchResultView(SearchStateRaw.ERROR, code > 0 ? ErrorActionMapper.textKey(code, reason) : null, code,
      platform, traceId);
  }
}

/**
 * 请求归属与页面世代（APP-06a；lessons：迟到响应只丢弃、出栈即失效）。
 * 每次搜索、换 Tab、换排序、换筛选、翻页都 begin 一个新序号：新请求一开始，旧序号就失效（不等新响应到达）。
 * leave（页面出栈）让当前序号失效；序号单调递增、不复用，重新进入后旧请求也不会重新生效。
 * accept 只接受当前序号，接受后记为 shownSeq。
 */
export class SearchSession {
  private counter: number = 0;
  private current: number | null = null;
  shownSeq: number | null = null;

  begin(_kind: string): number {
    this.counter++;
    this.current = this.counter;
    return this.counter;
  }

  isCurrent(seq: number): boolean {
    return this.current !== null && this.current === seq;
  }

  /** 响应到达：是当前序号返回 true 并记为已展示；否则丢弃（false）。 */
  accept(seq: number): boolean {
    if (!this.isCurrent(seq)) {
      return false;
    }
    this.shownSeq = seq;
    return true;
  }

  leave(): void {
    this.current = null;
  }
}

/** 详情页模型的原始判定（显示文字由页面经 DesignSystem 格式化）。 */
export class ProductDetailView {
  /** 购买按钮文案键：服务端 cta.text_key 原样（BR-TEXT-12、TRADE-21：客户端不自己决定）；缺失为空串。 */
  readonly buttonKeyRaw: string;
  /** 预售（is_presale，BR-PRICE-22）：「预售」标签与说明。 */
  readonly presale: boolean;
  /** 可返利、金额未知（rebate_basis=amount_unknown，BR-PRICE-08、TRADE-08）。 */
  readonly rebateUnknown: boolean;
  /**
   * 降级卡（ProductCardDegrade）。TODO(N-27)：getProduct 没有平台状态与认领配置，stale 也不等于画板的五种能力降级；
   * 判定不了，恒为 false（页面不显示降级卡），补齐依据后再判。
   */
  readonly degraded: boolean;
  /**
   * 返利消失（ProductRebateGone）。TODO(N-27)：只有 open 复核时返利由正变 0 才算（BR-PRICE-13），单张当前卡判定不了；
   * 恒为 false（不显示），在 APP-06b 的 open 结果里判。
   */
  readonly rebateGone: boolean;
  /** 公开态：游客或基本模式（不表示公开发布版本的分享入口）。 */
  readonly publicMode: boolean;
  /**
   * 购买按钮可点：有按钮文案键，且 availability 不是 off_shelf / price_unavailable（BR-PRICE-21：这两种不属于三态）。
   * TODO(N-27)：下架与价格不可用的按钮文案键未规定（rule-gaps），按钮置灰、文案仍用服务端键。
   */
  readonly buyEnabled: boolean;
  /**
   * 缓存 / 商品池降级（stale=true 或 age_sec > 300，BR-PRICE-11）：取价处提示「价格可能已变化」；不当作降级卡（见 degraded，
   * N-27 的能力降级卡是另一回事）。
   */
  readonly stale: boolean;
  /**
   * 价格不可用（BR-PRICE-01）：availability=price_unavailable，或价格三字段任一为 null（amount_unknown 卡除外）。
   * 页面不显示任何金额、显示「暂时查不到该商品价格」、按钮「稍后再试」（禁用）；价格保持未知，不补 0。
   */
  readonly priceUnavailable: boolean;

  constructor(buttonKeyRaw: string, presale: boolean, rebateUnknown: boolean, publicMode: boolean, buyEnabled: boolean,
    stale: boolean, priceUnavailable: boolean = false) {
    this.buttonKeyRaw = buttonKeyRaw;
    this.presale = presale;
    this.rebateUnknown = rebateUnknown;
    this.degraded = false;
    this.rebateGone = false;
    this.publicMode = publicMode;
    this.buyEnabled = buyEnabled;
    this.stale = stale;
    this.priceUnavailable = priceUnavailable;
  }
}

/** getProduct 的 ProductCard → 详情页模型。context：{ loggedIn: boolean, privacy: 'consented' | 'basic' }。 */
export class ProductDetailState {
  static map(product: Record<string, Object>, context: Record<string, Object>): ProductDetailView {
    const cta: Record<string, Object> | null = objectOf(product['cta']);
    const keyRaw: Object | undefined = cta === null ? undefined : cta['text_key'];
    const buttonKey: string = typeof keyRaw === 'string' ? keyRaw as string : '';
    const presale: boolean = product['is_presale'] === true;
    const rebateUnknown: boolean = product['rebate_basis'] === RebateBasis.AMOUNT_UNKNOWN;
    const publicMode: boolean = context['loggedIn'] !== true || context['privacy'] === 'basic';
    const availability: Object | undefined = product['availability'];
    const priceUnavailable: boolean = ProductDetailState.priceUnavailable(product);
    const blocked: boolean = availability === 'off_shelf' || priceUnavailable;
    return new ProductDetailView(buttonKey, presale, rebateUnknown, publicMode, buttonKey.length > 0 && !blocked,
      ProductDetailState.stale(product), priceUnavailable);
  }

  /** 与 DesignSystem ProductCardMapper.priceUnavailable 同一判定（Core 不依赖 DesignSystem，两处各写一份、测试互相核对）。 */
  static priceUnavailable(product: Record<string, Object>): boolean {
    if (product['availability'] === 'price_unavailable') {
      return true;
    }
    if (product['rebate_basis'] === RebateBasis.AMOUNT_UNKNOWN) {
      return false;
    }
    // open 已给出新券后价、券前价 / 券额待补齐（CardPatch.PRICE_PENDING）：不是价格不可用，照常可购买（H-R2-04，APP-06b 共性第 34 条）
    if (product['client_price_pending'] === true && typeof product['final_price_fen'] === 'number') {
      return false;
    }
    for (const key of ['price_fen', 'coupon_fen', 'final_price_fen']) {
      if (typeof product[key] !== 'number') {
        return true;
      }
    }
    return false;
  }

  /** BR-PRICE-11：stale=true，或 age_sec > 300（正好 300 不提示）。 */
  static stale(product: Record<string, Object>): boolean {
    if (product['stale'] === true) {
      return true;
    }
    const age: Object | undefined = product['age_sec'];
    return typeof age === 'number' && (age as number) > 300;
  }
}
