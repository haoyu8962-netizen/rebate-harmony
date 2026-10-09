import { ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { SearchApiPort, disableMillisOf } from '../search/SearchController';
import { BaichuanAdapter } from '../tradejump/Baichuan';
import { CardPatch } from './CardPatch';
import {
  LateDecision, LateResponsePolicy, JumpTypes, OpenActions, OpenAttempt, OpenErrorAction, OpenErrorActions,
  OpenErrorOutcome, OpenResponseAction, OpenResponseOutcome
} from './OpenTradeFlow';
import { InstalledState, JumpOutcome, JumpPorts, PurchaseIdentity, TradeJumpExecutor } from './TradeJump';
import { TradeJson } from './TradeJson';
import {
  AuthSheetCounter, JumpTipService, PurchasePending, TaobaoAuthFlow, TaobaoAuthOutcome, TradeOperations, tradeGuarded,
  WebCodeAuthorizer
} from './TradeServices';

/** 计时器（生产 setTimeout；测试注入假时钟）。 */
export interface TradeTimers {
  set(millis: number, fn: () => void): number;

  clear(id: number): void;
}

export class SystemTradeTimers implements TradeTimers {
  set(millis: number, fn: () => void): number {
    return setTimeout(fn, millis);
  }

  clear(id: number): void {
    clearTimeout(id);
  }
}

/** 购买浮层的阶段。 */
export class PurchasePhase {
  static readonly IDLE: string = 'idle';
  /** open 请求在途：可取消的加载层（ProductBuyOpening，03 §4.5）。 */
  static readonly LOADING: string = 'loading';
  /** 8 秒没有响应（ProductBuyTimeout，TRADE-22）：【重试】沿用原键。 */
  static readonly TIMEOUT: string = 'timeout';
}

/** 购买流程的弹层种类（每种对应设计稿一个画板）。 */
export class PurchaseDialogKind {
  /** 价格变动（ProductPriceChanged）/ 券失效（coupon）确认；rebateGone 时合并无返利说明（ProductPriceChangedRebateGone）。 */
  static readonly CONFIRM_PRICE: string = 'confirm_price';
  /** 返利变为 0（ProductRebateGone）。 */
  static readonly CONFIRM_REBATE_GONE: string = 'confirm_rebate_gone';
  /** 比价无返利（ProductPriceCompareNoRebate，BR-PRICE-08）。 */
  static readonly COMPARE_NO_REBATE: string = 'compare_no_rebate';
  /** 平台授权说明半屏（ProductAuthSheet）。 */
  static readonly AUTH_SHEET: string = 'auth_sheet';
  /** 关闭授权（ProductAuthDeclined）/ 授权失败（failed，ProductAuthFailed）：【重试】【仍去购买（无返利）】（BR-ID-18）。 */
  static readonly AUTH_DECLINED: string = 'auth_declined';
  /**
   * 授权结果查不到（共性第 19 条，03 §4.2）：授权回流后的查询、淘宝绑定或重新取授权地址请求失败（42901、5xxxx、传输失败），不知道
   * 到底授权了没有，不能当成用户没授权。【重试】重新查询（42901 期间置灰、执行层也拦下）；【取消】放弃本次购买待办。
   */
  static readonly AUTH_CHECK_FAILED: string = 'auth_check_failed';
  /** 站长授权不可用（ProductAuthUnavailable，BR-ID-24）：只提示，不给无返利购买。 */
  static readonly AUTH_UNAVAILABLE: string = 'auth_unavailable';
  /** 下单须知（ProductJumpTip，BR-ATTR-21）。 */
  static readonly JUMP_TIP: string = 'jump_tip';
  /** 暂时无法打开淘宝（ProductJumpSdkFailed，BR-ATTR-27 淘宝行）。 */
  static readonly SDK_FAILED: string = 'sdk_failed';
  /** 带按钮的错误提示（30103 / 30121 / 30151 / 30153 / 50303）。 */
  static readonly NOTICE: string = 'notice';
}

/** 一个弹层（字段按种类取用）。 */
export class PurchaseDialog {
  private static counter: number = 0;
  /** 每个弹层对象一个编号（界面按它重建弹层，弹层内容不随旧对象残留）。 */
  readonly seq: number;
  readonly kind: string;
  platform: string = '';
  oldFen: number | null = null;
  newFen: number | null = null;
  rebateGone: boolean = false;
  coupon: boolean = false;
  /** 返利归零确认里的价格。 */
  priceFen: number | null = null;
  /** AuthSheet【去授权】已点、等结果。 */
  busy: boolean = false;
  /** AUTH_DECLINED：授权失败（否则是用户关闭授权）。 */
  failed: boolean = false;
  textKey: string | null = null;
  traceId: string | null = null;
  /** AUTH_CHECK_FAILED：淘宝绑定之后（查到未授权即授权失败），否则拼多多授权回来。 */
  afterBind: boolean = false;
  /**
   * AUTH_CHECK_FAILED：30104 恢复中授权许可被撤销后的回流查询（H-R2-01）——查到未授权就把 AuthSheet 交还用户再点（不当成用户关闭授权）。
   */
  resheet: boolean = false;
  noRebate: boolean = false;
  contact: boolean = false;
  retry: boolean = false;
  /**
   * 补同意后重开详情时的确认（H-R1-01，共性第 24 条）：重开取到的卡与原点击的报价基准不一致（改价、返利归零），还没发 open；
   * 【继续购买】才按此刻的卡发一次 open（新键）。
   */
  beforeOpen: boolean = false;

  constructor(kind: string, platform: string = '') {
    PurchaseDialog.counter++;
    this.seq = PurchaseDialog.counter;
    this.kind = kind;
    this.platform = platform;
  }

  copyBusy(busy: boolean): PurchaseDialog {
    const d: PurchaseDialog = new PurchaseDialog(this.kind, this.platform);
    d.busy = busy;
    return d;
  }
}

/** 轻提示（文案键 + trace6）。id 每次递增（同一句再次提示也重新播报）。 */
export class PurchaseToast {
  readonly key: string;
  readonly traceId: string | null;
  readonly id: number;

  constructor(key: string, traceId: string | null, id: number) {
    this.key = key;
    this.traceId = traceId;
    this.id = id;
  }
}

/** 点击结果带来的禁用原因（50301 / 30141，03 §7.4）。按对象绑定（共性第 5 条）。 */
export class BuyBlock {
  static readonly MAINTENANCE: string = 'maintenance';
  static readonly NOT_LAUNCHED: string = 'not_launched';
  static readonly OFF_SHELF: string = 'off_shelf';
}

/** 购买流程的界面状态（每次变化整体换新，页面按它渲染）。 */
export class PurchaseState {
  phase: string = PurchasePhase.IDLE;
  platform: string = '';
  /** 最近一次点购买的卡。 */
  card: Record<string, Object> | null = null;
  dialog: PurchaseDialog | null = null;
  toast: PurchaseToast | null = null;
  /** 42901 限时禁用购买按钮（Retry-After，缺省 5 秒）。 */
  rateLimited: boolean = false;
  /** 全部路径失败、安装状态明确为 false：「安装X后下单才有返利」（ProductJumpNotInstalled，BR-ATTR-27 ②；unknown 不算，共性第 13 条）。 */
  notInstalled: boolean = false;
  /** notInstalled 且这次已复制口令（ProductJumpNotInstalled：按钮「复制淘口令」）。 */
  notInstalledCopied: boolean = false;
  /** 即将交系统浏览器：「将通过浏览器打开X」+【取消】（ProductJumpBrowser）。 */
  browserNotice: boolean = false;
  /**
   * 当前尝试那张卡的最新展示版本（open 结果写入、权威重取补齐之后的）：确认框按它判断新价格的口径词（券后 / 售价），券额仍未知时
   * 不给口径词（H-R1-05，BR-PRICE-14，共性第 21 条）。
   */
  latest: Record<string, Object> | null = null;

  copy(): PurchaseState {
    const s: PurchaseState = new PurchaseState();
    s.phase = this.phase;
    s.platform = this.platform;
    s.card = this.card;
    s.dialog = this.dialog;
    s.toast = this.toast;
    s.rateLimited = this.rateLimited;
    s.notInstalled = this.notInstalled;
    s.notInstalledCopied = this.notInstalledCopied;
    s.browserNotice = this.browserNotice;
    s.latest = this.latest;
    return s;
  }
}

/**
 * 弹层按钮的可点状态（H-R1-08，共性第 19 条，03 §4.2）：42901 限流期间（Retry-After，缺省 5 秒）会被执行层拦下的按钮——授权结果查不到
 * 的【重试】（recheckAuth）、二选一与 50303 的【重试】（retryPurchase）、【仍去购买（无返利）】——在界面上同样置灰、不可点，到期恢复。
 */
export class PurchaseButtons {
  /** 【重试】（重新查询授权 / 重新购买）此刻不可点。 */
  static retryDisabled(state: PurchaseState): boolean {
    const d: PurchaseDialog | null = state.dialog;
    if (!state.rateLimited || d === null) {
      return false;
    }
    return d.kind === PurchaseDialogKind.AUTH_CHECK_FAILED || d.kind === PurchaseDialogKind.AUTH_DECLINED
      || (d.kind === PurchaseDialogKind.NOTICE && d.retry);
  }

  /** 【仍去购买（无返利）】此刻不可点（同样经 buyWithoutRebate 的限流拦截）。 */
  static noRebateDisabled(state: PurchaseState): boolean {
    const d: PurchaseDialog | null = state.dialog;
    return state.rateLimited && d !== null
      && (d.kind === PurchaseDialogKind.AUTH_DECLINED || (d.kind === PurchaseDialogKind.NOTICE && d.noRebate));
  }
}

/** 超时提示条的展示端（详情页、搜索页各自实现）。 */
export interface PurchaseTimeoutView {
  /** visible：显示「网络不稳定，请重试」+【重试】；retryDisabled：42901 限流期间【重试】置灰。 */
  show(visible: boolean, retryDisabled: boolean): void;
}

/**
 * 超时提示与同键重试的接线（ProductBuyTimeout，TRADE-22；H-R1-02，共性第 29 条）：详情页与搜索页共用。状态变化时 apply；【重试】
 * 走 retryAfterTimeout（原路径、原请求体、原键）；关闭 = 放弃本次（dismissTimeout，本机放弃，不调作废接口）。
 */
export class PurchaseTimeoutBinding {
  private readonly controller: OpenPurchaseController;
  private readonly view: PurchaseTimeoutView;
  /**
   * 购买限流（42901，Retry-After）的按钮状态（H-R2-07，共性第 36 条）：搜索卡的购买按钮按它置灰、到期恢复（详情页另由 buyState 接）。
   */
  private readonly buyLimit: ((limited: boolean) => void) | null;

  constructor(controller: OpenPurchaseController, view: PurchaseTimeoutView,
    buyLimit: ((limited: boolean) => void) | null = null) {
    this.controller = controller;
    this.view = view;
    this.buyLimit = buyLimit;
  }

  apply(state: PurchaseState): void {
    this.view.show(state.phase === PurchasePhase.TIMEOUT, state.rateLimited);
    if (this.buyLimit !== null) {
      this.buyLimit(state.rateLimited);
    }
  }

  retry(): void {
    this.controller.retryAfterTimeout();
  }

  dismiss(): void {
    this.controller.dismissTimeout();
  }
}

/** /v1/config.help_links.<key>：{route, params}。 */
export class HelpLink {
  readonly route: string;
  readonly params: Record<string, Object>;

  constructor(route: string, params: Record<string, Object>) {
    this.route = route;
    this.params = params;
  }
}

/**
 * 补同意前那次点击的购买意图（H01、H-R1-01，共性第 24 条）：同意会清栈，App 重开那件商品的详情后自动恢复一次。带原点击的 link_id、
 * 不可变的报价与返利基准（点击时那张卡的快照）与 spm：重开取到的新卡只用于展示与比对，不能当成判断改价 / 返利归零的基准。
 */
export class ConsentResume {
  readonly productKey: string;
  readonly linkId: string;
  readonly card: Record<string, Object>;
  readonly spm: string | null;

  constructor(productKey: string, linkId: string, card: Record<string, Object>, spm: string | null) {
    this.productKey = productKey;
    this.linkId = linkId;
    this.card = card;
    this.spm = spm;
  }
}

/** 购买流程要的页面环境（App 给）。 */
export interface PurchaseEnv {
  /** 有登录会话（游客 open 返回 10001）。 */
  loggedIn(): boolean;

  /** 基本模式（没有同意完整隐私政策）：购买先走补同意，同意后按 pending_action 恢复一次（BR-ID-11、03 §4.1，共性第 4 条）。 */
  basicMode(): boolean;

  /** 弹出补同意（首启弹窗的「开启完整功能」）；resume 是这次点击的购买意图（清栈后由 App 交给重开的详情）。 */
  requestConsent(resume: ConsentResume): void;

  /** 此刻的平台购买状态（点击结果确认的 50301 优先，其次 features.platform_status；on / maintenance / not_launched）。 */
  platformStatus(platform: string): string;

  /** 点击结果确认的平台状态（50301）：按平台记下，新配置覆盖它（共性第 5、6 条）。 */
  markPlatformStatus(platform: string, status: string): void;

  /** 用 open 响应更新 target 这张卡（无论确认还是取消，BR-PRICE-12）。 */
  updateCard(target: Record<string, Object>, transform: (card: Record<string, Object>) => Record<string, Object>): void;

  /** 经 Router 打开路由（Login、Search、Help，routes.json 的路由名）。 */
  open(route: string, params: Record<string, Object>): void;

  /**
   * 按 target 的 product_key + item_ref 重取权威商品卡（getProduct；之后仍须用户再点），结果到达时用 merge(此刻页面上的那张卡, 重取到的卡)
   * 决定怎么落到页面上（共性第 17 条）。失败、页面已离开时什么都不做（卡片保持原样）。
   */
  refetchCard(target: Record<string, Object>,
    merge: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object>): void;

  /** 帮助入口（/v1/config.help_links.<key>），没有配置为 null（不显示入口）。 */
  helpLink(key: string): HelpLink | null;
}

/**
 * 一次购买尝试（不可变，共性第 1、2 条）：用户这一次点击的原卡快照（改价、返利归零确认的判断基准）、完整的原请求（路径里的 link_id、
 * 请求体、幂等键）。超时【重试】、登录后的重放都只重放它；迟到响应可以更新展示的卡片（含 new_link_id），但不改它。
 */
export class PurchaseAttempt {
  readonly click: number;
  readonly card: Record<string, Object>;
  readonly linkId: string;
  readonly body: string;
  readonly key: string;
  readonly noRebate: boolean;
  readonly noRebateReason: string | null;
  readonly installed: string;
  /** 用户在二选一里主动点【重试】发起的（拦下时直接给授权，不占自动弹出次数，共性第 10 条）。 */
  readonly userAuthRetry: boolean;

  constructor(click: number, card: Record<string, Object>, linkId: string, body: string, key: string, noRebate: boolean,
    noRebateReason: string | null, installed: string, userAuthRetry: boolean) {
    this.click = click;
    this.card = card;
    this.linkId = linkId;
    this.body = body;
    this.key = key;
    this.noRebate = noRebate;
    this.noRebateReason = noRebateReason;
    this.installed = installed;
    this.userAuthRetry = userAuthRetry;
  }

  get platform(): string {
    return TradeJson.text(this.card, 'platform') ?? '';
  }

  /** 同一请求的重放（登录后）：新的点击编号，其余不变。 */
  replay(click: number): PurchaseAttempt {
    return new PurchaseAttempt(click, this.card, this.linkId, this.body, this.key, this.noRebate, this.noRebateReason,
      this.installed, this.userAuthRetry);
  }
}

/** 续执行许可（共性第 3 条）。 */
class Permit {
  readonly attempt: PurchaseAttempt;
  valid: boolean = true;

  constructor(attempt: PurchaseAttempt) {
    this.attempt = attempt;
  }
}

/** 授权外跳的续执行许可（H-R1-03，共性第 25 条）：用户点【去授权】时发；进入后台、被覆盖、离开、新点击都作废它。 */
class AuthPermit {
  readonly context: AuthContext;
  valid: boolean = true;

  constructor(context: AuthContext) {
    this.context = context;
  }
}

class ReadyJump {
  readonly plan: Record<string, Object>;
  readonly identity: PurchaseIdentity;
  readonly attempt: PurchaseAttempt;

  constructor(plan: Record<string, Object>, identity: PurchaseIdentity, attempt: PurchaseAttempt) {
    this.plan = plan;
    this.identity = identity;
    this.attempt = attempt;
  }
}

class AuthContext {
  readonly code: number;
  readonly linkId: string;
  readonly data: Record<string, Object>;
  readonly attempt: PurchaseAttempt;

  constructor(code: number, linkId: string, data: Record<string, Object>, attempt: PurchaseAttempt) {
    this.code = code;
    this.linkId = linkId;
    this.data = data;
    this.attempt = attempt;
  }

  get platform(): string {
    return this.attempt.platform;
  }
}

/** 购买执行器的依赖（App 组合）。 */
export class PurchaseDeps {
  api: SearchApiPort;
  executor: TradeJumpExecutor;
  ports: JumpPorts;
  env: PurchaseEnv;
  pending: PurchasePending;
  counter: AuthSheetCounter;
  tips: JumpTipService;
  webCode: WebCodeAuthorizer;
  baichuan: BaichuanAdapter;
  timers: TradeTimers = new SystemTradeTimers();
  clock: () => number = Date.now;
  keyGenerator: () => string = (): string => PurchaseDeps.uuid();
  timeoutMillis: number = OpenPurchaseController.TIMEOUT_MILLIS;
  browserNoticeMillis: number = OpenPurchaseController.BROWSER_NOTICE_MILLIS;

  constructor(api: SearchApiPort, executor: TradeJumpExecutor, ports: JumpPorts, env: PurchaseEnv,
    pending: PurchasePending, counter: AuthSheetCounter, tips: JumpTipService, webCode: WebCodeAuthorizer,
    baichuan: BaichuanAdapter) {
    this.api = api;
    this.executor = executor;
    this.ports = ports;
    this.env = env;
    this.pending = pending;
    this.counter = counter;
    this.tips = tips;
    this.webCode = webCode;
    this.baichuan = baichuan;
  }

  /** UUID v4（Idempotency-Key）。 */
  static uuid(): string {
    const hex: string = '0123456789abcdef';
    let out: string = '';
    for (let i: number = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        out += '-';
      } else if (i === 14) {
        out += '4';
      } else if (i === 19) {
        out += hex.charAt(8 + Math.floor(Math.random() * 4));
      } else {
        out += hex.charAt(Math.floor(Math.random() * 16));
      }
    }
    return out;
  }
}

