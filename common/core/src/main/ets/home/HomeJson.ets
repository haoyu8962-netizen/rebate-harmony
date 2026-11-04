// APP-11 首页页面配置的两段解码（03 §6.2 第 2 步，F-HOME-05、F-HOME-06、G05、G07–G09、G12–G14、G21、G22）：
// 先把 sections 当通用 JSON 数组，再逐项按 type 解成强类型卡片。每项三选一：kept / skipped（未知 type、门槛不满足——不记事件）/
// dropped{reason}（记 sdui_card_error）。条目级坏数据只丢条目（只记本机日志、不记事件）。
// 不执行任何下发的脚本或表达式：condition 一律不读（G09）；动作只认 RouteTarget（url / js / scheme 等字段出现即忽略，G05）。
// TODO(N-35)：字段名是代拟（G12–G14），schema 补上后按契约改。
import { UpdateGate } from '../update/UpdateGate';
import {
  HomeAction, HomeActivityItem, HomeBannerItem, HomeBuiltinIcon, HomeCard, HomeCardType, HomeDecoded, HomeDropped,
  HomeIconItem, HomeJsonObject, HomeJsonValue, HomeNoticeItem, HomeReason, HomeSkipped, HomeSourceKind
} from './HomeModels';

/** 解码一项失败的原因（内部用）。 */
class SectionFailure {
  readonly reason: string;

  constructor(reason: string) {
    this.reason = reason;
  }
}

const ISO_RE: RegExp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;
const HHMM_RE: RegExp = /^([01]\d|2[0-3]):([0-5]\d)$/;
const NOTICE_KEYS: string[] = ['item_id', 'content_version', 'text', 'target', 'closable', 'start_at', 'end_at'];
const PLATFORMS: string[] = ['taobao', 'jd', 'pdd'];

/** JSON 取值小工具（不抛出）。 */
export class HomeJsonRead {
  static isObject(v: HomeJsonValue | undefined): boolean {
    return v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v);
  }

  static objectOf(v: HomeJsonValue | undefined): HomeJsonObject | null {
    return HomeJsonRead.isObject(v) ? v as HomeJsonObject : null;
  }

  static arrayOf(v: HomeJsonValue | undefined): HomeJsonValue[] | null {
    return Array.isArray(v) ? v as HomeJsonValue[] : null;
  }

  static stringOf(v: HomeJsonValue | undefined): string | null {
    return typeof v === 'string' ? v as string : null;
  }

  static positiveInt(v: HomeJsonValue | undefined): number | null {
    return typeof v === 'number' && Number.isSafeInteger(v as number) && (v as number) >= 1 ? v as number : null;
  }

  /** 带时区的 RFC 3339 时刻 → 毫秒；不合法为 null。 */
  static instant(v: HomeJsonValue | undefined): number | null {
    if (typeof v !== 'string' || !ISO_RE.test(v as string)) {
      return null;
    }
    const ms: number = Date.parse(v as string);
    return Number.isSafeInteger(ms) ? ms : null;
  }

  /** https 图片地址（只收 https，鸿蒙直接 Image(url)，在解码阶段校验）。 */
  static httpsUrl(v: HomeJsonValue | undefined): string | null {
    if (typeof v !== 'string') {
      return null;
    }
    const s: string = v as string;
    return /^https:\/\/[^\s/?#]+[^\s]*$/.test(s) ? s : null;
  }

  /** "HH:mm" → 分钟数；不合法为 null。 */
  static minutesOf(v: HomeJsonValue | undefined): number | null {
    if (typeof v !== 'string') {
      return null;
    }
    const m: RegExpMatchArray | null = (v as string).match(HHMM_RE);
    return m === null ? null : Number.parseInt(m[1], 10) * 60 + Number.parseInt(m[2], 10);
  }
}

