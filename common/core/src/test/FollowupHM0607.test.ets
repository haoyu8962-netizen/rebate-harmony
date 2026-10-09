// FU-HM-0607：鸿蒙回查 APP-06b 共性第 42–47 条、APP-07 共性第 24–26 条与 F-HM-15 的回归测试（实现方自写）。
// 不连任何地址：购买用 OpenPurchaseIntegration 的挂起端口与手动计时器；剪贴板用真实 ApiClient + 本地假服务（NetworkTestRig）。
// 样例全部是演示数据；测试里没有像密钥的字面量。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, AuthSheetCounter, ClipboardController, ClipboardDeps, ClipboardHashStore, ClipboardReadPolicy,
  ClipboardResultBinding, ClipboardResultView, ClipboardSensitive, ClipboardSnapshot, ClipboardWriteLedger, ClipboardWriter,
  GuardState, JumpTipService, LaunchReadiness, ManualPasteAction, MemoryClipboardHashStore, MemoryPendingBackend,
  MemoryPurchasePending, MemoryUpdateStore, OpenActions, OpenPurchaseController, OpenResponseAction, OpenResponseOutcome,
  ParseRow, PasteboardPort, PasteOutcome, PendingActionStore, PrivacyState, PurchaseDeps, PurchaseDialogKind, PurchasePhase, PurchaseState,
  PurchaseModalRegistry, RouteDestination, RouteRequest, RouteSource, Router, RouteTable, StackNavigator, TradeJumpExecutor,
  TransportRequest, TransportResponse, UnavailableBaichuan, UnavailableWebCodeAuthorizer, UpdateCheckResult,
  UpdateCheckStatus, UpdateGate, UpdateState, UpdateStatusRaw
} from '../../Index';
import { RouteSpec } from 'generated';
import { MemoryPathStack } from './App05bFixture';
import { envelope, flush, Rig } from './NetworkTestRig';
import { ATTEMPT, card, FAR_FUTURE, Fixture, HeldCall, schemePlan, settle } from './OpenPurchaseIntegration.test';

// ---------------------------------------------------------------- 购买（APP-06b 共性第 43、44、46 条）

const PDD_AUTH: string = '{"auth_jump":{"primary":{"type":"universal_link","value":"https://auth.example.test/pdd"},'
  + '"fallbacks":[],"expire_at":"' + FAR_FUTURE + '"}}';

/** open 成功、返利为 0、no_rebate_cause=price_compare（价格不变）。 */
function compareOpen(): string {
  return '{"attempt_id":"' + ATTEMPT + '","jump":' + schemePlan() + ',"price_changed":false,"old_final_price_fen":2990,'
    + '"new_final_price_fen":2990,"new_link_id":null,"requote_failed":false,"new_rebate_min_fen":0,'
    + '"new_rebate_max_fen":0,"no_rebate_cause":"price_compare","availability":"ok",'
    + '"quoted_at":"2026-10-02T09:30:05+08:00"}';
}

/** 原卡返利为 rebate（null = 未知，按游客 login_required）。 */
function cardWithRebate(rebate: number | null): Record<string, Object> {
  const json: string = JSON.stringify(card());
  const v: string = rebate === null ? 'null' : String(rebate);
  const basis: string = rebate === null ? 'login_required' : (rebate === 0 ? 'no_rebate' : 'normal');
  return JSON.parse(json.split('"rebate_min_fen":269').join('"rebate_min_fen":' + v)
    .split('"rebate_max_fen":269').join('"rebate_max_fen":' + v)
    .split('"rebate_basis":"normal"').join('"rebate_basis":"' + basis + '"')) as Record<string, Object>;
}

/** 与 f 共用同一份购买待办（Router 的同一条本地记录）、同一个端口与计时器的另一个发起页。 */
function secondPage(f: Fixture): OpenPurchaseController {
  const executor: TradeJumpExecutor = new TradeJumpExecutor(f.ports, new UnavailableBaichuan(), f.sink,
    (): number => f.timers.now, (): number => f.timers.now);
  const deps: PurchaseDeps = new PurchaseDeps(f.port, executor, f.ports, f.env, f.pending,
    new AuthSheetCounter((): number => f.timers.now), new JumpTipService(f.port, (): string => 'session-1'),
    new UnavailableWebCodeAuthorizer(), new UnavailableBaichuan());
  deps.timers = f.timers;
  deps.clock = (): number => f.timers.now;
  deps.keyGenerator = (): string => 'page-b-key';
  return new OpenPurchaseController(deps);
}

