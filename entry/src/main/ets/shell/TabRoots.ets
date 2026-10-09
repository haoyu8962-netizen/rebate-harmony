import { agentTabRootBuilder } from 'agent';
import { HomeActions, homeTabRootBuilder } from 'home';
import { AppRouting } from '../routing/AppRouting';
import { SearchDraftTexts } from '../search/SearchDraftTexts';
import { MeActions, meTabRootBuilder } from 'me';
import { TradeDraftTexts } from '../trade/TradeDraftTexts';
import { ordersTabRootBuilder } from 'orders';
import { TabBarItem } from 'designsystem';
import { ShellDraftTexts } from './ShellDraftTexts';
import { homeClipboardBuilder } from '../clipboard/ClipboardViews';

/** 一个底部 Tab：根页的路由名（routes.json）、名称、图标。 */
export class ShellTab {
  readonly route: string;
  readonly label: string;
  readonly icon: string;

  constructor(route: string, label: string, icon: string) {
    this.route = route;
    this.label = label;
    this.icon = icon;
  }
}

/** 四个 Tab（设计稿 HomeGuest / BasicMode：首页 / AI 助手 / 订单 / 我的）。 */
export const SHELL_TABS: ShellTab[] = [
  new ShellTab('Home', ShellDraftTexts.TAB_HOME, 'home'),
  new ShellTab('AgentChat', ShellDraftTexts.TAB_AGENT, 'chat'),
  new ShellTab('OrderList', ShellDraftTexts.TAB_ORDERS, 'orders'),
  new ShellTab('Me', ShellDraftTexts.TAB_ME, 'user')
];

export function shellTabItems(): TabBarItem[] {
  return SHELL_TABS.map((tab: ShellTab, index: number) =>
    new TabBarItem(tab.label, tab.icon, ShellDraftTexts.tabPosition(index, SHELL_TABS.length)));
}

/**
 * Tab 根页注册表：路由名 → Feature 导出的 builder（经各 Feature 的 Index 公开入口，不 import Feature 内部类型；
 * 外壳只认路由名，03 §3.1）。参数 readonlyMode：基本模式等只读打开。
 */
export class TabRootRegistry {
  private static readonly builders: Map<string, WrappedBuilder<[boolean]>> = TabRootRegistry.build();

  static builder(route: string): WrappedBuilder<[boolean]> | undefined {
    return TabRootRegistry.builders.get(route);
  }

  private static build(): Map<string, WrappedBuilder<[boolean]>> {
    // 首页的搜索入口（APP-06a）：经 Router 打开 Search（auth=none；基本模式按 EntryGuard 只读打开）。
    HomeActions.searchLabel = SearchDraftTexts.text('search.placeholder');
    HomeActions.openSearch = (): void => {
      AppRouting.shared.openInApp('Search');
    };
    // APP-07：首页剪贴板区（粘贴卡、邀请确认条、结果提示）在搜索框下方；基本模式（只读首页）不显示、不读。
    HomeActions.clipboardArea = wrapBuilder(homeClipboardBuilder);
    // 「我的」顶部的授权管理入口（APP-06b 共性第 14 条）：经 Router 打开 AuthManage（auth=login：游客先登录；基本模式先补同意）。
    MeActions.authManageLabel = TradeDraftTexts.text('auth_manage.entry');
    MeActions.openAuthManage = (): void => {
      AppRouting.shared.openInApp('AuthManage');
    };
    const m: Map<string, WrappedBuilder<[boolean]>> = new Map<string, WrappedBuilder<[boolean]>>();
    m.set('Home', wrapBuilder(homeTabRootBuilder));
    m.set('AgentChat', wrapBuilder(agentTabRootBuilder));
    m.set('OrderList', wrapBuilder(ordersTabRootBuilder));
    m.set('Me', wrapBuilder(meTabRootBuilder));
    return m;
  }
}