export class HomeJson {
  /**
   * 动作解码（G05）：只认 {route: 非空字符串, params?: 对象}；其余字段忽略、形状不对 → null。不查路由表（未知名称交 Router 的未知路由处理）。
   * params 显式为 null、数组、字符串 → null（不是对象）。
   */
  static action(value: HomeJsonValue | undefined): HomeAction | null {
    const obj: HomeJsonObject | null = HomeJsonRead.objectOf(value);
    if (obj === null) {
      return null;
    }
    const route: string | null = HomeJsonRead.stringOf(obj['route']);
    if (route === null || route.length === 0) {
      return null;
    }
    if (!(Object.keys(obj).indexOf('params') >= 0)) {
      return new HomeAction(route, {}, false);
    }
    const params: HomeJsonObject | null = HomeJsonRead.objectOf(obj['params']);
    if (params === null) {
      return null;
    }
    const copy: Record<string, Object> = {};
    for (const key of Object.keys(params)) {
      const v: HomeJsonValue = params[key];
      if (v !== null && v !== undefined) {
        copy[key] = v;
      }
    }
    return new HomeAction(route, copy, true);
  }

  /** 解码 JSON 文本；不是对象按整页无效。 */
  static decodeText(text: string | null, platform: string, appVersion: string): HomeDecoded {
    if (text === null) {
      return HomeDecoded.invalid();
    }
    try {
      const parsed: Object = JSON.parse(text) as Object;
      const page: HomeJsonObject | null = HomeJsonRead.objectOf(parsed);
      return page === null ? HomeDecoded.invalid() : HomeJson.decodePage(page, platform, appVersion);
    } catch (e) {
      return HomeDecoded.invalid();
    }
  }

  /** 整页解码（G07：sections 不是数组或 version 不是正整数 → 整页无效）。 */
  static decodePage(page: HomeJsonObject, platform: string, appVersion: string): HomeDecoded {
    const version: number | null = HomeJsonRead.positiveInt(page['version']);
    const sections: HomeJsonValue[] | null = HomeJsonRead.arrayOf(page['sections']);
    if (version === null || sections === null) {
      return HomeDecoded.invalid();
    }
    const pageKey: string = HomeJsonRead.stringOf(page['page_key']) ?? '';
    // ttl_sec 只解析、不用于显示决策（G15）。
    const ttl: HomeJsonValue | undefined = page['ttl_sec'];
    const ttlSec: number | null = typeof ttl === 'number' && Number.isSafeInteger(ttl as number) && (ttl as number) >= 0 ?
      ttl as number : null;
    const kept: HomeCard[] = [];
    const skipped: HomeSkipped[] = [];
    const dropped: HomeDropped[] = [];
    const keptIds: Set<string> = new Set<string>();
    let popupId: string | null = null;
    for (const raw of sections) {
      const section: HomeJsonObject | null = HomeJsonRead.objectOf(raw);
      if (section === null) {
        dropped.push(new HomeDropped('', '', null, HomeReason.BAD_TYPE));
        continue;
      }
      const idValue: HomeJsonValue | undefined = section['id'];
      const typeValue: HomeJsonValue | undefined = section['type'];
      const id: string = typeof idValue === 'string' ? idValue as string : '';
      const type: string = typeof typeValue === 'string' ? typeValue as string : '';
      const versionValue: HomeJsonValue | undefined = section['version'];
      const rawVersion: number | null = typeof versionValue === 'number' && Number.isSafeInteger(versionValue as number) ?
        versionValue as number : null;
      if (idValue === undefined || idValue === null || typeValue === undefined || typeValue === null) {
        dropped.push(new HomeDropped(id, type, rawVersion, HomeReason.MISSING_FIELD));
        continue;
      }
      if (typeof idValue !== 'string' || id.length === 0 || typeof typeValue !== 'string') {
        dropped.push(new HomeDropped(id, type, rawVersion, HomeReason.BAD_TYPE));
        continue;
      }
      if (HomeCardType.ALL.indexOf(type) < 0) {
        skipped.push(new HomeSkipped(id, HomeReason.UNKNOWN_TYPE));
        continue;
      }
      const hasMin: boolean = Object.keys(section).indexOf('min_app_version') >= 0;
      if (!HomeSectionFilter.keep(section['min_app_version'], !hasMin, platform, appVersion)) {
        skipped.push(new HomeSkipped(id, HomeReason.MIN_APP_VERSION));
        continue;
      }
      // condition：一律不读、不求值（G09、BR-INV-23）。
      if (versionValue === undefined || versionValue === null) {
        dropped.push(new HomeDropped(id, type, null, HomeReason.MISSING_VERSION));
        continue;
      }
      if (typeof versionValue !== 'number') {
        dropped.push(new HomeDropped(id, type, null, HomeReason.BAD_TYPE));
        continue;
      }
      if (rawVersion === null || rawVersion < 1) {
        dropped.push(new HomeDropped(id, type, rawVersion, HomeReason.BAD_VALUE));
        continue;
      }
      if (rawVersion > HomeCardType.MAX_VERSION) {
        dropped.push(new HomeDropped(id, type, rawVersion, HomeReason.UNSUPPORTED_VERSION));
        continue;
      }
      const card: HomeCard | SectionFailure = HomeJson.decodeCard(section, id, type, rawVersion);
      if (card instanceof SectionFailure) {
        dropped.push(new HomeDropped(id, type, rawVersion, (card as SectionFailure).reason));
        continue;
      }
      // 重复 id：保留第一个解码成功的，其余按解码失败（G08）。
      if (keptIds.has(id)) {
        dropped.push(new HomeDropped(id, type, rawVersion, HomeReason.DUPLICATE_ID));
        continue;
      }
      keptIds.add(id);
      kept.push(card as HomeCard);
      if (type === HomeCardType.POPUP && popupId === null) {
        popupId = id;
      }
    }
    return new HomeDecoded(true, pageKey, version, ttlSec, kept, skipped, dropped, popupId);
  }

