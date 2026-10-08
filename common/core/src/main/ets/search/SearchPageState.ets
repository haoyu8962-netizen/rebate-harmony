import { parsePlatform } from 'generated';
import { GuardDecision, GuardDecisionKind } from '../router/GuardDecision';
import { RouteRequest, RouteSource } from '../router/RouteRequest';
import { Router } from '../router/Router';
import { SearchConditions, SearchController, SearchPhase, SearchSnapshot } from './SearchController';

/**
 * 搜索与详情页的页面级规则（FU-HM-1112：APP-06a 共性第 15、17、20、23、27、28、29 条在鸿蒙上的落实）。
 * 纯逻辑与可注入的端口，不碰界面；页面在 features/search、features/product，接线在 entry AppSearch。
 */

/** 购买状态（契约 PlatformPurchaseStatus，/v1/config features.platform_status）。 */
export const PURCHASE_ON: string = 'on';
export const PURCHASE_MAINTENANCE: string = 'maintenance';
export const PURCHASE_NOT_LAUNCHED: string = 'not_launched';

/**
 * 点击前的平台购买状态（03 §7.4 50301 一行：点击前卡片状态取 features.platform_status.<platform>，点击时以 open 响应为准；
 * BR-PROD-10）。
 * - on → 可买；maintenance → 按钮「稍后再试」（禁用）；not_launched → 按钮「{平台}返利即将开放」（禁用，platform_coming_soon）。
 * - 该平台缺失（没有 platform_status 对象、或对象里没有这个平台）→ on：没有依据不拦（点击时 50301 仍以响应为准）。
 * - 取值不认识 → maintenance（与「无 reason 按 maintenance」同口径，保守禁用）。TODO(N-27)：缺失与未知值的口径未规定（rule-gaps）。
 */
export class PlatformPurchase {
  /** features：/v1/config 的 data.features（JSON 对象）；没有为 null。 */
  static statusOf(features: Record<string, Object> | null, platform: string): string {
    if (features === null) {
      return PURCHASE_ON;
    }
    const raw: Object | undefined = features['platform_status'];
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
      return PURCHASE_ON;
    }
    const value: Object | undefined = (raw as Record<string, Object>)[platform];
    if (value === undefined || value === null) {
      return PURCHASE_ON;
    }
    if (value === PURCHASE_ON || value === PURCHASE_MAINTENANCE || value === PURCHASE_NOT_LAUNCHED) {
      return value as string;
    }
    return PURCHASE_MAINTENANCE;
  }

  /** features 的 JSON 文本（ConfigStore.value('features')）版本；解析失败按没有。 */
  static statusOfJson(featuresJson: string | null, platform: string): string {
    if (featuresJson === null) {
      return PURCHASE_ON;
    }
    try {
      const parsed: Object = JSON.parse(featuresJson) as Object;
      return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
        ? PlatformPurchase.statusOf(parsed as Record<string, Object>, platform) : PURCHASE_ON;
    } catch (e) {
      return PURCHASE_ON;
    }
  }

  static buyAllowed(status: string): boolean {
    return status === PURCHASE_ON;
  }

  /** 购买按钮不可用时的文案键：maintenance 为空串（DesignSystem 的「稍后再试」）；not_launched 为 platform_coming_soon。 */
  static blockedTextKey(status: string): string {
    return status === PURCHASE_NOT_LAUNCHED ? 'platform_coming_soon' : '';
  }
}

/** 详情页购买状态的配置能力（生产为 ConfigStore；测试用假实现）。 */
export interface PurchaseStatusPort {
  /** 这个平台此刻的购买状态（PlatformPurchase.statusOf 的口径）。 */
  status(platform: string): string;

  /** 订阅配置变化；返回取消订阅的函数。 */
  subscribe(listener: () => void): () => void;
}

/**
 * 详情页的入账说明「确认收货后随联盟月度结算入账」（BR-TEXT-04、F-PROD-05；APP-06a 共性第 15 条）：有返利的商品显示
 * （normal、price_compare_risk、可返利金额未知的 amount_unknown；返利确定为 0 或无返利不显示）；平台入账开关明确关闭
 * （false）时隐藏。不写天数与日期。文案键契约没有，用集中草稿键（TODO(N-27)）。
 * TODO(N-27)：锁定契约 9cd1e6f 的 /v1/config 没有下发入账开关；按 features.flags 的 credit.enabled.<platform> 布尔读，
 * 没有即 null（照常显示）。
 */
export class CreditNote {
  static readonly TEXT_KEY: string = 'product.credit_note';
  private static readonly REBATE_BASES: string[] = ['normal', 'price_compare_risk', 'amount_unknown'];

  static visible(product: Record<string, Object>, creditSwitch: boolean | null): boolean {
    if (creditSwitch === false) {
      return false;
    }
    const basis: Object | undefined = product['rebate_basis'];
    if (typeof basis !== 'string' || CreditNote.REBATE_BASES.indexOf(basis as string) < 0) {
      return false;
    }
    const max: Object | undefined = product['rebate_max_fen'];
    return !(typeof max === 'number' && (max as number) === 0);
  }

  /** features.flags 里的 credit.enabled.<platform>：布尔原样，其余 null。 */
  static switchOf(features: Record<string, Object> | null, platform: string): boolean | null {
    if (features === null) {
      return null;
    }
    const flags: Object | undefined = features['flags'];
    if (flags === undefined || flags === null || typeof flags !== 'object' || Array.isArray(flags)) {
      return null;
    }
    const value: Object | undefined = (flags as Record<string, Object>)['credit.enabled.' + platform];
    return typeof value === 'boolean' ? value as boolean : null;
  }
}

/** 搜索、详情页打开的路由名（APP-06a 共性第 23 条：每个都要在 routes.json 里存在；测试逐个核对）。 */
export class SearchRoutes {
  static readonly SEARCH: string = 'Search';
  static readonly PRODUCT: string = 'ProductDetail';
  /** 详情【问问 AI】：AgentChat（不是 Agent）。 */
  static readonly ASK_AI: string = 'AgentChat';
  static readonly ALL: string[] = [SearchRoutes.SEARCH, SearchRoutes.PRODUCT, SearchRoutes.ASK_AI];
}

