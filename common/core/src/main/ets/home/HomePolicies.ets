// APP-11 首页的纯规则（向量 specs/home-sdui-vectors.json）：LKG 分区与清理事件（G16 ②、G11）、公告过滤与关闭键（G10）、弹窗决策（G14）、
// 曝光判定（G20，不接埋点）、sdui_card_error 去重（G20、G21）、三级兜底状态机（G16）。不读系统时钟，时刻一律由调用方给。
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { HomeJson, HomeJsonRead } from './HomeJson';
import { HomeAction, HomeCard, HomeCardType, HomeDecoded, HomeJsonObject, HomeJsonValue, HomeNoticeItem } from './HomeModels';

const SHANGHAI_OFFSET_MS: number = 8 * 60 * 60 * 1000;

/** 首页身份档（与「我的」同一口径：basic / guest / member）。 */
export class HomeLevel {
  static readonly BASIC: string = 'basic';
  static readonly GUEST: string = 'guest';
  static readonly MEMBER: string = 'member';
}

/** BR-TEXT-11：时间按 Asia/Shanghai（与设备时区无关）。 */
export class HomeShanghai {
  /** 上海自然日 YYYY-MM-DD（弹窗每日次数的「一天」，G14 ①）。 */
  static day(epochMillis: number): string {
    const d: Date = new Date(epochMillis + SHANGHAI_OFFSET_MS);
    const m: number = d.getUTCMonth() + 1;
    const day: number = d.getUTCDate();
    return d.getUTCFullYear() + '-' + (m < 10 ? '0' + m : '' + m) + '-' + (day < 10 ? '0' + day : '' + day);
  }

  /** 上海时区一天里的分钟数。 */
  static minuteOfDay(epochMillis: number): number {
    const d: Date = new Date(epochMillis + SHANGHAI_OFFSET_MS);
    return d.getUTCHours() * 60 + d.getUTCMinutes();
  }

  /** HH:mm（HomePreview「HH:mm 前有效」等）。 */
  static hhmm(epochMillis: number): string {
    const d: Date = new Date(epochMillis + SHANGHAI_OFFSET_MS);
    const h: number = d.getUTCHours();
    const m: number = d.getUTCMinutes();
    return (h < 10 ? '0' + h : '' + h) + ':' + (m < 10 ? '0' + m : '' + m);
  }
}

/** LKG 分区（G16 ②、03 §12「缓存键」）：环境 + 账号作用域（user_id / guest / basic）。分隔符是代拟，测试只比较相等关系。 */
export class HomeLkgScope {
  static of(level: string, userId: string | null, env: string): string {
    if (level === HomeLevel.MEMBER) {
      return env + ':user:' + (userId ?? '');
    }
    return env + ':' + (level === HomeLevel.BASIC ? 'basic' : 'guest');
  }

  /**
   * 这个作用域是不是会员作用域（F-HM-35：存储层按「账号 + 持久化登录世代」再分一层，只识别、不改上面 of 的向量取值）。
   * 会员作用域是 of 里的 `<env>:user:<userId>`（账号未知时 userId 为空串，同样按会员处理）；游客、基本模式不分世代。
   */
  static isMember(scope: string): boolean {
    return scope.indexOf(':user:') >= 0;
  }
}

/** 本机三类数据在哪些事件下清（G16 ②、G11）。 */
export class HomeLocalData {
  static readonly LKG_CURRENT: string = 'lkg_current_scope';
  static readonly LKG_OTHER: string = 'lkg_other_scope';
  static readonly NOTICE_CLOSED: string = 'notice_closed';
  static readonly POPUP_COUNT: string = 'popup_count';
  private static readonly ALL_CLEAR: string[] = ['consent_revoked', 'env_switch'];
  private static readonly ACCOUNT_CLEAR: string[] = ['logout', 'account_switch', 'session_invalid'];

  static clearsOn(event: string, item: string): boolean {
    if (HomeLocalData.ALL_CLEAR.indexOf(event) >= 0) {
      return true;
    }
    return item === HomeLocalData.LKG_CURRENT && HomeLocalData.ACCOUNT_CLEAR.indexOf(event) >= 0;
  }
}

/** 公告条过滤的结果（纯值）。 */
export class NoticeView {
  readonly visible: HomeNoticeItem[];
  readonly nextExpiryMs: number | null;

