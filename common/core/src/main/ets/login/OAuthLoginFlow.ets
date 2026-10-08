import { ApiOperation, ApiOperations } from 'generated';
import {
  EffectKind, ErrorActionInput, ErrorActionMapper, ErrorActionState, ErrorEffect, ErrorUpdateState
} from '../network/ErrorActionMapper';
import { SessionScope } from '../network/NetworkPolicy';

/**
 * 第三方登录、绑手机与空号并入的纯逻辑（APP-05b；BR-ID-04、BR-ID-06、BR-INV-03 细则；03 §4.2）。三端同名；向量
 * specs/oauth-login-vectors.json（OAuthLoginVector.test.ets）。没有界面、网络、SDK 与计时器：执行器是 OAuthLoginService /
 * BindPhoneService，页面在 features/auth。raw 取值（routeRaw / actionRaw / resultRaw）是三端接线名，不是契约路由。
 */

/** 第三方 provider 名（openapi CreateOauthAttemptRequest.provider）。 */
export class OAuthProvider {
  static readonly WECHAT: string = 'wechat';
  static readonly APPLE: string = 'apple';
  static readonly HUAWEI: string = 'huawei';

  /** provider → 登录接口 operationId；不认识的为 null。 */
  static loginOperation(provider: string): string | null {
    switch (provider) {
      case OAuthProvider.WECHAT:
        return 'loginByWechat';
      case OAuthProvider.APPLE:
        return 'loginByApple';
      case OAuthProvider.HUAWEI:
        return 'loginByHuawei';
      default:
        return null;
    }
  }
}

/** 被拒的回调（观测接线：attempt 句柄与回调编号，不是服务端字段）。 */
export class DroppedCallback {
  readonly attempt: string;
  readonly seq: number;

  constructor(attempt: string, seq: number) {
    this.attempt = attempt;
    this.seq = seq;
  }
}

/** 一次本地授权尝试的状态。 */
class AttemptRecord {
  readonly handle: string;
  launched: boolean = false;
  /** 已收到凭证（callback 接受）。 */
  credential: boolean = false;
  submitted: boolean = false;
  /** 已取消、离开、超时或被新尝试取代：之后的回调只丢弃、提交不发出。 */
  terminated: boolean = false;

  constructor(handle: string) {
    this.handle = handle;
  }
}

/**
 * 授权尝试的归属与页面世代（BR-ID-04 细则「授权尝试」「先校验、后消费」；brief §2.1）：
 * - create 取一个新的本地尝试（再次 create 时旧尝试作废，TODO(N-29) ATTEMPT：原文未定义，保守处理）；
 * - callback 只接收凭证：当前尝试、已拉起、没终止、还没收到过凭证才接受；其余一律记入 dropped（迟到、重复、属于旧尝试）；
 * - submit 是唯一提交边界：同一尝试只提交一次，已终止或没有凭证的不提交（不记 dropped）；
 * - cancel / leave / timeout 终止当前尝试：回前台后迟到的回调只丢弃。
 * 同步纯逻辑，单线程使用。
 */
export class OAuthAttemptSession {
  readonly submitted: string[] = [];
  readonly dropped: DroppedCallback[] = [];
  private readonly records: Map<string, AttemptRecord> = new Map<string, AttemptRecord>();
  private current: AttemptRecord | null = null;
  private counter: number = 0;

  create(): string {
    this.terminateCurrent();
    this.counter++;
    const record: AttemptRecord = new AttemptRecord('oauth-attempt-' + this.counter);
    this.records.set(record.handle, record);
    this.current = record;
    return record.handle;
  }

  launch(attempt: string): void {
    const record: AttemptRecord | null = this.live(attempt);
    if (record !== null) {
      record.launched = true;
    }
  }

