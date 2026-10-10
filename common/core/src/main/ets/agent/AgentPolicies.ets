// APP-10 纯策略（向量 specs/agent-vectors.json 的 pageGuideTap、earningsView、ticket、sendErrors、streamErrors、duplicate、clientMsgId、consent）。
// 这些只返回「该怎么做」的描述，执行层（AgentController / 页面）先比票据再产生副作用（向量 gaps 第 4 条）。
import { RouteSpec } from 'generated';
import { RouteSource } from '../router/RouteRequest';
import { CreditPeriodText } from '../orders/OrderPresentation';
import { WalletDraftTexts } from '../wallet/WalletDraftTexts';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentCard, AgentCardDecoder, AgentCardKind, EarningsShape, PageGuideCheck } from './AgentDecoder';
import { AgentDraftTexts } from './AgentDraftTexts';

// ---------------------------------------------------------------- 金额（BR-TEXT-10）

/**
 * BR-TEXT-10 App 金额写法的 Core 副本（可选负号 +「¥」+ 元，最多两位小数，去末尾 0，无千分位；整数运算）。Core 不能依赖 DesignSystem，
 * 而收益卡的展示值要在 Core 里算好（向量 earningsView 直接比较文字）；页面渲染时传入 DesignSystem 的 CouliFormat.money（同一算法），
 * 两者逐条一致由 AgentIntegration 测试按 specs/format-vectors.json 的金额用例核对（rule-gaps 鸿蒙 H01）。
 */
export class AgentAmount {
  static yuan(fen: number): string {
    const sign: string = fen < 0 ? '-' : '';
    const abs: number = Math.abs(Math.trunc(fen));
    const cent: number = abs % 100;
    const whole: number = (abs - cent) / 100;
    let digits: string = whole.toFixed(0);
    if (cent !== 0) {
      digits += cent % 10 === 0 ? '.' + String(cent / 10) : '.' + (cent < 10 ? '0' + String(cent) : String(cent));
    }
    return sign + '¥' + digits;
  }
}

// ---------------------------------------------------------------- 页面引导卡（D31，G09、G10）

export class PageGuidePolicy {
  /**
   * 点击时的判定：只有包内 agent_guide 路由、data 只含 route 与 text_key、text_key 与 route 相符时才画按钮；按钮交 Router 的永远是
   * {route, params: {}, source: agent_card}（brief §0 第 1 条）。被拦下且 route 满足路由名正则 → 一次 route_entry_blocked{route, in_app}。
   */
  static tap(card: AgentJsonObject, routes: Map<string, RouteSpec>): AgentJsonObject {
    const data: AgentJsonObject | null = AgentJson.objectOf(card['data']);
    const version: number = AgentJson.intOf(card['schema_version']) ?? 1;
    const check: PageGuideCheck = PageGuideCheck.of(data, version, routes);
    const o: AgentJsonObject = {};
    o['showButton'] = check.ok;
    if (check.ok) {
      o['route'] = check.route;
    }
    const params: AgentJsonObject = {};
    o['params'] = params;
    o['sourceRaw'] = RouteSource.AGENT_CARD;
    if (!check.ok && check.blockedRoute !== null) {
      const e: AgentJsonObject = {};
      e['route'] = check.blockedRoute;
      e['entry'] = 'in_app';
      o['blockedEvent'] = e;
    } else {
      o['blockedEvent'] = null;
    }
    return o;
  }
}

// ---------------------------------------------------------------- 收益卡（D32，G11–G14）

export class EarningsButton {
  readonly route: string;
  readonly textKey: string;

  constructor(route: string, textKey: string) {
    this.route = route;
    this.textKey = textKey;
  }
}

/** 收益卡的展示值（只在内存；金额隐藏时三处都是 ****，不带 ¥、位数、正负号）。 */
export class EarningsView {
  readonly shape: string;
  readonly withdrawable: string | null;
  readonly estimatedTotal: string | null;
  readonly creditPeriod: string | null;
  readonly creditOverdue: boolean;
  readonly latestWithdrawalShown: boolean;
  readonly latestTitleKey: string | null;
  readonly latestTitle: string | null;
  readonly appliedAmount: string | null;
  readonly updatedAt: string | null;
  readonly historyTextKey: string | null;
  readonly buttons: EarningsButton[];
  readonly fallbackText: string | null;
  readonly masked: boolean;