/** 拼多多购买 → 30111 → 授权跳转已拉起，回前台后正在查询授权状态（返回那一次查询）。 */
async function pddAwaitingQuery(f: Fixture): Promise<HeldCall> {
  f.ports.launch = true;
  f.env.card = card('pdd');
  f.controller.buy(card('pdd'), null);
  f.opens()[0].fail(30111, PDD_AUTH);
  await flush();
  expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
  f.controller.authorize();
  await settle(f);
  f.controller.onBackground();
  f.controller.onForeground();
  await flush();
  const lists: HeldCall[] = f.port.ofOp('listUnionBindings');
  expect(lists.length).assertEqual(1);
  return lists[0];
}

function owner(record: Record<string, Object> | null): string {
  const v: Object | undefined = record === null ? undefined : record[OpenPurchaseController.OWNER];
  return typeof v === 'string' ? v as string : '';
}

// ---------------------------------------------------------------- 剪贴板（APP-07 共性第 25、26 条，F-HM-15）

const PRODUCT_LINK: string = 'https://e.tb.cn/h.Demo01?tk=Sample';
const PRODUCT_TEXT: string = '分享好物 ' + PRODUCT_LINK + ' 「全脂纯牛奶 250ml」';
const TAB_ROOTS: string[] = ['Home', 'AgentChat', 'OrderList', 'Me'];

function clipCard(key: string): string {
  return '{"product_key":"' + key + '","item_ref":"ref-' + key + '","platform":"taobao","title":"降噪蓝牙耳机",'
    + '"image":null,"price_fen":3990,"coupon_fen":1000,"final_price_fen":2990,"est_net_price_fen":2721,'
    + '"rebate_min_fen":269,"rebate_max_fen":269,"rebate_basis":"normal","benefit_tags":[],"is_presale":false,'
    + '"link_id":"link-' + key + '","cta":{"text_key":"btn.buy.coupon"},"quoted_at":"2026-10-02T09:30:00+08:00",'
    + '"stale":false,"age_sec":12,"source":"taobao_union","disclaimer_keys":["price_basis"],"availability":"ok"}';
}

function twoCards(): string {
  return '{"results":[{"hit":{"platform":"taobao","kind":"url","raw":"x"},"card":' + clipCard('tb:1')
    + '},{"hit":{"platform":"taobao","kind":"url","raw":"y"},"card":' + clipCard('tb:2') + '}]}';
}

class CountingPasteboard implements PasteboardPort {
  text: string | null = null;
  reads: number = 0;
  writes: number = 0;

  readText(): Promise<string | null> {
    this.reads++;
    return Promise.resolve(this.text);
  }

  writeText(text: string): Promise<boolean> {
    this.writes++;
    this.text = text;
    return Promise.resolve(true);
  }
}

/** 剪贴板执行层 + 真实 Router / StackNavigator；敏感浮层按 PurchaseModalRegistry（与 entry AppClipboard.overlay 同口径）。 */
class ClipRig {
  readonly rig: Rig = new Rig(null);
  readonly pasteboard: CountingPasteboard = new CountingPasteboard();
  readonly stack: MemoryPathStack = new MemoryPathStack();
  readonly navigator: StackNavigator = new StackNavigator();
  readonly router: Router;
  readonly modals: PurchaseModalRegistry = new PurchaseModalRegistry();
  readonly controller: ClipboardController;
  reply: TransportResponse = envelope(0, twoCards());

