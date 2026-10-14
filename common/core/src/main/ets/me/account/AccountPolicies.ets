// APP-13a 注销账号、换手机号、BindPhone 待确认与入口裁剪的纯规则（brief §2 第 1–9 项；三端同名；向量 specs/account-vectors.json）。
// 只做判定，不发请求、不碰系统接口、不按本机时钟推算能否申请或撤回（G15、G25）；页面与执行器（AccountControllers）按这里的结论落地。
// 键的结束口径按 APP-13a §0 第 1 条（G40），不沿用 APP-09 SensitiveOutcome 普通提交里「5xxxx 结束键」的分支：
// - 键只在三种结果下结束：业务成功；写入了幂等记录的 3xxxx（注销 30412、30416，换号 30411、30414，及表外 3xxxx，G26）；已作废（abandoned / 20903）。
// - 从未出现过结果未知的键：42901、明确的 40901、20001 / 20002 / 20003、44001 之后结束，下次点击用新键（APP-09 编排者补充）。
// - 其余（1xxxx、5xxxx、10405、没有响应等）不结束；nextKeyRaw 表示下一次允许的用户操作（new：补办回来后的新提交；same：待确认里用原键；
//   none：成功结果页暂无提交），不表示收到响应时就生成新键（G40）。harmony-review-r1 R1-02：实际的键去留以 PendingKeyStore 为准——
//   这两个操作从未未知的键只在 42901、40901、20001–20003、44001 与补办码之后删除；10007、5xxxx、10405 等保留为 held，下一次提交沿用
//   原键原体。harmony-review-r2 R2-08（编排者修正向量）：这些分支 nextKeyRaw=same；只有补办码（10001/10004/10005）从未未知时补办后
//   再点用新键（nextKeyRaw=new，brief §2 第 13 项）。
// 规则空白一律按 NATIVE/APP-13a/rule-gaps.md「现在的做法」，代码标 TODO(N-37)。
import { DefaultTexts } from 'generated';
import { ApiOutcome, ApiResult } from '../../network/ApiClient';
import { ErrorActionMapper } from '../../network/ErrorActionMapper';
import { LocalRejectReason, PendingResolution } from '../../network/NetworkPolicy';
import { RoutePolicy } from '../../router/RoutePolicy';
import { trace6Of } from '../../search/SearchController';
import { futureTimeText } from '../MePresentation';
import { AccountJson, AccountRecord, DeletionParse, DeletionRecord } from './AccountJson';

type JSONValue = Object | null;

function obj(): AccountRecord {
  const r: AccountRecord = {};
  return r;
}

function pushAll(target: string[], items: string[]): void {
  for (const item of items) {
    target.push(item);
  }
}

function str(r: AccountRecord | null, key: string): string | null {
  if (r === null) {
    return null;
  }
  const v: JSONValue | undefined = r[key];
  return typeof v === 'string' ? v as string : null;
}

// ---------------------------------------------------------------- 结果输入

/** 一次响应的判定输入（向量 JSON 与 ApiResult 两种来源统一成这一份）。 */
export class AccountResultInput {
  static readonly OK: string = 'ok';
  static readonly ERROR: string = 'error';
  /** 超时、断连、进程被杀、没有统一外壳的网关错误（结果未知）。 */
  static readonly TRANSPORT: string = 'transport';
  static readonly ABANDONED: string = 'abandoned';
  static readonly COMPLETED: string = 'completed';
  /** 没有发出（存储失败、账号不符、键未结清等；不含限流闸门）。 */
  static readonly LOCAL: string = 'local';

  readonly kind: string;
  /** error：业务码；completed：原结果的码；其余 0。 */
  readonly code: number;
  readonly data: AccountRecord | null;
  /** 42901 的禁用毫秒（Retry-After 秒数；缺省或非法 5 秒）；不是 42901 为 0。 */
  readonly disableMs: number;
  readonly traceId: string;
  /** 共享 42901 闸门在实际发包前拦下（没有发出）。 */
  readonly blockedLocally: boolean;

  constructor(kind: string, code: number, data: AccountRecord | null, disableMs: number, traceId: string,
    blockedLocally: boolean = false) {
    this.kind = kind;
    this.code = code;
    this.data = data;
    this.disableMs = disableMs;
    this.traceId = traceId;
    this.blockedLocally = blockedLocally;
  }

  /** 向量 JSON：http / code 为 null 表示没有带外壳的响应；作废阶段的成功看 data.outcome。 */
  static fromJson(phase: string, http: number | null, code: number | null, data: JSONValue, retryAfter: string | null,
    traceId: string | null): AccountResultInput {
    const d: AccountRecord | null = AccountJson.objectOf(data);
    const trace: string = traceId ?? '';
    if (http === null || code === null) {
      return new AccountResultInput(AccountResultInput.TRANSPORT, 0, null, 0, trace);
    }
    if (code === 0 && phase === AccountPhase.ABANDON && d !== null) {
      const outcome: string | null = str(d, 'outcome');
      if (outcome === PendingResolution.ABANDONED) {
        return new AccountResultInput(AccountResultInput.ABANDONED, 0, null, 0, trace);
      }
      const original: AccountRecord | null = AccountJson.objectOf(d['original']);
      const oc: JSONValue | undefined = original === null ? undefined : original['code'];
      if (outcome === PendingResolution.COMPLETED && typeof oc === 'number') {
        return new AccountResultInput(AccountResultInput.COMPLETED, oc as number,
          original === null ? null : AccountJson.objectOf(original['data']), 0, trace);
      }
    }
    if (code === 0) {
      return new AccountResultInput(AccountResultInput.OK, 0, d, 0, trace);
    }
    const headers: Record<string, string> = {};
    if (retryAfter !== null) {
      headers['Retry-After'] = retryAfter;
    }
    return new AccountResultInput(AccountResultInput.ERROR, code, d,
      code === 42901 ? ErrorActionMapper.retryAfterMillis(headers) : 0, trace);
  }

  /** 网络层结果（作废接口的 completed 已由 ApiClient 解包成原结果，pendingResolution 标出）。 */
  static fromResult(result: ApiResult): AccountResultInput {
    if (result.pendingResolution === PendingResolution.ABANDONED) {
      return new AccountResultInput(AccountResultInput.ABANDONED, 0, null, 0, result.traceId);
    }
    if (result.pendingResolution === PendingResolution.COMPLETED) {
      return new AccountResultInput(AccountResultInput.COMPLETED, result.code, result.data as AccountRecord, 0,
        result.traceId);
    }
    if (result.outcome === ApiOutcome.SUCCESS) {
      return new AccountResultInput(AccountResultInput.OK, 0, result.data as AccountRecord, 0, result.traceId);
    }
    if (result.outcome === ApiOutcome.LOCAL_REJECT && result.localRejectReason === LocalRejectReason.SEND_BLOCKED) {
      return new AccountResultInput(AccountResultInput.ERROR, 42901, null, 0, '', true);
    }
    if (result.outcome === ApiOutcome.LOCAL_REJECT) {
      return new AccountResultInput(AccountResultInput.LOCAL, 0, null, 0, '');
    }
    if (result.outcome === ApiOutcome.BUSINESS_ERROR && result.code >= 0) {
      let ms: number = 0;
      if (result.code === 42901) {
        ms = result.effect !== null && result.effect.disableMillis > 0 ? result.effect.disableMillis
          : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS;
      }
      return new AccountResultInput(AccountResultInput.ERROR, result.code, result.data as AccountRecord, ms,
        result.traceId);
    }
    return new AccountResultInput(AccountResultInput.TRANSPORT, 0, null, 0, result.traceId);
  }
}

