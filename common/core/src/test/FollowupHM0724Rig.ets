// FU-HM-0724 测试设施（测试作者，2026-10-16）：一台「设备」（跨进程保留的存储）+ 一次「进程」（真实 ApiClient + 真实
// SecureSessionTokens，冷启动时令牌尚未装载）。身份暂时未知用三种真实来源模拟：
// - tokens：安全存储（Asset）读令牌项抛错（SecureSessionTokens.load 记 readFailed、不缓存，下次再读；成功一次后进程内缓存）；
// - credentials：撤回清理未完成（NetworkContext.credentialsReadable = false）；
// - environment：环境闸门未就绪（endpoints undefined）；
// - privacy：隐私屏障未过（冷启动隐私结论未决，privacy = NOT_DECIDED）。
// 「第 n 次读失败」= FlakyTokenStore.failNextReads(k)：之后 k 次读令牌项抛错，第 k+1 次起正常——与 SecureSessionTokens 的真实语义一致
// （装载成功后不再读存储，所以已知之后不会再出现单次读失败）。不改产品代码，不加产品侧钩子。
import {
  ApiOutcome, ApiRequest, ApiResult, ClientScope, ClipboardController, HomeIdentity, HomeLevel, OrderListConditions,
  OrderRateGate, PendingKeyRecord, WalletApiPort, WithdrawInputBackend, WithdrawInputDraft, FlushedPageStateKv, MemoryHomeLkgBackend, MemoryOrderCacheStore,
  OrderAnchorKeeper, OrderListController, OrderListDeps, OrderListViewport, OrderPageRestorer, OrderPageState,
  OrderPageStateKv, OrderPageStateStore, OrderPersistResult, OrderRecord, OrderSessionHub, OrderStaleCache, SearchApiPort,
  SecureEntry, SecureSessionTokens, SecureStore, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse,
  WalletRecord, WalletSession, WalletStaleCache, ApiClientSearchPort
} from '../../Index';
import { envelope, flush, Rig } from './NetworkTestRig';
import { NOW, order, page } from './OrderIntegration.test';
import { summaryJson } from './WalletIntegration.test';

export const A: string = 'user-1';
export const E1: string = 'epoch-login-1';
export const E2: string = 'epoch-login-2';
export const PAGE_KEY: string = 'orders.page_state';
export const TOKENS_ALIAS: string = 'session_tokens';
/** 三种「身份暂时未知」。 */
export const UNKNOWN_KINDS: string[] = ['tokens', 'credentials', 'environment', 'privacy'];
/** 已知之后还可能出现的暂时未知（令牌装载成功后进程内缓存，不会再读失败；见 SessionTokens.ets SecureSessionTokens.load）。 */
export const LATER_UNKNOWN_KINDS: string[] = ['credentials', 'environment', 'privacy'];
/** 预存记录的非默认条件：平台 taobao + 完整订单号搜索词。 */
export const SEED_Q: string = '3741234567890123456';
export const SEED_PLATFORM: string = 'taobao';

/** 订单列表缓存文件（账号 + 登录世代分区）。 */
export function listFile(account: string, epoch: string): string {
  return OrderStaleCache.partitionTag(account, epoch) + '/list_self.json';
}

/** 钱包摘要缓存文件。 */
export function walletFile(account: string, epoch: string): string {
  return OrderStaleCache.partitionTag(account, epoch) + '/summary.json';
}

/**
 * 等结算条件（不按固定时长）：反复排空微任务直到 cond 成立，最多 rounds 轮；返回结算时的 cond()。
 * 调用方先断言返回值为 true，再断言其余结果（负向断言都放在结算之后、引用局部值）。
 */
export async function until(cond: () => boolean, rounds: number = 60): Promise<boolean> {
  for (let i: number = 0; i < rounds && !cond(); i++) {
    await flush();
  }
  return cond();
}

/** 令牌所在的安全存储：读令牌项可按次数注入失败（gets 记读取次数）。 */
export class FlakyTokenStore implements SecureStore {
  readonly values: Map<string, string> = new Map<string, string>();
  gets: number = 0;
  private failing: number = 0;

