/** 守卫结论的类别（任务书 §2；REQUIRE_REALNAME 为三端统一追加项）。 */
export enum GuardDecisionKind {
  OPEN = 'open',
  OPEN_READONLY = 'open_readonly',
  REJECT = 'reject',
  UPGRADE = 'upgrade',
  REQUIRE_LOGIN = 'require_login',
  REQUIRE_BIND_PHONE = 'require_bind_phone',
  /** auth=realname 而尚无实名通过结论：先进 RealName（BR-ID-02）。 */
  REQUIRE_REALNAME = 'require_realname',
  REQUIRE_CONSENT = 'require_consent',
  FORCE_UPDATE = 'force_update',
  DEFER = 'defer'
}

/** 机读原因码，取值照 specs/router-vectors.json 的 reasons；最后几项为向量之外的三端统一追加项。 */
export class GuardReason {
  static readonly ALLOWED: string = 'allowed';
  static readonly ENTRY_NOT_ALLOWED: string = 'entry_not_allowed';
  static readonly PUSH_ENTRY_FALLBACK: string = 'push_entry_fallback';
  static readonly LOGIN_REQUIRED: string = 'login_required';
  static readonly PHONE_REQUIRED: string = 'phone_required';
  static readonly BASIC_READONLY: string = 'basic_readonly';
  static readonly CONSENT_REQUIRED: string = 'consent_required';
  static readonly BASIC_MODE_BLOCKED: string = 'basic_mode_blocked';
  static readonly PRIVACY_UNDECIDED: string = 'privacy_undecided';
  static readonly ENVIRONMENT_UNSETTLED: string = 'environment_unsettled';
  static readonly UPDATE_UNKNOWN_READONLY: string = 'update_unknown_readonly';
  static readonly UPDATE_UNKNOWN_BLOCKED: string = 'update_unknown_blocked';
  static readonly UPDATE_UNKNOWN_PUSH_FALLBACK: string = 'update_unknown_push_fallback';
  static readonly FORCE_UPDATE_REQUIRED: string = 'force_update_required';
  static readonly FORCE_UPDATE_EXCEPTION: string = 'force_update_exception';
  static readonly UNKNOWN_ROUTE: string = 'unknown_route';
  static readonly ROUTE_TOO_NEW: string = 'route_too_new';
  static readonly AGENT_ROUTE_NOT_ALLOWED: string = 'agent_route_not_allowed';
  static readonly AGENT_PARAMS_NOT_ALLOWED: string = 'agent_params_not_allowed';
  static readonly AGENT_CONSENT_NO_REPLAY: string = 'agent_consent_no_replay';
  static readonly PARAMS_DROPPED: string = 'params_dropped';
  /** 参数不符合 routes.json params schema（类型、必填、多余字段、枚举、长度、pattern）。 */
  static readonly PARAMS_INVALID: string = 'params_invalid';
  /** ExternalPage / WebPage 的目标地址不在 external_hosts / bridge_origins 白名单。 */
  static readonly TARGET_NOT_ALLOWED: string = 'target_not_allowed';
  static readonly REALNAME_REQUIRED: string = 'realname_required';
  /** 强更检查中（闸门通过后未满 5 秒）：外部请求排队等结果，不交给 EntryGuard（Router 层的等待，03 §4.4 状态表）。 */
  static readonly UPDATE_CHECKING: string = 'update_checking';
}

/** 守卫结论。 */
export class GuardDecision {
  readonly kind: GuardDecisionKind;
  /** 实际要打开的路由（被拒、升级提示、等待时为 null）。 */
  readonly route: string | null;
  /** 机读原因码（GuardReason）。 */
  readonly reason: string;

  constructor(kind: GuardDecisionKind, route: string | null, reason: string) {
    this.kind = kind;
    this.route = route;
    this.reason = reason;
  }

  get kindRaw(): string {
    return this.kind;
  }

  /** 隐私闸门造成的阻断（未决、要同意、基本模式丢弃）。 */
  get isPrivacyBlock(): boolean {
    return this.reason === GuardReason.PRIVACY_UNDECIDED || this.reason === GuardReason.CONSENT_REQUIRED
      || this.reason === GuardReason.BASIC_MODE_BLOCKED || this.reason === GuardReason.AGENT_CONSENT_NO_REPLAY;
  }

  /** 前置步骤（登录、绑手机、实名）。 */
  get isPrerequisite(): boolean {
    return this.kind === GuardDecisionKind.REQUIRE_LOGIN || this.kind === GuardDecisionKind.REQUIRE_BIND_PHONE
      || this.kind === GuardDecisionKind.REQUIRE_REALNAME;
  }

  /** 结论为打开页面（含只读打开）。 */
  get opensPage(): boolean {
    return this.kind === GuardDecisionKind.OPEN || this.kind === GuardDecisionKind.OPEN_READONLY;
  }

  toString(): string {
    return this.kind + ' ' + (this.route ?? '-') + ' ' + this.reason;
  }
}
