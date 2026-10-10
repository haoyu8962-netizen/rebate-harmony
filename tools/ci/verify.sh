#!/bin/bash
# 本机 CI 入口（03 §11 鸿蒙列：hvigorw assembleHap + codelinter + Hypium）。
#
# 用法：
#   tools/ci/verify.sh          全量：生成物检查 → lint（项目规则 + codelinter）→ 违反样例必须报错 → 桥启动脚本 node 执行测试 → 镜像 + ohpm install（锁文件不变）
#                               → SDK 版本核对 → Debug / Staging / Release 三套 assembleHap（每套核对 API 版本、API 20 兼容告警、应用名）
#                               → Hypium 本机单测（designsystem 另在 TZ=UTC / America/Los_Angeles 各跑一次）→ release-scan 自测 → Release 制品扫描 → Staging / Debug 必须命中全部标记
#   tools/ci/verify.sh --fast   只到生成物检查、项目 lint、SDK 版本核对与一次 Debug 构建
#
# 环境变量（都有默认值）：
#   DEVECO_HOME           DevEco Studio 的 Contents 目录（默认 /Applications/DevEco-Studio.app/Contents）
#   COULI_HM_BUILD_DIR    构建镜像目录（默认 $HOME/couli-build/rebate-harmony/<仓库目录名>）。
#                         必须是只含 ASCII 的绝对路径，且不能在 /tmp、/private/tmp、$TMPDIR 下（规划/11 §0：
#                         那是 Codex 沙箱默认可写根，构建产物不放那里）。
#
# 为什么在镜像目录里构建：hvigor 要求工程路径只含字母、数字、-_.()、空格与 @（错误 00306003，按 process.cwd()
# 的真实路径判断，软链接绕不过去），本仓库在含中文的路径下。脚本把仓库 rsync 到 ASCII 路径的镜像目录再跑
# ohpm / hvigor / codelinter，产物（.hap、单测结果、日志）留在镜像目录，仓库工作区不产生构建文件。
#
# 失败语义：set -euo pipefail；每一步（含复制产物、rsync、解析结果）失败都让整体以非零退出，并打印已完成步骤的汇总。
# 只有 grep 的「无匹配」（exit 1）在明确判断处当成正常。
# 兼容 macOS 自带 bash 3.2；路径一律加引号。
set -euo pipefail

FAST=0
BUILD_DIR_CHECK_ONLY=0
if [ "${1:-}" = "--fast" ]; then
    FAST=1
elif [ "${1:-}" = "--check-build-dir" ]; then
    # 只做镜像目录校验后退出（0 = 接受，1 = 拒绝）；供下面「含空格 TMPDIR」自测在子进程里调用。
    BUILD_DIR_CHECK_ONLY=1
elif [ -n "${1:-}" ]; then
    echo "用法：verify.sh [--fast]" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
BUILD_DIR="${COULI_HM_BUILD_DIR:-$HOME/couli-build/rebate-harmony/$(basename "$ROOT")}"
BUILD_DIR="$(printf '%s' "$BUILD_DIR" | sed -e 's#//*#/#g' -e 's#/$##')"
OUT_DIR="$BUILD_DIR/.verify-out"
LOG_DIR="$OUT_DIR/logs"

HVIGORW="$DEVECO_HOME/tools/hvigor/bin/hvigorw"
OHPM="$DEVECO_HOME/tools/ohpm/bin/ohpm"
NODE_BIN="$DEVECO_HOME/tools/node/bin"
CODELINTER="$DEVECO_HOME/plugins/codelinter/run/index.js"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_HOME/sdk}"
SDK_PKG="$DEVECO_SDK_HOME/default/sdk-pkg.json"
RESTOOL="$DEVECO_SDK_HOME/default/openharmony/toolchains/restool"
if [ -z "${JAVA_HOME:-}" ] && [ -d "$DEVECO_HOME/jbr/Contents/Home" ]; then
    export JAVA_HOME="$DEVECO_HOME/jbr/Contents/Home"   # PackageHap 需要 Java，用 DevEco 自带的 JBR