  constructor(shape: string, withdrawable: string | null, estimatedTotal: string | null, creditPeriod: string | null,
    creditOverdue: boolean, latestWithdrawalShown: boolean, latestTitleKey: string | null, latestTitle: string | null,
    appliedAmount: string | null, updatedAt: string | null, historyTextKey: string | null, buttons: EarningsButton[],
    fallbackText: string | null, masked: boolean) {
    this.shape = shape;
    this.withdrawable = withdrawable;
    this.estimatedTotal = estimatedTotal;
    this.creditPeriod = creditPeriod;
    this.creditOverdue = creditOverdue;
    this.latestWithdrawalShown = latestWithdrawalShown;
    this.latestTitleKey = latestTitleKey;
    this.latestTitle = latestTitle;
    this.appliedAmount = appliedAmount;
    this.updatedAt = updatedAt;
    this.historyTextKey = historyTextKey;
    this.buttons = buttons;
    this.fallbackText = fallbackText;
    this.masked = masked;
  }

  /** 向量形状：只放要展示的字段；历史形状与 fallback 不出现任何金额键（G13）。 */
  json(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['shapeRaw'] = this.shape;
    o['latestWithdrawalShown'] = this.latestWithdrawalShown;
    o['buttons'] = this.buttons.map((b: EarningsButton): AgentJsonObject => {
      const x: AgentJsonObject = {};
      x['route'] = b.route;
      x['textKey'] = b.textKey;
      return x;
    });
    if (this.shape === EarningsShape.LIVE) {
      o['withdrawable'] = this.withdrawable;
      o['estimatedTotal'] = this.estimatedTotal;
      o['creditPeriod'] = this.creditPeriod;
      o['creditOverdue'] = this.creditOverdue;
      o['updatedAt'] = this.updatedAt;
      if (this.latestWithdrawalShown) {
        o['latestTitleKey'] = this.latestTitleKey;
        o['appliedAmount'] = this.appliedAmount;
      }
    } else if (this.shape === EarningsShape.HISTORY) {
      o['textKey'] = this.historyTextKey;
    } else {
      o['fallbackText'] = this.fallbackText;
    }
    return o;
  }
}

export class EarningsCardView {
  static readonly WALLET: EarningsButton = new EarningsButton('Wallet', 'agent.earnings.open_wallet');
  static readonly RECORDS: EarningsButton = new EarningsButton('WithdrawRecords', 'agent.earnings.open_records');

  /** 向量入口：卡片外壳 + 来源 + 金额隐藏 + 当前时刻（上海月份比较用）。 */
  static of(card: AgentJsonObject, origin: string, amountMasked: boolean, nowMs: number,
    money: (fen: number) => string = AgentAmount.yuan): AgentJsonObject {
    const parsed: AgentCard = AgentCardDecoder.parse(card, origin, new Map<string, RouteSpec>());
    return EarningsCardView.view(parsed, amountMasked, nowMs, money).json();
  }

  /** 已解码的卡 → 展示值。只有 known 且 shape=live 才计算金额；金额隐藏时不调用格式化（不产生带数字的中间串）。 */
  static view(card: AgentCard, amountMasked: boolean, nowMs: number, money: (fen: number) => string = AgentAmount.yuan):
    EarningsView {
    const buttons: EarningsButton[] = [EarningsCardView.WALLET, EarningsCardView.RECORDS];
    if (card.kind !== AgentCardKind.KNOWN) {
      return new EarningsView(EarningsShape.FALLBACK, null, null, null, false, false, null, null, null, null, null, [],
        card.fallbackText, amountMasked);
    }
    if (card.shape !== EarningsShape.LIVE) {
      return new EarningsView(EarningsShape.HISTORY, null, null, null, false, false, null, null, null, null,
        'agent.earnings.history', buttons, null, amountMasked);
    }
    const d: AgentJsonObject = card.data;
    const show: (fen: AgentJsonValue | undefined) => string = (fen: AgentJsonValue | undefined): string =>
    amountMasked ? AgentDraftTexts.MASK : money(AgentJson.intOf(fen) ?? 0);
    const period: string | null = CreditPeriodText.monthText(AgentJson.stringOf(d['next_credit_period']), nowMs);
    const latest: AgentJsonObject | null = AgentJson.objectOf(d['latest_withdrawal']);
    let shown: boolean = false;
    let titleKey: string | null = null;
    let title: string | null = null;
    let applied: string | null = null;
    if (latest !== null) {
      const key: string = latest['title_key'] as string;
      const resolved: string | null = EarningsCardView.titleOf(key);
      if (resolved !== null) {
        shown = true;
        titleKey = key;
        title = resolved;
        applied = show(latest['amount_fen']);
      }
    }
    return new EarningsView(EarningsShape.LIVE, show(d['withdrawable_fen']), show(d['estimated_total_fen']), period,
      d['credit_overdue'] === true, shown, titleKey, title, applied,
      EarningsCardView.hhmm(AgentJson.stringOf(d['as_of'])), null, buttons, null, amountMasked);
  }

