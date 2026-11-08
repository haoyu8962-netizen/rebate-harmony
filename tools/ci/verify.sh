#!/bin/bash
# 本机 CI 入口（03 §11 鸿蒙列：hvigorw assembleHap + codelinter + Hypium）。
#
# 用法：
#   tools/ci/verify.sh          全量：生成物检查 → lint（项目规则 + codelinter）→ 违反样例必须报错 → 桥启动脚本 node 执行测试 → 镜像 + ohpm install（锁文件不变）
#                               → SDK 版本核对 → Debug / Staging / Release 三套 assembleHap（每套核对 API 版本、API 20 兼容告警、应用名）
#                               → Hypium 本机单测（designsystem 另在 TZ=UTC / America/Los_Angeles 各跑一次）
#                               → release-scan 自测 → Release 制品扫描 → Staging / Debug 必须命中全部标记
#                               → 设备测试（core + entry 的 ohosTest，需已连接的鸿蒙模拟器 / 真机；没有就失败，不跳过）
#   tools/ci/verify.sh --fast   只到生成物检查、项目 lint、SDK 版本核对与一次 Debug 构建
#
# 环境变量（都有默认值）：
#   DEVECO_HOME           DevEco Studio 的 Contents 目录（默认 /Applications/DevEco-Studio.app/Contents）
#   COULI_HM_DEVICE       设备测试用的 hdc 目标（默认先连 127.0.0.1:5557，再取第一个已连接的目标）
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
# 例外（FU-HM-DEVICE-FLAKE，D10-642 ①）：设备步（最后一段）不首红即停——每个设备步都跑完，再按汇总判失败（仍非零退出）；
# 没有设备 / 设备不响应仍立即失败。构建、单元、静态检查（含 Release 制品扫描）照旧 fail-fast，且都排在设备步之前。
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

# TOKENS-PIPE-harmony：所有令牌只从锁定快照一条链路生成（brief-harmony §4-2）。管线检查先自测（合成合规参照件全过、错误实现逐个打红）
# 再查本仓库：无旁路副本与悬空引用、版本 / 快照指纹唯一、资源与 DesignTokens / CouliThemeTokens 逐叶等于快照、无手抄深色表 / 手算遮罩、
# 组件尺寸只一份、锁是 f088f04 或其后代；生成器单测（8 位色、colorsDark / shadowsDark、1.5、单源、--check 覆盖、HM-LINT-11 反例）；
# 两个 Hypium 套件与设备测试按键比对的 node 执行（设备那份是离线演练，不算设备通过）；ArkTS 严格检查。
step "TOKENS-PIPE 令牌管线检查"
python3 "$ROOT/tools/ci/tokens/check_tokens_pipe.py" --self-test || fail_fast "tokens-pipe 自测" "见上方输出"
python3 "$ROOT/tools/ci/tokens/check_tokens_pipe.py" || fail_fast "tokens-pipe" "见上方违反项"
python3 "$ROOT/tools/codegen/test_tokens.py" || fail_fast "tokens-gen-unit" "见上方用例断言"
node "$ROOT/tools/ci/tokens/run-logic.cjs" --self-test || fail_fast "tokens-logic 自测" "见上方输出"
node "$ROOT/tools/ci/tokens/run-logic.cjs" || fail_fast "tokens-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/tokens/check-arkts.cjs" --real || fail_fast "tokens-arkts" "TOKENS-PIPE 测试文件 ArkTS 严格检查失败"
record "TOKENS-PIPE 令牌管线" PASS "单源 / 无副本 / 逐叶 / 无手抄 / 组件尺寸一份 / 锁血缘 / 生成器单测 / 主题读取 / ArkTS"

# CT-LOCK-01：contract.lock 与快照一致（锁定提交重建逐字节相同 + lock files 哈希相同）。
# 必须按锁定提交重建核对（R1-02）：取不到上游仓库或其中没有锁定提交就失败，不退化成只比哈希（只比哈希用
# sync.sh --check-hashes-only 单独跑，不算本步 PASS）。上游仓库按顺序推导：
#   1. 环境变量 REBATE_PLATFORM_DIR / COULI_DIR（设了就只用它，不对则失败）；
#   2. lock 里的相对路径，相对本仓库根；
#   3. 同一相对路径，相对主检出（git worktree 的公共 .git 所在目录；worktree 下 1 不成立时用它）；
#   4. 本机固定位置 /Users/zhixing/我的项目/rebate-platform、/Users/zhixing/我的项目/couli。
step "contract.lock 一致性"
lock_field() {
    python3 -c 'import json,sys; n=json.load(open(sys.argv[1],encoding="utf-8"))
for p in sys.argv[2].split("."): n=n[p]
print(n)' "$ROOT/contract.lock" "$1"
}
is_git_repo() {
    [ -n "$1" ] && [ -d "$1" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}
# $1 环境变量值 $2 lock 相对路径 $3 本机固定位置；输出仓库绝对路径，取不到输出空串
resolve_upstream() {
    local override="$1" rel="$2" fixed="$3" main_root="" cand=""
    if [ -n "$override" ]; then
        if is_git_repo "$override"; then (cd "$override" && pwd); fi
        return 0
    fi
    main_root="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    main_root="${main_root%/.git}"
    for cand in "$ROOT/$rel" "${main_root:+$main_root/$rel}" "$fixed"; do
        if is_git_repo "$cand"; then
            (cd "$cand" && pwd)
            return 0
        fi
    done
}
RP_DIR="$(resolve_upstream "${REBATE_PLATFORM_DIR:-}" "$(lock_field rebate_platform.repo)" "/Users/zhixing/我的项目/rebate-platform")"
DT_DIR="$(resolve_upstream "${COULI_DIR:-}" "$(lock_field design_tokens.repo)" "/Users/zhixing/我的项目/couli")"
if [ -z "$RP_DIR" ] || [ -z "$DT_DIR" ]; then
    echo "取不到上游仓库（rebate-platform：${RP_DIR:-未找到}；couli：${DT_DIR:-未找到}），无法按锁定提交核对快照。" >&2
    echo "请设置 REBATE_PLATFORM_DIR=/path/to/rebate-platform COULI_DIR=/path/to/couli 后重跑；" >&2
    echo "只想核对 lock files 哈希可单独运行 tools/contracts/sync.sh --check-hashes-only（不算完整一致性检查）。" >&2
    fail_fast "contract.lock 一致性" "取不到 rebate-platform / couli，未能核对锁定提交（设 REBATE_PLATFORM_DIR、COULI_DIR）"
fi
echo "rebate-platform：$RP_DIR"
echo "couli：$DT_DIR"
REBATE_PLATFORM_DIR="$RP_DIR" COULI_DIR="$DT_DIR" "$ROOT/tools/contracts/sync.sh" --check >"$LOG_DIR/contract-lock-check.log" 2>&1 \
    || { cat "$LOG_DIR/contract-lock-check.log" >&2; fail_fast "contract.lock 一致性" "快照与锁定提交或 lock 哈希不一致（或上游仓库里没有锁定提交）"; }
tail -1 "$LOG_DIR/contract-lock-check.log"
record "contract.lock 一致性" PASS "锁定提交 $(lock_field rebate_platform.commit | cut -c1-12) 重建逐字节相同、files 哈希相同"

# ---------------------------------------------------------------- 2. 项目 lint
# 前置检查（F-HM-33 / FU-HM-0716）：HM-LINT-10 用 node + typescript 解析源码。lint.py 的推导顺序：COULI_HM_NODE →
# $DEVECO_HOME/tools/node/bin/node → $NVM_BIN/node → ~/.nvm 最高版本 → PATH；COULI_HM_TYPESCRIPT → 鸿蒙 SDK
# ets-loader 的 ohos-typescript → DevEco hvigor / ohpm 的 typescript。本机 CI 要求解析 ArkTS 语法的 ohos-typescript
# （带 ets 编译选项）；找不到即失败，不退化为手写词法启发式。
step "lint 前置：HM-LINT-10 扫描器（node + typescript）"
export DEVECO_HOME
HM10_TOOLCHAIN="$(python3 "$ROOT/tools/ci/lint.py" --hm10-toolchain)" \
    || fail_fast "lint-hm10-toolchain" "找不到 HM-LINT-10 扫描器要用的 node 或 typescript（见上方输出；设 DEVECO_HOME / COULI_HM_NODE / COULI_HM_TYPESCRIPT）"
echo "$HM10_TOOLCHAIN"
case "$HM10_TOOLCHAIN" in
    *"带 ets 编译选项"*) ;;
    *) fail_fast "lint-hm10-toolchain" "找到的 typescript 不带 ets 编译选项（不是鸿蒙 SDK 的 ohos-typescript），ArkTS 语法会退回扫描器判定" ;;
