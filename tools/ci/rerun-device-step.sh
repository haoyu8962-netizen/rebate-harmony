#!/bin/bash
# 按 D10-642 复跑 verify.sh 的一个 entry 设备步（FU-HM-DEVICE-FLAKE；评审 r1 S1-1 后 v2）：用首跑 verify 的**同一个安装包**把**整个设备步**再跑一次。
#
# 用法：tools/ci/rerun-device-step.sh <步骤名> <首跑 verify 日志>
#   步骤名：verify 汇总里 device-test 后缀（entry、entry-hm07va、entry-me12v …；core 步不适用）。
#   首跑 verify 日志：那一轮 verify.sh 的完整标准输出（含 DEVICE_HAP_SHA256 / DEVICE_STEPS_FAILED 行）。
#   环境变量同 verify.sh：COULI_HM_BUILD_DIR（缺省 $HOME/couli-build/rebate-harmony/<仓库目录名>）、COULI_HM_DEVICE、DEVECO_HOME。
#
# 开跑前逐条核对，任一不满足即拒跑（退出 1，输出 RERUN_REFUSED 行）：
#   ① 首跑日志的 DEVICE_STEPS_FAILED 恰好只列这一步（D10-642 ①「只有一个设备步红」；verify 走到这行即说明构建 / 单元 / 静态已全过）；
#   ② 首跑日志里该步的 DEVICE_HAP_SHA256（应用包、测试包）与本次将用的两个包逐一相同（「同一个安装包」）；
#   ③ 同一对安装包、同一步只允许复跑一次（评审 r2 S1-1'）：标记记在构建镜像输出区 $OUT_DIR/rerun-marks/<步骤名>-<应用包 sha 前 16 位>-<测试包 sha 前 16 位>，
#      与首跑日志的路径 / 文件名无关（复制、改名、软链、归档日志都不会让次数归零）；新一轮 verify 重建了包，键自然变了，首次复跑照常放行。
#      开跑前写标记（中断也算用过）；拒跑行列出之前那次复跑的日志。
# 条件 ②（套件与被测代码不在本单 diff）、③（上一版同套件全过）属于 D10-642 的人工 / 编排判断，本脚本不判。
# 过滤与必跑名单从 verify.sh 的分派行读（同一来源）；超时同 verify（整步 1800 秒、单例 600 秒）。只复跑、不构建；须在宿主锁内调用。
# 退出码：0 全过（RERUN_PASS）；1 仍红 / 拒跑 / 包不在；2 用法错误。
set -euo pipefail