/** 搜索页里尚未提交的输入（输入框文字、价格弹层是否打开与两个草稿值）。 */
export class SearchDraft {
  inputText: string = '';
  sheetOpen: boolean = false;
  sheetMin: string = '';
  sheetMax: string = '';
}

/** 详情页的身份（路由参数）。 */
export class DetailIdentity {
  platform: string = '';
  productKey: string = '';
  itemRef: string | null = null;

  /** 路由参数（routes.json ProductDetail）。 */
  params(): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['platform'] = this.platform;
    out['product_key'] = this.productKey;
    if (this.itemRef !== null) {
      out['item_ref'] = this.itemRef;
    }
    return out;
  }
}

/**
 * 持久化的页面状态（APP-06a 共性第 17、20、29 条；鸿蒙页面状态持久化）：进程被系统回收后重开时，按它恢复搜索页的条件、
 * 未提交的输入与弹层草稿、滚动锚点，以及盖在上面的详情页。
 * - 滚动锚点：结果卡（列表与无结果推荐合在一起按显示顺序）的序号与它所属的查询轮次；只在新一轮查询或页面真正出栈时重置，
 *   被详情盖住、临时没有可见卡片时保留最后有效的值（共性第 29 条）。
 * - 编码带版本号；解码时逐项校验，任何一项不合法就整条丢弃（不半恢复）。
 */
export class SearchPageRecord {
  static readonly VERSION: number = 1;
  conditions: SearchConditions = new SearchConditions();
  draft: SearchDraft = new SearchDraft();
  /** 滚动锚点：第几张卡（从 0 起）；没有为 -1。 */
  anchorCard: number = -1;
  /** 锚点属于哪一轮查询（与 conditions.round 不同就不用）。 */
  anchorRound: number = 0;
  /**
   * 锚点卡相对视口顶部的偏移（vp，共性第 32 条）：卡片顶边在视口顶部之上多少（正数 = 已滚出一部分；负数 = 卡片上方还露出页头）。
   */
  anchorOffset: number = 0;
  /** 盖在搜索页上面的详情页；没有为 null。 */
  detail: DetailIdentity | null = null;

  static encode(r: SearchPageRecord): string {
    const c: Record<string, Object | null> = {};
    c['keyword'] = r.conditions.keyword;
    c['platform'] = r.conditions.platform;
    c['sort'] = r.conditions.sort;
    c['has_coupon'] = r.conditions.hasCoupon;
    c['price_min_fen'] = r.conditions.priceMinFen;
    c['price_max_fen'] = r.conditions.priceMaxFen;
    c['round'] = r.conditions.round;
    const d: Record<string, Object> = {};
    d['input'] = r.draft.inputText;
    d['sheet_open'] = r.draft.sheetOpen;
    d['sheet_min'] = r.draft.sheetMin;
    d['sheet_max'] = r.draft.sheetMax;
    const out: Record<string, Object | null> = {};
    out['v'] = SearchPageRecord.VERSION;
    out['conditions'] = c;
    out['draft'] = d;
    out['anchor_card'] = r.anchorCard;
    out['anchor_round'] = r.anchorRound;
    out['anchor_offset'] = r.anchorOffset;
    if (r.detail !== null) {
      const p: Record<string, Object | null> = {};
      p['platform'] = r.detail.platform;
      p['product_key'] = r.detail.productKey;
      p['item_ref'] = r.detail.itemRef;
      out['detail'] = p;
    } else {
      out['detail'] = null;
    }
    return JSON.stringify(out);
  }

  /** 解码；格式不对、版本不认识、任一项不合法返回 null。 */
  static decode(text: string | null): SearchPageRecord | null {
    if (text === null || text.length === 0) {
      return null;
    }
    let root: Record<string, Object> | null = null;
    try {
      root = SearchPageRecord.objectOf(JSON.parse(text) as Object);
    } catch (e) {
      return null;
    }
    if (root === null || root['v'] !== SearchPageRecord.VERSION) {
      return null;
    }
    const c: Record<string, Object> | null = SearchPageRecord.objectOf(root['conditions']);
    const d: Record<string, Object> | null = SearchPageRecord.objectOf(root['draft']);
    if (c === null || d === null) {
      return null;
    }
    const r: SearchPageRecord = new SearchPageRecord();
    const keyword: Object | undefined = c['keyword'];
    const platform: Object | null | undefined = c['platform'];
    const sort: Object | undefined = c['sort'];
    const coupon: Object | undefined = c['has_coupon'];
    const round: Object | undefined = c['round'];
    if (typeof keyword !== 'string' || typeof sort !== 'string' || typeof coupon !== 'boolean'
      || !SearchPageRecord.count(round)) {
      return null;
    }
    if (platform !== null && platform !== undefined
      && (typeof platform !== 'string' || parsePlatform(platform as string) === undefined)) {
      return null;
    }
    const min: number | null | undefined = SearchPageRecord.fen(c['price_min_fen']);
    const max: number | null | undefined = SearchPageRecord.fen(c['price_max_fen']);
    if (min === undefined || max === undefined) {
      return null;
    }
    r.conditions.keyword = keyword as string;
    r.conditions.platform = platform === null || platform === undefined ? null : platform as string;
    r.conditions.sort = sort as string;
    r.conditions.hasCoupon = coupon as boolean;
    r.conditions.priceMinFen = min;
    r.conditions.priceMaxFen = max;
    r.conditions.round = round as number;
    const input: Object | undefined = d['input'];
    const open: Object | undefined = d['sheet_open'];
    const sheetMin: Object | undefined = d['sheet_min'];
    const sheetMax: Object | undefined = d['sheet_max'];
    if (typeof input !== 'string' || typeof open !== 'boolean' || typeof sheetMin !== 'string'
      || typeof sheetMax !== 'string') {
      return null;
    }
    r.draft.inputText = input as string;
    r.draft.sheetOpen = open as boolean;
    r.draft.sheetMin = sheetMin as string;
    r.draft.sheetMax = sheetMax as string;
    const anchor: Object | undefined = root['anchor_card'];
    const anchorRound: Object | undefined = root['anchor_round'];
    if (!(anchor === -1 || SearchPageRecord.count(anchor)) || !SearchPageRecord.count(anchorRound)) {
      return null;
    }
    r.anchorCard = anchor as number;
    r.anchorRound = anchorRound as number;
    const offset: Object | undefined = root['anchor_offset'];
    if (offset !== undefined && (typeof offset !== 'number' || !Number.isFinite(offset as number))) {
      return null;
    }
    r.anchorOffset = offset === undefined ? 0 : offset as number;
    const detailRaw: Object | undefined = root['detail'];
    if (detailRaw !== undefined && detailRaw !== null) {
      const p: Record<string, Object> | null = SearchPageRecord.objectOf(detailRaw);
      if (p === null) {
        return null;
      }
      const dp: Object | undefined = p['platform'];
      const key: Object | undefined = p['product_key'];
      const ref: Object | null | undefined = p['item_ref'];
      if (typeof dp !== 'string' || parsePlatform(dp as string) === undefined || typeof key !== 'string'
        || (key as string).length === 0 || (ref !== null && ref !== undefined && typeof ref !== 'string')) {
        return null;
      }
      const detail: DetailIdentity = new DetailIdentity();
      detail.platform = dp as string;
      detail.productKey = key as string;
      detail.itemRef = ref === null || ref === undefined ? null : ref as string;
      r.detail = detail;
    }
    return r;
  }