esac
record "lint-hm10-toolchain" PASS "$(printf '%s' "$HM10_TOOLCHAIN" | sed -E 's/^HM-LINT-10 扫描器：//; s/（[^）]*）/ /g; s/ +$//')"

step "lint.py（项目规则）"
python3 "$ROOT/tools/ci/lint.py" || fail_fast "lint.py" "见上方输出"
record "lint.py" PASS

step "DS-02 组件资源 / 守卫 / 目录隔离宿主测试"
python3 "$ROOT/tools/ci/ds02/test_host.py" || fail_fast "ds02-host" "见上方用例断言"
record "ds02-host" PASS

# LINT-STYLE-harmony（D10-643 ④ / D10-734）：页面层（features/*/src/main、entry/src/main、entry/src/release）禁写死颜色 / 字号 /
# 圆角 / 间距；基线 tools/ci/hardcoded-style-baseline.json 只减不增（超出失败，变少也失败须同步降基线）。
# 先自测（合规参照件全过、各类错误实现逐个打红），再查本仓库。
step "LINT-STYLE 写死样式基线"
python3 "$ROOT/tools/ci/check_hardcoded_style.py" --self-test || fail_fast "lint-style 自测" "见上方输出"
python3 "$ROOT/tools/ci/check_hardcoded_style.py" || fail_fast "lint-style" "见上方违反项（超出基线、少于基线须降基线、基线里的文件不存在）"
record "lint-style" PASS "写死样式基线"

# F-X-05a：平台内置图标（资源逐字节 = couli 原图、清单 / README、读屏隐藏与不着色守卫、接线、F-DS-01 挂起、设备用例名单）。
# 先自测（合规参照件全过、13 种错误实现逐个打红），再查本仓库；纯逻辑断言另用 node 跑真实源码。
step "F-X-05a 平台图标宿主检查"
python3 "$ROOT/tools/ci/fx05a/check_platform_icons.py" --self-test || fail_fast "fx05a-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/fx05a/check_platform_icons.py" || fail_fast "fx05a-host" "见上方违反项"
node "$ROOT/tools/ci/fx05a/run-unit.cjs" --self-test || fail_fast "fx05a-logic 自测" "见上方输出"
node "$ROOT/tools/ci/fx05a/run-unit.cjs" || fail_fast "fx05a-logic" "见上方真实产品断言"
# v3（评审 r1 R1-01）：剪贴板徽标图标键（天猫只显示文字）——core Hypium 套件 + entry 设备宿主逻辑的 node 执行。
node "$ROOT/tools/ci/fx05a/run-clipboard.cjs" --self-test || fail_fast "fx05a-clipboard 自测" "见上方输出"
node "$ROOT/tools/ci/fx05a/run-clipboard.cjs" || fail_fast "fx05a-clipboard" "剪贴板徽标图标键断言失败（天猫不得配淘宝图），见上方输出"
node "$ROOT/tools/ci/fx05a/check-arkts.cjs" --real || fail_fast "fx05a-arkts" "F-X-05a 测试文件 ArkTS 严格检查失败"
record "F-X-05a 宿主检查" PASS "资源 / 源码 / 接线 / 纯逻辑 / ArkTS"

