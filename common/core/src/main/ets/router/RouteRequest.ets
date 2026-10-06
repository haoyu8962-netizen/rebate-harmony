import { RouteEntry } from 'generated';

/** 打开请求的来源（任务书 §2）。入口类别看来源，不看请求里的任何标记（03 §4.4、BR-ID-10）。 */
export enum RouteSource {
  IN_APP = 'in_app',
  PUSH = 'push',
  DEEPLINK = 'deeplink',
  BRIDGE = 'bridge',
  PENDING_ACTION = 'pending_action',
  AGENT_CARD = 'agent_card'
}

/** 来源字符串不认识时按 deeplink（最严格的外部入口）处理。 */
export function parseRouteSource(raw: string): RouteSource {
  switch (raw) {
    case RouteSource.IN_APP:
      return RouteSource.IN_APP;
    case RouteSource.PUSH:
      return RouteSource.PUSH;
    case RouteSource.BRIDGE:
      return RouteSource.BRIDGE;
    case RouteSource.PENDING_ACTION:
      return RouteSource.PENDING_ACTION;
    case RouteSource.AGENT_CARD:
      return RouteSource.AGENT_CARD;
    default:
      return RouteSource.DEEPLINK;
  }
}

/**
 * 校验 routes.json `entry` 时用的入口类别：push 只给回查得到的 route，deeplink 是外部直接带来的 route，
 * 其余（原生页面、JSBridge nav.open、Agent 卡片、pending_action 恢复）按 in_app。
 * TODO(N-14): pending_action 恢复时按 in_app 校验（原始来源另记在 PendingAction.origin，rule-gaps G01、G09）。
 */
export function entryOf(source: RouteSource): RouteEntry {
  switch (source) {
    case RouteSource.PUSH:
      return RouteEntry.PUSH;
    case RouteSource.DEEPLINK:
      return RouteEntry.DEEPLINK;
    default:
      return RouteEntry.IN_APP;
  }
}

/** 一次打开请求：路由名 + 参数（JSON 对象）+ 来源。 */
export class RouteRequest {
  readonly route: string;
  readonly params: Record<string, Object>;
  /** 规范化后的来源（未知字符串按 deeplink）。 */
  readonly sourceKind: RouteSource;

  constructor(route: string, params: Record<string, Object>, source: string) {
    this.route = route;
    this.params = params;
    this.sourceKind = parseRouteSource(source);
  }

  /** 来源的取值（任务书 §2）。 */
  get source(): string {
    return this.sourceKind;
  }

  static of(route: string, source: RouteSource, params?: Record<string, Object>): RouteRequest {
    return new RouteRequest(route, params === undefined ? emptyParams() : params, source);
  }
}

export function emptyParams(): Record<string, Object> {
  const empty: Record<string, Object> = {};
  return empty;
}

export function paramCount(params: Record<string, Object>): number {
  return Object.keys(params).length;
}
