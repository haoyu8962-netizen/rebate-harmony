// 剪贴板识别的纯逻辑（APP-07；brief §2.1–§2.3、§2.5–§2.7；BR-ID-16、BR-INV-04、OPS-06；规则空白 G02–G14、CLIP-18…24）。
// 三端同名：ClipboardRules、ClipboardText、InviteCodeExtractor、ClipboardSensitive、ClipboardReadPolicy、ClipboardClassifier、
// ClipboardWriteLedger、PromptHistory、ParseResultAction、ManualPasteAction、InviteConfirmAction（向量 specs/clipboard-vectors.json）。
// 这里不读系统剪贴板、不落盘、不打日志：原文只在调用方的内存里经过这些函数，结果只含抽出的片段与 hash。
import { url } from '@kit.ArkTS';
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
 * 包内默认白名单的一项（FU-CLIP §2.1 第 1 条；K01）：主机等于 host、或以「.host」结尾即命中 platform。displayName 为提示条上的平台显示名
 * （K26：tmall.com 项显示「天猫」，platform 仍是 taobao）。
 */
export class ClipboardHostRule {
  readonly host: string;
  readonly platform: string;
  readonly displayName: string;

  constructor(host: string, platform: string, displayName: string) {
    this.host = host;
    this.platform = platform;
    this.displayName = displayName;
  }
}

/**
 * 远程收紧项（FU-CLIP §2.1 第 5 条；K02、K03、K30）：只能减不能加。platforms 只保留这些平台（白名单之外的平台名忽略；空数组 = 全关）；
 * removeHosts 去掉与默认项完全相同的项；tpwdEnabled 为 false 关口令。各项为 null 表示这一维度不限制。
 */
export class ClipboardLimits {
  readonly platforms: string[] | null;
  readonly removeHosts: string[] | null;
  readonly tpwdEnabled: boolean | null;

  constructor(platforms?: string[] | null, removeHosts?: string[] | null, tpwdEnabled?: boolean | null) {
    this.platforms = platforms === undefined || platforms === null ? null : platforms.slice();
    this.removeHosts = removeHosts === undefined || removeHosts === null ? null : removeHosts.slice();
    this.tpwdEnabled = tpwdEnabled === undefined ? null : tpwdEnabled;
  }

  static readonly NONE: ClipboardLimits = new ClipboardLimits();

  /**
   * features.flags → 收紧项（K03；F-CLIP-05「按平台一键关闭」）：只看 clipboard.enabled.taobao|jd|pdd 为 false 的键，等价于从 platforms
   * 去掉该平台；true 与缺键无效果；端键 clipboard.enabled.ios|android|harmony 与未知平台忽略。没有被关的平台时 platforms 为 null。
   * TODO(N-34) K03：电商平台级开关的含义待规划确认。
   */
  static fromFeatureFlags(flags: Record<string, boolean> | null | undefined): ClipboardLimits {
    if (flags === null || flags === undefined) {
      return ClipboardLimits.NONE;
    }
    const kept: string[] = [];
    let off: boolean = false;
    for (const platform of ClipboardRules.PLATFORMS) {
      if (flags[ClipboardLimits.FLAG_PREFIX + platform] === false) {
        off = true;
      } else {
        kept.push(platform);
      }
    }
    return off ? new ClipboardLimits(kept) : ClipboardLimits.NONE;
  }

  /** features.flags 的电商平台开关前缀（K03）。 */
  static readonly FLAG_PREFIX: string = 'clipboard.enabled.';
}

/**
 * 本地过滤规则（F-CLIP-02、BR-INV-04 细则；规则空白 G02、G03、G14；FU-CLIP K01～K04）。包内默认取原文数值：长度 10～500、排除不超过
 * 20 位的纯数字或纯字母数字、排除词表为空；邀请触发前提为文本含 config.share_domains 任一域名的 /i/{code} 落地页，或含「邀请码」字样。
 * 商品候选只认包内白名单（hostRules）里的链接与淘宝口令（tpwdEnabled 且 platforms 含 taobao）；白名单只能经 tightened 收紧。
 * TODO(N-30) G02 / TODO(N-34) K02：config.clipboard 在契约里是 FreeForm，键名与类型没定，fromConfig 不按猜测的键名解析，一律用包内默认。
 */
export class ClipboardRules {
  static readonly DEFAULT_MIN_LENGTH: number = 10;
  static readonly DEFAULT_MAX_LENGTH: number = 500;
  static readonly DEFAULT_PURE_ALNUM_MAX: number = 20;
  static readonly DEFAULT_MAX_LINKS: number = 3;
  static readonly INVITE_KEYWORD: string = '邀请码';

  static readonly PLATFORM_TAOBAO: string = 'taobao';
  static readonly PLATFORM_JD: string = 'jd';
  static readonly PLATFORM_PDD: string = 'pdd';
  /** M-内测平台（04 §2.1），顺序即 ClipboardLimits.fromFeatureFlags 输出顺序。 */
  static readonly PLATFORMS: string[] = ['taobao', 'jd', 'pdd'];

  /**
   * 包内默认白名单（K01，三端逐字一致）。TODO(N-34) K01 / K31：B1-07 出 link-patterns 真实规则后由契约 / 规划决定是否改为构建时生成，
   * 仍保持「远程只能收紧」。
   */
  static readonly DEFAULT_HOSTS: ClipboardHostRule[] = [
    new ClipboardHostRule('taobao.com', 'taobao', '淘宝'),
    new ClipboardHostRule('tb.cn', 'taobao', '淘宝'),
    new ClipboardHostRule('tmall.com', 'taobao', '天猫'),
    new ClipboardHostRule('jd.com', 'jd', '京东'),
    new ClipboardHostRule('3.cn', 'jd', '京东'),
    new ClipboardHostRule('yangkeduo.com', 'pdd', '拼多多'),
    new ClipboardHostRule('pinduoduo.com', 'pdd', '拼多多')
  ];

