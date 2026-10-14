// APP-10 §2 第 9 条：AgentController（页面状态机，界面无关）。页面在 features/agent，组合在 entry/agent（AppAgent）。
// 身份构造时一次取得、之后只比较（brief §0 第 3 条，APP-09 第 63、65 条）：控制器构造时固定「环境 + 隐私 / 会话世代（网络层归属键）+
// 账号作用域 + AI 同意世代 + 页面实例」（AgentIdentity）；会话（session_id）、对话世代（【新对话】+1）、run 票据（client_msg_id + 本地
// run 序号）都在它之下派生。请求、连接、计时器、卡片回调、购买、同意弹窗、停止只用这一份；读「当前身份」只用于比较。
// 流的每一帧在发起时就绑定 run 票据：控制器先比票据（控制器存活、对话世代、run 是当前活动 run），不等即丢弃——不改消息、不改额度、
// 不写卡片、不发埋点、不滚动、不弹任何层。归属变化由 entry 在同步出口作废整个控制器并按新身份重建（不发 cancel，G06）。
// 消息、卡片、收益金额、client_msg_id、输入草稿都只在内存（G15），不写任何本机存储，不进日志与埋点。
// APP-10b（F-X-04）：接真实端口后新增——进入页面只读恢复历史（首页 + 向上翻页，G08、G39）；字节级流经 Reducer 外层的缺号守卫与累计上限
// （limited / incomplete，G11、G36）；断线 / 缺号 / duplicate / cancel 30505 的历史重载（AgentReconnect，G07、G38）；【停止】的 cancel 恰好一次与
// meta 之前的「正在停止」（AgentStopFlow，G26）；【赞】【踩】与举报（AgentFeedbackState / AgentReportState，G28、G29）；三组 Retry-After 闸门
// （G24）；30502 按 data.next（G27）；切 Tab / 被覆盖时流与在途历史保留、隐藏期间不更新界面、回来一次性应用（G02，编排者补充第 2 条）；
// 归属协调器（AgentOwnershipStop）在身份事件前同步作废本控制器并交出在途 run（stopForOwnership）。
// harmony-review-r1（APP-10b 第 1 轮修复）：AI 10004 不论来自 HTTP（七个 operation）还是 SSE 都经同一个同步作废入口 haltOwnedWork（关流、
// cancelOwned、撤销卡片回调与在途历史，R1-01）；30501（七个 operation + 流内）锁住本控制器的可用性并在实际发包准入处检查（R1-06）；发送 / 反馈 /
// 举报 / 重载结果按发起时的进入世代决定能否导航、提示、弹框（R1-05、R1-13）；进后台暂停整个重载流程（R1-08）；重载结果接入 AgentHistoryMerge
// 追加对不上的历史轮（R1-09）；所有有效历史页统一处理 expired（R1-10）；新对话 / 停止在同步入口 cancelOwned（R1-11）。
import { ClientEvent, ClientEvents, DefaultTexts, EventRouteEntryBlockedEntry, RouteSpec, Routes } from 'generated';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { CreditPeriodText, OrderStatusText } from '../orders/OrderPresentation';
import { SensitiveOutcome } from '../wallet/WalletPresentation';
import { OrderDraftTexts } from '../orders/OrderDraftTexts';
import { RouteSource } from '../router/RouteRequest';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentCard, AgentCardKind, AgentCardType, AgentEvent, AgentFrame, EarningsShape } from './AgentDecoder';
import { AgentDraftTexts } from './AgentDraftTexts';
import {
  AgentAmount, AgentConsentPolicy, AgentSendAction, AgentSendDecision, AgentSendErrorPolicy, AgentStreamErrorPolicy,
  AgentStreamErrorView, AgentTicketAction, AgentTicketEvent, AgentTicketPolicy, ClientMsgId, EarningsButton,
  EarningsCardView, EarningsView
} from './AgentPolicies';
import { AgentText, AgentTextBlock } from './AgentText';
import { AgentQuickReply, AgentStatus, AgentStreamState, AgentTerminal, AgentTool, StreamReducer } from './StreamReducer';
import {
  AgentCall, AgentContractPort, AgentConversationPort, AgentHttpResult, AgentStreamEvent, AgentStreamEventKind, AgentTimer,
  StreamClient, SystemAgentTimer
} from './StreamClient';
import { AgentPublishGate, AgentSeqGuard, AgentStreamLimits } from './AgentTransport';
import {
  AgentHistory, AgentHistoryGroup, AgentHistoryItem, AgentHistoryMerge, AgentHistoryPage, AgentHistoryPager, AgentTurnKey,
  AgentTurnMatch
} from './AgentHistory';
import {
  AgentReconnect, AgentReloadAction, AgentReloadOutcome, AgentReloadStep, AgentReloadTrigger
} from './AgentReconnect';
import {
  AgentCancelLedger, AgentCancelPolicy, AgentCancelResult, AgentConsentLapseTarget, AgentOwnedRun, AgentOwnershipTarget,
  AgentStopEffect, AgentStopFlow, AgentStopPhase
} from './AgentStop';
import {
  AgentActionFailure, AgentFeedback, AgentFeedbackState, AgentReplyTicket, AgentReport, AgentReportCheck,
  AgentReportOutcome, AgentReportState
} from './AgentFeedback';
import { AgentOperation } from './AgentErrors';
import { AgentQuotaNext, AgentQuotaPolicy } from './AgentAvailability';

/** 控制器构造时固定的身份（不含凭据；session 是网络层归属键，只用于比较）。 */
export class AgentIdentity {
  static readonly BASIC: string = 'basic';
  static readonly GUEST: string = 'guest';
  static readonly MEMBER: string = 'member';
  readonly env: string;
  readonly level: string;
  readonly userId: string | null;
  readonly session: string;
  /** AI 服务同意世代（设置页撤回成功 +1）。 */
  readonly aiConsent: number;
  /** 页面实例编号（Tab 根页每次创建 +1；页面销毁即作废）。 */
  readonly page: number;

  constructor(env: string, level: string, userId: string | null, session: string, aiConsent: number, page: number) {
    this.env = env;
    this.level = level;
    this.userId = userId;
    this.session = session;
    this.aiConsent = aiConsent;
    this.page = page;
  }

  get key(): string {
    return [this.env, this.level, this.userId ?? '', this.session, String(this.aiConsent), String(this.page)]
      .join('\u0001');
  }

  /** 归属键（不含页面实例）：换号、撤回、切环境、撤回 AI 同意才变（情境入口的交接按它核对）。 */
  get ownerKey(): string {
    return [this.env, this.level, this.userId ?? '', this.session, String(this.aiConsent)].join('\u0001');
  }

  /** 基本模式（未同意当前隐私版本）：不发任何 /v1/agent/* 请求（BR-ID-11、BR-AI-13）。 */
  get basic(): boolean {
    return this.level === AgentIdentity.BASIC;
  }
}

/** 一次 run 的票据（发起时生成，不可变）。 */
export class AgentRunTicket {
  readonly controller: number;
  readonly conversation: number;
  readonly run: string;
  readonly clientMsgId: string;

  constructor(controller: number, conversation: number, run: string, clientMsgId: string) {
    this.controller = controller;
    this.conversation = conversation;
    this.run = run;
    this.clientMsgId = clientMsgId;
  }

  json(): AgentJsonObject {
    const o: AgentJsonObject = {};
    o['controller'] = this.controller;
    o['conversation'] = this.conversation;
    o['run'] = this.run;
    return o;
  }
}

/** 页面级动作（发送、新对话、重新同意、重试加载）的渲染时票据。 */
export class AgentPageTicket {
  readonly controller: number;
  readonly conversation: number;

  constructor(controller: number, conversation: number) {
    this.controller = controller;
    this.conversation = conversation;
  }
}

export class AgentTapKind {
  static readonly GUIDE: string = 'guide';
  static readonly EARNINGS: string = 'earnings';
  static readonly RULE: string = 'rule';
  static readonly ORDER: string = 'order';
  static readonly PRODUCT: string = 'product';
  static readonly AUTH: string = 'auth';
  static readonly HANDOFF: string = 'handoff';
  static readonly SEARCH: string = 'search';
  static readonly LOGIN: string = 'login';
  static readonly BIND_PHONE: string = 'bind_phone';
}

/** 卡片按钮的渲染时票据：{run 票据, card_id, route, params}（APP-09 第 63 条：执行时只比较，不读当前控制器或消息列表）。 */
export class AgentTap {
  readonly controller: number;
  readonly conversation: number;
  readonly run: string;
  readonly cardId: string;
  readonly kind: string;
  readonly route: string;
  readonly params: Record<string, Object>;
  readonly source: RouteSource;
  /** 读屏用的完整名称（如「去看看，提现记录」）。 */
  readonly label: string;
  /** auth_required(union_auth) 的 resume_link_id（G19）。 */
  readonly resumeLinkId: string | null;
  /** 按钮上显示的文字（缺省同 label；页面引导卡显示「去看看」，读屏读「去看看，提现记录」）。 */
  readonly text: string;
  /** 渲染时的卡片动作世代（【停止】、【新对话】+1：之前渲染的卡片回调一律失效，R1-03）。 */
  epoch: number = 0;

  constructor(run: AgentRunTicket, cardId: string, kind: string, route: string, params: Record<string, Object>,
    source: RouteSource, label: string, resumeLinkId: string | null = null, text: string | null = null) {
    this.controller = run.controller;
    this.conversation = run.conversation;
    this.run = run.run;
    this.cardId = cardId;
    this.kind = kind;
    this.route = route;
    this.params = params;
    this.source = source;
    this.label = label;
    this.resumeLinkId = resumeLinkId;
    this.text = text ?? label;
  }
}

/** 购买按钮的渲染时票据：{run 票据, card_id, link_id, 渲染时的卡片快照}。 */
export class AgentBuyTap {
  readonly controller: number;
  readonly conversation: number;
  readonly run: string;
  readonly cardId: string;
  readonly itemCardId: string;
  readonly linkId: string;
  readonly product: AgentJsonObject;
  /** 渲染时的卡片动作世代（R1-03）。 */
  readonly epoch: number;

  constructor(run: AgentRunTicket, cardId: string, itemCardId: string, linkId: string, product: AgentJsonObject,
    epoch: number = 0) {
    this.epoch = epoch;
    this.controller = run.controller;
    this.conversation = run.conversation;
    this.run = run.run;
    this.cardId = cardId;
    this.itemCardId = itemCardId;
    this.linkId = linkId;
    this.product = product;
  }
}

/** 快捷追问（suggestions、notice 的 actions、「换一批」、示例问题、「查订单」）：{对话世代, send_text}。 */
export class AgentChipTap {
  readonly controller: number;
  readonly conversation: number;
  readonly text: string;
  readonly sendText: string;
  /** 卡片上的胶囊（notice 的 actions、「换一批」）的卡片动作世代；对话级胶囊（追问、示例、查订单）为 -1，不比较（R1-03）。 */
  epoch: number = -1;

  constructor(controller: number, conversation: number, text: string, sendText: string) {
    this.controller = controller;
    this.conversation = conversation;
    this.text = text;
    this.sendText = sendText;
  }
}

export class AgentRetryMode {
  /** 沿用同一 client_msg_id 直接重发（50401、无历史接口时的断线）。 */
  static readonly SAME: string = 'same';
  /** 断线后的【重试】（G07）：先拉历史首页（失败按 1/2/4/8 秒退避），再按决策表替换 / 同键重发 / 只留【重试】。 */
  static readonly RECONNECT: string = 'reconnect';
  /** 【刷新】（duplicate 30506、历史重载失败后）：用户点才拉一次历史首页（G40）。 */
  static readonly REFRESH: string = 'refresh';
  /** 新消息、新 client_msg_id（流内 error 后的人工重试）。 */
  static readonly NEW: string = 'new';
}

/** 【重试】：{run 票据, client_msg_id}。 */
export class AgentRetryTap {
  readonly controller: number;
  readonly conversation: number;
  readonly run: string;
  readonly clientMsgId: string;
  readonly mode: string;

  constructor(run: AgentRunTicket, mode: string) {
    this.controller = run.controller;
    this.conversation = run.conversation;
    this.run = run.run;
    this.clientMsgId = run.clientMsgId;
    this.mode = mode;
  }
}

/** 同意弹窗：{控制器编号, 弹窗编号, 待重放请求}。 */
export class AgentConsentTicket {
  readonly controller: number;
  readonly serial: number;
  /** 待重放的 run（同一 client_msg_id 重放一次）；进入页面时的 10004 没有待重放请求。 */
  readonly pendingRun: string | null;

  constructor(controller: number, serial: number, pendingRun: string | null) {
    this.controller = controller;
    this.serial = serial;
    this.pendingRun = pendingRun;
  }
}

/** 购买的卡片定位（PurchaseEnv.updateCard 只替换这一张卡：controller + conversation + run + card_id + 商品 card_id）。 */
export class AgentProductRef {
  readonly controller: number;
  readonly conversation: number;
  readonly run: string;
  readonly cardId: string;
  readonly itemCardId: string;
  /** 发起购买时的卡片动作世代（【停止】后购买尝试的结果不再更新卡片，R1-03）。 */
  readonly epoch: number;

  constructor(controller: number, conversation: number, run: string, cardId: string, itemCardId: string,
    epoch: number = 0) {
    this.epoch = epoch;
    this.controller = controller;
    this.conversation = conversation;
    this.run = run;
    this.cardId = cardId;
    this.itemCardId = itemCardId;
  }
}

export class AgentProductView {
  readonly json: AgentJsonObject;
  readonly detail: AgentTap | null;
  readonly buy: AgentBuyTap | null;
  /** 30141 下架、coupon_gone：卡片下方追加「换一批」（G25）。 */
  readonly refresh: AgentChipTap | null;
  readonly couponGone: boolean;

  constructor(json: AgentJsonObject, detail: AgentTap | null, buy: AgentBuyTap | null, refresh: AgentChipTap | null,
    couponGone: boolean) {
    this.json = json;
    this.detail = detail;
    this.buy = buy;
    this.refresh = refresh;
    this.couponGone = couponGone;
  }
}

/** 一张卡的展示（视图只展示；所有可点的东西都带票据）。 */
export class AgentCardView {
  readonly card: AgentCard;
  readonly layout: string;
  readonly products: AgentProductView[];
  readonly guideText: string;
  readonly guide: AgentTap | null;
  readonly earnings: EarningsView | null;
  readonly earningsTaps: AgentTap[];
  readonly rule: AgentTap | null;
  readonly order: AgentTap | null;
  readonly auth: AgentTap | null;
  readonly handoff: AgentTap | null;
  readonly chips: AgentChipTap[];
  /** 已在 Core 取好的展示文字（视图不计算）：标题、正文行、金额标签与金额（订单卡的预估返，受金额隐藏约束）。 */
  title: string = '';
  lines: string[] = [];
  amountLabel: string = '';
  amountText: string | null = null;
  /** fallback 卡的文字：经受限渲染器剥离 URL / scheme / 口令后的纯文字（APP-10 共性第 30 条，BR-AI-06；不可点、无按钮）。 */
  fallbackPlain: string = '';

  constructor(card: AgentCard, layout: string, products: AgentProductView[], guideText: string, guide: AgentTap | null,
    earnings: EarningsView | null, earningsTaps: AgentTap[], rule: AgentTap | null, order: AgentTap | null,
    auth: AgentTap | null, handoff: AgentTap | null, chips: AgentChipTap[]) {
    this.card = card;
    this.layout = layout;
    this.products = products;
    this.guideText = guideText;
    this.guide = guide;
    this.earnings = earnings;
    this.earningsTaps = earningsTaps;
    this.rule = rule;
    this.order = order;
    this.auth = auth;
    this.handoff = handoff;
    this.chips = chips;
  }
}

export class AgentTurnPhase {
  static readonly CONNECTING: string = 'connecting';
  static readonly STREAMING: string = 'streaming';
  static readonly ENDED: string = 'ended';
  /** JSON 错误（发送失败）。 */
  static readonly FAILED: string = 'failed';
  static readonly AWAITING_CONSENT: string = 'awaiting_consent';
}

export class AgentErrorView {
  readonly text: string;
  readonly retry: AgentRetryTap | null;
  readonly newChat: AgentPageTicket | null;
  readonly search: AgentTap | null;
  readonly searchLabel: string;
  readonly searchHint: string;
  readonly login: AgentTap | null;
  readonly quotaHint: string;

  constructor(text: string, retry: AgentRetryTap | null, newChat: AgentPageTicket | null, search: AgentTap | null,
    searchLabel: string = '', searchHint: string = '', login: AgentTap | null = null, quotaHint: string = '') {
    this.text = text;
    this.retry = retry;
    this.newChat = newChat;
    this.search = search;
    this.searchLabel = searchLabel;
    this.searchHint = searchHint;
    this.login = login;
    this.quotaHint = quotaHint;
  }
}

/** 【赞】【踩】（AgentResult 稿）：渲染时票据 + 当前选中与在途状态。 */
export class AgentFeedbackView {
  readonly ticket: AgentReplyTicket;
  readonly selected: string | null;
  readonly enabled: boolean;
  /** 读屏：「已赞」/「已踩」（未选为空串）。 */
  readonly a11y: string;

  constructor(ticket: AgentReplyTicket, selected: string | null, enabled: boolean, a11y: string) {
    this.ticket = ticket;
    this.selected = selected;
    this.enabled = enabled;
    this.a11y = a11y;
  }
}

/** 举报入口（长按 + 读屏「更多操作 → 举报」）与「已举报」标记（AgentReported 稿）。 */
export class AgentReportEntryView {
  readonly ticket: AgentReplyTicket;
  readonly reported: boolean;

  constructor(ticket: AgentReplyTicket, reported: boolean) {
    this.ticket = ticket;
    this.reported = reported;
  }
}

/** 举报半屏（AgentReport 稿）：被举报回复的摘要（受限渲染、截断）、原因、补充说明、提交中、原因旁错误。 */
export class AgentReportSheetView {
  readonly ticket: AgentReplyTicket;
  readonly quote: string;
  readonly reasons: string[];
  readonly selected: string | null;
  readonly supplement: string;
  readonly submitting: boolean;
  readonly inlineError: boolean;
  /** 补充说明输入框的码点上限（200 − 原因 − 1，G29）。 */
  readonly supplementLimit: number;

  constructor(ticket: AgentReplyTicket, quote: string, reasons: string[], selected: string | null, supplement: string,
    submitting: boolean, inlineError: boolean, supplementLimit: number) {
    this.ticket = ticket;
    this.quote = quote;
    this.reasons = reasons;
    this.selected = selected;
    this.supplement = supplement;
    this.submitting = submitting;
    this.inlineError = inlineError;
    this.supplementLimit = supplementLimit;
  }
}

export class AgentTurnView {
  readonly key: string;
  readonly run: AgentRunTicket;
  readonly userText: string;
  readonly phase: string;
  readonly status: string;
  readonly blocks: AgentTextBlock[];
  readonly tools: AgentTool[];
  readonly cards: AgentCardView[];
  readonly chips: AgentChipTap[];
  /** 已结束的 assistant 消息底部 AiLabel（meta.ai_label，缺则 ai_label 键）。 */
  readonly aiLabel: string | null;
  readonly error: AgentErrorView | null;
  readonly streaming: boolean;
  /** 【赞】【踩】（只在已结束且有可信回复 id 时，G28）。 */
  feedback: AgentFeedbackView | null = null;
  /** 举报入口 / 已举报（同一条件，G29）。 */
  report: AgentReportEntryView | null = null;
  /** 状态说明（「正在停止」「已停止」等草稿；空串不显示）。 */
  statusText: string = '';
  /** 历史里没有对应用户消息（页首孤立的回复）：不画用户气泡。 */
  hideUser: boolean = false;
  /** 历史来源（进入页面恢复、重载替换）。 */
  fromHistory: boolean = false;
  /** 历史 error 的通用出错条目（不带 trace6、不给重试，G42）。 */
  genericError: string = '';

  constructor(key: string, run: AgentRunTicket, userText: string, phase: string, status: string, blocks: AgentTextBlock[],
    tools: AgentTool[], cards: AgentCardView[], chips: AgentChipTap[], aiLabel: string | null, error: AgentErrorView | null,
    streaming: boolean) {
    this.key = key;
    this.run = run;
    this.userText = userText;
    this.phase = phase;
    this.status = status;
    this.blocks = blocks;
    this.tools = tools;
    this.cards = cards;
    this.chips = chips;
    this.aiLabel = aiLabel;
    this.error = error;
    this.streaming = streaming;
  }
}

export class AgentPhase {
  /** Release / 无接口 / 30501：「未开放」（不显示输入框、不弹同意框、不发请求，G01）。 */
  static readonly UNAVAILABLE: string = 'unavailable';
  /** 基本模式：不发请求（EntryGuard 已拦 AgentChat，这里只防 Tab 根页被挂载时发请求）。 */
  static readonly BLOCKED: string = 'blocked';
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly READY: string = 'ready';
  static readonly LOAD_FAILED: string = 'load_failed';
  /** 【暂不使用】之后：说明 +【重新同意】（G17）。 */
  static readonly CONSENT_DECLINED: string = 'consent_declined';
}

