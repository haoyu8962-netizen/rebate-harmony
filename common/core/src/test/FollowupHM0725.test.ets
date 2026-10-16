// FU-HM-0725 鸿蒙跟进合集（十三）——只用现有接口的用例（测试作者，2026-10-16；第 2 版按 tests-review T-09 / T-10 / T-11 修订）。
// 依赖第 2 版接口约定（N1–N4）的用例在 FollowupHM0725Contract.test.ets。
// - F-HM-40 / M41（T-11）：决策延后期间用户提交查询 + 之后身份重绑——只经 app.sync，不手动补加载；响应随条件变化。
// - F-HM-40 C-40b（T-09 / T-10）：无记录或条件解不出、目标条件与当前列表相同 → 跳过恢复（不 begin、不推进轮次、不重取、不清空、
//   不下发滚动）；目标条件不同（路由 scope=share）或有可恢复记录 → 照常切换并加载（对照）。
// 调度一律经 OrderTabCoordinator.showTab / sync / persist；等待都用 until 并断言；负向断言在列表请求全部结算之后。
import { describe, it, expect } from '@ohos/hypium';
import {
  OrderListConditions, OrderListScrollSync, OrderPageState, OrderPersistResult, OrderPhase
} from '../../Index';
import {
  BoundedViewport, Device, PAGE_KEY, Proc, SEED_Q, seededDevice, UNKNOWN_KINDS, until
} from './FollowupHM0724Rig';
import { fingerprint, OrdersApp } from './FollowupHM0725Rig';

/** 订单 Tab：恢复记录读不出（'record' 键读失败 / 'open' 命名空间打不开）时显示，等默认列表加载并结算。 */
async function deferredOrders(d: Device, fault: string, routeScope: string | null): Promise<OrdersApp> {
  const p: Proc = new Proc(d);
  const app: OrdersApp = new OrdersApp(p);
  app.compose();
  app.sync();
  if (fault === 'record') {
    d.prefs.failNextReads(PAGE_KEY, 1000000);
  } else {
    d.prefs.failNextOpens(1000000);
  }
  app.coordinator.showTab(routeScope);
  return app;
}

/** 把设备上的恢复记录改成外层合法（账号、归属世代都对）但条件解不出。 */
function makeUndecodable(d: Device): boolean {
  const s: OrderPageState | null = OrderPageState.decode(d.prefs.record());
  if (s === null) {
    return false;
  }
  d.prefs.values.set(PAGE_KEY, new OrderPageState(s.account, 'not-json', s.anchor, s.input, s.generation).encode());
  const back: OrderPageState | null = OrderPageState.decode(d.prefs.record());
  return back !== null && OrderListConditions.decode(back.conditions) === null;
}

/** 视图的滚动接线（与 OrderListView 同一构造）；rescrolls 记下发的定位命令数。 */
class ViewScroll {
  readonly viewport: BoundedViewport = new BoundedViewport();
  readonly sync: OrderListScrollSync;
  rescrolls: number = 0;

  constructor(app: OrdersApp) {
    this.viewport.setItems(app.list.snapshot.items);
    this.sync = new OrderListScrollSync(app.keeper, this.viewport, (): void => {
      app.coordinator.persist();
    }, (listIndex: number): void => {
      this.rescrolls++;
      this.viewport.alignTo(listIndex);
    });
  }
}