  /** 提现主状态标题：只做精确键查找（契约文案 → APP-09 钱包草稿表），查不到为 null（整行不显示，G11）。 */
  static titleOf(key: string): string | null {
    if (!WalletDraftTexts.has(key)) {
      return null;
    }
    const t: string = WalletDraftTexts.text(key);
    return t.length > 0 ? t : null;
  }

  /** as_of（+08:00）→ 上海 HH:mm（G12「更新于 HH:mm」）。 */
  static hhmm(asOf: string | null): string | null {
    if (asOf === null) {
      return null;
    }
    const m: RegExpMatchArray | null = asOf.match(/T([0-9]{2}):([0-9]{2})/);
    return m === null ? null : m[1] + ':' + m[2];
  }
}

// ---------------------------------------------------------------- 票据（brief §0 第 3 条，G06）

export class AgentTicketEvent {
  static readonly SESSION_INVALID: string = 'session_invalid';
  static readonly LOGOUT: string = 'logout';
  static readonly ACCOUNT_SWITCH: string = 'account_switch';
  static readonly PRIVACY_WITHDRAWN: string = 'privacy_withdrawn';
  static readonly AI_CONSENT_WITHDRAWN: string = 'ai_consent_withdrawn';
  static readonly ENV_SWITCH: string = 'env_switch';
  static readonly PAGE_DESTROYED: string = 'page_destroyed';
  static readonly NEW_CHAT: string = 'new_chat';
  static readonly STOP: string = 'stop';
}

/** 作废事件 → 作废到哪一层、是否发 cancel。 */
export class AgentTicketAction {
  readonly dropController: boolean;
  readonly dropConversation: boolean;
  readonly dropRun: boolean;
  readonly sendsCancel: boolean;
  readonly clearsMessages: boolean;

  constructor(dropController: boolean, dropConversation: boolean, dropRun: boolean, sendsCancel: boolean,
    clearsMessages: boolean) {
    this.dropController = dropController;
    this.dropConversation = dropConversation;
    this.dropRun = dropRun;
    this.sendsCancel = sendsCancel;
    this.clearsMessages = clearsMessages;
  }

  json(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['dropController'] = this.dropController;
    o['dropConversation'] = this.dropConversation;
    o['dropRun'] = this.dropRun;
    o['sendsCancel'] = this.sendsCancel;
    o['clearsMessages'] = this.clearsMessages;
    return o;
  }
}

export class AgentTicketPolicy {
  /**
   * 归属变化（会话失效、退出、换号、撤回隐私、撤回 AI 同意、切环境）与页面销毁：作废整个控制器（含其下对话与 run）、清空消息、不发 cancel
   * （cancel 会带新身份的令牌，主体对不上，G06）；【新对话】：作废对话与 run、清空消息，不换控制器、不发 cancel；【停止】：只作废 run、
   * 保留内容，发 cancel（带 run 票据里的原身份）。
   */
  static action(eventRaw: string): AgentTicketAction {
    switch (eventRaw) {
      case AgentTicketEvent.NEW_CHAT:
        return new AgentTicketAction(false, true, true, false, true);
      case AgentTicketEvent.STOP:
        return new AgentTicketAction(false, false, true, true, false);
      default:
        return new AgentTicketAction(true, true, true, false, true);
    }
  }

  static onEvent(eventRaw: string): AgentJsonObject {
    return AgentTicketPolicy.action(eventRaw).json();
  }

  /** 票据比较：控制器编号、对话世代、run 票据任一不同（或控制器已作废）→ 丢弃。 */
  static accept(issued: AgentJsonObject, current: AgentJsonObject | null): boolean {
    if (current === null) {
      return false;
    }
    return issued['controller'] === current['controller'] && issued['conversation'] === current['conversation']
      && issued['run'] === current['run'];
  }
}

// ---------------------------------------------------------------- 错误（G24、G26）

