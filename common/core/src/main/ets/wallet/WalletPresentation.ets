// APP-09 钱包类页面的纯规则（brief §2.2–§2.10；向量 specs/wallet-vectors.json）。三端同名。
// 金额只用服务端字段（brief §0 第 1 条）：本文件不做任何金额加减、比较最低额或推算税费；所有 fen 原样转交，格式化交给 CouliFormat。
// 不判断资金结论（§0 第 2 条）：能不能提只看 can_withdraw / block_code；【全部提现】只填 max_withdrawable_fen；估算只用 est_*。
import { DefaultTexts, RouteSpec } from 'generated';
import { ErrorActionMapper } from '../network/ErrorActionMapper';
import { CreditPeriodText } from '../orders/OrderPresentation';
import { RouteParamValidator } from '../router/RouteParamValidator';
import { AppVersion, RoutePolicy } from '../router/RoutePolicy';
import { WalletDraftTexts } from './WalletDraftTexts';
import { WalletJson, WalletRecord } from './WalletJson';

type JSONValue = Object | null;

function obj(): WalletRecord {
  const r: WalletRecord = {};
  return r;
}

function fenNode(fen: number, masked: boolean): WalletRecord {
  const r: WalletRecord = obj();
  r['fen'] = fen;
  if (masked) {
    r['maskedText'] = WalletDraftTexts.MASK;
  }
  return r;
}

function num(record: WalletRecord, key: string): number {
  const v: JSONValue | undefined = record[key];
  return typeof v === 'number' ? v as number : 0;
}

function nullableNum(record: WalletRecord, key: string): number | null {
  const v: JSONValue | undefined = record[key];
  return typeof v === 'number' ? v as number : null;
}

function str(record: WalletRecord, key: string): string | null {
  const v: JSONValue | undefined = record[key];
  return typeof v === 'string' ? v as string : null;
}

/**
 * 钱包页显示（brief §2.2；BR-TEXT-01、BR-FUND-18、G10、G11、G23）。
 * - hero：可提现余额（withdrawable_fen）；冻结中、待抵扣不进大数字（03 §10.2）。
 * - negativeLine：negative_fen>0 时「待抵扣 {x}，后续返利将优先抵扣」。
 * - 预估收益直接用 estimated_total_fen（客户端不相加）；其下三项分开：其中已收货（为 0 照常显示）、最早预计月份、暂缓入账（>0）。
 * - 金额隐藏：每个金额节点给 maskedText「****」，fen 保留服务端值；月份与「入账核对中」照常。
 * - 【提现】只按 summary 置灰（G11 更正，BR-WDR-05 细则、BR-TEXT-01）：withdraw_enabled=false（附 error.30306）、negative_fen>0；
 *   风控冻结（risk_paused_reason 非 null）只显示提示条、不置灰，点进提现页由 rules 的 30303 account_frozen 提示。
 */
export class WalletSummaryView {
  static of(summary: WalletRecord, masked: boolean, nowMs: number): WalletRecord {
    const out: WalletRecord = obj();
    out['hero'] = fenNode(num(summary, 'withdrawable_fen'), masked);
    const negative: number = num(summary, 'negative_fen');
    out['negativeLine'] = negative > 0 ? fenNode(negative, masked) : null;
    out['frozen'] = fenNode(num(summary, 'frozen_fen'), masked);
    out['withdrawn'] = fenNode(num(summary, 'withdrawn_fen'), masked);
    out['estimated'] = fenNode(num(summary, 'estimated_total_fen'), masked);
    out['receivedLine'] = fenNode(num(summary, 'pending_credit_fen'), masked);
    const month: string | null = CreditPeriodText.monthText(str(summary, 'next_credit_period'), nowMs);
    if (month === null) {
      out['earliestMonth'] = null;
    } else {
      const m: WalletRecord = obj();
      m['monthText'] = month;
      out['earliestMonth'] = m;
    }
    out['overdueNote'] = summary['credit_overdue'] === true;
    const paused: number = num(summary, 'pending_credit_paused_fen');
    out['pausedLine'] = paused > 0 ? fenNode(paused, masked) : null;
    out['riskBanner'] = WalletSummaryView.riskBanner(str(summary, 'risk_paused_reason'));
    const button: WalletRecord = obj();
    if (summary['withdraw_enabled'] === false) {
      button['enabled'] = false;
      button['reasonKey'] = 'error.30306';
    } else {
      button['enabled'] = negative <= 0;
    }
    out['withdrawButton'] = button;
    return out;
  }

  /**
   * 风控暂停提示条（G10）：先查 risk_msg.<reason>，查得到「提现已暂停：{文案}」，否则只「提现已暂停」；不显示原因码原文。
   * 提示条可点，经 Router 打开 RiskNotice。
   */
  static riskBanner(reason: string | null): WalletRecord {
    const out: WalletRecord = obj();
    if (reason === null) {
      out['show'] = false;
      return out;
    }
    out['show'] = true;
    const key: string = 'risk_msg.' + reason;
    if (/^[A-Za-z0-9_]+$/.test(reason) && DefaultTexts.text(key) !== undefined) {
      out['textKey'] = 'wallet.draft.risk_paused_reason';
      out['reasonKey'] = key;
    } else {
      out['textKey'] = 'wallet.draft.risk_paused';
    }
    out['route'] = 'RiskNotice';
    return out;
  }
}

/** 提现金额输入（G18）：只接受半角数字与一个小数点，小数最多 2 位，整数部分最多 9 位；字符串拆分后整数运算，不用浮点。 */
export class WithdrawAmountInput {
  static readonly MAX_INTEGER_DIGITS: number = 9;