  /** 第三方回调带回凭证；返回是否接受（不接受的记入 dropped）。 */
  callback(attempt: string, seq: number): boolean {
    const record: AttemptRecord | null = this.live(attempt);
    if (record === null || !record.launched || record.credential || record.submitted) {
      this.dropped.push(new DroppedCallback(attempt, seq));
      return false;
    }
    record.credential = true;
    return true;
  }

  /** 提交（登录请求的唯一边界）；返回这次是否真正提交。 */
  submit(attempt: string): boolean {
    const record: AttemptRecord | null = this.live(attempt);
    if (record === null || !record.credential || record.submitted) {
      return false;
    }
    record.submitted = true;
    this.submitted.push(attempt);
    return true;
  }

  /** 用户在第三方授权里取消。 */
  cancel(): void {
    this.terminateCurrent();
  }

  /** 离开登录页（出栈、换方式、登出）。 */
  leave(): void {
    this.terminateCurrent();
  }

  /** 授权等待超时。 */
  timeout(): void {
    this.terminateCurrent();
  }

  /** 这个尝试仍是当前、没有终止。 */
  isLive(attempt: string): boolean {
    return this.live(attempt) !== null;
  }

  private live(attempt: string): AttemptRecord | null {
    const record: AttemptRecord | undefined = this.records.get(attempt);
    if (record === undefined || record.terminated || this.current !== record) {
      return null;
    }
    return record;
  }

  private terminateCurrent(): void {
    const record: AttemptRecord | null = this.current;
    if (record !== null) {
      record.terminated = true;
    }
    this.current = null;
  }
}

/** 第三方登录成功后的分流（OAuthLoginRoute.map 的结果）。 */
export class OAuthRouteResult {
  /** done（老用户直接登录）/ bind_phone_guide（第三方新号绑手机引导）/ error（不是可保存的登录响应）。 */
  readonly routeRaw: string;
  /** 保存会话的意图（落盘与世代检查由 ApiClient 与 LoginService 负责）。 */
  readonly saveSession: boolean;
  /** 首次购买前提示的标记：登录响应不含判定所需的信息（INVITE-STATE），一律不给值。 */
  readonly firstPurchaseTip?: boolean;

  constructor(routeRaw: string, saveSession: boolean) {
    this.routeRaw = routeRaw;
    this.saveSession = saveSession;
  }
}

/**
 * 第三方登录响应 → 分流（BR-ID-04 细则：四个登录接口都带 is_new_user；BR-INV-03 细则 ①：第三方新号登录成功后弹一次绑手机
 * 引导）。只看完整外壳的 code、data.tokens 与 is_new_user；deletion_only（受限登录）沿用 APP-05a 的登录后计划（done）。
 * 并号不来自登录响应（LOGIN-MERGE），只来自 bindPhone 的 30411 mergeable。
 */
export class OAuthLoginRoute {
  static readonly DONE: string = 'done';
  static readonly BIND_PHONE_GUIDE: string = 'bind_phone_guide';
  static readonly ERROR: string = 'error';

  static map(provider: string, response: Record<string, Object>): OAuthRouteResult {
    if (OAuthProvider.loginOperation(provider) === null || response['code'] !== 0) {
      return new OAuthRouteResult(OAuthLoginRoute.ERROR, false);
    }
    const data: Object | undefined = response['data'];
    if (data === undefined || data === null || typeof data !== 'object') {
      return new OAuthRouteResult(OAuthLoginRoute.ERROR, false);
    }
    return OAuthLoginRoute.ofData(data as Record<string, Object>);
  }

  /** 已成功的登录响应的 data（LoginData）→ 分流。 */
  static ofData(data: Record<string, Object>): OAuthRouteResult {
    const tokens: Object | undefined = data['tokens'];
    if (tokens === undefined || tokens === null || typeof tokens !== 'object') {
      return new OAuthRouteResult(OAuthLoginRoute.ERROR, false);
    }
    const pair: Record<string, Object> = tokens as Record<string, Object>;
    if (typeof pair['access_token'] !== 'string' || typeof pair['refresh_token'] !== 'string') {
      return new OAuthRouteResult(OAuthLoginRoute.ERROR, false);
    }
    const restricted: boolean = pair['session_scope'] === SessionScope.DELETION_ONLY;
    if (data['is_new_user'] === true && !restricted) {
      return new OAuthRouteResult(OAuthLoginRoute.BIND_PHONE_GUIDE, true);
    }
    return new OAuthRouteResult(OAuthLoginRoute.DONE, true);
  }
}