  /** 之后 k 次读令牌项抛错（k = 0 取消）。 */
  failNextReads(k: number): void {
    this.failing = k;
  }

  get(alias: string): string | null {
    if (alias === TOKENS_ALIAS) {
      this.gets++;
      if (this.failing > 0) {
        this.failing--;
        throw new Error('asset query failed');
      }
    }
    return this.values.get(alias) ?? null;
  }

  set(alias: string, value: string): void {
    this.values.set(alias, value);
  }

  setGrouped(_group: string, alias: string, value: string): void {
    this.values.set(alias, value);
  }

  remove(alias: string): void {
    this.values.delete(alias);
  }

  entries(): SecureEntry[] {
    return [];
  }

  entriesInGroup(_group: string): SecureEntry[] {
    return [];
  }

  clear(): void {
    this.values.clear();
  }
}

/**
 * 偏好命名空间（订单恢复记录 + 待清理标记 .wipe + 归属世代 .gen）：可分别注入「命名空间打不开」与各键读取失败
 * （Preferences 暂时读不出）。
 */
export class Prefs {
  readonly values: Map<string, string> = new Map<string, string>();
  private failReads: Map<string, number> = new Map<string, number>();
  private failOpens: number = 0;

  /** 之后 k 次读 key 抛错（k = 0 取消）。 */
  failNextReads(key: string, k: number): void {
    this.failReads.set(key, k);
  }

  /** 之后 k 次打开命名空间失败（k = 0 取消）。 */
  failNextOpens(k: number): void {
    this.failOpens = k;
  }

  /** 恢复记录键（兼容旧写法）。 */
  failNextRecordReads(k: number): void {
    this.failNextReads(PAGE_KEY, k);
  }

  /** 取消全部故障。 */
  heal(): void {
    this.failReads.clear();
    this.failOpens = 0;
  }

  kv(): OrderPageStateKv {
    if (this.failOpens > 0) {
      this.failOpens--;
      throw new Error('preferences open failed');
    }
    return new FlushedPageStateKv((key: string): string | null => {
      const left: number = this.failReads.get(key) ?? 0;
      if (left > 0) {
        this.failReads.set(key, left - 1);
        throw new Error('preferences read failed');
      }
      return this.values.get(key) ?? null;
    }, (key: string, value: string): void => {
      this.values.set(key, value);
    }, (key: string): void => {
      this.values.delete(key);
    }, (): void => {
    });
  }

  /** 记录里的锚点（没有记录为 null；直接看存储，不经故障注入）。 */
  anchor(): string | null {
    const s: OrderPageState | null = OrderPageState.decode(this.values.get(PAGE_KEY) ?? null);
    return s === null ? null : s.anchor;
  }

  /** 记录原文。 */
  record(): string | null {
    return this.values.get(PAGE_KEY) ?? null;
  }
}

/** 提现金额草稿的存储（偏好里的一个键；跨进程保留）。 */
export class DraftStore implements WithdrawInputBackend {
  value: string | null = null;

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    this.value = value;
  }

  flushSync(): void {
  }

  flushLater(): void {
  }
}

/** 一台设备：跨「进程」保留的存储。 */
export class Device {
  readonly tokenStore: FlakyTokenStore = new FlakyTokenStore();
  readonly orderFiles: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly walletFiles: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly prefs: Prefs = new Prefs();
  readonly lkg: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
  readonly draft: DraftStore = new DraftStore();

  /** 写入一份会话（登录成功后落盘的令牌项）。 */
  login(account: string, epoch: string): void {
    new SecureSessionTokens(this.tokenStore).save(new SessionTokenSet('access-' + epoch, 'refresh-' + epoch, 'full',
      account, epoch));
  }
}

/** 一次进程：真实 ApiClient（NetworkTestRig）+ 真实 SecureSessionTokens（冷启动未装载）。 */
export class Proc {
  readonly device: Device;
  readonly tokens: SecureSessionTokens;
  readonly rig: Rig;

  constructor(device: Device) {
    this.device = device;
    this.tokens = new SecureSessionTokens(device.tokenStore);
    this.rig = new Rig(null, null, null, null, null, null, null, this.tokens);
    this.rig.nowMillis = NOW;
  }