/**
 * 购买执行器（APP-06b；03 §4.5、§7.4，TRADE-03 / 22，BR-PRICE-08 / 12 / 13，BR-ATTR-21 / 27，BR-ID-10 / 11 / 17 / 18 / 22 / 24）。
 * 一个发起页一份，只在 UI 线程使用。
 *
 * - 点击：基本模式先补同意（登记 pending_action，同意后恢复一次）；按此刻的平台状态再核对一次（maintenance 提示、not_launched 不发），
 *   卡片已下架不发；再建一次 PurchaseAttempt 发 open（新键、可取消的加载层）；
 * - 8 秒没有响应：结束加载，「网络不稳定，请重试」，【重试】完整重放原尝试（原路径、原请求体、原键）；不自动重试、不自动外跳；
 * - 续执行许可（共性第 3 条）：每次点击（及用户在确认框、超时条上的继续）发一张许可；取消、离开、进入后台或被覆盖、再次点击都作废它。
 *   等 JumpTip 已读、浏览器提示、跳转每一步、上报 link_jump 之前都复核许可；作废之后到达的 open 响应只更新卡片，不外跳、不弹确认；
 * - 响应 → OpenResponseAction（判断基准是尝试的原卡快照）；卡片按响应更新，价格 / 返利字段给不全时重取权威卡片（不反推）；
 *   错误 → OpenErrorAction；
 * - 10001：登记 pending_action（沿用原键）进登录，登录后 resumeAfterLogin 自动重放一次（不在前台时等回到前台）；
 * - 30101 / 30102 / 30111：AuthSheet（每平台每会话最多自动弹 2 次，BR-ID-18；用户在二选一里主动【重试】不受限）→ 授权 → 服务端确认已
 *   授权后自动执行一次 open，用新键（BR-ID-10 / 22 细则）；取消、没完成或查不到授权 → 删除待办，给【仍去购买（无返利）】【重试】；
 * - 外跳：JumpTip（用户 × 平台首次）→ TradeJumpExecutor（每步上报 link_jump，同一个 attempt_id 与替换后的 link_id；expire_at 过期即停）。
 */
