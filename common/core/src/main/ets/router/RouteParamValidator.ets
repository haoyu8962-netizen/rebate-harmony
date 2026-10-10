import { RouteParamSpec, RouteParamType, RouteSpec } from 'generated';
import { RouteTargetAllowlist } from './GuardState';
import { RoutePolicy } from './RoutePolicy';
import { RouteSource } from './RouteRequest';
import { HomeActionJson } from '../home/HomePolicies';

/**
 * routes.json params 的 JSON Schema 校验（03 §4.4「统一入口守卫」：所有来源都校验参数）。
 * 只认生成器支持的关键字：type、enum、minLength、maxLength、pattern、required、additionalProperties。
 */
export class RouteParamValidator {
  static isValid(params: Record<string, Object>, spec: RouteSpec): boolean {
    for (const name of spec.requiredParams) {
      if (!RouteParamValidator.present(params, name)) {
        return false;
      }
    }
    for (const name of Object.keys(params)) {
      const param: RouteParamSpec | undefined = spec.param(name);
      if (param === undefined) {
        if (spec.additionalParams) {
          continue;
        }
        return false;
      }
      if (!RouteParamValidator.isValidValue(params[name], param)) {
        return false;
      }
    }
    return true;
  }

  static isValidValue(raw: Object | null | undefined, param: RouteParamSpec): boolean {
    if (raw === null || raw === undefined) {
      return false;
    }
    const value: Object = raw;
    if (!RouteParamValidator.matchesType(value, param.type)) {
      return false;
    }
    if (typeof value !== 'string') {
      return param.enumValues === null;
    }
    const text: string = value as string;
    if (param.enumValues !== null && param.enumValues.indexOf(text) < 0) {
      return false;
    }
    // JSON Schema 的长度按 Unicode 码点计。
    const length: number = RouteParamValidator.codePointLength(text);
    if (param.minLength !== null && length < param.minLength) {
      return false;
    }
    if (param.maxLength !== null && length > param.maxLength) {
      return false;
    }
    if (param.pattern !== null && !new RegExp(param.pattern, 'u').test(text)) {
      return false;
    }
    return true;
  }

  static codePointLength(text: string): number {
    let count: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const next: number = text.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          i++;
        }
      }
      count++;
    }
    return count;
  }

  private static present(params: Record<string, Object>, name: string): boolean {
    if (Object.keys(params).indexOf(name) < 0) {
      return false;
    }
    const value: Object | null | undefined = params[name];
    return value !== null && value !== undefined;
  }

  private static matchesType(value: Object, type: RouteParamType): boolean {
    switch (type) {
      case RouteParamType.STRING:
        return typeof value === 'string';
      case RouteParamType.BOOLEAN:
        return typeof value === 'boolean';
      case RouteParamType.NUMBER:
        return typeof value === 'number' && Number.isFinite(value as number);
      case RouteParamType.INTEGER:
        return typeof value === 'number' && Number.isInteger(value as number);
      case RouteParamType.ARRAY:
        return Array.isArray(value);
      case RouteParamType.OBJECT:
        return typeof value === 'object' && !Array.isArray(value);
      default:
        return false;
    }
  }
}

/** 解析出的 https 目标：主机名小写，默认端口 443 归一为无端口。 */
export class HttpsTarget {
  readonly host: string;
  readonly port: number | null;

  constructor(host: string, port: number | null) {
    this.host = host;
    this.port = port;
  }

  get origin(): string {
    return this.port === null ? 'https://' + this.host : 'https://' + this.host + ':' + this.port;
  }

  /** 只认 https、无用户信息、有主机名的绝对地址；其余返回 null。 */
  static parse(text: string): HttpsTarget | null {
    const match: RegExpMatchArray | null = text.match(/^https:\/\/([^/?#]*)([/?#].*)?$/i);
    if (match === null) {
      return null;
    }
    const authority: string = match[1] ?? '';
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
    const portText: string | undefined = hostPort[2];
    let port: number | null = null;
    if (portText !== undefined && portText.length > 0) {
      port = Number.parseInt(portText, 10);
      if (port < 1 || port > 65535) {
        return null;
      }
      if (port === 443) {
        port = null;
      }
    }
    return new HttpsTarget(host, port);
  }
}

/**
 * ExternalPage / WebPage 的目标地址白名单（03 §4.4「入口限制」，BR-ID-10 细则）：
 * - WebPage：任何来源都只认 bridge_origins 白名单内的 https origin；
 * - ExternalPage：external_hosts 只约束深链入口（03 §4.4：「这张白名单只决定深链能不能进入 ExternalPage」）。App 内、
 *   推送回查、JSBridge 与可信页的跨域跳转（03 §5.1：跳到白名单外的 https 在新的 ExternalWebView 打开）不受这张表限制，只要
 *   求是可解析的 https 地址；进入之后第一个 URL 与每一次导航仍由容器的 ExternalNavPolicy 判定（APP-04 R1-10）。
 *   pending_action 恢复（原始来源可能是深链，TODO(N-14)）与 Agent 卡片仍按深链口径。
 */
export class RouteTargetCheck {
  /**
   * APP-11（G05，rule-gaps H01）：首页卡片动作的形状解码。只认 {route: 非空字符串, params?: 对象}，其余字段（url、js、scheme…）忽略；
   * 形状不对为 null。不查路由表（未知名称、since 交 Router）。实现在 home/HomeJson。
   */
  static decode(json: Record<string, Object | null> | null): Record<string, Object | null> | null {
    return HomeActionJson.of(json);
  }

  /** 该路由的目标地址是否在白名单内；不是这两个路由时恒为 true。source 不认识时按深链（最严格）。 */
  static isAllowed(route: string, params: Record<string, Object>, allowlist: RouteTargetAllowlist,
    source: RouteSource = RouteSource.DEEPLINK): boolean {
    if (route !== RoutePolicy.EXTERNAL_PAGE && route !== RoutePolicy.WEB_PAGE) {
      return true;
    }
    const raw: Object | null | undefined = params['url'];
    if (typeof raw !== 'string') {
      return false;
    }
    const target: HttpsTarget | null = HttpsTarget.parse(raw as string);
    if (target === null) {
      return false;
    }
    if (route === RoutePolicy.EXTERNAL_PAGE) {
      if (source === RouteSource.IN_APP || source === RouteSource.PUSH || source === RouteSource.BRIDGE) {
        return true;
      }
      // 深链（以及来源说不清的 pending_action 恢复、Agent 卡片，按最严格的深链口径）：完整主机名匹配；带非默认端口的地址不按主机名放行。
      if (target.port !== null) {
        return false;
      }
      for (const host of allowlist.externalHosts) {
        if (host.toLowerCase() === target.host) {
          return true;
        }
      }
      return false;
    }
    for (const origin of allowlist.bridgeOrigins) {
      const allowed: HttpsTarget | null = HttpsTarget.parse(origin);
      if (allowed !== null && allowed.origin === target.origin) {
        return true;
      }
    }
    return false;
  }
}
