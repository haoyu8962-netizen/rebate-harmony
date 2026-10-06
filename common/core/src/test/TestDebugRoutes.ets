// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// debug_only 路由表的测试副本（APP-02a）：core 单测在 default target 下模拟 Debug / Staging 构建注册调试路由。
// 只在 src/test，不进产物；内容与 generated/src/staging/ets/DebugRoutes.ets 同源。

import { RouteEntry, RouteKind, RouteParamSpec, RouteParamType, RouteSpec } from 'generated';

export class TestDebugRoutes {
  static readonly all: Map<string, RouteSpec> = TestDebugRoutes.build();

  private static build(): Map<string, RouteSpec> {
    const all: Map<string, RouteSpec> = new Map<string, RouteSpec>();
    all.set('HomePreview', new RouteSpec('HomePreview', RouteKind.NATIVE, 'none', '1.0.0', [RouteEntry.IN_APP, RouteEntry.DEEPLINK], null, true, false, null,
      [new RouteParamSpec('page_key', RouteParamType.STRING, null, 1, null, null), new RouteParamSpec('token', RouteParamType.STRING, null, 1, null, null)], ['page_key', 'token'], false));
    return all;
  }
}
