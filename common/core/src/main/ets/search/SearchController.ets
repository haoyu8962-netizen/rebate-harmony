import { parseSort } from 'generated';
import { ApiClient, ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { EffectKind, ErrorActionMapper, ErrorEffect } from '../network/ErrorActionMapper';
import { TransportFailure } from '../network/HttpTransport';
import { CardPatch } from '../trade/CardPatch';
import {
  ProductDetailState, ProductDetailView, SearchPager, SearchQuery, SearchQueryResult, SearchResultState,
  SearchResultView, SearchSession, SearchStateRaw, SearchTabs
} from './SearchProductFlow';

/** 搜索与详情执行器用到的网络能力（生产为 ApiClient；集成测试用本地假服务）。 */
export interface SearchApiPort {
  request(request: ApiRequest): Promise<ApiResult>;

  /** 取消归属守卫为 owner 的在途请求（ApiClient.cancelOwned）。 */
  cancelOwned(owner: () => boolean): number;
}

/** 生产接线：ApiClient。 */
export class ApiClientSearchPort implements SearchApiPort {
  private readonly client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    return this.client.request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.client.cancelOwned(owner);
  }
}

/** 搜索页用到的配置能力（生产为 ConfigStore；测试用假实现）。 */
export interface SearchConfigPort {
  /**
   * 重新拉取配置（search_disabled 时，error-codes 50304「刷新配置」）：保证之后有一次在此刻之后才发出的拉取
   * （有在途拉取时，等它结算后再发一次；ConfigStore.requestFresh）。
   */
  refresh(): void;

  /** 已发出的配置拉取的最大编号（单调递增）；在 refresh 之前取，作为「之后的配置」的分界。 */
  issuedMark(): number;

  /** 当前配置（current 层）来自的拉取编号；还没有成功拉取为 0。大于分界即为分界之后发出、成功取得的配置。 */
  appliedMark(): number;

  /** 订阅配置变化（search_status 换层或换内容）；返回取消订阅的函数。可以在订阅时立即回调一次。 */
  subscribe(listener: () => void): () => void;
}

/** 购买状态 on（与 SearchPageState.PURCHASE_ON 同值；这里不引用它，避免两个模块互相引用）。 */
const PURCHASE_ON: string = 'on';

/** 50304 的 reason：该平台搜索开关已关（BR-PROD-10 细则「按平台的搜索开关」）。 */
const REASON_SEARCH_DISABLED: string = 'search_disabled';

/**
 * 42901 的禁用时长（error-codes：按 Retry-After 禁用按钮，缺省 5 秒）：取网络层 ErrorEffect.disableMillis；
 * 没有 Effect 但码是 42901 时按缺省 5 秒。其余结果为 0（不禁用）。
 */
export function disableMillisOf(result: ApiResult): number {
  const effect: ErrorEffect | null = result.effect;
  if (effect !== null && effect.effectKindRaw === EffectKind.DISABLE_BUTTON) {
    return effect.disableMillis > 0 ? effect.disableMillis : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
  }
  return result.code === 42901 ? ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS : 0;
}

/** trace_id 后 6 位（03 §4.2 通用错误态）；没有 trace_id 为空串（文案按无编号的 fallback）。 */
export function trace6Of(traceId: string): string {
  return traceId.length > 6 ? traceId.substring(traceId.length - 6) : traceId;
}

/**
 * 错误正文统一附上追踪编号（APP-06a 共性第 12 条，A-R1-03）：不依赖文案键里恰好有 {trace6} 占位——有 trace_id 时正文末尾
 * 补「（末六位）」，正文里已经有这六位就不重复；确实没有 trace_id 时原样（用不带编号的文案）。50304、search_disabled 也一样。
 */
export function withTrace6(message: string, traceId: string): string {
  const trace: string = trace6Of(traceId);
  if (trace.length === 0 || message.length === 0 || message.indexOf(trace) >= 0) {
    return message;
  }
  return message + '（' + trace + '）';
}

/** 错误文案的格式化（页面的文案来源：契约字典 → 草稿表；{name} 替换为 vars[name]，占位缺值时按契约 fallback）。 */
export interface SearchTextFormatter {
  format(key: string, vars: Map<string, string>): string;
}

/**
 * 搜索 / 详情错误文案（03 §4.2、BR-TEXT-14）：error.<code>[.<reason>]；{platform_name} 用平台显示名，{trace6} 用服务端
 * trace_id 后 6 位。没有键、或键的文字为空时用通用失败键（同样带 trace6）；只有确实没有 trace_id 时，格式化才回落到
 * 不带编号的 fallback 文案。
 */
export class SearchErrorText {
  static vars(error: SearchResultView, platformName: (platform: string | null) => string,
    currentPlatform: string | null): Map<string, string> {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('platform_name', platformName(error.platform ?? currentPlatform));
    vars.set('trace6', trace6Of(error.traceId));
    return vars;
  }

  static of(error: SearchResultView | null, texts: SearchTextFormatter,
    platformName: (platform: string | null) => string, currentPlatform: string | null, genericKey: string): string {
    if (error === null) {
      return '';
    }
    const vars: Map<string, string> = SearchErrorText.vars(error, platformName, currentPlatform);
    const text: string = texts.format(error.textKey ?? genericKey, vars);
    return text.length > 0 ? text : texts.format(genericKey, vars);
  }

  /**
   * 页面实际显示的错误正文（共性第 12 条）：of 的文字再经 withTrace6 统一补追踪编号（键里没有 {trace6} 的 50304、
   * search_disabled、42901 等也带；已有的不重复）。首屏错误、search_disabled 提示、翻页底部都用它。
   */
  static display(error: SearchResultView | null, texts: SearchTextFormatter,
    platformName: (platform: string | null) => string, currentPlatform: string | null, genericKey: string): string {
    if (error === null) {
      return '';
    }
    return withTrace6(SearchErrorText.of(error, texts, platformName, currentPlatform, genericKey), error.traceId);
  }

  /**
   * 翻页失败时列表底部的错误文案（R2-03、03 §4.2）：保留已展示的结果，先显示这段（带 trace6），再给【重试】。
   * 没有翻页失败为空串；控制器没给错误（不应发生）时用通用失败键。
   */
  static loadMoreFooter(s: SearchSnapshot, texts: SearchTextFormatter, platformName: (platform: string | null) => string,
    genericKey: string): string {
    if (!s.loadMoreFailed) {
      return '';
    }
    const text: string = SearchErrorText.display(s.loadMoreError, texts, platformName, s.platform, genericKey);
    return text.length > 0 ? text : texts.format(genericKey, new Map<string, string>());
  }
}

