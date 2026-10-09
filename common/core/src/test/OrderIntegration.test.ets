// APP-08 鸿蒙订单列表、详情与待跟单卡的本地假服务集成测试（brief §2.12）：真实 ApiClient + 本地假服务（NetworkTestRig.FakeServer，
// 不连任何地址）、真实 Router / StackNavigator（页面上的入口经 Router 打开，断言导航栈与路由参数）、执行层的页面入口（列表 Tab 显示、
// 换条件、下拉、翻页、详情出栈、卡片按钮）。假数据照 design-hifi sample-data §12.2、§12.3（样例商品与样例单号，没有个人信息）；
// 系统剪贴板用可数写入次数的假剪贴板，写入只经统一写入口 ClipboardWriter。测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  ClipboardWriteLedger, ClipboardWriter, CreditPeriodText, GuardState, LaunchReadiness, MemoryClipboardHashStore,
  MemoryOrderCacheStore, MemoryPendingBackend, OrderAmountCells, OrderCopy, OrderDetailActions, OrderDetailController,
  OrderDetailDeps, OrderDraftTexts, OrderErrorAction, OrderJson, OrderListController, OrderListDeps, OrderListSnapshot,
  OrderPhase, OrderRecord, OrderStaleCache, OrderStatusText, OrderTimelineView, PasteboardPort, PathStack,
  PendingActionStore, PendingTrackCard, PendingTrackController, PendingTrackDeps, PendingTrackJumpWatcher,
  PriceCompareEntry, PrivacyState, RouteDestination, RouteRequest, RouteSource, Router, RouteTable, StackNavigator,
  TransportFailure, TransportRequest, TransportResponse, UpdateCheckStatus, UpdateState, ViewProductEntry,
  WhyNoRebate, ApiClientSearchPort, LocalDataCleanerRegistry, OrderCacheCleaner, PrivacyWithdrawalCleaners,
  CleanReport, OrderQuery, OrderNumberDisplay, OrderCacheEntry, OrderSessionHub, OrderScrollAnchor, OrderListConditions,
  PermissionRequester, PermissionTypeRaw, PermissionResult, OrderDetailSnapshot, PendingTrackSnapshot
} from '../../Index';
import { Routes, RouteSpec } from 'generated';
import { Deferred, envelope, flush, Rig } from './NetworkTestRig';

export const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];
export const NOW: number = Date.parse('2026-10-12T10:30:00+08:00');

/** 记录路由参数的内存导航栈（Router 推入的 RouteDestination 原样留下）。 */
export class ParamStack implements PathStack {
  names: string[] = [];
  params: Object[] = [];

  pushPathByName(name: string, param: Object): void {
    this.names.push(name);
    this.params.push(param);
  }

  clear(): void {
    this.names = [];
    this.params = [];
  }

  removeByName(name: string): void {
    const keep: number[] = [];
    this.names.forEach((n: string, i: number) => {
      if (n !== name) {
        keep.push(i);
      }
    });
    this.params = keep.map((i: number) => this.params[i]);
    this.names = keep.map((i: number) => this.names[i]);
  }

  getAllPathName(): string[] {
    return this.names.slice();
  }

  topParams(): Record<string, Object> {
    const p: Object = this.params[this.params.length - 1];
    return p instanceof RouteDestination ? (p as RouteDestination).params : {};
  }
}

class FakePasteboard implements PasteboardPort {
  text: string | null = null;
  writes: number = 0;

  readText(): Promise<string | null> {
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.writes++;
    this.text = text;
    return Promise.resolve(true);
  }
}

/** 记录失败的 hash 存储（共性第 23 条：记不下就不写剪贴板）。 */
class FailingHashStore extends MemoryClipboardHashStore {
  write(_key: string, _value: string | null): boolean {
    return false;
  }
}

export function order(id: string, no: string, status: string, extra: string = ''): string {
  return '{"order_id":"' + id + '","platform":"taobao","title":"样例商品 A：纯牛奶 250ml×12 盒","image_url":null,'
    + '"pay_amount_fen":4560,"quantity":2,"order_no":"' + no + '","display_status":"' + status + '","reason":null,'
    + '"est_rebate_fen":234,"paid_at":"2026-10-12T09:05:00+08:00","is_other_product":false' + extra + '}';
}

export function shareOrder(id: string, masked: string): string {
  return '{"order_id":"' + id + '","platform":"taobao","title":"样例商品 E：保温杯 500ml","image_url":null,'
    + '"pay_amount_fen":5900,"quantity":1,"masked_order_no":"' + masked + '","display_status":"PAID","reason":null,'
    + '"est_rebate_fen":180,"paid_at":"2026-10-12T10:21:00+08:00","is_other_product":false}';
}

export function page(items: string[], cursor: string | null, earliest: string | null = null): string {
  return '{"items":[' + items.join(',') + '],"next_cursor":' + (cursor === null ? 'null' : '"' + cursor + '"')
    + ',"earliest_visible_date":' + (earliest === null ? 'null' : '"' + earliest + '"') + '}';
}

export function detail(id: string, fields: string): string {
  return '{"order_id":"' + id + '","platform":"taobao","title":"样例商品 C：洗衣液 3kg","image_url":null,'
    + '"pay_amount_fen":3990,"quantity":1,"display_status":"WAITING","reason":null,"est_rebate_fen":450,'
    + '"paid_at":"2026-09-20T14:03:00+08:00","is_other_product":false,"product_key":"tb:9007","reason_action":[],'
    + '"timeline":[],"expected_credit_period":"2026-10","credit_overdue":false,"actual_fen":null,"clawback_fen":null,'
    + '"appeal_pending":false,"is_price_compare":false,' + fields + '}';
}

export function pending(link: string, attempt: string, platform: string, claim: boolean, dismissed: boolean): string {
  return '{"link_id":"' + link + '","attempt_id":"' + attempt + '","platform":"' + platform
    + '","jumped_at":"2026-10-12T09:00:00+08:00","show_claim_entry":' + claim + ',"dismissed":' + dismissed + '}';
}

export function queryOf(request: TransportRequest): string {
  const i: number = request.url.indexOf('?');
  return i < 0 ? '' : request.url.substring(i + 1);
}

export function rec(json: string): OrderRecord {
  return JSON.parse(json) as OrderRecord;
}

/** 订单执行层 + 真实 Router 的装配（与 entry AppOrders 同一接线：页面入口经 Router 打开路由）。 */
export class OrderFixture {
  readonly rig: Rig = new Rig();
  readonly stack: ParamStack = new ParamStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly store: MemoryOrderCacheStore = new MemoryOrderCacheStore();
  readonly cache: OrderStaleCache;
  account: string | null = 'user-1';
  scopeKey: string = 'scope-1';
  nowMs: number = NOW;
  /** 列表的回答（按请求 query）；返回 null 时挂起到 held。 */
  list: (query: string) => TransportResponse | null = (_q: string) => envelope(0, page([], null));
  detailReply: (id: string) => TransportResponse | null = (_id: string) => envelope(0, detail('O1', '"order_no":"1"'));
  pendingReply: () => TransportResponse | null = () => envelope(0, '{"items":[]}');
  dismissReply: () => TransportResponse | null = () => envelope(0, '{}');
  held: Deferred[] = [];
  snapshots: OrderListSnapshot[] = [];
  forced: number = 0;
  pushRequests: number = 0;
  marked: number = 0;
  requestedBefore: boolean = false;
  notification: string = 'not_determined';
  member: boolean = true;
  realname: boolean = false;
  /** 与 entry AppOrders 同一接线：按会话共享的 42901 闸门、会话变化时清空并移出旧详情页（R1-01、R1-02）。 */
  readonly hub: OrderSessionHub;
  /** 待跟单卡的 requestPush（null = 计数用的假申请；R1-04 用真实 PermissionRequester 经 PendingTrackDeps.pushVia）。 */
  pushVia: ((valid: () => boolean) => Promise<boolean>) | null = null;