  constructor(visible: HomeNoticeItem[], nextExpiryMs: number | null) {
    this.visible = visible;
    this.nextExpiryMs = nextExpiryMs;
  }

  get cardHidden(): boolean {
    return this.visible.length === 0;
  }
}

/** 公告条（G10、G11、BR-TEXT-13 细则）：生效区间本机再过滤、到期立即隐藏、按「卡片 id + item_id + 内容版本」记关闭。 */
export class NoticeFilter {
  /** 关闭记录键（分隔符代拟；只存组合键，不存正文）。 */
  static closeKey(sectionId: string, itemId: string, contentVersion: number): string {
    return sectionId + '|' + itemId + '|' + contentVersion;
  }

  static filter(sectionId: string, items: HomeNoticeItem[], closedKeys: string[], nowMs: number): NoticeView {
    const closed: Set<string> = new Set<string>(closedKeys);
    const visible: HomeNoticeItem[] = [];
    let next: number | null = null;
    for (const item of items) {
      if (item.startMs > nowMs || (item.endMs !== null && nowMs >= item.endMs)) {
        continue;
      }
      if (closed.has(NoticeFilter.closeKey(sectionId, item.itemId, item.contentVersion))) {
        continue;
      }
      visible.push(item);
      if (item.endMs !== null && (next === null || item.endMs < next)) {
        next = item.endMs;
      }
    }
    return new NoticeView(visible, next);
  }

  /** 向量接线：items 为原始 NoticeItem JSON（不合 schema 的条目只丢这一条）。 */
  static visible(sectionId: string, itemsJson: HomeJsonObject[], closedKeys: string[], nowMs: number): HomeJsonObject {
    const items: HomeNoticeItem[] = [];
    for (const raw of itemsJson) {
      const item: HomeNoticeItem | null = HomeJson.noticeItem(raw);
      if (item !== null) {
        items.push(item);
      }
    }
    const view: NoticeView = NoticeFilter.filter(sectionId, items, closedKeys, nowMs);
    const out: HomeJsonObject = {};
    out['visibleItemIds'] = view.visible.map((i: HomeNoticeItem): string => i.itemId);
    const closable: HomeJsonObject = {};
    for (const i of view.visible) {
      closable[i.itemId] = i.closable;
    }
    out['closable'] = closable;
    out['cardHidden'] = view.cardHidden;
    out['nextExpiryMs'] = view.nextExpiryMs;
    return out;
  }
}

/** 弹窗的阻挡项（G14 ④）。 */
export class PopupBlocker {
  static readonly PRIVACY_DIALOG: string = 'privacy_dialog';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly UPDATE_PROMPT: string = 'update_prompt';
  static readonly CLIPBOARD_PROMPT: string = 'clipboard_prompt';
  static readonly SHEET_OPEN: string = 'sheet_open';
  static readonly HOME_NOT_VISIBLE: string = 'home_not_visible';
}

/** 弹窗决策结果。 */
export class PopupDecision {
  static readonly SHOW: string = 'show';
  static readonly SKIP: string = 'skip';
  readonly decision: string;
  readonly reason: string;
  /** 真正显示后的计数（skip 时等于原计数）。 */
  readonly countAfter: number;

  constructor(decision: string, reason: string, countAfter: number) {
    this.decision = decision;
    this.reason = reason;
    this.countAfter = countAfter;
  }

  get show(): boolean {
    return this.decision === PopupDecision.SHOW;
  }
}

/** 首页弹窗（F-HOME-08、G14）。时间按上海；shownToday 由调用方按上海自然日给。 */
export class PopupPolicy {
  static decideCard(card: HomeCard, level: string, nowMs: number, shownToday: number, coldStartShown: boolean,
    blockers: string[], imageLoaded: boolean): PopupDecision {
    const skip = (reason: string): PopupDecision => new PopupDecision(PopupDecision.SKIP, reason, shownToday);
    if (level === HomeLevel.BASIC) {
      return skip('basic_mode');
    }
    if (coldStartShown) {
      return skip('cold_start_shown');
    }
    if (shownToday >= card.dailyMax) {
      return skip('daily_max');
    }
    const minute: number = HomeShanghai.minuteOfDay(nowMs);
    if (minute < card.windowStart || minute >= card.windowEnd) {
      return skip('time_window');
    }
    if (blockers.length > 0) {
      return skip('blocked');
    }
    if (!imageLoaded) {
      return skip('image_not_loaded');
    }
    return new PopupDecision(PopupDecision.SHOW, '', shownToday + 1);
  }

