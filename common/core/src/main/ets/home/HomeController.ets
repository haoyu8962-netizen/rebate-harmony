// APP-11 首页执行层（HomeStore）：三级兜底（G16）、卡片数据源（G03、G10、G13）、公告关闭与到期（G10、G11）、弹窗（G14）、
// sdui_card_error 上报（G20、G21）、Retry-After（42901）与 10405 分流。页面在 features/home，组合在 entry/home（AppHome）。
// 身份构造时一次性取、之后只比较（APP-09 第 63、65 条，APP-12 第 6、13、18 条）：控制器在构造时固定「环境 + 隐私世代 + 会话世代 +
// 账号作用域」（HomeIdentity）；拉取、写 LKG、写关闭记录、写弹窗计数、渲染回调都只用这一份，读「当前身份」只用于比较。
// 归属变化时 entry 作废旧控制器（dispose）并按新身份重建（不是只刷新展示）。
// 每次异步等待（网络、读 LKG、读包内默认、图片加载、1.5 秒计时）结束后复核控制器仍在、身份仍一致（APP-04 第 30、60 条）。
import { SessionIdentity } from '../session/SessionIdentity';
import { ClientEvent, ClientEvents } from 'generated';
import { ApiClient, ApiRequest, ApiResult, ApiOutcome } from '../network/ApiClient';
import { TransportFailure } from '../network/HttpTransport';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { ErrorActionMapper, ErrorEffect } from '../network/ErrorActionMapper';
import { disableMillisOf } from '../search/SearchController';
import { HomeJson, HomeJsonRead } from './HomeJson';
import {
  HomeAction, HomeActivityItem, HomeBannerItem, HomeCard, HomeCardType, HomeDecoded, HomeDropped, HomeIconItem,
  HomeJsonObject, HomeJsonValue, HomeNoticeItem, HomeSourceKind
} from './HomeModels';
import {
  CardErrorDedupe, HomeLevel, HomeLkgScope, HomeShowing, HomeSourcePolicy, HomeSourceStep, NoticeFilter, NoticeView,
  PopupDecision, PopupPolicy
} from './HomePolicies';
import { HomeLkgStore, HomeLocalStore } from './HomeStorage';
import {
  HomeNoticeCloseTicket, HomeNoticeRow, HomePopupImageTicket, HomePopupTicket, HomeProductRow, HomeRenderTicket,
  HomeSectionTicket, HomeTap
} from './HomeTickets';

/** 控制器构造时固定的身份（不含凭据；session 是网络层归属键，只用于比较）。 */
export class HomeIdentity {
  readonly env: string;
  readonly level: string;
  readonly userId: string | null;
  readonly session: string;

  constructor(env: string, level: string, userId: string | null, session: string) {
    this.env = env;
    this.level = level;
    this.userId = userId;
    this.session = session;
  }

  /** LKG 分区（G16 ②）。 */
  get scope(): string {
    return HomeLkgScope.of(this.level, this.userId, this.env);
  }

  /** 比较用的键：任一部分变化即归属变化。 */
  get key(): string {
    return [this.env, this.level, this.userId ?? '', this.session].join('\u0001');
  }

  /** 基本模式只发匿名请求（BR-ID-11、G25）。 */
  get anonymous(): boolean {
    return this.level === HomeLevel.BASIC;
  }
}

/**
 * 首页会员 LKG 的会话对账（FU-HM-0723 第 2 轮修复 R2-02，F-X-17 同口径）：AppHome 在建控制器时记下身份与当时的登录世代票据
 * （built），身份变了（旧控制器已作废）时交此刻的身份与世代（reconcile）。同一环境里旧身份是会员，且「不再是会员 / 换了账号 /
 * 同账号但登录世代变了（重新登录）」都删旧账号的整个作用域（含各世代子目录），返回 HomeClearResult；不删返回 null。
 * 原来只比较会员状态与账号：同账号重新登录时旧世代的分区留在盘上（读不回，但还在）。建控制器时世代未知（null）说明那时没写过
 * 会员 LKG（save 要求世代已知），不因世代从未知变已知而删（冷启动会话晚一步读出时不误删本世代的 LKG）。
 */
export class HomeSyncOutcome {
  readonly keep: boolean;
  readonly cleared: string | null;

  constructor(keep: boolean, cleared: string | null) {
    this.keep = keep;
    this.cleared = cleared;
  }
}

export class HomeLkgReconciler {
  private confirmed: SessionIdentity | null = null;
  private confirmedHome: HomeIdentity | null = null;

  syncWith(oldKey: string | null, now: HomeIdentity, identity: SessionIdentity, store: HomeLkgStore,
    invalidate: () => void): HomeSyncOutcome {
    store.retryPendingClear();
    const previous: SessionIdentity | null = this.confirmed;
    const member: HomeIdentity | null = this.confirmedHome;
    const changed: boolean = identity.known && identity.changedFrom(previous);
    const coldLogout: boolean = identity.known && identity.account === null && previous === null;
    const keep: boolean = oldKey !== null && oldKey === now.key && !changed && !coldLogout;
    if (!keep) {
      invalidate();
    }
    let cleared: string | null = null;
    if (identity.known) {
      if (coldLogout) {
        // 不需要知道上个进程的会员账号；保留当前环境公共分区，清掉其余残留。
        cleared = store.clearMembersResult(now.env);
      } else if (changed && member !== null && member.level === HomeLevel.MEMBER && member.env === now.env) {
        cleared = store.clearScopeResult(member.scope);
      }
      this.confirmed = identity;
      this.confirmedHome = now;
    }
    return new HomeSyncOutcome(keep, cleared);
  }

  private before: HomeIdentity | null = null;
  private beforeEpoch: string | null = null;

  /** 建控制器时调：记下身份与此刻的登录世代票据（HomeLkgStore.epochTicket）。 */
  built(identity: HomeIdentity, epoch: string | null): void {
    this.before = identity;
    this.beforeEpoch = epoch;
  }

  /**
   * 现有控制器能不能留着（AppHome.syncInner；FU-HM-0723 末轮窄修 R3-01）：身份键相同，且没有发生「会员、建控制器时世代已知、此刻世代
   * 不同」——身份键不含持久化登录世代，令牌被换而会话计数没动时键不变，这时也要作废、对账、重建。
   */
  keeps(oldKey: string | null, now: HomeIdentity, nowEpoch: string | null): boolean {
    if (oldKey === null || oldKey !== now.key) {
      return false;
    }
    const b: HomeIdentity | null = this.before;
    return !(b !== null && b.level === HomeLevel.MEMBER && this.beforeEpoch !== null && this.beforeEpoch !== nowEpoch);
  }

  /**
   * AppHome.syncInner 的入口（末轮窄修二 RC-01）：能留着旧控制器时返回 true，并在「建控制器时世代未知、此刻已知」时记下观察到的世代——
   * 缓存照留（冷启动落定不删），之后同账号再换代就按已知换代删旧分区。只改本对账器记的世代，不改旧控制器请求固定的写入票据。
   * 返回 false 时调用方作废旧控制器后调 reconcile。
   */
  keepOrObserve(oldKey: string | null, now: HomeIdentity, nowEpoch: string | null): boolean {
    if (!this.keeps(oldKey, now, nowEpoch)) {
      return false;
    }
    const b: HomeIdentity | null = this.before;
    if (b !== null && b.level === HomeLevel.MEMBER && this.beforeEpoch === null && nowEpoch !== null) {
      this.beforeEpoch = nowEpoch;
    }
    return true;
  }