/** 第三方登录错误的页面动作。 */
export class OAuthErrorResult {
  /**
   * reauthorize（20004：用户重新取尝试并授权，不自动重试）/ provider_unavailable（50305：保留其他方式，不自动重试）/
   * field_error / risk_blocked（44001）/ force_update（10405）/ service_error（5xxxx，附 trace6）/ retry_after（42901）/
   * network_error / message（其余）。
   */
  readonly actionRaw: string;
  readonly textKey?: string;
  readonly showTrace6?: boolean;
  /** 42901 的禁用毫秒数（Retry-After）。 */
  readonly disableMillis: number;

  constructor(actionRaw: string, textKey: string | null, showTrace6: boolean, disableMillis: number = 0) {
    this.actionRaw = actionRaw;
    if (textKey !== null) {
      this.textKey = textKey;
    }
    this.showTrace6 = showTrace6;
    this.disableMillis = disableMillis;
  }
}

/** 第三方登录（含取授权尝试）错误码 → 页面动作，接已有的 ErrorActionMapper（不另造码表）。 */
export class OAuthLoginErrorAction {
  static readonly REAUTHORIZE: string = 'reauthorize';
  static readonly PROVIDER_UNAVAILABLE: string = 'provider_unavailable';
  static readonly FIELD_ERROR: string = 'field_error';
  static readonly RISK_BLOCKED: string = 'risk_blocked';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly SERVICE_ERROR: string = 'service_error';
  static readonly RETRY_AFTER: string = 'retry_after';
  static readonly NETWORK_ERROR: string = 'network_error';
  static readonly MESSAGE: string = 'message';

  static map(provider: string, code: number, data: Record<string, Object>,
    headers: Record<string, string> = {}): OAuthErrorResult {
    const opId: string = OAuthProvider.loginOperation(provider) ?? 'loginByWechat';
    const operation: ApiOperation | undefined = ApiOperations.byId(opId);
    if (operation === undefined) {
      return new OAuthErrorResult(OAuthLoginErrorAction.MESSAGE, null, false);
    }
    // 登录页没有会话：按「不低于、正常作用域」映射（同 LoginErrorMapper；网络层按真实状态另行处理强更与会话）。
    const effect: ErrorEffect = ErrorActionMapper.map(new ErrorActionInput(code, data, operation, headers, false,
      new ErrorActionState(ErrorUpdateState.SUPPORTED, SessionScope.FULL, '')));
    return OAuthLoginErrorAction.ofEffect(code, effect);
  }

  /** 网络层已给出的 Effect（ApiResult.effect）→ 页面动作。 */
  static ofEffect(code: number, effect: ErrorEffect): OAuthErrorResult {
    const key: string | null = effect.textKey;
    if (code === 44001) {
      return new OAuthErrorResult(OAuthLoginErrorAction.RISK_BLOCKED, key, false);
    }
    if (code === 50305) {
      return new OAuthErrorResult(OAuthLoginErrorAction.PROVIDER_UNAVAILABLE, key, false);
    }
    switch (effect.effectKindRaw) {
      case EffectKind.REAUTHORIZE:
        return new OAuthErrorResult(OAuthLoginErrorAction.REAUTHORIZE, key, false);
      case EffectKind.FIELD_ERROR:
        return new OAuthErrorResult(OAuthLoginErrorAction.FIELD_ERROR, key, false);
      case EffectKind.FORCE_UPDATE:
        return new OAuthErrorResult(OAuthLoginErrorAction.FORCE_UPDATE, key, false);
      case EffectKind.DISABLE_BUTTON:
        return new OAuthErrorResult(OAuthLoginErrorAction.RETRY_AFTER, key, false, effect.disableMillis);
      case EffectKind.GENERIC_ERROR:
        return new OAuthErrorResult(OAuthLoginErrorAction.SERVICE_ERROR, key, true);
      case EffectKind.NETWORK_ERROR:
        return new OAuthErrorResult(OAuthLoginErrorAction.NETWORK_ERROR, key, effect.includeTrace6);
      default:
        return new OAuthErrorResult(OAuthLoginErrorAction.MESSAGE, key, effect.includeTrace6);
    }
  }
}