  constructor() {
    this.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> =>
    Promise.resolve(r.url.indexOf('/v1/inputs/parse') >= 0 ? this.reply : envelope(0, '{}'));
    this.navigator.attachStack(this.stack);
    this.navigator.tabRootHandler = (d: RouteDestination): boolean => d.route !== null && TAB_ROOTS.indexOf(d.route) >= 0;
    this.router = new Router(new PendingActionStore(new MemoryPendingBackend(), (): number => 1800000000000),
      (): GuardState => new GuardState('consented', 'ok', 'guest', true, '1.0.0', false),
      this.navigator, (name: string): RouteSpec | undefined => RouteTable.spec(name),
      (): LaunchReadiness => new LaunchReadiness(true, PrivacyState.CONSENTED, UpdateCheckStatus.finished(UpdateState.OK)));
    const deps: ClipboardDeps = new ClipboardDeps(this.pasteboard, new ApiClientSearchPort(this.rig.client));
    deps.consent = (): string => ClipboardReadPolicy.CONSENT_AGREED;
    deps.overlay = (): string => this.modals.active ? ClipboardSensitive.OVERLAY_AUTH_SHEET : ClipboardSensitive.OVERLAY_NONE;
    deps.scope = (): string => ClipboardController.scopeKey(this.rig.client.captureScope());
    deps.guest = (): boolean => true;
    deps.config = (): Record<string, Object> => {
      const c: Record<string, Object> = {};
      c['share_domains'] = ['share.example.test'];
      return c;
    };
    deps.open = (route: string, params: Record<string, Object>): boolean => {
      this.router.open(RouteRequest.of(route, RouteSource.IN_APP, params));
      return true;
    };
    deps.store = new MemoryClipboardHashStore();
    this.controller = new ClipboardController(deps);
    this.controller.onChange = (_s: ClipboardSnapshot): void => {
    };
    // 与 entry AppClipboard.compose 同一接线：导航栈改动先清掉栈里已没有发起页的弹层登记，再通知执行层
    this.navigator.onStackChanged = (names: string[]): void => {
      this.modals.prune(names);
      this.controller.stackChanged(names);
    };
    this.controller.sync();
    this.controller.onForeground();
  }

  open(route: string): void {
    this.router.open(RouteRequest.of(route, RouteSource.IN_APP));
  }

  /** 清栈回首页（强更清栈后撤回强更、补同意清栈）：栈直接清空并全量同步（不经页面的系统返回）。 */
  clearToHome(): void {
    this.stack.names = [];
    this.navigator.onStackChanged(this.stack.getAllPathName());
  }

  parseCount(): number {
    return this.rig.server.count('/v1/inputs/parse');
  }
}

/** 写入会进内存、但「落盘」失败的存储：读回能读到，write 返回 false（APP-07 共性第 25 条）。 */
class UnflushedStore implements ClipboardHashStore {
  private readonly values: Map<string, string> = new Map<string, string>();

  read(key: string): string | null {
    return this.values.get(key) ?? null;
  }

  write(key: string, value: string | null): boolean {
    if (value === null) {
      this.values.delete(key);
    } else {
      this.values.set(key, value);
    }
    return false;
  }
}