  /** 文本 → 分；空串、只有小数点、不合法、换算后为 0 → null。首尾空白先去掉。 */
  static parse(text: string): number | null {
    const t: string = text.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '');
    const m: RegExpMatchArray | null = t.match(/^([0-9]{1,9})(?:\.([0-9]{1,2}))?$/);
    if (m === null) {
      return null;
    }
    const intPart: number = Number.parseInt(m[1], 10);
    const fracRaw: string = m[2] === undefined ? '' : m[2] as string;
    const frac: number = fracRaw.length === 0 ? 0 : (fracRaw.length === 1 ? Number.parseInt(fracRaw, 10) * 10
      : Number.parseInt(fracRaw, 10));
    const fen: number = intPart * 100 + frac;
    return fen > 0 && Number.isSafeInteger(fen) ? fen : null;
  }

  /** 分 → 输入框里的元（去掉末尾的 0 与多余的小数点，不带「¥」；BR-TEXT-10 的写法）。 */
  static display(fen: number): string {
    const negative: boolean = fen < 0;
    const abs: number = Math.abs(fen);
    const cents: number = abs % 100;
    const yuan: number = (abs - cents) / 100;
    let text: string = String(yuan);
    if (cents > 0) {
      const two: string = cents < 10 ? '0' + cents : String(cents);
      text += '.' + (two.endsWith('0') ? two.substring(0, 1) : two);
    }
    return negative ? '-' + text : text;
  }

  /**
   * 编辑时的过滤（粘贴与键入）：首尾空白先去掉；含半角数字与小数点以外的字符、多于一个小数点、小数多于 2 位、整数多于 9 位 →
   * 整段不接受，返回 null（调用方保持原值）。允许中间态（空串、「12.」）。
   */
  static accept(text: string): string | null {
    const t: string = text.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '');
    return /^[0-9]{0,9}(\.[0-9]{0,2})?$/.test(t) ? t : null;
  }
}

/**
 * 提现页显示（brief §2.4；G29）。inputFen 为当前合法金额（不合法或空为 null）；slaText 为 Config texts.withdraw.sla_text。
 * estimate 只在 rules 是带同一金额取到的（调用方经 WithdrawEstimateGate 核对后才把带金额的 rules 交进来）。
 */
export class WithdrawRulesView {
  static of(rules: WalletRecord, inputFen: number | null, slaText: string | null): WalletRecord {
    const out: WalletRecord = obj();
    const can: boolean = rules['can_withdraw'] === true;
    const withdrawable: number = num(rules, 'withdrawable_fen');
    const max: number = num(rules, 'max_withdrawable_fen');
    const balance: WalletRecord = obj();
    balance['fen'] = withdrawable;
    out['balanceLine'] = balance;
    const remaining: WalletRecord = obj();
    remaining['daily'] = num(rules, 'daily_remaining');
    remaining['monthly'] = num(rules, 'monthly_remaining');
    out['remaining'] = remaining;
    if (can && max < withdrawable) {
      const line: WalletRecord = obj();
      line['fen'] = max;
      out['maxLine'] = line;
    } else {
      out['maxLine'] = null;
    }
    const all: WalletRecord = obj();
    all['enabled'] = can && max > 0;
    if (can && max > 0) {
      all['fen'] = max;
    }
    out['allButton'] = all;
    const quick: number[] = [];
    if (can) {
      const raw: JSONValue | undefined = rules['quick_amounts_fen'];
      if (Array.isArray(raw)) {
        for (const q of raw as JSONValue[]) {
          if (typeof q === 'number') {
            quick.push(q as number);
          }
        }
      }
    }
    out['quick'] = quick;
    out['estimate'] = WithdrawRulesView.estimate(rules, inputFen);
    out['slaKeyOrText'] = slaText !== null && slaText.trim().length > 0 ? slaText : WalletDraftTexts.SLA_MANUAL;
    out['submitEnabled'] = can && inputFen !== null && inputFen > 0;
    const block: number | null = nullableNum(rules, 'block_code');
    out['amountEditable'] = block !== 30304;
    return out;
  }

  /** 估算行：输入合法、can_withdraw、est_net_fen 非 null 才显示；手续费与代扣个税都为 0 用 net_only。其余 'hidden'。 */
  static estimate(rules: WalletRecord, inputFen: number | null): JSONValue {
    const net: number | null = nullableNum(rules, 'est_net_fen');
    if (inputFen === null || rules['can_withdraw'] !== true || net === null) {
      return 'hidden';
    }
    const fee: number | null = nullableNum(rules, 'est_fee_fen');
    const tax: number | null = nullableNum(rules, 'est_tax_fen');
    const out: WalletRecord = obj();
    out['net'] = net;
    if (fee !== null && tax !== null && (fee !== 0 || tax !== 0)) {
      out['key'] = 'withdraw.estimate';
      out['fee'] = fee;
      out['tax'] = tax;
    } else {
      // 两项都为 0，或服务端只给了预计到账：只显示预计到账（不由别的字段推算手续费与税）。
      out['key'] = 'withdraw.estimate.net_only';
    }
    return out;
  }
}

/** 估算响应的归属（BR-WDR-04 细则「估算响应的归属」）：账号、页面实例、最新序号、请求金额 = 当前输入，四项都对得上才应用。 */
export class WithdrawEstimateGate {
  static shouldApply(request: WalletRecord, current: WalletRecord): boolean {
    const amount: JSONValue | undefined = request['amountFen'];
    const input: JSONValue | undefined = current['inputFen'];
    if (typeof amount !== 'number' || typeof input !== 'number') {
      return false;
    }
    return typeof request['account'] === 'string' && request['account'] === current['account']
      && typeof request['pageInstance'] === 'string' && request['pageInstance'] === current['pageInstance']
      && typeof request['seq'] === 'number' && request['seq'] === current['latestSeq']
      && amount === input;
  }
}

/** 30303 的原因文案（G06、G07）：占位符取不到值时用 fallbacks 版本；未登记的 reason 回落 error.30303。 */
export class WithdrawConditionText {
  static of(reason: string | null): WalletRecord {
    const out: WalletRecord = obj();
    if (reason === null || !/^[A-Za-z0-9_]+$/.test(reason)) {
      out['textKey'] = 'error.30303';
      out['useFallback'] = true;
      return out;
    }
    const key: string = 'error.30303.' + reason;
    const text: string | undefined = DefaultTexts.text(key);
    if (text === undefined) {
      // TODO(N-32) G07：payee_daily_count 等字典里没有的子键回落「暂不满足提现条件」。
      out['textKey'] = 'error.30303';
      out['useFallback'] = true;
      return out;
    }
    out['textKey'] = key;
    out['useFallback'] = /\{[a-z0-9_]+\}/.test(text);
    return out;
  }
}

