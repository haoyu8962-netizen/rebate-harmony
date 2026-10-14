// APP-08 订单列表执行器（brief §2.2、§2.4、§2.7）。请求归属与页面世代（APP-03a 第 14、25、30、34 条，APP-04 第 4、15、22 条，
// APP-07 第 2、12 条）：每个请求 begin 一个序号，owner = 「序号仍是当前、页面没离开、会话归属没变」交给 ApiClient；每次筛选、切子 Tab、
// 搜索、下拉刷新开新轮次，旧轮次的响应（含翻页）一律丢弃（APP-06a 第 33 条，APP-06b 第 20 条）；响应到达（await 之后）再复核。
// 42901 按 Retry-After 在执行层禁用刷新、翻页、筛选与搜索提交（页面另外置灰）；5xxxx 带 trace6，不伪装成空结果；传输层失败且是默认视图时
// 用缓存（OrderStaleCache），带筛选或搜索词的不用缓存。
import { ApiOutcome, ApiRequest, ApiResult } from '../network/ApiClient';
import { TransportFailure } from '../network/HttpTransport';
import { LocalRejectReason } from '../network/NetworkPolicy';
import { SearchApiPort, trace6Of } from '../search/SearchController';
import { OrderJson, OrderRecord } from './OrderJson';
import { OrderErrorAction, OrderQuery, OrderStatusGroup } from './OrderPresentation';
import { OrderCacheEntry, OrderStaleCache } from './OrderStaleCache';
import { preferences } from '@kit.ArkData';

type JSONValue = Object | null;

/** 订单页的阶段。 */
export class OrderPhase {
  /** 还没加载（Tab 没打开过、换账号后）。 */
  static readonly IDLE: string = 'idle';
  static readonly LOADING: string = 'loading';
  static readonly CONTENT: string = 'content';
  static readonly EMPTY: string = 'empty';
  static readonly ERROR: string = 'error';
}

/** 一次失败给页面的样子（OrderErrorAction 的结果 + 码与 trace_id）。 */
export class OrderErrorView {
  readonly actionRaw: string;
  readonly textKey: string | null;
  readonly code: number;
  readonly traceId: string;
  readonly showTrace6: boolean;
  readonly disableMs: number;

  constructor(action: Record<string, JSONValue>, code: number, traceId: string) {
    this.actionRaw = typeof action['actionRaw'] === 'string' ? action['actionRaw'] as string : OrderErrorAction.ERROR;
    this.textKey = typeof action['textKey'] === 'string' ? action['textKey'] as string : null;
    this.code = code;
    this.traceId = traceId;
    this.showTrace6 = action['showTrace6'] === true;
    this.disableMs = typeof action['disableMs'] === 'number' ? action['disableMs'] as number : 0;
  }

  /** 追踪编号（末 6 位；不显示时为空串）。 */
  get trace6(): string {
    return this.showTrace6 ? trace6Of(this.traceId) : '';
  }
}

/** 结果的分类（transport：断网、超时、没有外壳；被取消不算）。 */
export class OrderOutcome {
  readonly ok: boolean;
  readonly transport: boolean;
  /**
   * 没有发出：订单 42901 共享闸门在这次（含自动重试、重签、刷新后的重放）实际发包前拦下（ApiRequest.sendAllowed；R2-01）。
   * 不算传输失败（不用缓存、不显示网络错误），按限流处理。
   */
  readonly sendBlocked: boolean;
  readonly code: number;
  readonly traceId: string;
  readonly headers: Record<string, string>;

  constructor(result: ApiResult) {
    this.ok = result.outcome === ApiOutcome.SUCCESS;
    this.sendBlocked = result.outcome === ApiOutcome.LOCAL_REJECT
      && result.localRejectReason === LocalRejectReason.SEND_BLOCKED;
    this.transport = !this.sendBlocked
      && (result.outcome === ApiOutcome.NETWORK_ERROR || result.outcome === ApiOutcome.LOCAL_REJECT);
    this.code = result.code;
    this.traceId = result.traceId;
    const headers: Record<string, string> = {};
    if (result.effect !== null && result.effect.disableMillis > 0) {
      headers['Retry-After'] = String(Math.round(result.effect.disableMillis / 1000));
    }
    this.headers = headers;
  }

  /** 被取消（作废、撤回、离开）：调用方一般已丢弃；万一仍是当前，按网络失败但不用缓存。 */
  static cancelled(result: ApiResult): boolean {
    return result.outcome === ApiOutcome.NETWORK_ERROR && result.failure === TransportFailure.CANCELLED;
  }
}

/** 端口不该抛错；万一抛了按断网收口。 */
export function guardedOrder(promise: Promise<ApiResult>): Promise<ApiResult> {
  return promise.catch((): ApiResult => new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0,
    TransportFailure.DISCONNECT, null, null, null));
}

/**
 * 订单请求的 42901 限流闸门（R1-02；brief §0「任一订单请求」）：按会话共享一份截止时刻，列表、翻页、详情、待跟单查询与关闭（订单列表、
 * 商品详情、搜索页各卡片位置）发送前统一检查，任一请求收到 42901 都延长同一截止时刻；页面重进拿到的仍是这一份，不能绕过。
 * - 按会话：截止时刻记在开始时的会话归属下；会话归属变了（换账号、登出、会话失效）即不再生效，App 另在会话变化时 reset。
 * - 判定一律按时钟（不只靠计时器）；到期由计时器通知全部订阅方一次（各页面据此恢复按钮）。
 */
export class OrderRateGate {
  private until: number = 0;
  private owner: string = '';
  private timer: number = -1;
  private lastView: OrderErrorView | null = null;
  private listeners: (() => void)[] = [];
  private readonly clock: () => number;
  private readonly scope: () => string;

  constructor(clock: () => number, scope: () => string) {
    this.clock = clock;
    this.scope = scope;
    this.sendAllowed = (): boolean => !this.active;
  }

  /** 此刻是否禁用（当前会话归属下、截止时刻未到）。 */
  get active(): boolean {
    let scope: string = '';
    try {
      scope = this.scope();
    } catch (e) {
      return false;
    }
    return scope === this.owner && this.clock() < this.until;
  }

  /** 禁用期内页面要显示的 42901 错误（列表首屏、详情；禁用期外为 null）。 */
  get view(): OrderErrorView | null {
    return this.active ? this.lastView : null;
  }

  /** 被闸门拦下（发送前或退避、重签、重放之后）时页面显示的 42901 错误：有这次禁用的原错误用它，否则按 target 生成。 */
  heldView(target: string, filtered: boolean): OrderErrorView {
    return this.view ?? new OrderErrorView(OrderErrorAction.map(target, 42901, false, {}, null, false, filtered), 42901,
      '');
  }

  /**
   * 交给 ApiRequest.sendAllowed 的发送闸门（共性第 13 条）：ApiClient 在每一次实际发包前（首发、GET 自动重试退避之后、10401 重签、
   * 刷新或重新注册后的重放、传输层 admit）都调它，禁用期内不发。
   */
  readonly sendAllowed: () => boolean;

  /** 收到 42901：延长截止时刻并通知全部订阅方。view：这次的错误（列表与详情显示用；没有时保留上一次的）。 */
  start(millis: number, view: OrderErrorView | null): void {
    if (millis <= 0) {
      return;
    }
    const scope: string = this.scope();
    if (scope !== this.owner) {
      this.owner = scope;
      this.until = 0;
      this.lastView = null;
    }
    this.until = Math.max(this.until, this.clock() + millis);
    if (view !== null) {
      this.lastView = view;
    }
    this.arm();
    this.notify();
  }

  /** 会话变化（换账号、登出、会话失效、撤回同意、切换环境）：清掉截止时刻并通知。 */
  reset(): void {
    this.cancel();
    const was: boolean = this.until > 0;
    this.until = 0;
    this.lastView = null;
    if (was) {
      this.notify();
    }
  }

  /** 订阅「禁用状态可能变了」（开始、到期、reset）；返回取消订阅。 */
  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      this.listeners = this.listeners.filter((l: () => void): boolean => l !== listener);
    };
  }

  private arm(): void {
    this.cancel();
    const wait: number = Math.max(0, this.until - this.clock());
    this.timer = setTimeout((): void => {
      this.timer = -1;
      if (this.clock() < this.until) {
        this.arm();
        return;
      }
      this.notify();
    }, wait);
  }

  private cancel(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private notify(): void {
    for (const l of this.listeners.slice()) {
      try {
        l();
      } catch (e) {
        // 订阅方出错不影响其他页面。
      }
    }
  }
}