  constructor() {
    this.cache = new OrderStaleCache(this.store, (): string | null => this.account, (): number => this.nowMs);
    this.hub = new OrderSessionHub((): number => this.nowMs, (): string => this.scopeKey);
    this.hub.removePages = (route: string): void => this.navigator.remove(route);
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
      let reply: TransportResponse | null = null;
      if (r.url.indexOf('/v1/orders/pending-tracks/') >= 0) {
        reply = this.dismissReply();
      } else if (r.url.indexOf('/v1/orders/pending-tracks') >= 0) {
        reply = this.pendingReply();
      } else if (r.url.indexOf('/v1/orders/') >= 0) {
        const tail: string = r.url.substring(r.url.indexOf('/v1/orders/') + 11);
        reply = this.detailReply(tail.split('?')[0]);
      } else if (r.url.indexOf('/v1/orders') >= 0) {
        reply = this.list(queryOf(r));
      } else {
        reply = envelope(0, '{}');
      }
      if (reply !== null) {
        return Promise.resolve(reply);
      }
      const d: Deferred = new Deferred();
      this.held.push(d);
      return d.promise;
    };
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null
      && TAB_ROOTS.indexOf(d.route) >= 0;
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => this.nowMs),
      (): GuardState => new GuardState('consented', 'ok', 'phone_bound', true, '1.0.0', false, false, this.realname),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
  }

  listController(): OrderListController {
    const deps: OrderListDeps = new OrderListDeps(new ApiClientSearchPort(this.rig.client));
    deps.cache = this.cache;
    deps.clock = (): number => this.nowMs;
    deps.scope = (): string => this.scopeKey;
    this.hub.attachList(deps);
    const c: OrderListController = new OrderListController(deps);
    c.onChange = (s: OrderListSnapshot): void => {
      this.snapshots.push(s);
    };
    this.hub.setList(c);
    return c;
  }

  detailController(): OrderDetailController {
    const deps: OrderDetailDeps = new OrderDetailDeps(new ApiClientSearchPort(this.rig.client));
    deps.cache = this.cache;
    deps.clock = (): number => this.nowMs;
    deps.scope = (): string => this.scopeKey;
    this.hub.attachDetail(deps);
    const d: OrderDetailController = new OrderDetailController(deps);
    this.hub.addDetail(d);
    return d;
  }

  pendingController(): PendingTrackController {
    const deps: PendingTrackDeps = new PendingTrackDeps(new ApiClientSearchPort(this.rig.client));
    deps.scope = (): string => this.scopeKey;
    deps.session = (): string => this.member ? 'member' : 'guest';
    deps.notification = (): string => this.notification;
    deps.requestedBefore = (): boolean => this.requestedBefore;
    deps.markRequested = (): void => {
      this.marked++;
      this.requestedBefore = true;
    };
    deps.requestPush = this.pushVia ?? ((valid: () => boolean): Promise<boolean> => {
      if (valid()) {
        this.pushRequests++;
      }
      return Promise.resolve(true);
    });
    deps.forceUpdate = (): void => {
      this.forced++;
    };
    deps.open = (route: string, params: Record<string, Object>): void => {
      this.open(route, params);
    };
    this.hub.attachPending(deps);
    const p: PendingTrackController = new PendingTrackController(deps);
    this.hub.addPending(p);
    return p;
  }

  /** 页面上的入口：经 Router 打开（与 entry AppRouting.openInApp 同）。 */
  open(route: string, params: Record<string, Object>): void {
    this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
  }

  listRequests(): TransportRequest[] {
    return this.rig.server.received.filter((r: TransportRequest) => r.url.indexOf('/v1/orders?') >= 0);
  }

  lastListQuery(): string {
    const all: TransportRequest[] = this.listRequests();
    return all.length === 0 ? '' : queryOf(all[all.length - 1]);
  }

  top(): string {
    const names: string[] = this.stack.getAllPathName();
    return names.length === 0 ? '' : names[names.length - 1];
  }
}

function texts(item: OrderRecord): string[] {
  const out: string[] = [];
  const status: Record<string, Object | null> = OrderStatusText.of(OrderJson.text(item, 'display_status') ?? '');
  out.push(OrderDraftTexts.text(status['labelKey'] as string));
  return out;
}

