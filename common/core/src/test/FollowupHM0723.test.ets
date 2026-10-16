// FU-HM-0723 鸿蒙跟进合集（十一）——iOS FU-IOS-0712 第 1 轮教训回灌的回归测试：
// - 第 1 项 F-X-17（iOS R1-01 S0 同类）：按「账号 + 登录世代」分区的缓存，归属在请求开始 / 页面绑定时一次取得并随回调带到写入点；
//   每类一例「旧响应通过最后一次身份核对后暂停 → 同账号重新登录（新世代）→ 恢复旧回调写入 → 新世代分区读不到（内存 + 重建进程）」，
//   以及会话变化对账（CachePartitionTracker）不保留旧登录的分区。暂停点用写入路径上本来就会调用的依赖（缓存时钟、存储写入、令牌读取）
//   注入「此刻同账号重新登录」，与 iOS 评审的静态交错同构。
// - 第 2 项 F-X-18（iOS R1-06 同类）：搜索页与订单列表的一次性滚动恢复，模型先就绪、列表布局滞后时不按回调轮次结束，等目标真实布局。
// - 第 4 项（iOS R1-03 同类）：剪贴板 parse 整体失败 10405 的非强更 Effect → 统一错误文案 + trace6 + 可重试，不进强更；行内 10405 与
//   真强更不变（服务到页面的对照）。
// 「重建进程」= 同一份存储上新建缓存 / Restorer / 绑定。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, ApiOutcome, ApiResult, CacheOwner, CachePartitionTracker, ClipboardController, ClipboardDeps,
  ClipboardNoticeText, ClipboardReadPolicy, ClipboardResultView, ClipboardSensitive, EffectKind, ErrorEffect,
  FlushedPageStateKv, HomeClearResult, HomeIdentity, HomeLevel, HomeLkgReconciler, HomeLkgScope, HomeLkgStore, LegalVersions, LoginHost, LoginService, ManualPasteAction,
  MemoryClipboardHashStore, MemoryHomeLkgBackend, MemoryOrderCacheStore, MemorySessionTokens, OrderAnchorKeeper,
  OrderDetailController, OrderDetailDeps, OrderListController, OrderListDeps, OrderListScrollSync, OrderListViewport, OrderPageRestorer, OrderPageStateKv, OrderSessionReconciler, OrderSyncResult,
  OrderPageState, OrderPageStateStore, OrderPersistResult, OrderRecord, OrderScrollAnchor, OrderStaleCache, PasteboardPort, ReplayKind,
  RestoreEnd, RestoreStage, ScrollKeeperHost, SearchApiPort, SearchConditions, SearchController, SearchPageRecord,
  SearchScrollKeeper, SearchSnapshot, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse,
  ViewportTop, WalletController, WalletDeps, WalletRecord, WalletStaleCache, WithdrawDraftBinding, WithdrawInputBackend,
  WithdrawInputDraft, ApiRequest
} from '../../Index';
import { envelope, flush, Rig } from './NetworkTestRig';
import { detail, NOW, order, OrderFixture, page } from './OrderIntegration.test';
import { settle, summaryJson, WalletFixture } from './WalletIntegration.test';
import { card as searchCard, FakeConfig, LeakyPort, MutableStatus, page as searchPage } from './SearchReviewR1.test';

const ACCOUNT: string = 'user-1';
const E1: string = 'epoch-login-1';
const E2: string = 'epoch-login-2';
const PAGE_KEY: string = 'orders.page_state';
const OLD_QUERY: string = '3741234567890123456';

/** 此刻的会话（账号 + 持久化登录世代）：relogin 模拟同账号重新登录（新登录世代）。 */
class Session {
  account: string | null = ACCOUNT;
  epoch: string | null = E1;
}

/** 写入路径上的暂停点：第一次调用时执行一次钩子（此刻同账号重新登录），之后照常。 */
class PausePoint {
  private hook: (() => void) | null = null;
  fired: number = 0;

  arm(hook: () => void): void {
    this.hook = hook;
  }

  pass(): void {
    const h: (() => void) | null = this.hook;
    this.hook = null;
    if (h !== null) {
      this.fired++;
      h();
    }
  }
}

function listFile(account: string, epoch: string): string {
  return OrderStaleCache.partitionTag(account, epoch) + '/list_self.json';
}

/**
 * 订单 / 钱包缓存的落盘端口：存储写入入口是暂停点（第 1 轮修复 R1-01）——缓存已经过最后一次归属核对、带着固定分区标签调到这里，
 * 此刻同账号重新登录，再按传入的标签照常写下（迟到写入确实发生）。writes 记下每次实际写入的位置。
 */
class HookCacheStore extends MemoryOrderCacheStore {
  readonly pause: PausePoint = new PausePoint();
  readonly writes: string[] = [];

  write(account: string, name: string, value: string): void {
    this.pause.pass();
    super.write(account, name, value);
    this.writes.push(account + '/' + name);
  }
}

// ---------------------------------------------------------------- 第 1 项：金额草稿、恢复记录、首页 LKG 的存储替身

/** 提现金额草稿的存储（偏好里的一个键；beforeWrite 是写入路径上的暂停点）。 */
class DraftBackend implements WithdrawInputBackend {
  value: string | null = null;
  readonly pause: PausePoint = new PausePoint();

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    this.pause.pass();
    this.value = value;
  }

  flushSync(): void {
  }

  flushLater(): void {
  }
}

/** 订单恢复记录的偏好命名空间（记录键写入前是暂停点）。 */
class HookPrefs {
  readonly values: Map<string, string> = new Map<string, string>();
  readonly pause: PausePoint = new PausePoint();

  kv(): OrderPageStateKv {
    return new FlushedPageStateKv((key: string): string | null => this.values.get(key) ?? null,
      (key: string, value: string): void => {
        if (key === PAGE_KEY) {
          this.pause.pass();
        }
        this.values.set(key, value);
      }, (key: string): void => {
        this.values.delete(key);
      }, (): void => {
      });
  }
}

function restorerOf(prefs: HookPrefs, s: Session): OrderPageRestorer {
  const store: OrderPageStateStore = new OrderPageStateStore((): OrderPageStateKv | null => prefs.kv(), PAGE_KEY);
  return new OrderPageRestorer((): string | null => store.read(), (value: string | null): void => store.write(value),
    (): string | null => s.account, new OrderAnchorKeeper(), store.marks(), (): string | null => s.epoch);
}

/** 首页 LKG 的盘（写入前是暂停点）。 */
class HookLkgBackend extends MemoryHomeLkgBackend {
  readonly pause: PausePoint = new PausePoint();

  write(tag: string, text: string): void {
    this.pause.pass();
    super.write(tag, text);
  }
}

// ---------------------------------------------------------------- 第 1 项：phone_bound（登录后按账号的本机状态）

/**
 * 令牌存储：ApiClient 按这次登录保存会话之后，排一个微任务作暂停点——它在登录执行器 await 回来、写 phone_bound 之前执行（与「别的登录
 * 在这次登录的回调恢复之前落地」同构）。
 */
class HookTokens extends MemorySessionTokens {
  readonly pause: PausePoint = new PausePoint();

  save(tokens: SessionTokenSet): void {
    super.save(tokens);
    Promise.resolve().then((): void => this.pause.pass());
  }
}

class QuietHost implements LoginHost {
  updateState(): string {
    return 'ok';
  }

  hasPendingAction(): boolean {
    return false;
  }

  closeLogin(): void {
  }

  resumePending(): void {
  }

  discardPending(): void {
  }

  enterForceUpdate(): void {
  }

  sessionChanged(): void {
  }

  sessionSynced(): void {
  }

  sessionEnded(): void {
  }
}

function smsLoginData(account: string): string {
  return '{"user_id":"' + account + '","is_new_user":false,"tokens":{"access_token":"login-access",'
    + '"access_expires_at":"2026-10-08T11:30:00+08:00","refresh_token":"login-refresh",'
    + '"refresh_expires_at":"2026-11-07T09:30:00+08:00","session_scope":"full"}}';
}

// ---------------------------------------------------------------- 第 2 项：布局滞后的假列表

/**
 * 假列表（与 FollowupHM1112R3 的 Viewport 同一模型）：视口顶部是 topRow 行、顶边在 topY；topRow -1 = 还没布局。lagging 时 scrollToRow
 * 只记下（模型已就绪、列表布局滞后，定位还没生效），applyPending 才落点。
 */
class LaggingList implements ScrollKeeperHost {
  keeper: SearchScrollKeeper | null = null;
  scrolls: string[] = [];
  topRow: number = -1;
  topY: number = 0;
  lagging: boolean = false;
  pendingRow: number = -1;
  pendingY: number = 0;
  queue: (() => void)[] = [];
  more: () => boolean = (): boolean => false;

  scrollToTop(): void {
    this.topRow = 0;
    this.topY = 0;
  }

  scrollToRow(row: number, extra: number): void {
    this.scrolls.push(row + '@' + extra);
    if (this.lagging) {
      this.pendingRow = row;
      this.pendingY = -extra;
      return;
    }
    this.topRow = row;
    this.topY = -extra;
  }

