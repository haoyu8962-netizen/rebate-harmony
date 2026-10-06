import { EntryGuard, RouteLookup } from './EntryGuard';
import { GuardDecision, GuardDecisionKind } from './GuardDecision';
import { GuardState } from './GuardState';
import { RoutePolicy, RouteTable } from './RoutePolicy';
import { emptyParams, RouteRequest, RouteSource } from './RouteRequest';
import { RouteSpec } from 'generated';

/** 按消息编号回查的结果（GET /v1/messages/{message_id}）。 */
export enum PushLookupKind {
  /** 回查成功；route 可能为空。 */
  FOUND = 'found',
  /** 30701：消息不存在或不属于当前账号。 */
  NOT_FOUND = 'not_found',
  /** 请求失败或超时。 */
  FAILED = 'failed'
}

export class PushLookupResult {
  readonly kind: PushLookupKind;
  readonly route: string | null;
  readonly params: Record<string, Object>;

  constructor(kind: PushLookupKind, route: string | null, params: Record<string, Object>) {
    this.kind = kind;
    this.route = route;
    this.params = params;
  }

  static found(route: string | null, params?: Record<string, Object>): PushLookupResult {
    return new PushLookupResult(PushLookupKind.FOUND, route, params === undefined ? emptyParams() : params);
  }

  static notFound(): PushLookupResult {
    return new PushLookupResult(PushLookupKind.NOT_FOUND, null, emptyParams());
  }

  static failed(): PushLookupResult {
    return new PushLookupResult(PushLookupKind.FAILED, null, emptyParams());
  }
}

/** 推送回查函数（由调用方注入；本任务用假实现，APP-03 接网络）。 */
export type PushLookup = (messageId: string) => Promise<PushLookupResult>;

/** 推送点击的落点结论。 */
export class PushLandingResult {
  readonly decision: GuardDecision;
  /** 交给守卫的请求（回查到的 route 或兜底的 Messages）；没有回查时为 null。 */
  readonly request: RouteRequest | null;
  /** 未登录时：登录成功后要打开的请求（Messages，不回查这条消息）。 */
  readonly afterLogin: RouteRequest | null;

  constructor(decision: GuardDecision, request: RouteRequest | null, afterLogin: RouteRequest | null) {
    this.decision = decision;
    this.request = request;
    this.afterLogin = afterLogin;
  }
}

/**
 * 推送点击（03 §4.4「推送点击」，BR-ID-10 细则「推送点击的落点」）：
 * 载荷只带消息编号 → 先过守卫（环境、隐私、强更）→ 已登录时用注入的回查函数取 route → 以 push 入口再过守卫。
 * 未登录：进登录页，登录成功后打开 Messages，不拿这条消息编号回查新登录的账号。
 * 回查失败、超时、30701、route 为空：打开 Messages。
 * 回查是异步的：结果回来时由 Router 用当时最新的 GuardState 再调 resolve（期间的退出登录 / 强更 / 环境变化都生效）。
 */
export class PushLanding {
  /** 推送回查等待上限（03 §4.4，客户端常量）。 */
  static readonly LOOKUP_TIMEOUT_MILLIS: number = 5000;
  private readonly lookup: PushLookup;
  private readonly timeoutMillis: number;

  constructor(lookup: PushLookup, timeoutMillis: number = PushLanding.LOOKUP_TIMEOUT_MILLIS) {
    this.lookup = lookup;
    this.timeoutMillis = timeoutMillis;
  }

  /** 回查（含超时兜底）。返回交给守卫的请求：回查到的 route，或兜底的 Messages。 */
  async lookUp(messageId: string): Promise<RouteRequest> {
    if (messageId.length === 0) {
      return PushLanding.messages();
    }
    const result: PushLookupResult | null | undefined = await this.lookupWithTimeout(messageId);
    // 回查函数返回了空值（实现有误）也按失败兜底。
    if (result !== null && result !== undefined && result.kind === PushLookupKind.FOUND
      && typeof result.route === 'string' && result.route.length > 0) {
      return new RouteRequest(result.route, result.params, RouteSource.PUSH);
    }
    return PushLanding.messages();
  }