  readonly minLength: number;
  readonly maxLength: number;
  /** 不超过这个长度的纯数字 / 纯字母数字文本排除（F-CLIP-02）。 */
  readonly pureAlnumMaxLength: number;
  readonly excludedWords: string[];
  /** 邀请触发字样（BR-INV-04 细则「含『邀请码』字样」）。 */
  readonly inviteKeyword: string;
  /** 上传的候选（白名单链接与口令合计）最多几个（G04、K07：按出现顺序）。 */
  readonly maxUploadLinks: number;
  /** 商品链接白名单（K01）。 */
  readonly hostRules: ClipboardHostRule[];
  /** 淘口令开关（K04；收紧后可关）。 */
  readonly tpwdEnabled: boolean;
  /** 仍开着的电商平台（K02、K03）。 */
  readonly platforms: string[];

  constructor(minLength: number = ClipboardRules.DEFAULT_MIN_LENGTH,
    maxLength: number = ClipboardRules.DEFAULT_MAX_LENGTH,
    pureAlnumMaxLength: number = ClipboardRules.DEFAULT_PURE_ALNUM_MAX, excludedWords: string[] = [],
    inviteKeyword: string = ClipboardRules.INVITE_KEYWORD, maxUploadLinks: number = ClipboardRules.DEFAULT_MAX_LINKS,
    hostRules: ClipboardHostRule[] = ClipboardRules.DEFAULT_HOSTS, tpwdEnabled: boolean = true,
    platforms: string[] = ClipboardRules.PLATFORMS) {
    this.minLength = minLength;
    this.maxLength = maxLength;
    this.pureAlnumMaxLength = pureAlnumMaxLength;
    this.excludedWords = excludedWords;
    this.inviteKeyword = inviteKeyword;
    this.maxUploadLinks = maxUploadLinks;
    this.hostRules = hostRules.slice();
    this.tpwdEnabled = tpwdEnabled;
    this.platforms = platforms.slice();
  }

  static readonly defaults: ClipboardRules = new ClipboardRules();

  /**
   * 下发的 config.clipboard（FreeForm）→ 规则。TODO(N-30) G02 / TODO(N-34) K02：结构未定，任何下发值都认不出，整体忽略、用包内默认
   * （不按猜测的键名解析）。契约定下键名后在这里解析，认不出的结构仍整体回落；白名单只取与包内默认的交集（tightened）。
   */
  static fromConfig(_raw: Object | null | undefined): ClipboardRules {
    return ClipboardRules.defaults;
  }

  /** 淘口令此刻可用（开关开、淘宝平台未被关）。 */
  get tpwdActive(): boolean {
    return this.tpwdEnabled && this.platforms.indexOf(ClipboardRules.PLATFORM_TAOBAO) >= 0;
  }

  /**
   * 远程收紧（K02、K03、K30）：返回新规则，只减不加——platforms 与现有平台取交集（未知平台名忽略），removeHosts 只去掉完全相同的现有项，
   * tpwdEnabled=false 关口令。任何取值都不能增加主机或放宽判定。
   */
  tightened(limits: ClipboardLimits): ClipboardRules {
    let platforms: string[] = this.platforms.slice();
    const only: string[] | null = limits.platforms;
    if (only !== null) {
      platforms = platforms.filter((p: string): boolean => only.indexOf(p) >= 0);
    }
    let hosts: ClipboardHostRule[] = this.hostRules.filter((r: ClipboardHostRule): boolean =>
    platforms.indexOf(r.platform) >= 0);
    const removed: string[] | null = limits.removeHosts;
    if (removed !== null) {
      hosts = hosts.filter((r: ClipboardHostRule): boolean => removed.indexOf(r.host) < 0);
    }
    const tpwd: boolean = this.tpwdEnabled && limits.tpwdEnabled !== false;
    return new ClipboardRules(this.minLength, this.maxLength, this.pureAlnumMaxLength, this.excludedWords,
      this.inviteKeyword, this.maxUploadLinks, hosts, tpwd, platforms);
  }

  /** 平台显示名（K26）：口令与没有主机信息时用。 */
  static displayNameOf(platform: string): string {
    if (platform === ClipboardRules.PLATFORM_JD) {
      return '京东';
    }
    if (platform === ClipboardRules.PLATFORM_PDD) {
      return '拼多多';
    }
    return '淘宝';
  }
}

/** 文本片段的抽取（G04、BR-TEXT-14 的 30132 预填规则）：只在内存里做，原文不落盘、不进日志。 */
export class ClipboardText {
  /** http(s) 链接：只取 ASCII URL 字符，遇到空白、全角与中文标点即止（G03、G04）。 */
  private static readonly LINK: RegExp = new RegExp('https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&\'()*+,;=%]+', 'gi');
  private static readonly TITLE: RegExp = new RegExp('「([^「」]+)」');

  /** 链接片段与位置（候选按原文位置排序用）。 */
  static linkSpans(text: string): ClipboardSpan[] {
    const out: ClipboardSpan[] = [];
    const pattern: RegExp = new RegExp(ClipboardText.LINK.source, 'gi');
    let match: RegExpExecArray | null = pattern.exec(text);
    while (match !== null) {
      out.push(new ClipboardSpan(match[0], match.index));
      match = pattern.exec(text);
    }
    return out;
  }

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

