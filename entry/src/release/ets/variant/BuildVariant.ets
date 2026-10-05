// Release（entry 模块 default target，product=default）的构建变体。
// 与 src/staging/ets/variant/BuildVariant.ets 同名同接口，由 hvigor 按 target 二选一编译；
// 本文件不得引用任何调试能力、非 prod 地址或 debug_only 路由（tools/ci/release-scan.sh 检查产物）。
import { AppEnvironment } from 'core';

export class BuildVariant {
  static readonly CONFIG_NAME: string = 'Release';

  static defaultEnvironment(): AppEnvironment {
    return AppEnvironment.PROD;
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
