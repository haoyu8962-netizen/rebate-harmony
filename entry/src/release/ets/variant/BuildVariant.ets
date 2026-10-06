// Release（entry 模块 default target，product=default）的构建变体。
// 与 src/staging/ets/variant/BuildVariant.ets 同名同接口，由 hvigor 按 target 二选一编译；
// 本文件不得引用任何调试能力、非 prod 地址或 debug_only 路由（tools/ci/release-scan.sh 检查产物）。
import { common, Want } from '@kit.AbilityKit';
import { AppEnvironment, DeepLinkConfig } from 'core';

export class BuildVariant {
  static readonly CONFIG_NAME: string = 'Release';

  static defaultEnvironment(): AppEnvironment {
    return AppEnvironment.PROD;
  }

  static readonly IS_DEBUG_BUILD: boolean = false;

  /** TODO(N-05): 正式 scheme 与 l. 子域由 apps.json inbound 给出后生成；在此之前 Release 不认任何深链。 */
  static deepLinkConfig(): DeepLinkConfig {
    return DeepLinkConfig.EMPTY;
  }

  /** Release 没有 debug_only 路由。 */
  static registerDebugOnlyTable(): void {
  }

  /** Release 不认任何调试启动参数。 */
  static applyLaunchOptions(context: common.ApplicationContext, want: Want): void {
  }
}

/** Release 首屏不叠加任何内容。 */
@Builder
export function VariantHomeOverlay(pathStack: NavPathStack) {
}

/** Release 没有调试路由；业务路由由 HM-02 的 Router 接管。 */
@Builder
export function VariantDestination(name: string, param: Object) {
}