# HM-07v-a（首页视觉 a 段）：fixture 与 Android / iOS 逐字一致、设备必跑名单、深色启动参数只在 Debug / Staging（H-V06）、
# 网格 / 搜索行 / 价值卡 / 平台格接线。先自测（12 种错误实现逐个打红），再查本仓库；ArkTS 严格检查用真实产品源码。
step "HM-07v-a 首页视觉宿主检查"
python3 "$ROOT/tools/ci/hm07v/check_home_visual.py" --self-test || fail_fast "hm07v-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/hm07v/check_home_visual.py" || fail_fast "hm07v-host" "见上方违反项"
node "$ROOT/tools/ci/hm07v/check-arkts.cjs" --real || fail_fast "hm07v-arkts" "HM-07v-a 测试文件 ArkTS 严格检查失败"
record "HM-07v-a 宿主检查" PASS "fixture / 名单 / 深色入口 / 接线 / ArkTS"
# HM-07v-b（首页视觉 b 段：弹窗与剪贴板浮层）：设备名单与第三个 entry 设备步、单测登记、读屏名 / 按钮字草稿、弹窗遮罩与几何接线、
# 邀请条排法、①⑤ 关闭按类别 / ⑤ 重试接线、半屏系统把手、假服务场景词（tools/ci/hm07v/check_overlays.py），以及 b 段测试文件 ArkTS 严格检查。
step "HM-07v-b 弹窗与剪贴板浮层宿主检查"
python3 "$ROOT/tools/ci/hm07v/check_overlays.py" --self-test || fail_fast "hm07vb-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/hm07v/check_overlays.py" || fail_fast "hm07vb-host" "见上方违反项"
node "$ROOT/tools/ci/hm07v/check-arkts-b.cjs" --real || fail_fast "hm07vb-arkts" "HM-07v-b 测试文件 ArkTS 严格检查失败"
record "HM-07v-b 宿主检查" PASS "名单 / 设备步 / 草稿 / 接线 / ArkTS"
# HM-05r（剪贴板改版对齐 BR-ID-16）：importGate 与 Android 字节一致由 gen.py --check 守；这里查 Release 不声明 READ_PASTEBOARD、
# 权限清单不登记 clipboard_read、回前台弹层只有一个来源、半屏关闭接 onWillDismiss、旧端键不再读、默认装配、设备名单与第五个 entry 设备步
# （tools/ci/hm05r/check_hm05r.py，先自测），纯逻辑套件的 node 执行（run-logic.cjs，真实产品），以及本任务测试文件 ArkTS 严格检查。
step "HM-05r 剪贴板用途说明与自动识别宿主检查"
python3 "$ROOT/tools/ci/hm05r/check_hm05r.py" --self-test || fail_fast "hm05r-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/hm05r/check_hm05r.py" || fail_fast "hm05r-host" "见上方违反项"
node "$ROOT/tools/ci/hm05r/run-logic.cjs" || fail_fast "hm05r-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/hm05r/check-arkts.cjs" --real || fail_fast "hm05r-arkts" "HM-05r 测试文件 ArkTS 严格检查失败"
record "HM-05r 宿主检查" PASS "权限声明 / 弹层来源 / 关闭语义 / 端键 / 名单 / 纯逻辑 / ArkTS"
# APP-12v-harmony（「我的」Tab 视觉）：逻辑文件 sha256 合入前后一致（brief-harmony §3.1）、MeTabView 守卫区与 a4eaed2 逐字节一致（§3.2）、
# entry 三处自动入口只走 autoLoad（H-M01）、宫格等功能图标改 HarmonyOS Symbol（H-M03，收益看板 histogram）、无 LoadingProgress、
# 设备名单与第六个 entry 设备步（tools/ci/me12v/check_me_visual.py，先自测）；纯逻辑套件的 node 执行（run-logic.cjs，真实产品）；
# 本任务测试文件 ArkTS 严格检查。
step "APP-12v 「我的」视觉宿主检查"
python3 "$ROOT/tools/ci/me12v/check_me_visual.py" --self-test || fail_fast "me12v-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/me12v/check_me_visual.py" || fail_fast "me12v-host" "见上方违反项"
node "$ROOT/tools/ci/me12v/run-logic.cjs" || fail_fast "me12v-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/me12v/check-arkts.cjs" --real || fail_fast "me12v-arkts" "APP-12v 测试文件 ArkTS 严格检查失败"
record "APP-12v 宿主检查" PASS "逻辑零改动 / 守卫区 / 自动入口 / Symbol / 名单 / 纯逻辑 / ArkTS"
# APP-12w-a-harmony（设置一族视觉）：逻辑文件 / 注销线 / 权限 / 契约 / features/me 其余文件 / DS / staging sha256 合入前后一致、MeKit 一字不动
# （brief-a-harmony §3.1、H-S01 / H-S02）、SettingsView 守卫区与 cc872c3 逐字节一致（§3.2，按符号）、回调体留在 SettingsView、私有件不读 config /
# 控制器、协议半屏遮罩令牌、无新增系统 Toggle / showToast 直用、me-vectors 已有组不变、设备名单与第七个 entry 设备步
# （tools/ci/me12wa/check_settings_visual.py，先自测）；visualSettings 夹具的 Core 套件 node 执行（run-logic.cjs，真实产品）；ArkTS 严格检查。
step "APP-12w-a 设置一族视觉宿主检查"
python3 "$ROOT/tools/ci/me12wa/check_settings_visual.py" --self-test || fail_fast "me12wa-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/me12wa/check_settings_visual.py" || fail_fast "me12wa-host" "见上方违反项"
node "$ROOT/tools/ci/me12wa/run-logic.cjs" || fail_fast "me12wa-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/me12wa/check-arkts.cjs" --real || fail_fast "me12wa-arkts" "APP-12w-a 测试文件 ArkTS 严格检查失败"
record "APP-12w-a 宿主检查" PASS "逻辑零改动 / 守卫区 / 回调体 / MeKit / 遮罩 / 名单 / 纯逻辑 / ArkTS"
# APP-12w-b-harmony（隐私中心 / 关于 / 联系客服半屏视觉）：执行器 / 纯规则 / 客服出口 / 隐私与剪贴板 / 强更 / 权限 / features/me 其余文件 / DS
# sha256 合入前后一致（brief-b-harmony §3.1）、三视图守卫区与 8699e5a 逐字节一致（§3.2，按符号：confirmWithdraw / aboutToDisappear / apply、
# 四个协议去向、个性化 onToggle、复制回调、客服四个动作与键）、RootPage 的客服 bindSheet 只多 maskColor 一项（H-P06）、私有件
# PrivacyAboutCsParts 只收值与 @Event、无删除入口 / 不申请权限、privacy-visual-vectors 与 Android / iOS 逐字节相同（H-P14）、设备名单与第八个
# entry 设备步（tools/ci/me12wb/check_privacy_visual.py，先自测）；夹具的 Core 套件 node 执行（run-logic.cjs，真实产品）；ArkTS 严格检查。
step "APP-12w-b 隐私中心 / 关于 / 客服视觉宿主检查"
python3 "$ROOT/tools/ci/me12wb/check_privacy_visual.py" --self-test || fail_fast "me12wb-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/me12wb/check_privacy_visual.py" || fail_fast "me12wb-host" "见上方违反项"
node "$ROOT/tools/ci/me12wb/run-logic.cjs" || fail_fast "me12wb-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/me12wb/check-arkts.cjs" --real || fail_fast "me12wb-arkts" "APP-12w-b 测试文件 ArkTS 严格检查失败"
record "APP-12w-b 宿主检查" PASS "逻辑零改动 / 守卫区 / 红线 / RootPage 遮罩 / 私有件 / 夹具 / 名单 / 纯逻辑 / ArkTS"
# APP-12w-c-harmony（账号状态 RiskNotice / 申诉 Appeal 视觉）：执行器 / 纯规则 / 会话 / entry 接线与确认框 / 注销线 / 钱包 / 路由 / features/me 其余
# 文件 / MeKit / DS / 契约 sha256 合入前后一致（brief-c-harmony §3.1）、两视图守卫区与 30201f0 逐字节一致（§3.2，按符号：提交按钮三属性与回调、
# onChange、ForEach 键、【再次申诉】、主按钮去向、出口三链接与显示条件、detailRows / noteKey 只许 H-R03 键串替换、title() 只许 H-R06）、
# 处罚 / 申诉红线静态（无点击手势、不读 CT-26e、不接 SLA、不比时间）、私有件 RiskAppealParts 只收值与 @Event、risk-appeal-visual-vectors 与
# Android 逐字节相同（H-R14）、设备名单与第九个 entry 设备步（tools/ci/me12wc/check_risk_visual.py，先自测）；夹具的 Core 套件与私有件纯函数取值表
# node 执行（run-logic.cjs，真实产品）；ArkTS 严格检查。
step "APP-12w-c 账号状态 / 申诉视觉宿主检查"
python3 "$ROOT/tools/ci/me12wc/check_risk_visual.py" --self-test || fail_fast "me12wc-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/me12wc/check_risk_visual.py" || fail_fast "me12wc-host" "见上方违反项"
node "$ROOT/tools/ci/me12wc/run-logic.cjs" || fail_fast "me12wc-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/me12wc/check-arkts.cjs" --real || fail_fast "me12wc-arkts" "APP-12w-c 测试文件 ArkTS 严格检查失败"
record "APP-12w-c 宿主检查" PASS "逻辑零改动 / 守卫区 / 处罚申诉红线 / 私有件 / 夹具 / 名单 / 纯逻辑 / ArkTS"
# FU-X-STAGING-HOSTS：staging 五个主机只在 src/staging、LOCAL / TEST 仍占位、正式不变、深链主机、分享域不手写、release-scan 新规则
# （合成制品，tools/ci/stghosts/check_staging_hosts.py，先自测）；stream 分流套件的 node 执行（run-logic.cjs，真实产品）；ArkTS 严格检查。
step "FU-X-STAGING-HOSTS 宿主检查"
python3 "$ROOT/tools/ci/stghosts/check_staging_hosts.py" --self-test || fail_fast "stghosts-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/stghosts/check_staging_hosts.py" || fail_fast "stghosts-host" "见上方违反项"
node "$ROOT/tools/ci/stghosts/run-logic.cjs" || fail_fast "stghosts-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/stghosts/check-arkts.cjs" --real || fail_fast "stghosts-arkts" "FU-X-STAGING-HOSTS 测试文件 ArkTS 严格检查失败"
record "FU-X-STAGING-HOSTS 宿主检查" PASS "主机位置 / 占位 / 正式不变 / 深链 / release-scan 规则 / stream 分流 / ArkTS"
# FU-X-HOME-PAGE-API：首页走契约 getPage + listPageSectionItems——Release / Staging 的 BuildVariant.homeContract(real)、AppHome 注入真实端口、
# 假服务默认关闭、契约快照与生成物、基本模式白名单（tools/ci/homeapi/check_home_page_api.py，先自测）；core 套件的 node 执行；ArkTS 严格检查。
step "FU-X-HOME-PAGE-API 宿主检查"
python3 "$ROOT/tools/ci/homeapi/check_home_page_api.py" --self-test || fail_fast "homeapi-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/homeapi/check_home_page_api.py" || fail_fast "homeapi-host" "见上方违反项"
node "$ROOT/tools/ci/homeapi/run-logic.cjs" || fail_fast "homeapi-logic" "见上方真实产品断言"
node "$ROOT/tools/ci/homeapi/check-arkts.cjs" --real || fail_fast "homeapi-arkts" "FU-X-HOME-PAGE-API 测试文件 ArkTS 严格检查失败"
record "FU-X-HOME-PAGE-API 宿主检查" PASS "生产入口 / 假服务默认关 / 契约与生成物 / 基本模式白名单 / 取数调度 / ArkTS"
# FU-HM-LOCK-PLACEHOLDERS：文案占位符通用守卫——产品代码里每个 fmt1 / fmt / format1 / format(KEY, VARS) / text(KEY).split('{x}') / 常量模板
# 代入调用，代入名须在生效文案（契约 texts 优先、否则草稿）里存在、文案占位符须都有代入（tools/ci/lockph/check_placeholders.py，先自测）；
# 冷静期截止 / 时间线与验证码倒计时两处升锁回归在契约与草稿回落下的真实渲染（run-logic.cjs，真实产品文案来源）。
step "FU-HM-LOCK-PLACEHOLDERS 文案占位符检查"
python3 "$ROOT/tools/ci/lockph/check_placeholders.py" --self-test || fail_fast "lockph-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/lockph/check_placeholders.py" || fail_fast "lockph-host" "见上方违反项"
node "$ROOT/tools/ci/lockph/run-logic.cjs" || fail_fast "lockph-logic" "见上方真实产品断言"
record "FU-HM-LOCK-PLACEHOLDERS 检查" PASS "占位符守卫（自测 14 个错误实现）/ 冷静期与倒计时两处回归"
# FU-X-CTA-KEY-DRIFT（D10-856 / D10-857 / D10-861）：锁 a89c1ec3a 与四个同名快照、向量与 iOS 逐字节、五个调用点的文案函数对 cta 键等同
# 向量 contract 模式、默认诊断只带 text_key、调用方不覆盖诊断、两个新套件已登记（tools/ci/ctakey/check_cta_key.py，先自测）；新套件 ArkTS 严格检查。
step "FU-X-CTA-KEY-DRIFT cta 文案键宿主检查"
python3 "$ROOT/tools/ci/ctakey/check_cta_key.py" --self-test || fail_fast "ctakey-host 自测" "见上方输出"
python3 "$ROOT/tools/ci/ctakey/check_cta_key.py" || fail_fast "ctakey-host" "见上方违反项"
node "$ROOT/tools/ci/ctakey/check-arkts.cjs" --real || fail_fast "ctakey-arkts" "FU-X-CTA-KEY-DRIFT 测试文件 ArkTS 严格检查失败"
record "FU-X-CTA-KEY-DRIFT 宿主检查" PASS "锁 / 同名快照 / 向量 / 调用点文案函数 / 默认诊断 / 登记（自测 29 个错误实现）/ ArkTS"

