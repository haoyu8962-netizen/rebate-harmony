// APP-10 §2 第 9 条：AgentController（页面状态机，界面无关）。页面在 features/agent，组合在 entry/agent（AppAgent）。
// 身份构造时一次取得、之后只比较（brief §0 第 3 条，APP-09 第 63、65 条）：控制器构造时固定「环境 + 隐私 / 会话世代（网络层归属键）+
// 账号作用域 + AI 同意世代 + 页面实例」（AgentIdentity）；会话（session_id）、对话世代（【新对话】+1）、run 票据（client_msg_id + 本地
// run 序号）都在它之下派生。请求、连接、计时器、卡片回调、购买、同意弹窗、停止只用这一份；读「当前身份」只用于比较。
// 流的每一帧在发起时就绑定 run 票据：控制器先比票据（控制器存活、对话世代、run 是当前活动 run），不等即丢弃——不改消息、不改额度、
// 不写卡片、不发埋点、不滚动、不弹任何层。归属变化由 entry 在同步出口作废整个控制器并按新身份重建（不发 cancel，G06）。
// 消息、卡片、收益金额、client_msg_id、输入草稿都只在内存（G15），不写任何本机存储，不进日志与埋点。
import { ClientEvent, ClientEvents, DefaultTexts, EventRouteEntryBlockedEntry, RouteSpec, Routes } from 'generated';
import { RetryAfterGate } from '../network/RetryAfterGate';
import { CreditPeriodText, OrderStatusText } from '../orders/OrderPresentation';
import { SensitiveOutcome } from '../wallet/WalletPresentation';
import { OrderDraftTexts } from '../orders/OrderDraftTexts';
import { RouteSource } from '../router/RouteRequest';
import { AgentJson, AgentJsonObject, AgentJsonValue } from './AgentJson';
import { AgentCard, AgentCardKind, AgentCardType, AgentEvent, EarningsShape } from './AgentDecoder';
import { AgentDraftTexts } from './AgentDraftTexts';
import {
  AgentAmount, AgentConsentPolicy, AgentSendAction, AgentSendDecision, AgentSendErrorPolicy, AgentStreamErrorPolicy,
  AgentStreamErrorView, AgentTicketAction, AgentTicketEvent, AgentTicketPolicy, ClientMsgId, EarningsButton,
  EarningsCardView, EarningsView
} from './AgentPolicies';
import { AgentText, AgentTextBlock } from './AgentText';
import { AgentQuickReply, AgentStatus, AgentStreamState, AgentTerminal, AgentTool, StreamReducer } from './StreamReducer';
import {
  AgentCall, AgentContractPort, AgentHttpResult, AgentStreamEvent, AgentStreamEventKind, AgentTimer, StreamClient,
  SystemAgentTimer
} from './StreamClient';

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
  /** 沿用同一 client_msg_id（50401、断线、duplicate 30506）。 */
  static readonly SAME: string = 'same';
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
  loadErrorText: string = '';
  /** 数据变化的版本号（自动滚动与读屏播报用）。 */
  revision: number = 0;
  /** 最近一条可播报的新文字（读屏开启时用无障碍播报；不含金额）。 */
  announcement: string = '';
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

  constructor(run: AgentRunTicket, userText: string, body: string) {
    this.run = run;
    this.userText = userText;
    this.body = body;
  }
}

export class AgentController {
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
  onChange: (s: AgentSnapshot) => void = (_s: AgentSnapshot) => {
  };