export class AgentSendAction {
  static readonly UNAVAILABLE: string = 'unavailable';
  static readonly QUOTA: string = 'quota';
  static readonly NEW_CHAT: string = 'new_chat';
  static readonly RUN_IN_PROGRESS: string = 'run_in_progress';
  static readonly RATE_LIMITED: string = 'rate_limited';
  static readonly RETRY_SAME_MESSAGE: string = 'retry_same_message';
  static readonly AGENT_CONSENT: string = 'agent_consent';
  static readonly UNIFIED_CONSENT: string = 'unified_consent';
  static readonly UNIFIED_ERROR: string = 'unified_error';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly TEXT_TOO_LONG: string = 'text_too_long';
}

export class AgentSendDecision {
  readonly action: string;
  readonly disableMs: number;
  readonly reuseClientMsgId: boolean;
  readonly trace6: string | null;

  constructor(action: string, disableMs: number = 0, reuseClientMsgId: boolean = false, trace6: string | null = null) {
    this.action = action;
    this.disableMs = disableMs;
    this.reuseClientMsgId = reuseClientMsgId;
    this.trace6 = trace6;
  }

  json(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['actionRaw'] = this.action;
    if (this.disableMs > 0) {
      o['disableMs'] = this.disableMs;
    }
    o['reuseClientMsgId'] = this.reuseClientMsgId;
    o['trace6'] = this.trace6;
    return o;
  }
}

export class AgentSendErrorPolicy {
  static readonly DEFAULT_DISABLE_MS: number = 5000;

  static of(http: number, code: number, data: AgentJsonObject | null, retryAfter: string | null, traceId: string | null,
    consentType: string | null): AgentJsonObject {
    return AgentSendErrorPolicy.decide(http, code, data, retryAfter, traceId, consentType).json();
  }

  /** Retry-After（秒，正整数）→ 毫秒；缺省、非法、非正数按 5 秒（日期形式、小数未定，向量 gaps G24）。 */
  static retryAfterMs(raw: string | null): number {
    if (raw === null || !/^[0-9]{1,6}$/.test(raw.trim())) {
      return AgentSendErrorPolicy.DEFAULT_DISABLE_MS;
    }
    const s: number = Number.parseInt(raw.trim(), 10);
    return s > 0 ? s * 1000 : AgentSendErrorPolicy.DEFAULT_DISABLE_MS;
  }

  static trace6(traceId: string | null): string | null {
    if (traceId === null || traceId.length === 0) {
      return null;
    }
    return traceId.length > 6 ? traceId.substring(traceId.length - 6) : traceId;
  }

  static decide(_http: number, code: number, data: AgentJsonObject | null, retryAfter: string | null,
    traceId: string | null, consentType: string | null): AgentSendDecision {
    switch (code) {
      case 30501:
        return new AgentSendDecision(AgentSendAction.UNAVAILABLE);
      case 30502:
        return new AgentSendDecision(AgentSendAction.QUOTA);
      case 30504:
        return new AgentSendDecision(AgentSendAction.NEW_CHAT);
      case 30506:
        return new AgentSendDecision(AgentSendAction.RUN_IN_PROGRESS, AgentSendErrorPolicy.DEFAULT_DISABLE_MS);
      case 42901:
        return new AgentSendDecision(AgentSendAction.RATE_LIMITED, AgentSendErrorPolicy.retryAfterMs(retryAfter));
      case 50401:
        return new AgentSendDecision(AgentSendAction.RETRY_SAME_MESSAGE, 0, true, AgentSendErrorPolicy.trace6(traceId));
      case 50001:
        return new AgentSendDecision(AgentSendAction.NEW_CHAT, 0, false, AgentSendErrorPolicy.trace6(traceId));
      case 10004:
        return consentType === 'ai_third_party' ? new AgentSendDecision(AgentSendAction.AGENT_CONSENT, 0, true)
          : new AgentSendDecision(AgentSendAction.UNIFIED_CONSENT);
      case 10405:
        return new AgentSendDecision(AgentSendAction.FORCE_UPDATE);
      case 20001: {
        const fields: AgentJsonValue[] | null = data === null ? null : AgentJson.arrayOf(data['fields']);
        return fields !== null && fields.indexOf('text') >= 0 ? new AgentSendDecision(AgentSendAction.TEXT_TOO_LONG)
          : new AgentSendDecision(AgentSendAction.UNIFIED_ERROR);
      }
      default:
        return new AgentSendDecision(AgentSendAction.UNIFIED_ERROR, 0, false,
          code >= 50000 && code <= 59999 ? AgentSendErrorPolicy.trace6(traceId) : null);
    }
  }
}