  private static objectOf(value: Object | null | undefined): Record<string, Object> | null {
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  private static count(value: Object | undefined): boolean {
    return typeof value === 'number' && Number.isInteger(value as number) && (value as number) >= 0;
  }

  /** null → null；非负整数 → 值；其余 undefined（不合法）。区间的业务边界由 SearchController 恢复时再判。 */
  private static fen(value: Object | null | undefined): number | null | undefined {
    if (value === null || value === undefined) {
      return null;
    }
    return SearchPageRecord.count(value) ? value as number : undefined;
  }
}

/** 页面状态的存取（生产为 Preferences；测试用内存实现）。读失败返回 null；写 null 删除。 */
export interface PageStateStore {
  read(): string | null;

  /** 写入（内存立即生效，落盘可以异步）。 */
  write(value: string | null): void;

  /** 写入并同步落盘后才返回（进后台、被覆盖前用：进程随后可能被回收，不能只靠异步 flush；共性第 33 条）。 */
  writeNow(value: string | null): void;
}

/**
 * 滚动锚点的记录（APP-06a 共性第 29、32 条）：按实际视口记「顶部第一张可见卡」及它相对视口顶部的偏移；页面被详情覆盖时冻结
 * （覆盖期间列表重排、重建发出的滚动回调一律不改记录）；只有新一轮查询（reset）才清空，临时没有可见卡片时保留最后有效的值。
 */
export class ScrollAnchorTracker {
  card: number = -1;
  offset: number = 0;
  round: number = 0;
  private frozen: boolean = false;

  /** 被覆盖（详情盖在上面、页面隐藏）时 true，回到前台 false。 */
  freeze(frozen: boolean): void {
    this.frozen = frozen;
  }

  get isFrozen(): boolean {
    return this.frozen;
  }

  /** 新一轮查询：清空锚点。 */
  reset(round: number): void {
    this.card = -1;
    this.offset = 0;
    this.round = round;
  }

  /** 恢复：沿用保存的锚点（轮次一致才用）。 */
  restore(record: SearchPageRecord): void {
    this.round = record.conditions.round;
    const usable: boolean = record.anchorRound === record.conditions.round && record.anchorCard >= 0;
    this.card = usable ? record.anchorCard : -1;
    this.offset = usable ? record.anchorOffset : 0;
  }

  /**
   * 视口变化：firstCard 是顶部第一张可见卡的序号（没有可见卡片为 -1），itemTop 是它的顶边相对视口顶部的位置（vp）。
   * 冻结中或没有可见卡片时不改记录；记录变了返回 true。
   */
  observe(firstCard: number, itemTop: number): boolean {
    if (this.frozen || firstCard < 0 || !Number.isFinite(itemTop)) {
      return false;
    }
    const offset: number = Math.round(-itemTop * 10) / 10;
    if (firstCard === this.card && offset === this.offset) {
      return false;
    }
    this.card = firstCard;
    this.offset = offset;
    return true;
  }

  /** 写进持久化记录。 */
  fill(record: SearchPageRecord): void {
    record.anchorCard = this.card;
    record.anchorOffset = this.offset;
    record.anchorRound = this.round;
  }
}

/** 恢复滚动锚点的下一步。 */
export enum ScrollRestoreStep {
  /** 结果还没出来（加载中、正在翻页）：等。 */
  WAIT = 'wait',
  /** 锚点在还没加载的页里：再翻一页。 */
  LOAD_MORE = 'load_more',
  /** 滚到 targetCard。 */
  SCROLL = 'scroll',
  /** 不再恢复（没有结果、出错、轮次不同）。 */
  DROP = 'drop'
}

/**
 * 进程回收后恢复滚动位置（共性第 20 条）：锚点所在的卡可能在第 2 页以后，先按原条件逐页加载到它出现，再滚过去；
 * 到底、翻页失败或限流时就停在已加载的最后一张。
 */
export class ScrollRestore {
  static step(anchorCard: number, cardCount: number, phaseRaw: string, loadingMore: boolean, endReached: boolean,
    loadMoreFailed: boolean, blocked: boolean): ScrollRestoreStep {
    if (anchorCard < 0) {
      return ScrollRestoreStep.DROP;
    }
    if (phaseRaw === 'loading' || loadingMore) {
      return ScrollRestoreStep.WAIT;
    }
    if (phaseRaw !== 'content' && phaseRaw !== 'empty') {
      return ScrollRestoreStep.DROP;
    }
    if (cardCount === 0) {
      return ScrollRestoreStep.DROP;
    }
    if (anchorCard < cardCount || endReached || loadMoreFailed || blocked) {
      return ScrollRestoreStep.SCROLL;
    }
    return ScrollRestoreStep.LOAD_MORE;
  }

