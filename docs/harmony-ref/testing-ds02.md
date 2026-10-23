# DS-02 测试使用的 API 子集

2026-10-21，离线核对本机 DevEco 6.1.1 SDK（目标 API 24、最低 API 20）。本页仅登记测试依赖，不改变产品代码。
权威声明根：`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/`。

- `kits/@kit.TestKit.d.ts`、`api/@ohos.uitest.d.ts`：`Driver.create`、`findComponent`、`waitForComponent`、`waitForIdle`、`click`、`swipe`、`pressBack`、`screenCapture(path, Rect)`；选择器是值 **ON**，`On` 是类型。组件 `scrollSearch`、`getBounds`、`getType`、`getText`、`getDescription`、`isChecked`、`isSelected`、`isEnabled`。以上用法 API ≤11；窗口/屏幕多显示器重载未使用。超时/不可见/被销毁抛错即用例失败，所有等待结果必须断言。
- `api/application/AbilityDelegator.d.ts`：`getAppContext` 返回 Context；`getApplicationContext()` 后才可 `setColorMode`。`startAbility(Want)` 启动真实 EntryAbility。测试包与 Staging 应用包均需安装。
- `api/application/ApplicationContext.d.ts`：`setColorMode`、目录已有 `setFontSizeScale`；测试通过真实目录切换操作，不把按钮文本当配置生效证据。
- `kits/@kit.ImageKit.d.ts` / `api/@ohos.multimedia.image.d.ts`：`image.createImageSource(path)`、`ImageSource.createPixelMap({ desiredPixelFormat: RGBA_8888 })`、`PixelMap.getImageInfo`、`readPixelsToBuffer`、`release`；用于真实控件截图取像素。使用的接口不高于 API 11，ImageSource / PixelMap 均等待 release。
- `@kit.ArkUI` 的 display `getDefaultDisplaySync().densityPixels`：把截图 px 换算为 vp。
- `api/@ohos.resourceManager.d.ts`：`getColorSync(Resource)`（API 10，已弃用但仍可用）取真实限定词颜色；无 Resource 的纯逻辑测试不会调用资源管理器。
- `api/@ohos.arkui.theme.d.ts`：API 12 `Colors` 的全部 **51** 个颜色角色（冻结名单在 `tools/ci/ds02/fixtures/system-color-roles.json`），`CustomColors = Partial<Colors>`；测试逐一读取每个角色，不遍历实现返回的子集。产品使用 `ThemeControl.setDefaultTheme` 时必须消费受测映射。

SDK ArkTS 1.1 静态校验入口：`tools/ci/ds02/check-arkts.cjs --self-test`。缺产品接口时仅提供声明，无实现；真 SDK API 不替身。反例验证 any、delete、对象字面量类型都被实际 ArkTS linter 拒绝。该检查不冒充 hvigor、HAR 链接或 UiTest 执行。

本任务的 brief/v0.4.0 已明确要求浅深两套；README 第 8 条“强制浅色、不放 dark 目录”是旧基线，此任务按新要求验收。

## v2 离线核对补充（2026-10-22）

- 本机同一 SDK `api/@ohos.uitest.d.ts`：`On.within(On)`（API 10）、`MatchPattern.STARTS_WITH`、`Driver.findComponents(On)`、`Driver.delayMs(number)`、`Component.getId(): Promise<string>`、`scrollToTop(speed)` / `scrollToBottom(speed)`（API 9）。分段控件用 `within` 限定真实组内的系统 Button，核文本和 `isSelected()`；遍历用 `getBounds()` 排除离屏节点。以上 API 均 ≤20。
- `api/@ohos.app.ability.Want.d.ts` / 对应 Want 声明中的 `moduleName`：启动明确指定 `com.couli.hm / entry / EntryAbility`。有界重拉与真实隐私入口处理后，等待 `Debug panel`，经真实面板进入并等待 `catalog-index`；不把测试包 Hello World 当就绪。
- 本机 hvigor 插件源码（`/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor-ohos-plugin/src/utils/target-utils.js`）的 `TargetUtils.pushTryTargets`：测试模式下只选显式的 `ohosTest` 或 `default`，普通 staging / alignTarget 不参与回退。`ohos-test-util.js` 自动生成的测试 Ability 名是 `TestAbility`。这是本机源码核对，不是联网结论。
- `entry_test` 与 `entry` 已不同名；两包同 bundle 的被测场景保持不变。共享 HAR 内同一 `generated/Index` 记录的不同 target 导出不能靠改 HAP 模块名消除。正式采用现有 staging 三处显式 `generated/src/staging/ets/DebugOnly` 导入，调试 API 的记录路径与 Release 不同；测试不复制产品清单，不给所有 HAR 添加伪 ohosTest target，也不改 Release default 源。