  applyPending(): void {
    this.lagging = false;
    this.topRow = this.pendingRow;
    this.topY = this.pendingY;
  }

  loadMore(): boolean {
    return this.more();
  }

  later(task: () => void): void {
    this.queue.push(task);
  }

  measure(): ViewportTop | null {
    if (this.keeper === null || this.topRow < 0) {
      return null;
    }
    const k: SearchScrollKeeper = this.keeper;
    for (let row: number = this.topRow; row < k.currentRows.length; row++) {
      const c: number = k.cardIndexOfRow(row);
      if (c >= 0) {
        return new ViewportTop(c, row === this.topRow ? this.topY : 0);
      }
    }
    return null;
  }
}

class SearchPage {
  readonly status: MutableStatus = new MutableStatus(['taobao']);
  readonly port: LeakyPort = new LeakyPort();
  readonly list: LaggingList = new LaggingList();
  readonly keeper: SearchScrollKeeper;
  readonly controller: SearchController;

  constructor() {
    this.keeper = new SearchScrollKeeper(this.list);
    this.list.keeper = this.keeper;
    this.controller = new SearchController(this.port, () => this.status.layers(), new FakeConfig());
    this.list.more = (): boolean => this.controller.loadMore();
    this.controller.onChange = (s: SearchSnapshot): void => {
      this.keeper.onSnapshot(s);
    };
  }

  restore(record: SearchPageRecord): void {
    this.keeper.begin(record, false);
    this.controller.open(null, null, record.conditions);
  }
}

function searchCards(from: number, to: number): string[] {
  const out: string[] = [];
  for (let i: number = from; i <= to; i++) {
    out.push(searchCard('tb:' + i, 'taobao'));
  }
  return out;
}

/** 回收前：第 4 轮查询 milk，顶部是第 6 张卡（序号 5）、已滚出 30vp。 */
function savedSearch(): SearchPageRecord {
  const r: SearchPageRecord = new SearchPageRecord();
  const c: SearchConditions = new SearchConditions();
  c.keyword = 'milk';
  c.platform = 'taobao';
  c.round = 4;
  r.conditions = c;
  r.anchorCard = 5;
  r.anchorRound = 4;
  r.anchorOffset = 30;
  return r;
}

function orderItems(n: number): OrderRecord[] {
  const out: OrderRecord[] = [];
  for (let i: number = 1; i <= n; i++) {
    out.push(JSON.parse('{"order_id":"O' + i + '"}') as OrderRecord);
  }
  return out;
}

/**
 * 第 2 轮修复 R2-01：订单列表的假视口——真实的几何：List 顶部内边距 8vp，第 0 项页头高 200，卡片高 100、项间距 12；offset 是内容的
 * 滚动偏移。itemAt / itemRect 与 Scroller.getItemIndex / getItemRect 同口径（坐标相对 List 组件，内边距算在内）。layout=false 模拟
 * 布局还没跟上（取点抛错）。
 */
class GeometryViewport implements OrderListViewport {
  static readonly PAD: number = 8;
  static readonly HEADER: number = 200;
  static readonly CARD: number = 100;
  static readonly GAP: number = 12;
  offsetPx: number = 0;
  layout: boolean = true;
  readonly ids: string[];

  constructor(cards: number) {
    this.ids = [];
    for (let i: number = 1; i <= cards; i++) {
      this.ids.push('O' + i);
    }
  }

  /** 第 index 项在内容里的上沿（不含内边距）。 */
  static contentTop(index: number): number {
    return index === 0 ? 0 : GeometryViewport.HEADER + GeometryViewport.GAP
      + (index - 1) * (GeometryViewport.CARD + GeometryViewport.GAP);
  }

  static heightOf(index: number): number {
    return index === 0 ? GeometryViewport.HEADER : GeometryViewport.CARD;
  }

  paddingTop(): number {
    return GeometryViewport.PAD;
  }

  itemAt(_x: number, y: number): number {
    if (!this.layout) {
      throw new Error('no layout');
    }
    const content: number = y - GeometryViewport.PAD + this.offsetPx;
    for (let i: number = 0; i <= this.ids.length; i++) {
      const top: number = GeometryViewport.contentTop(i);
      if (content >= top && content < top + GeometryViewport.heightOf(i)) {
        return i;
      }
    }
    return -1;
  }

  itemRect(index: number): number[] | null {
    if (!this.layout) {
      return null;
    }
    return [16, GeometryViewport.PAD + GeometryViewport.contentTop(index) - this.offsetPx, 344,
      GeometryViewport.heightOf(index)];
  }

  offset(): number {
    return this.layout ? this.offsetPx : NaN;
  }

  orderIdAt(index: number): string | null {
    return index >= 1 && index <= this.ids.length ? this.ids[index - 1] : null;
  }

  /** 程序定位（scrollToIndex(listIndex, START)）生效：该项上沿对齐内容区顶部。 */
  alignTo(listIndex: number): void {
    this.offsetPx = GeometryViewport.contentTop(listIndex);
  }
}

class ScrollPage {
  readonly keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
  readonly view: GeometryViewport = new GeometryViewport(10);
  readonly persisted: string[] = [];
  readonly rescrolls: number[] = [];
  readonly sync: OrderListScrollSync;

  constructor() {
    this.sync = new OrderListScrollSync(this.keeper, this.view, (): void => {
      this.persisted.push(this.keeper.anchor);
    }, (listIndex: number): void => {
      this.rescrolls.push(listIndex);
    });
  }

  /** 恢复 O7：目标已加载，列表在 O1（偏移 250），延迟对齐回调执行（与 OrderListView.restoreScroll 同一步骤）。 */
  startRestore(): number {
    this.keeper.begin('O7', 'cond');
    this.view.offsetPx = 250;
    this.sync.scrollIndex(1, true);
    expect(this.sync.topOrderId).assertEqual('O1');
    const index: number = this.keeper.resolve(orderItems(10), 'cond', 'content', 1);
    expect(this.keeper.commitAlignAndVerify(this.keeper.ticket, 1, 'cond', this.sync.topOrderId, this.view.offset(), index))
      .assertTrue();
    return index;
  }
}

// ---------------------------------------------------------------- 第 4 项：剪贴板

class FakeBoard implements PasteboardPort {
  text: string | null = null;

  readText(): Promise<string | null> {
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.text = text;
    return Promise.resolve(true);
  }
}

/** parse 由测试给定网络层已结算的结果（Effect 由 ApiClient 给出）；其余照常走真实 ApiClient。 */
class ParsePort implements SearchApiPort {
  readonly inner: SearchApiPort;
  next: ApiResult | null = null;
  parses: number = 0;

  constructor(inner: SearchApiPort) {
    this.inner = inner;
  }

  request(request: ApiRequest): Promise<ApiResult> {
    if (request.operationId === 'parseInput') {
      this.parses++;
      const fixed: ApiResult | null = this.next;
      if (fixed !== null) {
        return Promise.resolve(fixed);
      }
    }
    return this.inner.request(request);
  }

  cancelOwned(owner: () => boolean): number {
    return this.inner.cancelOwned(owner);
  }
}

const PRODUCT_TEXT: string = '分享好物 https://e.tb.cn/h.Demo01?tk=Sample 「全脂纯牛奶 250ml」';

class Clip {
  readonly rig: Rig = new Rig();
  readonly board: FakeBoard = new FakeBoard();
  readonly port: ParsePort;
  readonly controller: ClipboardController;
  forced: number = 0;

  constructor() {
    this.port = new ParsePort(new ApiClientSearchPort(this.rig.client));
    this.rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
    Promise.resolve(envelope(10405, '{"min_supported_version":"9.0.0"}'));
    const deps: ClipboardDeps = new ClipboardDeps(this.board, this.port);
    deps.consent = (): string => ClipboardReadPolicy.CONSENT_AGREED;
    deps.overlay = (): string => ClipboardSensitive.OVERLAY_NONE;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => false;
    deps.clock = (): number => 1800000000000;
    deps.store = new MemoryClipboardHashStore();
    deps.forceUpdate = (_m: string | null): void => {
      this.forced++;
    };
    this.controller = new ClipboardController(deps);
    this.controller.sync();
    this.controller.onForeground();
  }

  async paste(): Promise<void> {
    this.board.text = PRODUCT_TEXT;
    await this.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
    await flush();
  }

  result(): ClipboardResultView | null {
    return this.controller.snapshot.result;
  }
}

function failed10405(effect: ErrorEffect | null): ApiResult {
  const data: Record<string, Object> = JSON.parse('{"min_supported_version":"1.1.0"}') as Record<string, Object>;
  return new ApiResult(ApiOutcome.BUSINESS_ERROR, 10405, '', data, 'trace-0723ab12cd', 400, TransportFailure.NONE, null,
    effect, null);
}

