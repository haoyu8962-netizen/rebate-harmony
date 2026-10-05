# lint-fixtures

每个子目录是一个「违反样例」，目录名就是它要触发的规则号（见 `tools/ci/lint.py` 文件头）。
`tools/ci/verify.sh` 对每个子目录跑 `lint.py --root <子目录>`，必须退出非零且输出含该规则号，证明规则有牙齿。
这些文件不参与构建（hvigor 不编译 tools/，code-linter.json5 也忽略 tools/）。