export class AgentStreamErrorView {
  /** new_message：【重试】按新消息（新 client_msg_id，04 §8.1 同 ID 只重放原终止帧）；none：不给重试。 */
  readonly retry: string;
  readonly searchButton: boolean;
  /** 【去搜索】预填（fallback_q ≤100 字才预填）。 */
  readonly prefillQ: string | null;
  readonly textKey: string;
  readonly code: number;

  constructor(retry: string, searchButton: boolean, prefillQ: string | null, textKey: string, code: number) {
    this.retry = retry;
    this.searchButton = searchButton;
    this.prefillQ = prefillQ;
    this.textKey = textKey;
    this.code = code;
  }

  json(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['retryRaw'] = this.retry;
    o['searchButton'] = this.searchButton;
    o['prefillQ'] = this.prefillQ;
    o['textKey'] = this.textKey;
    return o;
  }
}

export class AgentStreamErrorPolicy {
  static readonly SEARCH_Q_MAX: number = 100;

  static of(data: AgentJsonObject): AgentJsonObject {
    return AgentStreamErrorPolicy.view(data).json();
  }

  static view(data: AgentJsonObject): AgentStreamErrorView {
    const code: number = AgentJson.intOf(data['code']) ?? 50001;
    const search: boolean = data['fallback'] === 'search_page';
    const q: string | null = AgentJson.stringOf(data['fallback_q']);
    const prefill: string | null = search && q !== null && AgentJson.codePoints(q) <= AgentStreamErrorPolicy.SEARCH_Q_MAX
      ? q : null;
    return new AgentStreamErrorView(data['retryable'] === true ? 'new_message' : 'none', search, prefill,
      'error.' + String(code), code);
  }
}

export class AgentDuplicatePolicy {
  /** duplicate 流的终止帧 → 本地怎么收尾（G26）：done 结束；error 30506 结束 loading、给同键【重试】；其他 error 按流内 error。 */
  static of(terminal: AgentJsonObject): AgentJsonObject {
    const o: AgentJsonObject = {};
    const data: AgentJsonObject | null = AgentJson.objectOf(terminal['data']);
    if (terminal['event'] === 'done') {
      o['localEndRaw'] = 'done';
    } else if (data !== null && data['code'] === 30506) {
      o['localEndRaw'] = 'error_30506';
      o['retryReusesClientMsgId'] = true;
    } else {
      o['localEndRaw'] = 'error';
      o['retryReusesClientMsgId'] = false;
    }
    return o;
  }
}

// ---------------------------------------------------------------- client_msg_id（BR-AI-23，G02、G24、G26）

export class ClientMsgId {
  static readonly PATTERN: RegExp = /^[A-Za-z0-9_-]{8,64}$/;
  private static counter: number = 0;
  private static readonly ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /** 新消息：进程内计数 + 时刻 + 随机，满足 ^[A-Za-z0-9_-]{8,64}$。 */
  static new(): string {
    ClientMsgId.counter++;
    let rand: string = '';
    for (let i: number = 0; i < 12; i++) {
      rand += ClientMsgId.ALPHABET.charAt(Math.floor(Math.random() * ClientMsgId.ALPHABET.length));
    }
    return 'm' + Date.now().toString(36) + '_' + ClientMsgId.counter.toString(36) + '_' + rand;
  }

  /**
   * 重发：50401、断线【重试】、同意后重放、duplicate 30506 的【重试】沿用原 ID（服务端按 BR-AI-23 ⑥ 去重）；流内 error 后的人工重试与新消息
   * 用新 ID（04 §8.1：同 ID 只重放原终止帧）。
   */
  static forRetry(situationRaw: string, previous: string): string {
    switch (situationRaw) {
      case 'retry_50401':
      case 'retry_disconnected':
      case 'replay_after_consent':
      case 'retry_duplicate_30506':
        return previous;
      default:
        return ClientMsgId.new();
    }
  }
}

// ---------------------------------------------------------------- AgentConsent（BR-ID-14、BR-AI-13，G16、G17）

export class AgentConsentPolicy {
  /** 只在 10004 + consent_type=ai_third_party 时弹（客户端不自行判断主体或版本）；同意后重放原请求一次。 */
  static of(_http: number, code: number, consentType: string | null): AgentJsonObject {
    const show: boolean = AgentConsentPolicy.shows(code, consentType);
    const o: AgentJsonObject = {};
    o['showSheet'] = show;
    o['replayCount'] = show ? 1 : 0;
    return o;
  }

  static shows(code: number, consentType: string | null): boolean {
    return code === 10004 && consentType === 'ai_third_party';
  }
}