/**
 * rules 的 block_code 引导表（G03、G04、G28、G29）。actionRaw：route（显示原因 + 按钮，用户点按钮才打开）、disable（提现置灰）、
 * notice（只提示）、none。表外的码只显示 error.<code>，字典里没有时回落 error.30303，不引导、不显示码值。
 */
export class WithdrawBlockGuide {
  static readonly ROUTE: string = 'route';
  static readonly DISABLE: string = 'disable';
  static readonly NOTICE: string = 'notice';
  static readonly NONE: string = 'none';
  private static readonly NOTICE_CODES: number[] = [30301, 30302, 30309, 10006, 44001];

  static of(blockCode: number | null, blockReason: string | null): WalletRecord {
    const out: WalletRecord = obj();
    if (blockCode === null) {
      out['actionRaw'] = WithdrawBlockGuide.NONE;
      out['textKey'] = '';
      return out;
    }
    switch (blockCode) {
      case 30304:
        return WithdrawBlockGuide.route(out, 'RealName', 'error.30304', 'withdraw.guide.realname');
      case 30305:
      case 30307:
      case 30308:
        return WithdrawBlockGuide.route(out, 'PayoutAccount', 'error.' + blockCode, 'withdraw.guide.payout');
      case 10004:
        // G04：rules 的 10004 没有 consent_type，一律按劳务协议处理。
        return WithdrawBlockGuide.route(out, 'LaborAgreement', 'error.10004', 'withdraw.guide.labor');
      case 30306:
        out['actionRaw'] = WithdrawBlockGuide.DISABLE;
        out['textKey'] = 'error.30306';
        return out;
      case 30303: {
        const c: WalletRecord = WithdrawConditionText.of(blockReason);
        out['actionRaw'] = WithdrawBlockGuide.NOTICE;
        out['textKey'] = c['textKey'];
        out['fallbackUsed'] = c['useFallback'];
        return out;
      }
      default:
        break;
    }
    out['actionRaw'] = WithdrawBlockGuide.NOTICE;
    if (WithdrawBlockGuide.NOTICE_CODES.indexOf(blockCode) >= 0) {
      out['textKey'] = 'error.' + blockCode;
      // G25：30302 / 30309 原因下加「提现规则」入口（help_links.withdraw_rules 已配置时；页面判断）。
      out['rulesLink'] = blockCode === 30302 || blockCode === 30309;
      return out;
    }
    const key: string = 'error.' + blockCode;
    if (DefaultTexts.text(key) !== undefined) {
      out['textKey'] = key;
      out['fallbackUsed'] = false;
    } else {
      out['textKey'] = 'error.30303';
      out['fallbackUsed'] = true;
    }
    return out;
  }

  private static route(out: WalletRecord, route: string, textKey: string, buttonKey: string): WalletRecord {
    out['actionRaw'] = WithdrawBlockGuide.ROUTE;
    out['route'] = route;
    out['textKey'] = textKey;
    out['buttonKey'] = buttonKey;
    return out;
  }
}

/**
 * 提现与收款账号变更的结果分流（brief §2.5、§2.7；BR-ID-10 细则「敏感操作的幂等键」）。
 * op：withdraw / payout_account；phase：submit（从未结果未知的键）/ confirm（原键原体重发）/ abandon（作废接口）。
 * result（已解包的判定输入）：kind = ok / error / transport / abandon_result；error 带 code、data、headers、traceId；
 * abandon_result 带 outcome（abandoned / completed）与 original（{code, msg, data}）。
 * 输出：actionRaw、keyEnds（这个键不再使用）、nextSubmitNewKey、textKey、route、disableMs、showTrace6。
 */
export class SensitiveOutcome {
  static readonly DONE: string = 'done';
  static readonly STEP_UP: string = 'step_up_same_key';
  static readonly AUTO_RESEND: string = 'auto_resend_same_key';
  static readonly GUIDE: string = 'guide_prereq';
  static readonly SHOW_ERROR_KEY_ENDS: string = 'show_error_key_ends';
  static readonly SHOW_ERROR_KEEP_PENDING: string = 'show_error_keep_pending';
  static readonly FIELD_ERROR: string = 'field_error';
  static readonly RISK_BLOCKED: string = 'risk_blocked';
  static readonly RETRY_AFTER: string = 'retry_after';
  static readonly ERROR_TRACE6: string = 'error_trace6';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly PENDING_CONFIRM: string = 'pending_confirm';
  static readonly ABANDONED: string = 'abandoned';
  static readonly ALREADY_DONE: string = 'already_done';
  static readonly ABANDON_BUSY: string = 'abandon_busy';
  /** 提交得到 40901（同键在途 / 收款账号核验在途）：保持加载态后恢复，不换键自动重发（brief §2.7）。 */
  static readonly BUSY: string = 'busy';

  static readonly OP_WITHDRAW: string = 'withdraw';
  static readonly OP_PAYOUT: string = 'payout_account';
  static readonly SUBMIT: string = 'submit';
  static readonly CONFIRM: string = 'confirm';
  static readonly ABANDON: string = 'abandon';

  static of(op: string, phase: string, keyEverUnknown: boolean, result: WalletRecord): WalletRecord {
    const kind: string = str(result, 'kind') ?? 'transport';
    const unknownKey: boolean = keyEverUnknown || phase !== SensitiveOutcome.SUBMIT;
    switch (kind) {
      case 'ok':
        return SensitiveOutcome.done(op);
      case 'abandon_result':
        return SensitiveOutcome.abandonResult(op, result);
      case 'error':
        return SensitiveOutcome.error(op, phase, unknownKey, result);
      default:
        return SensitiveOutcome.make(SensitiveOutcome.PENDING_CONFIRM, false, false,
          unknownKey ? 'pending_confirm.retry_later' : 'pending_confirm.title');
    }
  }

  private static make(action: string, keyEnds: boolean, nextNew: boolean, textKey: string | null): WalletRecord {
    const out: WalletRecord = obj();
    out['actionRaw'] = action;
    out['keyEnds'] = keyEnds;
    out['nextSubmitNewKey'] = nextNew;
    if (textKey !== null) {
      out['textKey'] = textKey;
    }
    return out;
  }

