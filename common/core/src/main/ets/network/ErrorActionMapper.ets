import { ApiOperation, DefaultTexts, ErrorCodeInfo, ErrorCodes, RetryKind } from 'generated';
import { AppVersion } from '../router/RoutePolicy';
import { SessionScope } from './NetworkPolicy';

/**
 * 错误码 → 客户端动作（APP-03a；03 §4.2「错误码 → 客户端动作」「ErrorActionMapper 实现要点」，error-codes.yaml，
 * BR-ID-01 细则、BR-ID-10 细则「不适用的动作」「敏感操作的幂等键」，BR-TEXT-14）。页面只消费 Effect，不自行判断码值。
 * 三端同名；向量 specs/network-vectors.json errorAction。
 *
 * 判定顺序：
 * 1. 10002 → 单飞刷新后沿用原键重放 1 次（敏感操作同样）；
 * 2. 10402 → 重新注册设备后沿用原键重放 1 次；本次已是重放 → 按其他 5xxxx 兜底（BR-TEXT-14 表 A）；
 * 3. 10405 → 本机版本不低于 data.min_supported_version（或它为空）且会话为 deletion_only：只刷新令牌、不进强更、不显示版本文案；
 *    否则进强更（调用 Update 的 on10405），不重放、不登记 pending_action；
 * 4. 带 reason 且 retry_kind_by_reason 不是 after_action 的（30101 auth_unavailable 等）→ 只提示（取 error.<code>.<reason>）；
 * 5. 四个 step-up 操作被 10001、10004（任何 consent_type）、10005 或 3xxxx 前置码拦下 → 只引导、不重放、不登记 pending_action；
 * 6. 1xxxx 前置（登录、同意、绑手机）→ 前置完成后沿用原键并登记 pending_action；10003 → StepUpSheet 后沿用原键；
 *    3xxxx 授权前置 → 新键并登记 pending_action；30304 / 30305 / 30307 / 30308 无论哪个操作都只引导（error-codes：不重放）；
 * 7. 42901 → 按 Retry-After 秒数禁用按钮，缺省 5 秒；
 * 8. 50301 按 reason（maintenance / 无 reason：禁用 + Toast；not_launched：禁用不弹 Toast）；
 * 9. 5xxxx（50001、50401 与表外）→ 通用错误态附 trace_id 后 6 位；表外与废弃的非 5xxxx 码 → 服务端 msg 兜底；
 *    表内但用户侧字典没有 error.<code> 的码（10008 / 10009、30154、30417、44004 只在 /admin/v1 出现，客户端不会收到）同表外码：
 *    服务端 msg 兜底（CT-LOCK-01 R1-01 起 1xxxx，CT-LOCK-02 扩到全部码段；page_action 表与置灰码除外，
 *    10002 / 10402 已在前面专门处理）；
 *    error-codes.yaml 写明具体动作的码（30144 refetch_product、30306 disable_button、page_action 表等，见 specialAction）；
 *    其余表内码 → Toast（文案 error.<code>，带 reason 先取子键）。
 */