/** 列表页的一次快照（执行器每次变化都给页面）。 */
export class OrderListSnapshot {
  scope: string = 'self';
  group: string = OrderStatusGroup.ALL;
  platform: string | null = null;
  month: string | null = null;
  q: string | null = null;
  phase: string = OrderPhase.IDLE;
  items: OrderRecord[] = [];
  /** 还有下一页（next_cursor 非空，且不是缓存数据）。 */
  hasMore: boolean = false;
  loadingMore: boolean = false;
  loadMoreError: OrderErrorView | null = null;
  error: OrderErrorView | null = null;
  /** 正在显示缓存（OrdersStale）：顶部提示条，{time} 为缓存的成功获取时刻；不能翻页。 */
  stale: boolean = false;
  staleFetchedAt: number = 0;
  earliestVisibleDate: string | null = null;
  /** 42901 禁用中：刷新、翻页、筛选与搜索提交都不可用。 */
  blocked: boolean = false;
  /** 下拉刷新进行中（保留已有结果）。 */
  refreshing: boolean = false;
  /** 查询轮次：页面只在轮次变化时回到顶部。 */
  round: number = 0;
  /** 失败序号：每出现一次新的失败加 1（页面播报并聚焦【重试】）。 */
  failureSeq: number = 0;
  /** 当前展示的结果来自哪个请求序号（测试核对迟到响应）。 */
  shownSeq: number = 0;
  filtered: boolean = false;
  /**
   * 会话世代（共性第 19 条）：每次会话变化（resetForSession）加 1。页面看到它变了就同步清空搜索框输入（可能是上一账号的完整订单号）、
   * 关闭筛选弹层；App 同时清掉持久化的页面状态与恢复锚点。
   */
  sessionEpoch: number = 0;
}

/**
 * 渲染时的身份票据（FU-HM-0712，APP-08 共性第 41、44 条；第 1 轮评审 R1-01）：列表卡渲染时一次取出的不可变值——列表执行器实例、页面实例、
 * 已显示数据所属的会话归属与会话世代、子 Tab、查询轮次（查询版本）、结果版本，以及这张卡的订单标识与订单号。复制 / 打开详情回调执行前
 * 交页面守卫（OrderListPage：页面仍在）与执行器（ticketValid：会话、子 Tab、查询、结果仍是渲染时那一份，且这一行的单号没变）比较，
 * 都通过才走统一写入口；不在执行时读取当前会话当身份。
 */
export class OrderRenderTicket {
  readonly list: number;
  readonly page: number;
  readonly scope: string;
  readonly sessionEpoch: number;
  readonly tab: string;
  readonly round: number;
  readonly result: number;
  readonly orderId: string;
  readonly orderNo: string;

  constructor(list: number, page: number, scope: string, sessionEpoch: number, tab: string, round: number,
    result: number, orderId: string, orderNo: string) {
    this.list = list;
    this.page = page;
    this.scope = scope;
    this.sessionEpoch = sessionEpoch;
    this.tab = tab;
    this.round = round;
    this.result = result;
    this.orderId = orderId;
    this.orderNo = orderNo;
  }
}

/**
 * 列表页实例的守卫（FU-HM-0712 第 1 轮评审 R1-01）：页面 aboutToAppear 时创建（固定这一页的执行器与页面实例编号），aboutToDisappear
 * 时 close。列表卡的票据由它签发；复制 / 打开详情的旧回调先核对页面仍在、票据属于本页，再交执行器核对会话、子 Tab、查询与结果版本、
 * 单号，全部通过才调写入口——视图销毁、换条件、切子 Tab、会话换代后执行旧回调零写入。
 */
export class OrderListPage {
  private static serial: number = 0;
  readonly id: number;
  private readonly controller: OrderListController;
  private open: boolean = true;

  constructor(controller: OrderListController) {
    OrderListPage.serial++;
    this.id = OrderListPage.serial;
    this.controller = controller;
  }

  get alive(): boolean {
    return this.open;
  }

  /** 视图销毁（aboutToDisappear 的同步出口）：本页签发过的票据永久失效。 */
  close(): void {
    this.open = false;
  }

  /** 渲染这一行时签发票据。 */
  ticket(item: OrderRecord): OrderRenderTicket {
    return this.controller.renderTicket(item, this.id);
  }

  /** 票据此刻仍有效（页面仍在、属于本页、执行器核对通过）。 */
  valid(ticket: OrderRenderTicket | null, item: OrderRecord): boolean {
    return ticket !== null && this.open && ticket.page === this.id && this.controller.ticketValid(ticket, item);
  }

  /** 【复制订单号】：核对通过才交统一写入口（write）。返回是否交出。 */
  copy(ticket: OrderRenderTicket | null, item: OrderRecord, write: (item: OrderRecord) => void): boolean {
    if (!this.valid(ticket, item)) {
      return false;
    }
    write(item);
    return true;
  }

  /** 整卡打开详情：核对通过才打开。 */
  openDetail(ticket: OrderRenderTicket | null, item: OrderRecord, open: (item: OrderRecord) => void): boolean {
    if (!this.valid(ticket, item)) {
      return false;
    }
    open(item);
    return true;
  }

  /** 此刻签发输入类回调的身份（第 2 轮评审 R2-01；页面在 aboutToAppear 与每次会话换代后的 apply 里调）。 */
  inputStamp(): OrderInputStamp {
    return this.controller.inputStamp(this.id);
  }

  /** 输入类回调的身份此刻仍有效：页面仍在、身份由本页签发、执行器核对会话归属与世代通过。 */
  inputValid(stamp: OrderInputStamp | null): boolean {
    return stamp !== null && this.open && stamp.page === this.id && this.controller.inputValid(stamp);
  }

  /**
   * 渲染时绑定一组输入类回调（R2-01）：一次取出页面编号、执行器实例、会话归属与会话世代（不可变），页面把返回值放进 ForEach 的数据项，
   * 搜索框输入 / 提交 / 清空、子 Tab、分组、平台与月份半屏的回调只经它执行。
   */
  inputs(model: OrderInputModel): OrderInputHandlers {
    return new OrderInputHandlers(this, this.controller, model, this.inputStamp());
  }
}

/**
 * 输入类回调的渲染时身份（FU-HM-0712 第 2 轮评审 R2-01，APP-08 共性第 47 条、APP-09 第 63 条）：页面实例编号、执行器实例编号、
 * 会话归属与会话世代，渲染时一次取出、不可变。同一个执行器在会话换代时会被 resetForSession 绑定到新会话——旧页面 / 旧渲染的输入回调
 * 拿着这里的旧值，执行时与执行器比较不通过，就不写模型、不改查询、不持久化、不发请求。
 */
export class OrderInputStamp {
  readonly list: number;
  readonly page: number;
  readonly scope: string;
  readonly sessionEpoch: number;

  constructor(list: number, page: number, scope: string, sessionEpoch: number) {
    this.list = list;
    this.page = page;
    this.scope = scope;
    this.sessionEpoch = sessionEpoch;
  }

  /** ForEach 键（不含会话归属原文）。 */
  get key(): string {
    return this.list + ':' + this.page + ':' + this.sessionEpoch;
  }
}

/** 输入回调会写的页面模型字段（features 的 OrderListModel 实现它；测试用普通对象）。 */
export interface OrderInputModel {
  inputText: string;
  platformSheet: boolean;
  monthSheet: boolean;
}

/**
 * 一组绑定了渲染时身份的输入回调（R2-01）。每个入口先经页面守卫与执行器核对身份（页面仍在、由本页签发、执行器实例相同、列表仍属于
 * 当前会话、会话归属与世代都还是渲染时那一份），通过才写模型 / 改查询（查询变化随即持久化并发请求）；不通过返回 false、零写入。
 */
export class OrderInputHandlers {
  readonly stamp: OrderInputStamp;
  private readonly page: OrderListPage;
  private readonly controller: OrderListController;
  private readonly model: OrderInputModel;

  constructor(page: OrderListPage, controller: OrderListController, model: OrderInputModel, stamp: OrderInputStamp) {
    this.page = page;
    this.controller = controller;
    this.model = model;
    this.stamp = stamp;
  }

  get key(): string {
    return this.stamp.key;
  }

  get valid(): boolean {
    return this.page.inputValid(this.stamp);
  }

  /** 搜索框 onChange：只写输入框文字（不发请求，G11）。 */
  change(value: string): boolean {
    if (!this.valid) {
      return false;
    }
    this.model.inputText = value;
    return true;
  }

  /** 搜索框【搜索】（onSubmit）：提交输入框文字。42901 禁用中执行器拒绝。 */
  submit(): boolean {
    if (!this.valid || this.controller.blocked) {
      return false;
    }
    return this.controller.submitQuery(this.model.inputText);
  }

  /** 清空按钮：清输入框；有搜索词时也是一次提交（发不带 q 的请求）。 */
  clear(): boolean {
    if (!this.valid) {
      return false;
    }
    this.model.inputText = '';
    if (this.controller.conditions().q !== null) {
      this.controller.submitQuery('');
    }
    return true;
  }

  /** 子 Tab「自购 / 分享」。 */
  scope(scope: string): boolean {
    return this.valid && this.controller.setScope(scope);
  }

  /** 状态分组胶囊。 */
  group(group: string): boolean {
    return this.valid && this.controller.setGroup(group);
  }

  /** 打开【平台】（kind = 'platform'）或【月份】（'month'）半屏。 */
  openSheet(kind: string): boolean {
    if (!this.valid) {
      return false;
    }
    if (kind === 'platform') {
      this.model.platformSheet = true;
    } else {
      this.model.monthSheet = true;
    }
    return true;
  }

  /** 平台半屏里选一项（null = 全部平台）：收起半屏并改条件。 */
  platform(platform: string | null): boolean {
    if (!this.valid) {
      return false;
    }
    this.model.platformSheet = false;
    return this.controller.setPlatform(platform);
  }