  /** SCROLL 时滚到哪张卡。 */
  static target(anchorCard: number, cardCount: number): number {
    return Math.max(0, Math.min(anchorCard, cardCount - 1));
  }

  /** SCROLL 时卡片顶边与视口顶部的额外偏移（滚到的就是锚点卡才用保存的偏移；退到最后一张时贴顶）。 */
  static extraOffset(anchorCard: number, anchorOffset: number, cardCount: number): number {
    return ScrollRestore.target(anchorCard, cardCount) === anchorCard ? anchorOffset : 0;
  }
}

/**
 * 进程回收后自动恢复页面（共性第 20、28 条）：恢复属于自动执行的动作，要等本轮版本检查有结果（最长 5 秒，03 §4.4），
 * 不能按用户主动操作跳过检查等待。
 * - App 每次状态同步后调 tryRestore：Router 还不允许自动执行（外壳未就绪、隐私未决、强更检查中且未满 5 秒）→ 继续等；
 * - 允许后经 Router 以自动来源（pending_action，入口按 in_app 校验）打开 Search，打开了且记录里有详情再打开 ProductDetail；
 *   守卫结论不是打开（低于最低版本进入 ForceUpdate、未知状态只读清单之外、基本模式等）就停下，不再打开后面的页。
 * - 已经有外部带进来的启动意图（深链、推送）、或用户已经离开首页时不恢复（外部意图与用户操作优先），记录作废。
 * 只执行一次。
 */
export class PageRestorer {
  private readonly router: Router;
  private readonly atRoot: () => boolean;
  private record: SearchPageRecord | null = null;
  /** 即将打开搜索页：把记录交给页面（App 的一次性交接）。 */
  onRestoreSearch: (record: SearchPageRecord) => void = (_r: SearchPageRecord) => {
  };
  /** 记录作废（不恢复）时调，App 据此删除持久化的记录。 */
  onDropped: () => void = () => {
  };

  constructor(router: Router, atRoot: () => boolean) {
    this.router = router;
    this.atRoot = atRoot;
  }

  arm(record: SearchPageRecord | null): void {
    this.record = record;
  }

  get armed(): boolean {
    return this.record !== null;
  }

  /** 状态同步后调用；这一次执行了恢复返回 true。 */
  tryRestore(): boolean {
    const record: SearchPageRecord | null = this.record;
    if (record === null) {
      return false;
    }
    if (!this.router.automaticOpenAllowed()) {
      return false;
    }
    this.record = null;
    if (this.router.hasPendingLaunchIntent || !this.atRoot()) {
      this.onDropped();
      return false;
    }
    this.onRestoreSearch(record);
    const search: GuardDecision = this.router.open(RouteRequest.of(SearchRoutes.SEARCH, RouteSource.PENDING_ACTION));
    if (!PageRestorer.opened(search)) {
      this.onDropped();
      return true;
    }
    if (record.detail !== null) {
      this.router.open(RouteRequest.of(SearchRoutes.PRODUCT, RouteSource.PENDING_ACTION, record.detail.params()));
    }
    return true;
  }

  private static opened(decision: GuardDecision): boolean {
    return decision.kind === GuardDecisionKind.OPEN || decision.kind === GuardDecisionKind.OPEN_READONLY;
  }
}

/**
 * 详情页说明区的文案键（BR-TEXT-04、共性第 15、31、34 条）：先是商品的口径说明键（ProductCardMapper.disclaimerKeys），
 * 平台 not_launched 时去掉返利句（只隐藏金额相关的说明）；入账说明独立按 creditNote（CreditNote.visible + 入账开关）追加，
 * 不受购买状态影响（H-FU-R1-04）。isRebateKey 由页面传 DesignSystem 的 SearchDisclaimers.isRebateKey。
 */
export class DetailNotes {
  static keys(disclaimerKeys: string[], isRebateKey: (key: string) => boolean, purchaseStatus: string,
    creditNote: boolean): string[] {
    const out: string[] = [];
    for (const key of disclaimerKeys) {
      if (purchaseStatus === PURCHASE_NOT_LAUNCHED && isRebateKey(key)) {
        continue;
      }
      if (out.indexOf(key) < 0) {
        out.push(key);
      }
    }
    if (creditNote && out.indexOf(CreditNote.TEXT_KEY) < 0) {
      out.push(CreditNote.TEXT_KEY);
    }
    return out;
  }
}

/** 搜索页的布局判定（页面按它决定显示哪些区；纯函数，测试直接断言）。 */
export class SearchLayout {
  /**
   * 平台 Tab、排序、筛选行：搜过之后都显示；初始输入态（还没搜）隐藏；平台恢复后等待用户操作（phase 仍为 IDLE）时显示，
   * 让用户看到恢复的 Tab（共性第 18、36 条，H-FU-R1-06）。
   */
  static showsConditionRows(s: SearchSnapshot): boolean {
    return s.phase !== SearchPhase.IDLE || s.waitingForUser;
  }

  /** 输入态（历史区）上方显示保留的关闭提示：只在平台恢复后等待用户操作时（仍不自动重搜）。 */
  static showsIdleNotice(s: SearchSnapshot): boolean {
    return s.phase === SearchPhase.IDLE && s.waitingForUser && s.notice !== null;
  }
}

/**
 * 搜索结果列表的行（与 SearchView.results() 的 ListItem 顺序一致；不是卡片的行为 null）：search_disabled 提示、缓存降级提示、
 * 空态 + 推荐标题 + 推荐卡、结果卡、底部（加载更多 / 到底）。
 */
export class SearchRows {
  static of(s: SearchSnapshot): (Record<string, Object> | null)[] {
    const rows: (Record<string, Object> | null)[] = [];
    if (s.phase !== SearchPhase.CONTENT && s.phase !== SearchPhase.EMPTY) {
      return rows;
    }
    if (s.notice !== null) {
      rows.push(null);
    }
    if (s.stale && s.phase === SearchPhase.CONTENT) {
      rows.push(null);
    }
    if (s.phase === SearchPhase.EMPTY) {
      rows.push(null);
      if (s.fallbackItems.length > 0) {
        rows.push(null);
        for (const item of s.fallbackItems) {
          rows.push(item);
        }
      }
    }
    for (const item of s.items) {
      rows.push(item);
    }
    rows.push(null);
    return rows;
  }