  /** 这次身份变化要不要删旧作用域（不执行删除）。 */
  clears(now: HomeIdentity, nowEpoch: string | null): boolean {
    const b: HomeIdentity | null = this.before;
    if (b === null || b.level !== HomeLevel.MEMBER || b.env !== now.env) {
      return false;
    }
    if (now.level !== HomeLevel.MEMBER || now.userId !== b.userId) {
      return true;
    }
    return this.beforeEpoch !== null && this.beforeEpoch !== nowEpoch;
  }

  /** 身份变了（旧控制器已作废）：要删就删旧作用域并返回结果（HomeClearResult），不删返回 null。 */
  reconcile(now: HomeIdentity, nowEpoch: string | null, store: HomeLkgStore): string | null {
    const b: HomeIdentity | null = this.before;
    if (b === null || !this.clears(now, nowEpoch)) {
      return null;
    }
    return store.clearScopeResult(b.scope);
  }
}

/**
 * 契约还没有的两个接口（G02 getPage、G03 listSectionItems，标「需契约」）：手写的待定 operation，不进生成的 ApiOperations，
 * 只由 Debug / Staging 的本地假服务实现；Release 构建为 null（不发请求：首页只显示 LKG / 包内默认，商品池与物料卡隐藏）。
 * anonymous：基本模式（不带 Authorization、X-Device-Id、签名与任何设备标识）。sendAllowed：共享 42901 闸门（每次实际发包前核对）。
 * 请求里不带频道或排序参数（AC-S1-90 ③）。TODO(N-35)：契约补上后改为真实接口。
 */
export interface HomeContractPort {
  /** getPage：GET /v1/pages/{page_key}（optional，不签名、不带幂等键）→ {page_key, version, ttl_sec?, sections}。 */
  getPage(pageKey: string, anonymous: boolean, sendAllowed: () => boolean): Promise<ApiResult>;

  /** listSectionItems：GET /v1/pages/{page_key}/sections/{section_id}/items?cursor → {items: ProductCard[], next_cursor}。 */
  listSectionItems(pageKey: string, sectionId: string, cursor: string | null, anonymous: boolean,
    sendAllowed: () => boolean): Promise<ApiResult>;

  /** 作废这个归属的在途请求（控制器作废时调）。 */
  cancel(owner: number): void;
}

/** 公告 api 来源（G10）：listArticles(category=notice) 第一页，契约已有。 */
export interface HomeNoticePort {
  listNotices(owner: () => boolean, sendAllowed: () => boolean): Promise<ApiResult>;

  cancelOwned(owner: () => boolean): void;
}

/** 经 ApiClient 调 listArticles（x-auth: none）。 */
export class ApiClientHomeNoticePort implements HomeNoticePort {
  private readonly client: () => ApiClient | null;

  constructor(client: () => ApiClient | null) {
    this.client = client;
  }

  listNotices(owner: () => boolean, sendAllowed: () => boolean): Promise<ApiResult> {
    const c: ApiClient | null = this.client();
    if (c === null) {
      return Promise.resolve(new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT,
        null, null, null));
    }
    // 只取第一页：Limit 用默认、不传 Cursor、不带别的参数（G10）。
    const request: ApiRequest = new ApiRequest('listArticles', {}, 'category=notice');
    request.owner = owner;
    request.sendAllowed = sendAllowed;
    return c.request(request);
  }

  cancelOwned(owner: () => boolean): void {
    this.client()?.cancelOwned(owner);
  }
}

/** 计时器端口（单测注入假计时器）。 */
export interface HomeTimer {
  schedule(ms: number, run: () => void): number;

  cancel(id: number): void;
}

export class SystemHomeTimer implements HomeTimer {
  schedule(ms: number, run: () => void): number {
    return setTimeout(run, ms);
  }

  cancel(id: number): void {
    clearTimeout(id);
  }
}

/** 控制器依赖（entry AppHome 组装；单测按同一接线组装）。 */
export class HomeDeps {
  identity: HomeIdentity;
  /** 比较用：此刻的身份键（只比较，不赋值）。 */
  currentKey: () => string;
  contract: HomeContractPort | null = null;
  notices: HomeNoticePort | null = null;
  lkg: HomeLkgStore;
  local: HomeLocalStore;
  /** 包内 default_home.json（G17）；读不出为 null。 */
  defaultJson: () => string | null = () => null;
  clock: () => number = Date.now;
  timer: HomeTimer = new SystemHomeTimer();
  platform: string = 'harmony';
  appVersion: string = '';
  pageKey: string = 'home';
  gate: RetryAfterGate;
  dedupe: CardErrorDedupe = new CardErrorDedupe();
  /** 草稿预览（HomePreview）：只读、不发埋点、不写本机数据（G24 ⑥）。 */
  preview: boolean = false;
  track: (event: ClientEvent) => void = (_e: ClientEvent) => {
  };
  /** 10405：服务端已判定强更（照已有分流，不另写逻辑）。 */
  forceUpdate: () => void = () => {
  };
  /** 卡片动作：一律交 Router（入口 in_app，F-HOME-09）。spm 只作上下文（G06）。 */
  open: (route: string, params: Record<string, Object>, spm: string) => void =
    (_r: string, _p: Record<string, Object>, _s: string) => {
    };
  /** 提示（textKey + trace_id；entry 经统一错误消息函数追加 trace6）。 */
  toast: (textKey: string, traceId: string) => void = (_k: string, _t: string) => {
  };
  /** 弹窗的阻挡项（G14 ④）。 */
  blockers: () => string[] = () => [];
  /** 本次冷启动（进程）是否已弹过（G14 ④ 每次冷启动最多一次）。 */
  coldStartShown: () => boolean = () => false;
  markColdStartShown: () => void = () => {
  };
  log: (message: string) => void = (_m: string) => {
  };

  constructor(identity: HomeIdentity, currentKey: () => string, lkg: HomeLkgStore, local: HomeLocalStore,
    gate: RetryAfterGate) {
    this.identity = identity;
    this.currentKey = currentKey;
    this.lkg = lkg;
    this.local = local;
    this.gate = gate;
  }
}

/** 一张卡的动态数据（商品池、物料信息流、公告 api）。 */
export class HomeSectionData {
  /** 商品项原样（ProductCard JSON；按服务端顺序，不重排、不过滤、不补数，AC-S1-90 ③）。 */
  readonly products: Record<string, Object>[];
  readonly notices: HomeNoticeItem[];
  readonly loading: boolean;
  readonly failed: boolean;
  readonly cursor: string | null;
  readonly loaded: boolean;
  /** 失败后点【重试】正在重新加载（信息流首屏失败时，底部重试行在重新加载期间保留，R1-05）。 */
  readonly retrying: boolean;

  constructor(products: Record<string, Object>[], notices: HomeNoticeItem[], loading: boolean, failed: boolean,
    cursor: string | null, loaded: boolean, retrying: boolean = false) {
    this.products = products;
    this.notices = notices;
    this.loading = loading;
    this.failed = failed;
    this.cursor = cursor;
    this.loaded = loaded;
    this.retrying = retrying;
  }

  static initial(): HomeSectionData {
    return new HomeSectionData([], [], true, false, null, false);
  }
}

/** 公告关闭票据里「渲染时」的部分（环境、本机记录清理世代、是否允许落盘）。 */
export class HomeNoticeContext {
  readonly env: string;
  readonly localGeneration: number;
  readonly persist: boolean;

  constructor(env: string, localGeneration: number, persist: boolean) {
    this.env = env;
    this.localGeneration = localGeneration;
    this.persist = persist;
  }
}

/**
 * 界面渲染的一张卡（纯值）。每个可点的东西都带一张渲染时生成的不可变票据（HomeTap、HomeNoticeCloseTicket、HomeSectionTicket），
 * 界面的回调只捕获 ForEach 的条目（票据），执行时交回执行层比较（R1-02，APP-09 第 63 条）。
 */
