// APP-08 鸿蒙评审第 3 轮（harmony-review-r3.md R3-01..04）与共性第 23–26 条：真实 ApiClient + 本地假服务（OrderFixture）。
import { describe, it, expect } from '@ohos/hypium';
import {
  OrderAnchorKeeper, OrderCacheEntry, OrderDetailController, OrderJson, OrderListConditions, OrderListController, OrderListSnapshot,
  OrderPageRestorer, OrderPageState, OrderPhase, OrderRecord, OrderScrollAnchor, OrderStaleCache, PendingTrackCard,
  PendingTrackController,
  TransportFailure, TransportResponse
} from '../../Index';
import { envelope, flush } from './NetworkTestRig';
import { detail, OrderFixture, order, page, pending, rec } from './OrderIntegration.test';

/** 内存里的页面状态偏好（AppOrders 的 orders.page_state）。 */
class MemoryPageState {
  value: string | null = null;
  writes: number = 0;

  read(): string | null {
    return this.value;
  }

  write(value: string | null): void {
    this.value = value;
    this.writes++;
  }

  decoded(): OrderPageState {
    return OrderPageState.decode(this.value) as OrderPageState;
  }
}

export default function orderReviewR3Test() {
  describe('OrderReviewR3', () => {
    // ---------------------------------------------------------------- R3-01 冷启动隐藏挂载不覆盖恢复记录（共性第 23 条）
    // 旧逻辑：persistPage 不等恢复决策，隐藏挂载的 aboutToAppear → apply → onPersist 先把默认条件与空锚点写盘，
    // 之后 restoreConditions 读到的已是默认值：下面对 writes、share 条件与锚点 O3 的断言都会失败。
    it('R3_01_hidden_tab_mount_persist_before_restore_keeps_record', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID'), order('O3', '3', 'PAID')],
        null));
      const c: OrderListController = f.listController();
      const keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
      const prefs: MemoryPageState = new MemoryPageState();
      const saved: OrderListConditions = new OrderListConditions();
      saved.scope = 'share';
      saved.platform = 'taobao';
      saved.month = '2026-10';
      saved.q = '保温杯';
      prefs.value = new OrderPageState(OrderStaleCache.accountTag('user-1'), saved.encode(), 'O3', '').encode();
      const restorer: OrderPageRestorer = new OrderPageRestorer((): string | null => prefs.read(),
        (v: string | null): void => prefs.write(v), (): string | null => f.account, keeper);
      // 冷启动：AppShell 隐藏挂载订单 Tab 根（与 OrderListView 同序）——aboutToAppear 接 onChange → apply(初始快照) → onPersist
      c.onChange = (_s: OrderListSnapshot): void => restorer.persist(c);
      restorer.persist(c);
      // 页面滚动回调同样走 onPersist（隐藏期间也不写）
      expect(keeper.visible('')).assertFalse();
      restorer.persist(c);
      expect(restorer.restoreDecided).assertFalse();
      expect(prefs.writes).assertEqual(0);
      expect(prefs.decoded().anchor).assertEqual('O3');
      expect((OrderListConditions.decode(prefs.decoded().conditions) as OrderListConditions).scope).assertEqual('share');
      // 用户打开订单 Tab（ShellState.onRootShown → restoreConditions）：读到的仍是原记录
      restorer.restore(c, null);
      expect(restorer.restoreDecided).assertTrue();
      expect(c.conditions().scope).assertEqual('share');
      expect(c.conditions().platform).assertEqual('taobao');
      expect(c.conditions().month).assertEqual('2026-10');
      expect(c.conditions().q).assertEqual('保温杯');
      expect(keeper.anchor).assertEqual('O3');
      expect(keeper.frozen).assertTrue();
      // 决策完成后的持久化：恢复出的条件 + 原锚点（恢复进行中冻结）
      expect(prefs.writes > 0).assertTrue();
      expect(prefs.decoded().anchor).assertEqual('O3');
      expect(prefs.decoded().conditions).assertEqual(saved.encode());
      c.ensureLoaded();
      await flush();
      expect(f.lastListQuery().indexOf('scope=share') >= 0).assertTrue();
      expect(f.lastListQuery().indexOf('platform=taobao') >= 0).assertTrue();
      expect(f.lastListQuery().indexOf('paid_month=2026-10') >= 0).assertTrue();
      // 别的账号的记录：决策为不恢复，之后照常按当前条件写盘
      const other: MemoryPageState = new MemoryPageState();
      other.value = new OrderPageState(OrderStaleCache.accountTag('user-2'), saved.encode(), 'O3', '').encode();
      const c2: OrderListController = f.listController();
      const r2: OrderPageRestorer = new OrderPageRestorer((): string | null => other.read(),
        (v: string | null): void => other.write(v), (): string | null => f.account, new OrderAnchorKeeper());
      c2.onChange = (_s: OrderListSnapshot): void => r2.persist(c2);
      r2.persist(c2);
      expect(other.writes).assertEqual(0);
      r2.restore(c2, null);
      expect(c2.conditions().scope).assertEqual('self');
      expect(other.decoded().account).assertEqual(OrderStaleCache.accountTag('user-1'));
      expect(other.decoded().anchor).assertEqual('');
      // 会话变化：记录删除、锚点清空
      r2.reset();
      expect(other.value).assertNull();
    });

    // ---------------------------------------------------------------- R3-02 对齐延迟回调复核任务与轮次（共性第 24 条）
    // 旧逻辑：resolve 找到目标后 restore 已置空，新一轮查询时直接返回 DROPPED、不取消 aligning；旧回调照样 aligned() + 持久化，
    // 新搜索条件下保存旧锚点 O3：下面 keeper.anchor 为 '' 与 commitAlign 为 false 的断言都会失败（旧代码也没有任务编号）。
    it('R3_02_pending_align_callback_cancelled_by_new_query', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (q: string): TransportResponse => envelope(0, q.indexOf('q=') >= 0
        ? page([order('N1', '9', 'PAID')], null)
        : page([order('O1', '1', 'PAID'), order('O2', '2', 'PAID'), order('O3', '3', 'PAID')], null));
      const c: OrderListController = f.listController();
      const keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
      const persisted: string[] = [];
      const persist: () => void = (): void => {
        persisted.push(new OrderPageState('tag', c.conditions().encode(), keeper.anchor, '').encode());
      };
      const saved: OrderListConditions = new OrderListConditions();
      keeper.begin('O3', saved.encode());
      c.restore(saved, null);
      c.ensureLoaded();
      await flush();
      // 目标已加载：页面排入布局等待回调（记下任务编号）
      expect(keeper.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase, c.snapshot.round)).assertEqual(2);
      const ticket: number = keeper.ticket;
      expect(keeper.frozen).assertTrue();
      // 回调执行前提交新搜索：apply 照常 resolve，等待中的对齐被取消、锚点清空并解冻
      expect(c.submitQuery('牛奶')).assertTrue();
      expect(keeper.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase, c.snapshot.round))
        .assertEqual(OrderScrollAnchor.DROPPED);
      expect(keeper.frozen).assertFalse();
      expect(keeper.anchor).assertEqual('');
      // 旧回调执行：复核失效，不滚动、不持久化
      if (keeper.commitAlign(ticket, c.snapshot.round, c.conditions().encode())) {
        persist();
      }
      expect(persisted.length).assertEqual(0);
      await flush();
      persist();
      const last: OrderPageState = OrderPageState.decode(persisted[persisted.length - 1]) as OrderPageState;
      expect(last.anchor).assertEqual('');
      expect((OrderListConditions.decode(last.conditions) as OrderListConditions).q).assertEqual('牛奶');

      // 回调先于新快照的 resolve 执行（只有轮次变了）：commitAlign 自己发现轮次不同，取消并返回 false
      const c2: OrderListController = f.listController();
      const k2: OrderAnchorKeeper = new OrderAnchorKeeper();
      k2.begin('O3', saved.encode());
      c2.restore(saved, null);
      c2.ensureLoaded();
      await flush();
      expect(k2.resolve(c2.snapshot.items, c2.conditions().encode(), c2.snapshot.phase, c2.snapshot.round)).assertEqual(2);
      const t2: number = k2.ticket;
      expect(c2.refresh()).assertTrue();
      expect(k2.commitAlign(t2, c2.snapshot.round, c2.conditions().encode())).assertFalse();
      expect(k2.frozen).assertFalse();
      expect(k2.anchor).assertEqual('');

      // 条件不变、轮次不变：照常对齐一次（第二次同一编号无效）
      const k3: OrderAnchorKeeper = new OrderAnchorKeeper();
      const c3: OrderListController = f.listController();
      k3.begin('O3', saved.encode());
      c3.restore(saved, null);
      c3.ensureLoaded();
      await flush();
      expect(k3.resolve(c3.snapshot.items, c3.conditions().encode(), c3.snapshot.phase, c3.snapshot.round)).assertEqual(2);
      const t3: number = k3.ticket;
      expect(k3.commitAlign(t3, c3.snapshot.round, c3.conditions().encode())).assertTrue();
      expect(k3.frozen).assertFalse();
      expect(k3.anchor).assertEqual('O3');
      expect(k3.commitAlign(t3, c3.snapshot.round, c3.conditions().encode())).assertFalse();

      // 会话变化（reset）或新的恢复任务（begin）后，旧编号作废
      const k4: OrderAnchorKeeper = new OrderAnchorKeeper();
      k4.begin('O3', saved.encode());
      expect(k4.resolve(c3.snapshot.items, c3.conditions().encode(), c3.snapshot.phase, c3.snapshot.round)).assertEqual(2);
      const t4: number = k4.ticket;
      k4.reset();
      expect(k4.commitAlign(t4, c3.snapshot.round, c3.conditions().encode())).assertFalse();
      expect(k4.anchor).assertEqual('');
    });

    // ---------------------------------------------------------------- R3-03 通知行「点过」同步全部位置（共性第 25 条）
    // 旧逻辑：只有点击的那个控制器隐藏通知行，列表位置仍显示；旧按钮也不复核本机记录与系统状态：下面列表位置 notificationRow 为
    // false、复核场景 pushRequests 为 0 的断言都会失败。
    it('R3_03_push_row_used_broadcast_to_all_controllers_and_rechecked', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ','
        + pending('L2', 'b1', 'jd', false, false) + ']}');
      const list: PendingTrackController = f.pendingController();
      const product: PendingTrackController = f.pendingController();
      let listEmits: number = 0;
      list.onChange = (): void => {
        listEmits++;
      };
      list.fetch(null);
      product.fetch('taobao');
      await flush();
      expect(list.snapshot.cards.length).assertEqual(2);
      expect(list.snapshot.cards[0].notificationRow).assertTrue();
      expect(product.snapshot.cards[0].notificationRow).assertTrue();
      const rendered: PendingTrackCard = list.snapshot.cards[0];
      // 商品页点【开启通知】：列表位置（仍在栈内）立即移除全部通知行并通知页面，不等再拉
      const before: number = listEmits;
      expect(product.enableNotification(product.snapshot.cards[0])).assertTrue();
      await flush();
      expect(f.pushRequests).assertEqual(1);
      expect(f.marked).assertEqual(1);
      expect(product.snapshot.cards[0].notificationRow).assertFalse();
      expect(list.snapshot.cards[0].notificationRow).assertFalse();
      expect(list.snapshot.cards[1].notificationRow).assertFalse();
      expect(listEmits > before).assertTrue();
      // 列表页旧按钮（渲染时的卡）再点：不申请
      expect(list.enableNotification(rendered)).assertFalse();
      await flush();
      expect(f.pushRequests).assertEqual(1);
      // 新开的位置拉到的卡也不再出现
      const search: PendingTrackController = f.pendingController();
      search.fetch(null);
      await flush();
      expect(search.snapshot.cards[0].notificationRow).assertFalse();
      list.leave();
      product.leave();
      search.leave();

      // 执行前复核本机申请记录：别处已写下记录（未经广播）→ 不申请，只移除通知行
      const g: OrderFixture = new OrderFixture();
      g.pendingReply = f.pendingReply;
      const p: PendingTrackController = g.pendingController();
      p.fetch(null);
      await flush();
      expect(p.snapshot.cards[0].notificationRow).assertTrue();
      g.requestedBefore = true;
      expect(p.enableNotification(p.snapshot.cards[0])).assertFalse();
      await flush();
      expect(g.pushRequests).assertEqual(0);
      expect(p.snapshot.cards[0].notificationRow).assertFalse();
      p.leave();

      // 执行前复核系统权限：用户已在系统设置里开启 → 不申请，只移除通知行
      const h: OrderFixture = new OrderFixture();
      h.pendingReply = f.pendingReply;
      const q: PendingTrackController = h.pendingController();
      q.fetch(null);
      await flush();
      expect(q.snapshot.cards[0].notificationRow).assertTrue();
      h.notification = 'granted';
      expect(q.enableNotification(q.snapshot.cards[0])).assertFalse();
      await flush();
      expect(h.pushRequests).assertEqual(0);
      expect(h.marked).assertEqual(0);
      expect(q.snapshot.cards[0].notificationRow).assertFalse();
      q.leave();
    });

    // ---------------------------------------------------------------- R3-04 详情缓存态的刷新入口（共性第 26 条）
    // 旧逻辑：详情缓存态没有刷新入口（页面只有 Scroll 与提示条，controller.retry 只挂在 ERROR 分支），也没有刷新在途状态；
    // 本测试调用的 refreshStale / snapshot.refreshing 在旧代码里不存在，页面 Refresh 绑定的就是这两项。
    it('R3_04_detail_stale_refresh_updates_content_cache_and_banner', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.cache.saveDetail('O1', rec(detail('O1', '"order_no":"111"')));
      f.detailReply = (_id: string): TransportResponse => TransportResponse.failed(TransportFailure.TIMEOUT);
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      expect(d.snapshot.phase).assertEqual(OrderPhase.CONTENT);
      expect(d.snapshot.stale).assertTrue();
      expect(d.snapshot.refreshing).assertFalse();
      const sent: number = f.rig.server.count('/v1/orders/O1');
      // 共享 42901 禁用期内：刷新入口不可用，不发请求，缓存与提示条保留
      f.hub.gate.start(30000, null);
      expect(d.snapshot.blocked).assertTrue();
      expect(d.refreshStale()).assertFalse();
      await flush();
      expect(f.rig.server.count('/v1/orders/O1')).assertEqual(sent);
      expect(d.snapshot.stale).assertTrue();
      f.nowMs += 31000;
      // 仍断网时下拉：发一次，失败后保留缓存与提示条，转圈结束
      expect(d.refreshStale()).assertTrue();
      await flush();
      expect(f.rig.server.count('/v1/orders/O1') > sent).assertTrue();
      expect(d.snapshot.phase).assertEqual(OrderPhase.CONTENT);
      expect(d.snapshot.stale).assertTrue();
      expect(d.snapshot.refreshing).assertFalse();
      // 网络恢复：下拉刷新在途时转圈、内容与提示条保留
      f.detailReply = (_id: string): TransportResponse | null => null;
      expect(d.refreshStale()).assertTrue();
      await flush();
      expect(d.snapshot.refreshing).assertTrue();
      expect(d.snapshot.stale).assertTrue();
      expect(d.snapshot.phase).assertEqual(OrderPhase.CONTENT);
      f.held[f.held.length - 1].resolve(envelope(0, detail('O1', '"order_no":"222"')));
      await flush();
      // 成功：更新内容与缓存，移除提示条
      expect(d.snapshot.refreshing).assertFalse();
      expect(d.snapshot.stale).assertFalse();
      expect(d.snapshot.staleFetchedAt).assertEqual(0);
      expect(OrderJson.text(d.snapshot.detail as OrderRecord, 'order_no')).assertEqual('222');
      const cached: OrderCacheEntry | null = f.cache.loadDetail('O1');
      expect(cached !== null).assertTrue();
      expect(OrderJson.text((cached as OrderCacheEntry).data, 'order_no')).assertEqual('222');
      // 不再是缓存态：刷新入口关闭
      expect(d.refreshStale()).assertFalse();
      d.leave();
    });
  });
}
