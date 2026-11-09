import { SymbolGlyphModifier } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction } from '../CouliMetrics';

/** 系统标题栏高（NavDestination 标题栏的标准高度，Mini 样式）。 */
const NAV_BAR_HEIGHT: number = 56;

/** 导航栏右侧的一个操作（系统 menus：图标 + 读屏名，点按回调）。 */
export class NavBarAction {
  readonly label: string;
  readonly symbol: Resource;
  readonly action: () => void;

  constructor(label: string, symbol: Resource, action: () => void) {
    this.label = label;
    this.symbol = symbol;
    this.action = action;
  }
}

/**
 * 导航栏（清单 §3.4 NavBar，评审 r1 R1-01）：系统 Navigation 标题栏（Mini）+ 系统返回按钮，不再 Row + 自绘返回图标。
 * - 标题、返回图标、标题位置、高度、字号与读屏「返回，按钮」都由系统标题栏画；返回按钮的读屏名用 backLabel
 *   （backButtonIcon 的 accessibilityText，API 19）。
 * - 返回走系统：点标题栏的返回按钮与按系统返回键 / 边缘手势一样，交给页面所在的路由 NavDestination——先回调它的
 *   onBackPressed（各页面已有的拦截：隐私弹窗吞返回、设置子页先关子页、封禁说明无返回等），没拦下就由系统出栈。
 *   所以组件不再提供 onBack 回调（真机核过：标题栏返回按钮触发宿主路由页的 onBackPressed）。
 * - 一级页（showBack = false）：不显示返回；透明（transparent，详情头图上）：标题栏底透明；滚动后（scrolled）：
 *   标题栏换 background.surface 底 + 下分隔线 border.subtle。
 * - 右侧操作：actions → 系统 menus（图标 + 读屏名）。
 * 用法：路由页 NavDestination 保持 hideTitleBar(true)，页面内容最上方放 NavBar（高 56）；业务页面与组件目录用的是同一个组件。
 */
@ComponentV2
export struct NavBar {
  @Param title: string = '';
  @Param backLabel: string = '';
  @Param showBack: boolean = true;
  @Param transparent: boolean = false;
  @Param scrolled: boolean = false;
  @Param actions: NavBarAction[] = [];
  /** 标题栏容器的组件 id；空串不设（系统子节点 id 形如 __NavigationField__BackButton__Back__<navId>）。 */
  @Param navId: string = '';

  private titleOptions(): NavigationTitleOptions {
    const options: NavigationTitleOptions = {
      backgroundColor: this.transparent && !this.scrolled ? Color.Transparent
        : (this.scrolled ? CouliColors.backgroundSurface : CouliColors.backgroundCanvas),
      barStyle: BarStyle.STANDARD
    };
    return options;
  }

  private menuItems(): NavigationMenuItem[] {
    return this.actions.map((item: NavBarAction): NavigationMenuItem => {
      const menu: NavigationMenuItem = {
        value: item.label,
        symbolIcon: new SymbolGlyphModifier(item.symbol),
        action: (): void => item.action()
      };
      return menu;
    });
  }

  build() {
    Navigation() {
    }
    .title(this.title, this.titleOptions())
    .titleMode(NavigationTitleMode.Mini)
    .hideBackButton(!this.showBack)
    .backButtonIcon(new SymbolGlyphModifier($r('sys.symbol.arrow_left')), this.backLabel)
    .menus(this.menuItems())
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .backgroundColor(Color.Transparent)
    .border(this.scrolled ? { width: { bottom: CouliComponentMetrics.controlBorderWidth }, color: CouliColors.borderSubtle }
      : { width: 0 })
    .width('100%')
    .height(NAV_BAR_HEIGHT)
    .id(this.navId.length > 0 ? this.navId : undefined)
  }
}

/** Tab 栏的一项（文字由调用方给：首页 / AI 助手 / 订单 / 我的；icon 是语义名，见 tabSymbols）。 */
export class TabBarItem {
  readonly label: string;
  readonly icon: string;

  constructor(label: string, icon: string) {
    this.label = label;
    this.icon = icon;
  }
}

/** 一项的系统符号：未选、选中各一个。 */
interface TabSymbols {
  normal: Resource;
  selected: Resource;
}

/** 语义名 → 系统符号（$r 实参必须是字面量，所以用 switch）。未知名回落问号，目录里一眼能发现。 */
function tabSymbols(icon: string): TabSymbols {
  switch (icon) {
    case 'home':
      return { normal: $r('sys.symbol.house'), selected: $r('sys.symbol.house_fill') };
    case 'chat':
      return { normal: $r('sys.symbol.ellipsis_message'), selected: $r('sys.symbol.ellipsis_message_fill') };
    case 'orders':
      return { normal: $r('sys.symbol.doc_plaintext'), selected: $r('sys.symbol.doc_plaintext_fill') };
    case 'user':
      return { normal: $r('sys.symbol.person'), selected: $r('sys.symbol.person_fill') };
    case 'search':
      return { normal: $r('sys.symbol.magnifyingglass'), selected: $r('sys.symbol.magnifyingglass') };
    default:
      return { normal: $r('sys.symbol.questionmark_circle'), selected: $r('sys.symbol.questionmark_circle') };
  }
}