export class HomeCardView {
  /** 渲染这张卡的控制器编号与内容换代编号（回调捕获、执行时只比较）。 */
  readonly owner: number;
  readonly render: number;
  readonly card: HomeCard;
  /** 商品类卡的商品项（Release 没有数据源 → 空 → 卡隐藏）。 */
  readonly products: Record<string, Object>[];
  /** 公告条此刻可见的条目（生效区间、关闭记录已过滤）。 */
  readonly notices: HomeNoticeItem[];
  /** 数据源成功但为空、或公告全隐藏：整张卡隐藏（不显示空壳与骨架残留）。信息流加载失败不隐藏（底部给【重试】，R1-05）。 */
  readonly hidden: boolean;
  /** 信息流：底部状态。 */
  readonly feedLoading: boolean;
  readonly feedFailed: boolean;
  readonly feedHasMore: boolean;
  /** 42901 闸门生效中：【重试】与翻页禁用（R1-05）。 */
  readonly retryDisabled: boolean;
  /** 失败后点了【重试】、正在重新加载（底部重试行保留）。 */
  readonly retrying: boolean;
  readonly bannerTaps: HomeTap[];
  readonly iconTaps: HomeTap[];
  readonly activityTaps: HomeTap[];
  readonly moreTap: HomeTap | null;
  readonly noticeRows: HomeNoticeRow[];
  readonly productRows: HomeProductRow[];
  readonly section: HomeSectionTicket;

  constructor(owner: number, card: HomeCard, products: Record<string, Object>[], notices: HomeNoticeItem[],
    hidden: boolean, feedLoading: boolean, feedFailed: boolean, feedHasMore: boolean, render: number = 0,
    retryDisabled: boolean = false, noticeContext: HomeNoticeContext | null = null, retrying: boolean = false) {
    this.owner = owner;
    this.render = render;
    this.card = card;
    this.products = products;
    this.notices = notices;
    this.hidden = hidden;
    this.feedLoading = feedLoading;
    this.feedFailed = feedFailed;
    this.feedHasMore = feedHasMore;
    this.retryDisabled = retryDisabled;
    this.retrying = retrying;
    const id: string = card.id;
    this.bannerTaps = card.banners.map((b: HomeBannerItem, i: number): HomeTap => new HomeTap(owner, render, id, i + 1, b.action));
    this.iconTaps = card.icons.map((c: HomeIconItem, i: number): HomeTap => new HomeTap(owner, render, id, i + 1, c.action));
    this.activityTaps = card.activities.map((a: HomeActivityItem, i: number): HomeTap => new HomeTap(owner, render, id, i + 1, a.action));
    this.moreTap = card.moreAction === null ? null : new HomeTap(owner, render, id, 0, card.moreAction as HomeAction);
    const ctx: HomeNoticeContext = noticeContext ?? new HomeNoticeContext('', -1, false);
    this.noticeRows = notices.map((n: HomeNoticeItem): HomeNoticeRow => new HomeNoticeRow(n,
      n.target === null ? null : new HomeTap(owner, render, id, 1, n.target as HomeAction),
      n.closable ? new HomeNoticeCloseTicket(owner, render, ctx.env, ctx.localGeneration, ctx.persist, id, n.itemId,
        n.contentVersion) : null));
    this.productRows = products.map((p: Record<string, Object>, i: number): HomeProductRow => {
      const action: HomeAction | null = HomeCardView.productAction(p);
      return new HomeProductRow(p, action === null ? null : new HomeTap(owner, render, id, i + 1, action), i + 1);
    });
    this.section = new HomeSectionTicket(owner, render, id);
  }

  /** 商品项 → ProductDetail 的动作（契约路由参数：platform、product_key、item_ref?）。 */
  static productAction(p: Record<string, Object>): HomeAction | null {
    const platform: Object | undefined = p['platform'];
    const key: Object | undefined = p['product_key'];
    if (typeof platform !== 'string' || typeof key !== 'string') {
      return null;
    }
    const params: Record<string, Object> = {};
    params['platform'] = platform;
    params['product_key'] = key;
    const ref: Object | undefined = p['item_ref'];
    if (typeof ref === 'string' && (ref as string).length > 0) {
      params['item_ref'] = ref;
    }
    return new HomeAction('ProductDetail', params, true);
  }
}

/** 页面快照（不可变）。 */
export class HomeSnapshot {
  /** 控制器编号（回调捕获、执行时只比较）。 */
  owner: number = 0;
  /** 内容换代编号（换一份页面配置加一；下拉替换内容后回到顶部，G23）。 */
  renderSerial: number = 0;
  showing: string = HomeShowing.NONE;
  version: number = 0;
  cards: HomeCardView[] = [];
  refreshing: boolean = false;
  refreshDisabled: boolean = false;
  /** 预加载图片中的弹窗候选（图片加载完成才弹，G14 ⑨）。 */
  popupCandidate: HomeCard | null = null;
  /** 正在显示的弹窗。 */
  popup: HomeCard | null = null;
  popupSerial: number = 0;
  /** 被丢弃的卡（HomePreview 页底列出，G24 ⑥）。 */
  dropped: HomeDropped[] = [];
  readonlyMode: boolean = false;
  /** 本次渲染的归属（下拉刷新、【重试】、滚动交互的回调捕获它，R1-02）。 */
  ticket: HomeRenderTicket = new HomeRenderTicket(0, 0);
  /** 弹窗候选的图片预加载票据（R1-02/03）。 */
  popupImage: HomePopupImageTicket | null = null;
  /** 正在显示的弹窗票据（显示计数、关闭、点图片）。 */
  popupTicket: HomePopupTicket | null = null;
}

/** 首页当前显示的版本与来源级别（G31，诊断信息「首页版本」）。 */
export class HomeVersionInfo {
  readonly version: number;
  readonly source: string;

  constructor(version: number, source: string) {
    this.version = version;
    this.source = source;
  }
}

class FetchTicket {
  readonly seq: number;
  readonly pull: boolean;

  constructor(seq: number, pull: boolean) {
    this.seq = seq;
    this.pull = pull;
  }
}

/** 渲染来源：冷启动（LKG、包内默认、冷启动拉到的网络版）、下拉刷新、草稿预览。只有冷启动与草稿预览会安排弹窗（G14 ④，R1-03）。 */
class RenderOrigin {
  static readonly COLD: string = 'cold';
  static readonly PULL: string = 'pull';
  static readonly DRAFT: string = 'draft';
}

export class HomeController {
  private static serials: number = 0;
  readonly serial: number;
  private readonly deps: HomeDeps;
  private readonly identity: HomeIdentity;
  private readonly identityKey: string;
  private readonly policy: HomeSourcePolicy = new HomeSourcePolicy();
  private disposed: boolean = false;
  private started: boolean = false;
  private decoded: HomeDecoded | null = null;
  private renderSerial: number = 0;
  private sections: Map<string, HomeSectionData> = new Map<string, HomeSectionData>();
  private sectionSerial: Map<string, number> = new Map<string, number>();
  private fetchSeq: number = 0;
  private lastWrittenSeq: number = 0;
  /**
   * 冷启动读 LKG 时的登录世代票据（F-HM-35，HomeLkgStore.epochTicket）：之后的 LKG 写入核对它，世代变了（同账号重新登录、会话被清）
   * 不写。start 之前为 undefined（不核对）。
   */
  private lkgEpoch: string | null | undefined = undefined;
  private waitTimer: number = -1;
  private noticeTimer: number = -1;
  private refreshing: boolean = false;
  private refreshResolve: ((replaced: boolean) => void) | null = null;
  private refreshRender: number = 0;
  /** 下拉刷新过：之后这一次运行不再安排弹窗（G14 ④「下拉刷新换了内容不再弹」）。 */
  private pulled: boolean = false;
  private popupCandidate: HomeCard | null = null;
  /** 候选编号：每次换候选（含清空）加一，旧图片结果按它拒绝（R1-03）。 */
  private candidateSerial: number = 0;
  private popupImageReady: boolean = false;
  private popup: HomeCard | null = null;
  private popupSerial: number = 0;
  private popupDone: boolean = false;
  private popupCounted: boolean = false;
  /** 内存里的关闭（基本模式只读不落盘；落盘失败时本次运行仍隐藏）。 */
  private closedInMemory: string[] = [];
  private readonly ownerGuard: () => boolean;
  private gateUnsubscribe: (() => void) | null = null;
  onChange: (s: HomeSnapshot) => void = (_s: HomeSnapshot) => {
  };

