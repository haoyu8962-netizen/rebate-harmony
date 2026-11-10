#!/usr/bin/env bash
# 参照件（摘要）：HM-L2-CARD 宿主步。
python3 "$ROOT/tools/ci/l2card/check_l2_card.py" --self-test
python3 "$ROOT/tools/ci/l2card/check_l2_card.py"
node "$ROOT/tools/ci/l2card/run-logic.cjs"
node "$ROOT/tools/ci/l2card/check-arkts.cjs"