  private static done(op: string): WalletRecord {
    const out: WalletRecord = SensitiveOutcome.make(SensitiveOutcome.DONE, true, true, null);
    if (op === SensitiveOutcome.OP_WITHDRAW) {
      out['route'] = 'WithdrawRecords';
    }
    return out;
  }

  private static abandonResult(op: string, result: WalletRecord): WalletRecord {
    if (result['outcome'] === 'abandoned') {
      return SensitiveOutcome.make(SensitiveOutcome.ABANDONED, true, true, 'pending_confirm.abandoned');
    }
    const original: WalletRecord | null = WalletJson.objectOf(result['original']);
    const code: number | null = original === null ? null : nullableNum(original, 'code');
    if (code === 0) {
      const out: WalletRecord = SensitiveOutcome.make(SensitiveOutcome.ALREADY_DONE, true, true,
        'pending_confirm.already_done');
      if (op === SensitiveOutcome.OP_WITHDRAW) {
        out['route'] = 'WithdrawRecords';
      }
      return out;
    }
    const data: WalletRecord | null = original === null ? null : WalletJson.objectOf(original['data']);
    return SensitiveOutcome.make(SensitiveOutcome.ALREADY_DONE, true, true,
      code === null ? 'pending_confirm.already_done' : SensitiveOutcome.codeText(code, data));
  }

  /** 错误码的正文键：30303 按 reason（G06、G07）；其余 error.<code>，5xxxx 未收录回落 error.50001。 */
  static codeText(code: number, data: WalletRecord | null): string {
    if (code === 30303) {
      return WithdrawConditionText.of(data === null ? null : str(data, 'reason'))['textKey'] as string;
    }
    if (code >= 50000 && code <= 59999) {
      return ErrorActionMapper.textKey(code, null) ?? 'error.50001';
    }
    return 'error.' + code;
  }

  private static error(op: string, phase: string, unknownKey: boolean, result: WalletRecord): WalletRecord {
    const code: number = nullableNum(result, 'code') ?? -1;
    const data: WalletRecord | null = WalletJson.objectOf(result['data']);
    const headers: Record<string, string> = SensitiveOutcome.headersOf(result['headers']);
    const payout: boolean = op === SensitiveOutcome.OP_PAYOUT;
    const submitNew: boolean = !unknownKey;
    if (code === 10003) {
      return SensitiveOutcome.make(SensitiveOutcome.STEP_UP, false, false, 'error.10003');
    }
    if (code === 10002 || code === 10402) {
      return SensitiveOutcome.make(SensitiveOutcome.AUTO_RESEND, false, false, null);
    }
    if (code === 10405) {
      // 10405 不结束未决键；从未结果未知的键升级后由用户用新键重新提交（BR-ID-01 细则）。
      return SensitiveOutcome.make(SensitiveOutcome.FORCE_UPDATE, false, submitNew, 'error.10405');
    }
    if (code === 10001 || code === 10004 || code === 10005) {
      const out: WalletRecord = SensitiveOutcome.make(SensitiveOutcome.GUIDE, submitNew, submitNew, 'error.' + code);
      const route: string | null = SensitiveOutcome.prereqRoute(code, data);
      if (route !== null) {
        out['route'] = route;
      }
      return out;
    }
    if (code === 20903) {
      return SensitiveOutcome.make(SensitiveOutcome.SHOW_ERROR_KEY_ENDS, true, true, 'error.20903');
    }
    if (code === 42901) {
      const out: WalletRecord = unknownKey
        ? SensitiveOutcome.make(SensitiveOutcome.PENDING_CONFIRM, false, false, 'pending_confirm.retry_later')
        : SensitiveOutcome.make(SensitiveOutcome.RETRY_AFTER, true, true, 'error.42901');
      out['disableMs'] = ErrorActionMapper.retryAfterMillis(headers);
      return out;
    }
    if (code >= 50000 && code <= 59999) {
      const out: WalletRecord = unknownKey
        ? SensitiveOutcome.make(SensitiveOutcome.PENDING_CONFIRM, false, false, 'pending_confirm.retry_later')
        : SensitiveOutcome.make(SensitiveOutcome.ERROR_TRACE6, true, true, SensitiveOutcome.codeText(code, null));
      out['showTrace6'] = true;
      return out;
    }
    if (code === 40901) {
      if (phase === SensitiveOutcome.ABANDON) {
        return SensitiveOutcome.make(SensitiveOutcome.ABANDON_BUSY, false, false, 'pending_confirm.abandon_busy');
      }
      return unknownKey
        ? SensitiveOutcome.make(SensitiveOutcome.PENDING_CONFIRM, false, false, 'pending_confirm.retry_later')
        : SensitiveOutcome.make(SensitiveOutcome.BUSY, true, true, 'error.40901');
    }
    if (code === 44001) {
      // 风控封禁不结束结果未知的键（PendingKeyStore）；从未结果未知的键不再使用（用户申诉后重新提交）。
      const riskCode: string | null = data === null ? null : str(data, 'risk_msg_code');
      const riskKey: string | null = riskCode !== null && /^[A-Za-z0-9_]+$/.test(riskCode)
        && DefaultTexts.text('risk_msg.' + riskCode) !== undefined ? 'risk_msg.' + riskCode : null;
      return SensitiveOutcome.make(SensitiveOutcome.RISK_BLOCKED, submitNew, submitNew, riskKey ?? 'error.44001');
    }
    if (code >= 30000 && code <= 39999) {
      return SensitiveOutcome.businessFailure(op, payout, unknownKey, code, data);
    }
    if (code >= 20000 && code <= 29999) {
      if (unknownKey) {
        // 结果未知后 20903 以外的 2xxxx：按上一次的内容暂时确认不了，键不结束（brief §2.5）。
        return SensitiveOutcome.make(SensitiveOutcome.SHOW_ERROR_KEEP_PENDING, false, false,
          'pending_confirm.cannot_confirm');
      }
      if (code === 20001) {
        const reason: string | null = data === null ? null : str(data, 'reason');
        return SensitiveOutcome.make(SensitiveOutcome.FIELD_ERROR, true, true,
          ErrorActionMapper.textKey(20001, reason) ?? 'error.20001');
      }
      return SensitiveOutcome.make(SensitiveOutcome.SHOW_ERROR_KEY_ENDS, true, true,
        ErrorActionMapper.textKey(code, null) ?? 'error.50001');
    }
    // 其余（不可达的 1xxxx 等）：从未结果未知的键不再使用；结果未知的键保持待确认。
    return unknownKey
      ? SensitiveOutcome.make(SensitiveOutcome.PENDING_CONFIRM, false, false, 'pending_confirm.retry_later')
      : SensitiveOutcome.make(SensitiveOutcome.SHOW_ERROR_KEY_ENDS, true, true,
        ErrorActionMapper.textKey(code, null) ?? 'error.50001');
  }

