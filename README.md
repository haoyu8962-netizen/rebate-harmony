# rebate-harmony

凑狸 harmony 原生壳。规则见 `AGENTS.md`；ArkTS 限制与锁定版本见 `docs/harmony-ref/README.md`。

## 结构

| 目录 | 内容 |
| --- | --- |
| `entry/` | HAP：`EntryAbility`、首屏 `RootPage`（Navigation + NavPathStack）；`src/release` / `src/staging` 是按构建配置二选一的源码目录 |
| `common/core/` | HAR：`config`（环境、本机数据清理注册表、启动对账；`src/staging` 里是环境切换实现与调试能力判断，Release 不编译）；其余子目录为占位 |
| `common/designsystem/` | HAR：设计令牌 → ArkUI 常量（`CouliColors`、`CouliTypography`、`CouliSpacing`、`CouliRadius`、`CouliInteraction`） |
| `common/generated/` | HAR：契约生成物（禁止手改），`python3 tools/codegen/gen.py` 生成 |
| `features/*` | HAR 占位：home search product agent orders wallet me auth web，互不依赖 |
| `contracts/snapshot/` | 契约快照（禁止手改），`tools/contracts/sync.sh` 按 `contract.lock` 生成 |

## 命令

| 用途 | 命令 |
| --- | --- |
| 契约快照 | `tools/contracts/sync.sh`（worktree 里加 `REBATE_PLATFORM_DIR=… COULI_DIR=…`） |
| 生成代码 | `python3 tools/codegen/gen.py`；`--check` 只查漂移 |
| 本机 CI | `tools/ci/verify.sh`（`--fast` 只到生成物检查与 Debug 构建） |
| 项目 lint | `python3 tools/ci/lint.py` |
| Release 扫描 | `tools/ci/release-scan.sh <Release.hap>`；`--self-test <Debug 或 Staging .hap>`（全部标记必须命中）；`tools/ci/release-scan-selftest.sh <工作目录>`（扫描出错必须非零退出） |

## 三套构建配置

| 配置 | product | buildMode | 默认环境 | 调试能力 | 应用名 |
| --- | --- | --- | --- | --- | --- |
| Debug | staging | debug | test | 编译 | 凑狸测试 |
| Staging | staging | release | staging | 编译 | 凑狸测试 |
| Release | default | release | prod | 不编译 | 凑狸 |

三套同一 bundleName，可互相覆盖安装：启动时比较「上次生效的环境」与本次环境，不同就先跑全部清理器、全部成功才记录新环境
（`EnvironmentLaunchReconciler`）；调试面板选择的环境跨重启保留。SDK：compile/target API 24（`6.1.1(24)`），最低兼容 API 20。

命令与原理见 `build-profile.json5` 文件头。本仓库路径含中文，hvigor 拒绝在这种路径下构建（00306003），
`verify.sh` 会把仓库同步到 ASCII 路径的镜像目录（默认 `$HOME/couli-build/rebate-harmony/<仓库目录名>`，可用 `COULI_HM_BUILD_DIR`
覆盖；脚本拒绝 `/tmp`、`/private/tmp`、`$TMPDIR` 下的路径）再构建。