  /** 月份半屏里选一项（null = 全部月份）：收起半屏并改条件。 */
  month(month: string | null): boolean {
    if (!this.valid) {
      return false;
    }
    this.model.monthSheet = false;
    return this.controller.setMonth(month);
  }
}

/** 列表执行器的依赖。 */
export class OrderListDeps {
  readonly api: SearchApiPort;
  cache: OrderStaleCache | null = null;
  clock: () => number = Date.now;
  /** 会话归属（ApiClient.captureScope 的键）：请求开始时记下，变了就作废（换账号后不把旧账号的结果显示给新账号）。 */
  scope: () => string = () => '';
  /** 按会话共享的 42901 闸门（App 一份，列表、详情、各待跟单卡共用；null 时自建一份，只在测试里单独用）。 */
  gate: OrderRateGate | null = null;

  constructor(api: SearchApiPort) {
    this.api = api;
  }
}

/** 页面状态持久化与恢复用的条件（子 Tab、分组、平台、月份、搜索词）。 */
export class OrderListConditions {
  scope: string = 'self';
  group: string = OrderStatusGroup.ALL;
  platform: string | null = null;
  month: string | null = null;
  q: string | null = null;

  encode(): string {
    const r: Record<string, JSONValue> = {};
    r['scope'] = this.scope;
    r['group'] = this.group;
    r['platform'] = this.platform;
    r['month'] = this.month;
    r['q'] = this.q;
    return JSON.stringify(r);
  }

  static decode(text: string | null): OrderListConditions | null {
    if (text === null) {
      return null;
    }
    try {
      const r: OrderRecord | null = OrderJson.objectOf(JSON.parse(text) as Object);
      if (r === null) {
        return null;
      }
      const c: OrderListConditions = new OrderListConditions();
      c.scope = OrderJson.text(r, 'scope') === 'share' ? 'share' : 'self';
      const group: string | null = OrderJson.text(r, 'group');
      c.group = group !== null && OrderStatusGroup.ALL_GROUPS.indexOf(group) >= 0 ? group : OrderStatusGroup.ALL;
      c.platform = OrderJson.nonEmpty(r, 'platform');
      const month: string | null = OrderJson.text(r, 'month');
      c.month = month !== null && /^\d{4}-(0[1-9]|1[0-2])$/.test(month) ? month : null;
      c.q = OrderQuery.normalizeQ(OrderJson.text(r, 'q'));
      return c;
    } catch (e) {
      return null;
    }
  }
}

/**
 * 订单列表执行器（OrderList 路由，订单 Tab 根）。Tab 被切走只是被覆盖，不算出栈；换账号、登出由 App 调 resetForSession。
 */
export class OrderListController {
  private readonly d: OrderListDeps;
  private query: OrderQuery = OrderQuery.initial(null);
  private seq: number = 0;
  private current: number = 0;
  private owners: (() => boolean)[] = [];
  private left: boolean = false;
  private readonly gate: OrderRateGate;
  private readonly unsubscribe: () => void;
  private state: OrderListSnapshot = new OrderListSnapshot();
  /**
   * 已显示数据所属的会话归属（FU-HM-0712，APP-08 共性第 44 条、APP-09 第 65 条）：只在构造与会话换代通知（resetForSession）里取得；
   * 下拉刷新、翻页、筛选等入口只拿它与当前会话比较，不再在每轮 run() 里重新绑定（旧逻辑会把已显示的旧账号列表经 begin 之后的
   * 重新赋值绑到新会话）。
   */
  private boundScope: string = '';
  /** 执行器实例编号（票据核对：别的执行器签发的票据不算）。 */
  private static instances: number = 0;
  private readonly instanceId: number;
  /**
   * 结果版本（FU-HM-0712 第 1 轮评审 R1-01）：已显示的结果被整体替换或清空（新一轮结果、缓存、错误、作废、会话换代）时加 1；翻页追加与
   * 详情回填同一行不加（那一行的单号另行核对）。
   */
  private resultVersion: number = 0;
  onChange: (snapshot: OrderListSnapshot) => void = (_s: OrderListSnapshot) => {
  };

  constructor(deps: OrderListDeps) {
    OrderListController.instances++;
    this.instanceId = OrderListController.instances;
    this.d = deps;
    this.gate = deps.gate ?? new OrderRateGate(deps.clock, deps.scope);
    this.boundScope = deps.scope();
    this.state.blocked = this.gate.active;
    // 闸门由任一订单请求触发或到期：页面同步置灰 / 恢复（R1-02）。
    this.unsubscribe = this.gate.subscribe((): void => {
      if (!this.left && this.state.blocked !== this.gate.active) {
        this.emit();
      }
    });
  }

  get snapshot(): OrderListSnapshot {
    return this.state;
  }

  /** 当前查询（测试与持久化用的副本）。 */
  get currentQuery(): OrderQuery {
    return this.query.copy();
  }

  conditions(): OrderListConditions {
    const c: OrderListConditions = new OrderListConditions();
    c.scope = this.query.scope;
    c.group = this.query.group;
    c.platform = this.query.platform;
    c.month = this.query.month;
    c.q = this.query.q;
    return c;
  }

  get blocked(): boolean {
    return this.gate.active;
  }

  /** 装入条件（路由参数 scope、进程回收后恢复的条件）；不发请求。 */
  restore(conditions: OrderListConditions | null, routeScope: string | null): void {
    const q: OrderQuery = OrderQuery.initial(conditions !== null ? conditions.scope : routeScope);
    if (conditions !== null) {
      q.group = conditions.group;
      q.platform = conditions.platform;
      q.month = conditions.month;
      q.q = conditions.q;
    }
    q.round = this.query.round;
    this.query = q;
    this.state.round = q.round;
    this.syncConditions();
    this.emit();
  }

  /** Tab 第一次显示（或换账号后再显示）：还没加载就加载第一页。 */
  ensureLoaded(): void {
    if (this.state.phase === OrderPhase.IDLE) {
      this.run(false);
    }
  }

  /** 切子 Tab（BR-TEXT-02 细则：分组回「全部」，平台、月份、搜索词清空）。路由 scope=share 也走这里。 */
  setScope(scope: string): boolean {
    if (scope === this.query.scope) {
      return false;
    }
    return this.change('set_scope', scope, true);
  }

  setGroup(group: string): boolean {
    return group === this.query.group ? false : this.change('set_group', group, false);
  }

  setPlatform(platform: string | null): boolean {
    return platform === this.query.platform ? false : this.change('set_platform', platform, false);
  }

  setMonth(month: string | null): boolean {
    return month === this.query.month ? false : this.change('set_month', month, false);
  }

  /** 搜索框【搜索】或清空（G11：只在提交与清空时发请求，不边输边搜）。 */
  submitQuery(text: string | null): boolean {
    return this.change('set_q', text, false);
  }

  /**
   * 条件变化：开新轮次。42901 禁用中拒绝（筛选与搜索提交在执行层也禁用；切子 Tab 是导航，照常切换并清条件，只是不发请求）。
   */
  private change(op: string, value: string | null, navigation: boolean): boolean {
    if (this.left) {
      return false;
    }
    if (this.gate.active && !navigation) {
      return false;
    }
    this.query.apply(op, value);
    this.syncConditions();
    this.run(false);
    return true;
  }

  /** 下拉刷新：新轮次，保留已有结果直到新结果到达；42901 禁用中不发。 */
  refresh(): boolean {
    if (this.left || this.gate.active) {
      return false;
    }
    this.query.apply('refresh', null);
    this.run(true);
    return true;
  }

  /** 【重试】：首屏失败重新加载；翻页失败重翻这一页；显示缓存时重新加载第一页。 */
  retry(): boolean {
    if (this.left || this.gate.active) {
      return false;
    }
    if (this.state.phase === OrderPhase.ERROR || this.state.stale) {
      this.query.apply('refresh', null);
      this.run(false);
      return true;
    }
    if (this.state.loadMoreError !== null) {
      return this.loadMore();
    }
    return false;
  }

  /** 加载更多：已到底、正在加载、显示缓存、禁用中、不在内容态时不做。 */
  loadMore(): boolean {
    const s: OrderListSnapshot = this.state;
    if (this.left || this.gate.active || !s.hasMore || s.loadingMore || s.stale || s.phase !== OrderPhase.CONTENT
      || !this.query.sendsRequest() || this.query.cursor === null) {
      return false;
    }
    if (!this.ownsSession()) {
      // FU-HM-0712（共性第 44 条）：翻页发现会话已变——先作废旧列表，不翻页、不把旧数据绑到当前会话。
      this.voidForeignSession();
      return false;
    }
    const seq: number = this.begin();
    const round: OrderQuery = this.query.copy();
    s.loadingMore = true;
    s.loadMoreError = null;
    this.emit();
    this.send(seq, round).then((result: ApiResult) => {
      if (!this.accept(seq)) {
        return;
      }
      s.loadingMore = false;
      const outcome: OrderOutcome = new OrderOutcome(result);
      if (outcome.sendBlocked) {
        // 翻页的自动重试被共享闸门拦下（R2-01）：保留已加载的结果，底部显示限流错误。
        s.loadMoreError = this.gate.heldView(OrderErrorAction.LIST_NEXT, round.filtered);
        s.failureSeq++;
        this.emit();
        return;
      }
      if (outcome.ok) {
        const items: OrderRecord[] = OrderJson.summaries(result.data as OrderRecord);
        s.items = s.items.concat(items);
        this.applyCursor(OrderJson.nextCursor(result.data as OrderRecord));
        s.shownSeq = seq;
        this.emit();
        return;
      }
      const view: OrderErrorView = this.errorView(OrderErrorAction.LIST_NEXT, result, outcome, false);
      s.loadMoreError = view;
      s.failureSeq++;
      this.startBlock(view);
      this.emit();
    });
    return true;
  }