fi
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$NODE_BIN:$PATH"

RESULTS=""
CURRENT_STEP="start"

record() {
    # $1 步骤名 $2 结果（PASS / FAIL / SKIP）$3 说明
    RESULTS="$RESULTS
$(printf '%-34s %-5s %s' "$1" "$2" "${3:-}")"
}

summary() {
    echo
    echo "================ verify.sh 汇总 ================"
    printf '%s\n' "$RESULTS" | sed '/^$/d' || true
    echo "构建镜像：${BUILD_DIR}（日志在 ${LOG_DIR}）"
}

fail_fast() {
    trap - ERR
    record "$1" FAIL "${2:-}"
    summary
    echo "结果：失败"
    exit 1
}

on_error() {
    # 没有被显式检查的命令失败（set -e）也要让整体失败并留下汇总。
    local code=$? line="$1"
    trap - ERR
    record "$CURRENT_STEP" FAIL "第 ${line} 行命令意外失败（exit ${code}）"
    summary
    echo "结果：失败"
    exit 1
}
trap 'on_error $LINENO' ERR

step() {
    CURRENT_STEP="$1"
    echo
    echo "==> $1"
}

strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# 只给人看的摘录：grep 无匹配不算失败。
show_matches() {
    # $1 正则 $2 文件 $3 行数
    { grep -E "$1" "$2" || true; } | strip_ansi | head -"${3:-30}"
}