/** 阶段：apply / submit（用户新提交，从未结果未知）、confirm（原键原体重发）、abandon（作废接口）。 */
export class AccountPhase {
  static readonly APPLY: string = 'apply';
  static readonly SUBMIT: string = 'submit';
  static readonly CONFIRM: string = 'confirm';
  static readonly ABANDON: string = 'abandon';
}

/** 键的去留与下一次允许的操作（G40）。 */
export class KeyEnd {
  static readonly ENDS: string = 'ends';
  static readonly KEEPS: string = 'keeps';
  static readonly NEW: string = 'new';
  static readonly SAME: string = 'same';
  static readonly NONE: string = 'none';
}

/** 一次结果的结局（DeletionOutcomePolicy / PhoneChangeOutcomePolicy 的输出；json() 给向量接线）。 */
export class AccountOutcome {
  keyEnds: boolean = false;
  nextKey: string = KeyEnd.NEW;
  autoResendSameKey: boolean = false;
  stepUpAction: string | null = null;
  nextState: string = '';
  textKey: string | null = null;
  /** completed + 3xxxx：同时有已处理完的轻提示与原结果的错误（G39）。 */
  toastKey: string | null = null;
  /** 返回去向：none / force_update / settings。 */
  navigate: string = 'none';
  refetchDeletion: boolean = false;
  disableMs: number = 0;
  trace6: string | null = null;
  /** 30416 的 {amount}（data.amount_fen；取不到为 null → 契约 fallback 不带金额的句子）。 */
  negativeAmountFen: number | null = null;
  /** 前置补办的目的地（10001 Login、10005 BindPhone、10004 按 consent_type；privacy / agreement 为 null → 重新同意组件）。 */
  guideRoute: string | null = null;
  guideCode: number = 0;
  /** 换号：新号保留、验证码清空、token 保留、字段错误（none / phone / code）、弹窗标题、重取 getMe、清全部 action 的 token。 */
  keepsNewPhone: boolean = true;
  clearsCode: boolean = false;
  keepsToken: boolean = true;
  fieldError: string = 'none';
  dialogTitleKey: string | null = null;
  refetchMe: boolean = false;
  clearsAllStepUpTokens: boolean = false;
  /** 30414：页内提示加【联系客服】（G05）。 */
  showCustomerService: boolean = false;
  /** 表外码且字典没有：用服务端 msg（G26）。 */
  serverMsg: boolean = false;
  /** 本地没有发出（存储失败、账号不符）：键状态以存储为准。 */
  local: boolean = false;
  /** 被共享 42901 闸门在发包前拦下（不再延长截止时间）。 */
  blockedLocally: boolean = false;
  /** 成功的 Deletion（申请、确认成功或放弃得知已受理）。 */
  deletion: DeletionRecord | null = null;

  get keyEndsRaw(): string {
    return this.keyEnds ? KeyEnd.ENDS : KeyEnd.KEEPS;
  }

  jsonBase(): AccountRecord {
    const r: AccountRecord = obj();
    r['keyEndsRaw'] = this.keyEndsRaw;
    r['nextKeyRaw'] = this.nextKey;
    r['autoResendSameKey'] = this.autoResendSameKey;
    r['nextStateRaw'] = this.nextState;
    r['textKey'] = this.textKey;
    r['navigateRaw'] = this.navigate;
    if (this.stepUpAction !== null) {
      r['stepUpAction'] = this.stepUpAction;
    }
    if (this.disableMs > 0) {
      r['disableMs'] = this.disableMs;
    }
    if (this.trace6 !== null) {
      r['trace6'] = this.trace6;
    }
    if (this.toastKey !== null) {
      r['toastKey'] = this.toastKey;
    }
    const keys: string[] = [];
    if (this.toastKey !== null) {
      keys.push(this.toastKey);
    }
    if (this.textKey !== null) {
      keys.push(this.textKey);
    }
    r['textKeys'] = keys;
    return r;
  }

  deletionJson(): AccountRecord {
    const r: AccountRecord = this.jsonBase();
    r['refetchDeletion'] = this.refetchDeletion;
    r['negativeAmountFen'] = this.negativeAmountFen;
    return r;
  }

  phoneJson(): AccountRecord {
    const r: AccountRecord = this.jsonBase();
    r['keepsNewPhone'] = this.keepsNewPhone;
    r['clearsCode'] = this.clearsCode;
    r['keepsToken'] = this.keepsToken;
    r['fieldErrorRaw'] = this.fieldError;
    r['dialogTitleKey'] = this.dialogTitleKey;
    r['refetchMe'] = this.refetchMe;
    r['clearsAllStepUpTokens'] = this.clearsAllStepUpTokens;
    r['showCustomerService'] = this.showCustomerService;
    return r;
  }
}

/** 共用的码 → 文案键与补办去向。 */
export class AccountCodes {
  /** error.<code>（带 reason 子键）；5xxxx 未收录回落 error.50001；字典没有返回 null（G26：调用方用服务端 msg）。 */
  static textKey(code: number, data: AccountRecord | null): string | null {
    if (code >= 50000 && code <= 59999) {
      return ErrorActionMapper.textKey(code, null) ?? 'error.50001';
    }
    return ErrorActionMapper.textKey(code, str(data, 'reason'));
  }

  /** 44001 弹窗标题：risk_msg.<risk_msg_code> 命中字典才用，否则 error.44001（G09、G42）。 */
  static riskTitle(data: AccountRecord | null): string {
    const code: string | null = str(data, 'risk_msg_code');
    if (code !== null && /^[A-Za-z0-9_]+$/.test(code) && DefaultTexts.text('risk_msg.' + code) !== undefined) {
      return 'risk_msg.' + code;
    }
    return 'error.44001';
  }

  /** 前置补办的路由（10001 Login、10005 BindPhone、10004 按 consent_type）；privacy / agreement 等返回 null（重新同意组件）。 */
  static prereqRoute(code: number, data: AccountRecord | null): string | null {
    if (code === 10001) {
      return RoutePolicy.LOGIN;
    }
    if (code === 10005) {
      return RoutePolicy.BIND_PHONE;
    }
    if (code === 10004) {
      const type: string | null = str(data, 'consent_type');
      if (type === 'labor_agreement') {
        return 'LaborAgreement';
      }
      if (type === 'id_verification') {
        return RoutePolicy.REAL_NAME;
      }
    }
    return null;
  }

  static isPrereq(code: number): boolean {
    return code === 10001 || code === 10004 || code === 10005;
  }

  static trace6(traceId: string): string {
    return trace6Of(traceId);
  }
}

// ---------------------------------------------------------------- 注销：结局

/** 申请、确认、放弃的结局（brief §2 第 3 项；向量 deletionOutcomes）。 */
export class DeletionOutcomePolicy {
  static readonly INITIAL: string = 'initial';
  static readonly NEGATIVE: string = 'negative';
  static readonly COOLING: string = 'cooling';
  static readonly STEP_UP: string = 'step_up';
  static readonly PENDING: string = 'pending_confirm';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly UNCHANGED: string = 'unchanged';

