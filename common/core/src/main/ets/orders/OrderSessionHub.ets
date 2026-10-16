// APP-08 订单的会话协调（R1-01、R1-02；共性第 1、2 条）：App 一份，登记订单列表、打开着的详情页与各待跟单卡位置（订单列表顶部、商品详情、
// 搜索页），并持有按会话共享的 42901 闸门。会话归属变化（会话失效、登出、换账号、撤回同意、切换环境）时在状态同步的同步区里：
// 作废全部在途请求、清空列表与卡片、同步清空已显示的详情快照并通知视图、把旧会话的详情页移出导航栈、清掉闸门。
// 另持有会话级的待跟单卡关闭登记（PendingDismissals；R2-02、R2-03，共性第 14、15 条）：各卡片位置共用，任一位置关闭成功后其他位置
// 此前发出的查询迟到也不复活同一尝试。
import { OrderDetailController, OrderDetailDeps } from './OrderDetailController';
import { OrderListController, OrderListDeps, OrderPageRestorer, OrderRateGate } from './OrderListController';
import { CacheOwner, CachePartitionTracker, OrderStaleCache } from './OrderStaleCache';
import {
  PendingDismissals, PendingPushRowSignal, PendingTrackController, PendingTrackDeps
} from './PendingTrackController';

export class OrderSessionHub {
  static readonly DETAIL_ROUTE: string = 'OrderDetail';
  readonly gate: OrderRateGate;
  /** 会话级的待跟单卡关闭登记（各显示位置共用）。 */
  readonly dismissals: PendingDismissals = new PendingDismissals();
  /** 通知行「点过」的设备级广播（R3-03；各显示位置共用，不随会话清：本机申请记录是设备级的）。 */
  readonly pushRow: PendingPushRowSignal = new PendingPushRowSignal();
  private readonly scope: () => string;
  /** 把这个路由的页面全部移出导航栈（App：StackNavigator.remove）。 */
  removePages: (route: string) => void = (_r: string) => {
  };
  private list: OrderListController | null = null;
  private details: OrderDetailController[] = [];
  private pendings: PendingTrackController[] = [];
  /** 上次同步时的会话归属（undefined = 还没同步过）。 */
  private lastScope: string | undefined = undefined;

  constructor(clock: () => number, scope: () => string) {
    this.scope = scope;
    this.gate = new OrderRateGate(clock, scope);
  }

  /** 列表、详情、待跟单卡的依赖都接到这一份闸门。 */
  attachList(deps: OrderListDeps): void {
    deps.gate = this.gate;
  }

  attachDetail(deps: OrderDetailDeps): void {
    deps.gate = this.gate;
  }

  attachPending(deps: PendingTrackDeps): void {
    deps.gate = this.gate;
    deps.dismissals = this.dismissals;
    deps.pushRow = this.pushRow;
  }

  setList(list: OrderListController): void {
    this.list = list;
  }

  addDetail(controller: OrderDetailController): void {
    this.details.push(controller);
  }

  removeDetail(controller: OrderDetailController): void {
    this.details = this.details.filter((d: OrderDetailController): boolean => d !== controller);
  }

  addPending(controller: PendingTrackController): void {
    this.pendings.push(controller);
  }

  removePending(controller: PendingTrackController): void {
    this.pendings = this.pendings.filter((p: PendingTrackController): boolean => p !== controller);
  }

  get openDetails(): number {
    return this.details.length;
  }

  /**
   * 每次状态同步：会话归属变了就 reset 并返回 true（App 再删缓存、按需重载）；第一次同步只记下。
   */
  sync(): boolean {
    const scope: string = this.scope();
    const changed: boolean = this.lastScope !== undefined && this.lastScope !== scope;
    this.lastScope = scope;
    if (changed) {
      this.reset();
    }
    return changed;
  }

  /** 作废并清空全部订单页面（撤回同意、切换环境的清理前第一步也调）。 */
  reset(): void {
    this.gate.reset();
    this.dismissals.reset();
    this.list?.resetForSession();
    const details: OrderDetailController[] = this.details;
    this.details = [];
    for (const d of details) {
      d.resetForSession();
    }
    for (const p of this.pendings) {
      p.resetForSession();
    }
    if (details.length > 0) {
      try {
        this.removePages(OrderSessionHub.DETAIL_ROUTE);
      } catch (e) {
        // 导航出错：详情快照已清空，页面不再显示旧账号数据。
      }
    }
  }
}

/** OrderSessionReconciler.sync 的结局（AppOrders 据此清待恢复输入、重载订单 Tab）。 */
export class OrderSyncResult {
  /** 会话归属变了，或同账号的持久化登录世代换了（页面要按新会话重载）。 */
  readonly changed: boolean;
  /** 恢复记录按会话变化删了（待恢复输入一并清掉）。 */
  readonly wiped: boolean;
  /** 要删订单缓存但没删干净（待清理标记保留，之后每次同步重试）。 */
  readonly clearFailed: boolean;

  constructor(changed: boolean, wiped: boolean, clearFailed: boolean) {
    this.changed = changed;
    this.wiped = wiped;
    this.clearFailed = clearFailed;
  }
}

/**
 * 订单的会话对账（FU-HM-0723 末轮窄修 R3-01：AppOrders.sync 的判定挪进 Core，测试与生产同一入口）。每次状态同步调 sync：
 * - 订单缓存：会话归属变了且（账号或分区变了），或同账号的登录世代换了（归属键不含世代，计数没动时也要删）→ 删；都没有 → 补清上次没删完的。
 * - 恢复记录：会话归属按 wipesOnScopeChange 算会话变化，或同账号的已知登录世代换了 → 删；冷启动落定（含世代从未知到已知）→ 只重新固定
 *   写盘归属，不删。
 * - 先判定、后记录（上次的分区标签与归属键在判定完成后才更新）。
 */
export class OrderSessionReconciler {
  private readonly hub: OrderSessionHub;
  private readonly cache: OrderStaleCache | null;
  private readonly restorer: OrderPageRestorer;
  private readonly scope: () => string;
  private readonly account: () => string | null;
  private readonly partitions: CachePartitionTracker = new CachePartitionTracker();
  private lastScope: string | undefined = undefined;

  constructor(hub: OrderSessionHub, cache: OrderStaleCache | null, restorer: OrderPageRestorer, scope: () => string,
    account: () => string | null) {
    this.hub = hub;
    this.cache = cache;
    this.restorer = restorer;
    this.scope = scope;
    this.account = account;
  }

  sync(): OrderSyncResult {
    const cache: OrderStaleCache | null = this.cache;
    const scope: string = this.scope();
    const account: string | null = this.account();
    const owner: CacheOwner | null = cache === null ? null : cache.owner();
    const hubChanged: boolean = this.hub.sync();
    const epochChanged: boolean = this.partitions.epochChanged(account, owner);
    const clear: boolean = this.partitions.sessionSync(hubChanged, account, owner);
    let clearFailed: boolean = false;
    if (clear) {
      clearFailed = cache !== null && !cache.clear();
    } else if (!hubChanged && cache !== null) {
      cache.retryPendingClear();
    }
    let wiped: boolean = false;
    if ((hubChanged && OrderPageRestorer.wipesOnScopeChange(this.lastScope, scope)) || epochChanged) {
      this.restorer.reset();
      wiped = true;
    } else if (hubChanged) {
      this.restorer.rebindOwner();
    }
    this.lastScope = scope;
    return new OrderSyncResult(hubChanged || epochChanged, wiped, clearFailed);
  }
}
