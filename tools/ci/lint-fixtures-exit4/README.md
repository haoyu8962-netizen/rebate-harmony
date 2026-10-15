# lint-fixtures-exit4

FU-HM-0718 第 3 项：「扫不完 / 不支持」的样例。每个子目录跑 `lint.py --root <子目录>` 都必须以 **4** 退出（不是 0，也不是
表示「有违反」的 1）。`tools/ci/verify.sh` 的 lint-fixtures-exit4 步骤逐个核对；「一个正常源码 + 一个不可列举的源码子目录」
需要 chmod 000，git 存不了，由 verify.sh 在临时目录里现造。

- `HM-LINT-10-js`：entry/src/staging 里有 .js 文件（含 DebugFakeServer.enabled 读取）。HM-LINT-10 只用 TypeScript 解析器认
  .ets / .ts，不把 .js 套 TS 词法，按「不支持」失败。
- `HM-LINT-10-c`：entry/src/staging 里有 .c 文件，同上。

这些文件不参与构建（hvigor 不编译 tools/，code-linter.json5 也忽略 tools/）。