  /** 当前显示的卡片（列表结果，或无结果时的推荐），按显示顺序。 */
  static cards(s: SearchSnapshot): Record<string, Object>[] {
    if (s.phase === SearchPhase.EMPTY) {
      return s.fallbackItems;
    }
    return s.phase === SearchPhase.CONTENT ? s.items : [];
  }

  /** 第一张卡所在的行；没有卡为 0。 */
  static firstCardRow(rows: (Record<string, Object> | null)[]): number {
    for (let i: number = 0; i < rows.length; i++) {
      if (rows[i] !== null) {
        return i;
      }
    }
    return 0;
  }
}

/** 实际视口顶部：第一张可见卡（显示顺序的序号）与它顶边相对视口顶部的位置（vp；负数 = 已滚出一部分）。 */
export class ViewportTop {
  readonly card: number;
  readonly top: number;

  constructor(card: number, top: number) {
    this.card = card;
    this.top = top;
  }
}

/** 滚动保持需要页面提供的能力（SearchView 用 List 的 Scroller 实现；测试用假实现）。 */
export interface ScrollKeeperHost {
  /** 新一轮查询：列表回到顶部。 */
  scrollToTop(): void;

  /** 把第 row 行对齐到视口顶部，再多滚 extra vp（卡片顶边在视口顶部之上 extra）。 */
  scrollToRow(row: number, extra: number): void;

  /** 按当前条件翻一页（SearchController.loadMore）；没发出返回 false。 */
  loadMore(): boolean;

  /** 异步执行（生产 setTimeout 0）：回调执行前由 SearchScrollKeeper 复核任务归属。 */
  later(task: () => void): void;

  /** 按实际视口量出顶部第一张可见卡；没有布局、没有可见卡片为 null。 */
  measure(): ViewportTop | null;
}

/** 恢复任务的阶段。 */
export enum RestoreStage {
  /** 等结果（首屏加载中、补翻页）。 */
  CONTENT = 'content',
  /** 目标卡已加载：等列表布局就绪再滚。 */
  LAYOUT = 'layout',
  /** 已滚：下一次布局后按实际视口核对是否到位。 */
  VERIFY = 'verify'
}

/**
 * 恢复任务预期的视口顶部（APP-06a 共性第 38 条，H-FU-R2-01）：任务每次自己移动列表后记下；补页、定位、核对前与实际位置比较，
 * 偏离（超出容差）且不是任务造成的就说明别人动了列表（触摸、惯性、读屏、键盘 / 辅助功能滚动），任务让位。
 */
export class RestoreExpectation {
  /** 位置比较的容差（vp）：量视口的取整与亚像素误差。 */
  static readonly TOLERANCE: number = 2;
  /** true：任务还没移动过列表，预期列表停在最顶上（第 0 张卡、顶边不在视口顶部之上）；与行结构无关。 */
  readonly atTop: boolean;
  readonly card: number;
  /** 卡片顶边相对视口顶部的位置（vp；负数 = 已滚出一部分），与 ViewportTop.top 同口径。 */
  readonly top: number;
  /** 记录时第一张卡所在的行：提示行增减改变了行结构时，同一滚动位置量出的卡会变，要按当前位置重取基准。 */
  readonly firstRow: number;

  private constructor(atTop: boolean, card: number, top: number, firstRow: number) {
    this.atTop = atTop;
    this.card = card;
    this.top = top;
    this.firstRow = firstRow;
  }

  /** 新列表：还在最顶上。 */
  static listTop(): RestoreExpectation {
    return new RestoreExpectation(true, 0, 0, -1);
  }

  static at(card: number, top: number, firstRow: number): RestoreExpectation {
    return new RestoreExpectation(false, card, top, firstRow);
  }

  matches(now: ViewportTop): boolean {
    if (this.atTop) {
      return now.card === 0 && now.top >= -RestoreExpectation.TOLERANCE;
    }
    return now.card === this.card && Math.abs(now.top - this.top) <= RestoreExpectation.TOLERANCE;
  }
}

/** 一个滚动恢复任务：属于哪一轮查询、恢复到第几张卡与偏移、生命周期标识（取消后旧回调凭它认出自己已失效）。 */
export class ScrollRestoreJob {
  readonly id: number;
  readonly round: number;
  readonly card: number;
  readonly offset: number;
  stage: RestoreStage = RestoreStage.CONTENT;
  /** 任务预期的视口顶部（最近一次自己移动列表后的位置；还没移动过 = 列表最顶上）。 */
  expected: RestoreExpectation = RestoreExpectation.listTop();
  /** 最近一次移动之前的位置：移动还没被布局观察到（落点未核对）时不为 null，此时实际仍在原处不算偏离。 */
  before: RestoreExpectation | null = null;
  /** 已排了补翻页、还没执行（避免同一状态重复排）。 */
  loadQueued: boolean = false;
  /** 不能再翻页（loadMore 没发出）：按已加载的卡滚。 */
  noMorePages: boolean = false;
  row: number = -1;
  extra: number = 0;
  /** 目标卡（显示顺序）。 */
  target: number = -1;
  attempts: number = 0;