/** Effect 的种类（三端统一的原始字符串；向量 effectKinds）。 */
export class EffectKind {
  static readonly LOGIN: string = 'login';
  static readonly BIND_PHONE: string = 'bind_phone';
  static readonly CONSENT: string = 'consent';
  static readonly STEP_UP: string = 'step_up';
  static readonly AUTHORIZE: string = 'authorize';
  static readonly GUIDE_ONLY: string = 'guide_only';
  static readonly REFRESH_REPLAY: string = 'refresh_replay';
  static readonly REGISTER_DEVICE_REPLAY: string = 'register_device_replay';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly REFRESH_ONLY: string = 'refresh_only';
  static readonly CLEAR_SESSION_LOGIN: string = 'clear_session_login';
  static readonly CLEAR_SESSION_STAY_FORCE_UPDATE: string = 'clear_session_stay_force_update';
  static readonly DISABLE_BUTTON: string = 'disable_button';
  static readonly TOAST: string = 'toast';
  static readonly GENERIC_ERROR: string = 'generic_error';
  static readonly FALLBACK_MESSAGE: string = 'fallback_message';
  static readonly DISABLE_WITH_TOAST: string = 'disable_with_toast';
  static readonly DISABLE_WITHOUT_TOAST: string = 'disable_without_toast';
  /** 跳到说明页（封禁说明、注销进度、搜索等），不重放（向量 effectKinds 之外的补充种类）。 */
  static readonly NAVIGATE: string = 'navigate';
  /** 网络失败（超时、断连、无统一外壳）：通用错误态，不是业务码。 */
  static readonly NETWORK_ERROR: string = 'network_error';
  // ---- 以下为 error-codes.yaml 写明的非 Toast 动作（harmony-review-r1 R1-08；名字与三端对齐清单一致）。
  /** 发起页按码自己的界面处理（卡片置灰、无返利购买按钮、并号确认、申诉入口、空态等），文案取 textKey，不重放。 */
  static readonly PAGE_ACTION: string = 'page_action';
  /**
   * 30144：按卡片的 product_key + item_ref 重新取商品（转链）并替换卡片，之后仍须用户再次点击（不重放原请求）。
   * 没有卡片数据的入口（App 内链接落地页 LinkLanding）不输出它，改为 page_action（空态、不自动重试）。
   */
  static readonly REFETCH_PRODUCT: string = 'refetch_product';
  /** 40901：保持加载态，稍后查询结果（作废请求得到本码时未决键保持待确认）。 */
  static readonly KEEP_LOADING: string = 'keep_loading';
  /**
   * 20001：在对应字段旁提示（ErrorEffect.fields = data.fields；文案带 reason 先取子键）。不重放。
   * data.fields 含 device_hash 时不是字段提示，改为 REREAD_DEVICE_HASH。
   */
  static readonly FIELD_ERROR: string = 'field_error';
  /**
   * 20001 且 data.fields 含 device_hash（三端对齐的名字，iOS 先有；APP-03b）：不向用户提示（textKey 为 null），由设备注册
   * （DeviceRegistry）按 BR-ID-09 重读一次设备标识再注册，读到的还是被拒的值就不再发（不带原值重试）。fields 照样带出。
   */
  static readonly REREAD_DEVICE_HASH: string = 'reread_device_hash';
  /**
   * 20004：回到登录页（三个第三方登录）或二次验证面板（stepUp），由用户重新发起第三方授权（重新取授权尝试，
   * 不复用原尝试与原凭证）；不自动重放、不登记 pending_action。去向见 ErrorEffect.reauthorizeIn。
   */
  static readonly REAUTHORIZE: string = 'reauthorize';
}

/** 20004 重新授权的去向（ErrorEffect.reauthorizeIn）。 */
export class ReauthorizeIn {
  /** 回登录页重新发起第三方登录。 */
  static readonly LOGIN: string = 'login';
  /** 回二次验证面板（StepUpSheet）重新发起第三方授权。 */
  static readonly STEP_UP: string = 'step_up';
}

/** 重放方式。 */
export class ReplayKind {
  static readonly NONE: string = 'none';
  /** 沿用原 Idempotency-Key。 */
  static readonly SAME_KEY: string = 'same_key';
  /** 用新的 Idempotency-Key（3xxxx 前置完成后是一次新的请求）。 */
  static readonly NEW_KEY: string = 'new_key';
}

/** 强更结论在 mapper 里的取值：supported（不低于）/ below（低于）/ unknown（检查中或失败）。 */
export class ErrorUpdateState {
  static readonly SUPPORTED: string = 'supported';
  static readonly BELOW: string = 'below';
  static readonly UNKNOWN: string = 'unknown';
}

export class ErrorActionState {
  /** supported / below / unknown。 */
  readonly update: string;
  /** full / deletion_only。 */
  readonly sessionScope: string;
  /** 本机版本（SemVer）。 */
  readonly appVersion: string;

  constructor(update: string, sessionScope: string, appVersion: string) {
    this.update = update;
    this.sessionScope = sessionScope;
    this.appVersion = appVersion;
  }
}

export class ErrorActionInput {
  readonly code: number;
  /** 响应外壳的 data（没有为 {}）。 */
  readonly data: Record<string, Object>;
  /** 原请求的 operation。 */
  readonly operation: ApiOperation;
  /** 响应头（名字大小写不敏感地读取）。 */
  readonly headers: Record<string, string>;
  /** 本次响应是否来自一次重放（重放至多 1 次）。 */
  readonly isReplay: boolean;
  readonly state: ErrorActionState;
  /** 发起页有可重新转链的商品卡（30144 输出 refetch_product）；LinkLanding 等没有卡片数据的入口为 false。 */
  readonly fromProductCard: boolean;

