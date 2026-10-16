// FU-HM-0724 鸿蒙跟进合集（十二）——依赖新接口约定的用例（测试作者先写，2026-10-16；第 2 版按 tests-review T-01..T-11、
// 第 3 版按 tests-review-r2 T-01 / T-04 / T-12..T-14、第 4 版按 tests-review-r3 T-01 / T-15..T-17、
// 第 5 版按实现后对抗评审 review-r1 R1-01 / R1-02 / R1-04..R1-07 修订）。
// 接口约定见 couli-runs/NATIVE/FU-HM-0724/tests-handback.md「第 2 版」。实现前本文件编译不过，按「红」计。用到的新接口：
//   C1 SessionIdentity；C2 ApiClient.sessionIdentity(epochs)；C3 OrderSessionReconciler 第 6 参 identity；
//   C4 OrderPageRestorer 第 7 参 identity；C5 WalletSessionReconciler / WalletSyncResult；
//   C6 OrderListScrollSync.restoreStep(list) / align(ticket, list, index)；C7 OrderTabCoordinator；
//   C8 HomeLkgReconciler.syncWith(...) / HomeSyncOutcome。
// 调度一律经生产协调器（C5 / C6 / C7 / C8），测试不自行实现「恢复重试」「对账」「补页」的调度。
// 身份读取的确定性桩：IdentityProbe（C2 层）——一次检查窗口内第 n 次及之后的身份读取（快照、账号、世代、归属键）失败。
// 鸿蒙令牌装载成功后进程内缓存（SecureSessionTokens.load），「已确认之后同一次检查里后续读取失败」只能在 C2 层构造（handback 说明）。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientWalletPort, HomeIdentity, HomeLkgReconciler, HomeLkgStore, HomeSyncOutcome, LocalDataCleanerRegistry,
  OrderAnchorKeeper, OrderCacheCleaner, OrderListController, OrderListDeps, OrderListScrollSync, OrderPageRestorer,
  OrderPageStateKv, OrderPageStateStore, OrderPersistResult, OrderPhase, OrderRateGate, OrderScrollAnchor, OrderSessionHub,
  OrderSessionReconciler, OrderStaleCache, OrderSyncResult, OrderTabCoordinator, PrivacyWithdrawalCleaners,
  SessionIdentity, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse, WalletCacheCleaner,
  WalletController, WalletDeps, WalletPhase, WalletSession, WalletSessionReconciler, WalletStaleCache, WalletSyncResult,
  ApiClientSearchPort, OrderDetailController, OrderDetailDeps, OrderRecord, WithdrawController, WithdrawDraftBinding,
  WithdrawInputDraft, SecureSessionTokens, SearchApiPort, ApiRequest, ApiResult, HomeLevel, HomeLkgScope
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { detail, NOW, page } from './OrderIntegration.test';
import { ALIPAY, rulesJson, summaryJson } from './WalletIntegration.test';
import {
  A, BoundedViewport, Device, LazyViewport, E1, E2, fx20Gate, homeIdentityNow, ids, LATER_UNKNOWN_KINDS, listFile, PAGE_KEY,
  PagedOrdersPort, pagedList, Proc, rows, SEED_PLATFORM, SEED_Q, seededDevice, SettledWalletPort, UNKNOWN_KINDS, until,
  walletFile
} from './FollowupHM0724Rig';

const FIVE: string[] = ['O1', 'O2', 'O3', 'O4', 'O5'];

/** 窗口内同步结果的容器（闭包里赋值）。 */
class SyncBox {
  order: OrderSyncResult | null = null;
  wallet: WalletSyncResult | null = null;
}
const B: string = 'user-2';

/** listOrders / 详情的端口包装（T-17）：在 request 入口同步计数——没启动的请求直接看得到，不依赖传输层结算。 */
class CountingSearchPort implements SearchApiPort {
  private readonly inner: SearchApiPort;
  requests: number = 0;
  listRequests: number = 0;

  constructor(inner: SearchApiPort) {
    this.inner = inner;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    this.requests++;
    if (request.operationId === 'listOrders') {
      this.listRequests++;
    }
    return this.inner.request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }
}

/**
 * C2 层的身份读取桩：生产接线里所有「身份」读取（快照、账号、世代、归属键）都经它。window(n, fn, single) 在一次检查窗口内执行 fn，
 * single=false：窗口内第 n 次（1 起）及之后的读取失败；single=true：仅第 n 次失败、之后恢复（T-15）。失败时快照为未知、账号 / 世代为 null、归属键为凭据读不出时的形状；n = 0 不注入。返回窗口内读取次数。
 * 窗口之外原样读取真实 ApiClient。
 */
class IdentityProbe {
  private readonly p: Proc;
  private active: boolean = false;
  private reads: number = 0;
  private failFrom: number = 0;
  /** 仅第 failFrom 次失败、之后恢复（T-15）；false = 第 failFrom 次及之后都失败。 */
  private single: boolean = false;

  constructor(p: Proc) {
    this.p = p;
  }

  window(failFrom: number, fn: () => void, single: boolean = false): number {
    this.active = true;
    this.reads = 0;
    this.failFrom = failFrom;
    this.single = single;
    try {
      fn();
    } finally {
      this.active = false;
      this.failFrom = 0;
      this.single = false;
    }
    return this.reads;
  }

  private failing(): boolean {
    if (!this.active) {
      return false;
    }
    this.reads++;
    if (this.failFrom <= 0) {
      return false;
    }
    return this.single ? this.reads === this.failFrom : this.reads >= this.failFrom;
  }

  identity(): SessionIdentity {
    return this.failing() ? new SessionIdentity(false, null, null) : this.p.rig.client.sessionIdentity(this.p.tokens);
  }

  account(): string | null {
    return this.failing() ? null : this.p.account();
  }

  epoch(): string | null {
    return this.failing() ? null : this.p.epoch();
  }

  scope(): string {
    return this.failing() ? this.p.unknownScopeKey() : this.p.scopeKey();
  }
}

/** 订单的生产接线（entry AppOrders.compose；C3、C4、C7），身份读取全部经 IdentityProbe。 */
class OrdersApp {
  readonly p: Proc;
  readonly probe: IdentityProbe;
  readonly hub: OrderSessionHub;
  readonly cache: OrderStaleCache;
  readonly keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
  readonly restorer: OrderPageRestorer;
  readonly reconciler: OrderSessionReconciler;
  readonly list: OrderListController;
  readonly coordinator: OrderTabCoordinator;
  readonly port: CountingSearchPort;

  constructor(p: Proc) {
    this.p = p;
    this.port = new CountingSearchPort(new ApiClientSearchPort(p.rig.client));
    const probe: IdentityProbe = new IdentityProbe(p);
    this.probe = probe;
    this.hub = new OrderSessionHub((): number => p.rig.nowMillis, (): string => probe.scope());
    this.cache = new OrderStaleCache(p.device.orderFiles, (): string | null => probe.account(), (): number => p.rig.nowMillis,
      (): string | null => probe.epoch());
    const store: OrderPageStateStore = new OrderPageStateStore((): OrderPageStateKv | null => p.device.prefs.kv(),
      PAGE_KEY);
    this.restorer = new OrderPageRestorer((): string | null => store.read(), (v: string | null): void => store.write(v),
      (): string | null => probe.account(), this.keeper, store.marks(), (): string | null => probe.epoch(),
      (): SessionIdentity => probe.identity());
    this.reconciler = new OrderSessionReconciler(this.hub, this.cache, this.restorer, (): string => probe.scope(),
      (): string | null => probe.account(), (): SessionIdentity => probe.identity());
    this.list = this.newList();
    this.coordinator = new OrderTabCoordinator(this.reconciler, this.restorer, this.list);
  }

  /** 构造并登记一个订单列表执行器（与 AppOrders.compose 同一接线）。 */
  newList(): OrderListController {
    const deps: OrderListDeps = new OrderListDeps(this.port);
    deps.cache = this.cache;
    deps.clock = (): number => this.p.rig.nowMillis;
    deps.scope = (): string => this.probe.scope();
    this.hub.attachList(deps);
    const list: OrderListController = new OrderListController(deps);
    this.hub.setList(list);
    return list;
  }

  /** 订单详情页（与 AppOrders.detailConfig 同一接线：共享闸门、登记到 hub）。 */
  newDetail(): OrderDetailController {
    const deps: OrderDetailDeps = new OrderDetailDeps(this.port);
    deps.cache = this.cache;
    deps.clock = (): number => this.p.rig.nowMillis;
    deps.scope = (): string => this.probe.scope();
    this.hub.attachDetail(deps);
    const controller: OrderDetailController = new OrderDetailController(deps);
    this.hub.addDetail(controller);
    return controller;
  }

  /** AppOrders.compose：启动时先补清上次没删完的缓存。 */
  compose(): boolean {
    return this.cache.retryPendingClear();
  }

  /** 一次正常状态同步（订单 Tab 选中）。 */
  sync(): OrderSyncResult {
    return this.coordinator.sync(true);
  }