export default function followupHM0725Test() {
  describe('FollowupHM0725', () => {
    // ================================================================ T-11 / 变异 M41
    it('fhm0725_f40_m41_deferred_user_query_then_identity_rebind_keeps_user_query', 0, async () => {
      for (const kind of UNKNOWN_KINDS) {
        const d: Device = seededDevice('O3');
        const p: Proc = new Proc(d);
        p.makeUnknown(kind);
        const app: OrdersApp = new OrdersApp(p);
        app.compose();
        app.sync();
        d.prefs.failNextReads(PAGE_KEY, 1000000);
        app.coordinator.showTab(null);
        expect(app.restorer.restoreDecided).assertFalse();
        // 决策完成之前用户自己搜索。第 5 版（T-21 同源）：身份未知期间可以发出查询，也可以延后——只等已发出的列表请求都结算，
        // 不要求此刻已有内容或错误。
        expect(app.list.submitQuery('9988')).assertTrue();
        const searched: boolean = await until((): boolean => app.port.listQuiet);
        expect(searched).assertTrue();
        const requests0: number = app.listRequests();
        // 身份落定（判据 A/E1，不是换代）：只走正常同步，测试不补加载。
        p.makeKnown();
        app.sync();
        expect(kind + ':q=' + app.list.conditions().q).assertEqual(kind + ':q=9988');
        expect(kind + ':snapshot.q=' + app.list.snapshot.q).assertEqual(kind + ':snapshot.q=9988');
        expect(app.list.ownsSession()).assertTrue();
        expect(app.restorer.restoreDecided).assertTrue();
        const loaded: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT
          && app.port.listQuiet && app.listRequests() > requests0);
        expect(kind + ':loaded=' + loaded + ',' + app.list.snapshot.phase + ',' + app.shownIds())
          .assertEqual(kind + ':loaded=true,' + OrderPhase.CONTENT + ',O9988');
        // 恢复后真实发出的列表请求带的是用户的条件；显示的是这份响应（服务端按条件返回不同结果）。
        expect(kind + ':' + app.lastListQuery()).assertEqual(kind + ':scope=self&q=9988');
        expect(app.list.conditions().q).assertEqual('9988');
        expect(app.keeper.anchor === 'O3').assertFalse();
        expect(app.keeper.frozen).assertFalse();
        expect(app.coordinator.persist()).assertEqual(OrderPersistResult.SAVED);
        const record: string = d.prefs.record() ?? '';
        expect(record.indexOf('9988') >= 0 && record.indexOf(SEED_Q) < 0).assertTrue();
      }
    });

    // ================================================================ T-09 / T-10：无记录或条件解不出，目标条件与当前列表相同 → 跳过恢复
    it('fhm0725_f40_no_or_undecodable_record_same_conditions_skips_restore_without_flash', 0, async () => {
      const got: string[] = [];
      const want: string[] = [];
      for (const record of ['missing', 'undecodable']) {
        for (const fault of ['record', 'open']) {
          for (const route of ['null', 'self']) {
            const tag: string = record + '/' + fault + '/' + route;
            const d: Device = seededDevice('O3');
            if (record === 'missing') {
              d.prefs.values.delete(PAGE_KEY);
              expect(d.prefs.record() === null).assertTrue();
            } else {
              expect(makeUndecodable(d)).assertTrue();
            }
            const app: OrdersApp = await deferredOrders(d, fault, route === 'null' ? null : route);
            const loaded: boolean = await until((): boolean => app.list.snapshot.phase === OrderPhase.CONTENT
              && app.port.listQuiet);
            expect(loaded).assertTrue();
            expect(app.restorer.restoreDecided).assertFalse();
            const view: ViewScroll = new ViewScroll(app);
            view.sync.scrollIndex(0, true);
            const fp0: string = fingerprint(app.list.snapshot);
            const ticket0: number = app.keeper.ticket;
            const cond0: string = app.list.conditions().encode();
            const ids0: string = app.shownIds();
            const requests0: number = app.listRequests();
            app.record();
            d.prefs.heal();
            app.sync();
            const decided: boolean = app.restorer.restoreDecided;
            const syncFlash: string = app.emitted.filter((e: string): boolean => e !== fp0).join(';');
            // 生产调度完成：再走一次正常同步，等全部列表请求结算。
            app.sync();
            const settled: boolean = await until((): boolean => app.port.listQuiet);
            const step: number = view.sync.restoreStep(app.list);
            const laterFlash: string = app.emitted.filter((e: string): boolean => e !== fp0).join(';');
            const persisted: string = app.coordinator.persist();
            got.push(tag + ': decided=' + decided + ' settled=' + settled + ' flash=' + syncFlash + '|' + laterFlash
              + ' requests+' + (app.listRequests() - requests0) + ' ticket+' + (app.keeper.ticket - ticket0)
              + ' cond=' + (app.list.conditions().encode() === cond0) + ' ids=' + (app.shownIds() === ids0)
              + ' frozen=' + app.keeper.frozen + ' rescroll=' + view.rescrolls + ' step<0=' + (step < 0)
              + ' persist=' + persisted + ' seedInRecord=' + ((d.prefs.record() ?? '').indexOf(SEED_Q) >= 0));
            want.push(tag + ': decided=true settled=true flash=| requests+0 ticket+0 cond=true ids=true frozen=false'
              + ' rescroll=0 step<0=true persist=' + OrderPersistResult.SAVED + ' seedInRecord=false');
          }
        }
      }
      expect(got.join(' || ')).assertEqual(want.join(' || '));
    });

    // 对照（当前绿；防「列表已是内容就一律跳过」）：目标条件不同（路由 scope=share）或记录可恢复 → 照常切换并加载新条件的结果。
    it('fhm0725_f40_different_target_conditions_still_restore_and_load', 0, async () => {
      for (const fault of ['record', 'open']) {
        // a）无记录 + 路由 scope=share：目标 = share 默认条件，与正在显示的 self 列表不同。
        const d1: Device = seededDevice('O3');
        d1.prefs.values.delete(PAGE_KEY);
        const a1: OrdersApp = await deferredOrders(d1, fault, 'share');
        expect(await until((): boolean => a1.list.snapshot.phase === OrderPhase.CONTENT && a1.port.listQuiet))
          .assertTrue();
        d1.prefs.heal();
        a1.sync();
        expect(a1.restorer.restoreDecided).assertTrue();
        expect(a1.list.conditions().scope).assertEqual('share');
        const shared: boolean = await until((): boolean => a1.list.snapshot.phase === OrderPhase.CONTENT
          && a1.port.listQuiet && a1.shownIds() === 'S1,S2');
        expect(fault + ':share=' + shared + ',' + a1.lastListQuery()).assertEqual(fault + ':share=true,scope=share');
        // b）可恢复记录（q = SEED_Q、平台 taobao）：切到旧条件并显示它的结果。
        const d2: Device = seededDevice('O3');
        const a2: OrdersApp = await deferredOrders(d2, fault, null);
        expect(await until((): boolean => a2.list.snapshot.phase === OrderPhase.CONTENT && a2.port.listQuiet))
          .assertTrue();
        d2.prefs.heal();
        a2.sync();
        expect(a2.list.conditions().q).assertEqual(SEED_Q);
        const seeded: boolean = await until((): boolean => a2.list.snapshot.phase === OrderPhase.CONTENT
          && a2.port.listQuiet && a2.shownIds() === 'O3,O4');
        expect(fault + ':seed=' + seeded).assertEqual(fault + ':seed=true');
      }
    });
  });
}