## v3 离线核对补充（2026-10-22）

本节按已安装 SDK 声明登记测试 API 子集，未联网，均不高于最低 API 20。

- `@kit.ArkUI` → `api/@ohos.measure.d.ts`：`MeasureText.measureText({ textContent, fontSize }): number` 返回 px 字宽（API 9，API 18 标弃用但仍可用）。协议句 100% / 12fp 下按实际 Text 的 bounds 与字宽计算 Span 链接点；完整回调结果和勾选状态必须通过。未调用不可达的 Span id。弃用提示不抑制。
- `api/@ohos.uitest.d.ts`：`MatchPattern.CONTAINS`；`waitForComponent` 返回节点后检查非空；`findComponent` + `delayMs(200)` 有界轮询关闭和选中状态。`Driver.swipe` 第五参数是速度 px/s（200–40000），遍历固定 3000，仍保留 30% 重叠。`Component` 句柄仅在同一详情、同一主题的一次遍历内缓存，bounds 每屏重读；不缓存跨主题的可见结果。
- `api/@ohos.resourceManager.d.ts`：`getColorByNameSync(resName: string): number`（API 10）。实际 getter 返回 `id === -1` 且 `params[0] === 'app.color.<名>'` 时按名称读取；非名称资源仍走原 `getColorSync`。44 个 getter × 浅 / 深 / 还原值逐个核对。
- 系统标题截图验全文使用本机 `default/hms/ets/kits/@kit.CoreVisionKit.d.ts` → `api/@hms.ai.ocr.textRecognition.d.ts`：`recognizeText(visionInfo: VisionInfo, configuration?: TextRecognitionConfiguration): Promise<TextRecognitionResult>`（API 10）；`VisionInfo.pixelMap: image.PixelMap`，`TextRecognitionResult.value: string`。只在测试包对两个 200% 标题截图调用系统文字识别，不增加网络请求、三方 SDK 或产品入口。OCR 异常、错字、省略号都让测试失败；仅去除空白后要求全文相等。释放 PixelMap / ImageSource；不把可访问性原文当作无截断证明。设备需有 `SystemCapability.AI.OCR.TextRecognition`，本轮只能静态核验，尚未实测该服务。
- `display.Display.width / height`：标题 bounds 必须完整落在屏幕内；系统标题 100→200 要确实变高，200% 截图要全文可读，200→100 高度还原误差仍 ≤2px。正文原有 >1.5× 阈值不变。

## v4 离线核对补充（2026-10-22）

替代上节系统标题 OCR 路径：设备日志确认 `SystemCapability.AI.OCR.TextRecognition` 不可用，测试已移除 CoreVisionKit 导入与文字识别调用。沿用已登记的 UiTest `getType` / `getText` / `getBounds` 和 `display.Display.width / height`，无新增 API。

AlertDialog / ActionMenu 在 100→200→100 三个阶段均要求标题 Text 存在、文本严格等于完整预期、bounds 宽高为正且完整落在屏幕内；200% 标题高度必须增长，还原误差 ≤2px。正文严格 >1.5× 及其还原、关闭断言不变。标题节点缺失仍失败，不静默跳过。

这是“不截断”的结构证据：可拦截节点文本缺字 / 省略号和 bounds 越出屏幕。UiTest 的 `getText()` 可能仍返回布局前原文，以上接口没有给出系统标题最终绘制的省略标志，不能证明像素级无遮挡或内部绘制未省略；不再声称 OCR / 像素级验全文。系统标题字号封顶的限制仍按 v3 处理。

## v7 离线核对补充（2026-10-22）

本节替代 v3 的跨滚动句柄缓存描述。`Ds02Traversal` 每屏一次 `findComponents`，先以 bounds 与当前视口的正面积交集过滤，再读取可见 id；只返回 `Map<string, Rect>`。滚动后重查锚点，补查后重查列表/样例。组件对象不跨滚动存留。

