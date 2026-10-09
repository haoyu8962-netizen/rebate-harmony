// 剪贴板识别的纯逻辑（APP-07；brief §2.1–§2.3、§2.5–§2.7；BR-ID-16、BR-INV-04、OPS-06；规则空白 G02–G14、CLIP-18…24）。
// 三端同名：ClipboardRules、ClipboardText、InviteCodeExtractor、ClipboardSensitive、ClipboardReadPolicy、ClipboardClassifier、
// ClipboardWriteLedger、PromptHistory、ParseResultAction、ManualPasteAction、InviteConfirmAction（向量 specs/clipboard-vectors.json）。
// 这里不读系统剪贴板、不落盘、不打日志：原文只在调用方的内存里经过这些函数，结果只含抽出的片段与 hash。
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { RequestSigner } from '../network/RequestSigner';
import { Sha256 } from '../clientcore/Sha256';

/** 字符串值（JSON 里的 string）；不是为 null。 */
function textOf(value: Object | null | undefined): string | null {
  return typeof value === 'string' ? value as string : null;
}

/** 布尔值（JSON 里的 boolean）；不是为 null。 */
function flagOf(value: Object | null | undefined): boolean | null {
  return typeof value === 'boolean' ? value as boolean : null;
}

/** JSON 对象（不是数组）；不是为 null。 */
function objectOf(value: Object | null | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, Object>;
}

/**
 * 本地过滤规则（F-CLIP-02、BR-INV-04 细则；规则空白 G02、G03、G14）。包内默认取原文数值：长度 10～500、排除不超过 20 位的纯数字或
 * 纯字母数字、排除词表为空；邀请触发前提为文本含 config.share_domains 任一域名的 /i/{code} 落地页，或含「邀请码」字样。
 * TODO(N-30) G02：config.clipboard 在契约里是 FreeForm，键名与类型没定，fromConfig 不按猜测的键名解析，一律用包内默认。
 */
export class ClipboardRules {
  static readonly DEFAULT_MIN_LENGTH: number = 10;
  static readonly DEFAULT_MAX_LENGTH: number = 500;
  static readonly DEFAULT_PURE_ALNUM_MAX: number = 20;
  static readonly DEFAULT_MAX_LINKS: number = 3;
  static readonly INVITE_KEYWORD: string = '邀请码';

  readonly minLength: number;
  readonly maxLength: number;
  /** 不超过这个长度的纯数字 / 纯字母数字文本排除（F-CLIP-02）。 */
  readonly pureAlnumMaxLength: number;
  readonly excludedWords: string[];
  /** 邀请触发字样（BR-INV-04 细则「含『邀请码』字样」）。 */
  readonly inviteKeyword: string;
  /** 上传的链接最多几个（G04：按出现顺序）。 */
  readonly maxUploadLinks: number;

  constructor(minLength: number = ClipboardRules.DEFAULT_MIN_LENGTH,
    maxLength: number = ClipboardRules.DEFAULT_MAX_LENGTH,
    pureAlnumMaxLength: number = ClipboardRules.DEFAULT_PURE_ALNUM_MAX, excludedWords: string[] = [],
    inviteKeyword: string = ClipboardRules.INVITE_KEYWORD, maxUploadLinks: number = ClipboardRules.DEFAULT_MAX_LINKS) {
    this.minLength = minLength;
    this.maxLength = maxLength;
    this.pureAlnumMaxLength = pureAlnumMaxLength;
    this.excludedWords = excludedWords;
    this.inviteKeyword = inviteKeyword;
    this.maxUploadLinks = maxUploadLinks;
  }

  static readonly defaults: ClipboardRules = new ClipboardRules();

  /**
   * 下发的 config.clipboard（FreeForm）→ 规则。TODO(N-30) G02：结构未定，任何下发值都认不出，整体忽略、用包内默认（不按猜测的
   * 键名解析）。契约定下键名后在这里解析，认不出的结构仍整体回落。
   */
  static fromConfig(_raw: Object | null | undefined): ClipboardRules {
    return ClipboardRules.defaults;
  }
}

/** 文本片段的抽取（G04、BR-TEXT-14 的 30132 预填规则）：只在内存里做，原文不落盘、不进日志。 */
export class ClipboardText {
  /** http(s) 链接：只取 ASCII URL 字符，遇到空白、全角与中文标点即止（G03、G04）。 */
  private static readonly LINK: RegExp = new RegExp('https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&\'()*+,;=%]+', 'gi');
  private static readonly TITLE: RegExp = new RegExp('「([^「」]+)」');

  static links(text: string): string[] {
    const out: string[] = [];
    const pattern: RegExp = new RegExp(ClipboardText.LINK.source, 'gi');
    let match: RegExpExecArray | null = pattern.exec(text);
    while (match !== null) {
      out.push(match[0]);
      match = pattern.exec(text);
    }
    return out;
  }

  /** 「」内的第一段文字（去掉首尾空白）；没有为 null。 */
  static quotedTitle(text: string): string | null {
    const match: RegExpExecArray | null = ClipboardText.TITLE.exec(text);
    if (match === null) {
      return null;
    }
    const title: string = match[1].trim();
    return title.length > 0 ? title : null;
  }

  /** 30132【用商品名搜索】的预填（BR-TEXT-14：「」内或首行商品名，提取不到留空）。 */
  static searchPrefill(text: string | null | undefined): string | null {
    if (text === null || text === undefined || text.trim().length === 0) {
      return null;
    }
    const title: string | null = ClipboardText.quotedTitle(text);
    if (title !== null) {
      return title;
    }
    const lines: string[] = text.split('\n');
    for (const line of lines) {
      const trimmed: string = line.trim();
      if (trimmed.length > 0) {
        return trimmed;
      }
    }
    return null;
  }

