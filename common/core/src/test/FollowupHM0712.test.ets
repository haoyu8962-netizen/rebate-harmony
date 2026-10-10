// FU-HM-0712 鸿蒙回头补课：钱包 / 订单 / 我的 会话读取全量审计（F-HM-23，APP-09 共性第 63、65 条，APP-08 第 44–46 条）与 F-HM-24。
// 真实 ApiClient + 本地假服务，不连任何地址、不做真实提现。每个用例的注释写明「按旧逻辑为何失败」或「作为证据」。
// 统一窗口：新账号令牌已保存（ApiClient 归属立即变化），会话清空通知（WalletSession.sync 等）还没执行。
import { describe, it, expect } from '@ohos/hypium';
import {
  RecordsPhase, SensitiveFlow, SensitiveOutcome, SessionTokenSet, TransportFailure, TransportRequest, TransportResponse,
  WalletController, WalletPhase, WithdrawController, WithdrawPhase, WithdrawRecordsController
} from '../../Index';
import {
  IdentityBoundSlot, MeLevel, MeLocalStore, MemoryMeClearMark, MemoryMeLocalBackend, MeTabController, OrderAnchorKeeper,
  OrderDetailController, OrderListConditions, OrderListController, OrderPageRestorer, OrderPageState, OrderPhase,
  OrderRenderTicket, OrderStaleCache, PendingTrackCard, PendingTrackController, PrivacyCenterController,
  PrivacyWithdrawOutcomes
} from '../../Index';
import {
  OrderCopy, OrderListPage, OrderRecord, PendingTrackDeps, PendingTrackPosition, PermissionRequester, PermissionResult,
  PermissionTypeRaw, TabSwitchSignal
} from '../../Index';
import {
  FlushedPageStateKv, OrderInputHandlers, OrderInputModel, OrderListSnapshot, OrderPageStateKv, OrderPageStateStore,
  OrderPersistResult, OrderPlatformOptions, OrderStatusGroup
} from '../../Index';
import { envelope, flush } from './NetworkTestRig';
import { NOW, openWithdraw, settle, WalletFixture, withdrawal } from './WalletIntegration.test';
import { detail, order, OrderFixture, page, pending, rec } from './OrderIntegration.test';
import { MeFixture, Ports } from './MeIntegration.test';

/** 订单列表页模型里输入回调会写的字段（与 features OrderListModel 同一接口）。 */
class InputModel implements OrderInputModel {
  inputText: string = '';
  platformSheet: boolean = false;
  monthSheet: boolean = false;
}

/** 系统偏好的替身（R2-02）：putSync / deleteSync 只改内存，flushSync 才落盘，可注入落盘失败。 */
class FakePrefs {
  readonly memory: Map<string, string> = new Map<string, string>();
  readonly disk: Map<string, string> = new Map<string, string>();
  failFlush: boolean = false;

  kv(): FlushedPageStateKv {
    return new FlushedPageStateKv((key: string): string | null => this.memory.get(key) ?? null,
      (key: string, value: string): void => {
        this.memory.set(key, value);
      }, (key: string): void => {
        this.memory.delete(key);
      }, (): void => {
        if (this.failFlush) {
          throw new Error('flush failed');
        }
        this.disk.clear();
        this.memory.forEach((v: string, k: string): void => {
          this.disk.set(k, v);
        });
      });
  }
}

function meStore(): MeLocalStore {
  const s: MeLocalStore = new MeLocalStore();
  s.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
  return s;
}

/** 新令牌已保存（登录世代已变），钱包会话的清空通知（session.sync）还没执行。 */
function relogin(f: WalletFixture, account: string): void {
  f.rig.tokens.save(new SessionTokenSet('access-' + account + '-b', 'refresh-' + account + '-b', 'full', account));
  f.rig.client.onSessionChanged();
}

/** 当前账号的提现提交得到结果未知（断连），返回提现页。 */
async function pendingWithdrawFor(f: WalletFixture, account: string): Promise<WithdrawController> {
  f.reply('POST /v1/withdrawals', (_r: TransportRequest) => TransportResponse.failed(TransportFailure.DISCONNECT));
  f.session.tokens.put('withdraw', account, 'fixture-step-token', NOW + 300000);
  const c: WithdrawController = await openWithdraw(f);
  c.fillQuick(1000, c.snapshot.version);
  await settle();
  c.submit();
  await settle();
  return c;
}