  constructor(deps: HomeDeps) {
    HomeController.serials++;
    this.serial = HomeController.serials;
    this.deps = deps;
    // 构造时一次性固定身份（之后只比较）。
    this.identity = deps.identity;
    this.identityKey = deps.identity.key;
    this.ownerGuard = (): boolean => this.alive();
    this.gateUnsubscribe = deps.gate.subscribe((): void => this.publish());
  }

  /** 控制器仍有效：没作废、此刻身份与构造时一致。 */
  alive(): boolean {
    if (this.disposed) {
      return false;
    }
    try {
      return this.deps.currentKey() === this.identityKey;
    } catch (e) {
      return false;
    }
  }

  get boundIdentity(): HomeIdentity {
    return this.identity;
  }

  get currentVersion(): HomeVersionInfo {
    const d: HomeDecoded | null = this.decoded;
    return new HomeVersionInfo(d === null ? 0 : d.version, this.policy.current);
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  private readonlyMode(): boolean {
    return this.deps.preview || this.identity.level === HomeLevel.BASIC;
  }

  /** 渲染票据仍是这一次渲染（控制器、内容换代都一致，控制器仍有效）。 */
  private current(owner: number, render: number): boolean {
    return owner === this.serial && render === this.renderSerial && this.alive();
  }

  // ---------------------------------------------------------------- 三级兜底

  /** 冷启动（或作废后按新身份重建）：有 LKG 立即显示，无 LKG 等网络 1.5 秒，超时先显示包内默认。 */
  start(): void {
    if (this.started || this.deps.preview) {
      return;
    }
    this.started = true;
    const scope: string = this.identity.scope;
    this.lkgEpoch = this.deps.lkg.epochTicket();
    const lkgText: string | null = this.deps.lkg.load(scope);
    this.apply(this.policy.step('cold_start', HomeController.arg('hasLkg', lkgText !== null)), null, lkgText);
    if (this.deps.contract === null) {
      // Release 没有网络来源（G02）：不等 1.5 秒，直接按「LKG → 包内默认」显示。
      this.apply(this.policy.step('timer_1500', {}), null, null);
    } else {
      this.waitTimer = this.deps.timer.schedule(HomeSourcePolicy.WAIT_MS, (): void => {
        this.waitTimer = -1;
        if (!this.alive()) {
          return;
        }
        this.apply(this.policy.step('timer_1500', {}), null, null);
        this.publish();
      });
      this.fetch(false);
    }
    this.publish();
  }

  /** LoadFailed 版式的【重试】：重新走一次冷启动（最后防线，G16 ⑦）。票据是渲染时的归属。 */
  retry(t: HomeRenderTicket): void {
    if (!this.current(t.owner, t.render) || this.deps.preview) {
      return;
    }
    this.started = false;
    this.start();
  }

  /** 用户在首页滚动或点击过（G16 ③：之后到达的网络版不再替换，只写 LKG）。 */
  interacted(t: HomeRenderTicket): void {
    if (t.owner !== this.serial || !this.alive()) {
      return;
    }
    this.policy.step('user_interacted', {});
  }

  /**
   * 下拉刷新（票据是渲染时的归属）。返回的 Promise 在本次刷新结束（成功、失败、被拦下、控制器作废）时完成，值为「这次刷新替换了这个
   * 控制器的内容且控制器仍有效」：界面只有为 true 且当前快照仍属这个控制器时才回到顶部（R1-02）。
   */
  pullRefresh(t: HomeRenderTicket): Promise<boolean> {
    if (!this.current(t.owner, t.render) || this.deps.preview || this.deps.contract === null) {
      return Promise.resolve(false);
    }
    if (this.refreshing) {
      return Promise.resolve(false);
    }
    if (this.deps.gate.active) {
      // 本地限流拦下：结束刷新动画并提示一次 42901（APP-09 第 45、56 条）。
      this.deps.toast('error.42901', '');
      this.publish();
      return Promise.resolve(false);
    }
    this.refreshing = true;
    this.refreshRender = this.renderSerial;
    this.policy.step('pull_refresh', {});
    const done: Promise<boolean> = new Promise<boolean>((resolve: (replaced: boolean) => void) => {
      this.refreshResolve = resolve;
    });
    this.fetch(true);
    this.publish();
    return done;
  }

  private endRefresh(): void {
    this.refreshing = false;
    const r: ((replaced: boolean) => void) | null = this.refreshResolve;
    this.refreshResolve = null;
    if (r !== null) {
      r(!this.disposed && this.alive() && this.renderSerial !== this.refreshRender);
    }
  }

  private fetch(pull: boolean): void {
    const contract: HomeContractPort | null = this.deps.contract;
    if (contract === null) {
      return;
    }
    this.fetchSeq++;
    const ticket: FetchTicket = new FetchTicket(this.fetchSeq, pull);
    const sendAllowed: () => boolean = (): boolean => this.alive() && this.deps.gate.sendAllowed();
    let promise: Promise<ApiResult>;
    try {
      promise = contract.getPage(this.deps.pageKey, this.identity.anonymous, sendAllowed);
    } catch (e) {
      promise = Promise.resolve(HomeController.networkError());
    }
    promise.catch((): ApiResult => HomeController.networkError()).then((r: ApiResult): void => {
      this.onPage(ticket, r);
    });
  }

  private static networkError(): ApiResult {
    return new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null, null, null);
  }

  private onPage(ticket: FetchTicket, result: ApiResult): void {
    // 等待后复核：作废、身份变了 → 丢弃（不写新身份的 LKG、不改屏）。
    if (!this.alive()) {
      if (!this.disposed) {
        this.policy.step('identity_changed', {});
      }
      if (ticket.pull) {
        this.endRefresh();
      }
      return;
    }
    const latest: boolean = ticket.seq === this.fetchSeq;
    const origin: string = ticket.pull ? RenderOrigin.PULL : RenderOrigin.COLD;
    if (result.ok) {
      const text: string = JSON.stringify(result.data);
      const decoded: HomeDecoded = HomeJson.decodePage(result.data as HomeJsonObject, this.deps.platform,
        this.deps.appVersion);
      if (!latest) {
        // 下拉刷新发出后到达的旧冷启动结果：只写 LKG（且不覆盖更新的结果），不替换当前屏。
        if (decoded.renderable && ticket.seq > this.lastWrittenSeq) {
          this.writeLkg(text, ticket.seq);
        }
        return;
      }
      if (!decoded.renderable) {
        this.apply(this.policy.step('network_fail', HomeController.arg('kind', 'invalid_page')), null, null,
          result.traceId);
      } else {
        const arg: HomeJsonObject = {};
        arg['valid'] = true;
        arg['version'] = decoded.version;
        this.apply(this.policy.step('network_ok', arg), decoded, text, '', ticket.seq, origin);
      }
    } else if (latest) {
      const arg: HomeJsonObject = {};
      arg['kind'] = HomeController.failKind(result);
      arg['traceId'] = result.traceId;
      arg['retryAfter'] = HomeController.retryAfterOf(result);
      this.apply(this.policy.step('network_fail', arg), null, null, result.traceId);
    }
    if (ticket.pull && latest) {
      this.endRefresh();
    }
    this.publish();
  }