realpath_py() {
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

# ---------------------------------------------------------------- 0. 前置检查
step "前置检查"
case "$BUILD_DIR" in
    /*) ;;
    *) fail_fast "build-dir" "COULI_HM_BUILD_DIR 必须是绝对路径：$BUILD_DIR" ;;
esac
if ! printf '%s' "$BUILD_DIR" | grep -Eq '^(/[A-Za-z0-9._()@ -]+)+$'; then
    fail_fast "build-dir" "镜像目录含 hvigor 不接受的字符（只能 ASCII 字母数字 ._()@ - 空格）：$BUILD_DIR"
fi
BUILD_REAL="$(realpath_py "$BUILD_DIR")"
# 禁用目录放在数组里逐项比较：TMPDIR 可能含空格（R2-03），不能靠空格分隔的字符串再按 IFS 拆开。
FORBIDDEN=("/tmp" "/private/tmp")
if [ -n "${TMPDIR:-}" ]; then
    TMPDIR_TRIMMED="$(printf '%s' "$TMPDIR" | sed -e 's#//*#/#g' -e 's#/$##')"
    if [ -n "$TMPDIR_TRIMMED" ]; then
        FORBIDDEN+=("$TMPDIR_TRIMMED")
    fi
    FORBIDDEN+=("$(realpath_py "$TMPDIR")")
fi
for bad in "${FORBIDDEN[@]}"; do
    for candidate in "$BUILD_DIR" "$BUILD_REAL"; do
        case "$candidate/" in
            "$bad"/*) fail_fast "build-dir" "镜像目录不能在 ${bad} 下（规划/11 §0）：$BUILD_DIR" ;;
        esac
    done
done
if [ "$BUILD_DIR_CHECK_ONLY" -eq 1 ]; then
    echo "build-dir 接受：$BUILD_DIR"
    exit 0
fi

# 自测（R2-03）：在子进程里用含空格的 TMPDIR 跑上面的校验。镜像目录在该 TMPDIR 下必须被拒绝；
# 同名前缀但不在其下的目录（「temporary area-x」）与正常默认目录必须被接受。只算路径，不创建任何目录。
step "build-dir 自测（含空格的 TMPDIR）"
SPACE_TMP="$HOME/couli-build/temporary area"
build_dir_check() {
    # $1 TMPDIR $2 COULI_HM_BUILD_DIR；返回子进程退出码
    local rc=0
    TMPDIR="$1" COULI_HM_BUILD_DIR="$2" DEVECO_HOME="$DEVECO_HOME" \
        bash "$ROOT/tools/ci/verify.sh" --check-build-dir >/dev/null 2>&1 || rc=$?
    return "$rc"
}
rc=0; build_dir_check "$SPACE_TMP" "$SPACE_TMP/harmony" || rc=$?
[ "$rc" -eq 1 ] || fail_fast "build-dir 自测" "TMPDIR=「${SPACE_TMP}」时其下的镜像目录没有被拒绝（exit ${rc}）"
rc=0; build_dir_check "$SPACE_TMP/" "$SPACE_TMP/nested dir/harmony" || rc=$?
[ "$rc" -eq 1 ] || fail_fast "build-dir 自测" "TMPDIR 带尾斜杠且镜像目录含空格时没有被拒绝（exit ${rc}）"
rc=0; build_dir_check "$SPACE_TMP" "$SPACE_TMP-x/harmony" || rc=$?
[ "$rc" -eq 0 ] || fail_fast "build-dir 自测" "同前缀但不在 TMPDIR 下的目录被误拒（exit ${rc}）"
rc=0; build_dir_check "$SPACE_TMP" "$BUILD_DIR" || rc=$?
[ "$rc" -eq 0 ] || fail_fast "build-dir 自测" "当前镜像目录在含空格 TMPDIR 下被误拒（exit ${rc}）"
record "build-dir 自测" PASS "含空格 TMPDIR：其下拒绝 2 例，其外接受 2 例"
for tool in "$HVIGORW" "$OHPM" "$NODE_BIN/node" "$RESTOOL"; do
    [ -x "$tool" ] || fail_fast "toolchain" "找不到 ${tool}（设 DEVECO_HOME）"
done
[ -f "$SDK_PKG" ] || fail_fast "toolchain" "找不到 ${SDK_PKG}"
mkdir -p "$LOG_DIR"
record "build-dir" PASS "$BUILD_DIR"

# ---------------------------------------------------------------- 1. 生成物漂移
step "gen.py --check"
python3 "$ROOT/tools/codegen/gen.py" --check || fail_fast "gen.py --check" "生成物与快照不一致"
record "gen.py --check" PASS

# ---------------------------------------------------------------- 2. 项目 lint
step "lint.py（项目规则）"
python3 "$ROOT/tools/ci/lint.py" || fail_fast "lint.py" "见上方输出"
record "lint.py" PASS

step "lint-fixtures（每条规则的违反样例必须被拦下）"
FIXTURE_COUNT=0
for dir in "$ROOT"/tools/ci/lint-fixtures/HM-LINT-*; do
    [ -d "$dir" ] || continue
    rule="$(basename "$dir")"
    if output="$(python3 "$ROOT/tools/ci/lint.py" --root "$dir" 2>&1)"; then
        code=0
    else
        code=$?
    fi
    # lint.py 约定：1 = 有违规；其余非零（如 Python 崩溃）不算「拦下」。
    if [ "$code" -eq 1 ] && printf '%s\n' "$output" | grep -q "$rule"; then
        echo "  ${rule}：已拦下"
        FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
    else
        printf '%s\n' "$output" >&2
        fail_fast "lint-fixtures" "${rule} 没有被拦下（exit ${code}）"
    fi
done
[ "$FIXTURE_COUNT" -eq 10 ] || fail_fast "lint-fixtures" "应有 10 个违反样例，实际 ${FIXTURE_COUNT}"
record "lint-fixtures" PASS "HM-LINT-1…10 均被拦下"
# FU-HM-0711b R1-06、R2-03：HM-LINT-10 的词法检查正反例（字符串、注释、正则字面量、模板表达式、导入别名、局部别名等）。
python3 "$ROOT/tools/ci/lint.py" --self-test-hm10 || fail_fast "lint-hm10-self-test" "HM-LINT-10 正反例自测失败"
record "lint-hm10-self-test" PASS "HM-LINT-10 正反例全部符合"

step "一致性结果断言自测（APP-04 共性 44）"
python3 "$ROOT/tools/ci/conformance-assert.py" --self-test || fail_fast "conformance-assert" "断言脚本自测失败"
record "conformance-assert" PASS "逐条判定：未实现只豁免 normal；bad_params 回 90001、缺必测用例、空结果集都非零"

step "桥启动脚本执行测试（node 沙箱，APP-04 R2-07）"
"$NODE_BIN/node" "$ROOT/tools/ci/bridge-bootstrap-test.js" "$ROOT" || fail_fast "bridge-bootstrap-test" "见上方输出"
record "bridge-bootstrap-test" PASS "启动脚本在途 id 行为"

# ---------------------------------------------------------------- 3. SDK 版本（规划 D5）
step "SDK 版本：compile/target = 已装 SDK（API 24），compatible = API 20"
SDK_VERSION="$(python3 - "$SDK_PKG" "$ROOT/build-profile.json5" <<'PY'
import json, re, sys
pkg = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
expected = "%s(%s)" % (pkg["platformVersion"], pkg["apiVersion"])
text = open(sys.argv[2], encoding="utf-8").read()
problems = []
if pkg["apiVersion"] != "24":
    problems.append("已装 SDK 是 API %s，不是规划 D5 的 API 24" % pkg["apiVersion"])
for key, want in (("compileSdkVersion", expected), ("targetSdkVersion", expected), ("compatibleSdkVersion", "6.0.0(20)")):
    values = re.findall(r'"%s"\s*:\s*"([^"]+)"' % key, text)
    if len(values) != 2:
        problems.append("%s 应在两个 product 里各出现一次，实际 %d 次" % (key, len(values)))
    for v in values:
        if v != want:
            problems.append("%s = %s，应为 %s" % (key, v, want))
if problems:
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
print(expected)
PY
)" || fail_fast "sdk-version" "build-profile.json5 与已装 SDK / 规划 D5 不一致"
record "sdk-version" PASS "compile/target ${SDK_VERSION}，compatible 6.0.0(20)"

# API 20 兼容检查：ArkTS 编译器对「高于 compatibleSdkVersion 的接口」打告警
#   The 'X' API is supported since SDK version N. However, the current compatible SDK version is 6.0.0(20).
# 构建日志里出现这类告警即失败。先用真实告警样例证明匹配有效。
API_COMPAT_PATTERN='API is supported since SDK version [0-9]+\. However, the current compatible SDK version is'
api_compat_hits() {
    # $1 日志；有命中返回 0，无命中返回 1，grep 出错退出脚本
    local rc=0
    grep -Eq "$API_COMPAT_PATTERN" "$1" || rc=$?
    if [ "$rc" -gt 1 ]; then
        fail_fast "api-compat" "grep 读 $1 失败（exit ${rc}）"
    fi
    return "$rc"
}
step "api-compat 匹配自测"
if api_compat_hits "$ROOT/tools/ci/fixtures/api-compat-warning.log"; then
    record "api-compat 自测" PASS "真实告警样例被识别"
else
    fail_fast "api-compat 自测" "没识别出 tools/ci/fixtures/api-compat-warning.log 里的告警"
fi

# ---------------------------------------------------------------- 4. 镜像 + ohpm install
step "同步到构建镜像 $BUILD_DIR"
mkdir -p "$BUILD_DIR"
rsync -a --delete \
    --exclude 'oh_modules' --exclude 'build' --exclude '.hvigor' --exclude '.test' --exclude '.preview' \
    --exclude '.git' --exclude '.idea' --exclude '.DS_Store' --exclude '.verify-out' \
    "$ROOT/" "$BUILD_DIR/" || fail_fast "mirror" "rsync 失败"
record "mirror" PASS

step "ohpm install（锁文件不变）"
if ! (cd "$BUILD_DIR" && "$OHPM" install --all) >"$LOG_DIR/ohpm-install.log" 2>&1; then
    tail -20 "$LOG_DIR/ohpm-install.log" || true
    fail_fast "ohpm install" "见 ${LOG_DIR}/ohpm-install.log"
fi
LOCKS="$(cd "$ROOT" && find . -name oh_modules -prune -o -name build -prune -o -name 'oh-package-lock.json5' -print)" \
    || fail_fast "ohpm install" "列锁文件失败"
[ -n "$LOCKS" ] || fail_fast "ohpm install" "仓库里没有 oh-package-lock.json5"
LOCK_DRIFT=""
while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    if ! cmp -s "$ROOT/$lock" "$BUILD_DIR/$lock"; then
        LOCK_DRIFT="$LOCK_DRIFT ${lock#./}"
        diff "$ROOT/$lock" "$BUILD_DIR/$lock" 2>&1 | head -20 || true
    fi
done <<EOF
$LOCKS
EOF
[ -z "$LOCK_DRIFT" ] || fail_fast "ohpm install" "锁文件被改动或缺失：${LOCK_DRIFT}"
record "ohpm install" PASS "各 oh-package-lock.json5 未变"

# ---------------------------------------------------------------- 5. codelinter（全量模式）
if [ "$FAST" -eq 0 ]; then
    step "codelinter（0 error）"
    if [ -f "$CODELINTER" ]; then
        if (cd "$BUILD_DIR" && "$NODE_BIN/node" "$CODELINTER" -c ./code-linter.json5 -e error .) \
            >"$LOG_DIR/codelinter.log" 2>&1; then
            code=0
        else
            code=$?
        fi
        show_matches "Defects:|error " "$LOG_DIR/codelinter.log" 20
        [ "$code" -eq 0 ] || fail_fast "codelinter" "有 error（exit ${code}），见 $LOG_DIR/codelinter.log"
        DEFECTS="$({ grep -Eo 'Defects: [0-9]+; Errors: [0-9]+' "$LOG_DIR/codelinter.log" || true; } | tail -1)"
        [ -n "$DEFECTS" ] || fail_fast "codelinter" "日志里没有汇总行，无法确认 0 error"
        record "codelinter" PASS "$DEFECTS"
    else
        record "codelinter" SKIP "本机没有命令行 codelinter（${CODELINTER}）"
    fi
fi

# ---------------------------------------------------------------- 6. 构建
# 三套配置（映射见 build-profile.json5 注释）：Debug=staging×debug，Staging=staging×release，Release=default×release
step "清掉镜像里的旧构建输出（保证每次真编译，API 兼容告警不会因增量构建而漏掉）"
for d in "$BUILD_DIR"/entry/build "$BUILD_DIR"/common/*/build "$BUILD_DIR"/features/*/build; do
    rm -rf "$d"
done
rm -rf "$OUT_DIR"/*.hap
record "clean build outputs" PASS

check_hap_meta() {
    # $1 配置名 $2 .hap $3 期望应用名
    local name="$1" hap="$2" app_name="$3" dump="$OUT_DIR/$1.resources.json" meta="$OUT_DIR/$1.module.json"
    unzip -p "$hap" module.json >"$meta" || fail_fast "meta $name" "从 $hap 读 module.json 失败"
    "$RESTOOL" dump "$hap" >"$dump" 2>"$LOG_DIR/restool-$name.log" || fail_fast "meta $name" "restool dump 失败，见 $LOG_DIR/restool-$name.log"
    local detail
    detail="$(python3 - "$meta" "$dump" "$ROOT/build-profile.json5" "$app_name" <<'PY'
import json, re, sys
meta_path, dump_path, profile_path, want_name = sys.argv[1:5]
app = json.load(open(meta_path, encoding="utf-8"))["app"]
text = open(profile_path, encoding="utf-8").read()

def code(version):
    # "6.1.1(24)" → 60101024（module.json 的 xxxAPIVersion 编码：major*10^7 + minor*10^5 + patch*10^3 + api）
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)\((\d+)\)", version)
    if not m:
        raise SystemExit("版本串格式不对：" + version)
    a, b, c, api = (int(x) for x in m.groups())
    return a * 10**7 + b * 10**5 + c * 10**3 + api

target = re.findall(r'"targetSdkVersion"\s*:\s*"([^"]+)"', text)[0]
compatible = re.findall(r'"compatibleSdkVersion"\s*:\s*"([^"]+)"', text)[0]
problems = []
if app.get("targetAPIVersion") != code(target) or app.get("targetAPIVersion", 0) % 1000 != 24:
    problems.append("targetAPIVersion=%r，应为 %d（%s）" % (app.get("targetAPIVersion"), code(target), target))
if app.get("minAPIVersion") != code(compatible) or app.get("minAPIVersion", 0) % 1000 != 20:
    problems.append("minAPIVersion=%r，应为 %d（%s）" % (app.get("minAPIVersion"), code(compatible), compatible))

names = {}
def walk(o):
    if isinstance(o, dict):
        if o.get("type") == "string" and o.get("name") in ("app_name", "EntryAbility_label"):
            names.setdefault(o["name"], set()).update(v.get("value") for v in o.get("entryValues", []))
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(json.load(open(dump_path, encoding="utf-8")))
for key in ("app_name", "EntryAbility_label"):
    if names.get(key) != {want_name}:
        problems.append("%s=%r，应为 %r" % (key, sorted(names.get(key, [])), want_name))
if problems:
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)
print("targetAPIVersion=%d minAPIVersion=%d 应用名=%s" % (app["targetAPIVersion"], app["minAPIVersion"], want_name))
PY
)" || fail_fast "meta $name" "产物元信息不对（见上）"
    record "meta $name" PASS "$detail"
}

build_config() {
    # $1 配置名 $2 product $3 buildMode $4 期望应用名
    local name="$1" product="$2" mode="$3" app_name="$4" log="$LOG_DIR/build-$1.log"
    local hap="$BUILD_DIR/entry/build/$2/outputs/$2/entry-$2-unsigned.hap"
    step "hvigorw assembleHap：${name}（product=$product buildMode=${mode}）"
    rm -f "$hap"
    if ! (cd "$BUILD_DIR" && "$HVIGORW" --mode module -p product="$product" -p buildMode="$mode" assembleHap --no-daemon) \
        >"$log" 2>&1; then
        show_matches "ERROR|Error Message|error" "$log" 30
        fail_fast "build $name" "见 $log"
    fi
    [ -f "$hap" ] || fail_fast "build $name" "构建成功但找不到 $hap"
    cp "$hap" "$OUT_DIR/$name.hap" || fail_fast "build $name" "复制 $hap 到 $OUT_DIR 失败"
    cmp -s "$hap" "$OUT_DIR/$name.hap" || fail_fast "build $name" "复制后的 $OUT_DIR/$name.hap 与原件不一致"
    record "build $name" PASS "$OUT_DIR/$name.hap"

    # 这次确实编译了 ArkTS（不是增量跳过），告警才可信。
    grep -q "Finished :entry:${product}@CompileArkTS" "$log" \
        || fail_fast "api-compat $name" "日志里没有 entry:${product}@CompileArkTS 的编译记录，无法确认 API 兼容"
    if api_compat_hits "$log"; then
        show_matches "$API_COMPAT_PATTERN|ArkTS:WARN File" "$log" 20
        fail_fast "api-compat $name" "用到了高于 API 20 的接口，见 $log"
    fi
    record "api-compat $name" PASS "无高于 compatibleSdkVersion 的接口告警"
    check_hap_meta "$name" "$OUT_DIR/$name.hap" "$app_name"
}

if [ "$FAST" -eq 1 ]; then
    build_config Debug staging debug "凑狸测试"
    summary
    echo "结果：通过（--fast）"
    exit 0
fi

build_config Release default release "凑狸"
build_config Staging staging release "凑狸测试"
build_config Debug staging debug "凑狸测试"

# ---------------------------------------------------------------- 7. Hypium 本机单测（Local Test，无需模拟器）
run_unit_tests() {
    # $1 模块名 $2 模块目录（相对仓库根）$3 可选：TZ（时区回归，DS-01 格式向量要求在 UTC、America/Los_Angeles 各跑一次）
    local module="$1" dir="$2" tz="${3:-}" code
    local label="$module${tz:+ TZ=$tz}"
    local log="$LOG_DIR/test-$module${tz:+-$(printf '%s' "$tz" | tr '/' '_')}.log"
    local result="$BUILD_DIR/$dir/.test/default/intermediates/test/coverage_data/test_result.txt"
    step "Hypium 本机单测：$label"
    rm -f "$result"
    if (cd "$BUILD_DIR" && if [ -n "$tz" ]; then export TZ="$tz"; fi \
        && "$HVIGORW" --mode module -p module="$module@default" -p product=default test --no-daemon) \
        >"$log" 2>&1; then
        code=0
    else
        code=$?
    fi
    if [ ! -f "$result" ]; then
        show_matches "ERROR|Error Message" "$log" 30
        fail_fast "test $label" "没有测试结果（hvigor exit ${code}），见 $log"
    fi
    local summary_line
    summary_line="$({ grep -E '^Tests run:' "$result" || true; } | tail -1)"
    { grep -B1 -E "result=(Failure|Error|Fail)" "$result" || true; } | head -40
    echo "  $summary_line"
    if [ "$code" -eq 0 ] && printf '%s' "$summary_line" | grep -Eq 'Tests run: [1-9][0-9]*, Failure: 0, Error: 0'; then
        record "test $label" PASS "$summary_line"
        return 0
    fi
    fail_fast "test $label" "${summary_line:-无汇总}（hvigor exit ${code}，见 ${result}）"
}

run_unit_tests generated common/generated
run_unit_tests core common/core
run_unit_tests designsystem common/designsystem
# 格式向量的时区回归（BR-TEXT-11 固定 Asia/Shanghai，与设备时区无关）：Local Test 进程继承 TZ（已实测 getTimezoneOffset 随之变化）。
run_unit_tests designsystem common/designsystem UTC
run_unit_tests designsystem common/designsystem America/Los_Angeles

# ---------------------------------------------------------------- 8. Release 制品扫描
export COULI_SCAN_WORK_DIR="$OUT_DIR/scan-work"

step "release-scan 失败路径自测（非 ZIP、假 unzip / python3 返回 127 等必须失败）"
"$ROOT/tools/ci/release-scan-selftest.sh" "$OUT_DIR/scan-selftest" || fail_fast "release-scan 失败路径自测" "见上方输出"
record "release-scan 失败路径自测" PASS "12 个出错用例均非零退出，4 个正向用例符合预期"

step "release-scan：Release 必须不命中"
if "$ROOT/tools/ci/release-scan.sh" "$OUT_DIR/Release.hap"; then
    record "release-scan Release" PASS "未命中"
else
    fail_fast "release-scan Release" "exit $?（1 = 含调试残留，2 = 扫描出错）"
fi

for cfg in Staging Debug; do
    step "release-scan --self-test：$cfg 必须命中全部标记"
    if "$ROOT/tools/ci/release-scan.sh" --self-test "$OUT_DIR/$cfg.hap"; then
        record "release-scan --self-test $cfg" PASS "全部内容标记命中"
    else
        fail_fast "release-scan --self-test $cfg" "exit $?（1 = 有标记没命中，2 = 扫描出错）"
    fi
done

summary
echo "结果：通过"