step "FU-HM-DEVICE-FLAKE 设备测试设施自测"
node "$ROOT/tools/ci/flake/run-logic.cjs" || fail_fast "flake-logic" "见上方 FlakeKit 断言"
python3 "$ROOT/tools/ci/flake/test_device_steps.py" || fail_fast "flake-device-steps" "见上方设备步汇总 / 复跑脚本断言"
node "$ROOT/tools/ci/flake/check-arkts.cjs" --real || fail_fast "flake-arkts" "见上方 ArkTS 报错"
record "FU-HM-DEVICE-FLAKE 设施自测" PASS "截屏校验重拍 / 有界等待 / 设备步跑完再汇总 / 复跑同包 / ArkTS（替身，不算设备通过）"

step "DS-02 纯逻辑与测试设施自测"
node "$ROOT/tools/ci/ds02/run-unit.cjs" || fail_fast "ds02-logic" "见上方真实产品断言"
PYTHONPATH="$ROOT/tools/codegen:$ROOT/tools/ci/ds02${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$ROOT/tools/ci/ds02/test_test_facilities.py" || fail_fast "ds02-facilities" "见上方设施反例"
node "$ROOT/tools/ci/ds02/check-ui-facilities.cjs" || fail_fast "ds02-ui-facilities" "见上方遍历 / 启动 / 注册反例"
record "ds02-logic/facilities" PASS "设施模拟不计入设备通过；entry_test 仍须真机全量执行"

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
# FU-HM-0711b R1-06、R2-03、F-HM-33：HM-LINT-10 的正反例（字符串、注释、正则字面量、模板表达式、导入别名、局部别名、泛型 / 比较、case、ASI 等）。
python3 "$ROOT/tools/ci/lint.py" --self-test-hm10 || fail_fast "lint-hm10-self-test" "HM-LINT-10 正反例自测失败"
record "lint-hm10-self-test" PASS "HM-LINT-10 正反例全部符合"