  constructor(id: number, round: number, card: number, offset: number) {
    this.id = id;
    this.round = round;
    this.card = card;
    this.offset = offset;
  }
}

/**
 * 搜索页的滚动保持（APP-06a 共性第 17、20、29、32、33、37 条；H-FU-R1-01..03）。页面的 List 与它之间只经 ScrollKeeperHost。
 * - 锚点：按实际视口记「顶部第一张可见卡 + 相对偏移」（ScrollAnchorTracker）；只有新一轮查询（快照轮次变化）才清空并回到顶部。
 * - 进程回收后的恢复是一个任务对象（轮次 + 目标卡 + 偏移 + 生命周期标识）：按快照推进（等首屏、逐页补翻到目标卡），目标卡
 *   加载后等列表布局就绪（layoutReady：UIObserver didLayout）再滚，滚后按实际视口核对；不用固定定时器。
 * - 取消：用户拖动 / 触摸列表、新一轮查询、页面出栈；被覆盖（详情盖在上面、进后台）时暂停，回到前台继续。每个异步回调执行前
 *   复核任务标识与覆盖、出栈状态，失效的回调什么都不做。
 * - 进后台、被覆盖前：先按实际视口重记（capture），再冻结锚点；页面随后同步落盘（PageStateStore.writeNow）。
 */
export class SearchScrollKeeper {
  /** 滚到目标后按实际视口核对的最多次数。 */
  private static readonly MAX_ATTEMPTS: number = 3;
  readonly anchor: ScrollAnchorTracker = new ScrollAnchorTracker();
  private readonly host: ScrollKeeperHost;
  private shownRound: number = -1;
  private job: ScrollRestoreJob | null = null;
  private nextJobId: number = 1;
  private covered: boolean = false;
  private left: boolean = false;
  /**
   * 恢复任务发现列表被别人移动（共性第 38 条）而让位、并已按实际视口重记锚点后调：页面据此持久化用户当前的位置。
   * 页面出栈后不再调。
   */
  onTakeover: () => void = () => {
  };
  private last: SearchSnapshot | null = null;
  private rows: (Record<string, Object> | null)[] = [];
  private cards: Record<string, Object>[] = [];

  constructor(host: ScrollKeeperHost) {
    this.host = host;
  }

  /**
   * 页面打开（在 SearchController.open 之前调）：restored 为进程回收后恢复的页面状态（没有为 null）；covered 为打开时是否已被
   * 覆盖（恢复时详情同时盖在上面）。锚点属于保存的轮次时建立恢复任务。
   */
  begin(restored: SearchPageRecord | null, covered: boolean): void {
    this.covered = covered;
    if (restored !== null) {
      this.shownRound = restored.conditions.round;
      this.anchor.restore(restored);
      if (this.anchor.card >= 0) {
        this.job = new ScrollRestoreJob(this.nextJobId++, this.shownRound, this.anchor.card, this.anchor.offset);
      }
    }
    this.syncFreeze();
  }

  /** 正在恢复的任务（测试与页面判断用）；没有为 null。 */
  get restoring(): ScrollRestoreJob | null {
    return this.job;
  }

  get isCovered(): boolean {
    return this.covered;
  }

  /** 执行器的每个快照（页面已拷进模型之后调）。 */
  onSnapshot(s: SearchSnapshot): void {
    if (this.left) {
      return;
    }
    this.last = s;
    this.rows = SearchRows.of(s);
    this.cards = SearchRows.cards(s);
    if (s.round !== this.shownRound) {
      // 新一轮查询：回到顶部、清空锚点、取消恢复（共性第 17、33 条）。
      if (this.shownRound >= 0) {
        this.host.scrollToTop();
      }
      this.shownRound = s.round;
      this.anchor.reset(s.round);
      this.cancel();
      return;
    }
    if (this.job !== null && this.job.stage !== RestoreStage.CONTENT) {
      // 同一轮里结果又变了（配置更新 Tab、提示行增减）：按新的行重新算目标再等布局。
      this.job.stage = RestoreStage.CONTENT;
    }
    this.advance();
  }

  /** 列表布局完成（UIObserver didLayout、列表 onScrollIndex / onAreaChange）：等布局的任务此时滚过去，滚过的核对是否到位。 */
  layoutReady(): void {
    const job: ScrollRestoreJob | null = this.job;
    if (job === null || this.covered || this.left) {
      return;
    }
    if (job.stage === RestoreStage.LAYOUT) {
      // 定位前先核对：等布局期间列表被别人移动过（读屏、键盘、惯性）就让位，不抢回。
      if (this.drifted(job)) {
        this.takeover();
        return;
      }
      this.move(job);
      return;
    }
    if (job.stage === RestoreStage.VERIFY) {
      const top: ViewportTop | null = this.host.measure();
      const arrived: boolean = top !== null && top.card === job.target && Math.abs(-top.top - job.extra) <= 1;
      if (arrived) {
        this.finish();
        return;
      }
      // 没到位：先分清是任务自己的落点（移动还没生效、落在目标卡上但偏移差一点）还是别人移动了列表。
      if (this.drifted(job)) {
        this.takeover();
        return;
      }
      if (job.attempts >= SearchScrollKeeper.MAX_ATTEMPTS) {
        this.finish();
        return;
      }
      // 估算行高时一次可能没到位：再滚一次（次数有上限，之后按实际视口记）。
      this.move(job);
    }
  }

  /** 任务自己移动列表：先记下移动前的位置与移动后的预期位置，再滚（共性第 38 条）。 */
  private move(job: ScrollRestoreJob): void {
    const firstRow: number = SearchRows.firstCardRow(this.rows);
    const now: ViewportTop | null = this.host.measure();
    job.before = now === null ? job.expected : RestoreExpectation.at(now.card, now.top, firstRow);
    job.expected = RestoreExpectation.at(job.target, -job.extra, firstRow);
    job.stage = RestoreStage.VERIFY;
    job.attempts++;
    this.host.scrollToRow(job.row, job.extra);
  }

  /**
   * 实际位置是否偏离任务的预期且不是任务造成的（共性第 38 条）。量不到（没有布局）时不判。
   * - 与预期位置一致（容差内）：没偏离。
   * - 移动还没被核对（before 不为 null）：实际仍在移动前的位置（还没生效）、或已落在目标卡上（偏移差一点由核对重试）都算任务自己的。
   * - 行结构变了（提示行增减）而预期不是「最顶上」：位置变化来自内容而不是用户，按当前位置重取基准。
   */
  private drifted(job: ScrollRestoreJob): boolean {
    const now: ViewportTop | null = this.host.measure();
    if (now === null) {
      return false;
    }
    const firstRow: number = SearchRows.firstCardRow(this.rows);
    if (!job.expected.atTop && job.expected.firstRow !== firstRow) {
      job.expected = RestoreExpectation.at(now.card, now.top, firstRow);
      job.before = null;
      return false;
    }
    if (job.expected.matches(now)) {
      return false;
    }
    const before: RestoreExpectation | null = job.before;
    if (before !== null && (before.matches(now) || now.card === job.target)) {
      return false;
    }
    return true;
  }

