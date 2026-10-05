// Release（product=default，core 模块 default target）的环境目录：只有 prod，没有切换能力。
// 与 src/staging/ets/config/EnvironmentCatalog.ets 同名同接口，由 hvigor 按 target 二选一编译。
import {
  AppEnvironment, EnvironmentEndpoints, EnvironmentSource, FixedEnvironment, PROD_ENDPOINTS
} from '../../../main/ets/config/AppEnvironment';
import { EnvironmentRecord } from '../../../main/ets/config/EnvironmentRecord';
import { LocalDataCleanerRegistry } from '../../../main/ets/config/LocalDataCleaner';

export class EnvironmentCatalog {
  static endpoints(): Map<AppEnvironment, EnvironmentEndpoints> {
    const map: Map<AppEnvironment, EnvironmentEndpoints> = new Map<AppEnvironment, EnvironmentEndpoints>();
    map.set(AppEnvironment.PROD, PROD_ENDPOINTS);
    return map;
  }

  /** Release 恒为 prod：不读任何选择。 */
  static async launchEnvironment(buildDefault: AppEnvironment, record: EnvironmentRecord): Promise<AppEnvironment> {
    return AppEnvironment.PROD;
  }

  static createSource(environment: AppEnvironment, record: EnvironmentRecord,
    cleaners: LocalDataCleanerRegistry): EnvironmentSource {
    return new FixedEnvironment(AppEnvironment.PROD, PROD_ENDPOINTS);
  }
}