  /** 向量接线：JSON 输入 → JSON 输出。 */
  static of(phase: string, http: number | null, code: number | null, data: JSONValue, retryAfter: string | null,
    traceId: string | null, sourceRaw: string, hadUnknownResult: boolean): AccountRecord {
    return DeletionOutcomePolicy.decide(phase, AccountResultInput.fromJson(phase, http, code, data, retryAfter, traceId),
      sourceRaw, hadUnknownResult).deletionJson();
  }

  static decide(phase: string, input: AccountResultInput, sourceRaw: string, hadUnknownResult: boolean): AccountOutcome {
    const unknown: boolean = hadUnknownResult || phase !== AccountPhase.APPLY;
    const out: AccountOutcome = new AccountOutcome();
    out.blockedLocally = input.blockedLocally;
    const forced: boolean = sourceRaw === DeletionSource.FORCE_UPDATE;
    switch (input.kind) {
      case AccountResultInput.OK:
      case AccountResultInput.COMPLETED:
        if (input.kind === AccountResultInput.OK || input.code === 0) {
          return DeletionOutcomePolicy.done(out, input, forced, input.kind === AccountResultInput.COMPLETED);
        }
        return DeletionOutcomePolicy.completedFailure(out, input);
      case AccountResultInput.ABANDONED:
        DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.INITIAL, 'pending_confirm.abandoned');
        return out;
      case AccountResultInput.LOCAL:
        DeletionOutcomePolicy.keeps(out, unknown, DeletionOutcomePolicy.PENDING, 'pending_confirm.retry_later');
        out.nextKey = unknown ? KeyEnd.SAME : KeyEnd.NEW;
        out.nextState = unknown ? DeletionOutcomePolicy.PENDING : DeletionOutcomePolicy.UNCHANGED;
        out.local = true;
        return out;
      case AccountResultInput.TRANSPORT:
        // 没有带外壳的响应：不换键、不自动重发，进待确认（从未未知的提交显示待确认卡；确认 / 放弃仍没结果为 retry_later）。
        DeletionOutcomePolicy.keeps(out, true, DeletionOutcomePolicy.PENDING,
          unknown ? 'pending_confirm.retry_later' : 'pending_confirm.title');
        return out;
      default:
        return DeletionOutcomePolicy.error(out, phase, unknown, input);
    }
  }

  private static ends(out: AccountOutcome, state: string, textKey: string | null): void {
    out.keyEnds = true;
    out.nextKey = KeyEnd.NEW;
    out.nextState = state;
    out.textKey = textKey;
  }

  /**
   * 不结束键：下一次用户操作沿用原键（出现过结果未知的在待确认里确认；从未未知的保留为 held，下次提交原键原体，R2-08、G58）。
   * 例外由调用处改写：补办码从未未知时补办后再点用新键（brief §2 第 13 项）。
   */
  private static keeps(out: AccountOutcome, unknown: boolean, unknownState: string, textKey: string | null,
    knownState: string = DeletionOutcomePolicy.INITIAL): void {
    out.keyEnds = false;
    out.nextKey = KeyEnd.SAME;
    out.nextState = unknown ? unknownState : knownState;
    out.textKey = textKey;
  }

  private static done(out: AccountOutcome, input: AccountResultInput, forced: boolean, completed: boolean): AccountOutcome {
    out.keyEnds = true;
    out.nextKey = KeyEnd.NONE;
    out.nextState = DeletionOutcomePolicy.COOLING;
    out.textKey = completed ? 'pending_confirm.already_done' : null;
    out.navigate = forced ? DeletionOutcomePolicy.FORCE_UPDATE : 'none';
    // 回强更页时重取标签（G28：强更页显示「撤销注销」）。
    out.refetchDeletion = forced;
    const parsed: DeletionParse = AccountJson.deletion(input.data);
    out.deletion = parsed.record;
    return out;
  }

  /** 放弃得到 completed 且原结果是业务失败（3xxxx）：键结束，显示原结果（同时轻提示已处理完，G39）。 */
  private static completedFailure(out: AccountOutcome, input: AccountResultInput): AccountOutcome {
    const code: number = input.code;
    out.toastKey = 'pending_confirm.already_done';
    if (code === 30416) {
      DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.NEGATIVE, 'error.30416');
      out.negativeAmountFen = input.data === null ? null : AccountJson.fen(input.data, 'amount_fen');
      return out;
    }
    const key: string | null = AccountCodes.textKey(code, input.data);
    DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.INITIAL, key);
    out.serverMsg = key === null;
    return out;
  }

  private static error(out: AccountOutcome, phase: string, unknown: boolean, input: AccountResultInput): AccountOutcome {
    const code: number = input.code;
    const data: AccountRecord | null = input.data;
    const abandon: boolean = phase === AccountPhase.ABANDON;
    if (code === 10003 && !abandon) {
      DeletionOutcomePolicy.keeps(out, true, DeletionOutcomePolicy.STEP_UP, 'error.10003');
      out.nextState = DeletionOutcomePolicy.STEP_UP;
      out.autoResendSameKey = true;
      out.stepUpAction = 'account_deletion';
      return out;
    }
    if (code === 10405) {
      DeletionOutcomePolicy.keeps(out, unknown, DeletionOutcomePolicy.FORCE_UPDATE, 'error.10405',
        DeletionOutcomePolicy.FORCE_UPDATE);
      out.navigate = DeletionOutcomePolicy.FORCE_UPDATE;
      return out;
    }
    if (AccountCodes.isPrereq(code)) {
      // 前置补办只回发起页，不自动提交（§0 第 2 条）；出现过结果未知的键补办后仍是待确认。
      DeletionOutcomePolicy.keeps(out, unknown, DeletionOutcomePolicy.PENDING, 'error.' + code);
      out.nextKey = unknown ? KeyEnd.SAME : KeyEnd.NEW;
      out.guideRoute = AccountCodes.prereqRoute(code, data);
      out.guideCode = code;
      return out;
    }
    if (code === 20903) {
      DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.INITIAL, abandon ? 'pending_confirm.abandoned' : 'error.20903');
      return out;
    }
    if (abandon) {
      if (code === 40901) {
        DeletionOutcomePolicy.keeps(out, true, DeletionOutcomePolicy.PENDING, 'pending_confirm.abandon_busy');
        return out;
      }
      DeletionOutcomePolicy.keeps(out, true, DeletionOutcomePolicy.PENDING, 'pending_confirm.retry_later');
      DeletionOutcomePolicy.decorate(out, input);
      return out;
    }
    if (code === 10007) {
      // G27：停在本页、重取 getDeletion（cooling），键不结束（1xxxx 说明不了这个键有没有结果）；processing 只提示。
      out.keyEnds = false;
      out.nextKey = KeyEnd.SAME;
      out.nextState = unknown ? DeletionOutcomePolicy.PENDING : DeletionOutcomePolicy.UNCHANGED;
      out.textKey = 'error.10007';
      out.refetchDeletion = str(data, 'stage') !== 'processing';
      return out;
    }
    if (code === 42901) {
      if (unknown) {
        DeletionOutcomePolicy.keeps(out, true, DeletionOutcomePolicy.PENDING, 'pending_confirm.retry_later');
      } else {
        DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.INITIAL, 'error.42901');
      }
      DeletionOutcomePolicy.decorate(out, input);
      return out;
    }
    if (code >= 50000 && code <= 59999) {
      DeletionOutcomePolicy.keeps(out, unknown, DeletionOutcomePolicy.PENDING,
        unknown ? 'pending_confirm.retry_later' : AccountCodes.textKey(code, null));
      DeletionOutcomePolicy.decorate(out, input);
      return out;
    }
    if (code === 40901 || code === 44001 || code === 20001 || code === 20002 || code === 20003) {
      if (unknown) {
        DeletionOutcomePolicy.keeps(out, true, DeletionOutcomePolicy.PENDING,
          code === 40901 || code === 44001 ? 'pending_confirm.retry_later' : 'pending_confirm.cannot_confirm');
      } else {
        DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.INITIAL,
          code === 44001 ? AccountCodes.riskTitle(data) : AccountCodes.textKey(code, data));
      }
      return out;
    }
    if (code >= 30000 && code <= 39999) {
      if (code === 30416) {
        DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.NEGATIVE, 'error.30416');
        out.negativeAmountFen = data === null ? null : AccountJson.fen(data, 'amount_fen');
        return out;
      }
      // 30412 与表外 3xxxx（G26）：写入了幂等记录，键结束；字典没有的用服务端 msg。
      const key: string | null = AccountCodes.textKey(code, data);
      DeletionOutcomePolicy.ends(out, DeletionOutcomePolicy.INITIAL, key);
      out.serverMsg = key === null;
      return out;
    }
    if (code >= 20000 && code <= 29999) {
      if (unknown) {
        DeletionOutcomePolicy.keeps(out, true, DeletionOutcomePolicy.PENDING, 'pending_confirm.cannot_confirm');
      } else {
        // brief §0 第 1 条：20001 / 20002 / 20003（上面已处理）以外的 2xxxx 不结束键（R1-02：存储层同样保留原键）。
        DeletionOutcomePolicy.keeps(out, false, DeletionOutcomePolicy.PENDING, AccountCodes.textKey(code, data));
        out.serverMsg = out.textKey === null;
      }
      return out;
    }
    // 其余 1xxxx、4xxxx（G26）：不结束键，按通用错误提示。
    const key: string | null = AccountCodes.textKey(code, data);
    DeletionOutcomePolicy.keeps(out, unknown, DeletionOutcomePolicy.PENDING,
      unknown ? 'pending_confirm.retry_later' : key);
    out.serverMsg = !unknown && key === null;
    return out;
  }

  /** 42901 的禁用毫秒与 5xxxx 的 trace6（任何阶段都带）。 */
  private static decorate(out: AccountOutcome, input: AccountResultInput): void {
    if (input.code === 42901) {
      out.disableMs = input.blockedLocally ? 0 : (input.disableMs > 0 ? input.disableMs
        : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS);
    }
    if (input.code >= 50000 && input.code <= 59999) {
      out.trace6 = AccountCodes.trace6(input.traceId);
    }
  }
}