  /** 订单列表请求次数（端口入口同步计数，T-17）。 */
  listRequests(): number {
    return this.port.listRequests;
  }

  /** 最近一次订单列表请求带着恢复出的条件。 */
  lastListHasSeedQuery(): boolean {
    const list: TransportRequest[] = this.p.rig.server.received.filter((r: TransportRequest): boolean =>
    r.url.indexOf('/v1/orders') >= 0 && r.url.indexOf('/v1/orders/') < 0);
    return list.length > 0 && list[list.length - 1].url.indexOf(SEED_Q) >= 0;
  }
}

/** 订单假服务：默认第一页 5 单；搜索词 milk 回 42901（Retry-After 120 秒）；详情 /v1/orders/{id}。 */
function ordersServer(p: Proc): void {
  p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    if (r.url.indexOf('/v1/orders/') >= 0 && r.url.indexOf('/v1/orders/pending-tracks') < 0) {
      const tail: string = r.url.substring(r.url.indexOf('/v1/orders/') + 11).split('?')[0];
      return Promise.resolve(envelope(0, detail(tail, '"order_no":"' + SEED_Q + '"')));
    }
    if (r.url.indexOf('q=milk') >= 0) {
      const headers: Record<string, string> = {};
      headers['retry-after'] = '120';
      return Promise.resolve(envelope(42901, '{}', headers));
    }
    return Promise.resolve(envelope(0, page(rows(FIVE), null)));
  };
}

/** 钱包的生产接线（entry AppWallet.compose / sync；C5），身份读取全部经 IdentityProbe。 */
class WalletApp {
  readonly p: Proc;
  readonly probe: IdentityProbe;
  readonly session: WalletSession;
  readonly cache: WalletStaleCache;
  readonly reconciler: WalletSessionReconciler;
  readonly draft: WithdrawInputDraft;
  /** 钱包类请求的端口（入口同步计数 issued，T-17）。 */
  readonly port: SettledWalletPort;
  draftClears: number = 0;
  /** 摘要接口：'ok' | 'offline'（断网，页面应显示缓存）| 'limited'（42901，Retry-After 120 秒）。 */
  summaryMode: string = 'ok';

  constructor(p: Proc) {
    this.p = p;
    const probe: IdentityProbe = new IdentityProbe(p);
    this.probe = probe;
    this.session = new WalletSession((): number => p.rig.nowMillis, (): string => probe.scope());
    this.cache = new WalletStaleCache(p.device.walletFiles, (): string | null => probe.account(),
      (): number => p.rig.nowMillis, (): string | null => probe.epoch());
    this.port = new SettledWalletPort(new ApiClientWalletPort(p.rig.client));
    const draft: WithdrawInputDraft = new WithdrawInputDraft(p.device.draft);
    this.draft = draft;
    // AppWallet.clearWithdrawInput：清金额草稿（真实存储）。
    this.reconciler = new WalletSessionReconciler(this.session, this.cache, (): SessionIdentity => probe.identity(),
      (): void => {
        this.draftClears++;
        draft.clear();
      });
    p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      if (r.url.indexOf('/v1/wallet/summary') >= 0) {
        if (this.summaryMode === 'offline') {
          return Promise.resolve(TransportResponse.failed(TransportFailure.DISCONNECT));
        }
        if (this.summaryMode === 'limited') {
          const headers: Record<string, string> = {};
          headers['retry-after'] = '120';
          return Promise.resolve(envelope(42901, '{}', headers));
        }
        return Promise.resolve(envelope(0, summaryJson()));
      }
      if (r.url.indexOf('/v1/withdrawals/rules') >= 0) {
        return Promise.resolve(envelope(0, rulesJson(null)));
      }
      if (r.url.indexOf('/v1/me/payout-account') >= 0) {
        return Promise.resolve(envelope(0, ALIPAY));
      }
      return Promise.resolve(envelope(0, '{"realname_status":"verified"}'));
    };
  }

  compose(): boolean {
    return this.cache.retryPendingClear();
  }

  sync(): WalletSyncResult {
    return this.reconciler.sync();
  }

  deps(): WalletDeps {
    const d: WalletDeps = new WalletDeps(this.port, this.session);
    d.clock = (): number => this.p.rig.nowMillis;
    d.scope = (): string => this.probe.scope();
    d.account = (): string | null => this.probe.account();
    d.cache = this.cache;
    return d;
  }

  page(): WalletController {
    return new WalletController(this.deps());
  }

  /** 提现页（与 AppWallet.withdraw 同一接线：表单归属 + 金额草稿绑定，输入变化即保存）。 */
  withdraw(): WithdrawController {
    const c: WithdrawController = new WithdrawController(this.deps());
    const binding: WithdrawDraftBinding = new WithdrawDraftBinding(this.draft, c.formAccount, c.formScope,
      (): string | null => this.probe.account(), (): string | null => this.probe.epoch(), (): string => this.probe.scope());
    const saved: string | null = binding.restore();
    if (saved !== null) {
      c.restoreInput(saved);
    }
    c.onInputChanged = (text: string, account: string | null, scope: string): void => binding.save(text, account, scope);
    return c;
  }
}

/** 页面断网加载后显示的是缓存摘要（stale 内容）。 */
async function showsCachedSummary(w: WalletController): Promise<boolean> {
  w.load();
  const settled: boolean = await until((): boolean => w.snapshot.phase === WalletPhase.CONTENT
    || w.snapshot.phase === WalletPhase.ERROR);
  return settled && w.snapshot.phase === WalletPhase.CONTENT && w.snapshot.stale && w.snapshot.summary !== null;
}

/** 首页的生产接线（AppHome.syncInner + build；C8）。 */
class HomeApp {
  readonly p: Proc;
  readonly store: HomeLkgStore;
  readonly reconciler: HomeLkgReconciler = new HomeLkgReconciler();
  current: HomeIdentity | null = null;
  invalidations: number = 0;

  constructor(p: Proc) {
    this.p = p;
    this.store = new HomeLkgStore(p.device.lkg);
    this.store.bindLoginEpoch((): string | null => p.epoch());
  }

  sync(): HomeSyncOutcome {
    const now: HomeIdentity = homeIdentityNow(this.p);
    const old: HomeIdentity | null = this.current;
    const outcome: HomeSyncOutcome = this.reconciler.syncWith(old === null ? null : old.key, now,
      this.p.rig.client.sessionIdentity(this.p.tokens), this.store, (): void => {
        this.invalidations++;
      });
    if (!outcome.keep) {
      // AppHome.build：按此刻身份建控制器（built 记身份与世代票据）。
      this.current = now;
      this.reconciler.built(now, this.store.epochTicket());
    }
    return outcome;
  }
}

/** F-X-20：分页列表 + 有底视口 + 生产的滚动接线（OrderListScrollSync，C6）。 */
class Fx20 {
  readonly port: PagedOrdersPort = new PagedOrdersPort();
  readonly list: OrderListController;
  readonly keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
  readonly view: BoundedViewport;
  readonly sync: OrderListScrollSync;
  readonly rescrolls: number[] = [];
  readonly persisted: string[] = [];
  readonly target: string;
  ticket: number = -1;

  constructor(pages: string[][], height: number, target: string, gate: OrderRateGate | null = null, lazy: boolean = false) {
    this.port.pages = pages;
    this.list = pagedList(this.port, gate);
    this.view = lazy ? new LazyViewport(height) : new BoundedViewport(height);
    this.target = target;
    this.sync = new OrderListScrollSync(this.keeper, this.view, (): void => {
      this.persisted.push(this.keeper.anchor);
    }, (listIndex: number): void => {
      this.rescrolls.push(listIndex);
      this.view.alignTo(listIndex);
    });
  }

  /** 冷启动恢复：装锚点、加载第一页并建立位置基准。返回第一页是否加载完。 */
  async start(): Promise<boolean> {
    this.keeper.begin(this.target, this.list.conditions().encode());
    this.list.ensureLoaded();
    const loaded: boolean = await until((): boolean => this.list.snapshot.phase === OrderPhase.CONTENT);
    this.view.setItems(this.list.snapshot.items);
    this.sync.scrollIndex(this.view.topIndex(), true);
    return loaded;
  }

  /** 页面收到一次快照：交给生产的恢复步骤（C6）。返回下标时记下当时的任务票据（页面排入对齐回调时同样记）。 */
  step(): number {
    this.view.setItems(this.list.snapshot.items);
    const r: number = this.sync.restoreStep(this.list);
    if (r >= 0) {
      this.ticket = this.keeper.ticket;
    }
    return r;
  }

  /** 反复交快照并等翻页结算，直到不再是 WAIT（最多 maxSteps 次）。 */
  async drive(maxSteps: number = 10): Promise<number> {
    for (let i: number = 0; i < maxSteps; i++) {
      const r: number = this.step();
      if (r !== OrderScrollAnchor.WAIT) {
        return r;
      }
      const settled: boolean = await until((): boolean => !this.list.snapshot.loadingMore);
      if (!settled) {
        return OrderScrollAnchor.WAIT;
      }
    }
    return OrderScrollAnchor.WAIT;
  }

