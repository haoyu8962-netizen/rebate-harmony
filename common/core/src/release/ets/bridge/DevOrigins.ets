// Release（core 模块 default target）：可信容器只认 https，没有任何本机调试源的规范化口径（APP-04 R1-02）。
// Debug / Staging 的同名文件在 src/staging/ets/bridge/DevOrigins.ets；由 hvigor 按 target 二选一编译，Release 制品里没有
// 回环主机名与 http 例外（tools/ci/release-scan.sh 检查）。

/** 非 https origin 的默认端口：Release 一律不认（null）。 */
export function devOriginDefaultPort(_scheme: string, _host: string): number | null {
  return null;
}