  /** 上传内容（G04）：链接（最多 maxLinks 个，按出现顺序）加「」内的标题，换行连接；原文其余部分不上传。 */
  static uploadText(links: string[], text: string, maxLinks: number): string {
    const parts: string[] = links.slice(0, maxLinks);
    const title: string | null = ClipboardText.quotedTitle(text);
    if (title !== null) {
      parts.push(title);
    }
    return parts.join('\n');
  }

  /** NFKC 规范化（全角 → 半角等，BR-INV-04 细则）。 */
  static nfkc(text: string): string {
    return text.normalize('NFKC');
  }

  /** 码点个数（长度规则按字符算，代理对算一个）。 */
  static codePoints(text: string): number {
    let count: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        const next: number = text.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          i++;
        }
      }
      count++;
    }
    return count;
  }

  /** 本机记录用的 hash（G08：原文 UTF-8 字节的 SHA-256，小写十六进制）。 */
  static sha256(text: string): string {
    return RequestSigner.hex(Sha256.digest(RequestSigner.utf8(text)));
  }
}

/**
 * 邀请码抽取（BR-INV-04 细则）：NFKC 后转大写，按 (?<![0-9A-Z])[2-9A-HJ-NP-Z]{6}(?![0-9A-Z]) 取第一个匹配；不判断触发前提。
 * 逐位扫描实现前后边界（不依赖后行断言）。
 */
export class InviteCodeExtractor {
  private static readonly ALPHABET: RegExp = /^[2-9A-HJ-NP-Z]{6}$/;
  private static readonly BOUNDARY: RegExp = /^[0-9A-Z]$/;

  static extract(text: string): string | null {
    const upper: string = ClipboardText.nfkc(text).toUpperCase();
    for (let i: number = 0; i + 6 <= upper.length; i++) {
      const candidate: string = upper.substring(i, i + 6);
      if (!InviteCodeExtractor.ALPHABET.test(candidate)) {
        continue;
      }
      const before: string = i > 0 ? upper.charAt(i - 1) : '';
      const after: string = i + 6 < upper.length ? upper.charAt(i + 6) : '';
      if (InviteCodeExtractor.BOUNDARY.test(before) || InviteCodeExtractor.BOUNDARY.test(after)) {
        continue;
      }
      return candidate;
    }
    return null;
  }
}

/**
 * 敏感清单（BR-ID-16 细则「敏感页面不识别」；规则空白 G12）：这些路由或浮层在前台时不识别、不放 PasteButton 读取，离开后也不补做。
 * 集中放这一处，Router（当前路由）与浮层（当前浮层）都按它判断。
 */
export class ClipboardSensitive {
  static readonly ROUTES: string[] = ['Login', 'BindPhone', 'RealName', 'PayoutAccount', 'Withdraw', 'LaborAgreement',
    'DeleteAccount', 'FindOrder', 'ForceUpdate'];

  static readonly OVERLAY_NONE: string = 'none';
  static readonly OVERLAY_STEP_UP: string = 'step_up';
  static readonly OVERLAY_AUTH_SHEET: string = 'auth_sheet';
  static readonly OVERLAY_OAUTH: string = 'oauth_in_progress';
  static readonly OVERLAY_AUTH_JUMP: string = 'auth_jump';
  static readonly OVERLAY_PRIVACY_FIRST_LAUNCH: string = 'privacy_first_launch';
  static readonly OVERLAY_FORCE_UPDATE: string = 'force_update';

  /** 二次验证面板、AuthSheet、第三方登录或授权进行中（含 auth_jump 执行中）、首启隐私弹窗、强更（G12）。 */
  static readonly OVERLAYS: string[] = [ClipboardSensitive.OVERLAY_STEP_UP, ClipboardSensitive.OVERLAY_AUTH_SHEET,
    ClipboardSensitive.OVERLAY_OAUTH, ClipboardSensitive.OVERLAY_AUTH_JUMP, ClipboardSensitive.OVERLAY_PRIVACY_FIRST_LAUNCH,
    ClipboardSensitive.OVERLAY_FORCE_UPDATE];

  static sensitiveRoute(route: string | null): boolean {
    return route !== null && ClipboardSensitive.ROUTES.indexOf(route) >= 0;
  }

  static sensitiveOverlay(overlay: string | null): boolean {
    return overlay !== null && ClipboardSensitive.OVERLAYS.indexOf(overlay) >= 0;
  }

  static sensitive(route: string | null, overlay: string | null): boolean {
    return ClipboardSensitive.sensitiveRoute(route) || ClipboardSensitive.sensitiveOverlay(overlay);
  }
}

/** 读取判定结果：actionRaw read / detect_patterns / show_prompt / paste_only / skip。 */
export class ClipboardReadDecision {
  readonly actionRaw: string;
  readonly reasonRaw: string | null;

  constructor(actionRaw: string, reasonRaw: string | null = null) {
    this.actionRaw = actionRaw;
    this.reasonRaw = reasonRaw;
  }
}

/**
 * 读取判定（brief §2.1、§3；BR-ID-16、CAP-X-02；规则空白 G05、G06、G12、G13）。顺序：隐私（基本模式 / 隐私政策版本过期）→ 敏感路由与
 * 浮层 → 鸿蒙只给 PasteButton（paste_only，不读、也不探测）→ 触发事件 → 本次前台已读 → 配置开关 → 网页抑制 → Android 设备级开关、窗口
 * 焦点 → iOS changeCount 与 detectPatterns。state 的键与向量 readPolicy.state 同名。
 */
export class ClipboardReadPolicy {
  static readonly PLATFORM_IOS: string = 'ios';
  static readonly PLATFORM_ANDROID: string = 'android';
  static readonly PLATFORM_HARMONY: string = 'harmony';