export class OpenPurchaseController {
  /** TRADE-22：open 最多等 8 秒。 */
  static readonly TIMEOUT_MILLIS: number = 8000;
  /** 「将通过浏览器打开」的提示停留时长（可取消；未规定，TODO(N-28)）。 */
  static readonly BROWSER_NOTICE_MILLIS: number = 1200;
  static readonly LOGIN_ROUTE: string = 'Login';
  static readonly SEARCH_ROUTE: string = 'Search';
  static readonly HELP_ROUTE: string = 'Help';
  static readonly HELP_PRICE_COMPARE: string = 'price_compare';
  static readonly NO_REBATE_AUTH_DECLINED: string = 'auth_declined';
  static readonly NO_REBATE_AUTH_FAILED: string = 'auth_failed';
  static readonly PENDING_LOGIN: string = 'login';
  static readonly PENDING_AUTH: string = 'auth';
  static readonly PENDING_CONSENT: string = 'consent';
  // 文案键（契约有的读契约，没有的在 App 的草稿表，TODO(N-28)）
  static readonly MAINTENANCE_KEY: string = 'error.50301.maintenance';
  static readonly OFF_SHELF_KEY: string = 'error.30141';
  static readonly REF_EXPIRED_KEY: string = 'error.30144';
  static readonly RATE_LIMITED_KEY: string = 'error.42901';
  static readonly GENERIC_KEY: string = 'error.50001';
  static readonly NETWORK_KEY: string = 'buy.timeout';
  static readonly COPIED_KEY: string = 'share_page.copy_tpwd.done';
  static readonly NOT_INSTALLED_COPIED_KEY: string = 'trade.not_installed.copied';
  static readonly REQUOTE_KEY: string = 'trade.requote_notice';
  static readonly JUMP_FAILED_KEY: string = 'trade.jump_failed';
  static readonly JUMP_EXPIRED_KEY: string = 'trade.jump_expired';
  /** ProductJumpHarmonyH5：鸿蒙淘宝降级到网页的提示（仅鸿蒙，草稿）。 */
  static readonly HARMONY_H5_KEY: string = 'trade.harmony_h5_notice';
  static readonly CANCELLED_PRICE_KEY: string = 'trade.cancelled.price';
  static readonly CANCELLED_PRICE_REBATE_KEY: string = 'trade.cancelled.price_rebate';
  static readonly CANCELLED_REBATE_KEY: string = 'trade.cancelled.rebate';
  private static readonly TITLE_MAX: number = 60;
  private static readonly SPM_MAX: number = 128;

  private readonly d: PurchaseDeps;
  private readonly keys: OpenAttempt;
  private s: PurchaseState = new PurchaseState();
  onChange: (state: PurchaseState) => void = (_s: PurchaseState) => {
  };

  /** 点击编号：每次新的点击（含授权后、登录后的自动执行）加 1。 */
  private click: number = 0;
  /** 请求编号：超时【重试】是同一尝试的重发，旧请求的响应丢弃。 */
  private request: number = 0;
  private interrupt: string = LateResponsePolicy.NONE;
  private timedOut: boolean = false;
  private left: boolean = false;
  /** 发起页在前台（onShown 之后、onHidden / 进后台之前）。 */
  private foreground: boolean = true;
  /** 自动执行的动作（登录、补同意后的恢复）遇到页面不在前台：回到前台再执行。 */
  private deferred: (() => void) | null = null;
  private owners: (() => boolean)[] = [];
  private timer: number = -1;
  private toastSeq: number = 0;
  private blockedUntil: number = 0;
  private blockTimer: number = -1;
  private current: PurchaseAttempt | null = null;
  /** 当前尝试那张卡的最新展示版本（按响应更新后的）。 */
  private card: Record<string, Object> = {};
  private spm: string | null = null;
  private permit: Permit | null = null;
  private ready: ReadyJump | null = null;
  private authContext: AuthContext | null = null;
  private awaitingAuthReturn: boolean = false;
  /**
   * 授权外跳（拼多多 auth_jump）已发起、执行器的完成回调还没到（H-R2-05，共性第 38 条）：这期间 App 进过后台就记 authLeftApp；
   * 完成回调到达时若已离开过 App 又回到了前台（onForeground 先到），立即补查授权状态；还没离开过就等回前台再查。
   */
  private authJumpInFlight: boolean = false;
  private authLeftApp: boolean = false;
  /** 回流查询查到未授权时交还 AuthSheet（30104 恢复被撤销，H-R2-01），否则按「没完成就回来」给二选一。 */
  private authReturnSheet: boolean = false;
  private browserResolve: ((ok: boolean) => void) | null = null;
  private browserTimer: number = -1;
  /** 基本模式下点购买、等补同意的那张卡。 */
  private consentCard: Record<string, Object> | null = null;
  private consentSpm: string | null = null;
  /** 最近一次 open 响应对应尝试的原卡（确认框「之前」一行的价格口径词用）。 */
  cardBeforeResponse: Record<string, Object> = {};
  /** 补同意后重开详情、与原基准不一致时等用户确认的那张卡（beforeOpen 确认框；确认才发 open）。 */
  private resumeCard: Record<string, Object> | null = null;
  /** 授权外跳的续执行许可（H-R1-03）。 */
  private authPermit: AuthPermit | null = null;
  /** 补齐请求的世代（H-R1-04，共性第 26 条）：每写入一次 open 结果换一个，旧补齐响应认出卡片已不是那一次的结果。 */
  private static fillSeq: number = 0;

  constructor(deps: PurchaseDeps) {
    this.d = deps;
    this.keys = new OpenAttempt(deps.keyGenerator);
  }

  get state(): PurchaseState {
    return this.s;
  }

  /** 当前卡片（测试观察、搜索页认卡用）。 */
  get currentCard(): Record<string, Object> {
    return this.card;
  }

  /** 当前购买尝试（测试观察用）。 */
  get currentAttempt(): PurchaseAttempt | null {
    return this.current;
  }

  // ---------------------------------------------------------------- 点击与发送

  /** 用户点了【购买】。spm 为按钮的 页面.模块.坑位（03 §4.7）。 */
  buy(card: Record<string, Object>, spm: string | null): void {
    this.buyWith(card, spm, false);
  }

  private buyWith(card: Record<string, Object>, spm: string | null, userAuthRetry: boolean): void {
    if (this.left || this.busy()) {
      return;
    }
    const platform: string = TradeJson.text(card, 'platform') ?? '';
    if (!this.purchasable(card) || this.blocked()) {
      return;
    }
    this.card = card;
    this.spm = spm;
    this.update((st: PurchaseState) => {
      st.platform = platform;
      st.card = card;
      st.notInstalled = false;
      st.notInstalledCopied = false;
    });
    if (this.d.env.basicMode()) {
      this.requestConsentFor(card, spm);
      return;
    }
    this.startClick(card, this.keys.start(), false, null, userAuthRetry);
  }

  /** 基本模式：登记购买待办（没有发请求，不带键）并弹补同意；同意后 resumeAfterConsent 恢复一次，仍不同意由 Router 删除待办。 */
  private requestConsentFor(card: Record<string, Object>, spm: string | null): void {
    const linkId: string | null = TradeJson.text(card, 'link_id');
    if (linkId === null) {
      this.toast(OpenPurchaseController.REF_EXPIRED_KEY);
      return;
    }
    this.consentCard = card;
    this.consentSpm = spm;
    this.d.pending.register(OpenPurchaseController.pendingParams(card, linkId, null,
      OpenPurchaseController.PENDING_CONSENT, false, null));
    this.d.env.requestConsent(new ConsentResume(TradeJson.text(card, 'product_key') ?? '', linkId, card, spm));
  }

  /** 加载层【取消】：只挡本机外跳，之后到达的响应只更新卡片（03 §4.5）。 */
  cancelLoading(): void {
    if (this.s.phase !== PurchasePhase.LOADING) {
      return;
    }
    this.interrupt = LateResponsePolicy.CANCEL;
    this.revokePermit();
    this.keys.cancel();
    this.clearTimer();
    this.update((st: PurchaseState) => {
      st.phase = PurchasePhase.IDLE;
    });
  }

  /** 超时后的【重试】：完整重放原尝试（原路径、原请求体、原键，TRADE-22）；用户这一下重新发许可。 */
  retryAfterTimeout(): void {
    const attempt: PurchaseAttempt | null = this.current;
    if (this.left || this.s.phase !== PurchasePhase.TIMEOUT || attempt === null || this.blocked()) {
      return;
    }
    // 重发前复核最新平台购买状态与商品可购状态（H-R1-06，共性第 27 条）：不可买就放弃本次（不再发同键请求），界面回到空闲
    if (!this.purchasable(this.latestCard(attempt))) {
      this.dismissTimeout();
      return;
    }
    this.keys.retry();
    this.grantPermit(attempt);
    this.send(attempt);
  }

  /** 超时条的关闭（放弃本次）：本机放弃，不调作废接口。 */
  dismissTimeout(): void {
    if (this.s.phase !== PurchasePhase.TIMEOUT) {
      return;
    }
    this.keys.abandon();
    this.revokePermit();
    this.update((st: PurchaseState) => {
      st.phase = PurchasePhase.IDLE;
    });
  }

  private startClick(card: Record<string, Object>, key: string, noRebate: boolean, noRebateReason: string | null,
    userAuthRetry: boolean): void {
    // 没有 link_id 的卡买不了（契约 openLink 只按 link_id）：保守不发、提示失效
    const linkId: string | null = TradeJson.text(card, 'link_id');
    if (linkId === null) {
      this.toast(OpenPurchaseController.REF_EXPIRED_KEY);
      return;
    }
    this.click++;
    const installed: string = this.d.ports.installed(TradeJson.text(card, 'platform') ?? '');
    const attempt: PurchaseAttempt = new PurchaseAttempt(this.click, card, linkId,
      this.openBody(installed, noRebate, noRebateReason), key, noRebate, noRebateReason, installed, userAuthRetry);
    this.card = card;
    this.current = attempt;
    this.ready = null;
    this.resumeCard = null;
    // 新的点击先作废旧尝试的授权归属（共性第 20 条）：旧的授权查询 / 绑定之后返回一律丢弃
    this.authContext = null;
    this.resetAuthReturn();
    this.revokeAuthPermit();
    this.grantPermit(attempt);
    this.update((st: PurchaseState) => {
      st.platform = attempt.platform;
      st.card = card;
      st.latest = card;
      st.notInstalled = false;
      st.notInstalledCopied = false;
    });
    this.send(attempt);
  }

  private send(attempt: PurchaseAttempt): void {
    this.request++;
    const myRequest: number = this.request;
    this.interrupt = LateResponsePolicy.NONE;
    this.timedOut = false;
    this.cancelOwners();
    const owner: () => boolean = (): boolean => !this.left && this.current === attempt && myRequest === this.request;
    this.owners.push(owner);
    this.update((st: PurchaseState) => {
      st.phase = PurchasePhase.LOADING;
      st.dialog = null;
    });
    this.clearTimer();
    this.timer = this.d.timers.set(this.d.timeoutMillis, () => {
      this.timer = -1;
      if (this.current === attempt && myRequest === this.request && this.s.phase === PurchasePhase.LOADING) {
        this.keys.timeout();
        this.timedOut = true;
        this.update((st: PurchaseState) => {
          st.phase = PurchasePhase.TIMEOUT;
        });
      }
    });
    const path: Record<string, string> = {};
    path['link_id'] = attempt.linkId;
    const request: ApiRequest = new ApiRequest(TradeOperations.OPEN_LINK, path, '', attempt.body);
    request.idempotencyKey = attempt.key;
    request.owner = owner;
    tradeGuarded(this.d.api.request(request)).then((result: ApiResult) => {
      // 等待之后复核归属：离开、再次点击、重发之后的旧响应只丢弃
      if (this.left || this.current !== attempt || myRequest !== this.request) {
        return;
      }
      this.owners = this.owners.filter((o: () => boolean) => o !== owner);
      this.clearTimer();
      this.settle(result, attempt);
    });
  }