  /** AppOrders.account / AppWallet.account：ApiClient.sessionAccount。 */
  account(): string | null {
    return this.rig.client.sessionAccount();
  }

  /** AppNetwork.loginEpoch：ApiClient.sessionLoginEpoch(令牌存储)。 */
  epoch(): string | null {
    return this.rig.client.sessionLoginEpoch(this.tokens);
  }

  /** AppOrders.scopeKey / AppWallet.scopeKey。 */
  scopeKey(): string {
    return ClipboardController.scopeKey(this.rig.client.captureScope());
  }

  /** 让身份暂时未知（kind 见 UNKNOWN_KINDS）。 */
  makeUnknown(kind: string): void {
    if (kind === 'tokens') {
      this.device.tokenStore.failNextReads(1000000);
    } else if (kind === 'credentials') {
      this.rig.context.readable = false;
    } else if (kind === 'privacy') {
      this.rig.context.privacyRaw = '';
    } else {
      this.rig.context.settled = false;
    }
  }

  /** 凭据读不出时的归属键（ApiClient.captureScope 在凭据不可读时给出的形状：credentialsAllowed=false、账号为空）。 */
  unknownScopeKey(): string {
    const s: ClientScope = this.rig.client.captureScope();
    return ClipboardController.scopeKey(new ClientScope(s.epoch, s.loginSerial, s.sessionGeneration, false, s.privacy,
      s.apiBase, null));
  }

  /** 身份恢复可读。 */
  makeKnown(): void {
    this.device.tokenStore.failNextReads(0);
    this.rig.context.readable = true;
    this.rig.context.settled = true;
    this.rig.context.privacyRaw = 'full';
  }
}

/** 订单列表的响应：/v1/orders 第一页（firstCursor 非空时还有下一页）、带 cursor 的为第二页。 */
export function ordersServer(p: Proc, first: string[], firstCursor: string | null, second: string[]): void {
  p.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
    const json: string = r.url.indexOf('cursor=') >= 0 ? page(second, null) : page(first, firstCursor);
    return Promise.resolve(envelope(0, json));
  };
}

/** 订单 id 列表 → 列表行 JSON。 */
export function rows(ids: string[]): string[] {
  return ids.map((id: string): string => order(id, '37412345' + id.substring(1).padStart(4, '0'), 'PAID'));
}

/**
 * 订单的生产接线（与 entry AppOrders.compose 一致；不带身份快照，当前代码的构造参数）。
 */
export class LegacyOrdersApp {
  readonly p: Proc;
  readonly hub: OrderSessionHub;
  readonly cache: OrderStaleCache;
  readonly pageStore: OrderPageStateStore;
  readonly keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
  readonly restorer: OrderPageRestorer;
  readonly list: OrderListController;

  constructor(p: Proc) {
    this.p = p;
    this.hub = new OrderSessionHub((): number => NOW, (): string => p.scopeKey());
    this.cache = new OrderStaleCache(p.device.orderFiles, (): string | null => p.account(), (): number => NOW,
      (): string | null => p.epoch());
    this.pageStore = new OrderPageStateStore((): OrderPageStateKv | null => p.device.prefs.kv(), PAGE_KEY);
    const store: OrderPageStateStore = this.pageStore;
    this.restorer = new OrderPageRestorer((): string | null => store.read(), (v: string | null): void => store.write(v),
      (): string | null => p.account(), this.keeper, store.marks(), (): string | null => p.epoch());
    const deps: OrderListDeps = new OrderListDeps(new ApiClientSearchPort(p.rig.client));
    deps.cache = this.cache;
    deps.clock = (): number => NOW;
    deps.scope = (): string => p.scopeKey();
    this.hub.attachList(deps);
    this.list = new OrderListController(deps);
    this.hub.setList(this.list);
  }
}

/**
 * 预置设备（上一个进程 A/E1 留下的）：令牌、订单列表第一页缓存、带锚点的恢复记录（经生产 OrderPageRestorer.save 写下）、
 * 钱包摘要缓存（经生产 WalletStaleCache.save）。
 */