  /**
   * 从详情返回（G17）：本次详情请求成功时，用详情里与 OrderSummary 同名的字段替换同 order_id 的那一行；其余行、筛选、搜索词、
   * 滚动位置不动，不额外请求列表。显示缓存时不改（不把新数据混进旧快照）。
   */
  replaceRow(detail: OrderRecord, detailScope: string | null = null): boolean {
    const id: string | null = OrderJson.nonEmpty(detail, 'order_id');
    const s: OrderListSnapshot = this.state;
    // FU-HM-0712：详情与列表属于同一个会话（详情页固定的归属 = 列表固定的归属 = 当前会话）才替换。
    if (this.left || id === null || s.stale || OrderJson.order(detail) === null || !this.ownsSession()
      || (detailScope !== null && detailScope !== this.boundScope)) {
      return false;
    }
    let changed: boolean = false;
    const items: OrderRecord[] = s.items.map((item: OrderRecord): OrderRecord => {
      if (OrderJson.text(item, 'order_id') !== id) {
        return item;
      }
      changed = true;
      return OrderJson.summaryOf(detail);
    });
    if (changed) {
      s.items = items;
      this.emit();
    }
    return changed;
  }

  /**
   * 换账号、登出、会话失效、撤回同意（App 在状态同步的同步区里调）：作废全部在途请求，清掉结果与条件，回到未加载；不显示旧账号的数据。
   */
  resetForSession(): void {
    this.begin();
    this.gate.reset();
    this.boundScope = this.d.scope();
    const round: number = this.query.round + 1;
    this.query = OrderQuery.initial(null);
    this.query.round = round;
    const s: OrderListSnapshot = new OrderListSnapshot();
    s.round = round;
    s.failureSeq = this.state.failureSeq;
    s.sessionEpoch = this.state.sessionEpoch + 1;
    this.state = s;
    this.resultVersion++;
    this.syncConditions();
    this.emit();
  }

  /** 页面实例销毁（App 退出前的兜底）：之后迟到的响应一律丢弃。 */
  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.begin();
    this.unsubscribe();
    // APP-08 共性第 30 条：同步结束下拉刷新与翻页加载态（请求已取消、迟到响应被丢弃）。
    const s: OrderListSnapshot = this.state;
    if (s.refreshing || s.loadingMore) {
      s.refreshing = false;
      s.loadingMore = false;
      try {
        this.onChange(s);
      } catch (e) {
        // 页面回调出错不影响执行器。
      }
    }
  }

  private syncConditions(): void {
    const s: OrderListSnapshot = this.state;
    s.scope = this.query.scope;
    s.group = this.query.group;
    s.platform = this.query.platform;
    s.month = this.query.month;
    s.q = this.query.q;
    s.filtered = this.query.filtered;
  }

  /**
   * 已显示的列表仍属于当前会话（只比较）：页面复制、打开详情、持久化前用；会话已变（新令牌已保存、清空通知还没到）为 false。
   */
  ownsSession(): boolean {
    return !this.left && this.d.scope() === this.boundScope;
  }

  /** 渲染这一行时的身份票据（经 OrderListPage.ticket 签发；page 为页面实例编号）。 */
  renderTicket(item: OrderRecord, page: number = 0): OrderRenderTicket {
    return new OrderRenderTicket(this.instanceId, page, this.boundScope, this.state.sessionEpoch, this.query.scope,
      this.query.round, this.resultVersion, OrderJson.text(item, 'order_id') ?? '', OrderJson.text(item, 'order_no') ?? '');
  }

  /** 输入类回调的渲染时身份（R2-01；经 OrderListPage.inputStamp 签发）。 */
  inputStamp(page: number): OrderInputStamp {
    return new OrderInputStamp(this.instanceId, page, this.boundScope, this.state.sessionEpoch);
  }

  /**
   * 输入类回调的身份此刻仍有效（R2-01，APP-08 共性第 47 条）：本执行器签发、列表仍属于当前会话（新令牌已保存、清空通知未到时为 false），
   * 且会话归属与会话世代都还是渲染时那一份（resetForSession 换代后旧回调永久失效）。只比较，不重新绑定。
   */
  inputValid(stamp: OrderInputStamp | null): boolean {
    return stamp !== null && this.ownsSession() && stamp.list === this.instanceId && stamp.scope === this.boundScope
      && stamp.sessionEpoch === this.state.sessionEpoch;
  }

  /**
   * 渲染时捕获的票据此刻仍有效（R1-01）：本执行器签发、列表仍属于当前会话且没有随会话换代清空过；子 Tab、查询轮次、结果版本都还是
   * 渲染时那一份；回调带的这一行与票据同一订单、同一单号，且当前结果里这一行的单号没变。
   */
  ticketValid(ticket: OrderRenderTicket | null, item: OrderRecord | null = null): boolean {
    if (ticket === null || !this.ownsSession() || ticket.list !== this.instanceId || ticket.scope !== this.boundScope
      || ticket.sessionEpoch !== this.state.sessionEpoch || ticket.tab !== this.query.scope
      || ticket.round !== this.query.round || ticket.result !== this.resultVersion || ticket.orderId.length === 0) {
      return false;
    }
    if (item !== null && ((OrderJson.text(item, 'order_id') ?? '') !== ticket.orderId
      || (OrderJson.text(item, 'order_no') ?? '') !== ticket.orderNo)) {
      return false;
    }
    for (const row of this.state.items) {
      if ((OrderJson.text(row, 'order_id') ?? '') === ticket.orderId) {
        return (OrderJson.text(row, 'order_no') ?? '') === ticket.orderNo;
      }
    }
    return false;
  }

  /**
   * 会话已变（清空通知还没到）时的入口（APP-08 共性第 44 条）：先作废已显示的旧列表与在途请求，不发请求、不重新绑定当前会话，
   * 等清空通知（resetForSession）重建。
   */
  private voidForeignSession(): void {
    this.begin();
    const s: OrderListSnapshot = this.state;
    s.items = [];
    this.resultVersion++;
    s.hasMore = false;
    s.loadingMore = false;
    s.loadMoreError = null;
    s.refreshing = false;
    s.stale = false;
    s.staleFetchedAt = 0;
    s.earliestVisibleDate = null;
    s.error = null;
    s.phase = OrderPhase.IDLE;
    this.emit();
  }

  /** 第一页（新轮次）。keepItems：下拉刷新时保留已有结果。 */
  private run(keepItems: boolean): void {
    if (this.left) {
      return;
    }
    if (!this.ownsSession()) {
      this.voidForeignSession();
      return;
    }
    const seq: number = this.begin();
    const round: OrderQuery = this.query.copy();
    const s: OrderListSnapshot = this.state;
    s.round = round.round;
    s.loadingMore = false;
    s.loadMoreError = null;
    s.error = null;
    if (keepItems && (s.phase === OrderPhase.CONTENT || s.phase === OrderPhase.EMPTY)) {
      s.refreshing = true;
    } else {
      s.refreshing = false;
      s.items = [];
      this.resultVersion++;
      s.hasMore = false;
      s.stale = false;
      s.earliestVisibleDate = null;
      s.phase = OrderPhase.LOADING;
    }
    if (this.gate.active) {
      // 限流只限制发送（APP-06a 第 19 条）：条件照常更新，页面保持限流错误。
      s.refreshing = false;
      s.items = [];
      this.resultVersion++;
      s.hasMore = false;
      s.stale = false;
      s.error = this.gate.heldView(OrderErrorAction.LIST_FIRST, this.query.filtered);
      s.phase = OrderPhase.ERROR;
      this.emit();
      return;
    }
    this.emit();
    this.send(seq, round).then((result: ApiResult) => {
      if (!this.accept(seq)) {
        return;
      }
      s.refreshing = false;
      const outcome: OrderOutcome = new OrderOutcome(result);
      if (outcome.sendBlocked) {
        // 退避、重签、刷新后的重放被共享闸门拦下（R2-01）：与收到 42901 同样处理（不发、不用缓存、显示限流错误）。
        s.shownSeq = seq;
        s.failureSeq++;
        s.items = [];
        this.resultVersion++;
        s.stale = false;
        s.hasMore = false;
        s.error = this.gate.heldView(OrderErrorAction.LIST_FIRST, round.filtered);
        s.phase = OrderPhase.ERROR;
        this.emit();
        return;
      }
      if (outcome.ok) {
        const data: OrderRecord = result.data as OrderRecord;
        s.items = OrderJson.summaries(data);
        this.resultVersion++;
        s.earliestVisibleDate = OrderJson.earliestVisibleDate(data);
        s.stale = false;
        s.staleFetchedAt = 0;
        s.error = null;
        s.phase = s.items.length > 0 ? OrderPhase.CONTENT : OrderPhase.EMPTY;
        s.shownSeq = seq;
        this.applyCursor(OrderJson.nextCursor(data));
        const cache: OrderStaleCache | null = this.d.cache;
        if (cache !== null && OrderStaleCache.isCacheable('list', round.params())) {
          cache.saveList(round.scope, data);
        }
        this.emit();
        return;
      }
      const cached: OrderCacheEntry | null = this.cachedFor(round, outcome, result);
      const view: OrderErrorView = this.errorView(OrderErrorAction.LIST_FIRST, result, outcome, cached !== null);
      s.shownSeq = seq;
      s.failureSeq++;
      if (view.actionRaw === OrderErrorAction.SHOW_STALE && cached !== null) {
        s.items = OrderJson.summaries(cached.data);
        this.resultVersion++;
        s.earliestVisibleDate = OrderJson.earliestVisibleDate(cached.data);
        s.stale = true;
        s.staleFetchedAt = cached.fetchedAt;
        s.hasMore = false;
        s.phase = s.items.length > 0 ? OrderPhase.CONTENT : OrderPhase.EMPTY;
        // stale 状态下不能翻页：列表底部显示同一网络错误与【重试】（重新加载第一页）。
        s.loadMoreError = new OrderErrorView(OrderErrorAction.map(OrderErrorAction.LIST_NEXT, null, true, {}, null, false,
          false), -1, '');
        s.error = null;
        this.emit();
        return;
      }
      s.items = [];
      this.resultVersion++;
      s.stale = false;
      s.hasMore = false;
      s.error = view;
      s.phase = OrderPhase.ERROR;
      this.startBlock(view);
      this.emit();
    });
  }

  /** 传输层失败、默认视图：读缓存（读不出、损坏按没有）。 */
  private cachedFor(round: OrderQuery, outcome: OrderOutcome, result: ApiResult): OrderCacheEntry | null {
    const cache: OrderStaleCache | null = this.d.cache;
    if (cache === null || !outcome.transport || OrderOutcome.cancelled(result) || round.filtered) {
      return null;
    }
    return cache.loadList(round.scope);
  }

  private errorView(target: string, result: ApiResult, outcome: OrderOutcome, hasCache: boolean): OrderErrorView {
    const transport: boolean = outcome.transport;
    const action: Record<string, JSONValue> = OrderErrorAction.map(target, transport ? null : outcome.code, transport,
      outcome.headers, result.traceId, hasCache, this.query.filtered);
    return new OrderErrorView(action, outcome.code, result.traceId);
  }

  private applyCursor(next: string | null): void {
    this.query.apply('next_page', next);
    this.state.hasMore = next !== null;
  }

  private startBlock(view: OrderErrorView): void {
    if (view.actionRaw !== OrderErrorAction.RETRY_AFTER || view.disableMs <= 0) {
      return;
    }
    this.gate.start(view.disableMs, view);
  }

  /** 新请求开始：旧序号立即失效，并取消旧请求的传输。 */
  private begin(): number {
    this.seq++;
    this.current = this.seq;
    const owners: (() => boolean)[] = this.owners;
    this.owners = [];
    for (const owner of owners) {
      this.d.api.cancelOwned(owner);
    }
    return this.seq;
  }

  private alive(seq: number): boolean {
    return !this.left && this.current === seq && this.d.scope() === this.boundScope;
  }

  /** 等待之后复核：序号仍是当前、页面没离开、会话归属没变。 */
  private accept(seq: number): boolean {
    if (!this.alive(seq)) {
      return false;
    }
    this.owners = [];
    return true;
  }

  private send(seq: number, round: OrderQuery): Promise<ApiResult> {
    const request: ApiRequest = new ApiRequest('listOrders', {}, round.queryString());
    const owner: () => boolean = (): boolean => this.alive(seq);
    request.owner = owner;
    request.sendAllowed = this.gate.sendAllowed;
    this.owners.push(owner);
    return guardedOrder(this.d.api.request(request));
  }

  private emit(): void {
    this.state.blocked = this.gate.active;
    this.onChange(this.state);
  }
}

