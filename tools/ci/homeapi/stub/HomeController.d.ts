// FU-X-HOME-PAGE-API-harmony 测试作者 v1：新接口声明桩（= tests-harmony-handback.md §3）。只给 check-arkts.cjs 默认模式用：
// 产品还没有 ApiClientHomeContractPort 时，测试文件对 '../main/ets/home/HomeController' 的导入解析到这里（其余符号照真实源码）；
// --real 模式不用它。
export * from '../../../../common/core/src/main/ets/home/HomeController';
import { HomeContractPort } from '../../../../common/core/src/main/ets/home/HomeController';
import { ApiClient, ApiResult } from '../../../../common/core/src/main/ets/network/ApiClient';

export declare class ApiClientHomeContractPort implements HomeContractPort {
  constructor(client: () => ApiClient | null);

  getPage(pageKey: string, anonymous: boolean, sendAllowed: () => boolean): Promise<ApiResult>;

  listSectionItems(pageKey: string, sectionId: string, cursor: string | null, anonymous: boolean,
    sendAllowed: () => boolean): Promise<ApiResult>;

  cancel(owner: number): void;
}