  /**
   * 本地 30132（没有候选、不上传）的【用商品名搜索】预填（BR-TEXT-14：「」内或首行商品名，提取不到留空）。预填点了就发搜索，所以与上传同一套
   * 最小化（FU-CLIP 共性第 5 条，R2-01 同类路径）：有「」标题时只用最小化后的标题（含非白名单链接 / 口令被整段舍弃时留空，不退回首行）；
   * 首行含链接形态或像口令的片段时留空。服务端回显的 hit.raw 预填仍用 searchPrefill。
   */
  static localPrefill(text: string | null | undefined, rules: ClipboardRules, shareDomains: string[]): string | null {
    if (text === null || text === undefined || text.trim().length === 0) {
      return null;
    }
    const title: string | null = ClipboardText.quotedTitle(text);
    if (title !== null) {
      return ClipboardTitlePolicy.minimize(title, rules, shareDomains);
    }
    const line: string | null = ClipboardText.searchPrefill(text);
    if (line === null || ClipboardText.linkSpans(line).length > 0 || TpwdExtractor.spans(line, rules).length > 0
      || ClipboardTitlePolicy.unsafe(line)) {
      return null;
    }
    return line;
  }

  /**
   * 上传内容（G04）：候选（最多 maxLinks 个，按出现顺序）加「」内的标题，换行连接；原文其余部分不上传。
   * FU-CLIP 共性第 5 条（鸿蒙 R2-01，S0）：标题先经 ClipboardTitlePolicy.minimize 最小化——剔除其中的白名单链接与口令，含非白名单链接、
   * 无法识别的口令或其他链接形态时整段舍弃；标题里的链接、口令不绕过白名单与候选总数上限。
   */
  static uploadText(links: string[], text: string, maxLinks: number, rules: ClipboardRules,
    shareDomains: string[]): string {
    const parts: string[] = links.slice(0, maxLinks);
    const title: string | null = ClipboardTitlePolicy.minimize(ClipboardText.quotedTitle(text), rules, shareDomains);
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

/** 文本里切出的一个链接片段与它在原文中的位置（只在内存里，随调用结束丢弃）。 */
export class ClipboardSpan {
  readonly raw: string;
  readonly index: number;

  constructor(raw: string, index: number) {
    this.raw = raw;
    this.index = index;
  }
}

/** 链接判定结果（FU-CLIP §2.1 第 2 条）：allowed 时 platform、rule、host 有值；否则 reasonRaw 为第一个命中的拒绝原因。 */
export class ClipboardHostCheck {
  readonly allowed: boolean;
  readonly platform: string | null;
  readonly reasonRaw: string | null;
  readonly rule: ClipboardHostRule | null;
  /** 规范化后的主机（小写、去一个末尾点）；判定前就被拒绝时为 null。 */
  readonly host: string | null;
  /** 主机之后还有路径、查询或片段（显示为「/…」，K26）。 */
  readonly hasRest: boolean;

  constructor(allowed: boolean, platform: string | null, reasonRaw: string | null, rule: ClipboardHostRule | null = null,
    host: string | null = null, hasRest: boolean = false) {
    this.allowed = allowed;
    this.platform = platform;
    this.reasonRaw = reasonRaw;
    this.rule = rule;
    this.host = host;
    this.hasRest = hasRest;
  }
}

/**
 * 链接白名单判定（FU-CLIP §2.1 第 2 条；K01、K06）。系统 URL 解析器（url.URL.parseURL）解析失败 → unparsable；之后按字面检查，原因顺序
 * 固定：unparsable → scheme → userinfo → port → ip → host_invalid → not_allowed，命中第一个即返回。判定用规范化主机，上传与显示用原串。
 * 与服务端 link-patterns 同口径：主机等于白名单某项或以「.项」结尾即命中；伪装域名（taobao.com.evil.cn、evil-taobao.com）拒绝。
 */
export class ClipboardHostPolicy {
  static readonly UNPARSABLE: string = 'unparsable';
  static readonly SCHEME: string = 'scheme';
  static readonly USERINFO: string = 'userinfo';
  static readonly PORT: string = 'port';
  static readonly IP: string = 'ip';
  static readonly HOST_INVALID: string = 'host_invalid';
  static readonly NOT_ALLOWED: string = 'not_allowed';

  private static readonly SCHEME_PATTERN: RegExp = /^([A-Za-z][A-Za-z0-9+.\-]*):/;
  private static readonly HOST_CHARS: RegExp = /^[a-z0-9.\-]+$/;
  private static readonly DIGITS: RegExp = /^[0-9]+$/;
  private static readonly HEX: RegExp = /^0x[0-9a-f]*$/;

  /** url.URL.parseURL 判定「不是合法 URL」的错误码（401 参数错误、10200002 Invalid url string）。 */
  private static readonly PARSE_REJECT_CODES: number[] = [401, 10200002];

  /**
   * 系统 URL 解析器能否解析（解析器之外另做字面检查，两者都通过才算）。只有解析器明确回「不是合法 URL」（BusinessError 401 / 10200002）
   * 才算解析失败；运行环境里解析器本身不可用（本机 Local Test 的 @ohos.url 缺 URLSearchParams，抛的不是 BusinessError）时不据此拒绝，
   * 由后面的字面检查判定（规则空白 HS01）。
   */
  static systemParses: (raw: string) => boolean = (raw: string): boolean => {
    try {
      url.URL.parseURL(raw);
      return true;
    } catch (e) {
      const code: Object | undefined = e === null || e === undefined || typeof e !== 'object' ? undefined
        : (e as Record<string, Object>)['code'];
      return !(typeof code === 'number' && ClipboardHostPolicy.PARSE_REJECT_CODES.indexOf(code as number) >= 0);
    }
  };

  private static reject(reason: string, host: string | null = null): ClipboardHostCheck {
    return new ClipboardHostCheck(false, null, reason, null, host, false);
  }

  static check(raw: string, rules: ClipboardRules): ClipboardHostCheck {
    let parses: boolean = false;
    try {
      parses = ClipboardHostPolicy.systemParses(raw);
    } catch (e) {
      parses = false;
    }
    const schemeMatch: RegExpExecArray | null = ClipboardHostPolicy.SCHEME_PATTERN.exec(raw);
    if (!parses || schemeMatch === null) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.UNPARSABLE);
    }
    const scheme: string = schemeMatch[1].toLowerCase();
    const rest: string = raw.substring(schemeMatch[0].length);
    if (scheme !== 'http' && scheme !== 'https') {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.SCHEME);
    }
    if (!rest.startsWith('//')) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.UNPARSABLE);
    }
    const afterSlashes: string = rest.substring(2);
    let end: number = afterSlashes.length;
    for (const stop of ['/', '?', '#', '\\']) {
      const at: number = afterSlashes.indexOf(stop);
      if (at >= 0 && at < end) {
        end = at;
      }
    }
    const authority: string = afterSlashes.substring(0, end);
    const tail: string = afterSlashes.substring(end);
    const hasRest: boolean = tail.length > 0 && tail !== '/';
    if (authority.length === 0) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.UNPARSABLE);
    }
    if (authority.indexOf('@') >= 0) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.USERINFO);
    }
    if (authority.startsWith('[')) {
      const close: number = authority.indexOf(']');
      if (close < 0) {
        return ClipboardHostPolicy.reject(ClipboardHostPolicy.UNPARSABLE);
      }
      if (close + 1 < authority.length) {
        return ClipboardHostPolicy.reject(ClipboardHostPolicy.PORT);
      }
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.IP);
    }
    if (authority.indexOf('[') >= 0 || authority.indexOf(']') >= 0) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.UNPARSABLE);
    }
    if (authority.indexOf(':') >= 0) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.PORT);
    }
    let host: string = authority.toLowerCase();
    if (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    const labels: string[] = host.split('.');
    const last: string = labels[labels.length - 1];
    if (ClipboardHostPolicy.DIGITS.test(last) || ClipboardHostPolicy.HEX.test(last)) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.IP, host);
    }
    if (!ClipboardHostPolicy.HOST_CHARS.test(host) || labels.length < 2
      || labels.some((l: string): boolean => l.length === 0 || l.startsWith('-') || l.endsWith('-'))) {
      return ClipboardHostPolicy.reject(ClipboardHostPolicy.HOST_INVALID, host);
    }
    for (const rule of rules.hostRules) {
      if (host === rule.host || host.endsWith('.' + rule.host)) {
        return new ClipboardHostCheck(true, rule.platform, null, rule, host, hasRest);
      }
    }
    return ClipboardHostPolicy.reject(ClipboardHostPolicy.NOT_ALLOWED, host);
  }
}