[ "$#" -eq 2 ] || { echo "用法：rerun-device-step.sh <步骤名，如 entry-hm07va> <首跑 verify 日志>" >&2; exit 2; }
LABEL="$1"
FIRST_LOG="$2"
[[ "$LABEL" =~ ^entry(-[a-z0-9]+)?$ ]] || { echo "步骤名不合法（只认 entry / entry-<步>，core 不适用）：${LABEL}" >&2; exit 2; }
[ -f "$FIRST_LOG" ] || { echo "首跑 verify 日志不存在：${FIRST_LOG}" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${COULI_HM_BUILD_DIR:-$HOME/couli-build/rebate-harmony/$(basename "$ROOT")}"
BUILD_DIR="$(printf '%s' "$BUILD_DIR" | sed -e 's#//*#/#g' -e 's#/$##')"
OUT_DIR="$BUILD_DIR/.verify-out"
APP_HAP="$OUT_DIR/Staging.hap"
TEST_HAP="$BUILD_DIR/entry/build/staging/outputs/ohosTest/entry-ohosTest-unsigned.hap"

refuse() { echo "RERUN_REFUSED step=${LABEL} $1"; exit 1; }

# verify.sh 分派行：run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" <步骤名> <过滤> <名单>
LINE="$(awk -v l="$LABEL" '$1 == "run_device_tests" && $2 == "entry" && $7 == l { print; exit }' "$ROOT/tools/ci/verify.sh")"
[ -n "$LINE" ] || { echo "verify.sh 里没有设备步 ${LABEL}" >&2; exit 2; }
FILTER="$(printf '%s\n' "$LINE" | awk '{ print $8 }')"
SET="$(printf '%s\n' "$LINE" | awk '{ print $9 }')"
[ -n "$FILTER" ] && [ -n "$SET" ] || { echo "设备步 ${LABEL} 的过滤 / 名单读不出：${LINE}" >&2; exit 2; }

# ① 首跑只红这一步
FAILED="$({ grep -E '^DEVICE_STEPS_FAILED( |$)' "$FIRST_LOG" || true; } | tail -1)"
[ -n "$FAILED" ] || refuse "first_run_red=none（首跑日志没有 DEVICE_STEPS_FAILED 行：没跑到设备步汇总，或设备步全过）"
read -r -a RED <<<"${FAILED#DEVICE_STEPS_FAILED}"
[ "${#RED[@]}" -eq 1 ] || refuse "first_run_red=${#RED[@]} steps（${RED[*]:-}；D10-642 ① 只红一个设备步才可复跑）"
[ "${RED[0]}" = "$LABEL" ] || refuse "first_run_red=${RED[0]}（首跑红的不是 ${LABEL}）"

# ② 同一个安装包
SHA_LINE="$({ grep -E "^DEVICE_HAP_SHA256 step=${LABEL} " "$FIRST_LOG" || true; } | tail -1)"
[ -n "$SHA_LINE" ] || refuse "same_package=unknown（首跑日志没有该步的 DEVICE_HAP_SHA256 行）"
FIRST_APP="$(printf '%s\n' "$SHA_LINE" | sed -nE 's/.* app=([0-9a-f]{64}).*/\1/p')"
FIRST_TEST="$(printf '%s\n' "$SHA_LINE" | sed -nE 's/.* test=([0-9a-f]{64}).*/\1/p')"
[ -n "$FIRST_APP" ] && [ -n "$FIRST_TEST" ] || refuse "same_package=unknown（DEVICE_HAP_SHA256 行读不出两个 sha256：${SHA_LINE}）"
for f in "$APP_HAP" "$TEST_HAP"; do
    [ -f "$f" ] || refuse "same_package=no（找不到上一轮 verify 的安装包 ${f}；只复跑、不构建）"
done
sha() { shasum -a 256 "$1" | awk '{ print $1 }'; }
NOW_APP="$(sha "$APP_HAP")"
NOW_TEST="$(sha "$TEST_HAP")"
[ "$NOW_APP" = "$FIRST_APP" ] || refuse "same_package=no app 首跑 ${FIRST_APP} ≠ 现在 ${NOW_APP}（构建镜像已被后来的构建覆盖）"
[ "$NOW_TEST" = "$FIRST_TEST" ] || refuse "same_package=no test 首跑 ${FIRST_TEST} ≠ 现在 ${NOW_TEST}（构建镜像已被后来的构建覆盖）"

# ③ 同一对安装包、同一步只复跑一次（键与日志路径无关）
MARK_DIR="$OUT_DIR/rerun-marks"
MARK="$MARK_DIR/${LABEL}-${NOW_APP:0:16}-${NOW_TEST:0:16}"
[ ! -e "$MARK" ] || refuse "attempt=2（这对安装包已复跑过该步一次：$(head -1 "$MARK")；仍红按 D10-642 整轮重跑）"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG="$OUT_DIR/device-test-$LABEL-rerun-$STAMP.log"
WORK="$OUT_DIR/device-test-$LABEL-rerun"
mkdir -p "$MARK_DIR"
printf '%s 第 1 次复跑 首跑日志 %s 复跑日志 %s app=%s test=%s\n' "$(date '+%F %T')" "$FIRST_LOG" "$LOG" "$NOW_APP" "$NOW_TEST" > "$MARK"

echo "第 1 次复跑设备步 ${LABEL}（${FILTER}，名单 ${SET}）；首跑日志 ${FIRST_LOG}"
echo "  同一个安装包：应用 ${NOW_APP}，测试包 ${NOW_TEST}（与首跑 DEVICE_HAP_SHA256 一致）"
echo "  日志 ${LOG}；复跑标记 ${MARK}"
code=0
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 COULI_HM_TEST_FILTER="$FILTER" COULI_HM_DEVICE_SET="$SET" \
    "$ROOT/tools/ci/device-test.sh" "$TEST_HAP" entry_test "$WORK" "$APP_HAP" >"$LOG" 2>&1 || code=$?
cat "$LOG"
pass="$({ grep -E '^DEVICE_TEST_PASS' "$LOG" || true; } | tail -1)"
if [ "$code" -eq 0 ] && [ -n "$pass" ]; then
    echo "RERUN_PASS step=${LABEL} attempt=1（第 1 次复跑）same_package=yes app_sha256=${NOW_APP} test_sha256=${NOW_TEST} ${pass#DEVICE_TEST_PASS }"
    exit 0
fi
echo "RERUN_FAIL step=${LABEL} attempt=1（第 1 次复跑）same_package=yes exit=${code}（见 ${LOG}；按 D10-642 整轮重跑并当真问题查）"
exit 1
