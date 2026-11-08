G1 改义（FU-HM-G1-SYSTEM-CONTROLS，D10-827 ③ / D10-901 ② / D37）四条规则的违反样例，各恰好触发一条 `[couli-g1/<规则>]` 警告（lint.py exit 0）。
tools/ci/ds02/test_host.py 与 tools/ci/system-controls/test_system_controls.py 把它们复制到临时源码树使用。本目录不作为应用源编译，
也不在 verify.sh 的 lint-fixtures 步骤里（那一步只遍历 HM-LINT-*）。