  private static decodeCard(section: HomeJsonObject, id: string, type: string,
    version: number): HomeCard | SectionFailure {
    const card: HomeCard = new HomeCard(id, type, version);
    const adLabel: HomeJsonValue | undefined = section['ad_label'];
    if (adLabel !== undefined && adLabel !== null && typeof adLabel !== 'string') {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    card.sectionAdLabel = typeof adLabel === 'string' ? adLabel as string : null;
    const propsValue: HomeJsonValue | undefined = section['props'];
    const sourceValue: HomeJsonValue | undefined = section['data_source'];
    if (propsValue !== undefined && propsValue !== null && !HomeJsonRead.isObject(propsValue)) {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    if (sourceValue !== undefined && sourceValue !== null && !HomeJsonRead.isObject(sourceValue)) {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    const props: HomeJsonObject | null = HomeJsonRead.objectOf(propsValue);
    const source: HomeJsonObject | null = HomeJsonRead.objectOf(sourceValue);
    switch (type) {
      case HomeCardType.BANNER:
        return HomeJson.banner(card, props, source);
      case HomeCardType.ICON_GRID:
        return HomeJson.iconGrid(card, props, source);
      case HomeCardType.PRODUCT_SCROLL:
        return HomeJson.productScroll(card, props, source);
      case HomeCardType.PRODUCT_GRID:
        return HomeJson.productGrid(card, props, source);
      case HomeCardType.ACTIVITY_ENTRY:
        return HomeJson.activity(card, props, source);
      case HomeCardType.NOTICE_BAR:
        return HomeJson.noticeBar(card, props, source);
      case HomeCardType.FEED_INFINITE:
        return HomeJson.feed(card, props, source);
      case HomeCardType.POPUP:
        return HomeJson.popup(card, props, source);
      default:
        return new SectionFailure(HomeReason.BAD_TYPE);
    }
  }

  /** static 数据源的条目数组：缺 data_source / items → missing_field；kind 不是 static → bad_value。 */
  private static staticItems(source: HomeJsonObject | null): HomeJsonValue[] | SectionFailure {
    if (source === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const kind: HomeJsonValue | undefined = source['kind'];
    if (kind === undefined || kind === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (kind !== HomeSourceKind.STATIC) {
      return new SectionFailure(typeof kind === 'string' ? HomeReason.BAD_VALUE : HomeReason.BAD_TYPE);
    }
    const items: HomeJsonValue | undefined = source['items'];
    if (items === undefined || items === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const list: HomeJsonValue[] | null = HomeJsonRead.arrayOf(items);
    return list === null ? new SectionFailure(HomeReason.BAD_TYPE) : list;
  }

  /** 商品类数据源（G03、G13）：只认 product_pool / union_material；其余种类（含 api）→ bad_value。 */
  private static productSource(card: HomeCard, source: HomeJsonObject | null): SectionFailure | null {
    if (source === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const kind: HomeJsonValue | undefined = source['kind'];
    if (kind === undefined || kind === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (typeof kind !== 'string') {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    if (kind === HomeSourceKind.PRODUCT_POOL) {
      const pool: HomeJsonValue | undefined = source['pool_id'];
      if (pool === undefined || pool === null) {
        return new SectionFailure(HomeReason.MISSING_FIELD);
      }
      if (typeof pool !== 'string' || (pool as string).length === 0) {
        return new SectionFailure(HomeReason.BAD_TYPE);
      }
      card.poolId = pool as string;
    } else if (kind !== HomeSourceKind.UNION_MATERIAL) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    card.sourceKind = kind as string;
    const limit: HomeJsonValue | undefined = source['limit'];
    if (limit !== undefined && limit !== null) {
      const n: number | null = HomeJsonRead.positiveInt(limit);
      if (n === null) {
        return new SectionFailure(typeof limit === 'number' ? HomeReason.BAD_VALUE : HomeReason.BAD_TYPE);
      }
      card.limit = n;
    }
    return null;
  }

  private static banner(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const ratio: HomeJsonValue | undefined = props['height_ratio'];
    if (ratio === undefined || ratio === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (typeof ratio !== 'number' || !Number.isFinite(ratio as number)) {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    if ((ratio as number) <= 0 || (ratio as number) > 1) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    card.heightRatio = ratio as number;
    const autoplay: HomeJsonValue | undefined = props['autoplay_ms'];
    if (autoplay !== undefined && autoplay !== null) {
      if (typeof autoplay !== 'number') {
        return new SectionFailure(HomeReason.BAD_TYPE);
      }
      if (!Number.isSafeInteger(autoplay as number) || (autoplay as number) < 0) {
        return new SectionFailure(HomeReason.BAD_VALUE);
      }
      card.autoplayMs = autoplay as number;
    }
    const items: HomeJsonValue[] | SectionFailure = HomeJson.staticItems(source);
    if (items instanceof SectionFailure) {
      return items as SectionFailure;
    }
    for (const raw of items as HomeJsonValue[]) {
      const item: HomeJsonObject | null = HomeJsonRead.objectOf(raw);
      if (item === null) {
        continue;
      }
      const image: string | null = HomeJsonRead.httpsUrl(item['image']);
      const action: HomeAction | null = HomeJson.action(item['action']);
      const label: HomeJsonValue | undefined = item['ad_label'];
      const alt: HomeJsonValue | undefined = item['alt'];
      if (image === null || action === null || (label !== undefined && label !== null && typeof label !== 'string')
        || (alt !== undefined && alt !== null && typeof alt !== 'string')) {
        continue;
      }
      card.banners.push(new HomeBannerItem(image, action, HomeAdLabel.of(card.sectionAdLabel, label),
        typeof alt === 'string' && (alt as string).length > 0 ? alt as string : null));
    }
    return card;
  }

  private static iconGrid(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const columns: HomeJsonValue | undefined = props['columns'];
    if (columns === undefined || columns === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (typeof columns !== 'number') {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    if (columns !== 4 && columns !== 5) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    card.columns = columns as number;
    const rows: HomeJsonValue | undefined = props['rows'];
    if (rows !== undefined && rows !== null) {
      if (typeof rows !== 'number') {
        return new SectionFailure(HomeReason.BAD_TYPE);
      }
      if (HomeJsonRead.positiveInt(rows) === null) {
        return new SectionFailure(HomeReason.BAD_VALUE);
      }
      card.rows = rows as number;
    }
    const items: HomeJsonValue[] | SectionFailure = HomeJson.staticItems(source);
    if (items instanceof SectionFailure) {
      return items as SectionFailure;
    }
    for (const raw of items as HomeJsonValue[]) {
      const item: HomeJsonObject | null = HomeJsonRead.objectOf(raw);
      if (item === null) {
        continue;
      }
      const iconRaw: string | null = HomeJsonRead.stringOf(item['icon']);
      const icon: string | null = iconRaw === null ? null :
        (HomeBuiltinIcon.nameOf(iconRaw) !== null ? iconRaw : HomeJsonRead.httpsUrl(iconRaw));
      const title: string | null = HomeJsonRead.stringOf(item['title']);
      const action: HomeAction | null = HomeJson.action(item['action']);
      const badge: HomeJsonValue | undefined = item['badge'];
      if (icon === null || title === null || title.length === 0 || action === null
        || (badge !== undefined && badge !== null && typeof badge !== 'string')) {
        continue;
      }
      card.icons.push(new HomeIconItem(icon, title, action,
        typeof badge === 'string' && (badge as string).length > 0 ? badge as string : null));
    }
    // 行数：给了 rows 按 columns × rows 截取（不随屏宽增加列数，brief §0 读屏与大屏）。
    if (card.rows > 0 && card.icons.length > card.columns * card.rows) {
      card.icons = card.icons.slice(0, card.columns * card.rows);
    }
    return card;
  }

  private static productScroll(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const title: HomeJsonValue | undefined = props['title'];
    if (title === undefined || title === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (typeof title !== 'string') {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    card.title = title as string;
    const more: HomeJsonValue | undefined = props['more_action'];
    if (more !== undefined && more !== null) {
      const action: HomeAction | null = HomeJson.action(more);
      if (action === null) {
        return new SectionFailure(HomeReason.BAD_ACTION);
      }
      card.moreAction = action;
    }
    return HomeJson.productSource(card, source) ?? card;
  }

  private static productGrid(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const columns: HomeJsonValue | undefined = props['columns'];
    if (columns === undefined || columns === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (typeof columns !== 'number') {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    if (columns !== 1 && columns !== 2) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    card.columns = columns as number;
    const title: HomeJsonValue | undefined = props['title'];
    if (title !== undefined && title !== null) {
      if (typeof title !== 'string') {
        return new SectionFailure(HomeReason.BAD_TYPE);
      }
      card.title = title as string;
    }
    return HomeJson.productSource(card, source) ?? card;
  }

  private static activity(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props !== null) {
      const layout: HomeJsonValue | undefined = props['layout'];
      if (layout !== undefined && layout !== null) {
        if (typeof layout !== 'string') {
          return new SectionFailure(HomeReason.BAD_TYPE);
        }
        card.layout = layout as string;
      }
    }
    const items: HomeJsonValue[] | SectionFailure = HomeJson.staticItems(source);
    if (items instanceof SectionFailure) {
      return items as SectionFailure;
    }
    if ((items as HomeJsonValue[]).length > 3) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    for (const raw of items as HomeJsonValue[]) {
      const item: HomeJsonObject | null = HomeJsonRead.objectOf(raw);
      if (item === null) {
        continue;
      }
      const imageRaw: HomeJsonValue | undefined = item['image'];
      const image: string | null = imageRaw === undefined || imageRaw === null ? null : HomeJsonRead.httpsUrl(imageRaw);
      const title: HomeJsonValue | undefined = item['title'];
      const subtitle: HomeJsonValue | undefined = item['subtitle'];
      const action: HomeAction | null = HomeJson.action(item['action']);
      const badImage: boolean = imageRaw !== undefined && imageRaw !== null && image === null;
      const badTitle: boolean = title !== undefined && title !== null && typeof title !== 'string';
      const badSub: boolean = subtitle !== undefined && subtitle !== null && typeof subtitle !== 'string';
      const titleText: string | null = typeof title === 'string' && (title as string).length > 0 ? title as string : null;
      if (action === null || badImage || badTitle || badSub || (titleText === null && image === null)) {
        continue;
      }
      card.activities.push(new HomeActivityItem(image, titleText,
        typeof subtitle === 'string' && (subtitle as string).length > 0 ? subtitle as string : null, action));
    }
    return card;
  }

  /** NoticeItem（04 §6.2，additionalProperties: false）；不合 schema → null（只丢这一条，G08、G10）。 */
  static noticeItem(value: HomeJsonValue | undefined): HomeNoticeItem | null {
    const item: HomeJsonObject | null = HomeJsonRead.objectOf(value);
    if (item === null) {
      return null;
    }
    for (const key of Object.keys(item)) {
      if (NOTICE_KEYS.indexOf(key) < 0) {
        return null;
      }
    }
    const itemId: string | null = HomeJsonRead.stringOf(item['item_id']);
    const version: number | null = HomeJsonRead.positiveInt(item['content_version']);
    const text: string | null = HomeJsonRead.stringOf(item['text']);
    const closable: HomeJsonValue | undefined = item['closable'];
    const start: number | null = HomeJsonRead.instant(item['start_at']);
    const endRaw: HomeJsonValue | undefined = item['end_at'];
    const end: number | null = endRaw === null ? null : HomeJsonRead.instant(endRaw);
    const targetRaw: HomeJsonValue | undefined = item['target'];
    if (itemId === null || itemId.length === 0 || version === null || text === null || typeof closable !== 'boolean'
      || start === null || endRaw === undefined || (endRaw !== null && end === null) || targetRaw === undefined) {
      return null;
    }
    const target: HomeAction | null = targetRaw === null ? null : HomeJson.action(targetRaw);
    if (targetRaw !== null && target === null) {
      return null;
    }
    // 契约 not 约束：closable=false 时 end_at 不能为 null。
    if (closable === false && end === null) {
      return null;
    }
    return new HomeNoticeItem(itemId, version, text, target, closable as boolean, start, end);
  }

  private static noticeBar(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props !== null) {
      const mode: HomeJsonValue | undefined = props['mode'];
      if (mode !== undefined && mode !== null) {
        if (typeof mode !== 'string') {
          return new SectionFailure(HomeReason.BAD_TYPE);
        }
        if (mode !== 'scroll' && mode !== 'static') {
          return new SectionFailure(HomeReason.BAD_VALUE);
        }
        card.noticeMode = mode as string;
      }
    }
    if (source === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const kind: HomeJsonValue | undefined = source['kind'];
    if (kind === undefined || kind === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (kind === HomeSourceKind.API) {
      // api：只调 listArticles(category=notice) 第一页；data_source 里别的路径与参数一律忽略（G10、03 §6.3）。
      card.sourceKind = HomeSourceKind.API;
      return card;
    }
    if (kind !== HomeSourceKind.STATIC) {
      return new SectionFailure(typeof kind === 'string' ? HomeReason.BAD_VALUE : HomeReason.BAD_TYPE);
    }
    const itemsValue: HomeJsonValue | undefined = props === null ? undefined : props['items'];
    if (itemsValue === undefined || itemsValue === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const items: HomeJsonValue[] | null = HomeJsonRead.arrayOf(itemsValue);
    if (items === null) {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    for (const raw of items) {
      const item: HomeNoticeItem | null = HomeJson.noticeItem(raw);
      if (item !== null) {
        card.notices.push(item);
      }
    }
    return card;
  }

  private static feed(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props !== null) {
      const title: HomeJsonValue | undefined = props['title'];
      if (typeof title === 'string') {
        card.title = title as string;
      }
    }
    if (source === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const kind: HomeJsonValue | undefined = source['kind'];
    if (kind === undefined || kind === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (kind !== HomeSourceKind.UNION_MATERIAL) {
      return new SectionFailure(typeof kind === 'string' ? HomeReason.BAD_VALUE : HomeReason.BAD_TYPE);
    }
    card.sourceKind = HomeSourceKind.UNION_MATERIAL;
    // 契约形状 channels [{platform, channel_id}]（home-schema.json）；旧的 platforms 只给包内 / 三端向量的临时 fixture。
    const channels: HomeJsonValue | undefined = source['channels'];
    if (channels !== undefined && channels !== null) {
      const chs: HomeJsonValue[] | null = HomeJsonRead.arrayOf(channels);
      if (chs === null) {
        return new SectionFailure(HomeReason.BAD_TYPE);
      }
      for (const raw of chs) {
        const ch: HomeJsonObject | null = HomeJsonRead.objectOf(raw);
        const p: string | null = ch === null ? null : HomeJsonRead.stringOf(ch['platform']);
        if (p === null) {
          return new SectionFailure(HomeReason.BAD_VALUE);
        }
        if (card.platforms.indexOf(p) < 0) {
          card.platforms.push(p);
        }
      }
      if (card.platforms.length === 0) {
        return new SectionFailure(HomeReason.BAD_VALUE);
      }
      return HomeJson.feedMix(card, source);
    }
    const platforms: HomeJsonValue | undefined = source['platforms'];
    if (platforms === undefined || platforms === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const list: HomeJsonValue[] | null = HomeJsonRead.arrayOf(platforms);
    if (list === null) {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    for (const p of list) {
      if (typeof p !== 'string' || PLATFORMS.indexOf(p as string) < 0) {
        return new SectionFailure(HomeReason.BAD_VALUE);
      }
      card.platforms.push(p as string);
    }
    if (card.platforms.length === 0) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    return HomeJson.feedMix(card, source);
  }

  private static feedMix(card: HomeCard, source: HomeJsonObject): HomeCard | SectionFailure {
    const mix: HomeJsonValue | undefined = source['mix'];
    if (mix !== undefined && mix !== null) {
      if (mix !== 'interleave') {
        return new SectionFailure(HomeReason.BAD_VALUE);
      }
      card.mix = 'interleave';
    }
    return card;
  }

  private static popup(card: HomeCard, props: HomeJsonObject | null,
    source: HomeJsonObject | null): HomeCard | SectionFailure {
    if (props === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    const imageRaw: HomeJsonValue | undefined = props['image'];
    const dailyRaw: HomeJsonValue | undefined = props['daily_max'];
    const windowRaw: HomeJsonValue | undefined = props['time_window'];
    if (imageRaw === undefined || imageRaw === null || dailyRaw === undefined || dailyRaw === null
      || windowRaw === undefined || windowRaw === null) {
      return new SectionFailure(HomeReason.MISSING_FIELD);
    }
    if (typeof imageRaw !== 'string' || typeof dailyRaw !== 'number' || !Array.isArray(windowRaw)) {
      return new SectionFailure(HomeReason.BAD_TYPE);
    }
    const image: string | null = HomeJsonRead.httpsUrl(imageRaw);
    const daily: number | null = HomeJsonRead.positiveInt(dailyRaw);
    const window: HomeJsonValue[] = windowRaw as HomeJsonValue[];
    if (image === null || daily === null || window.length !== 2) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    const start: number | null = HomeJsonRead.minutesOf(window[0]);
    const end: number | null = HomeJsonRead.minutesOf(window[1]);
    // G14 ①：起点 ≥ 终点（含跨零点）→ 解码失败。
    if (start === null || end === null || start >= end) {
      return new SectionFailure(HomeReason.BAD_VALUE);
    }
    card.popupImage = image;
    card.dailyMax = daily;
    card.windowStart = start;
    card.windowEnd = end;
    if (source !== null) {
      const items: HomeJsonValue[] | null = HomeJsonRead.arrayOf(source['items']);
      if (items !== null && items.length > 0) {
        const first: HomeJsonObject | null = HomeJsonRead.objectOf(items[0]);
        // items[0].action 缺失或形状不对：图片不可点（只丢这一条，G08）。
        card.popupAction = first === null ? null : HomeJson.action(first['action']);
      }
    }
    return card;
  }

  /** 向量接线（HomeVector.test）：kept 每项 {id, type, itemCount}；dropped {id, type, version, reasonRaw}。 */
  static decode(page: HomeJsonObject, platform: string, appVersion: string): HomeJsonObject {
    const d: HomeDecoded = HomeJson.decodePage(page, platform, appVersion);
    const out: HomeJsonObject = {};
    out['pageValid'] = d.valid;
    out['kept'] = d.kept.map((c: HomeCard): HomeJsonObject => {
      const o: HomeJsonObject = {};
      o['id'] = c.id;
      o['type'] = c.type;
      o['itemCount'] = c.itemCount;
      return o;
    });
    out['skipped'] = d.skipped.map((s: HomeSkipped): HomeJsonObject => {
      const o: HomeJsonObject = {};
      o['id'] = s.id;
      o['reasonRaw'] = s.reason;
      return o;
    });
    out['dropped'] = d.dropped.map((x: HomeDropped): HomeJsonObject => {
      const o: HomeJsonObject = {};
      o['id'] = x.id;
      o['type'] = x.type;
      o['version'] = x.version;
      o['reasonRaw'] = x.reason;
      return o;
    });
    out['popupId'] = d.popupId;
    return out;
  }
}

/** 本端门槛只做「当前版本 ≥ 门槛」一种比较（G09、03 §4.3）；版本比较复用 UpdateGate.compareOrNull。 */
export class HomeSectionFilter {
  /**
   * absent：字段不存在（不限制）。字段存在但为 null、不是对象、缺本端键、值不是合法版本号 → 不保留（与 routes.json since: null 同一口径）。
   */
  static keep(minAppVersion: HomeJsonValue | undefined, absent: boolean, platform: string, appVersion: string): boolean {
    if (absent) {
      return true;
    }
    const obj: HomeJsonObject | null = HomeJsonRead.objectOf(minAppVersion);
    if (obj === null) {
      return false;
    }
    const min: string | null = HomeJsonRead.stringOf(obj[platform]);
    if (min === null) {
      return false;
    }
    const compared: number | null = UpdateGate.compareOrNull(appVersion, min);
    return compared !== null && compared >= 0;
  }
}

/** 推广角标（G22）：条目上有非 null 字符串用条目的，否则用 section 级的；原样显示，不替换、不判断。 */
export class HomeAdLabel {
  static of(sectionLabel: HomeJsonValue | undefined, itemLabel: HomeJsonValue | undefined): string | null {
    if (typeof itemLabel === 'string') {
      return itemLabel as string;
    }
    return typeof sectionLabel === 'string' ? sectionLabel as string : null;
  }
}

/** spm（03 §4.7、G06）：home.<section id>.<坑位>，坑位从 1 起；只作上下文，不塞进路由参数。 */
export class HomeSpm {
  static of(sectionId: string, slot: number): string {
    return 'home.' + sectionId + '.' + slot;
  }
}