  constructor(code: number, data: Record<string, Object>, operation: ApiOperation, headers: Record<string, string>,
    isReplay: boolean, state: ErrorActionState, fromProductCard: boolean = true) {
    this.code = code;
    this.data = data;
    this.operation = operation;
    this.headers = headers;
    this.isReplay = isReplay;
    this.state = state;
    this.fromProductCard = fromProductCard;
  }
}

/** mapper 的输出。页面只按它行事。 */
export class ErrorEffect {
  readonly effectKindRaw: string;
  /** 要打开的路由（Login、BindPhone、AuthSheet、RealName、ForceUpdate…）；不跳为 null。 */
  readonly route: string | null;
  /** 文案键（error.<code> 或 error.<code>.<reason>）；没有为 null（展示层按 BR-TEXT-14 兜底）。 */
  readonly textKey: string | null;
  readonly replayRaw: string;
  /** 跳前置页之前要持久化 pending_action（Router 的 PendingActionStore）。 */
  readonly registerPending: boolean;
  /** 禁用触发按钮的毫秒数（42901）；其余 0。 */
  readonly disableMillis: number;
  /** 通用错误态要附 trace_id 后 6 位。 */
  readonly includeTrace6: boolean;
  /** field_error：要在旁边提示的字段名（data.fields）；其余为空。 */
  readonly fields: string[];
  /** reauthorize：login / step_up（ReauthorizeIn）；其余为 null。 */
  readonly reauthorizeIn: string | null;

  constructor(effectKindRaw: string, route: string | null, textKey: string | null, replayRaw: string,
    registerPending: boolean, disableMillis: number = 0, includeTrace6: boolean = false, fields: string[] = [],
    reauthorizeIn: string | null = null) {
    this.effectKindRaw = effectKindRaw;
    this.route = route;
    this.textKey = textKey;
    this.replayRaw = replayRaw;
    this.registerPending = registerPending;
    this.disableMillis = disableMillis;
    this.includeTrace6 = includeTrace6;
    this.fields = fields;
    this.reauthorizeIn = reauthorizeIn;
  }
}

/** 需要跳页完成的业务前置码（3xxxx）：路由与「是否新键重放」（error-codes.yaml action）。 */
class Prerequisite {
  readonly route: string;
  /** true：完成后新键重放并登记 pending_action（30101 等授权）；false：只引导，回发起页由用户重新提交。 */
  readonly replayWithNewKey: boolean;
  readonly effectKind: string;

  constructor(route: string, replayWithNewKey: boolean, effectKind: string) {
    this.route = route;
    this.replayWithNewKey = replayWithNewKey;
    this.effectKind = effectKind;
  }
}

export class ErrorActionMapper {
  /** 42901 无 Retry-After 时禁用 5 秒（03 §4.2）。 */
  static readonly DEFAULT_RETRY_AFTER_MILLIS: number = 5000;
  /**
   * Retry-After 秒数的上限。TODO(N-19)：HTTP-date、小数、负数的处理未规定（rule-gaps 第 5 条）；
   * 只接受十进制非负整数秒，其余按缺省 5 秒。上限取 24 小时（APP-05a：BR-ID-05 发码每日额度与滑动 24 小时保护的
   * Retry-After 可到次日，原先的一小时上限会让按钮提前解禁，向量 smsSend.rate_limit_86400）；超过按 24 小时（保守：不让
   * 按钮被一个异常值永久禁用）。
   */
  static readonly MAX_RETRY_AFTER_SECONDS: number = 86400;

  private static readonly PREREQUISITES: Map<number, Prerequisite> = ErrorActionMapper.buildPrerequisites();
  /** 只跳说明页、不重放的码（error-codes.yaml action 里写明「跳 X」的）。 */
  private static readonly NAVIGATIONS: Map<number, string> = ErrorActionMapper.buildNavigations();
  /** 由发起页按自己的界面处理的码（error-codes.yaml 写明了具体界面动作；三端同一张表）。 */
  private static readonly PAGE_ACTION_CODES: number[] = [20902, 30103, 30104, 30121, 30132, 30141, 30151, 30153, 30302,
    30309, 30408, 30411, 30413, 30416, 30501, 30504, 30505, 30506, 30602, 30701, 30802, 30803, 30804, 44003, 50303,
    50304, 50305];
  /** 按钮置灰（不限时，页面按状态恢复）：30206 找回入口、30306 提现按钮。 */
  private static readonly DISABLE_CODES: number[] = [30206, 30306];
  /** LinkLanding 的 30144 空态文案（BR-TEXT-14）。 */
  static readonly LINK_LANDING_INVALID: string = 'link_landing.invalid';

