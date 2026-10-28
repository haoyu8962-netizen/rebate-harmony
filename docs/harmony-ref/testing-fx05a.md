# F-X-05a 测试使用的 API 子集

2026-10-27，离线核对本机 DevEco 6.1.1 SDK（目标 API 24、最低 API 20），只登记测试依赖，不改产品代码。沿用 `testing-ds02.md` 已登记的 UiTest / ImageKit / display / AbilityDelegator 接口，新增如下（均不高于 API 20）：

- `api/@ohos.UiTest.d.ts`：`On.originalText(text)`（API 20）——文字节点设了 `accessibilityLevel('no')` 后 `On.text` / `getText()` 读不到，测试用它定位已绘制但对读屏隐藏的平台名；`On.enabled(true).within(...)` 枚举范围内全部节点；`Component.getDescription()`、`isClickable()`、`isFocused()`（API 9）。读屏可见性以 `getText()` / `getDescription()` 为准（同一 d.ts 的 originalText 说明）。
- `api/@ohos.resourceManager.d.ts`：`getMediaByNameSync(resName)`（API 10）读已安装包里的平台图字节；资源不存在时抛错，用于断言暂缺平台没有占位图。
- `@kit.CryptoArchitectureKit` → `api/@ohos.security.cryptoFramework.d.ts`：`createMd('SHA256')`、`Md.update(DataBlob)`、`Md.digest()`（API 9），在设备上核对包内字节 = couli 原图。
- `api/@ohos.multimedia.image.d.ts`：`createImageSource(ArrayBuffer)`、`DecodingOptions.desiredSize`（API 7+），把原图解码缩放到截图尺寸作像素参照。
- `api/@ohos.arkui.UIContext.d.ts`：`UIContext.getFilteredInspectorTreeById(id, depth)`（API 12），仅测试宿主页 `Fx05aFixture` 调用，导出组件树里每个节点的 `$type` 与 `accessibilityLevel` / `accessibilityGroup`。**该 JSON 的属性名尚未在设备上实测**：属性缺失时用例以 `FX05A_ICON_NOT_HIDDEN … ?` 报红而不是放行；若设备上的键名不同，按 test-change 流程改宿主摘要函数，不得删掉这条断言。
- `ApplicationContext.setColorMode`（已登记）：深浅切换后等待 800ms + idle 再截屏。

宿主页、Ability 与 profile 只在 `entry/src/ohosTest`，产品源码不出现 `Fx05aAbility` / `Fx05aFixture`（`tools/ci/ds02/test_test_facilities.py` 守）。

## v2 补充（2026-10-27，测试作者 v2）

- `build-tools/ets-loader/declarations/global.d.ts`：`getInspectorTree()`（API 9，`@test`）——只在测试宿主页 `Fx05aFixture` 调用，取带全部属性的组件树（`$type` / `$attrs` / `$children`），按包裹节点 `id` 找子树。过滤版 `getFilteredInspectorTreeById` 只在全量树里找不到该 id 时兜底。`tools/ci/fx05a/check-arkts.cjs` 同步把这份全局声明加进类型检查（hvigor 编译 .ets 时本来就带）。
- 读屏判定口径：UiTest 的 `getText` / `getDescription` 读不到成组节点的 `accessibilityText`（设备证据见 `NATIVE/F-X-05a/tests-harmony-handback.md` v2 节）。「平台名只读一次」改由宿主页按组件树上声明的无障碍属性模拟朗读单元（`Fx05aFixture.announce`：`no-hide-descendants` 整棵不读、`no` 自身不读、`accessibilityGroup(true)` 整组一个单元读 `accessibilityText` 或合并子孙文字、未隐藏 Image 记一个可聚焦单元）。UiTest 节点断言（没有第二个可见副本、没有多余文字、Image 无文字 / 不可点 / 不聚焦）保留。仍不等于真机屏幕朗读的人工验收。
- 徽标几何：`border` 画在组件边界内、padding 从描边内侧算，文字左缘 = 描边 1vp + 内边距（有图 1 + 4 + 14 + 4 = 23vp，无图 1 + 8 = 9vp），右侧 1 + 8 = 9vp。

## v3 补充（2026-10-28，测试作者 v3，评审 r1 R1-01）

- 没有新增 SDK API。新用例 `fx05a_r1_clipboard_tmall_badge_text_only_others_keep_official_icon` 只用上面已登记的 `On.id` / `getBounds` / `screenCapture` / 组件树摘要 / 读屏单元；被测组件是真实 `ClipboardPromptBar`（designsystem），参数由宿主页现场经真实识别链路（`ClipboardCandidates` → `ClipboardPromptDisplay` → `SharePromptTexts` + `ClipboardDraftTexts`）与真实派生入口 `ClipboardBadgeIcon.of`（core）算出，与 `AppClipboard.apply` 同源。
- 宿主页 `Fx05aFixture` 从 `../test/Fx05aClipboardBadge` 引纯逻辑，再由它相对引入 `entry/src/main/ets/clipboard/ClipboardDraftTexts`（同 `Ds02Catalog.test.ets` 引 staging 源码的写法），只在测试 HAP 里编译。
- 徽标定位：徽标在提示条文字区第二行最前，取 `{barId}_body` 左缘到 `{barId}_detail` 左缘这一段截图；有图平台在描边 1 + 左内边距 4vp 处匹配本平台官方图，天猫这一段不得匹配任何一家官方图，且宽度等于不传 `badgePlatform` 的同名纯文字徽标（±2px）。