# FU-HM-0724 测试评审 T-04：产品接线检查——AppOrders / AppWallet / AppHome / OrderListView 必须调用 Core 新协调器并传身份快照，
# 旧调度路径不得再被调用（单测只覆盖 Core 协调器本身）。先跑样例自测（漏接任一入口必须失败），再检查本仓库。
step "接线检查（FU-HM-0724 E1–E4）"
python3 "$ROOT/tools/ci/wiring-check.py" --self-test || fail_fast "wiring-check 自测" "样例与期望不符，见上方输出"
python3 "$ROOT/tools/ci/wiring-check.py" --root "$ROOT" || fail_fast "wiring-check" "组合入口没有接上新协调器或仍走旧路径，见上方输出"
record "wiring-check" PASS "E0–E4 接线满足（含 FU-HM-0725 第 2 版 E2-pages / E3-input / E3-takeover / E4-source / E4-key / E4-same-source 一行转发；FU-HM-0726 E2-pages 五页、E2-pages-sync、身份参数只看返回值），样例自测通过"

# FU-HM-0718 第 3 项：「扫不完 / 不支持」必须以 4 失败（不是 0，也不是表示「有违反」的 1）。
step "lint-fixtures-exit4（不支持的文件、词法边界无法确认、不可列举的源码子目录必须以 4 失败）"
EXIT4_COUNT=0
for dir in "$ROOT"/tools/ci/lint-fixtures-exit4/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    if output="$(python3 "$ROOT/tools/ci/lint.py" --root "$dir" 2>&1)"; then
        code=0
    else
        code=$?
    fi
    if [ "$code" -eq 4 ]; then
        echo "  ${name}：exit 4"
        EXIT4_COUNT=$((EXIT4_COUNT + 1))
    else
        printf '%s\n' "$output" >&2
        fail_fast "lint-fixtures-exit4" "${name} 应以 4 失败（exit ${code}）"
    fi
done
# FU-HM-0723：另加 2 个解析器判不了的样例（未闭合块注释、模板插值未闭合 → 语法错误）。第 2 轮修复起词法由 TypeScript 解析器决定，
# 原来按「歧义」以 4 失败的两个合法样例（) 之后的 /、变量 of 之后的 /）移到 lint-fixtures-lex，必须报出（1）。
# 末轮窄修 R3-03：再加 1 个（import() 的模块名静态确定不了）；末轮窄修二 RC-02 再加 1 个（同名参数遮蔽外层 const）。
# 末轮窄修三 RC-03 再加 1 个（navBar 高度参数的同名绑定冲突）。
[ "$EXIT4_COUNT" -eq 7 ] || fail_fast "lint-fixtures-exit4" "应有 7 个 exit 4 样例，实际 ${EXIT4_COUNT}"
# 一个正常源码 + 一个不可列举的源码子目录（git 存不了权限，现造；跑完恢复权限再删）。
EXIT4_TMP="$(mktemp -d "${TMPDIR:-/tmp}/couli-lint-exit4.XXXXXX")"
mkdir -p "$EXIT4_TMP/entry/src/staging/ets/variant/hidden"
cp "$ROOT/tools/ci/lint-fixtures-exit4/HM-LINT-10-js/entry/src/staging/ets/variant/Ok.ets" "$EXIT4_TMP/entry/src/staging/ets/variant/"
printf 'export const fake = DebugFakeServer.enabled;\n' >"$EXIT4_TMP/entry/src/staging/ets/variant/hidden/Bad.ets"
chmod 000 "$EXIT4_TMP/entry/src/staging/ets/variant/hidden"
if output="$(python3 "$ROOT/tools/ci/lint.py" --root "$EXIT4_TMP" 2>&1)"; then
    code=0
else
    code=$?
fi
chmod 755 "$EXIT4_TMP/entry/src/staging/ets/variant/hidden"
rm -rf "$EXIT4_TMP"
if [ "$code" -ne 4 ]; then
    printf '%s\n' "$output" >&2
    fail_fast "lint-fixtures-exit4" "不可列举的源码子目录应以 4 失败（exit ${code}）"
fi
echo "  不可列举的源码子目录：exit 4"
record "lint-fixtures-exit4" PASS "js / c 不支持、词法边界无法确认、不可列举的子目录均以 4 失败"