/**
 * 限时禁用（42901）：记下截止时刻，到期由计时器通知一次；判定一律按时钟与截止时刻（不只靠计时器）。
 */
class RetryBlock {
  private until: number = 0;
  private timer: number = -1;
  private readonly clock: () => number;

  constructor(clock: () => number) {
    this.clock = clock;
  }

  get active(): boolean {
    return this.clock() < this.until;
  }

  /** 开始禁用 millis 毫秒；到期（且没有被更晚的禁用覆盖）时调 onExpire。 */
  start(millis: number, onExpire: () => void): void {
    this.until = Math.max(this.until, this.clock() + millis);
    this.arm(onExpire);
  }

  private arm(onExpire: () => void): void {
    this.cancelTimer();
    const wait: number = Math.max(0, this.until - this.clock());
    this.timer = setTimeout((): void => {
      this.timer = -1;
      if (this.active) {
        this.arm(onExpire);
        return;
      }
      onExpire();
    }, wait);
  }

  cancelTimer(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }
}

/** 端口不该抛错（ApiClient 不抛）；万一抛了，按断网收口，页面显示错误态而不是一直加载。 */
function guarded(promise: Promise<ApiResult>): Promise<ApiResult> {
  return promise.catch((): ApiResult => new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0,
    TransportFailure.DISCONNECT, null, null, null));
}

/** ApiResult → 统一外壳（SearchResultState.map 的输入）；没有外壳（断网、超时、本地拒绝）为 null。 */
function envelopeOf(result: ApiResult): Record<string, Object> | null {
  if (result.outcome !== ApiOutcome.SUCCESS && result.outcome !== ApiOutcome.BUSINESS_ERROR) {
    return null;
  }
  const envelope: Record<string, Object> = {};
  envelope['code'] = result.code;
  envelope['msg'] = result.msg;
  envelope['data'] = result.data;
  envelope['trace_id'] = result.traceId;
  return envelope;
}

/** 没有外壳的失败：错误态，文案键取网络层给的（没有为 null，页面用通用失败兜底）。 */
function transportError(result: ApiResult): SearchResultView {
  const key: string | null = result.effect === null ? null : result.effect.textKey;
  return new SearchResultView(SearchStateRaw.ERROR, key, result.code, null, result.traceId);
}

/** 搜索页的阶段。 */
export class SearchPhase {
  /** 还没搜（输入态 SearchTyping）。 */
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly CONTENT: string = 'content';
  static readonly EMPTY: string = 'empty';
  static readonly ERROR: string = 'error';
  /** 没有 search_status=on 的平台（不发请求）。 */
  static readonly UNAVAILABLE: string = 'unavailable';
}

/** 搜索页的一次状态快照（执行器每次变化都给页面一份新的）。 */
export class SearchSnapshot {
  keyword: string = '';
  platform: string | null = null;
  tabs: string[] = [];
  sort: string = 'relevance';
  hasCoupon: boolean = false;
  priceMinFen: number | null = null;
  priceMaxFen: number | null = null;
  phase: string = SearchPhase.IDLE;
  items: Record<string, Object>[] = [];
  fallbackItems: Record<string, Object>[] = [];
  endReached: boolean = true;
  loadingMore: boolean = false;
  loadMoreFailed: boolean = false;
  /**
   * 翻页失败的错误（R2-03；保留已展示的结果时显示在列表底部）：文案键、所属平台、trace_id（trace6）。search_disabled
   * 不在这里（按平台关闭处理，见 notice）。翻页成功、重新搜索时清除。
   */
  loadMoreError: SearchResultView | null = null;
  error: SearchResultView | null = null;
  /** 当前展示的结果来自哪个请求序号（测试核对迟到响应）。 */
  shownSeq: number | null = null;
  /**
   * 50304 search_disabled 的提示（平台搜索已关闭；文案 error.50304.search_disabled，不带重试）：该平台 Tab 已移除、已按可用平台回落。
   * 用户下一次主动换条件时清除。
   */
  notice: SearchResultView | null = null;
  /** 结果里有缓存降级的报价（stale=true 或 age_sec > 300）：结果顶部提示价格可能已变化（BR-PROD-07、BR-PRICE-11）。 */
  stale: boolean = false;
  /** 42901 限时禁用中：搜索、换条件、翻页、重试入口都不可用（页面置灰），到期自动恢复。 */
  blocked: boolean = false;
  /**
   * 查询轮次（APP-06a 共性第 17、29 条）：每开始一轮新的第一页查询加 1。页面只在轮次变化时把列表滚回顶部；返回本页、
   * 配置变化只更新 Tab、进程回收后按保存的条件恢复（轮次沿用保存的值）都不清零滚动位置。
   */
  round: number = 0;
  /**
   * 加载失败的序号（共性第 16 条）：首屏、翻页每出现一次新的失败加 1。页面按它立即播报（assertive）并把焦点移到对应的【重试】；
   * 限流禁用状态照常保留。
   */
  failureSeq: number = 0;
  /**
   * 各平台的购买状态（配置 features.platform_status，PlatformPurchaseStatus；共性第 27 条）：on / maintenance / not_launched。
   * 配置变化时更新；卡片据此展示购买按钮，点击前页面再经 SearchController.purchaseStatus 核对一次。
   */
  purchase: Record<string, string> = {};
  /**
   * 平台恢复后等待用户操作（APP-06a 共性第 18、36 条）：本轮已返回 search_disabled 的平台被配置恢复，自动回落停在输入态
   * （phase 仍为 IDLE、不自动重搜），但与初始输入态不同——页面要显示恢复的 Tab 和保留的关闭提示。下一次发出搜索、进入
   * 「无可搜索平台」时清除。
   */
  waitingForUser: boolean = false;
}

/**
 * 搜索条件（页面状态持久化与进程回收后的恢复用，共性第 17、20 条）：关键词、平台、排序、筛选与查询轮次。
 */
export class SearchConditions {
  keyword: string = '';
  platform: string | null = null;
  sort: string = 'relevance';
  hasCoupon: boolean = false;
  priceMinFen: number | null = null;
  priceMaxFen: number | null = null;
  round: number = 0;
}