export default function orderIntegrationTest() {
  describe('OrderIntegration', () => {
    // ---------------------------------------------------------------- AC-S1-103 分组、筛选、搜索
    it('AC_S1_103_group_platform_month_search_only_send_params', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(f.lastListQuery()).assertEqual('scope=self');
      expect(c.setGroup('credited')).assertTrue();
      await flush();
      expect(f.lastListQuery()).assertEqual('scope=self&status_group=credited');
      c.setGroup('all');
      await flush();
      expect(f.lastListQuery()).assertEqual('scope=self');
      c.setPlatform('taobao');
      c.setMonth('2026-10');
      await flush();
      expect(f.lastListQuery()).assertEqual('scope=self&platform=taobao&paid_month=2026-10');
      // 自购搜完整单号、前 10 位、标题词各发 1 次 q；结果只按假服务返回显示（客户端不过滤）
      const before: number = f.listRequests().length;
      f.list = (q: string): TransportResponse => envelope(0, q.indexOf('q=') >= 0
        ? page([order('O1', '3741234567890123456', 'PAID')], null) : page([], null));
      c.submitQuery('3741234567890123456');
      await flush();
      expect(f.lastListQuery().indexOf('q=3741234567890123456') >= 0).assertTrue();
      c.submitQuery(' 3741234567 ');
      await flush();
      expect(f.lastListQuery().indexOf('q=3741234567&') >= 0 || f.lastListQuery().endsWith('q=3741234567'))
        .assertTrue();
      c.submitQuery('纯牛奶');
      await flush();
      expect(f.lastListQuery().indexOf('q=' + encodeURIComponent('纯牛奶')) >= 0).assertTrue();
      expect(f.listRequests().length - before).assertEqual(3);
      expect(c.snapshot.items.length).assertEqual(1);
      expect(c.snapshot.phase).assertEqual(OrderPhase.CONTENT);
      // 切子 Tab：分组回「全部」，平台、月份、搜索词清空
      c.setGroup('estimating');
      await flush();
      c.setScope('share');
      await flush();
      expect(f.lastListQuery()).assertEqual('scope=share');
      expect(c.snapshot.group).assertEqual('all');
      expect(c.snapshot.platform).assertNull();
      expect(c.snapshot.month).assertNull();
      expect(c.snapshot.q).assertNull();
      expect(f.listRequests().every((r: TransportRequest) => queryOf(r).indexOf('display_status') < 0)).assertTrue();
    });

    it('AC_S1_106_share_search_placeholder_and_server_only_match', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const c: OrderListController = f.listController();
      c.restore(null, 'share');
      c.ensureLoaded();
      await flush();
      expect(f.lastListQuery()).assertEqual('scope=share');
      // 分享子 Tab 的搜索框提示为「搜商品名」
      expect(OrderDraftTexts.text('order_list.search.placeholder_share')).assertEqual('搜商品名');
      expect(OrderDraftTexts.text('order_list.search.placeholder')).assertEqual('搜订单号或商品名');
      // 搜分享单的完整单号：q 原样发出，结果只看服务端（空）
      c.submitQuery('3712345678901234567');
      await flush();
      expect(f.lastListQuery()).assertEqual('scope=share&q=3712345678901234567');
      expect(c.snapshot.phase).assertEqual(OrderPhase.EMPTY);
      expect(OrderDraftTexts.text('order_list.search.share_note')).assertEqual('分享订单只按商品名搜索');
    });

    it('AC_S1_103_share_number_not_copyable_self_copy_via_writer', 0, async () => {
      const board: FakePasteboard = new FakePasteboard();
      const store: MemoryClipboardHashStore = new MemoryClipboardHashStore();
      const ledger: ClipboardWriteLedger = new ClipboardWriteLedger(ClipboardWriteLedger.DEFAULT_CAPACITY,
        (t: string): string => 'h:' + t, store);
      const writer: ClipboardWriter = new ClipboardWriter(board, ledger);
      const share: OrderRecord = rec(shareOrder('S1', '3712****67'));
      const own: OrderRecord = rec(order('O1', '3741234567890123456', 'PAID'));
      expect(OrderNumberDisplay.of(share)['copyable']).assertFalse();
      expect(await OrderCopy.copy(share, (t: string) => writer.write(t))).assertEqual(OrderCopy.NOT_COPYABLE);
      expect(board.writes).assertEqual(0);
      expect(await OrderCopy.copy(own, (t: string) => writer.write(t))).assertEqual(OrderCopy.DONE);
      expect(board.writes).assertEqual(1);
      expect(board.text).assertEqual('3741234567890123456');
      expect(ledger.contains('3741234567890123456')).assertTrue();
      expect(OrderDraftTexts.text(OrderCopy.DONE_KEY)).assertEqual('已复制订单号');
      // 记 hash 失败：不写剪贴板，提示失败
      const failing: ClipboardWriter = new ClipboardWriter(board, new ClipboardWriteLedger(
        ClipboardWriteLedger.DEFAULT_CAPACITY, (t: string): string => 'h:' + t, new FailingHashStore()));
      expect(await OrderCopy.copy(own, (t: string) => failing.write(t))).assertEqual(OrderCopy.FAILED);
      expect(board.writes).assertEqual(1);
      // 脱敏号读屏读出星号（原样，不补不拼）
      expect(OrderNumberDisplay.spoken('3712****67', OrderDraftTexts.text('order_list.star')))
        .assertEqual('3712星号星号星号星号67');
    });

    // ---------------------------------------------------------------- AC-S1-104 查看商品
    it('AC_S1_104_view_product_opens_product_detail_with_two_params', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const o7: OrderRecord = rec(detail('O7', '"order_no":"3741234567890123456"'));
      const entry: Record<string, Object | null> = ViewProductEntry.of(o7);
      expect(entry['show']).assertTrue();
      f.open(entry['route'] as string, entry['params'] as Record<string, Object>);
      expect(f.top()).assertEqual('ProductDetail');
      expect(JSON.stringify(Object.keys(f.stack.topParams()).sort())).assertEqual('["platform","product_key"]');
      expect(f.stack.topParams()['product_key']).assertEqual('tb:9007');
      const o8: OrderRecord = rec(detail('O8', '"order_no":"1"').replace('"product_key":"tb:9007"', '"product_key":null'));
      expect(ViewProductEntry.of(o8)['show']).assertFalse();
      const o10: OrderRecord = rec(detail('O10', '"masked_order_no":"3756****21"')
        .replace('"product_key":"tb:9007"', '"product_key":null').replace('"is_other_product":false',
        '"is_other_product":true'));
      expect(ViewProductEntry.of(o10)['show']).assertFalse();
      // 「查看商品」不占按钮名额：按钮数只按状态与 reason_action
      const credited: OrderRecord = rec(detail('O9', '"order_no":"1"').replace('"WAITING"', '"CREDITED"'));
      const withKey: number = (OrderDetailActions.of(credited)['buttons'] as Object[]).length;
      const noKey: number = (OrderDetailActions.of(rec(JSON.stringify(credited).replace('"tb:9007"', 'null')))['buttons'] as
        Object[]).length;
      expect(withKey).assertEqual(1);
      expect(noKey).assertEqual(1);
    });

    // ---------------------------------------------------------------- AC-S1-27 / BR-TEXT-02 状态文案与按钮
    it('AC_S1_27_status_texts_buttons_and_forbidden_words', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const expected: string[][] = [['DEPOSIT_PAID', '已付定金'], ['PAID', '已付款，返利待确认'],
        ['WAITING', '已收货，等待联盟结算'], ['CREDITING', '入账核对中'], ['RIGHTS_PENDING', '售后处理中，入账暂停'],
        ['REVIEWING', '入账核对中'], ['NO_REBATE', '本单无返利'], ['CREDITED', '已结算'], ['INVALID', '已失效'],
        ['CLAWED_BACK', '已扣回'], ['FUTURE_X', '状态更新中']];
      for (const e of expected) {
        expect(texts(rec(order('X', '1', e[0])))[0]).assertEqual(e[1]);
      }
      expect(OrderDraftTexts.text('order_status.UNKNOWN.hint')).assertEqual('请稍后查看');
      // 原因与按钮：BLACKLIST【去申诉】；PUNISH / COMMISSION_ZERO【联系客服】；CLAWED_BACK + PUNISH【联系客服】（主）+【查看流水】
      const blacklist: OrderRecord = rec(detail('B', '"order_no":"1"').replace('"WAITING"', '"INVALID"')
        .replace('"reason":null', '"reason":"BLACKLIST"').replace('"reason_action":[]', '"reason_action":["APPEAL"]'));
      const b: Object[] = OrderDetailActions.of(blacklist)['buttons'] as Object[];
      expect(OrderDraftTexts.text(OrderDetailActions.labelKey((b[0] as Record<string, Object>)['actionRaw'] as string)))
        .assertEqual('去申诉');
      const why: Record<string, Object | null> = WhyNoRebate.of(blacklist);
      expect(OrderDraftTexts.text(why['titleKey'] as string)).assertEqual('订单未通过安全校验');
      expect(OrderDraftTexts.text(why['headerKey'] as string)).assertEqual('为什么没返利？');
      const clawed: OrderRecord = rec(detail('P', '"order_no":"1"').replace('"WAITING"', '"CLAWED_BACK"')
        .replace('"reason":null', '"reason":"PUNISH"').replace('"reason_action":[]', '"reason_action":["CONTACT_CS"]'));
      const cb: Object[] = OrderDetailActions.of(clawed)['buttons'] as Object[];
      expect(cb.length).assertEqual(2);
      expect((cb[0] as Record<string, Object>)['primary']).assertTrue();
      expect(OrderDraftTexts.text(OrderDetailActions.labelKey((cb[0] as Record<string, Object>)['actionRaw'] as string)))
        .assertEqual('联系客服');
      expect(OrderDraftTexts.text(OrderDetailActions.labelKey((cb[1] as Record<string, Object>)['actionRaw'] as string)))
        .assertEqual('查看流水');
      // 【联系客服】经 Router 打开 Help（G09）
      f.open((cb[0] as Record<string, Object>)['route'] as string, {});
      expect(f.top()).assertEqual('Help');
      const extra: Record<string, Object | null> = WhyNoRebate.of(clawed);
      expect(OrderDraftTexts.text(extra['extraKey'] as string)).assertEqual('已从余额扣除');
      for (const reason of ['REFUND', 'RIGHTS', 'COMMISSION_ZERO']) {
        const r: OrderRecord = rec(detail('R', '"order_no":"1"').replace('"WAITING"', '"INVALID"')
          .replace('"reason":null', '"reason":"' + reason + '"'));
        const w: Record<string, Object | null> = WhyNoRebate.of(r);
        expect(OrderDraftTexts.text(w['titleKey'] as string).length > 0).assertTrue();
        expect(OrderDraftTexts.text(w['descKey'] as string).length > 0).assertTrue();
      }
      // 用户可见文案不出现「佣金」「待结算」「结算中」
      for (const t of OrderDraftTexts.allTexts()) {
        expect(t.indexOf('佣金') < 0 && t.indexOf('待结算') < 0 && t.indexOf('结算中') < 0).assertTrue();
      }
    });

    // ---------------------------------------------------------------- AC-S1-73 历史提示、30701
    it('AC_S1_73_history_hint_and_detail_30701_empty', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID')], null, '2026-01-01'));
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(c.snapshot.earliestVisibleDate).assertEqual('2026-01-01');
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('date', '01-01');
      expect(OrderDraftTexts.format('order_list.history_hint', vars)).assertEqual('只显示 01-01 之后的订单，更早的订单请联系客服');
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID')], null, null));
      c.refresh();
      await flush();
      expect(c.snapshot.earliestVisibleDate).assertNull();
      f.detailReply = (_id: string): TransportResponse => envelope(30701, '{}');
      const d: OrderDetailController = f.detailController();
      d.load('O-out');
      await flush();
      expect(d.snapshot.phase).assertEqual(OrderPhase.EMPTY);
      expect(d.snapshot.error?.textKey).assertEqual('error.30701');
      expect(d.retry()).assertFalse();
      expect(f.rig.server.count('/v1/orders/O-out')).assertEqual(1);
    });

    // ---------------------------------------------------------------- BR-TEXT-04 与预售
    it('BR_TEXT_04_credit_month_and_presale', 0, () => {
      const vars: Map<string, string> = new Map<string, string>();
      const same: Record<string, Object | null> = CreditPeriodText.of('WAITING', '2026-11', NOW);
      vars.set('credit_period', same['monthText'] as string);
      expect(OrderDraftTexts.format(same['textKey'] as string, vars)).assertEqual('预计 11 月结算');
      const cross: Record<string, Object | null> = CreditPeriodText.of('WAITING', '2027-01', NOW);
      vars.set('credit_period', cross['monthText'] as string);
      expect(OrderDraftTexts.format(cross['textKey'] as string, vars)).assertEqual('预计 2027 年 1 月结算');
      for (const s of ['CREDITING', 'REVIEWING', 'RIGHTS_PENDING']) {
        expect(CreditPeriodText.of(s, '2026-11', NOW)['monthText']).assertNull();
      }
      expect(CreditPeriodText.of('WAITING', null, NOW)['textKey']).assertNull();
      // 预售：已付定金 ¥30（3000 分）；pay_amount_fen 为 null 时不显示金额；不显示返利金额
      const presale: OrderRecord = rec(order('B', '3798765432109876543', 'DEPOSIT_PAID').replace('"pay_amount_fen":4560',
        '"pay_amount_fen":3000'));
      const cells: Record<string, Object | null> = OrderAmountCells.of(presale, false);
      const left: Record<string, Object | null> = cells['left'] as Record<string, Object | null>;
      expect(left['fen']).assertEqual(3000);
      expect(cells['right']).assertNull();
      expect(OrderDraftTexts.text(left['labelKey'] as string).indexOf('已付定金') === 0).assertTrue();
      const nullPay: Record<string, Object | null> = OrderAmountCells.of(rec(JSON.stringify(presale)
        .replace('"pay_amount_fen":3000', '"pay_amount_fen":null')), false);
      expect((nullPay['left'] as Record<string, Object | null>)['fen']).assertNull();
      const rows: Record<string, Object | null>[] = OrderTimelineView.of('DEPOSIT_PAID', [
        rec('{"node":"deposit_paid","at":null,"period":null}'),
        rec('{"node":"final_paid","at":null,"period":null}'),
        rec('{"node":"received","at":null,"period":null}')], NOW);
      expect(rows[0]['labelKey']).assertEqual('order_timeline.deposit_paid');
      expect(OrderDraftTexts.format(rows[0]['labelKey'] as string, new Map<string, string>())).assertEqual('付定金');
      expect(OrderDraftTexts.format(rows[1]['labelKey'] as string, new Map<string, string>())).assertEqual('付尾款');
    });

    // ---------------------------------------------------------------- AC-S1-25 / AC-S1-84 待跟单卡
    it('AC_S1_25_pending_cards_dismiss_with_attempt_id', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ','
        + pending('L2', 'a2', 'jd', false, true) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      const card: PendingTrackCard = p.snapshot.cards[0];
      expect(card.claimEntry).assertTrue();
      // 找回入口经 Router 打开 FindOrder（H5）
      expect(p.claim(card)).assertTrue();
      expect(f.stack.getAllPathName().indexOf('FindOrder') >= 0 || f.stack.getAllPathName().indexOf('WebPage') >= 0)
        .assertTrue();
      // 关闭：在途时不重复发；请求路径与 body 的 attempt_id 是渲染时那张卡的
      f.dismissReply = (): TransportResponse | null => null;
      expect(p.dismiss(card)).assertTrue();
      expect(p.dismiss(card)).assertFalse();
      expect(p.snapshot.cards[0].busy).assertTrue();
      await flush();
      const req: TransportRequest = f.rig.server.last('/dismiss');
      expect(req.method).assertEqual('POST');
      expect(req.url.indexOf('/v1/orders/pending-tracks/L3/dismiss') >= 0).assertTrue();
      expect(req.body).assertEqual('{"attempt_id":"a3"}');
      expect(f.rig.server.count('/dismiss')).assertEqual(1);
      f.held[0].resolve(envelope(0, '{}'));
      await flush();
      expect(p.snapshot.cards.length).assertEqual(0);
    });

    it('AC_S1_25_claim_entry_false_and_20001_refetch_10405_force', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L2', 'a2', 'jd', false, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards[0].claimEntry).assertFalse();
      expect(p.claim(p.snapshot.cards[0])).assertFalse();
      const fetches: number = f.rig.server.count('/v1/orders/pending-tracks');
      f.dismissReply = (): TransportResponse => envelope(20001, '{"fields":["attempt_id"]}');
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      // 20001：重新拉一次 pending-tracks，按服务端结果显示
      expect(f.rig.server.count('/v1/orders/pending-tracks') - fetches).assertEqual(2);
      expect(p.snapshot.cards.length).assertEqual(1);
      f.dismissReply = (): TransportResponse => envelope(10405, '{}');
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      expect(f.forced).assertEqual(1);
      expect(f.rig.update.calls.length).assertEqual(1);
      expect(p.snapshot.cards.length).assertEqual(1);
      // 传输失败：卡片保留并轻提示网络错误
      f.dismissReply = (): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT);
      const seq: number = p.snapshot.toastSeq;
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      expect(p.snapshot.toastSeq).assertEqual(seq + 1);
      expect(p.snapshot.toastKey).assertEqual('order.network_error');
      // 42901：按 Retry-After 禁用关闭按钮
      f.dismissReply = (): TransportResponse => envelope(42901, '{}', { 'Retry-After': '7' });
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      expect(p.snapshot.closeDisabled).assertTrue();
      expect(p.dismiss(p.snapshot.cards[0])).assertFalse();
      p.leave();
      f.hub.reset();
    });

    it('AC_S1_84_notification_row_only_after_tap', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards[0].notificationRow).assertTrue();
      // 不点不弹系统框
      expect(f.pushRequests).assertEqual(0);
      expect(p.enableNotification(p.snapshot.cards[0])).assertTrue();
      await flush();
      expect(f.pushRequests).assertEqual(1);
      expect(f.marked).assertEqual(1);
      expect(p.snapshot.cards[0].notificationRow).assertFalse();
      // 点过之后再拉也不再出现
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards[0].notificationRow).assertFalse();
      // 已授权：不出
      const g: OrderFixture = new OrderFixture();
      g.notification = 'granted';
      g.pendingReply = f.pendingReply;
      const q: PendingTrackController = g.pendingController();
      q.fetch(null);
      await flush();
      expect(q.snapshot.cards[0].notificationRow).assertFalse();
    });

    it('G07_jump_return_fetches_once_same_platform', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', false, false) + ','
        + pending('L2', 'a2', 'jd', false, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      const w: PendingTrackJumpWatcher = new PendingTrackJumpWatcher();
      w.onReturn = (platform: string): void => p.fetch(platform);
      w.buyStarted('jd');
      w.jumpedOut('jd');
      await flush();
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(0);
      w.onBackground();
      w.onForeground();
      await flush();
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(1);
      expect(p.snapshot.cards.length).assertEqual(1);
      expect(p.snapshot.cards[0].platform).assertEqual('jd');
      w.onBackground();
      w.onForeground();
      await flush();
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(1);
      // 外跳完成回调晚于回前台：完成时已回到前台就立即拉
      w.buyStarted('taobao');
      w.onBackground();
      w.onForeground();
      w.jumpedOut('taobao');
      await flush();
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(2);
    });

    // ---------------------------------------------------------------- TECH-20 缓存
    it('TECH_20_stale_cache_then_refresh_and_account_isolation', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID')], 'c1'));
      const first: OrderListController = f.listController();
      first.ensureLoaded();
      await flush();
      expect(first.snapshot.stale).assertFalse();
      // 断网冷启动：新的页面执行器，第一页传输失败 → 显示缓存与「网络不可用，以下为 … 的数据」
      f.list = (_q: string): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT);
      f.nowMs = NOW + 3600000;
      const cold: OrderListController = f.listController();
      cold.ensureLoaded();
      await flush();
      expect(cold.snapshot.stale).assertTrue();
      expect(cold.snapshot.staleFetchedAt).assertEqual(NOW);
      expect(cold.snapshot.items.length).assertEqual(1);
      expect(cold.snapshot.hasMore).assertFalse();
      expect(cold.loadMore()).assertFalse();
      expect(cold.snapshot.loadMoreError?.actionRaw).assertEqual(OrderErrorAction.PAGE_ERROR);
      // 带筛选的查询失败不用缓存
      cold.setGroup('credited');
      await flush();
      expect(cold.snapshot.stale).assertFalse();
      expect(cold.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(cold.snapshot.error?.actionRaw).assertEqual(OrderErrorAction.NETWORK_ERROR);
      cold.setGroup('all');
      await flush();
      expect(cold.snapshot.stale).assertTrue();
      // 下拉成功：提示条消失、缓存更新
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O2', '2', 'PAID')], null));
      cold.refresh();
      await flush();
      expect(cold.snapshot.stale).assertFalse();
      const entry: OrderCacheEntry | null = f.cache.loadList('self');
      expect(entry !== null && entry.fetchedAt === NOW + 3600000).assertTrue();
      // 换账号：缓存删除；新账号断网看到网络错误态而不是旧账号数据
      expect(f.cache.clear()).assertTrue();
      f.account = 'user-2';
      f.scopeKey = 'scope-2';
      cold.resetForSession();
      f.list = (_q: string): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT);
      cold.ensureLoaded();
      await flush();
      expect(cold.snapshot.stale).assertFalse();
      expect(cold.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(cold.snapshot.items.length).assertEqual(0);
    });

    it('TECH_20_server_error_no_cache_trace6_and_account_tagged', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID')], null));
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      f.list = (_q: string): TransportResponse => envelope(50001, '{}');
      c.refresh();
      await flush();
      expect(c.snapshot.stale).assertFalse();
      expect(c.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(c.snapshot.error?.textKey).assertEqual('error.50001');
      expect(c.snapshot.error?.trace6).assertEqual('123456');
      // 另一账号读不到这个账号的缓存
      f.account = 'user-2';
      expect(f.cache.loadList('self')).assertNull();
      f.account = 'user-1';
      expect(f.cache.loadList('self') !== null).assertTrue();
    });

    it('TECH_20_withdrawal_and_env_switch_clear_with_pending_mark', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.cache.saveList('self', rec(page([order('O1', '1', 'PAID')], null)));
      f.cache.saveDetail('O1', rec(detail('O1', '"order_no":"1"')));
      const registry: LocalDataCleanerRegistry = new LocalDataCleanerRegistry();
      let pagesReset: number = 0;
      OrderCacheCleaner.install(registry, f.cache, (): void => {
        pagesReset++;
      });
      PrivacyWithdrawalCleaners.registerPlaceholders(registry);
      // 删除失败：撤回清理不算完成，「待清理」期间不读回旧数据
      f.store.failClear = true;
      const failed: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(failed.ok).assertFalse();
      expect(f.cache.loadList('self')).assertNull();
      expect(f.store.pending).assertTrue();
      f.store.failClear = false;
      const ok: CleanReport = await PrivacyWithdrawalCleaners.run(registry);
      expect(ok.ok).assertTrue();
      expect(f.store.files.size).assertEqual(0);
      expect(f.store.pending).assertFalse();
      expect(pagesReset).assertEqual(2);
      // 切换环境（cleanAll）同样清
      f.cache.saveList('self', rec(page([], null)));
      await registry.cleanAll();
      expect(f.store.files.size).assertEqual(0);
    });

    it('TECH_20_detail_cache_keeps_30_recent', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      for (let i: number = 0; i < 35; i++) {
        f.nowMs = NOW + i;
        f.cache.saveDetail('O' + i, rec(detail('O' + i, '"order_no":"1"')));
      }
      expect(f.cache.detailCount()).assertEqual(30);
      expect(f.cache.loadDetail('O0')).assertNull();
      expect(f.cache.loadDetail('O34') !== null).assertTrue();
      f.detailReply = (_id: string): TransportResponse => TransportResponse.failed(TransportFailure.TIMEOUT);
      const d: OrderDetailController = f.detailController();
      d.load('O34');
      await flush();
      expect(d.snapshot.stale).assertTrue();
      expect(d.snapshot.phase).assertEqual(OrderPhase.CONTENT);
      const miss: OrderDetailController = f.detailController();
      miss.load('O0');
      await flush();
      expect(miss.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(miss.snapshot.error?.actionRaw).assertEqual(OrderErrorAction.NETWORK_ERROR);
    });

    // ---------------------------------------------------------------- 迟到与作废
    it('late_list_responses_dropped_on_scope_filter_and_account_change', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse | null => null;
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      c.setScope('share');
      await flush();
      expect(f.held.length).assertEqual(2);
      expect(f.rig.server.cancelled.length >= 1).assertTrue();
      f.held[0].resolve(envelope(0, page([order('OLD', '1', 'PAID')], null)));
      await flush();
      expect(c.snapshot.phase).assertEqual(OrderPhase.LOADING);
      f.held[1].resolve(envelope(0, page([shareOrder('S1', '3712****67')], null)));
      await flush();
      expect(c.snapshot.items.length).assertEqual(1);
      expect(OrderJson.text(c.snapshot.items[0], 'order_id')).assertEqual('S1');
      // 翻页在途时改筛选：旧翻页响应不追加
      f.list = (_q: string): TransportResponse => envelope(0, page([shareOrder('S1', '3712****67')], 'c1'));
      c.refresh();
      await flush();
      f.list = (_q: string): TransportResponse | null => null;
      expect(c.loadMore()).assertTrue();
      c.setPlatform('jd');
      await flush();
      const held: number = f.held.length;
      f.held[held - 2].resolve(envelope(0, page([shareOrder('S9', '9999****99')], null)));
      await flush();
      expect(c.snapshot.items.length).assertEqual(0);
      // 换账号：在途请求作废，旧账号的结果不显示给新账号
      f.scopeKey = 'scope-2';
      c.resetForSession();
      f.held[held - 1].resolve(envelope(0, page([shareOrder('S8', '8888****88')], null)));
      await flush();
      expect(c.snapshot.items.length).assertEqual(0);
      expect(c.snapshot.phase).assertEqual(OrderPhase.IDLE);
    });

    it('detail_leave_drops_late_response_and_replace_row', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID'), order('O2', '2', 'PAID')],
        null));
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      f.detailReply = (_id: string): TransportResponse | null => null;
      const d: OrderDetailController = f.detailController();
      let loaded: number = 0;
      d.onLoaded = (x: OrderRecord): void => {
        loaded++;
        c.replaceRow(x);
      };
      d.load('O1');
      await flush();
      // 出栈的同步出口
      d.leave();
      f.held[0].resolve(envelope(0, detail('O1', '"order_no":"1"')));
      await flush();
      expect(d.snapshot.phase).assertEqual(OrderPhase.LOADING);
      expect(loaded).assertEqual(0);
      // 另一次进详情成功：只替换那一行（G17），不请求列表
      const listCount: number = f.listRequests().length;
      f.detailReply = (_id: string): TransportResponse => envelope(0, detail('O2', '"order_no":"2"').replace('"WAITING"',
        '"CREDITED"'));
      const d2: OrderDetailController = f.detailController();
      d2.onLoaded = (x: OrderRecord): void => {
        c.replaceRow(x);
      };
      d2.load('O2');
      await flush();
      expect(OrderJson.text(c.snapshot.items[1], 'display_status')).assertEqual('CREDITED');
      expect(OrderJson.text(c.snapshot.items[0], 'display_status')).assertEqual('PAID');
      expect(f.listRequests().length).assertEqual(listCount);
    });

    it('retry_after_blocks_refresh_paging_filters', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(42901, '{}', { 'Retry-After': '30' });
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(c.snapshot.blocked).assertTrue();
      expect(c.snapshot.error?.textKey).assertEqual('error.42901');
      const count: number = f.listRequests().length;
      expect(c.refresh()).assertFalse();
      expect(c.setGroup('credited')).assertFalse();
      expect(c.submitQuery('纸巾')).assertFalse();
      expect(c.retry()).assertFalse();
      expect(f.listRequests().length).assertEqual(count);
      // 详情同样禁用【重试】
      f.detailReply = (_id: string): TransportResponse => envelope(42901, '{}');
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      expect(d.snapshot.blocked).assertTrue();
      expect(d.retry()).assertFalse();
      c.leave();
      d.leave();
      f.hub.reset();
    });

    it('next_page_failure_keeps_items_with_trace6', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (q: string): TransportResponse => q.indexOf('cursor=') >= 0 ? envelope(50001, '{}')
        : envelope(0, page([order('O1', '1', 'PAID')], 'c1'));
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(c.loadMore()).assertTrue();
      await flush();
      expect(c.snapshot.items.length).assertEqual(1);
      expect(c.snapshot.loadMoreError?.trace6).assertEqual('123456');
      expect(f.lastListQuery()).assertEqual('scope=self&cursor=c1');
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O3', '3', 'PAID')], null));
      expect(c.retry()).assertTrue();
      await flush();
      expect(c.snapshot.items.length).assertEqual(2);
      expect(c.snapshot.hasMore).assertFalse();
      expect(c.loadMore()).assertFalse();
    });

    // ---------------------------------------------------------------- 比价「查看说明」
    it('price_compare_help_entry_configured_or_not', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const d: OrderRecord = rec(detail('U', '"order_no":"260920-111122223333444"').replace('"WAITING"', '"NO_REBATE"')
        .replace('"is_price_compare":false', '"is_price_compare":true'));
      expect(OrderDraftTexts.text(WhyNoRebate.of(d)['hintKey'] as string)).assertEqual('这笔订单被平台判为比价订单，没有返利');
      expect(PriceCompareEntry.of(d, null, Routes.all)['show']).assertFalse();
      const links: OrderRecord = rec('{"price_compare":{"route":"Help","params":{"article_id":"price-compare"}}}');
      const entry: Record<string, Object | null> = PriceCompareEntry.of(d, links, Routes.all);
      expect(entry['show']).assertTrue();
      f.open(entry['route'] as string, entry['params'] as Record<string, Object>);
      expect(f.stack.getAllPathName().length > 0).assertTrue();
      const top: Record<string, Object> = f.stack.topParams();
      const target: Object | undefined = top['article_id'] ?? top['url'];
      expect(target !== undefined).assertTrue();
      expect(OrderDraftTexts.text('order_detail.help_entry')).assertEqual('查看说明');
    });

    it('query_round_and_q_limit', 0, () => {
      const q: OrderQuery = OrderQuery.initial(null);
      q.apply('set_q', '1234567890123456789012345678901234567890123');
      expect((q.params()['q'] as string).length).assertEqual(40);
    });
    // ---------------------------------------------------------------- 第 1 轮评审修复（R1-01..05）与共性第 7–12 条
    it('R1_01_session_lost_login_b_back_to_old_detail_no_a_data', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '260920-111122223333444', 'PAID')], null));
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      // 账号 A：列表 → 详情（经 Router 打开，与 entry 同一接线）
      const params: Record<string, Object> = {};
      params['order_id'] = 'O1';
      f.open('OrderDetail', params);
      expect(f.top()).assertEqual('OrderDetail');
      f.detailReply = (_id: string): TransportResponse => envelope(0, detail('O1', '"order_no":"260920-111122223333444"'));
      const d: OrderDetailController = f.detailController();
      const shown: OrderDetailSnapshot[] = [];
      d.onChange = (x: OrderDetailSnapshot): void => {
        shown.push(x);
      };
      d.load('O1');
      await flush();
      expect(OrderJson.text(d.snapshot.detail as OrderRecord, 'order_no')).assertEqual('260920-111122223333444');
      // 详情 → 商品页；请求触发会话失效（会话归属变为游客）
      const product: Record<string, Object> = {};
      product['platform'] = 'taobao';
      product['product_key'] = 'tb:9007';
      f.open('ProductDetail', product);
      expect(f.top()).assertEqual('ProductDetail');
      f.account = null;
      f.scopeKey = 'guest';
      expect(f.hub.sync()).assertTrue();
      // 同步清空已显示的详情快照并通知视图；旧会话的详情页移出导航栈
      expect(d.snapshot.detail === null).assertTrue();
      expect(d.snapshot.phase).assertEqual(OrderPhase.IDLE);
      const last: OrderDetailSnapshot = shown[shown.length - 1];
      expect(last.detail === null).assertTrue();
      expect(f.stack.getAllPathName().indexOf('OrderDetail')).assertEqual(-1);
      expect(f.hub.openDetails).assertEqual(0);
      // 登录账号 B，返回：不会回到旧详情，也不再用旧 order_id 请求
      f.account = 'user-2';
      f.scopeKey = 'scope-2';
      expect(f.hub.sync()).assertTrue();
      const before: number = f.rig.server.count('/v1/orders/O1');
      f.stack.removeByName('ProductDetail');
      expect(f.stack.getAllPathName().indexOf('OrderDetail')).assertEqual(-1);
      expect(d.retry()).assertFalse();
      await flush();
      expect(f.rig.server.count('/v1/orders/O1')).assertEqual(before);
      expect(d.snapshot.detail === null).assertTrue();
      // 列表同样不留 A 的数据
      expect(c.snapshot.items.length).assertEqual(0);
    });

    it('R1_02_retry_after_shared_by_list_detail_pending_positions', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      // 订单列表顶部的卡先拉到
      const listCard: PendingTrackController = f.pendingController();
      listCard.fetch(null);
      await flush();
      expect(listCard.snapshot.cards.length).assertEqual(1);
      expect(listCard.snapshot.closeDisabled).assertFalse();
      // 列表收到 42901 + Retry-After=30
      f.list = (_q: string): TransportResponse => envelope(42901, '{}', { 'Retry-After': '30' });
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(c.snapshot.blocked).assertTrue();
      // 同页待跟单卡的关闭同步禁用，且发送前拦截
      expect(listCard.snapshot.closeDisabled).assertTrue();
      expect(listCard.dismiss(listCard.snapshot.cards[0])).assertFalse();
      expect(f.rig.server.count('/dismiss')).assertEqual(0);
      // 待跟单查询也不发
      const pendingCount: number = f.rig.server.count('/v1/orders/pending-tracks');
      listCard.fetch(null);
      await flush();
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(pendingCount);
      // 重新进入：商品详情 / 搜索页的卡片位置一开始就禁用，查询不发
      const productCard: PendingTrackController = f.pendingController();
      expect(productCard.snapshot.closeDisabled).assertTrue();
      productCard.fetch('taobao');
      await flush();
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(pendingCount);
      // 详情：重进也不发，显示限流并禁用【重试】
      const d: OrderDetailController = f.detailController();
      expect(d.snapshot.blocked).assertTrue();
      d.load('O1');
      await flush();
      expect(f.rig.server.count('/v1/orders/O1')).assertEqual(0);
      expect(d.snapshot.error?.textKey).assertEqual('error.42901');
      expect(d.retry()).assertFalse();
      // 翻页、刷新同样被拦
      expect(c.refresh()).assertFalse();
      expect(c.loadMore()).assertFalse();
      // 到期：恢复；被拦下的查询补拉一次
      f.nowMs += 31000;
      expect(c.blocked).assertFalse();
      expect(listCard.dismiss(listCard.snapshot.cards[0])).assertTrue();
      await flush();
      expect(f.rig.server.count('/dismiss')).assertEqual(1);
      f.hub.reset();
      listCard.leave();
      productCard.leave();
      d.leave();
    });

    it('R1_02_pending_query_42901_blocks_list_detail_and_resets_on_session', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      f.pendingReply = (): TransportResponse => envelope(42901, '{}', { 'Retry-After': '20' });
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.closeDisabled).assertTrue();
      const once: number = f.rig.server.count('/v1/orders/pending-tracks');
      p.fetch(null);
      await flush();
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(once);
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(f.listRequests().length).assertEqual(0);
      expect(c.snapshot.blocked).assertTrue();
      expect(c.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(c.snapshot.error?.textKey).assertEqual('error.42901');
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      expect(f.rig.server.count('/v1/orders/O1')).assertEqual(0);
      // 换账号：闸门按会话，不带到新会话
      f.scopeKey = 'scope-2';
      expect(f.hub.sync()).assertTrue();
      expect(c.blocked).assertFalse();
      expect(p.snapshot.closeDisabled).assertFalse();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O9', '9', 'PAID')], null));
      c.ensureLoaded();
      await flush();
      expect(f.listRequests().length).assertEqual(1);
      p.leave();
      f.hub.reset();
    });

    it('R1_03_dismissed_card_not_revived_by_earlier_query', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ','
        + pending('L2', 'b1', 'jd', false, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards.length).assertEqual(2);
      // 重新拉取尚未返回时关闭 A
      f.pendingReply = (): TransportResponse | null => null;
      p.fetch(null);
      await flush();
      expect(f.held.length).assertEqual(1);
      const cardA: PendingTrackCard = p.snapshot.cards.filter((c: PendingTrackCard): boolean => c.linkId === 'L1')[0];
      expect(p.dismiss(cardA)).assertTrue();
      await flush();
      expect(p.snapshot.cards.filter((c: PendingTrackCard): boolean => c.linkId === 'L1').length).assertEqual(0);
      // 此前的查询晚到（dismissed=false 的旧快照）：A 不得重新出现，B 照常
      f.held[0].resolve(envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ','
        + pending('L2', 'b1', 'jd', false, false) + ']}'));
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      expect(p.snapshot.cards[0].linkId).assertEqual('L2');
      // 同平台的新尝试照常显示
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a2', 'taobao', false, false) + ','
        + pending('L2', 'b1', 'jd', false, false) + ']}');
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards.length).assertEqual(2);
      expect(p.snapshot.cards.filter((c: PendingTrackCard): boolean => c.attemptId === 'a2').length).assertEqual(1);
    });

    it('R1_04_card_enable_notification_no_duplicate_purpose', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      let rationale: number = 0;
      let system: number = 0;
      let stored: string | null = null;
      let status: string = 'not_asked';
      const requester: PermissionRequester = new PermissionRequester((): string | null => stored,
        (v: string | null): void => {
          stored = v;
        }, (): number => f.nowMs, 'harmony', (_p: string): string => status,
        (_purpose: string, _cont: string | null): Promise<void> => {
          rationale++;
          return Promise.resolve();
        }, (_p: string): Promise<string> => {
          system++;
          return Promise.resolve('denied');
        }, (_m: string | null, _b: string): void => {
        });
      f.pushVia = PendingTrackDeps.pushVia((permission: string, fromSettings: boolean, valid: () => boolean,
        purposeShown: boolean): Promise<PermissionResult> => requester.request(permission, fromSettings, valid,
        purposeShown));
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards[0].notificationRow).assertTrue();
      expect(p.enableNotification(p.snapshot.cards[0])).assertTrue();
      await flush();
      await flush();
      // 卡内通知行即用途说明：直接进系统申请，不再出说明页
      expect(rationale).assertEqual(0);
      expect(system).assertEqual(1);
      // 节流保留：被拒后 48 小时内同一入口不再弹系统框
      status = 'denied';
      const again: boolean = await PendingTrackDeps.pushVia((permission: string, fromSettings: boolean,
        valid: () => boolean, purposeShown: boolean): Promise<PermissionResult> => requester.request(permission,
        fromSettings, valid, purposeShown))((): boolean => true);
      expect(again).assertFalse();
      expect(system).assertEqual(1);
      // 其他入口（没展示过说明）仍先出说明
      const other: PermissionRequester = new PermissionRequester((): string | null => null, (_v: string | null): void => {
      }, (): number => f.nowMs, 'harmony', (_p: string): string => 'not_asked',
        (_purpose: string, _cont: string | null): Promise<void> => {
          rationale++;
          return Promise.resolve();
        }, (_p: string): Promise<string> => Promise.resolve('granted'), (_m: string | null, _b: string): void => {
        });
      await other.request(PermissionTypeRaw.PUSH);
      expect(rationale).assertEqual(1);
      // 页面已离开：不调系统接口（有效性复核保留）
      const left: PermissionResult = await requester.request(PermissionTypeRaw.PUSH, true, (): boolean => false, true);
      expect(left.resultRaw).assertEqual('unavailable');
      expect(system).assertEqual(1);
    });

    it('R1_05_list_amounts_stack_rebate_first_detail_rebate_first', 0, () => {
      expect(JSON.stringify(OrderAmountCells.sequence(OrderAmountCells.LIST, false))).assertEqual('["left","right"]');
      expect(JSON.stringify(OrderAmountCells.sequence(OrderAmountCells.LIST, true))).assertEqual('["right","left"]');
      expect(JSON.stringify(OrderAmountCells.sequence(OrderAmountCells.DETAIL, false))).assertEqual('["right","left"]');
      expect(JSON.stringify(OrderAmountCells.sequence(OrderAmountCells.DETAIL, true))).assertEqual('["right","left"]');
      // left 是实付，right 是返利
      const cells: Record<string, Object | null> = OrderAmountCells.of(rec(order('O1', '1', 'PAID')), false);
      expect((cells['left'] as Record<string, Object>)['labelKey']).assertEqual(OrderAmountCells.PAY_KEY);
      expect((cells['right'] as Record<string, Object>)['labelKey']).assertEqual(OrderAmountCells.EST_KEY);
    });

    it('L7_refresh_clears_loading_more_and_keeps_paging', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (q: string): TransportResponse | null => q.indexOf('cursor=') >= 0 ? null
        : envelope(0, page([order('O1', '1', 'PAID')], 'c2'));
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(c.loadMore()).assertTrue();
      expect(c.snapshot.loadingMore).assertTrue();
      // 下拉刷新开新轮次：同步清掉旧轮次的 loadingMore
      expect(c.refresh()).assertTrue();
      expect(c.snapshot.loadingMore).assertFalse();
      await flush();
      expect(c.snapshot.hasMore).assertTrue();
      // 旧轮次的翻页（若已到服务端）晚到：丢弃
      const stale: number = f.held.length;
      for (const h of f.held) {
        h.resolve(envelope(0, page([order('OX', 'x', 'PAID')], null)));
      }
      await flush();
      expect(c.snapshot.items.length).assertEqual(1);
      // 刷新后仍能翻页（游标来自刷新结果）
      expect(c.loadMore()).assertTrue();
      await flush();
      expect(f.lastListQuery().indexOf('cursor=c2') >= 0).assertTrue();
      f.held[stale].resolve(envelope(0, page([order('O2', '2', 'PAID')], null)));
      await flush();
      expect(c.snapshot.items.length).assertEqual(2);
      // 刷新失败：不留下无法继续的列表，给首屏【重试】
      f.list = (_q: string): TransportResponse => envelope(50001, '{}');
      c.refresh();
      await flush();
      expect(c.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(c.snapshot.error?.trace6).assertEqual('123456');
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID')], 'c2'));
      expect(c.retry()).assertTrue();
      await flush();
      expect(c.snapshot.hasMore).assertTrue();
    });

    it('L8_L9_dismiss_server_error_trace6_transport_network', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', false, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      f.dismissReply = (): TransportResponse => envelope(50001, 'null');
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      expect(p.snapshot.toastKey).assertEqual('error.50001');
      expect(p.snapshot.toastTrace).assertEqual('trace-abcdef123456');
      expect(p.snapshot.cards.length).assertEqual(1);
      // 未收录的 5xxxx 回落 error.50001，仍带 trace
      f.dismissReply = (): TransportResponse => envelope(50999, 'null');
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      expect(p.snapshot.toastKey).assertEqual('error.50001');
      expect(p.snapshot.toastTrace).assertEqual('trace-abcdef123456');
      const vars: Map<string, string> = new Map<string, string>();
      vars.set('trace6', '654321');
      expect(OrderDraftTexts.format('error.50001', vars).indexOf('654321') >= 0).assertTrue();
      // 只有传输失败才是网络错误
      f.dismissReply = (): TransportResponse => TransportResponse.failed(TransportFailure.TIMEOUT);
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      expect(p.snapshot.toastKey).assertEqual('order.network_error');
    });

    it('L10_restore_anchor_waits_for_target_then_aligns_once', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (q: string): TransportResponse => q.indexOf('cursor=c2') >= 0
        ? envelope(0, page([order('O3', '3', 'PAID'), order('O4', '4', 'PAID')], null))
        : envelope(0, page([order('O1', '1', 'PAID'), order('O2', '2', 'PAID')], 'c2'));
      const c: OrderListController = f.listController();
      const saved: OrderListConditions = new OrderListConditions();
      saved.group = 'all';
      c.restore(OrderListConditions.decode(saved.encode()), null);
      const anchor: OrderScrollAnchor = new OrderScrollAnchor('O4', c.conditions().encode());
      // 加载中：等
      c.ensureLoaded();
      expect(anchor.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase)).assertEqual(OrderScrollAnchor.WAIT);
      await flush();
      // 第一页没有目标：不丢弃
      expect(anchor.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase)).assertEqual(OrderScrollAnchor.WAIT);
      expect(anchor.pending).assertTrue();
      c.loadMore();
      await flush();
      // 翻页加载到目标：返回下标，只对齐一次
      expect(anchor.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase)).assertEqual(3);
      expect(anchor.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase))
        .assertEqual(OrderScrollAnchor.DROPPED);
      // 条件不同：放弃
      const other: OrderScrollAnchor = new OrderScrollAnchor('O1', c.conditions().encode());
      c.setGroup('credited');
      expect(other.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase))
        .assertEqual(OrderScrollAnchor.DROPPED);
    });

    it('L12_every_order_entry_lands_on_exact_route_and_params', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const landed = (route: string, params: Record<string, Object>, expectRoute: string, expectKeys: string): void => {
        f.open(route, params);
        expect(f.top()).assertEqual(expectRoute);
        expect(JSON.stringify(Object.keys(f.stack.topParams()).sort())).assertEqual(expectKeys);
      };
      const routeOf = (item: OrderRecord, i: number): string =>
        ((OrderDetailActions.of(item)['buttons'] as Object[])[i] as Record<string, Object>)['route'] as string;
      // 【去提现】Withdraw（CREDITED）：未实名先进 RealName（BR-ID-02），已实名精确落到 Withdraw
      const credited: OrderRecord = rec(detail('W', '"order_no":"1"').replace('"WAITING"', '"CREDITED"'));
      landed(routeOf(credited, 0), {}, 'RealName', '[]');
      f.realname = true;
      landed(routeOf(credited, 0), {}, 'Withdraw', '[]');
      // 【查看流水】Ledger（CLAWED_BACK）
      const clawed: OrderRecord = rec(detail('P', '"order_no":"1"').replace('"WAITING"', '"CLAWED_BACK"')
        .replace('"reason":null', '"reason":"PUNISH"').replace('"reason_action":[]', '"reason_action":["CONTACT_CS"]'));
      landed(routeOf(clawed, 1), {}, 'Ledger', '[]');
      // 【联系客服】Help（G09，不带 article_id）
      landed(routeOf(clawed, 0), {}, 'Help', '[]');
      // 【去申诉】Appeal（G08，不带参数）
      const blacklist: OrderRecord = rec(detail('B', '"order_no":"1"').replace('"WAITING"', '"INVALID"')
        .replace('"reason":null', '"reason":"BLACKLIST"').replace('"reason_action":[]', '"reason_action":["APPEAL"]'));
      landed(routeOf(blacklist, 0), {}, 'Appeal', '[]');
      // REAUTH → AuthManage
      const reauth: OrderRecord = rec(detail('R', '"order_no":"1"').replace('"WAITING"', '"INVALID"')
        .replace('"reason":null', '"reason":"AUTH_EXPIRED"').replace('"reason_action":[]', '"reason_action":["REAUTH"]'));
      landed(routeOf(reauth, 0), {}, 'AuthManage', '[]');
      // 「未跟单？去找回」FindOrder（卡内入口经 Router，无参数）
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.claim(p.snapshot.cards[0])).assertTrue();
      expect(f.top()).assertEqual('FindOrder');
      expect(JSON.stringify(Object.keys(f.stack.topParams()))).assertEqual('[]');
      // 「查看商品」ProductDetail（platform + product_key）
      const entry: Record<string, Object | null> = ViewProductEntry.of(rec(detail('O7', '"order_no":"1"')));
      landed(entry['route'] as string, entry['params'] as Record<string, Object>, 'ProductDetail',
        '["platform","product_key"]');
      expect(f.stack.topParams()['platform']).assertEqual('taobao');
      // 「查看说明」Help + article_id
      const pc: OrderRecord = rec(detail('U', '"order_no":"1"').replace('"WAITING"', '"NO_REBATE"')
        .replace('"is_price_compare":false', '"is_price_compare":true'));
      const links: OrderRecord = rec('{"price_compare":{"route":"Help","params":{"article_id":"price-compare"}}}');
      const help: Record<string, Object | null> = PriceCompareEntry.of(pc, links, Routes.all);
      landed(help['route'] as string, help['params'] as Record<string, Object>, 'Help', '["article_id"]');
      expect(f.stack.topParams()['article_id']).assertEqual('price-compare');
    });
  });
}
