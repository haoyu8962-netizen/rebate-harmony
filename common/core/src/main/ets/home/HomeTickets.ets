// APP-11 首页回调票据（鸿蒙第 1 轮评审 R1-01/02/03/05/13/14/15/16，跨端共性第 1–7、14 条）：
// 所有页面回调（卡片点击、公告关闭、弹窗图片完成 / 失败、弹窗显示 / 关闭、下拉刷新、【重试】、信息流翻页）在渲染时拿到一张不可变票据，
// 执行时只把票据交回执行层比较；不在执行时重新读「当前快照 / 当前控制器」，也不转交给新控制器（APP-09 第 63、65 条）。
// 本文件只有纯值与纯函数（不依赖控制器），界面与单测共用。
import { DefaultTexts } from 'generated';
import { ApiOutcome, ApiResult } from '../network/ApiClient';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { trace6Of, withTrace6 } from '../search/SearchController';
import { HomeAction, HomeBuiltinIcon, HomeNoticeItem } from './HomeModels';
import { HomeLevel, NoticeFilter } from './HomePolicies';

/** 一次渲染的归属：控制器编号 + 内容换代编号（换一份页面配置加一）。 */
export class HomeRenderTicket {
  readonly owner: number;
  readonly render: number;

  constructor(owner: number, render: number) {
    this.owner = owner;
    this.render = render;
  }

  /** 界面用作行键（票据变了整行重建，旧行的回调随旧行销毁）。 */
  get key(): string {
    return this.owner + ':' + this.render;
  }
}

/** 卡片 / 条目点击：渲染时的归属 + section id + 坑位 + 动作（RouteTarget 原样）。 */
export class HomeTap {
  readonly owner: number;
  readonly render: number;
  readonly sectionId: string;
  readonly slot: number;
  readonly action: HomeAction;

  constructor(owner: number, render: number, sectionId: string, slot: number, action: HomeAction) {
    this.owner = owner;
    this.render = render;
    this.sectionId = sectionId;
    this.slot = slot;
    this.action = action;
  }
}

/**
 * 公告关闭（R1-01，G10、G11）：三元组 + 渲染时的环境、本机记录清理世代与「是否允许落盘」（基本模式、HomePreview 为 false）。
 * 执行时只在环境与清理世代都没变时落盘；同一环境内换账号仍记（设备级记录，G11）。
 */
export class HomeNoticeCloseTicket {
  readonly owner: number;
  readonly render: number;
  readonly env: string;
  readonly localGeneration: number;
  readonly persist: boolean;
  readonly sectionId: string;
  readonly itemId: string;
  readonly contentVersion: number;

  constructor(owner: number, render: number, env: string, localGeneration: number, persist: boolean, sectionId: string,
    itemId: string, contentVersion: number) {
    this.owner = owner;
    this.render = render;
    this.env = env;
    this.localGeneration = localGeneration;
    this.persist = persist;
    this.sectionId = sectionId;
    this.itemId = itemId;
    this.contentVersion = contentVersion;
  }

  get key(): string {
    return NoticeFilter.closeKey(this.sectionId, this.itemId, this.contentVersion);
  }
}

/** 公告条的一行：条目 + 点击票据（有 target 才有）+ 关闭票据（closable 才有）。 */
export class HomeNoticeRow {
  readonly item: HomeNoticeItem;
  readonly tap: HomeTap | null;
  readonly close: HomeNoticeCloseTicket | null;

  constructor(item: HomeNoticeItem, tap: HomeTap | null, close: HomeNoticeCloseTicket | null) {
    this.item = item;
    this.tap = tap;
    this.close = close;
  }
}

/** 商品项一行：ProductCard JSON 原样 + 点击票据（缺 platform / product_key 时为 null，不可点）。 */
export class HomeProductRow {
  readonly product: Record<string, Object>;
  readonly tap: HomeTap | null;
  readonly slot: number;

  constructor(product: Record<string, Object>, tap: HomeTap | null, slot: number) {
    this.product = product;
    this.tap = tap;
    this.slot = slot;
  }
}

/** 信息流翻页与【重试】：渲染时的归属 + section id。 */
export class HomeSectionTicket {
  readonly owner: number;
  readonly render: number;
  readonly sectionId: string;

  constructor(owner: number, render: number, sectionId: string) {
    this.owner = owner;
    this.render = render;
    this.sectionId = sectionId;
  }
}

/** 弹窗图片预加载（R1-02/03）：控制器、内容换代、候选编号、section id 与图片地址都要一致，结果才算数。 */
export class HomePopupImageTicket {
  readonly owner: number;
  readonly render: number;
  readonly candidate: number;
  readonly sectionId: string;
  readonly image: string;