/**
 * 淘口令抽取（FU-CLIP §2.1 第 3 条；K04，TODO(N-34) 待 B1-07 样本校准）：只对 taobao。旧版同一包裹符号成对、中间 8～16 位字母数字且不是
 * 纯数字、前后不紧贴 ASCII 字母数字；新版「/CZ 四位数字 空格 8～16 位字母数字/」。抽出整段（含符号），按出现位置排序。
 * 京口令、拼多多口令没有形态描述，不识别。
 */
export class TpwdExtractor {
  private static readonly OLD: string = '([￥¥$€£₤₳¢₴₰])([A-Za-z0-9]{8,16})\\1';
  private static readonly NEW: string = '/CZ[0-9]{4} [A-Za-z0-9]{8,16}/';
  private static readonly ALNUM: RegExp = /^[A-Za-z0-9]$/;
  private static readonly ALL_DIGITS: RegExp = /^[0-9]+$/;

  static extract(text: string, rules: ClipboardRules): string[] {
    return TpwdExtractor.spans(text, rules).map((s: ClipboardSpan): string => s.raw);
  }

  static spans(text: string, rules: ClipboardRules): ClipboardSpan[] {
    const out: ClipboardSpan[] = [];
    if (!rules.tpwdActive) {
      return out;
    }
    const old: RegExp = new RegExp(TpwdExtractor.OLD, 'g');
    let match: RegExpExecArray | null = old.exec(text);
    while (match !== null) {
      const start: number = match.index;
      const stop: number = start + match[0].length;
      const before: string = start > 0 ? text.charAt(start - 1) : '';
      const after: string = stop < text.length ? text.charAt(stop) : '';
      if (TpwdExtractor.ALNUM.test(before) || TpwdExtractor.ALNUM.test(after)
        || TpwdExtractor.ALL_DIGITS.test(match[2])) {
        old.lastIndex = start + 1;
      } else {
        out.push(new ClipboardSpan(match[0], start));
      }
      match = old.exec(text);
    }
    const fresh: RegExp = new RegExp(TpwdExtractor.NEW, 'g');
    let next: RegExpExecArray | null = fresh.exec(text);
    while (next !== null) {
      out.push(new ClipboardSpan(next[0], next.index));
      next = fresh.exec(text);
    }
    out.sort((a: ClipboardSpan, b: ClipboardSpan): number => a.index - b.index);
    return out;
  }
}