/**
 * 进程回收后的滚动锚点恢复（共性第 10 条；APP-06a 第 40、42、43 条）：保存时记下稳定的订单标识（列表顶部可见那一行的 order_id）与当时的
 * 查询条件；恢复后每次快照调 resolve：
 * - 条件已不同（换了子 Tab、筛选、搜索词）→ 放弃（DROPPED）；
 * - 还在加载、目标订单还没加载出来 → 继续等（WAIT），不丢弃恢复任务（翻页加载到它时再对齐）；
 * - 目标已在列表里 → 返回它的下标，由页面在布局就绪后做一次顶对齐，之后不再生效（只对齐一次）。
 */
export class OrderScrollAnchor {
  static readonly WAIT: number = -1;
  static readonly DROPPED: number = -2;
  private target: string | null;
  private readonly conditions: string;
  /** 因条件变了（用户换子 Tab、筛选、搜索词）而放弃（区别于首屏失败 / 空结果放弃）。 */
  droppedByConditions: boolean = false;

  constructor(target: string, conditions: string) {
    this.target = target.length > 0 ? target : null;
    this.conditions = conditions;
  }

  get pending(): boolean {
    return this.target !== null;
  }

  resolve(items: OrderRecord[], conditions: string, phase: string): number {
    const target: string | null = this.target;
    if (target === null) {
      return OrderScrollAnchor.DROPPED;
    }
    if (conditions !== this.conditions || phase === OrderPhase.EMPTY || phase === OrderPhase.ERROR) {
      this.target = null;
      this.droppedByConditions = conditions !== this.conditions;
      return OrderScrollAnchor.DROPPED;
    }
    if (phase !== OrderPhase.CONTENT) {
      return OrderScrollAnchor.WAIT;
    }
    for (let i = 0; i < items.length; i++) {
      if (OrderJson.text(items[i], 'order_id') === target) {
        this.target = null;
        return i;
      }
    }
    return OrderScrollAnchor.WAIT;
  }

  /** 会话变化、用户换条件：放弃。 */
  cancel(): void {
    this.target = null;
  }
}

/**
 * 滚动锚点的持久化（共性第 10、17 条；R2-05）：页面状态里存的锚点由它给出。
 * - 进程回收后恢复（begin）：恢复进行中保留原持久化锚点（目标 order_id），冻结普通滚动记录（首屏、加载中的滚动回调不覆盖它）；
 *   目标加载出来、页面完成一次顶对齐（aligned）后才解冻，之后按滚动照常更新。二次回收发生在恢复完成前时，下次仍按原锚点恢复。
 * - 用户换条件（子 Tab、筛选、搜索词）导致恢复放弃：明确解冻，锚点清空（新条件从顶部开始）。
 * - 首屏失败 / 空结果放弃恢复（H20）：解冻，但保留原锚点（之后重试成功时由滚动记录覆盖）。
 * - 会话变化：清空（reset）。
 */
export class OrderAnchorKeeper {
  private anchorId: string = '';
  private restore: OrderScrollAnchor | null = null;
  /** 已找到目标、等页面布局就绪后对齐（这段时间同样冻结）。 */
  private aligning: boolean = false;
  /**
   * 恢复任务编号（R3-02；共性第 24 条）：每次 begin、reset、取消对齐加 1。页面排入的布局等待回调绑定它，执行前经 commitAlign 复核。
   */
  private task: number = 0;
  /** 进入对齐时的条件（编码）：回调执行前条件变了即作废。 */
  private alignConditions: string = '';
  /**
   * 恢复进行中列表首次可交互时的顶部订单（位置基准；APP-06a 第 38、41 条，APP-08 共性第 35 条）：恢复任务自己在对齐前不移动列表，
   * 之后顶部订单偏离基准即是别人（触摸、惯性、读屏 / 键盘滚动、补页期间的滚动）造成的——取消恢复，不再把用户拉回旧目标。
   * null = 还没建立。
   */
  private baselineTop: string | null = null;
  /**
   * 同一时刻列表的实际滚动偏移（像素；FU-HM-0710 R1-04，APP-08 共性第 39 条）：顶部订单编号不变的小幅滚动（同一卡片内）、惯性、
   * 无障碍滚动都会改变偏移——判定「用户已滚动」看偏移，不只看顶部条目。NaN = 调用方没给偏移（只比较顶部订单）。
   */
  private baselineOffset: number = NaN;

  /** 偏移变化超过这个值（像素）才算滚动（排除浮点误差）。 */
  static readonly SCROLL_EPSILON: number = 0.5;

  /** 要写进页面状态的锚点（稳定的 order_id；在顶部为空串）。 */
  get anchor(): string {
    return this.anchorId;
  }

  /** 恢复进行中（含等对齐）：普通滚动记录冻结。 */
  get frozen(): boolean {
    return this.restore !== null || this.aligning;
  }