/**
 * 搜索页执行器（APP-06a）。请求归属与页面世代（lessons：APP-05a 共性 1、9，APP-04 共性 22、47）：
 * - 每个请求 begin 一个序号，归属守卫 owner = 「序号仍是当前、页面没离开」，交给 ApiClient（ApiRequest.owner）；
 * - 换关键词、换 Tab、换排序、换筛选、翻页、离开页面时，先让旧序号失效，再 cancelOwned 取消旧请求的传输；
 * - 响应到达（await 之后）再经 SearchSession.accept 复核，旧响应只丢弃，不改界面。
 * 自动回落（FU-HM-1112，APP-06a 共性第 11、18、19、21、26 条）：配置变化与 search_disabled 都经唯一入口 fallBack；
 * 先做不受限流影响的事（作废请求、清分页、切换页面状态），最后才决定发不发回落搜索；42901 禁用期间一律不发（统一在 run 检查），
 * 本轮已返回 search_disabled 的平台不再自动重搜（下一次由用户触发）。
 */
export class SearchController {
  private readonly api: SearchApiPort;
  private readonly statusLayers: () => Record<string, Object>;
  private readonly config: SearchConfigPort | null;
  private readonly purchaseOf: ((platform: string) => string) | null;
  private readonly session: SearchSession = new SearchSession();
  private readonly block: RetryBlock;
  private pager: SearchPager = new SearchPager();
  private owners: (() => boolean)[] = [];
  private left: boolean = false;
  private state: SearchSnapshot = new SearchSnapshot();
  /**
   * 本页收到 search_disabled 的平台 → 收到时配置拉取的分界（SearchConfigPort.issuedMark）。在本页隐藏、不再请求；
   * 只有分界之后发出、成功取得的配置（appliedMark > 分界）里该平台明确为 on 时才恢复（R2-02），禁用前或同一次在途
   * 拉取的旧配置不能提前恢复。没有配置端口时不恢复。
   */
  private disabled: Map<string, number> = new Map<string, number>();
  /**
   * 本轮（用户最近一次主动搜索 / 换条件 / 重试以来）已经返回 search_disabled 的平台（共性第 18、21 条）。配置恢复了它的 Tab
   * 也不在同一轮里自动重搜它（配置与联盟搜索开关不同步时会「隐藏 → 恢复 → 再 50304」循环）；下一次由用户触发。
   */
  private disabledThisRound: Set<string> = new Set<string>();
  /** 最近一次 42901 的错误：限流期间配置换了平台时，页面仍显示它并保持入口禁用（共性第 11 条）。 */
  private blockedView: SearchResultView | null = null;
  private unsubscribe: (() => void) | null = null;
  /** 每次状态变化（页面把快照拷进可观察模型）。 */
  onChange: (snapshot: SearchSnapshot) => void = (_s: SearchSnapshot) => {
  };

  /**
   * purchase：平台 → 购买状态（features.platform_status；PlatformPurchase.statusOf 的口径）。没给时一律 on（只按卡片自身判定）。
   */
  constructor(api: SearchApiPort, statusLayers: () => Record<string, Object>, config: SearchConfigPort | null = null,
    clock: () => number = Date.now, purchase: ((platform: string) => string) | null = null) {
    this.api = api;
    this.statusLayers = statusLayers;
    this.config = config;
    this.block = new RetryBlock(clock);
    this.purchaseOf = purchase;
  }

  get snapshot(): SearchSnapshot {
    return this.state;
  }

  /** 当前搜索条件（页面持久化用）。 */
  conditions(): SearchConditions {
    const s: SearchSnapshot = this.state;
    const c: SearchConditions = new SearchConditions();
    c.keyword = s.keyword;
    c.platform = s.platform;
    c.sort = s.sort;
    c.hasCoupon = s.hasCoupon;
    c.priceMinFen = s.priceMinFen;
    c.priceMaxFen = s.priceMaxFen;
    c.round = s.round;
    return c;
  }

  /**
   * 页面打开：按路由参数 q、platform（routes.json Search）。有 q 时直接搜。
   * restored：进程被系统回收后按持久化的页面状态重建本页（共性第 20 条）：不看路由参数，按保存的关键词、平台、排序、筛选
   * 重新搜第一页，查询轮次沿用保存的值（不算新一轮，页面不把滚动位置清零）。
   * 没有可搜索的平台时立即进入「无可搜索平台」，不必等用户点搜索（共性第 26 条）。
   */
  open(q: string | null, platform: string | null, restored: SearchConditions | null = null): void {
    this.left = false;
    this.refreshPurchase();
    if (restored !== null) {
      // 恢复（共性第 37 条，H-FU-R1-01）：先完整装入保存的条件与轮次，再订阅配置。生产 ConfigStore.subscribe 会立即回调一次；
      // 先订阅的话，那次回调发出的「轮次 0、输入态」中间快照会被页面当成新查询，清掉要恢复的滚动锚点。
      this.restore(restored);
      this.subscribeConfig();
      return;
    }
    this.subscribeConfig();
    this.refreshTabs(platform);
    if (q !== null && SearchQuery.normalizeKeyword(q).length > 0) {
      this.submit(q);
      return;
    }
    if (this.state.platform === null) {
      this.state.phase = SearchPhase.UNAVAILABLE;
    }
    this.emit();
  }

  private subscribeConfig(): void {
    if (this.config !== null && this.unsubscribe === null && !this.left) {
      this.unsubscribe = this.config.subscribe((): void => this.configChanged());
    }
  }

  private restore(saved: SearchConditions): void {
    const s: SearchSnapshot = this.state;
    s.keyword = SearchQuery.normalizeKeyword(saved.keyword);
    s.sort = parseSort(saved.sort) !== undefined ? saved.sort : 'relevance';
    const filtersOk: boolean = SearchController.filtersValid(saved.hasCoupon, saved.priceMinFen, saved.priceMaxFen);
    s.hasCoupon = filtersOk && saved.hasCoupon;
    s.priceMinFen = filtersOk ? saved.priceMinFen : null;
    s.priceMaxFen = filtersOk ? saved.priceMaxFen : null;
    s.round = Number.isInteger(saved.round) && saved.round >= 0 ? saved.round : 0;
    this.refreshTabs(saved.platform);
    if (s.platform === null) {
      this.toUnavailable();
      return;
    }
    if (s.keyword.length === 0 || !this.run(false)) {
      s.phase = SearchPhase.IDLE;
      this.emit();
    }
  }