  static readonly CONSENT_AGREED: string = 'agreed';
  static readonly CONSENT_BASIC: string = 'basic';
  static readonly CONSENT_OUTDATED: string = 'outdated';

  static readonly EVENT_COLD_START: string = 'cold_start_foreground';
  static readonly EVENT_FOREGROUND: string = 'foreground_after_background';
  static readonly EVENT_REFOCUS: string = 'refocus_without_background';
  static readonly EVENT_NAVIGATION: string = 'in_app_navigation';
  static readonly EVENT_WINDOW_FOCUS: string = 'window_focus';

  static readonly ACTION_READ: string = 'read';
  static readonly ACTION_DETECT: string = 'detect_patterns';
  static readonly ACTION_SHOW_PROMPT: string = 'show_prompt';
  static readonly ACTION_PASTE_ONLY: string = 'paste_only';
  static readonly ACTION_SKIP: string = 'skip';

  static readonly REASON_BASIC_MODE: string = 'basic_mode';
  static readonly REASON_PRIVACY_OUTDATED: string = 'privacy_outdated';
  static readonly REASON_SENSITIVE: string = 'sensitive';
  static readonly REASON_HARMONY_PASTE_ONLY: string = 'harmony_paste_only';
  static readonly REASON_NOT_FOREGROUND: string = 'not_foreground';
  static readonly REASON_ALREADY_READ: string = 'already_read';
  static readonly REASON_CONFIG_OFF: string = 'config_off';
  static readonly REASON_WEB_SUPPRESSED: string = 'web_suppressed';
  static readonly REASON_SWITCH_OFF: string = 'switch_off';
  static readonly REASON_NO_FOCUS: string = 'no_focus';
  static readonly REASON_UNCHANGED: string = 'unchanged';
  static readonly REASON_NO_DETECT_HIT: string = 'no_detect_hit';

  private static skip(reason: string): ClipboardReadDecision {
    return new ClipboardReadDecision(ClipboardReadPolicy.ACTION_SKIP, reason);
  }

  static decide(platform: string, state: Record<string, Object>): ClipboardReadDecision {
    const consent: string = textOf(state['consent']) ?? ClipboardReadPolicy.CONSENT_OUTDATED;
    if (consent === ClipboardReadPolicy.CONSENT_BASIC) {
      return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_BASIC_MODE);
    }
    if (consent !== ClipboardReadPolicy.CONSENT_AGREED) {
      return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_PRIVACY_OUTDATED);
    }
    const overlay: string = textOf(state['overlay']) ?? ClipboardSensitive.OVERLAY_NONE;
    if (ClipboardSensitive.sensitive(textOf(state['route']), overlay)) {
      return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_SENSITIVE);
    }
    if (platform === ClipboardReadPolicy.PLATFORM_HARMONY) {
      // 鸿蒙只提供 PasteButton（BR-ID-16、CAP-X-02；不申请 READ_PASTEBOARD、不调 detectPatterns）
      return new ClipboardReadDecision(ClipboardReadPolicy.ACTION_PASTE_ONLY, ClipboardReadPolicy.REASON_HARMONY_PASTE_ONLY);
    }
    const event: string = textOf(state['event']) ?? '';
    const foreground: boolean = event === ClipboardReadPolicy.EVENT_COLD_START
      || event === ClipboardReadPolicy.EVENT_FOREGROUND
      || (platform === ClipboardReadPolicy.PLATFORM_ANDROID && event === ClipboardReadPolicy.EVENT_WINDOW_FOCUS);
    if (!foreground) {
      return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_NOT_FOREGROUND);
    }
    if (flagOf(state['readThisForeground']) === true) {
      return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_ALREADY_READ);
    }
    if (flagOf(state['configEnabled']) === false) {
      return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_CONFIG_OFF);
    }
    if (flagOf(state['webSuppressed']) === true) {
      return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_WEB_SUPPRESSED);
    }
    if (platform === ClipboardReadPolicy.PLATFORM_ANDROID) {
      if (flagOf(state['androidAutoSwitch']) === false) {
        return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_SWITCH_OFF);
      }
      if (flagOf(state['androidWindowFocused']) === false) {
        return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_NO_FOCUS);
      }
      return new ClipboardReadDecision(ClipboardReadPolicy.ACTION_READ);
    }
    if (platform === ClipboardReadPolicy.PLATFORM_IOS) {
      if (flagOf(state['iosChangeCountChanged']) === false) {
        return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_UNCHANGED);
      }
      const hit: boolean | null = flagOf(state['iosDetectHit']);
      if (hit === null) {
        return new ClipboardReadDecision(ClipboardReadPolicy.ACTION_DETECT);
      }
      return hit ? new ClipboardReadDecision(ClipboardReadPolicy.ACTION_SHOW_PROMPT)
        : ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_NO_DETECT_HIT);
    }
    return ClipboardReadPolicy.skip(ClipboardReadPolicy.REASON_NOT_FOREGROUND);
  }
}

/** 24 小时内提示过的一条记录（只有 hash 与时间，G08）。 */
export class ClipboardPromptStamp {
  readonly hash: string;
  readonly atMs: number;

  constructor(hash: string, atMs: number) {
    this.hash = hash;
    this.atMs = atMs;
  }
}

/**
 * 分类时的本机状态（纯逻辑 DTO，不是服务端字段）：selfWritten 为 App 自写内容的 hash（最近 10 条）；prompted 为出过提示条的 hash 与
 * 时间；inviteEligible 用户可以绑定上级（游客一律可以；已登录看 getMe，拿不到不可以）；selfInviteCode 本人邀请码；shareDomains 为
 * config.share_domains；hash 为原文 → hash（生产 ClipboardText.sha256，向量测试注入假 hash）。
 */
