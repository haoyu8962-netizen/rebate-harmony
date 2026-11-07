# FU-HM-DEVICE-FLAKE 测试设施使用的 API 子集

2026-11-06，离线核对本机 DevEco 6.1.1 SDK（目标 API 24、最低 API 20），只登记测试依赖（`entry/src/ohosTest/ets/test/FlakeKit.ets`），不改产品代码。
沿用 `testing-ds02.md` / `testing-fx05a.md` 已登记的 `screenCapture`、ImageKit 解码、`waitForIdle`、`delayMs`，新增如下（均不高于 API 20）：

- `api/@ohos.UiTest.d.ts`：`Driver.findWindow(WindowFilter)`（API 9）+ `WindowFilter.focused`（API 9）、`UiWindow.getBundleName()` / `getTitle()`（API 9）——
  失败现场诊断：当前获焦窗口是不是本 App（系统对话框、权限框、ANR 框盖在上面时不是）。只进失败信息，不参与判定。
- **不使用** `Driver.createUIEventObserver()` / `UIEventObserver.once(...)`：开发轮 dev3 接入后，me12v_03 一出轻提示测试进程即 App died
  （回调在原生线程回到同进程 JS），诊断设施不得有让用例崩的可能，已去掉。
- 截屏校验：`screenCapture(path, rect)` 返回 true 不等于拿到了真截图（设备上见过整块 RGBA 全 0：me12wb_02「0/0/0」、hm07va「浅色价值卡覆盖 0」）。
  `captureChecked` 解码后要求尺寸与请求矩形相差 ≤ 2px、每个像素 alpha = 255（屏幕合成结果恒不透明），不合格换新文件名重拍，最多 3 次，
  仍不合格抛 `FLAKE_CAPTURE_INVALID`。真黑色（不透明）不算不合格，颜色由用例原断言判。