  /** 当前恢复任务编号（页面排入布局等待回调时记下，回调执行前交给 commitAlign 复核）。 */
  get ticket(): number {
    return this.task;
  }

  /** 恢复任务绑定的查询轮次（-1 = 还没看到第一份快照）：轮次变了（用户换筛选、搜索、下拉刷新）即放弃（共性第 21 条）。 */
  private boundRound: number = -1;

  /** 进程回收后恢复：target 为持久化的锚点，conditions 为当时的条件（编码）。 */
  begin(target: string, conditions: string): void {
    this.task++;
    this.anchorId = target;
    this.aligning = false;
    this.boundRound = -1;
    this.baselineTop = null;
    this.baselineOffset = NaN;
    this.restore = target.length > 0 ? new OrderScrollAnchor(target, conditions) : null;
  }

  /**
   * 每次快照调：返回目标下标（≥0：页面在布局就绪后顶对齐一次，然后调 aligned）、WAIT（继续等）或 DROPPED（没有恢复任务 / 已放弃）。
   */
  resolve(items: OrderRecord[], conditions: string, phase: string, round: number = -1): number {
    const r: OrderScrollAnchor | null = this.restore;
    if (r === null) {
      if (this.aligning && round >= 0 && round !== this.boundRound) {
        // 目标已找到、等布局对齐期间开了新一轮查询（R3-02）：作废对齐任务，待执行的回调不得再滚动或持久化。
        this.cancelAlign();
      }
      return OrderScrollAnchor.DROPPED;
    }
    if (round >= 0 && this.boundRound < 0) {
      this.boundRound = round;
    }
    if (round >= 0 && round !== this.boundRound) {
      // 恢复等待期间开了新一轮查询（用户换了筛选或搜索、下拉刷新）：取消旧恢复任务，不用旧条件覆盖新条件。
      r.cancel();
      this.restore = null;
      this.aligning = false;
      this.anchorId = '';
      return OrderScrollAnchor.DROPPED;
    }
    const index: number = r.resolve(items, conditions, phase);
    if (index === OrderScrollAnchor.WAIT) {
      return index;
    }
    this.restore = null;
    if (index === OrderScrollAnchor.DROPPED) {
      this.aligning = false;
      if (r.droppedByConditions) {
        this.anchorId = '';
      }
      return index;
    }
    this.aligning = true;
    this.alignConditions = conditions;
    return index;
  }

  /**
   * 布局等待回调执行前调（R3-02；共性第 24 条）：ticket 为排入回调时的任务编号，round、conditions 为此刻列表的查询轮次与条件（编码）。
   * 仍是同一恢复任务、同一轮次、同一条件才解冻并返回 true（页面随后滚动并持久化）；任务已换（begin / reset / 已取消）返回 false 不改动；
   * 轮次或条件变了则取消对齐（锚点清空、解冻）并返回 false。返回 false 时页面不得滚动或持久化。
   */
  commitAlign(ticket: number, round: number, conditions: string, topId: string | null = null,
    offset: number = NaN): boolean {
    if (!this.aligning || ticket !== this.task) {
      return false;
    }
    if ((round >= 0 && round !== this.boundRound) || conditions !== this.alignConditions) {
      this.cancelAlign();
      return false;
    }
    if (topId !== null && this.movedFromBaseline(topId, offset)) {
      // R1-04（共性第 39 条）：延迟对齐执行前再复核一次实际位置——等待期间用户已滚动（哪怕顶部还是同一张卡片）就取消恢复，
      // 按用户此刻的位置记录锚点，不把用户拉回旧目标。
      this.userScrolled(topId);
      return false;
    }
    this.aligning = false;
    this.baselineTop = null;
    this.baselineOffset = NaN;
    return true;
  }

  /** 取消等待中的对齐（新一轮查询、条件变化）：任务作废、锚点清空并解冻。 */
  private cancelAlign(): void {
    this.task++;
    this.aligning = false;
    this.anchorId = '';
    this.baselineTop = null;
    this.baselineOffset = NaN;
  }

  /** 页面完成了顶对齐（或布局失败退回顶部）：解冻。 */
  aligned(): void {
    this.aligning = false;
  }

  /**
   * 滚动后顶部可见的订单（在顶部为空串）；返回是否变了（变了要持久化）。恢复进行中（冻结）：第一次调用建立位置基准；之后顶部偏离基准
   * 即视为用户已滚动（含补页期间），取消恢复任务（待执行的对齐回调经 commitAlign 失效）、解冻，并按用户的新位置记录锚点。
   */
  visible(orderId: string): boolean {
    return this.observe(orderId, NaN);
  }

  /**
   * 列表位置变化（onScrollIndex 与 onDidScroll 都调）：orderId 为此刻顶部可见的订单（在顶部为空串），offset 为实际滚动偏移（像素）。
   * 恢复进行中：第一次调用建立基准（顶部订单 + 偏移）；之后顶部订单或偏移（超过 SCROLL_EPSILON）偏离基准即视为用户已滚动——含同一
   * 卡片内的小幅滚动、惯性与无障碍滚动（R1-04，APP-08 共性第 39 条）——取消恢复任务、解冻，按用户的新位置记录锚点并返回 true。
   * 没有恢复任务时：顶部订单变了才返回 true（要持久化）。
   */
  observe(orderId: string, offset: number): boolean {
    if (this.frozen) {
      if (this.baselineTop === null) {
        this.baselineTop = orderId;
        this.baselineOffset = offset;
        return false;
      }
      if (Number.isNaN(this.baselineOffset) && !Number.isNaN(offset)) {
        // 基准由只带顶部订单的调用建立：第一次拿到偏移时补上（此前没有可比较的偏移）。
        this.baselineOffset = offset;
      }
      if (!this.movedFromBaseline(orderId, offset)) {
        return false;
      }
      this.userScrolled(orderId);
      return true;
    }
    if (orderId === this.anchorId) {
      return false;
    }
    this.anchorId = orderId;
    return true;
  }

  /** 此刻位置是否偏离基准（还没有基准时不算）。 */
  private movedFromBaseline(orderId: string, offset: number): boolean {
    if (this.baselineTop === null) {
      return false;
    }
    if (orderId !== this.baselineTop) {
      return true;
    }
    return !Number.isNaN(offset) && !Number.isNaN(this.baselineOffset)
      && Math.abs(offset - this.baselineOffset) > OrderAnchorKeeper.SCROLL_EPSILON;
  }

  /** 用户已滚动：取消恢复任务（待执行的对齐回调经 commitAlign 失效）、解冻，按用户的新位置记录锚点。 */
  private userScrolled(orderId: string): void {
    const r: OrderScrollAnchor | null = this.restore;
    if (r !== null) {
      r.cancel();
    }
    this.restore = null;
    this.aligning = false;
    this.task++;
    this.baselineTop = null;
    this.baselineOffset = NaN;
    this.anchorId = orderId;
  }


  /** 会话变化：清空并解冻。 */
  reset(): void {
    this.task++;
    this.anchorId = '';
    this.restore = null;
    this.aligning = false;
    this.boundRound = -1;
    this.baselineTop = null;
    this.baselineOffset = NaN;
  }
}

/**
 * 订单页状态（进程回收后恢复）的编码：账号短标识 + 条件 + 滚动锚点 + 输入框文字。AppOrders 读写偏好时用它，测试用同一份编解码。
 */
export class OrderPageState {
  readonly account: string;
  readonly conditions: string;
  readonly anchor: string;
  readonly input: string;
  /** 归属世代哈希（F-HM-25）：写入时的账号与持久化归属世代的哈希；没有为空串。 */
  readonly generation: string;

  constructor(account: string, conditions: string, anchor: string, input: string, generation: string = '') {
    this.account = account;
    this.conditions = conditions;
    this.anchor = anchor;
    this.input = input;
    this.generation = generation;
  }

  encode(): string {
    const record: Record<string, JSONValue> = {};
    record['account'] = this.account;
    record['conditions'] = this.conditions;
    record['anchor'] = this.anchor;
    record['input'] = this.input;
    if (this.generation.length > 0) {
      record['gen'] = this.generation;
    }
    return JSON.stringify(record);
  }

  static decode(text: string | null): OrderPageState | null {
    if (text === null) {
      return null;
    }
    try {
      const r: OrderRecord | null = OrderJson.objectOf(JSON.parse(text) as Object);
      if (r === null) {
        return null;
      }
      return new OrderPageState(OrderJson.text(r, 'account') ?? '', OrderJson.text(r, 'conditions') ?? '',
        OrderJson.text(r, 'anchor') ?? '', OrderJson.text(r, 'input') ?? '', OrderJson.text(r, 'gen') ?? '');
    } catch (e) {
      return null;
    }
  }
}

/**
 * 订单 Tab 根的页面状态恢复与持久化（R3-01；共性第 23 条）。订单 Tab 根在冷启动时会被隐藏挂载（AppShell 同时构建各 Tab 根），
 * 页面 aboutToAppear → apply → onPersist 早于 Tab 第一次显示时的恢复：恢复决策（读取并校验同一账号的记录、装锚点与条件）完成之前，
 * persist 一律不写盘，初始的默认条件与空锚点不得覆盖恢复记录。AppOrders 读写偏好时用它，测试用同一份。
 */