/** 一个本地抽出的商品候选（kindRaw url / tpwd）：只在内存里，随请求或提示条作废而释放。 */
export class ClipboardCandidate {
  static readonly KIND_URL: string = 'url';
  static readonly KIND_TPWD: string = 'tpwd';

  readonly kindRaw: string;
  readonly platform: string;
  readonly raw: string;
  readonly index: number;
  readonly displayName: string;
  /** 链接的规范化主机（口令为 null）。 */
  readonly host: string | null;
  readonly hasRest: boolean;

  constructor(kindRaw: string, platform: string, raw: string, index: number, displayName: string, host: string | null,
    hasRest: boolean) {
    this.kindRaw = kindRaw;
    this.platform = platform;
    this.raw = raw;
    this.index = index;
    this.displayName = displayName;
    this.host = host;
    this.hasRest = hasRest;
  }
}

/**
 * 商品候选（FU-CLIP §2.1 第 4 条；G04、K07、A02）：白名单链接（去掉邀请落地页）与淘口令，按在原文中的出现位置排序，合计最多
 * rules.maxUploadLinks（3）个；上传内容 = 候选 + 「」内第一段标题，换行连接，原文其余部分不上传。没有候选 → 不是商品。
 */
export class ClipboardCandidates {
  static extract(text: string, rules: ClipboardRules, shareDomains: string[]): ClipboardCandidate[] {
    const all: ClipboardCandidate[] = [];
    const links: ClipboardSpan[] = ClipboardText.linkSpans(text);
    for (const link of links) {
      if (ClipboardClassifier.inviteLanding(link.raw, shareDomains)) {
        continue;
      }
      const check: ClipboardHostCheck = ClipboardHostPolicy.check(link.raw, rules);
      if (check.allowed && check.rule !== null) {
        all.push(new ClipboardCandidate(ClipboardCandidate.KIND_URL, check.rule.platform, link.raw, link.index,
          check.rule.displayName, check.host, check.hasRest));
      }
    }
    for (const token of TpwdExtractor.spans(text, rules)) {
      const end: number = token.index + token.raw.length;
      // 落在某个链接片段里的不算口令（链接字符集含 $ 等包裹符号）
      const inside: boolean = links.some((l: ClipboardSpan): boolean =>
      token.index < l.index + l.raw.length && end > l.index);
      if (!inside) {
        all.push(new ClipboardCandidate(ClipboardCandidate.KIND_TPWD, ClipboardRules.PLATFORM_TAOBAO, token.raw,
          token.index, ClipboardRules.displayNameOf(ClipboardRules.PLATFORM_TAOBAO), null, false));
      }
    }
    all.sort((a: ClipboardCandidate, b: ClipboardCandidate): number => a.index - b.index);
    return all.slice(0, Math.max(0, rules.maxUploadLinks));
  }

  /** 上传内容；没有候选为 null。 */
  static uploadText(text: string, rules: ClipboardRules, shareDomains: string[]): string | null {
    return ClipboardCandidates.uploadOf(ClipboardCandidates.extract(text, rules, shareDomains), text, rules, shareDomains);
  }

  static uploadOf(candidates: ClipboardCandidate[], text: string, rules: ClipboardRules,
    shareDomains: string[]): string | null {
    if (candidates.length === 0) {
      return null;
    }
    return ClipboardText.uploadText(candidates.map((c: ClipboardCandidate): string => c.raw), text, candidates.length,
      rules, shareDomains);
  }
}

/**
 * 「」标题片段的最小化（FU-CLIP 共性第 5 条；鸿蒙 R2-01，S0；TODO(N-34) HS16）：标题只用来帮服务端认商品，不能夹带候选以外的东西。
 * - 标题里的 http(s) 链接逐个按 ClipboardHostPolicy 判定：任何一个不在白名单（含邀请落地页、伪装域名、IP、端口、userinfo）→ 整段舍弃；
 *   全部在白名单 → 从标题里剔除（它们本来就按原文位置参与候选排序与 3 个上限，超出上限的不再借标题上传）。
 * - 能识别的淘口令从标题里剔除；剔除后仍有其他链接形态（任意 scheme://、www.、无 scheme 的域名、IPv4）或像口令的成对包裹片段
 *   （含字母，如未识别的口令、口令被远程关闭时的口令）→ 整段舍弃。
 * - 剔除后只剩空白 → 没有标题。
 * 只在内存里做；本地预填（30132【用商品名搜索】）仍用原标题，不经上传。
 */
export class ClipboardTitlePolicy {
  private static readonly SCHEME: RegExp = /[A-Za-z][A-Za-z0-9+.\-]*:\/\//;
  private static readonly WWW: RegExp = /(^|[^A-Za-z0-9])www\./i;
  private static readonly BARE_HOST: RegExp = /(^|[^A-Za-z0-9.\-])(?:[A-Za-z0-9\-]+\.)+[A-Za-z]{2,}(?![A-Za-z0-9])/;
  private static readonly IPV4: RegExp = /(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?![0-9])/;
  private static readonly LOOSE_TOKEN: RegExp = /([￥¥$€£₤₳¢₴₰])([^\s￥¥$€£₤₳¢₴₰]{4,40})\1/g;
  private static readonly LOOSE_NEW_TOKEN: RegExp = /\/[A-Za-z]{2}[0-9]{2,6}\s/;
  private static readonly LETTER: RegExp = /[A-Za-z]/;

