// FU-HM-ROOTSHOWN-CHAIN（编排 D10-1652，rootcause-r3 agent_01 / 02）的回归测试：Ability 在同一进程里重建（relaunchCold、退出 Ability
// 进程仍在再打开）之后，进「我的」Tab 仍会刷新 /v1/me（G36 autoLoad），进「AI 助手」Tab 仍会把启动参数里的那条消息自动发出。
// 接线照 entry（entry 不能被 core 单测引用，组合方按 entry 源码逐行复刻，宿主 tools/ci/rootshown/check_root_shown.py 钉住 entry 侧同一写法）：
// - ShellState.onRootShown 是 RootShownRegistry（静态字段，整个进程一份，Ability 重建不重置）；StackNavigator.tabRootShown 接
//   ShellState.rootShown，只对 Tab 根路由 dispatch；
// - EntryAbility.onCreate 依次 compose：AppOrders（context 非空 → 只按名重登后返回）→ AppMe（同上）→ AppAgent（先按名登记，再判 composed）。
// 「我的」用真实 MeTabController + 真实 ApiClient + 本地假服务（MeIntegration 同一套装配），数的是假服务收到的 GET /v1/me。
// 修复前（AppOrders 直接赋值 ShellState.onRootShown、Me / Agent 包一层 previous）第二次 compose 后两项都丢：见 legacy 对照用例。
import { describe, it, expect } from '@ohos/hypium';
import { MeTabController, PageListeners, RootShownRegistry, RouteDestination } from '../../Index';
import { MeFixture, settle } from './MeIntegration.test';
import { TAB_ROOTS } from './OrderIntegration.test';

const ORDER_LIST_ROUTE: string = 'OrderList';
const AGENT_ROUTE: string = 'AgentChat';

/** entry ShellState 的同一写法（只取 onRootShown / rootShown 两处）。 */
class ShellReplica {
  readonly onRootShown: RootShownRegistry = new RootShownRegistry();

  rootShown(destination: RouteDestination): void {
    if (destination.route === null || TAB_ROOTS.indexOf(destination.route) < 0) {
      return;
    }
    this.onRootShown.dispatch(destination);
  }
}

/** entry AppOrders.compose 的同一写法：重入只更新 context 并按名重登。 */
class OrdersReplica {
  private readonly shell: ShellReplica;
  context: string | null = null;
  builds: number = 0;
  shown: number = 0;

  constructor(shell: ShellReplica) {
    this.shell = shell;
  }

  compose(context: string): void {
    if (this.context !== null) {
      this.context = context;
      this.registerRootShown();
      return;
    }
    this.context = context;
    this.builds++;
    this.registerRootShown();
  }

  private registerRootShown(): void {
    this.shell.onRootShown.register(RootShownRegistry.ORDERS, (destination: RouteDestination): void => {
      if (destination.route === ORDER_LIST_ROUTE) {
        this.shown++;
      }
    });
  }
}

/** entry AppMe.compose 的同一写法：G36 进「我的」Tab 走 tab().autoLoad()。 */
class MeReplica {
  private readonly shell: ShellReplica;
  private readonly f: MeFixture;
  private tabInstance: MeTabController | null = null;
  context: string | null = null;

  constructor(shell: ShellReplica, f: MeFixture) {
    this.shell = shell;
    this.f = f;
  }

  tab(): MeTabController {
    if (this.tabInstance === null) {
      this.tabInstance = new MeTabController(this.f.deps());
    }
    return this.tabInstance as MeTabController;
  }

  compose(context: string): void {
    if (this.context !== null) {
      this.context = context;
      this.registerRootShown();
      return;
    }
    this.context = context;
    this.registerRootShown();
  }

  private registerRootShown(): void {
    this.shell.onRootShown.register(RootShownRegistry.ME, (destination: RouteDestination): void => {
      if (destination.route === 'Me') {
        this.tab().autoLoad();
      }
    });
  }
}

/** entry AppAgent.compose + staging AgentVariant.onAgentShown 的同一写法：启动参数消息一次性取走并发出。 */
class AgentReplica {
  private readonly shell: ShellReplica;
  composed: boolean = false;
  tabSelected: boolean = false;
  sendOnLaunch: string | null = null;
  sent: string[] = [];

