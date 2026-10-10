import { RouteDestination, TabSwitchSignal } from 'core';
import { SHELL_TABS, ShellTab } from './TabRoots';

/**
 * Tab 外壳的界面状态。Tab 根页也只由 Router 打开（AppShell 点 Tab → Router.open → EntryGuard）：
 * NavStackNavigator 遇到 Tab 根路由不入栈，而是交给 showRoot 切 Tab，并保留 Router 给的只读标记（基本模式等）。
 */
@ObservedV2
export class ShellState {
  private static instance: ShellState | null = null;

  /** 惰性创建（类体里的静态实例在 @ObservedV2 装饰之前创建、不可观察，见 AppPrivacy.shared）。 */
  static get shared(): ShellState {
    if (ShellState.instance === null) {
      ShellState.instance = new ShellState();
    }
    return ShellState.instance;
  }

  /** 当前选中的 Tab（0 = 首页）。 */
  @Trace selected: number = 0;
  /** 每个 Tab 根页最近一次由 Router 打开时的只读标记。 */
  @Trace readonlyFlags: boolean[] = SHELL_TABS.map((_tab: ShellTab) => false);
  /** Router 已经打开过 Tab 根页（外壳重建时不再重新判定、不覆盖已保存的只读标记；只有用户点 Tab 才重新判定）。 */
  rootsOpened: boolean = false;

  /**
   * 主 Tab 切换的同步信号（FU-HM-0712 R1-02）：showRoot 改 selected 之前发出。Tab 根页切走只是不可见、不卸载，订单列表顶部待跟单卡等
   * 显示位置靠它同步作废（AppOrders 订阅）。初值与 selected 的初值（第 0 个 Tab）一致。
   */
  static readonly tabSwitch: TabSwitchSignal = new TabSwitchSignal(SHELL_TABS[0].route);

  static indexOf(route: string): number {
    return SHELL_TABS.findIndex((tab: ShellTab) => tab.route === route);
  }

  /**
   * 切 Tab 生效之前的同步通知（APP-07：剪贴板识别的「当前前台界面」，离开首页即作废发起的读取与请求，共性第 3 条）。
   * 参数为目标 Tab 根路由与基本模式页标记。
   */
  static onTabWillChange: (route: string, basicMode: boolean) => void = (_r: string, _b: boolean) => {
  };

  /**
   * Tab 根页已由 Router 打开并切过去之后的通知（APP-08：订单 Tab 第一次显示时才加载列表与待跟单卡；OrderList 的 scope=share 路由参数
   * 直接进分享子 Tab）。参数为 Router 给的目的地（含已校验的路由参数）。
   * APP-12 R3-01：由 StackNavigator.tabRootShown 在本次导航的清栈、切 Tab 全部完成之后调（经 rootShown），不在 showRoot 里调——
   * 目标页此时发起的请求绑定的导航票据就是导航最终状态，合法的 10006 不会因捕获了导航中途的旧栈而被当成迟到。
   */
  static onRootShown: (destination: RouteDestination) => void = (_d: RouteDestination) => {
  };

  /**
   * Router 打开了一个 Tab 根路由：切过去并记下只读标记（只识别与切换，不发「已显示」通知，R3-01）。不是 Tab 根路由时返回 false
   * （照常入栈）。
   */
  showRoot(destination: RouteDestination): boolean {
    const index: number = destination.route === null ? -1 : ShellState.indexOf(destination.route);
    if (index < 0) {
      return false;
    }
    ShellState.onTabWillChange(destination.route as string, destination.readonly);
    ShellState.tabSwitch.change(destination.route as string);
    const flags: boolean[] = this.readonlyFlags.slice();
    flags[index] = destination.readonly;
    this.readonlyFlags = flags;
    this.selected = index;
    this.rootsOpened = true;
    return true;
  }

  /** 本次导航全部完成后的「已显示」通知（StackNavigator.tabRootShown 接这里，R3-01）。 */
  static rootShown(destination: RouteDestination): void {
    if (destination.route === null || ShellState.indexOf(destination.route) < 0) {
      return;
    }
    try {
      ShellState.onRootShown(destination);
    } catch (e) {
      // 监听方出错不影响切 Tab。
    }
  }
}
