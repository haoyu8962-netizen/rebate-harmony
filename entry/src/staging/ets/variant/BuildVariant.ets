// Debug / Staging（entry 模块 staging target，product=staging）的构建变体。
// 只在 product=staging 编译；Release 产物里没有本目录的任何代码与字符串。
import BuildProfile from 'BuildProfile';
import { AppEnvironment } from 'core';
import { CouliColors, CouliInteraction, CouliRadius, CouliSpacing, CouliTypography } from 'designsystem';
import { DesignTokens } from 'generated';
import { DEBUG_PANEL_ROUTE, DebugPanel } from './DebugPanel';

// BuildProfile.BUILD_MODE_NAME 在生成文件里是字面量类型，先放宽为 string 再比较。
const BUILD_MODE: string = BuildProfile.BUILD_MODE_NAME;

export class BuildVariant {
  /** buildMode=debug → Debug；buildMode=release → Staging（映射见工程根 build-profile.json5）。 */
  static readonly CONFIG_NAME: string = BUILD_MODE === 'debug' ? 'Debug' : 'Staging';

  /** Debug 默认连 test，Staging 默认连 staging（03 §3.6）；都可在调试面板切换。 */
  static defaultEnvironment(): AppEnvironment {
    return BuildVariant.CONFIG_NAME === 'Debug' ? AppEnvironment.TEST : AppEnvironment.STAGING;
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
      DebugPanel()
    }
    .title('Debug')
    .backgroundColor(CouliColors.backgroundCanvas)
  }
}
