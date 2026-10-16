# lint-fixtures-lex

FU-HM-0723 第 2 轮修复：HM-LINT-1…9 的注释 / 字符串 / 正则 / 导入改由 TypeScript 解析器（`hm10-scan.js --lex`，鸿蒙 SDK 的
ohos-typescript）给出之后的违反样例。每个子目录都是 SDK 解析器零语法诊断的合法代码，`lint.py --root <子目录>` 必须以 **1** 退出，
并报出子目录里 `EXPECT` 写的规则号；`tools/ci/verify.sh` 的 lint-fixtures-lex 步骤逐个核对（数量 11）。

- `LEX-ambiguous-slash`：`)` 之后的 `/`（第 1 轮按歧义以 4 失败，从 lint-fixtures-exit4 移来）。
- `LEX-contextual-keyword-slash`：变量 `of` 之后的除号与中文字符串（R1-04，从 lint-fixtures-exit4 移来）。
- `R2-03-nonnull-division`：`value! / '中文'.length / 2`。
- `R2-04-type-import-comments`：`import/*c*/type/*d*/{ router/*e*/as r }from'@kit.ArkUI'`。
- `R2-04-escaped-module`：`'@ohos.\u0072outer'`（解码后比较）。
- `R2-05-u2028`、`R2-05-u2029`：行注释之后是 U+2028 / U+2029 行终止符（文件里是真实字符）。

- `R3-02-emoji-before-navbar`：navBar() 之前有 emoji（非 BMP 字符），原实现两端位置单位不一致、范围收成空漏报（末轮窄修）。
- `R3-03-dynamic-import-concat`、`R3-03-feature-import-concat`：`import('@ohos.' + 'router')`、features/home 的 `import('sea' + 'rch')`。
- `R3-04-escaped-percent-height`：navBar 里 `.height('100\u0025')`（解码后是 100%）。

这些文件不参与构建（hvigor 不编译 tools/，code-linter.json5 也忽略 tools/）。