新增测试 API 均从上述已安装 SDK 离线核验，最低 API 20 可用：

- `api/@ohos.uitest.d.ts`：`triggerKey`、`triggerCombineKeys`、`Component.inputText` / `clearText`（API 9；使用单参数 inputText）。只读测试接受的唯一操作拒绝码是 `17000005`；`NoCandidates` / 窗口销毁 / 传输失败不当成只读成功。实际设备若使用其他拒绝码应报告并核验，不能广泛吞异常。
- `@kit.InputKit` → `api/@ohos.multimodalInput.keyCode.d.ts`：`KeyCode.KEYCODE_A / V / DEL / CTRL_LEFT`，键值由枚举取得。
- `@kit.BasicServicesKit` → `api/@ohos.pasteboard.d.ts`：`getSystemPasteboard`、`hasData`、`getData`、`setData`、`clearData`、`createData(MIMETYPE_TEXT_PLAIN, string)`。测试先保存原剪贴板，finally 还原；权限或平台调用失败正常报红。
- `api/arkui/Graphics.d.ts`：`ColorMetrics.numeric`、`red / green / blue`（API 12）；焦点测试核明确 RGB，不依赖 rgba 字符串序列化格式。Node 只替数值包装，真正的颜色选择和共享模式逻辑执行产品原类。
- `@kit.AbilityKit` 的 `UIAbility.onWindowStageCreate`；`@kit.ArkUI` 的 `WindowStage.loadContent`、`UIContext.getHostContext`；`NavPathStack.pushPathByName`、`NavDestination.onBackPressed`、`@Entry` / `@ComponentV2` / `@Local`。仅测试页使用，真实 NavBar 等由 designsystem 导入。
- `@kit.TestKit` 的 `TestRunner`、`abilityDelegatorRegistry.getArguments` 与 `@ohos/hypium` 的 `Hypium.hypiumTest`：测试 module 增加显式 Ability 后必须提供显式 runner。离线核对 hvigor `src/utils/ohos-test-util.js`：首个 ability 有 `srcEntry` 会关闭自动 TestAbility/runner 模板生成。因此 v7 提供 `OpenHarmonyTestRunner.ets`，完整转交原 List 与 aa 参数；不启动额外 Hello World 页面。需正式 hvigor 构建和设备复验，SDK 类型检查不替代这一步。

`Ds02R1Ability`、测试路由页和 profile 仅位于 `src/ohosTest`。NavBar 拦截回调、两行 8vp 间距胶囊、只读切换前焦点及 320vp 六图布局均在这里组合真实组件，不增加产品测试分支。新 6 项加入报告必跑集合；原 141 项名称与断言保留，总数 147。

R1-07 仍为人工验收：现有 200% 窗口用例把完整屏幕存到测试上下文 `cacheDir/ds02-v7-title-{Dialog|Sheet|AlertDialog|ActionMenu}-200.png`。截图成功与原文完整都不能证明实际无省略，必须按 `tools/ci/ds02/fixtures/manual-r1-cases.md` 目视签结；没有 OCR 自动通过兜底。

## v7c 离线核对补充（2026-10-22）