  /** 3xxxx：写入幂等记录的业务失败，键结束。提交时 30304 / 30305 / 30307 引导补办（回发起页、不重放，G05）。 */
  private static businessFailure(op: string, payout: boolean, unknownKey: boolean, code: number,
    data: WalletRecord | null): WalletRecord {
    const textKey: string = SensitiveOutcome.codeText(code, data);
    if (!unknownKey && (code === 30304 || code === 30305 || code === 30307)) {
      const out: WalletRecord = SensitiveOutcome.make(SensitiveOutcome.GUIDE, true, true, textKey);
      out['route'] = code === 30304 ? 'RealName' : 'PayoutAccount';
      return out;
    }
    const out: WalletRecord = SensitiveOutcome.make(SensitiveOutcome.SHOW_ERROR_KEY_ENDS, true, true, textKey);
    // 收款账号页的账号类错误留在本页显示（route = 本页，不重复压入同名页面）。
    if (payout && (code === 30303 || code === 30307 || code === 30308)) {
      out['route'] = 'PayoutAccount';
    }
    return out;
  }

  /** 前置补办的目的地（G04、G05）：10004 按 consent_type；privacy / agreement 交给已有的协议重新同意组件（没有路由）。 */
  static prereqRoute(code: number, data: WalletRecord | null): string | null {
    if (code === 10001) {
      return 'Login';
    }
    if (code === 10005) {
      return 'BindPhone';
    }
    if (code === 10004) {
      const type: string | null = data === null ? null : str(data, 'consent_type');
      if (type === 'labor_agreement') {
        return 'LaborAgreement';
      }
      if (type === 'id_verification') {
        return 'RealName';
      }
    }
    return null;
  }

  private static headersOf(value: JSONValue | undefined): Record<string, string> {
    const out: Record<string, string> = {};
    const r: WalletRecord | null = WalletJson.objectOf(value);
    if (r === null) {
      return out;
    }
    for (const key of Object.keys(r)) {
      const v: JSONValue | undefined = r[key];
      if (typeof v === 'string') {
        out[key] = v as string;
      }
    }
    return out;
  }
}

/** 二次验证 token 的复用条件（G17）：只放内存，按账号与 action 隔离；本机时钟早于 expire_at 才带上。 */
export class StepUpTokenCache {
  private readonly tokens: Map<string, StepUpEntry> = new Map<string, StepUpEntry>();

  put(action: string, account: string, token: string, expireAtMs: number): void {
    this.tokens.set(action, new StepUpEntry(account, token, expireAtMs));
  }

  /** 不核销服务端 token；不满足条件为 null。 */
  take(action: string, account: string, nowMs: number): string | null {
    const e: StepUpEntry | undefined = this.tokens.get(action);
    if (e === undefined || e.account !== account || nowMs >= e.expireAtMs) {
      return null;
    }
    return e.token;
  }

  /** 提交成功（token 已被服务端核销）：丢弃这个 action 的 token。 */
  onSuccess(action: string): void {
    this.tokens.delete(action);
  }

  /** 会话换代、登出、换账号、撤回同意：全部清空。 */
  onSessionChanged(): void {
    this.tokens.clear();
  }

  /** 得到 10003：丢弃并重新弹面板。 */
  on10003(action: string): void {
    this.tokens.delete(action);
  }

  get size(): number {
    return this.tokens.size;
  }
}

class StepUpEntry {
  readonly account: string;
  readonly token: string;
  readonly expireAtMs: number;

  constructor(account: string, token: string, expireAtMs: number) {
    this.account = account;
    this.token = token;
    this.expireAtMs = expireAtMs;
  }
}

/** 提现单的标题与副文案（G08、BR-TEXT-06、BR-TEXT-07；草稿键接线见 vectors.gaps）。values 里的金额是整数分。 */
export class WithdrawalText {
  static readonly REJECT_REASONS: string[] = ['RISK_SUSPECT', 'ORDER_ABNORMAL', 'PAYEE_INFO_INVALID', 'USER_REQUEST',
    'OTHER', 'NEGATIVE_BALANCE'];
  static readonly FAIL_REASONS: string[] = ['PAYEE_NOT_EXIST', 'PAYEE_USER_INFO_ERROR', 'PAYEE_ACCOUNT_STATUS_ERROR'];

  static statusOf(item: WalletRecord): string {
    const s: string | null = str(item, 'status');
    return s !== null && WalletJson.STATUSES.indexOf(s) >= 0 ? s : 'UNKNOWN';
  }

  static knownChannel(item: WalletRecord): boolean {
    const c: string | null = str(item, 'payout_channel');
    return c !== null && WalletJson.PAYOUT_METHODS.indexOf(c) >= 0;
  }