export function seededDevice(anchor: string = 'O3'): Device {
  const d: Device = new Device();
  d.login(A, E1);
  const p: Proc = new Proc(d);
  ordersServer(p, rows(['O1', 'O2', 'O3', 'O4', 'O5']), null, []);
  const app: LegacyOrdersApp = new LegacyOrdersApp(p);
  app.cache.saveList('self', JSON.parse(page(rows(['O1', 'O2', 'O3', 'O4', 'O5']), null)) as OrderRecord);
  app.restorer.restore(app.list, null);
  const c: OrderListConditions = new OrderListConditions();
  c.platform = SEED_PLATFORM;
  c.q = SEED_Q;
  app.list.restore(c, null);
  app.keeper.visible(anchor);
  if (app.restorer.save(app.list) !== OrderPersistResult.SAVED) {
    throw new Error('seed: restore record not saved');
  }
  const wallet: WalletStaleCache = new WalletStaleCache(d.walletFiles, (): string | null => p.account(), (): number => NOW,
    (): string | null => p.epoch());
  wallet.save(JSON.parse(summaryJson()) as WalletRecord);
  // 提现页留下的金额草稿（A/E1 分区）。
  new WithdrawInputDraft(d.draft).save(OrderStaleCache.partitionTag(A, E1), '25');
  if (!d.orderFiles.files.has(listFile(A, E1)) || !d.walletFiles.files.has(walletFile(A, E1))
    || d.prefs.anchor() !== anchor || d.draft.value === null) {
    throw new Error('seed: device not prepared');
  }
  return d;
}

/** 钱包会话（与 entry AppWallet 同一接线）。 */
export function walletSessionOf(p: Proc): WalletSession {
  return new WalletSession((): number => NOW, (): string => p.scopeKey());
}

/** 钱包缓存（与 entry AppWallet.compose 同一接线：按账号 + 登录世代分区）。 */
export function walletCacheOf(p: Proc): WalletStaleCache {
  return new WalletStaleCache(p.device.walletFiles, (): string | null => p.account(), (): number => NOW,
    (): string | null => p.epoch());
}

// ---------------------------------------------------------------- F-X-20：分页列表 + 有底的视口

/**
 * listOrders 的假端口（多页）：pages[i] 为第 i+1 页的订单号；第 i+1 页的 next_cursor 为 'c' + (i+2)（最后一页为 null）。
 * 每个 cursor 可设结局 'ok' | 'hold' | 'fail'；记下每个 cursor 的请求次数。
 */
export class PagedOrdersPort implements SearchApiPort {
  pages: string[][] = [];
  readonly modes: Map<string, string> = new Map<string, string>();
  readonly requests: Map<string, number> = new Map<string, number>();
  firstRequests: number = 0;
  private held: HeldPage[] = [];

  /** 带 cursor 的翻页请求总数。 */
  get moreRequests(): number {
    let n: number = 0;
    this.requests.forEach((v: number): void => {
      n += v;
    });
    return n;
  }

  /** 每个 cursor 至多请求一次。 */
  get eachPageOnce(): boolean {
    let ok: boolean = true;
    this.requests.forEach((v: number): void => {
      ok = ok && v <= 1;
    });
    return ok;
  }

  private pageJson(index: number): string {
    const cursor: string | null = index + 1 < this.pages.length ? 'c' + (index + 2) : null;
    return page(rows(this.pages[index]), cursor);
  }

  request(request: ApiRequest): Promise<ApiResult> {
    if (request.operationId !== 'listOrders') {
      return Promise.resolve(PagedOrdersPort.ok('{"items":[]}'));
    }
    const at: number = request.query.indexOf('cursor=');
    if (at < 0) {
      this.firstRequests++;
      return Promise.resolve(PagedOrdersPort.ok(this.pageJson(0)));
    }
    const cursor: string = request.query.substring(at + 7).split('&')[0];
    this.requests.set(cursor, (this.requests.get(cursor) ?? 0) + 1);
    const index: number = Number.parseInt(cursor.substring(1)) - 1;
    const mode: string = this.modes.get(cursor) ?? 'ok';
    if (mode === 'fail' || index < 0 || index >= this.pages.length) {
      return Promise.resolve(PagedOrdersPort.failed());
    }
    if (mode === 'hold') {
      return new Promise<ApiResult>((resolve: (r: ApiResult) => void): void => {
        this.held.push(new HeldPage(index, resolve));
      });
    }
    return Promise.resolve(PagedOrdersPort.ok(this.pageJson(index)));
  }

