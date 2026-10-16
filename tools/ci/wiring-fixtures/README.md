# wiring-check 样例（FU-HM-0724 测试评审 T-04）

每个子目录是一个迷你仓库树（四个组合入口），`expect.txt` 第一行是期望退出码，其余行是输出里必须出现的规则号。
`good` 全部满足；`e1-*`…`e4-*` 各漏接、回到旧路径或接了却不用一处（含 e2-no-reconciler-sync、e2-session-sync、e4-no-build、e4-empty-invalidate），必须以 1 失败并报对应规则；`x-missing-file` 缺文件必须以 4 失败。
由 `python3 tools/ci/wiring-check.py --self-test` 执行（verify.sh「接线检查」步骤）。