/**
 * 第三方登录按钮是否显示（BR-ID-04 细则「未安装微信时」；brief §2.2）：
 * - 微信：本机已安装（检测结果未知时调用方按「照常显示」传 true）且适配器已允许启用。鸿蒙正式适配器恒为不可用（无 SDK、
 *   无 AppID，06 Q-C12 验证前不启用），所以正式包不显示；Debug 假适配器只用于测试与截图（TODO(N-29) BUTTONS）。
 * - Apple：只有 iOS（BR-ID-04 默认值只给 iOS 写了 SIWA）。
 */
export class ThirdPartyButtons {
  static wechatVisible(platform: string, installed: boolean, adapterAvailable: boolean): boolean {
    if (platform !== 'ios' && platform !== 'android' && platform !== 'harmony') {
      return false;
    }
    return installed && adapterAvailable;
  }

  static appleVisible(platform: string): boolean {
    return platform === 'ios';
  }
}

/** 绑手机相关响应的页面动作。 */
export class BindActionResult {
  /**
   * done（bindPhone 成功：之后刷新 getMe 与会话状态）/ retry_after（发码已受理交倒计时，或 42901 按 Retry-After 等待）/
   * merge_confirm（30411 mergeable 且带 merge_ticket：弹并号确认，不自动并号）/ error（提示 textKey）。
   */
  readonly actionRaw: string;
  readonly textKey?: string;

  constructor(actionRaw: string, textKey: string | null) {
    this.actionRaw = actionRaw;
    if (textKey !== null) {
      this.textKey = textKey;
    }
  }
}

/**
 * 绑手机发码（purpose=bind）与 bindPhone 的响应 → 页面动作（BR-ID-05、BR-ID-06；openapi bindPhone 的 30411 data.reason=mergeable
 * 与 merge_ticket）。输入是本地接线包装 {operation, purpose?, body, headers?}，body 才是契约外壳。
 */
export class BindPhoneAction {
  static readonly DONE: string = 'done';
  static readonly RETRY_AFTER: string = 'retry_after';
  static readonly MERGE_CONFIRM: string = 'merge_confirm';
  static readonly ERROR: string = 'error';
  static readonly BIND_OPERATION: string = 'bindPhone';
  static readonly SMS_OPERATION: string = 'sendSmsCode';

  static map(input: Record<string, Object>): BindActionResult {
    const operation: Object | undefined = input['operation'];
    const body: Object | undefined = input['body'];
    if (typeof operation !== 'string' || body === undefined || body === null || typeof body !== 'object') {
      return new BindActionResult(BindPhoneAction.ERROR, 'error.50001');
    }
    const envelope: Record<string, Object> = body as Record<string, Object>;
    const code: Object | undefined = envelope['code'];
    const rawData: Object | undefined = envelope['data'];
    const data: Record<string, Object> = rawData !== undefined && rawData !== null && typeof rawData === 'object' ?
      rawData as Record<string, Object> : {};
    const rawHeaders: Object | undefined = input['headers'];
    const headers: Record<string, string> = rawHeaders !== undefined && rawHeaders !== null
      && typeof rawHeaders === 'object' ? rawHeaders as Record<string, string> : {};
    if (typeof code !== 'number') {
      return new BindActionResult(BindPhoneAction.ERROR, 'error.50001');
    }
    return BindPhoneAction.ofCode(operation as string, code as number, data, headers);
  }