export default function followupHM0607Test() {
  describe('FollowupHM0607', () => {
    // ---------------------------------------------------------------- 共性第 43 条
    it('l43_compare_no_rebate_ignores_original_rebate', 0, () => {
      const data: Record<string, Object> = JSON.parse(compareOpen()) as Record<string, Object>;
      const env: Record<string, Object> = {};
      env['code'] = 0;
      env['data'] = data;
      for (const before of [269, 0, -1]) {
        const ctx: Record<string, Object> = OpenPurchaseController.openContext(cardWithRebate(before < 0 ? null : before));
        const o: OpenResponseOutcome = OpenResponseAction.map(env, ctx);
        expect(o.actionRaw + ':' + before).assertEqual(OpenActions.COMPARE_NO_REBATE + ':' + before);
      }
      // 本次是用户已确认的无返利购买（no_rebate=true）：不再弹
      const confirmed: OpenResponseOutcome = OpenResponseAction.map(env,
        OpenPurchaseController.openContext(cardWithRebate(0), true));
      expect(confirmed.actionRaw === OpenActions.COMPARE_NO_REBATE).assertFalse();
      // 改价同时命中比价无返利：改价确认框里带上无返利说明（原返利为 0 也一样）
      const changed: Record<string, Object> = JSON.parse(compareOpen()) as Record<string, Object>;
      changed['price_changed'] = true;
      changed['new_final_price_fen'] = 3290;
      const envChanged: Record<string, Object> = {};
      envChanged['code'] = 0;
      envChanged['data'] = changed;
      const pc: OpenResponseOutcome = OpenResponseAction.map(envChanged,
        OpenPurchaseController.openContext(cardWithRebate(0)));
      expect(pc.actionRaw).assertEqual(OpenActions.CONFIRM_PRICE);
      expect(pc.rebateGone).assertTrue();
    });

    it('l43_zero_and_unknown_original_rebate_still_show_compare_dialog', 0, async () => {
      const rebates: (number | null)[] = [0, null];
      for (const rebate of rebates) {
        const f: Fixture = new Fixture();
        f.ports.launch = true;
        f.env.card = cardWithRebate(rebate);
        f.controller.buy(cardWithRebate(rebate), null);
        f.opens()[0].ok(compareOpen());
        await settle(f);
        expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.COMPARE_NO_REBATE);
        expect(f.ports.launched.length).assertEqual(0);
      }
    });

    it('l43_buy_without_rebate_request_does_not_ask_compare_again', 0, async () => {
      const f: Fixture = new Fixture();
      f.ports.launch = true;
      f.controller.buy(card(), null);
      f.opens()[0].fail(30101, '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}');
      await flush();
      // AuthSheet 关闭 → 二选一 →【仍去购买（无返利）】：no_rebate=true 的新请求
      f.controller.dismissDialog();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      f.controller.buyWithoutRebate();
      expect((f.opens()[1].request.body ?? '').indexOf('"no_rebate":true') >= 0).assertTrue();
      f.opens()[1].ok(compareOpen());
      await settle(f);
      // 不再弹比价无返利确认（与 Android 同口径：原返利为正时仍按返利归零确认一次，见 checklist 疑点）
      expect(f.controller.state.dialog?.kind === PurchaseDialogKind.COMPARE_NO_REBATE).assertFalse();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.CONFIRM_REBATE_GONE);
      // 原返利为 0 的卡用户已确认无返利：直接外跳
      const g: Fixture = new Fixture();
      g.ports.launch = true;
      g.env.card = cardWithRebate(0);
      g.controller.buy(cardWithRebate(0), null);
      g.opens()[0].fail(30101, '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}');
      await flush();
      g.controller.dismissDialog();
      g.controller.buyWithoutRebate();
      g.opens()[1].ok(compareOpen());
      await settle(g);
      expect(g.controller.state.dialog === null).assertTrue();
      expect(g.ports.launched.length).assertEqual(1);
    });

    // ---------------------------------------------------------------- 共性第 44 条
    it('l44_old_page_late_unbound_query_keeps_new_page_pending', 0, async () => {
      const f: Fixture = new Fixture();
      const query: HeldCall = await pddAwaitingQuery(f);
      // 页面 B 购买收到 30111，登记新的授权待办
      const b: OpenPurchaseController = secondPage(f);
      b.buy(card('pdd'), null);
      f.opens()[1].fail(30111, PDD_AUTH);
      await flush();
      expect(b.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
      const bOwner: string = owner(f.pending.peek());
      expect(bOwner.length > 0).assertTrue();
      // A 的旧查询迟到：未授权 → A 给二选一，但不清 B 的待办
      query.ok('{"items":[{"platform":"pdd","status":"unbound"}]}');
      await flush();
      expect(f.controller.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      expect(owner(f.pending.peek())).assertEqual(bOwner);
      // A 出栈也不删 B 的待办
      f.controller.leave();
      expect(owner(f.pending.peek())).assertEqual(bOwner);
    });

    it('l44_old_page_late_active_query_does_not_consume_new_page_pending', 0, async () => {
      const f: Fixture = new Fixture();
      const query: HeldCall = await pddAwaitingQuery(f);
      const b: OpenPurchaseController = secondPage(f);
      b.buy(card('pdd'), null);
      f.opens()[1].fail(30111, PDD_AUTH);
      await flush();
      const bOwner: string = owner(f.pending.peek());
      query.ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await flush();
      // 待办已被 B 取代：A 不自动 open，B 的待办原样保留
      expect(f.opens().length).assertEqual(2);
      expect(owner(f.pending.peek())).assertEqual(bOwner);
    });

    // ---------------------------------------------------------------- 共性第 46 条
    it('l46_deferred_resume_expires_after_ttl', 0, async () => {
      const f: Fixture = new Fixture();
      const query: HeldCall = await pddAwaitingQuery(f);
      // 查询未完成时 App 再次进入后台；查询返回 active → 延迟恢复，待办不先删
      f.controller.onBackground();
      query.ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await flush();
      expect(f.opens().length).assertEqual(1);
      expect(f.pending.peek() !== null).assertTrue();
      // 授权完成超过 10 分钟后才回前台：待办已过期，放弃
      f.timers.now += MemoryPurchasePending.TTL_MILLIS + 1000;
      f.controller.onForeground();
      await flush();
      expect(f.opens().length).assertEqual(1);
    });

    it('l46_deferred_resume_dropped_when_replaced_by_other_page', 0, async () => {
      const f: Fixture = new Fixture();
      const query: HeldCall = await pddAwaitingQuery(f);
      f.controller.onBackground();
      query.ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await flush();
      // 等待期间别的页面登记了新的购买待办
      const b: OpenPurchaseController = secondPage(f);
      b.buy(card('pdd'), null);
      f.opens()[1].fail(30111, PDD_AUTH);
      await flush();
      const bOwner: string = owner(f.pending.peek());
      f.controller.onForeground();
      await flush();
      expect(f.opens().length).assertEqual(2);
      expect(owner(f.pending.peek())).assertEqual(bOwner);
    });

    it('l46_deferred_resume_within_ttl_opens_once', 0, async () => {
      const f: Fixture = new Fixture();
      const query: HeldCall = await pddAwaitingQuery(f);
      f.controller.onBackground();
      query.ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await flush();
      f.timers.now += 60000;
      f.controller.onForeground();
      await flush();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey === f.opens()[0].request.idempotencyKey).assertFalse();
      expect(f.pending.peek() === null).assertTrue();
      // 只执行一次
      f.controller.onBackground();
      f.controller.onForeground();
      await flush();
      expect(f.opens().length).assertEqual(2);
    });

    // ---------------------------------------------------------------- APP-07 共性第 24 条
    it('a24_null_min_10405_forces_despite_cached_minimum_and_persists', 0, () => {
      const store: MemoryUpdateStore = new MemoryUpdateStore();
      const now: number = 1790661600 * 1000;
      const gate: UpdateGate = new UpdateGate(store, (): number => now, '1.2.0', 'harmony', 'agc', null);
      gate.onColdStart(now);
      // 缓存的最低版本 1.0.0 不高于本机 1.2.0
      gate.apply(new UpdateCheckResult('1.0.0', null, '1.3.0', 'huawei', [], 1800), now);
      expect(gate.state(now).statusRaw).assertEqual(UpdateStatusRaw.OK);
      // 网络层整体 10405（没带最低版本）/ 登录受限会话按「低于」处理：服务端已判定，强制进强更
      gate.on10405(null, now + 1);
      expect(gate.state(now + 1).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
      expect(store.load().forcedByServer === true).assertTrue();
      // 跨进程保留：同版本冷启动检查失败仍是强更
      const cold: UpdateGate = new UpdateGate(store, (): number => now + 2, '1.2.0', 'harmony', 'agc', null);
      cold.onColdStart(now + 2);
      cold.applyFailure(now + 3);
      expect(cold.state(now + 3).statusRaw).assertEqual(UpdateStatusRaw.BELOW_MIN);
      // 成功复查解除
      cold.apply(new UpdateCheckResult('1.0.0', null, '1.3.0', 'huawei', [], 1800), now + 4);
      expect(cold.state(now + 4).statusRaw).assertEqual(UpdateStatusRaw.OK);
      // 本机升级后失效
      const g2: UpdateGate = new UpdateGate(store, (): number => now, '1.2.0', 'harmony', 'agc', null);
      g2.on10405(null, now + 5);
      const upgraded: UpdateGate = new UpdateGate(store, (): number => now + 6, '1.2.1', 'harmony', 'agc', null);
      upgraded.onColdStart(now + 6);
      upgraded.applyFailure(now + 7);
      expect(upgraded.state(now + 7).statusRaw === UpdateStatusRaw.BELOW_MIN).assertFalse();
    });

    // ---------------------------------------------------------------- APP-07 共性第 25 条
    it('a25_ledger_trusts_flush_result_not_read_back', 0, async () => {
      const store: UnflushedStore = new UnflushedStore();
      const ledger: ClipboardWriteLedger = new ClipboardWriteLedger(ClipboardWriteLedger.DEFAULT_CAPACITY,
        (t: string): string => 'h-' + t.length, store);
      const board: CountingPasteboard = new CountingPasteboard();
      const writer: ClipboardWriter = new ClipboardWriter(board, ledger);
      // 内存里读得回，但没落盘：不写系统剪贴板
      expect(await writer.write('demo-text')).assertFalse();
      expect(ledger.contains('demo-text')).assertTrue();
      expect(board.writes).assertEqual(0);
    });

    // ---------------------------------------------------------------- APP-07 共性第 26 条
    it('a26_same_content_twice_gets_new_result_number_and_old_callback_is_inert', 0, async () => {
      const r: ClipRig = new ClipRig();
      r.pasteboard.text = PRODUCT_TEXT;
      await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const a: ClipboardResultView = r.controller.snapshot.result as ClipboardResultView;
      const bindA: ClipboardResultBinding = new ClipboardResultBinding(r.controller, a);
      // 同样的剪贴板内容、同样的服务端结果再来一次
      await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      const b: ClipboardResultView = r.controller.snapshot.result as ClipboardResultView;
      expect(b.kind).assertEqual(ClipboardResultView.CARD_LIST);
      expect(JSON.stringify(b.rows.map((x: ParseRow) => x.card)) === JSON.stringify(a.rows.map((x: ParseRow) => x.card))).assertTrue();
      expect(b.serial !== a.serial).assertTrue();
      // A 的回调（关闭、点卡）不作用于内容相同的 B
      bindA.close();
      expect(r.controller.snapshot.result === b).assertTrue();
      expect(bindA.openRow(a.rows[0])).assertFalse();
      expect(r.controller.snapshot.result === b).assertTrue();
    });

    // ---------------------------------------------------------------- F-HM-15
    it('f15_registry_release_visible_and_prune', 0, () => {
      const reg: PurchaseModalRegistry = new PurchaseModalRegistry();
      const a: Object = new Object();
      const b: Object = new Object();
      expect(reg.setModal(a, 'Search', true)).assertTrue();
      expect(reg.setModal(b, 'ProductDetail', true)).assertFalse();
      reg.release(a);
      expect(reg.active).assertTrue();
      // 被盖住不算，回到可见再算（返回 true：重新出现敏感浮层）
      expect(reg.setVisible(b, false)).assertFalse();
      expect(reg.active).assertFalse();
      expect(reg.setVisible(b, true)).assertTrue();
      // 栈里已没有它的路由名：兜底清掉
      reg.prune(['Search']);
      expect(reg.active).assertFalse();
      expect(reg.size).assertEqual(0);
      // 弹层关闭即移除
      reg.setModal(a, 'Search', true);
      reg.setModal(a, 'Search', false);
      expect(reg.size).assertEqual(0);
    });

    it('f15_modal_during_clear_stack_then_home_paste_recovers', 0, async () => {
      const r: ClipRig = new ClipRig();
      r.pasteboard.text = PRODUCT_TEXT;
      // 搜索页上的购买执行器显示 AuthSheet（与 entry TradeBinder.onState → AppClipboard.purchaseModal 同口径）
      const f: Fixture = new Fixture();
      const page: OpenPurchaseController = f.controller;
      page.onChange = (s: PurchaseState): void => {
        r.modals.setModal(page, 'Search', s.phase === PurchasePhase.LOADING || s.dialog !== null);
      };
      r.open('Search');
      page.buy(card(), null);
      f.opens()[0].fail(30101, '{"auth_url":"https://oauth.example.test/a","state":"st_01","auth_methods":["web_code"]}');
      await flush();
      expect(page.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_SHEET);
      expect(await r.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true)).assertEqual(PasteOutcome.SKIPPED);
      // 弹层显示期间被强更清栈：页面出栈的同步出口只调 AppTrade.release（leave 不再发状态通知），登记随之释放
      page.leave();
      expect(r.modals.active).assertTrue();
      r.modals.release(page);
      r.clearToHome();
      // 撤回强更、回到首页：主动粘贴恢复
      const outcome: string = await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true);
      await flush();
      expect(outcome).assertEqual(ManualPasteAction.PARSE);
      expect(r.pasteboard.reads).assertEqual(1);
      expect(r.parseCount()).assertEqual(1);
    });

    it('f15_clear_stack_without_exit_is_pruned_by_stack_sync', 0, async () => {
      const r: ClipRig = new ClipRig();
      r.pasteboard.text = PRODUCT_TEXT;
      const page: Object = new Object();
      r.open('Search');
      r.modals.setModal(page, 'Search', true);
      // 页面出口没走到（只有栈的全量同步）：栈里已没有 Search，登记兜底清掉
      r.clearToHome();
      expect(r.modals.active).assertFalse();
      expect(await r.controller.pasteProduct(ManualPasteAction.ENTRY_HOME, true)).assertEqual(ManualPasteAction.PARSE);
      expect(r.pasteboard.reads).assertEqual(1);
    });

    it('f15_covered_page_modal_does_not_block_paste_on_top_page', 0, async () => {
      const r: ClipRig = new ClipRig();
      r.pasteboard.text = PRODUCT_TEXT;
      const page: Object = new Object();
      r.open('Search');
      r.modals.setModal(page, 'Search', true);
      expect(await r.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true)).assertEqual(PasteOutcome.SKIPPED);
      // 别的页面盖在发起页上（AppTrade.pageVisible(false) → purchaseModalVisible）
      r.modals.setVisible(page, false);
      expect(await r.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true))
        .assertEqual(ManualPasteAction.PARSE);
    });

    // ---------------------------------------------------------------- 第 2 轮：F1-01（共性第 48 条）
    it('l48_deferred_auth_resume_survives_login_and_consent_notifications', 0, async () => {
      const f: Fixture = new Fixture();
      const query: HeldCall = await pddAwaitingQuery(f);
      // 查询未完成时 App 再次进入后台；查询返回 active → 授权恢复排队（授权槽）
      f.controller.onBackground();
      query.ok('{"items":[{"platform":"pdd","status":"active"}]}');
      await flush();
      expect(f.opens().length).assertEqual(1);
      // 后台期间收到无关的登录恢复、补同意恢复通知：各进各的槽，不覆盖授权恢复
      f.controller.resumeAfterLogin();
      f.controller.resumeAfterConsent();
      f.timers.now += 60000;
      f.controller.onForeground();
      await flush();
      // 有效期内回前台：只执行一次新键 open，授权待办消费掉
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey === f.opens()[0].request.idempotencyKey).assertFalse();
      expect(f.pending.peek() === null).assertTrue();
      f.controller.onBackground();
      f.controller.onForeground();
      await flush();
      expect(f.opens().length).assertEqual(2);
    });

    it('l48_deferred_login_and_consent_resume_each_still_work', 0, async () => {
      // 登录恢复排队后又收到补同意恢复通知：登录恢复照常以原键重放一次
      const f: Fixture = new Fixture();
      f.env.logged = false;
      f.controller.buy(card(), null);
      f.opens()[0].fail(10001);
      await flush();
      f.controller.onBackground();
      f.env.logged = true;
      f.controller.resumeAfterLogin();
      f.controller.resumeAfterConsent();
      f.controller.onForeground();
      expect(f.opens().length).assertEqual(2);
      expect(f.opens()[1].request.idempotencyKey).assertEqual(f.opens()[0].request.idempotencyKey);
      expect(f.pending.peek() === null).assertTrue();
      // 补同意恢复排队后又收到登录恢复通知：补同意恢复照常执行一次购买
      const g: Fixture = new Fixture();
      g.env.basic = true;
      g.controller.buy(card(), null);
      expect(g.opens().length).assertEqual(0);
      g.controller.onBackground();
      g.env.basic = false;
      g.controller.resumeAfterConsent();
      g.controller.resumeAfterLogin();
      expect(g.opens().length).assertEqual(0);
      g.controller.onForeground();
      expect(g.opens().length).assertEqual(1);
      expect(g.pending.peek() === null).assertTrue();
      // 页面离开清空全部槽位：之后回前台什么都不执行
      const h: Fixture = new Fixture();
      h.env.basic = true;
      h.controller.buy(card(), null);
      h.controller.onBackground();
      h.env.basic = false;
      h.controller.resumeAfterConsent();
      h.controller.leave(true);
      h.controller.onForeground();
      expect(h.opens().length).assertEqual(0);
    });

    // ---------------------------------------------------------------- 第 2 轮：F1-02（F-HM-15）
    it('f15_registry_keeps_hidden_state_before_modal_registered', 0, () => {
      const reg: PurchaseModalRegistry = new PurchaseModalRegistry();
      const a: Object = new Object();
      // 被盖住时还没有弹层登记：可见性也要记住
      expect(reg.setVisible(a, false)).assertFalse();
      expect(reg.setModal(a, 'Search', true)).assertFalse();
      expect(reg.active).assertFalse();
      // 弹层关了再开：仍按被盖住
      reg.setModal(a, 'Search', false);
      expect(reg.setModal(a, 'Search', true)).assertFalse();
      expect(reg.active).assertFalse();
      // 回到可见：重新算作敏感浮层
      expect(reg.setVisible(a, true)).assertTrue();
      expect(reg.active).assertTrue();
      // 出栈释放可见性：同一 owner 再登记按可见算（不残留隐藏状态）
      reg.setVisible(a, false);
      reg.release(a);
      expect(reg.setModal(a, 'Search', true)).assertTrue();
    });

    it('f15_covered_page_late_dialog_does_not_block_paste_on_top_page', 0, async () => {
      const r: ClipRig = new ClipRig();
      r.pasteboard.text = PRODUCT_TEXT;
      // 页面 A（搜索页）的购买执行器：状态通知按 entry TradeBinder.onState → AppClipboard.purchaseModal 同口径登记
      const f: Fixture = new Fixture();
      const page: OpenPurchaseController = f.controller;
      page.onChange = (s: PurchaseState): void => {
        r.modals.setModal(page, 'Search', s.phase === PurchasePhase.LOADING || s.dialog !== null);
      };
      r.open('Search');
      // A 授权外跳回来、AuthSheet 已关，正在等 bindings 查询：此刻没有弹层登记
      const query: HeldCall = await pddAwaitingQuery(f);
      expect(r.modals.size).assertEqual(0);
      // 页面 B 盖在 A 上（AppTrade.pageVisible(false) → purchaseModalVisible）
      r.open('Search');
      r.modals.setVisible(page, false);
      // A 的查询迟到：未授权 → A 弹二选一（迟到的 showDialog 重新登记弹层）
      query.ok('{"items":[{"platform":"pdd","status":"unbound"}]}');
      await flush();
      expect(page.state.dialog?.kind).assertEqual(PurchaseDialogKind.AUTH_DECLINED);
      expect(r.modals.active).assertFalse();
      // B 上的主动粘贴不被拦
      const outcome: string = await r.controller.pasteProduct(ManualPasteAction.ENTRY_SEARCH_TYPING, true);
      await flush();
      expect(outcome).assertEqual(ManualPasteAction.PARSE);
      expect(r.pasteboard.reads).assertEqual(1);
      // 回到 A：A 的弹层重新算作敏感浮层
      expect(r.modals.setVisible(page, true)).assertTrue();
      expect(r.modals.active).assertTrue();
    });
  });
}