  static map(input: ErrorActionInput): ErrorEffect {
    const code: number = input.code;
    const op: ApiOperation = input.operation;
    const reason: string | null = ErrorActionMapper.reasonOf(input.data);
    const info: ErrorCodeInfo | undefined = ErrorCodes.info(code);
    const known: boolean = info !== undefined && !info.isDeprecated;
    const textKey: string | null = ErrorActionMapper.textKey(code, reason);
    // 作废接口（放弃上一笔）被 10001/10004/10005 拦下同样只引导、不登记、不重放，键保持待确认（BR-ID-10 细则）。
    const stepUpOperation: boolean = op.stepUp !== null || op.operationId === 'abandonIdempotencyKey';

    if (code === 10002) {
      if (input.isReplay) {
        // TODO(N-19)：刷新后的重放仍得 10002 的处理未规定（rule-gaps 第 11 条）；至多重放 1 次，按通用错误态收口，不再刷新。
        return new ErrorEffect(EffectKind.GENERIC_ERROR, null, null, ReplayKind.NONE, false, 0, true);
      }
      return new ErrorEffect(EffectKind.REFRESH_REPLAY, null, null, ReplayKind.SAME_KEY, false);
    }
    if (code === 10402) {
      if (input.isReplay) {
        // BR-TEXT-14 表 A：10402 重放仍失败按其他 5xxxx。
        return new ErrorEffect(EffectKind.GENERIC_ERROR, null, null, ReplayKind.NONE, false, 0, true);
      }
      return new ErrorEffect(EffectKind.REGISTER_DEVICE_REPLAY, null, null, ReplayKind.SAME_KEY, false);
    }
    if (code === 10405) {
      return ErrorActionMapper.map10405(input, textKey);
    }
    if (code === 10404) {
      return new ErrorEffect(EffectKind.CLEAR_SESSION_LOGIN, 'Login', textKey, ReplayKind.NONE, false);
    }
    if (code === 42901) {
      return new ErrorEffect(EffectKind.DISABLE_BUTTON, null, textKey, ReplayKind.NONE, false,
        ErrorActionMapper.retryAfterMillis(input.headers));
    }
    if (code === 50301) {
      if (reason === 'not_launched') {
        return new ErrorEffect(EffectKind.DISABLE_WITHOUT_TOAST, null, textKey, ReplayKind.NONE, false);
      }
      // 无 reason 按 maintenance（error-codes.yaml）。
      const key: string | null = ErrorActionMapper.textKey(code, reason ?? 'maintenance');
      return new ErrorEffect(EffectKind.DISABLE_WITH_TOAST, null, key, ReplayKind.NONE, false);
    }
    if (!known || ErrorActionMapper.isTextlessUnhandledCode(code)) {
      if (ErrorActionMapper.isServerError(code)) {
        return new ErrorEffect(EffectKind.GENERIC_ERROR, null, null, ReplayKind.NONE, false, 0, true);
      }
      return new ErrorEffect(EffectKind.FALLBACK_MESSAGE, null, null, ReplayKind.NONE, false);
    }
    // error-codes.yaml 写明了具体动作的码（R1-08）：先于「带 reason 只提示」判定（50304 search_disabled、30411 mergeable）。
    const special: ErrorEffect | null = ErrorActionMapper.specialAction(input, textKey);
    if (special !== null) {
      return special;
    }
    // 带 reason、该 reason 不是 after_action（30101 / 30102 auth_unavailable：不拉起授权、只提示）。
    if (reason !== null && info !== undefined) {
      const byReason: RetryKind | undefined = info.retryKindByReason.get(reason);
      if (byReason !== undefined && byReason !== RetryKind.AFTER_ACTION) {
        return new ErrorEffect(EffectKind.TOAST, null, textKey, ReplayKind.NONE, false);
      }
    }
    if (code === 10001 || code === 10004 || code === 10005) {
      const route: string | null = code === 10001 ? 'Login' : code === 10005 ? 'BindPhone' : null;
      if (stepUpOperation) {
        return new ErrorEffect(EffectKind.GUIDE_ONLY, route, textKey, ReplayKind.NONE, false);
      }
      const kind: string = code === 10001 ? EffectKind.LOGIN : code === 10005 ? EffectKind.BIND_PHONE :
      EffectKind.CONSENT;
      return new ErrorEffect(kind, route, textKey, ReplayKind.SAME_KEY, true);
    }
    if (code === 10003) {
      // StepUpSheet 拿到 step_up_token 后沿用原键（BR-ID-08）；Sheet 不登记 pending_action。
      return new ErrorEffect(EffectKind.STEP_UP, null, textKey, ReplayKind.SAME_KEY, false);
    }
    const prerequisite: Prerequisite | undefined = ErrorActionMapper.PREREQUISITES.get(code);
    if (prerequisite !== undefined) {
      if (stepUpOperation || !prerequisite.replayWithNewKey) {
        return new ErrorEffect(EffectKind.GUIDE_ONLY, prerequisite.route, textKey, ReplayKind.NONE, false);
      }
      return new ErrorEffect(prerequisite.effectKind, prerequisite.route, textKey, ReplayKind.NEW_KEY, true);
    }
    const navigation: string | undefined = ErrorActionMapper.NAVIGATIONS.get(code);
    if (navigation !== undefined) {
      return new ErrorEffect(EffectKind.NAVIGATE, navigation, textKey, ReplayKind.NONE, false);
    }
    if (code === 50001 || code === 50401) {
      return new ErrorEffect(EffectKind.GENERIC_ERROR, null, textKey, ReplayKind.NONE, false, 0, true);
    }
    return new ErrorEffect(EffectKind.TOAST, null, textKey, ReplayKind.NONE, false);
  }

