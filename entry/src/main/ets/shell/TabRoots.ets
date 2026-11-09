import { HomeActions, homeTabRootBuilder } from 'home';
import { AppRouting } from '../routing/AppRouting';
import { TabBarItem } from 'designsystem';
import { ShellDraftTexts } from './ShellDraftTexts';
import { homeClipboardPasteBuilder, homeClipboardPromptBuilder } from '../clipboard/ClipboardViews';

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

/** 搜索 Tab（APP-10b G32：agent.entry.visible=false 时代替 AI 助手；点它经 Router 打开 Search 页，不切 Tab 根）。 */
export const SEARCH_TAB: ShellTab = new ShellTab('Search', ShellDraftTexts.TAB_SEARCH, 'search');

/** 底部 Tab 项（agentVisible=false 时第 2 个换成「搜索」）。 */
export function shellTabItems(agentVisible: boolean = true): TabBarItem[] {
  return SHELL_TABS.map((tab: ShellTab) => {
    const shown: ShellTab = !agentVisible && tab.route === 'AgentChat' ? SEARCH_TAB : tab;
    return new TabBarItem(shown.label, shown.icon);
  });
}

/**
 * entry 里组合的 Tab 根页（APP-08 订单）：由 RootPage 在构建前填入。TabRoots 不直接 import 订单页（订单页依赖 AppOrders 等组合处，
 * 静态 import 会让 BuildVariant → DebugPanel → AppPrivacy → ShellState → TabRoots 的链提前求值 AppTrade，形成模块循环）。
 */
export class TabRootSlots {
  static orders: WrappedBuilder<[boolean]> | null = null;
  /** APP-12：「我的」Tab 根（entry 组合的 MeTabView；同订单的理由不静态 import）。 */
  static me: WrappedBuilder<[boolean]> | null = null;
  /** APP-10：AI 助手 Tab 根（entry 组合的 AgentTabHost：features/agent 页面 + 购买浮层；同订单的理由不静态 import）。 */
  static agent: WrappedBuilder<[boolean]> | null = null;
}

@Builder
function agentSlotBuilder(readonlyMode: boolean) {
  if (TabRootSlots.agent !== null) {
    (TabRootSlots.agent as WrappedBuilder<[boolean]>).builder(readonlyMode)
  }
}

@Builder
function ordersSlotBuilder(readonlyMode: boolean) {
  if (TabRootSlots.orders !== null) {
    (TabRootSlots.orders as WrappedBuilder<[boolean]>).builder(readonlyMode)
  }
}

@Builder
function meSlotBuilder(readonlyMode: boolean) {
  if (TabRootSlots.me !== null) {
    (TabRootSlots.me as WrappedBuilder<[boolean]>).builder(readonlyMode)
  }
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
    // 首页的搜索入口（APP-06a）：经 Router 打开 Search（auth=none；基本模式按 EntryGuard 只读打开）。占位文案首页自己取
    // （HomeDraftTexts search.placeholder，HM-07v H-V03）。
    HomeActions.openSearch = (): void => {
      AppRouting.shared.openInApp('Search');
    };
    // HM-07v H4：游客价值卡【登录领返利】经 Router 打开登录页（入口 in_app；基本模式由 EntryGuard 先弹隐私，客户端不特判）。
    HomeActions.openLogin = (): void => {
      AppRouting.shared.openInApp('Login');
    };
    // APP-07 / HM-07v H6：首页剪贴板两行（提示条；粘贴卡 + 结果 + 识别卡半屏），游客价值卡夹在中间；基本模式（只读首页）不显示、不读。
    HomeActions.clipboardPrompt = wrapBuilder(homeClipboardPromptBuilder);
    HomeActions.clipboardPaste = wrapBuilder(homeClipboardPasteBuilder);
    // 「我的」页（APP-12）：授权管理与钱包入口在正式「我的」页的宫格里（取代 APP-06b / APP-09 的冒烟入口），都经 Router。
    const m: Map<string, WrappedBuilder<[boolean]>> = new Map<string, WrappedBuilder<[boolean]>>();
    m.set('Home', wrapBuilder(homeTabRootBuilder));
    m.set('AgentChat', wrapBuilder(agentSlotBuilder));
    // 订单 Tab（APP-08）：entry 组合的列表页（Core 执行器 + features/orders 页面 + 待跟单卡）。
    m.set('OrderList', wrapBuilder(ordersSlotBuilder));
    // 「我的」Tab（APP-12）：entry 组合的页面（Core 执行器 + features/me 页面）。
    m.set('Me', wrapBuilder(meSlotBuilder));
    return m;
  }
}