/** 进入注销页的来源（brief §2 第 2 项；只在本端内部流转，不是路由参数，G21）。 */
export class DeletionSource {
  static readonly SETTINGS: string = 'settings';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly RISK_NOTICE: string = 'risk_notice';
  static readonly ERROR_10007: string = 'error_10007';
  static readonly OTHER: string = 'other';
}

// ---------------------------------------------------------------- 注销：撤回

/** 【撤回注销】的结局（brief §2 第 4 项，G16、G17、G18；向量 deletionCancel）。cancelDeletion 不签名、不幂等，不写未决记录。 */
export class DeletionCancelPolicy {
  static of(http: number | null, code: number | null, data: JSONValue, sourceRaw: string,
    retryAfter: string | null = null, traceId: string | null = null): AccountRecord {
    const input: AccountResultInput = AccountResultInput.fromJson(AccountPhase.APPLY, http, code, data, retryAfter,
      traceId);
    return DeletionCancelPolicy.decide(input, sourceRaw).cancelJson();
  }

  static decide(input: AccountResultInput, sourceRaw: string): CancelOutcome {
    const out: CancelOutcome = new CancelOutcome();
    if (input.kind === AccountResultInput.OK) {
      out.nextState = DeletionOutcomePolicy.INITIAL;
      out.textKey = 'deletion.cancelled_toast';
      out.navigate = sourceRaw === DeletionSource.SETTINGS ? 'settings'
        : sourceRaw === DeletionSource.FORCE_UPDATE ? DeletionOutcomePolicy.FORCE_UPDATE : 'none';
      out.refetchDeletion = sourceRaw === DeletionSource.FORCE_UPDATE;
      out.deletion = AccountJson.deletion(input.data).record;
      return out;
    }
    out.nextState = DeletionOutcomePolicy.COOLING;
    if (input.kind === AccountResultInput.TRANSPORT) {
      // G17：不自动重发，提示后重取 getDeletion，由用户再点（服务端重复撤回返回已撤回的那条）。
      out.textKey = 'deletion.cooling.cancel_unknown';
      out.refetchDeletion = true;
      return out;
    }
    if (input.kind === AccountResultInput.LOCAL) {
      out.textKey = 'pending_confirm.retry_later';
      return out;
    }
    const code: number = input.code;
    if (code === 10007) {
      out.textKey = 'deletion.cooling.cancel_expired';
      out.refetchDeletion = true;
      return out;
    }
    if (code === 42901) {
      out.textKey = 'error.42901';
      out.disableMs = input.blockedLocally ? 0 : (input.disableMs > 0 ? input.disableMs
        : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS);
      out.blockedLocally = input.blockedLocally;
      return out;
    }
    if (code >= 50000 && code <= 59999) {
      out.textKey = AccountCodes.textKey(code, null);
      out.trace6 = AccountCodes.trace6(input.traceId);
      return out;
    }
    if (code === 10405) {
      out.textKey = 'error.10405';
      out.forceUpdate = true;
      return out;
    }
    const key: string | null = AccountCodes.textKey(code, input.data);
    out.textKey = key;
    out.serverMsg = key === null;
    return out;
  }
}

export class CancelOutcome {
  nextState: string = '';
  textKey: string | null = null;
  navigate: string = 'none';
  refetchDeletion: boolean = false;
  disableMs: number = 0;
  trace6: string | null = null;
  forceUpdate: boolean = false;
  serverMsg: boolean = false;
  blockedLocally: boolean = false;
  deletion: DeletionRecord | null = null;

  cancelJson(): AccountRecord {
    const r: AccountRecord = obj();
    r['nextStateRaw'] = this.nextState;
    r['textKey'] = this.textKey;
    r['navigateRaw'] = this.navigate;
    r['autoResend'] = false;
    r['refetchDeletion'] = this.refetchDeletion;
    r['writesPendingKey'] = false;
    if (this.disableMs > 0) {
      r['disableMs'] = this.disableMs;
    }
    if (this.trace6 !== null) {
      r['trace6'] = this.trace6;
    }
    return r;
  }
}

// ---------------------------------------------------------------- 注销：显示规则

/** 资金区三项（只用服务端字段，不相加、不推算，G11）。 */
export class DeletionFunds {
  readonly withdrawableFen: number;
  readonly estimatedFen: number;
  readonly negativeFen: number;