  /**
   * 一次完整落点：先用发起时的状态过前置（不满足就不回查），回查结果回来后用 state() 取当时最新的状态重判。
   * isCurrent：发起时的会话 / 环境代次是否仍有效（退出登录、切换账号、切换环境后为 false），失效时丢弃结果返回 null。
   * Router 自己按同样的顺序走（probe → lookUp → 代次核对 → resolve），这里给不经 Router 的调用方用。
   */
  async land(messageId: string, state: () => GuardState, isCurrent: () => boolean = (): boolean => true,
    routes: RouteLookup = PushLanding.buildRoutes): Promise<PushLandingResult | null> {
    const blocked: PushLandingResult | null = PushLanding.probe(state(), routes);
    if (blocked !== null) {
      return blocked;
    }
    const request: RouteRequest = await this.lookUp(messageId);
    if (!isCurrent()) {
      return null;
    }
    return PushLanding.resolve(request, state(), routes);
  }

  /**
   * 回查之前先过守卫里与目标无关的几步：用 Messages 作探针（它只声明 in_app、push，且在只读清单里）。
   * 需要停下（等待、强更、隐私、未登录等）时返回结论；可以回查时返回 null。
   */
  static probe(state: GuardState, routes: RouteLookup = PushLanding.buildRoutes): PushLandingResult | null {
    const probe: GuardDecision = EntryGuard.decide(PushLanding.messages(), state, routes);
    switch (probe.kind) {
      case GuardDecisionKind.DEFER:
      case GuardDecisionKind.FORCE_UPDATE:
      case GuardDecisionKind.REJECT:
      case GuardDecisionKind.REQUIRE_CONSENT:
      case GuardDecisionKind.UPGRADE:
        return new PushLandingResult(probe, null, null);
      case GuardDecisionKind.REQUIRE_LOGIN:
        return new PushLandingResult(probe, null, RouteRequest.of(RoutePolicy.MESSAGES, RouteSource.PENDING_ACTION));
      default:
        return null;
    }
  }

  /** 对回查得到的请求（或兜底的 Messages）按给定状态判定；状态应是结果回来时的最新状态。 */
  static resolve(request: RouteRequest, state: GuardState,
    routes: RouteLookup = PushLanding.buildRoutes): PushLandingResult {
    const blocked: PushLandingResult | null = PushLanding.probe(state, routes);
    if (blocked !== null) {
      return blocked;
    }
    return new PushLandingResult(EntryGuard.decide(request, state, routes), request, null);
  }

  static messages(): RouteRequest {
    return RouteRequest.of(RoutePolicy.MESSAGES, RouteSource.PUSH);
  }

  private static buildRoutes: RouteLookup = (name: string): RouteSpec | undefined => RouteTable.spec(name);

  /**
   * 超时按失败处理；回查函数同步抛错、返回拒绝的 Promise 也按失败（R1-03）。
   * 回查函数经 Promise.resolve().then 调用：同步抛错也变成拒绝，进同一个 catch；任何一种失败都清掉定时器，
   * 本 Promise 只会以结果或 failed 兑现，从不拒绝，调用方照常经守卫打开 Messages。
   */
  private lookupWithTimeout(messageId: string): Promise<PushLookupResult> {
    return new Promise<PushLookupResult>((resolve: (value: PushLookupResult) => void) => {
      let settled: boolean = false;
      const timer: number = setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve(PushLookupResult.failed());
        }
      }, this.timeoutMillis);
      const call: Promise<PushLookupResult> = Promise.resolve()
        .then((): Promise<PushLookupResult> => this.lookup(messageId));
      call.then((result: PushLookupResult) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(result);
        }
      }).catch(() => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(PushLookupResult.failed());
        }
      });
    });
  }
}