export class OrderPageRestorer {
  private readonly read: () => string | null;
  private readonly write: (value: string | null) => void;
  private readonly account: () => string | null;
  readonly keeper: OrderAnchorKeeper;
  private decided: boolean = false;
  /** 清理时没确认删掉恢复记录（共性第 36 条）：本进程内不再按落盘记录恢复，恢复时先重试删除。 */
  private wipePending: boolean = false;
  /** 恢复出的输入框文字（同一账号的记录才有）。 */
  input: string = '';
  /** 写盘用的固定账号（恢复决策、会话换代时一次性取得；FU-HM-0712）。 */
  private owner: string | null = null;
  /**
   * 与 owner 同时固定的持久化登录世代（F-HM-25 第 1 轮修复 R1-01）：读不出为 null（未知，不写盘、不恢复）。之后写盘时当前登录世代
   * 已变（同账号重新登录、清空通知还没到）不写——旧会话的条件不记到新登录名下。
   */
  private ownerEpoch: string | null = null;
  /**
   * 令牌存储里的持久化登录世代（F-HM-25 第 1 轮修复 R1-01；App 传 SecureSessionTokens.loginEpoch，为 null 时不绑登录世代，旧用法）。
   * 记录的归属世代哈希 = 账号 + 持久化登录世代 + 订单偏好里的清理计数（附加项）：同账号重新登录换了登录世代，旧记录即使清理计数、
   * 待清理标记、删除全都没写进去也对不上；读不出（抛错或为 null）按未知处理，禁止恢复。
   */
  private readonly loginEpoch: (() => string | null) | null;
  /**
   * 持久化的待清理标记与归属世代（F-HM-25；App 传 OrderPageStateStore.marks()，为 null 时只有本进程内存标记，旧用法）：
   * - 待清理标记落在与记录同一个命名空间：写失败、删不掉时先放进存储内存（putSync），之后任何一次同命名空间的 flush 把失败写入顺带
   *   落盘时，标记也一起落盘；单独重建 Restorer（同一进程共用同一份偏好实例）或进程重启都能读到，恢复前先重试删除、不按记录恢复；
   * - 记录带归属世代哈希（账号 + 持久化归属世代）：写失败、清理（会话换代、撤回同意、切环境）时归属世代先加一，旧记录即使之后被
   *   顺带落盘，读取时哈希对不上也不恢复；读不出世代按不恢复处理。
   */
  private readonly marks: OrderRestoreMarks | null;

  constructor(read: () => string | null, write: (value: string | null) => void, account: () => string | null,
    keeper: OrderAnchorKeeper, marks: OrderRestoreMarks | null = null, loginEpoch: (() => string | null) | null = null) {
    this.read = read;
    this.write = write;
    this.account = account;
    this.keeper = keeper;
    this.marks = marks;
    this.loginEpoch = loginEpoch;
  }

  /**
   * 归属世代哈希：账号短标识、持久化登录世代与清理计数合在一起再取短标识（不出现 user_id 与登录世代原文）。
   * 没接登录世代时 epoch 为空串。
   */
  static generationHash(account: string, epoch: string, generation: number): string {
    return OrderStaleCache.accountTag(OrderStaleCache.accountTag(account) + '|' + epoch + '|' + String(generation));
  }

  /** 此刻的持久化登录世代：没接为空串；读不出（抛错、为 null 或空）为 null（未知）。 */
  private currentEpoch(): string | null {
    const source: (() => string | null) | null = this.loginEpoch;
    if (source === null) {
      return '';
    }
    try {
      const epoch: string | null = source();
      return epoch !== null && epoch.length > 0 ? epoch : null;
    } catch (e) {
      return null;
    }
  }

  /** 固定写盘归属：账号与持久化登录世代同时取（账号为 null 时不读登录世代）。 */
  private fixOwner(): void {
    const account: string | null = this.account();
    this.owner = account;
    this.ownerEpoch = account === null ? null : this.currentEpoch();
  }

  /** 绑定的哈希：账号 + 登录世代 + 清理计数；任一来源读不出为 null（未知）。都没接时为空串（旧用法，不核对）。 */
  private bindingHash(account: string, epoch: string): string | null {
    const marks: OrderRestoreMarks | null = this.marks;
    if (marks === null && this.loginEpoch === null) {
      return '';
    }
    let generation: number = 0;
    if (marks !== null) {
      try {
        generation = marks.generation();
      } catch (e) {
        return null;
      }
    }
    return OrderPageRestorer.generationHash(account, epoch, generation);
  }

  /** 持久化的待清理标记（读不出按有标记处理）；没有持久化标记时为 false。 */
  private persistedPending(): boolean {
    const marks: OrderRestoreMarks | null = this.marks;
    if (marks === null) {
      return false;
    }
    try {
      return marks.pending();
    } catch (e) {
      return true;
    }
  }

  /** 记下待清理：内存一定记，持久化尽力写（写不进时存储内存里的值仍会随之后的 flush 落盘）。 */
  private markPending(): void {
    this.wipePending = true;
    const marks: OrderRestoreMarks | null = this.marks;
    if (marks !== null) {
      try {
        marks.setPending(true);
      } catch (e) {
        // 尽力：内存标记仍阻断本进程恢复。
      }
    }
  }

  /** 归属世代加一（尽力）：之前写下的记录（含之后被顺带落盘的失败写入）一律作废。 */
  private advanceGeneration(): void {
    const marks: OrderRestoreMarks | null = this.marks;
    if (marks === null) {
      return;
    }
    try {
      marks.setGeneration(marks.generation() + 1);
    } catch (e) {
      // 尽力：待清理标记另行阻断恢复。
    }
  }

  /**
   * 记录的归属世代哈希与当前账号、持久化登录世代、清理计数相符（都没接时不核对）。登录世代或清理计数读不出：不恢复。
   */
  private generationMatches(saved: OrderPageState, account: string, epoch: string | null): boolean {
    if (this.marks === null && this.loginEpoch === null) {
      return true;
    }
    if (epoch === null) {
      return false;
    }
    const expected: string | null = this.bindingHash(account, epoch);
    return expected !== null && expected.length > 0 && saved.generation === expected;
  }

  /** 恢复决策已完成（之后才允许持久化）。 */
  get restoreDecided(): boolean {
    return this.decided;
  }

  /**
   * Tab 第一次显示：读取并校验恢复记录（同一账号的才用；路由 scope 与记录不同则不恢复条件），先装锚点再装条件（list.restore 会同步通知
   * 页面并持久化，恢复进行中写的仍是原锚点，R2-05）；没有可恢复的条件时从顶部开始。
   */
  restore(list: OrderListController, routeScope: string | null): void {
    if (this.wipePending || this.persistedPending()) {
      // 上次清理没删掉（本进程内存标记，或 F-HM-25 持久化的待清理标记）：先重试删除；无论结果都不按这份记录恢复（禁止恢复，共性第 36 条）。
      this.wipePending = !this.wipe();
    }
    let saved: OrderPageState | null = null;
    if (!this.wipePending) {
      try {
        saved = OrderPageState.decode(this.read());
      } catch (e) {
        // 存储打不开 / 读取失败（R2-01）：不恢复，从顶部开始。
        saved = null;
      }
    }
    this.fixOwner();
    const account: string | null = this.owner;
    let conditions: OrderListConditions | null = null;
    let anchor: string = '';
    this.input = '';
    if (saved !== null && account !== null && saved.account === OrderStaleCache.accountTag(account)
      && this.generationMatches(saved, account, this.ownerEpoch)) {
      conditions = OrderListConditions.decode(saved.conditions);
      this.input = saved.input;
      anchor = saved.anchor;
    }
    if (conditions !== null && routeScope !== null && routeScope !== conditions.scope) {
      conditions = null;
    }
    this.keeper.begin(conditions !== null ? anchor : '', conditions !== null ? conditions.encode() : '');
    this.decided = true;
    list.restore(conditions, routeScope);
  }

  /** 页面状态写盘（结果见 save）。 */
  persist(list: OrderListController): void {
    this.save(list);
  }

  /**
   * 页面状态写盘：账号短标识 + 条件 + 滚动锚点。恢复决策完成前（隐藏挂载的初始快照）不写。
   * FU-HM-0712（共性第 65 条）：账号标签用恢复决策 / 会话换代时固定的账号（owner），不在写盘时重读当前会话打标签；列表已不属于当前
   * 会话、或当前账号已不是 owner（新令牌已保存、清空通知还没到）时不写——不把旧账号的条件（可能含完整订单号）记到新账号名下。
   * 第 2 轮评审 R2-02（APP-08 共性第 40、48 条）：写入经同步落盘接口（OrderPageStateStore.write → put + flushSync），返回明确结果：
   * SAVED = 已确认落盘；SKIPPED = 按规则不写；FAILED = 写入或落盘失败——不算保存完成，记 wipePending（本进程内不按这份记录恢复，
   * 下次恢复前先重试删除），交调用方报告。
   */
  save(list: OrderListController): string {
    if (!this.decided || !list.ownsSession()) {
      return OrderPersistResult.SKIPPED;
    }
    const owner: string | null = this.owner;
    if (owner === null || this.account() !== owner) {
      return OrderPersistResult.SKIPPED;
    }
    // R1-01：写盘归属的登录世代未知，或当前登录世代已不是固定时的那个（同账号重新登录）：不写。
    const epoch: string | null = this.ownerEpoch;
    if (epoch === null || this.currentEpoch() !== epoch) {
      return OrderPersistResult.SKIPPED;
    }
    try {
      const generation: string | null = this.bindingHash(owner, epoch);
      if (generation === null) {
        throw new Error('order restore generation unreadable');
      }
      this.write(new OrderPageState(OrderStaleCache.accountTag(owner), list.conditions().encode(), this.keeper.anchor,
        '', generation).encode());
    } catch (e) {
      // F-HM-25：失败写入可能已进存储内存、之后被同命名空间的 flush 顺带落盘——归属世代先加一使它作废，再记持久化待清理标记。
      this.advanceGeneration();
      this.markPending();
      return OrderPersistResult.FAILED;
    }
    return OrderPersistResult.SAVED;
  }