export class ClipboardContext {
  readonly selfWritten: string[];
  readonly prompted: ClipboardPromptStamp[];
  readonly inviteEligible: boolean;
  readonly selfInviteCode: string | null;
  readonly shareDomains: string[];
  readonly hash: (text: string) => string;

  constructor(selfWritten: string[], prompted: ClipboardPromptStamp[], inviteEligible: boolean,
    selfInviteCode: string | null | undefined, shareDomains: string[],
    hash: (text: string) => string = (text: string): string => ClipboardText.sha256(text)) {
    this.selfWritten = selfWritten;
    this.prompted = prompted;
    this.inviteEligible = inviteEligible;
    this.selfInviteCode = selfInviteCode ?? null;
    this.shareDomains = shareDomains;
    this.hash = hash;
  }
}

/** 分类结果：kindRaw product / invite / none；uploadText 只含本地抽出的片段（G04），原文不在结果里。 */
export class ClipboardClassification {
  readonly kindRaw: string;
  readonly reasonRaw: string | null;
  readonly inviteCode: string | null;
  readonly uploadText: string | null;
  /** 原文的 hash（出提示条时记入 PromptHistory）。 */
  readonly hash: string | null;

  constructor(kindRaw: string, reasonRaw: string | null, inviteCode: string | null, uploadText: string | null,
    hash: string | null) {
    this.kindRaw = kindRaw;
    this.reasonRaw = reasonRaw;
    this.inviteCode = inviteCode;
    this.uploadText = uploadText;
    this.hash = hash;
  }
}

/**
 * 本地分类（brief §2.2；BR-ID-16、BR-INV-04、OPS-06；规则空白 G03、G04、G08、G14）。顺序：
 * 1. App 自写的 hash → none（self_written）；
 * 2. 24 小时内（严格小于）提示过的同一 hash → none（prompted_recently）；
 * 3. 商品候选：通过长度、纯字母数字与排除词规则，并且含 http(s) 链接（G03；邀请落地页 /i/{code} 链接不算商品链接，CLIP-18）→ product；
 * 4. 否则邀请：抽到码、满足触发前提、不是本人码、用户可绑定 → invite（邀请不套用商品的长度规则，G14）；
 * 5. 否则 none：抽到了码给邀请的拒绝原因（no_trigger / self_code / not_eligible），抽不到给商品的拒绝原因。
 */
export class ClipboardClassifier {
  static readonly KIND_PRODUCT: string = 'product';
  static readonly KIND_INVITE: string = 'invite';
  static readonly KIND_NONE: string = 'none';

  static readonly REASON_SELF_WRITTEN: string = 'self_written';
  static readonly REASON_PROMPTED_RECENTLY: string = 'prompted_recently';
  static readonly REASON_TOO_SHORT: string = 'too_short';
  static readonly REASON_TOO_LONG: string = 'too_long';
  static readonly REASON_PURE_ALNUM: string = 'pure_alnum';
  static readonly REASON_EXCLUDED_WORD: string = 'excluded_word';
  static readonly REASON_NO_LINK: string = 'no_link';
  static readonly REASON_NO_TRIGGER: string = 'no_trigger';
  static readonly REASON_SELF_CODE: string = 'self_code';
  static readonly REASON_NOT_ELIGIBLE: string = 'not_eligible';

  /** 同一 hash 的提示间隔（G08：严格小于 24 小时不再提示）。 */
  static readonly PROMPT_WINDOW_MS: number = 24 * 60 * 60 * 1000;

  private static readonly PURE_ALNUM: RegExp = /^[A-Za-z0-9]+$/;
  private static readonly LANDING_PREFIX: string = '/i/';

  static classify(text: string, context: ClipboardContext, rules: ClipboardRules, nowMs: number): ClipboardClassification {
    const hash: string = context.hash(text);
    if (context.selfWritten.indexOf(hash) >= 0) {
      return ClipboardClassifier.none(ClipboardClassifier.REASON_SELF_WRITTEN, hash);
    }
    for (const stamp of context.prompted) {
      const age: number = nowMs - stamp.atMs;
      if (stamp.hash === hash && age >= 0 && age < ClipboardClassifier.PROMPT_WINDOW_MS) {
        return ClipboardClassifier.none(ClipboardClassifier.REASON_PROMPTED_RECENTLY, hash);
      }
    }
    const productLinks: string[] = ClipboardText.links(text)
      .filter((link: string): boolean => !ClipboardClassifier.inviteLanding(link, context.shareDomains));
    const productReason: string | null = ClipboardClassifier.productRejection(text, productLinks, rules);
    if (productReason === null) {
      return new ClipboardClassification(ClipboardClassifier.KIND_PRODUCT, null, null,
        ClipboardText.uploadText(productLinks, text, rules.maxUploadLinks), hash);
    }
    const code: string | null = InviteCodeExtractor.extract(text);
    if (code === null) {
      return ClipboardClassifier.none(productReason, hash);
    }
    let inviteReason: string | null = null;
    const self: string | null = context.selfInviteCode === null ? null
      : InviteCodeExtractor.extract(context.selfInviteCode);
    if (!ClipboardClassifier.inviteTriggered(text, context.shareDomains, rules)) {
      inviteReason = ClipboardClassifier.REASON_NO_TRIGGER;
    } else if (self !== null && self === code) {
      inviteReason = ClipboardClassifier.REASON_SELF_CODE;
    } else if (!context.inviteEligible) {
      inviteReason = ClipboardClassifier.REASON_NOT_ELIGIBLE;
    }
    if (inviteReason === null) {
      return new ClipboardClassification(ClipboardClassifier.KIND_INVITE, null, code, null, hash);
    }
    return ClipboardClassifier.none(inviteReason, hash);
  }

