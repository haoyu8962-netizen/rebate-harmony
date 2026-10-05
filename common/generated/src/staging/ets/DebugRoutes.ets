// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// debug_only 路由：只在 generated 模块的 staging target（Debug / Staging 配置）编译，Release 产物里没有。

import { RouteEntry } from '../../main/ets/ContractEnums';
import { RouteKind, RouteSpec } from '../../main/ets/Routes';

export class DebugRoutes {
  static readonly all: Map<string, RouteSpec> = DebugRoutes.build();

  static spec(name: string): RouteSpec | undefined {
    return DebugRoutes.all.get(name);
  }

  private static build(): Map<string, RouteSpec> {
    const all: Map<string, RouteSpec> = new Map<string, RouteSpec>();
    all.set('HomePreview', new RouteSpec('HomePreview', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.DEEPLINK], null, true));
    return all;
  }
}
