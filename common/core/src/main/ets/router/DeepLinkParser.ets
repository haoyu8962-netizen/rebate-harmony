import { RouteParamSpec, RouteParamType, RouteSpec } from 'generated';
import { RouteLookup } from './EntryGuard';
import { RouteParamValidator } from './RouteParamValidator';
import { RouteTable } from './RoutePolicy';
import { RouteRequest, RouteSource } from './RouteRequest';

/**
 * 入站链接配置：自定义 scheme 与 `l.<主域>` 链接域名（apps.json 入站回调类，03 §4.4）。
 * 由调用方传入，解析器不内建任何 scheme 或域名（apps.json inbound 当前为空，needs N-05）。
 */
export class DeepLinkConfig {
  static readonly EMPTY: DeepLinkConfig = new DeepLinkConfig([], []);
  readonly schemes: string[];
  readonly hosts: string[];

  constructor(schemes: string[], hosts: string[]) {
    this.schemes = schemes;
    this.hosts = hosts;
  }
}

const URL_SHAPE: RegExp = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(?:\?([^#]*))?(#.*)?$/;
const ROUTE_NAME: RegExp = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;

/**
 * 深链解析（03 §4.4「深链」）。只认两种形状，其余一律返回 null：
 * - `https://<hosts 之一>/r/<name>?<params>`（经验证的网页链接；不认 http）
 * - `<schemes 之一>://r/<name>?<params>`
 * 参数按 routes.json 的 params schema 校验（类型、枚举、长度、pattern、必填、多余参数）；
 * 查询参数一律是字符串，不做数字或布尔转换。路由名不在表里时不校验参数、照常返回，由守卫进升级提示。
 */
export class DeepLinkParser {
  /** TODO(N-14): 整个 URL 的长度上限规划未定（rule-gaps G05），先取保守值。 */
  static readonly MAX_URL_LENGTH: number = 4096;

  static parse(url: string, config: DeepLinkConfig,
    routes: RouteLookup = (name: string): RouteSpec | undefined => RouteTable.spec(name)): RouteRequest | null {
    if (url.length === 0 || url.length > DeepLinkParser.MAX_URL_LENGTH || /[\s\u0000-\u001f\u007f]/.test(url)) {
      return null;
    }
    const match: RegExpMatchArray | null = url.match(URL_SHAPE);
    // TODO(N-14): fragment 的处理未定（rule-gaps G05），保守拒绝。
    if (match === null || match[5] !== undefined) {
      return null;
    }
    const scheme: string = (match[1] ?? '').toLowerCase();
    const authority: string = (match[2] ?? '').toLowerCase();
    const path: string = match[3] ?? '';
    // 不认用户信息与端口。
    if (authority.length === 0 || authority.indexOf('@') >= 0 || authority.indexOf(':') >= 0) {
      return null;
    }
    let name: string;
    if (scheme === 'https') {
      if (!DeepLinkParser.containsIgnoreCase(config.hosts, authority) || !path.startsWith('/r/')) {
        return null;
      }
      name = path.substring(3);
    } else {
      const custom: string[] = config.schemes.filter((s: string) => {
        const lower: string = s.toLowerCase();
        return lower !== 'https' && lower !== 'http';
      });
      if (!DeepLinkParser.containsIgnoreCase(custom, scheme) || authority !== 'r' || !path.startsWith('/')) {
        return null;
      }
      name = path.substring(1);
    }
    if (!ROUTE_NAME.test(name)) {
      return null;
    }
    const params: Record<string, Object> | null = DeepLinkParser.parseQuery(match[4]);
    if (params === null) {
      return null;
    }
    const spec: RouteSpec | undefined = routes(name);
    if (spec !== undefined && !DeepLinkParser.valid(params, spec)) {
      return null;
    }
    return new RouteRequest(name, params, RouteSource.DEEPLINK);
  }

  /** 按 routes.json params schema 校验查询参数（值都是字符串；声明为对象、数字等类型的参数不能从深链进入）。 */
  static valid(params: Record<string, Object>, spec: RouteSpec): boolean {
    for (const key of Object.keys(params)) {
      const param: RouteParamSpec | undefined = spec.param(key);
      if (param !== undefined && param.type !== RouteParamType.STRING) {
        return false;
      }
    }
    return RouteParamValidator.isValid(params, spec);
  }

  /** 空键、没有 `=`、重复键、百分号编码非法：整条拒绝（TODO(N-14) rule-gaps G05）。`+` 按字面保留。 */
  private static parseQuery(query: string | undefined): Record<string, Object> | null {
    const params: Record<string, Object> = {};
    if (query === undefined || query.length === 0) {
      return params;
    }
    const seen: string[] = [];
    for (const item of query.split('&')) {
      const eq: number = item.indexOf('=');
      if (eq <= 0) {
        return null;
      }
      const key: string | null = DeepLinkParser.decode(item.substring(0, eq));
      const value: string | null = DeepLinkParser.decode(item.substring(eq + 1));
      if (key === null || value === null || key.length === 0 || seen.indexOf(key) >= 0) {
        return null;
      }
      seen.push(key);
      params[key] = value;
    }
    return params;
  }

  private static decode(text: string): string | null {
    try {
      return decodeURIComponent(text);
    } catch (e) {
      return null;
    }
  }

  private static containsIgnoreCase(list: string[], value: string): boolean {
    for (const item of list) {
      if (item.toLowerCase() === value) {
        return true;
      }
    }
    return false;
  }
}
