// FU-X-HOME-PAGE-API-harmony 测试作者 v1：新接口声明桩（= tests-harmony-handback.md §3）。只给 check-arkts.cjs 默认模式用：
// 产品还没有 HomeDebugSources.select 时，测试文件对 '../staging/ets/home/HomePreviewSession' 的导入解析到这里；--real 模式不用它。
export * from '../../../../common/core/src/staging/ets/home/HomePreviewSession';
import { AppEnvironment } from '../../../../common/core/src/main/ets/config/AppEnvironment';
import { HomeContractPort } from '../../../../common/core/src/main/ets/home/HomeController';

export declare class HomeDebugSources {
  static contract(fakeEnabled: boolean, environment: AppEnvironment | undefined, fake: HomeContractPort):
    HomeContractPort | null;

  static guarded(gate: () => boolean, fake: HomeContractPort): HomeContractPort | null;

  /** 每次调用时选：gate() 为 true 用（受保护的）fake，否则用 real。 */
  static select(gate: () => boolean, fake: HomeContractPort, real: HomeContractPort): HomeContractPort;
}