  static minimize(title: string | null, rules: ClipboardRules, shareDomains: string[]): string | null {
    if (title === null || title === undefined) {
      return null;
    }
    const strip: ClipboardSpan[] = [];
    const links: ClipboardSpan[] = ClipboardText.linkSpans(title);
    for (const link of links) {
      if (ClipboardClassifier.inviteLanding(link.raw, shareDomains)) {
        return null;
      }
      const check: ClipboardHostCheck = ClipboardHostPolicy.check(link.raw, rules);
      if (!check.allowed || check.rule === null) {
        return null;
      }
      strip.push(link);
    }
    for (const token of TpwdExtractor.spans(title, rules)) {
      const end: number = token.index + token.raw.length;
      const inside: boolean = links.some((l: ClipboardSpan): boolean => token.index < l.index + l.raw.length && end > l.index);
      if (!inside) {
        strip.push(token);
      }
    }
    strip.sort((a: ClipboardSpan, b: ClipboardSpan): number => b.index - a.index);
    let rest: string = title;
    for (const span of strip) {
      rest = rest.substring(0, span.index) + ' ' + rest.substring(span.index + span.raw.length);
    }
    if (ClipboardTitlePolicy.unsafe(rest)) {
      return null;
    }
    const out: string = rest.replace(/\s+/g, ' ').trim();
    return out.length > 0 ? out : null;
  }

  /** 剔除白名单链接与口令后的残留里还有链接形态或像口令的片段。 */
  static unsafe(rest: string): boolean {
    if (ClipboardTitlePolicy.SCHEME.test(rest) || ClipboardTitlePolicy.WWW.test(rest) || ClipboardTitlePolicy.BARE_HOST.test(rest)
      || ClipboardTitlePolicy.IPV4.test(rest) || ClipboardTitlePolicy.LOOSE_NEW_TOKEN.test(rest)) {
      return true;
    }
    const loose: RegExp = new RegExp(ClipboardTitlePolicy.LOOSE_TOKEN.source, 'g');
    let match: RegExpExecArray | null = loose.exec(rest);
    while (match !== null) {
      if (ClipboardTitlePolicy.LETTER.test(match[2])) {
        return true;
      }
      loose.lastIndex = match.index + 1;
      match = loose.exec(rest);
    }
    return false;
  }
}

/** 提示条上显示的平台与缩略候选（K26）：labelRaw link / tpwd；链接 display = 小写主机 +（有路径或查询时）「/…」，口令为 null。 */
export class ClipboardPromptInfo {
  static readonly LABEL_LINK: string = 'link';
  static readonly LABEL_TPWD: string = 'tpwd';

  readonly platform: string;
  readonly labelRaw: string;
  readonly display: string | null;
  readonly count: number;
  readonly displayName: string;

  constructor(platform: string, labelRaw: string, display: string | null, count: number, displayName: string) {
    this.platform = platform;
    this.labelRaw = labelRaw;
    this.display = display;
    this.count = count;
    this.displayName = displayName;
  }
}