  constructor(owner: number, render: number, candidate: number, sectionId: string, image: string) {
    this.owner = owner;
    this.render = render;
    this.candidate = candidate;
    this.sectionId = sectionId;
    this.image = image;
  }

  get key(): string {
    return this.owner + ':' + this.render + ':' + this.candidate + ':' + this.sectionId;
  }
}

/** 正在显示的弹窗（显示计数、关闭、点图片）：控制器 + 弹窗编号 + section id；图片动作的点击票据。 */
export class HomePopupTicket {
  readonly owner: number;
  readonly popupSerial: number;
  readonly sectionId: string;
  readonly image: string;
  readonly tap: HomeTap | null;

  constructor(owner: number, popupSerial: number, sectionId: string, image: string, tap: HomeTap | null) {
    this.owner = owner;
    this.popupSerial = popupSerial;
    this.sectionId = sectionId;
    this.image = image;
    this.tap = tap;
  }

  get key(): string {
    return this.owner + ':' + this.popupSerial;
  }
}

/**
 * 首页固定区（R1-08）：基本模式提示与「无搜索固定区」只看真实隐私状态；只读（强更检查未知）不隐藏搜索与剪贴板区。
 * HM-07v（APP-11v）：guestValue = 游客价值卡（HomeGuest-v3）：基本模式不论身份都显示（H-V07，同 HomeGuest-v3 底稿）；
 * 否则只对游客显示；草稿预览没有。guest 由 AppHome 每次状态同步按身份档写入（登录后同步即隐藏）。
 */
export class HomeFixedArea {
  readonly basicNotice: boolean;
  readonly search: boolean;
  readonly clipboard: boolean;
  readonly guestValue: boolean;

  constructor(basicNotice: boolean, search: boolean, clipboard: boolean, guestValue: boolean = false) {
    this.basicNotice = basicNotice;
    this.search = search;
    this.clipboard = clipboard;
    this.guestValue = guestValue;
  }

  /** basicMode：隐私结论是基本模式；preview：草稿预览（没有固定区）；guest：当前身份是游客（缺省 false：漏传不显示价值卡）。 */
  static of(basicMode: boolean, preview: boolean, guest: boolean = false): HomeFixedArea {
    if (preview) {
      return new HomeFixedArea(false, false, false, false);
    }
    return basicMode ? new HomeFixedArea(true, false, false, true) : new HomeFixedArea(false, true, true, guest);
  }

  /** 身份档是不是游客（HomeIdentity.level）：只有 GUEST 为真；MEMBER、BASIC、未知都为假。 */
  static isGuest(level: string): boolean {
    return level === HomeLevel.GUEST;
  }
}

/**
 * 首页列表里的原生行（HM-07v H1 / H-V02）：搜索行固定在列表外，不在这里。顺序即显示顺序：
 * 基本模式提示 → 剪贴板提示条（邀请 / 分享）→ 游客价值卡 → 粘贴卡（含内联结果与识别卡半屏宿主）。
 * 键在 native: 命名空间；SDUI 卡片行键（cardKey）以 card: 开头，section id 取任何值都不会落进 native:（共性 24）。
 */
export class HomeNativeRows {
  static readonly BASIC: string = 'native:basic';
  static readonly PROMPT: string = 'native:prompt';
  static readonly GUEST_VALUE: string = 'native:guest_value';
  static readonly PASTE: string = 'native:paste';

  static of(fixed: HomeFixedArea): string[] {
    const out: string[] = [];
    if (fixed.basicNotice) {
      out.push(HomeNativeRows.BASIC);
    }
    if (fixed.clipboard) {
      out.push(HomeNativeRows.PROMPT);
    }
    if (fixed.guestValue) {
      out.push(HomeNativeRows.GUEST_VALUE);
    }
    if (fixed.clipboard) {
      out.push(HomeNativeRows.PASTE);
    }
    return out;
  }

  /**
   * SDUI 卡片行键：渲染票据 + section id + 数据版本（票据或数据换代都换键，整行重建，R1-02）。section id 用长度前缀写入，
   * 任何字符（含冒号）都不会与相邻字段拼出同一个键。
   */
  static cardKey(ticketKey: string, sectionId: string, dataKey: string): string {
    return 'card:' + ticketKey + '|' + sectionId.length + ':' + sectionId + '|' + dataKey;
  }
}

