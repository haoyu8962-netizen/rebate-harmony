// APP-08 鸿蒙评审第 2 轮（harmony-review-r2.md R2-01..06）与共性第 13–21 条：真实 ApiClient + 本地假服务 + 真实 Router（OrderFixture）。
import { describe, it, expect } from '@ohos/hypium';
import {
  NetworkHeaders, OrderAnchorKeeper, OrderDetailController, OrderDetailEntries, OrderDraftTexts, OrderListConditions,
  OrderListController, OrderListEntries, OrderMessages, OrderPageState, OrderPhase, OrderRecord, OrderScrollAnchor,
  OrderErrorView, PendingTrackCard, PendingTrackController, RouteDestination, RouteTable, TransportFailure,
  TransportRequest, TransportResponse
} from '../../Index';
import { Routes, RouteSpec } from 'generated';
import { Deferred, envelope, flush, header, tokenPair } from './NetworkTestRig';
import { detail, OrderFixture, order, page, pending, rec, TAB_ROOTS } from './OrderIntegration.test';

/** H5 路由的占位容器收到的地址（routes.json h5_path；共性第 22 条：真实 H5 容器未接入，见 rule-gaps H23）。 */
function h5Path(route: string): string {
  const spec: RouteSpec | undefined = RouteTable.spec(route);
  return spec === undefined || spec.h5Path === null ? '' : spec.h5Path;
}

function cardsOf(p: PendingTrackController, link: string): PendingTrackCard[] {
  return p.snapshot.cards.filter((c: PendingTrackCard): boolean => c.linkId === link);
}