  static of(item: WalletRecord, slaText: string | null): WalletRecord {
    const out: WalletRecord = obj();
    const status: string = WithdrawalText.statusOf(item);
    out['titleKey'] = 'withdrawal_status.' + status + '.title';
    const lines: JSONValue[] = [];
    const amount: number = num(item, 'amount_fen');
    const known: boolean = WithdrawalText.knownChannel(item);
    switch (status) {
      case 'PENDING_REVIEW':
      case 'APPROVED': {
        if (str(item, 'review_mode') === 'auto') {
          lines.push(WithdrawalText.line('withdraw.sla_text_auto', null));
        } else {
          const v: WalletRecord = obj();
          v['text'] = slaText !== null && slaText.trim().length > 0 ? slaText : WalletDraftTexts.SLA_MANUAL;
          lines.push(WithdrawalText.line('withdraw.sla_text', v));
        }
        const v: WalletRecord = obj();
        v['amount'] = amount;
        lines.push(WithdrawalText.line('withdrawal.draft.frozen', v));
        break;
      }
      case 'PAYING':
        lines.push(WithdrawalText.line('withdrawal.draft.processing', null));
        break;
      case 'PAID_API':
      case 'PAID_MANUAL': {
        const v: WalletRecord = obj();
        v['payout_channel_name'] = str(item, 'payout_channel_name') ?? '';
        v['masked_account'] = str(item, 'masked_account') ?? '';
        if (known) {
          v['net'] = num(item, 'net_fen');
          lines.push(WithdrawalText.line('withdrawal.draft.paid', v));
        } else {
          lines.push(WithdrawalText.line('withdrawal.draft.channel', v));
        }
        const tax: number = num(item, 'tax_fen');
        if (tax > 0) {
          const t: WalletRecord = obj();
          t['tax'] = tax;
          lines.push(WithdrawalText.line('withdrawal.draft.tax', t));
        }
        break;
      }
      case 'REJECTED':
      case 'FAILED': {
        const reason: string | null = str(item, 'reason_code');
        const list: string[] = status === 'REJECTED' ? WithdrawalText.REJECT_REASONS : WithdrawalText.FAIL_REASONS;
        if (reason !== null && list.indexOf(reason) >= 0) {
          lines.push(WithdrawalText.line((status === 'REJECTED' ? 'withdraw_reject_reason.' : 'withdraw_fail_reason.')
            + reason, null));
        }
        const v: WalletRecord = obj();
        v['amount'] = amount;
        const change: boolean = WithdrawalText.changeAccount(item);
        lines.push(WithdrawalText.line(change ? 'withdrawal.draft.returned.change_account' : 'withdrawal.draft.returned',
          v));
        break;
      }
      default:
        break;
    }
    out['subLines'] = lines;
    out['showChangeAccount'] = WithdrawalText.changeAccount(item);
    switch (status) {
      case 'PENDING_REVIEW':
      case 'APPROVED':
      case 'PAYING':
        out['netKey'] = 'withdraw_detail.net.expected';
        break;
      case 'PAID_API':
      case 'PAID_MANUAL':
        out['netKey'] = 'withdraw_detail.net.actual';
        break;
      default:
        out['netKey'] = null;
    }
    return out;
  }

  /** 【修改收款账号】：FAILED + fail_action=change_payout_account，且收款方式是本端认得的（不出微信等入口）。 */
  static changeAccount(item: WalletRecord): boolean {
    return WithdrawalText.statusOf(item) === 'FAILED' && str(item, 'fail_action') === 'change_payout_account'
      && WithdrawalText.knownChannel(item);
  }

  private static line(key: string, values: WalletRecord | null): WalletRecord {
    const r: WalletRecord = obj();
    r['key'] = key;
    if (values !== null) {
      r['values'] = values;
    }
    return r;
  }
}

/** 交易流水号行（BR-WDR-25 细则）：PAID_API / PAID_MANUAL 且 channel_order_id 非空才显示（只在详情）。 */
export class TradeNoRow {
  static of(detail: WalletRecord): WalletRecord {
    const out: WalletRecord = obj();
    const status: string | null = str(detail, 'status');
    const id: string | null = str(detail, 'channel_order_id');
    if ((status === 'PAID_API' || status === 'PAID_MANUAL') && id !== null && id.length > 0) {
      out['show'] = true;
      out['copyText'] = id;
    } else {
      out['show'] = false;
    }
    return out;
  }
}

/** 收款账号的显示（brief §2.7）：{} = 未绑定；只显示服务端的脱敏字段；不认识的收款方式只显示脱敏串、不出操作入口。 */
export class PayoutAccountView {
  static of(data: WalletRecord): WalletRecord {
    const out: WalletRecord = obj();
    if (Object.keys(data).length === 0) {
      out['bound'] = false;
      return out;
    }
    const method: string = str(data, 'payout_method') ?? '';
    out['bound'] = true;
    out['methodRaw'] = method;
    out['maskedAccount'] = str(data, 'masked_account') ?? '';
    const known: boolean = WalletJson.PAYOUT_METHODS.indexOf(method) >= 0;
    out['known'] = known;
    out['bankName'] = method === 'bank_card' ? str(data, 'bank_name') : null;
    out['maskedPayee'] = known ? str(data, 'masked_payee_name') : null;
    out['changeRemaining'] = known ? nullableNum(data, 'change_remaining_this_month') : null;
    return out;
  }

  /** Withdraw 收款账号行与待确认摘要里用的一行（「支付宝 138****5678」「招商银行 尾号 1234」）。 */
  static line(data: WalletRecord): string | null {
    if (Object.keys(data).length === 0) {
      return null;
    }
    const method: string = str(data, 'payout_method') ?? '';
    const masked: string = str(data, 'masked_account') ?? '';
    if (method === 'alipay') {
      return WalletDraftTexts.text('payout_account.alipay') + ' ' + masked;
    }
    if (method === 'bank_card') {
      const bank: string = str(data, 'bank_name') ?? '';
      // 服务端的 masked_account 已是「尾号 1234」或带开户行的写法：不重复拼开户行。
      return masked.indexOf(bank) >= 0 || bank.length === 0 ? masked : bank + ' ' + masked;
    }
    return masked;
  }
}

/** 收款账号待确认摘要的本机脱敏（G15，BR-ID-33 细则）。取不到规定写法时 account 为 null（页面用 fallback 句）。 */
export class PayoutPendingSummary {
  static of(form: WalletRecord): WalletRecord {
    const out: WalletRecord = obj();
    const method: string | null = str(form, 'payout_method');
    out['account'] = method === 'bank_card' ? PayoutPendingSummary.bank(form)
      : (method === 'alipay' ? PayoutPendingSummary.alipay(str(form, 'alipay_logon_id') ?? '') : null);
    out['payee'] = PayoutPendingSummary.payee(str(form, 'payee_name') ?? '');
    return out;
  }