# FU-HM-0723 第 2 轮修复：HM-LINT-1…9 的注释 / 字符串 / 正则 / 导入改由 TypeScript 解析器给出（hm10-scan.js --lex）。手写词法曾漏报的
# 合法代码样例（非空断言后的除号、type 导入夹注释、转义模块名、U+2028 / U+2029 行终止符等）必须以 1 失败并报出 EXPECT 里的规则号。
step "lint-fixtures-lex（解析器词法的违反样例必须被拦下）"
LEX_COUNT=0
for dir in "$ROOT"/tools/ci/lint-fixtures-lex/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    want="$(tr -d '[:space:]' < "$dir/EXPECT")"
    if output="$(python3 "$ROOT/tools/ci/lint.py" --root "$dir" 2>&1)"; then
        code=0
    else
        code=$?
    fi
    if [ "$code" -eq 1 ] && [ -n "$want" ] && printf '%s\n' "$output" | grep -q "$want "; then
        echo "  ${name}：已拦下（${want}）"
        LEX_COUNT=$((LEX_COUNT + 1))
    else
        printf '%s\n' "$output" >&2
        fail_fast "lint-fixtures-lex" "${name} 应以 1 失败并报 ${want}（exit ${code}）"
    fi
done
# 末轮窄修再加 4 个（R3-02 emoji、R3-03 两个动态导入拼接、R3-04 转义百分号）。
[ "$LEX_COUNT" -eq 11 ] || fail_fast "lint-fixtures-lex" "应有 11 个解析器词法样例，实际 ${LEX_COUNT}"
record "lint-fixtures-lex" PASS "11 个合法代码反例均被拦下"

step "一致性结果断言自测（APP-04 共性 44）"
python3 "$ROOT/tools/ci/conformance-assert.py" --self-test || fail_fast "conformance-assert" "断言脚本自测失败"
record "conformance-assert" PASS "逐条判定：未实现只豁免 normal；bad_params 回 90001、缺必测用例、空结果集都非零"

step "桥启动脚本执行测试（node 沙箱，APP-04 R2-07）"
"$NODE_BIN/node" "$ROOT/tools/ci/bridge-bootstrap-test.js" "$ROOT" || fail_fast "bridge-bootstrap-test" "见上方输出"
record "bridge-bootstrap-test" PASS "启动脚本在途 id 行为"

# F-X-24：远程禁用桥方法（配置整键校验、准入 90403、has()、原生推送 / 去重 / 令牌门控）。锁定版本的 H5 SDK 源码
# 从上面 contract.lock 一致性一步解析出的 rebate-platform（RP_DIR，按 contract.lock 的提交 git show）读取；TypeScript 用
# DevEco SDK 自带的。
step "远程禁用桥方法执行测试（node，F-X-24）"
REBATE_PLATFORM_DIR="$RP_DIR" \
    COULI_HM_TYPESCRIPT="$DEVECO_SDK_HOME/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript" \
    "$NODE_BIN/node" "$ROOT/tools/ci/bridge-disabled-methods-test.js" >"$LOG_DIR/bridge-disabled-methods-test.log" 2>&1 \
    || { tail -40 "$LOG_DIR/bridge-disabled-methods-test.log" || true; fail_fast "bridge-disabled-methods-test" "见 ${LOG_DIR}/bridge-disabled-methods-test.log"; }
grep -E '^(PASS|FAIL) |^H5 has\(\) source|^Tests run' "$LOG_DIR/bridge-disabled-methods-test.log" || true
BDM_SUMMARY="$(grep -E '^Tests run' "$LOG_DIR/bridge-disabled-methods-test.log" | tail -1 || true)"
[ -n "$BDM_SUMMARY" ] || fail_fast "bridge-disabled-methods-test" "没有测试汇总行"
record "bridge-disabled-methods-test" PASS "$BDM_SUMMARY"

step "F-X-25 切号通知与可信 Web 存储测试（Node）"
"$NODE_BIN/node" "$ROOT/tools/ci/fx25-auth-change-test.js" >"$LOG_DIR/fx25-auth-change-test.log" 2>&1 \
    || { tail -60 "$LOG_DIR/fx25-auth-change-test.log" || true; fail_fast "fx25-auth-change-test" "见 ${LOG_DIR}/fx25-auth-change-test.log"; }
grep -E '^(PASS|FAIL) |^Registered:' "$LOG_DIR/fx25-auth-change-test.log" || true
record "fx25-auth-change-test" PASS "实际生产声明、生命周期和 Core 判定用例"


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

# ---------------------------------------------------------------- 7b. Release 制品扫描
# FU-HM-DEVICE-FLAKE（D10-642 ①）：静态的制品扫描挪到设备步之前（只依赖第 6 步的制品），仍 fail-fast；设备步排在最后、跑完再汇总，
# 设备步红时「构建、单元、静态检查都已通过」在同一轮里即可核对。
export COULI_SCAN_WORK_DIR="$OUT_DIR/scan-work"

step "release-scan 失败路径自测（非 ZIP、假 unzip / python3 返回 127 等必须失败）"
"$ROOT/tools/ci/release-scan-selftest.sh" "$OUT_DIR/scan-selftest" || fail_fast "release-scan 失败路径自测" "见上方输出"
record "release-scan 失败路径自测" PASS "12 个出错用例均非零退出，6 个正向用例符合预期（含 APP-10b R1-04 测试源码标记反向自测）"

step "release-scan：Release 必须不命中"
if "$ROOT/tools/ci/release-scan.sh" "$OUT_DIR/Release.hap"; then
    record "release-scan Release" PASS "未命中"
else
    fail_fast "release-scan Release" "exit $?（1 = 含调试残留，2 = 扫描出错）"
fi

step "F-X-05a：Release 包内平台图字节与清单一致（V7）"
python3 "$ROOT/tools/ci/fx05a/check_platform_icons.py" --hap "$OUT_DIR/Release.hap" \
    || fail_fast "fx05a-hap" "Release 包内平台图与源文件不一致或混入清单 / 替身，见上方输出"
record "F-X-05a Release 平台图" PASS "包内字节 = couli 原图"

step "HM-07v-a：深色启动参数 Release 不含、Staging / Debug 含（H-V06）"
python3 "$ROOT/tools/ci/hm07v/check_home_visual.py" --hap "$OUT_DIR/Release.hap" \
    || fail_fast "hm07v-hap Release" "Release 制品含 couli_debug_color_mode，见上方输出"
for cfg in Staging Debug; do
    python3 "$ROOT/tools/ci/hm07v/check_home_visual.py" --hap-staging "$OUT_DIR/$cfg.hap" \
        || fail_fast "hm07v-hap $cfg" "$cfg 制品缺 couli_debug_color_mode"
done
record "HM-07v-a 深色入口制品检查" PASS "Release 不含；Staging / Debug 含"