  /**
   * 商品候选的拒绝原因；null = 是商品候选。links 为已去掉邀请落地页的链接。自动识别与手动粘贴商品入口共用（共性第 22 条，F-CLIP-02）：
   * 过短、过长、短纯数字字母、含排除词、没有商品链接都不上传。
   */
  static productRejection(text: string, links: string[], rules: ClipboardRules): string | null {
    const length: number = ClipboardText.codePoints(text);
    if (length < rules.minLength) {
      return ClipboardClassifier.REASON_TOO_SHORT;
    }
    if (length > rules.maxLength) {
      return ClipboardClassifier.REASON_TOO_LONG;
    }
    if (length <= rules.pureAlnumMaxLength && ClipboardClassifier.PURE_ALNUM.test(text)) {
      return ClipboardClassifier.REASON_PURE_ALNUM;
    }
    for (const word of rules.excludedWords) {
      if (word.length > 0 && text.indexOf(word) >= 0) {
        return ClipboardClassifier.REASON_EXCLUDED_WORD;
      }
    }
    return links.length === 0 ? ClipboardClassifier.REASON_NO_LINK : null;
  }

  /** 邀请触发前提（BR-INV-04 细则）：含 share_domains 任一域名的 /i/{code} 落地页链接，或含「邀请码」字样。 */
  static inviteTriggered(text: string, shareDomains: string[], rules: ClipboardRules = ClipboardRules.defaults): boolean {
    if (ClipboardText.nfkc(text).indexOf(rules.inviteKeyword) >= 0) {
      return true;
    }
    return ClipboardText.links(text).some((link: string): boolean => ClipboardClassifier.inviteLanding(link, shareDomains));
  }

  /**
   * 是不是邀请落地页链接：主机名与 share_domains 之一完全相同（不区分大小写；不认子域、端口与 userinfo，CLIP-18 未定时从严），
   * 路径为 /i/{code}。
   */
  static inviteLanding(link: string, shareDomains: string[]): boolean {
    if (shareDomains.length === 0) {
      return false;
    }
    const schemeEnd: number = link.indexOf('://');
    if (schemeEnd < 0) {
      return false;
    }
    const rest: string = link.substring(schemeEnd + 3);
    let hostEnd: number = rest.length;
    for (const stop of ['/', '?', '#']) {
      const at: number = rest.indexOf(stop);
      if (at >= 0 && at < hostEnd) {
        hostEnd = at;
      }
    }
    const host: string = rest.substring(0, hostEnd).toLowerCase();
    const path: string = rest.substring(hostEnd);
    if (!path.startsWith(ClipboardClassifier.LANDING_PREFIX)) {
      return false;
    }
    let segment: string = path.substring(ClipboardClassifier.LANDING_PREFIX.length);
    for (const stop of ['/', '?', '#']) {
      const at: number = segment.indexOf(stop);
      if (at >= 0) {
        segment = segment.substring(0, at);
      }
    }
    const domainMatch: boolean = shareDomains.some((d: string): boolean => d.toLowerCase() === host);
    return domainMatch && InviteCodeExtractor.extract(segment) !== null;
  }

  private static none(reason: string, hash: string): ClipboardClassification {
    return new ClipboardClassification(ClipboardClassifier.KIND_NONE, reason, null, null, hash);
  }
}

/**
 * 本机 hash 记录的存储端口（只存 hash 与时间，不存原文；BR-ID-16「本机只存 hash」）。生产为 Preferences（entry 给），测试用内存。
 * 读失败或内容损坏按空处理：自写记录与提示记录丢了只会多出一次提示，不会少读或多上传。
 */
export interface ClipboardHashStore {
  read(key: string): string | null;

  /** 写入或删除（value 为 null）；确认落盘成功返回 true（共性第 14 条：撤回同意的删除要确认成功）。 */
  write(key: string, value: string | null): boolean;
}

/** 内存实现（测试与没有持久化时）。 */
export class MemoryClipboardHashStore implements ClipboardHashStore {
  private readonly values: Map<string, string> = new Map<string, string>();
  /** 测试：模拟落盘失败（写入不生效、返回 false）。 */
  failWrites: boolean = false;

  read(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  write(key: string, value: string | null): boolean {
    if (this.failWrites) {
      return false;
    }
    if (value === null) {
      this.values.delete(key);
    } else {
      this.values.set(key, value);
    }
    return true;
  }

  /** 测试核对：存储里所有值（只应有 hash 与时间）。 */
  dump(): string[] {
    const out: string[] = [];
    this.values.forEach((value: string, key: string): void => {
      out.push(key + '=' + value);
    });
    return out;
  }
}

/**
 * App 自己写入剪贴板的内容（F-CLIP-02；brief §2.3）：桥 clipboard.write、复制口令 copy_tpwd、各原生复制按钮都经同一个写入口
 * （ClipboardWriter），写入前先 record。保留最近 capacity 条 hash（重复写入同一内容移到最新），商品与邀请两种识别都排除。
 * 撤回同意时 clear。
 */
export class ClipboardWriteLedger {
  static readonly DEFAULT_CAPACITY: number = 10;
  private static readonly KEY: string = 'self_written';
  private static readonly SEPARATOR: string = ',';

  private readonly capacity: number;
  private readonly hash: (text: string) => string;
  private readonly store: ClipboardHashStore;

  constructor(capacity: number = ClipboardWriteLedger.DEFAULT_CAPACITY,
    hash: (text: string) => string = (text: string): string => ClipboardText.sha256(text),
    store: ClipboardHashStore = new MemoryClipboardHashStore()) {
    this.capacity = capacity;
    this.hash = hash;
    this.store = store;
  }

  /** 记下一条自写内容；确认落盘成功返回 true（共性第 23 条：失败时调用方不得继续写系统剪贴板）。 */
  record(text: string): boolean {
    return this.recordHash(this.hash(text));
  }

