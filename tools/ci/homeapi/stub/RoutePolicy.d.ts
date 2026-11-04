// FU-X-HOME-PAGE-API-harmony 测试作者 v4：新接口声明桩（= tests-harmony-handback.md v4 节）。只给 check-arkts.cjs 默认模式用：
// 产品还没有 NativeRouteHosts 时，测试文件对 '../main/ets/router/RoutePolicy' 的导入解析到这里；--real 模式不用它。
export * from '../../../../common/core/src/main/ets/router/RoutePolicy';
import { RouteSpec } from 'generated';

export declare class NativeRouteHosts {
  constructor(names: string[]);

  has(name: string): boolean;

  /** 在 lookup 之上：native、非 debug_only、本端没有承载者的路由按未发布返回（→ 升级提示）；其余原样。 */
  guard(lookup: (name: string) => RouteSpec | undefined): (name: string) => RouteSpec | undefined;
}