  private static failKind(r: ApiResult): string {
    if (r.code === 42901) {
      return 'http_42901';
    }
    if (ErrorActionMapper.forcesUpdate(r.code, r.effect)) {
      // 只有网络层判定的强更（FU-HM-0718 第 1 轮修复 G05）；REFRESH_ONLY / 刷新失败的 10405 按下面的通用失败（下拉提示 error.50001、可再下拉）。
      return 'code_10405';
    }
    if (r.outcome === ApiOutcome.NETWORK_ERROR) {
      return r.failure === TransportFailure.TIMEOUT ? 'timeout' : 'offline';
    }
    // 5xxxx 与其余业务错误：下拉时按统一错误消息提示（带 trace6），后台静默。
    return 'http_5xx';
  }

  /** 网络层已把 Retry-After 算进 effect（ErrorActionMapper）；这里按毫秒转成秒字符串交给状态机。 */
  private static retryAfterOf(r: ApiResult): HomeJsonValue {
    const effect: ErrorEffect | null = r.effect;
    if (effect !== null && effect.disableMillis > 0) {
      return String(Math.ceil(effect.disableMillis / 1000));
    }
    return null;
  }

  private static arg(key: string, value: Object): HomeJsonObject {
    const o: HomeJsonObject = {};
    o[key] = value;
    return o;
  }

  /** 执行状态机给的动作。 */
  private apply(step: HomeSourceStep, network: HomeDecoded | null, networkText: string | null, traceId: string = '',
    seq: number = 0, origin: string = RenderOrigin.COLD): void {
    for (const action of step.actions) {
      if (action === HomeSourcePolicy.SHOW_LKG) {
        // 读出的 LKG 当场解码（坏文件 → lkg_loaded(false)，当作无 LKG）。
        const decoded: HomeDecoded = HomeJson.decodeText(networkText, this.deps.platform, this.deps.appVersion);
        if (decoded.renderable) {
          this.render(decoded, RenderOrigin.COLD);
          this.policy.step('lkg_loaded', HomeController.arg('valid', true));
        } else {
          this.deps.log('home lkg invalid');
          this.apply(this.policy.step('lkg_loaded', HomeController.arg('valid', false)), null, null);
        }
      } else if (action === HomeSourcePolicy.SHOW_DEFAULT) {
        const decoded: HomeDecoded = HomeJson.decodeText(this.readDefault(), this.deps.platform, this.deps.appVersion);
        if (decoded.renderable) {
          this.render(decoded, RenderOrigin.COLD);
          this.policy.step('default_loaded', HomeController.arg('valid', true));
        } else {
          this.deps.log('home default invalid');
          this.apply(this.policy.step('default_loaded', HomeController.arg('valid', false)), null, null);
        }
      } else if (action === HomeSourcePolicy.SHOW_NETWORK && network !== null) {
        this.render(network, origin);
      } else if (action === HomeSourcePolicy.WRITE_LKG && networkText !== null) {
        this.writeLkg(networkText, seq);
      } else if (action === HomeSourcePolicy.SHOW_LOAD_FAILED) {
        this.decoded = null;
        this.renderSerial++;
        this.sections = new Map<string, HomeSectionData>();
        this.dropCandidate();
      } else if (action === HomeSourcePolicy.DISABLE_REFRESH) {
        this.deps.gate.start(step.refreshDisabledMs ?? 5000);
      } else if (action === HomeSourcePolicy.FORCE_UPDATE) {
        this.deps.forceUpdate();
      } else if (action.startsWith(HomeSourcePolicy.TOAST_PREFIX)) {
        this.deps.toast(action.substring(HomeSourcePolicy.TOAST_PREFIX.length), traceId);
      }
    }
  }

  private readDefault(): string | null {
    try {
      return this.deps.defaultJson();
    } catch (e) {
      return null;
    }
  }

  private writeLkg(text: string, seq: number): void {
    // 只存服务端下发的页面 JSON（G30）；写失败只记日志（G16 ①）。日志只记版本与来源，不记正文。
    if (this.deps.preview) {
      return;
    }
    const ok: boolean = this.deps.lkg.save(this.identity.scope, text, this.deps.lkg.clearGeneration, this.lkgEpoch);
    if (ok) {
      this.lastWrittenSeq = Math.max(this.lastWrittenSeq, seq);
    } else {
      this.deps.log('home lkg not written');
    }
  }

  // ---------------------------------------------------------------- 渲染

  /** HomePreview：草稿直接交给同一个渲染器（不写 LKG、计数、关闭记录，不发埋点；popup 立即预览一次）。 */
  showDraft(decoded: HomeDecoded): void {
    if (!this.deps.preview || !this.alive()) {
      return;
    }
    this.render(decoded, RenderOrigin.DRAFT);
    this.publish();
  }

  private render(decoded: HomeDecoded, origin: string): void {
    this.decoded = decoded;
    this.renderSerial++;
    this.sections = new Map<string, HomeSectionData>();
    // 换了一份页面：旧候选与它的图片就绪状态一并作废（旧图片结果按候选编号与内容换代拒绝，R1-03）。
    this.dropCandidate();
    if (origin === RenderOrigin.PULL) {
      this.pulled = true;
    }
    this.reportDropped(decoded);
    for (const card of decoded.listCards) {
      if (card.dynamicSource) {
        this.loadSection(card, null, false);
      }
    }
    if (origin !== RenderOrigin.PULL && !this.pulled) {
      this.evaluatePopup(decoded);
    }
  }

  private dropCandidate(): void {
    if (this.popupCandidate !== null || this.popupImageReady) {
      this.popupCandidate = null;
      this.popupImageReady = false;
    }
    this.candidateSerial++;
  }

  /** sdui_card_error：只为 dropped 的几张各发一次（同一进程内去重）；基本模式与 HomePreview 不发（G20、G25）。 */
  private reportDropped(decoded: HomeDecoded): void {
    if (this.readonlyMode()) {
      return;
    }
    for (const d of decoded.dropped) {
      if (!this.deps.dedupe.shouldSend(decoded.version, d.id, d.reason)) {
        continue;
      }
      try {
        this.deps.track(ClientEvents.sduiCardError('Home', d.type, decoded.version, d.reason, d.version));
      } catch (e) {
        // 字段不合法（版本不是整数等）不发。
      }
    }
  }

  // ---------------------------------------------------------------- 卡片数据源

