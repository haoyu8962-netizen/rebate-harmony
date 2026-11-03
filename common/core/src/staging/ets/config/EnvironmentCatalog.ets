// Debug / Staging（product=staging，core 模块 staging target）的环境目录：四个环境都可切换。
// 非 prod 地址只允许出现在本文件（src/staging）；Release 产物由 tools/ci/release-scan.sh 检查不含它们。
// local / test 是 .invalid 占位；staging 连真实主机 api-stg / h5-stg / stream-stg（FU-X-STAGING-HOSTS，D10-598）。
import {
  AppEnvironment, EnvironmentEndpoints, EnvironmentSource, PROD_ENDPOINTS
} from '../../../main/ets/config/AppEnvironment';
import { EnvironmentRecord } from '../../../main/ets/config/EnvironmentRecord';
import { LocalDataCleanerRegistry } from '../../../main/ets/config/LocalDataCleaner';
import { EnvironmentSelection, EnvironmentSwitcher } from './EnvironmentSwitcher';

export class EnvironmentCatalog {
  static endpoints(): Map<AppEnvironment, EnvironmentEndpoints> {
    const map: Map<AppEnvironment, EnvironmentEndpoints> = new Map<AppEnvironment, EnvironmentEndpoints>();
    map.set(AppEnvironment.LOCAL,
      new EnvironmentEndpoints('https://api.local.couli.invalid', 'https://h5.local.couli.invalid'));
    map.set(AppEnvironment.TEST,
      new EnvironmentEndpoints('https://api.test.couli.invalid', 'https://h5.test.couli.invalid'));
    map.set(AppEnvironment.STAGING,
      new EnvironmentEndpoints('https://api-stg.couliapp.cn', 'https://h5-stg.couliapp.cn', 'https://stream-stg.couliapp.cn'));
    map.set(AppEnvironment.PROD, PROD_ENDPOINTS);
    return map;
  }

  /** 本次启动要用的环境：调试面板的持久化选择优先，没有就用构建默认（Debug=test，Staging=staging）。 */
  static async launchEnvironment(buildDefault: AppEnvironment, record: EnvironmentRecord): Promise<AppEnvironment> {
    const selected: AppEnvironment | undefined = await EnvironmentSelection.read(record, EnvironmentCatalog.endpoints());
    return selected === undefined ? buildDefault : selected;
  }

  static createSource(environment: AppEnvironment, record: EnvironmentRecord,
    cleaners: LocalDataCleanerRegistry): EnvironmentSource {
    return new EnvironmentSwitcher(environment, EnvironmentCatalog.endpoints(), cleaners, record);
  }
}