- 已安装 `@ohos/hypium` 1.0.24 的 `index.d.ts` / `index.ts`：`it(name, attribute, callback)` 没有第四个单例超时参数。`src/main/service.js` 的 `processFunc` 读取全局 `config.timeout`，`getFuncWithArgsZero` 超时只 reject 外层 Promise，不取消仍执行的测试函数；`beforeEach` / `afterEach` 接受异步回调并有同样的超时包裹。本机 SDK 内置版本有相同实现。测试入口因此统一使用 `-s timeout 600000`，所有 entry 用例（含 ProductCard、BuyButton、AmountGrid、WalletHeroCard、EntryGrid、PriceTrendPanel）适用；不改 core 的原超时配置。整轮 900 秒门槛不变。
- `api/@ohos.uitest.d.ts` 的 `Component.scrollSearch(On): Promise<Component>` 没有取消句柄；没有采用未知的取消 API。`waitForIdle(200, 8000)` 只能在旧调用已结束后发出，它等待 UI 静止，不能用来中断另一条在途 UiTest 调用。
- 新 `Ds02UiSession` 只使用已有 UiTest API 和标准 `Promise.then`、数组及错误类型。队列跟踪整个测试函数，含异步 finally；所有 Ds02Ui / Ds02R1Ui 用例在队列内先断言 `waitForIdle`，才运行原测试体。beforeEach / afterEach 请求旧任务停止并入队等待空闲。遍历和四处 scrollSearch 统一检查停止标记：在途搜索结束后立即退出旧任务；若搜索拒绝，原始错误仍传给调用方。对不支持取消的调用选择等待，不能将 Promise.race 超时当成已经取消。
- 若收尾钩子也超时，已结束但尚未启动的排队任务会被后续收尾标记停止；队列仍不会越过尚未返回的旧任务。原生调用永久卡住时保持阻塞，由整轮硬超时判失败，不能清空句柄伪称空闲。断言错误、传输异常和 idle=false 均保留失败。
- ProductCard 按 search / ai / favorite / ranking / grid / large 六个变体分别注册浅、深用例，每条覆盖该变体六个状态，原 72 个样例/主题组合不变；总必跑数 147→157。产品仍使用完整 CatalogDetail 列表，测试通过现有组件直达 `couli.ds02.component` 和 UiTest 定位首/末目标状态；没有新增变体直达参数或产品分支。此次不需要变体级产品接口。

本轮设施自测用本机 Hypium 原始超时函数和延迟 UiTest 替身复现竞态，不代表真机时长或整轮成功；设备复验以 `DS02_DEVICE_COMPLETE required=157 all_passed` 及原始报告为准。

## v7c 补充 r2（2026-10-22）

R2-01 的宿主用例由本机 SDK ArkTS AST 提取产品 `Navigation.ets` 中 TabBar 的非 UI 字段、方法及 build 内实际登记的 `onTabBarClick` / `onContentWillChange` 函数，执行原函数体；不是另写一份选择逻辑。覆盖点当前项、点另一项一次回调并返回 false 拦切换、宿主受控同步无回调、第二标签替换入口后当前项点击转交。延迟 25ms 再交 willChange，检查去重不能依赖 `setTimeout(0)`。七种内存变异要求由行为断言失败，不能把解析/加载异常算作杀死旧写法。

新增 ohosTest `r2_tabbar_click_veto_sync_and_replaced_selected_entry`，使用原测试宿主里的真实 TabBar；宿主记录累计次数、下标和当时入口名称，提供拒绝更新、受控同步、原位替换 items 操作。每步 idle 后等待 500ms 再核对完整回执，覆盖迟到的第二次事件。原 0→1→0 设备用例、颜色断言和 v7c 的串行收尾保留，必跑数 157→158。API 均为此前登记的 UiTest 与 V2 状态管理，没有产品测试接口或产品代码改动。

R2-02 的正式宿主守卫从 `common/designsystem/Logic.ets` 遍历依赖，检查相对导入/重导出、generated 包入口及其 release/staging 两个 DebugOnly 分支，共 31 个当前源文件；明确要求 StepUpPanelFit / ProductGridLayout / CouliFixedTap 被访问。SDK AST 检测真实 `$r` / `$rawfile`、资源类型、组件/Builder 与 UI 调用，正常字符串/注释不算污染，模板插值仍检查。未知包、失效路径、非字面量动态导入及解析不完整均失败，循环依赖只访问一次。入口、三个拆出类、generated 令牌与两个 DebugOnly 共七处各注入资源/UI 重导出，共 14 个真实依赖链反例，全部运行同一正式宿主守卫。

以上宿主/设施结果不代替真实系统事件调度或 AppShell 搜索路由实测；设备验收更新为 `DS02_DEVICE_COMPLETE required=158 all_passed`，单例 600000ms、整轮 ≤900 秒不变。


## v7d 离线核对补充（2026-10-22）

本节替代 v7/v7c 的遍历批量查询和原生搜索描述。没有新增 SDK API，仍只用本页登记的 `findComponent` / `findComponents` / `within` / `getBounds` / `waitForIdle` / `swipe`。