/**
 * AI 同意的发送闸门（BR-ID-14、BR-AI-13；harmony-review-r1 R1-01，S0）：待同意 → 提交中 → 已记录。只有 recordConsent 成功才回到 clear；
 * 提交中、记录失败、暂不使用、关闭弹窗都保持禁发。发送、快捷追问、示例、【重试】、自动重放与实际发包（AgentCall.sendAllowed）统一核对它。
 */
export class AgentConsentGate {
  static readonly CLEAR: string = 'clear';
  /** 收到 10004(ai_third_party)，等用户在弹窗里选择。 */
  static readonly AWAITING: string = 'awaiting';
  /** 已点【同意并使用】，recordConsent 还没有结果。 */
  static readonly SUBMITTING: string = 'submitting';
  /** 暂不使用、关闭弹窗或记录失败：仍禁发，【重新同意】再弹。 */
  static readonly REFUSED: string = 'refused';
}

/** 四个待定 operation 共用错误规则的结论（AgentController.sharedError）。 */
export class AgentSharedError {
  static readonly RATE_LIMITED: string = 'rate_limited';
  static readonly FORCE_UPDATE: string = 'force_update';
  static readonly CONSENT: string = 'consent';
  static readonly UNIFIED: string = 'unified';
  static readonly UNAVAILABLE: string = 'unavailable';
  static readonly SILENT: string = 'silent';
  static readonly OTHER: string = 'other';
}

/** 页面快照（不可变）。 */
export class AgentSnapshot {
  owner: number = 0;
  conversation: number = 0;
  phase: string = AgentPhase.IDLE;
  turns: AgentTurnView[] = [];
  /** 发送中（发送按钮与胶囊禁用并显示【停止】）。 */
  sending: boolean = false;
  /** 【停止】的票据（当前活动 run）。 */
  stop: AgentRunTicket | null = null;
  /** 42901 / 30506 禁用期（Retry-After，缺省 5 秒）。 */
  limited: boolean = false;
  /** 30502：今日额度用完（输入框禁用，以服务端为准）。 */
  quotaExhausted: boolean = false;
  /** 最近一次非 duplicate 流的 done.quota_left（只在内存，G28；设计稿没有位置，不显示）。 */
  quotaLeft: number | null = null;
  consent: AgentConsentTicket | null = null;
  /** AI 同意的发送闸门（AgentConsentGate；不是 clear 时一律禁发，R1-01）。 */
  consentGate: string = 'clear';
  /** 同意记录失败（仍禁发；显示失败说明与【重新同意】，R1-01）。 */
  consentFailed: boolean = false;
  page: AgentPageTicket = new AgentPageTicket(0, 0);
  examples: AgentChipTap[] = [];
  ordersChip: AgentChipTap | null = null;
  filingText: string = '';
  /** 情境入口的提示（G27：附在用户发的第一条上，不自动发送）。 */
  contextLabelKey: string | null = null;
  /** 加载失败的统一文案（LOAD_FAILED 整页；就绪时为翻页失败那一行的统一文案，5xxxx 带 trace6，R2-05；空串用固定的「加载失败」）。 */
  loadErrorText: string = '';
  /** 数据变化的版本号（自动滚动与读屏播报用）。 */
  revision: number = 0;
  /** 最近一条可播报的新文字（读屏开启时用无障碍播报；不含金额）。 */
  announcement: string = '';
  /** 向上翻页（G08）：more（还有更早的）/ loading / none（没有更早的）/ failed / hidden（没有历史接口或空对话）。 */
  earlier: string = 'hidden';
  /** 会话已过期只读（G09）或历史 30504（会话已不存在）：输入框与胶囊禁用，显示 error.30504 +【新对话】。 */
  readOnly: boolean = false;
  /** 对话区底部的会话提示（error.30504 等；空串不显示）。 */
  sessionNotice: string = '';
  /** 读取闸门（42901）：禁用【重试】【刷新】与翻页。 */
  readLimited: boolean = false;
  /** 动作闸门（42901）：禁用【赞】【踩】与【提交举报】。 */
  actionLimited: boolean = false;
  /** 举报半屏（只开本控制器这一个实例；没有为 null）。 */
  reportSheet: AgentReportSheetView | null = null;
  /** 轻提示（举报已提交等）：页面按 revision 显示一次。 */
  notice: string = '';
  /** 有历史接口与当前会话（断线【重试】/【刷新】走历史重载、受读取闸门；否则同键重发、受发送闸门）。 */
  reloadable: boolean = false;

  // ---- 三组闸门的页面接线（harmony-review-r2 R2-06；G24：页面与执行层同时生效，执行层由 AgentCall.sendAllowed 按 operation 核对）

  /** 发送闸门（42901 / 30506）或 AI 同意未记录：发送、胶囊、追问、卡片动作与同键 / 新消息【重试】禁用。 */
  get sendBlocked(): boolean {
    return this.limited || this.consentGate !== AgentConsentGate.CLEAR;
  }

  /** 整页加载失败的【重试】（取当前会话 + 历史首页）：读取闸门。 */
  get loadRetryDisabled(): boolean {
    return this.readLimited;
  }

  /** 向上翻页（加载更早的消息 / 翻页失败后再点）：读取闸门。 */
  get earlierDisabled(): boolean {
    return this.readLimited;
  }

  /** 【赞】【踩】与【提交举报】：动作闸门。 */
  get actionDisabled(): boolean {
    return this.actionLimited;
  }

  /** 消息内【重试】/【刷新】：重连查询与刷新（走历史重载）用读取闸门，同键重发与新消息用发送闸门；AI 同意未记录时都禁用。 */
  retryDisabled(mode: string): boolean {
    if (this.consentGate !== AgentConsentGate.CLEAR) {
      return true;
    }
    if ((mode === AgentRetryMode.RECONNECT || mode === AgentRetryMode.REFRESH) && this.reloadable) {
      return this.readLimited;
    }
    return this.limited;
  }
}

/** 控制器依赖（entry AppAgent 组装；单测按同一接线组装）。 */
export class AgentDeps {
  identity: AgentIdentity;
  currentKey: () => string;
  contract: AgentContractPort | null = null;
  gate: RetryAfterGate;
  timer: AgentTimer = new SystemAgentTimer();
  clock: () => number = Date.now;
  routes: Map<string, RouteSpec> = Routes.all;
  /** 金额隐藏（AmountMaskStore，与钱包、订单页同一偏好）。 */
  masked: () => boolean = () => false;
  subscribeMask: (listener: (hidden: boolean) => void) => () => void = (_l: (hidden: boolean) => void) => (): void => {
  };
  /** 金额格式化（页面给 DesignSystem 的 CouliFormat.money）。 */
  money: (fen: number) => string = AgentAmount.yuan;
  /** 经 Router 打开（只在用户点击时调用）。 */
  open: (route: string, params: Record<string, Object>, source: RouteSource) => void =
    (_r: string, _p: Record<string, Object>, _s: RouteSource) => {
    };
  /** 卡片购买：交已有 OpenPurchaseController（场景 agent）。 */
  buy: (product: AgentJsonObject, ref: AgentProductRef) => void = (_p: AgentJsonObject, _r: AgentProductRef) => {
  };
  /** 企业微信客服（APP-12 已有的客服打开实现，G21）。 */
  customerService: () => void = () => {
  };
  /** recordConsent{type: ai_third_party, accepted, channel: agent_sheet}（G16）。 */
  recordConsent: (accepted: boolean) => Promise<AgentHttpResult> = (_a: boolean) =>
  Promise.resolve(AgentHttpResult.notSentResult());
  track: (event: ClientEvent) => void = (_e: ClientEvent) => {
  };
  toast: (text: string) => void = (_t: string) => {
  };
  /** 10405：照已有分流进强更。 */
  forceUpdate: () => void = () => {
  };
  /** 购买执行器的在途尝试作废（【停止】、【新对话】：只挡外跳，之后的响应不再更新卡片，R1-03）。 */
  cancelPurchase: () => void = () => {
  };
  /** 当前会员是否已绑手机（额度用完时已绑手机不再引导绑定，H10；未知为 null，按未验证处理）。 */
  phoneBound: () => boolean | null = () => null;
  /** 只写事件名与结果，不写 data、金额。 */
  log: (message: string) => void = (_m: string) => {
  };
  /** 平台显示名（草稿表；缺省原样）。 */
  platformName: (platform: string) => string = (p: string) => {
    const name: string = OrderDraftTexts.text('platform.' + p);
    return name.length > 0 ? name : p;
  };
  examples: () => string[] = () => [];
  filingText: () => string = () => '';
  /** 情境入口（G27）：in_app 入口交来的一次性 context（{product_key} / {order_id} / {text ≤2000}），附在第一条消息上。 */
  context: AgentJsonObject | null = null;
  /** 历史、反馈、举报（APP-10b 真实端口；APP-10 的测试替身没有，为 null 时这三项不提供）。 */
  conversation: AgentConversationPort | null = null;
  /** 读取闸门（getCurrentAgentSession、listAgentSessionMessages，G24）；null = 控制器自建（同一时钟与归属）。 */
  readGate: RetryAfterGate | null = null;
  /** 动作闸门（反馈、举报、cancel，G24）；null = 控制器自建。 */
  actionGate: RetryAfterGate | null = null;
  /** 退避抖动的随机数（[0,1)，G38；测试注入）。 */
  random: () => number = (): number => Math.random();
  /** App 此刻在前台（后台不发起任何重试，03 §7.2）。 */
  foreground: () => boolean = (): boolean => true;
  /** 已发 cancel 的 run（应用级共用：【停止】、重进页面、归属协调器同一 run 只发 1 次）。 */
  cancelLedger: AgentCancelLedger = new AgentCancelLedger();
  /** 「会员但账号未知」（FU-AND-0714 第 4 条）：不取会话、不拉历史、不建会话、不发消息、不反馈举报。 */
  memberUnknown: boolean = false;
  /**
   * 应用级发包许可（harmony-review-r1 R1-03、R1-07）：配置（agent.enabled / agent.entry.visible）仍开、没有身份变更流程（撤回 AI 同意、撤回隐私、
   * 退出登录）在途。每次实际发包前与本控制器的其他闸门一起核对，不通过就永久失效（同 AgentCall.sendAllowed）。
   */
  allowed: () => boolean = (): boolean => true;
  /**
   * 应用级「AI 同意失效」（harmony-review-r2 R2-02，AgentConsentLapse）：本控制器的归属此刻是否处于失效。为 true 时首次显示就是「需要重新同意」
   * （不取会话、不拉历史），直到重新同意记录成功（App 同时在 allowed 里封住准入）。
   */
  consentLapsed: () => boolean = (): boolean => false;
  /**
   * 此刻的归属键（不含页面实例，harmony-review-r3 R3-01）：【停止】与身份事件 cancel 的结果按它核对原归属（页面实例销毁 / 重建不丢弃结果）。
   * null = 退回按 currentKey 比较（APP-10 的测试接线）。
   */
  currentOwnerKey: (() => string) | null = null;
  /**
   * 应用级「AI 同意失效」入口（harmony-review-r3 R3-01，S0）：本控制器任何来源的 AI 10004（发送、重放、建会话、取会话、历史、反馈 / 举报、流内、
   * 【停止】的 cancel）都以构造时固定的归属键（不含页面实例）交给它；App 按此刻归属核对后记下并同步停下同归属的控制器。
   */
  aiConsentLost: (ownerKey: string) => void = (_k: string) => {
  };

  constructor(identity: AgentIdentity, currentKey: () => string, gate: RetryAfterGate) {
    this.identity = identity;
    this.currentKey = currentKey;
    this.gate = gate;
  }
}

/** 控制器内部的一轮对话。 */
class Turn {
  run: AgentRunTicket;
  readonly userText: string;
  readonly body: string;
  state: AgentStreamState = StreamReducer.initial();
  phase: string = AgentTurnPhase.CONNECTING;
  client: StreamClient<AgentRunTicket> | null = null;
  error: AgentErrorView | null = null;
  /** 同一 client_msg_id 重发中：duplicate 流不并入原消息（G26）。 */
  resend: boolean = false;
  resendState: AgentStreamState = StreamReducer.initial();
  consentReplays: number = 0;
  /** 【停止】过的这一轮：卡片照常显示，按钮与购买一律失效（R1-03）。 */
  revoked: boolean = false;
  /** 本轮响应头的 X-Trace-Id（流内 error 的 trace6，R1-07）。 */
  traceId: string = '';
  /** 已记过 route_entry_blocked 的卡（同一卡同一对话只记一次，G10）。 */
  readonly blockedReported: Set<string> = new Set<string>();
  /** 购买结果对商品卡的更新（card_id#item_card_id → 新卡）。 */
  readonly products: Map<string, AgentJsonObject> = new Map<string, AgentJsonObject>();
  /** 发送时刻（G05 对齐：发送时刻 −5 分钟下界）。 */
  sentAtMs: number = 0;
  /** 本轮累计上限（AgentStreamLimits，共性第 28、29、33 条）。 */
  limits: AgentStreamLimits = new AgentStreamLimits();
  /** 停止流程（G26）；没有点过【停止】为 null。 */
  stopFlow: AgentStopFlow | null = null;
  /** 「正在停止」的 30 秒等待计时。 */
  stopTimer: number = -1;
  /** 历史重载（AgentReconnect）与它的退避计时、发起时的票据序号。 */
  reload: AgentReconnect | null = null;
  reloadTimer: number = -1;
  reloadSerial: number = 0;
  /** 历史来源的轮（进入页面恢复、重载替换）。 */
  fromHistory: boolean = false;
  /** 历史里的用户消息 id（对齐与去重；本地发出的没有）。 */
  userId: string | null = null;
  /** 页首孤立的回复（历史里没有它的用户消息）。 */
  hideUser: boolean = false;
  /** 没有回复（只有用户消息的历史轮）。 */
  noReply: boolean = false;
  /** duplicate 收尾、尚未以历史替换（G28：替换前不显示反馈）。 */
  duplicatePending: boolean = false;
  /** 回复 id 是否可信（G03：meta.message_id 在历史里指到 user 时为 false）。 */
  replyTrusted: boolean = true;
  readonly feedback: AgentFeedbackState = new AgentFeedbackState();
  readonly report: AgentReportState = new AgentReportState();
  /** 本轮最近一次发出（发送、同键重发、同意后重放）时的进入世代：结果的导航、提示、弹框只在它仍有效且可见时做（R1-05）。 */
  entry: number = 0;
  /** 本轮历史重载开始时的进入世代（重载错误的前置分流与提示按它核对，R1-13）。 */
  reloadEntry: number = 0;
  /** 本轮重载最近一次带外壳的失败（完整结果：码、trace_id；退避用尽时 5xxxx 显示统一文案 + trace6，R1-13）。 */
  reloadError: AgentHttpResult | null = null;

  constructor(run: AgentRunTicket, userText: string, body: string) {
    this.run = run;
    this.userText = userText;
    this.body = body;
  }
}

export class AgentController implements AgentOwnershipTarget, AgentConsentLapseTarget {
  static readonly MAX_INPUT: number = 500;
  static readonly CONTEXT_TEXT_MAX: number = 2000;
  static readonly PAGE_NAME: string = 'AgentChat';
  private static serials: number = 0;
  readonly serial: number;
  private readonly deps: AgentDeps;
  private readonly identity: AgentIdentity;
  private readonly identityKey: string;
  private disposed: boolean = false;
  private started: boolean = false;
  private phase: string = AgentPhase.IDLE;
  private conversation: number = 1;
  private runSeq: number = 0;
  private sessionId: string | null = null;
  private turns: Turn[] = [];
  private active: Turn | null = null;
  private quotaExhausted: boolean = false;
  private quotaLeft: number | null = null;
  private consent: AgentConsentTicket | null = null;
  private consentSerial: number = 0;
  /** AI 同意闸门（R1-01）。 */
  private consentGate: string = AgentConsentGate.CLEAR;
  /** 提交中的那一张弹窗票据（结果只认它）。 */
  private submitting: AgentConsentTicket | null = null;
  private consentFailed: boolean = false;
  /** 页面此刻可见（Tab 选中、没被覆盖、在前台；entry 在同步可见性出口写入，R1-02）。 */
  private visible: boolean = false;
  /** 进入世代：每次离开（不可见）+1，之前发起的异步结果只结算、不改界面（R1-02）。 */
  private entry: number = 0;
  /** 卡片动作世代：【停止】、【新对话】+1（R1-03）。 */
  private cardEpoch: number = 0;
  private loadErrorText: string = '';
  private context: AgentJsonObject | null;
  private revision: number = 0;
  private announcement: string = '';
  private unsubscribers: (() => void)[] = [];
  /** 读取闸门、动作闸门（G24；发送闸门是 deps.gate）。 */
  private readonly readGate: RetryAfterGate;
  private readonly actionGate: RetryAfterGate;
  /** 隐藏期间不把快照交给界面，回来一次性应用（G02）。 */
  private readonly publishGate: AgentPublishGate = new AgentPublishGate();
  /** 向上翻页（G08）；没有历史或首页没有游标为 null。 */
  private pager: AgentHistoryPager | null = null;
  private earlierFailed: boolean = false;
  /** 会话只读（expired=true，G09）或历史 30504 后的提示。 */
  private readOnly: boolean = false;
  private sessionNotice: string = '';
  /** 举报半屏打开的那一轮（只开一个实例）。 */
  private reportTurn: Turn | null = null;
  private notice: string = '';
  /** 历史与重载的票据序号（新对话、作废时 +1：迟到的历史页丢弃）。 */
  private historySerial: number = 0;
  /** 本次进入（本控制器）收到过 30501：「未开放」，到下次进入页面（重建控制器）前不再发任何 agent 请求（R1-06）。 */
  private serverUnavailable: boolean = false;
  /** 反馈 / 举报的工作世代：【停止】+1（harmony-review-r2 R2-03：停止之前发起的反馈 / 举报结果作废，只结算共享事实）。 */
  private workSerial: number = 0;
  /** 正在把 AI 10004 交给应用级入口（R3-01：App 同步回调本控制器时不重入）。 */
  private lapseReporting: boolean = false;
  onChange:(s: AgentSnapshot) => void = (_s: AgentSnapshot) => {
  };

  constructor(deps: AgentDeps) {
    AgentController.serials++;
    this.serial = AgentController.serials;
    this.deps = deps;
    // 构造时一次性固定身份（之后只比较）。
    this.identity = deps.identity;
    this.identityKey = deps.identity.key;
    this.context = AgentController.validContext(deps.context);
    // G24：三组闸门由 App 分别给；没给的（APP-10 的测试接线）退回共享的发送闸门（APP-10 H21 口径）。
    this.readGate = deps.readGate ?? deps.gate;
    this.actionGate = deps.actionGate ?? deps.gate;
    this.unsubscribers.push(deps.gate.subscribe((): void => this.publish()));
    if (this.readGate !== deps.gate) {
      this.unsubscribers.push(this.readGate.subscribe((): void => this.publish()));
    }
    if (this.actionGate !== deps.gate && this.actionGate !== this.readGate) {
      this.unsubscribers.push(this.actionGate.subscribe((): void => this.publish()));
    }
    this.unsubscribers.push(deps.subscribeMask((_hidden: boolean): void => this.publish()));
    if (deps.contract === null) {
      this.phase = AgentPhase.UNAVAILABLE;
    } else if (deps.identity.basic || deps.memberUnknown) {
      // 基本模式、会员但账号未知（FU-AND-0714 第 4 条）：不取会话、不拉历史、不建会话、不发消息。
      this.phase = AgentPhase.BLOCKED;
    }
  }

  /** 控制器仍有效：没作废、此刻身份与构造时一致。 */
  alive(): boolean {
    if (this.disposed) {
      return false;
    }
    try {
      return this.deps.currentKey() === this.identityKey;
    } catch (e) {
      return false;
    }
  }

  get boundIdentity(): AgentIdentity {
    return this.identity;
  }

  /** 每轮 assistant 消息的流状态（只读；测试按 G32 规范化比较用）。 */
  get streamStates(): AgentStreamState[] {
    return this.turns.map((t: Turn): AgentStreamState => t.state);
  }

  get currentPhase(): string {
    return this.phase;
  }

  /** 当前活动 run（测试与诊断用）。 */
  get activeRun(): AgentRunTicket | null {
    return this.active === null ? null : this.active.run;
  }

  /** 第一次显示：取当前会话（不拉历史，G02）。Release / 无接口为「未开放」，不发请求。 */
  start(): void {
    if (this.started || !this.alive() || !this.visible) {
      return;
    }
    this.started = true;
    if (this.phase === AgentPhase.UNAVAILABLE || this.phase === AgentPhase.BLOCKED) {
      this.publish();
      return;
    }
    if (this.lapsedNow()) {
      // R2-02：应用级「AI 同意失效」期间重建（含撤回请求失败解锁后回到页面）：一开始就是「需要重新同意」，不取会话、不拉历史。
      this.consentLost(null, false);
      return;
    }
    this.load();
  }

  private lapsedNow(): boolean {
    try {
      return this.deps.consentLapsed();
    } catch (e) {
      return false;
    }
  }