  /** 有没确认的写入或删除（共性第 36、40 条）：本进程内不按落盘记录恢复。 */
  get unconfirmed(): boolean {
    return this.wipePending;
  }

  /**
   * 会话变化（共性第 19 条，状态同步的清空通知里调）：删记录、清锚点与待恢复输入，并按新会话重取固定账号（A 类）。
   * FU-HM-0712（APP-08 共性第 45 条）：删除没确认（写或读回失败）时与 wipe 一样记 wipePending——本进程内不再按落盘记录恢复。
   */
  reset(): void {
    this.wipe();
    this.fixOwner();
  }

  /**
   * 撤回同意 / 切换环境的清理（APP-08 共性第 36 条）：恢复记录可能含完整订单号搜索词——先作废内存里的锚点与待恢复输入，再删落盘记录，
   * 读回确认已删才返回 true（false 时清理器报失败，撤回清理不算完成、冷启动重试）。
   */
  wipe(): boolean {
    this.keeper.reset();
    this.input = '';
    // F-HM-25：先让归属世代加一——删除即使失败，旧记录之后也对不上哈希。
    this.advanceGeneration();
    let ok: boolean = false;
    try {
      this.write(null);
      ok = this.read() === null;
    } catch (e) {
      ok = false;
    }
    if (!ok) {
      this.markPending();
      return false;
    }
    this.wipePending = false;
    const marks: OrderRestoreMarks | null = this.marks;
    if (marks !== null) {
      try {
        marks.setPending(false);
      } catch (e) {
        // 标记清不掉：下次恢复前多删一次，无害。
      }
    }
    return true;
  }
}

/** 页面状态写盘的结果（R2-02）。 */
export class OrderPersistResult {
  /** 已确认同步落盘。 */
  static readonly SAVED: string = 'saved';
  /** 按规则不写（恢复决策前、会话已变、账号不是固定账号）。 */
  static readonly SKIPPED: string = 'skipped';
  /** 写入或落盘失败：不算保存完成。 */
  static readonly FAILED: string = 'failed';
}

/**
 * 订单页面恢复记录的持久化待清理标记与归属世代（F-HM-25）。读、写失败一律抛错。
 * App 用 OrderPageStateStore.marks()：与恢复记录同一个偏好命名空间、相邻的两个键。
 */
export interface OrderRestoreMarks {
  /** 归属世代（没有为 0）。 */
  generation(): number;

  setGeneration(value: number): void;

  /** 待清理标记。 */
  pending(): boolean;

  setPending(pending: boolean): void;
}

/** 页面恢复记录所在的键值存储（App 用系统偏好适配）。读、写、删失败一律抛错。 */
export interface OrderPageStateKv {
  /** 读取：没有这个键返回 null。 */
  get(key: string): string | null;

  /** 写入并同步落盘（flushSync）；失败抛错（R2-02）。 */
  put(key: string, value: string): void;

  /** 删除并同步落盘（flushSync）。 */
  remove(key: string): void;
}

/**
 * 订单页面恢复记录的读写（FU-HM-0710 R2-01，APP-08 共性第 28、36 条）。区分「记录不存在」（read 返回 null）与「存储打不开 / 读取失败」
 * （read、write(null) 抛错）：清理路径（OrderPageRestorer.wipe）据此只在确认删除落盘、读回确实没有时才算完成；存储打不开时删除与读回
 * 都抛错，清理报失败、保留待清理状态并禁止恢复——不能因为「打不开所以读回 null」误判为删除成功。
 * 第 2 轮评审 R2-02：普通持久化（非 null 写入）失败同样向上抛（不再吞掉），由 OrderPageRestorer.save 记为 FAILED、不算保存完成。
 */
export class OrderPageStateStore {
  private readonly open: () => OrderPageStateKv | null;
  private readonly key: string;

  constructor(open: () => OrderPageStateKv | null, key: string) {
    this.open = open;
    this.key = key;
  }

  private kv(): OrderPageStateKv {
    let kv: OrderPageStateKv | null = null;
    try {
      kv = this.open();
    } catch (e) {
      kv = null;
    }
    if (kv === null) {
      throw new Error('page state storage unavailable');
    }
    return kv;
  }

  /** 读取：记录不存在为 null；存储打不开或读取失败抛错。 */
  read(): string | null {
    const value: string | null = this.kv().get(this.key);
    return value !== null && value.length > 0 ? value : null;
  }

  /** 写入并同步落盘；value 为 null 时删除并落盘——存储打不开、写入 / 删除或落盘失败都抛错（R2-02：调用方据此报失败）。 */
  write(value: string | null): void {
    this.writeKey(this.key, value);
  }

  private writeKey(key: string, value: string | null): void {
    if (value === null) {
      this.kv().remove(key);
      return;
    }
    this.kv().put(key, value);
  }

  /**
   * 持久化的待清理标记与归属世代（F-HM-25）：同一命名空间里 `<key>.wipe` 与 `<key>.gen` 两个键，写入同样 put + flushSync。
   * 落盘失败时值已进存储内存（同一进程重建的 Restorer 读得到），之后同命名空间的任何 flush 都会把它与失败写入一起落盘。
   */
  marks(): OrderRestoreMarks {
    return new StoreRestoreMarks((k: string): string | null => this.kv().get(k),
      (k: string, v: string | null): void => this.writeKey(k, v), this.key);
  }
}

class StoreRestoreMarks implements OrderRestoreMarks {
  private readonly getFn: (key: string) => string | null;
  private readonly writeFn: (key: string, value: string | null) => void;
  private readonly genKey: string;
  private readonly wipeKey: string;

  constructor(get: (key: string) => string | null, write: (key: string, value: string | null) => void, key: string) {
    this.getFn = get;
    this.writeFn = write;
    this.genKey = key + '.gen';
    this.wipeKey = key + '.wipe';
  }

  generation(): number {
    const raw: string | null = this.getFn(this.genKey);
    if (raw === null || raw.length === 0) {
      return 0;
    }
    const value: number = Number(raw);
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error('order restore generation unreadable');
    }
    return value;
  }

  setGeneration(value: number): void {
    this.writeFn(this.genKey, String(value));
  }

  pending(): boolean {
    const raw: string | null = this.getFn(this.wipeKey);
    return raw !== null && raw.length > 0;
  }

  setPending(pending: boolean): void {
    this.writeFn(this.wipeKey, pending ? '1' : null);
  }
}

/**
 * 系统偏好上的页面恢复记录存取（生产适配层；R2-02，APP-08 共性第 40、48 条）：写入与删除都是 putSync / deleteSync 之后 flushSync
 * 同步落盘，任一步失败照常抛出（不再「flush() 异步 + 空 catch」），交 OrderPageStateStore / OrderPageRestorer 区分已落盘与只改了内存。
 * 用四个同步函数构造（测试可注入落盘失败）；App 用 of(preferences) 接系统偏好。
 */
export class FlushedPageStateKv implements OrderPageStateKv {
  private readonly getFn: (key: string) => string | null;
  private readonly putFn: (key: string, value: string) => void;
  private readonly deleteFn: (key: string) => void;
  private readonly flushFn: () => void;

  constructor(get: (key: string) => string | null, put: (key: string, value: string) => void,
    del: (key: string) => void, flush: () => void) {
    this.getFn = get;
    this.putFn = put;
    this.deleteFn = del;
    this.flushFn = flush;
  }

  /** 系统偏好（getSync / putSync / deleteSync API 11，flushSync API 14，均不高于 API 20）。 */
  static of(p: preferences.Preferences): FlushedPageStateKv {
    return new FlushedPageStateKv((key: string): string | null => {
      const value: preferences.ValueType = p.getSync(key, '');
      return typeof value === 'string' ? value : null;
    }, (key: string, value: string): void => {
      p.putSync(key, value);
    }, (key: string): void => {
      p.deleteSync(key);
    }, (): void => {
      p.flushSync();
    });
  }

  get(key: string): string | null {
    return this.getFn(key);
  }

  put(key: string, value: string): void {
    this.putFn(key, value);
    this.flushFn();
  }

  remove(key: string): void {
    this.deleteFn(key);
    this.flushFn();
  }
}