  private openBody(installed: string, noRebate: boolean, noRebateReason: string | null): string {
    const body: Record<string, Object> = {};
    body['installed'] = installed;
    if (noRebate) {
      body['no_rebate'] = true;
      if (noRebateReason !== null) {
        body['no_rebate_reason'] = noRebateReason;
      }
    }
    const spm: string | null = this.spm;
    if (spm !== null && spm.length > 0 && spm.length <= OpenPurchaseController.SPM_MAX) {
      body['spm'] = spm;
    }
    return JSON.stringify(body);
  }

  // ---------------------------------------------------------------- 响应

  private settle(result: ApiResult, attempt: PurchaseAttempt): void {
    const late: LateDecision =
      LateResponsePolicy.decide(this.timedOut ? LateResponsePolicy.CANCEL : this.interrupt);
    if (!late.jump || !this.permitted(attempt)) {
      // 取消、离开、后台、超时之后才到：只更新卡片（新价格、new_link_id、无返利状态），不外跳、不弹确认、不进登录 / 授权
      if (late.updateCard && result.outcome === ApiOutcome.SUCCESS) {
        this.patchCard(attempt, result.data);
      }
      if (this.s.phase === PurchasePhase.LOADING) {
        this.update((st: PurchaseState) => {
          st.phase = PurchasePhase.IDLE;
        });
      }
      return;
    }
    this.update((st: PurchaseState) => {
      st.phase = PurchasePhase.IDLE;
    });
    if (result.outcome === ApiOutcome.SUCCESS) {
      this.onSuccess(result, attempt);
    } else if (result.outcome === ApiOutcome.BUSINESS_ERROR) {
      this.onFailure(result, attempt);
    } else if (result.outcome === ApiOutcome.NETWORK_ERROR) {
      // 超时、断网、没有外壳：与 8 秒超时同样处理，【重试】重放原尝试
      this.timedOut = true;
      this.update((st: PurchaseState) => {
        st.phase = PurchasePhase.TIMEOUT;
      });
    } else {
      this.toast(result.effect?.textKey ?? OpenPurchaseController.GENERIC_KEY, null);
    }
  }

  private onSuccess(result: ApiResult, attempt: PurchaseAttempt): void {
    const data: Record<string, Object> = result.data;
    const envelope: Record<string, Object> = {};
    envelope['code'] = 0;
    envelope['data'] = data;
    // 判断基准是尝试的原卡快照：迟到响应更新过的展示卡片不能消除改价 / 返利归零的确认（共性第 1 条，BR-PRICE-13）
    const outcome: OpenResponseOutcome = OpenResponseAction.map(envelope, OpenPurchaseController.openContext(attempt.card));
    this.patchCard(attempt, data);
    const attemptId: string | null = TradeJson.text(data, 'attempt_id');
    const plan: Record<string, Object> | null = TradeJson.object(data, 'jump');
    if (attemptId === null || plan === null) {
      // 契约必填字段缺失：保守不外跳
      this.toast(OpenPurchaseController.GENERIC_KEY, result.traceId);
      return;
    }
    const jump: ReadyJump = new ReadyJump(plan, new PurchaseIdentity(attemptId, outcome.replaceLinkId ?? attempt.linkId),
      attempt);
    this.ready = jump;
    if (outcome.requoteNotice) {
      this.toast(OpenPurchaseController.REQUOTE_KEY);
    }
    if (outcome.actionRaw === OpenActions.OFF_SHELF) {
      this.toast(OpenPurchaseController.OFF_SHELF_KEY);
    } else if (outcome.actionRaw === OpenActions.CONFIRM_PRICE || outcome.actionRaw === OpenActions.CONFIRM_COUPON) {
      const dialog: PurchaseDialog = new PurchaseDialog(PurchaseDialogKind.CONFIRM_PRICE, attempt.platform);
      dialog.oldFen = outcome.oldFinalFen;
      dialog.newFen = outcome.newFinalFen;
      dialog.rebateGone = outcome.rebateGone;
      dialog.coupon = outcome.actionRaw === OpenActions.CONFIRM_COUPON;
      this.showDialog(dialog);
    } else if (outcome.actionRaw === OpenActions.CONFIRM_REBATE_GONE) {
      const dialog: PurchaseDialog = new PurchaseDialog(PurchaseDialogKind.CONFIRM_REBATE_GONE, attempt.platform);
      dialog.priceFen = outcome.newFinalFen ?? outcome.oldFinalFen;
      this.showDialog(dialog);
    } else if (outcome.actionRaw === OpenActions.COMPARE_NO_REBATE) {
      this.showDialog(new PurchaseDialog(PurchaseDialogKind.COMPARE_NO_REBATE, attempt.platform));
    } else {
      this.proceed(jump);
    }
  }

  private onFailure(failure: ApiResult, attempt: PurchaseAttempt): void {
    const platform: string = attempt.platform;
    const outcome: OpenErrorOutcome = OpenErrorAction.map(failure.code, failure.data);
    const trace: string | null = outcome.showTrace6 ? failure.traceId : null;
    switch (outcome.actionRaw) {
      case OpenErrorActions.LOGIN:
        // 1xxxx：登录后沿用原键重放（BR-ID-10 细则），登记 pending_action 后进登录页
        this.d.pending.register(OpenPurchaseController.pendingParams(attempt.card, attempt.linkId, attempt.key,
          OpenPurchaseController.PENDING_LOGIN, attempt.noRebate, attempt.noRebateReason));
        this.d.env.open(OpenPurchaseController.LOGIN_ROUTE, {});
        return;
      case OpenErrorActions.AUTH_SHEET:
      case OpenErrorActions.AUTH_JUMP:
        this.keys.authRequired(failure.code);
        this.authContext = new AuthContext(failure.code, attempt.linkId, failure.data, attempt);
        // 自动弹出每平台每会话最多 2 次（BR-ID-18）；用户在二选一里主动【重试】进来的不算自动弹出、不受限（共性第 10 条）
        if (attempt.userAuthRetry || this.d.counter.tryAutoPop(platform)) {
          this.d.pending.register(OpenPurchaseController.pendingParams(attempt.card, attempt.linkId, null,
            OpenPurchaseController.PENDING_AUTH, false, null));
          this.showDialog(new PurchaseDialog(PurchaseDialogKind.AUTH_SHEET, platform));
        } else {
          // 同一会话第 3 次起不再自动拉起授权，直接给二选一（BR-ID-18）
          this.d.pending.clear();
          this.showDialog(OpenPurchaseController.declined(platform, false));
        }
        return;
      case OpenErrorActions.NOTICE:
        if (failure.code === 30101 || failure.code === 30102) {
          const d: PurchaseDialog = new PurchaseDialog(PurchaseDialogKind.AUTH_UNAVAILABLE, platform);
          d.textKey = outcome.textKey;
          this.showDialog(d);
        } else if (failure.code === 50301) {
          // 点击结果确认的平台状态：按平台记下（卡片映射隐藏返利、按钮禁用），新配置到达即被覆盖（共性第 5、6 条）
          this.d.env.markPlatformStatus(platform, outcome.silent ? BuyBlock.NOT_LAUNCHED : BuyBlock.MAINTENANCE);
          if (!outcome.silent) {
            this.toast(outcome.textKey ?? OpenPurchaseController.MAINTENANCE_KEY, trace);
          }
        } else if (outcome.offerNoRebate || outcome.offerContact) {
          this.showDialog(OpenPurchaseController.notice(outcome.textKey, trace, outcome.offerNoRebate,
            outcome.offerContact, false, platform));
        } else {
          this.toast(outcome.textKey ?? OpenPurchaseController.GENERIC_KEY, trace);
        }
        return;
      case OpenErrorActions.ERROR:
        if (failure.code === 30141) {
          // 下架绑定这张卡（共性第 5 条）
          this.updateCard(attempt, (c: Record<string, Object>) => TradeJson.with(c, 'availability', BuyBlock.OFF_SHELF));
          this.toast(outcome.textKey ?? OpenPurchaseController.OFF_SHELF_KEY);
        } else if (failure.code === 50303) {
          this.showDialog(OpenPurchaseController.notice(outcome.textKey, failure.traceId, true, false, true, platform));
        } else {
          this.toast(outcome.textKey ?? OpenPurchaseController.GENERIC_KEY, failure.traceId);
        }
        return;
      case OpenErrorActions.RETRY_AFTER:
        this.startBlock(disableMillisOf(failure));
        this.toast(outcome.textKey ?? OpenPurchaseController.RATE_LIMITED_KEY);
        return;
      case OpenErrorActions.RESEARCH:
        this.toast(outcome.textKey ?? OpenPurchaseController.REF_EXPIRED_KEY);
        this.d.env.open(OpenPurchaseController.SEARCH_ROUTE, OpenPurchaseController.similarParams(this.latestCard(attempt)));
        return;
      case OpenErrorActions.REFETCH: {
        // 30144：按这张卡的 product_key + item_ref 重取（搜索卡与详情同样），替换后等用户再点（03 §4.2，共性第 9 条）
        this.toast(outcome.textKey ?? OpenPurchaseController.REF_EXPIRED_KEY);
        const target: Record<string, Object> = this.latestCard(attempt);
        this.d.env.refetchCard(target, CardPatch.reload(CardPatch.revision(target)));
        return;
      }
      case OpenErrorActions.FORCE_UPDATE:
        return;
      default:
        this.toast(outcome.textKey ?? OpenPurchaseController.GENERIC_KEY, trace);
    }
  }

  /** open 上下文：base 卡片的价格与返利上限（OpenResponseAction 判返利归零用）。 */
  static openContext(base: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    const price: number | null = TradeJson.fen(base, 'final_price_fen');
    const max: number | null = TradeJson.fen(base, 'rebate_max_fen');
    if (price !== null) {
      out['currentPriceFen'] = price;
    }
    if (max !== null) {
      out['currentRebateMaxFen'] = max;
    }
    if (TradeJson.text(base, 'rebate_basis') === 'amount_unknown') {
      out['amountUnknown'] = true;
    }
    return out;
  }

  /** 尝试那张卡的最新展示版本。 */
  private latestCard(attempt: PurchaseAttempt): Record<string, Object> {
    return CardPatch.sameCard(this.card, attempt.card) ? this.card : attempt.card;
  }