  /** 向量接线：popupJson 是完整 section（解码不过 → skip）。 */
  static decide(popupJson: HomeJsonObject, level: string, nowMs: number, shownToday: number, coldStartShown: boolean,
    blockers: string[], imageLoaded: boolean): HomeJsonObject {
    const page: HomeJsonObject = {};
    page['page_key'] = 'home';
    page['version'] = 1;
    page['sections'] = [popupJson];
    const decoded: HomeDecoded = HomeJson.decodePage(page, 'harmony', '0');
    const card: HomeCard | null = decoded.popup;
    const out: HomeJsonObject = {};
    if (card === null || card.type !== HomeCardType.POPUP) {
      out['decisionRaw'] = PopupDecision.SKIP;
      out['reasonRaw'] = 'invalid';
      out['countAfter'] = shownToday;
      return out;
    }
    const d: PopupDecision = PopupPolicy.decideCard(card, level, nowMs, shownToday, coldStartShown, blockers,
      imageLoaded);
    out['decisionRaw'] = d.decision;
    out['reasonRaw'] = d.reason;
    out['countAfter'] = d.countAfter;
    return out;
  }
}

/** 动作解码的向量接线输出（只含 route / params）。 */
export class HomeActionJson {
  static of(json: HomeJsonObject | null): HomeJsonObject | null {
    const action: HomeAction | null = HomeJson.action(json);
    if (action === null) {
      return null;
    }
    const out: HomeJsonObject = {};
    out['route'] = action.route;
    if (action.hasParams) {
      const params: HomeJsonObject = {};
      for (const k of Object.keys(action.params)) {
        params[k] = action.params[k];
      }
      out['params'] = params;
    }
    return out;
  }
}

/** 曝光判定（G20，纯逻辑，不发埋点）：可见 ≥50% 且连续 ≥500 毫秒判一次；去重键 = 页面停留编号 + section id + 坑位。 */
export class ExposureTracker {
  static readonly MIN_RATIO: number = 0.5;
  static readonly MIN_MILLIS: number = 500;
  readonly sectionId: string;
  readonly slot: number;
  private stay: number = Number.NaN;
  private since: number | null = null;
  private fired: boolean = false;

  constructor(sectionId: string, slot: number) {
    this.sectionId = sectionId;
    this.slot = slot;
  }

  /** stay：页面停留编号（切 Tab 或离开再回来是新的停留）。返回这一刻是否判为一次曝光。 */
  onVisible(tMs: number, ratio: number, stay: number): boolean {
    if (stay !== this.stay) {
      this.stay = stay;
      this.since = null;
      this.fired = false;
    }
    if (this.fired) {
      return false;
    }
    if (ratio < ExposureTracker.MIN_RATIO) {
      this.since = null;
      return false;
    }
    if (this.since === null) {
      this.since = tMs;
    }
    if (tMs - (this.since as number) >= ExposureTracker.MIN_MILLIS) {
      this.fired = true;
      return true;
    }
    return false;
  }
}

/** sdui_card_error 同一进程内按（page_version、section id、reason）只发一次。 */
export class CardErrorDedupe {
  private readonly sent: Set<string> = new Set<string>();

  shouldSend(pageVersion: number, sectionId: string, reason: string): boolean {
    const key: string = pageVersion + '\u0000' + sectionId + '\u0000' + reason;
    if (this.sent.has(key)) {
      return false;
    }
    this.sent.add(key);
    return true;
  }
}

/** 三级兜底的来源（G16）。 */
export class HomeShowing {
  static readonly NONE: string = 'none';
  static readonly NETWORK: string = 'network';
  static readonly LKG: string = 'lkg';
  static readonly DEFAULT: string = 'default';
  static readonly LOAD_FAILED: string = 'load_failed';
}

/** 状态机的一步输出。 */
export class HomeSourceStep {
  readonly actions: string[];
  readonly showing: string;
  /** disable_refresh 时的禁用毫秒；其余为 null。 */
  readonly refreshDisabledMs: number | null;
  /** toast_error 的文案键（没有为 null）。 */
  readonly toastKey: string | null;

