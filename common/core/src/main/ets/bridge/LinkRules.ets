import { devOriginDefaultPort } from 'core/ets/bridge/DevOrigins';
import { BridgeJson, BridgeSchema } from './BridgeSchema';

/**
 * origin 的比较口径（03 §5.2「origin 的比较口径」，三端相同）：只认 https；主机名转小写后逐字相等，不做子域通配；端口按默认
 * 端口 443 规范化后相等。Debug / Staging 构建另有本机一致性测试源的口径（core 的 src/staging/ets/bridge/DevOrigins.ets，
 * 是否放行仍只看白名单）；Release 编译的是 src/release 的同名文件，不认任何非 https origin（R1-02，release-scan 检查）。
 */
export class OriginRules {

  /** `scheme://host[:port]` → 规范化 origin；不是可比较的 origin（opaque「null」、带用户信息、非 https 非回环等）为 null。 */
  static normalize(origin: string): string | null {
    const match: RegExpMatchArray | null = origin.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)$/);
    if (match === null) {
      return null;
    }
    return OriginRules.build(match[1] ?? '', match[2] ?? '');
  }

  /** 完整 URL 的 origin（规范化）；解析不了为 null。 */
  static ofUrl(url: string): string | null {
    const match: RegExpMatchArray | null = url.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([/?#].*)?$/);
    if (match === null) {
      return null;
    }
    return OriginRules.build(match[1] ?? '', match[2] ?? '');
  }

  /** 规范化后在白名单（每项也按同一口径规范化）里。 */
  static allowed(origin: string, trusted: string[]): boolean {
    const normalized: string | null = OriginRules.normalize(origin);
    if (normalized === null) {
      return false;
    }
    for (const entry of trusted) {
      if (OriginRules.normalize(entry) === normalized) {
        return true;
      }
    }
    return false;
  }

  private static build(schemeRaw: string, authority: string): string | null {
    const scheme: string = schemeRaw.toLowerCase();
    if (authority.length === 0 || authority.indexOf('@') >= 0) {
      return null;
    }
    const hostPort: RegExpMatchArray | null = authority.match(/^([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?$/);
    if (hostPort === null) {
      return null;
    }
    const host: string = (hostPort[1] ?? '').toLowerCase();
    if (host.length === 0 || host.startsWith('.') || host.endsWith('.') || host.indexOf('..') >= 0) {
      return null;
    }
    let defaultPort: number;
    if (scheme === 'https') {
      defaultPort = 443;
    } else {
      const devPort: number | null = devOriginDefaultPort(scheme, host);
      if (devPort === null) {
        return null;
      }
      defaultPort = devPort;
    }
    const portText: string | undefined = hostPort[2];
    let port: number = defaultPort;
    if (portText !== undefined && portText.length > 0) {
      port = Number.parseInt(portText, 10);
      if (port < 1 || port > 65535) {
        return null;
      }
    }
    return port === defaultPort ? scheme + '://' + host : scheme + '://' + host + ':' + port;
  }
}

/**
 * 浏览器口径的 URL 解析（WHATWG URL Standard 的「特殊 scheme」子集；APP-04 R2-05）。@kit.ArkTS 的 url.URL 在本机单测里
 * 不可用（Local Test 没有该原生模块），判定又必须单测可证，所以按标准自己实现、生产与测试同一份代码：
 * - 去掉首尾的 C0 控制字符与空格，删掉所有 Tab、LF、CR；
 * - 只认 http、https；scheme 后面不论几个 / 或 \ 都跳过（special authority ignore slashes）；
 * - authority 到第一个 / \ ? # 为止；带用户信息（@）、IPv6 字面量一律解析不了（保守）；
 * - 主机：百分号解码一次后转小写，只允许 ASCII 字母数字与 . - _（非 ASCII 主机、禁用字符解析不了）；最后一个标签是数字形态
 *   （十进制或 0x）时必须是规范的点分十进制 IPv4，否则解析不了；
 * - 端口：只有数字（可为空），超 65535 解析不了，等于默认端口（https 443、http 80）记为 null；
 * - 路径：\ 当 /；点段「.」「%2e」与双点段「..」「.%2e」「%2e.」「%2e%2e」（不分大小写）按 path state 消除，与浏览器
 *   实际请求的路径一致；其余字符保持原样（不解码）。
 */
export class StandardUrl {
  readonly scheme: string;
  /** 小写、已解码；保留末尾的点（与浏览器一致）。 */
  readonly host: string;
  /** 非默认端口；默认端口与缺省为 null。 */
  readonly port: number | null;
  /** 消除点段后的路径（以 / 开头，未解码）。 */
  readonly path: string;
  /** ? 之后、# 之前（不含 ?）；没有为 null。 */
  readonly query: string | null;

  constructor(scheme: string, host: string, port: number | null, path: string, query: string | null) {
    this.scheme = scheme;
    this.host = host;
    this.port = port;
    this.path = path;
    this.query = query;
  }

  /** `scheme://host[:port]`（默认端口省略；主机去掉末尾的点）。 */
  get origin(): string {
    const host: string = this.host.endsWith('.') ? this.host.substring(0, this.host.length - 1) : this.host;
    return this.scheme + '://' + host + (this.port === null ? '' : ':' + this.port);
  }

  static parse(input: string): StandardUrl | null {
    if (typeof input !== 'string') {
      return null;
    }
    const text: string = input.replace(/^[\u0000-\u0020]+/, '').replace(/[\u0000-\u0020]+$/, '')
      .replace(/[\t\n\r]/g, '');
    const m: RegExpMatchArray | null = text.match(/^([A-Za-z][A-Za-z0-9+.-]*):([\s\S]*)$/);
    if (m === null) {
      return null;
    }
    const scheme: string = (m[1] ?? '').toLowerCase();
    if (scheme !== 'https' && scheme !== 'http') {
      return null;
    }
    let rest: string = m[2] ?? '';
    let i: number = 0;
    while (i < rest.length && (rest.charAt(i) === '/' || rest.charAt(i) === '\\')) {
      i++;
    }
    rest = rest.substring(i);
    let end: number = rest.length;
    for (let k = 0; k < rest.length; k++) {
      const c: string = rest.charAt(k);
      if (c === '/' || c === '\\' || c === '?' || c === '#') {
        end = k;
        break;
      }
    }
    const authority: string = rest.substring(0, end);
    let tail: string = rest.substring(end);
    if (authority.length === 0 || authority.indexOf('@') >= 0 || authority.indexOf('[') >= 0) {
      return null;
    }
    const colon: number = authority.lastIndexOf(':');
    const hostRaw: string = colon >= 0 ? authority.substring(0, colon) : authority;
    const portText: string = colon >= 0 ? authority.substring(colon + 1) : '';
    const host: string | null = StandardUrl.parseHost(hostRaw);
    if (host === null) {
      return null;
    }
    let port: number | null = null;
    if (portText.length > 0) {
      if (!/^[0-9]+$/.test(portText)) {
        return null;
      }
      const value: number = Number.parseInt(portText, 10);
      if (!(value >= 0 && value <= 65535)) {
        return null;
      }
      port = value === (scheme === 'https' ? 443 : 80) ? null : value;
    }
    const hash: number = tail.indexOf('#');
    if (hash >= 0) {
      tail = tail.substring(0, hash);
    }
    const q: number = tail.indexOf('?');
    const query: string | null = q >= 0 ? tail.substring(q + 1) : null;
    const rawPath: string = q >= 0 ? tail.substring(0, q) : tail;
    return new StandardUrl(scheme, host, port, StandardUrl.normalizePath(rawPath), query);
  }

  /** WHATWG path state（特殊 scheme）：\ 当 /，消除单点段与双点段（含编码形态）。结果以 / 开头。 */
  static normalizePath(raw: string): string {
    const text: string = raw.replace(/\\/g, '/');
    const body: string = text.startsWith('/') ? text.substring(1) : text;
    const segments: string[] = body.split('/');
    const out: string[] = [];
    for (let k = 0; k < segments.length; k++) {
      const segment: string = segments[k];
      const last: boolean = k === segments.length - 1;
      const lower: string = segment.toLowerCase();
      if (lower === '..' || lower === '.%2e' || lower === '%2e.' || lower === '%2e%2e') {
        if (out.length > 0) {
          out.pop();
        }
        if (last) {
          out.push('');
        }
      } else if (lower === '.' || lower === '%2e') {
        if (last) {
          out.push('');
        }
      } else {
        out.push(segment);
      }
    }
    return '/' + out.join('/');
  }

  /** 主机：百分号解码一次 → 小写 → 字符集与数字形态检查；不合格为 null。 */
  private static parseHost(raw: string): string | null {
    let host: string;
    try {
      host = decodeURIComponent(raw).toLowerCase();
    } catch (e) {
      return null;
    }
    if (host.length === 0 || !/^[a-z0-9._-]+$/.test(host)) {
      return null;
    }
    const labels: string[] = host.split('.');
    if (labels.length > 1 && labels[labels.length - 1] === '') {
      labels.pop();
    }
    const lastLabel: string = labels[labels.length - 1] ?? '';
    if (/^(0x[0-9a-f]*|[0-9]+)$/.test(lastLabel)) {
      if (labels.length !== 4) {
        return null;
      }
      for (const label of labels) {
        if (!/^(0|[1-9][0-9]{0,2})$/.test(label) || Number.parseInt(label, 10) > 255) {
          return null;
        }
      }
    }
    return host;
  }
}

/** 规范化后的 https 地址（BR-ATTR-29 细则「桥方法不留没有归因的打开入口」第 1 步）。 */
export class NormalizedHttpsUrl {
  /** 小写、去掉末尾的点。 */
  readonly host: string;
  /** 非默认端口；443 与缺省为 null。 */
  readonly port: number | null;
  /** 浏览器口径消除点段后、再百分号解码一次的路径（空路径为 /）。 */
  readonly path: string;
  /**
   * 参与规则匹配的路径：path，以及 path 解码后又出现点段（如 %2F..%2F）时再消除一次的形态（保守：任一形态命中都算命中）。
   */
  readonly paths: string[];
  /** ? 之后、# 之前（不含 ?，未解码）；没有为 null。 */
  readonly query: string | null;

  constructor(host: string, port: number | null, path: string, query: string | null = null) {
    this.host = host;
    this.port = port;
    this.path = path;
    const again: string = StandardUrl.normalizePath(path);
    this.paths = again === path ? [path] : [path, again];
    this.query = query;
  }

  /**
   * 标准解析（StandardUrl，浏览器口径，R2-05）：解析不了、不是 https、带用户信息的为 null；主机名转小写、去掉末尾的「.」；
   * 端口 443 去掉；路径先消除点段（含编码点段与反斜杠），再做一次百分号解码（解码失败按解析不了）。
   */
  static parse(url: string): NormalizedHttpsUrl | null {
    const std: StandardUrl | null = StandardUrl.parse(url);
    if (std === null || std.scheme !== 'https') {
      return null;
    }
    let host: string = std.host;
    if (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (host.length === 0 || host.startsWith('.') || host.endsWith('.') || host.indexOf('..') >= 0) {
      return null;
    }
    let path: string;
    try {
      path = decodeURIComponent(std.path);
    } catch (e) {
      return null;
    }
    return new NormalizedHttpsUrl(host, std.port, path, std.query);
  }
}

/** link_patterns 的一条规则（openapi LinkPatternRule：platform × category × hosts × path_patterns）。 */
export class LinkRule {
  readonly platform: string;
  readonly category: string;
  readonly hosts: string[];
  readonly pathPatterns: string[];
  /** 编译好的路径正则（LinkRuleTable.parse 已保证全部能编译）。 */
  private readonly compiled: RegExp[];

  constructor(platform: string, category: string, hosts: string[], pathPatterns: string[]) {
    this.platform = platform;
    this.category = category;
    this.hosts = hosts;
    this.pathPatterns = pathPatterns;
    const compiled: RegExp[] = [];
    for (const pattern of pathPatterns) {
      const re: RegExp | null = LinkRule.compile(pattern);
      if (re !== null) {
        compiled.push(re);
      }
    }
    this.compiled = compiled;
  }

  /** 编译一条路径正则（Unicode 模式）；编译不了为 null。 */
  static compile(pattern: string): RegExp | null {
    try {
      return new RegExp(pattern, 'u');
    } catch (e) {
      return null;
    }
  }

  /** 主机按注册域匹配（等于或是其子域，有点边界）。 */
  hostMatches(host: string): boolean {
    for (const h of this.hosts) {
      const rule: string = h.toLowerCase();
      if (rule.length > 0 && (host === rule || host.endsWith('.' + rule))) {
        return true;
      }
    }
    return false;
  }

  /**
   * 路径模式：空表示任意路径；否则任一正则命中。正则在建表时整表校验（R2-06），这里不会遇到坏正则；万一编译失败的条目
   * 数量对不上（不应发生），按命中处理（保守）。
   */
  pathMatches(path: string): boolean {
    if (this.pathPatterns.length === 0 || this.compiled.length !== this.pathPatterns.length) {
      return true;
    }
    for (const re of this.compiled) {
      re.lastIndex = 0;
      if (re.test(path)) {
        return true;
      }
    }
    return false;
  }

  /** union_host 按注册域整域阻断（R2-06：不看路径规则）；其余类别看主机 + 路径。 */
  matches(host: string, path: string): boolean {
    if (!this.hostMatches(host)) {
      return false;
    }
    return this.category === LinkRuleTable.UNION_HOST || this.pathMatches(path);
  }
}

/** 一张完整的平台链接形态表（BR-ATTR-29；03 §4.3 取用顺序由调用方决定）。 */
export class LinkRuleTable {
  static readonly UNION_HOST: string = 'union_host';
  static readonly PRODUCT: string = 'product';
  static readonly PROMO: string = 'promo';
  static readonly CATEGORIES: string[] = [LinkRuleTable.PRODUCT, LinkRuleTable.PROMO, LinkRuleTable.UNION_HOST];

  readonly version: string;
  readonly rules: LinkRule[];

  constructor(version: string, rules: LinkRule[]) {
    this.version = version;
    this.rules = rules;
  }

  /**
   * 完整且每条规则都合格的表（openapi ConfigLinkPatterns / LinkPatternRule，见 LinkRuleTable.valid）；否则 null（R2-06：
   * 坏表整表不用，调用方回落到上一次成功或包内表，都不可用时按拦下处理）。
   */
  static parse(json: string | null): LinkRuleTable | null {
    if (json === null) {
      return null;
    }
    let root: BridgeJson | null = null;
    try {
      root = BridgeSchema.objectOf(JSON.parse(json) as Object);
    } catch (e) {
      return null;
    }
    if (root === null || !LinkRuleTable.valid(root)) {
      return null;
    }
    const out: LinkRule[] = [];
    for (const item of root['rules'] as Object[]) {
      const obj: BridgeJson = BridgeSchema.objectOf(item) as BridgeJson;
      out.push(new LinkRule(obj['platform'] as string, obj['category'] as string, obj['hosts'] as string[],
        obj['path_patterns'] as string[]));
    }
    return new LinkRuleTable(root['version'] as string, out);
  }

  /**
   * 整表校验（openapi ConfigLinkPatterns，additionalProperties=false）：只有 version（非空字符串）与 rules（数组）；每条规则
   * 只有 platform（非空字符串）、category（product / promo / union_host）、hosts（非空字符串数组，每项是主机名）、
   * path_patterns（非空字符串数组，每项能编译为 Unicode 正则）。任一不合格整表不合格。ConfigStore 取层时用同一校验。
   */
  static valid(root: Record<string, Object>): boolean {
    for (const key of Object.keys(root)) {
      if (key !== 'version' && key !== 'rules') {
        return false;
      }
    }
    const version: Object | undefined = root['version'];
    const rules: Object | undefined = root['rules'];
    if (typeof version !== 'string' || (version as string).length === 0 || rules === undefined || rules === null
      || !Array.isArray(rules)) {
      return false;
    }
    for (const item of rules as Object[]) {
      if (!LinkRuleTable.validRule(item)) {
        return false;
      }
    }
    return true;
  }

  private static validRule(item: Object | null): boolean {
    const obj: BridgeJson | null = BridgeSchema.objectOf(item);
    if (obj === null) {
      return false;
    }
    for (const key of Object.keys(obj)) {
      if (key !== 'platform' && key !== 'category' && key !== 'hosts' && key !== 'path_patterns') {
        return false;
      }
    }
    const platform: Object | undefined = obj['platform'];
    const category: Object | undefined = obj['category'];
    if (typeof platform !== 'string' || (platform as string).length === 0 || typeof category !== 'string'
      || LinkRuleTable.CATEGORIES.indexOf(category as string) < 0) {
      return false;
    }
    const hosts: string[] | null = LinkRuleTable.strings(obj['hosts']);
    const paths: string[] | null = LinkRuleTable.strings(obj['path_patterns']);
    if (hosts === null || paths === null) {
      return false;
    }
    for (const host of hosts) {
      if (!/^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/.test(host)) {
        return false;
      }
    }
    for (const pattern of paths) {
      if (LinkRule.compile(pattern) === null) {
        return false;
      }
    }
    return true;
  }

  /** 表里有没有至少一条联盟平台网页域名规则（没有时视为不能判定，调用方按拦下处理，TODO(N-21)）。 */
  get hasUnionHosts(): boolean {
    for (const rule of this.rules) {
      if (rule.category === LinkRuleTable.UNION_HOST && rule.hosts.length > 0) {
        return true;
      }
    }
    return false;
  }

  /** 命中给定类别中任一条的第一条规则；不命中为 null。 */
  firstMatch(host: string, path: string, categories: string[]): LinkRule | null {
    for (const rule of this.rules) {
      if (categories.indexOf(rule.category) >= 0 && rule.matches(host, path)) {
        return rule;
      }
    }
    return null;
  }

  /** 规范化地址的任一路径形态（NormalizedHttpsUrl.paths）命中给定类别的第一条规则；不命中为 null。 */
  matchUrl(target: NormalizedHttpsUrl, categories: string[]): LinkRule | null {
    for (const path of target.paths) {
      const hit: LinkRule | null = this.firstMatch(target.host, path, categories);
      if (hit !== null) {
        return hit;
      }
    }
    return null;
  }

  /** 字符串数组且每项非空；否则 null。 */
  private static strings(value: Object | undefined): string[] | null {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return null;
    }
    const out: string[] = [];
    for (const v of value as Object[]) {
      if (typeof v !== 'string' || (v as string).length === 0) {
        return null;
      }
      out.push(v as string);
    }
    return out;
  }
}
