import { RouteSpec } from 'generated';
import { GuardDecision, GuardDecisionKind, GuardReason } from './GuardDecision';
import { GuardState, PrivacyState, SessionState, UpdateState } from './GuardState';
import { RouteParamValidator, RouteTargetCheck } from './RouteParamValidator';
import { AppVersion, RoutePolicy, RouteTable } from './RoutePolicy';
import { emptyParams, entryOf, paramCount, RouteRequest, RouteSource } from './RouteRequest';

/** 按路由名取 RouteSpec；缺省为本构建的 RouteTable（Release 只有 Routes.all）。 */
export type RouteLookup = (name: string) => RouteSpec | undefined;

const BUILD_ROUTES: RouteLookup = (name: string): RouteSpec | undefined => RouteTable.spec(name);

/**
 * 统一入口守卫（03 §4.4「统一入口守卫」「入口限制」，BR-ID-10、BR-ID-02、BR-ID-11、BR-ID-01）。
 * 纯函数：同样的请求与状态得到同样的结论，不读写任何存储、不导航。
 *
 * 判定顺序：环境 → 隐私闸门（未决 / 基本模式）→ 低于最低版本 → 路由是否存在与 since →
 * 入口 → Agent 卡片 → 参数 schema 与外部网页白名单 → 强更结果未知时的只读清单 → 登录、绑手机与实名 → 打开。
 */
export class EntryGuard {
  static decide(request: RouteRequest, state: GuardState, routes: RouteLookup = BUILD_ROUTES): GuardDecision {
    // 环境未 settled：一律不放行业务路由，等待（EnvironmentGate）。
    if (!state.environmentSettled) {
      return EntryGuard.wait(GuardReason.ENVIRONMENT_UNSETTLED);
    }
    const privacy: GuardDecision | null = EntryGuard.privacyGate(request, state);
    if (privacy !== null) {
      return privacy;
    }
    // 低于最低支持版本：只放行从强更页主动进入的次要入口（03 §4.1）。
    if (state.updateState === UpdateState.BELOW_MIN) {
      return EntryGuard.decideBelowMinimum(request, state, routes);
    }
    // 未知路由、Release 里的 debug_only 名称、since 为 null（未发布）或高于本端版本：升级提示。
    const upgrade: GuardDecision | null = EntryGuard.availability(request.route, state, routes);
    if (upgrade !== null) {
      return upgrade;
    }
    const spec: RouteSpec = routes(request.route) as RouteSpec;
    const entry: GuardDecision | null = EntryGuard.entryCheck(request, spec, state, routes);
    if (entry !== null) {
      return entry;
    }
    const params: GuardDecision | null = EntryGuard.paramsCheck(request, spec, state);
    if (params !== null) {
      return params;
    }
    const readonly: GuardDecision | null = EntryGuard.readonlyCheck(request, state, routes);
    if (readonly !== null) {
      return readonly;
    }
    const prerequisite: GuardDecision | null = EntryGuard.authPrerequisite(spec.auth, state);
    if (prerequisite !== null) {
      return prerequisite;
    }
    return EntryGuard.openDecision(request, state);
  }

  /**
   * 守卫校验与打开时实际使用的参数：资金与实名页面先丢弃全部参数（03 §4.4「资金与实名页面」）；注销页同样丢弃（APP-13a §0 第 3 条，
   * 不记 route_params_dropped，G21）。
   */
  static effectiveParams(request: RouteRequest): Record<string, Object> {
    return RoutePolicy.dropsAllParams(request.route) ? emptyParams() : request.params;
  }

  /**
   * 强更检查结果未知时，外部带进来的请求与自动执行的动作只开只读清单；
   * 用户在原生页面上自己的操作（in_app）不受影响（03 §4.1、§4.4 表格「未知」一行）。
   */
  private static readonlyByUpdate(request: RouteRequest, state: GuardState): boolean {
    return state.updateState === UpdateState.UNKNOWN && request.sourceKind !== RouteSource.IN_APP;
  }

  /** 隐私闸门：未决与基本模式。放行返回 null。 */
  private static privacyGate(request: RouteRequest, state: GuardState): GuardDecision | null {
    const source: RouteSource = request.sourceKind;
    if (state.privacyState === PrivacyState.NOT_DECIDED) {
      if (source === RouteSource.AGENT_CARD) {
        // Agent 卡片：先补同意，同意后不自动补打开（BR-ID-10 Agent 卡片 ②）。
        return new GuardDecision(GuardDecisionKind.REQUIRE_CONSENT, null, GuardReason.AGENT_CONSENT_NO_REPLAY);
      }
      if (source === RouteSource.IN_APP && RoutePolicy.PRIVACY_UNDECIDED_READONLY_ROUTES.indexOf(request.route) >= 0) {
        // 首启弹窗、二次说明里的《隐私政策》《用户协议》等链接（APP-02b）：同意前只读看协议文本（BR-ID-11）；
        // 其余检查（存在、入口、参数）照常，最后按只读打开（openDecision）。
        return null;
      }
      // TODO(N-14): 其余 in_app 在首启弹窗有结论之前不应出现，这里同样按等待处理（rule-gaps G11）。
      return EntryGuard.wait(GuardReason.PRIVACY_UNDECIDED);
    }
    if (state.privacyState === PrivacyState.BASIC_MODE) {
      if (RoutePolicy.BASIC_MODE_ROUTES.indexOf(request.route) >= 0) {
        return null;
      }
      if (source === RouteSource.IN_APP) {
        return new GuardDecision(GuardDecisionKind.REQUIRE_CONSENT, null, GuardReason.CONSENT_REQUIRED);
      }
      // 外部或自动入口：丢弃，不因此自动弹隐私弹窗（BR-ID-11）。
      return EntryGuard.reject(GuardReason.BASIC_MODE_BLOCKED);
    }
    return null;
  }