  cancelOwned(_owner: () => boolean): number {
    return 0;
  }

  get heldCount(): number {
    return this.held.length;
  }

  /** 让挂起的翻页结束（ok = 成功返回该页，否则断网失败）。 */
  release(ok: boolean): void {
    const list: HeldPage[] = this.held;
    this.held = [];
    for (const h of list) {
      h.resolve(ok ? PagedOrdersPort.ok(this.pageJson(h.index)) : PagedOrdersPort.failed());
    }
  }

  static ok(dataJson: string): ApiResult {
    return new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(dataJson) as Record<string, Object>, 'trace-ok', 200,
      TransportFailure.NONE, null, null, null);
  }

  static failed(): ApiResult {
    return new ApiResult(ApiOutcome.NETWORK_ERROR, -1, '', {}, '', 0, TransportFailure.DISCONNECT, null, null, null);
  }
}

class HeldPage {
  readonly index: number;
  readonly resolve: (r: ApiResult) => void;

  constructor(index: number, resolve: (r: ApiResult) => void) {
    this.index = index;
    this.resolve = resolve;
  }
}

/** 订单号 O<from>..O<to>。 */
export function ids(from: number, to: number): string[] {
  const out: string[] = [];
  for (let i: number = from; i <= to; i++) {
    out.push('O' + i);
  }
  return out;
}

/**
 * 有底的订单列表视口（OrderListViewport）：List 顶部内边距 8vp、页头 200、卡片 100、间距 12，视口高 640（内容区 632）。
 * 程序定位 scrollToIndex(listIndex, START) 生效时偏移取「该项上沿」与「最大可滚偏移」的较小值——锚点在已加载内容末尾时顶不上去，
 * 列表停在底部（与 ArkUI List 到底的行为一致）。
 */
export class BoundedViewport implements OrderListViewport {
  static readonly PAD: number = 8;
  static readonly HEADER: number = 200;
  static readonly CARD: number = 100;
  static readonly GAP: number = 12;
  readonly height: number;
  offsetPx: number = 0;
  ids: string[] = [];

  /** height：List 组件高度（vp，含顶部内边距）。 */
  constructor(height: number = 640) {
    this.height = height;
  }

  /** 内容区可见高度（vp，不含顶部内边距）。若实现需要从端口取视口高度，按此命名（见接口约定 C6）。 */
  viewportHeight(): number {
    return this.height - BoundedViewport.PAD;
  }

  setItems(items: OrderRecord[]): void {
    this.ids = items.map((r: OrderRecord): string => {
      const id: Object | null | undefined = r['order_id'];
      return typeof id === 'string' ? id as string : '';
    });
  }

  static contentTop(index: number): number {
    return index === 0 ? 0 : BoundedViewport.HEADER + BoundedViewport.GAP
      + (index - 1) * (BoundedViewport.CARD + BoundedViewport.GAP);
  }

  static heightOf(index: number): number {
    return index === 0 ? BoundedViewport.HEADER : BoundedViewport.CARD;
  }

  maxOffset(): number {
    const n: number = this.ids.length;
    const total: number = BoundedViewport.contentTop(n) + BoundedViewport.heightOf(n);
    return Math.max(0, total - this.viewportHeight());
  }

  paddingTop(): number {
    return BoundedViewport.PAD;
  }

  itemAt(_x: number, y: number): number {
    const content: number = y - BoundedViewport.PAD + this.offsetPx;
    for (let i: number = 0; i <= this.ids.length; i++) {
      const top: number = BoundedViewport.contentTop(i);
      if (content >= top && content < top + BoundedViewport.heightOf(i)) {
        return i;
      }
    }
    return -1;
  }

  itemRect(index: number): number[] | null {
    return [16, BoundedViewport.PAD + BoundedViewport.contentTop(index) - this.offsetPx, 344, BoundedViewport.heightOf(index)];
  }

