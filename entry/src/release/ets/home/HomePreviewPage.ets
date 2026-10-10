// Release（entry 模块 default target）：首页草稿预览不编译进来（03 §3.6、AC-S1-86 ②③、G24 ①）。
// Debug / Staging 的实现在 src/staging/ets/home/HomePreviewPage.ets；Release 的路由表没有对应路由，深链按未知路由处理。
// 本文件故意为空，没有任何代码、路由或字符串（tools/ci/release-scan.sh 查调试路由名与预览页标记）。

export const HOME_DRAFT_VIEW_COMPILED: boolean = false;