  /**
   * 用响应更新卡片（BR-PRICE-12：无论确认还是取消）；价格 / 返利字段给不全时重取权威卡片（共性第 7、8、17 条）。
   * 补齐世代只在真正发起新补齐时前进（H-R2-03，共性第 33 条）：同键重放得到相同结果（写入后卡片不变）不作废进行中的补齐；
   * 不同的购买结果（写入后卡片变了）一律作废旧补齐，仍有未知字段就为它重新发起补齐（旧响应不填新结果，共性第 26 条）。
   */
  private patchCard(attempt: PurchaseAttempt, data: Record<string, Object>): void {
    const before: Record<string, Object> = this.latestCard(attempt);
    this.cardBeforeResponse = attempt.card;
    const applied: Record<string, Object> = CardPatch.apply(before, data);
    const unchanged: boolean = CardPatch.sameResult(before, applied);
    const refetch: boolean = !unchanged && (CardPatch.needsRefetch(before, data) || CardPatch.awaitingFill(applied));
    if (!refetch) {
      // 不发补齐：卡片上的补齐世代原样保留（相同结果的重放不作废进行中的补齐）；不同结果仍作废旧补齐
      const keep = (c: Record<string, Object>): Record<string, Object> => unchanged ? CardPatch.apply(c, data)
        : TradeJson.with(CardPatch.apply(c, data), CardPatch.FILL_GENERATION, OpenPurchaseController.nextFillGeneration());
      this.updateCard(attempt, keep);
      return;
    }
    const generation: number = OpenPurchaseController.nextFillGeneration();
    const write = (c: Record<string, Object>): Record<string, Object> =>
    TradeJson.with(CardPatch.apply(c, data), CardPatch.FILL_GENERATION, generation);
    const after: Record<string, Object> = CardPatch.bump(write(before));
    this.updateCard(attempt, write);
    const fill: (current: Record<string, Object>, fresh: Record<string, Object>) => Record<string, Object> =
      CardPatch.fillFor(generation);
    this.d.env.refetchCard(after, (current: Record<string, Object>, fresh: Record<string, Object>) => {
      const merged: Record<string, Object> = fill(current, fresh);
      this.noteLatest(attempt, merged);
      return merged;
    });
  }

  private static nextFillGeneration(): number {
    OpenPurchaseController.fillSeq++;
    return OpenPurchaseController.fillSeq;
  }

  /** 补齐落到页面上的结果：仍是当前尝试的那张卡就同步给界面（确认框的价格口径词随之更新）。 */
  private noteLatest(attempt: PurchaseAttempt, card: Record<string, Object>): void {
    if (this.left || this.current !== attempt || !CardPatch.sameCard(card, attempt.card)) {
      return;
    }
    if (CardPatch.sameCard(this.card, attempt.card)) {
      this.card = card;
    }
    this.update((st: PurchaseState) => {
      st.latest = card;
    });
  }

  /** 写入购买结果（open 响应、30141 下架）：卡片版本加 1，之前发出的重新加载结果到达时认出卡片已更新、不覆盖。 */
  private updateCard(attempt: PurchaseAttempt, transform: (c: Record<string, Object>) => Record<string, Object>): void {
    const versioned = (c: Record<string, Object>): Record<string, Object> => CardPatch.bump(transform(c));
    if (CardPatch.sameCard(this.card, attempt.card)) {
      this.card = versioned(this.card);
      if (this.current === attempt) {
        const latest: Record<string, Object> = this.card;
        this.update((st: PurchaseState) => {
          st.latest = latest;
        });
      }
    }
    this.d.env.updateCard(attempt.card, versioned);
  }

  // ---------------------------------------------------------------- 确认与外跳

  /** 弹层的主按钮：改价 / 返利归零 / 券失效【继续购买】、比价【仍去购买（无返利）】、JumpTip【知道了，去X】。用户这一下重新发许可。 */
  confirm(): void {
    const dialog: PurchaseDialog | null = this.s.dialog;
    if (dialog === null) {
      return;
    }
    const jump: ReadyJump | null = this.ready;
    if (dialog.beforeOpen) {
      // 补同意后重开、与原基准不一致：用户确认了此刻的价格 / 返利，按此刻的卡发一次 open（新键；仍先复核平台购买状态）
      this.hideDialog();
      const target: Record<string, Object> | null = this.resumeCard;
      this.resumeCard = null;
      if (target !== null && !this.left && this.purchasable(target)) {
        this.startClick(target, this.keys.start(), false, null, false);
      }
      return;
    }
    if (dialog.kind === PurchaseDialogKind.CONFIRM_PRICE || dialog.kind === PurchaseDialogKind.CONFIRM_REBATE_GONE
      || dialog.kind === PurchaseDialogKind.COMPARE_NO_REBATE) {
      this.hideDialog();
      if (jump !== null && jump.attempt === this.current && this.purchasable(this.latestCard(jump.attempt))) {
        this.grantPermit(jump.attempt);
        this.proceed(jump);
      } else {
        this.ready = null;
      }
    } else if (dialog.kind === PurchaseDialogKind.JUMP_TIP) {
      this.hideDialog();
      this.d.tips.markRead(dialog.platform, this.owner()).catch((): void => {
      });
      if (jump !== null && jump.attempt === this.current && this.purchasable(this.latestCard(jump.attempt))) {
        this.grantPermit(jump.attempt);
        this.execute(jump);
      } else {
        this.ready = null;
      }
    } else {
      this.hideDialog();
    }
  }

  /** 弹层的取消 / 关闭（按钮、遮罩、返回键都一样）。 */
  dismissDialog(): void {
    const dialog: PurchaseDialog | null = this.s.dialog;
    if (dialog === null) {
      return;
    }
    if (dialog.kind === PurchaseDialogKind.CONFIRM_PRICE) {
      this.hideDialog();
      this.toast(dialog.rebateGone ? OpenPurchaseController.CANCELLED_PRICE_REBATE_KEY
        : OpenPurchaseController.CANCELLED_PRICE_KEY);
    } else if (dialog.kind === PurchaseDialogKind.CONFIRM_REBATE_GONE
      || dialog.kind === PurchaseDialogKind.COMPARE_NO_REBATE) {
      this.hideDialog();
      this.toast(OpenPurchaseController.CANCELLED_REBATE_KEY);
    } else if (dialog.kind === PurchaseDialogKind.AUTH_SHEET) {
      // 用户关闭授权：删除待办，给二选一（BR-ID-18）
      if (dialog.busy) {
        return;
      }
      this.d.pending.clear();
      this.showDialog(OpenPurchaseController.declined(dialog.platform, false));
    } else if (dialog.kind === PurchaseDialogKind.AUTH_CHECK_FAILED) {
      // 放弃本次：删除待办（之后授权了也不自动执行）
      this.hideDialog();
      this.d.pending.clear();
      this.authContext = null;
    } else {
      this.hideDialog();
    }
    this.ready = null;
    this.resumeCard = null;
    this.revokePermit();
  }

  private proceed(jump: ReadyJump): void {
    const granted: Permit | null = this.permit !== null && this.permit.attempt === jump.attempt ? this.permit : null;
    if (granted === null) {
      return;
    }
    if (!this.d.env.loggedIn()) {
      this.execute(jump);
      return;
    }
    this.d.tips.shouldShow(jump.attempt.platform, this.owner()).then((show: boolean) => {
      // 等待之后复核许可：期间进入后台、被覆盖、离开、再点了别的都不再继续（共性第 3 条）
      if (!this.allowed(granted) || this.ready !== jump) {
        return;
      }
      // 等下单须知期间平台关闭 / 维护、商品下架：停止续执行（H-R2-02，共性第 32 条）；按钮随配置与卡片状态置灰
      if (!this.purchasable(this.latestCard(jump.attempt))) {
        this.ready = null;
        return;
      }
      if (show) {
        this.showDialog(new PurchaseDialog(PurchaseDialogKind.JUMP_TIP, jump.attempt.platform));
      } else {
        this.execute(jump);
      }
    }).catch((): void => {
    });
  }

  private execute(jump: ReadyJump): void {
    const granted: Permit | null = this.permit !== null && this.permit.attempt === jump.attempt ? this.permit : null;
    if (granted === null || !this.allowed(granted)) {
      return;
    }
    this.ready = null;
    // 最终外跳前统一复核最新平台购买状态与商品可购状态（H-R2-02，共性第 32 条）：须知、浏览器提示等异步等待之后的路径都经这里
    if (!this.purchasable(this.latestCard(jump.attempt))) {
      return;
    }
    // 执行器两种许可分开（H-R3-02，共性第 40 条）：「允许开始下一步」每个新步骤前（含 scheme 等系统返回、浏览器提示停留之后）
    // 复核续执行许可 + 最新平台购买状态与商品可购状态；「允许上报已执行步骤」只看尝试与取消许可，已执行的步骤照常上报
    this.d.executor.execute(jump.plan, jump.attempt.platform, jump.attempt.installed, jump.identity,
      (): boolean => this.continuable(granted), (): Promise<boolean> => this.confirmBrowser(granted),
      (): boolean => this.allowed(granted))
      .then((outcome: JumpOutcome) => {
        if (!this.left) {
          this.afterJump(jump, outcome);
        }
      });
  }

  private confirmBrowser(granted: Permit): Promise<boolean> {
    if (!this.allowed(granted)) {
      return Promise.resolve(false);
    }
    return new Promise<boolean>((resolve: (ok: boolean) => void) => {
      const finish = (ok: boolean): void => {
        if (this.browserResolve === null) {
          return;
        }
        this.browserResolve = null;
        if (this.browserTimer !== -1) {
          this.d.timers.clear(this.browserTimer);
          this.browserTimer = -1;
        }
        this.update((st: PurchaseState) => {
          st.browserNotice = false;
        });
        resolve(ok && this.continuable(granted));
      };
      this.browserResolve = finish;
      this.update((st: PurchaseState) => {
        st.browserNotice = true;
      });
      this.browserTimer = this.d.timers.set(this.d.browserNoticeMillis, () => {
        this.browserTimer = -1;
        finish(true);
      });
    });
  }

  /** 「将通过浏览器打开」的【取消】。 */
  cancelBrowser(): void {
    const r: ((ok: boolean) => void) | null = this.browserResolve;
    if (r !== null) {
      r(false);
    }
  }

  private afterJump(jump: ReadyJump, outcome: JumpOutcome): void {
    if (outcome.cancelled || outcome.stopped) {
      return;
    }
    if (outcome.expired) {
      // 方案过了 expire_at：不外跳，提示重新点购买取新方案（共性第 12 条）
      this.toast(OpenPurchaseController.JUMP_EXPIRED_KEY);
      return;
    }
    const final: string = outcome.run.final;
    if (final === JumpTypes.FINAL_OPENED) {
      return;
    }
    if (final === JumpTypes.FINAL_BROWSER) {
      // ProductJumpHarmonyH5：鸿蒙淘宝只能降级到网页时提示可能影响返利跟踪（仅鸿蒙；文案草稿，TODO(N-28)）
      if (jump.attempt.platform === 'taobao') {
        this.toast(OpenPurchaseController.HARMONY_H5_KEY);
      }
      return;
    }
    if (final === JumpTypes.FINAL_COPIED) {
      this.toast(OpenPurchaseController.COPIED_KEY);
      return;
    }
    if (final === JumpTypes.FINAL_NOT_INSTALLED) {
      this.update((st: PurchaseState) => {
        st.notInstalled = true;
        st.notInstalledCopied = true;
      });
      this.toast(OpenPurchaseController.COPIED_KEY);
      return;
    }
    let onlySdk: boolean = outcome.run.executed.length > 0;
    for (const t of outcome.run.executed) {
      if (t !== JumpTypes.SDK) {
        onlySdk = false;
      }
    }
    if (outcome.sdkUnavailable && onlySdk) {
      // 淘宝 sdk 步骤不可用且没有可执行的后续步骤：提示、不外跳（BR-ATTR-27 淘宝行）
      this.showDialog(new PurchaseDialog(PurchaseDialogKind.SDK_FAILED, jump.attempt.platform));
    } else if (jump.attempt.installed === InstalledState.FALSE) {
      // 明确未安装（installed=false）、全部路径失败：安装提示（BR-ATTR-27 ②）；unknown 的失败不能当未安装（共性第 13 条）
      this.update((st: PurchaseState) => {
        st.notInstalled = true;
      });
    } else {
      // 通用跳转失败，按钮照常可再点
      this.toast(OpenPurchaseController.JUMP_FAILED_KEY);
    }
  }