  /**
   * error-codes.yaml action 里写明、不是「仅提示」的动作（harmony-review-r1 R1-08 逐项核对；三端对齐清单）。返回 null 走通用判定。
   * 30144：商品卡片重取商品并替换卡片（03 §4.2「重新取卡类动作」）；LinkLanding（fromProductCard=false，或本身就是
   * getLink / getSharePage 落地页取卡）没有卡片数据：page_action 空态、不自动重试（BR-ATTR-05 细则）。
   * 30206 / 30306：按钮置灰（disable_button，disableMillis=0 表示不限时，页面按状态恢复）。
   */
  private static specialAction(input: ErrorActionInput, textKey: string | null): ErrorEffect | null {
    const code: number = input.code;
    const none: string = ReplayKind.NONE;
    if (code === 10007) {
      // 冷静期跳注销进度页（可撤回）；processing 仅提示。
      const stage: Object | undefined = input.data['stage'];
      return stage === 'processing' ? new ErrorEffect(EffectKind.TOAST, null, textKey, none, false) :
        new ErrorEffect(EffectKind.NAVIGATE, 'DeleteAccount', textKey, none, false);
    }
    if (code === 30144) {
      const op: string = input.operation.operationId;
      const landing: boolean = !input.fromProductCard || op === 'getLink' || op === 'getSharePage';
      // 落地页空态用 link_landing.invalid（BR-TEXT-14；error.30144「正在重新获取」只用于商品卡重取，R2-09）。
      return landing ?
        new ErrorEffect(EffectKind.PAGE_ACTION, null, ErrorActionMapper.LINK_LANDING_INVALID, none, false) :
        new ErrorEffect(EffectKind.REFETCH_PRODUCT, null, textKey, none, false);
    }
    if (code === 20001) {
      const fields: string[] = ErrorActionMapper.fieldsOf(input.data);
      if (fields.indexOf('device_hash') >= 0) {
        return new ErrorEffect(EffectKind.REREAD_DEVICE_HASH, null, null, none, false, 0, false, fields);
      }
      return new ErrorEffect(EffectKind.FIELD_ERROR, null, textKey, none, false, 0, false, fields);
    }
    if (code === 20004) {
      const toStepUp: boolean = input.operation.operationId === 'stepUp';
      return new ErrorEffect(EffectKind.REAUTHORIZE, toStepUp ? null : 'Login', textKey, none, false, 0, false, [],
        toStepUp ? ReauthorizeIn.STEP_UP : ReauthorizeIn.LOGIN);
    }
    if (code === 40901) {
      return new ErrorEffect(EffectKind.KEEP_LOADING, null, textKey, none, false);
    }
    if (code === 44001) {
      // 文案取字典 risk_msg.<risk_msg_code>，未命中回落 error.44001。
      const risk: Object | undefined = input.data['risk_msg_code'];
      const riskKey: string | null = typeof risk === 'string' && ErrorActionMapper.hasText('risk_msg.' + risk) ?
        'risk_msg.' + risk : null;
      return new ErrorEffect(EffectKind.PAGE_ACTION, null, riskKey ?? textKey, none, false);
    }
    if (ErrorActionMapper.PAGE_ACTION_CODES.indexOf(code) >= 0) {
      return new ErrorEffect(EffectKind.PAGE_ACTION, null, textKey, none, false);
    }
    if (ErrorActionMapper.DISABLE_CODES.indexOf(code) >= 0) {
      return new ErrorEffect(EffectKind.DISABLE_BUTTON, null, textKey, none, false);
    }
    return null;
  }

