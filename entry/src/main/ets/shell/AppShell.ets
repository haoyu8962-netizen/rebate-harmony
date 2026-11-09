import { HomeDraftTexts, PrivacyDecision } from 'core';
import {
  CouliButton, CouliButtonSize, CouliColors, CouliFocus, CouliIcon, CouliInteraction, ContentColumn, CouliRadius, CouliSpacing,
  CouliTextModifier, CouliTypography, TabBar
} from 'designsystem';
import { DefaultTexts } from 'generated';
import { VariantHomeOverlay } from 'entry/ets/variant/BuildVariant';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { AppRouting } from '../routing/AppRouting';
import { ShellDraftTexts } from './ShellDraftTexts';
import { ShellState } from './ShellState';
import { SHELL_TABS, shellTabItems, ShellTab, TabRootRegistry } from './TabRoots';

/** 设计稿顶部搜索框、【设置】按钮的视觉高（GUIDE §6：鸿蒙命中区扩到 48，视觉不变）。 */
const TOP_CONTROL_HEIGHT: number = 44;

/** 基本模式顶部提示条（APP-11 起放进首页列表顶部，HomeActions.basicNotice）。 */
@Builder
export function homeBasicNoticeBuilder() {
  // 顶部提示条：privacy.basic_mode.notice +【开启完整功能】（privacy.basic_mode.enable）。
  Column({ space: CouliSpacing.space3 }) {
    Row({ space: CouliSpacing.space2 }) {
      CouliIcon({ name: 'info', iconSize: 20, color: CouliColors.brandEmphasis })
      Text(DefaultTexts.text('privacy.basic_mode.notice') ?? '')
        .attributeModifier(new CouliTextModifier(CouliTypography.footnote, CouliColors.textPrimary))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    CouliButton({
      text: DefaultTexts.text('privacy.basic_mode.enable') ?? '',
      buttonSize: CouliButtonSize.COMPACT,
      fullWidth: true,
      buttonId: 'couli-basic-enable',
      onTap: () => {
        AppPrivacy.shared.requestFullFunction();
      }
    })
  }
  .width('100%')
  .padding(CouliSpacing.space4)
  .borderRadius(CouliRadius.card)
  .backgroundColor(CouliColors.brandSubtle)
}


/** Debug / Staging 的开发信息与调试面板入口（首页列表底部，HomeActions.footer）；Release 为空。 */
@Builder
export function homeFooterBuilder() {
  if (AppShellSlots.pathStack !== null) {
    VariantHomeOverlay(AppShellSlots.pathStack as NavPathStack)
  }
}

/** 外壳给首页列表用的导航栈（调试面板入口）。 */
export class AppShellSlots {
  static pathStack: NavPathStack | null = null;
}

/**
 * Tab 外壳（APP-02b）：DesignSystem 的 TabBar + 四个 Tab 根页（经 TabRootRegistry 按路由名取 Feature 的占位页）。
 * - 只在隐私闸门有结论（已同意 / 基本模式）后显示；出现后告诉 AppRouting「Tab 就绪」（03 §4.4），
 *   之后才恢复 pending_action、放行排队的启动意图。
 * - 基本模式：四个 Tab 照常显示（设计稿 BasicMode）；首页 Tab 换成基本模式页（顶部提示条 +【开启完整功能】+【设置】）。
 *   点 AI 助手 / 订单 / 我的：EntryGuard 判「需先同意」→ 弹首启弹窗，不切过去；同意后切过去（BR-ID-11、BR-ID-02）。
 * - TabBar 的系统模糊材质挂在栏外层、铺到底部导航条下（adaptation-a11y-spec §5），栏和导航条是同一块材质（D10-909 ③，不叠加内容）。
 */
@ComponentV2
export struct AppShell {
  @Param pathStack: NavPathStack = new NavPathStack();
  @Local privacy: AppPrivacy = AppPrivacy.shared;
  @Local shell: ShellState = ShellState.shared;

  /**
   * 点 Tab：经 Router.open（EntryGuard）打开该 Tab 的根路由。能打开时 NavStackNavigator 把它交给 ShellState 切 Tab
   * （保留只读标记）；基本模式下需同意 → 登记待办并弹首启弹窗，同意后恢复切过去；需要登录 → 登记待办并去登录页。
   */
  private select(index: number): void {
    if (SHELL_TABS[index].route === 'AgentChat' && !this.shell.agentEntryVisible) {
      // G32：入口关闭时这个位置是「搜索」：经 Router 打开 Search（auth=none），不切到 Agent 页。
      AppRouting.shared.openInApp('Search');
      return;
    }
    AppRouting.shared.openInApp(SHELL_TABS[index].route);
  }

  private basicMode(): boolean {
    return this.privacy.decision === PrivacyDecision.BASIC_MODE;
  }

  @Builder
  tabRootWith(tab: ShellTab, readonlyMode: boolean) {
    if (TabRootRegistry.builder(tab.route) !== undefined) {
      (TabRootRegistry.builder(tab.route) as WrappedBuilder<[boolean]>).builder(readonlyMode)
    }
  }

  @Builder
  tabRoot(tab: ShellTab) {
    // @Builder 按值传参不随状态刷新：用 if 分支读只读标记，标记变化时重建该 Tab 根页。
    if (this.shell.readonlyFlags[ShellState.indexOf(tab.route)] === true) {
      this.tabRootWith(tab, true)
    } else {
      this.tabRootWith(tab, false)
    }
  }

  @Builder
  basicModeTop() {
    // BasicMode.dc.html 顶部：搜索框（打开 Search）+【设置】（打开 Settings），都经 Router。
    Row({ space: CouliSpacing.space2 }) {
      Row({ space: CouliSpacing.space2 }) {
        CouliIcon({ name: 'search', iconSize: 20, color: CouliColors.textSecondary })
        Text(HomeDraftTexts.text('search.placeholder'))
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
          // 与首页搜索入口同口径（评审 r1 R1-03）：大字号下最多 2 行、末尾省略；读屏名是完整占位。
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: TOP_CONTROL_HEIGHT })
      .padding({ left: CouliSpacing.space3, right: CouliSpacing.space3, top: CouliSpacing.space2,
        bottom: CouliSpacing.space2 })
      .backgroundColor(CouliColors.backgroundSurface)
      .border({ width: 1, color: CouliColors.borderControl })
      .borderRadius(CouliRadius.button)
      .responseRegion({ x: 0, y: -2, width: '100%', height: TOP_CONTROL_HEIGHT + 4 })
      .accessibilityGroup(true)
      .accessibilityText(HomeDraftTexts.text('search.placeholder'))
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .focusable(true)
      .focusBox(CouliFocus.box)
      .onClick(() => {
        AppRouting.shared.openInApp('Search');
      })

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        CouliIcon({ name: 'settings', iconSize: 24, color: CouliColors.textPrimary })
      }
      .width(TOP_CONTROL_HEIGHT)
      .height(TOP_CONTROL_HEIGHT)
      .backgroundColor(Color.Transparent)
      .responseRegion({ x: -2, y: -2, width: CouliInteraction.minTouchTarget, height: CouliInteraction.minTouchTarget })
      .accessibilityText(ShellDraftTexts.SETTINGS)
      .focusBox(CouliFocus.box)
      .onClick(() => {
        AppRouting.shared.openInApp('Settings');
      })
    }
    .width('100%')
    // HM-07v（APP-11v Android 评审 r1 S2-4）：基本模式顶栏与首页内容列同宽（限宽 600 居中）。
    .constraintSize({ maxWidth: ContentColumn.MAX_WIDTH })
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
  }

  @Builder
  homeTab() {
    // APP-11：首页自己的 Refresh + List（固定区、SDUI 区、基本模式提示与 Debug 开发信息都在列表里，随内容一起滚动，层级与改造前一致）。
    Column() {
      if (this.basicMode()) {
        this.basicModeTop()
      }
      Column() {
        this.tabRoot(SHELL_TABS[0])
      }
      .layoutWeight(1)
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      Stack() {
        ForEach(SHELL_TABS, (tab: ShellTab, index: number) => {
          Column() {
            if (index === 0) {
              this.homeTab()
            } else {
              this.tabRoot(tab)
            }
          }
          .width('100%')
          .height('100%')
          .visibility(this.shell.selected === index ? Visibility.Visible : Visibility.None)
        }, (tab: ShellTab) => tab.route)
      }
      .layoutWeight(1)
      .width('100%')

      Column() {
        TabBar({
          items: shellTabItems(this.shell.agentEntryVisible),
          selectedIndex: this.shell.selected,
          onSelect: (index: number) => {
            this.select(index);
          }
        })
      }
      .width('100%')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor(CouliColors.backgroundCanvas)
    .onAppear(() => {
      // 外壳第一次出现：先经 Router 打开首页 Tab（定下首页的只读标记），再告诉 AppRouting「Tab 就绪」恢复待办与启动意图。
      // 外壳重建（配置变化等）不重新判定，保留已保存的 Tab 与只读标记。
      if (!ShellState.shared.rootsOpened) {
        AppRouting.shared.openInApp('Home');
      }
      AppRouting.shared.setShellReady(true);
    })
    .onDisAppear(() => {
      AppRouting.shared.setShellReady(false);
    })
  }
}