  /** 构造时固定的归属键（不含页面实例；AgentConsentLapse 核对用）。 */
  boundOwnerKey(): string {
    return this.identity.ownerKey;
  }

  /**
   * 应用级 cancel 返回 AI 10004（harmony-review-r2 R2-02，S0；AgentConsentLapse 已核对同一归属）：与七个 operation 的 AI 10004 同一个同步作废入口
   * ——关流、停计时、取消所属请求、进行中的回复本地结束不更新额度，再锁同意闸门；不弹框、不导航（cancel 结果的限制）。
   */
  consentLapsed(): void {
    if (!this.alive() || this.lapseReporting) {
      // 自己上报时 App 回调到本控制器：已在 aiConsentRevoked 里作废过，不重复。
      return;
    }
    this.revokeConsent(null, false, false);
    this.publish();
  }

  /** 此刻归属（不含页面实例）仍是构造时的归属（R3-01；没给 currentOwnerKey 时按完整身份键）。 */
  private ownerStill(): boolean {
    const f: (() => string) | null = this.deps.currentOwnerKey;
    try {
      return f === null ? this.deps.currentKey() === this.identityKey : (f as () => string)() === this.identity.ownerKey;
    } catch (e) {
      return false;
    }
  }

  /** 把 AI 10004 交给应用级「AI 同意失效」入口（R3-01）；App 回调到本控制器时不重入。 */
  private reportConsentLapse(): void {
    if (this.lapseReporting) {
      return;
    }
    this.lapseReporting = true;
    try {
      this.deps.aiConsentLost(this.identity.ownerKey);
    } catch (e) {
      // App 出错不影响本控制器已完成的作废。
    } finally {
      this.lapseReporting = false;
    }
  }

  private load(): void {
    const contract: AgentContractPort = this.deps.contract as AgentContractPort;
    this.phase = AgentPhase.LOADING;
    this.loadErrorText = '';
    this.publish();
    const conversation: number = this.conversation;
    const entry: number = this.entry;
    const serial: number = this.historySerial;
    // 进入页面只读（G39）：取当前会话，有会话再取历史首页；不建会话、不发消息。读取闸门在执行层核对（G24）。
    contract.currentSession(this.call((): boolean => this.phase === AgentPhase.LOADING, AgentOperation.CURRENT))
      .then((r: AgentHttpResult): void => {
        // 先核对归属，再核对对话世代（切 Tab 期间到达的照常落到内存，回来一次性应用，G02）。
        if (!this.alive()) {
          return;
        }
        if (conversation !== this.conversation || serial !== this.historySerial || this.phase !== AgentPhase.LOADING) {
          this.settleOnly(r, AgentOperation.CURRENT);
          return;
        }
        if (r.ok) {
          // 「成功但为空」（session=null）与「加载失败」分开（APP-11 第 6 条）：空会话等第一次发送时再建。
          const session: AgentJsonObject | null = AgentJson.objectOf(r.data['session']);
          this.sessionId = session === null ? null :
            AgentJson.stringOf(session['session_id']) ?? AgentJson.stringOf(session['id']);
          if (this.sessionId !== null && this.deps.conversation !== null) {
            this.loadHistory(entry);
            return;
          }
          this.phase = AgentPhase.READY;
          this.publish();
          return;
        }
        this.loadFailed(r, AgentOperation.CURRENT, entry);
      });
  }

  /** 进入页面的历史首页（limit=20，G08；ApiClient 的 GET 自动重试 1 次照旧，G35）。 */
  private loadHistory(entry: number): void {
    const port: AgentConversationPort = this.deps.conversation as AgentConversationPort;
    const sessionId: string = this.sessionId as string;
    const conversation: number = this.conversation;
    const serial: number = this.historySerial;
    port.listMessages(sessionId, null, AgentHistory.LIMIT, this.call((): boolean => this.phase === AgentPhase.LOADING,
      AgentOperation.HISTORY), true).then((r: AgentHttpResult): void => {
      if (!this.alive()) {
        return;
      }
      if (conversation !== this.conversation || serial !== this.historySerial || this.sessionId !== sessionId
        || this.phase !== AgentPhase.LOADING) {
        // A 的历史页在换登 B / 新对话之后到达：丢弃（brief §0 第 1 条），只结算共享事实。
        this.settleOnly(r, AgentOperation.HISTORY);
        return;
      }
      if (r.ok) {
        const page: AgentHistoryPage | null = AgentHistory.page(r.data, this.deps.routes);
        if (page === null) {
          this.loadFailed(AgentHttpResult.network(), AgentOperation.HISTORY, entry);
          return;
        }
        this.applyFirstPage(page as AgentHistoryPage);
        return;
      }
      if (r.code === 30504) {
        // 会话不存在或不是本人：清掉本地 session_id，显示空对话 + error.30504（下次发送重新建会话，G24 表）。
        this.sessionId = null;
        this.sessionNotice = AgentController.errorText(30504, '');
        this.phase = AgentPhase.READY;
        this.publish();
        return;
      }
      this.loadFailed(r, AgentOperation.HISTORY, entry);
    });
  }

  /** 冷启动 / 页面实例新建：历史首页整体作为初始对话（G06）；只读过期（G09）。 */
  private applyFirstPage(page: AgentHistoryPage): void {
    this.turns = this.historyTurns(page.items);
    this.pager = new AgentHistoryPager(page.nextCursor);
    this.earlierFailed = false;
    if (page.dropped > 0) {
      this.deps.log('agent history dropped ' + String(page.dropped));
    }
    this.applyExpired(page);
    this.phase = AgentPhase.READY;
    this.publish();
  }

  /**
   * 有效历史页（首页、翻页、重载）的 expired=true（R1-10，G09）：整段只读——同步锁住输入框、胶囊与同键重发，显示 error.30504 与【新对话】，
   * 直到建立新对话（dropConversation 清除）。
   */
  private applyExpired(page: AgentHistoryPage): void {
    if (!page.expired) {
      return;
    }
    this.readOnly = true;
    this.sessionNotice = AgentController.errorText(30504, '');
  }