/** 底栏高：系统 BottomTabBarStyle 的默认高度 48（等于最小命中区）。Tabs 外高必须显式设，否则会撑满父容器。 */
const TAB_BAR_HEIGHT: number = CouliInteraction.minTouchTarget;

/**
 * 一级底部标签栏（harmony.md §1 底栏，D10-909 做法 A）：系统 Tabs(barPosition End) + BottomTabBarStyle + TabBarSymbol。
 * 图标、文字排布、字号（系统默认）、切换、焦点与读屏都由系统页签负责；这里只定选中 / 未选的颜色和点击的受控逻辑。
 * 栏本身不设底色（系统默认透明），系统模糊材质由宿主挂在栏外层（应用外壳见 AppShell），这样栏和底部导航条是同一块材质。
 * 三端生产都没有未读角标，以后要加须三端一起加。
 * - 受控：选中项只由 selectedIndex 决定。用户点另一项时经 onContentWillChange 拦下系统切换、只回调 onSelect（应用外壳
 *   经 Router / EntryGuard 判定后再改 selectedIndex），selectedIndex 变化引起的切换放行、不回调。
 * - 用户点击（含点已选中的项）每次都回调 onSelect（评审 r2 R2-01）：系统 Tabs 点当前项不触发 onContentWillChange，
 *   所以点击改经 onTabBarClick 转交——宿主决定是否打开 / 刷新（例：AI 助手入口关闭后同一位置换成「搜索」，选中下标不变，
 *   再点要能打开搜索）。同一次点击随后的 onContentWillChange 只拦切换、不重复转交。
 * - 只承载栏：各 Tab 的页面由调用方自己摆（应用外壳保留各 Tab 根页的显示 / 隐藏，不随栏重建）。
 * 应用外壳（AppShell）与组件目录用的是同一个组件。
 */
@ComponentV2
export struct TabBar {
  @Param items: TabBarItem[] = [];
  @Param selectedIndex: number = 0;
  @Event onSelect: (index: number) => void = (_index: number) => {
  };
  /**
   * 点了另一项、还在等系统随后的 onContentWillChange 的下标（-1 无）。系统先回调 onTabBarClick、再回调 onContentWillChange
   * （模拟器实测，二者相隔一帧以上），点击已在前者转交，后者见到同一下标时只拦切换、不再转交。不参与渲染。
   */
  private pendingClickIndex: number = -1;

  private validIndex(index: number): boolean {
    return index >= 0 && index < this.items.length;
  }

  private bar(item: TabBarItem): BottomTabBarStyle {
    const symbols: TabSymbols = tabSymbols(item.icon);
    const normal: SymbolGlyphModifier = new SymbolGlyphModifier(symbols.normal).fontColor([CouliColors.textSecondary]);
    const selected: SymbolGlyphModifier = new SymbolGlyphModifier(symbols.selected).fontColor([CouliColors.brandPrimary]);
    return new BottomTabBarStyle({ normal: normal, selected: selected }, item.label)
      .labelStyle({ selectedColor: CouliColors.textLink, unselectedColor: CouliColors.textSecondary })
      .id('couli-tab-' + item.icon);
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.selectedIndex }) {
      ForEach(this.items, (item: TabBarItem, index: number) => {
        TabContent() {
        }
        .tabBar(this.bar(item))
      }, (item: TabBarItem, index: number) => index + item.label)
    }
    .scrollable(false)
    .height(TAB_BAR_HEIGHT)
    .width('100%')
    .onTabBarClick((index: number) => {
      // 用户点击：每次都转交，含已选中项（系统不为当前项触发 onContentWillChange）。
      if (!this.validIndex(index)) {
        return;
      }
      this.pendingClickIndex = index === this.selectedIndex ? -1 : index;
      this.onSelect(index);
    })
    .onContentWillChange((_current: number, coming: number): boolean => {
      const fromClick: boolean = coming === this.pendingClickIndex;
      this.pendingClickIndex = -1;
      if (coming === this.selectedIndex) {
        // 受控下标同步（宿主改了 selectedIndex）：放行，不回调。
        return true;
      }
      // 用户发起的切换：拦下系统切换交宿主判定。点击已在 onTabBarClick 转交；其他来源（如键盘）在这里转交。
      if (!fromClick && this.validIndex(coming)) {
        this.onSelect(coming);
      }
      return false;
    })
  }
}