  // ---------------------------------------------------------------- 授权

  /** AuthSheet【去授权】。 */
  authorize(): void {
    const context: AuthContext | null = this.authContext;
    const dialog: PurchaseDialog | null = this.s.dialog;
    if (context === null || dialog === null || dialog.kind !== PurchaseDialogKind.AUTH_SHEET || dialog.busy) {
      return;
    }
    if (!this.foreground) {
      return;
    }
    this.showDialog(dialog.copyBusy(true));
    // 用户这一下发授权外跳许可（共性第 25 条）：进入后台、被覆盖、离开、新点击即作废；每一步外跳前复核
    this.revokeAuthPermit();
    const permit: AuthPermit = new AuthPermit(context);
    this.authPermit = permit;
    this.resetAuthReturn();
    const authJump: Record<string, Object> | null = TradeJson.object(context.data, 'auth_jump');
    if (authJump !== null) {
      // 拼多多：同一执行器执行 auth_jump（不上报 link_jump，不算购买外跳；h5 步骤交系统浏览器）。发起前就登记「外跳在途」：
      // 拉起的 Promise 可能晚于回前台通知完成（H-R2-05，共性第 38 条）
      this.authJumpInFlight = true;
      this.d.executor.execute(authJump, context.platform, this.d.ports.installed(context.platform), null,
        (): boolean => this.authJumpAllowed(permit)).then((outcome: JumpOutcome) => {
        // 授权回流（回前台后查询）的归属与外跳许可分开：这里只看授权上下文仍是本次
        if (!this.authLive(context)) {
          return;
        }
        this.authJumpInFlight = false;
        const launched: boolean = outcome.run.final === JumpTypes.FINAL_OPENED
          || outcome.run.final === JumpTypes.FINAL_BROWSER;
        if (launched || outcome.stopped) {
          // 已拉起授权页，或期间进入后台 / 被覆盖（含 H14 系统弹出应用市场）而停在半路、不再执行下一步：回到前台后由服务端确认
          // 是否已授权（onForeground → listUnionBindings；查不到授权按「没完成就回来」给二选一，BR-ID-22 细则）
          this.hideDialog();
          this.awaitReturn(context, false, !launched || this.authLeftApp);
        } else {
          this.authFailed(context.platform);
        }
      });
      return;
    }
    const flow: TaobaoAuthFlow = this.taobaoFlow(context, permit);
    if (flow.pick(context.platform, context.data) === null) {
      // 本端执行不了下发的任何授权方式（web_code 回跳未登记、百川不可用，TODO(N-28)）：按授权失败（BR-ID-17、BR-ID-18）
      this.authFailed(context.platform);
      return;
    }
    // 含 30104 按 reason 的恢复：重新取授权上下文、换方式、新凭证与新幂等键（共性第 18 条）
    flow.run(context.platform, context.data).then((outcome: TaobaoAuthOutcome) => {
      if (!this.authLive(context)) {
        return;
      }
      if (outcome.kind === TaobaoAuthOutcome.BOUND) {
        this.authorized(context);
      } else if (outcome.kind === TaobaoAuthOutcome.CANCELLED) {
        this.d.pending.clear();
        this.showDialog(OpenPurchaseController.declined(context.platform, false));
      } else if (outcome.kind === TaobaoAuthOutcome.FAILED) {
        this.authFailed(context.platform);
      } else if (outcome.kind === TaobaoAuthOutcome.REQUEST_FAILED && outcome.result !== null) {
        this.bindFailed(context, outcome.result);
      } else if (outcome.kind === TaobaoAuthOutcome.INTERRUPTED) {
        // 30104 恢复后要再次拉起时，用户点击发出的许可已撤销（进过后台 / 被覆盖，共性第 31 条）：不再自动拉起；回到前台后向服务端
        // 查询授权状态，已授权自动 open 一次，没授权删除待办给二选一（共性第 39 条）
        this.hideDialog();
        this.awaitReturn(context, true, true);
      } else if (outcome.kind === TaobaoAuthOutcome.ABANDONED) {
        // 要拉起授权时不在前台：不外跳，AuthSheet 回到可点状态，等用户在前台再点【去授权】
        const d: PurchaseDialog | null = this.s.dialog;
        if (d !== null && d.kind === PurchaseDialogKind.AUTH_SHEET && d.busy) {
          this.showDialog(d.copyBusy(false));
        }
      }
    });
  }

  /** 授权上下文仍是本次（当前尝试、没被新点击或放弃作废）：每次等待之后、消费之前都核对（共性第 20 条）。 */
  private authLive(context: AuthContext): boolean {
    return !this.left && this.authContext === context && this.current === context.attempt;
  }

  /**
   * 授权外跳之后等回流（H-R2-05，共性第 38 条）：returned = 已经离开过 App 又回到前台（或停在半路）——此刻在前台就立即查询；
   * 否则等 onForeground。sheet：30104 恢复被撤销的回流（只随查询失败的重试透传；查到未授权同样给二选一，共性第 39 条）。
   */
  private awaitReturn(context: AuthContext, sheet: boolean, returned: boolean): void {
    this.authJumpInFlight = false;
    this.authReturnSheet = sheet;
    if (returned && this.foreground) {
      this.awaitingAuthReturn = false;
      this.authLeftApp = false;
      this.queryBindings(context, false, sheet);
    } else {
      this.awaitingAuthReturn = true;
    }
  }

  private resetAuthReturn(): void {
    this.awaitingAuthReturn = false;
    this.authJumpInFlight = false;
    this.authLeftApp = false;
    this.authReturnSheet = false;
  }

  /** 授权外跳此刻可以继续：许可仍有效、授权上下文仍是本次、页面在前台（共性第 25 条，H14）。 */
  private authJumpAllowed(permit: AuthPermit): boolean {
    return permit.valid && this.authPermit === permit && this.authLive(permit.context) && this.foreground;
  }

  private revokeAuthPermit(): void {
    if (this.authPermit !== null) {
      this.authPermit.valid = false;
    }
    this.authPermit = null;
  }

  private taobaoFlow(context: AuthContext, permit: AuthPermit): TaobaoAuthFlow {
    // 每次拉起授权（含 30104 恢复后的再次授权）之前：用户点【去授权】发出的许可仍有效（进过后台即撤销，回前台不恢复）、页面在前台、
    // 授权上下文仍是本次（共性第 25、31 条，H-R2-01）
    return new TaobaoAuthFlow(this.d.api, this.d.webCode, this.d.baichuan, this.d.keyGenerator,
      (): (() => boolean) => this.ownerFor(context), (): boolean => this.authLive(context),
      (platform: string): string => this.d.ports.installed(platform),
      (): boolean => this.authJumpAllowed(permit));
  }

  /** 淘宝绑定（或 30104 后重新取授权地址）没有拿到结果：按码处理，限流、服务端故障不当成用户没授权（共性第 19 条）。 */
  private bindFailed(context: AuthContext, result: ApiResult): void {
    const business: boolean = result.outcome === ApiOutcome.BUSINESS_ERROR;
    if (business && (result.code === 30151 || result.code === 30153)) {
      this.d.pending.clear();
      const o: OpenErrorOutcome = OpenErrorAction.map(result.code, result.data);
      this.showDialog(OpenPurchaseController.notice(o.textKey, null, true, true, false, context.platform));
      return;
    }
    if (business && (result.code === 30101 || result.code === 30102)
      && TradeJson.text(result.data, 'reason') === 'auth_unavailable') {
      this.d.pending.clear();
      const d: PurchaseDialog = new PurchaseDialog(PurchaseDialogKind.AUTH_UNAVAILABLE, context.platform);
      d.textKey = OpenErrorAction.map(result.code, result.data).textKey;
      this.showDialog(d);
      return;
    }
    this.authCheckFailed(context, result, true, false);
  }

  /**
   * 授权状态查询 / 绑定请求失败（共性第 19 条）：42901 按 Retry-After（缺省 5 秒）禁用；5xxxx 显示对应错误与 trace6；传输失败显示网络错误。
   * 都不清待办、不当成用户取消授权，给【重试】重新查询。业务码不是这几类的（3xxxx 等）按授权失败。
   */
  private authCheckFailed(context: AuthContext, result: ApiResult, afterBind: boolean, sheet: boolean): void {
    const business: boolean = result.outcome === ApiOutcome.BUSINESS_ERROR;
    const millis: number = disableMillisOf(result);
    if (millis > 0) {
      this.startBlock(millis);
    }
    const serverError: boolean = business && result.code >= 50000 && result.code <= 59999;
    if (business && result.code !== 42901 && !serverError) {
      this.authFailed(context.platform);
      return;
    }
    const d: PurchaseDialog = new PurchaseDialog(PurchaseDialogKind.AUTH_CHECK_FAILED, context.platform);
    d.textKey = business ? (OpenErrorAction.map(result.code, result.data).textKey ?? OpenPurchaseController.GENERIC_KEY)
      : OpenPurchaseController.NETWORK_KEY;
    d.traceId = serverError ? result.traceId : null;
    d.afterBind = afterBind;
    d.resheet = sheet;
    this.authContext = context;
    this.showDialog(d);
  }

  /** 授权结果查不到时的【重试】：重新查询授权状态（listUnionBindings）；42901 禁用期间执行层直接拦下。 */
  recheckAuth(): void {
    const dialog: PurchaseDialog | null = this.s.dialog;
    const context: AuthContext | null = this.authContext;
    if (dialog === null || dialog.kind !== PurchaseDialogKind.AUTH_CHECK_FAILED || context === null
      || !this.authLive(context) || this.blocked()) {
      return;
    }
    this.hideDialog();
    this.queryBindings(context, dialog.afterBind, dialog.resheet);
  }