  /** 输入框【搜索】：关键词不合法（空、超长）返回 false，不发请求。 */
  submit(keyword: string): boolean {
    if (this.block.active || this.left) {
      return false;
    }
    const normalized: string = SearchQuery.normalizeKeyword(keyword);
    this.refreshTabs(this.state.platform);
    const previous: string = this.state.keyword;
    this.state.keyword = normalized;
    if (!this.userRun()) {
      this.state.keyword = previous;
      return false;
    }
    this.state.notice = null;
    return true;
  }

  /** 换 Tab；42901 禁用中、Tab 不可用时返回 false（不改选中）。 */
  selectTab(platform: string): boolean {
    if (this.block.active || this.state.tabs.indexOf(platform) < 0 || platform === this.state.platform) {
      return false;
    }
    this.state.platform = platform;
    this.state.notice = null;
    this.userRerun();
    return true;
  }

  selectSort(sort: string): boolean {
    if (this.block.active || sort === this.state.sort) {
      return false;
    }
    const previous: string = this.state.sort;
    this.state.sort = sort;
    if (!this.userRerun()) {
      this.state.sort = previous;
      return false;
    }
    this.state.notice = null;
    return true;
  }

  /** 只看有券、价格区间（整数分，null 为不限）。区间不合法（BR-PRICE-15）返回 false，不改筛选。 */
  setFilters(hasCoupon: boolean, minFen: number | null, maxFen: number | null): boolean {
    if (this.block.active || !SearchController.filtersValid(hasCoupon, minFen, maxFen)) {
      return false;
    }
    this.state.hasCoupon = hasCoupon;
    this.state.priceMinFen = minFen;
    this.state.priceMaxFen = maxFen;
    this.state.notice = null;
    this.userRerun();
    return true;
  }

  /** 价格区间是否合法（与 SearchQuery.build 同一规则）。 */
  static filtersValid(hasCoupon: boolean, minFen: number | null, maxFen: number | null): boolean {
    const input: Record<string, Object> = {};
    input['keyword'] = 'x';
    input['platform'] = 'taobao';
    input['filters'] = SearchController.filterRecord(hasCoupon, minFen, maxFen);
    return SearchQuery.build(input).valid;
  }

  /** 【重试】：42901 禁用中不发请求（返回 false）。 */
  retry(): boolean {
    if (this.block.active) {
      return false;
    }
    if (this.state.phase === SearchPhase.ERROR) {
      return this.userRun();
    } else if (this.state.loadMoreFailed) {
      return this.loadMore();
    }
    return false;
  }

  /** 是否处于 42901 限时禁用（按时钟判定）。 */
  get blocked(): boolean {
    return this.block.active;
  }

  /**
   * 这个平台此刻的购买状态（点击购买前再核对一次，共性第 27 条）：on / maintenance / not_launched；没接配置为 on。
   */
  purchaseStatus(platform: string): string {
    return this.purchaseOf === null ? PURCHASE_ON : this.purchaseOf(platform);
  }

  /** 加载更多：已到底、正在加载、没有结果页、42901 禁用中时不做（返回 false）。 */
  loadMore(): boolean {
    const s: SearchSnapshot = this.state;
    if (this.left || this.block.active || s.endReached || s.loadingMore || this.pager.nextCursor === null
      || (s.phase !== SearchPhase.CONTENT && s.phase !== SearchPhase.EMPTY)) {
      return false;
    }
    const query: SearchQueryResult = SearchQuery.build(this.input(this.pager.nextCursor));
    if (!query.valid) {
      return false;
    }
    const requested: string = s.platform ?? '';
    const seq: number = this.beginRequest('loadMore');
    s.loadingMore = true;
    s.loadMoreFailed = false;
    s.loadMoreError = null;
    this.emit();
    this.send(seq, query).then((result: ApiResult) => {
      if (!this.session.accept(seq)) {
        return;
      }
      this.release();
      s.loadingMore = false;
      const envelope: Record<string, Object> | null = envelopeOf(result);
      if (envelope !== null && SearchController.isSearchDisabled(result)) {
        // R2-01：与首屏同一处理（BR-PROD-10）：刷新配置、隐藏该平台、作废其请求、回落到可用平台；不给重试。
        this.searchDisabled(SearchResultState.map(envelope), requested);
        return;
      }
      if (envelope === null || result.outcome !== ApiOutcome.SUCCESS) {
        // TODO(N-27)：翻页失败的保留 / 重试策略未规定：保留已展示的结果；底部先给错误文案（带 trace6，03 §4.2），再给【重试】。
        const view: SearchResultView = envelope === null ? transportError(result) : SearchResultState.map(envelope);
        s.loadMoreFailed = true;
        s.loadMoreError = new SearchResultView(SearchStateRaw.ERROR, view.textKey, view.code, view.platform ?? requested,
          view.traceId);
        s.failureSeq++;
        this.startBlock(result, s.loadMoreError);
        this.emit();
        return;
      }
      this.pager.append(envelope);
      this.applyPager(seq);
    });
    return true;
  }