  private loadSection(card: HomeCard, cursor: string | null, retrying: boolean): void {
    const id: string = card.id;
    const serial: number = (this.sectionSerial.get(id) ?? 0) + 1;
    this.sectionSerial.set(id, serial);
    const render: number = this.renderSerial;
    const previous: HomeSectionData = this.sections.get(id) ?? HomeSectionData.initial();
    if (card.sourceKind === HomeSourceKind.API) {
      this.sections.set(id, HomeSectionData.initial());
      const port: HomeNoticePort | null = this.deps.notices;
      if (port === null) {
        this.sections.set(id, new HomeSectionData([], [], false, true, null, true));
        return;
      }
      port.listNotices(this.ownerGuard, (): boolean => this.alive() && this.deps.gate.sendAllowed())
        .catch((): ApiResult => HomeController.networkError())
        .then((r: ApiResult): void => {
          if (!this.alive() || render !== this.renderSerial || serial !== this.sectionSerial.get(id)) {
            return;
          }
          // 42901 先写进共享闸门（按 Retry-After，缺省 5 秒），再隐藏公告卡（R1-04）；10405 照已有分流进强更。冷启动静默不提示。
          this.handleSharedErrors(r);
          // 失败或空 → 隐藏卡，不提示（G10）。
          this.sections.set(id, new HomeSectionData([], r.ok ? HomeController.noticesOf(r.data) : [], false, !r.ok,
            null, true));
          this.publish();
        });
      return;
    }
    const contract: HomeContractPort | null = this.deps.contract;
    if (contract === null) {
      // Release：商品池与物料信息流一律按没有数据，整张卡隐藏（G03）。
      this.sections.set(id, new HomeSectionData([], [], false, false, null, true));
      return;
    }
    this.sections.set(id, new HomeSectionData(previous.products, [], true, false, previous.cursor, previous.loaded,
      retrying));
    contract.listSectionItems(this.deps.pageKey, id, cursor, this.identity.anonymous,
      (): boolean => this.alive() && this.deps.gate.sendAllowed())
      .catch((): ApiResult => HomeController.networkError())
      .then((r: ApiResult): void => {
        if (!this.alive() || render !== this.renderSerial || serial !== this.sectionSerial.get(id)) {
          return;
        }
        const before: Record<string, Object>[] = cursor === null ? [] : previous.products;
        if (!r.ok) {
          this.handleSharedErrors(r);
          // 一页失败只停止加载（信息流底部给【重试】），不影响上方卡片。
          this.sections.set(id, new HomeSectionData(before, [], false, true, cursor, true));
        } else {
          const items: Record<string, Object>[] = HomeController.productsOf(r.data);
          const next: Object | undefined = r.data['next_cursor'];
          this.sections.set(id, new HomeSectionData(before.concat(items), [], false, false,
            typeof next === 'string' && (next as string).length > 0 ? next as string : null, true));
        }
        this.publish();
      });
  }

  /** 三个首页接口共用（brief §0）：42901 写共享闸门（页面与发包两处生效），网络层判定的强更 10405 进强更。 */
  private handleSharedErrors(r: ApiResult): void {
    if (r.ok) {
      return;
    }
    if (r.code === 42901) {
      this.deps.gate.start(disableMillisOf(r));
    } else if (ErrorActionMapper.forcesUpdate(r.code, r.effect)) {
      // FU-HM-0718 第 1 轮修复（G05）：公告（listArticles，作用域含 deletion_only）等读取只在网络层判强更时进强更；
      // 非强更 10405 只是这次读取失败（公告卡隐藏、不提示，G10；下次刷新再取）。
      this.deps.forceUpdate();
    }
  }

  /** 信息流触底加载下一页（只在有下一页、没在加载、没失败、没被限流时）。票据是渲染时的归属。 */
  loadMore(t: HomeSectionTicket): void {
    if (!this.current(t.owner, t.render) || this.deps.gate.active) {
      return;
    }
    const card: HomeCard | undefined = this.decoded?.listCards.find((c: HomeCard): boolean => c.id === t.sectionId);
    const data: HomeSectionData | undefined = this.sections.get(t.sectionId);
    if (card === undefined || data === undefined || data.loading || data.failed || data.cursor === null) {
      return;
    }
    this.loadSection(card, data.cursor, false);
    this.publish();
  }

  /** 信息流底部【重试】（42901 闸门生效时禁用，页面与执行层两处，R1-05）。 */
  retrySection(t: HomeSectionTicket): void {
    if (!this.current(t.owner, t.render)) {
      return;
    }
    if (this.deps.gate.active) {
      this.deps.toast('error.42901', '');
      return;
    }
    const card: HomeCard | undefined = this.decoded?.listCards.find((c: HomeCard): boolean => c.id === t.sectionId);
    const data: HomeSectionData | undefined = this.sections.get(t.sectionId);
    if (card === undefined || data === undefined || data.loading) {
      return;
    }
    this.loadSection(card, data.cursor, true);
    this.publish();
  }