  constructor(deps: AgentDeps) {
    AgentController.serials++;
    this.serial = AgentController.serials;
    this.deps = deps;
    // 构造时一次性固定身份（之后只比较）。
    this.identity = deps.identity;
    this.identityKey = deps.identity.key;
    this.context = AgentController.validContext(deps.context);
    this.unsubscribers.push(deps.gate.subscribe((): void => this.publish()));
    this.unsubscribers.push(deps.subscribeMask((_hidden: boolean): void => this.publish()));
    if (deps.contract === null) {
      this.phase = AgentPhase.UNAVAILABLE;
    } else if (deps.identity.basic) {
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
    this.load();
  }

  private load(): void {
    const contract: AgentContractPort = this.deps.contract as AgentContractPort;
    this.phase = AgentPhase.LOADING;
    this.loadErrorText = '';
    this.publish();
    const conversation: number = this.conversation;
    const entry: number = this.entry;
    // R2-02：这次取会话只在仍处于本次加载时发出（离页退回 idle、回来重取的是新请求）。
    contract.currentSession(this.call((): boolean => this.phase === AgentPhase.LOADING)).then((r: AgentHttpResult): void => {
      // 先核对归属，再核对进入世代与可见性（R1-02）：离开后到达的结果只结算闸门与强更，不改界面（离开时已退回 idle，回来重取）。
      if (!this.alive()) {
        return;
      }
      if (!this.current(entry) || conversation !== this.conversation) {
        this.settleOnly(r);
        return;
      }
      if (r.ok) {
        // 「成功但为空」（session=null）与「加载失败」分开（APP-11 第 6 条）：空会话等第一次发送时再建。
        const session: AgentJsonObject | null = AgentJson.objectOf(r.data['session']);
        this.sessionId = session === null ? null : AgentJson.stringOf(session['id']) ?? AgentJson.stringOf(session['session_id']);
        this.phase = AgentPhase.READY;
        this.publish();
        return;
      }
      this.loadFailed(r);
    });
  }

  private loadFailed(r: AgentHttpResult): void {
    const kind: string = this.sharedError(r, null);
    if (kind === AgentSharedError.UNAVAILABLE) {
      this.phase = AgentPhase.UNAVAILABLE;
    } else if (kind === AgentSharedError.CONSENT) {
      this.phase = AgentPhase.READY;
    } else {
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
  private sharedError(r: AgentHttpResult, pendingRun: string | null): string {
    if (r.notSent) {
      return AgentSharedError.SILENT;
    }
    switch (r.code) {
      case 42901:
        this.deps.gate.start(AgentSendErrorPolicy.retryAfterMs(r.retryAfter));
        return AgentSharedError.RATE_LIMITED;
      case 10405:
        this.deps.forceUpdate();
        return AgentSharedError.FORCE_UPDATE;
      case 30501:
        return AgentSharedError.UNAVAILABLE;
      case 30505:
        return AgentSharedError.SILENT;
      default:
        break;
    }
    if (AgentConsentPolicy.shows(r.code, r.consentType)) {
      this.consentLost(pendingRun, true);
      return AgentSharedError.CONSENT;
    }
    if (r.code === 10001 || r.code === 10004 || r.code === 10005) {
      this.unified(r);
      return AgentSharedError.UNIFIED;
    }
    return AgentSharedError.OTHER;
  }

  /**
   * 迟到的结果（离页后、旧对话、旧 run、已被新请求取代的 operation；调用方已核对归属仍是同一身份）：只结算同一身份的共享事实——42901 闸门、
   * 10405 强更、AI 10004（R2-01：立即锁住发送闸门，但不弹框）；不弹层、不导航、不改消息（R2-03、R2-04）。
   */
  private settleOnly(r: AgentHttpResult): void {
    if (r.notSent) {
      return;
    }
    if (r.code === 42901) {
      this.deps.gate.start(AgentSendErrorPolicy.retryAfterMs(r.retryAfter));
      this.publish();
    } else if (r.code === 10405) {
      this.deps.forceUpdate();
    } else if (AgentConsentPolicy.shows(r.code, r.consentType)) {
      this.consentLost(null, false);
    }
  }

  /**
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

  // ---------------------------------------------------------------- 可见性（R1-02）

  /**
   * 同步可见性出口（entry 在切 Tab、被覆盖、前后台变化时同步调用）。离开：进入世代 +1，关闭当前连接、取消计时（本条消息记为连接中断、给同键
   * 【重试】），加载中退回 idle（回来重取）；之后到达的建会话、取会话、停止、同意结果只结算、不改界面。草稿与滚动位置由页面在内存里保留。
   */
  setVisible(visible: boolean): void {
    if (this.disposed || visible === this.visible) {
      return;
    }
    this.visible = visible;
    if (visible) {
      this.publish();
      return;
    }
    this.entry++;
    const a: Turn | null = this.active;
    if (a !== null) {
      a.client?.cancel();
      a.client = null;
      a.resend = false;
      a.state = StreamReducer.disconnected(a.state);
      a.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'),
        new AgentRetryTap(a.run, AgentRetryMode.SAME), null, null);
      a.phase = AgentTurnPhase.ENDED;
      this.active = null;
    }
    if (this.phase === AgentPhase.LOADING) {
      this.phase = AgentPhase.IDLE;
      this.started = false;
    }
    this.publish();
  }

  get isVisible(): boolean {
    return this.visible;
  }

  /** 发起时的进入世代仍有效且页面可见。 */
  private current(entry: number): boolean {
    return entry === this.entry && this.visible;
  }

  /** 加载失败的【重试】（受 42901 闸门控制）。 */
  retryLoad(t: AgentPageTicket): void {
    if (!this.pageOk(t) || this.phase !== AgentPhase.LOAD_FAILED || this.deps.gate.active) {
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
   * 实际发包出口的闸门（R1-01、R1-02；harmony-review-r2 R2-02）：创建请求时固定「进入世代 + 对话世代 + 本 operation 的票据（op）」，
   * sendAllowed 只比较这些固定值与此刻的控制器、42901 闸门、AI 同意闸门、可见性；任何一次核对不通过就永久失效（离页再回来、新对话、停止、
   * 同意被撤销后都不会恢复），端口之后的重签、重放、延迟发包一律不发。
   */
  private call(op: () => boolean): AgentCall {
    const entry: number = this.entry;
    const conversation: number = this.conversation;
    let revoked: boolean = false;
    return new AgentCall(this.identityKey, this.identity.level !== AgentIdentity.MEMBER,
      (): boolean => {
        if (revoked) {
          return false;
        }
        let ok: boolean = false;
        try {
          ok = this.alive() && entry === this.entry && conversation === this.conversation && this.visible
            && !this.deps.gate.active && this.consentGate === AgentConsentGate.CLEAR && op();
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
    return this.alive() && this.visible && this.phase === AgentPhase.READY && this.active === null
      && !this.deps.gate.active && !this.quotaExhausted && this.consentGate === AgentConsentGate.CLEAR;
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
    this.turns.push(turn);
    this.active = turn;
    this.announcement = '';
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
    if (this.consentGate !== AgentConsentGate.CLEAR || !this.visible) {
      // 实际发送出口（R1-01、R1-02）：同意未记录成功或页面不可见时一律不发；这一轮不留在列表里。
      this.removeTurn(turn);
      this.publish();
      return;
    }
    if (this.sessionId !== null) {
      this.stream(turn, this.sessionId as string);
      return;
    }
    const entry: number = this.entry;
    // R2-02：只为这一轮、这一个 run 建会话（停止、新对话、重试换 run、离页后都永久失效）。
    const call: AgentCall = this.call((): boolean => this.active === turn && turn.run === run && this.sessionId === null);
    contract.createSession(call).then((r: AgentHttpResult): void => {
      // R2-03：先核对固定身份；旧 run / 离页后到达的结果只结算共享事实（42901、10405、AI 10004），再按票据决定是否改界面。
      if (!this.alive()) {
        return;
      }
      if (!this.runOk(run) || this.active !== turn || !this.current(entry)) {
        this.settleOnly(r);
        return;
      }
      const session: AgentJsonObject | null = AgentJson.objectOf(r.data['session']) ?? (r.ok ? r.data : null);
      const id: string | null = session === null ? null
        : AgentJson.stringOf(session['id']) ?? AgentJson.stringOf(session['session_id']);
      if (!r.ok || id === null) {
        this.jsonFailed(turn, r.ok ? AgentHttpResult.network() : r);
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
    const run: AgentRunTicket = turn.run;
    // R2-02：许可绑定这一轮、这个 run、这一个流客户端（停止、断线收尾、重试换 run 之后都永久失效）。
    client.start(sessionId, turn.body,
      this.call((): boolean => this.active === turn && turn.run === run && turn.client === client));
  }

  /** 流事件：先比票据（控制器存活、对话世代、run 是当前活动 run），不等即丢弃，什么都不改。 */
  private onStream(ticket: AgentRunTicket, event: AgentStreamEvent): void {
    if (!this.runOk(ticket) || !this.visible) {
      // R2-03：同一身份的旧 run 迟到的 JSON 错误只结算共享事实（42901、10405、AI 10004），不改界面。
      if (this.alive() && event.kind === AgentStreamEventKind.JSON && event.result !== null) {
        this.settleOnly(event.result as AgentHttpResult);
      }
      // R3-01：旧 run 迟到的流内 error 10004 同样是同一身份的共享事实：只锁闸门、不弹框、不改界面（H27）。
      if (this.alive() && event.kind === AgentStreamEventKind.FRAME && event.frame !== null
        && AgentController.consentFrame(new AgentTerminal(event.frame.event, event.frame.data))) {
        this.consentLost(null, false);
      }
      return;
    }
    const turn: Turn = this.active as Turn;
    if (event.traceId.length > 0) {
      turn.traceId = event.traceId;
    }
    switch (event.kind) {
      case AgentStreamEventKind.PING:
        return;
      case AgentStreamEventKind.FRAME: {
        if (event.frame === null) {
          return;
        }
        if (turn.resend) {
          turn.resendState = StreamReducer.frame(turn.resendState, event.frame, this.deps.routes);
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
          turn.state = StreamReducer.frame(turn.state, event.frame, this.deps.routes);
        }
        turn.phase = turn.state.metaSeen ? AgentTurnPhase.STREAMING : turn.phase;
        this.afterFrame(turn);
        return;
      }
      case AgentStreamEventKind.EOF:
      case AgentStreamEventKind.TIMEOUT:
        if (turn.resend) {
          turn.resend = false;
        }
        turn.state = StreamReducer.disconnected(turn.state);
        this.finishTurn(turn);
        return;
      case AgentStreamEventKind.JSON:
        this.jsonFailed(turn, event.result ?? AgentHttpResult.network());
        return;
      case AgentStreamEventKind.FAILED:
        if (turn.state.metaSeen) {
          turn.state = StreamReducer.disconnected(turn.state);
          this.finishTurn(turn);
        } else {
          this.jsonFailed(turn, event.result ?? AgentHttpResult.network());
        }
        return;
      default:
        return;
    }
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

  private endDuplicate(turn: Turn): void {
    // duplicate=true 的流（G26）：不并入、不更新额度。done → 本地消息结束（保留已收到的内容）；error 30506 → 显示 error.30506 并给同键【重试】；
    // 其他 error → 按流内 error。
    const dup: AgentStreamState = turn.resendState;
    turn.resend = false;
    if (AgentController.consentFrame(dup.terminal)) {
      // R3-01：duplicate 流的 error 10004 与普通流同一处理（不走普通错误展示）。
      this.streamConsentLost(turn, dup.terminal as AgentTerminal);
      return;
    }
    const code: number | null = dup.terminal === null ? null : dup.terminal.code;
    if (dup.terminal !== null && dup.terminal.event === AgentEvent.DONE) {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.DONE);
      turn.error = null;
    } else if (code === 30506) {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.ERROR);
      turn.error = new AgentErrorView(AgentController.errorText(30506, turn.traceId),
        new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
    } else {
      turn.state = AgentController.endedAs(turn.state, AgentStatus.ERROR);
      turn.error = dup.terminal === null ? null : this.streamErrorView(turn, dup.terminal.data);
    }
    this.closeActive(turn);
  }

  /** 已收到的内容保留，只把状态收成结束（duplicate 收尾用）。 */
  private static endedAs(state: AgentStreamState, status: string): AgentStreamState {
    return new AgentStreamState(status, state.metaSeen, state.duplicate, state.runId,
      state.messageId, state.aiLabel, state.modelLabel, state.text, state.tools, state.cards, state.suggestions,
      state.rawSuggestions, state.terminal, state.lastSeq, state.quotaLeft);
  }

  private finishTurn(turn: Turn): void {
    const s: AgentStreamState = turn.state;
    if (AgentController.consentFrame(s.terminal)) {
      // R3-01（S0）：普通流与 duplicate 流（meta.duplicate=true 直接下发）的 error 10004 不按普通错误收尾。
      this.streamConsentLost(turn, s.terminal as AgentTerminal);
      return;
    }
    if (s.duplicate && s.terminal !== null && s.terminal.event === AgentEvent.ERROR && s.terminal.code === 30506) {
      // duplicate 流收到 30506（G26）：结束 loading，显示 error.30506 并给同键【重试】，不自动轮询。
      turn.error = new AgentErrorView(AgentController.errorText(30506, turn.traceId),
        new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
    } else if (s.status === AgentStatus.DISCONNECTED) {
      turn.error = new AgentErrorView(AgentDraftTexts.text('agent.draft.disconnected'),
        new AgentRetryTap(turn.run, AgentRetryMode.SAME), null, null);
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

  /**
   * 流内 error 帧 code=10004（harmony-review-r3 R3-01，S0；普通流、duplicate 流、重试后的 duplicate 收尾同一出口）：同步执行 consentLost 的
   * 禁发部分——停止本对话的所有流与计时、作废卡片回调和购买执行（cardEpoch +1）、对话世代 +1（已发出的 AgentCall.sendAllowed、停止许可、
   * 卡片 / 快捷追问 / 【重试】票据一律失效）、清空同意被撤销后不可展示的对话，再把闸门锁成 refused。
   * 是否弹框按现有规则另判：流契约的 error 帧没有 consent_type（不新增契约字段），AgentConsentPolicy.shows 不成立 → 不弹框，
   * 页面显示「暂不使用」同款说明与【重新同意】（H27）；不弹框也必须禁发。待同意 / 提交中时闸门已非 clear，保持原状态（H28）。
   */
  private streamConsentLost(turn: Turn, t: AgentTerminal): void {
    turn.phase = AgentTurnPhase.ENDED;
    turn.client?.cancel();
    turn.client = null;
    this.dropConversation();
    const consentType: string | null = AgentJson.stringOf(t.data['consent_type']);
    // interactive 只在现有规则允许弹框时成立（流契约下恒为 false）；锁闸门与是否弹框无关。
    this.consentLost(null, AgentConsentPolicy.shows(10004, consentType) && this.visible);
    if (this.consentGate === AgentConsentGate.CLEAR) {
      this.consentGate = AgentConsentGate.REFUSED;
    }
    this.publish();
  }

  private closeActive(turn: Turn): void {
    turn.phase = AgentTurnPhase.ENDED;
    turn.client?.cancel();
    turn.client = null;
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

  /** 发送返回 JSON 错误（G24）；42901、10405、10004、统一分流与其他三个 operation 共用 sharedError（R1-06）。 */
  private jsonFailed(turn: Turn, r: AgentHttpResult): void {
    turn.client?.cancel();
    turn.client = null;
    const d: AgentSendDecision = AgentSendErrorPolicy.decide(r.httpStatus, r.code < 0 ? 50001 : r.code, r.data,
      r.retryAfter, r.traceId, r.consentType);
    const page: AgentPageTicket = new AgentPageTicket(this.serial, this.conversation);
    turn.phase = AgentTurnPhase.FAILED;
    switch (d.action) {
      case AgentSendAction.UNAVAILABLE:
        this.phase = AgentPhase.UNAVAILABLE;
        this.removeTurn(turn);
        break;
      case AgentSendAction.QUOTA:
        this.quotaExhausted = true;
        turn.error = this.quotaView(turn);
        break;
      case AgentSendAction.NEW_CHAT:
        turn.error = new AgentErrorView(AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId), null, page, null);
        break;
      case AgentSendAction.RUN_IN_PROGRESS:
        this.deps.gate.start(d.disableMs);
        this.deps.toast(AgentController.errorText(r.code, r.traceId));
        this.removeTurn(turn);
        break;
      case AgentSendAction.RATE_LIMITED:
        this.sharedError(r, null);
        this.deps.toast(AgentController.errorText(r.code, r.traceId));
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
          this.consentLost(null, true);
          break;
        }
        turn.phase = AgentTurnPhase.AWAITING_CONSENT;
        if (this.active === turn) {
          this.active = null;
        }
        this.sharedError(r, turn.run.run);
        return;
      case AgentSendAction.FORCE_UPDATE:
        this.sharedError(r, null);
        this.removeTurn(turn);
        break;
      case AgentSendAction.TEXT_TOO_LONG:
        this.deps.toast(AgentDraftTexts.text('agent.draft.too_long'));
        this.removeTurn(turn);
        break;
      default:
        // 统一分流（10001 / 10005 / 非 AI 的 10004 / 表外码）：交统一入口（打开前置页或提示）；本条显示统一文案（5xxxx 带 trace6）。
        this.sharedError(r, null);
        turn.error = new AgentErrorView(AgentController.errorText(r.code < 0 ? 50001 : r.code, r.traceId), null, null, null);
        break;
    }
    if (this.active === turn) {
      this.active = null;
    }
    this.publish();
  }

  /**
   * 30502 额度用完（AgentQuotaGuest / AgentQuotaPhone，G24）：游客 →【登录】；会员未绑手机（或未知，按未验证）→【绑定手机号】；
   * 已绑手机的会员不再引导绑定（BR-AI-15 none 分支，H10），只给【去搜索】与「明天再来」的说明。
   */
  private quotaView(turn: Turn): AgentErrorView {
    const search: AgentTap = new AgentTap(turn.run, '', AgentTapKind.SEARCH, 'Search', {}, RouteSource.IN_APP,
      AgentDraftTexts.text('agent.draft.search'));
    const guest: boolean = this.identity.level !== AgentIdentity.MEMBER;
    let bound: boolean | null = null;
    try {
      bound = guest ? null : this.deps.phoneBound();
    } catch (e) {
      bound = null;
    }
    let up: AgentTap | null = null;
    let hint: string = AgentDraftTexts.text('agent.draft.quota.member_hint');
    if (guest) {
      up = new AgentTap(turn.run, '', AgentTapKind.LOGIN, 'Login', {}, RouteSource.IN_APP,
        AgentDraftTexts.text('agent.draft.login'));
      hint = AgentDraftTexts.text('agent.draft.quota.guest_hint');
    } else if (bound !== true) {
      up = new AgentTap(turn.run, '', AgentTapKind.BIND_PHONE, 'BindPhone', {}, RouteSource.IN_APP,
        AgentDraftTexts.text('agent.draft.bind_phone'));
      hint = AgentDraftTexts.text('agent.draft.quota.phone_hint');
    }
    return new AgentErrorView(AgentController.errorText(30502, ''), null, null, search,
      AgentDraftTexts.text('agent.draft.search'), '', up, hint);
  }

  private removeTurn(turn: Turn): void {
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

  // ---------------------------------------------------------------- 停止、新对话、重试

  /** 【停止】：本地立即 cancelled，再调 cancelAgentRun（带原身份；发包前复核身份未变，30505 静默）。 */
  stop(t: AgentRunTicket): void {
    if (!this.runOk(t)) {
      return;
    }
    const turn: Turn = this.active as Turn;
    const action: AgentTicketAction = AgentTicketPolicy.action(AgentTicketEvent.STOP);
    turn.client?.cancel();
    turn.client = null;
    turn.state = StreamReducer.localCancel(turn.state);
    turn.resend = false;
    turn.error = null;
    turn.phase = AgentTurnPhase.ENDED;
    this.active = null;
    // R1-03（brief §0.3）：停止同步作废这一对话已渲染的卡片回调与在途购买尝试；这一轮的卡片照常显示、按钮不再可用。
    this.revokeCardActions();
    turn.revoked = true;
    this.publish();
    const runId: string | null = turn.state.runId;
    if (action.sendsCancel && runId !== null && this.deps.contract !== null) {
      // R2-04：停止请求固定原对话与 operation 票据（停止时的 run 序号）：之后有新对话、新消息、重试或离页，结果只结算共享事实，
      // 不弹框、不导航、不改新对话。
      const entry: number = this.entry;
      const conversation: number = this.conversation;
      const seq: number = this.runSeq;
      // 发包许可固定进入世代与原对话（新对话、离页后不再发 cancel，与 G06 一致）；同一对话里接着发新消息不挡停止。
      const call: AgentCall = this.call((): boolean => true);
      (this.deps.contract as AgentContractPort).cancelRun(runId, call).then((r: AgentHttpResult): void => {
        this.afterOp(r, (): boolean => this.current(entry) && conversation === this.conversation && seq === this.runSeq
          && this.active === null, 'cancel');
      });
    }
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
   * 建会话（新对话）与停止的结果（R1-06）：先核对归属；成功不处理；票据失效（离页、换了对话、之后又发起了 run，R2-03、R2-04）只结算共享事实；
   * 仍有效时 30505、本地没发出静默，其余按 sharedError，剩下的码提示统一文案（5xxxx 带 trace6），不直接吞掉。
   */
  private afterOp(r: AgentHttpResult, uiOk: () => boolean, op: string): void {
    if (!this.alive() || r.ok) {
      return;
    }
    if (!uiOk()) {
      this.settleOnly(r);
      return;
    }
    const kind: string = this.sharedError(r, null);
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
    // R2-02：只为这一次新对话建会话（再点新对话、离页、已有会话后永久失效）。
    const call: AgentCall = this.call((): boolean => this.sessionId === null);
    contract.createSession(call).then((r: AgentHttpResult): void => {
      // R2-03：先核对固定身份，再结算共享事实；对话、进入世代、之后是否又发起了 run 决定能不能改界面。
      if (!this.alive()) {
        return;
      }
      const own: boolean = conversation === this.conversation && this.sessionId === null;
      if (r.ok) {
        const session: AgentJsonObject | null = AgentJson.objectOf(r.data['session']) ?? r.data;
        if (own && this.current(entry) && session !== null) {
          this.sessionId = AgentJson.stringOf(session['id']) ?? AgentJson.stringOf(session['session_id']);
        }
        return;
      }
      this.afterOp(r, (): boolean => own && this.current(entry) && seq === this.runSeq && this.active === null,
        'session');
    });
  }

  /** 同步作废当前对话（新对话）：关连接、停计时、清消息与卡片回调；对话世代 +1。 */
  private dropConversation(): void {
    for (const turn of this.turns) {
      turn.client?.cancel();
      turn.client = null;
    }
    this.active = null;
    this.turns = [];
    this.conversation++;
    this.sessionId = null;
    // 同意弹窗与同意闸门不随新对话解除（R1-01：没记录成功就一直禁发；旧对话的待重放消息随对话一起作废）。
    this.revokeCardActions();
    this.announcement = '';
  }

  /** 【重试】：沿用同一 client_msg_id（50401、断线、duplicate 30506）或新消息（流内 error）。 */
  retry(t: AgentRetryTap): void {
    const turn: Turn | null = this.turnOf(t.controller, t.conversation, t.run);
    if (turn === null || this.active !== null || turn.error === null || turn.error.retry === null
      || turn.run.clientMsgId !== t.clientMsgId || this.consentGate !== AgentConsentGate.CLEAR || !this.visible) {
      return;
    }
    if (this.deps.gate.active) {
      this.deps.toast(DefaultTexts.text('error.42901') ?? '');
      return;
    }
    if (t.mode === AgentRetryMode.NEW) {
      this.sendText(turn.userText);
      return;
    }
    const clientMsgId: string = ClientMsgId.forRetry('retry_disconnected', turn.run.clientMsgId);
    turn.run = this.newRun(clientMsgId);
    turn.error = null;
    turn.phase = AgentTurnPhase.CONNECTING;
    // 已收到的部分内容保留（不补拉历史，G02 ②）；回来的若是 duplicate 两帧，按 G26 收尾，不并入。
    turn.resend = turn.state.metaSeen;
    turn.resendState = StreamReducer.initial();
    if (!turn.resend) {
      turn.state = StreamReducer.initial();
    }
    this.active = turn;
    this.publish();
    this.dispatch(turn);
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
    }
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
    return s;
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
    return new AgentTurnView(t.run.run, t.run, t.userText, t.phase, state.status, AgentText.render(state.text), state.tools,
      cards, ended ? chips : [], label, t.error, t === this.active);
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
    if (this.consentGate === AgentConsentGate.REFUSED && this.phase === AgentPhase.READY && this.active === null) {
      // 迟到的 AI 10004 只锁了闸门（R2-01）：没有在途回复时显示说明与【重新同意】（不弹框）。
      this.phase = AgentPhase.CONSENT_DECLINED;
    }
    this.revision++;
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