  /** 延迟对齐回调执行（C6 align），随后列表回报布局（onDidScroll、onScrollIndex）。 */
  align(index: number): boolean {
    const ok: boolean = this.sync.align(this.ticket, this.list, index);
    this.sync.didScroll(true);
    this.sync.scrollIndex(this.view.topIndex(), true);
    return ok;
  }

  topId(): string | null {
    return this.view.orderIdAt(this.view.topIndex());
  }
}

export default function followupHM0724ContractTest() {
  describe('FollowupHM0724Contract', () => {
    // ---------------------------------------------------------------- C2：身份快照本身
    it('fhm0724_identity_snapshot_is_one_read_unknown_vs_confirmed_none', 0, () => {
      const d: Device = new Device();
      d.login(A, E1);
      const p: Proc = new Proc(d);
      const known: SessionIdentity = p.rig.client.sessionIdentity(p.tokens);
      expect(known.known && known.account === A && known.loginEpoch === E1).assertTrue();
      // 四种暂时未知（令牌读不出、凭据不可读、环境未就绪、隐私未决）：known=false，账号 / 世代都为 null。
      for (const kind of UNKNOWN_KINDS) {
        const q: Proc = new Proc(d);
        q.makeUnknown(kind);
        const u: SessionIdentity = q.rig.client.sessionIdentity(q.tokens);
        expect(u.known).assertFalse();
        expect(u.account === null && u.loginEpoch === null).assertTrue();
        q.makeKnown();
        const k: SessionIdentity = q.rig.client.sessionIdentity(q.tokens);
        expect(k.known && k.account === A && k.loginEpoch === E1).assertTrue();
      }
      // 读令牌项前 k 次失败：每次快照要么整份未知，要么整份已知（不拼接两次读取）。
      for (let k: number = 1; k <= 4; k++) {
        const q: Proc = new Proc(d);
        d.tokenStore.failNextReads(k);
        for (let i: number = 0; i <= k; i++) {
          const s: SessionIdentity = q.rig.client.sessionIdentity(q.tokens);
          const consistent: boolean = s.known ? (s.account === A && s.loginEpoch === E1)
            : (s.account === null && s.loginEpoch === null);
          expect(consistent).assertTrue();
        }
        d.tokenStore.failNextReads(0);
      }
      // 已确认无会话（登出）：known=true，账号为 null。
      const out: Proc = new Proc(d);
      out.tokens.clear();
      const none: SessionIdentity = out.rig.client.sessionIdentity(out.tokens);
      expect(none.known).assertTrue();
      expect(none.account === null).assertTrue();
    });

    // ---------------------------------------------------------------- 1. F-X-19 补充：订单（含隐私未决 → 已同意）
    it('fhm0724_x19_1_order_cold_start_unknown_keeps_cache_and_record_then_coordinator_restores', 0, async () => {
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        p.makeUnknown(kind);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        // 冷启动：身份暂时未知期间同步两次、页面持久化一次——不删、不写。
        const r1: OrderSyncResult = app.sync();
        const persisted: string = app.coordinator.persist();
        const r2: OrderSyncResult = app.sync();
        const cacheWhileUnknown: boolean = d.orderFiles.files.has(listFile(A, E1));
        const anchorWhileUnknown: string | null = d.prefs.anchor();
        expect(r1.wiped || r2.wiped).assertFalse();
        expect(persisted).assertEqual(OrderPersistResult.SKIPPED);
        expect(cacheWhileUnknown).assertTrue();
        expect(anchorWhileUnknown).assertEqual('O3');
        // 身份恢复可读：未知 → 已知只对账、不删。
        p.makeKnown();
        const r3: OrderSyncResult = app.sync();
        const cacheAfter: boolean = d.orderFiles.files.has(listFile(A, E1));
        expect(r3.wiped).assertFalse();
        expect(r3.clearFailed).assertFalse();
        expect(cacheAfter).assertTrue();
        expect(app.cache.loadList('self') !== null).assertTrue();
        // 打开订单 Tab（协调器）：恢复到锚点与条件，并按恢复的条件加载。
        app.coordinator.showTab(null);
        const loaded: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT);
        expect(loaded).assertTrue();
        expect(app.keeper.anchor).assertEqual('O3');
        expect(app.list.conditions().q).assertEqual(SEED_Q);
        expect(app.lastListHasSeedQuery()).assertTrue();
        // 对照：已确认无会话（登出）照删缓存与恢复记录。
        p.tokens.clear();
        const r4: OrderSyncResult = app.sync();
        expect(r4.wiped).assertTrue();
        const filesLeft: number = d.orderFiles.files.size;
        expect(filesLeft).assertEqual(0);
        expect(d.prefs.values.has(PAGE_KEY)).assertFalse();
      }
    });

    // ---------------------------------------------------------------- 1. F-X-19 补充：钱包（含隐私未决 → 已同意）
    it('fhm0724_x19_1_wallet_cold_start_unknown_keeps_summary_cache_and_draft', 0, async () => {
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const app: WalletApp = new WalletApp(p);
        app.compose();
        app.sync();
        app.sync();
        const whileUnknown: boolean = d.walletFiles.files.has(walletFile(A, E1));
        expect(whileUnknown).assertTrue();
        expect(app.draftClears).assertEqual(0);
        p.makeKnown();
        const r: WalletSyncResult = app.sync();
        const after: boolean = d.walletFiles.files.has(walletFile(A, E1));
        const draftClears: number = app.draftClears;
        expect(r.clearFailed).assertFalse();
        expect(after).assertTrue();
        expect(draftClears).assertEqual(0);
        app.summaryMode = 'offline';
        const shown: boolean = await showsCachedSummary(app.page());
        expect(shown).assertTrue();
        // 对照：已确认无会话（登出）照删摘要缓存与金额草稿。
        p.tokens.clear();
        app.sync();
        const left: number = d.walletFiles.files.size;
        expect(left).assertEqual(0);
        expect(app.draftClears > 0).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 1. 对照：真正撤回同意（清理器）照删，与「暂时未知」分开
    it('fhm0724_x19_1_withdrawal_cleaner_still_deletes_order_and_wallet_while_identity_unknown', 0, async () => {
      const d: Device = seededDevice('O3');
      const p: Proc = new Proc(d);
      ordersServer(p);
      const orders: OrdersApp = new OrdersApp(p);
      orders.compose();
      orders.sync();
      const wallet: WalletApp = new WalletApp(p);
      wallet.compose();
      wallet.sync();
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      OrderCacheCleaner.install(registry, orders.cache, (): void => orders.hub.reset(), (): boolean => orders.restorer.wipe());
      WalletCacheCleaner.install(registry, wallet.cache, (): void => wallet.session.reset());
      // 撤回同意：撤回清理进行中凭据不可读（身份暂时未知），清理器照样删除。
      p.makeUnknown('credentials');
      await PrivacyWithdrawalCleaners.run(registry);
      orders.sync();
      wallet.sync();
      const orderFiles: number = d.orderFiles.files.size;
      const walletFiles: number = d.walletFiles.files.size;
      expect(orderFiles).assertEqual(0);
      expect(walletFiles).assertEqual(0);
      expect(d.prefs.values.has(PAGE_KEY)).assertFalse();
    });

    // ---------------------------------------------------------------- 1. + T-05 / G01：Preferences 各处读取暂时失败
    it('fhm0724_x19_1_order_prefs_read_failures_defer_without_deleting_or_rewriting_then_restore', 0, async () => {
      for (const fault of ['open', 'record', 'wipe', 'gen']) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        const before: string | null = d.prefs.record();
        const genBefore: string | null = d.prefs.values.get(PAGE_KEY + '.gen') ?? null;
        if (fault === 'open') {
          d.prefs.failNextOpens(1000000);
        } else if (fault === 'record') {
          d.prefs.failNextReads(PAGE_KEY, 1000000);
        } else if (fault === 'wipe') {
          d.prefs.failNextReads(PAGE_KEY + '.wipe', 1000000);
        } else {
          d.prefs.failNextReads(PAGE_KEY + '.gen', 1000000);
        }
        // 订单 Tab 显示、页面加载并持久化、再同步一次：读不出 ≠ 没有记录 / 有待清理——不删、不改写、决策未完成。
        app.coordinator.showTab(null);
        const settled: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT
          || app.list.snapshot.phase === OrderPhase.ERROR);
        expect(settled).assertTrue();
        const persisted: string = app.coordinator.persist();
        app.sync();
        const during: string | null = d.prefs.record();
        const wipeMark: boolean = d.prefs.values.has(PAGE_KEY + '.wipe');
        const genDuring: string | null = d.prefs.values.get(PAGE_KEY + '.gen') ?? null;
        expect(during).assertEqual(before);
        expect(wipeMark).assertFalse();
        expect(genDuring).assertEqual(genBefore);
        expect(persisted).assertEqual(OrderPersistResult.SKIPPED);
        expect(app.restorer.restoreDecided).assertFalse();
        // 读恢复后，正常同步由协调器重做恢复决策：锚点与条件都回来，并按恢复的条件加载。
        d.prefs.heal();
        app.sync();
        const reloaded: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT
          && app.lastListHasSeedQuery());
        expect(reloaded).assertTrue();
        expect(app.restorer.restoreDecided).assertTrue();
        expect(app.keeper.anchor).assertEqual('O3');
        expect(app.list.conditions().q).assertEqual(SEED_Q);
        expect(app.list.conditions().platform).assertEqual(SEED_PLATFORM);
      }
    });

    // ---------------------------------------------------------------- 2①. 恢复决策那一次读失败、之后成功（订单，经协调器自动重试）
    it('fhm0724_x19b_1_order_restore_read_fails_once_keeps_record_and_sync_restores_anchor', 0, async () => {
      for (let k: number = 1; k <= 3; k++) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        p.makeUnknown('tokens');
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        // 打开订单 Tab 的恢复决策里前 k 次读令牌失败，之后正常（SecureSessionTokens 装载成功后缓存）。
        d.tokenStore.failNextReads(k);
        app.coordinator.showTab(null);
        // 页面在恢复决策之后立即持久化一次（OrderListView.apply → onPersist）：决策没按已确认身份做过之前不得写盘。
        app.coordinator.persist();
        d.tokenStore.failNextReads(0);
        // 正常同步（订单 Tab 显示着）：协调器在决策未完成时自动重做并加载。
        app.sync();
        const restored: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT
          && app.lastListHasSeedQuery());
        expect(restored).assertTrue();
        app.coordinator.persist();
        const recordAnchor: string | null = d.prefs.anchor();
        expect(recordAnchor).assertEqual('O3');
        expect(app.keeper.anchor).assertEqual('O3');
        expect(app.restorer.restoreDecided).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 2①. 钱包：页面构造时那一次读失败、之后成功
    it('fhm0724_x19b_1_wallet_page_built_with_one_failed_read_keeps_cache_and_shows_it', 0, async () => {
      for (let k: number = 1; k <= 3; k++) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        p.makeUnknown('tokens');
        const app: WalletApp = new WalletApp(p);
        app.compose();
        app.sync();
        d.tokenStore.failNextReads(k);
        const w: WalletController = app.page();
        d.tokenStore.failNextReads(0);
        app.sync();
        const cacheKept: boolean = d.walletFiles.files.has(walletFile(A, E1));
        expect(cacheKept).assertTrue();
        app.summaryMode = 'offline';
        const shown: boolean = await showsCachedSummary(w);
        expect(shown).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 2②. 身份未知只延后归属对账，已登记的待清理照常执行（订单）
    it('fhm0724_x19b_2_order_pending_clear_runs_at_init_while_identity_unknown', 0, () => {
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        d.orderFiles.pending = true;
        d.prefs.values.set(PAGE_KEY + '.wipe', '1');
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const app: OrdersApp = new OrdersApp(p);
        d.orderFiles.failClear = true;
        expect(app.compose()).assertFalse();
        d.orderFiles.failClear = false;
        app.sync();
        const files: number = d.orderFiles.files.size;
        const pending: boolean = d.orderFiles.pending;
        expect(files).assertEqual(0);
        expect(pending).assertFalse();
        // 打开订单 Tab（身份仍未知）：已确认的恢复记录待清理照删，不按记录恢复。
        app.coordinator.showTab(null);
        const record: boolean = d.prefs.values.has(PAGE_KEY);
        const mark: boolean = d.prefs.values.has(PAGE_KEY + '.wipe');
        expect(record).assertFalse();
        expect(mark).assertFalse();
        expect(app.keeper.anchor).assertEqual('');
      }
    });

    // ---------------------------------------------------------------- 2②. 钱包
    it('fhm0724_x19b_2_wallet_pending_clear_runs_at_init_while_identity_unknown', 0, () => {
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        d.walletFiles.pending = true;
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const app: WalletApp = new WalletApp(p);
        d.walletFiles.failClear = true;
        expect(app.compose()).assertFalse();
        d.walletFiles.failClear = false;
        app.sync();
        const files: number = d.walletFiles.files.size;
        const pending: boolean = d.walletFiles.pending;
        expect(files).assertEqual(0);
        expect(pending).assertFalse();
      }
    });

    // ---------------------------------------------------------------- 3①（T-01）：已确认 A/E1，同一次检查后续读取失败（订单）
    it('fhm0724_x19c_1_order_confirmed_identity_later_reads_fail_in_one_sync_keep_page_input_gate_cache', 0, async () => {
      const d: Device = seededDevice('O3');
      const p: Proc = new Proc(d);
      ordersServer(p);
      const app: OrdersApp = new OrdersApp(p);
      app.compose();
      app.sync();
      app.coordinator.showTab(null);
      expect(await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT)).assertTrue();
      // 真实输入与禁用期：提交搜索 milk，服务端 42901（Retry-After 120 秒，截止 = 此刻 + 120 秒）。
      const t0: number = p.rig.nowMillis;
      app.list.submitQuery('milk');
      const limited: boolean = await until((): boolean => app.hub.gate.active
        && app.list.snapshot.phase !== OrderPhase.LOADING);
      expect(limited).assertTrue();
      const epoch0: number = app.list.snapshot.sessionEpoch;
      const record0: string | null = d.prefs.record();
      // 禁用期建立后先过 30 秒，再做故障与恢复同步（T-01：重新计时会把截止推到 t0 + 150 秒）。
      p.rig.nowMillis = t0 + 30000;
      // 一次正常检查里的读取次数（实现决定；至少 1）。
      const steady: SyncBox = new SyncBox();
      const reads: number = app.probe.window(0, (): void => {
        steady.order = app.sync();
      });
      expect(steady.order !== null && !(steady.order as OrderSyncResult).changed).assertTrue();
      // 每个读取位置两种故障：第 n 次及之后都失败、仅第 n 次失败之后恢复（T-15）。
      for (let k: number = 0; k < 2 * (Math.max(reads, 1) + 1); k++) {
        const n: number = Math.floor(k / 2) + 1;
        const single: boolean = k % 2 === 1;
        const faulty: SyncBox = new SyncBox();
        app.probe.window(n, (): void => {
          faulty.order = app.sync();
        }, single);
        const recovered: OrderSyncResult = app.sync();
        const f: OrderSyncResult = faulty.order as OrderSyncResult;
        expect(f.changed || f.wiped || recovered.changed || recovered.wiped).assertFalse();
        const epoch: number = app.list.snapshot.sessionEpoch;
        const q: string | null = app.list.conditions().q;
        const gate: boolean = app.hub.gate.active;
        const cache: boolean = d.orderFiles.files.has(listFile(A, E1));
        const record: string | null = d.prefs.record();
        expect(epoch).assertEqual(epoch0);
        expect(q).assertEqual('milk');
        expect(gate).assertTrue();
        expect(cache).assertTrue();
        expect(record).assertEqual(record0);
      }
      // 禁用截止仍是原来的 t0 + 120 秒：截止前 1 秒仍禁用，截止后 1 秒解除（没有被缩短、延长或重建）。
      p.rig.nowMillis = t0 + 119000;
      const before: boolean = app.hub.gate.active;
      p.rig.nowMillis = t0 + 121000;
      const after: boolean = app.hub.gate.active;
      expect(before).assertTrue();
      expect(after).assertFalse();
    });

    // ---------------------------------------------------------------- 3①（T-01）：钱包（真实提现页 + 非空金额输入 + 草稿 + 禁用截止）
    it('fhm0724_x19c_1_wallet_confirmed_identity_later_reads_fail_in_one_sync_keep_input_draft_gate_cache', 0, async () => {
      const d: Device = seededDevice('O3');
      const p: Proc = new Proc(d);
      const app: WalletApp = new WalletApp(p);
      app.compose();
      app.sync();
      const w: WalletController = app.page();
      w.load();
      expect(await until((): boolean => w.snapshot.phase === WalletPhase.CONTENT)).assertTrue();
      // 同一会话里打开提现页并输入金额（AppWallet.withdraw 同一接线：输入即按表单归属保存草稿）。
      const c: WithdrawController = app.withdraw();
      c.onShown();
      expect(await until((): boolean => c.snapshot.rules !== null)).assertTrue();
      expect(c.setInput('12')).assertTrue();
      const input0: string = c.snapshot.inputText;
      const draft0: string | null = d.draft.value;
      expect(input0).assertEqual('12');
      expect(draft0 !== null && draft0.indexOf('12') >= 0).assertTrue();
      // 真实禁用期：刷新得到 42901（保留摘要、读闸门进入禁用期，剩余 120 秒）。
      const t0: number = p.rig.nowMillis;
      app.summaryMode = 'limited';
      w.refresh();
      const limited: boolean = await until((): boolean => app.session.readGate.active && !w.snapshot.refreshing);
      expect(limited).assertTrue();
      expect(app.session.readGate.remainingMs).assertEqual(120000);
      // 禁用期建立后先过 30 秒，再做故障与恢复同步：剩余时间应已扣除经过的 30 秒（T-01）。
      p.rig.nowMillis = t0 + 30000;
      const remaining0: number = app.session.readGate.remainingMs;
      expect(remaining0).assertEqual(90000);
      const epoch0: number = app.session.epoch;
      const pageEpoch0: number = w.snapshot.sessionEpoch;
      const formEpoch0: number = c.snapshot.sessionEpoch;
      const steady: SyncBox = new SyncBox();
      const reads: number = app.probe.window(0, (): void => {
        steady.wallet = app.sync();
      });
      expect(steady.wallet !== null && !(steady.wallet as WalletSyncResult).changed).assertTrue();
      for (let k: number = 0; k < 2 * (Math.max(reads, 1) + 1); k++) {
        const n: number = Math.floor(k / 2) + 1;
        const single: boolean = k % 2 === 1;
        const faulty: SyncBox = new SyncBox();
        app.probe.window(n, (): void => {
          faulty.wallet = app.sync();
        }, single);
        const recovered: WalletSyncResult = app.sync();
        const f: WalletSyncResult = faulty.wallet as WalletSyncResult;
        expect(f.changed || f.cleared || recovered.changed || recovered.cleared).assertFalse();
        const epoch: number = app.session.epoch;
        const pageEpoch: number = w.snapshot.sessionEpoch;
        const formEpoch: number = c.snapshot.sessionEpoch;
        const input: string = c.snapshot.inputText;
        const draft: string | null = d.draft.value;
        const summary: boolean = w.snapshot.summary !== null;
        const remaining: number = app.session.readGate.remainingMs;
        const cache: boolean = d.walletFiles.files.has(walletFile(A, E1));
        expect(epoch).assertEqual(epoch0);
        expect(pageEpoch).assertEqual(pageEpoch0);
        expect(formEpoch).assertEqual(formEpoch0);
        expect(input).assertEqual(input0);
        expect(draft).assertEqual(draft0);
        expect(summary).assertTrue();
        expect(remaining).assertEqual(remaining0);
        expect(cache).assertTrue();
        expect(app.draftClears).assertEqual(0);
      }
      // 禁用截止仍是 t0 + 120 秒。
      p.rig.nowMillis = t0 + 119000;
      const before: boolean = app.session.readGate.active;
      p.rig.nowMillis = t0 + 121000;
      const after: boolean = app.session.readGate.active;
      expect(before).assertTrue();
      expect(after).assertFalse();
      c.leave();
    });

    // ---------------------------------------------------------------- 3①：冷启动那次同步里任一读取位置失败都不是换代（订单）
    it('fhm0724_x19c_1_order_cold_start_read_failure_at_every_split_is_not_a_session_change', 0, () => {
      for (let k: number = 0; k <= 8; k++) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        p.makeUnknown('tokens');
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        const s1: OrderSyncResult = app.sync();
        d.tokenStore.failNextReads(k);
        const s2: OrderSyncResult = app.sync();
        d.tokenStore.failNextReads(0);
        const s3: OrderSyncResult = app.sync();
        const epochAfterKnown: number = app.list.snapshot.sessionEpoch;
        const s4: OrderSyncResult = app.sync();
        const epochSteady: number = app.list.snapshot.sessionEpoch;
        expect(p.account()).assertEqual(A);
        expect(s1.wiped || s2.wiped || s3.wiped || s4.wiped).assertFalse();
        expect(s4.changed).assertFalse();
        expect(epochSteady).assertEqual(epochAfterKnown);
        const cache: boolean = d.orderFiles.files.has(listFile(A, E1));
        const anchor: string | null = d.prefs.anchor();
        expect(cache).assertTrue();
        expect(anchor).assertEqual('O3');
      }
    });

    // ---------------------------------------------------------------- 3①：冷启动（钱包）
    it('fhm0724_x19c_1_wallet_cold_start_read_failure_at_every_split_is_not_a_session_change', 0, () => {
      for (let k: number = 0; k <= 8; k++) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        p.makeUnknown('tokens');
        const app: WalletApp = new WalletApp(p);
        app.compose();
        app.sync();
        d.tokenStore.failNextReads(k);
        app.sync();
        d.tokenStore.failNextReads(0);
        app.sync();
        const epochAfterKnown: number = app.session.epoch;
        const s4: WalletSyncResult = app.sync();
        const epochSteady: number = app.session.epoch;
        expect(p.account()).assertEqual(A);
        expect(s4.changed).assertFalse();
        expect(epochSteady).assertEqual(epochAfterKnown);
        const cache: boolean = d.walletFiles.files.has(walletFile(A, E1));
        const draftClears: number = app.draftClears;
        expect(cache).assertTrue();
        expect(draftClears).assertEqual(0);
      }
    });

    // ---------------------------------------------------------------- 3②：冷启动未知期间构造的列表，恢复后能加载（订单）
    it('fhm0724_x19c_2_order_list_built_while_unknown_loads_after_identity_known', 0, async () => {
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        p.makeUnknown(kind);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        p.makeKnown();
        app.sync();
        app.coordinator.showTab(null);
        const loaded: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT);
        expect(loaded).assertTrue();
        expect(app.list.snapshot.items.length).assertEqual(5);
        expect(app.list.ownsSession()).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 3②（T-03）：判据已是 A/E1、未知期间构造并登记列表、恢复后判据相同（订单）
    it('fhm0724_x19c_2_order_list_registered_while_unknown_same_key_loads_after_recovery', 0, async () => {
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        // 暂时未知期间构造并登记一个列表执行器（中间没有同步，判据仍是 A/E1）。
        p.makeUnknown(kind);
        const fresh: OrderListController = app.newList();
        p.makeKnown();
        app.sync();
        fresh.ensureLoaded();
        const loaded: boolean = await until((): boolean => fresh.snapshot.phase === OrderPhase.CONTENT);
        expect(loaded).assertTrue();
        expect(fresh.snapshot.items.length).assertEqual(5);
        expect(fresh.ownsSession()).assertTrue();
        expect(d.prefs.anchor()).assertEqual('O3');
      }
    });

    // ---------------------------------------------------------------- 3②：钱包（冷启动 + 判据相同）
    it('fhm0724_x19c_2_wallet_page_built_while_unknown_loads_after_identity_known', 0, async () => {
      for (const kind of UNKNOWN_KINDS) {
        // a）冷启动：未知期间建页，恢复后同步、加载。
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const app: WalletApp = new WalletApp(p);
        app.compose();
        app.sync();
        // 页面在身份未知期间打开并按生产路径首次加载（WalletView.aboutToAppear → load）。
        const cold: WalletController = app.page();
        cold.load();
        expect(await until((): boolean => cold.snapshot.phase !== WalletPhase.LOADING)).assertTrue();
        p.makeKnown();
        // 恢复后只走正常同步（评审 r1 R1-01：不再手动 load；替换页面身份后应由协调器 / 页面自己重取）。
        app.sync();
        const coldLoaded: boolean = await until((): boolean => cold.snapshot.phase === WalletPhase.CONTENT);
        expect(coldLoaded).assertTrue();
        // b）已按 A/E1 同步过；暂时未知期间建页（中间没有同步）；恢复后同步时判据与上次相同。
        if (LATER_UNKNOWN_KINDS.indexOf(kind) < 0) {
          continue; // 令牌装载成功后进程内缓存，已知之后不会再出现令牌读失败（SecureSessionTokens.load）。
        }
        p.makeUnknown(kind);
        const mid: WalletController = app.page();
        mid.load();
        expect(await until((): boolean => mid.snapshot.phase !== WalletPhase.LOADING)).assertTrue();
        p.makeKnown();
        app.sync();
        const midLoaded: boolean = await until((): boolean => mid.snapshot.phase === WalletPhase.CONTENT);
        expect(midLoaded).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 3③（T-02）：换代识别成功、仅对账再读身份失败、删除可用（订单）
    it('fhm0724_x19c_3_order_epoch_change_then_reconcile_reads_fail_next_sync_deletes_e1', 0, () => {
      for (let n: number = 2; n <= 6; n++) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        const requests0: number = app.listRequests();
        // 同账号换成 E2（三个会话计数没动）；这次检查第一次身份读取成功（A/E2），之后的读取全部失败。
        p.tokens.save(new SessionTokenSet('access-e2', 'refresh-e2', 'full', A, E2));
        app.probe.window(n, (): void => {
          app.sync();
        });
        // 读取恢复：只做正常同步，不发新的缓存请求。
        app.sync();
        app.sync();
        const e1Left: boolean = d.orderFiles.files.has(listFile(A, E1));
        const record: boolean = d.prefs.values.has(PAGE_KEY);
        const requests: number = app.listRequests();
        expect(e1Left).assertFalse();
        expect(record).assertFalse();
        expect(requests).assertEqual(requests0);
        expect(app.cache.loadList('self') === null).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 3③（T-02）：钱包
    it('fhm0724_x19c_3_wallet_epoch_change_then_reconcile_reads_fail_next_sync_deletes_e1', 0, () => {
      for (let n: number = 2; n <= 6; n++) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        const app: WalletApp = new WalletApp(p);
        app.compose();
        app.sync();
        p.tokens.save(new SessionTokenSet('access-e2', 'refresh-e2', 'full', A, E2));
        app.probe.window(n, (): void => {
          app.sync();
        });
        app.sync();
        app.sync();
        const e1Left: boolean = d.walletFiles.files.has(walletFile(A, E1));
        const requests: number = app.port.issued;
        expect(e1Left).assertFalse();
        expect(app.draftClears > 0).assertTrue();
        expect(requests).assertEqual(0);
      }
    });

    // ---------------------------------------------------------------- 3③：对账删除失败可重试（含身份暂时未知时）（订单）
    it('fhm0724_x19c_3_order_epoch_change_clear_fails_is_retried_even_while_identity_unknown', 0, () => {
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        p.tokens.save(new SessionTokenSet('access-e2', 'refresh-e2', 'full', A, E2));
        d.orderFiles.failClear = true;
        const r: OrderSyncResult = app.sync();
        expect(r.changed && r.wiped).assertTrue();
        expect(r.clearFailed).assertTrue();
        expect(d.orderFiles.files.has(listFile(A, E1))).assertTrue();
        d.orderFiles.failClear = false;
        p.makeUnknown(kind);
        app.sync();
        const left: number = d.orderFiles.files.size;
        expect(left).assertEqual(0);
        p.makeKnown();
        const again: OrderSyncResult = app.sync();
        expect(again.clearFailed).assertFalse();
        expect(app.cache.loadList('self') === null).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 3③：对账删除失败可重试（钱包）
    it('fhm0724_x19c_3_wallet_epoch_change_clear_fails_is_retried_even_while_identity_unknown', 0, () => {
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        const app: WalletApp = new WalletApp(p);
        app.compose();
        app.sync();
        p.tokens.save(new SessionTokenSet('access-e2', 'refresh-e2', 'full', A, E2));
        d.walletFiles.failClear = true;
        const r: WalletSyncResult = app.sync();
        expect(r.clearFailed).assertTrue();
        expect(app.draftClears > 0).assertTrue();
        d.walletFiles.failClear = false;
        p.makeUnknown(kind);
        app.sync();
        const left: number = d.walletFiles.files.size;
        expect(left).assertEqual(0);
        p.makeKnown();
        const again: WalletSyncResult = app.sync();
        expect(again.clearFailed).assertFalse();
        expect(app.cache.loadAs(app.cache.ownerOf(A)) === null).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 1. / T-06 / T-07：首页（C8）
    it('fhm0724_x19_1_home_confirmed_member_transient_unknown_keeps_lkg_logout_and_switch_delete', 0, () => {
      // a）冷启动暂时未知（含隐私未决）→ 已同意 / 可读：不删。
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = new Device();
        d.login(A, E1);
        const prev: HomeApp = new HomeApp(new Proc(d));
        prev.sync();
        const scope: string = (prev.current as HomeIdentity).scope;
        expect(prev.store.save(scope, '{"lkg":"A-E1"}', prev.store.clearGeneration, prev.store.epochTicket())).assertTrue();
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const home: HomeApp = new HomeApp(p);
        home.sync();
        home.sync();
        p.makeKnown();
        home.sync();
        expect(home.store.load(scope)).assertEqual('{"lkg":"A-E1"}');
      }
      // b）已确认会员 A/E1 之后暂时未知（没有登出 / 清理事件），恢复同一身份：LKG 保留；之后登出照删。
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = new Device();
        d.login(A, E1);
        const p: Proc = new Proc(d);
        const home: HomeApp = new HomeApp(p);
        home.sync();
        const scope: string = (home.current as HomeIdentity).scope;
        expect(home.store.save(scope, '{"lkg":"A-E1"}', home.store.clearGeneration, home.store.epochTicket())).assertTrue();
        const file: string = HomeLkgStore.partitionTag(scope, E1);
        p.makeUnknown(kind);
        const during: HomeSyncOutcome = home.sync();
        const keptDuring: boolean = d.lkg.files.has(file);
        expect(during.cleared === null).assertTrue();
        expect(keptDuring).assertTrue();
        p.makeKnown();
        const back: HomeSyncOutcome = home.sync();
        expect(back.cleared === null).assertTrue();
        expect(home.store.load(scope)).assertEqual('{"lkg":"A-E1"}');
        p.tokens.clear();
        home.sync();
        const scopeTag: string = HomeLkgStore.tagOf(scope);
        const left: string[] = Array.from(d.lkg.files.keys()).filter((k: string): boolean => k === scopeTag
          || k.startsWith(scopeTag + '/'));
        expect(left.length).assertEqual(0);
      }
      // c）已确认会员 A/E1 → 暂时未知 → 恢复为另一个账号 B：A 的作用域照删（以最后一次已确认身份对账）。
      const d: Device = new Device();
      d.login(A, E1);
      const p: Proc = new Proc(d);
      const home: HomeApp = new HomeApp(p);
      home.sync();
      const scopeA: string = (home.current as HomeIdentity).scope;
      expect(home.store.save(scopeA, '{"lkg":"A-E1"}', home.store.clearGeneration, home.store.epochTicket())).assertTrue();
      p.makeUnknown('credentials');
      home.sync();
      p.tokens.save(new SessionTokenSet('access-b', 'refresh-b', 'full', B, E2));
      p.makeKnown();
      home.sync();
      const tagA: string = HomeLkgStore.tagOf(scopeA);
      const leftA: string[] = Array.from(d.lkg.files.keys()).filter((k: string): boolean => k === tagA
        || k.startsWith(tagA + '/'));
      expect(leftA.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 3②（T-12）：判据已是 A/E1、未知期间构造并登记订单详情页、恢复同身份
    it('fhm0724_x19c_2_order_detail_built_while_unknown_same_key_loads_after_recovery', 0, async () => {
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        // 暂时未知期间打开订单详情（AppOrders.detailConfig 同一接线：构造并 addDetail；中间没有同步）。
        p.makeUnknown(kind);
        const detailPage: OrderDetailController = app.newDetail();
        // 详情页按生产路径首次加载（OrderDetailView.aboutToAppear → load），此刻身份未知。
        detailPage.load('O3');
        expect(await until((): boolean => detailPage.snapshot.phase !== OrderPhase.LOADING)).assertTrue();
        p.makeKnown();
        // 恢复同一身份：只走正常同步（评审 r1 R1-01：不再手动 load）。
        app.sync();
        const loaded: boolean = await until((): boolean => detailPage.snapshot.phase === OrderPhase.CONTENT);
        expect(loaded).assertTrue();
        const shown: OrderRecord | null = detailPage.snapshot.detail;
        expect(shown !== null && shown['order_id'] === 'O3').assertTrue();
        expect(detailPage.alive()).assertTrue();
        expect(detailPage.ownerScope).assertEqual(p.scopeKey());
      }
    });

    // ---------------------------------------------------------------- 1.（T-13）首页同账号换登录世代（经 HomeApp.sync / syncWith）
    it('fhm0724_x19_1_home_same_account_epoch_change_deletes_old_partition_via_sync_with', 0, () => {
      // a）已知 A/E1 → 同账号 A/E2（会话计数不变，身份键不变）：keep=false、旧控制器作废、E1 文件删除。
      const d: Device = new Device();
      d.login(A, E1);
      const p: Proc = new Proc(d);
      const home: HomeApp = new HomeApp(p);
      home.sync();
      const scope: string = (home.current as HomeIdentity).scope;
      expect(home.store.save(scope, '{"lkg":"A-E1"}', home.store.clearGeneration, home.store.epochTicket())).assertTrue();
      const e1: string = HomeLkgStore.partitionTag(scope, E1);
      const inv0: number = home.invalidations;
      p.tokens.save(new SessionTokenSet('access-e2', 'refresh-e2', 'full', A, E2));
      const changed: HomeSyncOutcome = home.sync();
      expect(changed.keep).assertFalse();
      expect(home.invalidations).assertEqual(inv0 + 1);
      expect(d.lkg.files.has(e1)).assertFalse();
      expect(home.store.load(scope)).assertNull();
      // 同一 E2 再同步：留着。
      expect(home.sync().keep).assertTrue();
      // b）A/E1 → 暂时未知 → A/E2：未知期间不删；恢复为 A/E2 时 keep=false、作废旧控制器、E1 删除。
      for (const kind of LATER_UNKNOWN_KINDS) {
        const d2: Device = new Device();
        d2.login(A, E1);
        const q: Proc = new Proc(d2);
        const h: HomeApp = new HomeApp(q);
        h.sync();
        const s2: string = (h.current as HomeIdentity).scope;
        expect(h.store.save(s2, '{"lkg":"A-E1"}', h.store.clearGeneration, h.store.epochTicket())).assertTrue();
        const f1: string = HomeLkgStore.partitionTag(s2, E1);
        q.makeUnknown(kind);
        h.sync();
        expect(d2.lkg.files.has(f1)).assertTrue();
        q.tokens.save(new SessionTokenSet('access-e2', 'refresh-e2', 'full', A, E2));
        const inv: number = h.invalidations;
        q.makeKnown();
        const out: HomeSyncOutcome = h.sync();
        expect(out.keep).assertFalse();
        expect(h.invalidations > inv).assertTrue();
        expect(d2.lkg.files.has(f1)).assertFalse();
        expect(h.store.load(s2)).assertNull();
      }
    });

    // ---------------------------------------------------------------- 1.（T-14）冷启动已确认无会话：旧数据照删（订单 / 钱包 / 首页）
    it('fhm0724_x19_1_cold_start_confirmed_no_session_deletes_old_order_wallet_home_data', 0, async () => {
      // 'none' = 首次同步即确认无会话；其余 = 先暂时未知、后确认无会话。
      const modes: string[] = ['none'].concat(UNKNOWN_KINDS);
      for (const mode of modes) {
        const d: Device = seededDevice('O3');
        // 上一个进程的首页会员 LKG（A/E1）。
        const prev: HomeApp = new HomeApp(new Proc(d));
        prev.sync();
        const scope: string = (prev.current as HomeIdentity).scope;
        expect(prev.store.save(scope, '{"lkg":"A-E1"}', prev.store.clearGeneration, prev.store.epochTicket())).assertTrue();
        // 令牌已清除（登出 / 会话失效），进程在缓存清理登记之前退出：缓存、记录、草稿、LKG 都还在，没有待清理标记。
        new SecureSessionTokens(d.tokenStore).clear();
        expect(d.orderFiles.pending || d.walletFiles.pending).assertFalse();
        const p: Proc = new Proc(d);
        ordersServer(p);
        if (mode !== 'none') {
          p.makeUnknown(mode);
        }
        const orders: OrdersApp = new OrdersApp(p);
        orders.compose();
        const wallet: WalletApp = new WalletApp(p);
        wallet.compose();
        const home: HomeApp = new HomeApp(p);
        orders.sync();
        wallet.sync();
        home.sync();
        if (mode !== 'none') {
          p.makeKnown();
          orders.sync();
          wallet.sync();
          home.sync();
        }
        const none: SessionIdentity = p.rig.client.sessionIdentity(p.tokens);
        expect(none.known && none.account === null).assertTrue();
        const orderFiles: number = d.orderFiles.files.size;
        const record: boolean = d.prefs.values.has(PAGE_KEY);
        const walletFiles: number = d.walletFiles.files.size;
        const draft: string | null = d.draft.value;
        const tag: string = HomeLkgStore.tagOf(scope);
        const lkgLeft: string[] = Array.from(d.lkg.files.keys()).filter((k: string): boolean => k === tag
          || k.startsWith(tag + '/'));
        expect(orderFiles).assertEqual(0);
        expect(record).assertFalse();
        expect(walletFiles).assertEqual(0);
        expect(draft === null).assertTrue();
        expect(lkgLeft.length).assertEqual(0);
      }
    });

    // ---------------------------------------------------------------- 第 5 版 R1-04：恢复决策延后期间用户改条件，之后恢复不得覆盖
    it('fhm0724_r5_order_user_query_during_deferred_restore_wins_over_old_record', 0, async () => {
      for (const fault of ['record', 'open']) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        ordersServer(p);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        if (fault === 'record') {
          d.prefs.failNextReads(PAGE_KEY, 1000000);
        } else {
          d.prefs.failNextOpens(1000000);
        }
        // 订单 Tab 显示：恢复记录读不出，决策延后。
        app.coordinator.showTab(null);
        expect(app.restorer.restoreDecided).assertFalse();
        // 用户在决策完成之前自己搜索（F-X-18：用户接管优先）。
        expect(app.list.submitQuery('9988')).assertTrue();
        const searched: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT
          && app.list.conditions().q === '9988');
        expect(searched).assertTrue();
        const requests0: number = app.listRequests();
        // Preferences 恢复后正常同步：放弃按旧记录恢复（不覆盖用户条件、锚点不跳），决策视为完成。
        d.prefs.heal();
        app.sync();
        const settled: boolean = await until((): boolean => app.restorer.restoreDecided
          && app.list.snapshot.phase === OrderPhase.CONTENT);
        expect(settled).assertTrue();
        const q: string | null = app.list.conditions().q;
        const platform: string | null = app.list.conditions().platform;
        const anchor: string = app.keeper.anchor;
        const frozen: boolean = app.keeper.frozen;
        expect(q).assertEqual('9988');
        expect(platform === null).assertTrue();
        expect(anchor === 'O3').assertFalse();
        expect(frozen).assertFalse();
        expect(app.lastListHasSeedQuery()).assertFalse();
        expect(app.listRequests() >= requests0).assertTrue();
        // 之后的持久化记的是用户此刻的条件。
        expect(app.coordinator.persist()).assertEqual(OrderPersistResult.SAVED);
        const record: string = d.prefs.record() ?? '';
        expect(record.indexOf('9988') >= 0 && record.indexOf(SEED_Q) < 0).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 第 5 版 R1-06：冷启动确认无会话删会员 LKG、保留公共 LKG
    it('fhm0724_r5_home_cold_logout_deletes_member_lkg_keeps_public_lkg_and_retries', 0, () => {
      for (const failClear of [false, true]) {
        const d: Device = new Device();
        d.login(A, E1);
        const prev: HomeApp = new HomeApp(new Proc(d));
        prev.sync();
        const member: string = (prev.current as HomeIdentity).scope;
        const guest: string = HomeLkgScope.of(HomeLevel.GUEST, null, 'test');
        const basic: string = HomeLkgScope.of(HomeLevel.BASIC, null, 'test');
        expect(prev.store.save(member, '{"lkg":"member"}', prev.store.clearGeneration, prev.store.epochTicket())).assertTrue();
        expect(prev.store.save(guest, '{"lkg":"guest"}')).assertTrue();
        expect(prev.store.save(basic, '{"lkg":"basic"}')).assertTrue();
        // 令牌已清除、进程在清理登记前退出；本次冷启动第一次同步即确认无会话。
        new SecureSessionTokens(d.tokenStore).clear();
        d.lkg.failClear = failClear;
        const p: Proc = new Proc(d);
        const home: HomeApp = new HomeApp(p);
        home.sync();
        if (failClear) {
          // 删除失败：持久化待清理；下一次进程（重建 Store）只靠已登记的清理重试完成。
          d.lkg.failClear = false;
          const rebuilt: HomeLkgStore = new HomeLkgStore(d.lkg);
          expect(rebuilt.retryPendingClear()).assertTrue();
        }
        const tag: string = HomeLkgStore.tagOf(member);
        const memberLeft: string[] = Array.from(d.lkg.files.keys()).filter((k: string): boolean => k === tag
          || k.startsWith(tag + '/'));
        const reader: HomeLkgStore = new HomeLkgStore(d.lkg);
        expect(memberLeft.length).assertEqual(0);
        expect(reader.load(guest)).assertEqual('{"lkg":"guest"}');
        expect(reader.load(basic)).assertEqual('{"lkg":"basic"}');
        expect(d.lkg.pending === null).assertTrue();
      }
    });

    // ---------------------------------------------------------------- 第 5 版 R1-02：首次确认无会话且已有页面（旧令牌无登录世代）→ 页面、闸门照常重置
    it('fhm0724_r5_first_confirmed_no_session_with_open_pages_resets_pages_and_gates', 0, async () => {
      const d: Device = new Device();
      // 升级前的旧令牌：没有持久化登录世代（身份快照恒为未知），但请求照常带令牌、页面显示账号数据。
      new SecureSessionTokens(d.tokenStore).save(new SessionTokenSet('access-legacy', 'refresh-legacy', 'full', A, null));
      const p: Proc = new Proc(d);
      ordersServer(p);
      const orders: OrdersApp = new OrdersApp(p);
      orders.compose();
      orders.sync();
      orders.coordinator.showTab(null);
      expect(await until((): boolean => orders.list.snapshot.phase === OrderPhase.CONTENT)).assertTrue();
      const wallet: WalletApp = new WalletApp(p);
      wallet.compose();
      wallet.sync();
      const w: WalletController = wallet.page();
      w.load();
      expect(await until((): boolean => w.snapshot.phase === WalletPhase.CONTENT)).assertTrue();
      wallet.summaryMode = 'limited';
      w.refresh();
      expect(await until((): boolean => wallet.session.readGate.active && !w.snapshot.refreshing)).assertTrue();
      const orderEpoch0: number = orders.list.snapshot.sessionEpoch;
      const walletEpoch0: number = wallet.session.epoch;
      // 登出（令牌清除）：本进程第一次确认身份即「无会话」。
      p.tokens.clear();
      orders.sync();
      wallet.sync();
      const orderItems: number = orders.list.snapshot.items.length;
      const orderEpoch: number = orders.list.snapshot.sessionEpoch;
      const walletEpoch: number = wallet.session.epoch;
      const summary: boolean = w.snapshot.summary !== null;
      const gate: boolean = wallet.session.readGate.active;
      expect(orderEpoch > orderEpoch0).assertTrue();
      expect(orderItems).assertEqual(0);
      expect(walletEpoch > walletEpoch0).assertTrue();
      expect(summary).assertFalse();
      expect(gate).assertFalse();
    });

    // ---------------------------------------------------------------- 第 5 版 R1-05：懒布局视口（不可见项 itemRect 抛错 + 卡片高度下界）
    it('fhm0724_r5_x20_lazy_viewport_enough_by_real_card_height_skips_next_cursor', 0, async () => {
      // 评审裁定项：可见卡片的真实高度（100 + 间距 12）已量到时优先于偏小的下界（60）。第二页后 O5 之后有 8 张（真实约 996vp），
      // 已够一屏（632vp）；只按下界算（9 × 60 = 540）会误判不够而请求第三页。期望：不请求 c3 即顶对齐。
      const f: Fx20 = new Fx20([ids(1, 5), ids(6, 13), ids(14, 25)], 640, 'O5', null, true);
      f.port.modes.set('c3', 'hold');
      expect(await f.start()).assertTrue();
      const index: number = await f.drive();
      expect(index).assertEqual(4);
      const c3: number = f.port.requests.get('c3') ?? 0;
      expect(c3).assertEqual(0);
      expect(f.align(index)).assertTrue();
      expect(f.keeper.endReason).assertEqual(OrderAnchorKeeper.END_ARRIVED);
      expect(f.topId()).assertEqual('O5');
      expect(f.port.heldCount).assertEqual(0);
    });

    // ---------------------------------------------------------------- 4. F-X-20：锚点在首页末尾 → 翻到够一屏再顶对齐（不同内容长度 / 视口）
    it('fhm0724_x20_anchor_near_loaded_end_loads_pages_until_a_screen_then_aligns_to_top', 0, async () => {
      const pages: string[][] = [ids(1, 5), ids(6, 7), ids(8, 13), ids(14, 25)];
      // 视口 640：O5 之后约要 5 张；视口 1200：约要 10 张（第二页、第三页之后仍不够，要到第四页）。O8 在第三页。
      const cases: string[] = ['640:O5', '1200:O5', '640:O8', '1200:O8'];
      for (const c of cases) {
        const height: number = Number.parseInt(c.split(':')[0]);
        const target: string = c.split(':')[1];
        const f: Fx20 = new Fx20(pages, height, target);
        expect(await f.start()).assertTrue();
        const index: number = await f.drive();
        expect(index).assertEqual(Number.parseInt(target.substring(1)) - 1);
        expect(f.align(index)).assertTrue();
        const end: string = f.keeper.endReason;
        expect(end).assertEqual(OrderAnchorKeeper.END_ARRIVED);
        expect(f.keeper.anchor).assertEqual(target);
        expect(f.topId()).assertEqual(target);
        expect(f.keeper.frozen).assertFalse();
        expect(f.port.eachPageOnce).assertTrue();
        expect(f.port.firstRequests).assertEqual(1);
        // 结束后再交快照：不再翻页、不再定位。
        const rescrolls: number = f.rescrolls.length;
        const more: number = f.port.moreRequests;
        expect(f.step()).assertEqual(OrderScrollAnchor.DROPPED);
        expect(f.rescrolls.length).assertEqual(rescrolls);
        expect(f.port.moreRequests).assertEqual(more);
      }
    });

    // ---------------------------------------------------------------- 4.（T-16）F-X-20：已够一屏就对齐，不再请求后续页
    it('fhm0724_x20_enough_after_target_aligns_without_requesting_next_cursor', 0, async () => {
      // 视口 640（内容区 632）：O5 之后要约 5 张。第二页加载后 O5 之后已有 8 张——够一屏；第三页（c3）存在但挂起。
      const f: Fx20 = new Fx20([ids(1, 5), ids(6, 13), ids(14, 25)], 640, 'O5');
      f.port.modes.set('c3', 'hold');
      expect(await f.start()).assertTrue();
      const index: number = await f.drive();
      expect(index).assertEqual(4);
      expect(f.align(index)).assertTrue();
      const end: string = f.keeper.endReason;
      expect(end).assertEqual(OrderAnchorKeeper.END_ARRIVED);
      expect(f.topId()).assertEqual('O5');
      expect(f.keeper.frozen).assertFalse();
      // 不释放 c3 就完成了对齐：c3 从未被请求，也没有挂起的翻页。
      const c3: number = f.port.requests.get('c3') ?? 0;
      expect(c3).assertEqual(0);
      expect(f.port.heldCount).assertEqual(0);
      expect(f.port.requests.get('c2') ?? 0).assertEqual(1);
      expect(f.step()).assertEqual(OrderScrollAnchor.DROPPED);
      expect(f.port.requests.get('c3') ?? 0).assertEqual(0);
    });

    // ---------------------------------------------------------------- 4. F-X-20：目标不存在且到底 / 翻页失败 / 被限流 → 结束恢复、不循环请求
    it('fhm0724_x20_target_missing_end_failure_or_throttled_ends_restore_without_looping', 0, async () => {
      for (const mode of ['end', 'fail', 'throttled']) {
        const gate: OrderRateGate = fx20Gate();
        const f: Fx20 = new Fx20([ids(1, 5), ids(6, 9)], 640, 'O99', gate);
        if (mode === 'fail') {
          f.port.modes.set('c2', 'fail');
        }
        expect(await f.start()).assertTrue();
        if (mode === 'throttled') {
          gate.start(120000, null);
        }
        const r: number = await f.drive();
        expect(r).assertEqual(OrderScrollAnchor.DROPPED);
        expect(f.keeper.frozen).assertFalse();
        const requests: number = f.port.moreRequests;
        for (let i: number = 0; i < 3; i++) {
          expect(f.step()).assertEqual(OrderScrollAnchor.DROPPED);
        }
        const settled: boolean = await until((): boolean => !f.list.snapshot.loadingMore);
        expect(settled).assertTrue();
        expect(f.port.moreRequests).assertEqual(requests);
        expect(f.port.moreRequests <= 1).assertTrue();
        expect(f.rescrolls.length).assertEqual(0);
        if (mode === 'throttled') {
          expect(f.port.moreRequests).assertEqual(0);
        }
      }
    });

    // ---------------------------------------------------------------- 4. F-X-20：翻页慢 / 失败不挂死、不重复请求；挂起期间用户接管
    it('fhm0724_x20_tail_load_more_slow_or_failing_does_not_hang_or_repeat', 0, async () => {
      // a）慢网：挂起期间反复交快照只发一次；最终失败 → 不再自动翻页，按已加载内容结束恢复（解冻）。
      const f: Fx20 = new Fx20([ids(1, 5), ids(6, 16)], 640, 'O5');
      f.port.modes.set('c2', 'hold');
      expect(await f.start()).assertTrue();
      for (let i: number = 0; i < 4; i++) {
        expect(f.step()).assertEqual(OrderScrollAnchor.WAIT);
      }
      const held: boolean = await until((): boolean => f.port.heldCount === 1);
      expect(held).assertTrue();
      expect(f.port.moreRequests).assertEqual(1);
      f.port.release(false);
      const failed: boolean = await until((): boolean => !f.list.snapshot.loadingMore
        && f.list.snapshot.loadMoreError !== null);
      expect(failed).assertTrue();
      const index: number = f.step();
      expect(index).assertEqual(4);
      expect(f.port.moreRequests).assertEqual(1);
      f.align(index);
      expect(f.keeper.frozen).assertFalse();
      expect(f.step()).assertEqual(OrderScrollAnchor.DROPPED);
      expect(f.port.moreRequests).assertEqual(1);
      // b）翻页挂起期间用户触摸列表：恢复取消；翻页结算后列表退出 loadingMore，之后不再翻页、不再定位。
      const g: Fx20 = new Fx20([ids(1, 5), ids(6, 16)], 640, 'O5');
      g.port.modes.set('c2', 'hold');
      expect(await g.start()).assertTrue();
      expect(g.step()).assertEqual(OrderScrollAnchor.WAIT);
      expect(await until((): boolean => g.port.heldCount === 1)).assertTrue();
      expect(g.sync.touchDown(true)).assertTrue();
      const persistedAtTouch: number = g.persisted.length;
      expect(g.step()).assertEqual(OrderScrollAnchor.DROPPED);
      g.port.release(true);
      const done: boolean = await until((): boolean => !g.list.snapshot.loadingMore
        && g.list.snapshot.items.length === 16);
      expect(done).assertTrue();
      expect(g.step()).assertEqual(OrderScrollAnchor.DROPPED);
      expect(g.port.moreRequests).assertEqual(1);
      expect(g.rescrolls.length).assertEqual(0);
      expect(g.persisted.length).assertEqual(persistedAtTouch);
      expect(g.keeper.frozen).assertFalse();
    });
  });
}