  constructor(actions: string[], showing: string, refreshDisabledMs: number | null, toastKey: string | null) {
    this.actions = actions;
    this.showing = showing;
    this.refreshDisabledMs = refreshDisabledMs;
    this.toastKey = toastKey;
  }

  has(action: string): boolean {
    return this.actions.indexOf(action) >= 0;
  }
}

/**
 * 三级兜底状态机（TECH-10、F-HOME-04、G16 ①–⑧）：网络最新 → 本机 LKG → 包内默认。纯逻辑：输入事件，输出动作。
 * 动作：show_network / show_lkg / show_default / write_lkg / toast_error:<键> / show_load_failed / disable_refresh / force_update /
 * drop_stale / none。每个控制器实例一份（构造时固定身份；identity_changed 之后旧结果一律 drop_stale，直到新的 cold_start）。
 */
export class HomeSourcePolicy {
  static readonly SHOW_NETWORK: string = 'show_network';
  static readonly SHOW_LKG: string = 'show_lkg';
  static readonly SHOW_DEFAULT: string = 'show_default';
  static readonly WRITE_LKG: string = 'write_lkg';
  static readonly SHOW_LOAD_FAILED: string = 'show_load_failed';
  static readonly DISABLE_REFRESH: string = 'disable_refresh';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly DROP_STALE: string = 'drop_stale';
  static readonly NONE: string = 'none';
  static readonly TOAST_PREFIX: string = 'toast_error:';
  /** 无 LKG 时等网络的上限（03 §6.2 第 4 步）。 */
  static readonly WAIT_MS: number = 1500;

  private showing: string = HomeShowing.NONE;
  private interacted: boolean = false;
  private replaced: boolean = false;
  private pullPending: boolean = false;
  private timerFired: boolean = false;
  private dead: boolean = false;

  get current(): string {
    return this.showing;
  }

  get pulling(): boolean {
    return this.pullPending;
  }

  step(event: string, arg: HomeJsonObject): HomeSourceStep {
    switch (event) {
      case 'cold_start':
        return this.coldStart(arg['hasLkg'] === true);
      case 'lkg_loaded':
        return this.lkgLoaded(arg['valid'] === true);
      case 'timer_1500':
        return this.timer();
      case 'network_ok':
        if (arg['valid'] !== true) {
          return this.networkFail('invalid_page', null);
        }
        return this.networkOk();
      case 'network_fail':
        return this.networkFail(HomeJsonRead.stringOf(arg['kind']) ?? 'offline', arg['retryAfter']);
      case 'default_loaded':
        return this.defaultLoaded(arg['valid'] === true);
      case 'user_interacted':
        this.interacted = true;
        return this.out([]);
      case 'pull_refresh':
        if (!this.dead) {
          this.pullPending = true;
        }
        return this.out([]);
      case 'identity_changed':
        this.dead = true;
        this.pullPending = false;
        this.showing = HomeShowing.NONE;
        return this.out([]);
      default:
        return this.out([]);
    }
  }

  /** 向量接线：on(event, arg) → {actionsRaw, showing, refreshDisabledMs?}。 */
  on(event: string, arg: HomeJsonObject): HomeJsonObject {
    const s: HomeSourceStep = this.step(event, arg);
    const out: HomeJsonObject = {};
    out['actionsRaw'] = s.actions.slice();
    out['showing'] = s.showing;
    if (s.refreshDisabledMs !== null) {
      out['refreshDisabledMs'] = s.refreshDisabledMs;
    }
    return out;
  }

  private out(actions: string[], disabled: number | null = null, toast: string | null = null): HomeSourceStep {
    return new HomeSourceStep(actions.length === 0 ? [HomeSourcePolicy.NONE] : actions, this.showing, disabled, toast);
  }

  private coldStart(hasLkg: boolean): HomeSourceStep {
    this.dead = false;
    this.interacted = false;
    this.replaced = false;
    this.pullPending = false;
    this.timerFired = false;
    if (hasLkg) {
      this.showing = HomeShowing.LKG;
      return this.out([HomeSourcePolicy.SHOW_LKG]);
    }
    this.showing = HomeShowing.NONE;
    return this.out([]);
  }