  static ofCode(operation: string, code: number, data: Record<string, Object>,
    headers: Record<string, string> = {}): BindActionResult {
    if (code === 0) {
      return new BindActionResult(operation === BindPhoneAction.BIND_OPERATION ? BindPhoneAction.DONE :
        BindPhoneAction.RETRY_AFTER, null);
    }
    if (operation === BindPhoneAction.BIND_OPERATION && code === 30411) {
      return BindPhoneAction.mergeTicket(data) !== null
        ? new BindActionResult(BindPhoneAction.MERGE_CONFIRM, 'error.30411.mergeable')
        : new BindActionResult(BindPhoneAction.ERROR, 'error.30411');
    }
    const op: ApiOperation | undefined = ApiOperations.byId(operation);
    if (op === undefined) {
      return new BindActionResult(BindPhoneAction.ERROR, 'error.50001');
    }
    const effect: ErrorEffect = ErrorActionMapper.map(new ErrorActionInput(code, data, op, headers, false,
      new ErrorActionState(ErrorUpdateState.SUPPORTED, SessionScope.FULL, '')));
    if (effect.effectKindRaw === EffectKind.DISABLE_BUTTON) {
      return new BindActionResult(BindPhoneAction.RETRY_AFTER, effect.textKey);
    }
    return new BindActionResult(BindPhoneAction.ERROR, effect.textKey);
  }

  /** 30411 的并号凭据：reason=mergeable 且 merge_ticket 是非空字符串才有；否则 null（不能并号）。 */
  static mergeTicket(data: Record<string, Object>): string | null {
    const ticket: Object | undefined = data['merge_ticket'];
    if (data['reason'] !== 'mergeable' || typeof ticket !== 'string' || (ticket as string).length === 0) {
      return null;
    }
    return ticket as string;
  }
}

/** 并号确认的结果。 */
export class MergeResult {
  /**
   * cancelled（请求发出前取消确认：不并号、不保存会话）/ rejected（确认后收到 30411：票据过期、已用或条件改变）/
   * unavailable（锁定契约没有并号接口，TODO(N-29) MERGE-SUCCESS：不发请求）/ unsupported（收到成功外壳但没有契约 schema，
   * 不拿 LoginResponse 冒充，不保存）/ failed（其他错误）。
   */
  readonly resultRaw: string;
  readonly saveSession: boolean;

  constructor(resultRaw: string, saveSession: boolean) {
    this.resultRaw = resultRaw;
    this.saveSession = saveSession;
  }
}

/** 并号确认 / 取消（BR-ID-06 OPS-04；规划/04 §6.1 30411）。任何结果都不保存会话（并号成功响应的形状未定）。 */
export class MergeDecision {
  static readonly CANCEL: string = 'cancel';
  static readonly CONFIRM: string = 'confirm';
  static readonly CANCELLED: string = 'cancelled';
  static readonly REJECTED: string = 'rejected';
  static readonly UNAVAILABLE: string = 'unavailable';
  static readonly UNSUPPORTED: string = 'unsupported';
  static readonly FAILED: string = 'failed';

  static apply(decision: string, response: Record<string, Object> | undefined): MergeResult {
    if (decision !== MergeDecision.CONFIRM) {
      return new MergeResult(MergeDecision.CANCELLED, false);
    }
    if (response === undefined) {
      return new MergeResult(MergeDecision.UNAVAILABLE, false);
    }
    const code: Object | undefined = response['code'];
    if (code === 30411) {
      return new MergeResult(MergeDecision.REJECTED, false);
    }
    if (code === 0) {
      return new MergeResult(MergeDecision.UNSUPPORTED, false);
    }
    return new MergeResult(MergeDecision.FAILED, false);
  }
}
