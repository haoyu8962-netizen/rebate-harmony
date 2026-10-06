#!/bin/bash
# Release 制品扫描（03 §3.6；05 QA-09 的最小前身）。
#
# 用法：
#   tools/ci/release-scan.sh <Release 的 .hap>             退出 0 = 未命中；1 = 命中（阻断发布）；2 = 扫描本身出错
#   tools/ci/release-scan.sh --self-test <Debug/Staging 的 .hap>
#                                                          证明扫描有牙齿：下列每一个「内容标记」都必须在包里命中，
#                                                          全部命中退出 0；有标记没命中退出 1；扫描出错退出 2
#
# 解包 .hap（zip）后逐字节扫描全部文件（ets/modules.abc、resources、module.json 等；UTF-8 与 UTF-16LE 两种编码）：
#   内容标记（Release 不得出现；Debug / Staging 必须全部出现）：
#   - 非 prod 环境地址：local / test / staging 的 .couli.invalid 域名
#   - 调试面板标记 COULI_DEBUG_PANEL、debug_only 路由表类名 DebugRoutes
#   - 快照 routes.json 里 debug_only 为 true 的路由名
#   - 环境切换实现：类名 EnvironmentSwitcher、调试面板选择的持久化键 couli.debug.environment_selection
#   - 调试能力判断：类名 DebugCapabilities、能力取值前缀 couli.debug.capability.
#   - 组件目录页（DS-01）：固定标记 COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2（目录页显示它；对照页同在 src/staging）
#   - 版本检查调试假数据（APP-02c）：生成物 AppVersionCheckExample 的 MARKER（三端同一串，调试面板显示它）、契约示例里的
#     商店地址 store.example.test（DATA_JSON 原样转写）、调试场景的偏好文件名 couli_debug_update
#   - 测试深链 scheme couli-debug（APP-02a：module.json 的 skills 只在 product=staging 声明，见 entry/hvigorfile.ts；
#     App 只认它的 DeepLinkConfig 在 entry/src/staging）。--self-test 另要求 module.json 的 EntryAbility skills 真的声明了它
#     （类名在开启混淆后可能被改名，所以每项都另配一个字符串字面量标记；字面量不会被裁掉，它们在逻辑里被用到）
#   可调试标志（只在扫描模式判定）：module.json 的 app.debug 为 true，或 app.buildMode 为 debug
#
# 任何一步失败（参数、mktemp、unzip、python3、读文件、产物结构不对）都按出错退出 2，绝不当成「未命中」或「命中」。
# 扫描只把 Python 打出的完成标记 + 约定退出码当成结果，其余一律视为出错（防 PATH 里被换成假工具）。
# 解包目录：$COULI_SCAN_WORK_DIR（verify.sh 设在构建镜像下）；未设时用 mktemp -d。
# 兼容 macOS bash 3.2；路径加引号。
set -euo pipefail