  constructor(shell: ShellReplica) {
    this.shell = shell;
  }

  compose(): void {
    this.shell.onRootShown.register(RootShownRegistry.AGENT, (destination: RouteDestination): void => {
      if (destination.route === AGENT_ROUTE) {
        this.tabSelected = true;
        this.onAgentShown();
      }
    });
    if (this.composed) {
      return;
    }
    this.composed = true;
  }

  private onAgentShown(): void {
    const text: string | null = this.sendOnLaunch;
    this.sendOnLaunch = null;
    if (text !== null) {
      this.sent.push(text);
    }
  }
}

/** EntryAbility.onCreate 的组合顺序（Orders :76 → Me :80 → Agent :85）。 */
class AbilityReplica {
  readonly shell: ShellReplica = new ShellReplica();
  readonly f: MeFixture = new MeFixture();
  readonly orders: OrdersReplica;
  readonly me: MeReplica;
  readonly agent: AgentReplica;
  private creates: number = 0;

  constructor() {
    this.orders = new OrdersReplica(this.shell);
    this.me = new MeReplica(this.shell, this.f);
    this.agent = new AgentReplica(this.shell);
    this.f.navigator.tabRootShown = (d: RouteDestination): void => this.shell.rootShown(d);
  }

  onCreate(): void {
    this.creates++;
    const context: string = 'ability-' + this.creates;
    this.orders.compose(context);
    this.me.compose(context);
    this.agent.compose();
  }
}

/** 修复前的写法（对照）：AppOrders 直接赋值，Me / Agent 包一层 previous 且重入直接返回。 */
class LegacyAbility {
  onRootShown: (destination: RouteDestination) => void = (_d: RouteDestination): void => {
  };
  meComposed: boolean = false;
  agentComposed: boolean = false;
  meLoads: number = 0;
  agentShown: number = 0;

  onCreate(): void {
    this.onRootShown = (_d: RouteDestination): void => {
    };
    if (!this.meComposed) {
      this.meComposed = true;
      const previous: (destination: RouteDestination) => void = this.onRootShown;
      this.onRootShown = (d: RouteDestination): void => {
        previous(d);
        if (d.route === 'Me') {
          this.meLoads++;
        }
      };
    }
    if (!this.agentComposed) {
      this.agentComposed = true;
      const previous: (destination: RouteDestination) => void = this.onRootShown;
      this.onRootShown = (d: RouteDestination): void => {
        previous(d);
        if (d.route === AGENT_ROUTE) {
          this.agentShown++;
        }
      };
    }
  }
}