  /**
   * 查询授权状态（listUnionBindings）：查询成功且该平台 active → 自动执行一次 open（新键）；查询成功但没有授权 → 删除待办，给二选一
   * （拼多多回来 / 30104 恢复被撤销后回前台：未完成授权；淘宝绑定之后：授权失败；H-R3-01，共性第 39 条）；
   * 请求失败 → authCheckFailed（共性第 19 条，保留待办、独立重试；sheet 只随重试透传）。
   */
  private queryBindings(context: AuthContext, afterBind: boolean, sheet: boolean = false): void {
    const request: ApiRequest = new ApiRequest(TradeOperations.LIST_UNION_BINDINGS);
    request.owner = this.ownerFor(context);
    tradeGuarded(this.d.api.request(request)).then((result: ApiResult) => {
      // 旧尝试的查询（期间又点了购买、放弃了授权）只丢弃：不清待办、不关新尝试的弹窗（共性第 20 条）
      if (!this.authLive(context)) {
        return;
      }
      if (result.outcome !== ApiOutcome.SUCCESS) {
        this.authCheckFailed(context, result, afterBind, sheet);
        return;
      }
      let active: boolean = false;
      for (const row of TradeJson.objects(result.data, 'items')) {
        if (TradeJson.text(row, 'platform') === context.platform && TradeJson.text(row, 'status') === 'active') {
          active = true;
        }
      }
      // 查询成功：只有确认 active 才以新键自动 open 一次；没有授权（含 30104 恢复被撤销 / INTERRUPTED 后回前台查得 unbound，
      // H-R3-01，共性第 39 条）一律删除本次待办、给【仍去购买（无返利）】【重试】二选一（BR-ID-18/22），不再交还 AuthSheet
      if (active) {
        this.authorized(context);
      } else if (afterBind) {
        this.authFailed(context.platform);
      } else {
        this.d.pending.clear();
        this.showDialog(OpenPurchaseController.declined(context.platform, false));
      }
    });
  }

  /** 授权完成：前置完成即自动执行一次 open，用新键（BR-ID-10 / 22 细则）；待办已过期（> 10 分钟）就不执行，等用户再点。 */
  private authorized(context: AuthContext): void {
    if (!this.authLive(context)) {
      return;
    }
    this.d.pending.stepDone();
    const record: Record<string, Object> | null = this.d.pending.peek();
    this.d.pending.clear();
    this.hideDialog();
    this.authContext = null;
    const target: Record<string, Object> = this.latestCard(context.attempt);
    if (record === null || TradeJson.text(record, 'link_id') !== context.linkId
      || TradeJson.text(target, 'link_id') !== context.linkId) {
      return;
    }
    const attempt: PurchaseAttempt = context.attempt;
    this.whenForeground(() => {
      // 延迟到回前台才执行：仍是那次尝试、没有别的弹层或加载才执行一次（共性第 20 条）；发 open 前复核平台购买状态（共性第 27 条）
      if (this.left || this.current !== attempt || this.busy() || !this.purchasable(this.latestCard(attempt))) {
        return;
      }
      this.startClick(target, this.keys.resendAfterAuth(), false, null, false);
    });
  }

  private authFailed(platform: string): void {
    this.d.pending.clear();
    this.showDialog(OpenPurchaseController.declined(platform, true));
  }

  /** 二选一的【重试】、50303 的【重试】：一次新的点击（新键）；二选一里的【重试】是用户主动授权，不受自动弹出次数限制（共性第 10 条）。 */
  retryPurchase(): void {
    const dialog: PurchaseDialog | null = this.s.dialog;
    this.hideDialog();
    this.authContext = null;
    const attempt: PurchaseAttempt | null = this.current;
    this.buyWith(attempt !== null ? this.latestCard(attempt) : this.card, this.spm,
      dialog !== null && dialog.kind === PurchaseDialogKind.AUTH_DECLINED);
  }

  /** 【仍去购买（无返利）】：no_rebate=true 的新请求（BR-ID-18、BR-PRICE-08）。 */
  buyWithoutRebate(): void {
    const dialog: PurchaseDialog | null = this.s.dialog;
    this.hideDialog();
    let reason: string | null = null;
    if (dialog !== null && dialog.kind === PurchaseDialogKind.AUTH_DECLINED) {
      reason = dialog.failed ? OpenPurchaseController.NO_REBATE_AUTH_FAILED : OpenPurchaseController.NO_REBATE_AUTH_DECLINED;
    }
    this.authContext = null;
    if (this.left || this.busy() || this.blocked()) {
      return;
    }
    const attempt: PurchaseAttempt | null = this.current;
    const target: Record<string, Object> = attempt !== null ? this.latestCard(attempt) : this.card;
    // 无返利购买同样先复核平台购买状态与商品可购状态（共性第 27 条）
    if (!this.purchasable(target)) {
      return;
    }
    this.startClick(target, this.keys.start(), true, reason, false);
  }

  /** 【联系客服】：统一客服出口未接入前经 Router 打开帮助中心（TODO(N-28)）。 */
  contactService(): void {
    this.hideDialog();
    this.d.env.open(OpenPurchaseController.HELP_ROUTE, {});
  }

  /**
   * 【看看相似商品】：同平台、原样标题打开搜索（BR-PRICE-08）。product 是入口所在的那张卡（详情首次进入、没点过购买也有，共性第 15 条）；
   * 比价弹窗里不给时用本次购买的卡。
   */
  similar(product: Record<string, Object> | null = null): void {
    this.hideDialog();
    this.d.env.open(OpenPurchaseController.SEARCH_ROUTE, OpenPurchaseController.similarParams(product ?? this.card));
  }

  /** 比价说明【查看说明】：/v1/config.help_links.price_compare（没有配置不显示入口）。 */
  viewExplanation(): void {
    const link: HelpLink | null = this.d.env.helpLink(OpenPurchaseController.HELP_PRICE_COMPARE);
    if (link !== null) {
      this.d.env.open(link.route, link.params);
    }
  }

  /** 比价说明入口是否可见。 */
  get explanationAvailable(): boolean {
    return this.d.env.helpLink(OpenPurchaseController.HELP_PRICE_COMPARE) !== null;
  }

  // ---------------------------------------------------------------- 登录 / 同意恢复、生命周期

  /**
   * 登录完成后（页面回到前台、会话已登录时调）：本页登记的购买待办仍有效 → 删除并自动重放一次原尝试（原路径、原请求体、原键：10001 不写
   * 幂等记录，BR-ID-10 细则）。页面不在前台时等回到前台再执行。
   */
  resumeAfterLogin(): void {
    if (this.left) {
      return;
    }
    if (!this.foreground) {
      this.deferred = (): void => this.resumeAfterLogin();
      return;
    }
    if (this.busy() || !this.d.env.loggedIn()) {
      return;
    }
    const record: Record<string, Object> | null = this.d.pending.peek();
    const attempt: PurchaseAttempt | null = this.current;
    if (record === null || attempt === null) {
      return;
    }
    if (TradeJson.text(record, 'kind') !== OpenPurchaseController.PENDING_LOGIN
      || TradeJson.text(record, 'link_id') !== attempt.linkId
      || TradeJson.text(record, 'idempotency_key') !== attempt.key) {
      return;
    }
    this.d.pending.clear();
    // 重放前复核平台购买状态与商品可购状态（共性第 27 条）：不可买就只删除待办，不发
    if (!this.purchasable(this.latestCard(attempt))) {
      return;
    }
    this.click++;
    const replay: PurchaseAttempt = attempt.replay(this.click);
    this.current = replay;
    this.ready = null;
    this.grantPermit(replay);
    this.send(replay);
  }

  /**
   * 补同意完成（隐私变为已同意时调）：本页登记的购买待办仍有效 → 删除并按那张卡执行一次购买（还没发过请求，新键）；不在前台时等回到前台。
   * 仍不同意时 Router 删除待办，这里什么都不做（BR-ID-11、03 §4.1）。
   */
  resumeAfterConsent(): void {
    if (this.left) {
      return;
    }
    if (!this.foreground) {
      this.deferred = (): void => this.resumeAfterConsent();
      return;
    }
    const target: Record<string, Object> | null = this.consentCard;
    const record: Record<string, Object> | null = this.d.pending.peek();
    if (target === null || record === null) {
      return;
    }
    if (TradeJson.text(record, 'kind') !== OpenPurchaseController.PENDING_CONSENT
      || TradeJson.text(record, 'link_id') !== TradeJson.text(target, 'link_id')) {
      return;
    }
    this.d.pending.clear();
    this.consentCard = null;
    if (this.d.env.basicMode()) {
      return;
    }
    this.buy(target, this.consentSpm);
  }

  /**
   * 补同意清栈后重开的详情取到了商品（config.onProduct → resumeConsentHook，H01）：按原点击的购买意图恢复一次（H-R1-01，共性第 24 条）。
   * - 重开取到的卡只用于展示与比对；判断基准是原点击时的卡快照（resume.card）；
   * - 与原基准一致（券后价相同、返利没有由正变 0）：按原 link_id、原基准发一次 open（新键：之前没发过请求），服务端按原报价复核，
   *   改价 / 返利归零照常先确认；
   * - 不一致：先弹改价（含返利归零）/ 返利归零 / 比价无返利确认（beforeOpen），不发请求；用户【继续购买】才按此刻的卡发 open；
   * - 平台不可买、商品下架、仍是基本模式、页面正忙：不执行（共性第 27 条）。
   */
  resumeConsent(resume: ConsentResume, product: Record<string, Object>): void {
    if (this.left || this.busy() || this.d.env.basicMode()) {
      return;
    }
    if (resume.productKey.length === 0 || TradeJson.text(product, 'product_key') !== resume.productKey
      || TradeJson.text(resume.card, 'link_id') !== resume.linkId) {
      return;
    }
    if (!this.purchasable(product) || this.blocked()) {
      return;
    }
    const base: Record<string, Object> = resume.card;
    this.spm = resume.spm;
    const amountUnknown: boolean = TradeJson.text(base, 'rebate_basis') === 'amount_unknown';
    const thenPrice: number | null = TradeJson.fen(base, 'final_price_fen');
    const nowPrice: number | null = TradeJson.fen(product, 'final_price_fen');
    const thenRebate: number | null = TradeJson.fen(base, 'rebate_max_fen');
    const nowRebate: number | null = TradeJson.fen(product, 'rebate_max_fen');
    const priceChanged: boolean = !amountUnknown && (thenPrice === null || nowPrice === null || thenPrice !== nowPrice);
    const rebateGone: boolean = !amountUnknown && thenRebate !== null && thenRebate > 0 && nowRebate === 0;
    if (!priceChanged && !rebateGone) {
      this.startClick(base, this.keys.start(), false, null, false);
      // 页面上展示的是重开取到的卡：之后的 open 结果写到它上面（同一件商品）
      this.card = product;
      return;
    }
    if (thenPrice === null || nowPrice === null) {
      // 价格未知、无从比对：不自动购买，等用户自己再点（保守）
      return;
    }
    this.resumeCard = product;
    this.ready = null;
    this.card = product;
    this.cardBeforeResponse = base;
    const platform: string = TradeJson.text(product, 'platform') ?? '';
    this.update((st: PurchaseState) => {
      st.platform = platform;
      st.card = base;
      st.latest = product;
      st.notInstalled = false;
      st.notInstalledCopied = false;
    });
    let dialog: PurchaseDialog;
    if (priceChanged) {
      dialog = new PurchaseDialog(PurchaseDialogKind.CONFIRM_PRICE, platform);
      dialog.oldFen = thenPrice;
      dialog.newFen = nowPrice;
      dialog.rebateGone = rebateGone;
    } else if (TradeJson.text(product, 'no_rebate_cause') === 'price_compare') {
      dialog = new PurchaseDialog(PurchaseDialogKind.COMPARE_NO_REBATE, platform);
    } else {
      dialog = new PurchaseDialog(PurchaseDialogKind.CONFIRM_REBATE_GONE, platform);
      dialog.priceFen = nowPrice;
    }
    dialog.beforeOpen = true;
    this.showDialog(dialog);
  }

