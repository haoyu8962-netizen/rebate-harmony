import { AppConfig, EnvironmentGate, PrivacyDecision, PrivacyPromptStage, RouteDestination, RouteTable } from 'core';
import {
  CouliColors, CouliFontWeight, CouliInteraction, CouliRadius, CouliSpacing, CouliTextModifier, CouliTypography
} from 'designsystem';
import { DefaultTexts } from 'generated';
import { VariantDestination } from 'entry/ets/variant/BuildVariant';
import { AppPrivacy } from '../privacy/AppPrivacy';
import { PrivacyPrompt } from '../privacy/PrivacyPrompt';
import { AppRouting, UPGRADE_PROMPT_PAGE } from '../routing/AppRouting';
import { AppShell } from '../shell/AppShell';
import { ShellDraftTexts } from '../shell/ShellDraftTexts';
import { RoutePlaceholderPage } from './RoutePlaceholderPage';

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
 * 弹窗里点协议链接时 Agreement 页盖在弹窗上（弹窗暂时让出），返回到导航根后弹窗重新出现。
 * 业务页面只由 Router 推入（AppRouting.navigator）。
 */
@Entry
@ComponentV2
struct RootPage {
  @Local pathStack: NavPathStack = new NavPathStack();
  @Local launch: LaunchGateModel = new LaunchGateModel();
  @Local privacy: AppPrivacy = AppPrivacy.shared;

  /** 弹窗显示时吞掉返回键（不进入首页、不记为同意或拒绝）；协议页盖在上面时照常返回到弹窗。 */
  onBackPress(): boolean {
    return AppPrivacy.shared.blocksBack;
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
    if (name === UPGRADE_PROMPT_PAGE || RouteTable.has(name)) {
      // 业务路由与内置升级提示页：占位页（各 Feature 的入口视图接入前）。参数只认 Router 放进来的 RouteDestination。
      RoutePlaceholderPage({
        route: name,
        readonlyMode: param instanceof RouteDestination ? (param as RouteDestination).readonly : false
      })
    } else {
      VariantDestination(name, param)
    }
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
        .accessibilityLevel(this.promptVisible() ? 'no-hide-descendants' : 'auto')
        .onAppear(() => {
          // 回到导航根（含从弹窗里打开的协议页返回）：弹窗重新出现。
          this.pathStack.setInterception({
            didShow: (_from: NavDestinationContext | NavBar, to: NavDestinationContext | NavBar) => {
              if (typeof to === 'string') {
                AppPrivacy.shared.returnedToRoot();
              }
            }
          });
          AppRouting.shared.attachNavigation(this.pathStack);
        })

        if (this.promptVisible()) {
          PrivacyPrompt({ stage: this.privacy.stage })
        }
      }
      .width('100%')
      .height('100%')
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
