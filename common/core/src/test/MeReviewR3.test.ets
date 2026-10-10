// APP-12 鸿蒙第 3 轮评审修复（harmony-review-r3 R3-01、R3-02）的回归测试：真实 ApiClient + 本地假服务（MeIntegration 的同一套装配）
// + 真实 Router / StackNavigator + Core 执行器（订单列表、隐私中心）。每条先构造评审给出的场景，再断言修复后的结论；注释写明修复前的结果。
import { describe, it, expect } from '@ohos/hypium';
import {
  ApiClientSearchPort, IdentityBoundSlot, MeLevel, MeLocalStore, MemoryMeClearMark, MemoryMeLocalBackend,
  MeTabController, OrderListController, OrderListDeps, PrivacyCenterController, RouteDestination, Route10006,
  SessionTokenSet, TransportRequest
} from '../../Index';
import { envelope } from './NetworkTestRig';
import { MeFixture, NOW, Ports, settle } from './MeIntegration.test';
import { TAB_ROOTS } from './OrderIntegration.test';

/**
 * 与 entry 同一接线：ShellState.showRoot（识别 + 切 Tab）接 tabRootHandler，ShellState.rootShown（「已显示」）接 tabRootShown；
 * 订单 Tab 第一次显示才加载（AppOrders.showTab）；导航标记 = 导航世代 | 选中 Tab | 栈页面名 | 进后台次数（AppMe.navigationMark）。
 */
class ShellRig {
  readonly f: MeFixture;
  selected: number = 0;
  readonly list: OrderListController;
  orderTabShown: boolean = false;
  /** 「已显示」通知时看到的导航状态（标记）。 */
  shownMarks: string[] = [];

  constructor(f: MeFixture) {
    this.f = f;
    const deps: OrderListDeps = new OrderListDeps(new ApiClientSearchPort(f.client));
    deps.clock = (): number => NOW;
    deps.scope = (): string => f.scope();
    this.list = new OrderListController(deps);
    f.navMarkOf = (): string => this.mark();
    f.navigator.tabRootHandler = (d: RouteDestination): boolean => {
      const index: number = d.route === null ? -1 : TAB_ROOTS.indexOf(d.route);
      if (index < 0) {
        return false;
      }
      this.selected = index;
      return true;
    };
    f.navigator.tabRootShown = (d: RouteDestination): void => {
      this.shownMarks.push((d.route ?? '') + '@' + this.mark());
      if (d.route === 'OrderList' && !this.orderTabShown) {
        this.orderTabShown = true;
        this.list.ensureLoaded();
      }
    };
  }

  mark(): string {
    return this.f.navigator.generation + '|' + this.selected + '|' + this.f.navigator.pathNames().join('/') + '|0';
  }

  /** App 一处（AppMe.on10006 的同一判定与动作）：许可通过且栈顶不是 RiskNotice 才清到导航根、经 Router 打开 RiskNotice。 */
  on10006(index: number): boolean {
    const f: MeFixture = this.f;
    if (!Route10006.allowed(f.riskMarks[index], this.mark(), f.riskPermits[index])) {
      return false;
    }
    const names: string[] = f.navigator.pathNames();
    const top: string = names.length > 0 ? names[names.length - 1] : '';
    if (Route10006.decide(top, false) !== Route10006.REPLACE) {
      return false;
    }
    f.navigator.reset([]);
    f.open('RiskNotice');
    return true;
  }
}

function store(): MeLocalStore {
  const s: MeLocalStore = new MeLocalStore();
  s.attach(new MemoryMeLocalBackend(), new MemoryMeClearMark());
  return s;
}

/** 隐私中心页的同一接线（entry AppPrivacyCenterPage）：执行器槽 + 会话通知时同步核对归属。 */
class PrivacyPageRig {
  readonly f: MeFixture;
  readonly ports: Ports = new Ports();
  readonly store: MeLocalStore = store();
  readonly slot: IdentityBoundSlot<PrivacyCenterController>;
  replaced: number = 0;

  constructor(f: MeFixture) {
    this.f = f;
    this.slot = new IdentityBoundSlot<PrivacyCenterController>(
      (): PrivacyCenterController => new PrivacyCenterController(f.deps(), this.ports, this.store),
      (): string => f.scope());
    this.slot.onReplaced = (_n: PrivacyCenterController, _p: PrivacyCenterController): void => {
      this.replaced++;
    };
    f.session.subscribe((): void => {
      this.slot.sync();
    });
  }
}