export default function rootShownChainTest() {
  describe('RootShownChain', () => {
    it('registry_same_key_replaces_in_place_and_unregister_by_name', 0, () => {
      const r: RootShownRegistry = new RootShownRegistry();
      const hits: string[] = [];
      r.register('a', (_d: RouteDestination): void => {
        hits.push('a1');
      });
      r.register('b', (_d: RouteDestination): void => {
        hits.push('b');
      });
      r.register('a', (_d: RouteDestination): void => {
        hits.push('a2');
      });
      expect(r.registered().join(',')).assertEqual('a,b');
      r.dispatch(new RouteDestination('Me'));
      expect(hits.join(',')).assertEqual('a2,b');
      r.unregister('a');
      r.unregister('missing');
      expect(r.registered().join(',')).assertEqual('b');
    });

    it('registry_listener_error_does_not_stop_others', 0, () => {
      const r: RootShownRegistry = new RootShownRegistry();
      let reached: boolean = false;
      r.register('bad', (_d: RouteDestination): void => {
        throw new Error('boom');
      });
      r.register('good', (_d: RouteDestination): void => {
        reached = true;
      });
      r.dispatch(new RouteDestination('Me'));
      expect(reached).assertTrue();
    });

    it('recreate_in_same_process_me_tab_still_refreshes_v1_me', 0, async () => {
      const a: AbilityReplica = new AbilityReplica();
      a.f.session.sync();
      a.onCreate();
      a.f.open('Me');
      await settle();
      expect(a.f.count('GET /v1/me')).assertEqual(1);
      // 同一进程第二次 onCreate（relaunchCold）：三项都还在、各一项、顺序不变；订单的进程级装配不重建。
      a.onCreate();
      expect(a.shell.onRootShown.registered().join(',')).assertEqual('orders,me,agent');
      expect(a.orders.builds).assertEqual(1);
      expect(a.orders.context).assertEqual('ability-2');
      a.f.open('Home');
      a.f.open('Me');
      await settle();
      expect(a.f.count('GET /v1/me')).assertEqual(2);
      // 订单那一项也没丢。
      a.f.open('OrderList');
      await settle();
      expect(a.orders.shown).assertEqual(1);
    });

    it('recreate_in_same_process_agent_launch_message_still_sent', 0, async () => {
      const a: AbilityReplica = new AbilityReplica();
      a.f.session.sync();
      a.onCreate();
      a.onCreate();
      // 第二次启动带的 couli_debug_agent_send（AgentVariant.applyLaunch 在 compose 之后写入）。
      a.agent.sendOnLaunch = '帮我找纯牛奶';
      a.f.open('Me');
      a.f.open('AgentChat');
      await settle();
      expect(a.agent.tabSelected).assertTrue();
      expect(a.agent.sent.join('|')).assertEqual('帮我找纯牛奶');
      // 一次性：再进不重发。
      a.f.open('Me');
      a.f.open('AgentChat');
      await settle();
      expect(a.agent.sent.length).assertEqual(1);
    });

    it('recreate_three_times_no_duplicate_dispatch', 0, async () => {
      const a: AbilityReplica = new AbilityReplica();
      a.f.session.sync();
      a.onCreate();
      a.onCreate();
      a.onCreate();
      expect(a.shell.onRootShown.registered().length).assertEqual(3);
      a.f.open('Me');
      await settle();
      expect(a.f.count('GET /v1/me')).assertEqual(1);
    });

    // D10-1668 ③：执行器按页订阅（提现 / 收款账号 / 换号 / 注销页不再覆盖单槽 onChange）。
    it('page_listeners_two_pages_both_notified_and_unsubscribe_by_page', 0, () => {
      const l: PageListeners<number> = new PageListeners<number>();
      const a: number[] = [];
      const b: number[] = [];
      const offA: () => void = l.subscribe((n: number): void => {
        a.push(n);
      });
      const offB: () => void = l.subscribe((n: number): void => {
        b.push(n);
      });
      l.notify(1);
      // 旧页面消失只摘自己：新页面仍收到通知（单槽写法下后建的页面会冲掉先建的，先建的消失后也不摘）。
      offA();
      l.notify(2);
      offA();
      expect(a.join(',')).assertEqual('1');
      expect(b.join(',')).assertEqual('1,2');
      offB();
      expect(l.count).assertEqual(0);
    });

    it('page_listeners_error_isolated', 0, () => {
      const l: PageListeners<number> = new PageListeners<number>();
      let got: number = 0;
      l.subscribe((_n: number): void => {
        throw new Error('page');
      });
      l.subscribe((n: number): void => {
        got = n;
      });
      l.notify(7);
      expect(got).assertEqual(7);
    });

    it('legacy_direct_assignment_loses_me_and_agent_after_recreate', 0, () => {
      // 对照：修复前的写法在第二次 onCreate 后两项都丢（本条锁住「新用例确实能分辨修复前后」）。
      const l: LegacyAbility = new LegacyAbility();
      l.onCreate();
      l.onRootShown(new RouteDestination('Me'));
      l.onRootShown(new RouteDestination(AGENT_ROUTE));
      expect(l.meLoads).assertEqual(1);
      expect(l.agentShown).assertEqual(1);
      l.onCreate();
      l.onRootShown(new RouteDestination('Me'));
      l.onRootShown(new RouteDestination(AGENT_ROUTE));
      expect(l.meLoads).assertEqual(1);
      expect(l.agentShown).assertEqual(1);
    });
  });
}
