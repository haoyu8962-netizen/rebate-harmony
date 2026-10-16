# lint-fixtures-exit4

FU-HM-0718 第 3 项：「扫不完 / 不支持」的样例。每个子目录跑 `lint.py --root <子目录>` 都必须以 **4** 退出（不是 0，也不是
表示「有违反」的 1）。`tools/ci/verify.sh` 的 lint-fixtures-exit4 步骤逐个核对；「一个正常源码 + 一个不可列举的源码子目录」
需要 chmod 000，git 存不了，由 verify.sh 在临时目录里现造。

- `HM-LINT-10-js`：entry/src/staging 里有 .js 文件（含 DebugFakeServer.enabled 读取）。HM-LINT-10 只用 TypeScript 解析器认
  .ets / .ts，不把 .js 套 TS 词法，按「不支持」失败。
- `HM-LINT-10-c`：entry/src/staging 里有 .c 文件，同上。
- `LEX-unclosed-block-comment`、`LEX-unclosed-template`（FU-HM-0723）：未闭合的块注释、模板插值到文件末尾仍未闭合——第 2 轮修复起
  HM-LINT-1…9 的词法由 TypeScript 解析器给出（`hm10-scan.js --lex`），解析器报语法错误的文件判不了，lint 以 4 失败。原来在这里的
  `LEX-ambiguous-slash`、`LEX-contextual-keyword-slash` 是合法代码，解析器能判，已移到 `../lint-fixtures-lex`（必须报出）。
- `R3-03-unresolved-dynamic-import`（FU-HM-0723 末轮窄修）：`import(name)` 的模块名静态确定不了，判不了是不是禁用模块，lint 以 4 失败。
- `RC-02-shadowed-dynamic-import`（末轮窄修二）：features/home 里参数 M 遮蔽外层 `const M = './local'`，调用方传 'search'；有其他同名
  绑定时按确定不了处理，lint 以 4 失败（原实现取外层值放行）。
- `RC-03-navbar-height-binding-conflict`（末轮窄修三）：navBar 里 `.height(H)`，H 同名绑定冲突、折叠不出值——判不了是不是百分比高度，
  lint 以 4 失败（原实现跳过、以 0 通过）。