  contains(text: string): boolean {
    return this.hashes().indexOf(this.hash(text)) >= 0;
  }

  recordHash(value: string): boolean {
    const next: string[] = this.hashes().filter((h: string): boolean => h !== value);
    next.push(value);
    return this.store.write(ClipboardWriteLedger.KEY, next.slice(Math.max(0, next.length - this.capacity))
      .join(ClipboardWriteLedger.SEPARATOR));
  }

  /** 最近 capacity 条（旧的在前）。 */
  hashes(): string[] {
    const raw: string | null = this.store.read(ClipboardWriteLedger.KEY);
    if (raw === null) {
      return [];
    }
    const all: string[] = raw.split(ClipboardWriteLedger.SEPARATOR).filter((h: string): boolean => h.length > 0);
    return all.slice(Math.max(0, all.length - this.capacity));
  }

  /** 删除全部记录；确认落盘成功返回 true。 */
  clear(): boolean {
    return this.store.write(ClipboardWriteLedger.KEY, null);
  }
}

/**
 * 出过提示条的内容（G08）：出了提示条就记录（点了或关了都算），同一 hash 严格小于 24 小时不再提示。只存 hash 与时间；时钟可注入。
 * 只按 24 小时到期清理，不设条数上限（共性第 7 条 A-R1-07：容量淘汰会让仍在 24 小时内的内容再次提示）。撤回同意时 clear。
 */
export class PromptHistory {
  private static readonly KEY: string = 'prompted';
  private static readonly SEPARATOR: string = ',';
  private static readonly FIELD: string = '@';

  private readonly clock: () => number;
  private readonly store: ClipboardHashStore;

  constructor(clock: () => number = Date.now, store: ClipboardHashStore = new MemoryClipboardHashStore()) {
    this.clock = clock;
    this.store = store;
  }

  record(hash: string): void {
    const now: number = this.clock();
    const kept: ClipboardPromptStamp[] = this.stamps().filter((s: ClipboardPromptStamp): boolean => {
      const age: number = now - s.atMs;
      return s.hash !== hash && age >= 0 && age < ClipboardClassifier.PROMPT_WINDOW_MS;
    });
    kept.push(new ClipboardPromptStamp(hash, now));
    this.store.write(PromptHistory.KEY, kept.map((s: ClipboardPromptStamp): string =>
    s.hash + PromptHistory.FIELD + s.atMs).join(PromptHistory.SEPARATOR));
  }

  stamps(): ClipboardPromptStamp[] {
    const raw: string | null = this.store.read(PromptHistory.KEY);
    if (raw === null) {
      return [];
    }
    const out: ClipboardPromptStamp[] = [];
    for (const entry of raw.split(PromptHistory.SEPARATOR)) {
      const at: number = entry.indexOf(PromptHistory.FIELD);
      if (at <= 0) {
        continue;
      }
      const time: number = Number(entry.substring(at + 1));
      if (!Number.isSafeInteger(time)) {
        continue;
      }
      out.push(new ClipboardPromptStamp(entry.substring(0, at), time));
    }
    return out;
  }

  /** 删除全部记录；确认落盘成功返回 true。 */
  clear(): boolean {
    return this.store.write(PromptHistory.KEY, null);
  }
}

/** parse 的一条结果（多卡弹层按搜索卡样式列出；行内 error_code 的那条按该码处理）。 */
export class ParseRow {
  readonly card: Record<string, Object> | null;
  readonly errorCode: number | null;
  /** hit.raw（服务端回显的命中片段；只用于 30132 的预填，不落盘、不进日志）。 */
  readonly hitRaw: string | null;

  constructor(card: Record<string, Object> | null, errorCode: number | null, hitRaw: string | null) {
    this.card = card;
    this.errorCode = errorCode;
    this.hitRaw = hitRaw;
  }
}

/**
 * parse 结果到页面动作（brief §2.6；规则空白 G09、CLIP-19、CLIP-20）：
 * - open_detail：只有 1 张卡 → 以进程内的卡片种子打开 ProductDetail，沿用这张卡的 linkId（G09）；
 * - card_list：多条结果 → 当前页弹层按搜索卡样式列出（rows，行内 error_code 逐条按码处理，A-R1-05）；
 * - notice：30131 / 30141 等只提示；search_prefill：30132 → error.30132 加【用商品名搜索】（prefill 取「」内或首行）；
 * - retry_after：42901 → 按 Retry-After 禁用所有粘贴入口与提示条按钮 disableMs（缺省、非法、0 都 5 秒）；
 * - error：5xxxx 等 → error.<code>，有 trace_id 时带末 6 位（showTrace6）；force_update：10405 由网络层走强更分流，页面不另写。
 */
export class ParseAction {
  readonly actionRaw: string;
  linkId: string | null = null;
  prefill: string | null = null;
  textKey: string | null = null;
  showTrace6: boolean | null = null;
  disableMs: number | null = null;
  card: Record<string, Object> | null = null;
  rows: ParseRow[] = [];
  errorCode: number | null = null;
  traceId: string | null = null;

  constructor(actionRaw: string) {
    this.actionRaw = actionRaw;
  }
}

export class ParseResultAction {
  static readonly OPEN_DETAIL: string = 'open_detail';
  static readonly CARD_LIST: string = 'card_list';
  static readonly NOTICE: string = 'notice';
  static readonly SEARCH_PREFILL: string = 'search_prefill';
  static readonly RETRY_AFTER: string = 'retry_after';
  static readonly ERROR: string = 'error';
  static readonly FORCE_UPDATE: string = 'force_update';

