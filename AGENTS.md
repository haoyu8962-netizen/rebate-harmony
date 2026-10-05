# AGENTS.md（rebate-harmony）

凑狸鸿蒙原生壳。与负责人沟通一律用中文、大白话；他只拍业务决定、提供素材与账号。

## 1. 依据在哪里

| 要查什么 | 看哪里 |
| --- | --- |
| 三端分层、Core、WebView 与桥、设计系统 | 规划仓库 `../couli` 的 `规划/03_前端架构.md`（读远端主干：`git -C ../couli show origin/main:<路径>`） |
| 任务清单与验收 | `规划/05` §3.6（APP-01…16） |
| 业务规则取值（BR） | `规划/08_业务规则/`；不在本仓库复述数值 |
| 接口、错误码、枚举、桥、路由、文案 | `contracts/snapshot/`（从 `../rebate-platform/contracts/` 按 `contract.lock` 锁定的提交转写，禁止手改） |
| 设计令牌 | `contracts/snapshot/design-tokens.json`（从规划仓库 `design/tokens/design-tokens.json` 按 `contract.lock` 转写） |
| 设计稿 | `../couli-runs/design-hifi/`（`GUIDE.md`、`flow-map.md`、`adaptation-a11y-spec.md`、`project/*.dc.html`） |

## 2. 命令

| 用途 | 命令 |
| --- | --- |
| 契约快照（换锁定版本时） | `tools/contracts/sync.sh` |
| 生成代码 | `python3 tools/codegen/gen.py`；`--check` 只查漂移 |
| 本机 CI | `tools/ci/verify.sh`（codelinter + 生成物漂移 + hvigor 构建 + Hypium） |

## 3. 硬规则

1. 依赖方向：App → Features → Core → Generated；Feature 之间不互相依赖，跨功能跳转只经 Router（路由名）。
2. `common/generated/` 与 `contracts/snapshot/` 是生成物，不手改；改生成器或换锁定版本后重新生成。
3. 金额是整数分（`number`，安全整数范围内；超范围用 bigint），不用浮点；格式化只走 DesignSystem 的格式化函数。
4. 业务页面不硬编码中文文案，文案经文案字典取键（BR-TEXT-12）。
5. 第三方 SDK 只在 `PrivacyGate.onConsented()` 里初始化。
6. 调试能力（环境切换、诊断面板、一致性测试页、HomePreview 等）只在 debug / staging 构建配置的模块或源码里编译，Release 制品里不存在。
7. 密钥、证书、签名资料不入库；没给的 签名证书 / AppKey（包名已定 `com.couli.hm`） 用占位并登记 `../couli-runs/NATIVE/needs.md`。
8. 实现子代理不提交、不装依赖；git 只有原生线编排会话一个写者。
9. ArkTS / ArkUI；target API 24、最低兼容 API 20（D5）；状态管理只用 V2（`@ComponentV2` 等），禁用 V1 装饰器；导航只用 `Navigation` + `NavPathStack`，禁用 `router`；ArkTS 禁止 `any`；只用 `docs/harmony-ref/` 镜像内的 API。
