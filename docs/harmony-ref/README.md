# docs/harmony-ref

规划 03 §3.4：这里放「锁定版本的 API 文档子集与 ArkTS 限制规则；镜像外的 API 禁止使用」。
本任务（HM-01）只写说明与规则清单，不复制官方文档。

## 锁定版本

| 项 | 当前值 | 说明 |
| --- | --- | --- |
| 最低兼容 | API 20（HarmonyOS 6.0.0，`compatibleSdkVersion "6.0.0(20)"`） | 规划 D5 |
| 编译目标 | `targetSdkVersion "6.1.1(24)"`（API 24） | 规划 D5；`tools/ci/verify.sh` 核对与已装 SDK 一致，并核对产物 `targetAPIVersion` |
| 编译 SDK | `compileSdkVersion "6.1.1(24)"` | 本机 DevEco Studio 6.1.1 自带 SDK 6.1.1.125（API 24） |
| 工具链 | DevEco Studio 6.1.1 自带 hvigor、ohpm、node、JBR | 见 `tools/ci/verify.sh` |

代码只用 API 20 及以下的接口（检查：`verify.sh` 的 api-compat 步骤——ArkTS 编译器对高于 compatibleSdkVersion 的接口打
「The 'X' API is supported since SDK version N. However, the current compatible SDK version is 6.0.0(20).」告警，出现即失败）。API 的权威定义是 DevEco 自带 SDK 的 `sdk/default/openharmony/ets/api`、`ets/kits` 与
`sdk/default/hms/ets`；开发资料速查在私有库 `rebate-private/dev-reference/harmony/`。以后在本目录放用到的 API 子集
（每个 Kit 一页：接口、最低 API、错误码），新增依赖的接口先登记再使用。

## 规则清单（硬规则，CI 检查的标了检查方式）

1. **状态管理只用 V2**：`@ComponentV2`、`@Local`、`@Param`、`@Once`、`@Event`、`@Provider` / `@Consumer`、
   `@ObservedV2` + `@Trace`、`@Computed`、`@Monitor`（不用 API 26 的通配符）。
   禁用 V1：`@Component`、`@State`、`@Prop`、`@Link`、`@Observed`、`@ObjectLink`、`@Provide`、`@Consume`、
   `@StorageLink`、`@StorageProp`、`@LocalStorageLink`、`@LocalStorageProp`、`@Watch`、`@Track`。
   检查：`tools/ci/lint.py` HM-LINT-2。官方示例多是 V1 外壳，只抄调用顺序，不抄装饰器。
2. **导航只用 `Navigation` + `NavPathStack`**（`NavDestination` 承载页面）；禁用 `@ohos.router` 与 `@kit.ArkUI` 的 `router`。
   检查：HM-LINT-3。不在 `aboutToAppear` 里改栈。
3. **禁 `any` / 滥用 `unknown`**：ArkTS 编译器本身禁止 `any`；`unknown` 只在系统接口要求处出现（如 `NavPathInfo.param`），
   拿到后立刻按白名单校验成具体类型。不用 `as` 把 JSON 直接断言成业务类型（生成的运行时校验函数由 HM-02 提供）。
4. **业务页面不硬编码中文**：`features/` 下字符串字面量不得含中文，文案经字典取键（BR-TEXT-12）。检查：HM-LINT-1。
5. **第三方 SDK 只在 `PrivacyGate.onConsented()` 里初始化**（03 §4.1）。检查：HM-LINT-4。
6. **依赖方向** entry → features → core → generated；feature 之间不互相依赖。检查：HM-LINT-5。
7. **调试能力编译期剔除**：只写在 `src/staging`（entry、core、generated 的 staging target），Release 只编译
   `src/release`；不靠运行时 if。core 的边界：`src/main` 只有环境枚举、prod 端点、只读的当前环境（`EnvironmentSource`）、
   本机数据清理注册表与启动对账（Release 也要用）；运行中切换环境（`EnvironmentSwitcher`）、调试面板选择的持久化、
   `DebugCapabilities` 只在 `src/staging`。检查：`tools/ci/release-scan.sh`（Release 不命中、Debug / Staging 全部命中）。
8. **浅 / 深两套（DS-02 起，00 D35、令牌 v0.4.0）**：应用跟随系统深浅（`EntryAbility.onCreate` 设 `COLOR_MODE_NOT_SET`）；颜色令牌在
   `common/designsystem/src/main/resources/base|dark/element/color.json`（`tools/codegen/gen_theme.py` 生成，`lint.py` 的 HM-LINT-11 查漂移），
   页面与组件只用 `CouliColors.*`（资源）、不写色值；系统组件主题经 `CouliTheme.install()`（`ThemeControl.setDefaultTheme`）。
   designsystem 总入口里引资源只用变量拼名（`couliColorResource`），字面量 `$r` 会让 core 本机单测编译报 Unknown resource type（F-HM-57）。
   原「强制浅色、不放 dark/」作废。
9. **文字用 fp、尺寸用 vp**：字号随系统字体大小缩放（03 §10.4），命中区下限 48vp。