  /** 列表被别人移动：取消恢复，按实际视口记下用户当前的位置并通知页面持久化。 */
  private takeover(): void {
    this.job = null;
    this.syncFreeze();
    this.track();
    this.onTakeover();
  }

  /** 用户拖动 / 触摸列表：取消恢复，之后按用户的滚动记录。 */
  userScroll(): void {
    if (this.job !== null) {
      this.cancel();
    }
  }

  /**
   * 被覆盖（true：详情盖在上面、进后台）/ 回到前台（false）。覆盖前先按实际视口重记再冻结；覆盖期间恢复任务暂停（不补翻页、
   * 不滚），回到前台继续。
   */
  setCovered(covered: boolean): void {
    if (this.left || covered === this.covered) {
      return;
    }
    if (covered) {
      this.capture();
      this.covered = true;
      this.syncFreeze();
      return;
    }
    this.covered = false;
    this.syncFreeze();
    const job: ScrollRestoreJob | null = this.job;
    if (job === null) {
      return;
    }
    if (job.stage === RestoreStage.CONTENT) {
      this.advance();
    }
    if (this.job !== null && this.job.stage !== RestoreStage.CONTENT) {
      // 回到前台后列表会重新布局（layoutReady 推进）；页面已布好、不再触发布局时，下一拍也推进一次（同样复核归属）。
      const id: number = this.job.id;
      this.host.later((): void => {
        if (this.owns(id)) {
          this.layoutReady();
        }
      });
    }
  }

  /**
   * 列表可见行变化 / 滚动停下：没被覆盖时按实际视口记锚点；记录变了返回 true。恢复任务进行中不记，但先核对实际位置：
   * 被别人移动过（读屏、键盘、惯性等非触摸滚动也会触发可见行变化）就取消恢复、记下用户当前位置并返回 true（共性第 38 条）。
   */
  track(): boolean {
    if (this.covered || this.left) {
      return false;
    }
    const job: ScrollRestoreJob | null = this.job;
    if (job !== null) {
      if (!this.drifted(job)) {
        return false;
      }
      this.takeover();
      return true;
    }
    const top: ViewportTop | null = this.host.measure();
    return top !== null && this.anchor.observe(top.card, top.top);
  }

  /** 进后台 / 冻结前采集实际视口（恢复任务进行中不采：任务的目标就是要保存的位置）。 */
  capture(): void {
    this.track();
  }

  /** 页面出栈：取消任务，之后的回调一律不执行。 */
  leave(): void {
    this.left = true;
    this.cancel();
    this.onTakeover = () => {
    };
  }

  /** 绑定页面实例的生命周期：页面出栈的同步出口（SearchPageLife.exit，onWillDisappear）立即 leave（共性第 39 条）。 */
  bindLife(life: SearchPageLife): void {
    life.onExit((): void => this.leave());
  }

  /** 卡片在显示顺序里的序号（页面量视口时把行换成卡）。 */
  cardIndexOfRow(row: number): number {
    if (row < 0 || row >= this.rows.length) {
      return -1;
    }
    const item: Record<string, Object> | null = this.rows[row];
    return item === null ? -1 : this.cards.indexOf(item);
  }

  /** 当前的行（与列表顺序一致）。 */
  get currentRows(): (Record<string, Object> | null)[] {
    return this.rows;
  }

  private owns(id: number): boolean {
    return this.job !== null && this.job.id === id && !this.covered && !this.left;
  }

  private cancel(): void {
    this.job = null;
    this.syncFreeze();
  }

  private finish(): void {
    this.job = null;
    this.syncFreeze();
    this.track();
  }

  /** 恢复任务进行中、被覆盖时冻结锚点（中间的布局回调不改记录）。 */
  private syncFreeze(): void {
    this.anchor.freeze(this.job !== null || this.covered || this.left);
  }

  private advance(): void {
    const job: ScrollRestoreJob | null = this.job;
    const s: SearchSnapshot | null = this.last;
    if (job === null || s === null || this.covered || this.left || job.stage !== RestoreStage.CONTENT) {
      return;
    }
    if (s.round !== job.round) {
      this.cancel();
      return;
    }
    // 补页、定位前先核对实际位置（等结果期间被读屏 / 键盘等移动过就让位，共性第 38 条）。
    if (this.drifted(job)) {
      this.takeover();
      return;
    }
    let step: ScrollRestoreStep = ScrollRestore.step(job.card, this.cards.length, s.phase, s.loadingMore,
      s.endReached, s.loadMoreFailed, s.blocked);
    if (step === ScrollRestoreStep.LOAD_MORE && job.noMorePages) {
      step = ScrollRestoreStep.SCROLL;
    }
    if (step === ScrollRestoreStep.WAIT) {
      return;
    }
    if (step === ScrollRestoreStep.DROP) {
      // 没有结果、出错：不再恢复（锚点保留保存的值，直到新一轮查询）。
      this.job = null;
      this.syncFreeze();
      return;
    }
    if (step === ScrollRestoreStep.LOAD_MORE) {
      if (job.loadQueued) {
        return;
      }
      job.loadQueued = true;
      const id: number = job.id;
      this.host.later((): void => {
        if (this.job !== null && this.job.id === id) {
          this.job.loadQueued = false;
        }
        if (!this.owns(id)) {
          return;
        }
        if (this.drifted(this.job as ScrollRestoreJob)) {
          this.takeover();
          return;
        }
        if (!this.host.loadMore()) {
          (this.job as ScrollRestoreJob).noMorePages = true;
          this.advance();
        }
      });
      return;
    }
    job.target = ScrollRestore.target(job.card, this.cards.length);
    job.row = SearchRows.firstCardRow(this.rows) + job.target;
    job.extra = ScrollRestore.extraOffset(job.card, job.offset, this.cards.length);
    job.stage = RestoreStage.LAYOUT;
  }
}

/**
 * 一个搜索页实例的生命周期（APP-06a 共性第 39 条，H-FU-R2-02）：页面出栈的同步出口（NavDestination.onWillDisappear，早于退场
 * 动画）调 exit，一次性同时作废执行器（SearchController.leave）、滚动恢复任务（SearchScrollKeeper.bindLife）与页面回调
 * （页面经 onExit 注册）；aboutToDisappear 再调一次无副作用。持久化入口（SearchPageStates）凭它拒绝已出栈页面的写入。
 */
export class SearchPageLife {
  private live: boolean = true;
  private exits: (() => void)[] = [];