/** 非强更的 10405：REFRESH_ONLY、刷新失败换成的清会话 Effect、刷新暂时失败换成的网络错误 Effect、没有 Effect。 */
function nonForced(): (ErrorEffect | null)[] {
  return [new ErrorEffect(EffectKind.REFRESH_ONLY, null, null, ReplayKind.NONE, false),
    new ErrorEffect(EffectKind.CLEAR_SESSION_LOGIN, 'Login', null, ReplayKind.NONE, false),
    new ErrorEffect(EffectKind.NETWORK_ERROR, null, null, ReplayKind.NONE, false), null];
}

function format(key: string, vars: Map<string, string>): string {
  return key + '|' + (vars.get('trace6') ?? '');
}

export default function followupHM0723Test() {
  describe('FollowupHM0723', () => {
    // ---------------------------------------------------------------- 第 1 项 F-X-17
    it('fhm0723_x17_order_list_late_write_after_same_account_relogin_not_in_new_epoch', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const s: Session = new Session();
      const pause: PausePoint = new PausePoint();
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      // 缓存时钟在「最后一次身份核对（accept）之后、实际写盘之前」被调用：这里就是暂停点。
      const cache: OrderStaleCache = new OrderStaleCache(store, (): string | null => s.account, (): number => {
        pause.pass();
        return NOW;
      }, (): string | null => s.epoch);
      const deps: OrderListDeps = new OrderListDeps(new ApiClientSearchPort(f.rig.client));
      deps.cache = cache;
      deps.clock = (): number => NOW;
      deps.scope = (): string => f.scopeKey;
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', OLD_QUERY, 'PAID')], null));
      const tracker: CachePartitionTracker = new CachePartitionTracker();
      tracker.observe(ACCOUNT, cache.owner());
      pause.arm((): void => {
        // 同账号重新登录：新登录世代、会话归属换代（清空通知还没到）。
        s.epoch = E2;
        f.scopeKey = 'scope-relogin';
      });
      const c: OrderListController = new OrderListController(deps);
      c.ensureLoaded();
      await flush();
      expect(pause.fired).assertEqual(1);
      expect(c.snapshot.items.length).assertEqual(1);
      // 内存：新世代分区读不到；盘上没有新世代分区的文件，也没有落到旧世代以外的任何位置。
      expect(cache.loadList('self') === null).assertTrue();
      expect(store.files.has(listFile(ACCOUNT, E2))).assertFalse();
      expect(store.files.size).assertEqual(0);
      // 重建进程（同一份存储，新世代）：读不到。
      const rebuilt: OrderStaleCache = new OrderStaleCache(store, (): string | null => ACCOUNT, (): number => NOW,
        (): string | null => E2);
      expect(rebuilt.loadList('self') === null).assertTrue();
      // 会话变化对账：同账号、分区变了 → 删缓存（不保留旧登录的分区）。
      expect(tracker.clears(ACCOUNT, rebuilt.owner())).assertTrue();
      expect(tracker.clears('user-2', null)).assertTrue();
      tracker.observe(ACCOUNT, rebuilt.owner());
      expect(tracker.clears(ACCOUNT, rebuilt.owner())).assertFalse();
      c.leave();
      // 对照：没有重新登录时同一流程照常写进本世代并可读回（含重建进程）。
      const g: OrderFixture = new OrderFixture();
      const s2: Session = new Session();
      const store2: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const cache2: OrderStaleCache = new OrderStaleCache(store2, (): string | null => s2.account, (): number => NOW,
        (): string | null => s2.epoch);
      const deps2: OrderListDeps = new OrderListDeps(new ApiClientSearchPort(g.rig.client));
      deps2.cache = cache2;
      deps2.scope = (): string => g.scopeKey;
      g.list = (_q: string): TransportResponse => envelope(0, page([order('O1', OLD_QUERY, 'PAID')], null));
      const c2: OrderListController = new OrderListController(deps2);
      c2.ensureLoaded();
      await flush();
      expect(store2.files.has(listFile(ACCOUNT, E1))).assertTrue();
      expect(new OrderStaleCache(store2, (): string | null => ACCOUNT, (): number => NOW, (): string | null => E1)
        .loadList('self') !== null).assertTrue();
      c2.leave();
    });

    it('fhm0723_x17_order_detail_late_write_after_same_account_relogin_not_in_new_epoch', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const s: Session = new Session();
      const pause: PausePoint = new PausePoint();
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const cache: OrderStaleCache = new OrderStaleCache(store, (): string | null => s.account, (): number => {
        pause.pass();
        return NOW;
      }, (): string | null => s.epoch);
      const deps: OrderDetailDeps = new OrderDetailDeps(new ApiClientSearchPort(f.rig.client));
      deps.cache = cache;
      deps.clock = (): number => NOW;
      deps.scope = (): string => f.scopeKey;
      f.detailReply = (id: string): TransportResponse => envelope(0, detail(id, '"order_no":"' + OLD_QUERY + '"'));
      pause.arm((): void => {
        s.epoch = E2;
        f.scopeKey = 'scope-relogin';
      });
      const d: OrderDetailController = new OrderDetailController(deps);
      d.load('O1');
      await flush();
      expect(pause.fired).assertEqual(1);
      expect(d.snapshot.detail !== null).assertTrue();
      expect(cache.loadDetail('O1') === null).assertTrue();
      expect(cache.detailCount()).assertEqual(0);
      expect(store.files.size).assertEqual(0);
      const rebuilt: OrderStaleCache = new OrderStaleCache(store, (): string | null => ACCOUNT, (): number => NOW,
        (): string | null => E2);
      expect(rebuilt.loadDetail('O1') === null).assertTrue();
      d.leave();
    });

    it('fhm0723_x17_wallet_summary_late_write_after_same_account_relogin_not_in_new_epoch', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const s: Session = new Session();
      const pause: PausePoint = new PausePoint();
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const account: () => string | null = (): string | null => f.rig.client.sessionAccount();
      const cache: WalletStaleCache = new WalletStaleCache(store, account, (): number => {
        pause.pass();
        return NOW;
      }, (): string | null => s.epoch);
      f.session.sync();
      const deps: WalletDeps = f.deps();
      deps.cache = cache;
      const tracker: CachePartitionTracker = new CachePartitionTracker();
      tracker.observe(ACCOUNT, cache.ownerOf(ACCOUNT));
      pause.arm((): void => {
        // 同账号重新登录：新令牌（同一账号）保存、会话换代、新登录世代。
        f.rig.tokens.save(new SessionTokenSet('acc-relogin', 'ref-relogin', 'full', ACCOUNT));
        f.rig.client.onSessionChanged();
        s.epoch = E2;
      });
      const c: WalletController = new WalletController(deps);
      c.load();
      await settle();
      expect(pause.fired).assertEqual(1);
      expect(c.snapshot.summary !== null).assertTrue();
      expect(cache.load(ACCOUNT) === null).assertTrue();
      expect(cache.loadAs(cache.ownerOf(ACCOUNT)) === null).assertTrue();
      expect(store.files.size).assertEqual(0);
      const rebuilt: WalletStaleCache = new WalletStaleCache(store, (): string | null => ACCOUNT, (): number => NOW,
        (): string | null => E2);
      expect(rebuilt.load() === null).assertTrue();
      expect(tracker.clears(ACCOUNT, rebuilt.ownerOf(ACCOUNT))).assertTrue();
      c.leave();
      // 对照：没有重新登录时写进本世代、可读回。
      const g: WalletFixture = new WalletFixture();
      const store2: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const cache2: WalletStaleCache = new WalletStaleCache(store2, (): string | null => g.rig.client.sessionAccount(),
        (): number => NOW, (): string | null => E1);
      g.session.sync();
      const deps2: WalletDeps = g.deps();
      deps2.cache = cache2;
      const c2: WalletController = new WalletController(deps2);
      c2.load();
      await settle();
      expect(cache2.load(ACCOUNT) !== null).assertTrue();
      c2.leave();
      const sum: WalletRecord = JSON.parse(summaryJson()) as WalletRecord;
      sum['zz_marker'] = 'late';
      // 固定归属在会话变了之后只比较、不写（不覆盖原分区，也不写到新会话名下）。
      const owner: CacheOwner | null = cache2.ownerOf(ACCOUNT);
      g.rig.tokens.save(new SessionTokenSet('acc-x', 'ref-x', 'full', 'user-2'));
      cache2.saveAs(owner, sum);
      const keys: string[] = Array.from(store2.files.keys());
      expect(keys.length).assertEqual(1);
      expect((store2.files.get(keys[0]) ?? '').indexOf('zz_marker') < 0).assertTrue();
    });

    it('fhm0723_x17_withdraw_draft_written_after_check_then_relogin_not_restored_in_new_epoch', 0, () => {
      const s: Session = new Session();
      const backend: DraftBackend = new DraftBackend();
      const draft: WithdrawInputDraft = new WithdrawInputDraft(backend);
      let scope: string = 'scope-e1';
      const bind = (d: WithdrawInputDraft): WithdrawDraftBinding => new WithdrawDraftBinding(d, s.account, scope,
        (): string | null => s.account, (): string | null => s.epoch, (): string => scope);
      const form: WithdrawDraftBinding = bind(draft);
      // 本世代照常保存、恢复。
      form.save('12.34', ACCOUNT, 'scope-e1');
      expect(form.restore()).assertEqual('12.34');
      // 旧表单的保存通过了最后一次核对，写入时（暂停点）同账号重新登录。
      backend.pause.arm((): void => {
        s.epoch = E2;
        scope = 'scope-e2';
      });
      form.save('56.78', ACCOUNT, 'scope-e1');
      expect(backend.pause.fired).assertEqual(1);
      // 新世代的表单（同一进程）与重建进程后的表单都读不到旧登录的金额。
      expect(bind(draft).restore()).assertNull();
      expect(bind(new WithdrawInputDraft(backend)).restore()).assertNull();
      // 旧表单此刻已不是当前会话：既不恢复也不再写。
      expect(form.restore()).assertNull();
      const before: string | null = backend.value;
      form.save('99', ACCOUNT, 'scope-e1');
      expect(backend.value).assertEqual(before);
      // 新世代自己的草稿照常。
      const fresh: WithdrawDraftBinding = bind(draft);
      fresh.save('1', ACCOUNT, 'scope-e2');
      expect(bind(new WithdrawInputDraft(backend)).restore()).assertEqual('1');
      // 清空（空文字）任何归属都执行。
      form.save('', ACCOUNT, 'scope-e1');
      expect(backend.value).assertNull();
    });

    it('fhm0723_x17_order_restore_record_written_after_check_then_relogin_not_restored', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const s: Session = new Session();
      const prefs: HookPrefs = new HookPrefs();
      const r1: OrderPageRestorer = restorerOf(prefs, s);
      const list: OrderListController = f.listController();
      r1.restore(list, null);
      list.submitQuery(OLD_QUERY);
      await flush();
      // 写盘通过了归属核对（账号、登录世代都是固定时的），写进偏好的那一刻同账号重新登录。
      prefs.pause.arm((): void => {
        s.epoch = E2;
      });
      expect(r1.save(list)).assertEqual(OrderPersistResult.SAVED);
      expect(prefs.pause.fired).assertEqual(1);
      expect((prefs.values.get(PAGE_KEY) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
      // 旧 Restorer 在会话已变之后再写：按规则不写（只比较，不按当前世代重新打标签）。
      expect(r1.save(list)).assertEqual(OrderPersistResult.SKIPPED);
      // 同一进程、按新会话重新固定归属后恢复：不按旧登录的记录恢复。
      const again: OrderListController = f.listController();
      r1.restore(again, null);
      expect(again.conditions().q).assertNull();
      // 重建进程（同一份偏好，新世代）：同样不恢复。
      const r2: OrderPageRestorer = restorerOf(prefs, s);
      const rebuilt: OrderListController = f.listController();
      r2.restore(rebuilt, null);
      expect(rebuilt.conditions().q).assertNull();
      f.hub.reset();
    });

    it('fhm0723_x17_home_lkg_written_after_check_then_relogin_not_read_in_new_epoch', 0, () => {
      const s: Session = new Session();
      const disk: HookLkgBackend = new HookLkgBackend();
      const lkg: HomeLkgStore = new HomeLkgStore(disk);
      lkg.bindLoginEpoch((): string | null => s.epoch);
      const scope: string = HomeLkgScope.of(HomeLevel.MEMBER, ACCOUNT, 'test');
      // 冷启动读 LKG 时取的写入票据（HomeController.start）。
      const ticket: string | null = lkg.epochTicket();
      // 迟到的网络结果写入：核对票据通过后、写盘那一刻同账号重新登录。
      disk.pause.arm((): void => {
        s.epoch = E2;
      });
      expect(lkg.save(scope, '{"old":true}', lkg.clearGeneration, ticket)).assertTrue();
      expect(disk.pause.fired).assertEqual(1);
      expect(lkg.load(scope)).assertNull();
      const rebuilt: HomeLkgStore = new HomeLkgStore(disk);
      rebuilt.bindLoginEpoch((): string | null => E2);
      expect(rebuilt.load(scope)).assertNull();
      expect(disk.files.has(HomeLkgStore.partitionTag(scope, E2))).assertFalse();
      // 票据之后世代已变：之后的旧写入直接拒绝。
      expect(lkg.save(scope, '{"old":2}', lkg.clearGeneration, ticket)).assertFalse();
      expect(lkg.load(scope)).assertNull();
    });

    it('fhm0723_x17_sms_login_phone_bound_goes_to_response_account_only', 0, async () => {
      // 对照：没有别的登录落地时，记到这次登录的账号。
      const tokens0: HookTokens = new HookTokens();
      const rig0: Rig = new Rig(null, null, tokens0);
      rig0.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, smsLoginData('user-9')));
      const svc0: LoginService = new LoginService(rig0.client, rig0.tokens, new QuietHost(), new LegalVersions(3, 2),
        (): number => rig0.nowMillis);
      const marked0: (string | null)[] = [];
      svc0.onPhoneVerifiedSession = (a: string | null): void => {
        marked0.push(a);
      };
      expect((await svc0.login('13800138000', '123456', 1800000000000, '', false)).stateRaw).assertEqual('logged_in');
      expect(JSON.stringify(marked0)).assertEqual('["user-9"]');
      // 这次登录的会话已保存、写 phone_bound 之前（暂停点）别的账号登录落地：不把「已绑手机」记到它名下。
      const tokens: HookTokens = new HookTokens();
      const rig: Rig = new Rig(null, null, tokens);
      rig.server.handler = (_r: TransportRequest): Promise<TransportResponse> =>
      Promise.resolve(envelope(0, smsLoginData('user-9')));
      const svc: LoginService = new LoginService(rig.client, rig.tokens, new QuietHost(), new LegalVersions(3, 2),
        (): number => rig.nowMillis);
      const marked: (string | null)[] = [];
      svc.onPhoneVerifiedSession = (a: string | null): void => {
        marked.push(a);
      };
      tokens.pause.arm((): void => {
        tokens.save(new SessionTokenSet('other-access', 'other-refresh', 'full', 'user-other'));
        rig.client.onSessionChanged();
      });
      expect((await svc.login('13800138000', '123456', 1800000000000, '', false)).stateRaw).assertEqual('logged_in');
      expect(tokens.pause.fired).assertEqual(1);
      expect(rig.client.sessionAccount()).assertEqual('user-other');
      expect(marked.indexOf('user-other') < 0).assertTrue();
      expect(marked.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 第 2 项 F-X-18
    it('fhm0723_x18_search_restore_waits_for_lagging_layout_instead_of_attempt_count', 0, async () => {
      const p: SearchPage = new SearchPage();
      p.restore(savedSearch());
      p.port.calls[0].succeed(searchPage(searchCards(1, 12), 'c2'));
      await flush();
      expect(p.keeper.restoring?.stage).assertEqual(RestoreStage.LAYOUT);
      // 模型已就绪；列表在顶部，但之后的定位都滞后生效。
      p.list.topRow = 0;
      p.list.topY = 0;
      p.list.lagging = true;
      p.keeper.layoutReady();
      expect(JSON.stringify(p.list.scrolls)).assertEqual('["5@30"]');
      // 远多于纠偏上限（3 次）的布局回调都停在原处：任务不结束、不按次数放弃，每次重新下发定位。
      for (let i: number = 0; i < 6; i++) {
        p.keeper.layoutReady();
        expect(p.keeper.restoring !== null).assertTrue();
      }
      expect((p.keeper.restoring?.attempts ?? 0) <= 1).assertTrue();
      expect(p.keeper.restoring?.lagged).assertEqual(6);
      expect(p.list.scrolls.length).assertEqual(7);
      expect(p.keeper.endReason).assertEqual(RestoreEnd.NONE);
      // 列表还没布局（量不到）也一样等。
      const top: number = p.list.topRow;
      p.list.topRow = -1;
      p.keeper.layoutReady();
      expect(p.keeper.restoring !== null).assertTrue();
      p.list.topRow = top;
      // 布局终于落点：按实际视口确认到位后才结束，锚点与回收前一致（断言不放宽：卡 5、偏移 30）。
      p.list.applyPending();
      p.keeper.layoutReady();
      expect(p.keeper.restoring === null).assertTrue();
      expect(p.keeper.endReason).assertEqual(RestoreEnd.ARRIVED);
      expect(p.keeper.anchor.card === 5 && p.keeper.anchor.offset === 30).assertTrue();
      // 用户接管仍立即取消（滞后期间触摸）、页面失效仍取消。
      const q: SearchPage = new SearchPage();
      q.restore(savedSearch());
      q.port.calls[0].succeed(searchPage(searchCards(1, 12), 'c2'));
      await flush();
      q.list.topRow = 0;
      q.list.lagging = true;
      q.keeper.layoutReady();
      q.keeper.layoutReady();
      q.keeper.userScroll();
      expect(q.keeper.restoring === null).assertTrue();
      expect(q.keeper.endReason).assertEqual(RestoreEnd.CANCELLED);
      const r: SearchPage = new SearchPage();
      r.restore(savedSearch());
      r.port.calls[0].succeed(searchPage(searchCards(1, 12), 'c2'));
      await flush();
      r.list.topRow = 0;
      r.list.lagging = true;
      r.keeper.layoutReady();
      r.keeper.layoutReady();
      r.keeper.leave();
      expect(r.keeper.restoring === null).assertTrue();
      const scrolls: number = r.list.scrolls.length;
      r.list.applyPending();
      r.keeper.layoutReady();
      expect(r.list.scrolls.length).assertEqual(scrolls);
      // 滞后期间别人把列表移到别处（读屏 / 键盘）：让位。
      const t: SearchPage = new SearchPage();
      t.restore(savedSearch());
      t.port.calls[0].succeed(searchPage(searchCards(1, 12), 'c2'));
      await flush();
      t.list.topRow = 0;
      t.list.lagging = true;
      t.keeper.layoutReady();
      t.keeper.layoutReady();
      t.list.topRow = 3;
      t.list.topY = -12;
      t.keeper.layoutReady();
      expect(t.keeper.restoring === null).assertTrue();
      expect(t.keeper.endReason).assertEqual(RestoreEnd.TAKEOVER);
    });

    it('fhm0723_x18_order_anchor_restore_ends_only_after_target_is_laid_out', 0, () => {
      const k: OrderAnchorKeeper = new OrderAnchorKeeper();
      k.begin('O7', 'cond');
      const index: number = k.resolve(orderItems(10), 'cond', 'content', 1);
      expect(index).assertEqual(6);
      // 页面排入的对齐回调执行：列表在顶部（顶部订单为空串），下发对齐后进入「等布局确认」，仍冻结。
      expect(k.commitAlignAndVerify(k.ticket, 1, 'cond', '', NaN, index)).assertTrue();
      expect(k.frozen && k.verifyingLayout).assertTrue();
      expect(k.anchor).assertEqual('O7');
      // 布局滞后：列表回报还停在下发前的位置——不结束，要求重新下发（多少次都一样）。
      for (let i: number = 0; i < 5; i++) {
        expect(k.observe('', NaN)).assertFalse();
        expect(k.rescrollIndex('')).assertEqual(index);
        expect(k.frozen).assertTrue();
      }
      expect(k.endReason).assertEqual('');
      // 目标真实成为顶部可见项：结束，锚点是目标（持久化值不变）。
      expect(k.observe('O7', 120)).assertFalse();
      expect(k.frozen).assertFalse();
      expect(k.endReason).assertEqual(OrderAnchorKeeper.END_ARRIVED);
      expect(k.anchor).assertEqual('O7');
      expect(k.rescrollIndex('')).assertEqual(-1);
      // 之后的滚动按普通记录。
      expect(k.observe('O8', 300)).assertTrue();
      expect(k.anchor).assertEqual('O8');
      // 用户接管：等确认期间列表停到别处 → 结束、按此刻位置记锚点并要求持久化。
      const u: OrderAnchorKeeper = new OrderAnchorKeeper();
      u.begin('O7', 'cond');
      const ui: number = u.resolve(orderItems(10), 'cond', 'content', 1);
      expect(u.commitAlignAndVerify(u.ticket, 1, 'cond', '', NaN, ui)).assertTrue();
      expect(u.observe('O3', 50)).assertTrue();
      expect(u.frozen).assertFalse();
      expect(u.anchor).assertEqual('O3');
      expect(u.endReason).assertEqual(OrderAnchorKeeper.END_MOVED);
      // 页面失效（出栈）/ 新一轮查询 / 会话变化：取消。
      const v: OrderAnchorKeeper = new OrderAnchorKeeper();
      v.begin('O7', 'cond');
      const vi: number = v.resolve(orderItems(10), 'cond', 'content', 1);
      expect(v.commitAlignAndVerify(v.ticket, 1, 'cond', '', NaN, vi)).assertTrue();
      v.aligned();
      expect(v.frozen).assertFalse();
      expect(v.endReason).assertEqual(OrderAnchorKeeper.END_CANCELLED);
      const w: OrderAnchorKeeper = new OrderAnchorKeeper();
      w.begin('O7', 'cond');
      const wi: number = w.resolve(orderItems(10), 'cond', 'content', 1);
      expect(w.commitAlignAndVerify(w.ticket, 1, 'cond', '', NaN, wi)).assertTrue();
      expect(w.resolve(orderItems(3), 'cond2', 'content', 2)).assertEqual(OrderScrollAnchor.DROPPED);
      expect(w.frozen).assertFalse();
      const x: OrderAnchorKeeper = new OrderAnchorKeeper();
      x.begin('O7', 'cond');
      const xi: number = x.resolve(orderItems(10), 'cond', 'content', 1);
      expect(x.commitAlignAndVerify(x.ticket, 1, 'cond', '', NaN, xi)).assertTrue();
      x.reset();
      expect(x.frozen).assertFalse();
      expect(x.rescrollIndex('')).assertEqual(-1);
    });

    // ---------------------------------------------------------------- 第 1 轮修复 R1-01：暂停点在最后核对之后的存储写入入口
    it('fhm0723_r1_01_order_list_late_write_lands_in_old_partition_unreadable_and_reconcile_deletes_it', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const s: Session = new Session();
      const store: HookCacheStore = new HookCacheStore();
      const cache: OrderStaleCache = new OrderStaleCache(store, (): string | null => s.account, (): number => NOW,
        (): string | null => s.epoch);
      const deps: OrderListDeps = new OrderListDeps(new ApiClientSearchPort(f.rig.client));
      deps.cache = cache;
      deps.scope = (): string => f.scopeKey;
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', OLD_QUERY, 'PAID')], null));
      const tracker: CachePartitionTracker = new CachePartitionTracker();
      tracker.observe(ACCOUNT, cache.owner());
      store.pause.arm((): void => {
        s.epoch = E2;
        f.scopeKey = 'scope-relogin';
      });
      const c: OrderListController = new OrderListController(deps);
      c.ensureLoaded();
      await flush();
      // 迟到写入确实发生，且只写进请求开始时固定的旧分区。
      expect(store.pause.fired).assertEqual(1);
      expect(JSON.stringify(store.writes)).assertEqual(JSON.stringify([listFile(ACCOUNT, E1)]));
      expect(store.files.has(listFile(ACCOUNT, E1))).assertTrue();
      expect(store.files.has(listFile(ACCOUNT, E2))).assertFalse();
      // 新世代（同一进程）与重建进程都读不到。
      expect(cache.loadList('self') === null).assertTrue();
      const rebuilt: OrderStaleCache = new OrderStaleCache(store, (): string | null => ACCOUNT, (): number => NOW,
        (): string | null => E2);
      expect(rebuilt.loadList('self') === null).assertTrue();
      // 会话变化对账（AppOrders.sync 同一判定）：同账号、分区变了 → 删；旧分区确实被删掉。
      expect(tracker.clears(ACCOUNT, cache.owner())).assertTrue();
      expect(cache.clear()).assertTrue();
      expect(store.files.size).assertEqual(0);
      tracker.observe(ACCOUNT, cache.owner());
      expect(tracker.clears(ACCOUNT, cache.owner())).assertFalse();
      c.leave();
    });

    it('fhm0723_r1_01_order_detail_late_write_lands_in_old_partition_unreadable_and_reconcile_deletes_it', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const s: Session = new Session();
      const store: HookCacheStore = new HookCacheStore();
      const cache: OrderStaleCache = new OrderStaleCache(store, (): string | null => s.account, (): number => NOW,
        (): string | null => s.epoch);
      const deps: OrderDetailDeps = new OrderDetailDeps(new ApiClientSearchPort(f.rig.client));
      deps.cache = cache;
      deps.scope = (): string => f.scopeKey;
      f.detailReply = (id: string): TransportResponse => envelope(0, detail(id, '"order_no":"' + OLD_QUERY + '"'));
      const tracker: CachePartitionTracker = new CachePartitionTracker();
      tracker.observe(ACCOUNT, cache.owner());
      store.pause.arm((): void => {
        s.epoch = E2;
        f.scopeKey = 'scope-relogin';
      });
      const d: OrderDetailController = new OrderDetailController(deps);
      d.load('O1');
      await flush();
      const oldFile: string = OrderStaleCache.partitionTag(ACCOUNT, E1) + '/details.json';
      expect(store.pause.fired).assertEqual(1);
      expect(JSON.stringify(store.writes)).assertEqual(JSON.stringify([oldFile]));
      expect((store.files.get(oldFile) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
      expect(cache.loadDetail('O1') === null).assertTrue();
      expect(new OrderStaleCache(store, (): string | null => ACCOUNT, (): number => NOW, (): string | null => E2)
        .loadDetail('O1') === null).assertTrue();
      expect(tracker.clears(ACCOUNT, cache.owner())).assertTrue();
      expect(cache.clear()).assertTrue();
      expect(store.files.size).assertEqual(0);
      d.leave();
    });

    it('fhm0723_r1_01_wallet_summary_late_write_lands_in_old_partition_unreadable_and_reconcile_deletes_it', 0, async () => {
      const f: WalletFixture = new WalletFixture();
      const s: Session = new Session();
      const store: HookCacheStore = new HookCacheStore();
      const cache: WalletStaleCache = new WalletStaleCache(store, (): string | null => f.rig.client.sessionAccount(),
        (): number => NOW, (): string | null => s.epoch);
      f.session.sync();
      const deps: WalletDeps = f.deps();
      deps.cache = cache;
      const tracker: CachePartitionTracker = new CachePartitionTracker();
      tracker.observe(ACCOUNT, cache.ownerOf(ACCOUNT));
      store.pause.arm((): void => {
        f.rig.tokens.save(new SessionTokenSet('acc-relogin', 'ref-relogin', 'full', ACCOUNT));
        f.rig.client.onSessionChanged();
        s.epoch = E2;
      });
      const c: WalletController = new WalletController(deps);
      c.load();
      await settle();
      const oldFile: string = OrderStaleCache.partitionTag(ACCOUNT, E1) + '/summary.json';
      expect(store.pause.fired).assertEqual(1);
      expect(JSON.stringify(store.writes)).assertEqual(JSON.stringify([oldFile]));
      expect(store.files.has(oldFile)).assertTrue();
      expect(cache.load(ACCOUNT) === null).assertTrue();
      expect(cache.loadAs(cache.ownerOf(ACCOUNT)) === null).assertTrue();
      expect(new WalletStaleCache(store, (): string | null => ACCOUNT, (): number => NOW, (): string | null => E2)
        .load() === null).assertTrue();
      // 会话变化对账（AppWallet.sync 同一判定）：删掉旧分区。
      expect(tracker.clears(ACCOUNT, cache.ownerOf(ACCOUNT))).assertTrue();
      expect(cache.clear()).assertTrue();
      expect(store.files.size).assertEqual(0);
      c.leave();
    });

    // ---------------------------------------------------------------- 第 1 轮修复 R1-02：等布局确认期间的用户接管
    it('fhm0723_r1_02_order_verify_same_card_scroll_screen_reader_and_touch_cancel_and_stop_rescroll', 0, () => {
      const start = (): OrderAnchorKeeper => {
        const k: OrderAnchorKeeper = new OrderAnchorKeeper();
        k.begin('O7', 'cond');
        const index: number = k.resolve(orderItems(10), 'cond', 'content', 1);
        expect(k.commitAlignAndVerify(k.ticket, 1, 'cond', 'O1', 100, index)).assertTrue();
        expect(k.verifyingLayout).assertTrue();
        return k;
      };
      // a）同一卡片内滚动（顶部仍是 O1、偏移 100 → 135）：用户接管，取消、记 O1、要求持久化，之后不再下发。
      const a: OrderAnchorKeeper = start();
      expect(a.observe('O1', 100.3)).assertFalse();
      expect(a.frozen).assertTrue();
      expect(a.observe('O1', 135)).assertTrue();
      expect(a.frozen).assertFalse();
      expect(a.anchor).assertEqual('O1');
      expect(a.endReason).assertEqual(OrderAnchorKeeper.END_USER);
      expect(a.rescrollIndex('O1')).assertEqual(-1);
      expect(a.observe('O1', 135)).assertFalse();
      // b）读屏滚动（没有触摸，顶部换成别的卡）：结束，按此刻位置记锚点，之后不再下发。
      const b: OrderAnchorKeeper = start();
      expect(b.observe('O3', 260)).assertTrue();
      expect(b.frozen).assertFalse();
      expect(b.anchor).assertEqual('O3');
      expect(b.rescrollIndex('O1')).assertEqual(-1);
      // c）触摸但没移动：同样按用户接管取消，之后的布局回调不再下发、待执行的对齐回调失效。
      const c: OrderAnchorKeeper = start();
      const ticket: number = c.ticket;
      expect(c.userTouched('O1')).assertTrue();
      expect(c.frozen).assertFalse();
      expect(c.anchor).assertEqual('O1');
      expect(c.endReason).assertEqual(OrderAnchorKeeper.END_USER);
      expect(c.rescrollIndex('O1')).assertEqual(-1);
      expect(c.commitAlignAndVerify(ticket, 1, 'cond', 'O1', 100, 6)).assertFalse();
      expect(c.userTouched('O1')).assertFalse();
      // d）对齐还在排队（aligning）时触摸：回调执行前复核失败，不滚动。
      const d: OrderAnchorKeeper = new OrderAnchorKeeper();
      d.begin('O7', 'cond');
      const di: number = d.resolve(orderItems(10), 'cond', 'content', 1);
      const dt: number = d.ticket;
      expect(d.userTouched('')).assertTrue();
      expect(d.commitAlignAndVerify(dt, 1, 'cond', '', NaN, di)).assertFalse();
      expect(d.frozen).assertFalse();
      // e）没有人动列表：程序定位生效时顶部直接换成目标（偏移跳变不算用户滚动），到位结束。
      const e: OrderAnchorKeeper = start();
      expect(e.observe('O1', 100)).assertFalse();
      expect(e.rescrollIndex('O1')).assertEqual(6);
      expect(e.observe('O7', 900)).assertFalse();
      expect(e.endReason).assertEqual(OrderAnchorKeeper.END_ARRIVED);
      expect(e.anchor).assertEqual('O7');
    });

    // ---------------------------------------------------------------- 第 1 轮修复 R1-03：新查询取消等布局确认时清空锚点
    it('fhm0723_r1_03_new_query_while_verifying_persists_new_conditions_with_empty_anchor', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const s: Session = new Session();
      const prefs: HookPrefs = new HookPrefs();
      const items: string[] = [];
      for (let i: number = 1; i <= 8; i++) {
        items.push(order('O' + i, String(1000 + i), 'PAID'));
      }
      f.list = (_q: string): TransportResponse => envelope(0, page(items, null));
      // 进程 1：滚到 O7，记下恢复记录。
      const r1: OrderPageRestorer = restorerOf(prefs, s);
      const l1: OrderListController = f.listController();
      r1.restore(l1, null);
      l1.ensureLoaded();
      await flush();
      expect(r1.keeper.observe('O7', 500)).assertTrue();
      expect(r1.save(l1)).assertEqual(OrderPersistResult.SAVED);
      expect(OrderPageState.decode(prefs.values.get(PAGE_KEY) ?? null)?.anchor).assertEqual('O7');
      // 进程 2：恢复 O7，对齐已下发、等布局确认时用户提交新搜索（请求还在加载）。
      const r2: OrderPageRestorer = restorerOf(prefs, s);
      const l2: OrderListController = f.listController();
      r2.restore(l2, null);
      l2.ensureLoaded();
      await flush();
      const k: OrderAnchorKeeper = r2.keeper;
      const index: number = k.resolve(l2.snapshot.items, l2.conditions().encode(), l2.snapshot.phase, l2.snapshot.round);
      expect(index).assertEqual(6);
      expect(k.commitAlignAndVerify(k.ticket, l2.snapshot.round, l2.conditions().encode(), '', NaN, index)).assertTrue();
      expect(k.verifyingLayout).assertTrue();
      f.list = (_q: string): TransportResponse | null => null;
      expect(l2.submitQuery('milk')).assertTrue();
      // 页面对新快照（加载中、新轮次）的处理：restoreScroll → resolve，然后持久化。
      k.resolve(l2.snapshot.items, l2.conditions().encode(), l2.snapshot.phase, l2.snapshot.round);
      expect(k.frozen).assertFalse();
      expect(k.anchor).assertEqual('');
      expect(r2.save(l2)).assertEqual(OrderPersistResult.SAVED);
      const saved: OrderPageState | null = OrderPageState.decode(prefs.values.get(PAGE_KEY) ?? null);
      expect(saved !== null && saved.anchor === '').assertTrue();
      // 进程 3（进后台被回收后重建）：恢复新条件，不带旧目标。
      const r3: OrderPageRestorer = restorerOf(prefs, s);
      const l3: OrderListController = f.listController();
      r3.restore(l3, null);
      expect(l3.conditions().q).assertEqual('milk');
      expect(r3.keeper.anchor).assertEqual('');
      expect(r3.keeper.frozen).assertFalse();
      f.hub.reset();
    });

    // ---------------------------------------------------------------- 第 2 轮修复 R2-01：页面级回调顺序与内容区测量
    it('fhm0723_r2_01_order_list_program_scroll_with_top_padding_arrives_on_did_scroll_not_user', 0, () => {
      // a）定位生效：onDidScroll（先）现量到的就是 O7——按到位结束，不判用户接管，不保存旧锚点；随后的 onScrollIndex 照常。
      const a: ScrollPage = new ScrollPage();
      const index: number = a.startRestore();
      a.view.alignTo(index + 1);
      a.sync.didScroll(true);
      expect(a.keeper.endReason).assertEqual(OrderAnchorKeeper.END_ARRIVED);
      expect(a.keeper.frozen).assertFalse();
      expect(a.keeper.anchor).assertEqual('O7');
      a.sync.scrollIndex(index + 1, true);
      expect(a.keeper.anchor).assertEqual('O7');
      expect(a.persisted.indexOf('O1') < 0).assertTrue();
      // b）onDidScroll 时布局还没跟上（测量无效）、偏移已变：不当证据——仍在等，不取消、不保存；onScrollIndex 到达后到位。
      const b: ScrollPage = new ScrollPage();
      const bi: number = b.startRestore();
      b.view.alignTo(bi + 1);
      b.view.layout = false;
      b.sync.didScroll(true);
      expect(b.keeper.verifyingLayout).assertTrue();
      expect(b.persisted.length).assertEqual(0);
      b.view.layout = true;
      b.sync.scrollIndex(bi + 1, true);
      expect(b.keeper.endReason).assertEqual(OrderAnchorKeeper.END_ARRIVED);
      expect(b.persisted.indexOf('O1') < 0).assertTrue();
      // c）取点落在项间距里（-1）同样不当证据。
      const c: ScrollPage = new ScrollPage();
      c.startRestore();
      c.view.offsetPx = GeometryViewport.contentTop(3) - 6;
      c.sync.didScroll(true);
      expect(c.keeper.verifyingLayout).assertTrue();
      expect(c.persisted.length).assertEqual(0);
      // d）对照：同一卡片内的用户滚动（测量有效，顶部仍是 O1、偏移 250 → 280）仍取消（R1-02 不回退），之后不再下发。
      const d: ScrollPage = new ScrollPage();
      d.startRestore();
      d.view.offsetPx = 280;
      d.sync.didScroll(true);
      expect(d.keeper.endReason).assertEqual(OrderAnchorKeeper.END_USER);
      expect(JSON.stringify(d.persisted)).assertEqual('["O1"]');
      d.sync.rescrollIfLagging(true);
      expect(d.rescrolls.length).assertEqual(0);
      // e）布局滞后（定位没生效、偏移没变）：didLayout 重新下发到同一目标（列表下标 = 目标 + 1）。
      const e: ScrollPage = new ScrollPage();
      const ei: number = e.startRestore();
      e.sync.didScroll(true);
      e.sync.rescrollIfLagging(true);
      expect(JSON.stringify(e.rescrolls)).assertEqual(JSON.stringify([ei + 1]));
      // f）触摸：按此刻测量到的顶部订单接管。
      const g: ScrollPage = new ScrollPage();
      g.startRestore();
      expect(g.sync.touchDown(true)).assertTrue();
      expect(g.keeper.anchor).assertEqual('O1');
      expect(g.keeper.endReason).assertEqual(OrderAnchorKeeper.END_USER);
    });

    // ---------------------------------------------------------------- 第 2 轮修复 R2-02：首页会员 LKG 对账删旧世代分区
    it('fhm0723_r2_02_home_lkg_same_account_relogin_reconcile_deletes_old_epoch_partition', 0, () => {
      const s: Session = new Session();
      const disk: HookLkgBackend = new HookLkgBackend();
      const lkg: HomeLkgStore = new HomeLkgStore(disk);
      lkg.bindLoginEpoch((): string | null => s.epoch);
      const a1: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, ACCOUNT, 'scope-e1');
      const reconciler: HomeLkgReconciler = new HomeLkgReconciler();
      // AppHome.build：建控制器时记下身份与登录世代票据（HomeController.start 取同一张票据）。
      reconciler.built(a1, lkg.epochTicket());
      const ticket: string | null = lkg.epochTicket();
      // 迟到的网络结果：核对票据通过后、写盘那一刻同账号重新登录 → 写进旧世代分区。
      disk.pause.arm((): void => {
        s.epoch = E2;
      });
      expect(lkg.save(a1.scope, '{"old":true}', lkg.clearGeneration, ticket)).assertTrue();
      const oldTag: string = HomeLkgStore.partitionTag(a1.scope, E1);
      expect(disk.files.get(oldTag)).assertEqual('{"old":true}');
      expect(lkg.load(a1.scope)).assertNull();
      // AppHome.syncInner：身份变了（会话归属键换代、同账号）→ 生产对账入口删掉旧账号作用域（含旧世代子目录）。
      const a2: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, ACCOUNT, 'scope-e2');
      expect(reconciler.clears(a2, lkg.epochTicket())).assertTrue();
      expect(reconciler.reconcile(a2, lkg.epochTicket(), lkg)).assertEqual(HomeClearResult.DONE);
      expect(disk.files.has(oldTag)).assertFalse();
      const scopeTag: string = HomeLkgStore.tagOf(a1.scope);
      expect(Array.from(disk.files.keys()).filter((k: string): boolean => k === scopeTag || k.startsWith(scopeTag + '/'))
        .length).assertEqual(0);
      const rebuilt: HomeLkgStore = new HomeLkgStore(disk);
      rebuilt.bindLoginEpoch((): string | null => E2);
      expect(rebuilt.load(a1.scope)).assertNull();
      // 对照：同账号、同一登录世代（如刷新换了会话归属键）不删本世代的 LKG。
      reconciler.built(a2, lkg.epochTicket());
      expect(lkg.save(a2.scope, '{"new":true}', lkg.clearGeneration, lkg.epochTicket())).assertTrue();
      const a3: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, ACCOUNT, 'scope-e2-refresh');
      expect(reconciler.reconcile(a3, lkg.epochTicket(), lkg)).assertNull();
      expect(lkg.load(a3.scope)).assertEqual('{"new":true}');
      // 对照：建控制器时世代未知（那时不会写会员 LKG），之后世代读出不删。
      const r2: HomeLkgReconciler = new HomeLkgReconciler();
      r2.built(a3, null);
      expect(r2.clears(a3, E2)).assertFalse();
      // 换账号、登出照旧删。
      expect(reconciler.clears(new HomeIdentity('test', HomeLevel.MEMBER, 'user-2', 'x'), E2)).assertTrue();
      expect(reconciler.clears(new HomeIdentity('test', HomeLevel.GUEST, null, 'x'), null)).assertTrue();
    });

    // ---------------------------------------------------------------- 第 2 轮修复（模拟器回收恢复实测发现）：冷启动落定不删恢复记录
    it('fhm0723_r2_cold_start_scope_settlement_keeps_order_restore_record', 0, () => {
      // 键格式同 ClipboardController.scopeKey：作废世代|登录序号|会话世代|凭据可读|隐私|环境端点|账号。
      const key = (gen: string, allowed: string, privacy: string, api: string, account: string): string =>
        gen + '|' + allowed + '|' + privacy + '|' + api + '|' + account;
      // 冷启动落定：凭据可读、隐私规范值、环境端点、账号从无到有在变，前三段不变 → 不算会话变化。
      expect(OrderPageRestorer.wipesOnScopeChange(undefined, key('0|0|0', 'false', '', '', ''))).assertFalse();
      expect(OrderPageRestorer.wipesOnScopeChange(key('0|0|0', 'false', '', '', ''),
        key('0|0|0', 'true', 'full', 'https://api.example.test', ACCOUNT))).assertFalse();
      // 会话变化：登录 / 换号（登录序号、会话世代）、作废世代、已有账号换成别的或没了 → 删。
      const settled: string = key('0|0|0', 'true', 'full', 'https://api.example.test', ACCOUNT);
      expect(OrderPageRestorer.wipesOnScopeChange(settled, key('0|1|1', 'true', 'full', 'https://api.example.test', ACCOUNT)))
        .assertTrue();
      expect(OrderPageRestorer.wipesOnScopeChange(settled, key('1|0|0', 'true', 'full', 'https://api.example.test', ACCOUNT)))
        .assertTrue();
      expect(OrderPageRestorer.wipesOnScopeChange(settled, key('0|0|0', 'true', 'full', 'https://api.example.test', 'user-2')))
        .assertTrue();
      expect(OrderPageRestorer.wipesOnScopeChange(settled, key('0|0|0', 'false', 'full', 'https://api.example.test', '')))
        .assertTrue();
      expect(OrderPageRestorer.wipesOnScopeChange(settled, 'broken')).assertTrue();
    });

    // ---------------------------------------------------------------- 末轮窄修 R3-01：会话计数没动、只换了登录世代
    it('fhm0723_r3_01_order_sync_same_scope_key_epoch_change_deletes_cache_and_restore_record', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const s: Session = new Session();
      const prefs: HookPrefs = new HookPrefs();
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const cacheOf = (): OrderStaleCache => new OrderStaleCache(store, (): string | null => s.account, (): number => NOW,
        (): string | null => s.epoch);
      // 进程 1（A/E1）：缓存、恢复记录各一份。
      const c1: OrderStaleCache = cacheOf();
      c1.saveList('self', JSON.parse(page([order('O1', OLD_QUERY, 'PAID')], null)) as OrderRecord);
      const r1: OrderPageRestorer = restorerOf(prefs, s);
      const l1: OrderListController = f.listController();
      r1.restore(l1, null);
      l1.submitQuery(OLD_QUERY);
      await flush();
      expect(r1.save(l1)).assertEqual(OrderPersistResult.SAVED);
      // 进程 2：冷启动时会话还没读出（世代未知），之后读出 E1——「未知 → 已知」不删。
      s.epoch = null;
      const cache: OrderStaleCache = cacheOf();
      const restorer: OrderPageRestorer = restorerOf(prefs, s);
      const rec: OrderSessionReconciler = new OrderSessionReconciler(f.hub, cache, restorer, (): string => f.scopeKey,
        (): string | null => s.account);
      expect(rec.sync().changed).assertFalse();
      s.epoch = E1;
      const settled: OrderSyncResult = rec.sync();
      expect(settled.wiped).assertFalse();
      expect(store.files.has(listFile(ACCOUNT, E1))).assertTrue();
      expect((prefs.values.get(PAGE_KEY) ?? '').indexOf(OLD_QUERY) >= 0).assertTrue();
      // 令牌换成同账号的新登录世代，三个会话计数没动（归属键不变）：生产 sync 入口照样删旧分区与恢复记录。
      s.epoch = E2;
      const r: OrderSyncResult = rec.sync();
      expect(r.changed && r.wiped).assertTrue();
      expect(r.clearFailed).assertFalse();
      expect(store.files.size).assertEqual(0);
      expect(prefs.values.has(PAGE_KEY)).assertFalse();
      expect(cacheOf().loadList('self') === null).assertTrue();
      const again: OrderListController = f.listController();
      restorerOf(prefs, s).restore(again, null);
      expect(again.conditions().q).assertNull();
      // 之后补发的会话变化通知（归属键变了）：判定已完成，不重复报错；同一世代再同步不再删。
      f.scopeKey = 'scope-later';
      expect(rec.sync().clearFailed).assertFalse();
      expect(rec.sync().changed).assertFalse();
      f.hub.reset();
    });

    it('fhm0723_r3_01_wallet_and_home_sync_same_key_epoch_change_delete_old_partition', 0, () => {
      // 钱包：AppWallet.sync 用的同一判定（CachePartitionTracker.sessionSync），归属键没变（sessionChanged=false）。
      const s: Session = new Session();
      const store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
      const cache: WalletStaleCache = new WalletStaleCache(store, (): string | null => s.account, (): number => NOW,
        (): string | null => s.epoch);
      const tracker: CachePartitionTracker = new CachePartitionTracker();
      // 冷启动第一次同步（世代还读不出）、之后读出 E1：都不删。
      s.epoch = null;
      expect(tracker.sessionSync(false, ACCOUNT, cache.ownerOf(ACCOUNT))).assertFalse();
      s.epoch = E1;
      expect(tracker.sessionSync(false, ACCOUNT, cache.ownerOf(ACCOUNT))).assertFalse();
      cache.save(JSON.parse(summaryJson()) as WalletRecord);
      expect(store.files.size).assertEqual(1);
      s.epoch = E2;
      expect(tracker.sessionSync(false, ACCOUNT, cache.ownerOf(ACCOUNT))).assertTrue();
      expect(cache.clear()).assertTrue();
      expect(store.files.size).assertEqual(0);
      expect(tracker.sessionSync(false, ACCOUNT, cache.ownerOf(ACCOUNT))).assertFalse();
      // 首页：AppHome.syncInner 的「能不能留着旧控制器」（身份键相同、世代换了 → 不能），随后对账删旧作用域。
      const disk: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const lkg: HomeLkgStore = new HomeLkgStore(disk);
      s.epoch = E1;
      lkg.bindLoginEpoch((): string | null => s.epoch);
      const id: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, ACCOUNT, 'same-scope-key');
      const home: HomeLkgReconciler = new HomeLkgReconciler();
      home.built(id, lkg.epochTicket());
      expect(lkg.save(id.scope, '{"old":true}', lkg.clearGeneration, lkg.epochTicket())).assertTrue();
      expect(home.keeps(id.key, id, lkg.epochTicket())).assertTrue();
      s.epoch = E2;
      expect(home.keeps(id.key, id, lkg.epochTicket())).assertFalse();
      expect(home.reconcile(id, lkg.epochTicket(), lkg)).assertEqual(HomeClearResult.DONE);
      expect(disk.files.has(HomeLkgStore.partitionTag(id.scope, E1))).assertFalse();
      // 冷启动建控制器时世代未知、之后读出：留着（不删）。
      const cold: HomeLkgReconciler = new HomeLkgReconciler();
      cold.built(id, null);
      expect(cold.keeps(id.key, id, E2)).assertTrue();
    });

    // ---------------------------------------------------------------- 末轮窄修二 RC-01：首页「未知 → E1 → E2」连续路径
    it('fhm0723_r3b_01_home_unknown_then_e1_then_e2_same_key_deletes_e1_on_second_change', 0, () => {
      const s: Session = new Session();
      const disk: MemoryHomeLkgBackend = new MemoryHomeLkgBackend();
      const id: HomeIdentity = new HomeIdentity('test', HomeLevel.MEMBER, ACCOUNT, 'same-scope-key');
      // 上一个进程（A/E1）留下的会员 LKG。
      s.epoch = E1;
      const prev: HomeLkgStore = new HomeLkgStore(disk);
      prev.bindLoginEpoch((): string | null => s.epoch);
      expect(prev.save(id.scope, '{"e1":true}', prev.clearGeneration, prev.epochTicket())).assertTrue();
      const e1Tag: string = HomeLkgStore.partitionTag(id.scope, E1);
      expect(disk.files.has(e1Tag)).assertTrue();
      // 冷启动：会话还没读出（世代未知）时按同一身份键建控制器（AppHome.build → built）。
      s.epoch = null;
      const lkg: HomeLkgStore = new HomeLkgStore(disk);
      lkg.bindLoginEpoch((): string | null => s.epoch);
      const home: HomeLkgReconciler = new HomeLkgReconciler();
      home.built(id, lkg.epochTicket());
      // AppHome.syncInner 的判定（keepOrObserve → 不留则 reconcile），身份键与会话计数始终不变。
      const syncInner = (): string | null => home.keepOrObserve(id.key, id, lkg.epochTicket()) ? 'kept'
        : home.reconcile(id, lkg.epochTicket(), lkg);
      // 第一次同步：世代读出 E1（未知 → 已知）——留着、不删。
      s.epoch = E1;
      expect(syncInner()).assertEqual('kept');
      expect(disk.files.has(e1Tag)).assertTrue();
      expect(lkg.load(id.scope)).assertEqual('{"e1":true}');
      // 第二次同步：同账号换成 E2（计数没动）——不再留着，删掉 E1 的分区；E2 读 null。
      s.epoch = E2;
      expect(syncInner()).assertEqual(HomeClearResult.DONE);
      expect(disk.files.has(e1Tag)).assertFalse();
      expect(lkg.load(id.scope)).assertNull();
      // 之后建的新控制器（AppHome.build）按 E2 记；同一世代再同步留着。
      home.built(id, lkg.epochTicket());
      expect(syncInner()).assertEqual('kept');
    });

    // ---------------------------------------------------------------- 第 4 项：剪贴板整体 10405
    it('fhm0723_clipboard_whole_non_forced_10405_generic_text_trace6_retry_no_force_update', 0, async () => {
      for (const effect of nonForced()) {
        const c: Clip = new Clip();
        c.port.next = failed10405(effect);
        await c.paste();
        const view: ClipboardResultView | null = c.result();
        expect(view !== null).assertTrue();
        expect((view as ClipboardResultView).kind).assertEqual(ClipboardResultView.NOTICE);
        expect((view as ClipboardResultView).textKey).assertEqual('error.50001');
        expect(ClipboardNoticeText.of((view as ClipboardResultView).textKey, (view as ClipboardResultView).traceId,
          format).indexOf('ab12cd') >= 0).assertTrue();
        expect(c.forced).assertEqual(0);
        expect(c.controller.snapshot.busy).assertFalse();
        // 可重试：再点粘贴照常发出新的 parse。
        c.controller.consumeResult(view as ClipboardResultView);
        await c.paste();
        expect(c.port.parses).assertEqual(2);
      }
    });

    it('fhm0723_clipboard_inline_10405_and_real_forced_10405_keep_original_behavior', 0, async () => {
      // 行内 10405（外层成功）：主动进强更，不出卡。
      const a: Clip = new Clip();
      a.port.next = new ApiResult(ApiOutcome.SUCCESS, 0, '', JSON.parse(
        '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"error_code":10405}]}') as Record<string, Object>,
        'trace-1', 200, TransportFailure.NONE, null, null, null);
      await a.paste();
      expect(a.forced).assertEqual(1);
      expect(a.result() === null).assertTrue();
      // 真强更（网络层 Effect = FORCE_UPDATE）：页面不另写提示（强更由网络层打开），不当成普通错误。
      const b: Clip = new Clip();
      b.port.next = failed10405(new ErrorEffect(EffectKind.FORCE_UPDATE, 'ForceUpdate', 'error.10405', ReplayKind.NONE,
        false));
      await b.paste();
      expect(b.result() === null).assertTrue();
      expect(b.forced).assertEqual(0);
      // 真实 ApiClient（full 会话）：10405 一律 FORCE_UPDATE，页面同样不另写。
      const r: Clip = new Clip();
      await r.paste();
      expect(r.port.parses).assertEqual(1);
      expect(r.result() === null).assertTrue();
      expect(r.forced).assertEqual(0);
    });
  });
}
