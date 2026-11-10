#!/usr/bin/env bash
# HM-L2-PRODUCT-CELL 参照件：verify.sh 里本单一步的写法（tests-harmony-impl.patch 落到真实 verify.sh，照 HM-L2-STATE 先例只新增本段）。
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
step() { echo "== $1"; }
fail_fast() { echo "FAIL $1: $2"; exit 1; }
record() { echo "$1 $2 $3"; }

# HM-L2-PRODUCT-CELL：商品卡整卡承载（openable / onOpen 经 CouliCard、openable=false 不吞页面外层点击）、去预估返后（U1）、信息区读屏合一、
# 购买按钮单独一项与隐私接线（S3-1）、无触感、图片段不动、目录与登记（先自测）；L2ProductCell 套件 node 预检与 ArkTS 严格检查。
step "HM-L2-PRODUCT-CELL 宿主检查"
python3 "$ROOT/tools/ci/l2cell/check_l2_cell.py" --self-test || fail_fast "l2cell-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/l2cell/check_l2_cell.py" || fail_fast "l2cell-host" "见上方违反项"
node "$ROOT/tools/ci/l2cell/run-logic.cjs" || fail_fast "l2cell-logic" "见上方用例"
node "$ROOT/tools/ci/l2cell/check-arkts.cjs" --real || fail_fast "l2cell-arkts" "L2ProductCell / Ds02L2Ui 测试文件 ArkTS 严格检查失败"
record "HM-L2-PRODUCT-CELL 宿主检查" PASS "外壳 / 不吞点击 / 去预估返后 / 读屏合一 / 隐私接线 / 无触感 / 图片段 / 目录 / 登记（自测）/ 纯逻辑 / ArkTS"