  /**
   * 详情页 config.onProduct 的处理（H01、H-R1-01）：取走 App 记下的补同意意图（一次性、商品对得上），页面允许购买时交 resumeConsent。
   */
  static resumeConsentHook(controller: OpenPurchaseController, productKey: string,
    take: (productKey: string) => ConsentResume | null,
    buyAllowed: () => boolean): (product: Record<string, Object>) => void {
    return (product: Record<string, Object>): void => {
      const resume: ConsentResume | null = take(productKey);
      if (resume !== null && buyAllowed()) {
        controller.resumeConsent(resume, product);
      }
    };
  }

  /**
   * 回到前台（发起页 onShown、App 回前台）：先执行等前台的自动动作；拼多多授权跳转之后由服务端确认（listUnionBindings）：确认已授权 →
   * 自动执行一次 open（新键）；查询成功但未授权 → 删除待办，给二选一（BR-ID-22 细则）；查询失败 → AUTH_CHECK_FAILED（共性第 19 条）。
   */
  onForeground(): void {
    if (this.left) {
      return;
    }
    this.foreground = true;
    const deferred: (() => void) | null = this.deferred;
    if (deferred !== null) {
      this.deferred = null;
      deferred();
    }
    if (!this.awaitingAuthReturn) {
      // 授权外跳的完成回调还没到（拉起的 Promise 晚于回前台通知）：由完成回调按 authLeftApp 立即补查（H-R2-05）
      return;
    }
    this.awaitingAuthReturn = false;
    this.authLeftApp = false;
    const sheet: boolean = this.authReturnSheet;
    this.authReturnSheet = false;
    const context: AuthContext | null = this.authContext;
    if (context !== null && this.authLive(context)) {
      this.queryBindings(context, false, sheet);
    }
  }

  /** 发起页被盖住或 App 进入后台：作废续执行许可；在途响应之后只更新卡片（03 §4.5，共性第 3 条）。 */
  onBackground(): void {
    this.foreground = false;
    if (this.authJumpInFlight) {
      this.authLeftApp = true;
    }
    this.revokePermit();
    this.revokeAuthPermit();
    if (this.s.phase === PurchasePhase.LOADING) {
      this.interrupt = LateResponsePolicy.BACKGROUND;
      this.clearTimer();
      this.update((st: PurchaseState) => {
        st.phase = PurchasePhase.IDLE;
      });
    }
    this.cancelBrowser();
  }

  /**
   * 页面出栈（同步出口 onWillDisappear）：作废在途请求并取消传输；本页登记的购买待办删除（不能再自动执行）。keepConsent：补同意导致的
   * 清栈（AppPrivacy 结论变化重开首页）不删补同意待办，由 App 在同意后重开详情再执行一次（鸿蒙实现发现 H01）。
   */
  leave(keepConsent: boolean = false): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.interrupt = LateResponsePolicy.LEAVE;
    this.revokePermit();
    this.revokeAuthPermit();
    this.resumeCard = null;
    this.deferred = null;
    this.clearTimer();
    if (this.blockTimer !== -1) {
      this.d.timers.clear(this.blockTimer);
      this.blockTimer = -1;
    }
    this.cancelBrowser();
    this.cancelOwners();
    const mine: string[] = [];
    const a: PurchaseAttempt | null = this.current;
    if (a !== null) {
      mine.push(a.linkId);
    }
    const consent: string | null = this.consentCard === null ? null : TradeJson.text(this.consentCard, 'link_id');
    if (consent !== null) {
      mine.push(consent);
    }
    const own: string | null = TradeJson.text(this.card, 'link_id');
    if (own !== null) {
      mine.push(own);
    }
    const record: Record<string, Object> | null = this.d.pending.peek();
    const link: string | null = record === null ? null : TradeJson.text(record, 'link_id');
    if (record !== null && link !== null && mine.indexOf(link) >= 0) {
      if (!(keepConsent && TradeJson.text(record, 'kind') === OpenPurchaseController.PENDING_CONSENT)) {
        this.d.pending.clear();
      }
    }
  }

  get isLeft(): boolean {
    return this.left;
  }

  consumeToast(id: number): void {
    if (this.s.toast !== null && this.s.toast.id === id) {
      this.update((st: PurchaseState) => {
        st.toast = null;
      });
    }
  }

  // ---------------------------------------------------------------- 工具

  /**
   * 此刻这张卡能发 open / 继续外跳（共性第 27 条，H-R1-06）：所有发 open 与继续外跳的入口都经这里——点击、超时同键重试、授权后
   * 自动执行、登录后重放、补同意恢复、无返利购买、确认框与 JumpTip 的继续。下架（30141 / availability=off_shelf，按卡）、平台
   * not_launched 不发；maintenance 提示后不发（含点击结果确认的 50301）。
   */
  private purchasable(card: Record<string, Object>, notify: boolean = true): boolean {
    if (TradeJson.text(card, 'availability') === BuyBlock.OFF_SHELF) {
      return false;
    }
    const status: string = this.d.env.platformStatus(TradeJson.text(card, 'platform') ?? '');
    if (status === BuyBlock.MAINTENANCE) {
      if (notify) {
        this.toast(OpenPurchaseController.MAINTENANCE_KEY);
      }
      return false;
    }
    return status !== BuyBlock.NOT_LAUNCHED;
  }

  /** 异步等待之后继续外跳之前（H-R2-02）：许可仍有效，且这张卡此刻仍可购买（平台状态、下架；不重复提示）。 */
  private continuable(granted: Permit): boolean {
    return this.allowed(granted) && this.purchasable(this.latestCard(granted.attempt), false);
  }

  private busy(): boolean {
    return this.s.phase === PurchasePhase.LOADING || this.s.dialog !== null;
  }

  private grantPermit(attempt: PurchaseAttempt): void {
    if (this.permit !== null) {
      this.permit.valid = false;
    }
    this.permit = new Permit(attempt);
  }

  private revokePermit(): void {
    if (this.permit !== null) {
      this.permit.valid = false;
    }
    this.permit = null;
  }

  /** 续执行许可仍有效：是当前尝试的、没作废、页面没离开且在前台。 */
  private allowed(granted: Permit): boolean {
    return granted.valid && this.permit === granted && granted.attempt === this.current && !this.left && this.foreground;
  }

  private permitted(attempt: PurchaseAttempt): boolean {
    const p: Permit | null = this.permit;
    return p !== null && p.attempt === attempt && this.allowed(p);
  }

  private whenForeground(action: () => void): void {
    if (this.foreground) {
      action();
    } else {
      this.deferred = action;
    }
  }

  /** 绑定授权上下文的归属：新点击、放弃后失效，cancelOwners 时一并取消（共性第 20 条）。 */
  private ownerFor(context: AuthContext): () => boolean {
    const o: () => boolean = (): boolean => this.authLive(context);
    this.owners.push(o);
    return o;
  }

  private owner(): () => boolean {
    const o: () => boolean = (): boolean => !this.left;
    this.owners.push(o);
    return o;
  }

  static pendingParams(target: Record<string, Object>, linkId: string, key: string | null, kind: string,
    noRebate: boolean, reason: string | null): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['kind'] = kind;
    out['link_id'] = linkId;
    out['platform'] = TradeJson.text(target, 'platform') ?? '';
    const productKey: string | null = TradeJson.text(target, 'product_key');
    if (productKey !== null) {
      out['product_key'] = productKey;
    }
    const itemRef: string | null = TradeJson.text(target, 'item_ref');
    if (itemRef !== null) {
      out['item_ref'] = itemRef;
    }
    if (key !== null) {
      out['idempotency_key'] = key;
    }
    if (noRebate) {
      out['no_rebate'] = true;
    }
    if (reason !== null) {
      out['no_rebate_reason'] = reason;
    }
    return out;
  }

  /** 相似商品的搜索参数：同平台、原样标题（截前 60 字；排除同 product_key 待契约补参数，A04 同口径）。 */
  static similarParams(product: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    const title: string | null = TradeJson.text(product, 'title');
    if (title !== null && title.length > 0) {
      out['q'] = title.length > OpenPurchaseController.TITLE_MAX ? title.substring(0, OpenPurchaseController.TITLE_MAX)
        : title;
    }
    const platform: string | null = TradeJson.text(product, 'platform');
    if (platform !== null && platform.length > 0) {
      out['platform'] = platform;
    }
    return out;
  }

  private static declined(platform: string, failed: boolean): PurchaseDialog {
    const d: PurchaseDialog = new PurchaseDialog(PurchaseDialogKind.AUTH_DECLINED, platform);
    d.failed = failed;
    return d;
  }

  private static notice(textKey: string | null, traceId: string | null, noRebate: boolean, contact: boolean,
    retry: boolean, platform: string): PurchaseDialog {
    const d: PurchaseDialog = new PurchaseDialog(PurchaseDialogKind.NOTICE, platform);
    d.textKey = textKey;
    d.traceId = traceId;
    d.noRebate = noRebate;
    d.contact = contact;
    d.retry = retry;
    return d;
  }

  private showDialog(dialog: PurchaseDialog): void {
    this.update((st: PurchaseState) => {
      st.dialog = dialog;
    });
  }

  private hideDialog(): void {
    if (this.s.dialog !== null) {
      this.update((st: PurchaseState) => {
        st.dialog = null;
      });
    }
  }

  private toast(key: string, traceId: string | null = null): void {
    this.toastSeq++;
    const t: PurchaseToast = new PurchaseToast(key, traceId, this.toastSeq);
    this.update((st: PurchaseState) => {
      st.toast = t;
    });
  }

  private blocked(): boolean {
    return this.d.clock() < this.blockedUntil;
  }

  private startBlock(millis: number): void {
    if (millis <= 0) {
      return;
    }
    this.blockedUntil = Math.max(this.blockedUntil, this.d.clock() + millis);
    this.update((st: PurchaseState) => {
      st.rateLimited = true;
    });
    this.armBlock();
  }

  private armBlock(): void {
    if (this.blockTimer !== -1) {
      this.d.timers.clear(this.blockTimer);
    }
    this.blockTimer = this.d.timers.set(Math.max(0, this.blockedUntil - this.d.clock()), () => {
      this.blockTimer = -1;
      if (this.left) {
        return;
      }
      if (this.blocked()) {
        this.armBlock();
        return;
      }
      this.update((st: PurchaseState) => {
        st.rateLimited = false;
      });
    });
  }

  private clearTimer(): void {
    if (this.timer !== -1) {
      this.d.timers.clear(this.timer);
      this.timer = -1;
    }
  }

  private cancelOwners(): void {
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const o of owners) {
      this.d.api.cancelOwned(o);
    }
  }

  private update(change: (st: PurchaseState) => void): void {
    const next: PurchaseState = this.s.copy();
    change(next);
    this.s = next;
    this.onChange(next);
  }
}
