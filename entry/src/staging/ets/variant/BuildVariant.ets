// Debug / Staging（entry 模块 staging target，product=staging）的构建变体。
// 只在 product=staging 编译；Release 产物里没有本目录的任何代码与字符串。
import { common, Want } from '@kit.AbilityKit';
import BuildProfile from 'BuildProfile';
import { AppEnvironment, CouliPreferences, DeepLinkConfig, RouteTable, UpdateChecker } from 'core';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from 'designsystem';
import { DebugRoutes, DesignTokens } from 'generated';
import { DEBUG_PANEL_ROUTE, DebugPanel } from './DebugPanel';
import { DebugUpdateChecker } from './DebugUpdate';
import {
  CATALOG_ROUTE, COMPARE_ME, COMPARE_PRODUCT, COMPARE_SEARCH, COMPARE_SEARCH_EMPTY, COMPARE_STRESS, COMPARE_WALLET,
  CompareMe, CompareProduct, CompareProductCardStress, CompareSearch, CompareSearchEmpty, CompareWallet,
  ComponentCatalog
} from '../catalog/ComponentCatalog';

// BuildProfile.BUILD_MODE_NAME 在生成文件里是字面量类型，先放宽为 string 再比较。
const BUILD_MODE: string = BuildProfile.BUILD_MODE_NAME;

export class BuildVariant {
  /** buildMode=debug → Debug；buildMode=release → Staging（映射见工程根 build-profile.json5）。 */
  static readonly CONFIG_NAME: string = BUILD_MODE === 'debug' ? 'Debug' : 'Staging';

  /** Debug 默认连 test，Staging 默认连 staging（03 §3.6）；都可在调试面板切换。 */
  static defaultEnvironment(): AppEnvironment {
    return BuildVariant.CONFIG_NAME === 'Debug' ? AppEnvironment.TEST : AppEnvironment.STAGING;
  }

  /** 守卫的 isDebugBuild：Debug / Staging 为 true（debug_only 路由可开）。 */
  static readonly IS_DEBUG_BUILD: boolean = true;

  /**
   * 深链入站配置：只认测试 scheme couli-debug（APP-02a 冒烟用；module.json 的 skills 也只在 product=staging 声明，
   * 见 entry/hvigorfile.ts）。正式 scheme 与 l. 子域未定（needs N-05），不在这里放任何域名。
   */
  static deepLinkConfig(): DeepLinkConfig {
    return new DeepLinkConfig(['couli-debug'], []);
  }

  /**
   * 版本检查器：读调试面板选的场景，返回契约示例改字段得到的假结果（APP-02c）；prod 环境下按请求失败。
   * TODO(APP-03): 网络层接入后，test / staging 环境改走真实请求，假数据只在调试面板显式选择时使用。
   */
  static updateChecker(context: common.Context): UpdateChecker {
    return new DebugUpdateChecker(context);
  }

  /** 强更结论存储：调试假结果只写 couli_update_debug，不写 Release 读取的 couli_update（三端统一裁定）。 */
  static readonly UPDATE_NAMESPACE: string = CouliPreferences.UPDATE_DEBUG_NAMESPACE;

  /** 把 debug_only 路由并入本构建的路由表（Release 的同名函数什么都不做）。 */
  static registerDebugOnlyTable(): void {
    RouteTable.registerDebugOnlyTable(DebugRoutes.all);
  }

  /**
   * 冒烟与截图用的启动参数（只在 Debug / Staging）：`aa start ... --pd couli_debug_font_scale 2` 让本次进程按该字号倍数
   * 渲染（ApplicationContext.setFontSizeScale）。用于在首启弹窗出现前就切到 200%：本机模拟器的系统字号设置不改变应用的
   * fontSizeScale（DS-01 compare-harmony §0）。只读这一个调试键，不影响 AppRouting 只认 want.uri 的规则。
   */
  static applyLaunchOptions(context: common.ApplicationContext, want: Want): void {
    const raw: Object | undefined = want.parameters?.['couli_debug_font_scale'];
    if (typeof raw !== 'string' && typeof raw !== 'number') {
      return;
    }
    const scale: number = Number(raw);
    if (Number.isNaN(scale) || scale < 0.5 || scale > 3.2) {
      return;
    }
    try {
      context.setFontSizeScale(scale);
    } catch (e) {
      // 设置失败时按系统字号继续。
    }
  }
}

/** 首屏开发信息：令牌版本、构建配置名、调试面板入口（英文开发字样）。 */
@Builder
export function VariantHomeOverlay(pathStack: NavPathStack) {
  Column({ space: CouliSpacing.space2 }) {
    Text('tokens ' + DesignTokens.version)
      .fontSize(CouliTypography.footnote.fontSize)
      .fontColor(CouliColors.textSecondary)
    Text('config ' + BuildVariant.CONFIG_NAME)
      .fontSize(CouliTypography.footnote.fontSize)
      .fontColor(CouliColors.textSecondary)
    Button('Debug panel')
      .height(CouliInteraction.minTouchTarget)
      .borderRadius(CouliRadius.button)
      .backgroundColor(CouliColors.buttonPrimaryDefaultBackground)
      .fontColor(CouliColors.buttonPrimaryDefaultText)
      .onClick(() => {
        pathStack.pushPathByName(DEBUG_PANEL_ROUTE, null);
      })
  }
}

@Builder
export function VariantDestination(name: string, param: Object) {
  if (name === DEBUG_PANEL_ROUTE) {
    NavDestination() {
      DebugPanelHost()
    }
    .title('Debug')
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === CATALOG_ROUTE) {
    // 组件目录页（DS-01）：从调试面板进入。
    NavDestination() {
      CatalogHost({ route: name })
    }
    .title('Components')
    .backgroundColor(CouliColors.backgroundCanvas)
  } else if (name === COMPARE_SEARCH || name === COMPARE_STRESS || name === COMPARE_PRODUCT
    || name === COMPARE_WALLET || name === COMPARE_ME || name === COMPARE_SEARCH_EMPTY) {
    // 设计对照页：不显示系统标题栏，整页按画板拼出。
    NavDestination() {
      CatalogHost({ route: name })
    }
    .hideTitleBar(true)
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}

/** 把导航栈交给调试面板（用于进入组件目录页）。 */
@ComponentV2
struct DebugPanelHost {
  @Local stack: NavPathStack | undefined = undefined;

  aboutToAppear(): void {
    this.stack = this.queryNavigationInfo()?.pathStack;
  }

  build() {
    DebugPanel({ pathStack: this.stack })
  }
}

/** 取到当前导航栈后渲染目录页 / 对照页。 */
@ComponentV2
struct CatalogHost {
  @Param route: string = '';
  @Local stack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    const s: NavPathStack | undefined = this.queryNavigationInfo()?.pathStack;
    if (s !== undefined) {
      this.stack = s;
    }
  }

  build() {
    if (this.route === CATALOG_ROUTE) {
      ComponentCatalog({ pathStack: this.stack })
    } else if (this.route === COMPARE_SEARCH) {
      CompareSearch()
    } else if (this.route === COMPARE_STRESS) {
      CompareProductCardStress()
    } else if (this.route === COMPARE_PRODUCT) {
      CompareProduct({ pathStack: this.stack })
    } else if (this.route === COMPARE_WALLET) {
      CompareWallet({ pathStack: this.stack })
    } else if (this.route === COMPARE_ME) {
      CompareMe()
    } else if (this.route === COMPARE_SEARCH_EMPTY) {
      CompareSearchEmpty()
    }
  }
}
