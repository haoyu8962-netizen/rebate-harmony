// 生成物，禁止手改；来源 contract.lock（tools/codegen/gen.py 生成）

// openapi GET /v1/app-versions/check 的 200 响应示例里的 data（AppVersionCheck），原样转写（APP-02c）。
// 只在 generated 模块的 staging target（Debug / Staging）编译：调试面板的版本检查假数据；Release 里没有，
// release-scan 查 MARKER。

export class AppVersionCheckExample {
  static readonly MARKER: string = 'COULI_UPDATE_CHECK_EXAMPLE_MARKER_5b7e3d91c2a4';
  static readonly DATA_JSON: string = '{"latest_version":"1.2.0","min_supported_version":"1.0.0","recommended_version":"1.1.0","update_title":"新版本","update_notes":"修复若干问题","store_url":"https://store.example.test/app/couli","default_store":"huawei","stores":[{"store":"huawei","listed_version":"1.2.0"},{"store":"xiaomi","listed_version":null}]}';
}