  static alipay(raw: string): string | null {
    const id: string = raw.trim();
    const at: number = id.lastIndexOf('@');
    if (at > 0) {
      const local: string = id.substring(0, at);
      const domain: string = id.substring(at + 1);
      const keep: number = local.length > 2 ? 2 : (local.length === 2 ? 1 : 0);
      return local.substring(0, keep) + '***@' + domain;
    }
    const digits: string = id.replace(/[^0-9]/g, '');
    if (digits.length === 11) {
      return digits.substring(0, 3) + '****' + digits.substring(7);
    }
    // 「其他」的脱敏写法未定义（vectors.gaps G15）：不输出完整登录号。
    return null;
  }

  static bank(form: WalletRecord): string | null {
    const digits: string = (str(form, 'card_no') ?? '').replace(/[^0-9]/g, '');
    const bank: string = (str(form, 'bank_name') ?? '').trim();
    if (digits.length < 4 || bank.length === 0) {
      return null;
    }
    const vars: Map<string, string> = new Map<string, string>();
    vars.set('bank_name', bank);
    vars.set('last4', digits.substring(digits.length - 4));
    return WalletDraftTexts.format('payout_account.bank_mask', vars);
  }

  /** 收款人姓名只留末字（**三）。 */
  static payee(raw: string): string | null {
    const chars: string[] = Array.from(raw.trim());
    return chars.length === 0 ? null : '**' + chars[chars.length - 1];
  }
}

/** 收款账号表单（G12、G13、G14）：只去首尾空白后原样提交；必填为空列入 fieldErrors（body 为 null）。不做 Luhn、规范化与卡类型判断。 */
export class PayoutAccountForm {
  static readonly CARD_MAX: number = 32;
  static readonly LOGON_MAX: number = 128;
  static readonly NAME_MAX: number = 64;

  static body(form: WalletRecord): WalletRecord {
    const out: WalletRecord = obj();
    const method: string | null = str(form, 'payout_method');
    const errors: string[] = [];
    const body: WalletRecord = obj();
    const fields: string[] = method === 'alipay' ? ['alipay_logon_id', 'payee_name']
      : (method === 'bank_card' ? ['card_no', 'bank_name', 'payee_name'] : []);
    if (fields.length === 0) {
      errors.push('payout_method');
    } else {
      body['payout_method'] = method;
      for (const f of fields) {
        const v: string = (str(form, f) ?? '').trim();
        if (v.length === 0) {
          errors.push(f);
        }
        body[f] = v;
      }
    }
    out['body'] = errors.length > 0 ? null : body;
    out['fieldErrors'] = errors;
    return out;
  }

  /** 字段错误的显示与焦点顺序（收款方式组在最前）。 */
  static readonly FIELD_ORDER: string[] = ['payout_method', 'alipay_logon_id', 'card_no', 'bank_name', 'payee_name'];

  /** 当前收款方式下页面上实际显示的字段（含收款方式组）：不在其中的字段错误没有可见位置（R3-03）。 */
  static visibleFields(method: string): string[] {
    return method === 'bank_card' ? ['payout_method', 'card_no', 'bank_name', 'payee_name']
      : ['payout_method', 'alipay_logon_id', 'payee_name'];
  }

  /**
   * 字段错误的焦点目标（R3-03，共性第 36 条）：收款方式组没有输入框，焦点落到当前选中的那个选项（payout_method_<方式>）；
   * 其余字段落到对应输入框（payout_<字段>）。返回的 id 都是页面上实际存在的控件。
   */
  static errorFocusId(field: string, method: string): string {
    if (field === 'payout_method') {
      return 'payout_method_' + (method === 'bank_card' ? 'bank_card' : 'alipay');
    }
    return 'payout_' + field;
  }

  /** 卡号输入框的过滤：只允许数字、空格、连字符，最多 32 字（契约 maxLength）；不合法整段不接受（返回 null）。 */
  static acceptCardNo(text: string): string | null {
    return /^[0-9 \-]{0,32}$/.test(text) ? text : null;
  }
}

/** 实名表单（brief §2.8）：姓名去首尾空白；身份证号小写 x 转大写；18 位（前 17 位数字、末位数字或 X）才可提交；不算校验位。 */
export class RealNameForm {
  static normalize(input: WalletRecord): WalletRecord {
    const out: WalletRecord = obj();
    const name: string = (str(input, 'name') ?? '').trim();
    const id: string = (str(input, 'idNo') ?? '').replace(/x/g, 'X');
    out['name'] = name;
    out['idNo'] = id;
    out['submitEnabled'] = name.length > 0 && /^[0-9]{17}[0-9X]$/.test(id);
    return out;
  }

  /** 输入框过滤：只收数字与 X（小写 x 转大写），最多 18 位；不合法整段不接受（null）。 */
  static acceptIdNo(text: string): string | null {
    const t: string = text.replace(/x/g, 'X');
    return /^[0-9X]{0,18}$/.test(t) ? t : null;
  }
}

/** 收益看板入口（G20）：flag 为 true 且 Earnings 在本端本版本可用（since 非 null 且不高于当前版本）才显示。 */
export class EarningsEntry {
  static readonly FLAG: string = 'earnings.dashboard.visible';

  static visible(flag: boolean | null, routeSince: string | null, appVersion: string): boolean {
    return flag === true && routeSince !== null && AppVersion.isAtLeast(appVersion, routeSince);
  }
}

/** 资金与实名四页丢弃全部路由参数（BR-WDR-01 细则，AC-S1-81 ⑫）；事件只带路由名与个数。 */
export class FundRouteParams {
  static readonly EVENT: string = 'route_params_dropped';

  static isFundRoute(route: string): boolean {
    return RoutePolicy.PARAMS_DROPPED_ROUTES.indexOf(route) >= 0;
  }

  static filter(route: string, params: WalletRecord): WalletRecord {
    const out: WalletRecord = obj();
    const count: number = Object.keys(params).length;
    if (FundRouteParams.isFundRoute(route)) {
      out['openedParams'] = obj();
      out['dropped'] = count;
      out['event'] = count > 0 ? FundRouteParams.EVENT : null;
      return out;
    }
    out['openedParams'] = params;
    out['dropped'] = 0;
    out['event'] = null;
    return out;
  }
}

/** 提现规则入口（G26，照 APP-08 PriceCompareEntry）：help_links.withdraw_rules 是 {route: Help, params: {article_id}} 且合法才给参数。 */
export class WalletHelpLink {
  static readonly KEY: string = 'withdraw_rules';