  /**
   * 10405（BR-ID-01 细则；03 §4.2「受限会话」）：本机版本不低于 min（或 min 为空）而会话为 deletion_only 的，是升级前
   * 留下的受限令牌——只刷新、不进强更、不显示版本文案，之后由用户重新操作。其余进强更（no_account 取子键文案）。
   */
  private static map10405(input: ErrorActionInput, textKey: string | null): ErrorEffect {
    if (input.state.sessionScope === SessionScope.DELETION_ONLY) {
      const minimum: Object | undefined = input.data['min_supported_version'];
      const atLeast: boolean = minimum === undefined || minimum === null
        || (typeof minimum === 'string' && AppVersion.isAtLeast(input.state.appVersion, minimum as string));
      if (atLeast) {
        return new ErrorEffect(EffectKind.REFRESH_ONLY, null, null, ReplayKind.NONE, false);
      }
    }
    return new ErrorEffect(EffectKind.FORCE_UPDATE, 'ForceUpdate', textKey, ReplayKind.NONE, false);
  }

  /** data.min_supported_version（字符串或 null；缺省或格式不对为 null）。 */
  static minSupportedVersion(data: Record<string, Object>): string | null {
    const minimum: Object | undefined = data['min_supported_version'];
    return typeof minimum === 'string' ? minimum as string : null;
  }

  /** 通用失败文案键（「出了点问题，请稍后再试」，BR-TEXT-14 兜底；搜索 / 详情页的 GENERIC 是同一个键）。 */
  static readonly GENERIC_TEXT_KEY: string = 'error.50001';

  /**
   * 页面按错误码选文案时的 10405 口径（F-X-09 三端统一；APP-13a G62 / G89；FU-HM-0718 第 4 项，对应 Android FU-AND-0715 R1-03）：
   * 只有网络层判定为 FORCE_UPDATE 的 10405 才用 error.10405（版本过低）；REFRESH_ONLY（遗留受限令牌只刷新）与刷新失败
   * （Effect 已换成清会话 / 网络错误）的 10405 不是强更——用统一失败文案、可重试，页面不按错误码再判一次强更。其余同 textKey。
   */
  static pageTextKey(code: number, reason: string | null, effect: ErrorEffect | null): string | null {
    if (code === 10405 && !ErrorActionMapper.forcesUpdate(code, effect)) {
      return ErrorActionMapper.GENERIC_TEXT_KEY;
    }
    return ErrorActionMapper.textKey(code, reason);
  }

  /**
   * 这个业务错误是不是强更（F-X-09 三端统一，Android G89；FU-HM-0718 第 1 轮修复并入 G05）：只认网络层结算的 Effect——10405 且
   * Effect 为 FORCE_UPDATE。REFRESH_ONLY、刷新失败换成的清会话 / 网络错误、没有 Effect（G06）都不是：页面与读取结算不按错误码
   * 再判一次强更（「我的」MeFailure.of、钱包 WalletLoadFailure.of、首页 HomeController 都走这里）。
   */
  static forcesUpdate(code: number, effect: ErrorEffect | null): boolean {
    return code === 10405 && effect !== null && effect.effectKindRaw === EffectKind.FORCE_UPDATE;
  }