/** 上传前可见平台（FU-CLIP §2.6；K26、K27）：取第一个候选的平台与类型；不显示路径与查询（可能带追踪参数）。 */
export class ClipboardPromptDisplay {
  static describe(candidates: ClipboardCandidate[]): ClipboardPromptInfo | null {
    if (candidates.length === 0) {
      return null;
    }
    const first: ClipboardCandidate = candidates[0];
    if (first.kindRaw === ClipboardCandidate.KIND_TPWD || first.host === null) {
      return new ClipboardPromptInfo(first.platform, ClipboardPromptInfo.LABEL_TPWD, null, candidates.length,
        first.displayName);
    }
    return new ClipboardPromptInfo(first.platform, ClipboardPromptInfo.LABEL_LINK,
      first.host + (first.hasRest ? '/…' : ''), candidates.length, first.displayName);
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
 * 3. 商品候选：通过长度、纯字母数字与排除词规则，并且有本地候选（FU-CLIP：白名单链接与淘口令；邀请落地页 /i/{code} 链接不算，
 *    CLIP-18；没有候选仍回 no_link）→ product；
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
    // FU-CLIP C2 / C8：商品判据从「有 http(s) 链接」换成「有本地候选」（白名单链接去掉邀请落地页 + 淘口令，K01、K04、K07）
    const candidates: string[] = ClipboardCandidates.extract(text, rules, context.shareDomains)
      .map((c: ClipboardCandidate): string => c.raw);
    const productReason: string | null = ClipboardClassifier.productRejection(text, candidates, rules);
    if (productReason === null) {
      return new ClipboardClassification(ClipboardClassifier.KIND_PRODUCT, null, null,
        ClipboardText.uploadText(candidates, text, rules.maxUploadLinks, rules, context.shareDomains), hash);
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
   * 商品候选的拒绝原因；null = 是商品候选。links 为本地候选（白名单链接与口令，已去掉邀请落地页）。自动识别与手动粘贴商品入口共用（共性第 22 条，F-CLIP-02）：
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
 * 自写记录的端口（ClipboardWriter 用）：写入前 record（确认落盘返回 true），识别时 contains。生产是 ClipboardController 的加盐台账
 * （SaltedWriteLedger，FU-CLIP C3）；ClipboardWriteLedger 是 APP-07 的通用实现（hash 由调用方注入）。
 */
export interface ClipboardSelfWriteLedger {
  record(text: string): boolean;

  contains(text: string): boolean;
}

/**
 * App 自己写入剪贴板的内容（F-CLIP-02；brief §2.3）：桥 clipboard.write、复制口令 copy_tpwd、各原生复制按钮都经同一个写入口
 * （ClipboardWriter），写入前先 record。保留最近 capacity 条 hash（重复写入同一内容移到最新），商品与邀请两种识别都排除。
 * 撤回同意时 clear。
 */
export class ClipboardWriteLedger implements ClipboardSelfWriteLedger {
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
 * - 商品入口（home、search_typing）：剪贴板为空 → 进 SearchTyping（flow-map 23.2.25）；抽到本地候选（FU-CLIP：白名单链接与淘口令）且通过商品过滤（长度 10～500 等，
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

  static decide(entry: string, text: string | null | undefined, rules: ClipboardRules,
    shareDomains: string[] = []): ManualPasteDecision {
    if (entry === ManualPasteAction.ENTRY_LOGIN_INVITE) {
      const code: string | null = text === null || text === undefined ? null : InviteCodeExtractor.extract(text);
      return code !== null ? new ManualPasteDecision(ManualPasteAction.FILL_INVITE, null, null, code)
        : new ManualPasteDecision(ManualPasteAction.INVITE_NOT_FOUND);
    }
    if (text === null || text === undefined || text.length === 0) {
      return new ManualPasteDecision(ManualPasteAction.OPEN_SEARCH_TYPING);
    }
    // FU-CLIP C2 / C8：只认本地候选（白名单链接去掉邀请落地页 + 淘口令），抽不到候选 → 本地 30132（G10 不变）
    const links: string[] = ClipboardCandidates.extract(text, rules, shareDomains)
      .map((c: ClipboardCandidate): string => c.raw);
    // 共性第 22 条：商品分支与自动识别同一套长度 / 形态过滤（ClipboardClassifier.productRejection），不通过不上传、走本地 30132
    if (ClipboardClassifier.productRejection(text, links, rules) === null) {
      return new ManualPasteDecision(ManualPasteAction.PARSE, ClipboardText.uploadText(links, text, rules.maxUploadLinks, rules,
        shareDomains));
    }
    return new ManualPasteDecision(ManualPasteAction.SEARCH_PREFILL, null,
      ClipboardText.localPrefill(text, rules, shareDomains), null, ParseResultAction.key(ParseResultAction.UNRECOGNIZED));
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

/**
 * 桥 clipboard.read 的最小化输出（FU-CLIP §2.3；K12、K13、K14）：读之前核对隐私已同意当前版本（不满足不读、回 ""）；读到的内容只回本地
 * 候选拼接（白名单链接 / 口令最多 3 个 + 「」标题），邀请内容、非白名单链接与其余文字都不回，抽不到回 ""；不套自写排除与 24 小时去重。
 * 鸿蒙：bridge.schema 里 clipboard.read 的 since.harmony 为 null，桥保持不声明（90001），这里只作三端同名的纯逻辑。
 */
export class ClipboardBridgeRead {
  static respond(consentRaw: string, read: () => string | null, rules: ClipboardRules, shareDomains: string[]): string {
    if (consentRaw !== ClipboardReadPolicy.CONSENT_AGREED) {
      return '';
    }
    const text: string | null = read();
    if (text === null || text === undefined || text.length === 0) {
      return '';
    }
    return ClipboardCandidates.uploadText(text, rules, shareDomains) ?? '';
  }
}

/**
 * 系统分享收到的文本当场抽出的东西（FU-CLIP §2.5；K17）：只有候选、上传内容、「」标题与显示信息，原文不在这里。mime 不是 text/plain
 * 时 mimeOk=false；文本为空 empty=true；超过 4000 字 tooLong=true（HS 段：按「没有候选」处理，不预填）。
 */
export class ShareImportPayload {
  readonly mimeOk: boolean;
  readonly empty: boolean;
  readonly tooLong: boolean;
  readonly candidates: ClipboardCandidate[];
  readonly uploadText: string | null;
  readonly prefill: string | null;
  readonly display: ClipboardPromptInfo | null;

  constructor(mimeOk: boolean, empty: boolean, tooLong: boolean, candidates: ClipboardCandidate[],
    uploadText: string | null, prefill: string | null, display: ClipboardPromptInfo | null) {
    this.mimeOk = mimeOk;
    this.empty = empty;
    this.tooLong = tooLong;
    this.candidates = candidates;
    this.uploadText = uploadText;
    this.prefill = prefill;
    this.display = display;
  }
}

/** 分享导入的判定：actionRaw prompt / search_prefill / home_only / ignore_mime / drop / ignore_busy；scene 只在 prompt 时为 share_ext。 */
export class ShareImportDecision {
  readonly actionRaw: string;
  readonly uploadText: string | null;
  readonly prefill: string | null;
  readonly scene: string | null;
  readonly display: ClipboardPromptInfo | null;
  readonly candidates: ClipboardCandidate[];

  constructor(actionRaw: string, uploadText: string | null = null, prefill: string | null = null,
    scene: string | null = null, display: ClipboardPromptInfo | null = null, candidates: ClipboardCandidate[] = []) {
    this.actionRaw = actionRaw;
    this.uploadText = uploadText;
    this.prefill = prefill;
    this.scene = scene;
    this.display = display;
    this.candidates = candidates;
  }
}

/**
 * 系统分享导入（FU-CLIP §2.5 第 3 条；K16～K23）。判定顺序：MIME 不是 text/plain → ignore_mime；未同意当前版本 / 基本模式 → drop（K18）；
 * 敏感路由或浮层（含首启隐私弹窗、强更）→ drop（K19）；parse 在途 → ignore_busy（K22）；文本为空 → home_only；超过 4000 字或没有候选
 * → search_prefill（预填只取「」标题，没有就留空，不拿原文首行）；有候选 → prompt（scene=share_ext，K16）。
 * 不套 24 小时去重、不查自写记录（K21）；不套剪贴板的长度过滤（分享是用户主动动作，HS 段）。
 */
export class ShareImportAction {
  static readonly PROMPT: string = 'prompt';
  static readonly SEARCH_PREFILL: string = 'search_prefill';
  static readonly HOME_ONLY: string = 'home_only';
  static readonly IGNORE_MIME: string = 'ignore_mime';
  static readonly DROP: string = 'drop';
  static readonly IGNORE_BUSY: string = 'ignore_busy';

  static readonly MIME_TEXT: string = 'text/plain';
  static readonly SCENE_SHARE: string = 'share_ext';
  /** ParseInputRequest.text 的上限（契约 1～4000）。 */
  static readonly MAX_TEXT: number = 4000;

  /** 当场抽候选（原文只在这次调用里经过，结果不含原文）。 */
  static payload(mime: string, text: string | null | undefined, rules: ClipboardRules,
    shareDomains: string[]): ShareImportPayload {
    if (mime.toLowerCase() !== ShareImportAction.MIME_TEXT) {
      return new ShareImportPayload(false, false, false, [], null, null, null);
    }
    if (text === null || text === undefined || text.length === 0) {
      return new ShareImportPayload(true, true, false, [], null, null, null);
    }
    if (ClipboardText.codePoints(text) > ShareImportAction.MAX_TEXT) {
      // TODO(N-34) HS 段：超长分享的处理口径未定，按「没有候选」给本地提示、不预填
      return new ShareImportPayload(true, false, true, [], null, null, null);
    }
    const candidates: ClipboardCandidate[] = ClipboardCandidates.extract(text, rules, shareDomains);
    return new ShareImportPayload(true, false, false, candidates, ClipboardCandidates.uploadOf(candidates, text, rules,
      shareDomains), ClipboardTitlePolicy.minimize(ClipboardText.quotedTitle(text), rules, shareDomains),
      ClipboardPromptDisplay.describe(candidates));
  }

  /** state 的键：consent、route、overlay（缺省 none）、parseInFlight（缺省 false）。 */
  static decideWith(state: Record<string, Object>, payload: ShareImportPayload): ShareImportDecision {
    if (!payload.mimeOk) {
      return new ShareImportDecision(ShareImportAction.IGNORE_MIME);
    }
    if (textOf(state['consent']) !== ClipboardReadPolicy.CONSENT_AGREED) {
      return new ShareImportDecision(ShareImportAction.DROP);
    }
    const overlay: string = textOf(state['overlay']) ?? ClipboardSensitive.OVERLAY_NONE;
    if (ClipboardSensitive.sensitive(textOf(state['route']), overlay)) {
      return new ShareImportDecision(ShareImportAction.DROP);
    }
    if (flagOf(state['parseInFlight']) === true) {
      return new ShareImportDecision(ShareImportAction.IGNORE_BUSY);
    }
    if (payload.empty) {
      return new ShareImportDecision(ShareImportAction.HOME_ONLY);
    }
    if (payload.tooLong || payload.uploadText === null || payload.candidates.length === 0) {
      return new ShareImportDecision(ShareImportAction.SEARCH_PREFILL, null, payload.tooLong ? null : payload.prefill);
    }
    return new ShareImportDecision(ShareImportAction.PROMPT, payload.uploadText, payload.prefill,
      ShareImportAction.SCENE_SHARE, payload.display, payload.candidates);
  }

  static decide(state: Record<string, Object>, mime: string, text: string | null | undefined, rules: ClipboardRules,
    shareDomains: string[]): ShareImportDecision {
    return ShareImportAction.decideWith(state, ShareImportAction.payload(mime, text, rules, shareDomains));
  }
}

/**
 * 分享提示条的文字（FU-CLIP §2.6；K26、K28，文案键草稿 TODO(N-34)，取值由调用方的文案来源给：entry 为 ClipboardDraftTexts）：
 * 标题 clipboard.share_prompt「收到分享的{平台}商品，查返利？」；第二行 clipboard.prompt.detail「{平台}商品链接 {缩略主机}」或
 * clipboard.prompt.detail.tpwd「{平台}口令」，多个时加 clipboard.prompt.detail.more「等 {count} 个」；读屏整条读
 * clipboard.share_prompt.label「检测到{平台}商品链接，查返利」（口令为 label_tpwd）。只用缩略候选，不含路径与查询。
 */
export class SharePromptTexts {
  readonly title: string;
  readonly detail: string;
  readonly badge: string;
  readonly label: string;

  constructor(title: string, detail: string, badge: string, label: string) {
    this.title = title;
    this.detail = detail;
    this.badge = badge;
    this.label = label;
  }

  static of(info: ClipboardPromptInfo, format: (key: string, vars: Map<string, string>) => string): SharePromptTexts {
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('platform_name', info.displayName);
    vars.set('display', info.display ?? '');
    vars.set('count', String(info.count));
    const tpwd: boolean = info.labelRaw === ClipboardPromptInfo.LABEL_TPWD || info.display === null;
    let detail: string = format(tpwd ? 'clipboard.prompt.detail.tpwd' : 'clipboard.prompt.detail', vars);
    if (info.count > 1) {
      detail = detail + format('clipboard.prompt.detail.more', vars);
    }
    const title: string = format('clipboard.share_prompt', vars);
    const label: string = format(tpwd ? 'clipboard.share_prompt.label_tpwd' : 'clipboard.share_prompt.label', vars);
    return new SharePromptTexts(title, detail, info.displayName, label);
  }
}
