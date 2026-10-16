// FU-HM-0725 测试设施（测试作者，2026-10-16；第 2 版按 tests-review T-01..T-14 修订）。
// 本文件只用现有接口（实现前可编译）：订单的生产接线 OrdersApp、入口计数端口、按条件变化的订单假服务、有底视口的滚动。
// 资金页、首页身份键、输入框、视图事件适配器等依赖第 2 版接口约定（N1–N4）的设施在 FollowupHM0725ContractRig.ets。
// 不改产品代码，不加产品侧钩子。
import {
  ApiClientSearchPort, ApiRequest, ApiResult, OrderAnchorKeeper, OrderListController, OrderListDeps, OrderListSnapshot,
  OrderPageRestorer, OrderPageStateKv, OrderPageStateStore, OrderSessionHub, OrderSessionReconciler, OrderStaleCache,
  OrderSyncResult, OrderTabCoordinator, OrderRecord, SearchApiPort, SessionIdentity, TransportRequest, TransportResponse
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { detail, page, shareOrder } from './OrderIntegration.test';
import { BoundedViewport, ids, PAGE_KEY, Proc, rows, SEED_Q } from './FollowupHM0724Rig';

/** 默认条件第一页：12 单（O1..O12），视口可滚到 O2 以下（最大偏移 912vp）。 */
export const TWELVE: string[] = ids(1, 12);
/** 旧记录条件（q = SEED_Q）的结果：与默认结果不同，用来判断显示的是哪份响应。 */
export const SEED_ROWS: string[] = ['O3', 'O4'];
/** 用户搜索 9988 的结果。 */
export const USER_ROWS: string[] = ['O9988'];

/**
 * listOrders / 详情的端口包装：request 入口同步计数（没启动的请求直接看得到）；consumed 在控制器自己的回调之后计数
 * （then 按登记顺序执行，下一个微任务再挂），= 已被控制器消费或丢弃的列表响应数。
 */
export class CountingOrdersPort implements SearchApiPort {
  private readonly inner: SearchApiPort;
  listRequests: number = 0;
  listConsumed: number = 0;

  constructor(inner: SearchApiPort) {
    this.inner = inner;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    const p: Promise<ApiResult> = this.inner.request(request);
    if (request.operationId === 'listOrders') {
      this.listRequests++;
      Promise.resolve().then((): void => {
        p.then((): void => {
          this.listConsumed++;
        }, (): void => {
          this.listConsumed++;
        });
      });
    }
    return p;
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }

  /** 已发出的列表请求都已结算。 */
  get listQuiet(): boolean {
    return this.listRequests === this.listConsumed;
  }
}

/** 列表快照的指纹：phase / 条数 / q / 查询轮次 / 第一单（内容身份）。 */
export function fingerprint(s: OrderListSnapshot): string {
  const first: Object | null | undefined = s.items.length > 0 ? s.items[0]['order_id'] : null;
  return s.phase + '/' + s.items.length + '/' + (s.q ?? '') + '/r' + s.round + '/' + (typeof first === 'string' ? first : '');
}

/** 订单的生产接线（entry AppOrders.compose）：身份读真实 ApiClient 单快照；假服务的结果随条件变化。 */
export class OrdersApp {
  readonly p: Proc;
  readonly hub: OrderSessionHub;
  readonly cache: OrderStaleCache;
  readonly keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
  readonly restorer: OrderPageRestorer;
  readonly reconciler: OrderSessionReconciler;
  readonly list: OrderListController;
  readonly coordinator: OrderTabCoordinator;
  readonly port: CountingOrdersPort;
  /** list.onChange 收到的快照指纹（见 fingerprint）。 */
  readonly emitted: string[] = [];

  constructor(p: Proc) {
    this.p = p;
    this.port = new CountingOrdersPort(new ApiClientSearchPort(p.rig.client));
    const identity: () => SessionIdentity = (): SessionIdentity => p.rig.client.sessionIdentity(p.tokens);
    this.hub = new OrderSessionHub((): number => p.rig.nowMillis, (): string => p.scopeKey());
    this.cache = new OrderStaleCache(p.device.orderFiles, (): string | null => p.account(), (): number => p.rig.nowMillis,
      (): string | null => p.epoch());
    const store: OrderPageStateStore = new OrderPageStateStore((): OrderPageStateKv | null => p.device.prefs.kv(),
      PAGE_KEY);
    this.restorer = new OrderPageRestorer((): string | null => store.read(), (v: string | null): void => store.write(v),
      (): string | null => p.account(), this.keeper, store.marks(), (): string | null => p.epoch(), identity);
    this.reconciler = new OrderSessionReconciler(this.hub, this.cache, this.restorer, (): string => p.scopeKey(),
      (): string | null => p.account(), identity);
    const deps: OrderListDeps = new OrderListDeps(this.port);
    deps.cache = this.cache;
    deps.clock = (): number => p.rig.nowMillis;
    deps.scope = (): string => p.scopeKey();
    this.hub.attachList(deps);
    this.list = new OrderListController(deps);
    this.hub.setList(this.list);
    this.coordinator = new OrderTabCoordinator(this.reconciler, this.restorer, this.list);
    p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/orders/') >= 0 && r.url.indexOf('/v1/orders/pending-tracks') < 0) {
        const tail: string = r.url.substring(r.url.indexOf('/v1/orders/') + 11).split('?')[0];
        return Promise.resolve(envelope(0, detail(tail, '"order_no":"' + SEED_Q + '"')));
      }
      if (r.url.indexOf('scope=share') >= 0) {
        return Promise.resolve(envelope(0, page([shareOrder('S1', '3741****0001'), shareOrder('S2', '3741****0002')],
          null)));
      }
      if (r.url.indexOf('q=9988') >= 0) {
        return Promise.resolve(envelope(0, page(rows(USER_ROWS), null)));
      }
      if (r.url.indexOf('q=' + SEED_Q) >= 0) {
        return Promise.resolve(envelope(0, page(rows(SEED_ROWS), null)));
      }
      return Promise.resolve(envelope(0, page(rows(TWELVE), null)));
    };
  }

  /** AppOrders.compose：启动补清。 */
  compose(): boolean {
    return this.cache.retryPendingClear();
  }

  /** AppOrders 状态同步（订单 Tab 选中）。 */
  sync(): OrderSyncResult {
    return this.coordinator.sync(true);
  }

  /** 页面挂上 onChange 后开始记录快照（OrderListView.aboutToAppear 同样接管 onChange）。 */
  record(): void {
    this.emitted.length = 0;
    this.list.onChange = (s: OrderListSnapshot): void => {
      this.emitted.push(fingerprint(s));
    };
  }

  listRequests(): number {
    return this.port.listRequests;
  }

  /** 最近一次订单列表请求的 query（没有为 ''）。 */
  lastListQuery(): string {
    const list: TransportRequest[] = this.p.rig.server.received.filter((r: TransportRequest): boolean =>
    r.url.indexOf('/v1/orders') >= 0 && r.url.indexOf('/v1/orders/') < 0);
    if (list.length === 0) {
      return '';
    }
    const url: string = list[list.length - 1].url;
    const at: number = url.indexOf('?');
    return at < 0 ? '' : url.substring(at + 1);
  }

  /** 列表此刻显示的单号。 */
  shownIds(): string {
    return this.list.snapshot.items.map((r: OrderRecord): string => {
      const id: Object | null | undefined = r['order_id'];
      return typeof id === 'string' ? id as string : '?';
    }).join(',');
  }
}

/** 把有底视口滚到 offset（受最大可滚偏移限制，与 ArkUI List 一致）；返回实际偏移。 */
export function scrollTo(viewport: BoundedViewport, offset: number): number {
  viewport.offsetPx = Math.max(0, Math.min(offset, viewport.maxOffset()));
  return viewport.offsetPx;
}