  static withdrawRules(helpLinks: WalletRecord | null, routeCatalog: Map<string, RouteSpec>): Record<string, Object> | null {
    if (helpLinks === null) {
      return null;
    }
    const target: WalletRecord | null = WalletJson.objectOf(helpLinks[WalletHelpLink.KEY]);
    if (target === null) {
      return null;
    }
    const params: WalletRecord | null = WalletJson.objectOf(target['params']);
    const article: string | null = params === null ? null : WalletJson.text(params, 'article_id');
    if (WalletJson.text(target, 'route') !== 'Help' || params === null || Object.keys(params).length !== 1
      || article === null || article.length === 0) {
      return null;
    }
    const out: Record<string, Object> = {};
    out['article_id'] = article;
    const spec: RouteSpec | undefined = routeCatalog.get('Help');
    return spec === undefined || !RouteParamValidator.isValid(out, spec) ? null : out;
  }
}

/**
 * 二次验证半屏按键盘弹起后的可用高度布局（鸿蒙 R1-11，共性第 11 条；AdaptShortStepUp）。单位 vp。
 * 半屏（bindSheet，自己不避让键盘）里：标题区与底部操作区（倒计时所在的中段之下的【验证并提交】）固定，只有中段滚动；面板下方放一块与
 * 键盘等高的占位，面板整体贴在键盘上沿。面板最大高 = 视口高 − 顶部安全区 − 24 − 键盘高 − 底部手势条（键盘收起时只减手势条），
 * 不低于 MIN_PANEL（极端短视口时中段压到最小、仍保留标题与按钮）。
 * 降级布局（鸿蒙 R2-09，共性第 33 条）：标题区 + 底部操作区 + chrome + 一行验证码格的最小高超过键盘上方的真实可用高（短窗口、200% 字号、
 * 键盘同时出现）时，三段不再分开固定，整块放进一个高度等于可用高的滚动区：完整标题、关闭、验证码格与【验证并提交】都可滚动到达，
 * 面板不会顶出窗口上沿。两种布局用同一棵组件树（只改高度与可否滚动），输入框不重建、键盘不收起。
 */
export class StepUpSheetFit {
  static readonly TOP_GAP: number = 24;
  static readonly MIN_PANEL: number = 160;
  /** 中段最小高（vp）：一行验证码格的大致高度。 */
  static readonly MIN_MIDDLE: number = 48;
  /** 视口高未知（取不到窗口）时的缺省最大高。 */
  static readonly FALLBACK_PANEL: number = 560;

  static maxPanel(viewport: number, topInset: number, bottomInset: number, keyboard: number): number {
    if (!(viewport > 0)) {
      return StepUpSheetFit.FALLBACK_PANEL;
    }
    const kb: number = keyboard > 0 ? keyboard : 0;
    const avail: number = viewport - Math.max(0, topInset) - StepUpSheetFit.TOP_GAP - kb - Math.max(0, bottomInset);
    return Math.max(StepUpSheetFit.MIN_PANEL, Math.floor(avail));
  }

  /**
   * 中段（唯一可滚动的部分）的高度：面板最大高减去标题区、底部操作区与 chrome（内边距 + 间距）后的可用高，与中段自然高取小；
   * 不低于 minMiddle（调用方给验证码格的高度，缺省 MIN_MIDDLE）：极端短视口时中段压到正好露出一行验证码格，标题与底部操作区照样完整。
   */
  static middle(panelMax: number, header: number, footer: number, chrome: number, natural: number,
    minMiddle: number = StepUpSheetFit.MIN_MIDDLE): number {
    const avail: number = panelMax - Math.max(0, header) - Math.max(0, footer) - Math.max(0, chrome);
    const floor: number = Math.min(Math.max(StepUpSheetFit.MIN_MIDDLE, minMiddle), Math.max(0, natural));
    return Math.max(floor, Math.min(Math.max(0, natural), Math.floor(avail)));
  }

  /** 降级布局的最小滚动区高（vp）：至少露出一行可点的控件。 */
  static readonly MIN_SCROLL: number = 48;

  /** 键盘上方的真实可用高（不按 MIN_PANEL 抬高；降级布局的整块滚动区用它，保证面板不超出窗口）。 */
  static available(viewport: number, topInset: number, bottomInset: number, keyboard: number): number {
    if (!(viewport > 0)) {
      return StepUpSheetFit.FALLBACK_PANEL;
    }
    const kb: number = keyboard > 0 ? keyboard : 0;
    const avail: number = viewport - Math.max(0, topInset) - StepUpSheetFit.TOP_GAP - kb - Math.max(0, bottomInset);
    return Math.max(StepUpSheetFit.MIN_SCROLL, Math.floor(avail));
  }

  /**
   * 三段最小高（标题区 + 底部操作区 + chrome + 一行验证码格）放不下可用高 → 降级为整块滚动。标题区或底部操作区还没量到时不降级
   * （按常规布局先量一次）。
   */
  static degraded(available: number, header: number, footer: number, chrome: number, minMiddle: number): boolean {
    if (!(header > 0) || !(footer > 0)) {
      return false;
    }
    return header + footer + Math.max(0, chrome) + Math.max(StepUpSheetFit.MIN_MIDDLE, minMiddle) > available;
  }

  /**
   * 整个面板（外层滚动区）的高度：降级时等于可用高（内容超出部分滚动）；常规时等于三段之和（中段已按可用高压缩），且不超过面板最大高。
   * 三段还没量到时先给 min(面板最大高, FALLBACK_PANEL)。
   */
  static outer(available: number, panelMax: number, header: number, footer: number, chrome: number, middle: number,
    degraded: boolean): number {
    if (degraded) {
      return available;
    }
    if (!(header > 0) || !(footer > 0)) {
      return Math.min(panelMax, StepUpSheetFit.FALLBACK_PANEL);
    }
    return Math.min(panelMax, Math.ceil(header + footer + Math.max(0, chrome) + Math.max(0, middle)));
  }

  /** 面板下方的键盘占位（键盘收起为 0）。 */
  static spacer(keyboard: number): number {
    return keyboard > 0 ? Math.ceil(keyboard) : 0;
  }
}
