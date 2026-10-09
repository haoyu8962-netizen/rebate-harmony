import { RouteDestination } from 'core';
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

  static indexOf(route: string): number {
    return SHELL_TABS.findIndex((tab: ShellTab) => tab.route === route);
  }

  /**
   * 切 Tab 生效之前的同步通知（APP-07：剪贴板识别的「当前前台界面」，离开首页即作废发起的读取与请求，共性第 3 条）。
   * 参数为目标 Tab 根路由与基本模式页标记。
   */
  static onTabWillChange: (route: string, basicMode: boolean) => void = (_r: string, _b: boolean) => {
  };

  /** Router 打开了一个 Tab 根路由：切过去并记下只读标记。不是 Tab 根路由时返回 false（照常入栈）。 */
  showRoot(destination: RouteDestination): boolean {
    const index: number = destination.route === null ? -1 : ShellState.indexOf(destination.route);
    if (index < 0) {
      return false;
    }
    ShellState.onTabWillChange(destination.route as string, destination.readonly);
    const flags: boolean[] = this.readonlyFlags.slice();
    flags[index] = destination.readonly;
    this.readonlyFlags = flags;
    this.selected = index;
    this.rootsOpened = true;
    return true;
  }
}