  private static productsOf(data: Record<string, Object>): Record<string, Object>[] {
    const items: Object | undefined = data['items'];
    if (!Array.isArray(items)) {
      return [];
    }
    const out: Record<string, Object>[] = [];
    for (const item of items as Object[]) {
      if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
        out.push(item as Record<string, Object>);
      }
    }
    return out;
  }

  private static noticesOf(data: Record<string, Object>): HomeNoticeItem[] {
    const items: Object | undefined = data['items'];
    if (!Array.isArray(items)) {
      return [];
    }
    const out: HomeNoticeItem[] = [];
    for (const raw of items as Object[]) {
      const summary: HomeJsonObject | null = HomeJsonRead.objectOf(raw as HomeJsonValue);
      if (summary === null || summary['category'] !== 'notice') {
        continue;
      }
      const item: HomeNoticeItem | null = HomeJson.noticeItem(summary['notice']);
      if (item !== null) {
        out.push(item);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- 公告

  private closedKeys(): string[] {
    const keys: string[] = this.deps.preview ? [] : this.deps.local.closedKeys();
    return keys.concat(this.closedInMemory);
  }

  /**
   * 公告关闭后的页面隐藏（落盘由 HomeTicketPort 按票据核对后做，R1-01）：只在票据仍属这个控制器时重画；旧页面的回调不改新页面。
   */
  hideNotice(t: HomeNoticeCloseTicket): void {
    if (t.owner !== this.serial || !this.alive()) {
      return;
    }
    this.closedInMemory.push(t.key);
    this.publish();
  }

  private scheduleNoticeExpiry(next: number | null): void {
    if (this.noticeTimer >= 0) {
      this.deps.timer.cancel(this.noticeTimer);
      this.noticeTimer = -1;
    }
    if (next === null || this.disposed) {
      return;
    }
    const wait: number = Math.max(0, next - this.deps.clock());
    // 页面停留时在最近的 end_at 到期时重算（不轮询网络，G10）。
    this.noticeTimer = this.deps.timer.schedule(wait, (): void => {
      this.noticeTimer = -1;
      if (this.alive()) {
        this.publish();
      }
    });
  }

  // ---------------------------------------------------------------- 弹窗

  private evaluatePopup(decoded: HomeDecoded): void {
    if (this.popupDone || this.popup !== null) {
      return;
    }
    const card: HomeCard | null = decoded.popup;
    if (card === null) {
      return;
    }
    if (this.deps.preview) {
      // 草稿里的 popup 立即预览一次（忽略每日次数与时间段，G24 ⑤），仍要图片加载成功。
      this.popupCandidate = card;
      return;
    }
    const d: PopupDecision = PopupPolicy.decideCard(card, this.identity.level, this.deps.clock(),
      this.deps.local.shownToday(card.id, this.deps.clock()), this.deps.coldStartShown(), [], true);
    if (d.show) {
      this.popupCandidate = card;
    }
  }

  /** 票据是不是此刻这一个候选的图片（控制器、内容换代、候选编号、section id、图片地址都一致）。 */
  private imageTicketCurrent(t: HomePopupImageTicket): boolean {
    const c: HomeCard | null = this.popupCandidate;
    return c !== null && this.current(t.owner, t.render) && t.candidate === this.candidateSerial
      && c.id === t.sectionId && c.popupImage === t.image && this.popup === null;
  }

  /** 弹窗图片加载完成（UI 预加载）：再按阻挡项判一次（G14 ④⑨）。票据是渲染时的值，执行时只比较（R1-02）。 */
  popupImageLoaded(t: HomePopupImageTicket): void {
    if (!this.imageTicketCurrent(t)) {
      return;
    }
    this.popupImageReady = true;
    this.tryShowPopup();
  }

  /** 图片加载失败：不弹（不显示只有关闭按钮的空框），不计数。 */
  popupImageFailed(t: HomePopupImageTicket): void {
    if (!this.imageTicketCurrent(t)) {
      return;
    }
    this.popupCandidate = null;
    this.popupImageReady = false;
    this.candidateSerial++;
    this.popupDone = true;
    this.publish();
  }

  /** 阻挡项变化（隐私弹窗、强更、更新提示、剪贴板提示条、半屏结束，首页回到前台）：仍满足条件才弹。 */
  blockersChanged(): void {
    if (!this.alive() || this.popup !== null || this.popupCandidate === null || !this.popupImageReady) {
      return;
    }
    this.tryShowPopup();
  }

  /** 图片已就绪、仍等阻挡项结束（AppHome 按它决定是否每秒复核）。 */
  get popupWaiting(): boolean {
    return this.alive() && this.popup === null && this.popupCandidate !== null && this.popupImageReady;
  }

  private tryShowPopup(): void {
    const card: HomeCard | null = this.popupCandidate;
    if (card === null || !this.popupImageReady) {
      return;
    }
    const blockers: string[] = this.deps.blockers();
    let show: boolean;
    if (this.deps.preview) {
      show = blockers.length === 0;
    } else {
      const now: number = this.deps.clock();
      show = PopupPolicy.decideCard(card, this.identity.level, now, this.deps.local.shownToday(card.id, now),
        this.deps.coldStartShown(), blockers, true).show;
    }
    if (!show) {
      return;
    }
    this.popup = card;
    this.popupSerial++;
    this.popupCounted = false;
    this.publish();
  }

  private popupTicketCurrent(t: HomePopupTicket): boolean {
    const card: HomeCard | null = this.popup;
    return card !== null && t.owner === this.serial && t.popupSerial === this.popupSerial && card.id === t.sectionId
      && this.alive();
  }

  /** 弹窗已真正显示（界面 onAppear）：此时才计数（G14 ⑤）；预览不计数。 */
  popupShown(t: HomePopupTicket): void {
    if (!this.popupTicketCurrent(t) || this.popupCounted) {
      return;
    }
    this.popupCounted = true;
    if (this.deps.preview) {
      return;
    }
    this.deps.markColdStartShown();
    if (!this.deps.local.countShown(t.sectionId, this.deps.clock())) {
      this.deps.log('home popup count not persisted');
    }
  }

  /**
   * 真正打开模态之前的最后复核（R2-03）：票据仍是此刻显示的这一个、控制器有效、没有阻挡项（含页面被盖住、切走、退到后台）。
   * 不满足就不打开：还没真正显示过的退回「图片已就绪、等阻挡项结束」（之后复核通过再弹，换新的弹窗编号）；已显示过的按关闭处理。
   */
  popupBeforeOpen(t: HomePopupTicket): boolean {
    if (!this.popupTicketCurrent(t)) {
      return false;
    }
    if (this.deps.blockers().length === 0) {
      return true;
    }
    this.suspendPopup();
    return false;
  }

  /**
   * 页面可见性变化（切走 Tab、被别的页面盖住、退到后台，或回来）：显示中的弹窗此刻有阻挡 → 收起（已显示过的按关闭处理，
   * 没显示过的退回等待）；没有显示中的弹窗 → 仍满足条件才弹（R2-03）。
   */
  visibilityChanged(): void {
    if (!this.alive()) {
      return;
    }
    if (this.popup !== null) {
      if (this.deps.blockers().length > 0) {
        this.suspendPopup();
      }
      return;
    }
    this.blockersChanged();
  }

  private suspendPopup(): void {
    if (this.popup === null) {
      return;
    }
    this.popup = null;
    if (this.popupCounted) {
      // 已真正显示过（已计数）：按关闭处理，之后不再弹。
      this.popupCandidate = null;
      this.popupImageReady = false;
      this.candidateSerial++;
      this.popupDone = true;
    }
    // 没显示过：保留候选与图片就绪，阻挡结束后由 blockersChanged 复核再弹。
    this.publish();
  }

  /** 关闭弹窗（关闭按钮、返回键、点遮罩、点图片执行动作后）：点一次即关。返回是否关了（系统返回按它决定是否消费）。 */
  closePopup(t: HomePopupTicket): boolean {
    if (t.owner !== this.serial || t.popupSerial !== this.popupSerial || this.popup === null) {
      return false;
    }
    this.popup = null;
    this.popupCandidate = null;
    this.popupImageReady = false;
    this.popupDone = true;
    this.publish();
    return true;
  }

  /** 系统返回（首页与预览共用，R1-14）：有弹窗就先关弹窗并消费返回；没有弹窗返回 false（交给页面照常处理）。 */
  backPressed(): boolean {
    const card: HomeCard | null = this.popup;
    if (card === null || this.disposed) {
      return false;
    }
    this.popup = null;
    this.popupCandidate = null;
    this.popupImageReady = false;
    this.popupDone = true;
    this.publish();
    return true;
  }

  // ---------------------------------------------------------------- 动作

  /**
   * 卡片点击：票据（控制器、内容换代、section id、坑位、动作）都是渲染时的值。控制器已作废（换号、撤回同意）或内容已换代 → 不执行。
   * 动作原样交 Router（in_app），不做占位替换、不拼任何个人数据（BR-ID-33）；spm 只作旁路上下文（G06）。
   */
  open(t: HomeTap): void {
    if (t.owner !== this.serial || !this.alive()) {
      return;
    }
    // 弹窗图片的票据随弹窗编号（不随内容换代）；卡片点击要求仍是这一次渲染。
    if (t.render >= 0 && t.render !== this.renderSerial) {
      return;
    }
    this.policy.step('user_interacted', {});
    const params: Record<string, Object> = {};
    for (const k of Object.keys(t.action.params)) {
      params[k] = t.action.params[k];
    }
    this.deps.open(t.action.route, params, 'home.' + t.sectionId + '.' + t.slot);
  }

  // ---------------------------------------------------------------- 作废

  /**
   * 归属变化（会话失效、登出、换账号、撤回同意、切换环境）：作废在途请求、已排程的弹窗与计时、数据源分页；正在显示的弹窗立即关闭且不计数。
   * 旧控制器之后的任何结果都不再写 LKG、不改屏。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.policy.step('identity_changed', {});
    if (this.waitTimer >= 0) {
      this.deps.timer.cancel(this.waitTimer);
      this.waitTimer = -1;
    }
    if (this.noticeTimer >= 0) {
      this.deps.timer.cancel(this.noticeTimer);
      this.noticeTimer = -1;
    }
    this.popup = null;
    this.popupCandidate = null;
    this.popupImageReady = false;
    this.candidateSerial++;
    this.popupDone = true;
    try {
      this.deps.contract?.cancel(this.serial);
      this.deps.notices?.cancelOwned(this.ownerGuard);
    } catch (e) {
      // 端口出错不影响作废。
    }
    const unsubscribe: (() => void) | null = this.gateUnsubscribe;
    this.gateUnsubscribe = null;
    if (unsubscribe !== null) {
      unsubscribe();
    }
    this.endRefresh();
  }

  // ---------------------------------------------------------------- 快照

  snapshot(): HomeSnapshot {
    const s: HomeSnapshot = new HomeSnapshot();
    s.owner = this.serial;
    s.renderSerial = this.renderSerial;
    s.ticket = new HomeRenderTicket(this.serial, this.renderSerial);
    s.showing = this.policy.current;
    s.readonlyMode = this.readonlyMode();
    s.refreshing = this.refreshing;
    s.refreshDisabled = this.deps.gate.active;
    if (this.disposed) {
      return s;
    }
    const d: HomeDecoded | null = this.decoded;
    if (d === null) {
      return s;
    }
    s.version = d.version;
    s.dropped = d.dropped;
    const now: number = this.deps.clock();
    const closed: string[] = this.closedKeys();
    const gated: boolean = this.deps.gate.active;
    const noticeContext: HomeNoticeContext = new HomeNoticeContext(this.identity.env, this.deps.local.generation,
      !this.readonlyMode());
    let nextExpiry: number | null = null;
    const views: HomeCardView[] = [];
    for (const card of d.listCards) {
      const data: HomeSectionData = this.sections.get(card.id) ?? HomeSectionData.initial();
      let notices: HomeNoticeItem[] = [];
      let hidden: boolean;
      if (card.type === HomeCardType.NOTICE_BAR) {
        const source: HomeNoticeItem[] = card.sourceKind === HomeSourceKind.API ? data.notices : card.notices;
        const view: NoticeView = NoticeFilter.filter(card.id, source, closed, now);
        notices = view.visible;
        hidden = view.cardHidden;
        if (view.nextExpiryMs !== null && (nextExpiry === null || view.nextExpiryMs < nextExpiry)) {
          nextExpiry = view.nextExpiryMs;
        }
      } else if (card.type === HomeCardType.FEED_INFINITE) {
        // 信息流：成功但为空、或首屏加载中 → 隐藏（不画空壳）；加载失败（含失败后重试中）保留底部重试行（R1-05）。
        hidden = data.products.length === 0 && !data.failed && !data.retrying;
      } else if (card.type === HomeCardType.PRODUCT_SCROLL || card.type === HomeCardType.PRODUCT_GRID) {
        // 数据源为空 → 只隐藏这一张（加载中也不画空壳与骨架，F-HOME-05）。
        hidden = data.products.length === 0;
      } else {
        hidden = card.itemCount === 0;
      }
      views.push(new HomeCardView(this.serial, card, data.products, notices, hidden, data.loading, data.failed,
        data.cursor !== null, this.renderSerial, gated, noticeContext, data.retrying));
    }
    s.cards = views;
    const candidate: HomeCard | null = this.popup === null ? this.popupCandidate : null;
    s.popupCandidate = candidate;
    s.popupImage = candidate === null ? null : new HomePopupImageTicket(this.serial, this.renderSerial,
      this.candidateSerial, candidate.id, candidate.popupImage);
    s.popup = this.popup;
    s.popupSerial = this.popupSerial;
    const popup: HomeCard | null = this.popup;
    s.popupTicket = popup === null ? null : new HomePopupTicket(this.serial, this.popupSerial, popup.id,
      popup.popupImage, popup.popupAction === null ? null :
        new HomeTap(this.serial, -1, popup.id, 1, popup.popupAction as HomeAction), popup.sectionAdLabel);
    this.scheduleNoticeExpiry(nextExpiry);
    return s;
  }

  publish(): void {
    if (this.disposed) {
      return;
    }
    try {
      this.onChange(this.snapshot());
    } catch (e) {
      // 界面出错不影响状态。
    }
  }
}

/**
 * 首页 / HomePreview 页面的执行出口（Core 部分，R1-01/02）：只接收渲染时的票据，按票据找控制器并比较；控制器换了就不执行，
 * 不转交给新控制器。公告关闭的落盘在这里按票据核对：允许落盘、环境与本机记录清理世代都没变才写（同一环境换账号仍记，G11）；
 * 不再有「控制器为空就直接落盘」的兜底。entry 的 HomeControllerPort 包一层（商品卡映射、图片地址、【问 AI】）。
 */
export class HomeTicketPort {
  private readonly source: () => HomeController | null;
  private readonly local: HomeLocalStore | null;
  private readonly env: () => string;
  /** 弹窗进入「图片已就绪、等阻挡项结束」时通知（页面据此定时复核阻挡项，R2-03）。 */
  onWaiting: () => void = () => {
  };

  /** local 为 null：本页不落盘（HomePreview）。env：此刻的环境名（只比较）。 */
  constructor(source: () => HomeController | null, local: HomeLocalStore | null, env: () => string) {
    this.source = source;
    this.local = local;
    this.env = env;
  }

  private ctl(owner: number): HomeController | null {
    const c: HomeController | null = this.source();
    return c !== null && c.serial === owner ? c : null;
  }

  open(t: HomeTap): void {
    this.ctl(t.owner)?.open(t);
  }

  closeNotice(t: HomeNoticeCloseTicket): boolean {
    let persisted: boolean = false;
    const local: HomeLocalStore | null = this.local;
    if (local !== null && t.persist) {
      let env: string = '';
      try {
        env = this.env();
      } catch (e) {
        env = '';
      }
      if (env === t.env && local.generation === t.localGeneration) {
        persisted = local.addClosed(t.key);
      }
    }
    this.ctl(t.owner)?.hideNotice(t);
    return persisted;
  }

  refresh(t: HomeRenderTicket): Promise<boolean> {
    const c: HomeController | null = this.ctl(t.owner);
    return c === null ? Promise.resolve(false) : c.pullRefresh(t);
  }

  retry(t: HomeRenderTicket): void {
    this.ctl(t.owner)?.retry(t);
  }

  interacted(t: HomeRenderTicket): void {
    this.ctl(t.owner)?.interacted(t);
  }

  loadMore(t: HomeSectionTicket): void {
    this.ctl(t.owner)?.loadMore(t);
  }

  retrySection(t: HomeSectionTicket): void {
    this.ctl(t.owner)?.retrySection(t);
  }

  popupImageLoaded(t: HomePopupImageTicket): void {
    const c: HomeController | null = this.ctl(t.owner);
    if (c === null) {
      return;
    }
    c.popupImageLoaded(t);
    this.notifyWaiting(c);
  }

  /** 打开模态之前的复核（R2-03）：按票据找控制器，不转交给新控制器。 */
  popupBeforeOpen(t: HomePopupTicket): boolean {
    const c: HomeController | null = this.ctl(t.owner);
    if (c === null) {
      return false;
    }
    const ok: boolean = c.popupBeforeOpen(t);
    if (!ok) {
      this.notifyWaiting(c);
    }
    return ok;
  }

  private notifyWaiting(c: HomeController): void {
    if (c.popupWaiting) {
      try {
        this.onWaiting();
      } catch (e) {
        // 页面出错不影响执行层。
      }
    }
  }

  popupImageFailed(t: HomePopupImageTicket): void {
    this.ctl(t.owner)?.popupImageFailed(t);
  }

  popupShown(t: HomePopupTicket): void {
    this.ctl(t.owner)?.popupShown(t);
  }

  closePopup(t: HomePopupTicket): boolean {
    const c: HomeController | null = this.ctl(t.owner);
    return c === null ? false : c.closePopup(t);
  }

  /** 点弹窗图片：先关弹窗，再按图片动作打开（执行即关闭）。 */
  openPopup(t: HomePopupTicket): void {
    const c: HomeController | null = this.ctl(t.owner);
    if (c === null || t.tap === null || !c.closePopup(t)) {
      return;
    }
    c.open(t.tap as HomeTap);
  }

  /**
   * 页面级系统返回（HomePreview 的 NavDestination.onBackPressed）：本页此刻的控制器有弹窗就先关。系统模态自己的关闭回调不走这里，
   * 一律按它绑定的票据走 closePopup（R2-02）。
   */
  backPressed(): boolean {
    const c: HomeController | null = this.source();
    return c === null ? false : c.backPressed();
  }
}
