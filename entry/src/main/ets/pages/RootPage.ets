import { AppConfig, EnvironmentGate, RouteDestination, RouteTable } from 'core';
import {
  CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography
} from 'designsystem';
import { DefaultTexts } from 'generated';
import { VariantDestination, VariantHomeOverlay } from 'entry/ets/variant/BuildVariant';
import { AppRouting, UPGRADE_PROMPT_PAGE } from '../routing/AppRouting';
import { RoutePlaceholderPage } from './RoutePlaceholderPage';

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
    } finally {
      this.retrying = false;
    }
  }
}

/**
 * 最小首屏（AppShell 外壳）：Navigation + NavPathStack，背景 color.background.canvas。
 * 环境闸门不是 SETTLED 时不进入正常界面：BLOCKED 显示阻断页（一句说明 +【重试】），重试成功后才显示正常首屏。
 * Debug / Staging 由 src/staging 的 VariantHomeOverlay 显示令牌版本、配置名与调试面板入口（英文开发字样）；
 * Release 的 VariantHomeOverlay 是空的，首屏只有品牌色图形占位。
 * 业务页面只由 Router 推入（AppRouting.navigator）：Navigation 出现后才把栈交给 Router 并放行排队的启动意图。
 * TODO(APP-02b)：Tab、隐私闸门接管本页。
 */
@Entry
@ComponentV2
struct RootPage {
  @Local pathStack: NavPathStack = new NavPathStack();
  @Local launch: LaunchGateModel = new LaunchGateModel();

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
      Navigation(this.pathStack) {
        Column({ space: CouliSpacing.space4 }) {
          // App 名称图形占位（品牌色块）；真实 Logo 由设计稿交付后替换。
          Row()
            .width(CouliSpacing.space16)
            .height(CouliSpacing.space16)
            .borderRadius(CouliRadius.card)
            .backgroundColor(CouliColors.brandPrimary)
          VariantHomeOverlay(this.pathStack)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(CouliColors.backgroundCanvas)
      }
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .hideToolBar(true)
      .navDestination(this.routeMap)
      .backgroundColor(CouliColors.backgroundCanvas)
      .onAppear(() => {
        AppRouting.shared.attachNavigation(this.pathStack);
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