  private loadFailed(r: AgentHttpResult, op: string, entry: number): void {
    const kind: string = this.sharedError(r, null, op, this.current(entry));
    if (kind === AgentSharedError.UNAVAILABLE) {
      this.phase = AgentPhase.UNAVAILABLE;
    } else if (kind === AgentSharedError.CONSENT) {
      this.phase = AgentPhase.READY;
    } else {
      // 读取失败要展示、不当成空对话（APP-12 第 23 条）；【重试】受读取闸门控制。没有外壳按网络失败（G34：planned 期间 404 同此）。
      this.phase = AgentPhase.LOAD_FAILED;
      this.loadErrorText = AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId);
    }
    this.publish();
  }

  // ---------------------------------------------------------------- 四个待定 operation 共用的错误规则（R1-05、R1-06）

  /**
   * createAgentSession、getCurrentAgentSession、sendAgentMessage、cancelAgentRun 同一套：调用方已核对归属与进入世代。
   * 42901 → 共享闸门（Retry-After 缺省 5 秒）；10405 → 强更；10004(ai_third_party) → 同意弹窗（pendingRun 为待重放的 run）；
   * 10001 / 10005 / 其他 10004 → 统一分流（unified）；30501 → 未开放（由调用方切换）；30505 → 静默；本地没发出 → 静默；其余交调用方。
   */
  private sharedError(r: AgentHttpResult, pendingRun: string | null, op: string = AgentOperation.SEND,
    interactive: boolean = true): string {
    if (r.notSent) {
      return AgentSharedError.SILENT;
    }
    switch (r.code) {
      case 42901:
        // G24：写这个 operation 所属的闸门（发送 / 读取 / 动作），缺省或非法 5 秒。
        this.gateOf(op).start(AgentSendErrorPolicy.retryAfterMs(r.retryAfter));
        return AgentSharedError.RATE_LIMITED;
      case 10405:
        this.deps.forceUpdate();
        return AgentSharedError.FORCE_UPDATE;
      case 30501:
        // R1-06：七个 operation 的 30501 同一处——锁住本次进入的可用性、取消在途工作；准入处（call）统一检查。
        this.lockUnavailable();
        return AgentSharedError.UNAVAILABLE;
      case 30505:
        return AgentSharedError.SILENT;
      default:
        break;
    }
    if (AgentConsentPolicy.shows(r.code, r.consentType)) {
      // 七个 operation 都经同一个同步作废入口（R1-01）；只有发送类（发送、建会话、取当前会话）在发起许可仍有效时弹框（G24、G59）。
      const sendClass: boolean = op === AgentOperation.SEND || op === AgentOperation.CREATE || op === AgentOperation.CURRENT;
      this.aiConsentRevoked(sendClass ? pendingRun : null, sendClass && interactive);
      return AgentSharedError.CONSENT;
    }
    if (r.code === 10001 || r.code === 10004 || r.code === 10005) {
      if (interactive) {
        this.unified(r);
      }
      return AgentSharedError.UNIFIED;
    }
    return AgentSharedError.OTHER;
  }

  /** operation 所属的 Retry-After 闸门（G24）。 */
  private gateOf(op: string): RetryAfterGate {
    if (op === AgentOperation.CURRENT || op === AgentOperation.HISTORY) {
      return this.readGate;
    }
    if (op === AgentOperation.CANCEL || op === AgentOperation.FEEDBACK || op === AgentOperation.REPORT) {
      return this.actionGate;
    }
    return this.deps.gate;
  }

  /**
   * 迟到的结果（旧对话、旧 run、已被新请求取代的 operation；调用方已核对归属仍是同一身份）：只结算同一身份的共享事实——42901 闸门、
   * 10405 强更、AI 10004（R2-01：立即锁住发送闸门，但不弹框）；不弹层、不导航、不改消息（R2-03、R2-04）。
   */
  private settleOnly(r: AgentHttpResult, op: string = AgentOperation.SEND): void {
    if (r.notSent) {
      return;
    }
    if (r.code === 42901) {
      this.gateOf(op).start(AgentSendErrorPolicy.retryAfterMs(r.retryAfter));
      this.publish();
    } else if (r.code === 10405) {
      this.deps.forceUpdate();
    } else if (r.code === 30501) {
      // 同一身份的迟到 30501 同样锁住本次进入（R1-06）。
      this.lockUnavailable();
      this.publish();
    } else if (AgentConsentPolicy.shows(r.code, r.consentType)) {
      this.aiConsentRevoked(null, false);
    }
  }

  /**
   * AI 10004 的同步作废入口（harmony-review-r1 R1-01，S0；brief §0 第 5 条：HTTP 与 SSE 一视同仁）：先同步停掉本控制器的全部在途工作
   * （haltOwnedWork：关流、停计时、cancelOwned 取消历史 / 反馈 / 举报 / 建会话请求、卡片回调与购买作废、在途历史页作废），再锁同意闸门并按规则
   * 决定是否弹框（只锁闸门不够：旧流之后的 delta / done 不得再交付、额度不得更新）。等待重放的那一轮（发送类、可弹框时）不在作废之列。
   */
  private aiConsentRevoked(pendingRun: string | null, interactive: boolean): void {
    this.revokeConsent(pendingRun, interactive, true);
  }

  /**
   * report：harmony-review-r3 R3-01（S0）——本控制器自己收到的 AI 10004 都再交给应用级「AI 同意失效」入口（按不含页面实例的归属键），
   * 同归属重建的控制器因此一开始就是「需要重新同意」、请求准入关闭；App 下发的失效（consentLapsed）不再上报。
   */
  private revokeConsent(pendingRun: string | null, interactive: boolean, report: boolean): void {
    this.haltOwnedWork(new AgentErrorView(AgentController.errorText(10004, ''), null, null, null));
    this.consentLost(pendingRun, interactive);
    if (report) {
      this.reportConsentLapse();
    }
  }

  /**
   * 30501（harmony-review-r1 R1-06）：本次进入「未开放」——同步停掉在途工作、切到未开放态；之后 call() 的准入一律不通过，到下次进入页面
   * （重建控制器）前不再发任何 agent 请求。
   */
  private lockUnavailable(): void {
    if (!this.serverUnavailable) {
      this.serverUnavailable = true;
      this.haltOwnedWork(null);
    }
    this.phase = AgentPhase.UNAVAILABLE;
  }

  /**
   * 同步停掉本控制器归属的全部在途工作（R1-01、R1-06 共用）：关闭所有流、停 30 秒 / 正在停止 / 重载退避计时，进行中的回复本地结束（不更新额度，
   * 之后到达的字节 0 帧交付）；举报半屏关闭；在途历史页与翻页作废；卡片动作世代 +1、购买执行器的在途尝试作废；最后 cancelOwned(本控制器)
   * 同步取消页面归属的历史 / 反馈 / 举报 / 建会话请求（cancel 由应用级持有，不在其中）。
   */
  private haltOwnedWork(activeError: AgentErrorView | null): void {
    for (const t of this.turns) {
      t.client?.cancel();
      t.client = null;
      t.reload = null;
      this.cancelReloadTimer(t);
      this.cancelStopTimer(t);
      if (t.report.sheetOpen && !t.report.inFlight) {
        t.report.close();
      }
    }
    const a: Turn | null = this.active;
    if (a !== null) {
      a.phase = AgentTurnPhase.ENDED;
      a.resend = false;
      if (!a.state.ended) {
        a.state = AgentController.endedAs(a.state, AgentStatus.ERROR);
      }
      a.error = activeError;
      this.active = null;
    }
    this.reportTurn = null;
    this.historySerial++;
    const pager: AgentHistoryPager | null = this.pager;
    if (pager !== null && (pager as AgentHistoryPager).loading) {
      (pager as AgentHistoryPager).failed();
    }
    this.revokeCardActions();
    this.cancelOwnedNow('');
  }

  /** 同步取消页面归属的在途请求（scope 为空 = 本控制器全部；否则只取消该子归属，R1-11）。端口不得抛出。 */
  private cancelOwnedNow(scope: string): void {
    try {
      this.deps.contract?.cancelOwned(scope.length === 0 ? this.identityKey : AgentCall.scoped(this.identityKey, scope));
    } catch (e) {
      // 端口不得抛出。
    }
  }

  /**
   * 收到 AI 10004(ai_third_party)（harmony-review-r2 R2-01，S0）  /**
   * 收到 AI 10004(ai_third_party)（harmony-review-r2 R2-01，S0）：不论来自发送、同意后的重放、新对话、停止还是取会话，都立即撤销发送许可。
   * - interactive（发起时的进入世代、对话与 operation 票据都仍有效）：弹同意框（pendingRun 为待重放的 run；重放过一次的不再给）。
   * - 否则（迟到结果）：只锁闸门、不弹框（refused，回到页面显示说明与【重新同意】，H27）。
   * 提交中（已点【同意并使用】、recordConsent 未回）收到的 10004 来自提交之前发出的请求（闸门非 clear 时不发包）：不改提交中的状态，由记录结果决定。
   * 已在待同意（有弹窗票据）时不重复开框；再次同意成功前，所有发送入口与 AgentCall.sendAllowed 都禁发。
   */
  private consentLost(pendingRun: string | null, interactive: boolean): void {
    if (this.consentGate === AgentConsentGate.SUBMITTING) {
      return;
    }
    if (this.consentGate === AgentConsentGate.AWAITING && this.consent !== null) {
      return;
    }
    if (interactive) {
      this.openConsent(pendingRun);
      return;
    }
    this.consent = null;
    this.consentGate = AgentConsentGate.REFUSED;
    this.consentFailed = false;
    if (this.phase === AgentPhase.IDLE || this.phase === AgentPhase.LOADING || this.phase === AgentPhase.LOAD_FAILED) {
      // 离页时退回 idle 的加载：不再自动重取（闸门已锁，取会话也不会发出），回来显示【重新同意】。
      this.started = true;
      this.phase = AgentPhase.CONSENT_DECLINED;
    }
    this.publish();
  }

  /**
   * 统一分流（R1-05）：10001 → Login、10005 → BindPhone、10004 按 consent_type（labor_agreement → LaborAgreement、id_verification →
   * RealName；privacy / agreement 没有可调用的统一入口，同钱包 H05 只提示 error.10004）——复用 SensitiveOutcome.prereqRoute 同一张表。
   * 只在发起时的进入世代仍有效、页面可见时打开（调用方已核对），in_app、参数为空。
   */
  private unified(r: AgentHttpResult): void {
    const route: string | null = SensitiveOutcome.prereqRoute(r.code, r.data);
    if (route !== null) {
      const empty: Record<string, Object> = {};
      this.deps.open(route, empty, RouteSource.IN_APP);
      return;
    }
    this.deps.toast(AgentController.errorText(r.code, r.traceId));
  }

  // ---------------------------------------------------------------- 可见性（G02，编排者补充第 2 条；更正 APP-10 R1-02 的离页断流）

  /**
   * 同步可见性出口（entry 在切 Tab、被同栈页面覆盖、前后台变化时同步调用）。离开：进入世代 +1——只撤销导航与弹层许可（之后到达的结果不打开前置页、
   * 不弹同意框、不播报、不自动滚动）；进行中的流、30 秒计时、在途的建会话 / 取会话 / 历史请求都保留（03 §7.2 2026-10-14），状态照常落到内存，
   * 但不把快照交给界面；回到可见时一次性应用。页面实例销毁、归属变化、新对话、停止才作废流（dispose / dropConversation / stop）。
   */
  setVisible(visible: boolean): void {
    if (this.disposed || visible === this.visible) {
      return;
    }
    this.visible = visible;
    if (visible) {
      if (this.publishGate.setVisible(true)) {
        this.emitSnapshot();
      }
      return;
    }
    this.entry++;
    this.publishGate.setVisible(false);
  }

  get isVisible(): boolean {
    return this.visible;
  }

  /** 前后台（App 进后台：流照常到 30 秒空闲或系统挂起为止；不发起任何重试，退避中的历史重载停下、只留【重试】）。 */
  setForeground(foreground: boolean): void {
    if (this.disposed || foreground) {
      return;
    }
    for (const t of this.turns) {
      this.pauseReload(t);
    }
  }

  /**
   * 进入后台（R1-08）：暂停这一轮的整个重载流程——退避等待与历史请求在途都算：停计时、同步取消在途的那次历史请求（结果丢弃），本条只留用户可点的
   * 【重试】；回前台不续。
   */
  private pauseReload(t: Turn): void {
    const machine: AgentReconnect | null = t.reload;
    if (machine === null) {
      return;
    }
    const step: AgentReloadStep | null = machine.pause();
    this.cancelReloadTimer(t);
    this.cancelOwnedNow('reload:' + t.run.run);
    if (step !== null) {
      this.applyReloadStep(t, step, null);
    }
  }

  /** App 此刻在前台（读不出按前台）。 */
  private foregroundNow(): boolean {
    try {
      return this.deps.foreground();
    } catch (e) {
      return true;
    }
  }

  /** 发起时的进入世代仍有效且页面可见（导航与弹层的许可）。 */
  private current(entry: number): boolean {
    return entry === this.entry && this.visible;
  }

  /** 加载失败的【重试】（受 42901 闸门控制）。 */
  retryLoad(t: AgentPageTicket): void {
    if (!this.pageOk(t) || this.phase !== AgentPhase.LOAD_FAILED || this.readGate.active) {
      return;
    }
    this.load();
  }

  // ---------------------------------------------------------------- 票据比较

  private pageOk(t: AgentPageTicket): boolean {
    return this.alive() && t.controller === this.serial && t.conversation === this.conversation;
  }

  private runOk(t: AgentRunTicket): boolean {
    const a: Turn | null = this.active;
    return this.alive() && a !== null && AgentTicketPolicy.accept(t.json(), a.run.json());
  }

  private turnOf(controller: number, conversation: number, run: string): Turn | null {
    if (!this.alive() || controller !== this.serial || conversation !== this.conversation) {
      return null;
    }
    for (const t of this.turns) {
      if (t.run.run === run) {
        return t;
      }
    }
    return null;
  }

  /**
   * 实际发包出口的闸门（R1-01；harmony-review-r2 R2-02；APP-10b G02、G24）：创建请求时固定「对话世代 + 本 operation 的票据（op）」，sendAllowed
   * 只比较这些固定值与此刻的控制器、本 operation 所属的 Retry-After 闸门（发送 / 读取 / 动作）、AI 同意闸门；任何一次核对不通过就永久失效
   * （新对话、停止、同意被撤销后都不会恢复），端口之后的重签、重放、延迟发包一律不发。切 Tab 不再撤销发送许可与流许可（G02）。
   */
  private call(op: () => boolean, operation: string = AgentOperation.SEND): AgentCall {
    const conversation: number = this.conversation;
    const gate: RetryAfterGate = this.gateOf(operation);
    let revoked: boolean = false;
    return new AgentCall(this.identityKey, this.identity.level !== AgentIdentity.MEMBER,
      (): boolean => {
        if (revoked) {
          return false;
        }
        let ok: boolean = false;
        try {
          // R1-03 / R1-06 / R1-07：30501 之后、配置关闭、身份变更流程在途时一律不准入。
          ok = this.alive() && conversation === this.conversation && !gate.active && !this.serverUnavailable
            && this.consentGate === AgentConsentGate.CLEAR && this.deps.allowed() && op();
        } catch (e) {
          ok = false;
        }
        if (!ok) {
          revoked = true;
        }
        return ok;
      },
      (): boolean => this.alive());
  }

  // ---------------------------------------------------------------- 发送

  /** 输入框是否可发：就绪、不在发送中、不在禁用期、额度没用完。 */
  get canSend(): boolean {
    return this.alive() && this.visible && this.phase === AgentPhase.READY && this.active === null && !this.serverUnavailable
      && !this.deps.gate.active && !this.quotaExhausted && this.consentGate === AgentConsentGate.CLEAR && !this.readOnly
      && this.allowedNow();
  }

  /** 应用级发包许可此刻是否放行（R1-03、R1-07）。 */
  private allowedNow(): boolean {
    try {
      return this.deps.allowed();
    } catch (e) {
      return false;
    }
  }

  /** 发送一条消息（文本 1–500 字，按 Unicode 码点；超出不让发送）。返回是否已受理。 */
  send(t: AgentPageTicket, rawText: string): boolean {
    if (!this.pageOk(t)) {
      return false;
    }
    const text: string = rawText.trim();
    const n: number = AgentJson.codePoints(text);
    if (n === 0) {
      return false;
    }
    if (n > AgentController.MAX_INPUT) {
      this.deps.toast(AgentDraftTexts.text('agent.draft.too_long'));
      return false;
    }
    if (this.deps.gate.active) {
      // 本地限流拦下时提示一次 42901（APP-09 第 45、56 条）。
      this.deps.toast(DefaultTexts.text('error.42901') ?? '');
      return false;
    }
    if (!this.canSend) {
      return false;
    }
    const clientMsgId: string = ClientMsgId.new();
    const run: AgentRunTicket = this.newRun(clientMsgId);
    const body: AgentJsonObject = {};
    body['client_msg_id'] = clientMsgId;
    body['text'] = text;
    if (this.context !== null) {
      body['context'] = this.context;
      // 情境只附在用户发的第一条上（G27）。
      this.context = null;
    }
    const turn: Turn = new Turn(run, text, JSON.stringify(body));
    turn.sentAtMs = this.deps.clock();
    this.turns.push(turn);
    this.active = turn;
    this.announcement = '';
    this.sessionNotice = '';
    this.publish();
    this.dispatch(turn);
    return true;
  }

  private newRun(clientMsgId: string): AgentRunTicket {
    this.runSeq++;
    return new AgentRunTicket(this.serial, this.conversation, clientMsgId + '#' + String(this.runSeq), clientMsgId);
  }

  /** 发出（必要时先建会话）；每次异步等待结束后复核控制器、对话世代、run 票据（APP-04 第 30、60 条）。 */
  private dispatch(turn: Turn): void {
    const run: AgentRunTicket = turn.run;
    const contract: AgentContractPort = this.deps.contract as AgentContractPort;
    // R1-05：发送结果捕获这一次发出时的进入世代。
    turn.entry = this.entry;
    if (this.consentGate !== AgentConsentGate.CLEAR) {
      // 实际发送出口（R1-01）：同意未记录成功时一律不发；这一轮不留在列表里。
      this.removeTurn(turn);
      this.publish();
      return;
    }
    if (this.sessionId !== null) {
      this.stream(turn, this.sessionId as string);
      return;
    }
    // R2-02：只为这一轮、这一个 run 建会话（停止、新对话、重试换 run 之后都永久失效；切 Tab 不再撤销，G02）。
    const call: AgentCall = this.call((): boolean => this.active === turn && turn.run === run && this.sessionId === null,
      AgentOperation.CREATE);
    // R1-11：这一轮的建会话挂在 run 子归属下，【停止】在同步入口只取消它。
    call.scope = 'run:' + run.run;
    contract.createSession(call).then((r: AgentHttpResult): void => {
      // R2-03：先核对固定身份；旧 run 的结果只结算共享事实（42901、10405、AI 10004），再按票据决定是否改界面。
      if (!this.alive()) {
        return;
      }
      if (!this.runOk(run) || this.active !== turn) {
        this.settleOnly(r, AgentOperation.CREATE);
        return;
      }
      const session: AgentJsonObject | null = AgentJson.objectOf(r.data['session']) ?? (r.ok ? r.data : null);
      const id: string | null = session === null ? null
        : AgentJson.stringOf(session['session_id']) ?? AgentJson.stringOf(session['id']);
      if (!r.ok || id === null) {
        this.jsonFailed(turn, r.ok ? AgentHttpResult.network() : r, AgentOperation.CREATE);
        return;
      }
      this.sessionId = id;
      this.stream(turn, id);
    });
  }

  private stream(turn: Turn, sessionId: string): void {
    const contract: AgentContractPort = this.deps.contract as AgentContractPort;
    const client: StreamClient<AgentRunTicket> = new StreamClient<AgentRunTicket>(contract, this.deps.timer, turn.run,
      (ticket: AgentRunTicket, event: AgentStreamEvent): void => this.onStream(ticket, event));
    client.log = (m: string): void => this.deps.log(m);
    turn.client = client;
    turn.limits = new AgentStreamLimits();
    const run: AgentRunTicket = turn.run;
    // R2-02：许可绑定这一轮、这个 run、这一个流客户端（停止、断线收尾、重试换 run 之后都永久失效）。
    const call: AgentCall = this.call((): boolean => this.active === turn && turn.run === run && turn.client === client,
      AgentOperation.SEND);
    // harmony-review-r2 R2-03：流挂在 stream 子归属下——【停止】同步取消除它以外的全部页面归属工作，流本身由停止流程关闭（meta 前最多等 30 秒）。
    call.scope = 'stream:' + run.run;
    client.start(sessionId, turn.body, call);
  }

  /** 流事件：先比票据（控制器存活、对话世代、run 是当前活动 run），不等即丢弃，什么都不改。切 Tab 期间照常处理、只是不交给界面（G02）。 */
  private onStream(ticket: AgentRunTicket, event: AgentStreamEvent): void {
    if (!this.runOk(ticket)) {
      // R2-03：同一身份的旧 run 迟到的 JSON 错误只结算共享事实（42901、10405、AI 10004），不改界面。
      if (this.alive() && event.kind === AgentStreamEventKind.JSON && event.result !== null) {
        this.settleOnly(event.result as AgentHttpResult);
      }
      // R3-01：旧 run 迟到的流内 error 10004 同样是同一身份的共享事实：只锁闸门、不弹框、不改界面（H27）。
      if (this.alive() && (event.kind === AgentStreamEventKind.FRAME || event.kind === AgentStreamEventKind.GAP_TERMINAL)
        && event.frame !== null && AgentController.consentFrame(new AgentTerminal(event.frame.event, event.frame.data))) {
        this.aiConsentRevoked(null, false);
      }
      return;
    }
    const turn: Turn = this.active as Turn;
    if (event.traceId.length > 0) {
      turn.traceId = event.traceId;
    }
    if (turn.stopFlow !== null && turn.stopFlow.phase === AgentStopPhase.STOPPING) {
      this.onStopping(turn, event);
      return;
    }
    switch (event.kind) {
      case AgentStreamEventKind.PING:
        return;
      case AgentStreamEventKind.FRAME: {
        if (event.frame === null) {
          return;
        }
        this.onFrame(turn, event.frame);
        return;
      }
      case AgentStreamEventKind.SEQ_GAP:
        // G11、G36：缺号——本条本地结束为 incomplete（显示「连接中断」但不给【重试】），连接保持只等终止帧或断线。
        if (turn.resend) {
          turn.resendState = AgentController.endedAs(turn.resendState, AgentStatus.INCOMPLETE);
        } else {
          turn.state = AgentController.endedAs(turn.state, AgentStatus.INCOMPLETE);
        }
        turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'), null, null, null);
        this.publish();
        return;
      case AgentStreamEventKind.GAP_TERMINAL: {
        const t: AgentTerminal = new AgentTerminal(event.frame === null ? '' : event.frame.event,
          event.frame === null ? {} : event.frame.data);
        if (AgentController.consentFrame(t)) {
          // 缺号之后的 error 10004 同样同步锁闸门（R3-01，S0）。
          this.streamConsentLost(turn, t);
          return;
        }
        if (AgentController.unavailableFrame(t)) {
          this.streamUnavailable(turn);
          return;
        }
        this.closeActive(turn);
        this.startReload(turn, AgentReloadTrigger.SEQ_GAP, false);
        return;
      }
      case AgentStreamEventKind.LIMITED:
        this.limitTurn(turn);
        return;
      case AgentStreamEventKind.EOF:
      case AgentStreamEventKind.TIMEOUT:
      case AgentStreamEventKind.ROUND_LIMIT:
        this.disconnected(turn);
        return;
      case AgentStreamEventKind.JSON:
        this.jsonFailed(turn, event.result ?? AgentHttpResult.network(), AgentOperation.SEND);
        return;
      case AgentStreamEventKind.FAILED:
        this.disconnected(turn);
        return;
      default:
        return;
    }
  }

  /** 一帧（已过缺号守卫）：累计上限与重复 card_id（共性第 28、29、33 条）→ Reducer。 */
  private onFrame(turn: Turn, frame: AgentFrame): void {
    if (frame.ok && AgentStreamLimits.isContent(frame.event) && !(turn.resend && !turn.resendState.metaSeen)) {
      const duplicateCard: boolean = frame.event === AgentEvent.CARD && turn.limits.duplicateCard(frame.data);
      if (!turn.limits.admit(frame.event, frame.data)) {
        this.limitTurn(turn);
        return;
      }
      if (duplicateCard) {
        // 同一轮里同 card_id 后到的卡丢弃，保留第一张，只推进序号。
        const before: AgentStreamState = turn.resend ? turn.resendState : turn.state;
        const after: AgentStreamState = AgentController.withCards(StreamReducer.frame(before, frame, this.deps.routes),
          before.cards);
        if (turn.resend) {
          turn.resendState = after;
        } else {
          turn.state = after;
        }
        return;
      }
    }
    if (turn.resend) {
      turn.resendState = StreamReducer.frame(turn.resendState, frame, this.deps.routes);
      if (turn.resendState.metaSeen && !turn.resendState.duplicate) {
        // 服务端按新请求处理（不是 duplicate）：这一次的流就是这条消息。
        turn.resend = false;
        turn.state = turn.resendState;
      } else if (turn.resendState.ended) {
        this.endDuplicate(turn);
        return;
      } else {
        return;
      }
    } else {
      turn.state = StreamReducer.frame(turn.state, frame, this.deps.routes);
    }
    turn.phase = turn.state.metaSeen ? AgentTurnPhase.STREAMING : turn.phase;
    this.afterFrame(turn);
  }

  /** 已收到的内容保留、只换卡片列表（重复 card_id 丢弃后到的）。 */
  private static withCards(state: AgentStreamState, cards: AgentCard[]): AgentStreamState {
    return new AgentStreamState(state.status, state.metaSeen, state.duplicate, state.runId, state.messageId, state.aiLabel,
      state.modelLabel, state.text, state.tools, cards, state.suggestions, state.rawSuggestions, state.terminal,
      state.lastSeq, state.quotaLeft);
  }

  /** 本地超限（G22、共性第 28、33 条）：停止累积、关连接、本轮 limited、不更新额度、不发契约外埋点。 */
  private limitTurn(turn: Turn): void {
    turn.client?.cancel();
    turn.client = null;
    turn.resend = false;
    turn.state = AgentController.endedAs(turn.state, AgentStatus.LIMITED);
    turn.error = null;
    this.deps.log('agent stream limited frames=' + String(turn.limits.contentFrames) + ' cards='
      + String(turn.limits.cards));
    this.closeActive(turn);
  }

  /**
   * 断线（30 秒、单轮总时长、eof、传输失败、无外壳的网关错误页）：本条「连接中断」+【重试】（AgentDisconnected 稿）；不自动重连、不自动重发、
   * 不自动拉历史（03 §7.2）。已缺号的本条：断线之后自动拉一次历史替换（G11）。
   */
  private disconnected(turn: Turn): void {
    const wasIncomplete: boolean = turn.state.status === AgentStatus.INCOMPLETE
      || (turn.resend && turn.resendState.status === AgentStatus.INCOMPLETE);
    turn.client?.cancel();
    turn.client = null;
    if (wasIncomplete) {
      turn.resend = false;
      this.closeActive(turn);
      this.startReload(turn, AgentReloadTrigger.SEQ_GAP, false);
      return;
    }
    if (turn.resend) {
      turn.resend = false;
    }
    turn.state = StreamReducer.disconnected(turn.state);
    if (turn.state.status !== AgentStatus.DISCONNECTED) {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.DISCONNECTED);
    }
    this.finishTurn(turn);
  }

  private afterFrame(turn: Turn): void {
    // page_guide 被客户端拦下：同一卡同一对话只记一次 route_entry_blocked（G10）；基本模式不发。
    for (const c of turn.state.cards) {
      if (c.type === AgentCardType.PAGE_GUIDE && c.kind === AgentCardKind.FALLBACK && c.blockedRoute !== null
        && !turn.blockedReported.has(c.cardId)) {
        turn.blockedReported.add(c.cardId);
        if (!this.identity.basic) {
          this.deps.track(ClientEvents.routeEntryBlocked(AgentController.PAGE_NAME, c.blockedRoute as string,
            EventRouteEntryBlockedEntry.IN_APP));
        }
      }
    }
    if (turn.state.ended) {
      this.finishTurn(turn);
      return;
    }
    this.publish();
  }

  /**
   * duplicate=true 的重发流（G26 → APP-10b 03 §7.2）：不并入、不更新额度。done / 其他 error → 自动拉一次历史替换本条（替换前不显示反馈，G28）；
   * error 30506 → error.30506 +【刷新】（不自动轮询，G40）、发送闸门禁用 5 秒；error 10004 → 同步锁闸门（R3-01）。没有历史接口时照 APP-10 收尾。
   */
  private endDuplicate(turn: Turn): void {
    const dup: AgentStreamState = turn.resendState;
    turn.resend = false;
    if (AgentController.consentFrame(dup.terminal)) {
      // R3-01：duplicate 流的 error 10004 与普通流同一处理（不走普通错误展示）。
      this.streamConsentLost(turn, dup.terminal as AgentTerminal);
      return;
    }
    if (AgentController.unavailableFrame(dup.terminal)) {
      this.streamUnavailable(turn);
      return;
    }
    const action: string = AgentReconnect.duplicateEnd(dup.terminal);
    if (action === AgentReloadAction.REFRESH_BUTTON) {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.ERROR);
      this.inProgress(turn);
      this.closeActive(turn);
      return;
    }
    if (this.canReload()) {
      turn.state = AgentController.endedAs(turn.state, dup.terminal !== null && dup.terminal.event === AgentEvent.DONE ?
        AgentStatus.DONE : AgentStatus.ERROR);
      turn.duplicatePending = true;
      if (dup.messageId !== null) {
        turn.state = AgentController.withMessageId(turn.state, dup.messageId);
      }
      turn.error = null;
      this.closeActive(turn);
      this.startReload(turn, AgentReloadTrigger.DUPLICATE_DONE, false);
      return;
    }
    if (dup.terminal !== null && dup.terminal.event === AgentEvent.DONE) {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.DONE);
      turn.error = null;
    } else {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.ERROR);
      turn.error = dup.terminal === null ? null : this.streamErrorView(turn, dup.terminal.data);
    }
    this.closeActive(turn);
  }

  /** duplicate 30506（上一条还在回复中）：error.30506 +【刷新】，发送闸门禁用 5 秒（G40、APP-10 G24）。 */
  private inProgress(turn: Turn): void {
    this.deps.gate.start(AgentReconnect.RUN_IN_PROGRESS_DISABLE_MS);
    turn.duplicatePending = true;
    turn.error = new AgentErrorView(AgentController.errorText(30506, turn.traceId),
      this.canReload() ? new AgentRetryTap(turn.run, AgentRetryMode.REFRESH) : new AgentRetryTap(turn.run,
        AgentRetryMode.SAME), null, null);
  }

  /** 已收到的内容保留，只把状态收成结束（duplicate 收尾用）。 */
  private static endedAs(state: AgentStreamState, status: string): AgentStreamState {
    return new AgentStreamState(status, state.metaSeen, state.duplicate, state.runId,
      state.messageId, state.aiLabel, state.modelLabel, state.text, state.tools, state.cards, state.suggestions,
      state.rawSuggestions, state.terminal, state.lastSeq, state.quotaLeft);
  }

  private static withMessageId(state: AgentStreamState, messageId: string): AgentStreamState {
    return new AgentStreamState(state.status, state.metaSeen, state.duplicate, state.runId, messageId, state.aiLabel,
      state.modelLabel, state.text, state.tools, state.cards, state.suggestions, state.rawSuggestions, state.terminal,
      state.lastSeq, state.quotaLeft);
  }

  private finishTurn(turn: Turn): void {
    const s: AgentStreamState = turn.state;
    if (AgentController.consentFrame(s.terminal)) {
      // R3-01（S0）：普通流与 duplicate 流（meta.duplicate=true 直接下发）的 error 10004 不按普通错误收尾。
      this.streamConsentLost(turn, s.terminal as AgentTerminal);
      return;
    }
    if (AgentController.unavailableFrame(s.terminal)) {
      this.streamUnavailable(turn);
      return;
    }
    if (s.duplicate && s.terminal !== null && s.terminal.event === AgentEvent.ERROR && s.terminal.code === 30506) {
      // duplicate 流收到 30506（G40）：结束 loading，显示 error.30506 +【刷新】，不自动轮询。
      this.inProgress(turn);
    } else if (s.duplicate && s.terminal !== null && this.canReload()) {
      // duplicate 流的终止帧（done / 其他 error）：自动拉一次历史替换本条（03 §7.2，替代 APP-10 G26 的「不补拉」）。
      turn.duplicatePending = true;
      turn.error = null;
      this.closeActive(turn);
      this.startReload(turn, AgentReloadTrigger.DUPLICATE_DONE, false);
      return;
    } else if (s.duplicate && s.terminal !== null && s.terminal.event === AgentEvent.ERROR && s.terminal.code === 30506) {
      turn.error = new AgentErrorView(AgentController.errorText(30506, turn.traceId),
        new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
    } else if (s.status === AgentStatus.DISCONNECTED) {
      turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'),
        new AgentRetryTap(turn.run, this.canReload() ? AgentRetryMode.RECONNECT : AgentRetryMode.SAME), null, null);
    } else if (s.status === AgentStatus.ERROR && s.terminal !== null && s.terminal.event === AgentEvent.ERROR) {
      turn.error = this.streamErrorView(turn, s.terminal.data);
    } else {
      turn.error = null;
    }
    if (s.updatesQuota && !s.duplicate) {
      this.quotaLeft = s.quotaLeft;
    }
    this.closeActive(turn);
  }

  /** 流内终止帧是 error 且 code=10004（R3-01）。 */
  private static consentFrame(t: AgentTerminal | null): boolean {
    return t !== null && t.event === AgentEvent.ERROR && t.code === 10004;
  }

  /** 流内终止帧是 error 且 code=30501（R1-06）。 */
  private static unavailableFrame(t: AgentTerminal | null): boolean {
    return t !== null && t.event === AgentEvent.ERROR && t.code === 30501;
  }

  /** 流内 30501（普通流、duplicate 流、缺号后的终止帧、正在停止期间）：本轮关连接、不更新额度，本次进入「未开放」（R1-06）。 */
  private streamUnavailable(turn: Turn): void {
    turn.client?.cancel();
    turn.client = null;
    turn.resend = false;
    turn.error = null;
    turn.phase = AgentTurnPhase.ENDED;
    if (this.active === turn) {
      this.active = null;
    }
    this.lockUnavailable();
    this.publish();
  }

  /**
   * 流内 error 帧 code=10004（harmony-review-r3 R3-01，S0；普通流、duplicate 流、重试后的 duplicate 收尾、缺号后的终止帧、正在停止期间同一出口）：
   * 同步执行 consentLost 的禁发部分——停止本对话的所有流与计时、作废卡片回调和购买执行（cardEpoch +1）、对话世代 +1（已发出的 AgentCall.sendAllowed、
   * 停止许可、卡片 / 快捷追问 / 【重试】票据一律失效）、清空同意被撤销后不可展示的对话，再把闸门锁成 refused。
   * 是否弹框按现有规则另判：流契约的 error 帧没有 consent_type（不新增契约字段），AgentConsentPolicy.shows 不成立 → 不弹框，
   * 页面显示「暂不使用」同款说明与【重新同意】（H27）；不弹框也必须禁发。待同意 / 提交中时闸门已非 clear，保持原状态（H28）。
   */
  private streamConsentLost(turn: Turn, t: AgentTerminal): void {
    turn.phase = AgentTurnPhase.ENDED;
    turn.client?.cancel();
    turn.client = null;
    this.dropConversation();
    const consentType: string | null = AgentJson.stringOf(t.data['consent_type']);
    // interactive 只在现有规则允许弹框时成立（流契约下恒为 false）；锁闸门与是否弹框无关。与 HTTP 10004 同一个同步作废入口（R1-01）。
    this.aiConsentRevoked(null, AgentConsentPolicy.shows(10004, consentType) && this.visible);
    if (this.consentGate === AgentConsentGate.CLEAR) {
      this.consentGate = AgentConsentGate.REFUSED;
    }
    this.publish();
  }

  private closeActive(turn: Turn): void {
    turn.phase = AgentTurnPhase.ENDED;
    turn.client?.cancel();
    turn.client = null;
    this.cancelStopTimer(turn);
    if (this.active === turn) {
      this.active = null;
    }
    this.announcement = AgentController.plain(turn.state);
    this.publish();
  }

  private streamErrorView(turn: Turn, data: AgentJsonObject): AgentErrorView {
    const v: AgentStreamErrorView = AgentStreamErrorPolicy.view(data);
    const retry: AgentRetryTap | null = v.retry === 'new_message' ? new AgentRetryTap(turn.run, AgentRetryMode.NEW) : null;
    let search: AgentTap | null = null;
    let label: string = '';
    if (v.searchButton) {
      const params: Record<string, Object> = {};
      if (v.prefillQ !== null) {
        params['q'] = v.prefillQ as string;
        const vars: Map<string, string> = new Map<string, string>();
        vars.set('q', v.prefillQ as string);
        label = AgentDraftTexts.format('agent.draft.search_q', vars);
      } else {
        label = AgentDraftTexts.text('agent.draft.search');
      }
      search = new AgentTap(turn.run, '', AgentTapKind.SEARCH, 'Search', params, RouteSource.IN_APP, label);
    }
    // 流内 error 帧没有 trace_id：5xxxx 用本轮响应头的 X-Trace-Id 追加 trace6（R1-07；都没有就不追加）。
    return new AgentErrorView(AgentController.errorText(v.code, turn.traceId), retry, null, search, label,
      v.searchButton && v.prefillQ !== null ? AgentDraftTexts.text('agent.draft.search_hint') : '');
  }

  /**
   * 发送 / 建会话返回 JSON 错误（G24）；42901、10405、10004、统一分流与其他 operation 共用 sharedError（R1-06）。没有统一外壳（无外壳、外壳成功却不是
   * 流、传输失败，G19、G34）：本条「连接中断」+【重试】（同一 client_msg_id），不当成「新对话」。
   */
  private jsonFailed(turn: Turn, r: AgentHttpResult, op: string): void {
    turn.client?.cancel();
    turn.client = null;
    if (r.code < 0 && !r.notSent) {
      this.disconnected(turn);
      return;
    }
    const d: AgentSendDecision = AgentSendErrorPolicy.decide(r.httpStatus, r.code < 0 ? 50001 : r.code, r.data,
      r.retryAfter, r.traceId, r.consentType);
    const page: AgentPageTicket = new AgentPageTicket(this.serial, this.conversation);
    // R1-05：导航、提示、弹框只在这一次发出时的进入世代仍有效且可见时做；否则只结算共享事实、只改内存。
    const permit: boolean = this.current(turn.entry);
    turn.phase = AgentTurnPhase.FAILED;
    if (r.notSent) {
      // 本地没有发出（准入不通过：同意闸门、限流闸门、归属变化）：这一轮不留（APP-10 H11）。
      this.removeTurn(turn);
      if (this.active === turn) {
        this.active = null;
      }
      this.publish();
      return;
    }
    switch (d.action) {
      case AgentSendAction.UNAVAILABLE:
        this.removeTurn(turn);
        this.lockUnavailable();
        break;
      case AgentSendAction.QUOTA:
        this.quotaExhausted = true;
        turn.error = this.quotaView(turn, AgentJson.stringOf(r.data['next']));
        break;
      case AgentSendAction.NEW_CHAT:
        turn.error = new AgentErrorView(AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId), null, page, null);
        break;
      case AgentSendAction.RUN_IN_PROGRESS:
        this.deps.gate.start(d.disableMs);
        if (permit) {
          this.deps.toast(AgentController.errorText(r.code, r.traceId));
        }
        this.removeTurn(turn);
        break;
      case AgentSendAction.RATE_LIMITED:
        this.sharedError(r, null, op, permit);
        if (permit) {
          this.deps.toast(AgentController.errorText(r.code, r.traceId));
        }
        this.removeTurn(turn);
        break;
      case AgentSendAction.RETRY_SAME_MESSAGE:
        turn.error = new AgentErrorView(AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId),
          new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
        break;
      case AgentSendAction.AGENT_CONSENT:
        if (this.consentGate === AgentConsentGate.SUBMITTING) {
          // 提交中收到的 10004 来自提交前发出的请求：不改提交中的状态；这一条给同键【重试】（记录成功后用户自己点）。
          turn.error = new AgentErrorView(AgentController.errorText(10004, r.traceId),
            new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
          break;
        }
        if (turn.consentReplays >= 1) {
          // 同意后重放只一次；再遇 10004 不再自动重放（按统一错误显示），但必须立即重新锁住闸门并再弹同意框（R2-01，S0：
          // 重放次数只限制自动重放，不跳过同意状态的更新；这一次的弹窗没有待重放消息）。
          turn.error = new AgentErrorView(AgentController.errorText(10004, r.traceId), null, null, null);
          if (this.active === turn) {
            this.active = null;
          }
          // R1-05：隐藏期 / 进入世代已变时只锁闸门（回来显示【重新同意】，不留自动弹框票据，G59）。
          this.aiConsentRevoked(null, permit);
          break;
        }
        turn.phase = AgentTurnPhase.AWAITING_CONSENT;
        if (this.active === turn) {
          this.active = null;
        }
        // 隐藏期间（切 Tab）或进入世代已变时到达的 AI 10004：只锁闸门、不弹框、不保留待重放消息（G02、G59；回来显示【重新同意】）。
        this.sharedError(r, permit ? turn.run.run : null, op, permit);
        if (!permit) {
          this.removeTurn(turn);
          this.publish();
        }
        return;
      case AgentSendAction.FORCE_UPDATE:
        this.sharedError(r, null, op);
        this.removeTurn(turn);
        break;
      case AgentSendAction.TEXT_TOO_LONG:
        if (permit) {
          this.deps.toast(AgentDraftTexts.text('agent.draft.too_long'));
        }
        this.removeTurn(turn);
        break;
      default:
        // 统一分流（10001 / 10005 / 非 AI 的 10004 / 表外码）：发起许可仍有效时交统一入口（打开前置页或提示）；本条显示统一文案（5xxxx 带 trace6）。
        this.sharedError(r, null, op, permit);
        turn.error = new AgentErrorView(AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId), null, null, null);
        break;
    }
    if (this.active === turn) {
      this.active = null;
    }
    this.publish();
  }

  /**
   * 30502 额度用完（AgentQuotaGuest / AgentQuotaPhone，G24、G27）：服务端 data.next 优先（login →【登录】；bind_phone →【绑定手机号】；
   * none → 只给【去搜索】与「明天再来」）；缺失或不认识回落本地身份规则（游客 → 登录；会员未绑手机或未知 → 绑定；已绑 → 只有搜索，H10）。
   * reset_at 不显示（error.30502 已说「明天恢复」）。
   */
  private quotaView(turn: Turn, next: string | null): AgentErrorView {
    const search: AgentTap = new AgentTap(turn.run, '', AgentTapKind.SEARCH, 'Search', {}, RouteSource.IN_APP,
      AgentDraftTexts.text('agent.draft.search'));
    const guest: boolean = this.identity.level !== AgentIdentity.MEMBER;
    let bound: boolean | null = null;
    try {
      bound = guest ? null : this.deps.phoneBound();
    } catch (e) {
      bound = null;
    }
    const identity: string = guest ? 'guest' : (bound === true ? 'member_bound' : 'member_unbound');
    const buttons: string[] = AgentQuotaPolicy.buttons(next, identity);
    let up: AgentTap | null = null;
    let hint: string = AgentDraftTexts.text('agent.draft.quota.member_hint');
    if (buttons.indexOf('Login') >= 0) {
      up = new AgentTap(turn.run, '', AgentTapKind.LOGIN, 'Login', {}, RouteSource.IN_APP,
        AgentDraftTexts.text('agent.draft.login'));
      hint = AgentDraftTexts.text('agent.draft.quota.guest_hint');
    } else if (buttons.indexOf('BindPhone') >= 0) {
      up = new AgentTap(turn.run, '', AgentTapKind.BIND_PHONE, 'BindPhone', {}, RouteSource.IN_APP,
        AgentDraftTexts.text('agent.draft.bind_phone'));
      hint = AgentDraftTexts.text('agent.draft.quota.phone_hint');
    }
    if (next === AgentQuotaNext.NONE) {
      hint = AgentDraftTexts.text('agent.draft.quota.member_hint');
    }
    return new AgentErrorView(AgentController.errorText(30502, ''), null, null, search,
      AgentDraftTexts.text('agent.draft.search'), '', up, hint);
  }

  private removeTurn(turn: Turn): void {
    this.cancelReloadTimer(turn);
    this.cancelStopTimer(turn);
    this.turns = this.turns.filter((x: Turn): boolean => x !== turn);
    if (this.active === turn) {
      this.active = null;
    }
  }

  /** 统一错误文案：error.<code>（5xxxx 由 withTrace6 的同一规则独立追加 trace6，没有 trace_id 不追加）。 */
  static errorText(code: number, traceId: string): string {
    const key: string = 'error.' + String(code);
    const raw: string = DefaultTexts.text(key) ?? DefaultTexts.text('error.50001') ?? '';
    const plain: string = DefaultTexts.fallback(key) ?? raw.split('（{trace6}）').join('').split('{trace6}').join('');
    const t6: string | null = AgentSendErrorPolicy.trace6(traceId);
    if (code < 50000 || code > 59999 || t6 === null || plain.indexOf(t6) >= 0) {
      return plain;
    }
    return plain + '（' + t6 + '）';
  }

  // ---------------------------------------------------------------- 历史重载（AgentReconnect，G07、G35、G38）

  /** 有历史接口与当前会话（APP-10 的测试替身没有历史接口：照 APP-10 直接同键重发）。 */
  private canReload(): boolean {
    return this.deps.conversation !== null && this.sessionId !== null;
  }

  /** 开始一次历史重载（替换本条）。 */
  private startReload(turn: Turn, trigger: string, userRetry: boolean): void {
    if (!this.canReload()) {
      if (trigger === AgentReloadTrigger.SEQ_GAP) {
        turn.state = AgentController.endedAs(turn.state, AgentStatus.DISCONNECTED);
        turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'),
          new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
        this.publish();
      }
      return;
    }
    this.cancelReloadTimer(turn);
    const machine: AgentReconnect = new AgentReconnect(trigger, userRetry, this.deps.random);
    turn.reload = machine;
    turn.reloadEntry = this.entry;
    turn.reloadError = null;
    this.applyReloadStep(turn, machine.begin(this.foregroundNow(), this.consentGate === AgentConsentGate.CLEAR), null);
  }

  private applyReloadStep(turn: Turn, step: AgentReloadStep, match: AgentTurnMatch | null): void {
    const machine: AgentReconnect | null = turn.reload;
    if (machine === null) {
      return;
    }
    if (step.kind === AgentReloadStep.REQUEST) {
      this.requestReload(turn, machine);
      this.publish();
      return;
    }
    if (step.kind === AgentReloadStep.WAIT) {
      turn.reloadTimer = this.deps.timer.schedule(step.delayMs, (): void => {
        turn.reloadTimer = -1;
        if (!this.alive() || turn.reload !== machine || this.turns.indexOf(turn) < 0) {
          return;
        }
        this.applyReloadStep(turn, machine.onTimer(this.foregroundNow()), null);
      });
      return;
    }
    turn.reload = null;
    this.cancelReloadTimer(turn);
    switch (step.action) {
      case AgentReloadAction.REPLACE:
        if (match !== null) {
          this.replaceTurn(turn, match as AgentTurnMatch);
        }
        break;
      case AgentReloadAction.RESEND:
        this.resend(turn);
        return;
      case AgentReloadAction.NEW_CHAT:
        // 历史 30504：会话已失效，本轮结束为「这个对话已结束」+【新对话】，不重发（G07）。
        this.sessionId = null;
        turn.error = new AgentErrorView(AgentController.errorText(30504, ''), null,
          new AgentPageTicket(this.serial, this.conversation), null);
        break;
      case AgentReloadAction.CONSENT:
        if (step.lockAiGate) {
          this.consentLost(null, false);
          // R3-01：同样交给应用级「AI 同意失效」入口（通常 sharedError 已交过，这里兜底）。
          this.reportConsentLapse();
        }
        turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'), null, null, null);
        break;
      case AgentReloadAction.RETRY_ONLY:
      case AgentReloadAction.PAUSED:
        if (step.status.length > 0 && turn.state.status !== AgentStatus.CANCELLED) {
          turn.state = AgentController.endedAs(turn.state, step.status);
        }
        if (this.readOnly) {
          // R1-10：会话已过期只读——不给【重试】，显示 error.30504 与【新对话】。
          turn.error = new AgentErrorView(AgentController.errorText(30504, ''), null,
            new AgentPageTicket(this.serial, this.conversation), null);
        } else if (turn.state.status !== AgentStatus.CANCELLED) {
          turn.error = new AgentErrorView(this.reloadFailureText(turn),
            new AgentRetryTap(turn.run, AgentRetryMode.RECONNECT), null, null);
        }
        break;
      default:
        // KEEP：历史里没有可替换的内容，本条保持（duplicate 仍不显示反馈，G28）。
        break;
    }
    this.publish();
  }

  /** 退避用尽 / 只留【重试】时的说明（R1-13）：最近一次带外壳的 5xxxx 显示统一文案 + trace6；没有外壳的仍是「连接中断」。 */
  private reloadFailureText(turn: Turn): string {
    const e: AgentHttpResult | null = turn.reloadError;
    if (e !== null && (e as AgentHttpResult).code >= 50000 && (e as AgentHttpResult).code <= 59999) {
      return AgentController.errorText((e as AgentHttpResult).code, (e as AgentHttpResult).traceId);
    }
    return AgentDraftTexts.text('agent.draft.disconnected');
  }

  /**
   * 一次历史请求（关掉 ApiClient 的 GET 自动重试，G35；挂在这一轮的 reload 子归属下，进后台时同步取消，R1-08）；结果先比票据（同一对话、
   * 同一会话、这一轮的这一次重载），再复核前后台（后台到达的结果不处理、不重发，R1-08）。成功页：expired 统一只读（R1-10）；对不上时按消息 id
   * 去重追加历史轮（R1-09）。失败保留完整结果（R1-13）：前置路由码（10001 / 10005 / 非 AI 10004）按重载开始时的进入世代与可见性分流、不再退避；
   * 5xxxx 记下供退避用尽时显示统一文案 + trace6。
   */
  private requestReload(turn: Turn, machine: AgentReconnect): void {
    const port: AgentConversationPort = this.deps.conversation as AgentConversationPort;
    const sessionId: string = this.sessionId as string;
    const conversation: number = this.conversation;
    const serial: number = this.historySerial;
    const call: AgentCall = this.call((): boolean => turn.reload === machine && this.foregroundNow(), AgentOperation.HISTORY);
    call.scope = 'reload:' + turn.run.run;
    port.listMessages(sessionId, null, AgentHistory.LIMIT, call, false).then((r: AgentHttpResult): void => {
      if (!this.alive()) {
        return;
      }
      if (conversation !== this.conversation || serial !== this.historySerial || this.sessionId !== sessionId
        || turn.reload !== machine || this.turns.indexOf(turn) < 0) {
        // 迟到的重载（对话已换代、旧会话、旧 run、已暂停）：丢弃，只结算共享事实。
        this.settleOnly(r, AgentOperation.HISTORY);
        return;
      }
      if (!this.foregroundNow()) {
        // R1-08：结果在后台到达——只结算共享事实，整个重载暂停、只留【重试】（不替换、不重发）。
        this.settleOnly(r, AgentOperation.HISTORY);
        this.pauseReload(turn);
        return;
      }
      const permit: boolean = this.current(turn.reloadEntry);
      let outcome: AgentReloadOutcome = new AgentReloadOutcome(AgentReloadOutcome.NETWORK, false, null, -1, null);
      let match: AgentTurnMatch | null = null;
      let expired: boolean = false;
      if (r.ok) {
        const page: AgentHistoryPage | null = AgentHistory.page(r.data, this.deps.routes);
        if (page !== null) {
          const p: AgentHistoryPage = page as AgentHistoryPage;
          // R3-02：传入其他本地轮次已确认的消息归属，排除已属于其他轮次的候选；对不上保留目标轮，走未匹配处理与同 client_msg_id 重发。
          match = AgentHistoryMerge.match(p, this.turnKey(turn), this.knownIds(turn));
          const reply: AgentHistoryItem | null = (match as AgentTurnMatch).reply;
          outcome = new AgentReloadOutcome(AgentReloadOutcome.SUCCESS, (match as AgentTurnMatch).matched,
            reply === null ? null : reply.finishReason, 0, null);
          if (!(match as AgentTurnMatch).usedMetaAsReplyId && turn.state.messageId !== null
            && p.items.some((i: AgentHistoryItem): boolean => i.isUser && i.messageId === turn.state.messageId)) {
            // G03：meta.message_id 在历史里是 user——不当回复 id 用（反馈 / 举报入口不显示，直到历史给出回复 id）。
            turn.replyTrusted = false;
          }
          if (!(match as AgentTurnMatch).matched) {
            // R1-09（编排者补充第 3 条）：对不上——本地保留，按消息 id 去重把历史轮追加在后（只在内存）。
            this.appendHistory(p);
          }
          this.applyExpired(p);
          expired = p.expired;
        }
      } else if (r.code >= 0 && !r.notSent) {
        const kind: string = this.sharedError(r, null, AgentOperation.HISTORY, permit);
        if (turn.reload !== machine) {
          // AI 10004 / 30501 已经同步作废了全部在途工作（含这次重载）。
          if (kind === AgentSharedError.CONSENT) {
            turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'), null, null, null);
          }
          this.publish();
          return;
        }
        if (kind === AgentSharedError.UNIFIED || kind === AgentSharedError.FORCE_UPDATE) {
          // R1-13：前置路由 / 强更不再退避；本条显示统一文案（保留【重试】给用户处理完前置之后再点）。
          turn.reload = null;
          this.cancelReloadTimer(turn);
          if (turn.state.status !== AgentStatus.CANCELLED) {
            turn.error = new AgentErrorView(AgentController.errorText(r.code, r.traceId),
              new AgentRetryTap(turn.run, AgentRetryMode.RECONNECT), null, null);
          }
          this.publish();
          return;
        }
        turn.reloadError = r;
        outcome = new AgentReloadOutcome(AgentReloadOutcome.ENVELOPE, false, null, r.code, r.consentType);
      }
      // 过期会话（R1-10）不重发：按发送闸门关闭处理（只留结论，随后由 RETRY_ONLY 分支显示 error.30504 +【新对话】）。
      this.applyReloadStep(turn, machine.onOutcome(outcome, !this.deps.gate.active && !expired && !this.readOnly,
        this.consentGate === AgentConsentGate.CLEAR), match);
    });
  }

  /** 重载对不上时追加的历史轮（R1-09）：本地没有任何一条 message_id 的整轮，按页内顺序接在当前对话之后。 */
  private appendHistory(page: AgentHistoryPage): void {
    const groups: AgentHistoryGroup[] = AgentHistoryMerge.appendable(page, this.knownIds());
    if (groups.length === 0) {
      return;
    }
    let items: AgentHistoryItem[] = [];
    for (const g of groups) {
      items = items.concat(g.items);
    }
    this.turns = this.turns.concat(this.historyTurns(items));
  }

  /** 本地这一轮的对齐依据（G03、G05）。 */
  private turnKey(turn: Turn): AgentTurnKey {
    const s: AgentStreamState = turn.resend ? turn.resendState : turn.state;
    const replyId: string | null = s.messageId ?? turn.state.messageId;
    return new AgentTurnKey(turn.userText, turn.sentAtMs, turn.replyTrusted ? replyId : null);
  }

  /** 只替换发起重载的那一轮（G06）：卡片动作世代 +1（旧回调失效、在途购买只挡外跳）、新卡按历史版本重新发票据；反馈 / 举报状态清空。 */
  private replaceTurn(turn: Turn, match: AgentTurnMatch): void {
    const group: AgentHistoryGroup = match.group as AgentHistoryGroup;
    const reply: AgentHistoryItem | null = match.reply;
    this.revokeCardActions();
    turn.products.clear();
    turn.revoked = false;
    turn.fromHistory = true;
    turn.duplicatePending = false;
    turn.resend = false;
    turn.userId = group.user === null ? null : (group.user as AgentHistoryItem).messageId;
    turn.error = null;
    turn.phase = AgentTurnPhase.ENDED;
    turn.feedback.reset();
    turn.report.reset();
    if (reply !== null) {
      turn.state = AgentController.historyState(reply as AgentHistoryItem);
      turn.replyTrusted = true;
    }
  }

  /** 历史回复 → 本条状态（G42：只有历史形状，不更新额度；没有 run_id，不给【停止】）。 */
  private static historyState(item: AgentHistoryItem): AgentStreamState {
    return new AgentStreamState(item.status, true, false, null, item.messageId, null, null, item.text, [], item.cards, [], [],
      null, 0, null);
  }

  /** 历史条目 → 轮（进入页面与向上翻页）。 */
  private historyTurns(items: AgentHistoryItem[]): Turn[] {
    const out: Turn[] = [];
    for (const g of AgentHistory.groups(items)) {
      const user: AgentHistoryItem | null = g.user;
      const replies: AgentHistoryItem[] = g.replies.length === 0 ? [] : g.replies;
      const first: AgentHistoryItem | null = replies.length === 0 ? null : replies[0];
      const id: string = user !== null ? (user as AgentHistoryItem).messageId : (first as AgentHistoryItem).messageId;
      const turn: Turn = new Turn(new AgentRunTicket(this.serial, this.conversation, 'history#' + id, 'history' + id),
        user === null ? '' : (user as AgentHistoryItem).text, '');
      turn.fromHistory = true;
      turn.hideUser = user === null;
      turn.userId = user === null ? null : (user as AgentHistoryItem).messageId;
      turn.phase = AgentTurnPhase.ENDED;
      if (first === null) {
        turn.noReply = true;
      } else {
        turn.state = AgentController.historyState(first as AgentHistoryItem);
      }
      out.push(turn);
      for (let i: number = 1; i < replies.length; i++) {
        const extra: Turn = new Turn(new AgentRunTicket(this.serial, this.conversation, 'history#' + replies[i].messageId,
          'history' + replies[i].messageId), '', '');
        extra.fromHistory = true;
        extra.hideUser = true;
        extra.phase = AgentTurnPhase.ENDED;
        extra.state = AgentController.historyState(replies[i]);
        out.push(extra);
      }
    }
    return out;
  }

  private cancelReloadTimer(turn: Turn): void {
    if (turn.reloadTimer !== -1) {
      this.deps.timer.cancel(turn.reloadTimer);
      turn.reloadTimer = -1;
    }
  }

  /** 同一 client_msg_id 重发（G07 resend_same_id；没有历史接口时的断线【重试】，APP-10 照旧）。 */
  private resend(turn: Turn): void {
    if (this.readOnly) {
      // R1-10：过期会话不重发。
      turn.error = new AgentErrorView(AgentController.errorText(30504, ''), null,
        new AgentPageTicket(this.serial, this.conversation), null);
      this.publish();
      return;
    }
    if (this.active !== null || this.consentGate !== AgentConsentGate.CLEAR || this.deps.gate.active
      || !this.foregroundNow() || this.serverUnavailable || !this.allowedNow()) {
      // R1-08：实际发包前复核前后台——后台不重发，只留【重试】。
      turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'),
        new AgentRetryTap(turn.run, this.canReload() ? AgentRetryMode.RECONNECT : AgentRetryMode.SAME), null, null);
      this.publish();
      return;
    }
    const clientMsgId: string = ClientMsgId.forRetry('retry_disconnected', turn.run.clientMsgId);
    turn.run = this.newRun(clientMsgId);
    turn.error = null;
    turn.phase = AgentTurnPhase.CONNECTING;
    turn.stopFlow = null;
    // 已收到的部分内容保留；回来的若是 duplicate 两帧，按 03 §7.2 收尾（拉历史替换），不并入。
    turn.resend = turn.state.metaSeen;
    turn.resendState = StreamReducer.initial();
    if (!turn.resend) {
      turn.state = StreamReducer.initial();
    }
    this.active = turn;
    this.publish();
    this.dispatch(turn);
  }

  // ---------------------------------------------------------------- 停止、新对话、重试

  /**
   * 【停止】（G25、G26）：有 run_id → 同步本地结束为 cancelled、关连接、推进卡片动作世代，cancelAgentRun 恰好 1 次（账本按 run 去重；连点、重放、
   * 重进页面不再发）；没有 run_id（meta 之前）→「正在停止」，内容票据作废，连接保持到 meta 到达（≤30 秒）后关连接并发 1 次 cancel，30 秒没有 meta
   * 或先到了终止帧就只关连接、不发。动作闸门期间不发 cancel，本地照常停止。cancel 不挂页面归属（离页不取消），结果只按停止时的 run 序号结算。
   */
  stop(t: AgentRunTicket): void {
    if (!this.runOk(t)) {
      return;
    }
    const turn: Turn = this.active as Turn;
    if (turn.stopFlow !== null) {
      return;
    }
    const flow: AgentStopFlow = new AgentStopFlow(this.deps.cancelLedger);
    turn.stopFlow = flow;
    // R1-03（brief §0.3）：停止同步作废这一对话已渲染的卡片回调与在途购买尝试；这一轮的卡片照常显示、按钮不再可用。
    this.revokeCardActions();
    turn.revoked = true;
    // harmony-review-r2 R2-03（含 R1-11）：同步取消并作废本控制器归属的历史 / 翻页 / 反馈 / 举报 / 重载 / 建会话工作；只留下这一轮的流（由下面的
    // 停止流程关闭或等 meta ≤30 秒）。应用级 cancel 不挂页面归属，不在其中。
    this.stopOwnedWork(turn);
    const runId: string | null = turn.resend ? (turn.resendState.runId ?? turn.state.runId) : turn.state.runId;
    const effect: AgentStopEffect = flow.stop(runId, !this.actionGate.active);
    if (effect.waitMs > 0 && (turn.client === null || !(turn.client as StreamClient<AgentRunTicket>).active)) {
      // 消息还没发出（建会话在途）：没有连接可等，本地立即结束（没有 run，不发 cancel）。
      this.finishStop(turn, flow.onTerminal());
      return;
    }
    if (effect.waitMs > 0) {
      turn.stopTimer = this.deps.timer.schedule(effect.waitMs, (): void => {
        turn.stopTimer = -1;
        if (!this.alive() || this.active !== turn) {
          return;
        }
        this.finishStop(turn, flow.onWaitExpired());
      });
      this.publish();
      return;
    }
    this.finishStop(turn, effect);
  }

  /**
   * 【停止】的同步作废（harmony-review-r2 R2-03；brief §0.1）：历史与重载的票据序号 +1（迟到的历史页、翻页、重载结果只结算共享事实），其他轮的重载
   * 退避与在途请求停下、只留【重试】；反馈 / 举报的工作世代 +1，在途的那一次回滚并解除（迟到结果不提示、不导航）；在途翻页作废；最后同步
   * cancelOwned 除这一轮的流以外的全部页面归属请求。
   */
  private stopOwnedWork(turn: Turn): void {
    this.historySerial++;
    this.workSerial++;
    for (const t of this.turns) {
      if (t !== turn) {
        this.pauseReload(t);
      }
      t.feedback.abort();
      t.report.abort();
    }
    const pager: AgentHistoryPager | null = this.pager;
    if (pager !== null && (pager as AgentHistoryPager).loading) {
      (pager as AgentHistoryPager).failed();
    }
    try {
      this.deps.contract?.cancelOwned(AgentCall.except(this.identityKey, 'stream:' + turn.run.run));
    } catch (e) {
      // 端口不得抛出。
    }
  }

  /** 正在停止期间的流事件：只等 meta（取 run_id）；终止帧 / 断线 / JSON 结果先到就只关连接。10004 照常锁闸门（S0）。 */
  private onStopping(turn: Turn, event: AgentStreamEvent): void {
    const flow: AgentStopFlow = turn.stopFlow as AgentStopFlow;
    const frame: AgentFrame | null = event.frame;
    if (frame !== null && AgentController.consentFrame(new AgentTerminal(frame.event, frame.data))) {
      this.streamConsentLost(turn, new AgentTerminal(frame.event, frame.data));
      return;
    }
    if (frame !== null && AgentController.unavailableFrame(new AgentTerminal(frame.event, frame.data))) {
      this.finishStop(turn, flow.onTerminal());
      this.lockUnavailable();
      this.publish();
      return;
    }
    if (event.kind === AgentStreamEventKind.FRAME && frame !== null && frame.event === AgentEvent.META) {
      this.finishStop(turn, flow.onMeta(AgentJson.stringOf(frame.data['run_id']), !this.actionGate.active));
      return;
    }
    if (event.kind === AgentStreamEventKind.FRAME && frame !== null && !AgentSeqGuard.isTerminal(frame.event)) {
      // 停止之后的内容帧：内容票据已作废，不交 Reducer、不渲染。
      return;
    }
    if (event.kind === AgentStreamEventKind.PING || event.kind === AgentStreamEventKind.SEQ_GAP) {
      return;
    }
    if (event.kind === AgentStreamEventKind.JSON && event.result !== null) {
      this.settleOnly(event.result as AgentHttpResult);
    }
    this.finishStop(turn, flow.onTerminal());
  }

  private finishStop(turn: Turn, effect: AgentStopEffect): void {
    this.cancelStopTimer(turn);
    turn.client?.cancel();
    turn.client = null;
    turn.state = StreamReducer.localCancel(turn.resend ? turn.state : turn.state);
    if (turn.state.status !== AgentStatus.CANCELLED) {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.CANCELLED);
    }
    turn.resend = false;
    turn.error = null;
    turn.phase = AgentTurnPhase.ENDED;
    if (this.active === turn) {
      this.active = null;
    }
    this.publish();
    if (effect.cancelRunId !== null) {
      this.sendCancel(turn, effect.cancelRunId as string);
    }
  }

  private cancelStopTimer(turn: Turn): void {
    if (turn.stopTimer !== -1) {
      this.deps.timer.cancel(turn.stopTimer);
      turn.stopTimer = -1;
    }
  }

  /** cancel（应用级持有：不登记页面归属、离页不取消；只按原身份准入）。结果只结算共享事实，30505 重载原 run（G25）。 */
  private sendCancel(turn: Turn, runId: string): void {
    const contract: AgentContractPort | null = this.deps.contract;
    if (contract === null) {
      return;
    }
    const conversation: number = this.conversation;
    const entry: number = this.entry;
    const seq: number = this.runSeq;
    const key: string = this.identityKey;
    const gate: RetryAfterGate = this.actionGate;
    // harmony-review-r3 R3-01（S0）：传输结果的归属按不含页面实例的归属键核对——页面实例销毁 / 重建后到达的结果照样结算（不丢弃）；
    // 对话、run、进入世代只约束界面副作用（提示、重载）。
    const same = (): boolean => this.ownerStill();
    const call: AgentCall = new AgentCall(key, this.identity.level !== AgentIdentity.MEMBER,
      (): boolean => same() && !gate.active, same);
    contract.cancelRun(runId, call).then((r: AgentHttpResult): void => {
      const res: AgentCancelResult = AgentCancelPolicy.result(r);
      if (res.forceUpdate) {
        // 强更是应用级事实（与身份无关）。
        this.deps.forceUpdate();
      }
      if (!same()) {
        // G60 / harmony-review-r2 R2-01：不同身份的 cancel 结果整体丢弃——不写闸门（闸门按此刻归属记，会落到新身份上）、不锁同意、不重载、不提示。
        return;
      }
      if (res.gateDelayMs > 0) {
        gate.start(res.gateDelayMs);
        // R2-04：只按停止时的 run 序号提示一次；之后有新对话、新消息、离页，结果只结算闸门、不提示。
        if (this.alive() && this.current(entry) && conversation === this.conversation && seq === this.runSeq
          && this.active === null) {
          this.deps.toast(DefaultTexts.text('error.42901') ?? '');
        }
      }
      if (res.lockAiGate) {
        if (!this.alive()) {
          // R3-01（S0）：本控制器已随页面实例作废，但归属没变——交给应用级「AI 同意失效」入口，由它同步停下同归属此刻的控制器
          // （新流立即停、额度不更新、重建后不准入）；不弹框、不导航、不提示。
          this.reportConsentLapse();
          return;
        }
        // harmony-review-r2 R2-01（S0，G60 裁定）：同一身份的 cancel 迟到返回 AI 10004，同样走统一同步作废入口——之后的新回复立即停下、迟到帧
        // 0 帧交付、额度不更新；cancel 结果的限制照旧：不弹框、不导航、不提示。R3-01：同时交给应用级入口。
        this.aiConsentRevoked(null, false);
        this.publish();
        return;
      }
      if (!this.alive()) {
        return;
      }
      if (r.code === 30501 && !r.notSent) {
        // 编排者 R2-07 向量：cancel 的 30501 同样锁住本次进入（之后不再发 agent 请求）；不导航、不弹框。
        this.lockUnavailable();
        this.publish();
        return;
      }
      if (res.reload && conversation === this.conversation && this.turns.indexOf(turn) >= 0) {
        this.startReload(turn, AgentReloadTrigger.CANCEL_30505, false);
        return;
      }
      if (!r.ok && !r.notSent && !res.reload && res.gateDelayMs === 0) {
        // 网络失败与其他码：只记本机日志（APP-10 H21），不重试、不提示。
        this.deps.log('agent cancel ' + String(r.code));
      }
    });
  }

  /** 卡片动作世代 +1、作废购买执行器的在途尝试（只挡外跳；之后的响应带旧世代，不再更新卡片）。 */
  private revokeCardActions(): void {
    this.cardEpoch++;
    try {
      this.deps.cancelPurchase();
    } catch (e) {
      // 执行器出错不影响作废。
    }
  }

  /**
   * 建会话（新对话）的结果（R1-06）：先核对归属；成功不处理；票据失效（换了对话、之后又发起了 run，R2-03、R2-04）只结算共享事实；
   * 仍有效时本地没发出静默，其余按 sharedError，剩下的码提示统一文案（5xxxx 带 trace6），不直接吞掉。
   */
  private afterOp(r: AgentHttpResult, uiOk: () => boolean, op: string): void {
    if (!this.alive() || r.ok) {
      return;
    }
    if (!uiOk()) {
      this.settleOnly(r, op);
      return;
    }
    const kind: string = this.sharedError(r, null, op);
    if (kind === AgentSharedError.UNAVAILABLE) {
      this.phase = AgentPhase.UNAVAILABLE;
      this.publish();
    } else if (kind === AgentSharedError.OTHER) {
      if (r.code < 0) {
        this.deps.log('agent ' + op + ' failed');
      } else {
        this.deps.toast(AgentController.errorText(r.code, r.traceId));
      }
    } else if (kind === AgentSharedError.RATE_LIMITED) {
      this.publish();
    }
  }

  /** 【新对话】：作废当前对话与所有卡片回调（在途 run 本地结束、不发 cancel），createAgentSession。 */
  newChat(t: AgentPageTicket): void {
    if (!this.pageOk(t)) {
      return;
    }
    this.dropConversation();
    this.quotaExhausted = false;
    this.publish();
    const contract: AgentContractPort | null = this.deps.contract;
    if (contract === null || this.phase !== AgentPhase.READY) {
      return;
    }
    const conversation: number = this.conversation;
    const entry: number = this.entry;
    const seq: number = this.runSeq;
    // R2-02：只为这一次新对话建会话（再点新对话、已有会话后永久失效）。
    const call: AgentCall = this.call((): boolean => this.sessionId === null, AgentOperation.CREATE);
    contract.createSession(call).then((r: AgentHttpResult): void => {
      // R2-03：先核对固定身份，再结算共享事实；对话、之后是否又发起了 run 决定能不能改界面。
      if (!this.alive()) {
        return;
      }
      const own: boolean = conversation === this.conversation && this.sessionId === null;
      if (r.ok) {
        const session: AgentJsonObject | null = AgentJson.objectOf(r.data['session']) ?? r.data;
        if (own && session !== null) {
          this.sessionId = AgentJson.stringOf(session['session_id']) ?? AgentJson.stringOf(session['id']);
        }
        return;
      }
      this.afterOp(r, (): boolean => own && this.current(entry) && seq === this.runSeq && this.active === null,
        AgentOperation.CREATE);
    });
  }

  /** 同步作废当前对话（新对话）：关连接、停计时、清消息与卡片回调；对话世代 +1；在途历史、翻页、反馈、举报结果作废。 */
  private dropConversation(): void {
    for (const turn of this.turns) {
      turn.client?.cancel();
      turn.client = null;
      turn.reload = null;
      this.cancelReloadTimer(turn);
      this.cancelStopTimer(turn);
    }
    // harmony-review-r1 R1-11：同步取消旧对话页面归属的在途历史 / 翻页 / 反馈 / 举报 / 建会话请求，再推进对话世代（应用级 cancel 不在其中）。
    this.cancelOwnedNow('');
    this.active = null;
    this.turns = [];
    this.conversation++;
    this.historySerial++;
    this.sessionId = null;
    this.pager = null;
    this.earlierFailed = false;
    this.readOnly = false;
    this.sessionNotice = '';
    this.reportTurn = null;
    // 同意弹窗与同意闸门不随新对话解除（R1-01：没记录成功就一直禁发；旧对话的待重放消息随对话一起作废）。
    this.revokeCardActions();
    this.announcement = '';
  }

  /**
   * 【重试】：RECONNECT（断线，G07）先拉历史再按决策表；SAME 沿用同一 client_msg_id 直接重发（50401、没有历史接口时）；REFRESH（30506 /「回复中」）
   * 用户点才拉一次历史；NEW 新消息（流内 error）。
   */
  retry(t: AgentRetryTap): void {
    const turn: Turn | null = this.turnOf(t.controller, t.conversation, t.run);
    if (turn === null || this.active !== null || turn.error === null || turn.error.retry === null
      || turn.run.clientMsgId !== t.clientMsgId || this.consentGate !== AgentConsentGate.CLEAR || !this.visible
      || turn.reload !== null || this.serverUnavailable || this.readOnly || !this.allowedNow()) {
      return;
    }
    if (t.mode === AgentRetryMode.RECONNECT || t.mode === AgentRetryMode.REFRESH) {
      if (this.readGate.active) {
        this.deps.toast(DefaultTexts.text('error.42901') ?? '');
        return;
      }
      if (this.canReload()) {
        turn.error = null;
        this.startReload(turn, t.mode === AgentRetryMode.REFRESH ? AgentReloadTrigger.REFRESH :
        AgentReloadTrigger.DISCONNECT, true);
        return;
      }
    }
    if (this.deps.gate.active) {
      this.deps.toast(DefaultTexts.text('error.42901') ?? '');
      return;
    }
    if (t.mode === AgentRetryMode.NEW) {
      this.sendText(turn.userText);
      return;
    }
    this.resend(turn);
  }

  // ---------------------------------------------------------------- 历史翻页（G08）

  /** 滚到顶部（第一条消息进入可见区）：按 next_cursor 取更早一页插在前面；一次只在途一页；读取闸门期间不取。 */
  loadEarlier(t: AgentPageTicket): void {
    const pager: AgentHistoryPager | null = this.pager;
    if (!this.pageOk(t) || pager === null || this.deps.conversation === null || this.sessionId === null
      || this.readGate.active || this.serverUnavailable) {
      return;
    }
    const cursor: string | null = (pager as AgentHistoryPager).top();
    if (cursor === null) {
      return;
    }
    this.earlierFailed = false;
    this.loadErrorText = '';
    this.publish();
    const sessionId: string = this.sessionId as string;
    const conversation: number = this.conversation;
    const serial: number = this.historySerial;
    const entry: number = this.entry;
    (this.deps.conversation as AgentConversationPort).listMessages(sessionId, cursor, AgentHistory.LIMIT,
      this.call((): boolean => this.pager === pager, AgentOperation.HISTORY), true).then((r: AgentHttpResult): void => {
      if (!this.alive()) {
        return;
      }
      if (conversation !== this.conversation || serial !== this.historySerial || this.sessionId !== sessionId
        || this.pager !== pager) {
        this.settleOnly(r, AgentOperation.HISTORY);
        return;
      }
      if (!r.ok && !r.notSent && r.code === 30504) {
        // harmony-review-r2 R2-04（§2.10 历史 30504 分流）：会话已不存在——与进入页面的历史 30504 同一处理（作废旧会话工作、清本地会话与对话）。
        this.sessionGone();
        return;
      }
      const page: AgentHistoryPage | null = r.ok ? AgentHistory.page(r.data, this.deps.routes) : null;
      if (page === null) {
        (pager as AgentHistoryPager).failed();
        this.earlierFailed = true;
        if (!r.ok) {
          // 统一错误分流按发起时的进入世代与可见性（R1-13 同一口径；隐藏期间不导航、不提示）。
          const kind: string = this.sharedError(r, null, AgentOperation.HISTORY, this.current(entry));
          if (kind === AgentSharedError.UNIFIED || kind === AgentSharedError.OTHER || kind === AgentSharedError.RATE_LIMITED
            || kind === AgentSharedError.FORCE_UPDATE) {
            // harmony-review-r2 R2-05：保留完整结果——翻页那一行显示统一文案（5xxxx 带 trace6，来自外壳 trace_id）；只是内存状态，隐藏期间
            // 不交给界面（AgentPublishGate），回来一次性应用。
            this.loadErrorText = AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId);
          }
        }
        this.publish();
        return;
      }
      this.loadErrorText = '';
      const known: Set<string> = this.knownIds();
      const fresh: AgentHistoryItem[] = (page as AgentHistoryPage).items.filter((i: AgentHistoryItem): boolean =>
      !known.has(i.messageId));
      this.turns = this.historyTurns(fresh).concat(this.turns);
      (pager as AgentHistoryPager).arrived((page as AgentHistoryPage).nextCursor);
      // R1-10：翻页拿到 expired=true 同样整段只读。
      this.applyExpired(page as AgentHistoryPage);
      this.publish();
    });
  }

  /**
   * 会话已失效（历史翻页返回 30504，harmony-review-r2 R2-04；§2.10）：同步作废旧会话的全部工作（dropConversation：关流、停计时、cancelOwned、清本地
   * session_id、分页状态与对话，对话世代 +1），显示 error.30504 +【新对话】；下次发送重新建会话（同进入页面时的历史 30504）。
   */
  private sessionGone(): void {
    this.dropConversation();
    this.loadErrorText = '';
    this.sessionNotice = AgentController.errorText(30504, '');
    this.phase = AgentPhase.READY;
    this.publish();
  }

  /** 本对话里已有的消息 id（用户与回复；翻页去重）。 */
  private knownIds(except: Turn | null = null): Set<string> {
    const ids: Set<string> = new Set<string>();
    for (const t of this.turns) {
      if (t === except) {
        // R3-02：目标轮自己的 id 不算「其他轮次的归属」。
        continue;
      }
      if (t.userId !== null) {
        ids.add(t.userId as string);
      }
      if (t.state.messageId !== null) {
        ids.add(t.state.messageId as string);
      }
      if (except !== null && t.resendState.messageId !== null) {
        // R3-02：其他轮同键重发（duplicate 流）拿到的回复 id 同样是它的归属。
        ids.add(t.resendState.messageId as string);
      }
    }
    return ids;
  }

  // ---------------------------------------------------------------- 反馈与举报（G28、G29）

  /** 回复票据 → 这一轮（控制器、对话世代、可信的回复 id 都对得上）。 */
  private replyTurn(t: AgentReplyTicket): Turn | null {
    if (!this.alive() || t.controller !== this.serial || t.conversation !== this.conversation) {
      return null;
    }
    for (const turn of this.turns) {
      if (turn.state.messageId === t.messageId && turn.replyTrusted) {
        return turn;
      }
    }
    return null;
  }

  /** 这一轮能不能显示【赞】【踩】与举报入口。 */
  private replyActions(turn: Turn): boolean {
    return this.deps.conversation !== null && !turn.noReply && turn.phase === AgentTurnPhase.ENDED
      && AgentFeedback.visible('assistant', turn.state.status, turn.state.messageId, turn.replyTrusted, 'assistant',
        turn.duplicatePending);
  }

  /** 【赞】【踩】：乐观更新、在途禁点、同值不发、改选发新值；失败回滚并按统一错误提示（G28、G31）。 */
  feedback(t: AgentReplyTicket, value: string): void {
    const turn: Turn | null = this.replyTurn(t);
    if (turn === null || !this.visible || !this.replyActions(turn) || this.actionGate.active
      || this.consentGate !== AgentConsentGate.CLEAR) {
      return;
    }
    const send: string | null = turn.feedback.tap(value);
    if (send === null) {
      return;
    }
    this.publish();
    const state: AgentFeedbackState = turn.feedback;
    const entry: number = this.entry;
    const work: number = this.workSerial;
    (this.deps.conversation as AgentConversationPort).setFeedback(t.messageId, send as string,
      this.call((): boolean => this.replyTurn(t) === turn && turn.feedback === state && work === this.workSerial,
        AgentOperation.FEEDBACK))
      .then((r: AgentHttpResult): void => {
        if (!this.alive()) {
          return;
        }
        if (this.replyTurn(t) !== turn || work !== this.workSerial) {
          // 迟到（对话换代、归属变化、之后点过【停止】，R2-03）：丢弃，只结算共享事实（不提示、不导航）。
          this.settleOnly(r, AgentOperation.FEEDBACK);
          return;
        }
        const fail: AgentActionFailure | null = state.result(r);
        if (fail !== null) {
          this.actionFailed(fail as AgentActionFailure, r, AgentOperation.FEEDBACK, this.current(entry));
        }
        this.publish();
      });
  }

  /** 反馈 / 举报失败：共享结算（42901 动作闸门、10405、AI 10004 锁闸门不弹框、10001 / 10005 统一前置）+ 可见时提示。 */
  private actionFailed(fail: AgentActionFailure, r: AgentHttpResult, op: string, permit: boolean): void {
    this.sharedError(r, null, op, permit);
    if (permit && fail.message.length > 0 && !fail.decision.lockAiGate && r.code !== 42901 && r.code !== 30501) {
      this.deps.toast(fail.message);
    } else if (permit && r.code === 42901) {
      this.deps.toast(DefaultTexts.text('error.42901') ?? '');
    }
  }

  /** 长按回复 / 读屏「更多操作 → 举报」：打开举报半屏（只开一个实例；已举报的不再提供）。 */
  reportOpen(t: AgentReplyTicket): void {
    const turn: Turn | null = this.replyTurn(t);
    if (turn === null || !this.visible || !this.replyActions(turn) || turn.report.reported) {
      return;
    }
    if (this.reportTurn !== null && this.reportTurn !== turn) {
      (this.reportTurn as Turn).report.close();
    }
    turn.report.open();
    this.reportTurn = turn;
    this.publish();
  }

  /** 选原因 / 改补充说明（只在内存；不进日志）。 */
  reportEdit(t: AgentReplyTicket, reason: string | null, supplement: string): void {
    const turn: Turn | null = this.replyTurn(t);
    if (turn === null || this.reportTurn !== turn || !turn.report.sheetOpen) {
      return;
    }
    turn.report.select(reason);
    turn.report.supplement = supplement;
    this.publish();
  }

  /** 【提交举报】（单飞；未选原因或超长不发）。 */
  reportSubmit(t: AgentReplyTicket): void {
    const turn: Turn | null = this.replyTurn(t);
    if (turn === null || this.reportTurn !== turn || this.consentGate !== AgentConsentGate.CLEAR) {
      return;
    }
    if (this.actionGate.active) {
      this.deps.toast(DefaultTexts.text('error.42901') ?? '');
      return;
    }
    const reason: string | null = turn.report.submit();
    if (reason === null) {
      this.publish();
      return;
    }
    this.publish();
    const state: AgentReportState = turn.report;
    const entry: number = this.entry;
    const work: number = this.workSerial;
    (this.deps.conversation as AgentConversationPort).report(t.messageId, reason as string,
      this.call((): boolean => this.replyTurn(t) === turn && turn.report === state && work === this.workSerial,
        AgentOperation.REPORT))
      .then((r: AgentHttpResult): void => {
        if (!this.alive()) {
          return;
        }
        if (this.replyTurn(t) !== turn || work !== this.workSerial) {
          // 迟到（含之后点过【停止】，R2-03）：丢弃，只结算共享事实。
          this.settleOnly(r, AgentOperation.REPORT);
          return;
        }
        const out: AgentReportOutcome = state.result(r);
        if (out.success) {
          if (this.reportTurn === turn) {
            this.reportTurn = null;
          }
          if (this.current(entry)) {
            this.notice = AgentDraftTexts.text('agent.draft.report.toast');
            this.deps.toast(this.notice);
          }
        } else if (out.failure !== null) {
          if (!state.sheetOpen && this.reportTurn === turn) {
            this.reportTurn = null;
          }
          this.actionFailed(out.failure as AgentActionFailure, r, AgentOperation.REPORT, this.current(entry));
        }
        this.publish();
      });
  }

  /** 系统返回 / 点遮罩 / 关闭：只关本实例（不提交、不导航）。 */
  reportClose(t: AgentReplyTicket): void {
    const turn: Turn | null = this.replyTurn(t);
    if (turn === null || this.reportTurn !== turn) {
      return;
    }
    turn.report.close();
    this.reportTurn = null;
    this.publish();
  }

  // ---------------------------------------------------------------- 归属变化（AgentOwnershipStop，G01）

  /**
   * 应用级协调器在身份事件的同步入口调用：同步作废本控制器（关连接、停计时、作废票据与卡片回调、清空对话；与 dispose 相同），交出在途那一轮的
   * run_id 与「以原身份准入」的 cancel 调用。控制器自己不发 cancel（APP-10 ticket 表照旧）。
   */
  stopForOwnership(_event: string): AgentOwnedRun | null {
    const a: Turn | null = this.active;
    let runId: string | null = null;
    if (a !== null && a.stopFlow === null) {
      runId = a.resend ? (a.resendState.runId ?? a.state.runId) : a.state.runId;
    }
    const key: string = this.identityKey;
    const gate: RetryAfterGate = this.actionGate;
    // R3-01：身份事件 cancel 同样按不含页面实例的归属键核对（页面实例销毁 / 重建不丢结果，由应用级入口结算）。
    const same = (): boolean => this.ownerStill();
    const call: AgentCall = new AgentCall(key, this.identity.level !== AgentIdentity.MEMBER,
      (): boolean => same() && !gate.active, same);
    this.dispose();
    return a === null ? null : new AgentOwnedRun(runId, call, key, this.identity.ownerKey);
  }

  /** 快捷追问 / 示例问题 / 「换一批」：用户点击才发（绑定渲染时的对话世代）。 */
  chip(t: AgentChipTap): void {
    if (!this.pageOk(new AgentPageTicket(t.controller, t.conversation))) {
      return;
    }
    if (t.epoch >= 0 && t.epoch !== this.cardEpoch) {
      // 卡片上的胶囊（notice、「换一批」）：【停止】后旧回调失效（R1-03）。
      return;
    }
    this.sendText(t.sendText);
  }

  private sendText(text: string): void {
    this.send(new AgentPageTicket(this.serial, this.conversation), text);
  }

  // ---------------------------------------------------------------- 卡片动作（只在用户点击时）

  /** 卡片按钮：page_guide 与收益卡按钮以 agent_card 来源、空参数交 Router（EntryGuard 再按 agent_guide 校验）；其余按 in_app。 */
  tap(t: AgentTap): void {
    if (!this.visible) {
      // 离开页面后执行的旧回调不导航（APP-12 第 14 条）。
      return;
    }
    if (t.kind === AgentTapKind.SEARCH || t.kind === AgentTapKind.LOGIN || t.kind === AgentTapKind.BIND_PHONE) {
      if (this.turnOf(t.controller, t.conversation, t.run) === null) {
        return;
      }
      this.deps.open(t.route, t.params, RouteSource.IN_APP);
      return;
    }
    const turn: Turn | null = this.cardTurnOf(t.controller, t.conversation, t.run, t.epoch);
    if (turn === null) {
      return;
    }
    const card: AgentCard | null = AgentController.cardIn(turn, t.cardId);
    if (card === null || !card.known) {
      return;
    }
    switch (t.kind) {
      case AgentTapKind.GUIDE:
      case AgentTapKind.EARNINGS: {
        // brief §0 第 1 条：params 一律为空对象，来源 agent_card。
        const empty: Record<string, Object> = {};
        this.deps.open(t.route, empty, RouteSource.AGENT_CARD);
        return;
      }
      case AgentTapKind.HANDOFF:
        this.deps.customerService();
        return;
      case AgentTapKind.AUTH:
        this.authTap(turn, t);
        return;
      default:
        this.deps.open(t.route, t.params, RouteSource.IN_APP);
        return;
    }
  }

  /**
   * auth_required（G19）：login / bind_phone → Login / BindPhone；union_auth → 若本对话里有 resume_link_id 对应的商品卡，经 OpenPurchaseController
   * 对它发起 open（服务端回 30101 / 30111 时由已有流程拉起授权，授权成功后自动执行一次 open）；没有就只打开 AuthSheet{platform}。
   */
  private authTap(turn: Turn, t: AgentTap): void {
    if (t.route === 'AuthSheet' && t.resumeLinkId !== null) {
      for (const x of this.turns) {
        if (x.revoked) {
          continue;
        }
        for (const c of x.state.cards) {
          for (const p of AgentController.productsOf(x, c)) {
            if (p['link_id'] === t.resumeLinkId) {
              const itemId: string = AgentJson.stringOf(p['card_id']) ?? '';
              this.deps.buy(p, new AgentProductRef(this.serial, this.conversation, x.run.run, c.cardId, itemId,
                this.cardEpoch));
              return;
            }
          }
        }
      }
    }
    this.deps.open(t.route, t.params, RouteSource.IN_APP);
  }

  /** 购买按钮：把渲染时的 link_id 与卡片快照交已有 OpenPurchaseController（BR-PRICE-13、14）。 */
  buy(t: AgentBuyTap): void {
    if (!this.visible) {
      return;
    }
    const turn: Turn | null = this.cardTurnOf(t.controller, t.conversation, t.run, t.epoch);
    if (turn === null || AgentController.cardIn(turn, t.cardId) === null) {
      return;
    }
    this.deps.buy(t.product, new AgentProductRef(t.controller, t.conversation, t.run, t.cardId, t.itemCardId, t.epoch));
  }

  /**
   * 购买结果对卡片的更新（PurchaseEnv.updateCard）：只替换这一张卡（以 card_id 定位、渲染票据比较）；离开 Agent 页后到达的 open 响应只更新卡片，
   * 控制器已作废时什么都不改。
   */
  updateProduct(ref: AgentProductRef, transform: (card: Record<string, Object>) => Record<string, Object>): void {
    const turn: Turn | null = this.cardTurnOf(ref.controller, ref.conversation, ref.run, ref.epoch);
    if (turn === null) {
      return;
    }
    const card: AgentCard | null = AgentController.cardIn(turn, ref.cardId);
    if (card === null) {
      return;
    }
    for (const p of AgentController.productsOf(turn, card)) {
      if (p['card_id'] === ref.itemCardId) {
        const next: Record<string, Object> = transform(p as Record<string, Object>);
        turn.products.set(ref.cardId + '#' + ref.itemCardId, next as AgentJsonObject);
        this.publish();
        return;
      }
    }
  }

  /** 卡片动作与购买：在 turnOf 之上再比卡片动作世代，且这一轮没被【停止】（R1-03）。 */
  private cardTurnOf(controller: number, conversation: number, run: string, epoch: number): Turn | null {
    const turn: Turn | null = this.turnOf(controller, conversation, run);
    if (turn === null || turn.revoked || epoch !== this.cardEpoch) {
      return null;
    }
    return turn;
  }

  private static cardIn(turn: Turn, cardId: string): AgentCard | null {
    for (const c of turn.state.cards) {
      if (c.cardId === cardId) {
        return c;
      }
    }
    return null;
  }

  /** 卡里的商品（购买结果更新过的用新卡）。 */
  private static productsOf(turn: Turn, card: AgentCard): AgentJsonObject[] {
    if (!card.known) {
      return [];
    }
    let raw: AgentJsonValue[] = [];
    if (card.type === AgentCardType.PRODUCT_LIST) {
      raw = AgentJson.arrayOf(card.data['items']) ?? [];
    } else if (card.type === AgentCardType.REBATE_QUOTE) {
      raw = [card.data['product']];
    }
    return raw.map((v: AgentJsonValue): AgentJsonObject => {
      const p: AgentJsonObject = v as AgentJsonObject;
      const id: string = AgentJson.stringOf(p['card_id']) ?? '';
      return turn.products.get(card.cardId + '#' + id) ?? p;
    });
  }

  // ---------------------------------------------------------------- AgentConsent（G16、G17）

  private openConsent(pendingRun: string | null): void {
    this.consentSerial++;
    this.consent = new AgentConsentTicket(this.serial, this.consentSerial, pendingRun);
    // 待同意：从这一刻起禁发（R1-01），直到 recordConsent 成功。
    this.consentGate = AgentConsentGate.AWAITING;
    this.publish();
  }

  /** 当前弹窗票据仍有效（关闭回调只提交自己的票据，APP-11 第 17 条）。 */
  consentValid(t: AgentConsentTicket): boolean {
    const c: AgentConsentTicket | null = this.consent;
    return this.alive() && c !== null && c.controller === t.controller && c.serial === t.serial
      && this.consentGate === AgentConsentGate.AWAITING;
  }

  /**
   * 同意弹窗此刻能不能显示（R1-10）：票据仍是此刻那一张、页面可见、没有阻挡层（隐私弹窗、强更、更新提示、半屏）。真正打开前与打开完成后各核对
   * 一次；不满足时页面同步收起本实例（不提交），条件恢复后按同一张票据再显示。
   */
  consentShowable(t: AgentConsentTicket, blocked: boolean): boolean {
    return this.consentValid(t) && this.visible && !blocked;
  }

  get consentState(): string {
    return this.consentGate;
  }

  /**
   * 【同意并使用】：弹窗票据当场作废、闸门进入提交中（仍禁发）；recordConsent 成功才回到 clear，并用同一 client_msg_id 重放原请求一次。
   * 失败保持禁发（显示失败说明与【重新同意】），待重放的消息丢弃。结果到达时页面已离开：只解除 / 保持闸门，不重放（原消息给同键【重试】）。
   */
  consentAgree(t: AgentConsentTicket): Promise<boolean> {
    if (!this.consentValid(t)) {
      return Promise.resolve(false);
    }
    this.consent = null;
    this.consentGate = AgentConsentGate.SUBMITTING;
    this.submitting = t;
    const entry: number = this.entry;
    this.publish();
    return this.deps.recordConsent(true).then((r: AgentHttpResult): boolean => {
      if (!this.alive() || this.submitting !== t) {
        return false;
      }
      this.submitting = null;
      if (!r.ok) {
        this.consentGate = AgentConsentGate.REFUSED;
        this.consentFailed = true;
        this.dropPending(t.pendingRun);
        this.phase = AgentPhase.CONSENT_DECLINED;
        if (this.current(entry) && !r.notSent) {
          // 保留完整结果走统一分流（同 R2-06）：前置路由（10001 / 10005 / 10004 前置）→ 打开；其余统一文案（5xxxx 带 trace6）。
          const route: string | null = SensitiveOutcome.prereqRoute(r.code, r.data);
          if (route !== null) {
            const empty: Record<string, Object> = {};
            this.deps.open(route, empty, RouteSource.IN_APP);
          } else {
            this.deps.toast(AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId));
          }
        }
        this.publish();
        return false;
      }
      this.consentGate = AgentConsentGate.CLEAR;
      this.consentFailed = false;
      if (this.phase === AgentPhase.CONSENT_DECLINED) {
        this.phase = AgentPhase.READY;
      }
      const turn: Turn | null = t.pendingRun === null ? null : this.turnOf(this.serial, this.conversation, t.pendingRun);
      if (turn !== null && turn.phase === AgentTurnPhase.AWAITING_CONSENT && this.active === null) {
        if (!this.current(entry) || turn.consentReplays >= 1) {
          // 离开后才记录成功：不自动发出，原消息给同键【重试】（用户回来自己点）。
          turn.phase = AgentTurnPhase.FAILED;
          turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'),
            new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
          this.publish();
          return true;
        }
        turn.consentReplays++;
        const clientMsgId: string = ClientMsgId.forRetry('replay_after_consent', turn.run.clientMsgId);
        turn.run = this.newRun(clientMsgId);
        turn.phase = AgentTurnPhase.CONNECTING;
        this.active = turn;
        this.publish();
        this.dispatch(turn);
        return true;
      }
      this.publish();
      return true;
    });
  }

  /** 【暂不使用】：记 accepted=false（channel agent_sheet），留在 Agent 页显示说明与【重新同意】（G17）；闸门保持禁发。 */
  consentDecline(t: AgentConsentTicket): void {
    if (!this.consentValid(t)) {
      return;
    }
    this.consent = null;
    this.consentGate = AgentConsentGate.REFUSED;
    this.consentFailed = false;
    this.dropPending(t.pendingRun);
    this.phase = AgentPhase.CONSENT_DECLINED;
    this.publish();
    this.deps.recordConsent(false).then((r: AgentHttpResult): void => {
      if (!r.ok && this.alive()) {
        this.deps.log('agent consent decline not recorded ' + String(r.code));
      }
    });
  }

  /** 系统返回 / 点遮罩关闭：只关自己这一个弹窗（按暂不使用处理，不记录、不重放）；闸门保持禁发。 */
  consentDismissed(t: AgentConsentTicket): void {
    if (!this.consentValid(t)) {
      return;
    }
    this.consent = null;
    this.consentGate = AgentConsentGate.REFUSED;
    this.consentFailed = false;
    this.dropPending(t.pendingRun);
    this.phase = AgentPhase.CONSENT_DECLINED;
    this.publish();
  }

  /** 【重新同意】：再弹同意框（没有待重放请求）。 */
  consentReopen(t: AgentPageTicket): void {
    if (!this.pageOk(t) || this.phase !== AgentPhase.CONSENT_DECLINED || this.consentGate !== AgentConsentGate.REFUSED) {
      return;
    }
    this.openConsent(null);
  }

  private dropPending(run: string | null): void {
    if (run === null) {
      return;
    }
    this.turns = this.turns.filter((x: Turn): boolean => x.run.run !== run || x.phase !== AgentTurnPhase.AWAITING_CONSENT);
  }

  // ---------------------------------------------------------------- 作废

  /**
   * 同步作废（归属变化、页面销毁）：关闭连接、取消计时、作废全部 run 票据与卡片回调、清空消息与金额、释放订阅；不发 cancel（G06）。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    for (const turn of this.turns) {
      turn.client?.cancel();
      turn.client = null;
      turn.reload = null;
      this.cancelReloadTimer(turn);
      this.cancelStopTimer(turn);
    }
    this.historySerial++;
    this.pager = null;
    this.reportTurn = null;
    this.turns = [];
    this.active = null;
    this.consent = null;
    this.submitting = null;
    this.context = null;
    this.quotaLeft = null;
    try {
      this.deps.contract?.cancelOwned(this.identityKey);
    } catch (e) {
      // 端口不得抛出。
    }
    for (const u of this.unsubscribers) {
      try {
        u();
      } catch (e) {
        // 忽略。
      }
    }
    this.unsubscribers = [];
    this.onChange = (_s: AgentSnapshot) => {
    };
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  // ---------------------------------------------------------------- 快照

  private static plain(state: AgentStreamState): string {
    return AgentText.render(state.text).map((b: AgentTextBlock): string => b.plain).join('\n');
  }

  private static validContext(raw: AgentJsonObject | null): AgentJsonObject | null {
    if (raw === null) {
      return null;
    }
    const keys: string[] = Object.keys(raw);
    if (keys.length !== 1) {
      return null;
    }
    const k: string = keys[0];
    const v: AgentJsonValue | undefined = raw[k];
    if ((k === 'product_key' && AgentJson.str(v, 3, 128)) || (k === 'order_id' && AgentJson.entityId(v))
      || (k === 'text' && AgentJson.str(v, 1, AgentController.CONTEXT_TEXT_MAX))) {
      const o: AgentJsonObject = {};
      o[k] = v as string;
      return o;
    }
    return null;
  }

  /**
   * 情境入口（G27）：in_app 入口交来的 context（{product_key} / {order_id} / {text ≤2000}，三选一，不合就丢弃）附在用户接下来发的第一条消息上；
   * 不自动发送、不清空当前对话。
   */
  attachContext(raw: AgentJsonObject | null): void {
    if (!this.alive()) {
      return;
    }
    this.context = AgentController.validContext(raw);
    this.publish();
  }

  /** 情境提示的文案键（G27）。 */
  private contextLabel(): string | null {
    const c: AgentJsonObject | null = this.context;
    if (c === null) {
      return null;
    }
    if (AgentJson.has(c, 'product_key')) {
      return 'agent.draft.context.product';
    }
    return AgentJson.has(c, 'order_id') ? 'agent.draft.context.order' : 'agent.draft.context.text';
  }

  snapshot(): AgentSnapshot {
    const s: AgentSnapshot = new AgentSnapshot();
    s.owner = this.serial;
    s.conversation = this.conversation;
    s.phase = this.phase;
    s.revision = this.revision;
    s.page = new AgentPageTicket(this.serial, this.conversation);
    if (!this.alive()) {
      return s;
    }
    const masked: boolean = this.deps.masked();
    s.turns = this.turns.map((t: Turn): AgentTurnView => this.turnView(t, masked));
    s.sending = this.active !== null;
    s.stop = this.active === null ? null : (this.active as Turn).run;
    s.limited = this.deps.gate.active;
    s.quotaExhausted = this.quotaExhausted;
    s.quotaLeft = this.quotaLeft;
    s.consent = this.consent;
    s.consentGate = this.consentGate;
    s.consentFailed = this.consentFailed;
    s.examples = this.deps.examples().map((q: string): AgentChipTap => new AgentChipTap(this.serial, this.conversation, q, q));
    const orders: string = AgentDraftTexts.text('agent.draft.chip.orders');
    s.ordersChip = new AgentChipTap(this.serial, this.conversation, orders, orders);
    s.filingText = this.deps.filingText();
    s.contextLabelKey = this.contextLabel();
    s.loadErrorText = this.loadErrorText;
    s.announcement = this.announcement;
    s.readOnly = this.readOnly;
    s.sessionNotice = this.sessionNotice;
    s.readLimited = this.readGate.active;
    s.actionLimited = this.actionGate.active;
    s.notice = this.notice;
    s.reloadable = this.canReload();
    const pager: AgentHistoryPager | null = this.pager;
    if (pager === null || this.deps.conversation === null || this.turns.length === 0) {
      s.earlier = 'hidden';
    } else if ((pager as AgentHistoryPager).loading) {
      s.earlier = 'loading';
    } else if (this.earlierFailed) {
      s.earlier = 'failed';
    } else {
      s.earlier = (pager as AgentHistoryPager).hasEarlier ? 'more' : 'none';
    }
    const a: Turn | null = this.active;
    if (a !== null && a.stopFlow !== null) {
      // 正在停止：不再给【停止】（G26）。
      s.stop = null;
    }
    const rt: Turn | null = this.reportTurn;
    if (rt !== null && (rt as Turn).report.sheetOpen && (rt as Turn).state.messageId !== null) {
      const turn: Turn = rt as Turn;
      const quote: string = AgentController.plain(turn.state);
      s.reportSheet = new AgentReportSheetView(new AgentReplyTicket(this.serial, this.conversation,
        turn.state.messageId as string), AgentController.clip(quote, 60), AgentReport.reasons(), turn.report.selected,
        turn.report.supplement, turn.report.inFlight, turn.report.inlineError,
        AgentReport.supplementLimit(turn.report.selected));
    }
    return s;
  }

  /** 按码点截断（举报摘要，受限渲染之后的纯文字）。 */
  private static clip(text: string, max: number): string {
    const cps: string[] = Array.from(text);
    return cps.length <= max ? text : cps.slice(0, max).join('') + '……';
  }

  private turnView(t: Turn, masked: boolean): AgentTurnView {
    const state: AgentStreamState = t.state;
    const ended: boolean = t.phase === AgentTurnPhase.ENDED;
    const cards: AgentCardView[] = state.cards.map((c: AgentCard): AgentCardView => this.cardView(t, c, masked));
    const chips: AgentChipTap[] = state.suggestions.map((q: AgentQuickReply): AgentChipTap =>
    new AgentChipTap(this.serial, this.conversation, q.text, q.sendText));
    // 每条已结束的 assistant 回复都有 AiLabel（done、error、停止、断线收尾都算，03 §7.2；R1-08）：meta.ai_label，缺则字典 ai_label。
    const label: string | null = ended && state.metaSeen
      ? (state.aiLabel ?? DefaultTexts.text('ai_label') ?? null) : null;
    const view: AgentTurnView = new AgentTurnView(t.run.run, t.run, t.userText, t.phase, state.status,
      AgentText.render(state.text), state.tools, cards, ended ? chips : [], label, t.error, t === this.active);
    view.hideUser = t.hideUser;
    view.fromHistory = t.fromHistory;
    if (t.noReply) {
      return view;
    }
    if (t.stopFlow !== null && t.stopFlow.phase === AgentStopPhase.STOPPING) {
      view.statusText = AgentDraftTexts.text('agent.draft.stopping');
    } else if (state.status === AgentStatus.CANCELLED && state.text.length === 0 && state.cards.length === 0) {
      view.statusText = AgentDraftTexts.text('agent.draft.stopped');
    } else if (state.status === AgentStatus.LIMITED) {
      view.statusText = AgentDraftTexts.text('agent.draft.limited');
    }
    if (t.fromHistory && state.status === AgentStatus.ERROR && t.error === null) {
      // 历史 error：通用出错条目（历史没有错误码，不带 trace6、不给重试，G42）。
      view.genericError = AgentController.errorText(50001, '');
    }
    if (this.replyActions(t)) {
      const ticket: AgentReplyTicket = new AgentReplyTicket(this.serial, this.conversation, state.messageId as string);
      view.feedback = new AgentFeedbackView(ticket, t.feedback.selected, t.feedback.enabled && !this.actionGate.active,
        AgentFeedback.a11y(t.feedback.selected));
      view.report = new AgentReportEntryView(ticket, t.report.reported);
    }
    return view;
  }

  private cardView(t: Turn, c: AgentCard, masked: boolean): AgentCardView {
    const run: AgentRunTicket = t.run;
    // 【停止】过的这一轮（R1-03）：卡片照常显示，不再给任何按钮票据。
    const inert: boolean = t.revoked;
    let products: AgentProductView[] = [];
    let guide: AgentTap | null = null;
    let guideText: string = '';
    let earnings: EarningsView | null = null;
    let earningsTaps: AgentTap[] = [];
    let rule: AgentTap | null = null;
    let order: AgentTap | null = null;
    let auth: AgentTap | null = null;
    let handoff: AgentTap | null = null;
    let chips: AgentChipTap[] = [];
    let layout: string = 'list';
    if (c.known) {
      const d: AgentJsonObject = c.data;
      switch (c.type) {
        case AgentCardType.PRODUCT_LIST:
        case AgentCardType.REBATE_QUOTE:
          layout = c.type === AgentCardType.PRODUCT_LIST ? (AgentJson.stringOf(d['layout']) ?? 'list') : 'single';
          products = AgentController.productsOf(t, c).map((p: AgentJsonObject): AgentProductView =>
          this.productView(run, c.cardId, p, inert));
          break;
        case AgentCardType.PAGE_GUIDE: {
          const route: string = d['route'] as string;
          const key: string = d['text_key'] as string;
          guideText = AgentDraftTexts.has(key) ? AgentDraftTexts.text(key) : c.fallbackText;
          const open: string = AgentDraftTexts.text('agent.guide.open');
          guide = new AgentTap(run, c.cardId, AgentTapKind.GUIDE, route, {}, RouteSource.AGENT_CARD,
            open + '，' + AgentController.routeLabel(route), null, open);
          break;
        }
        case AgentCardType.EARNINGS_SUMMARY: {
          earnings = EarningsCardView.view(c, masked, this.deps.clock(), this.deps.money);
          earningsTaps = earnings.buttons.map((b: EarningsButton): AgentTap =>
          new AgentTap(run, c.cardId, AgentTapKind.EARNINGS, b.route, {}, RouteSource.AGENT_CARD,
            AgentDraftTexts.text(b.textKey)));
          break;
        }
        case AgentCardType.RULE_REF: {
          const action: AgentJsonObject = d['action'] as AgentJsonObject;
          const params: Record<string, Object> = (AgentJson.objectOf(action['params']) ?? {}) as Record<string, Object>;
          rule = new AgentTap(run, c.cardId, AgentTapKind.RULE, action['route'] as string, params, RouteSource.IN_APP,
            AgentDraftTexts.text('agent.draft.rule.view'));
          break;
        }
        case AgentCardType.ORDER_STATUS: {
          const params: Record<string, Object> = {};
          params['order_id'] = d['order_id'] as string;
          order = new AgentTap(run, c.cardId, AgentTapKind.ORDER, 'OrderDetail', params, RouteSource.IN_APP,
            AgentDraftTexts.text('agent.draft.order.title'));
          break;
        }
        case AgentCardType.AUTH_REQUIRED: {
          const reason: string = d['reason'] as string;
          const params: Record<string, Object> = {};
          let route: string = 'Login';
          let label: string = AgentDraftTexts.text('agent.draft.login');
          if (reason === 'bind_phone') {
            route = 'BindPhone';
            label = AgentDraftTexts.text('agent.draft.bind_phone');
          } else if (reason === 'union_auth') {
            route = 'AuthSheet';
            params['platform'] = d['platform'] as string;
            label = AgentDraftTexts.text('agent.draft.auth.go');
          }
          auth = new AgentTap(run, c.cardId, AgentTapKind.AUTH, route, params, RouteSource.IN_APP, label,
            AgentJson.stringOf(d['resume_link_id']));
          break;
        }
        case AgentCardType.HANDOFF:
          handoff = new AgentTap(run, c.cardId, AgentTapKind.HANDOFF, '', {}, RouteSource.IN_APP,
            AgentDraftTexts.text('agent.draft.handoff.open'));
          break;
        case AgentCardType.NOTICE: {
          const actions: AgentJsonValue[] = AgentJson.arrayOf(d['actions']) ?? [];
          chips = inert ? [] : actions.map((v: AgentJsonValue): AgentChipTap => {
            const o: AgentJsonObject = v as AgentJsonObject;
            const chip: AgentChipTap = new AgentChipTap(this.serial, this.conversation, o['text'] as string,
              o['send_text'] as string);
            chip.epoch = this.cardEpoch;
            return chip;
          });
          break;
        }
        default:
          break;
      }
    }
    const tap: (x: AgentTap | null) => AgentTap | null = (x: AgentTap | null): AgentTap | null => {
      if (x === null || inert) {
        return null;
      }
      x.epoch = this.cardEpoch;
      return x;
    };
    const taps: AgentTap[] = inert ? [] : earningsTaps.map((x: AgentTap): AgentTap => {
      x.epoch = this.cardEpoch;
      return x;
    });
    const view: AgentCardView = new AgentCardView(c, layout, products, guideText, tap(guide), earnings, taps, tap(rule),
      tap(order), tap(auth), tap(handoff), chips);
    if (!c.known) {
      view.fallbackPlain = AgentText.render(c.fallbackText).map((b: AgentTextBlock): string => b.plain).join('\n');
    }
    if (c.known) {
      this.cardTexts(view, c.data, masked);
    }
    return view;
  }

  /** 各类卡的展示文字（订单状态、找回草稿、规则、客服、授权、提示、素材行）。 */
  private cardTexts(v: AgentCardView, d: AgentJsonObject, masked: boolean): void {
    switch (v.card.type) {
      case AgentCardType.ORDER_STATUS: {
        v.title = d['is_other_product'] === true ? '' : (AgentJson.stringOf(d['title']) ?? '');
        // 复用订单展示规则（R1-14）：未知状态按 UNKNOWN；卡片契约没有扣回金额，带 {z} 的状态用 .label_plain（与订单页 z 为 null 同一写法）。
        const labelKey: string = OrderStatusText.of(d['display_status'] as string)['labelKey'] as string;
        const plain: string = OrderDraftTexts.text(labelKey + '_plain');
        const label: string = plain.length > 0 ? plain : OrderDraftTexts.text(labelKey);
        v.lines = [this.deps.platformName(d['platform'] as string), label];
        const reason: string | null = AgentJson.stringOf(d['reason']);
        if (reason !== null) {
          const r: string = OrderDraftTexts.text('order_reason.' + reason + '.title');
          if (r.length > 0) {
            v.lines.push(r);
          }
        }
        // 订单的预计结算月份用订单自己的文案（order_status.WAITING.hint「预计 {credit_period}结算」，BR-TEXT-04），与收益卡的「最早预计」分开（R1-15）。
        const credit: Record<string, Object | null> = CreditPeriodText.of(d['display_status'] as string,
          AgentJson.stringOf(d['expected_credit_period']), this.deps.clock()) as Record<string, Object | null>;
        const creditKey: Object | null = credit['textKey'] ?? null;
        const creditMonth: Object | null = credit['monthText'] ?? null;
        if (typeof creditKey === 'string' && typeof creditMonth === 'string') {
          const text: string = OrderDraftTexts.text(creditKey as string).split('{credit_period}').join(creditMonth as string);
          if (text.length > 0) {
            v.lines.push(text);
          }
        }
        const fen: number | null = AgentJson.intOf(d['est_rebate_fen']);
        v.amountLabel = OrderDraftTexts.text('order_amount.est_rebate');
        v.amountText = fen === null ? null : (masked ? AgentDraftTexts.MASK : this.deps.money(fen));
        return;
      }
      case AgentCardType.CLAIM_DRAFT: {
        v.title = AgentDraftTexts.text('agent.draft.claim.title');
        v.lines = [this.deps.platformName(d['platform'] as string),
          AgentDraftTexts.text('agent.draft.claim.order_no') + ' ' + (d['order_no'] as string)];
        const times: AgentJsonValue[] = AgentJson.arrayOf(d['click_times']) ?? [];
        for (const t of times) {
          const iso: string = t as string;
          v.lines.push(AgentDraftTexts.text('agent.draft.claim.click_time') + ' ' + iso.substring(0, 10) + ' '
            + iso.substring(11, 16));
        }
        return;
      }
      case AgentCardType.RULE_REF:
        v.title = d['title'] as string;
        v.lines = [d['excerpt'] as string];
        return;
      case AgentCardType.HANDOFF:
        v.lines = [d['summary'] as string];
        return;
      case AgentCardType.AUTH_REQUIRED: {
        const reason: string = d['reason'] as string;
        if (reason === 'union_auth') {
          const vars: Map<string, string> = new Map<string, string>();
          vars.set('platform_name', this.deps.platformName(d['platform'] as string));
          v.lines = [AgentDraftTexts.format('agent.draft.auth.union', vars)];
        } else {
          v.lines = [AgentDraftTexts.text(reason === 'bind_phone' ? 'agent.need_phone' : 'agent.need_login')];
        }
        return;
      }
      case AgentCardType.NOTICE: {
        const key: string = d['text_key'] as string;
        const text: string = DefaultTexts.text(key) ?? '';
        v.lines = [text.length > 0 ? text : v.card.fallbackText];
        return;
      }
      case AgentCardType.REBATE_QUOTE: {
        // 素材行（G22）：没有 BR-PRICE-10 的已有组件，只显示 title_hint 与 conditions 原样，不显示 claimed_* 金额与口令。
        const m: AgentJsonObject | null = AgentJson.objectOf(d['material']);
        if (m !== null) {
          v.title = AgentDraftTexts.text('agent.draft.material.title');
          const parts: string[] = [];
          const hint: string | null = AgentJson.stringOf(m['title_hint']);
          if (hint !== null) {
            parts.push(hint);
          }
          for (const cnd of AgentJson.arrayOf(m['conditions']) ?? []) {
            parts.push(cnd as string);
          }
          v.lines = parts.length > 0 ? [parts.join(' · ')] : [];
        }
        return;
      }
      default:
        return;
    }
  }

  /** 读屏完整名称里的目标页（「去看看，提现记录」）：路由对应的页面名草稿（代拟，与页面标题一致）。 */
  private static routeLabel(route: string): string {
    const name: string = AgentDraftTexts.text('agent.draft.route.' + route);
    return name.length > 0 ? name : route;
  }

  private productView(run: AgentRunTicket, cardId: string, p: AgentJsonObject, inert: boolean): AgentProductView {
    const itemId: string = AgentJson.stringOf(p['card_id']) ?? '';
    const params: Record<string, Object> = {};
    const platform: string | null = AgentJson.stringOf(p['platform']);
    const key: string | null = AgentJson.stringOf(p['product_key']);
    let detail: AgentTap | null = null;
    if (platform !== null && key !== null) {
      params['platform'] = platform;
      params['product_key'] = key;
      const ref: string | null = AgentJson.stringOf(p['item_ref']);
      if (ref !== null) {
        params['item_ref'] = ref;
      }
      detail = new AgentTap(run, cardId, AgentTapKind.PRODUCT, 'ProductDetail', params, RouteSource.IN_APP,
        AgentJson.stringOf(p['title']) ?? '');
      detail.epoch = this.cardEpoch;
    }
    if (inert) {
      return new AgentProductView(p, null, null, null, AgentJson.stringOf(p['availability']) === 'coupon_gone');
    }
    const linkId: string | null = AgentJson.stringOf(p['link_id']);
    const availability: string = AgentJson.stringOf(p['availability']) ?? 'ok';
    const buy: AgentBuyTap | null = linkId === null ? null
      : new AgentBuyTap(run, cardId, itemId, linkId, AgentJson.copy(p), this.cardEpoch);
    const gone: boolean = availability === 'off_shelf' || availability === 'coupon_gone';
    const refreshText: string = AgentDraftTexts.text('agent.draft.refresh_batch');
    let refresh: AgentChipTap | null = null;
    if (gone) {
      refresh = new AgentChipTap(this.serial, this.conversation, refreshText, refreshText);
      refresh.epoch = this.cardEpoch;
    }
    return new AgentProductView(p, detail, buy, refresh, availability === 'coupon_gone');
  }

  private publish(): void {
    if (!this.alive()) {
      return;
    }
    if (this.serverUnavailable) {
      // R1-06：本次进入收到过 30501，「未开放」不被之后的任何结果改回。
      this.phase = AgentPhase.UNAVAILABLE;
    }
    if (this.consentGate === AgentConsentGate.REFUSED && this.phase === AgentPhase.READY && this.active === null) {
      // 迟到的 AI 10004 只锁了闸门（R2-01）：没有在途回复时显示说明与【重新同意】（不弹框）。
      this.phase = AgentPhase.CONSENT_DECLINED;
    }
    this.revision++;
    if (!this.publishGate.offer()) {
      // 切 Tab / 被覆盖（G02）：状态照常落到内存，不交给界面；回到可见时一次性应用。
      return;
    }
    this.emitSnapshot();
  }

  private emitSnapshot(): void {
    try {
      this.onChange(this.snapshot());
    } catch (e) {
      // 页面出错不影响控制器。
    }
  }

  /** 金额隐藏偏好或闸门变化时的重绘入口（entry 也可直接调）。 */
  refresh(): void {
    this.publish();
  }

  /** 收益卡是否有实时金额正在显示（测试用：金额只在内存，不落盘）。 */
  get liveEarningsShown(): boolean {
    for (const t of this.turns) {
      for (const c of t.state.cards) {
        if (c.type === AgentCardType.EARNINGS_SUMMARY && c.known && c.shape === EarningsShape.LIVE) {
          return true;
        }
      }
    }
    return false;
  }
}