/**
 * 金刚区一格的图怎么画（G-V01 / H8）：
 * - builtin:platform.<键>：包内有官方平台图（F-X-05a PlatformIconSource，键 taobao / jd / pdd）→ PLATFORM_IMAGE；
 *   暂缺（天猫等）或键不对（文件名 pinduoduo 不是标识键）→ PLATFORM_TEXT（图块里写平台名，不借别家的图）；
 * - builtin:<已知类目 / 指南> → GLYPH（凑狸自有线性图标，G-V08）；其他 builtin: → PLACEHOLDER（不当网络地址去加载）；
 * - 其余当下发图 → REMOTE；加载失败 → PLACEHOLDER（只换占位底，格子与格名保留）。
 */
export class HomeIconArt {
  static readonly REMOTE: string = 'remote';
  static readonly PLATFORM_IMAGE: string = 'platform_image';
  static readonly PLATFORM_TEXT: string = 'platform_text';
  static readonly GLYPH: string = 'glyph';
  static readonly PLACEHOLDER: string = 'placeholder';
  private static readonly PLATFORM_PREFIX: string = 'builtin:platform.';

  static platformOf(icon: string): string | null {
    if (!icon.startsWith(HomeIconArt.PLATFORM_PREFIX)) {
      return null;
    }
    const key: string = icon.substring(HomeIconArt.PLATFORM_PREFIX.length);
    return key.length > 0 ? key : null;
  }

  static kind(icon: string, remoteFailed: boolean, hasBuiltin: (platform: string) => boolean): string {
    const platform: string | null = HomeIconArt.platformOf(icon);
    if (platform !== null) {
      return hasBuiltin(platform) ? HomeIconArt.PLATFORM_IMAGE : HomeIconArt.PLATFORM_TEXT;
    }
    if (icon.startsWith(HomeBuiltinIcon.PREFIX)) {
      return HomeBuiltinIcon.nameOf(icon) !== null ? HomeIconArt.GLYPH : HomeIconArt.PLACEHOLDER;
    }
    if (icon.trim().length === 0 || remoteFailed) {
      return HomeIconArt.PLACEHOLDER;
    }
    return HomeIconArt.REMOTE;
  }
}

/** 公告条展示方式（R1-16）：scroll 且多于一条才滚动；读屏开启或首页不在前台时不自动滚动（WCAG 2.2.2）。 */
export class HomeNoticeDisplay {
  static readonly SCROLL: string = 'scroll';
  static readonly STATIC: string = 'static';
  readonly kind: string;
  readonly autoplay: boolean;

  constructor(kind: string, autoplay: boolean) {
    this.kind = kind;
    this.autoplay = autoplay;
  }

  static of(mode: string, count: number, screenReader: boolean, active: boolean): HomeNoticeDisplay {
    if (mode === HomeNoticeDisplay.SCROLL && count > 1) {
      return new HomeNoticeDisplay(HomeNoticeDisplay.SCROLL, !screenReader && active);
    }
    return new HomeNoticeDisplay(HomeNoticeDisplay.STATIC, false);
  }
}

/**
 * 首页与 HomePreview 的统一错误消息（R1-15，brief §0「trace6」，APP-06a 第 6、12 条）：
 * - 文案键：error.<code>[.<reason>] 字典有就用，保留真实错误码语义；5xxxx 未收录回落 error.50001；断网、超时用 error.50001；
 * - 5xxxx（含断网、超时回落的 50001）有 trace_id 时由 withTrace6 独立追加末 6 位（不依赖键里恰好有 {trace6} 占位）；
 *   没有 trace_id 时用不带编号的 fallback。
 */
export class HomeErrorText {
  static keyOf(result: ApiResult): string {
    if (result.outcome === ApiOutcome.NETWORK_ERROR) {
      return 'error.50001';
    }
    const code: number = result.code;
    if (ErrorActionMapper.isServerError(code)) {
      return DefaultTexts.text('error.' + code) !== undefined ? 'error.' + code : 'error.50001';
    }
    return ErrorActionMapper.textKey(code, null) ?? 'error.50001';
  }

  /** key 的文案 + trace6（只给 5xxxx 追加）。 */
  static message(key: string, traceId: string): string {
    const code: number = Number.parseInt(key.substring('error.'.length), 10);
    const server: boolean = Number.isFinite(code) && ErrorActionMapper.isServerError(code);
    const raw: string = DefaultTexts.text(key) ?? DefaultTexts.text('error.50001') ?? '';
    const plain: string = DefaultTexts.fallback(key) ?? raw.split('（{trace6}）').join('').split('{trace6}').join('');
    if (!server) {
      return plain;
    }
    // 不依赖键里的 {trace6} 占位：取不带编号的正文，再由 withTrace6 独立追加「（末六位）」。
    return trace6Of(traceId).length === 0 ? plain : withTrace6(plain, traceId);
  }

  static of(result: ApiResult): string {
    return HomeErrorText.message(HomeErrorText.keyOf(result), result.traceId);
  }
}
