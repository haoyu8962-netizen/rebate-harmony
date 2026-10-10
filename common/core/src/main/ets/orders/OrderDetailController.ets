// APP-08 订单详情执行器（OrderDetail 路由；brief §2.5）。30701 显示空态（不重试）；42901 按 Retry-After 禁用【重试】；5xxxx 带 trace6；
// 传输层失败时用最近 30 条详情缓存。详情页出栈的同步出口（onWillDisappear）调 leave：作废请求、取消传输，之后的响应不改任何状态
// （APP-04 第 28、47 条，APP-06a 第 39 条）。
import { ApiRequest, ApiResult } from '../network/ApiClient';
import { SearchApiPort } from '../search/SearchController';
import { OrderJson, OrderRecord } from './OrderJson';
import {
  guardedOrder, OrderErrorView, OrderOutcome, OrderPhase, OrderRateGate
} from './OrderListController';
import { OrderErrorAction } from './OrderPresentation';
import { OrderCacheEntry, OrderStaleCache } from './OrderStaleCache';

type JSONValue = Object | null;

/** 详情页的一次快照。 */
export class OrderDetailSnapshot {
  /** loading / content / empty（30701）/ error。 */
  phase: string = OrderPhase.LOADING;
  detail: OrderRecord | null = null;
  error: OrderErrorView | null = null;
  stale: boolean = false;
  staleFetchedAt: number = 0;
  blocked: boolean = false;
  /** 显示缓存时的刷新在途（R3-04：页面 Refresh 的转圈状态；结果到达即清）。 */
  refreshing: boolean = false;
  failureSeq: number = 0;
  shownSeq: number = 0;
}

export class OrderDetailDeps {
  readonly api: SearchApiPort;
  cache: OrderStaleCache | null = null;
  clock: () => number = Date.now;
  scope: () => string = () => '';
  /** 按会话共享的 42901 闸门（与列表、待跟单卡同一份；null 时自建）。 */
  gate: OrderRateGate | null = null;

  constructor(api: SearchApiPort) {
    this.api = api;
  }
}

export class OrderDetailController {
  private readonly d: OrderDetailDeps;
  private orderId: string = '';
  private seq: number = 0;
  private current: number = 0;
  private owners: (() => boolean)[] = [];
  private left: boolean = false;
  private boundScope: string = '';
  private readonly gate: OrderRateGate;
  private readonly unsubscribe: () => void;
  private state: OrderDetailSnapshot = new OrderDetailSnapshot();
  onChange: (snapshot: OrderDetailSnapshot) => void = (_s: OrderDetailSnapshot) => {
  };
  /** 详情请求成功（G17：从详情返回时列表只替换这一行）。 */
  onLoaded: (detail: OrderRecord) => void = (_d: OrderRecord) => {
  };

  constructor(deps: OrderDetailDeps) {
    this.d = deps;
    this.gate = deps.gate ?? new OrderRateGate(deps.clock, deps.scope);
    this.state.blocked = this.gate.active;
    this.unsubscribe = this.gate.subscribe((): void => {
      if (!this.left && this.state.blocked !== this.gate.active) {
        this.emit();
      }
    });
  }

  get snapshot(): OrderDetailSnapshot {
    return this.state;
  }

  get isLeft(): boolean {
    return this.left;
  }

  load(orderId: string): void {
    this.orderId = orderId;
    this.fetch();
  }

  /** 【重试】：30701 不重试；42901 禁用中不发。 */
  retry(): boolean {
    const s: OrderDetailSnapshot = this.state;
    if (this.left || this.gate.active || (s.phase !== OrderPhase.ERROR && !s.stale)) {
      return false;
    }
    this.fetch();
    return true;
  }

  /**
   * 显示断网缓存时的刷新入口（R3-04；共性第 26 条；页面下拉）：只在 stale 内容态可用，走同一条重试路径（共享 42901 闸门禁用中不发）；
   * 成功后更新内容与缓存并移除提示条，失败时保留缓存与提示条。
   */
  refreshStale(): boolean {
    if (this.state.phase !== OrderPhase.CONTENT || !this.state.stale) {
      return false;
    }
    return this.retry();
  }

  /** 页面出栈（同步出口）：作废请求并取消传输。 */
  leave(): void {
    if (this.left) {
      return;
    }
    this.left = true;
    this.begin();
    this.unsubscribe();
    // APP-08 共性第 30 条：同步结束下拉刷新（请求已取消、迟到响应被丢弃，不能让 refreshing 依赖已取消的响应）。
    this.endRefreshing();
  }

  private endRefreshing(): void {
    if (this.state.refreshing) {
      this.state.refreshing = false;
      try {
        this.onChange(this.state);
      } catch (e) {
        // 页面回调出错不影响执行器。
      }
    }
  }