  constructor(controller: SearchController | null = null) {
    if (controller !== null) {
      this.exits.push((): void => controller.leave());
    }
  }

  get alive(): boolean {
    return this.live;
  }

  /** 注册出栈时同步执行的作废动作；已出栈时立即执行。 */
  onExit(action: () => void): void {
    if (!this.live) {
      action();
      return;
    }
    this.exits.push(action);
  }

  /** 页面出栈的同步出口：按注册顺序执行全部作废动作，只执行一次。 */
  exit(): void {
    if (!this.live) {
      return;
    }
    this.live = false;
    const actions: (() => void)[] = this.exits;
    this.exits = [];
    for (const action of actions) {
      action();
    }
  }
}

/**
 * App 侧搜索页状态的持久化入口（共性第 17、20、29、33、39 条）：记着栈里的搜索页实例（后开的在上）与当前的页面状态；
 * 页面的写入只接受仍在栈里、且是最上面那个搜索页实例的（已出栈页面迟到的布局、隐藏、滚动停止回调一律拒绝）。
 * entry AppSearch 把 PageStateStore（Preferences）交给它；页面出栈（onWillDisappear）只调 willDisappear。
 */
export class SearchPageStates {
  store: PageStateStore | null = null;
  private record: SearchPageRecord | null = null;
  private lives: SearchPageLife[] = [];
  private saveNows: (() => void)[] = [];

  /** 当前的页面状态（搜索页在栈里时才有；详情盖在上面时带详情身份）。 */
  get current(): SearchPageRecord | null {
    return this.record;
  }

  /** 进程回收后恢复：页面打开前先接管保存的记录（PageRestorer.onRestoreSearch）。 */
  adopt(record: SearchPageRecord): void {
    this.record = record;
  }

  /** 恢复作废：只删上次进程留下的那条（restoring）；用户这次已经自己打开的搜索页的状态不受影响。 */
  drop(restoring: SearchPageRecord | null): void {
    if (this.record === null || this.record === restoring) {
      this.record = null;
      this.save(false);
    }
  }

  /** 搜索页实例打开（成为最上面的搜索页）；saveNow 为它进后台前按实际视口采集并同步落盘的入口。 */
  attach(life: SearchPageLife, saveNow: () => void): void {
    this.lives.push(life);
    this.saveNows.push(saveNow);
  }

  /** 页面持久化的写入口：页面实例已出栈、或不是最上面的搜索页时拒绝（返回 false）。now 时同步落盘。 */
  changed(life: SearchPageLife, record: SearchPageRecord, now: boolean): boolean {
    if (!this.owns(life)) {
      return false;
    }
    record.detail = this.record === null ? null : this.record.detail;
    this.record = record;
    this.save(now);
    return true;
  }

  /** 给页面的持久化回调（SearchPageConfig.onPersist / onPersistNow）：带上页面实例，写入时校验。 */
  persister(life: SearchPageLife, now: boolean): (record: SearchPageRecord) => void {
    return (record: SearchPageRecord): void => {
      this.changed(life, record, now);
    };
  }

  /**
   * 页面出栈的同步出口（AppSearchPage.onWillDisappear 只调这里）：先作废这个实例（执行器、恢复任务、页面回调），
   * 它是最上面的搜索页时页面状态作废并删除记录（之后重开不恢复，共性第 29 条）。
   */
  willDisappear(life: SearchPageLife): void {
    life.exit();
    const index: number = this.lives.indexOf(life);
    if (index < 0) {
      return;
    }
    const top: boolean = index === this.lives.length - 1;
    this.lives.splice(index, 1);
    this.saveNows.splice(index, 1);
    if (top) {
      this.record = null;
      this.save(false);
    }
  }

  /** 进后台：搜索页在栈里时请最上面的实例按实际视口采集并同步落盘；不在时把已有记录同步落盘（共性第 33 条）。 */
  saveNow(): void {
    if (this.saveNows.length > 0) {
      this.saveNows[this.saveNows.length - 1]();
      return;
    }
    if (this.record !== null) {
      this.save(true);
    }
  }

  /** 从搜索页打开的详情显示：记下盖在上面的详情页。 */
  detailShown(identity: DetailIdentity): void {
    if (this.record !== null) {
      this.record.detail = identity;
      this.save(false);
    }
  }

  /** 详情出栈：去掉盖在上面的详情页（只认同一个商品）。 */
  detailLeft(identity: DetailIdentity): void {
    const detail: DetailIdentity | null = this.record === null ? null : this.record.detail;
    if (detail !== null && detail.productKey === identity.productKey && detail.platform === identity.platform) {
      (this.record as SearchPageRecord).detail = null;
      this.save(false);
    }
  }

  private owns(life: SearchPageLife): boolean {
    return life.alive && this.lives.length > 0 && this.lives[this.lives.length - 1] === life;
  }

  private save(now: boolean): void {
    const store: PageStateStore | null = this.store;
    if (store === null) {
      return;
    }
    const value: string | null = this.record === null ? null : SearchPageRecord.encode(this.record);
    if (now) {
      store.writeNow(value);
    } else {
      store.write(value);
    }
  }
}