  /** 入口限制、Agent 卡片限制。放行返回 null。 */
  private static entryCheck(request: RouteRequest, spec: RouteSpec, state: GuardState,
    routes: RouteLookup): GuardDecision | null {
    const source: RouteSource = request.sourceKind;
    if (spec.entries.indexOf(entryOf(source)) < 0) {
      if (source !== RouteSource.PUSH) {
        return EntryGuard.reject(GuardReason.ENTRY_NOT_ALLOWED);
      }
      // 推送回查到的 route 没有声明 push：改开 Messages（BR-ID-10），Messages 本身照样过守卫。
      return EntryGuard.pushFallback(state, routes, GuardReason.PUSH_ENTRY_FALLBACK);
    }
    // Agent 卡片：只开 agent_guide=true 的路由，且不带参数（BR-ID-10 Agent 页面引导卡）。
    if (source === RouteSource.AGENT_CARD) {
      if (!spec.agentGuide) {
        return EntryGuard.reject(GuardReason.AGENT_ROUTE_NOT_ALLOWED);
      }
      if (paramCount(request.params) > 0) {
        return EntryGuard.reject(GuardReason.AGENT_PARAMS_NOT_ALLOWED);
      }
    }
    return null;
  }

  /** 参数 schema（所有来源统一，03 §4.4）与 ExternalPage / WebPage 目标白名单。放行返回 null。 */
  private static paramsCheck(request: RouteRequest, spec: RouteSpec, state: GuardState): GuardDecision | null {
    const params: Record<string, Object> = EntryGuard.effectiveParams(request);
    if (!RouteParamValidator.isValid(params, spec)) {
      // TODO(N-14): 一般 schema 错误的提示与落点规划未定（rule-gaps G04），保守拒绝、不打开目标。
      return EntryGuard.reject(GuardReason.PARAMS_INVALID);
    }
    if (!RouteTargetCheck.isAllowed(request.route, params, state.targets, request.sourceKind)) {
      return EntryGuard.reject(GuardReason.TARGET_NOT_ALLOWED);
    }
    return null;
  }

  /** 强更检查结果未知时的只读清单。放行返回 null。 */
  private static readonlyCheck(request: RouteRequest, state: GuardState, routes: RouteLookup): GuardDecision | null {
    if (!EntryGuard.readonlyByUpdate(request, state)
      || RoutePolicy.UPDATE_UNKNOWN_READONLY_ROUTES.indexOf(request.route) >= 0) {
      return null;
    }
    if (request.sourceKind !== RouteSource.PUSH) {
      return EntryGuard.reject(GuardReason.UPDATE_UNKNOWN_BLOCKED);
    }
    return EntryGuard.pushFallback(state, routes, GuardReason.UPDATE_UNKNOWN_PUSH_FALLBACK);
  }

  /**
   * 推送兜底：以 push 入口对 Messages 再过一次守卫（需要登录就去登录等）；能打开时保留打开方式、原因码记兜底原因。
   * Messages 声明了 push 且在只读清单里，不会再次触发兜底。
   */
  private static pushFallback(state: GuardState, routes: RouteLookup, reason: string): GuardDecision {
    const messages: GuardDecision = EntryGuard.decide(RouteRequest.of(RoutePolicy.MESSAGES, RouteSource.PUSH), state,
      routes);
    if (!messages.opensPage) {
      return messages;
    }
    return new GuardDecision(messages.kind, RoutePolicy.MESSAGES, reason);
  }