  constructor(withdrawableFen: number, estimatedFen: number, negativeFen: number) {
    this.withdrawableFen = withdrawableFen;
    this.estimatedFen = estimatedFen;
    this.negativeFen = negativeFen;
  }

  /** 钱包摘要里的三个字段（缺一或不是整数分 → null，按读取失败）。 */
  static of(summary: JSONValue | undefined): DeletionFunds | null {
    const r: AccountRecord | null = AccountJson.objectOf(summary);
    if (r === null) {
      return null;
    }
    const w: number | null = AccountJson.fen(r, 'withdrawable_fen');
    const e: number | null = AccountJson.fen(r, 'estimated_total_fen');
    const n: number | null = AccountJson.fen(r, 'negative_fen');
    return w === null || e === null || n === null ? null : new DeletionFunds(w, e, n);
  }
}

/**
 * 注销页显示规则（brief §2 第 2 项；向量 deletionView）。优先级：pending_confirm > load_failed > cooling / processing > negative >
 * funds_unavailable > no_phone_step_up > initial（G37：no_phone 与 negative / funds_unavailable 的相互次序未裁定，按「申请已不可用的先显示」
 * 保守排在后面，TODO(N-37)）。cancelled 一律按 initial / negative（G20、G46）；done 按 processing 兜底。客户端不按本机时钟推算能不能撤回
 * （G15）：【撤回注销】只看 can_cancel。
 */
export class DeletionPresentation {
  static readonly INITIAL: string = 'initial';
  static readonly NEGATIVE: string = 'negative';
  static readonly FUNDS_UNAVAILABLE: string = 'funds_unavailable';
  static readonly COOLING: string = 'cooling';
  static readonly PROCESSING: string = 'processing';
  static readonly PENDING: string = 'pending_confirm';
  static readonly NO_PHONE: string = 'no_phone_step_up';
  static readonly LOAD_FAILED: string = 'load_failed';
  static readonly LOADING: string = 'loading';

  /**
   * deletion：Deletion 原始对象 / null（从未申请）/ 'load_failed'（读取失败或坏数据）/ 'loading'；wallet：钱包摘要原始对象 / 'failed' /
   * 'loading'；phoneBoundRaw：true / false / unknown；pendingRaw：none / in_flight / unknown；scopeRaw：full / deletion_only；
   * sourceRaw：DeletionSource。
   */
  static of(deletion: JSONValue | undefined, wallet: JSONValue | undefined, phoneBoundRaw: string, pendingRaw: string,
    scopeRaw: string, sourceRaw: string, nowMs: number): AccountRecord {
    let parse: DeletionParse | null = null;
    if (deletion === 'loading') {
      parse = null;
    } else if (typeof deletion === 'string') {
      parse = DeletionParse.bad();
    } else {
      parse = AccountJson.deletion(deletion === undefined ? undefined : deletion);
    }
    const funds: DeletionFunds | null = wallet === 'failed' || wallet === 'loading' ? null : DeletionFunds.of(wallet);
    return DeletionPresentation.view(parse, deletion === 'loading', funds, wallet === 'loading', phoneBoundRaw,
      pendingRaw, scopeRaw, sourceRaw, nowMs);
  }

  /** 页面用的同一规则（解析过的输入）。deletionLoading / walletLoading：首轮读取还没回来。 */
  static view(parse: DeletionParse | null, deletionLoading: boolean, funds: DeletionFunds | null, walletLoading: boolean,
    phoneBoundRaw: string, pendingRaw: string, scopeRaw: string, sourceRaw: string, nowMs: number): AccountRecord {
    const out: AccountRecord = obj();
    const keys: string[] = [];
    const full: boolean = scopeRaw === 'full';
    const withdrawEntry: boolean = full && sourceRaw !== DeletionSource.FORCE_UPDATE;
    let state: string = DeletionPresentation.INITIAL;
    let apply: boolean = false;
    let goWithdraw: boolean = false;
    let showCancel: boolean = false;
    let negative: number | null = null;
    const record: DeletionRecord | null = parse === null ? null : parse.record;
    const fundsKeys: string[] = ['deletion.funds.title', 'deletion.withdrawable', 'deletion.estimated'];
    const noticeKeys: string[] = ['deletion.notice.title', 'deletion.notice.1', 'deletion.notice.2', 'deletion.notice.3',
      'deletion.notice.4', 'deletion.notice.5', 'deletion.notice.6'];
    if (pendingRaw === 'unknown') {
      // BR-ID-10「发起页按未决记录进入待确认」：不按 getDeletion 自行结束这个键。
      state = DeletionPresentation.PENDING;
      keys.push('pending_confirm.title', 'pending_confirm.deletion.desc', 'pending_confirm.deletion.action',
        'pending_confirm.abandon', 'pending_confirm.summary.operation', 'pending_confirm.summary.operation.deletion',
        'pending_confirm.summary.waiver', 'deletion.waiver', 'pending_confirm.summary.submitted_at',
        'deletion.pending_card_hint', 'deletion.pending_hint');
      if (funds !== null) {
        pushAll(keys, fundsKeys);
        goWithdraw = withdrawEntry;
      }
      pushAll(keys, noticeKeys);
    } else if (parse !== null && parse.kind === DeletionParse.BAD) {
      state = DeletionPresentation.LOAD_FAILED;
      keys.push('deletion.load_failed');
    } else if (deletionLoading || parse === null) {
      state = DeletionPresentation.LOADING;
    } else if (record !== null && record.status === DeletionRecord.COOLING) {
      state = DeletionPresentation.COOLING;
      showCancel = record.canCancel;
      out['coolingUntilText'] = futureTimeText(record.coolingUntilMs, nowMs);
      out['applyAtText'] = futureTimeText(record.applyAtMs, nowMs);
      keys.push('deletion.cooling.badge', 'deletion.cooling.title', 'deletion.cooling.deadline',
        'deletion.cooling.timeline.apply', 'deletion.cooling.timeline.cooling', 'deletion.cooling.timeline.cooling_desc',
        'deletion.cooling.timeline.process', 'deletion.cooling.timeline.process_desc', 'deletion.cooling.readonly');
      if (record.canCancel) {
        keys.push('deletion.cooling.restore', 'deletion.cooling.cancel');
      } else {
        // G15：冷静期已过、定时任务还没跑：不给【撤回注销】，显示 error.10007 与说明（草稿）。
        keys.push('error.10007', 'deletion.cooling.cancel_expired');
      }
    } else if (record !== null && (record.status === DeletionRecord.PROCESSING || record.status === DeletionRecord.DONE)) {
      state = DeletionPresentation.PROCESSING;
      keys.push('error.10007');
    } else if (funds !== null && funds.negativeFen > 0) {
      state = DeletionPresentation.NEGATIVE;
      negative = funds.negativeFen;
      keys.push('error.30416', 'deletion.contact_cs');
      pushAll(keys, fundsKeys);
      keys.push('deletion.negative', 'deletion.negative.note');
      pushAll(keys, noticeKeys);
      keys.push('deletion.submit');
    } else if (funds === null && !walletLoading) {
      state = DeletionPresentation.FUNDS_UNAVAILABLE;
      keys.push('deletion.funds.title', 'deletion.funds_failed');
      pushAll(keys, noticeKeys);
      keys.push('deletion.submit');
    } else if (funds === null) {
      state = DeletionPresentation.LOADING;
    } else {
      state = phoneBoundRaw === 'false' ? DeletionPresentation.NO_PHONE : DeletionPresentation.INITIAL;
      apply = true;
      goWithdraw = withdrawEntry;
      keys.push('deletion.intro');
      pushAll(keys, fundsKeys);
      keys.push('deletion.withdraw_hint');
      pushAll(keys, noticeKeys);
      keys.push('deletion.waiver', 'deletion.submit', 'deletion.submit_hint');
      if (withdrawEntry) {
        keys.push('deletion.go_withdraw');
      }
      if (state === DeletionPresentation.NO_PHONE) {
        keys.push('deletion.step_up_unsupported');
        if (full) {
          keys.push('deletion.bind_phone');
        }
      }
    }
    if (pendingRaw === 'in_flight') {
      // G37：别的页面实例的首次提交还在途（没有结论）：申请置灰，等结算通知后重新同步。
      apply = false;
      out['inFlight'] = true;
    }
    out['stateRaw'] = state;
    out['applyEnabledWhenChecked'] = apply;
    out['showGoWithdraw'] = goWithdraw && funds !== null;
    out['showCancelDeletion'] = showCancel;
    out['negativeAmountFen'] = negative;
    out['showFunds'] = funds !== null && (state === DeletionPresentation.INITIAL || state === DeletionPresentation.NO_PHONE
      || state === DeletionPresentation.NEGATIVE || state === DeletionPresentation.PENDING);
    if (funds !== null) {
      out['withdrawableFen'] = funds.withdrawableFen;
      out['estimatedFen'] = funds.estimatedFen;
      out['negativeFen'] = funds.negativeFen;
    }
    // G10：phone_bound 未知时【申请注销】可点，点后先重取 getMe（不按未绑定直接拦，也不预先置灰）。
    out['phoneRefetchOnApply'] = phoneBoundRaw === 'unknown';
    out['bindPhoneEntry'] = state === DeletionPresentation.NO_PHONE && full;
    out['textKeys'] = keys;
    return out;
  }
}