  offset(): number {
    return this.offsetPx;
  }

  orderIdAt(index: number): string | null {
    return index >= 1 && index <= this.ids.length ? this.ids[index - 1] : null;
  }

  /** 程序定位生效（受列表底部限制）。 */
  alignTo(listIndex: number): void {
    this.offsetPx = Math.min(BoundedViewport.contentTop(listIndex), this.maxOffset());
  }

  /** 此刻顶部可见项的列表下标（取点在内容区顶部之下 1vp）。 */
  topIndex(): number {
    return this.itemAt(1, BoundedViewport.PAD + 1);
  }
}

/**
 * 懒布局视口（评审 r1 R1-05）：与 BoundedViewport 同一几何，但只有当前视口内可见的项能测量——不可见项 itemRect 抛错（与
 * Scroller.getItemRect 对未布局项的行为一致）；另提供卡片高度下界 minimumItemHeight（偏小的保守值 60，真实卡片 100 + 间距 12）。
 */
export class LazyViewport extends BoundedViewport {
  static readonly MINIMUM: number = 60;

  minimumItemHeight(): number {
    return LazyViewport.MINIMUM;
  }

  itemRect(index: number): number[] | null {
    const top: number = BoundedViewport.PAD + BoundedViewport.contentTop(index) - this.offsetPx;
    const bottom: number = top + BoundedViewport.heightOf(index);
    if (index > this.ids.length || bottom <= BoundedViewport.PAD || top >= this.height) {
      throw new Error('item not laid out');
    }
    return [16, top, 344, BoundedViewport.heightOf(index)];
  }
}

/** F-X-20 的列表：分页假端口 + 真实 OrderListController；gate 为共享 42901 闸门（限流场景用）。 */
export function pagedList(port: PagedOrdersPort, gate: OrderRateGate | null = null): OrderListController {
  const deps: OrderListDeps = new OrderListDeps(port);
  deps.clock = (): number => NOW;
  deps.scope = (): string => 'scope-fx20';
  deps.gate = gate;
  return new OrderListController(deps);
}

/** F-X-20 用的限流闸门（与列表同一归属键）。 */
export function fx20Gate(): OrderRateGate {
  return new OrderRateGate((): number => NOW, (): string => 'scope-fx20');
}

/** AppHome.identityNow 同口径（AppMe.level：隐私未同意 / 凭据不可读 → basic；有会话账号 → member；否则 guest）。 */
export function homeIdentityNow(p: Proc): HomeIdentity {
  if (!p.rig.client.credentialReadAllowed()) {
    return new HomeIdentity('test', HomeLevel.BASIC, null, p.scopeKey());
  }
  const account: string | null = p.account();
  return account === null ? new HomeIdentity('test', HomeLevel.GUEST, null, p.scopeKey())
    : new HomeIdentity('test', HomeLevel.MEMBER, account, p.scopeKey());
}

/**
 * 钱包端口包装（T-10）：完成信号在控制器自己的响应回调之后触发——在内层 Promise 上于下一个微任务再挂回调（then 按登记顺序执行，
 * 控制器的 then 在 request 返回时同步登记，所以先执行）。consumed = 已被控制器消费或丢弃的响应数。
 */
export class SettledWalletPort implements WalletApiPort {
  private readonly inner: WalletApiPort;
  issued: number = 0;
  consumed: number = 0;

  constructor(inner: WalletApiPort) {
    this.inner = inner;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    this.issued++;
    const p: Promise<ApiResult> = this.inner.request(request);
    Promise.resolve().then((): void => {
      p.then((): void => {
        this.consumed++;
      }, (): void => {
        this.consumed++;
      });
    });
    return p;
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }

  pendingFor(operationId: string): PendingKeyRecord | null {
    return this.inner.pendingFor(operationId);
  }

  pendingStoreUnavailable(): boolean {
    return this.inner.pendingStoreUnavailable();
  }

  confirmPending(key: string, token: string | null, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.inner.confirmPending(key, token, sendAllowed);
  }

  abandonPending(key: string, sendAllowed: () => boolean): Promise<ApiResult> {
    return this.inner.abandonPending(key, sendAllowed);
  }
}
