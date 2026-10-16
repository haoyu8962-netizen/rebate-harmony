# wiring-check 样例（FU-HM-0724 测试评审 T-04）

每个子目录是一个迷你仓库树（四个组合入口），`expect.txt` 第一行是期望退出码，其余行是输出里必须出现的规则号。
`good` 全部满足；`e1-*`…`e4-*` 各漏接、回到旧路径或接了却不用一处（含 e2-no-reconciler-sync、e2-session-sync、e4-no-build、e4-empty-invalidate），必须以 1 失败并报对应规则；`x-missing-file` 缺文件必须以 4 失败。
由 `python3 tools/ci/wiring-check.py --self-test` 执行（verify.sh「接线检查」步骤）。

FU-HM-0725 第 2 版（逻辑下沉 Core，entry / 视图一行转发；规则见 wiring-check.js 文件头）：`good` 与全部样例的 AppHome / OrderListView / WalletPages / AppWallet（FundPageFactory 字段）都换成新形状，旧样例按新形状重做（报的规则不变；e4-constant-identity、e4-no-sync-with 另报 E4-same-source）。新增漏接样例（每个只报目标规则）：
- E2-pages：`e2-factory-missing`、`e2-pages-bypass-factory`、`e2-pages-no-shown-forward`、`e2-pages-dead-forward`（死代码）、`e2-pages-wrong-receiver`（错误接收者）、`e2-pages-overwritten`（后续覆盖）、`e2-pages-records-param-dropped`（换参数）。
- E3-input（M43 的新形状）：`e3-input-cleared`（恒值）、`e3-input-constant-expr`、`e3-input-removed`、`e3-input-dead-branch`、`e3-input-overwritten`、`e3-input-wrong-arg`。
- E3-takeover：`e3-touch-constant`、`e3-scroll-index-constant`（恒值）、`e3-events-wrong-receiver`、`e3-events-other-sync`、`e3-events-dead-method`（挪出 build）、`e3-no-touch-down`。
- E4-source / E4-key / E4-same-source（M38 的新形状）：`e4-source-constant`、`e4-source-overwritten`、`e4-key-constant`、`e4-key-discard-reread`（丢弃结果后二次读取）、`e4-key-wrong-receiver`、`e4-now-second-read`、`e4-now-reassigned`、`e4-sync-dead-branch`、`e4-build-other-identity`。