die() {
    echo "release-scan：出错：$*" >&2
    exit 2
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || die "找不到仓库根"
ROUTES="$ROOT/contracts/snapshot/contracts/routes.json"

MODE="scan"
if [ "${1:-}" = "--self-test" ]; then
    MODE="self-test"
    shift
fi
HAP="${1:-}"
if [ -z "$HAP" ] || [ "$#" -ne 1 ]; then
    echo "用法：release-scan.sh [--self-test] <.hap 路径>" >&2
    exit 2
fi
[ -f "$HAP" ] || die "找不到 $HAP"
[ -r "$HAP" ] || die "读不了 $HAP"
[ -f "$ROUTES" ] || die "找不到 $ROUTES"

if [ -n "${COULI_SCAN_WORK_DIR:-}" ]; then
    mkdir -p "$COULI_SCAN_WORK_DIR" || die "建不了 $COULI_SCAN_WORK_DIR"
    TMP="$(mktemp -d "$COULI_SCAN_WORK_DIR/scan.XXXXXX")" || die "mktemp 失败"
else
    TMP="$(mktemp -d)" || die "mktemp 失败"
fi
[ -n "$TMP" ] && [ -d "$TMP" ] || die "mktemp 没有给出目录"
trap 'rm -rf "$TMP"' EXIT

if ! unzip -q -o "$HAP" -d "$TMP/hap"; then
    die "unzip 失败（不是 zip / .hap，或 unzip 不可用）：$HAP"
fi

# Python 退出码约定：0 未命中 / 全部标记命中；10 命中（scan）；11 有标记没命中（self-test）；其余一律是出错。
# 正常结束时最后一行打印 RELEASE-SCAN-COMPLETE，没有这一行也算出错。
set +e
OUTPUT="$(python3 - "$TMP/hap" "$ROUTES" "$MODE" <<'PY'
import json, os, sys

def fail(msg):
    print("  出错 " + msg)
    sys.exit(2)

root, routes_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
DEBUG_SCHEME = "couli-debug"
try:
    with open(routes_path, encoding="utf-8") as f:
        routes = json.load(f)["routes"]
except Exception as e:  # noqa: BLE001 —— 任何读取/解析问题都是出错
    fail("读 routes.json 失败：%r" % (e,))

markers = [
    "local.couli.invalid", "test.couli.invalid", "staging.couli.invalid",
    "COULI_DEBUG_PANEL", "DebugRoutes",
    "EnvironmentSwitcher", "couli.debug.environment_selection",
    "DebugCapabilities", "couli.debug.capability.",
    "COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2",
    "COULI_UPDATE_CHECK_EXAMPLE_MARKER_5b7e3d91c2a4", "store.example.test", "couli_debug_update",
    DEBUG_SCHEME,
]
debug_routes = sorted(name for name, r in routes.items() if r.get("debug_only") is True)
if not debug_routes:
    fail("routes.json 里没有 debug_only 路由，快照不对")
markers += debug_routes

for required in ("module.json", os.path.join("ets", "modules.abc")):
    if not os.path.isfile(os.path.join(root, required)):
        fail("产物缺 %s，不像是 .hap" % required)

found = {}
files = 0
for dirpath, _, names in os.walk(root, onerror=lambda e: fail("遍历失败：%r" % (e,))):
    for name in names:
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except Exception as e:  # noqa: BLE001
            fail("读 %s 失败：%r" % (rel, e))
        files += 1
        for p in markers:
            for enc in ("utf-8", "utf-16-le"):
                if p.encode(enc) in data:
                    found.setdefault(p, []).append("%s（%s）" % (rel, enc))
                    break

try:
    with open(os.path.join(root, "module.json"), encoding="utf-8") as f:
        app = json.load(f)["app"]
except Exception as e:  # noqa: BLE001
    fail("解析 module.json 失败：%r" % (e,))
flags = []
if app.get("debug") is True:
    flags.append("module.json: app.debug = true（可调试标志打开）")
if app.get("buildMode") == "debug":
    flags.append("module.json: app.buildMode = debug")

# module.json 里声明的深链 scheme（EntryAbility 等所有 ability 的 skills.uris）。
module_obj = None
try:
    with open(os.path.join(root, "module.json"), encoding="utf-8") as f:
        module_obj = json.load(f).get("module", {})
except Exception as e:  # noqa: BLE001
    fail("解析 module.json 失败：%r" % (e,))
declared_schemes = set()
for ability in module_obj.get("abilities", []) or []:
    for skill in ability.get("skills", []) or []:
        for uri in skill.get("uris", []) or []:
            if isinstance(uri, dict) and uri.get("scheme"):
                declared_schemes.add(uri["scheme"])
if DEBUG_SCHEME in declared_schemes:
    flags.append("module.json: skills 声明了测试深链 scheme %s" % DEBUG_SCHEME)

for p in markers:
    if p in found:
        print("  命中 %r：%s" % (p, "、".join(found[p][:3])))
for fl in flags:
    print("  命中 " + fl)

if mode == "self-test":
    missing = [p for p in markers if p not in found]
    if DEBUG_SCHEME not in declared_schemes:
        missing.append("module.json skills scheme " + DEBUG_SCHEME)
    for p in missing:
        print("  未命中 %r" % p)
    print("RELEASE-SCAN-COMPLETE files=%d markers=%d found=%d" % (files, len(markers), len(markers) - len(missing)))
    sys.exit(11 if missing else 0)
print("RELEASE-SCAN-COMPLETE files=%d markers=%d found=%d" % (files, len(markers), len(found)))
sys.exit(10 if (found or flags) else 0)
PY
)"
STATUS=$?
set -e

printf '%s\n' "$OUTPUT" | grep -v '^RELEASE-SCAN-COMPLETE' || true
if ! printf '%s\n' "$OUTPUT" | grep -q '^RELEASE-SCAN-COMPLETE '; then
    die "扫描没有正常结束（python3 exit ${STATUS}，没有完成标记）"
fi
NAME="$(basename "$HAP")"

if [ "$MODE" = "self-test" ]; then
    case "$STATUS" in
        0)  echo "release-scan --self-test：${NAME} 命中全部内容标记（扫描有效）"; exit 0 ;;
        11) echo "release-scan --self-test：${NAME} 有内容标记没命中——扫描没有牙齿或标记被裁掉" >&2; exit 1 ;;
        *)  die "python3 exit ${STATUS}" ;;
    esac
fi
case "$STATUS" in
    0)  echo "release-scan：${NAME} 未命中（非 prod 地址、调试面板、debug_only 路由、环境切换实现、调试能力判断、组件目录页、版本检查假数据、测试深链 scheme、可调试标志）"; exit 0 ;;
    10) echo "release-scan：${NAME} 含调试能力或非 prod 残留，阻断发布" >&2; exit 1 ;;
    *)  die "python3 exit ${STATUS}" ;;
esac
