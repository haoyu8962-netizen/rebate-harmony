import { SymbolGlyphModifier } from '@kit.ArkUI';
import { CouliColors } from '../CouliColors';
import { CouliComponentMetrics, CouliInteraction, CouliSpacing } from '../CouliMetrics';
import { CouliFontWeight, CouliTypography } from '../CouliTypography';
import { CouliIcon } from './CouliIcon';
import { CouliTextModifier } from './CouliText';

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

/** Tab 栏的一项（文字由调用方给：首页 / AI 助手 / 订单 / 我的）。 */
export class TabBarItem {
  readonly label: string;
  readonly icon: string;
  /** 读屏的角色与位置说明（如「标签，第 1 个，共 4 个」，由调用方给；空串不设）。选中状态由 accessibilitySelected 读出。 */
  readonly accessibilityHint: string;

  constructor(label: string, icon: string, accessibilityHint: string = '') {
    this.label = label;
    this.icon = icon;
    this.accessibilityHint = accessibilityHint;
  }
}

/** 底栏高：命中区 48 + 上下留白（选中项图标狸橙、文字深橙 600）。 */
const TAB_BAR_HEIGHT: number = CouliInteraction.minTouchTarget + CouliSpacing.space3;

/**
 * 一级底部标签栏（清单 §3.4 TabBar，评审 r1 R1-01）：系统 Tabs(barPosition End)，每项的 tabBar 用凑狸自有矢量图标 + 文字
 * （BottomTabBarStyle 只接图片资源，凑狸图标是路径，所以用自定义 tabBar 构建；容器、切换、焦点与读屏仍是系统 Tabs）；
 * 带角标的项挂系统 Badge（T4）。栏的上沿是系统 Tabs 的分隔线（border.subtle），底 background.surface。
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
  /** 挂红点的项（-1 不挂）。 */
  @Param badgeIndex: number = -1;
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

  @Builder
  bar(item: TabBarItem, index: number) {
    Column({ space: 2 }) {
      if (index === this.badgeIndex) {
        Badge({ value: '', position: BadgePosition.RightTop,
          style: { badgeSize: 8, badgeColor: CouliColors.badgeBackground } }) {
          CouliIcon({
            name: item.icon, iconSize: 24,
            color: index === this.selectedIndex ? CouliColors.brandPrimary : CouliColors.textSecondary
          })
        }
      } else {
        CouliIcon({
          name: item.icon, iconSize: 24,
          color: index === this.selectedIndex ? CouliColors.brandPrimary : CouliColors.textSecondary
        })
      }
      Text(item.label)
        .attributeModifier(new CouliTextModifier(CouliTypography.caption,
          index === this.selectedIndex ? CouliColors.textLink : CouliColors.textSecondary,
          index === this.selectedIndex ? CouliFontWeight.semibold : CouliFontWeight.regular))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .accessibilityGroup(true)
    .accessibilityText(item.label)
    .accessibilityDescription(item.accessibilityHint)
    .accessibilitySelected(index === this.selectedIndex)
  }

  build() {
    Tabs({ barPosition: BarPosition.End, index: this.selectedIndex }) {
      ForEach(this.items, (item: TabBarItem, index: number) => {
        TabContent() {
        }
        .tabBar(this.bar(item, index))
      }, (item: TabBarItem, index: number) => index + item.label)
    }
    .barHeight(TAB_BAR_HEIGHT)
    .barBackgroundColor(CouliColors.backgroundSurface)
    .divider({ strokeWidth: CouliComponentMetrics.controlBorderWidth, color: CouliColors.borderSubtle })
    .scrollable(false)
    .animationDuration(0)
    .height(TAB_BAR_HEIGHT + CouliComponentMetrics.controlBorderWidth)
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