  static readonly UNSUPPORTED: number = 30131;
  static readonly UNRECOGNIZED: number = 30132;
  static readonly OFF_SHELF: number = 30141;
  static readonly RATE_LIMITED: number = 42901;
  static readonly FORCE_UPDATE_CODE: number = 10405;
  static readonly SERVER_ERROR_MIN: number = 50000;
  /** 没有结果、或传输失败时的通用错误文案键。 */
  static readonly GENERIC_KEY: string = 'error.50001';

  /** response 原样是 ParseInputResponse 外壳（code、data.results、trace_id）；errorCode 为整体失败的业务码。 */
  static map(response: Record<string, Object> | null | undefined, errorCode: number | null | undefined,
    retryAfter: string | null | undefined, traceId: string | null | undefined): ParseAction {
    if (errorCode !== null && errorCode !== undefined && errorCode !== 0) {
      return ParseResultAction.failure(errorCode, retryAfter ?? null, traceId ?? null, null);
    }
    const envelope: Record<string, Object> | null = response ?? null;
    const data: Record<string, Object> | null = envelope === null ? null : objectOf(envelope['data']);
    const rows: ParseRow[] = ParseResultAction.rowsOf(data);
    const trace: string | null = traceId ?? (envelope === null ? null : textOf(envelope['trace_id']));
    if (rows.length === 0) {
      const empty: ParseAction = new ParseAction(ParseResultAction.ERROR);
      empty.textKey = ParseResultAction.GENERIC_KEY;
      empty.showTrace6 = trace !== null && trace.length > 0;
      empty.traceId = trace;
      return empty;
    }
    if (rows.length > 1) {
      const list: ParseAction = new ParseAction(ParseResultAction.CARD_LIST);
      list.rows = rows;
      list.traceId = trace;
      return list;
    }
    const only: ParseRow = rows[0];
    if (only.card !== null) {
      const detail: ParseAction = new ParseAction(ParseResultAction.OPEN_DETAIL);
      detail.card = only.card;
      detail.linkId = textOf(only.card['link_id']);
      detail.traceId = trace;
      return detail;
    }
    return ParseResultAction.failure(only.errorCode ?? ParseResultAction.SERVER_ERROR_MIN, retryAfter ?? null, trace,
      only.hitRaw);
  }

  /** data.results → 行（只留有 card 或 error_code 的）。 */
  static rowsOf(data: Record<string, Object> | null): ParseRow[] {
    const out: ParseRow[] = [];
    const raw: Object | undefined = data === null ? undefined : data['results'];
    if (raw === undefined || raw === null || !Array.isArray(raw)) {
      return out;
    }
    for (const item of raw as Object[]) {
      const row: Record<string, Object> | null = objectOf(item);
      if (row === null) {
        continue;
      }
      const card: Record<string, Object> | null = objectOf(row['card']);
      const code: Object | undefined = row['error_code'];
      const errorCode: number | null = typeof code === 'number' && Number.isInteger(code as number) ? code as number
        : null;
      const hit: Record<string, Object> | null = objectOf(row['hit']);
      const hitRaw: string | null = hit === null ? null : textOf(hit['raw']);
      if (card !== null || errorCode !== null) {
        out.push(new ParseRow(card, errorCode, hitRaw));
      }
    }
    return out;
  }

  private static failure(code: number, retryAfter: string | null, traceId: string | null,
    hitRaw: string | null): ParseAction {
    let action: ParseAction;
    if (code === ParseResultAction.UNRECOGNIZED) {
      action = new ParseAction(ParseResultAction.SEARCH_PREFILL);
      action.prefill = ClipboardText.searchPrefill(hitRaw);
      action.textKey = ParseResultAction.key(code);
    } else if (code === ParseResultAction.RATE_LIMITED) {
      action = new ParseAction(ParseResultAction.RETRY_AFTER);
      action.textKey = ParseResultAction.key(code);
      action.disableMs = ParseResultAction.retryAfterMillis(retryAfter);
    } else if (code === ParseResultAction.FORCE_UPDATE_CODE) {
      action = new ParseAction(ParseResultAction.FORCE_UPDATE);
    } else if (code >= ParseResultAction.SERVER_ERROR_MIN) {
      action = new ParseAction(ParseResultAction.ERROR);
      action.textKey = ParseResultAction.key(code);
      action.showTrace6 = traceId !== null && traceId.length > 0;
      action.traceId = traceId;
    } else {
      // 30131、30141 与其余业务码：只提示（30141 在多卡弹层里另按置灰处理）
      action = new ParseAction(ParseResultAction.NOTICE);
      action.textKey = ParseResultAction.key(code);
      action.traceId = traceId;
    }
    action.errorCode = code;
    return action;
  }

  /** Retry-After 的非负整数秒（与网络层同一个解析）；缺省、非法、0 都按 5 秒（规则空白 A11 / H 段）。 */
  static retryAfterMillis(raw: string | null | undefined): number {
    if (raw === null || raw === undefined) {
      return ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
    }
    const headers: Record<string, string> = {};
    headers['Retry-After'] = raw;
    const parsed: number = ErrorActionMapper.retryAfterMillis(headers);
    return parsed > 0 ? parsed : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
  }

  static key(code: number): string {
    return 'error.' + code;
  }
}

/** 手动粘贴的动作（brief §2.5；G10）：parse / open_search_typing / search_prefill / fill_invite / invite_not_found。 */
export class ManualPasteDecision {
  readonly actionRaw: string;
  readonly uploadText: string | null;
  readonly prefill: string | null;
  readonly code: string | null;
  readonly textKey: string | null;