  /**
   * 会话变化（换账号、登出、会话失效、撤回同意、切换环境；R1-01）：作废请求，并同步清空已显示的详情快照、通知视图（页面回到空白关闭态
   * phase=idle），之后不再加载；旧账号的订单号与金额不再留在页面上。App 另把旧会话的详情页移出导航栈。
   */
  resetForSession(): void {
    if (!this.left) {
      // 不经 leave() 的刷新态通知：下面立即换成空白快照并通知，不再把旧会话的内容多发一次。
      this.left = true;
      this.begin();
      this.unsubscribe();
    }
    const s: OrderDetailSnapshot = new OrderDetailSnapshot();
    s.phase = OrderPhase.IDLE;
    s.failureSeq = this.state.failureSeq;
    this.state = s;
    this.onChange(s);
  }

  /** 这一刻的归属是否仍有效（页面回调执行前复核用）。 */
  alive(): boolean {
    return !this.left && this.d.scope() === this.boundScope;
  }

  private fetch(): void {
    if (this.left || this.orderId.length === 0) {
      return;
    }
    const seq: number = this.begin();
    this.boundScope = this.d.scope();
    const s: OrderDetailSnapshot = this.state;
    const held: OrderErrorView | null = this.gate.view;
    if (this.gate.active) {
      // 42901 禁用期内（任一订单请求触发的）：不发请求，显示限流错误，【重试】置灰（R1-02）。
      s.refreshing = false;
      s.failureSeq++;
      s.error = held ?? this.gate.heldView(OrderErrorAction.DETAIL, false);
      if (!s.stale) {
        s.detail = null;
        s.phase = OrderPhase.ERROR;
      }
      this.emit();
      return;
    }
    if (!s.stale) {
      s.phase = OrderPhase.LOADING;
    }
    s.refreshing = s.stale;
    s.error = null;
    this.emit();
    const path: Record<string, string> = {};
    path['order_id'] = this.orderId;
    const request: ApiRequest = new ApiRequest('getOrder', path);
    const owner: () => boolean = (): boolean => this.current === seq && this.alive();
    request.owner = owner;
    request.sendAllowed = this.gate.sendAllowed;
    this.owners.push(owner);
    guardedOrder(this.d.api.request(request)).then((result: ApiResult) => {
      if (this.current !== seq || !this.alive()) {
        return;
      }
      this.owners = [];
      s.shownSeq = seq;
      s.refreshing = false;
      const outcome: OrderOutcome = new OrderOutcome(result);
      if (outcome.sendBlocked) {
        // 自动重试、重签、刷新后的重放被共享闸门拦下（R2-01）：与禁用期内打开同样显示限流错误，保留正在显示的缓存。
        s.failureSeq++;
        s.error = this.gate.heldView(OrderErrorAction.DETAIL, false);
        if (!s.stale) {
          s.detail = null;
          s.phase = OrderPhase.ERROR;
        }
        this.emit();
        return;
      }
      if (outcome.ok) {
        const detail: OrderRecord | null = OrderJson.detail(result.data);
        if (detail !== null) {
          s.detail = detail;
          s.phase = OrderPhase.CONTENT;
          s.stale = false;
          s.staleFetchedAt = 0;
          const cache: OrderStaleCache | null = this.d.cache;
          if (cache !== null) {
            cache.saveDetail(this.orderId, detail);
          }
          this.emit();
          this.onLoaded(detail);
          return;
        }
      }
      const cache: OrderStaleCache | null = this.d.cache;
      const cached: OrderCacheEntry | null = cache !== null && outcome.transport && !OrderOutcome.cancelled(result)
        ? cache.loadDetail(this.orderId) : null;
      const cachedDetail: OrderRecord | null = cached === null ? null : OrderJson.detail(cached.data);
      const action: Record<string, JSONValue> = OrderErrorAction.map(OrderErrorAction.DETAIL,
        outcome.ok || outcome.transport ? (outcome.ok ? 50001 : null) : outcome.code, outcome.transport,
        outcome.headers, result.traceId, cachedDetail !== null, false);
      const view: OrderErrorView = new OrderErrorView(action, outcome.code, result.traceId);
      s.failureSeq++;
      if (view.actionRaw === OrderErrorAction.SHOW_STALE && cached !== null && cachedDetail !== null) {
        s.detail = cachedDetail;
        s.stale = true;
        s.staleFetchedAt = cached.fetchedAt;
        s.phase = OrderPhase.CONTENT;
        this.emit();
        return;
      }
      s.detail = null;
      s.stale = false;
      s.error = view;
      s.phase = view.actionRaw === OrderErrorAction.EMPTY_30701 ? OrderPhase.EMPTY : OrderPhase.ERROR;
      if (view.actionRaw === OrderErrorAction.RETRY_AFTER && view.disableMs > 0) {
        this.gate.start(view.disableMs, view);
      }
      this.emit();
    });
  }

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

  private emit(): void {
    this.state.blocked = this.gate.active;
    this.onChange(this.state);
  }
}
