#!/bin/bash
# REFERENCE_ONLY 参照件（摘要）：只含本单一步。
# HM-L2-SKELETON：骨架件挪出 ProductCard、微光与减弱动态、SkeletonGate / SkeletonHost 防闪、目录与登记（先自测）；SkeletonGate 套件 node 预检与 ArkTS 严格检查。
step "HM-L2-SKELETON 宿主检查"
python3 "$ROOT/tools/ci/l2skeleton/check_l2_skeleton.py" --self-test || fail_fast "l2skeleton-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/l2skeleton/check_l2_skeleton.py" || fail_fast "l2skeleton-host" "见上方违反项"
node "$ROOT/tools/ci/l2skeleton/run-logic.cjs" || fail_fast "l2skeleton-logic" "见上方用例"
node "$ROOT/tools/ci/l2skeleton/check-arkts.cjs" --real || fail_fast "l2skeleton-arkts" "SkeletonGate / Ds02L2Ui 与新文件 ArkTS 严格检查失败"
record "HM-L2-SKELETON 宿主检查" PASS "挪件 / 导出 / 纯逻辑 / 微光与减弱动态 / 读屏 / SkeletonHost / 目录 / 登记（自测）/ 纯逻辑 / ArkTS"