// ---------------------------------------------------------------- 换手机号

/** 换号第 1 步（验证当前手机号）的发码与验证结局（brief §2 第 5 项；向量 phoneChangeStep1）。 */
export class PhoneChangeStep1Policy {
  static readonly SEND_CODE: string = 'send_code';
  static readonly VERIFY: string = 'verify';

  static of(eventRaw: string, http: number | null, code: number | null, data: JSONValue,
    phoneKnown: boolean): AccountRecord {
    const r: AccountRecord = obj();
    if (!phoneKnown) {
      // G02：本机取不到绑定账号归属的号码：不编造、不让用户另填，提示并置灰，不发请求。
      r['allowed'] = false;
      r['textKey'] = 'step_up.no_phone';
      r['clearsCode'] = false;
      r['assertive'] = false;
      r['advancesToStep2'] = false;
      r['tokenStored'] = false;
      return r;
    }
    r['allowed'] = true;
    r['advancesToStep2'] = false;
    r['tokenStored'] = false;
    r['clearsCode'] = false;
    if (http === null || code === null) {
      r['textKey'] = 'pending_confirm.retry_later';
      r['assertive'] = true;
      return r;
    }
    if (code === 0) {
      if (eventRaw === PhoneChangeStep1Policy.SEND_CODE) {
        r['textKey'] = 'phone_change.code_sent';
        r['assertive'] = false;
        return r;
      }
      const d: AccountRecord | null = AccountJson.objectOf(data);
      const token: string | null = str(d, 'step_up_token');
      r['textKey'] = null;
      r['assertive'] = false;
      r['advancesToStep2'] = token !== null && token.length > 0;
      r['tokenStored'] = token !== null && token.length > 0;
      return r;
    }
    r['assertive'] = true;
    if (eventRaw === PhoneChangeStep1Policy.VERIFY && (code === 20002 || code === 20003)) {
      r['textKey'] = 'error.' + code;
      r['clearsCode'] = true;
      return r;
    }
    r['textKey'] = AccountCodes.textKey(code, AccountJson.objectOf(data)) ?? 'error.50001';
    return r;
  }
}

/** 换号第 2 步提交、确认、放弃的结局（brief §2 第 5 项；向量 phoneChangeSubmit）。 */
export class PhoneChangeOutcomePolicy {
  static readonly DONE: string = 'done';
  static readonly STEP1: string = 'step1';
  static readonly STEP2: string = 'step2';
  static readonly BLOCKED: string = 'blocked_dialog';
  static readonly PENDING: string = 'pending_confirm';
  static readonly FORCE_UPDATE: string = 'force_update';

  static of(phaseRaw: string, http: number | null, code: number | null, data: JSONValue, retryAfter: string | null,
    traceId: string | null, tokenValid: boolean): AccountRecord {
    return PhoneChangeOutcomePolicy.decide(phaseRaw,
      AccountResultInput.fromJson(phaseRaw, http, code, data, retryAfter, traceId), tokenValid).phoneJson();
  }

