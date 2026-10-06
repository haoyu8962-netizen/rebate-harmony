/** 隐私闸门结论（BR-ID-11）。NOT_DECIDED = 首启弹窗尚未有结论。 */
export enum PrivacyState {
  CONSENTED = 'consented',
  BASIC_MODE = 'basic_mode',
  NOT_DECIDED = 'not_decided'
}

/** 强更检查结果（03 §4.1、§4.4）。UNKNOWN = 等待超时或检查失败；「检查中」由 LaunchQueue 处理，不进守卫。 */
export enum UpdateState {
  OK = 'ok',
  UNKNOWN = 'unknown',
  BELOW_MIN = 'below_min',
  BELOW_RECOMMENDED = 'below_recommended'
}

/** 会话状态（BR-ID-02；RESTRICTED 见 BR-ID-01 细则「受限会话」）。 */
export enum SessionState {
  GUEST = 'guest',
  LOGGED_IN = 'logged_in',
  PHONE_BOUND = 'phone_bound',
  RESTRICTED = 'restricted'
}

/** 不认识的取值按最保守处理：隐私按未决。 */
export function parsePrivacyState(raw: string): PrivacyState {
  switch (raw) {
    case PrivacyState.CONSENTED:
      return PrivacyState.CONSENTED;
    case PrivacyState.BASIC_MODE:
      return PrivacyState.BASIC_MODE;
    default:
      return PrivacyState.NOT_DECIDED;
  }
}

/** 不认识的取值按未知（只读清单）。 */
export function parseUpdateState(raw: string): UpdateState {
  switch (raw) {
    case UpdateState.OK:
      return UpdateState.OK;
    case UpdateState.BELOW_MIN:
      return UpdateState.BELOW_MIN;
    case UpdateState.BELOW_RECOMMENDED:
      return UpdateState.BELOW_RECOMMENDED;
    default:
      return UpdateState.UNKNOWN;
  }
}

/** 不认识的取值按游客。 */
export function parseSessionState(raw: string): SessionState {
  switch (raw) {
    case SessionState.LOGGED_IN:
      return SessionState.LOGGED_IN;
    case SessionState.PHONE_BOUND:
      return SessionState.PHONE_BOUND;
    case SessionState.RESTRICTED:
      return SessionState.RESTRICTED;
    default:
      return SessionState.GUEST;
  }
}

/**
 * ExternalPage / WebPage 的目标白名单（03 §4.4「入口限制」，BR-ID-10）：由 /v1/config 下发，调用方注入。
 * 缺省为空，即 ExternalPage、WebPage 一律不放行（配置缺失时保守拒绝）。
 */
export class RouteTargetAllowlist {
  static readonly EMPTY: RouteTargetAllowlist = new RouteTargetAllowlist([], []);
  /** ExternalPage 的 url 主机（完整主机名匹配，不认子域通配）。 */
  readonly externalHosts: string[];
  /** WebPage 的 url origin（https://host[:port]）。 */
  readonly bridgeOrigins: string[];

  constructor(externalHosts: string[], bridgeOrigins: string[]) {
    this.externalHosts = externalHosts;
    this.bridgeOrigins = bridgeOrigins;
  }
}

/** 入口守卫的输入状态（任务书 §2；realnameVerified 与 targets 为三端统一追加项，缺省 false / 空）。 */
export class GuardState {
  readonly privacyState: PrivacyState;
  readonly updateState: UpdateState;
  readonly sessionState: SessionState;
  readonly environmentSettled: boolean;
  /** 本端版本号，与 routes.json since.harmony 比较。 */
  readonly appVersion: string;
  /** Debug / Staging = true（debug_only 路由只在这时可开）。 */
  readonly isDebugBuild: boolean;
  /** 本次打开是否由强更页的次要入口发起。 */
  readonly fromForceUpdatePage: boolean;
  /** 已取得明确的实名通过结论（缺省 false：未知按未实名；已绑手机不等于已实名，BR-ID-02）。 */
  readonly realnameVerified: boolean;
  /** ExternalPage / WebPage 的目标白名单（缺省空 = 全拒）。 */
  readonly targets: RouteTargetAllowlist;

  constructor(privacy: string, update: string, session: string, environmentSettled: boolean, appVersion: string,
    isDebugBuild: boolean, fromForceUpdatePage: boolean = false, realnameVerified: boolean = false,
    targets: RouteTargetAllowlist = RouteTargetAllowlist.EMPTY) {
    this.privacyState = parsePrivacyState(privacy);
    this.updateState = parseUpdateState(update);
    this.sessionState = parseSessionState(session);
    this.environmentSettled = environmentSettled;
    this.appVersion = appVersion;
    this.isDebugBuild = isDebugBuild;
    this.fromForceUpdatePage = fromForceUpdatePage;
    this.realnameVerified = realnameVerified;
    this.targets = targets;
  }

  get privacy(): string {
    return this.privacyState;
  }

  get update(): string {
    return this.updateState;
  }

  get session(): string {
    return this.sessionState;
  }

  /** 换掉启动排队放行时确定的三项（环境、隐私、强更结果），其余照旧。 */
  withLaunch(environmentSettled: boolean, privacy: PrivacyState, update: UpdateState): GuardState {
    return new GuardState(privacy, update, this.sessionState, environmentSettled, this.appVersion, this.isDebugBuild,
      this.fromForceUpdatePage, this.realnameVerified, this.targets);
  }
}