  /** 前置条件都满足后的打开方式。 */
  private static openDecision(request: RouteRequest, state: GuardState): GuardDecision {
    const route: string = request.route;
    if (state.privacyState === PrivacyState.NOT_DECIDED) {
      // 只有 PRIVACY_UNDECIDED_READONLY_ROUTES 的 App 内请求走得到这里（privacyGate）。
      return new GuardDecision(GuardDecisionKind.OPEN_READONLY, route, GuardReason.PRIVACY_UNDECIDED_READONLY);
    }
    if (state.privacyState === PrivacyState.BASIC_MODE) {
      return new GuardDecision(GuardDecisionKind.OPEN_READONLY, route, GuardReason.BASIC_READONLY);
    }
    if (EntryGuard.readonlyByUpdate(request, state)) {
      return new GuardDecision(GuardDecisionKind.OPEN_READONLY, route, GuardReason.UPDATE_UNKNOWN_READONLY);
    }
    if (RoutePolicy.PARAMS_DROPPED_ROUTES.indexOf(route) >= 0 && paramCount(request.params) > 0) {
      return new GuardDecision(GuardDecisionKind.OPEN, route, GuardReason.PARAMS_DROPPED);
    }
    return new GuardDecision(GuardDecisionKind.OPEN, route, GuardReason.ALLOWED);
  }

  private static decideBelowMinimum(request: RouteRequest, state: GuardState, routes: RouteLookup): GuardDecision {
    const route: string = request.route;
    const forceUpdate: GuardDecision = new GuardDecision(GuardDecisionKind.FORCE_UPDATE, RoutePolicy.FORCE_UPDATE,
      GuardReason.FORCE_UPDATE_REQUIRED);
    if (!state.fromForceUpdatePage || request.sourceKind !== RouteSource.IN_APP
      || RoutePolicy.FORCE_UPDATE_SECONDARY_ROUTES.indexOf(route) < 0
      || EntryGuard.availability(route, state, routes) !== null) {
      // TODO(N-14): DeleteAccount 的 since.harmony 仍为 null（未发布），按未发布处理，停在强更页（rule-gaps G02）。
      return forceUpdate;
    }
    const spec: RouteSpec = routes(route) as RouteSpec;
    const params: GuardDecision | null = EntryGuard.paramsCheck(request, spec, state);
    if (params !== null) {
      return params;
    }
    // 受限会话可用于注销流程（BR-ID-01 细则「受限会话」）；游客要先登录（登录页本身也在次要入口里）。
    if (spec.auth !== 'none' && state.sessionState === SessionState.GUEST) {
      return new GuardDecision(GuardDecisionKind.REQUIRE_LOGIN, RoutePolicy.LOGIN, GuardReason.LOGIN_REQUIRED);
    }
    return new GuardDecision(GuardDecisionKind.OPEN, route, GuardReason.FORCE_UPDATE_EXCEPTION);
  }

  /** 路由不可用时返回升级提示结论；可用返回 null。 */
  private static availability(route: string, state: GuardState, routes: RouteLookup): GuardDecision | null {
    const spec: RouteSpec | undefined = routes(route);
    if (spec === undefined || (spec.debugOnly && !state.isDebugBuild)) {
      // 升级提示页没有契约路由名（rule-gaps G03）：route 为 null，由 Router 打开内置提示页。
      return new GuardDecision(GuardDecisionKind.UPGRADE, null, GuardReason.UNKNOWN_ROUTE);
    }
    if (spec.sinceHarmony === null) {
      // since.harmony 为 null（本端未发布）按未知路由处理（三端统一，rule-gaps G02）。
      return new GuardDecision(GuardDecisionKind.UPGRADE, null, GuardReason.UNKNOWN_ROUTE);
    }
    if (!AppVersion.isAtLeast(state.appVersion, spec.sinceHarmony)) {
      return new GuardDecision(GuardDecisionKind.UPGRADE, null, GuardReason.ROUTE_TOO_NEW);
    }
    return null;
  }

  /** routes.json auth 与会话状态（BR-ID-02 身份能力矩阵）。满足返回 null。 */
  private static authPrerequisite(auth: string, state: GuardState): GuardDecision | null {
    if (auth === 'none') {
      return null;
    }
    switch (state.sessionState) {
      case SessionState.LOGGED_IN:
        return auth === 'login' ? null
          : new GuardDecision(GuardDecisionKind.REQUIRE_BIND_PHONE, RoutePolicy.BIND_PHONE, GuardReason.PHONE_REQUIRED);
      case SessionState.PHONE_BOUND:
        // auth=realname：只有明确的实名通过结论才放行；绑手机不等于实名，未知按未实名（BR-ID-02）。
        if (auth === 'realname' && !state.realnameVerified) {
          return new GuardDecision(GuardDecisionKind.REQUIRE_REALNAME, RoutePolicy.REAL_NAME,
            GuardReason.REALNAME_REQUIRED);
        }
        return null;
      default:
        // 游客；TODO(N-14): 受限会话在版本恢复支持后须先刷新（rule-gaps G15），这里按需要重新登录处理。
        return new GuardDecision(GuardDecisionKind.REQUIRE_LOGIN, RoutePolicy.LOGIN, GuardReason.LOGIN_REQUIRED);
    }
  }

  private static wait(reason: string): GuardDecision {
    return new GuardDecision(GuardDecisionKind.DEFER, null, reason);
  }

  private static reject(reason: string): GuardDecision {
    return new GuardDecision(GuardDecisionKind.REJECT, null, reason);
  }
}