export default function followupHM0712Test() {
  describe('FollowupHM0712', () => {
    it('C_W1_wallet_refresh_in_window_does_not_rebind_old_summary_to_new_session', 0, async () => {
      // 旧逻辑：WalletController.run 每轮都 `boundScope = d.scope()`——窗口里下拉刷新会把已显示的 A 摘要重新绑定到 B：B 的摘要请求
      // 照常发出（摘要次数 +1 断言失败），B 的摘要按执行时账号写进 B 的缓存（cache.load 非空断言失败）；【提现】按点击时的当前账号（B）
      // 查实名、通过后直接导航（opened=1 断言失败）。现在本页构造时一次性取得归属键与账号，run 发现会话已变不再 begin 重绑、不发请求；
      // 【提现】、实名查询、缓存读写只用固定账号。
      const f: WalletFixture = new WalletFixture();
      f.session.sync();
      const w: WalletController = new WalletController(f.deps());
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      const summaries: number = f.count('/v1/wallet/summary');
      const mes: number = f.count('/v1/me');
      f.cache.clear();

      relogin(f, 'user-2');
      w.refresh();
      await settle();
      expect(f.count('/v1/wallet/summary')).assertEqual(summaries);
      expect(f.cache.load()).assertNull();
      let opened: number = 0;
      w.requestWithdraw((): void => {
        opened++;
      });
      await settle();
      expect(opened).assertEqual(0);
      expect(f.count('/v1/me')).assertEqual(mes);

      // 清空通知执行后：本页按新会话重建身份，照常读取（不误伤）
      f.session.sync();
      w.load();
      await settle();
      expect(w.snapshot.phase).assertEqual(WalletPhase.CONTENT);
      expect(f.count('/v1/wallet/summary')).assertEqual(summaries + 1);
      expect(f.cache.load() !== null).assertTrue();
      w.requestWithdraw((): void => {
        opened++;
      });
      await settle();
      expect(opened).assertEqual(1);
    });

    it('C_W2_records_refresh_and_copy_in_window_stay_bound_to_page_session', 0, async () => {
      // 旧逻辑：WithdrawRecordsController.run 同样每轮 `boundScope = d.scope()`——窗口里下拉刷新给旧列表重新绑定 B 并发 B 的列表请求
      // （列表次数断言失败）；【复制】只看 left 与版本，旧列表的交易流水号照常写进剪贴板（'done' 而非 'not_copyable'）。现在 run 发现
      // 会话已变就不重绑、不发；复制前与本页固定归属比较。
      const f: WalletFixture = new WalletFixture();
      f.reply('/v1/withdrawals/:id', (_r: TransportRequest) => envelope(0, withdrawal('W2', 'PAID_API', 500,
        '2026-09-27T15:20:00+08:00', ',"channel_order_id":"20260928200040011100"')));
      f.session.sync();
      const c: WithdrawRecordsController = new WithdrawRecordsController(f.deps());
      c.open('W2');
      await settle();
      expect(c.snapshot.phase).assertEqual(RecordsPhase.CONTENT);
      expect(c.tradeNo('W2')['copyText'] as string).assertEqual('20260928200040011100');
      const lists: number = f.count('/v1/withdrawals');
      const writes: number = f.board.writes;

      relogin(f, 'user-2');
      c.refresh();
      await settle();
      expect(f.count('/v1/withdrawals')).assertEqual(lists);
      expect(await c.copy('W2', c.snapshot.version)).assertEqual('not_copyable');
      expect(f.board.writes).assertEqual(writes);
      // 清空通知执行后本页失效（清空），旧回调同样不写
      f.session.sync();
      expect(c.snapshot.items.length).assertEqual(0);
      expect(await c.copy('W2', c.snapshot.version)).assertEqual('not_copyable');
    });

    it('C_W3_withdraw_resync_in_window_never_reads_new_account_pending_into_old_page', 0, async () => {
      // 旧逻辑：syncPending 按「当前会话账号」读未决记录（ApiClient.pendingFor），onShown 只看 left——窗口里 A 的提现页回到可见，
      // B 的待确认记录（含金额）被读进 A 的页面（pending 非空断言失败）；SensitiveFlow.pending() 同样直接返回 B 的记录。现在
      // SensitiveFlow 带发起页构建时的表单账号，只认属于它的记录；页面会话已变时 syncPending 不读。
      const f: WalletFixture = new WalletFixture();
      f.switchAccount('user-2');
      const b: WithdrawController = await pendingWithdrawFor(f, 'user-2');
      expect(b.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
      b.leave();
      f.switchAccount('user-1');
      f.reply('POST /v1/withdrawals', (_r: TransportRequest) => envelope(0, '{}'));
      const a: WithdrawController = await openWithdraw(f);
      expect(a.snapshot.pending).assertNull();
      expect(a.flow.pending()).assertNull();

      relogin(f, 'user-2');
      expect(f.rig.client.pendingFor(WithdrawController.CREATE_OPERATION) !== null).assertTrue();
      a.onShown();
      await settle();
      expect(a.snapshot.pending).assertNull();
      expect(a.snapshot.phase === WithdrawPhase.PENDING).assertFalse();
      expect(a.flow.pending()).assertNull();
      expect(a.flow.inFlightElsewhere()).assertFalse();

      // 不误伤：B 自己的新页面（清空通知之后）照常显示 B 的待确认
      f.session.sync();
      const b2: WithdrawController = await openWithdraw(f);
      expect(b2.snapshot.pending !== null).assertTrue();
      expect(b2.snapshot.phase).assertEqual(WithdrawPhase.PENDING);
    });

    it('C_W3b_sensitive_flow_bound_account_filters_pending_record', 0, async () => {
      // 执行层单独核对：同一未决存储里 B 的记录，对绑定 A 的 SensitiveFlow 不存在；未绑定（直接构造）时仍按当前会话（兼容单测）。
      const f: WalletFixture = new WalletFixture();
      f.switchAccount('user-2');
      const b: WithdrawController = await pendingWithdrawFor(f, 'user-2');
      b.leave();
      const boundA: SensitiveFlow = new SensitiveFlow(f.deps(), SensitiveOutcome.OP_WITHDRAW,
        WithdrawController.CREATE_OPERATION, WithdrawController.STEP_UP_ACTION, f.session.withdrawGate, 'user-1');
      const boundB: SensitiveFlow = new SensitiveFlow(f.deps(), SensitiveOutcome.OP_WITHDRAW,
        WithdrawController.CREATE_OPERATION, WithdrawController.STEP_UP_ACTION, f.session.withdrawGate, 'user-2');
      const unbound: SensitiveFlow = new SensitiveFlow(f.deps(), SensitiveOutcome.OP_WITHDRAW,
        WithdrawController.CREATE_OPERATION, WithdrawController.STEP_UP_ACTION, f.session.withdrawGate);
      expect(boundA.pending()).assertNull();
      const key: string = boundB.pending()?.key ?? '';
      expect(key.length > 0).assertTrue();
      expect(boundA.keyOpen(key)).assertFalse();
      expect(boundA.keySuperseded('other')).assertFalse();
      expect(boundB.keyOpen(key)).assertTrue();
      expect(unbound.pending() !== null).assertTrue();
    });

    // ================================================================ 订单（APP-08 第 44–46 条）
    it('C_O1_list_refresh_and_load_more_in_window_void_old_list_without_rebinding', 0, async () => {
      // 共性第 44 条（Android FU R1-01 同类）。旧逻辑：OrderListController.run 每轮 `boundScope = d.scope()`——窗口里下拉刷新保留 A 的
      // 列表并把它重新绑到新会话，按 A 的条件用新会话发列表请求（请求次数断言失败、items 仍是 A 的两行）；渲染票据也随之「有效」。
      // 现在构造 / 换代通知之外不重绑：刷新、翻页发现会话已变就先作废旧列表（items 清空、IDLE），不发请求；渲染时的票据失效。
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '3741234567890123456', 'PAID'),
        order('O2', '3741234567890123457', 'PAID')], 'c2'));
      f.hub.sync();
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(c.snapshot.items.length).assertEqual(2);
      expect(c.snapshot.hasMore).assertTrue();
      const ticket: OrderRenderTicket = c.renderTicket(c.snapshot.items[0]);
      expect(c.ticketValid(ticket)).assertTrue();
      const requests: number = f.listRequests().length;

      f.scopeKey = 'scope-2';
      expect(c.ticketValid(ticket)).assertFalse();
      expect(c.loadMore()).assertFalse();
      expect(c.snapshot.loadingMore).assertFalse();
      expect(c.snapshot.items.length).assertEqual(0);
      c.refresh();
      await flush();
      expect(f.listRequests().length).assertEqual(requests);
      expect(c.snapshot.items.length).assertEqual(0);
      expect(c.snapshot.phase).assertEqual(OrderPhase.IDLE);
      expect(c.ticketValid(ticket)).assertFalse();
      // 详情结果也不替换进列表（列表已不属于当前会话）
      expect(c.replaceRow(rec(detail('O1', '"order_no":"3741234567890123456"')))).assertFalse();

      // 清空通知执行后：按新会话照常加载（不误伤）；旧票据仍无效
      expect(f.hub.sync()).assertTrue();
      c.ensureLoaded();
      await flush();
      expect(f.listRequests().length).assertEqual(requests + 1);
      expect(c.snapshot.items.length).assertEqual(2);
      expect(c.ticketValid(ticket)).assertFalse();
      expect(c.ticketValid(c.renderTicket(c.snapshot.items[0]))).assertTrue();
      f.hub.reset();
    });

    it('C_O2_detail_retry_in_window_does_not_rebind_and_replace_row_needs_same_scope', 0, async () => {
      // 旧逻辑：OrderDetailController 构造时不取归属、fetch 每次 `boundScope = d.scope()`——窗口里对显示中的 A 详情【重试】会把它
      // 重新绑定新会话（alive() 变 true，复制等入口放行），并用新会话请求 A 的 order_id（详情请求次数断言失败）。现在构造时固定、
      // fetch 只比较：会话已变就清空显示、不发；列表只接受同一会话详情页的结果替换。
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID')], null));
      f.detailReply = (_id: string): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT);
      f.hub.sync();
      const list: OrderListController = f.listController();
      list.ensureLoaded();
      await flush();
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      expect(d.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(d.alive()).assertTrue();
      const sentScope: string = d.ownerScope;
      const before: number = f.rig.server.count('/v1/orders/O1');

      f.scopeKey = 'scope-2';
      expect(d.retry()).assertTrue();
      await flush();
      expect(f.rig.server.count('/v1/orders/O1')).assertEqual(before);
      expect(d.alive()).assertFalse();
      expect(d.ownerScope).assertEqual(sentScope);
      expect(d.snapshot.phase).assertEqual(OrderPhase.IDLE);
      // 别的会话的详情结果不能替换列表行
      expect(f.hub.sync()).assertTrue();
      list.ensureLoaded();
      await flush();
      expect(list.replaceRow(rec(detail('O1', '"order_no":"1"')), sentScope)).assertFalse();
      expect(list.replaceRow(rec(detail('O1', '"order_no":"1"')), list.renderTicket(list.snapshot.items[0]).scope)).assertTrue();
      f.hub.reset();
    });

    it('C_O3_pending_card_dismiss_and_fetch_in_window_stay_bound_to_position_session', 0, async () => {
      // 旧逻辑：PendingTrackController.dismiss 点击时现读当前归属当作请求归属——窗口里 A 的卡被点关闭，就用新会话对 A 的 link_id 发
      // POST（关闭请求次数断言失败）；fetch 每次 `boundScope = d.scope()`，新会话的卡被拉进旧位置（拉取次数断言失败）。现在归属只在
      // 构造与会话换代通知里取得，dismiss / 开启通知 / fetch 先比较。
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      f.hub.sync();
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      const card: PendingTrackCard = p.snapshot.cards[0];
      const fetches: number = f.rig.server.count('/v1/orders/pending-tracks');
      const dismissals: number = f.rig.server.count('/dismiss');

      f.scopeKey = 'scope-2';
      expect(p.dismiss(card)).assertFalse();
      expect(p.enableNotification(card)).assertFalse();
      p.fetch(null);
      await flush();
      expect(f.rig.server.count('/dismiss')).assertEqual(dismissals);
      expect(f.rig.server.count('/v1/orders/pending-tracks')).assertEqual(fetches);
      expect(p.snapshot.cards.length).assertEqual(0);
      expect(f.pushRequests).assertEqual(0);

      // 清空通知执行后按新会话照常拉、照常关闭（不误伤）
      expect(f.hub.sync()).assertTrue();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      expect(p.dismiss(p.snapshot.cards[0])).assertTrue();
      await flush();
      expect(f.rig.server.count('/dismiss')).assertEqual(dismissals + 1);
      p.leave();
      f.hub.reset();
    });

    it('APP08_46_pending_card_ticket_voided_when_leaving_position_and_not_revived', 0, async () => {
      // 共性第 46 条（Android FU R1-04）：自购 → 分享 → 自购后执行旧卡片回调。鸿蒙卡片编号只增不减（新拉到相同 link_id / attempt_id
      // 也是新编号），旧逻辑离开显示位置不作废：切到分享子 Tab 时卡片仍是当前卡，旧回调照常发关闭（vacate 后 dismiss 为 true 会失败）。
      // 现在离开位置（PendingTrackArea 的 onDisAppear）同步作废卡片与在途拉取；回来（onAppear）重新拉到的是新编号卡片。
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      f.hub.sync();
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      const old: PendingTrackCard = p.snapshot.cards[0];
      // 切到分享子 Tab
      p.vacate();
      expect(p.snapshot.cards.length).assertEqual(0);
      expect(p.dismiss(old)).assertFalse();
      expect(p.claim(old)).assertFalse();
      // 切回自购：重新拉到同一尝试
      p.reoccupy();
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      const fresh: PendingTrackCard = p.snapshot.cards[0];
      expect(fresh.linkId).assertEqual(old.linkId);
      expect(fresh.attemptId).assertEqual(old.attemptId);
      expect(fresh.id !== old.id).assertTrue();
      const dismissals: number = f.rig.server.count('/dismiss');
      expect(p.dismiss(old)).assertFalse();
      expect(f.rig.server.count('/dismiss')).assertEqual(dismissals);
      expect(p.dismiss(fresh)).assertTrue();
      // 离开位置时在途的拉取作废：结果回来也不把卡放回去
      f.pendingReply = (): TransportResponse | null => null;
      p.reoccupy();
      p.vacate();
      p.reoccupy();
      p.vacate();
      for (const h of f.held) {
        h.resolve(envelope(0, '{"items":[' + pending('L4', 'a4', 'taobao', true, false) + ']}'));
      }
      await flush();
      expect(p.snapshot.cards.length).assertEqual(0);
      p.leave();
      f.hub.reset();
    });

    // ================================================================ 第 1 轮评审修复（R1-01 / R1-02 / R1-03）
    it('R1_01_list_copy_old_card_after_condition_subtab_refresh_or_view_destroyed_writes_nothing', 0, async () => {
      // R1-01（S0，APP-08 共性第 41、44 条）。旧逻辑：票据只有 boundScope + sessionEpoch——换条件、切子 Tab 都不改这两项，旧卡的复制回调
      // 照常把旧 view.raw 交统一写入口（下面「换条件 / 切子 Tab / 刷新换结果」后的 writes 断言失败）；视图销毁时只置页面自己的 alive，
      // 复制回调不看它（close 之后的 writes 断言失败）。现在票据带执行器与页面实例、子 Tab、查询轮次、结果版本、订单标识与单号，
      // 页面守卫与执行器都核对通过才写。
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '3741234567890123456', 'PAID'),
        order('O2', '3741234567890123457', 'PAID')], null));
      f.hub.sync();
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      const written: string[] = [];
      const write: (item: OrderRecord) => void = (item: OrderRecord): void => {
        OrderCopy.copy(item, (text: string): Promise<boolean> => {
          written.push(text);
          return Promise.resolve(true);
        });
      };
      const pg: OrderListPage = new OrderListPage(c);
      const first: OrderRecord = c.snapshot.items[0];
      const t1: OrderRenderTicket = pg.ticket(first);
      // 当前卡照常写（不误伤）；回调带的行与票据不是同一单不写
      expect(pg.copy(t1, first, write)).assertTrue();
      expect(pg.copy(t1, c.snapshot.items[1], write)).assertFalse();
      await flush();
      expect(written.length).assertEqual(1);

      // 换条件（提交搜索词）：服务端回的仍是同一批订单，旧卡也不写
      expect(c.submitQuery('3741')).assertTrue();
      await flush();
      expect(c.snapshot.items.length).assertEqual(2);
      expect(pg.copy(t1, first, write)).assertFalse();
      expect(pg.openDetail(t1, first, (_i: OrderRecord): void => {
        written.push('open');
      })).assertFalse();
      const t2: OrderRenderTicket = pg.ticket(c.snapshot.items[0]);
      // 切到分享子 Tab 再切回：旧卡（t2）不写
      expect(c.setScope('share')).assertTrue();
      await flush();
      expect(pg.copy(t2, first, write)).assertFalse();
      expect(c.setScope('self')).assertTrue();
      await flush();
      expect(pg.copy(t2, first, write)).assertFalse();
      expect(pg.copy(t1, first, write)).assertFalse();
      // 下拉刷新：刷新中重新签发的票据，结果整体换掉之后也失效（结果版本）
      expect(c.refresh()).assertTrue();
      const during: OrderRenderTicket = pg.ticket(c.snapshot.items[0]);
      expect(c.ticketValid(during, c.snapshot.items[0])).assertTrue();
      await flush();
      expect(pg.copy(during, first, write)).assertFalse();
      // 同一行单号变了（详情回填）：旧卡不写
      const t3: OrderRenderTicket = pg.ticket(c.snapshot.items[0]);
      expect(c.replaceRow(rec(detail('O1', '"order_no":"3741234567890999999"')))).assertTrue();
      expect(pg.copy(t3, first, write)).assertFalse();
      // 视图销毁：本页签发的、此刻其余条件都满足的票据也不写；新页面实例不接受旧页面的票据
      const t4: OrderRenderTicket = pg.ticket(c.snapshot.items[1]);
      expect(pg.valid(t4, c.snapshot.items[1])).assertTrue();
      pg.close();
      expect(pg.copy(t4, c.snapshot.items[1], write)).assertFalse();
      const pg2: OrderListPage = new OrderListPage(c);
      expect(pg2.copy(t4, c.snapshot.items[1], write)).assertFalse();
      expect(pg2.copy(pg2.ticket(c.snapshot.items[1]), c.snapshot.items[1], write)).assertTrue();
      await flush();
      expect(written.length).assertEqual(2);
      expect(written[1]).assertEqual('3741234567890123457');
      f.hub.reset();
    });

    it('R1_01b_detail_copy_checks_page_and_shown_order_number', 0, async () => {
      // 详情复制顺带核对（R1-01）：旧逻辑只看 alive()，回调带的行与正在显示的详情不是同一单 / 单号变了也照常写。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      const shown: OrderRecord = d.snapshot.detail as OrderRecord;
      expect(d.copyValid(shown)).assertTrue();
      expect(d.copyValid(rec(detail('O1', '"order_no":"2"')))).assertFalse();
      expect(d.copyValid(rec(detail('O2', '"order_no":"1"')))).assertFalse();
      f.scopeKey = 'scope-2';
      expect(d.copyValid(shown)).assertFalse();
      f.scopeKey = 'scope-1';
      d.leave();
      expect(d.copyValid(shown)).assertFalse();
      f.hub.reset();
    });

    it('R1_02_main_tab_switch_through_shell_signal_vacates_list_pending_card', 0, async () => {
      // R1-02（S1，共性第 46 条）。旧逻辑只在 PendingTrackArea.onDisAppear 作废；切主 Tab 时 Tab 根只设为不可见、不卸载，原卡仍在
      // snapshot.cards 里，保留的关闭 / 通知回调照常通过（下面切到「我的」后 cards 为 0、dismiss 为 false 的断言失败）。现在走与 AppOrders
      // 相同的接线：PendingTrackPosition.onTab 订阅 ShellState.showRoot 发出的 TabSwitchSignal；导航栈盖住同样作废；回来取新的位置世代。
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      f.hub.sync();
      const signal: TabSwitchSignal = new TabSwitchSignal('Home');
      const p: PendingTrackController = f.pendingController();
      const pos: PendingTrackPosition = PendingTrackPosition.onTab(p, 'OrderList', signal);
      pos.areaAppeared();
      signal.change('OrderList');
      expect(pos.visible).assertTrue();
      p.fetch(null);
      await flush();
      const old: PendingTrackCard = p.snapshot.cards[0];
      expect(old.notificationRow).assertTrue();
      const dismissals: number = f.rig.server.count('/dismiss');

      // 切到「我的」（AppShell 保留订单根节点，不触发 onDisAppear）
      signal.change('Me');
      expect(pos.visible).assertFalse();
      expect(p.snapshot.cards.length).assertEqual(0);
      expect(p.dismiss(old)).assertFalse();
      expect(p.enableNotification(old)).assertFalse();
      expect(p.claim(old)).assertFalse();
      // 切回订单 Tab：由 Tab 显示入口（AppOrders.showTab → loadTab）拉，拉到同一尝试也是新编号
      signal.change('OrderList');
      p.fetch(null);
      await flush();
      const fresh: PendingTrackCard = p.snapshot.cards[0];
      expect(fresh.attemptId).assertEqual(old.attemptId);
      expect(fresh.id !== old.id).assertTrue();
      expect(p.dismiss(old)).assertFalse();
      expect(p.enableNotification(old)).assertFalse();
      expect(f.rig.server.count('/dismiss')).assertEqual(dismissals);
      expect(f.pushRequests).assertEqual(0);

      // 被详情页盖住（导航栈非空，AppOrders.stackChanged）→ 作废；回到栈底 → 位置自己重拉、新编号
      pos.setCovered(true);
      expect(p.snapshot.cards.length).assertEqual(0);
      expect(p.dismiss(fresh)).assertFalse();
      pos.setCovered(false);
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      const back: PendingTrackCard = p.snapshot.cards[0];
      expect(back.id !== fresh.id).assertTrue();
      expect(p.dismiss(fresh)).assertFalse();
      expect(f.rig.server.count('/dismiss')).assertEqual(dismissals);
      // 不误伤：当前卡照常关闭
      expect(p.dismiss(back)).assertTrue();
      await flush();
      expect(f.rig.server.count('/dismiss')).assertEqual(dismissals + 1);
      pos.release();
      p.leave();
      f.hub.reset();
    });

    it('R1_03_queued_push_permit_dies_when_position_left_card_gone_or_same_attempt_reappears', 0, async () => {
      // R1-03（S1，共性第 42、46 条）。旧逻辑：交给共享 PermissionRequester 的许可只看 left 与会话归属——在队列里等待期间离开显示位置、
      // 原卡被重拉清掉或换成同一 attempt 的新卡，出队后仍调系统权限申请（下面三种扰动的 system 断言为 1，失败）。现在许可捕获不可变的
      // 位置世代与原卡编号，出队与调系统接口前都核对，旧许可永久失效。
      const disturbances: string[] = ['vacate', 'gone', 'same_attempt', 'vacate_and_back', 'none'];
      const expected: number[] = [0, 0, 0, 0, 1];
      for (let i: number = 0; i < disturbances.length; i++) {
        const f: OrderFixture = new OrderFixture();
        let system: number = 0;
        let releaseBlocker: (v: string) => void = (_v: string): void => {
        };
        const blocker: Promise<string> = new Promise<string>((resolve: (v: string) => void): void => {
          releaseBlocker = resolve;
        });
        const requester: PermissionRequester = new PermissionRequester((): string | null => null,
          (_v: string | null): void => {
          }, (): number => f.nowMs, 'harmony', (_p: string): string => 'not_asked',
          (_purpose: string, _cont: string | null): Promise<void> => Promise.resolve(),
          (perm: string): Promise<string> => {
            if (perm === PermissionTypeRaw.PUSH) {
              system++;
              return Promise.resolve('granted');
            }
            return blocker;
          }, (_m: string | null, _b: string): void => {
          });
        f.pushVia = PendingTrackDeps.pushVia((permission: string, fromSettings: boolean, valid: () => boolean,
          purposeShown: boolean): Promise<PermissionResult> => requester.request(permission, fromSettings, valid,
          purposeShown));
        f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false)
          + ']}');
        f.hub.sync();
        const p: PendingTrackController = f.pendingController();
        p.fetch(null);
        await flush();
        // 别的入口的申请占住共享队列
        const busy: Promise<PermissionResult> = requester.request(PermissionTypeRaw.PHOTOS, true, (): boolean => true, true);
        await flush();
        const card: PendingTrackCard = p.snapshot.cards[0];
        expect(p.enableNotification(card)).assertTrue();
        const d: string = disturbances[i];
        if (d === 'vacate') {
          p.vacate();
        } else if (d === 'gone') {
          f.pendingReply = (): TransportResponse => envelope(0, '{"items":[]}');
          p.fetch(null);
          await flush();
          expect(p.snapshot.cards.length).assertEqual(0);
        } else if (d === 'same_attempt') {
          p.fetch(null);
          await flush();
          expect(p.snapshot.cards[0].attemptId).assertEqual(card.attemptId);
        } else if (d === 'vacate_and_back') {
          p.vacate();
          p.reoccupy();
          await flush();
          expect(p.snapshot.cards[0].attemptId).assertEqual(card.attemptId);
        }
        releaseBlocker('denied');
        await busy;
        for (let k: number = 0; k < 6; k++) {
          await flush();
        }
        expect(system).assertEqual(expected[i]);
        p.leave();
        f.hub.reset();
      }
    });

    it('C_O4_page_state_persist_tagged_with_fixed_owner_and_reset_failure_blocks_restore', 0, async () => {
      // 旧逻辑：OrderPageRestorer.persist 在写盘时现读当前账号打标签——窗口里旧列表的条件（含完整订单号搜索词）被记到新账号名下
      // （stored 的账号标签为 user-2，断言失败）；reset 删不掉时不记待清理，本进程内仍按旧记录恢复（同账号重登恢复出旧搜索词）。现在标签
      // 用恢复决策 / 会话换代时固定的账号，列表不属于当前会话或当前账号不是它就不写；reset 删不掉记 wipePending。
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      let stored: string | null = null;
      let failDelete: boolean = false;
      let current: string | null = 'user-1';
      const restorer: OrderPageRestorer = new OrderPageRestorer((): string | null => stored,
        (value: string | null): void => {
          if (value === null && failDelete) {
            throw new Error('delete failed');
          }
          stored = value;
        }, (): string | null => current, new OrderAnchorKeeper());
      const list: OrderListController = f.listController();
      restorer.restore(list, null);
      list.submitQuery('2026101288886666');
      await flush();
      restorer.persist(list);
      expect(OrderPageState.decode(stored)?.account).assertEqual(OrderStaleCache.accountTag('user-1'));
      // 窗口：新账号令牌已保存，清空通知还没到
      current = 'user-2';
      f.account = 'user-2';
      f.scopeKey = 'scope-2';
      stored = null;
      restorer.persist(list);
      expect(stored).assertNull();
      // 清空通知：删记录失败——同账号（user-2）的恢复也不按这份记录
      f.hub.sync();
      const cond: OrderListConditions = new OrderListConditions();
      cond.q = '2026101288886666';
      stored = new OrderPageState(OrderStaleCache.accountTag('user-2'), cond.encode(), 'O1', '').encode();
      failDelete = true;
      restorer.reset();
      failDelete = false;
      const list2: OrderListController = f.listController();
      restorer.restore(list2, null);
      expect(list2.conditions().q).assertNull();
      expect(stored).assertNull();
      f.hub.reset();
    });

    it('R2_01_order_input_callbacks_kept_from_old_render_write_nothing_after_account_switch_and_page_update', 0,
      async () => {
      // R2-01（S0，APP-08 共性第 47 条、APP-09 第 63 条）。旧逻辑：搜索框 onChange 直接 `model.inputText = value`，提交 / 清空 /
      // 子 Tab / 分组 / 平台 / 月份回调直接调执行器——resetForSession 已把同一个执行器绑到 B，保留下来的 A 页面旧回调照常把 A 的完整订单号
      // 写进 B 的页面模型、以 B 的会话发搜索，apply → onPersist 又记到 B 名下（下面 model.inputText、请求 q、stored 的断言失败）。现在
      // 回调只经渲染时签发的 OrderInputHandlers（页面编号 + 执行器实例 + 会话归属与世代），执行前核对，不通过零写入。
      const f: OrderFixture = new OrderFixture();
      const queries: string[] = [];
      f.list = (q: string): TransportResponse => {
        queries.push(q);
        return envelope(0, page([order('O1', '3741234567890123456', 'PAID')], null));
      };
      f.hub.sync();
      let account: string | null = 'user-1';
      let stored: string | null = null;
      const restorer: OrderPageRestorer = new OrderPageRestorer((): string | null => stored,
        (value: string | null): void => {
          stored = value;
        }, (): string | null => account, new OrderAnchorKeeper());
      const c: OrderListController = f.listController();
      // 页面：与 OrderListView 相同的接线——aboutToAppear 签发一份输入回调；每次快照 apply，会话世代变了清输入框、关半屏并换新一份；
      // 末尾 onPersist。
      const pg: OrderListPage = new OrderListPage(c);
      const model: InputModel = new InputModel();
      let rendered: OrderInputHandlers = pg.inputs(model);
      let shownEpoch: number = c.snapshot.sessionEpoch;
      c.onChange = (s: OrderListSnapshot): void => {
        if (s.sessionEpoch !== shownEpoch) {
          shownEpoch = s.sessionEpoch;
          model.inputText = '';
          model.platformSheet = false;
          model.monthSheet = false;
          rendered = pg.inputs(model);
        }
        restorer.persist(c);
      };
      restorer.restore(c, null);
      c.ensureLoaded();
      await flush();
      // A 的页面照常输入、提交（不误伤）
      const oldA: OrderInputHandlers = rendered;
      expect(oldA.change('3741234567890123456')).assertTrue();
      expect(oldA.submit()).assertTrue();
      await flush();
      expect(queries[queries.length - 1].indexOf('3741234567890123456') >= 0).assertTrue();
      expect(oldA.clear()).assertTrue();
      await flush();
      const before: number = queries.length;

      // 窗口：B 的令牌已保存，清空通知还没到——A 的回调已不通过
      account = 'user-2';
      f.account = 'user-2';
      f.scopeKey = 'scope-2';
      const secret: string = '2026101288886666';
      expect(oldA.change(secret)).assertFalse();
      expect(model.inputText).assertEqual('');
      expect(oldA.submit()).assertFalse();
      // 清空通知：同一个执行器绑到 B，页面 apply 换新一份回调
      f.hub.sync();
      restorer.reset();
      await flush();
      expect(rendered === oldA).assertFalse();
      // 保留的 A 页面旧回调逐个执行：输入、提交、清空、子 Tab、分组、平台 / 月份半屏全部零写入、零请求
      expect(oldA.change(secret)).assertFalse();
      expect(model.inputText).assertEqual('');
      model.inputText = secret;
      expect(oldA.submit()).assertFalse();
      expect(oldA.clear()).assertFalse();
      expect(model.inputText).assertEqual(secret);
      model.inputText = '';
      expect(oldA.scope('share')).assertFalse();
      expect(oldA.group(OrderStatusGroup.ALL_GROUPS[1])).assertFalse();
      expect(oldA.openSheet('platform')).assertFalse();
      expect(oldA.openSheet('month')).assertFalse();
      expect(model.platformSheet || model.monthSheet).assertFalse();
      expect(oldA.platform(OrderPlatformOptions.PLATFORMS[0])).assertFalse();
      expect(oldA.month('2026-09')).assertFalse();
      await flush();
      expect(queries.length).assertEqual(before);
      const q: OrderListConditions = c.conditions();
      expect(q.q).assertNull();
      expect(q.scope).assertEqual('self');
      expect(q.group).assertEqual(OrderStatusGroup.ALL);
      expect(q.platform).assertNull();
      expect(q.month).assertNull();
      expect(stored === null || (stored as string).indexOf(secret) < 0).assertTrue();

      // B 的新回调照常（不误伤）：输入、提交、筛选都生效并按 B 持久化
      const curB: OrderInputHandlers = rendered;
      expect(curB.change('3741000011112222')).assertTrue();
      expect(curB.submit()).assertTrue();
      await flush();
      expect(queries[queries.length - 1].indexOf('3741000011112222') >= 0).assertTrue();
      expect(curB.openSheet('platform')).assertTrue();
      expect(curB.platform(OrderPlatformOptions.PLATFORMS[0])).assertTrue();
      expect(model.platformSheet).assertFalse();
      await flush();
      expect(OrderPageState.decode(stored)?.account).assertEqual(OrderStaleCache.accountTag('user-2'));
      // 同一个执行器、另一个页面实例（旧页面已销毁）：旧页面签发的回调不通过
      pg.close();
      expect(curB.change('x')).assertFalse();
      expect(curB.group(OrderStatusGroup.ALL_GROUPS[1])).assertFalse();
      const pg2: OrderListPage = new OrderListPage(c);
      expect(pg2.inputValid(curB.stamp)).assertFalse();
      expect(pg2.inputs(model).change('y')).assertTrue();
      f.hub.reset();
    });

    it('R2_02_page_state_write_flushes_synchronously_and_failure_is_not_saved', 0, async () => {
      // R2-02（S1，APP-08 共性第 40、48 条）。旧逻辑：生产适配层 put 是 putSync 后 flush() 异步、空 catch，OrderPageStateStore.write 也
      // 吞掉写入异常——落盘失败时上层照样当作已保存（save 返回 SAVED 断言失败），本进程内还按内存里的新记录恢复。现在适配层写入后
      // flushSync，失败照常抛出；store.write 不再吞；restorer.save 返回 FAILED 并记待清理，恢复前先重试删除、不按记录恢复。
      const prefs: FakePrefs = new FakePrefs();
      const key: string = 'orders.page_state';
      const store: OrderPageStateStore = new OrderPageStateStore((): OrderPageStateKv | null => prefs.kv(), key);
      const restorer: OrderPageRestorer = new OrderPageRestorer((): string | null => store.read(),
        (value: string | null): void => store.write(value), (): string | null => 'user-1', new OrderAnchorKeeper());
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const list: OrderListController = f.listController();
      restorer.restore(list, null);
      list.submitQuery('3741234567890123456');
      await flush();
      // 落盘成功：SAVED，磁盘上就是这份
      expect(restorer.save(list)).assertEqual(OrderPersistResult.SAVED);
      expect((prefs.disk.get(key) ?? '').indexOf('3741234567890123456') >= 0).assertTrue();
      expect(restorer.unconfirmed).assertFalse();
      // 落盘失败：生产适配层与 store 都抛出；restorer 返回 FAILED、记待清理
      prefs.failFlush = true;
      let threw: boolean = false;
      try {
        prefs.kv().put('probe', 'v');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      threw = false;
      try {
        store.write('x');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      list.submitQuery('2026101288886666');
      await flush();
      expect(restorer.save(list)).assertEqual(OrderPersistResult.FAILED);
      expect(restorer.unconfirmed).assertTrue();
      expect((prefs.disk.get(key) ?? '').indexOf('2026101288886666') >= 0).assertFalse();
      // 本进程内恢复：内存里虽有新记录，也不按它恢复（先重试删除，仍失败则保持待清理）
      const list2: OrderListController = f.listController();
      restorer.restore(list2, null);
      expect(list2.conditions().q).assertNull();
      expect(restorer.unconfirmed).assertTrue();
      // 存储恢复：下一次恢复前删除确认落盘，之后正常写入
      prefs.failFlush = false;
      const list3: OrderListController = f.listController();
      restorer.restore(list3, null);
      expect(list3.conditions().q).assertNull();
      expect(restorer.unconfirmed).assertFalse();
      expect(prefs.disk.has(key)).assertFalse();
      expect(restorer.save(list3)).assertEqual(OrderPersistResult.SAVED);
      expect(prefs.disk.has(key)).assertTrue();
      f.hub.reset();
    });

    // ================================================================ 我的
    it('C_M1_me_tab_identity_comes_with_data_and_run_does_not_rebind_in_window', 0, async () => {
      // 旧逻辑：MeTabView.apply 每次通知现读 `config.identity()`（当前会话）——窗口里任一次通知（如读闸门变化）就把 B 的身份配给 A 的
      // 资料，邀请码复制按 B 的身份通过核对（快照 identity 应保持 A，旧逻辑没有这个同源字段）；MeTabController.run 发现会话变化就
      // `boundScope = d.scope()` 并用新会话发 getMe（请求次数断言失败）。现在身份由执行器与资料一起写入快照；run 不重绑、不发，清掉
      // 已显示的旧资料，等清空通知重建。
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const tab: MeTabController = new MeTabController(f.deps());
      tab.load();
      await settle();
      expect(tab.snapshot.me !== null).assertTrue();
      const shown: string = tab.snapshot.identity;
      expect(shown).assertEqual(f.scope());
      const reads: number = f.count('/v1/me');

      f.tokens.save(new SessionTokenSet('access-user-2-b', 'refresh-user-2-b', 'full', 'user-2'));
      f.client.onSessionChanged();
      expect(f.scope() !== shown).assertTrue();
      // 读闸门变化触发一次通知：快照身份仍是数据所属的会话
      f.session.readGate.start(1000);
      expect(tab.snapshot.identity).assertEqual(shown);
      f.session.readGate.reset();
      tab.load();
      await settle();
      expect(f.count('/v1/me')).assertEqual(reads);
      expect(tab.snapshot.me === null).assertTrue();
      expect(tab.snapshot.identity).assertEqual(shown);

      // 清空通知后：按新会话重建并读取（不误伤）
      f.session.sync();
      expect(tab.snapshot.identity).assertEqual(f.scope());
      tab.load();
      await settle();
      expect(f.count('/v1/me')).assertEqual(reads + 1);
      expect(tab.snapshot.me !== null).assertTrue();
    });

    it('C_M2_privacy_center_old_instance_does_not_take_new_session_level', 0, async () => {
      // 旧逻辑：refreshLevel 现读当前档位——会话已变、IdentityBoundSlot 还没换实例时，旧隐私中心显示新会话的档位（GUEST 断言失败）。
      const f: MeFixture = new MeFixture();
      f.session.sync();
      const p: PrivacyCenterController = new PrivacyCenterController(f.deps(), new Ports(), meStore());
      expect(p.snapshot.level).assertEqual(MeLevel.MEMBER);
      f.tokens.save(new SessionTokenSet('access-user-2-b', 'refresh-user-2-b', 'full', 'user-2'));
      f.client.onSessionChanged();
      f.level = MeLevel.GUEST;
      p.refreshLevel();
      expect(p.snapshot.level).assertEqual(MeLevel.MEMBER);
    });

    // ================================================================ F-HM-24
    it('F_HM_24_withdraw_in_flight_survives_controller_rebuild_and_blocks_second_start', 0, async () => {
      // APP-12 定向复核 RC-01：旧逻辑撤回进行中只记在控制器实例上——撤回在途时会话失效、隐私中心按新归属重建，新实例 withdrawing=false，
      // 可再次确认撤回（第二次 /v1/consents、第二次本地清理），个性化开关也能在途修改。现在进行中状态在应用级 PrivacyWithdrawOutcomes：
      // 新实例继承忙状态，完成前拒绝重复启动与个性化修改；旧实例的撤回走完后同步解除，新实例之后可正常操作。
      const f: MeFixture = new MeFixture();
      f.reply('/v1/consents', (_r: TransportRequest) => null);
      const ports: Ports = new Ports();
      const outcomes: PrivacyWithdrawOutcomes = new PrivacyWithdrawOutcomes();
      const prefs: MeLocalStore = meStore();
      const slot: IdentityBoundSlot<PrivacyCenterController> = new IdentityBoundSlot<PrivacyCenterController>(
        (): PrivacyCenterController => new PrivacyCenterController(f.deps(), ports, prefs, outcomes),
        (): string => f.scope());
      f.session.subscribe((): void => {
        slot.sync();
      });
      f.session.sync();
      slot.shown();
      const a: PrivacyCenterController = slot.current;
      const done: Promise<boolean> = a.withdraw(a.identity, a.withdrawPermit());
      await settle();
      expect(f.count('/v1/consents')).assertEqual(1);
      expect(outcomes.inFlight).assertTrue();
      // 撤回在途：会话失效（别的请求 10404 清掉会话）→ 状态同步 → 隐私中心按新归属重建为游客实例
      f.tokens.clear();
      f.client.onSessionChanged();
      f.level = MeLevel.GUEST;
      f.session.sync();
      slot.shown();
      const b: PrivacyCenterController = slot.current;
      expect(b !== a).assertTrue();
      expect(b.snapshot.withdrawing).assertTrue();
      expect(await b.withdraw(b.identity, b.withdrawPermit())).assertFalse();
      b.setPersonalization(false, b.identity);
      expect(prefs.personalizationOn()).assertTrue();
      expect(f.count('/v1/consents')).assertEqual(1);
      expect(ports.withdrawn).assertEqual(0);
      // 第一次撤回结束（旧请求按原归属作废，本地撤回照常完成一次）：新实例同步解除忙状态
      for (const h of f.held) {
        h.resolve(envelope(0, '{}'));
      }
      expect(await done).assertTrue();
      expect(ports.withdrawn).assertEqual(1);
      expect(outcomes.inFlight).assertFalse();
      expect(b.snapshot.withdrawing).assertFalse();
      // 之后新实例可以照常撤回（不误伤）
      f.reply('/v1/consents', (_r: TransportRequest) => envelope(0, '{}'));
      expect(await b.withdraw(b.identity, b.withdrawPermit())).assertTrue();
      expect(ports.withdrawn).assertEqual(2);
    });
  });
}