  static decide(phase: string, input: AccountResultInput, tokenValid: boolean): AccountOutcome {
    const out: AccountOutcome = new AccountOutcome();
    out.blockedLocally = input.blockedLocally;
    const unknown: boolean = phase !== AccountPhase.SUBMIT && phase !== AccountPhase.APPLY;
    out.keepsToken = tokenValid;
    switch (input.kind) {
      case AccountResultInput.OK:
        return PhoneChangeOutcomePolicy.done(out, null);
      case AccountResultInput.COMPLETED:
        if (input.code === 0) {
          return PhoneChangeOutcomePolicy.done(out, 'pending_confirm.already_done');
        }
        PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP2, AccountCodes.textKey(input.code, input.data));
        out.toastKey = 'pending_confirm.already_done';
        out.serverMsg = out.textKey === null;
        return out;
      case AccountResultInput.ABANDONED:
        PhoneChangeOutcomePolicy.restart(out, 'pending_confirm.abandoned');
        return out;
      case AccountResultInput.LOCAL:
        PhoneChangeOutcomePolicy.keeps(out, unknown, 'pending_confirm.retry_later', PhoneChangeOutcomePolicy.STEP2);
        out.nextKey = unknown ? KeyEnd.SAME : KeyEnd.NEW;
        out.local = true;
        return out;
      case AccountResultInput.TRANSPORT:
        PhoneChangeOutcomePolicy.keeps(out, true, unknown ? 'pending_confirm.retry_later' : 'pending_confirm.title',
          PhoneChangeOutcomePolicy.STEP2);
        return out;
      default:
        return PhoneChangeOutcomePolicy.error(out, phase, unknown, input);
    }
  }

  /** 成功：结果页（新号的本机脱敏）；刷新 getMe、丢弃全部 action 的 step_up_token（G04）。 */
  private static done(out: AccountOutcome, toast: string | null): AccountOutcome {
    out.keyEnds = true;
    out.nextKey = KeyEnd.NONE;
    out.nextState = PhoneChangeOutcomePolicy.DONE;
    out.textKey = toast ?? 'phone_change.done.title';
    out.keepsNewPhone = true;
    out.keepsToken = false;
    out.refetchMe = true;
    out.clearsAllStepUpTokens = true;
    return out;
  }

  private static ends(out: AccountOutcome, state: string, textKey: string | null): void {
    out.keyEnds = true;
    out.nextKey = KeyEnd.NEW;
    out.nextState = state;
    out.textKey = textKey;
  }

  /** 20903 / 放弃得到 abandoned：回第 1 步、清空表单、丢弃 token（G23）。 */
  private static restart(out: AccountOutcome, textKey: string): void {
    PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP1, textKey);
    out.keepsNewPhone = false;
    out.clearsCode = true;
    out.keepsToken = false;
  }

  /** 不结束键：下一次用户操作沿用原键（R2-08、G58）；补办码从未未知时由调用处改为新键。 */
  private static keeps(out: AccountOutcome, unknown: boolean, textKey: string | null, knownState: string): void {
    out.keyEnds = false;
    out.nextKey = KeyEnd.SAME;
    out.nextState = unknown ? PhoneChangeOutcomePolicy.PENDING : knownState;
    out.textKey = textKey;
  }

  private static error(out: AccountOutcome, phase: string, unknown: boolean, input: AccountResultInput): AccountOutcome {
    const code: number = input.code;
    const data: AccountRecord | null = input.data;
    const abandon: boolean = phase === AccountPhase.ABANDON;
    if (code === 10003 && !abandon) {
      // token 过期或被拒：二次验证面板（phone_change），拿到新 token 后沿用原键重放 1 次。
      out.keyEnds = false;
      out.nextKey = KeyEnd.SAME;
      out.autoResendSameKey = true;
      out.stepUpAction = 'phone_change';
      out.nextState = unknown ? PhoneChangeOutcomePolicy.PENDING : PhoneChangeOutcomePolicy.STEP2;
      out.textKey = 'error.10003';
      out.keepsToken = false;
      return out;
    }
    if (code === 10405) {
      PhoneChangeOutcomePolicy.keeps(out, unknown, 'error.10405', PhoneChangeOutcomePolicy.FORCE_UPDATE);
      out.nextState = PhoneChangeOutcomePolicy.FORCE_UPDATE;
      out.navigate = PhoneChangeOutcomePolicy.FORCE_UPDATE;
      return out;
    }
    if (AccountCodes.isPrereq(code)) {
      // 补办后回本步：新号保留、验证码清空，不自动提交（§0 第 2 条，G39）。
      PhoneChangeOutcomePolicy.keeps(out, unknown, 'error.' + code, PhoneChangeOutcomePolicy.STEP2);
      out.nextKey = unknown ? KeyEnd.SAME : KeyEnd.NEW;
      out.clearsCode = true;
      out.guideRoute = AccountCodes.prereqRoute(code, data);
      out.guideCode = code;
      return out;
    }
    if (code === 20903) {
      PhoneChangeOutcomePolicy.restart(out, abandon ? 'pending_confirm.abandoned' : 'error.20903');
      return out;
    }
    if (abandon) {
      PhoneChangeOutcomePolicy.keeps(out, true, code === 40901 ? 'pending_confirm.abandon_busy'
        : 'pending_confirm.retry_later', PhoneChangeOutcomePolicy.STEP2);
      PhoneChangeOutcomePolicy.decorate(out, input);
      return out;
    }
    if (unknown) {
      // 确认（原键原体）：3xxxx 结束键并显示原结果；20903 以外的 2xxxx → cannot_confirm（不在字段旁标红，PhoneChangePendingStill）；
      // 其余（40901、42901、5xxxx、44001、没有响应）→ retry_later，保持待确认（G09：出现过结果未知的键 44001 不结束）。
      if (code >= 30000 && code <= 39999) {
        PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP2, AccountCodes.textKey(code, data));
        out.showCustomerService = code === 30414;
        out.serverMsg = out.textKey === null;
        return out;
      }
      if (code >= 20000 && code <= 29999) {
        PhoneChangeOutcomePolicy.keeps(out, true, 'pending_confirm.cannot_confirm', PhoneChangeOutcomePolicy.STEP2);
        return out;
      }
      PhoneChangeOutcomePolicy.keeps(out, true, 'pending_confirm.retry_later', PhoneChangeOutcomePolicy.STEP2);
      PhoneChangeOutcomePolicy.decorate(out, input);
      return out;
    }
    if (code === 20001) {
      // G33：服务端规范化；phone_invalid 时在新号旁提示，保留新号与 token，键结束。
      PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP2, AccountCodes.textKey(20001, data) ?? 'error.20001');
      out.fieldError = PhoneChangeOutcomePolicy.field(data);
      return out;
    }
    if (code === 20002 || code === 20003) {
      // BR-ID-08 例：新号验证码错误不核销 token，5 分钟内修正后重提。20003 清空码。
      PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP2, 'error.' + code);
      out.fieldError = 'code';
      out.clearsCode = code === 20003;
      return out;
    }
    if (code === 44001) {
      // G09：PhoneChangeNewBlocked 弹窗；新号保留、验证码清空、留在第 2 步；从未未知的键结束。
      PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.BLOCKED, 'phone_change.risk_blocked.desc');
      out.clearsCode = true;
      out.dialogTitleKey = AccountCodes.riskTitle(data);
      return out;
    }
    if (code === 42901) {
      PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP2, 'error.42901');
      PhoneChangeOutcomePolicy.decorate(out, input);
      return out;
    }
    if (code === 40901) {
      PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP2, 'error.40901');
      return out;
    }
    if (code >= 50000 && code <= 59999) {
      PhoneChangeOutcomePolicy.keeps(out, false, AccountCodes.textKey(code, null), PhoneChangeOutcomePolicy.STEP2);
      PhoneChangeOutcomePolicy.decorate(out, input);
      return out;
    }
    if (code >= 30000 && code <= 39999) {
      // 30411（不论 reason 是否 mergeable，G08：换号不进并号）、30414（G05：加【联系客服】）与表外 3xxxx：键结束，新号与 token 保留。
      PhoneChangeOutcomePolicy.ends(out, PhoneChangeOutcomePolicy.STEP2, code === 30411 ? 'error.30411'
        : AccountCodes.textKey(code, data));
      out.showCustomerService = code === 30414;
      out.serverMsg = out.textKey === null;
      return out;
    }
    const key: string | null = AccountCodes.textKey(code, data);
    PhoneChangeOutcomePolicy.keeps(out, false, key, PhoneChangeOutcomePolicy.STEP2);
    out.serverMsg = key === null;
    return out;
  }

  private static field(data: AccountRecord | null): string {
    const fields: JSONValue | undefined = data === null ? undefined : data['fields'];
    if (Array.isArray(fields) && (fields as JSONValue[]).length > 0 && (fields as JSONValue[])[0] === 'code') {
      return 'code';
    }
    return 'phone';
  }

  private static decorate(out: AccountOutcome, input: AccountResultInput): void {
    if (input.code === 42901) {
      out.disableMs = input.blockedLocally ? 0 : (input.disableMs > 0 ? input.disableMs
        : ErrorActionMapper.DEFAULT_RETRY_AFTER_MILLIS);
    }
    if (input.code >= 50000 && input.code <= 59999) {
      out.trace6 = AccountCodes.trace6(input.traceId);
    }
  }
}

// ---------------------------------------------------------------- 脱敏摘要