/** 评审场景前半：账号 A 打开隐私中心 → 在途请求返回 10404 清会话并打开登录页（隐私中心被盖住）→ 状态同步。 */
async function sessionLostWhileCovered(r: PrivacyPageRig): Promise<void> {
  const f: MeFixture = r.f;
  f.reply('/v1/me', (_r: TransportRequest) => envelope(10404, '{}'));
  const tab: MeTabController = new MeTabController(f.deps());
  tab.load();
  await settle();
  // 登录页盖住隐私中心。
  r.slot.hidden();
  f.level = MeLevel.GUEST;
  // AppMe.sync：会话归属变了 → MeSession.reset → 通知订阅方。
  f.session.sync();
}

export default function meReviewR3Test() {
  describe('MeReviewR3', () => {
    // ---------------------------------------------------------------- R3-01
    it('R3_01_wallet_my_orders_10006_enters_risk_notice', 0, async () => {
      const f: MeFixture = new MeFixture();
      const shell: ShellRig = new ShellRig(f);
      f.reply('/v1/orders', (_r: TransportRequest) => envelope(10006, '{}'));
      f.open('Wallet');
      expect(f.navigator.pathNames().join('/')).assertEqual('Wallet');
      // 钱包页点「我的订单」：经 Router 打开 Tab 根 OrderList（订单 Tab 尚未加载）。
      f.open('OrderList');
      expect(f.navigator.pathNames().length).assertEqual(0);
      expect(shell.selected).assertEqual(TAB_ROOTS.indexOf('OrderList'));
      // 「已显示」在清栈、切 Tab 完成后才通知：目标页发请求时的票据就是最终状态（修复前是「…|2|Wallet|0」）。
      expect(shell.shownMarks.length).assertEqual(1);
      expect(shell.shownMarks[0]).assertEqual('OrderList@' + shell.mark());
      await settle();
      expect(f.riskNotices.length).assertEqual(1);
      expect(f.riskMarks[0]).assertEqual(shell.mark());
      // 修复前：Route10006.allowed 返回 false，停在订单错误态。
      expect(shell.on10006(0)).assertTrue();
      expect(f.navigator.pathNames().join('/')).assertEqual('RiskNotice');
    });

    it('R3_01_late_10006_after_leaving_orders_still_rejected', 0, async () => {
      const f: MeFixture = new MeFixture();
      const shell: ShellRig = new ShellRig(f);
      f.reply('/v1/orders', (_r: TransportRequest) => null);
      f.open('Wallet');
      f.open('OrderList');
      await settle();
      expect(f.held.length).assertEqual(1);
      // 发起后用户又导航（切到「我的」Tab），订单请求的 10006 才回来：迟到，不得覆盖用户后续导航。
      f.open('Me');
      f.held[0].resolve(envelope(10006, '{}'));
      await settle();
      expect(f.riskNotices.length).assertEqual(1);
      expect(shell.on10006(0)).assertFalse();
      expect(shell.selected).assertEqual(TAB_ROOTS.indexOf('Me'));
      expect(f.navigator.pathNames().length).assertEqual(0);
      // 空票据一律不放行。
      expect(Route10006.allowed('', '', null)).assertFalse();
    });

    it('R3_01_root_shown_after_reset_and_nested_navigation_in_listener', 0, async () => {
      const f: MeFixture = new MeFixture();
      const shell: ShellRig = new ShellRig(f);
      f.open('Settings');
      // reset([]) 回首页：「已显示」时栈已清、首页已选中。
      f.navigator.reset([]);
      expect(shell.shownMarks[shell.shownMarks.length - 1]).assertEqual('Home@' + shell.mark());
      expect(shell.selected).assertEqual(0);
      // 监听方里再导航：本次的通知先发完，嵌套导航的通知在它自己结束时发出，世代单调递增。
      const seen: string[] = [];
      f.navigator.tabRootShown = (d: RouteDestination): void => {
        seen.push((d.route ?? '') + '@' + shell.mark());
        if (d.route === 'Me') {
          f.open('OrderList');
        }
      };
      f.open('Me');
      expect(seen.length).assertEqual(2);
      expect(seen[0].indexOf('Me@') === 0).assertTrue();
      expect(seen[1]).assertEqual('OrderList@' + shell.mark());
      expect(shell.selected).assertEqual(TAB_ROOTS.indexOf('OrderList'));
      // 监听方出错不影响导航。
      f.navigator.tabRootShown = (_d: RouteDestination): void => {
        throw new Error('listener failed');
      };
      f.open('Settings');
      f.open('Me');
      expect(f.navigator.pathNames().length).assertEqual(0);
      expect(shell.selected).assertEqual(TAB_ROOTS.indexOf('Me'));
    });

    // ---------------------------------------------------------------- R3-02
    it('R3_02_session_lost_then_back_rebuilds_privacy_center_and_withdraw_works', 0, async () => {
      const f: MeFixture = new MeFixture();
      const r: PrivacyPageRig = new PrivacyPageRig(f);
      f.session.sync();
      r.slot.shown();
      const a: PrivacyCenterController = r.slot.current;
      const oldIdentity: string = a.identity;
      // A 时期打开的撤回确认框（确认框生成时绑定的归属与许可）。
      const oldPermit: () => boolean = a.withdrawPermit();
      await sessionLostWhileCovered(r);
      expect(f.client.sessionAccount() === null).assertTrue();
      // 会话变化时同步作废旧执行器（释放订阅）并按新归属新建。
      expect(r.replaced).assertEqual(1);
      expect(a.subscriptionCount).assertEqual(0);
      // 用户关闭登录页回到原隐私中心。
      r.slot.shown();
      const b: PrivacyCenterController = r.slot.current;
      expect(b !== a).assertTrue();
      expect(b.identity).assertEqual(f.scope());
      expect(b.identity !== oldIdentity).assertTrue();
      expect(b.snapshot.level).assertEqual(MeLevel.GUEST);
      // 旧确认框的回调仍被拒绝（不改旧实例的身份放行它）。
      expect(await a.withdraw(oldIdentity, oldPermit)).assertFalse();
      expect(r.ports.withdrawn).assertEqual(0);
      expect(f.count('/v1/consents')).assertEqual(0);
      // 新点【撤回同意】并确认：发撤回记录并完成本地清理（修复前：localWithdrawCalls=0、consentRequests=0）。
      const ok: boolean = await b.withdraw(b.identity, b.withdrawPermit());
      expect(ok).assertTrue();
      expect(f.count('/v1/consents')).assertEqual(1);
      const body: Record<string, Object> = JSON.parse(f.last('/v1/consents').body ?? '{}') as Record<string, Object>;
      expect(body['type'] as string).assertEqual('privacy');
      expect(body['accepted'] as boolean).assertFalse();
      expect(r.ports.withdrawn).assertEqual(1);
      expect(r.ports.halts).assertEqual(1);
      expect(JSON.stringify(r.ports.order)).assertEqual('["stop_push","local"]');
    });

    it('R3_02_session_lost_then_back_personalization_switch_works', 0, async () => {
      const f: MeFixture = new MeFixture();
      const r: PrivacyPageRig = new PrivacyPageRig(f);
      f.session.sync();
      r.slot.shown();
      const a: PrivacyCenterController = r.slot.current;
      const oldIdentity: string = a.identity;
      await sessionLostWhileCovered(r);
      r.slot.shown();
      const b: PrivacyCenterController = r.slot.current;
      // 旧视图的开关回调（旧执行器 + 旧身份）被拒绝：本机偏好不变、不发记录。
      a.setPersonalization(false, oldIdentity);
      expect(r.store.personalizationOn()).assertTrue();
      expect(f.count('/v1/consents')).assertEqual(0);
      // 新视图关闭个性化推荐：本机按选择保存并发记录（修复前：个性化仍为开启、不发记录）。
      b.setPersonalization(false, b.identity);
      expect(r.store.personalizationOn()).assertFalse();
      expect(b.snapshot.personalizationOn).assertFalse();
      await settle();
      expect(f.count('/v1/consents')).assertEqual(1);
      const body: Record<string, Object> = JSON.parse(f.last('/v1/consents').body ?? '{}') as Record<string, Object>;
      expect(body['type'] as string).assertEqual('personalization');
      expect(body['accepted'] as boolean).assertFalse();
    });

    it('R3_02_slot_keeps_instance_when_scope_unchanged_and_stops_after_leave', 0, () => {
      const f: MeFixture = new MeFixture();
      const r: PrivacyPageRig = new PrivacyPageRig(f);
      f.session.sync();
      r.slot.shown();
      const a: PrivacyCenterController = r.slot.current;
      // 归属没变（回前台、Me 快照更新等通知）：不重建，同一实例、同一许可照常有效。
      expect(r.slot.sync()).assertFalse();
      const permit: () => boolean = a.withdrawPermit();
      expect(permit()).assertTrue();
      expect(r.slot.current === a).assertTrue();
      // 页面被盖住期间换账号：回到可见时再核对一次（没收到通知也换新），新实例可见。
      r.slot.hidden();
      f.tokens.save(new SessionTokenSet('access-B', 'refresh-B', 'full', 'user-B'));
      f.client.onSessionChanged();
      r.slot.shown();
      expect(r.slot.current !== a).assertTrue();
      expect(r.slot.current.withdrawPermit()()).assertTrue();
      // 出栈后不再重建，当前实例作废。
      const last: PrivacyCenterController = r.slot.current;
      r.slot.leave();
      f.switchAccount('user-C');
      expect(r.slot.current === last).assertTrue();
      expect(last.subscriptionCount).assertEqual(0);
      expect(r.replaced).assertEqual(1);
    });
  });
}
