// APP-11 首页 SDUI 的强类型模型（rule-gaps G01、G12–G14：首页 schema 不在锁定契约里，字段按 03 §6.1 / §6.3 摘要与代拟字段手写）。
// TODO(N-35)：CT-07 的 home-schema.json 补上后按契约改模型，并把向量迁到 fixtures/home-golden。
// 所有可能出错的计算（数据映射、动作校验、时间解析）都在解码阶段完成（HomeJson），这里只放解码后的普通值，视图只做纯展示（03 §6.2 第 2 步）。

export type HomeJsonValue = Object | null;
export type HomeJsonObject = Record<string, HomeJsonValue>;

/** 本端编译进去的 8 种卡片（03 §6.3）；其余 type 一律静默跳过（G01）。 */
export class HomeCardType {
  static readonly BANNER: string = 'banner';
  static readonly ICON_GRID: string = 'icon_grid';
  static readonly PRODUCT_SCROLL: string = 'product_scroll';
  static readonly PRODUCT_GRID: string = 'product_grid';
  static readonly ACTIVITY_ENTRY: string = 'activity_entry';
  static readonly NOTICE_BAR: string = 'notice_bar';
  static readonly FEED_INFINITE: string = 'feed_infinite';
  static readonly POPUP: string = 'popup';
  static readonly ALL: string[] = ['banner', 'icon_grid', 'product_scroll', 'product_grid', 'activity_entry',
    'notice_bar', 'feed_infinite', 'popup'];
  /** 每种卡片渲染器支持的最高 section version（G07：本任务都是 1）。 */
  static readonly MAX_VERSION: number = 1;
}

/** 数据源种类（03 §6.1、G03、G10、G13）。 */
export class HomeSourceKind {
  static readonly STATIC: string = 'static';
  static readonly API: string = 'api';
  static readonly PRODUCT_POOL: string = 'product_pool';
  static readonly UNION_MATERIAL: string = 'union_material';
}

/** sdui_card_error 的 reason（G21 代拟固定几种）与跳过原因。 */
export class HomeReason {
  static readonly MISSING_FIELD: string = 'missing_field';
  static readonly BAD_TYPE: string = 'bad_type';
  static readonly MISSING_VERSION: string = 'missing_version';
  static readonly UNSUPPORTED_VERSION: string = 'unsupported_version';
  static readonly BAD_VALUE: string = 'bad_value';
  static readonly DUPLICATE_ID: string = 'duplicate_id';
  static readonly BAD_ACTION: string = 'bad_action';
  /** skipped（不记事件）。 */
  static readonly UNKNOWN_TYPE: string = 'unknown_type';
  static readonly MIN_APP_VERSION: string = 'min_app_version';
}

/** 卡片动作：只认 RouteTarget{route, params?}（F-HOME-09、G05）；点击时一律交 Router（入口 in_app）。 */
export class HomeAction {
  readonly route: string;
  /** 参数原样（Router 按路由表 params schema 校验；不注入 spm、不做占位替换，G06、BR-ID-33）。 */
  readonly params: Record<string, Object>;
  /** 下发里有 params 字段（原样回给向量；Router 调用时没有就传空对象）。 */
  readonly hasParams: boolean;

  constructor(route: string, params: Record<string, Object>, hasParams: boolean) {
    this.route = route;
    this.params = params;
    this.hasParams = hasParams;
  }
}

export class HomeBannerItem {
  readonly image: string;
  readonly action: HomeAction;
  /** 条目级优先、否则 section 级（G22）；都没有为 null。原样显示。 */
  readonly adLabel: string | null;
  readonly alt: string | null;

  constructor(image: string, action: HomeAction, adLabel: string | null, alt: string | null) {
    this.image = image;
    this.action = action;
    this.adLabel = adLabel;
    this.alt = alt;
  }
}

export class HomeIconItem {
  /** https 地址，或包内图标 builtin:<名>（只认 HomeBuiltinIcon 列出的名字，G17）。 */
  readonly icon: string;
  readonly title: string;
  readonly action: HomeAction;
  readonly badge: string | null;

  constructor(icon: string, title: string, action: HomeAction, badge: string | null) {
    this.icon = icon;
    this.title = title;
    this.action = action;
    this.badge = badge;
  }
}

export class HomeActivityItem {
  readonly image: string | null;
  readonly title: string | null;
  readonly subtitle: string | null;
  readonly action: HomeAction;

  constructor(image: string | null, title: string | null, subtitle: string | null, action: HomeAction) {
    this.image = image;
    this.title = title;
    this.subtitle = subtitle;
    this.action = action;
  }
}

/** 契约 NoticeItem（04 §6.2），时刻已解析为毫秒。 */
export class HomeNoticeItem {
  readonly itemId: string;
  readonly contentVersion: number;
  readonly text: string;
  readonly target: HomeAction | null;
  readonly closable: boolean;
  readonly startMs: number;
  readonly endMs: number | null;

  constructor(itemId: string, contentVersion: number, text: string, target: HomeAction | null, closable: boolean,
    startMs: number, endMs: number | null) {
    this.itemId = itemId;
    this.contentVersion = contentVersion;
    this.text = text;
    this.target = target;
    this.closable = closable;
    this.startMs = startMs;
    this.endMs = endMs;
  }
}