  /**
   * 用购买结果更新列表里的那张卡（APP-06b：open 响应的 new_link_id、新价格、返利变化、30141 下架；BR-PRICE-12）。按 card_id /
   * product_key / link_id 认卡（CardPatch.sameCard），结果页与推荐区都找；只替换那一张，不重新请求、不动分页与滚动。
   */
  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    if (this.left) {
      return;
    }
    let changed: boolean = false;
    for (let i: number = 0; i < this.pager.items.length; i++) {
      if (CardPatch.sameCard(this.pager.items[i], target)) {
        this.pager.items[i] = transform(this.pager.items[i]);
        changed = true;
      }
    }
    for (let i: number = 0; i < this.pager.fallbackItems.length; i++) {
      if (CardPatch.sameCard(this.pager.fallbackItems[i], target)) {
        this.pager.fallbackItems[i] = transform(this.pager.fallbackItems[i]);
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    const s: SearchSnapshot = this.state;
    s.items = this.pager.items.slice();
    s.fallbackItems = this.pager.fallbackItems.slice();
    this.emit();
  }

  /**
   * 按 target 的 product_key + item_ref 静默重取权威卡（APP-06b 共性第 7、9、17 条；getProduct）：不进加载态，只替换那一张；
   * 失败、离开、没有 product_key 时什么都不做。
   */
  refetchCard(target: Record<string, Object>,
    merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void {
    const key: Object | undefined = target['product_key'];
    if (this.left || typeof key !== 'string' || (key as string).length === 0) {
      return;
    }
    const ref: Object | undefined = target['item_ref'];
    const query: string = typeof ref === 'string' ? 'item_ref=' + encodeURIComponent(ref as string) : '';
    const pathParams: Record<string, string> = {};
    pathParams['product_key'] = key as string;
    const request: ApiRequest = new ApiRequest('getProduct', pathParams, query);
    const owner: () => boolean = (): boolean => !this.left;
    request.owner = owner;
    this.owners.push(owner);
    guarded(this.api.request(request)).then((result: ApiResult) => {
      if (this.left || result.outcome !== ApiOutcome.SUCCESS) {
        return;
      }
      this.updateCard(target, (current: Record<string, Object>) => merge(current, result.data));
    });
  }

  /** 页面出栈（onWillDisappear 的同步出口）：作废当前请求并取消传输；之后迟到的响应一律丢弃。 */
  leave(): void {
    this.left = true;
    this.session.leave();
    this.cancelAll();
    this.block.cancelTimer();
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  /**
   * 配置变化（ConfigStore 订阅）：重算 Tab 与各平台购买状态。当前平台仍可用时只更新（不打断在途请求、不重复搜索）；
   * 当前平台不再可搜（或之前没有可搜平台、现在有了）时：
   * - 还没有关键词（输入态）：没有请求可作废，只换选中 Tab；全部关闭立即进入「无可搜索平台」，恢复后回到输入态（共性第 26 条）；
   * - 有关键词：交给自动回落的唯一入口 fallBack（共性第 11、19、21 条）。
   */
  configChanged(): void {
    if (this.left) {
      return;
    }
    const s: SearchSnapshot = this.state;
    const before: string | null = s.platform;
    const beforeTabs: string = JSON.stringify(s.tabs);
    const purchaseChanged: boolean = this.refreshPurchase();
    this.refreshTabs(before);
    if (s.platform === before) {
      if (JSON.stringify(s.tabs) !== beforeTabs || purchaseChanged) {
        this.emit();
      }
      return;
    }
    if (s.keyword.length === 0) {
      this.beginRequest('config');
      if (s.platform === null) {
        this.toUnavailable();
        return;
      }
      if (s.phase === SearchPhase.UNAVAILABLE) {
        s.phase = SearchPhase.IDLE;
      }
      this.emit();
      return;
    }
    this.fallBack();
  }

  private static isSearchDisabled(result: ApiResult): boolean {
    return result.outcome === ApiOutcome.BUSINESS_ERROR && result.code === 50304
      && result.data['reason'] === REASON_SEARCH_DISABLED;
  }

  private refreshTabs(wanted: string | null): void {
    const layers: Record<string, Object> = this.statusLayers();
    this.restoreReopened(layers);
    this.state.tabs = SearchTabs.resolve(layers).filter((platform: string) => !this.disabled.has(platform));
    this.state.platform = SearchTabs.select(this.state.tabs, wanted);
  }

  /** 重算各平台购买状态；有变化返回 true。 */
  private refreshPurchase(): boolean {
    const next: Record<string, string> = {};
    for (const platform of SearchTabs.CANDIDATES) {
      next[platform] = this.purchaseStatus(platform);
    }
    const changed: boolean = JSON.stringify(next) !== JSON.stringify(this.state.purchase);
    this.state.purchase = next;
    return changed;
  }

  /**
   * R2-02：因 search_disabled 隐藏的平台，在分界之后成功取得的配置（current 层）里明确为 on 时恢复。
   * 分界之前或同一次在途拉取的配置、没有 current 层、或取值不是 on（off、缺省、未知值）都继续隐藏。
   */
  private restoreReopened(layers: Record<string, Object>): void {
    if (this.config === null || this.disabled.size === 0) {
      return;
    }
    const applied: number = this.config.appliedMark();
    const currentRaw: Object | undefined = layers['current'];
    const current: Record<string, Object> | null =
      currentRaw !== undefined && currentRaw !== null && typeof currentRaw === 'object' && !Array.isArray(currentRaw)
        ? currentRaw as Record<string, Object> : null;
    const reopened: string[] = [];
    this.disabled.forEach((mark: number, platform: string) => {
      if (applied > mark && current !== null && current[platform] === 'on') {
        reopened.push(platform);
      }
    });
    for (const platform of reopened) {
      this.disabled.delete(platform);
    }
  }

  /** 42901：按 ErrorEffect.disableMillis 禁用，到期恢复并通知页面。 */
  private startBlock(result: ApiResult, view: SearchResultView): void {
    const millis: number = disableMillisOf(result);
    if (millis <= 0) {
      return;
    }
    this.blockedView = view;
    this.state.blocked = true;
    this.block.start(millis, (): void => {
      if (this.left) {
        return;
      }
      this.state.blocked = false;
      this.emit();
    });
  }

  /**
   * 50304 + search_disabled（error-codes：不显示重试，刷新配置并隐藏该平台 Tab；BR-PROD-10）：本页先移除该平台，
   * 请求配置刷新，按可用平台回落（唯一入口 fallBack：本轮已关闭过的平台不再自动重搜）；没有可用平台就进入「无可搜索平台」。
   * 提示保留到用户下一次换条件。
   * APP-07：提示保留期间页面照常显示「粘贴查返利」入口（SearchView 的 SearchPasteUi.entryVisible，共性第 11 条）。
   */
  private searchDisabled(view: SearchResultView, requested: string): void {
    const platform: string = view.platform ?? requested;
    this.disabledThisRound.add(platform);
    if (this.config !== null) {
      // 分界在刷新之前取：之后发出的拉取编号都大于它（重复收到时以最新的分界为准）。
      this.disabled.set(platform, this.config.issuedMark());
      this.config.refresh();
    } else {
      this.disabled.set(platform, Number.MAX_SAFE_INTEGER);
    }
    this.state.notice = new SearchResultView(view.stateRaw, view.textKey, view.code, platform, view.traceId);
    this.refreshTabs(null);
    this.fallBack();
  }

  /**
   * 自动回落的唯一入口（配置变化、search_disabled 都走这里；共性第 11、18、19、21 条）。先做不受限流影响的事：作废并取消旧平台的
   * 请求、清掉分页、切换页面状态；最后才决定要不要发回落搜索（限流只限制发送）。
   * - 没有任何可用平台：立即进入「无可搜索平台」（不管是否在 42901 禁用中）；
   * - 可用平台都在本轮返回过 search_disabled（配置恢复了它们的 Tab）：回到输入态并保留提示，下一次搜索由用户触发；
   * - 42901 禁用中：选中回落平台，页面保持限流错误与禁用，到期后由用户【重试】在新平台上搜（不自动补发）；
   * - 否则在第一个本轮没关闭过的平台上重搜。
   */
  private fallBack(): void {
    const s: SearchSnapshot = this.state;
    this.beginRequest('fallback');
    this.pager = new SearchPager();
    s.waitingForUser = false;
    let usable: string | null = null;
    for (const tab of s.tabs) {
      if (!this.disabledThisRound.has(tab)) {
        usable = tab;
        break;
      }
    }
    if (s.tabs.length === 0) {
      this.toUnavailable();
      return;
    }
    if (usable === null) {
      // 平台恢复后等待用户操作（共性第 36 条）：与初始输入态区分，页面显示恢复的 Tab 和保留的提示。
      this.clearResults();
      s.phase = SearchPhase.IDLE;
      s.waitingForUser = true;
      this.emit();
      return;
    }
    s.platform = usable;
    if (this.block.active) {
      this.clearResults();
      s.phase = SearchPhase.ERROR;
      s.error = this.blockedView;
      s.blocked = true;
      this.emit();
      return;
    }
    this.run();
  }

  /** 没有可搜索的平台：作废旧请求、清掉结果与分页，进入「无可搜索平台」（BR-PROD-10 细则；不发请求）。 */
  private toUnavailable(): void {
    this.beginRequest('unavailable');
    this.pager = new SearchPager();
    this.state.platform = null;
    this.clearResults();
    this.state.waitingForUser = false;
    this.state.phase = SearchPhase.UNAVAILABLE;
    this.emit();
  }

  private clearResults(): void {
    const s: SearchSnapshot = this.state;
    s.items = [];
    s.fallbackItems = [];
    s.endReached = true;
    s.loadingMore = false;
    s.loadMoreFailed = false;
    s.loadMoreError = null;
    s.error = null;
    s.stale = false;
  }

  /** 用户换 Tab / 排序 / 筛选：已有关键词时按当前条件重搜；还没搜过只记下条件。 */
  private userRerun(): boolean {
    if (this.state.keyword.length === 0) {
      this.emit();
      return true;
    }
    return this.userRun();
  }

  /** 用户主动发起的一轮搜索：清空本轮记下的 search_disabled 平台（之后的自动回落重新计）。 */
  private userRun(): boolean {
    this.disabledThisRound.clear();
    return this.run();
  }

  /**
   * 搜第一页。条件不合法返回 false（不发请求、不改界面）。这是所有第一页请求的统一发送入口：42901 禁用期间一律不发
   * （共性第 11 条；翻页的入口 loadMore 同样检查）。newRound 为 false 只在进程回收后恢复时用：轮次不变，页面不把滚动位置清零。
   */
  private run(newRound: boolean = true): boolean {
    if (this.left || this.block.active) {
      return false;
    }
    const s: SearchSnapshot = this.state;
    if (s.platform === null) {
      // 没有可搜索的平台：不发请求（BR-PROD-10 细则）。旧请求照样作废。
      this.toUnavailable();
      return true;
    }
    const requested: string = s.platform;
    const query: SearchQueryResult = SearchQuery.build(this.input(null));
    if (!query.valid) {
      return false;
    }
    const seq: number = this.beginRequest('search');
    this.pager = new SearchPager();
    s.waitingForUser = false;
    // TODO(N-27)：begin 时是否清除已展示的旧结果未规定；这里清掉并显示加载态，避免新条件下仍显示旧条件的结果。
    this.clearResults();
    s.phase = SearchPhase.LOADING;
    if (newRound) {
      s.round++;
    }
    this.emit();
    this.send(seq, query).then((result: ApiResult) => {
      if (!this.session.accept(seq)) {
        return;
      }
      this.release();
      const envelope: Record<string, Object> | null = envelopeOf(result);
      const view: SearchResultView = envelope === null ? transportError(result) : SearchResultState.map(envelope);
      if (envelope !== null && SearchController.isSearchDisabled(result)) {
        this.searchDisabled(view, requested);
        return;
      }
      if (view.stateRaw === SearchStateRaw.ERROR || envelope === null) {
        s.phase = SearchPhase.ERROR;
        s.error = view;
        s.shownSeq = seq;
        s.failureSeq++;
        this.startBlock(result, view);
        this.emit();
        return;
      }
      this.pager.append(envelope);
      this.applyPager(seq);
    });
    return true;
  }

  private applyPager(seq: number): void {
    const s: SearchSnapshot = this.state;
    s.items = this.pager.items.slice();
    s.fallbackItems = this.pager.fallbackItems;
    s.endReached = this.pager.endReached;
    s.phase = this.pager.stateRaw === SearchStateRaw.CONTENT ? SearchPhase.CONTENT : SearchPhase.EMPTY;
    s.stale = s.items.concat(s.fallbackItems).some((item: Record<string, Object>) => ProductDetailState.stale(item));
    s.error = null;
    s.loadMoreFailed = false;
    s.loadMoreError = null;
    s.shownSeq = seq;
    this.emit();
  }

  private input(cursor: string | null): Record<string, Object> {
    const s: SearchSnapshot = this.state;
    const input: Record<string, Object> = {};
    input['keyword'] = s.keyword;
    input['platform'] = s.platform ?? '';
    input['sort'] = s.sort;
    input['filters'] = SearchController.filterRecord(s.hasCoupon, s.priceMinFen, s.priceMaxFen);
    if (cursor !== null) {
      input['cursor'] = cursor;
    }
    return input;
  }

  private static filterRecord(hasCoupon: boolean, minFen: number | null, maxFen: number | null): Record<string, Object> {
    const filters: Record<string, Object> = {};
    if (hasCoupon) {
      filters['has_coupon'] = true;
    }
    if (minFen !== null) {
      filters['price_min_fen'] = minFen;
    }
    if (maxFen !== null) {
      filters['price_max_fen'] = maxFen;
    }
    return filters;
  }

  /** 新请求开始：旧序号立即失效，并取消旧请求的传输。 */
  private beginRequest(kind: string): number {
    const seq: number = this.session.begin(kind);
    this.cancelAll();
    return seq;
  }

  private send(seq: number, query: SearchQueryResult): Promise<ApiResult> {
    const request: ApiRequest = new ApiRequest('searchProducts', {}, query.toQueryString());
    const owner: () => boolean = (): boolean => !this.left && this.session.isCurrent(seq);
    request.owner = owner;
    this.owners.push(owner);
    return guarded(this.api.request(request));
  }

  private release(): void {
    this.owners = [];
  }

  private cancelAll(): void {
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.api.cancelOwned(owner);
    }
  }

  private emit(): void {
    this.onChange(this.state);
  }
}

/** 详情页的阶段。 */
export class ProductPhase {
  static readonly LOADING: string = 'loading';
  static readonly CONTENT: string = 'content';
  static readonly ERROR: string = 'error';
}

/** 详情页的一次状态快照。 */
export class ProductSnapshot {
  phase: string = ProductPhase.LOADING;
  product: Record<string, Object> | null = null;
  view: ProductDetailView | null = null;
  /** 错误态：code（30141 下架、30143 失效…）与文案键；没有外壳 code 为 -1。 */
  errorCode: number = 0;
  errorTextKey: string | null = null;
  traceId: string = '';
  shownSeq: number | null = null;
  /** 42901 限时禁用中：【重试】置灰，到期恢复。 */
  retryBlocked: boolean = false;
  /** 加载失败的序号（共性第 16 条）：每出现一次新的失败加 1，页面据此立即播报并把焦点移到【重试】。 */
  failureSeq: number = 0;
  /** 该平台此刻的购买状态（features.platform_status，共性第 27 条）：on / maintenance / not_launched；配置变化时更新。 */
  purchaseStatus: string = PURCHASE_ON;
  /**
   * 是否显示入账说明（BR-TEXT-04；共性第 15、34、35 条）：只按商品是否有返利（CreditNote.visible）与平台入账开关
   * credit.enabled.<platform> 决定，与购买状态无关（not_launched 只隐藏金额）。配置变化时与购买状态一起重算，
   * 只有入账开关变化也通知页面。
   */
  creditNote: boolean = false;
}

/** 详情页购买状态的来源（SearchPageState.PurchaseStatusPort 的同形接口，避免两个模块互相引用）。 */
export interface DetailPurchasePort {
  status(platform: string): string;

  subscribe(listener: () => void): () => void;
}

/**
 * 商品详情执行器（APP-06a）：getProduct（product_key 路径参数、item_ref 原样透传，BR-PROD-11）→ ProductDetailState。
 * 与搜索同一套归属规则：重新加载、离开页面都让旧请求失效并取消，迟到响应只丢弃。
 * 购买只到「发出购买意图」为止（TODO(APP-06b)：open 流程）。
 */
export class ProductDetailController {
  private readonly api: SearchApiPort;
  private readonly context: () => Record<string, Object>;
  private readonly session: SearchSession = new SearchSession();
  private readonly block: RetryBlock;
  private owners: (() => boolean)[] = [];
  private left: boolean = false;
  private platform: string = '';
  private productKey: string = '';
  private itemRef: string | null = null;
  private state: ProductSnapshot = new ProductSnapshot();
  private readonly purchase: DetailPurchasePort | null;
  /** 平台入账开关（credit.enabled.<platform>）：true / false / null（拿不到，照常显示）。 */
  private readonly creditOf: ((platform: string) => boolean | null) | null;
  /** 入账说明是否适用于这件商品（由 SearchPageState.CreditNote.visible 注入，避免两个模块互相引用）。 */
  private readonly creditRule: ((product: Record<string, Object>, creditSwitch: boolean | null) => boolean) | null;
  private unsubscribe: (() => void) | null = null;
  onChange: (snapshot: ProductSnapshot) => void = (_s: ProductSnapshot) => {
  };

  /**
   * purchase：平台购买状态（features.platform_status，共性第 27 条）；没给时一律 on。
   * credit / creditRule：入账开关与入账说明的适用规则（共性第 15、34、35 条）；没给时不显示入账说明。配置变化经 purchase 的
   * 订阅通知（同一个 ConfigStore），入账开关单独变化也会更新页面。
   */
  constructor(api: SearchApiPort, context: () => Record<string, Object>, clock: () => number = Date.now,
    purchase: DetailPurchasePort | null = null, credit: ((platform: string) => boolean | null) | null = null,
    creditRule: ((product: Record<string, Object>, creditSwitch: boolean | null) => boolean) | null = null) {
    this.api = api;
    this.context = context;
    this.block = new RetryBlock(clock);
    this.purchase = purchase;
    this.creditOf = credit;
    this.creditRule = creditRule;
  }

  /** 此刻是否显示入账说明：内容态的商品按规则与现读的入账开关判定。 */
  private currentCredit(): boolean {
    const product: Record<string, Object> | null = this.state.product;
    if (this.creditRule === null || product === null || this.state.phase !== ProductPhase.CONTENT) {
      return false;
    }
    const creditSwitch: boolean | null = this.creditOf === null || this.platform.length === 0 ? null
      : this.creditOf(this.platform);
    return this.creditRule(product, creditSwitch);
  }

  /** 这个平台此刻的购买状态（现读配置）。 */
  private currentPurchase(): string {
    return this.purchase === null || this.platform.length === 0 ? PURCHASE_ON : this.purchase.status(this.platform);
  }

  /**
   * 配置变化：重读购买状态与入账说明，任一变了就通知页面（按钮、说明区随之切换）。入账开关单独变化（购买状态不变）也通知
   * （共性第 35 条，H-FU-R1-05）。
   */
  private purchaseChanged(): void {
    if (this.left) {
      return;
    }
    const next: string = this.currentPurchase();
    const credit: boolean = this.currentCredit();
    if (next !== this.state.purchaseStatus || credit !== this.state.creditNote) {
      this.state.purchaseStatus = next;
      this.state.creditNote = credit;
      this.emit();
    }
  }

  /**
   * 发出购买意图前再核对一次（共性第 27 条）：内容态、服务端判定可买（ProductDetailView.buyEnabled），且此刻配置里该平台的
   * 购买状态为 on。不满足返回 false（页面不发出意图，按钮按最新状态显示）。
   */
  buyAllowed(): boolean {
    const s: ProductSnapshot = this.state;
    this.purchaseChanged();
    return !this.left && s.phase === ProductPhase.CONTENT && s.view !== null && s.view.buyEnabled
      && s.purchaseStatus === PURCHASE_ON;
  }

  get snapshot(): ProductSnapshot {
    return this.state;
  }

  /**
   * seed：进程内的卡片种子（APP-07 G09：剪贴板 parse 的卡，product_key 与路由参数一致时才用）：直接进内容态、不发 getProduct，
   * 卡上的 link_id 原样保留给购买（entry_source=parse）。没有种子照常 getProduct。
   */
  load(platform: string, productKey: string, itemRef: string | null,
    seed: Record<string, Object> | null = null): void {
    this.left = false;
    this.platform = platform;
    this.productKey = productKey;
    this.itemRef = itemRef;
    this.state.purchaseStatus = this.currentPurchase();
    if (this.purchase !== null && this.unsubscribe === null) {
      this.unsubscribe = this.purchase.subscribe((): void => this.purchaseChanged());
    }
    if (seed !== null && seed['product_key'] === productKey) {
      const seq: number = this.session.begin('seed');
      this.session.accept(seq);
      const s: ProductSnapshot = this.state;
      s.shownSeq = seq;
      s.product = seed;
      s.view = ProductDetailState.map(seed, this.context());
      s.phase = ProductPhase.CONTENT;
      s.errorCode = 0;
      s.errorTextKey = null;
      s.creditNote = this.currentCredit();
      this.emit();
      return;
    }
    this.fetch();
  }

  /** 【重试】：42901 禁用中不发请求（返回 false）。 */
  retry(): boolean {
    if (this.state.phase !== ProductPhase.ERROR || this.block.active) {
      return false;
    }
    this.fetch();
    return true;
  }

  /** 页面实例已出栈（APP-10 R1-04：【问问 AI】的来源页票据按它判断来源页是否仍在）。 */
  get isLeft(): boolean {
    return this.left;
  }

  leave(): void {
    this.left = true;
    this.session.leave();
    this.cancelAll();
    this.block.cancelTimer();
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  private fetch(): void {
    if (this.left || this.productKey.length === 0) {
      return;
    }
    const seq: number = this.session.begin('detail');
    this.cancelAll();
    const s: ProductSnapshot = this.state;
    s.phase = ProductPhase.LOADING;
    s.errorCode = 0;
    s.errorTextKey = null;
    this.emit();
    const query: string = this.itemRef === null ? '' : 'item_ref=' + encodeURIComponent(this.itemRef);
    const pathParams: Record<string, string> = {};
    pathParams['product_key'] = this.productKey;
    const request: ApiRequest = new ApiRequest('getProduct', pathParams, query);
    const owner: () => boolean = (): boolean => !this.left && this.session.isCurrent(seq);
    request.owner = owner;
    this.owners.push(owner);
    guarded(this.api.request(request)).then((result: ApiResult) => {
      if (!this.session.accept(seq)) {
        return;
      }
      this.owners = [];
      s.shownSeq = seq;
      s.traceId = result.traceId;
      if (result.outcome === ApiOutcome.SUCCESS) {
        s.product = result.data;
        s.view = ProductDetailState.map(result.data, this.context());
        s.phase = ProductPhase.CONTENT;
        s.purchaseStatus = this.currentPurchase();
        s.creditNote = this.currentCredit();
      } else if (result.outcome === ApiOutcome.BUSINESS_ERROR) {
        const reasonRaw: Object | undefined = result.data['reason'];
        s.errorCode = result.code;
        s.errorTextKey = ErrorActionMapper.textKey(result.code, typeof reasonRaw === 'string' ? reasonRaw as string : null);
        s.phase = ProductPhase.ERROR;
      } else {
        s.errorCode = -1;
        s.errorTextKey = result.effect === null ? null : result.effect.textKey;
        s.phase = ProductPhase.ERROR;
      }
      if (s.phase === ProductPhase.ERROR) {
        s.failureSeq++;
      }
      const millis: number = disableMillisOf(result);
      if (s.phase === ProductPhase.ERROR && millis > 0) {
        s.retryBlocked = true;
        this.block.start(millis, (): void => {
          if (this.left) {
            return;
          }
          s.retryBlocked = false;
          this.emit();
        });
      }
      this.emit();
    });
  }

  /**
   * 用购买结果更新页面上的商品（APP-06b：open 响应的 new_link_id、新价格、返利变化、30141 下架；BR-PRICE-12 无论确认还是取消）。
   * 只在内容态改；重新计算按钮与说明区。
   */
  replaceProduct(transform: (product: Record<string, Object>) => Record<string, Object>): void {
    const s: ProductSnapshot = this.state;
    if (this.left || s.phase !== ProductPhase.CONTENT || s.product === null) {
      return;
    }
    s.product = transform(s.product);
    s.view = ProductDetailState.map(s.product, this.context());
    s.creditNote = this.currentCredit();
    this.emit();
  }

  /**
   * 按当前商品的 product_key + item_ref 静默重取权威卡（APP-06b 共性第 7、9、17 条）：不进加载态、不打断弹层；结果到达时用
   * merge(此刻页面上的商品, 重取到的卡) 决定落到页面上的样子。失败、离开、期间重新加载都什么都不做（保持原样）。
   */
  refetch(merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void {
    if (this.left || this.productKey.length === 0) {
      return;
    }
    const seq: number | null = this.state.shownSeq;
    const query: string = this.itemRef === null ? '' : 'item_ref=' + encodeURIComponent(this.itemRef);
    const pathParams: Record<string, string> = {};
    pathParams['product_key'] = this.productKey;
    const request: ApiRequest = new ApiRequest('getProduct', pathParams, query);
    const owner: () => boolean = (): boolean => !this.left;
    request.owner = owner;
    this.owners.push(owner);
    guarded(this.api.request(request)).then((result: ApiResult) => {
      if (this.left || result.outcome !== ApiOutcome.SUCCESS || this.state.shownSeq !== seq) {
        return;
      }
      this.replaceProduct((current: Record<string, Object>) => merge(current, result.data));
    });
  }

  /** 路由参数的平台（页面显示平台名用）。 */
  get platformRaw(): string {
    return this.platform;
  }

  private cancelAll(): void {
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.api.cancelOwned(owner);
    }
  }

  private emit(): void {
    this.onChange(this.state);
  }
}
