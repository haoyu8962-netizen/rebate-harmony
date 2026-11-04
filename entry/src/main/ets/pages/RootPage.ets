import {
  AppConfig, EnvironmentGate, ExternalPageOptions, PrivacyDecision, PrivacyPromptStage, RouteDestination, RoutePolicy,
  RouteTable, UpdateStatusRaw
} from 'core';
import {
  CouliColors, CouliFontWeight, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { DefaultTexts } from 'generated';
import { BuildVariant, VariantDestination } from 'entry/ets/variant/BuildVariant';
import { PermissionPrompt } from '../permission/PermissionPrompt';
import { PermissionPromptModel } from '../permission/PermissionPromptModel';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { PrivacyPrompt } from '../privacy/PrivacyPrompt';
import { AppRouting, UPGRADE_PROMPT_PAGE } from '../routing/AppRouting';
import { AppShell, AppShellSlots, homeBasicNoticeBuilder, homeFooterBuilder } from '../shell/AppShell';
import { HomeActions } from 'home';
import { ShellDraftTexts } from '../shell/ShellDraftTexts';
import { AppUpdate } from '../update/AppUpdate';
import { ForceUpdatePage } from '../update/ForceUpdatePage';
import { UpdatePrompt } from '../update/UpdatePrompt';
import { RoutePlaceholderPage } from './RoutePlaceholderPage';
import { AppLogin } from '../login/AppLogin';
import { AppBindPhonePage, AppLoginPage, destinationReadonly } from '../login/LoginPages';
import { AppExternalPage, AppWebPage, destinationUrl } from '../web/WebPages';
import { AppProductPage, AppSearch, AppSearchPage } from '../search/AppSearch';
import { AuthManagePage } from '../trade/AuthManagePage';
import { AppClipboard } from '../clipboard/AppClipboard';
import { AppOrders } from '../orders/AppOrders';
import { AppOrderDetailPage, appOrdersTabBuilder } from '../orders/OrderPages';
import { TabRootSlots } from '../shell/TabRoots';
import { appAgentTabBuilder } from '../agent/AgentPages';
import { AppAgent } from '../agent/AppAgent';
import { AppWallet } from '../wallet/AppWallet';
import {
  AppLaborAgreementPage, AppPayoutAccountPage, AppRealNamePage, AppWalletPage, AppWithdrawPage, AppWithdrawRecordsPage
} from '../wallet/WalletPages';
import { CsSheetView } from 'me';
import { AppMe } from '../me/AppMe';
import { AppHome } from '../home/AppHome';
import { AppCsSheet } from '../me/AppCsSheet';
import { AppDeleteAccountPage } from '../account/AccountPages';
import {
  AppAboutPage, AppAppealPage, AppPrivacyCenterPage, AppRiskNoticePage, AppSettingsPage, appMeTabBuilder
} from '../me/MePages';

/** 启动背景的品牌块（LaunchPrivacy / LaunchSecondNotice 弹窗后面）：88 见方、圆角 20、文字 22/700。 */
const BRAND_MARK_SIZE: number = 88;
const BRAND_MARK_RADIUS: number = 20;
const BRAND_MARK_FONT: number = 22;

/**
 * 阻断页文案（不硬编码）：从生成的 DefaultTexts 取已有的通用键，与 iOS 同口径。
 * - 说明：error.50001 的 fallback「出了点问题，请稍后再试」（通用失败；text 版本带 {trace6} 占位，这里没有 trace，故用 fallback）。
 * - 按钮：external_page.retry「重试」。契约里没有通用的 common.retry / 启动阻断专用键，待补键见交付说明。
 */
const BLOCKED_MESSAGE_KEY: string = 'error.50001';
const RETRY_KEY: string = 'external_page.retry';
const SETTINGS_ROUTE: string = 'Settings';
const SEARCH_ROUTE: string = 'Search';
const PRODUCT_DETAIL_ROUTE: string = 'ProductDetail';
const AUTH_MANAGE_ROUTE: string = 'AuthManage';
const ORDER_DETAIL_ROUTE: string = 'OrderDetail';

/** 首屏观察的环境闸门状态。 */
@ObservedV2
class LaunchGateModel {
  @Trace gate: EnvironmentGate = AppConfig.gate();
  @Trace retrying: boolean = false;

  async retry(): Promise<void> {
    if (this.retrying) {
      return;
    }
    this.retrying = true;
    try {
      this.gate = await AppConfig.retry();
      if (this.gate === EnvironmentGate.SETTLED) {
        // Debug / Staging：暂存的剪贴板、分享样例按此刻环境执行或丢弃（FU-HM-0711b R1-05）；Release 为空。
        BuildVariant.environmentSettled();
        AppPrivacy.shared.environmentSettled();
      }
    } finally {
      this.retrying = false;
    }
  }
}

/**
 * 首屏：Navigation + NavPathStack，背景 color.background.canvas。冷启动顺序（03 §4.4）：
 * 1. 环境闸门：不是 SETTLED 时不进入正常界面，BLOCKED 显示阻断页（一句说明 +【重试】）；
 * 2. 隐私闸门：没有结论（首启、版本升级后）只显示启动背景 + 首启弹窗 / 二次说明，不显示 Tab；
 * 3. 有结论（已同意 / 基本模式）→ Tab 外壳（AppShell）出现，即「Tab 就绪」，之后才恢复 pending_action、执行启动意图。
 * 弹窗是模态：遮罩吃掉触摸；底层对读屏隐藏；返回键在弹窗显示时不响应（onBackPress 返回 true，BR-ID-11）。
 * 弹窗里点协议链接时 Agreement 页盖在弹窗上（弹窗暂时让出），返回到打开协议前的页面（导航根或强更页）后弹窗重新出现。
 * 业务页面只由 Router 推入（AppRouting.navigator）。
 * 强更（APP-02c）：ForceUpdate 由 Router / AppRouting.syncForceUpdatePage 推入（全屏、返回键不能离开）；可关闭更新提示
 * （MainUpdatePrompt）在外壳之上居中显示，隐私弹窗显示时让位，显示时底层对读屏隐藏、返回键不响应。
 */
@Entry
@ComponentV2
struct RootPage {
  @Local pathStack: NavPathStack = new NavPathStack();
  @Local launch: LaunchGateModel = new LaunchGateModel();
  @Local privacy: AppPrivacy = AppPrivacy.shared;
  @Local update: AppUpdate = AppUpdate.shared;
  @Local permissionPrompt: PermissionPromptModel = PermissionPromptModel.shared;
  @Local cs: AppCsSheet = AppCsSheet.shared;

  aboutToAppear(): void {
    // APP-08：订单 Tab 根页（entry 组合）在外壳构建前登记（见 TabRootSlots）。
    TabRootSlots.orders = wrapBuilder(appOrdersTabBuilder);
    // APP-12：「我的」Tab 根页（entry 组合）同样在外壳构建前登记。
    TabRootSlots.me = wrapBuilder(appMeTabBuilder);
    // APP-10：AI 助手 Tab 根页（entry 组合：页面 + 购买浮层）。
    TabRootSlots.agent = wrapBuilder(appAgentTabBuilder);
    // APP-11：首页列表里的基本模式提示与 Debug 开发信息（外壳的 builder，首页模块不 import entry）。
    AppShellSlots.pathStack = this.pathStack;
    HomeActions.basicNotice = wrapBuilder(homeBasicNoticeBuilder);
    HomeActions.footer = wrapBuilder(homeFooterBuilder);
  }

  /** 弹窗显示时吞掉返回键（不进入首页、不记为同意或拒绝）；协议页盖在上面时照常返回到弹窗。可关闭更新提示同样只能点按钮。 */
  onBackPress(): boolean {
    return AppPrivacy.shared.blocksBack || this.updatePromptVisible() || this.permissionPromptVisible();
  }

  /** 权限用途说明 / 去设置引导（APP-03b，PermissionRequester）：隐私弹窗显示时让位。 */
  private permissionPromptVisible(): boolean {
    return this.permissionPrompt.visible && !this.promptVisible();
  }

  /** 可关闭更新提示：below_recommended 且该弹、外壳已显示、隐私弹窗没在显示。 */
  private updatePromptVisible(): boolean {
    return this.update.showPrompt && this.update.statusRaw === UpdateStatusRaw.BELOW_RECOMMENDED
      && this.shellVisible() && !this.promptVisible();
  }

  private promptVisible(): boolean {
    return this.privacy.stage !== PrivacyPromptStage.NONE && !this.privacy.promptCovered;
  }

  /** 隐私闸门有结论（已同意当前版本或基本模式）：显示 Tab 外壳。 */
  private shellVisible(): boolean {
    return this.privacy.loaded && this.privacy.decision !== PrivacyDecision.NOT_DECIDED;
  }

  @Builder
  launchBackdrop() {
    // 启动背景（设计稿 LaunchPrivacy 弹窗后面）：画布底色 + 居中品牌块。纯装饰，读屏忽略。
    Column() {
      Text(ShellDraftTexts.BRAND_MARK)
        .attributeModifier(new CouliTextModifier(CouliTypography.body, CouliColors.textInverse, CouliFontWeight.bold))
        .fontSize(BRAND_MARK_FONT)
        .letterSpacing(2)
        .textAlign(TextAlign.Center)
        .width(BRAND_MARK_SIZE)
        .height(BRAND_MARK_SIZE)
        .borderRadius(BRAND_MARK_RADIUS)
        .backgroundColor(CouliColors.brandPrimary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(CouliColors.backgroundCanvas)
    .accessibilityLevel('no-hide-descendants')
  }

  @Builder
  routeMap(name: string, param: Object) {
    if (name === RoutePolicy.FORCE_UPDATE) {
      // 强更全屏页（APP-02c）。
      ForceUpdatePage()
    } else if (name === RoutePolicy.WEB_PAGE) {
      // 可信容器（APP-04）。
      AppWebPage({ url: destinationUrl(param) })
    } else if (name === RoutePolicy.EXTERNAL_PAGE) {
      // 第三方页容器（APP-04）。
      AppExternalPage({ options: ExternalPageOptions.fromDestination(param) })
    } else if (name === RoutePolicy.LOGIN) {
      // 登录页（APP-05a）。强更状态下守卫只放行从强更页进入的 Login：带受限登录标记（不显示邀请码等业务输入）。
      AppLoginPage({ restrictedLogin: AppUpdate.shared.belowMin })
    } else if (name === RoutePolicy.BIND_PHONE) {
      // 绑手机页（APP-05b）。
      AppBindPhonePage()
    } else if (name === SEARCH_ROUTE) {
      // 搜索页（APP-06a）。参数只认 Router 放进来的 RouteDestination（q、platform）。
      AppSearchPage({ param: param })
    } else if (name === PRODUCT_DETAIL_ROUTE) {
      // 商品详情（APP-06a）：platform、product_key、item_ref。
      AppProductPage({ param: param })
    } else if (name === ORDER_DETAIL_ROUTE) {
      // 订单详情（APP-08）：order_id。
      AppOrderDetailPage({ param: param })
    } else if (name === 'Wallet') {
      // 钱包（APP-09）。
      AppWalletPage()
    } else if (name === 'Withdraw') {
      // 提现申请（APP-09）：不接受任何参数（Router 已丢弃）。
      AppWithdrawPage()
    } else if (name === 'WithdrawRecords') {
      // 提现记录（APP-09）：withdrawal_id?。
      AppWithdrawRecordsPage({ param: param })
    } else if (name === 'PayoutAccount') {
      AppPayoutAccountPage()
    } else if (name === 'RealName') {
      AppRealNamePage()
    } else if (name === 'LaborAgreement') {
      AppLaborAgreementPage()
    } else if (name === AUTH_MANAGE_ROUTE) {
      // 授权管理（APP-06b）：只显示已授权 / 未授权，页内【去授权】由用户点击发起。
      AuthManagePage()
    } else if (name === SETTINGS_ROUTE) {
      // 设置（APP-12）：按基本模式 / 游客 / 已登录裁剪条目；修改昵称、通知设置、协议选择是页内子页。
      AppSettingsPage({ readonlyMode: destinationReadonly(param) })
    } else if (name === 'PrivacyCenter') {
      // 隐私中心（APP-12）：基本模式只读并显示【开启完整功能】。强更状态下守卫只放行从强更页进入的隐私中心（03 §4.1 次要入口）：
      // 带受限上下文，只显示协议、清单与撤回入口，协议跳转走强更次要入口（R2-05）。
      AppPrivacyCenterPage({ fromForceUpdate: AppUpdate.shared.belowMin })
    } else if (name === 'DeleteAccount') {
      // 注销页（APP-13a）：params 为空对象（Router 已丢弃）；强更状态下守卫只放行从强更页进入的 DeleteAccount（受限会话可用）。
      AppDeleteAccountPage({ fromForceUpdate: AppUpdate.shared.belowMin })
    } else if (name === 'About') {
      AppAboutPage()
    } else if (name === 'RiskNotice') {
      // 封禁 / 冻结说明（APP-12）：10006 的统一落点。
      AppRiskNoticePage()
    } else if (name === 'Appeal') {
      // 账户申诉（APP-12）：提交、进度、结果同一页。
      AppAppealPage()
    } else if (BuildVariant.ownsRoute(name)) {
      // Debug / Staging 的调试专用页（APP-11 HomePreview 等，debug_only）：Release 的同名函数恒为 false。
      VariantDestination(name, param)
    } else if (name === UPGRADE_PROMPT_PAGE || RouteTable.has(name)) {
      // 业务路由与内置升级提示页：占位页（各 Feature 的入口视图接入前）。参数只认 Router 放进来的 RouteDestination。
      // 强更状态下守卫只放行从强更页进入的次要入口，所以 below_min 时出现的这几页都来自强更页：带强更状态 / 受限登录标记。
      RoutePlaceholderPage({
        route: name,
        readonlyMode: param instanceof RouteDestination ? (param as RouteDestination).readonly : false,
        fromForceUpdate: AppUpdate.shared.belowMin && RoutePolicy.FORCE_UPDATE_SECONDARY_ROUTES.indexOf(name) >= 0
      })
    } else {
      VariantDestination(name, param)
    }
  }

  @Builder
  csSheet() {
    Column() {
      CsSheetView({ decision: this.cs.decision, actions: this.cs.actions })
    }
    .width('100%')
  }

  @Builder
  blockedPage() {
    Column({ space: CouliSpacing.space4 }) {
      Text(DefaultTexts.fallback(BLOCKED_MESSAGE_KEY) ?? '')
        .fontSize(CouliTypography.body.fontSize)
        .fontColor(CouliColors.textPrimary)
        .textAlign(TextAlign.Center)
      Button(DefaultTexts.text(RETRY_KEY) ?? '')
        .height(CouliInteraction.minTouchTarget)
        .borderRadius(CouliRadius.button)
        .backgroundColor(CouliColors.buttonPrimaryDefaultBackground)
        .fontColor(CouliColors.buttonPrimaryDefaultText)
        .enabled(!this.launch.retrying)
        .onClick(() => {
          this.launch.retry();
        })
    }
    .width('100%')
    .height('100%')
    .padding(CouliSpacing.space4)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(CouliColors.backgroundCanvas)
  }

  /** 根布局宽度：窗口宽度；Debug / Staging 可用启动参数限制为窄屏宽度截图（BuildVariant.layoutWidthOverride）。 */
  private rootWidth(): Length {
    const width: number | null = BuildVariant.layoutWidthOverride();
    return width === null ? '100%' : width;
  }

  build() {
    if (this.launch.gate === EnvironmentGate.SETTLED) {
      Stack() {
        Navigation(this.pathStack) {
          if (this.shellVisible()) {
            AppShell({ pathStack: this.pathStack })
          } else {
            this.launchBackdrop()
          }
        }
        .mode(NavigationMode.Stack)
        .hideTitleBar(true)
        .hideToolBar(true)
        .navDestination(this.routeMap)
        .backgroundColor(CouliColors.backgroundCanvas)
        // 弹窗显示时底层（Tab 外壳与已推入的页面）对读屏隐藏，焦点只在弹窗内（adaptation-a11y-spec §8）。
        .accessibilityLevel(this.promptVisible() || this.updatePromptVisible() || this.permissionPromptVisible() ?
          'no-hide-descendants' : 'auto')
        .onAppear(() => {
          // 从弹窗里打开的协议页返回到宿主页（导航根，或强更页等 NavDestination，R2-02）：弹窗重新出现。
          this.pathStack.setInterception({
            willShow: (_from: NavDestinationContext | NavBar, _to: NavDestinationContext | NavBar) => {
              // APP-07：系统返回等不经 StackNavigator 的栈变化，在转场开始时同步给剪贴板识别（当前前台界面）。
              AppClipboard.shared.stackChanged(this.pathStack.getAllPathName());
              // FU-HM-0712 R1-02：栈非空即 Tab 根被盖住，订单列表顶部的待跟单卡同步离开显示位置。
              AppOrders.shared.stackChanged(this.pathStack.getAllPathName());
              // APP-11 R2-03：首页被推入的页面盖住时，在转场开始就收起或抑制首页弹窗。
              AppHome.shared.navigationWillShow(this.pathStack.getAllPathName());
            },
            didShow: (_from: NavDestinationContext | NavBar, _to: NavDestinationContext | NavBar) => {
              AppPrivacy.shared.navigationShown(this.pathStack.getAllPathName());
              AppClipboard.shared.stackChanged(this.pathStack.getAllPathName());
              // APP-12：从子页回到「我的」Tab（导航根）时取一次 /v1/me（G36）。
              AppMe.shared.navigationShown(this.pathStack.getAllPathName());
              // APP-11：回到首页（导航根）时复核弹窗阻挡项。
              AppHome.shared.navigationShown(this.pathStack.getAllPathName());
              // APP-10：Agent 页被盖住 / 回到导航根（同意弹窗打开前复核可见性、购买续执行许可）。
              AppAgent.shared.navigationShown(this.pathStack.getAllPathName());
            }
          });
          AppRouting.shared.attachNavigation(this.pathStack);
          // APP-11 鸿蒙复核 RC-01：Ability 重建后挂上新的（可能为空的）导航栈，空栈初显没有转场回调，按真实 Tab、栈、前后台重设首页可见性。
          AppHome.shared.navigationAttached(this.pathStack.getAllPathName());
          // 登录成功后的邀请结果提示用根页的界面上下文（登录页已出栈）。
          AppLogin.shared.attachUi(this.getUIContext());
          AppSearch.shared.attachUi(this.getUIContext());
          AppClipboard.shared.attachUi(this.getUIContext());
          AppOrders.shared.attachUi(this.getUIContext());
          AppWallet.shared.attachUi(this.getUIContext());
          AppMe.shared.attachUi(this.getUIContext());
          AppHome.shared.attachUi(this.getUIContext());
          AppAgent.shared.attachUi(this.getUIContext());
        })

        if (this.promptVisible()) {
          PrivacyPrompt({ stage: this.privacy.stage })
        } else if (this.permissionPromptVisible()) {
          PermissionPrompt()
        } else if (this.updatePromptVisible()) {
          UpdatePrompt()
        }
      }
      .width(this.rootWidth())
      .height('100%')
      // APP-12 统一客服出口的三张半屏（CsHandoff / CsWechatMissing / CsOpenFailed）：任何页面打开都盖在最上层；系统返回、下滑先关半屏，
      // 关闭后焦点回到触发控件（AdaptSheetRules）。
      .bindSheet(this.cs.shown, this.csSheet(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        maskColor: CouliColors.overlayScrim,
        onDisappear: () => {
          this.cs.disappeared(this.getUIContext());
        }
      })
    } else if (this.launch.gate === EnvironmentGate.BLOCKED) {
      this.blockedPage()
    } else {
      // PENDING：EntryAbility 等对账有结论后才加载本页，正常走不到这里；只铺背景，不进入任何界面。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(CouliColors.backgroundCanvas)
    }
  }
}