/** 包内图标名（G17：只用于包内默认；未知名字按坏条目丢弃，不能据此放行任意协议）。 */
export class HomeBuiltinIcon {
  static readonly PREFIX: string = 'builtin:';
  static readonly NAMES: string[] = ['platform.taobao', 'platform.jd', 'platform.pdd', 'category.supermarket',
    'category.fresh', 'category.baby', 'category.beauty', 'category.household', 'category.electronics', 'guide'];

  static nameOf(icon: string): string | null {
    if (!icon.startsWith(HomeBuiltinIcon.PREFIX)) {
      return null;
    }
    const name: string = icon.substring(HomeBuiltinIcon.PREFIX.length);
    return HomeBuiltinIcon.NAMES.indexOf(name) >= 0 ? name : null;
  }
}

/** 解码成功的一张卡。字段按 type 取用，其余为缺省值。 */
export class HomeCard {
  readonly id: string;
  readonly type: string;
  readonly version: number;
  sectionAdLabel: string | null = null;
  // banner
  heightRatio: number = 0;
  autoplayMs: number = 0;
  banners: HomeBannerItem[] = [];
  // icon_grid
  columns: number = 0;
  rows: number = 0;
  icons: HomeIconItem[] = [];
  // product_scroll / product_grid / feed_infinite
  title: string | null = null;
  moreAction: HomeAction | null = null;
  sourceKind: string = HomeSourceKind.STATIC;
  poolId: string | null = null;
  limit: number = 0;
  platforms: string[] = [];
  mix: string | null = null;
  // activity_entry
  layout: string | null = null;
  activities: HomeActivityItem[] = [];
  // notice_bar
  noticeMode: string = 'static';
  notices: HomeNoticeItem[] = [];
  // popup
  popupImage: string = '';
  dailyMax: number = 0;
  /** 上海时区的分钟数（含起点不含终点，G14 ①）。 */
  windowStart: number = 0;
  windowEnd: number = 0;
  popupAction: HomeAction | null = null;

  constructor(id: string, type: string, version: number) {
    this.id = id;
    this.type = type;
    this.version = version;
  }

  /** 静态条目数（向量 itemCounts；动态数据源的卡为 0）。 */
  get itemCount(): number {
    switch (this.type) {
      case HomeCardType.BANNER:
        return this.banners.length;
      case HomeCardType.ICON_GRID:
        return this.icons.length;
      case HomeCardType.ACTIVITY_ENTRY:
        return this.activities.length;
      case HomeCardType.NOTICE_BAR:
        return this.notices.length;
      case HomeCardType.POPUP:
        return this.popupAction === null ? 0 : 1;
      default:
        return 0;
    }
  }

  /** 需要再取数据的卡（商品池 / 物料信息流 / 公告 api）。 */
  get dynamicSource(): boolean {
    return this.sourceKind === HomeSourceKind.PRODUCT_POOL || this.sourceKind === HomeSourceKind.UNION_MATERIAL
      || this.sourceKind === HomeSourceKind.API;
  }
}

export class HomeSkipped {
  readonly id: string;
  readonly reason: string;

  constructor(id: string, reason: string) {
    this.id = id;
    this.reason = reason;
  }
}

export class HomeDropped {
  readonly id: string;
  readonly type: string;
  readonly version: number | null;
  readonly reason: string;

  constructor(id: string, type: string, version: number | null, reason: string) {
    this.id = id;
    this.type = type;
    this.version = version;
    this.reason = reason;
  }
}

/** 一页的解码结果（kept / skipped / dropped 三选一，F-HOME-05、G07、G08）。 */
export class HomeDecoded {
  readonly valid: boolean;
  readonly pageKey: string;
  readonly version: number;
  readonly ttlSec: number | null;
  readonly kept: HomeCard[];
  readonly skipped: HomeSkipped[];
  readonly dropped: HomeDropped[];
  /** 页面里第一个解码成功的 popup（G14 ③）；没有为 null。 */
  readonly popupId: string | null;

  constructor(valid: boolean, pageKey: string, version: number, ttlSec: number | null, kept: HomeCard[],
    skipped: HomeSkipped[], dropped: HomeDropped[], popupId: string | null) {
    this.valid = valid;
    this.pageKey = pageKey;
    this.version = version;
    this.ttlSec = ttlSec;
    this.kept = kept;
    this.skipped = skipped;
    this.dropped = dropped;
    this.popupId = popupId;
  }

  static invalid(): HomeDecoded {
    return new HomeDecoded(false, '', 0, null, [], [], [], null);
  }

  /** 首页里显示的卡（popup 不在列表里渲染，另由弹窗处理）。 */
  get listCards(): HomeCard[] {
    return this.kept.filter((c: HomeCard): boolean => c.type !== HomeCardType.POPUP);
  }

  get popup(): HomeCard | null {
    const id: string | null = this.popupId;
    if (id === null) {
      return null;
    }
    const found: HomeCard | undefined = this.kept.find((c: HomeCard): boolean => c.type === HomeCardType.POPUP
      && c.id === id);
    return found === undefined ? null : found;
  }

  /** 成功渲染（G16 ①）：整页有效且至少一张卡解码成功。 */
  get renderable(): boolean {
    return this.valid && this.kept.length > 0;
  }
}