  /** 先取 error.<code>.<reason>，未命中回落 error.<code>；都没有为 null（BR-TEXT-14）。 */
  static textKey(code: number, reason: string | null): string | null {
    if (reason !== null && /^[A-Za-z0-9_]+$/.test(reason)) {
      const sub: string = 'error.' + code + '.' + reason;
      if (ErrorActionMapper.hasText(sub)) {
        return sub;
      }
    }
    const parent: string = 'error.' + code;
    return ErrorActionMapper.hasText(parent) ? parent : null;
  }

  /** Retry-After（十进制整数秒）→ 毫秒；缺省或不合法 5 秒。 */
  static retryAfterMillis(headers: Record<string, string>): number {
    const keys: string[] = Object.keys(headers);
    for (const key of keys) {
      if (key.toLowerCase() === 'retry-after') {
        const value: string = String(headers[key]).trim();
        if (/^[0-9]{1,9}$/.test(value)) {
          const seconds: number = Math.min(Number.parseInt(value, 10), ErrorActionMapper.MAX_RETRY_AFTER_SECONDS);
          return seconds * 1000;
        }
        return ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
      }
    }
    return ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
  }

  static isServerError(code: number): boolean {
    return code >= 50000 && code <= 59999;
  }

  /**
   * 表内、没有专门分支、用户侧字典也没有 error.<code> 的码（CT-LOCK-01 R1-01 起 1xxxx；CT-LOCK-02 扩到全部码段）：
   * 客户端不会收到（10008 / 10009、30154、30417、44004 只在 /admin/v1），按表外码的通用回落处理（fallback_message，
   * 服务端 msg 兜底），不新增后台业务处理。由发起页按界面处理的码（PAGE_ACTION_CODES，如 30505、44003）与置灰码不在此列，
   * 行为不变；10002 / 10402 在前面已专门处理。
   */
  private static isTextlessUnhandledCode(code: number): boolean {
    return ErrorActionMapper.PAGE_ACTION_CODES.indexOf(code) < 0 && ErrorActionMapper.DISABLE_CODES.indexOf(code) < 0 &&
      !ErrorActionMapper.hasText('error.' + code);
  }

  private static hasText(key: string): boolean {
    return DefaultTexts.text(key) !== undefined || DefaultTexts.fallback(key) !== undefined;
  }

  /** data.fields（字符串数组；缺省或形状不对为空）。 */
  private static fieldsOf(data: Record<string, Object>): string[] {
    const raw: Object | undefined = data['fields'];
    const out: string[] = [];
    if (raw !== undefined && raw !== null && Array.isArray(raw)) {
      for (const item of raw as Object[]) {
        if (typeof item === 'string') {
          out.push(item as string);
        }
      }
    }
    return out;
  }

  private static reasonOf(data: Record<string, Object>): string | null {
    const reason: Object | undefined = data['reason'];
    return typeof reason === 'string' && (reason as string).length > 0 ? reason as string : null;
  }

  private static buildPrerequisites(): Map<number, Prerequisite> {
    const map: Map<number, Prerequisite> = new Map<number, Prerequisite>();
    // 授权类（error-codes：弹 AuthSheet → 授权 → 用新的幂等键重新发起原请求）。
    map.set(30101, new Prerequisite('AuthSheet', true, EffectKind.AUTHORIZE));
    map.set(30102, new Prerequisite('AuthSheet', true, EffectKind.AUTHORIZE));
    map.set(30111, new Prerequisite('AuthSheet', true, EffectKind.AUTHORIZE));
    // 实名、收款账号（error-codes：完成后回到发起页，不重放原请求）。
    map.set(30304, new Prerequisite('RealName', false, EffectKind.GUIDE_ONLY));
    map.set(30305, new Prerequisite('PayoutAccount', false, EffectKind.GUIDE_ONLY));
    map.set(30307, new Prerequisite('PayoutAccount', false, EffectKind.GUIDE_ONLY));
    map.set(30308, new Prerequisite('PayoutAccount', false, EffectKind.GUIDE_ONLY));
    return map;
  }

  private static buildNavigations(): Map<number, string> {
    const map: Map<number, string> = new Map<number, string>();
    map.set(10006, 'RiskNotice');
    map.set(30143, 'Search');
    map.set(30205, 'FindOrder');
    map.set(30502, 'Search');
    map.set(50302, 'Search');
    return map;
  }
}