- R1 chip / share 在场景切换后等待目标存在、所有矩形为正且连续两次坐标完全一致，两轮之间断言 `waitForIdle`。上限 8s / 40 轮，不加固定 sleep。chip 首次点击之后重新等待稳定才点第二个边缘；share 同时读取 320vp 容器及六个 GridCol，仍按原四列、等宽、正方形、无重叠/溢出断言验收。设备 `aa-test-runR1.log:117–121` 指向旧 R1 测试第 178 行 `nodes.length`：运行时 `findComponents` 返回 null，虽然本机声明写的是 `Promise<Array<Component>>`。null / undefined / 无节点 / 短暂 NoCandidates 重置稳定计数；一直缺失明确失败，其他异常原样传播。
- `Ds02Traversal` 不再前缀批量读取所有样例。每屏仅按缺失 id 在当前容器内定位及读取矩形。已见项只允许一个方向边界锚点作为停止探针，滚动后重定位，不遍历已见项，不跨滚动缓存 Component。仍要求样例与当屏容器有严格正面积交集，并逐 id 断言。锚点仍可见、视口不变且位移 ≤2px 时停止该方向；零矩形不当端点。尚无目标项或锚点离屏时只查一个全目录方向端点，以免单跑深色变体从页顶起步而空滑；端点属于目标时也必须本次读数真实相交才能计入。首轮 600px/s，缺项反向 200px/s 补扫，两轮合用 120s 截止，每轮最多 320 页；缺项不能通过。
- 取消遍历入口定位和末尾逐项原生 `scrollSearch`；ProductCard 从当前滚动位置沿方向扫，必要时反向补扫。其余目录入口 / 单个控件搜索改为 `searchUiComponent(driver, containerSelector, targetSelector)`：两方向各最多 80 次小步滑动，首方向截止为第 60s、总截止为第 120s；返回目标必须正面积且中心位于视口内。每步 await 后检查停止，搜索结束不留后台 Promise。整个 ohosTest 源码无 `.scrollSearch(` 调用。
- 保留 v7c 的完整任务/finally 串行队列。Hypium 超时后不能强杀正在执行的单条 IPC，但当前 swipe 返回即停止旧搜索，不再启动下一次滑动或 idle；后续任务须等完整旧任务退出。原生 IPC 永久不返回仍由整轮硬超时判失败，不能宣称系统调用已强制取消。设施用本机 Hypium 原函数和延迟 swipe 覆盖超时、异常、异步 finally、钩子再次超时和过期排队任务。

设备必跑仍 **158**，清单 **400 × 2 = 800** 组，ProductCard **72** 组；单例 600000ms 与整轮 ≤900 秒不变。离线替身不代替设备复验；v7d 尚无真实设备全绿/耗时结论。


### v7d 修正（评审 S1，2026-10-22）

本节替代上节“锚点 top 位移 ≤2px 即结束”的描述，无新增 SDK API。设备 `getBounds()` 给出视口裁剪后的矩形，内部高卡的 top 甚至四条边都可能在滚动时保持不变。

端点现在要求同一个 id 的**完整 Rect 与完整视口 Rect 连续两次滑动后完全不变**，且要有至少一条落在视口内部的纵向边作未裁剪的位置参照。满屏裁剪的内部节点禁止触发停止；如果探针是明确的全目录首项（反向）/末项（正向），可在上述两次完整相等后结束该方向的样例搜索，这说明已到清单端点，不声称滚动已到物理像素终点。探针更换、失效或坐标/视口变化会清零连续次数。

每屏仍只查缺项，已见项最多重读一个端点探针，不跨滚动复用 Component。两个加入 seen 的位置仍要求本次矩形与本次视口严格正面积相交；最终逐 id 断言、120s/320页边界、串行超时收尾均未改。

设施默认对全部样例执行 `top=max(0, rawTop)` / `bottom=min(1000, rawBottom)` 的视口裁剪。完整 36 项 ProductCard 列表中的 search 六状态在 2800px 与 6000px 高卡下均双向通过；6000px 情景实际出现六次“完整裁剪矩形相同但内容仍移动”。另验证首尾 2800px 高卡；在内存中复原旧 top 判据，以及仅比较两次完整矩形却移除未裁剪参照的写法，分别由同一正例中的 long-price 缺项断言拒绝。所有原有反例及 158 条/800 组覆盖保留。