/** 待确认摘要里的手机号（G24、BR-ID-33）：取输入里的数字，正好 11 位才显示为前 3 后 4（139****1234），否则不带号码（用 fallbacks）。 */
export class PhoneMask {
  static summary(input: string): string | null {
    const digits: string = input.replace(/[^0-9]/g, '');
    if (digits.length !== 11) {
      return null;
    }
    return digits.substring(0, 3) + '****' + digits.substring(7);
  }

  /** 待确认摘要（写未决记录时由本机生成；原文只在安全存储的请求体里）。 */
  static pendingSummary(input: string): string {
    const r: AccountRecord = obj();
    r['op'] = 'phone';
    r['phone_masked'] = PhoneMask.summary(input);
    return JSON.stringify(r);
  }

  /** 摘要里的脱敏号码：本任务写的 JSON 摘要，或 APP-05b 首次绑定写的纯脱敏串（139****1234）；都不是为 null。 */
  static fromSummary(summary: string): string | null {
    if (/^\d{3}\*{4}\d{4}$/.test(summary)) {
      return summary;
    }
    try {
      const r: AccountRecord | null = AccountJson.objectOf(JSON.parse(summary) as Object);
      const m: string | null = str(r, 'phone_masked');
      return m !== null && /^\d{3}\*{4}\d{4}$/.test(m) ? m : null;
    } catch (e) {
      return null;
    }
  }
}

/** 注销的待确认摘要（G24）：固定「提交的操作：申请注销账号」「已勾选：放弃未提现余额和预估收益」，不含任何号码或金额。 */
export class DeletionSummary {
  static pendingSummary(): string {
    const r: AccountRecord = obj();
    r['op'] = 'account_deletion';
    r['waiver'] = true;
    return JSON.stringify(r);
  }
}

// ---------------------------------------------------------------- 二次验证 token

/**
 * token 的复用条件（brief §2 第 7 项，APP-09 G17、APP-13a G23；向量 stepUpToken）：action、会话作用域、会话世代、账号都一致，且本机时钟
 * 早于 expire_at 才复用；受限会话（deletion_only）下只允许 account_deletion，其他 action 本地拒绝（scope_denied）。
 */
export class StepUpTokenPolicy {
  static reuse(cached: AccountRecord | null, request: AccountRecord): AccountRecord {
    const out: AccountRecord = obj();
    const action: string | null = str(request, 'action');
    const scope: string | null = str(request, 'scopeRaw');
    if (scope === 'deletion_only' && action !== 'account_deletion') {
      out['reuse'] = false;
      out['localRejectRaw'] = 'scope_denied';
      return out;
    }
    out['localRejectRaw'] = 'none';
    if (cached === null) {
      out['reuse'] = false;
      return out;
    }
    const now: JSONValue | undefined = request['nowMs'];
    const expire: JSONValue | undefined = cached['expireAtMs'];
    out['reuse'] = action !== null && str(cached, 'action') === action && str(cached, 'scopeRaw') === scope
      && cached['sessionGen'] === request['sessionGen'] && str(cached, 'accountId') === str(request, 'accountId')
      && str(cached, 'accountId') !== null && typeof now === 'number' && typeof expire === 'number'
      && (now as number) < (expire as number);
    return out;
  }
}

// ---------------------------------------------------------------- 入口裁剪

/**
 * 入口裁剪（brief §0 第 4 条、§2 第 5、8、9 项，编排者补充 G01、G02；向量 entryTrim）。sessionRaw：basic / guest / member / deletion_only；
 * deleteAccountAvailable：Router 的路由可用性（since 满足；Release 里 since=null 恒为 false，Debug 可用覆盖开关）；ownedPhoneKnown（G34）：
 * 本机有当前账号绑定了归属的规范化号码（取得到才让「手机号」行进换号第 1 步，取不到保持不可点，编排者补充 G02）。
 */
export class AccountEntryPolicy {
  static readonly HIDDEN: string = 'hidden';
  static readonly BIND_PHONE: string = 'bind_phone';
  static readonly PHONE_CHANGE: string = 'phone_change';
  static readonly DISABLED: string = 'disabled';

  static of(sessionRaw: string, forceUpdate: boolean, phoneBoundRaw: string, deleteAccountAvailable: boolean,
    deletion: JSONValue | undefined, ownedPhoneKnown: boolean = false): AccountRecord {
    const out: AccountRecord = obj();
    out['phoneRowRaw'] = AccountEntryPolicy.phoneRow(sessionRaw, forceUpdate, phoneBoundRaw, ownedPhoneKnown);
    // 设置「注销账号」：只在已登录（完整会话）、非强更时，且路由可用（G01）。deletion_only 未强更时不显示（G34 未裁定，保守）。
    out['deletionRowShown'] = sessionRaw === 'member' && !forceUpdate && deleteAccountAvailable;
    out['forceUpdateLabelKey'] = AccountEntryPolicy.forceUpdateLabel(sessionRaw, forceUpdate, deleteAccountAvailable,
      deletion);
    // 10007 cooling：路由可用才导航到注销页，否则只提示 error.10007、键不结束（编排者补充 G01）。
    out['error10007Raw'] = deleteAccountAvailable ? 'navigate' : 'prompt_only';
    return out;
  }

  static phoneRow(sessionRaw: string, forceUpdate: boolean, phoneBoundRaw: string, ownedPhoneKnown: boolean): string {
    if (sessionRaw !== 'member' || forceUpdate) {
      return AccountEntryPolicy.HIDDEN;
    }
    if (phoneBoundRaw === 'false') {
      return AccountEntryPolicy.BIND_PHONE;
    }
    if (phoneBoundRaw === 'true' && ownedPhoneKnown) {
      return AccountEntryPolicy.PHONE_CHANGE;
    }
    return AccountEntryPolicy.DISABLED;
  }

  /**
   * 强更页次要入口的标签（G28）：路由不可用时不显示（null，编排者补充 G01）；可用时 cooling 且 can_cancel=true → 撤销注销，其余（游客、
   * 读取失败、processing、can_cancel=false）→ 注销账号。基本模式：G34 未裁定，按不显示处理（基本模式不能登录，TODO(N-37) G48）。
   */
  static forceUpdateLabel(sessionRaw: string, forceUpdate: boolean, available: boolean,
    deletion: JSONValue | undefined): string | null {
    if (!forceUpdate || !available || sessionRaw === 'basic') {
      return null;
    }
    if (sessionRaw === 'guest') {
      return 'app_update.delete_account';
    }
    const parse: DeletionParse = AccountJson.deletion(deletion === undefined ? undefined : deletion);
    return parse.record !== null && parse.record.cancellable ? 'app_update.cancel_deletion' : 'app_update.delete_account';
  }
}

// ---------------------------------------------------------------- BindPhone 待确认

/** 首次绑定与换号共用 pendingFor(bindPhone) 恢复待确认（G07；向量 bindPhonePendingRestore）。 */
export class BindPhonePendingPolicy {
  static restore(records: AccountRecord[], account: string, entryRaw: string): AccountRecord {
    let show: boolean = false;
    for (const r of records) {
      if (str(r, 'operation') === 'bindPhone' && str(r, 'account') === account && str(r, 'state') === 'unknown') {
        show = true;
      }
    }
    const out: AccountRecord = obj();
    out['showPendingConfirm'] = show;
    out['skipsStep1'] = show && entryRaw === 'phone_change';
    return out;
  }
}
