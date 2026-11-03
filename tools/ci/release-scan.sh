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
#   - 非 prod 环境地址：local / test 的 .couli.invalid 域名；staging 真实主机的公共后缀 -stg.couliapp.cn
#     （api-stg / h5-stg / stream-stg / l-stg / s-stg，FU-X-STAGING-HOSTS；Release 一个都不得含）
#   - 调试面板标记 COULI_DEBUG_PANEL、debug_only 路由表类名 DebugRoutes
#   - 快照 routes.json 里 debug_only 为 true 的路由名
#   - 环境切换实现：类名 EnvironmentSwitcher、调试面板选择的持久化键 couli.debug.environment_selection
#   - 调试能力判断：类名 DebugCapabilities、能力取值前缀 couli.debug.capability.
#   - 组件目录页（DS-01）：固定标记 COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2（目录页显示它；对照页同在 src/staging）
#   - 版本检查调试假数据（APP-02c）：生成物 AppVersionCheckExample 的 MARKER（三端同一串，调试面板显示它）、契约示例里的
#     商店地址 store.example.test（DATA_JSON 原样转写）、调试场景的偏好文件名 couli_debug_update
#   - 桥一致性入口（APP-04）：本机回环可信源 http://127.0.0.1:8788、入口标记 COULI_BRIDGE_CONFORMANCE_APP04_3c9e1f、
#     调试路由名 CouliDebugWeb（都在 entry/src/staging；回环源只在 Debug 构建加入可信白名单）
#   - 桥的测试专用实现（APP-04 R1-02）：替换值类名 AppBridgeOverrides、假登录字段 assumeLoggedIn、调试探针 debugProbe
#     （entry/src/staging/ets/variant/DebugBridge.ets）；回环支持 LOOPBACK_HOSTS 与回环字面量 127.0.0.1、localhost
#     （core 的 src/staging/ets/bridge/DevOrigins.ets 与 DebugBridge.ets）。Release 编译的是 src/release 的同名替身，不含这些
#   - 登录本机假服务（APP-05a）：标记 COULI_FAKE_LOGIN_SERVER_APP05A_9d2c41、启动参数键 couli_debug_fake_server
#     （entry/src/staging/ets/variant/DebugFakeServer.ets）；APP-06a 搜索与详情场景的标记 COULI_FAKE_SEARCH_SERVER_APP06A_4f8e27（DebugFakeSearch.ets）
#   - 微信登录的假适配器（APP-05b）：标记 COULI_FAKE_WECHAT_ADAPTER_APP05B_7b31e5（entry/src/staging/ets/variant/DebugWechatAdapter.ets）
#   - 购买与授权的本机假服务（APP-06b）：标记 COULI_FAKE_TRADE_SERVER_APP06B_5d1e93、场景启动参数键 couli_debug_trade_scene
#     （entry/src/staging/ets/variant/DebugFakeTrade.ets）；模拟安装状态的外跳端口包装：类名 DebugJumpPorts、标记
#     COULI_DEBUG_JUMP_PORTS_FUHM0607_2c7d4e（同文件，共性第 42 条：Release 的外跳端口没有任何模拟开关或分支）
#   - 订单的本机假服务（APP-08）：标记 COULI_FAKE_ORDERS_SERVER_APP08_7c31d9、场景启动参数键 couli_debug_orders_scene
#     （entry/src/staging/ets/variant/DebugFakeOrders.ets）
#   - 钱包的本机假服务（APP-09）：标记 COULI_FAKE_WALLET_SERVER_APP09_6b2f41、启动参数键 couli_debug_wallet_scene、
#     couli_debug_open_route（entry/src/staging/ets/variant/DebugFakeWallet.ets、BuildVariant.ets）
#   - 「我的」类本机假服务与推送令牌假来源（APP-12）：标记 COULI_FAKE_ME_SERVER_APP12_8e4b27、COULI_DEBUG_PUSH_TOKEN_APP12_3a9d52、
#     启动参数键 couli_debug_me_scene、couli_debug_settings_sub（entry/src/staging/ets/variant/DebugFakeMe.ets、BuildVariant.ets）
#   - Agent 的本机假服务（APP-10）：标记 COULI_AGENT_FAKE_APP10_7d3e15、类名 AgentFakeService、
#     启动参数键 couli_debug_agent_fixture（common/core/src/staging/ets/agent/、entry/src/staging/ets/agent/）；
#     启动参数自动发送（harmony-review-r1 R1-11）：标记 COULI_AGENT_LAUNCH_SEND_APP10_2f9c4d、启动参数键 couli_debug_agent_send
#     （entry/src/staging/ets/agent/AgentVariant.ets；Release 的同名文件是空实现）
#   - Agent 真实流式传输（APP-10b）：传输入口的本机假服务类名 AgentFakeTransport（common/core/src/staging/ets/agent/）、
#     历史场景启动参数键 couli_debug_agent_history（entry/src/staging/ets/agent/AgentVariant.ets）
# 另有「只许在测试源码集」的标记（APP-10b harmony-review-r1 R1-04）：向量接线的脚本端口 / 虚拟流类名（TimeoutProbePort、TimeoutProbeHandle、
# AgentProbePort、AgentProbeHandle、AgentProbeTimer、AgentVectorProbe、虚拟计时器 AgentVirtualTimer）与硬编码的 meta / done 帧片段（common/core/src/test/AgentVectorWiring.ets）。
# 它们不该出现在任何制品里：Release 扫描命中即阻断；--self-test（Staging / Debug）同样不得命中（命中退出 1，与「有标记没命中」区分见下）。
#   - 注销与换手机号的本机假服务（APP-13a）：标记 COULI_FAKE_ACCOUNT_SERVER_APP13A_2d7f90、启动参数键 couli_debug_account_scene；
#     路由可用性覆盖开关：标记 COULI_DEBUG_ROUTE_AVAILABILITY_APP13A_5c1e、启动参数键 couli_debug_route_available
#     （entry/src/staging/ets/variant/DebugFakeAccount.ets、BuildVariant.ets）
#   - 首页 SDUI 的本机假服务与草稿预览（APP-11）：标记 COULI_FAKE_HOME_SERVER_APP11_5e8c21、启动参数键 couli_debug_home_scene
#     （entry/src/staging/ets/variant/DebugFakeHome.ets）、预览页标记 COULI_HOME_PREVIEW_APP11_9b4d27（entry/src/staging/ets/home/HomePreviewPage.ets）
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
    "local.couli.invalid", "test.couli.invalid", "-stg.couliapp.cn",
    "COULI_DEBUG_PANEL", "DebugRoutes",
    "EnvironmentSwitcher", "couli.debug.environment_selection",
    "DebugCapabilities", "couli.debug.capability.",
    "COULI_COMPONENT_CATALOG_DS01_7f3a9c51e2",
    "COULI_UPDATE_CHECK_EXAMPLE_MARKER_5b7e3d91c2a4", "store.example.test", "couli_debug_update",
    DEBUG_SCHEME,
    # APP-04：Debug 构建的桥一致性入口（本机回环可信源、一致性入口标记、调试路由名）。
    "http://127.0.0.1:8788", "COULI_BRIDGE_CONFORMANCE_APP04_3c9e1f", "CouliDebugWeb",
    # APP-04 R1-02：桥的测试专用实现与回环支持。
    "AppBridgeOverrides", "assumeLoggedIn", "debugProbe", "LOOPBACK_HOSTS", "127.0.0.1", "localhost",
    # APP-05a：登录冒烟与截图用的本机假服务（entry/src/staging/ets/variant/DebugFakeServer.ets）。
    "COULI_FAKE_LOGIN_SERVER_APP05A_9d2c41", "couli_debug_fake_server",
    # APP-06a：搜索与详情的本机假服务场景（entry/src/staging/ets/variant/DebugFakeSearch.ets）。
    "COULI_FAKE_SEARCH_SERVER_APP06A_4f8e27",
    # APP-05b：微信登录的假适配器（entry/src/staging/ets/variant/DebugWechatAdapter.ets）。
    "COULI_FAKE_WECHAT_ADAPTER_APP05B_7b31e5",
    # HM-14a：core staging 华为假能力与 entry 场景参数，Release 不得包含。
    "COULI_FAKE_HUAWEI_HM14A_8c2f31", "couli_debug_huawei_scene",
    # APP-06b：购买、外跳与授权的本机假服务场景（entry/src/staging/ets/variant/DebugFakeTrade.ets）与场景启动参数键。
    "COULI_FAKE_TRADE_SERVER_APP06B_5d1e93", "couli_debug_trade_scene",
    # APP-06b 共性第 42 条：模拟安装状态的外跳端口包装（entry/src/staging/ets/variant/DebugFakeTrade.ets），开关与执行分支都只在 staging。
    "DebugJumpPorts", "COULI_DEBUG_JUMP_PORTS_FUHM0607_2c7d4e",
    # APP-08：订单列表、详情与待跟单卡的本机假服务场景（entry/src/staging/ets/variant/DebugFakeOrders.ets）与场景启动参数键。
    "COULI_FAKE_ORDERS_SERVER_APP08_7c31d9", "couli_debug_orders_scene", "couli_debug_open_order",
    # APP-09：钱包、提现、收款账号、二次验证与实名 / 劳务协议待定接口的本机假服务（entry/src/staging/ets/variant/DebugFakeWallet.ets）
    # 与场景、打开路由的启动参数键。
    "COULI_FAKE_WALLET_SERVER_APP09_6b2f41", "couli_debug_wallet_scene", "couli_debug_open_route",
    # APP-12：「我的」、封禁与申诉、改昵称与通知设置待定接口的本机假服务与推送令牌的 Debug 假来源（entry/src/staging/ets/variant/
    # DebugFakeMe.ets）与场景、截图覆盖的启动参数键。
    "COULI_FAKE_ME_SERVER_APP12_8e4b27", "COULI_DEBUG_PUSH_TOKEN_APP12_3a9d52", "couli_debug_me_scene",
    "couli_debug_settings_sub",
    # APP-11：首页 SDUI 待定接口（getPage、listSectionItems）与 previewPage 草稿的本机假服务（entry/src/staging/ets/variant/DebugFakeHome.ets）、
    # 场景启动参数键，以及首页草稿预览页 HomePreview 的标记（entry/src/staging/ets/home/HomePreviewPage.ets；路由名 HomePreview 由下面
    # routes.json 的 debug_only 路由覆盖）。
    "COULI_FAKE_HOME_SERVER_APP11_5e8c21", "couli_debug_home_scene", "COULI_HOME_PREVIEW_APP11_9b4d27",
    # HM-07v（H-V06，D10-119）：首页深色截图的启动参数键（entry/src/staging/ets/variant/BuildVariant.ets），Release 必须不含。
    "couli_debug_color_mode",
    # APP-10：Agent 四个待定 operation 的本机假服务（common/core/src/staging/ets/agent/AgentFakeService.ets）、fixture 原文表
    # （entry/src/staging/ets/variant/AgentFixtures.ets，gen.py 生成）与启动参数键（entry/src/staging/ets/agent/AgentVariant.ets）。
    "COULI_AGENT_FAKE_APP10_7d3e15", "AgentFakeService", "couli_debug_agent_fixture",
    # APP-10b：7 个 /v1/agent operation 的本机假服务（接在 ApiClient 下面的实际传输入口；历史 / 反馈 / 举报的假实现同一标记）与其启动参数键。
    "AgentFakeTransport", "couli_debug_agent_history",
    # APP-10 R1-11：启动参数自动发送与重试计时的实现（只在 staging 源码集）。
    "COULI_AGENT_LAUNCH_SEND_APP10_2f9c4d", "couli_debug_agent_send",
    # APP-13a：注销与换手机号的本机假服务（entry/src/staging/ets/variant/DebugFakeAccount.ets）与场景启动参数键；路由可用性覆盖开关
    # （编排者补充 G01：DeleteAccount since=null 时只在 Debug / Staging 用于冒烟、截图，entry/src/staging/ets/variant/BuildVariant.ets）。
    "COULI_FAKE_ACCOUNT_SERVER_APP13A_2d7f90", "couli_debug_account_scene",
    "COULI_DEBUG_ROUTE_AVAILABILITY_APP13A_5c1e", "couli_debug_route_available",
]
# APP-10b R1-04：只许在测试源码集的标记（任何制品都不得命中；不参与 --self-test 的「必须命中」）。
test_only_markers = [
    "TimeoutProbePort", "TimeoutProbeHandle", "AgentProbePort", "AgentProbeHandle", "AgentProbeTimer", "AgentVectorProbe",
    "AgentVirtualTimer",
    '"model_label":"m","ai_label":"a"', '"finish_reason":"stop","quota_left":1}',
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
        for p in test_only_markers:
            for enc in ("utf-8", "utf-16-le"):
                if p.encode(enc) in data:
                    found.setdefault(p, []).append("%s（%s）" % (rel, enc))
                    break
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

for p in markers + test_only_markers:
    if p in found:
        print("  命中 %r：%s" % (p, "、".join(found[p][:3])))
test_only_found = [p for p in test_only_markers if p in found]
for fl in flags:
    print("  命中 " + fl)

if mode == "self-test":
    missing = [p for p in markers if p not in found]
    if DEBUG_SCHEME not in declared_schemes:
        missing.append("module.json skills scheme " + DEBUG_SCHEME)
    for p in missing:
        print("  未命中 %r" % p)
    for p in test_only_found:
        print("  测试源码集标记进了制品 %r" % p)
    print("RELEASE-SCAN-COMPLETE files=%d markers=%d found=%d" % (files, len(markers), len(markers) - len(missing)))
    sys.exit(12 if test_only_found else (11 if missing else 0))
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
        12) echo "release-scan --self-test：${NAME} 含只许在测试源码集的向量探针或帧数据（R1-04）" >&2; exit 1 ;;
        *)  die "python3 exit ${STATUS}" ;;
    esac
fi
case "$STATUS" in
    0)  echo "release-scan：${NAME} 未命中（非 prod 地址、调试面板、debug_only 路由、环境切换实现、调试能力判断、组件目录页、版本检查假数据、桥一致性入口与回环源、桥测试专用实现、测试深链 scheme、可调试标志）"; exit 0 ;;
    10) echo "release-scan：${NAME} 含调试能力或非 prod 残留，阻断发布" >&2; exit 1 ;;
    *)  die "python3 exit ${STATUS}" ;;
esac
