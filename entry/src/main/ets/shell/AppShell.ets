import { PrivacyDecision } from 'core';
import {
  CouliButton, CouliButtonSize, CouliColors, CouliFocus, CouliIcon, CouliInteraction, CouliRadius, CouliSpacing,
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

/**
 * Tab 外壳（APP-02b）：DesignSystem 的 TabBar + 四个 Tab 根页（经 TabRootRegistry 按路由名取 Feature 的占位页）。
 * - 只在隐私闸门有结论（已同意 / 基本模式）后显示；出现后告诉 AppRouting「Tab 就绪」（03 §4.4），
 *   之后才恢复 pending_action、放行排队的启动意图。
 * - 基本模式：四个 Tab 照常显示（设计稿 BasicMode）；首页 Tab 换成基本模式页（顶部提示条 +【开启完整功能】+【设置】）。
 *   点 AI 助手 / 订单 / 我的：EntryGuard 判「需先同意」→ 弹首启弹窗，不切过去；同意后切过去（BR-ID-11、BR-ID-02）。
 * - TabBar 白底铺到底部导航条下（adaptation-a11y-spec §5）。
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
        Text(ShellDraftTexts.BASIC_SEARCH_PLACEHOLDER)
          .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textSecondary))
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
    .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space2,
      bottom: CouliSpacing.space2 })
  }

  @Builder
  basicModeNotice() {
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

  @Builder
  homeTab() {
    Column() {
      if (this.basicMode()) {
        this.basicModeTop()
      }
      Scroll() {
        Column({ space: CouliSpacing.space3 }) {
          if (this.basicMode()) {
            this.basicModeNotice()
          }
          this.tabRoot(SHELL_TABS[0])
          // Debug / Staging：令牌版本、配置名与调试面板入口；Release 为空。
          VariantHomeOverlay(this.pathStack)
        }
        .width('100%')
        .padding({ left: CouliSpacing.space4, right: CouliSpacing.space4, top: CouliSpacing.space1,
          bottom: CouliSpacing.space4 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.None)
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
          items: shellTabItems(),
          selectedIndex: this.shell.selected,
          onSelect: (index: number) => {
            this.select(index);
          }
        })
      }
      .width('100%')
      .backgroundColor(CouliColors.backgroundSurface)
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