step "HM-05r：Release 制品不声明 READ_PASTEBOARD（D1：CAP-X-02 实测前不声明、探测恒 not_eligible）"
python3 "$ROOT/tools/ci/hm05r/check_hm05r.py" --hap "$OUT_DIR/Release.hap" \
    || fail_fast "hm05r-hap Release" "Release 制品的 module.json 声明了 READ_PASTEBOARD，见上方输出"
record "HM-05r Release 权限声明" PASS "未声明 ohos.permission.READ_PASTEBOARD"

for cfg in Staging Debug; do
    step "release-scan --self-test：$cfg 必须命中全部标记"
    if "$ROOT/tools/ci/release-scan.sh" --self-test "$OUT_DIR/$cfg.hap"; then
        record "release-scan --self-test $cfg" PASS "全部内容标记命中"
    else
        fail_fast "release-scan --self-test $cfg" "exit $?（1 = 有标记没命中，2 = 扫描出错）"
    fi
done


# ---------------------------------------------------------------- 8. 设备测试（ohosTest，鸿蒙模拟器 / 真机）
# FU-HM-0718 第 1 轮修复 R1-01：Local Test 里 fileIo 是空实现，真实文件系统行为（statSync 的错误码、FileSlot 遇到查不了的路径）
# 只能在设备上验。core 的 src/ohosTest 构建成测试包（target ohosTest，与 Release 同一套 src/release），由 device-test.sh 签名、
# 安装、aa test 并解析结果。**没有已连接的设备 / 模拟器就失败，不跳过**（先启动 DevEco 模拟器，或设 COULI_HM_DEVICE）。
# 注意：测试包与应用同包名（com.couli.hm），device-test.sh 会先卸掉设备上已装的应用，跑完再卸掉测试包。
run_device_tests() {
    # $1 模块名 $2 模块目录（相对仓库根）$3 ohosTest 的 module.name $4 product $5 被测应用包
    # $6 步骤名（同一测试包分多步跑时区分日志与工作目录；缺省 = 模块名）$7 Hypium 套件过滤（class=… / notClass=…；缺省全部）
    # $8 entry_test 必跑名单（main / hm07va / hm07vb / hm05r / me12v / me12wa / me12wb / me12wc / all，见 ds02/check_device_result.py）
    # HM-07v-a（编排 D10-405 D4）：同一模块第二步复用第一步构建好的测试包（同包），只重新签名、卸载重装、执行。
    local module="$1" dir="$2" test_module="$3" log="$LOG_DIR/device-test-build-$1.log" code
    local test_product="${4:-default}" application_hap="${5:-}"
    local label="${6:-$1}" test_filter="${7:-}" device_set="${8:-all}"
    local test_task="genOnDeviceTestHap"
    if [ "$module" = entry ]; then test_task="assembleHap"; fi
    local hap="$BUILD_DIR/$dir/build/$test_product/outputs/ohosTest/$module-ohosTest-unsigned.hap"
    step "设备测试：${label}（ohosTest，${test_module}${test_filter:+，$test_filter}）"
    case "${DEVICE_TEST_BUILT:- }" in
        *" $module "*)
            [ -f "$hap" ] || fail_fast "device-test $label" "复用的测试包不见了：$hap"
            run_device_test_hap "$module" "$test_module" "$hap" "$application_hap" "$label" "$test_filter" "$device_set"
            return
            ;;
    esac
    rm -f "$hap"
    # F-X-25 t2：测试包装在被测应用旁边（同一 bundle）时，它带进来的 core / generated 必须与应用同源，否则运行时同名模块
    # （&core/Index&1.0.0）解析到测试包那一份 Release 版，Staging 应用缺 DebugCapabilities 等导出被杀（App died）。hvigor 测试模式
    # 下依赖只能取 default target，所以只在构建镜像里、只在构建测试包期间把这些模块的 default 源码临时换成应用 target 的
    # （tools/ci/ohostest-app-source.cjs；构建完立刻还原，随后核对测试包里的源码记录）。仓库文件不动。
    if [ -n "$application_hap" ]; then
        "$NODE_BIN/node" "$ROOT/tools/ci/ohostest-app-source.cjs" apply "$BUILD_DIR" "$test_product" "$module" \
            || fail_fast "device-test $module" "测试包同源准备失败"
    fi
    if ! (cd "$BUILD_DIR" && "$HVIGORW" --mode module -p module="$module@ohosTest" -p isOhosTest=true -p product="$test_product" \
        -p buildMode=debug "$test_task" --no-daemon) >"$log" 2>&1; then
        [ -z "$application_hap" ] || "$NODE_BIN/node" "$ROOT/tools/ci/ohostest-app-source.cjs" restore "$BUILD_DIR" || true
        show_matches "ERROR|Error Message|error" "$log" 30
        fail_fast "device-test $module" "测试包构建失败，见 $log"
    fi
    if [ -n "$application_hap" ]; then
        "$NODE_BIN/node" "$ROOT/tools/ci/ohostest-app-source.cjs" restore "$BUILD_DIR" \
            || fail_fast "device-test $module" "构建镜像的模块配置还原失败"
    fi
    [ -f "$hap" ] || fail_fast "device-test $module" "构建成功但找不到 $hap"
    if [ -n "$application_hap" ]; then
        "$NODE_BIN/node" "$ROOT/tools/ci/ohostest-app-source.cjs" check "$BUILD_DIR" "$test_product" "$module" "$hap" \
            || fail_fast "device-test $module" "测试包与被测应用 $application_hap 不同源"
    fi
    grep -q "Finished :${module}:ohosTest@OhosTestCompileArkTS" "$log" \
        || fail_fast "device-test $module" "日志里没有 ${module}:ohosTest@OhosTestCompileArkTS 的编译记录"
    if api_compat_hits "$log"; then
        show_matches "$API_COMPAT_PATTERN" "$log" 20
        fail_fast "device-test $module" "测试包用到了高于 API 20 的接口，见 $log"
    fi
    DEVICE_TEST_BUILT="${DEVICE_TEST_BUILT:- }$module "
    run_device_test_hap "$module" "$test_module" "$hap" "$application_hap" "$label" "$test_filter" "$device_set"
}
run_device_test_hap() {
    # $1 模块名 $2 ohosTest 的 module.name $3 测试包 $4 被测应用包 $5 步骤名 $6 套件过滤 $7 必跑名单
    local module="$1" test_module="$2" hap="$3" application_hap="$4" label="$5" code
    local out="$OUT_DIR/device-test-$label.log" work="$OUT_DIR/device-test"
    # 每一步独立工作目录（aa test 结果文件同名，分步时不能互相覆盖）。
    if [ "$label" != "$module" ]; then work="$OUT_DIR/device-test-$label"; fi
    # FU-HM-DEVICE-FLAKE（评审 r1 S1-1）：开跑前打印本步所用两包的 sha256（固定格式，rerun-device-step.sh 据此核「同一个安装包」）。
    local app_sha="none" test_sha="missing"
    if [ -n "$application_hap" ]; then
        app_sha="missing"
        if [ -f "$application_hap" ]; then app_sha="$(shasum -a 256 "$application_hap" | awk '{ print $1 }')"; fi
    fi
    if [ -f "$hap" ]; then test_sha="$(shasum -a 256 "$hap" | awk '{ print $1 }')"; fi
    echo "DEVICE_HAP_SHA256 step=$label app=$app_sha test=$test_sha"
    record "hap-sha256 $label" INFO "app=$app_sha test=$test_sha"
    if COULI_HM_TEST_FILTER="$6" COULI_HM_DEVICE_SET="$7" \
        "$ROOT/tools/ci/device-test.sh" "$hap" "$test_module" "$work" "$application_hap" >"$out" 2>&1; then
        code=0
    else
        code=$?
    fi
    cat "$out"
    # 评审 r2 S2-A：设施留痕计数（补登录 / 截屏重拍 / 截屏无效）进汇总，只打印、不判定。
    local trace
    trace="$({ grep -E '^FLAKE_TRACE ' "$out" || true; } | tail -1)"
    if [ -n "$trace" ]; then record "flake-trace $label" INFO "${trace#FLAKE_TRACE }"; fi
    if [ "$code" -ne 0 ]; then
        device_step_failed "$label" "exit ${code}（安装失败、有用例失败或超过 1800 秒），见 $out" "$out"
        return 0
    fi
    local pass
    pass="$({ grep -E '^DEVICE_TEST_PASS' "$out" || true; } | tail -1)"
    if [ -z "$pass" ]; then
        device_step_failed "$label" "device-test.sh 退出 0 但没有 DEVICE_TEST_PASS 行" "$out"
        return 0
    fi
    record "device-test $label" PASS "${pass#DEVICE_TEST_PASS }"
}
# FU-HM-DEVICE-FLAKE（D10-642 ①）：设备步不再首红即停——记下失败、接着跑后面的设备步，全部跑完后在下方统一判失败（整体仍非零退出）。
# 例外（环境问题，后面各步必然同样失败）：没有设备 / 设备不响应 / 失联 / 开机未完成，立即 fail-fast。测试包构建、同源核对、API 兼容等仍在
# run_device_tests 里 fail-fast（属构建）。
device_step_failed() {
    # $1 步骤名 $2 说明 $3 该步日志
    if grep -qE '没有已连接的鸿蒙设备|不响应（hdc shell 失败|没有开机完成|失联' "$3" 2>/dev/null; then
        fail_fast "device-test $1" "$2（设备不可用，后续设备步不再跑）"
    fi
    record "device-test $1" FAIL "$2"
    DEVICE_FAILED="${DEVICE_FAILED:-} $1"
}
run_device_tests core common/core core_test
# HM-07v-a（编排 D10-405 D4、测试 v2 T0）：entry 拆成两个设备步，同锁、同一个测试包，各自计时、各自 1800 秒门槛、各自必跑名单：
#   entry         DS-02 158 + F-X-05a 9 + F-X-25 6 = 173 条（排除 Hm07vHomeUi、Hm07vOverlayUi 两个套件）
#   entry-hm07va  HM-07v-a 17 条（只跑 Hm07vHomeUi 套件）；device-test.sh 先卸载再装，从未同意隐私的冷启动开始（不受前一步状态影响）
#   entry-hm07vb  HM-07v-b 11 条（只跑 Hm07vOverlayUi 套件：弹窗与剪贴板浮层）；同样先卸载再装、各自 1800 秒（D10-232 / D10-405 D4 同口径）
#   entry-hm05r   HM-05r 11 条（只跑 Hm05rConsentUi 套件：剪贴板默认开启、关闭态、升级迁移、撤回与重新同意，测试 v3）；同样先卸载再装、从未同意隐私开始、各自 1800 秒
#   entry-me12v   APP-12v-harmony 14 条（只跑 Me12vUi 套件：「我的」Tab 视觉、受限会话不自动读、读取次数；H-M11）；同样先卸载再装、从未同意隐私开始、各自 1800 秒
#   entry-me12wa  APP-12w-a-harmony 15 条（只跑 Me12waUi 套件：设置一族视觉；H-S08）；同样先卸载再装、从未同意隐私开始（基本模式 → 游客 → 会员）、各自 1800 秒
#   entry-me12wb  APP-12w-b-harmony 17 条（只跑 Me12wbUi 套件：隐私中心 / 关于 / 客服半屏视觉与隐私红线；H-P13）；同样先卸载再装、从未同意隐私开始
#                 （基本模式 → 游客 → 会员 → 强更 → 真撤回）、各自 1800 秒
#   entry-me12wc  APP-12w-c-harmony 21 条（只跑 Me12wcUi 套件：账号状态 / 申诉视觉与处罚申诉红线；H-R16）；同样先卸载再装、从未同意隐私开始
#                 （会员 → 冻结组直达 → 封禁组 10006 落页 → 真退出）、各自 1800 秒（超了按 risk / appeal 拆两步，不放宽门槛）
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry notClass=Hm07vHomeUi,Hm07vOverlayUi,Hm05rConsentUi,Me12vUi,Me12waUi,Me12wbUi,Me12wcUi main
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry-hm07va class=Hm07vHomeUi hm07va
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry-hm07vb class=Hm07vOverlayUi hm07vb
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry-hm05r class=Hm05rConsentUi hm05r
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry-me12v class=Me12vUi me12v
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry-me12wa class=Me12waUi me12wa
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry-me12wb class=Me12wbUi me12wb
COULI_HM_TEST_TOTAL_TIMEOUT=1800 COULI_HM_TEST_CASE_TIMEOUT=600000 \
    run_device_tests entry entry entry_test staging "$OUT_DIR/Staging.hap" entry-me12wc class=Me12wcUi me12wc
# 设备步汇总（FU-HM-DEVICE-FLAKE）：全部设备步跑完才判；任一步红 → 整体失败，汇总里逐步列出 PASS / FAIL（D10-642 ① 可据此核对）。
if [ -n "${DEVICE_FAILED:-}" ]; then
    echo "DEVICE_STEPS_FAILED${DEVICE_FAILED}"
    fail_fast "device-test${DEVICE_FAILED}" "以上设备步红（其余设备步均已跑完，结果见汇总）"
fi

summary
echo "结果：通过"