  constructor(actionRaw: string, uploadText: string | null = null, prefill: string | null = null,
    code: string | null = null, textKey: string | null = null) {
    this.actionRaw = actionRaw;
    this.uploadText = uploadText;
    this.prefill = prefill;
    this.code = code;
    this.textKey = textKey;
  }
}

/**
 * 用户主动粘贴（首页「去粘贴」卡、SearchTyping「粘贴查返利」、登录页邀请码【粘贴】；鸿蒙都是 PasteButton 返回 SUCCESS 之后）：
 * - 商品入口（home、search_typing）：剪贴板为空 → 进 SearchTyping（flow-map 23.2.25）；抽到链接且通过商品过滤（长度 10～500 等，
 *   与自动识别同一套，共性第 22 条）→ 只上传链接与「」标题（G04）；非空但没抽到链接或没通过过滤 → 不上传，本地显示 30132 的同一种提示，预填「」内或首行（G10）；
 * - 登录页邀请码（login_invite）：只抽码填入输入框；抽不到 → 轻提示「未识别到邀请码」，不清空已有输入（BR-INV-04）。
 */
export class ManualPasteAction {
  static readonly ENTRY_HOME: string = 'home';
  static readonly ENTRY_SEARCH_TYPING: string = 'search_typing';
  static readonly ENTRY_LOGIN_INVITE: string = 'login_invite';

  static readonly PARSE: string = 'parse';
  static readonly OPEN_SEARCH_TYPING: string = 'open_search_typing';
  static readonly SEARCH_PREFILL: string = 'search_prefill';
  static readonly FILL_INVITE: string = 'fill_invite';
  static readonly INVITE_NOT_FOUND: string = 'invite_not_found';

  static decide(entry: string, text: string | null | undefined, rules: ClipboardRules): ManualPasteDecision {
    if (entry === ManualPasteAction.ENTRY_LOGIN_INVITE) {
      const code: string | null = text === null || text === undefined ? null : InviteCodeExtractor.extract(text);
      return code !== null ? new ManualPasteDecision(ManualPasteAction.FILL_INVITE, null, null, code)
        : new ManualPasteDecision(ManualPasteAction.INVITE_NOT_FOUND);
    }
    if (text === null || text === undefined || text.length === 0) {
      return new ManualPasteDecision(ManualPasteAction.OPEN_SEARCH_TYPING);
    }
    const links: string[] = ClipboardText.links(text);
    // 共性第 22 条：商品分支与自动识别同一套长度 / 形态过滤（ClipboardClassifier.productRejection），不通过不上传、走本地 30132
    if (ClipboardClassifier.productRejection(text, links, rules) === null) {
      return new ManualPasteDecision(ManualPasteAction.PARSE, ClipboardText.uploadText(links, text, rules.maxUploadLinks));
    }
    return new ManualPasteDecision(ManualPasteAction.SEARCH_PREFILL, null, ClipboardText.searchPrefill(text), null,
      ParseResultAction.key(ParseResultAction.UNRECOGNIZED));
  }
}

/** 可绑定判定（brief §2.7）：游客一律可以；已登录只看 getMe 的 invite_backfill.eligible 与 inviter_bound，拿不到或未知时不可以。 */
export class InviteEligibility {
  static of(guest: boolean, me: Record<string, Object> | null | undefined): boolean {
    return guest || InviteEligibility.loggedInEligible(me);
  }

  static loggedInEligible(me: Record<string, Object> | null | undefined): boolean {
    if (me === null || me === undefined) {
      return false;
    }
    const bound: boolean | null = flagOf(me['inviter_bound']);
    const backfill: Record<string, Object> | null = objectOf(me['invite_backfill']);
    const eligible: boolean | null = backfill === null ? null : flagOf(backfill['eligible']);
    return bound === false && eligible === true;
  }
}

/** 邀请确认的去向（brief §2.7）：prefill_login / bind_phone_first / backfill_pending_contract / none。 */
export class InviteConfirmDecision {
  readonly actionRaw: string;

  constructor(actionRaw: string) {
    this.actionRaw = actionRaw;
  }
}

/**
 * 邀请提示条点确认之后（BR-INV-04 细则；规则空白 G01、G16）：
 * - 游客：码放进进程内的预填容器，经 Router 打开 Login，随登录提交（不发请求、不持久化）；
 * - 已登录、可补填：未绑手机 → 先绑手机（bind_phone_first）；已绑手机 → 补填绑定，但契约没有 POST /v1/me/inviter 与 InviteBackfill 路由
 *   （G01），只给判定值 backfill_pending_contract，界面上不出已登录用户的邀请提示条；
 * - getMe 拿不到、不可补填、已有上级 → none。
 */
export class InviteConfirmAction {
  static readonly SESSION_GUEST: string = 'guest';
  static readonly SESSION_MEMBER: string = 'member';
  static readonly SESSION_PHONE: string = 'phone';

  static readonly PREFILL_LOGIN: string = 'prefill_login';
  static readonly BIND_PHONE_FIRST: string = 'bind_phone_first';
  static readonly BACKFILL_PENDING_CONTRACT: string = 'backfill_pending_contract';
  static readonly NONE: string = 'none';

  static decide(session: string, me: Record<string, Object> | null | undefined): InviteConfirmDecision {
    if (session === InviteConfirmAction.SESSION_GUEST) {
      return new InviteConfirmDecision(InviteConfirmAction.PREFILL_LOGIN);
    }
    if (!InviteEligibility.loggedInEligible(me)) {
      return new InviteConfirmDecision(InviteConfirmAction.NONE);
    }
    if (session === InviteConfirmAction.SESSION_MEMBER) {
      return new InviteConfirmDecision(InviteConfirmAction.BIND_PHONE_FIRST);
    }
    if (session === InviteConfirmAction.SESSION_PHONE) {
      // TODO(N-30) G01：契约补 POST /v1/me/inviter 与 InviteBackfill 路由前不发任何绑定请求
      return new InviteConfirmDecision(InviteConfirmAction.BACKFILL_PENDING_CONTRACT);
    }
    return new InviteConfirmDecision(InviteConfirmAction.NONE);
  }
}