export default function orderReviewR2Test() {
  describe('OrderReviewR2', () => {
    // ---------------------------------------------------------------- R2-01 共享限流覆盖每次实际发包（共性第 13 条）
    it('R2_01_backoff_retry_blocked_after_other_request_42901', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      f.rig.timer.holdBackoff = true;
      f.list = (_q: string): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT);
      f.detailReply = (_id: string): TransportResponse => TransportResponse.failed(TransportFailure.DISCONNECT);
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      // 列表、详情的 GET 都断连，进入自动重试退避（挂起）
      expect(f.listRequests().length).assertEqual(1);
      expect(f.rig.server.count('/v1/orders/O1')).assertEqual(1);
      expect(f.rig.timer.heldBackoffs).assertEqual(2);
      // 退避期间另一请求（待跟单查询）收到 42901 + Retry-After=30
      f.pendingReply = (): TransportResponse => envelope(42901, '{}', { 'Retry-After': '30' });
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(f.hub.gate.active).assertTrue();
      // 退避结束：不再发包，页面显示限流（不当成网络错误、不用缓存）
      f.rig.timer.releaseBackoffs();
      await flush();
      expect(f.listRequests().length).assertEqual(1);
      expect(f.rig.server.count('/v1/orders/O1')).assertEqual(1);
      expect(c.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(c.snapshot.error?.textKey).assertEqual('error.42901');
      expect(c.snapshot.blocked).assertTrue();
      expect(d.snapshot.phase).assertEqual(OrderPhase.ERROR);
      expect(d.snapshot.error?.textKey).assertEqual('error.42901');
      expect(d.retry()).assertFalse();
      // 到期后恢复，重试照常发
      f.rig.timer.holdBackoff = false;
      f.nowMs += 31000;
      f.list = (_q: string): TransportResponse => envelope(0, page([order('O1', '1', 'PAID')], null));
      expect(c.retry()).assertTrue();
      await flush();
      expect(f.listRequests().length).assertEqual(2);
      expect(c.snapshot.phase).assertEqual(OrderPhase.CONTENT);
      p.leave();
      d.leave();
      f.hub.reset();
    });

    it('R2_01_refresh_barrier_replay_blocked_after_dismiss_42901', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const refresh: Deferred = new Deferred();
      const dismiss: Deferred = new Deferred();
      let replayed: number = 0;
      f.rig.server.handler = (r: TransportRequest): Promise<TransportResponse> => {
        if (r.url.indexOf('/v1/auth/refresh') >= 0) {
          return refresh.promise;
        }
        if (r.url.indexOf('/dismiss') >= 0) {
          return dismiss.promise;
        }
        if (r.url.indexOf('/v1/orders/pending-tracks') >= 0) {
          return Promise.resolve(envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ']}'));
        }
        if (r.url.indexOf('/v1/orders?') >= 0) {
          if (header(r, NetworkHeaders.AUTHORIZATION) === 'Bearer new-access') {
            replayed++;
            return Promise.resolve(envelope(0, page([order('O1', '1', 'PAID')], null)));
          }
          return Promise.resolve(envelope(10002, '{}'));
        }
        return Promise.resolve(envelope(0, '{}'));
      };
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.dismiss(p.snapshot.cards[0])).assertTrue();
      await flush();
      // 列表请求 10002 → 等刷新屏障
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(f.rig.server.count('/v1/auth/refresh')).assertEqual(1);
      // 屏障期间关闭请求回 42901
      dismiss.resolve(envelope(42901, '{}', { 'Retry-After': '30' }));
      await flush();
      expect(f.hub.gate.active).assertTrue();
      // 刷新成功：重放被闸门拦下，不发包
      refresh.resolve(envelope(0, tokenPair('new-access', 'new-refresh', 'full')));
      await flush();
      await flush();
      expect(replayed).assertEqual(0);
      expect(c.snapshot.error?.textKey).assertEqual('error.42901');
      p.leave();
      f.hub.reset();
    });

    // ---------------------------------------------------------------- R2-02 关闭忙碌按 link_id + attempt_id（共性第 14 条）
    it('R2_02_close_failure_clears_busy_on_rebuilt_card', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      const first: PendingTrackCard = p.snapshot.cards[0];
      f.dismissReply = (): TransportResponse | null => null;
      expect(p.dismiss(first)).assertTrue();
      await flush();
      expect(p.snapshot.cards[0].busy).assertTrue();
      // 关闭在途时另一轮查询重建了同一尝试的卡片（新编号，仍忙碌、不能重复关闭）
      p.fetch(null);
      await flush();
      const rebuilt: PendingTrackCard = p.snapshot.cards[0];
      expect(rebuilt.id === first.id).assertFalse();
      expect(rebuilt.busy).assertTrue();
      expect(p.dismiss(rebuilt)).assertFalse();
      // 关闭失败：新卡的忙碌清掉，用户能再点
      f.held[f.held.length - 1].resolve(envelope(50001, '{}'));
      await flush();
      expect(p.snapshot.cards.length).assertEqual(1);
      expect(p.snapshot.cards[0].busy).assertFalse();
      f.dismissReply = (): TransportResponse => envelope(0, '{}');
      expect(p.dismiss(p.snapshot.cards[0])).assertTrue();
      await flush();
      expect(p.snapshot.cards.length).assertEqual(0);
    });

    // ---------------------------------------------------------------- R2-03 已关闭的尝试跨显示位置共享（共性第 15 条）
    it('R2_03_dismiss_on_product_page_not_revived_by_list_late_query', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ','
        + pending('L2', 'b1', 'jd', false, false) + ']}');
      const list: PendingTrackController = f.pendingController();
      const product: PendingTrackController = f.pendingController();
      list.fetch(null);
      product.fetch('taobao');
      await flush();
      expect(list.snapshot.cards.length).assertEqual(2);
      expect(product.snapshot.cards.length).assertEqual(1);
      // 列表位置发出的查询挂起
      f.pendingReply = (): TransportResponse | null => null;
      list.fetch(null);
      await flush();
      const late: Deferred = f.held[f.held.length - 1];
      // 商品页关闭进行中：列表位置的同一尝试同步忙碌、不能重复关闭
      f.dismissReply = (): TransportResponse | null => null;
      expect(product.dismiss(product.snapshot.cards[0])).assertTrue();
      await flush();
      expect(cardsOf(list, 'L1')[0].busy).assertTrue();
      expect(list.dismiss(cardsOf(list, 'L1')[0])).assertFalse();
      expect(f.rig.server.count('/dismiss')).assertEqual(1);
      // 商品页关闭成功：两个位置都移除 A
      f.held[f.held.length - 1].resolve(envelope(0, '{}'));
      await flush();
      expect(product.snapshot.cards.length).assertEqual(0);
      expect(cardsOf(list, 'L1').length).assertEqual(0);
      // 列表此前的查询迟到（A 仍是 dismissed=false）：不复活 A，B 照常
      late.resolve(envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ','
        + pending('L2', 'b1', 'jd', false, false) + ']}'));
      await flush();
      expect(cardsOf(list, 'L1').length).assertEqual(0);
      expect(cardsOf(list, 'L2').length).assertEqual(1);
      // 同平台的新尝试不受影响
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a2', 'taobao', false, false) + ']}');
      list.fetch(null);
      product.fetch('taobao');
      await flush();
      expect(cardsOf(list, 'L1')[0].attemptId).assertEqual('a2');
      expect(product.snapshot.cards[0].attemptId).assertEqual('a2');
      // 会话变化清空登记
      f.hub.reset();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ']}');
      list.fetch(null);
      await flush();
      expect(cardsOf(list, 'L1')[0].attemptId).assertEqual('a1');
      list.leave();
      product.leave();
    });

    // ---------------------------------------------------------------- R2-04 trace6 独立追加（共性第 8、9、16 条）
    it('R2_04_dismiss_50301_50303_toast_has_trace6_without_placeholder', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L1', 'a1', 'taobao', false, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      const codes: number[] = [50301, 50303];
      for (const code of codes) {
        f.dismissReply = (): TransportResponse => envelope(code, 'null');
        expect(p.dismiss(p.snapshot.cards[0])).assertTrue();
        await flush();
        const key: string = p.snapshot.toastKey as string;
        expect(key).assertEqual('error.' + code);
        // 已收录、文案里没有 {trace6} 占位
        expect(OrderDraftTexts.text(key).length > 0).assertTrue();
        expect(OrderDraftTexts.text(key).indexOf('{trace6}') < 0).assertTrue();
        // App 显示的轻提示文字（AppOrders.toast 用同一函数）带 trace6
        const text: string = PendingTrackController.toastText(key, p.snapshot.toastTrace);
        expect(text.indexOf('123456') >= 0).assertTrue();
        // 正文是对应错误文案（50301 的 {platform_name} 缺值时按契约 fallback），trace6 追加在末尾
        expect(text).assertEqual(OrderDraftTexts.format(key, new Map<string, string>()) + '（123456）');
      }
      // 传输失败：网络错误、无 trace
      f.dismissReply = (): TransportResponse => TransportResponse.failed(TransportFailure.TIMEOUT);
      p.dismiss(p.snapshot.cards[0]);
      await flush();
      expect(p.snapshot.toastKey).assertEqual('order.network_error');
      expect(PendingTrackController.toastText('order.network_error', p.snapshot.toastTrace).indexOf('（')).assertEqual(-1);
      // 列表首屏、翻页、详情的错误正文同一函数（50303 无占位也带 trace6）
      f.list = (_q: string): TransportResponse => envelope(50303, 'null');
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      expect(c.snapshot.error !== null).assertTrue();
      const e: OrderErrorView = c.snapshot.error as OrderErrorView;
      const listText: string = OrderMessages.compose((k: string, v: Map<string, string>): string =>
      OrderDraftTexts.format(k, v), e.textKey, e.traceId, e.showTrace6);
      expect(listText.indexOf('123456') >= 0).assertTrue();
      f.detailReply = (_id: string): TransportResponse => envelope(50301, 'null');
      const d: OrderDetailController = f.detailController();
      d.load('O1');
      await flush();
      const de: OrderErrorView = d.snapshot.error as OrderErrorView;
      expect(OrderMessages.compose((k: string, v: Map<string, string>): string => OrderDraftTexts.format(k, v),
        de.textKey, de.traceId, de.showTrace6).indexOf('123456') >= 0).assertTrue();
      d.leave();
    });

    // ---------------------------------------------------------------- R2-05 恢复中保留锚点（共性第 10、17、21 条）
    it('R2_05_restore_in_progress_keeps_anchor_across_second_recycle', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.list = (q: string): TransportResponse => q.indexOf('cursor=c2') >= 0
        ? envelope(0, page([order('O39', '39', 'PAID'), order('O40', '40', 'PAID')], null))
        : envelope(0, page([order('O1', '1', 'PAID'), order('O2', '2', 'PAID')], 'c2'));
      const c: OrderListController = f.listController();
      const saved: OrderListConditions = new OrderListConditions();
      const keeper: OrderAnchorKeeper = new OrderAnchorKeeper();
      // 与 AppOrders.restoreConditions 同序：先装锚点，再装条件
      keeper.begin('O40', saved.encode());
      c.restore(saved, null);
      const persist: () => string = (): string => new OrderPageState('tag', c.conditions().encode(), keeper.anchor, '').encode();
      c.ensureLoaded();
      expect(keeper.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase, c.snapshot.round))
        .assertEqual(OrderScrollAnchor.WAIT);
      await flush();
      // 第一页到了、目标在第二页：继续等；首屏的滚动回调不覆盖
      expect(keeper.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase, c.snapshot.round))
        .assertEqual(OrderScrollAnchor.WAIT);
      expect(keeper.visible('O1')).assertFalse();
      expect(keeper.frozen).assertTrue();
      const written: string = persist();
      expect((OrderPageState.decode(written) as OrderPageState).anchor).assertEqual('O40');
      // 此时进程再次回收：下次仍按 O40 恢复
      const again: OrderAnchorKeeper = new OrderAnchorKeeper();
      const state: OrderPageState = OrderPageState.decode(written) as OrderPageState;
      again.begin(state.anchor, state.conditions);
      expect(again.anchor).assertEqual('O40');
      expect(again.frozen).assertTrue();
      // 翻页加载到目标：返回下标，对齐完成前仍冻结
      c.loadMore();
      await flush();
      expect(keeper.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase, c.snapshot.round)).assertEqual(3);
      expect(keeper.visible('O1')).assertFalse();
      expect((OrderPageState.decode(persist()) as OrderPageState).anchor).assertEqual('O40');
      keeper.aligned();
      expect(keeper.visible('O39')).assertTrue();
      expect(keeper.anchor).assertEqual('O39');
      // 共性第 21 条：恢复等待期间用户换筛选 → 取消旧恢复，锚点清空，不用旧条件覆盖新条件
      const k2: OrderAnchorKeeper = new OrderAnchorKeeper();
      k2.begin('O40', c.conditions().encode());
      expect(k2.resolve(c.snapshot.items.slice(0, 2), c.conditions().encode(), c.snapshot.phase, c.snapshot.round))
        .assertEqual(OrderScrollAnchor.WAIT);
      c.setGroup('credited');
      expect(k2.resolve(c.snapshot.items, c.conditions().encode(), c.snapshot.phase, c.snapshot.round))
        .assertEqual(OrderScrollAnchor.DROPPED);
      expect(k2.frozen).assertFalse();
      expect(k2.anchor).assertEqual('');
      expect(c.conditions().group).assertEqual('credited');
      // 首屏失败放弃恢复（H20）：解冻但保留原锚点
      const k3: OrderAnchorKeeper = new OrderAnchorKeeper();
      k3.begin('O40', c.conditions().encode());
      expect(k3.resolve([], c.conditions().encode(), OrderPhase.ERROR, c.snapshot.round)).assertEqual(OrderScrollAnchor.DROPPED);
      expect(k3.frozen).assertFalse();
      expect(k3.anchor).assertEqual('O40');
    });

    // ---------------------------------------------------------------- 共性第 19 条：会话换代清搜索输入
    it('L19_session_change_bumps_epoch_clears_query_and_state', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      f.hub.sync();
      const c: OrderListController = f.listController();
      c.ensureLoaded();
      await flush();
      c.submitQuery('12345678901234');
      await flush();
      const epoch: number = c.snapshot.sessionEpoch;
      expect(c.snapshot.q).assertEqual('12345678901234');
      f.scopeKey = 'scope-2';
      expect(f.hub.sync()).assertTrue();
      expect(c.snapshot.sessionEpoch).assertEqual(epoch + 1);
      expect(c.snapshot.q).assertNull();
      expect(c.conditions().q).assertNull();
      expect(c.snapshot.phase).assertEqual(OrderPhase.IDLE);
      f.hub.reset();
    });

    // ---------------------------------------------------------------- R2-06 真实按钮回调 → 精确落点（共性第 12、18、22 条）
    it('R2_06_page_button_callbacks_land_on_exact_routes_and_values', 0, async () => {
      const f: OrderFixture = new OrderFixture();
      const roots: string[] = [];
      f.navigator.tabRootHandler = (dst: RouteDestination): boolean => {
        if (dst.route !== null && TAB_ROOTS.indexOf(dst.route) >= 0) {
          roots.push(dst.route);
          return true;
        }
        return false;
      };
      // 列表页：OrderListView 的整卡 / 标题栏 / 空态按钮直接调 config.entries（AppOrders 注入的 open 与 AppRouting.openInApp 同：
      // router.open(RouteRequest.of(route, IN_APP, params))）
      const listEntries: OrderListEntries = new OrderListEntries((r: string, p: Record<string, Object>): void => f.open(r, p));
      expect(listEntries.openDetail(rec(order('O7', '7', 'PAID')))).assertTrue();
      expect(f.top()).assertEqual('OrderDetail');
      expect(f.stack.topParams()['order_id']).assertEqual('O7');
      listEntries.findOrder();
      expect(f.top()).assertEqual('FindOrder');
      expect(JSON.stringify(Object.keys(f.stack.topParams()))).assertEqual('[]');
      expect(h5Path(f.top())).assertEqual('/find-order');
      listEntries.goHome();
      expect(roots[roots.length - 1]).assertEqual('Home');
      // 详情页：OrderDetailView 的按钮回调直接调 config.entries（CONTACT_CS 经统一客服出口 = AppLogin.openCustomerService → Help）
      let cs: number = 0;
      f.detailReply = (_id: string): TransportResponse => envelope(0, detail('O7', '"order_no":"7"'));
      const d: OrderDetailController = f.detailController();
      d.load('O7');
      await flush();
      const entries: OrderDetailEntries = new OrderDetailEntries((r: string, p: Record<string, Object>): void =>
      f.open(r, p), (): void => {
        cs++;
        f.open('Help', {});
      }, (): boolean => d.alive());
      const credited: OrderRecord = rec(detail('W', '"order_no":"1"').replace('"WAITING"', '"CREDITED"'));
      expect(entries.action(credited, 'withdraw')).assertTrue();
      expect(f.top()).assertEqual('RealName');
      f.realname = true;
      expect(entries.action(credited, 'withdraw')).assertTrue();
      expect(f.top()).assertEqual('Withdraw');
      expect(JSON.stringify(Object.keys(f.stack.topParams()))).assertEqual('[]');
      // 不是这份详情的按钮：不打开
      const depth: number = f.stack.names.length;
      expect(entries.action(credited, 'ledger')).assertFalse();
      expect(f.stack.names.length).assertEqual(depth);
      const clawed: OrderRecord = rec(detail('P', '"order_no":"1"').replace('"WAITING"', '"CLAWED_BACK"')
        .replace('"reason":null', '"reason":"PUNISH"').replace('"reason_action":[]', '"reason_action":["CONTACT_CS"]'));
      expect(entries.action(clawed, 'ledger')).assertTrue();
      expect(f.top()).assertEqual('Ledger');
      expect(h5Path(f.top())).assertEqual('/ledger');
      expect(entries.action(clawed, 'contact_cs')).assertTrue();
      expect(cs).assertEqual(1);
      expect(f.top()).assertEqual('Help');
      expect(JSON.stringify(Object.keys(f.stack.topParams()))).assertEqual('[]');
      const blacklist: OrderRecord = rec(detail('B', '"order_no":"1"').replace('"WAITING"', '"INVALID"')
        .replace('"reason":null', '"reason":"BLACKLIST"').replace('"reason_action":[]', '"reason_action":["APPEAL"]'));
      expect(entries.action(blacklist, 'appeal')).assertTrue();
      expect(f.top()).assertEqual('Appeal');
      const reauth: OrderRecord = rec(detail('R', '"order_no":"1"').replace('"WAITING"', '"INVALID"')
        .replace('"reason":null', '"reason":"AUTH_EXPIRED"').replace('"reason_action":[]', '"reason_action":["REAUTH"]'));
      expect(entries.action(reauth, 'reauth')).assertTrue();
      expect(f.top()).assertEqual('AuthManage');
      const claim: OrderRecord = rec(detail('C', '"order_no":"1"').replace('"reason_action":[]', '"reason_action":["CLAIM"]'));
      expect(entries.action(claim, 'claim')).assertTrue();
      expect(f.top()).assertEqual('FindOrder');
      expect(h5Path(f.top())).assertEqual('/find-order');
      // 「查看商品」：参数值逐项核对
      expect(entries.viewProduct(rec(detail('O7', '"order_no":"7"')))).assertTrue();
      expect(f.top()).assertEqual('ProductDetail');
      expect(f.stack.topParams()['platform']).assertEqual('taobao');
      expect(f.stack.topParams()['product_key']).assertEqual('tb:9007');
      expect(JSON.stringify(Object.keys(f.stack.topParams()).sort())).assertEqual('["platform","product_key"]');
      // 「查看说明」：Help + article_id 值
      const pc: OrderRecord = rec(detail('U', '"order_no":"1"').replace('"WAITING"', '"NO_REBATE"')
        .replace('"is_price_compare":false', '"is_price_compare":true'));
      const links: OrderRecord = rec('{"price_compare":{"route":"Help","params":{"article_id":"price-compare"}}}');
      expect(entries.priceCompare(pc, links, Routes.all)).assertTrue();
      expect(f.top()).assertEqual('Help');
      expect(f.stack.topParams()['article_id']).assertEqual('price-compare');
      expect(h5Path(f.top())).assertEqual('/help');
      expect(entries.priceCompare(pc, null, Routes.all)).assertFalse();
      // 【查看申诉进度】只在 appeal_pending=true 时成立
      expect(entries.appealProgress(rec(detail('A', '"order_no":"1"')))).assertFalse();
      expect(entries.appealProgress(rec(detail('A', '"order_no":"1"').replace('"appeal_pending":false',
        '"appeal_pending":true')))).assertTrue();
      expect(f.top()).assertEqual('Appeal');
      // 页面出栈后按钮回调不再打开任何页面
      d.leave();
      const after: number = f.stack.names.length;
      expect(entries.viewProduct(rec(detail('O7', '"order_no":"7"')))).assertFalse();
      expect(entries.action(credited, 'withdraw')).assertFalse();
      expect(f.stack.names.length).assertEqual(after);
      // 待跟单卡「未跟单？去找回」（PendingTrackArea 的回调 = controller.claim）
      f.pendingReply = (): TransportResponse => envelope(0, '{"items":[' + pending('L3', 'a3', 'taobao', true, false) + ']}');
      const p: PendingTrackController = f.pendingController();
      p.fetch(null);
      await flush();
      expect(p.claim(p.snapshot.cards[0])).assertTrue();
      expect(f.top()).assertEqual('FindOrder');
      expect(h5Path(f.top())).assertEqual('/find-order');
      p.leave();
    });
  });
}