  private lkgLoaded(valid: boolean): HomeSourceStep {
    if (this.dead || valid || this.showing !== HomeShowing.LKG) {
      return this.out([]);
    }
    // LKG 损坏 → 当作无 LKG（等网络；1.5 秒已过就直接显示包内默认）。
    this.showing = HomeShowing.NONE;
    if (this.timerFired) {
      this.showing = HomeShowing.DEFAULT;
      return this.out([HomeSourcePolicy.SHOW_DEFAULT]);
    }
    return this.out([]);
  }

  private timer(): HomeSourceStep {
    this.timerFired = true;
    if (this.dead || this.showing !== HomeShowing.NONE) {
      return this.out([]);
    }
    this.showing = HomeShowing.DEFAULT;
    return this.out([HomeSourcePolicy.SHOW_DEFAULT]);
  }

  private defaultLoaded(valid: boolean): HomeSourceStep {
    if (this.dead || valid) {
      return this.out([]);
    }
    if (this.showing === HomeShowing.DEFAULT || this.showing === HomeShowing.NONE) {
      this.showing = HomeShowing.LOAD_FAILED;
      return this.out([HomeSourcePolicy.SHOW_LOAD_FAILED]);
    }
    return this.out([]);
  }

  private networkOk(): HomeSourceStep {
    if (this.dead) {
      return this.out([HomeSourcePolicy.DROP_STALE]);
    }
    if (this.pullPending) {
      this.pullPending = false;
      this.showing = HomeShowing.NETWORK;
      return this.out([HomeSourcePolicy.SHOW_NETWORK, HomeSourcePolicy.WRITE_LKG]);
    }
    const s: string = this.showing;
    const replaceDefault: boolean = s === HomeShowing.DEFAULT && !this.interacted && !this.replaced;
    if (s === HomeShowing.NONE || s === HomeShowing.LOAD_FAILED || replaceDefault) {
      this.replaced = this.replaced || replaceDefault;
      this.showing = HomeShowing.NETWORK;
      return this.out([HomeSourcePolicy.SHOW_NETWORK, HomeSourcePolicy.WRITE_LKG]);
    }
    // 有 LKG / 已显示过网络版 / 包内默认已交互：只写 LKG，下次冷启动或下拉时替换（G16 ③④）。
    return this.out([HomeSourcePolicy.WRITE_LKG]);
  }

  private networkFail(kind: string, retryAfter: HomeJsonValue | undefined): HomeSourceStep {
    if (this.dead) {
      return this.out([HomeSourcePolicy.DROP_STALE]);
    }
    const pulling: boolean = this.pullPending;
    this.pullPending = false;
    if (kind === 'code_10405') {
      return this.out([HomeSourcePolicy.FORCE_UPDATE]);
    }
    if (kind === 'http_42901') {
      const ms: number = HomeSourcePolicy.retryAfterMillis(retryAfter);
      if (pulling) {
        const key: string = 'error.42901';
        return this.out([HomeSourcePolicy.TOAST_PREFIX + key, HomeSourcePolicy.DISABLE_REFRESH], ms, key);
      }
      // 冷启动的后台拉取被限流：静默（不提示），继续用当前显示的那一级；下拉同样按 Retry-After 禁用。
      return this.out([HomeSourcePolicy.DISABLE_REFRESH], ms);
    }
    if (!pulling) {
      // 后台拉取失败不弹提示（有内容在显示，G16）；没有内容时等 1.5 秒计时显示包内默认。
      return this.out([]);
    }
    // 下拉失败：保留当前屏，提示一次（5xxxx 带 trace6，由统一错误消息函数追加；其余同样按通用失败）。
    const key: string = 'error.50001';
    return this.out([HomeSourcePolicy.TOAST_PREFIX + key], null, key);
  }

  /** Retry-After 秒数 → 毫秒；缺省或非法按 5 秒（ErrorActionMapper 同一口径）。 */
  static retryAfterMillis(raw: HomeJsonValue | undefined): number {
    const def: number = ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
    if (typeof raw === 'number') {
      return Number.isSafeInteger(raw as number) && (raw as number) > 0 ? (raw as number) * 1000 : def;
    }
    if (typeof raw !== 'string' || !/^\d{1,6}$/.test(raw as string)) {
      return def;
    }
    const n: number = Number.parseInt(raw as string, 10);
    return n > 0 ? n * 1000 : def;
  }
}
